// Push-Relay: interne Mutations/Queries für die HTTP-Endpunkte /push/* (http.ts).
// Schutz: Server-Authentifizierung (serverSecret), nur gemeldete Tokens des Inhabers, Ratenbegrenzung,
// Kanäle gehören dem anlegenden Server. Den Versand an APNs macht convex/apns.ts ("use node").
import { v } from "convex/values";
import type { Doc, Id } from "./_generated/dataModel";
import { internalMutation, internalQuery, type MutationCtx } from "./_generated/server";
import {
  CHANNEL_MAX_AGE_MS,
  KIND_FOR,
  kindForPlatform,
  LIMITS,
  MAX_CHANNELS_PER_SERVER,
  MAX_TOKENS_PER_OWNER,
  normalizeToken,
  type PushType,
} from "./lib/push";
import { rateLimit } from "./lib/session";
import { granteesOf } from "./lib/shares";

async function serverBySecret(ctx: MutationCtx, secretHash: string): Promise<Doc<"servers"> | null> {
  return ctx.db
    .query("servers")
    .withIndex("by_secretHash", (q) => q.eq("secretHash", secretHash))
    .unique();
}

async function limit(ctx: MutationCtx, key: string, l: { limit: number; windowMs: number }, amount: number) {
  return rateLimit(ctx, key, l.limit, l.windowMs, { count: true, amount });
}

export const serverKnown = internalQuery({
  args: { secretHash: v.string() },
  handler: async (ctx, { secretHash }) =>
    Boolean(
      await ctx.db
        .query("servers")
        .withIndex("by_secretHash", (q) => q.eq("secretHash", secretHash))
        .unique(),
    ),
});

/** Tokens melden (vom Server, sobald die App sie ihm gibt). Mit `userId` (≠ Inhaber) meldet der Server das Gerät
 *  eines Gasts, der einen Share auf diesem Server hat (docs/sharing.md) – sonst wird der Eintrag abgelehnt. */
export const register = internalMutation({
  args: {
    secretHash: v.string(),
    entries: v.array(v.object({ token: v.string(), platform: v.string(), userId: v.optional(v.string()) })),
  },
  handler: async (ctx, a) => {
    const server = await serverBySecret(ctx, a.secretHash);
    if (!server) return { status: "unknown_server" as const };
    if (!(await limit(ctx, `pushreg:${server._id}`, LIMITS.registerHour, Math.max(1, a.entries.length)))) {
      return { status: "rate_limited" as const };
    }
    const now = Date.now();
    const rejected: { token: string; reason: string }[] = [];
    let registered = 0;
    let grantees: Set<Id<"users">> | null = null;
    const touched = new Set<Id<"users">>();
    for (const e of a.entries) {
      const token = normalizeToken(e.token);
      const kind = kindForPlatform(e.platform);
      let ownerId: Id<"users"> = server.ownerId;
      if (e.userId && e.userId !== server.ownerId) {
        grantees = grantees ?? (await granteesOf(ctx, server._id));
        const gid = ctx.db.normalizeId("users", e.userId);
        if (!gid || !grantees.has(gid)) {
          rejected.push({ token: e.token.slice(0, 400), reason: "NotShared" });
          continue;
        }
        ownerId = gid;
      }
      if (!token) {
        rejected.push({ token: e.token.slice(0, 400), reason: "BadDeviceToken" });
        continue;
      }
      if (!kind) {
        rejected.push({ token: e.token, reason: "UnknownPlatform" });
        continue;
      }
      touched.add(ownerId);
      const row = await ctx.db
        .query("pushTokens")
        .withIndex("by_owner_token", (q) => q.eq("ownerId", ownerId).eq("token", token))
        .unique();
      if (row) {
        // Plattformwechsel (z. B. Live-Start-Token wird nie zum App-Token) ist nicht vorgesehen – Art bleibt.
        await ctx.db.patch(row._id, { serverId: server._id, lastUsedAt: now, platform: e.platform.slice(0, 40) });
        if (row.kind !== kind) rejected.push({ token: e.token, reason: "KindMismatch" });
        else registered++;
        continue;
      }
      await ctx.db.insert("pushTokens", {
        ownerId,
        token,
        kind,
        platform: e.platform.slice(0, 40),
        serverId: server._id,
        createdAt: now,
        lastUsedAt: now,
      });
      registered++;
    }
    // Höchstens MAX_TOKENS_PER_OWNER Einträge je Konto: am längsten ungenutzte fallen heraus.
    for (const ownerId of touched) {
      const all = await ctx.db
        .query("pushTokens")
        .withIndex("by_owner_lastUsed", (q) => q.eq("ownerId", ownerId))
        .order("desc")
        .collect();
      for (const old of all.slice(MAX_TOKENS_PER_OWNER)) await ctx.db.delete(old._id);
    }
    return { status: "ok" as const, registered, rejected };
  },
});

/** Vor dem Versand: Server prüfen, Ratenbegrenzung zählen, nur eigene Tokens passender Art freigeben. */
export const prepareSend = internalMutation({
  args: { secretHash: v.string(), jobs: v.array(v.object({ token: v.string(), pushType: v.string() })) },
  handler: async (ctx, a) => {
    const server = await serverBySecret(ctx, a.secretHash);
    if (!server) return { status: "unknown_server" as const };
    const verdicts: { token: string; ok: boolean; reason?: string; env?: "production" | "sandbox"; ownerId?: Id<"users"> }[] = [];
    let grantees: Set<Id<"users">> | null = null;
    for (const j of a.jobs) {
      let row = await ctx.db
        .query("pushTokens")
        .withIndex("by_owner_token", (q) => q.eq("ownerId", server.ownerId).eq("token", j.token))
        .unique();
      if (!row) {
        // Gerät eines Gasts mit Share auf diesem Server (geteilte Scoops)?
        const rows = await ctx.db
          .query("pushTokens")
          .withIndex("by_token", (q) => q.eq("token", j.token))
          .take(20);
        if (rows.length) {
          grantees = grantees ?? (await granteesOf(ctx, server._id));
          row = rows.find((r) => grantees!.has(r.ownerId)) ?? null;
        }
      }
      if (!row) verdicts.push({ token: j.token, ok: false, reason: "UnknownToken" });
      else if (row.kind !== KIND_FOR[j.pushType as PushType]) verdicts.push({ token: j.token, ok: false, reason: "TopicDisallowed" });
      else verdicts.push({ token: j.token, ok: true, env: row.env, ownerId: row.ownerId });
    }
    const n = verdicts.filter((x) => x.ok).length;
    if (n > 0) {
      // Erst prüfen (ohne zu zählen), dann alle drei Zähler erhöhen – kein Zähler läuft bei Ablehnung hoch.
      const checks: [string, { limit: number; windowMs: number }][] = [
        [`pushmin:${server._id}`, LIMITS.sendMinute],
        [`pushhour:${server._id}`, LIMITS.sendHour],
        [`pushowner:${server.ownerId}`, LIMITS.ownerHour],
      ];
      for (const [key, l] of checks) {
        if (!(await rateLimit(ctx, key, l.limit, l.windowMs, { count: false, amount: n }))) {
          return { status: "rate_limited" as const };
        }
      }
      for (const [key, l] of checks) await limit(ctx, key, l, n);
    }
    return { status: "ok" as const, ownerId: server.ownerId, serverId: server._id, verdicts };
  },
});

/** Nach dem Versand: abgemeldete Tokens löschen, gelernte Umgebung (production/sandbox) merken. */
export const recordResults = internalMutation({
  args: {
    ownerId: v.id("users"),
    results: v.array(
      v.object({
        token: v.string(),
        ownerId: v.optional(v.id("users")), // Gerät eines Gasts: dessen Konto

        env: v.optional(v.union(v.literal("production"), v.literal("sandbox"))),
        remove: v.boolean(),
      }),
    ),
  },
  handler: async (ctx, a) => {
    const now = Date.now();
    for (const r of a.results) {
      const row = await ctx.db
        .query("pushTokens")
        .withIndex("by_owner_token", (q) => q.eq("ownerId", r.ownerId ?? a.ownerId).eq("token", r.token))
        .unique();
      if (!row) continue;
      if (r.remove) await ctx.db.delete(row._id);
      else await ctx.db.patch(row._id, { lastUsedAt: now, ...(r.env ? { env: r.env } : {}) });
    }
  },
});

/** Kanal anlegen/löschen/an Kanal senden: Server prüfen, Besitz des Kanals, Grenzen. */
export const prepareChannel = internalMutation({
  args: {
    secretHash: v.string(),
    op: v.union(v.literal("create"), v.literal("delete"), v.literal("broadcast")),
    channelId: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const server = await serverBySecret(ctx, a.secretHash);
    if (!server) return { status: "unknown_server" as const };
    if (a.op === "create") {
      const mine = await ctx.db
        .query("pushChannels")
        .withIndex("by_server", (q) => q.eq("serverId", server._id))
        .collect();
      if (mine.length >= MAX_CHANNELS_PER_SERVER) return { status: "too_many_channels" as const };
      if (!(await limit(ctx, `pushchan:${server._id}`, LIMITS.channelHour, 1))) return { status: "rate_limited" as const };
      return { status: "ok" as const, serverId: server._id, ownerId: server.ownerId };
    }
    const ch = a.channelId
      ? await ctx.db
          .query("pushChannels")
          .withIndex("by_channel", (q) => q.eq("channelId", a.channelId!))
          .unique()
      : null;
    if (!ch || ch.serverId !== server._id) return { status: "unknown_channel" as const };
    if (a.op === "broadcast") {
      const checks: [string, { limit: number; windowMs: number }][] = [
        [`bcmin:${server._id}`, LIMITS.broadcastMinute],
        [`bchour:${server._id}`, LIMITS.broadcastHour],
      ];
      for (const [key, l] of checks) {
        if (!(await rateLimit(ctx, key, l.limit, l.windowMs, { count: false }))) return { status: "rate_limited" as const };
      }
      for (const [key, l] of checks) await limit(ctx, key, l, 1);
    }
    return { status: "ok" as const, serverId: server._id, ownerId: server.ownerId };
  },
});

export const addChannel = internalMutation({
  args: { channelId: v.string(), serverId: v.id("servers"), ownerId: v.id("users") },
  handler: async (ctx, a) => {
    await ctx.db.insert("pushChannels", { ...a, createdAt: Date.now() });
  },
});

export const removeChannel = internalMutation({
  args: { channelId: v.string() },
  handler: async (ctx, { channelId }) => {
    for (const c of await ctx.db
      .query("pushChannels")
      .withIndex("by_channel", (q) => q.eq("channelId", channelId))
      .collect()) {
      await ctx.db.delete(c._id);
    }
  },
});

/** Für den Cron (apns.cleanupChannels): Kanäle, die älter sind als CHANNEL_MAX_AGE_MS oder deren Server weg ist. */
export const staleChannels = internalQuery({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const old = await ctx.db
      .query("pushChannels")
      .withIndex("by_createdAt", (q) => q.lt("createdAt", now - CHANNEL_MAX_AGE_MS))
      .take(100);
    const orphan: Doc<"pushChannels">[] = [];
    for (const c of await ctx.db.query("pushChannels").take(500)) {
      if (!(await ctx.db.get(c.serverId))) orphan.push(c);
    }
    const ids = new Set<string>();
    return [...old, ...orphan].filter((c) => !ids.has(c.channelId) && ids.add(c.channelId)).map((c) => c.channelId);
  },
});

/** Cron: Tokens, die 90 Tage nicht benutzt wurden (Live-Update-Tokens: 2 Tage), entfernen. */
export const cleanupTokens = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const old = await ctx.db
      .query("pushTokens")
      .withIndex("by_lastUsedAt", (q) => q.lt("lastUsedAt", now - 2 * 86400_000))
      .take(1000);
    for (const t of old) {
      const stale = t.platform === "liveactivity" || now - t.lastUsedAt > 90 * 86400_000;
      if (stale) await ctx.db.delete(t._id);
    }
  },
});

/** Beim Löschen eines Kontos: alle gemeldeten Tokens entfernen. */
export async function deletePushTokensOf(ctx: MutationCtx, ownerId: Id<"users">): Promise<void> {
  for (const t of await ctx.db
    .query("pushTokens")
    .withIndex("by_owner_lastUsed", (q) => q.eq("ownerId", ownerId))
    .collect()) {
    await ctx.db.delete(t._id);
  }
}
