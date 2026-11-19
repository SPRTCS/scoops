// Interne Mutations für die Server-Seite der Kopplung und den Herzschlag (aufgerufen aus http.ts).
import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { CODE_TTL_MS } from "./lib/crypto";
import { REVOKED_KEEP_MS } from "./lib/session";
import { granteesOf } from "./lib/shares";

export const create = internalMutation({
  args: {
    code: v.string(),
    claimSecretHash: v.string(),
    name: v.string(),
    publicUrl: v.string(),
    tailnetUrl: v.optional(v.string()),
    version: v.string(),
  },
  handler: async (ctx, a) => {
    const now = Date.now();
    const clash = await ctx.db
      .query("serverClaims")
      .withIndex("by_code", (q) => q.eq("code", a.code))
      .filter((q) => q.gt(q.field("expiresAt"), now))
      .first();
    if (clash) return null; // Aufrufer würfelt neu
    const expiresAt = now + CODE_TTL_MS;
    const claimId = await ctx.db.insert("serverClaims", { ...a, status: "pending", expiresAt, createdAt: now });
    return { claimId, expiresAt };
  },
});

/** Ergebnis für den Server. Bei „claimed“ wird das (neue) serverSecret-Hash gesetzt. */
export const poll = internalMutation({
  args: { claimId: v.string(), claimSecretHash: v.string(), newSecretHash: v.string() },
  handler: async (ctx, a) => {
    const id = ctx.db.normalizeId("serverClaims", a.claimId);
    const claim = id ? await ctx.db.get(id) : null;
    if (!claim || claim.claimSecretHash !== a.claimSecretHash) return { status: "unknown" as const };
    if (claim.status === "pending") {
      if (claim.expiresAt <= Date.now()) return { status: "expired" as const };
      return { status: "pending" as const, expiresAt: claim.expiresAt };
    }
    const server = claim.serverId ? await ctx.db.get(claim.serverId) : null;
    if (!server) return { status: "unknown" as const }; // inzwischen in der App entfernt
    // Jede Abholung erzeugt ein neues Secret (falls eine Antwort verloren ging). Der erste Herzschlag
    // löscht den Kopplungseintrag, danach ist kein erneutes Abholen mehr möglich.
    await ctx.db.patch(server._id, { secretHash: a.newSecretHash });
    const owner = await ctx.db.get(server.ownerId);
    return {
      status: "claimed" as const,
      serverId: server._id,
      ownerId: server.ownerId,
      name: server.name,
      // Anzeigename des Kontos (z. B. für die Ansprache durch die Scoops); null, wenn Apple keinen geliefert hat.
      ownerName: owner?.name ?? null,
    };
  },
});

export const heartbeat = internalMutation({
  args: {
    secretHash: v.string(),
    publicUrl: v.optional(v.string()),
    tailnetUrl: v.optional(v.string()),
    version: v.optional(v.string()),
  },
  handler: async (ctx, a) => {
    const server = await ctx.db
      .query("servers")
      .withIndex("by_secretHash", (q) => q.eq("secretHash", a.secretHash))
      .unique();
    if (!server) return null;
    const now = Date.now();
    await ctx.db.patch(server._id, {
      lastSeenAt: now,
      ...(a.publicUrl ? { publicUrl: a.publicUrl } : {}),
      ...(a.tailnetUrl ? { tailnetUrl: a.tailnetUrl } : {}),
      ...(a.version ? { version: a.version } : {}),
    });
    for (const c of await ctx.db
      .query("serverClaims")
      .withIndex("by_server", (q) => q.eq("serverId", server._id))
      .collect()) {
      await ctx.db.delete(c._id);
    }
    // Widerrufene Sitzungen des Inhabers und der Gäste mit Share auf diesem Server: Der Server lehnt deren
    // JWTs ab, obwohl sie noch nicht abgelaufen sind.
    const revokedSessions: string[] = [];
    for (const userId of [server.ownerId, ...(await granteesOf(ctx, server._id))]) {
      const sessions = await ctx.db
        .query("sessions")
        .withIndex("by_user", (q) => q.eq("userId", userId))
        .collect();
      for (const s of sessions) {
        if (s.revokedAt !== undefined && now - s.revokedAt < REVOKED_KEEP_MS) revokedSessions.push(s._id);
      }
    }
    const owner = await ctx.db.get(server.ownerId);
    return {
      serverId: server._id,
      ownerId: server.ownerId,
      name: server.name,
      ownerName: owner?.name ?? null,
      revokedSessions,
      // Geteilte Scoops: Weicht die Zahl vom Stand des Servers ab, lädt er die Shares neu (/shares/sync).
      sharesVersion: server.sharesVersion ?? 0,
    };
  },
});

/** Aufräumen (Cron): abgelaufene Codes, alte Zähler, lange widerrufene Sitzungen. */
export const cleanup = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const old = await ctx.db
      .query("serverClaims")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", now - 60 * 60 * 1000))
      .take(500);
    for (const c of old) await ctx.db.delete(c._id);
    for (const r of await ctx.db.query("rateLimits").take(1000)) {
      if (now - r.windowStart > 24 * 60 * 60 * 1000) await ctx.db.delete(r._id);
    }
    const revoked = await ctx.db
      .query("sessions")
      .withIndex("by_revokedAt", (q) => q.gt("revokedAt", 0).lt("revokedAt", now - REVOKED_KEEP_MS))
      .take(500);
    for (const s of revoked) await ctx.db.delete(s._id);
  },
});
