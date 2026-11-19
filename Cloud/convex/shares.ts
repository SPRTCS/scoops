// Geteilte Scoops (docs/sharing.md, „Ist-Stand Phase 1“): Einladungen und Shares.
// Admin = Inhaber des Servers (servers.ownerId). Gäste sehen und verlassen nur ihre eigenen Shares.
// Inhalte laufen nie über Convex – hier steht nur, wer welchen Scoop mit welcher Rolle sieht.
import { ConvexError, v } from "convex/values";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import { action, internalMutation, mutation, query, type QueryCtx } from "./_generated/server";
import { randomToken, sha256hex } from "./lib/crypto";
import { ONLINE_WINDOW_MS, rateLimit, viewer } from "./lib/session";
import {
  ACCEPT_FAILS,
  adminShare,
  bumpShares,
  cleanMascot,
  cleanName,
  computerV,
  deleteSharesOfBot,
  INVITE_LIMIT,
  INVITE_TTL_MS,
  MAX_INVITES_PER_BOT,
  MAX_SHARES_PER_BOT,
  normalizeInviteCode,
  ownedServer,
  roleV,
  validBotId,
} from "./lib/shares";

type Fail = { ok: false; error: string; message: string };
const fail = (error: string, message: string): Fail => ({ ok: false, error, message });

// -- Admin ----------------------------------------------------------------------------------

/** Einladung anlegen. Action, weil der Code echte Zufälligkeit braucht (nie in Mutations erzeugt).
 *  Aufruf: POST <cloud>/api/action {"path": "shares:createInvite", "args": {…}} */
export const createInvite = action({
  args: {
    serverId: v.string(),
    botId: v.string(),
    botName: v.string(),
    botMascot: v.optional(v.any()),
    role: v.optional(roleV),
    computer: v.optional(computerV),
  },
  handler: async (
    ctx,
    a,
  ): Promise<
    | { ok: true; inviteId: string; code: string; url: string; appUrl: string; expiresAt: number; role: string; computer: string }
    | Fail
  > => {
    const code = randomToken(16); // 128 Bit, URL-sicher (22 Zeichen)
    const out: { ok: true; inviteId: string; expiresAt: number; role: string; computer: string } | Fail =
      await ctx.runMutation(internal.shares.insertInvite, { ...a, codeHash: await sha256hex(code) });
    if (!out.ok) return out;
    const site = (process.env.CONVEX_SITE_URL ?? "").replace(/\/$/, "");
    return { ...out, code, url: `${site}/i/${code}`, appUrl: `aisscoops://invite/${code}` };
  },
});

export const insertInvite = internalMutation({
  args: {
    serverId: v.string(),
    botId: v.string(),
    botName: v.string(),
    botMascot: v.optional(v.any()),
    role: v.optional(roleV),
    computer: v.optional(computerV),
    codeHash: v.string(),
  },
  handler: async (ctx, a) => {
    const { user } = await viewer(ctx);
    const server = await ownedServer(ctx, user._id, a.serverId);
    if (!server) return fail("not_owner", "Nur der Admin (Inhaber des Servers) kann diesen Scoop teilen.");
    const botName = cleanName(a.botName);
    if (!validBotId(a.botId) || !botName) return fail("bad_request", "Scoop-ID oder Name fehlt.");
    const now = Date.now();
    const open = (
      await ctx.db
        .query("invites")
        .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", a.botId))
        .collect()
    ).filter((i) => !i.usedBy && i.expiresAt > now);
    if (open.length >= MAX_INVITES_PER_BOT) {
      return fail("too_many_invites", "Zu viele offene Einladungen für diesen Scoop. Bitte alte zurückziehen.");
    }
    const shares = await ctx.db
      .query("shares")
      .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", a.botId))
      .collect();
    if (shares.length >= MAX_SHARES_PER_BOT) return fail("too_many_shares", "Dieser Scoop ist schon mit sehr vielen Personen geteilt.");
    if (!(await rateLimit(ctx, `invite:${user._id}`, INVITE_LIMIT.limit, INVITE_LIMIT.windowMs))) {
      return fail("rate_limited", "Zu viele Einladungen in kurzer Zeit. Bitte später erneut versuchen.");
    }
    const role = a.role ?? "write";
    const computer = a.computer ?? "none";
    const expiresAt = now + INVITE_TTL_MS;
    const inviteId = await ctx.db.insert("invites", {
      codeHash: a.codeHash,
      serverId: server._id,
      ownerId: user._id,
      botId: a.botId,
      botName,
      botMascot: cleanMascot(a.botMascot),
      role,
      computer,
      createdAt: now,
      expiresAt,
    });
    return { ok: true as const, inviteId: inviteId as string, expiresAt, role, computer };
  },
});

/** Personen und offene Einladungen eines Scoops (nur Admin). */
export const listForBot = query({
  args: { serverId: v.string(), botId: v.string() },
  handler: async (ctx, { serverId, botId }) => {
    const { user } = await viewer(ctx);
    const server = await ownedServer(ctx, user._id, serverId);
    if (!server) throw new ConvexError({ code: "forbidden", message: "Nur der Admin sieht die Personen dieses Scoops." });
    const now = Date.now();
    const shares = await ctx.db
      .query("shares")
      .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", botId))
      .collect();
    const members = [];
    for (const s of shares.sort((a, b) => a.createdAt - b.createdAt)) {
      const u = await ctx.db.get(s.granteeId);
      members.push({
        shareId: s._id,
        userId: s.granteeId,
        name: u?.name ?? null,
        role: s.role,
        computer: s.computer,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
      });
    }
    const invites = (
      await ctx.db
        .query("invites")
        .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", botId))
        .collect()
    )
      .filter((i) => !i.usedBy && i.expiresAt > now)
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((i) => ({ inviteId: i._id, role: i.role, computer: i.computer, createdAt: i.createdAt, expiresAt: i.expiresAt }));
    return { members, invites };
  },
});

/** Alle geteilten Scoops eines eigenen Servers (für Kennzeichen „geteilt“ in der Seitenleiste des Admins). */
export const listForServer = query({
  args: { serverId: v.string() },
  handler: async (ctx, { serverId }) => {
    const { user } = await viewer(ctx);
    const server = await ownedServer(ctx, user._id, serverId);
    if (!server) throw new ConvexError({ code: "forbidden", message: "Nur der Admin sieht die Shares dieses Servers." });
    const counts = new Map<string, number>();
    for (const s of await ctx.db
      .query("shares")
      .withIndex("by_server", (q) => q.eq("serverId", server._id))
      .collect()) {
      counts.set(s.botId, (counts.get(s.botId) ?? 0) + 1);
    }
    return [...counts.entries()].map(([botId, count]) => ({ botId, count }));
  },
});

export const update = mutation({
  args: { shareId: v.string(), role: v.optional(roleV), computer: v.optional(computerV) },
  handler: async (ctx, a) => {
    const { user } = await viewer(ctx);
    const share = await adminShare(ctx, user._id, a.shareId);
    if (!share) return fail("not_found", "Freigabe nicht gefunden.");
    const patch: Partial<Doc<"shares">> = {};
    if (a.role && a.role !== share.role) patch.role = a.role;
    if (a.computer && a.computer !== share.computer) patch.computer = a.computer;
    if (Object.keys(patch).length) {
      await ctx.db.patch(share._id, { ...patch, updatedAt: Date.now() });
      await bumpShares(ctx, share.serverId);
    }
    return { ok: true as const };
  },
});

export const remove = mutation({
  args: { shareId: v.string() },
  handler: async (ctx, { shareId }) => {
    const { user } = await viewer(ctx);
    const share = await adminShare(ctx, user._id, shareId);
    if (!share) return fail("not_found", "Freigabe nicht gefunden.");
    await ctx.db.delete(share._id);
    await bumpShares(ctx, share.serverId);
    return { ok: true as const };
  },
});

export const revokeInvite = mutation({
  args: { inviteId: v.string() },
  handler: async (ctx, { inviteId }) => {
    const { user } = await viewer(ctx);
    const id = ctx.db.normalizeId("invites", inviteId);
    const inv = id ? await ctx.db.get(id) : null;
    const server = inv ? await ctx.db.get(inv.serverId) : null;
    if (!inv || !server || server.ownerId !== user._id) return fail("not_found", "Einladung nicht gefunden.");
    await ctx.db.delete(inv._id);
    return { ok: true as const };
  },
});

// -- Gäste ----------------------------------------------------------------------------------

async function inviteByCode(ctx: QueryCtx, code: string): Promise<Doc<"invites"> | null> {
  const norm = normalizeInviteCode(code);
  if (norm.length < 16) return null;
  const hash = await sha256hex(norm);
  return ctx.db
    .query("invites")
    .withIndex("by_codeHash", (q) => q.eq("codeHash", hash))
    .unique();
}

/** Vorschau einer Einladung – ohne Anmeldung (Annahme-Blatt). Codes haben 128 Bit; geraten werden kann nichts. */
export const inviteInfo = query({
  args: { code: v.string() },
  handler: async (ctx, { code }) => {
    const inv = await inviteByCode(ctx, code);
    if (!inv) return { valid: false as const, reason: "unknown" };
    const server = await ctx.db.get(inv.serverId);
    if (!server) return { valid: false as const, reason: "unknown" };
    if (inv.usedBy) return { valid: false as const, reason: "used" };
    if (inv.expiresAt <= Date.now()) return { valid: false as const, reason: "expired" };
    const owner = await ctx.db.get(inv.ownerId);
    return {
      valid: true as const,
      botId: inv.botId,
      botName: inv.botName,
      botMascot: inv.botMascot ?? null,
      ownerName: owner?.name ?? null,
      serverName: server.name,
      role: inv.role,
      computer: inv.computer,
      expiresAt: inv.expiresAt,
    };
  },
});

/** Einladung annehmen. Wirft bei falschem Code nicht (sonst rollt Convex den Fehlversuchszähler zurück). */
export const accept = mutation({
  args: { code: v.string() },
  handler: async (ctx, { code }) => {
    const { user } = await viewer(ctx);
    const key = `accept:${user._id}`;
    if (!(await rateLimit(ctx, key, ACCEPT_FAILS.limit, ACCEPT_FAILS.windowMs, { count: false }))) {
      return fail("rate_limited", "Zu viele Fehlversuche. Bitte in ein paar Minuten erneut versuchen.");
    }
    const now = Date.now();
    const inv = await inviteByCode(ctx, code);
    const server = inv ? await ctx.db.get(inv.serverId) : null;
    if (!inv || !server) {
      await rateLimit(ctx, key, ACCEPT_FAILS.limit, ACCEPT_FAILS.windowMs);
      return fail("invalid_code", "Diese Einladung gibt es nicht (mehr).");
    }
    if (server.ownerId === user._id) return fail("own_scoop", "Das ist dein eigener Scoop.");
    const existing = await ctx.db
      .query("shares")
      .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", inv.botId))
      .filter((q) => q.eq(q.field("granteeId"), user._id))
      .first();
    if (inv.usedBy) {
      // Einmalig: Nur wer sie angenommen hat und noch Zugriff hat, bekommt „schon angenommen“ als Erfolg.
      // Wurde die Person inzwischen entfernt, bringt derselbe Link sie nicht zurück.
      if (inv.usedBy === user._id && existing) {
        return { ok: true as const, shareId: existing._id, serverId: server._id, botId: inv.botId, already: true };
      }
      return fail("used", "Diese Einladung wurde schon angenommen.");
    }
    if (inv.expiresAt <= now) return fail("expired", "Diese Einladung ist abgelaufen. Bitte um eine neue.");
    let shareId: Id<"shares">;
    if (existing) {
      shareId = existing._id;
      await ctx.db.patch(existing._id, { role: inv.role, computer: inv.computer, botName: inv.botName, updatedAt: now });
    } else {
      shareId = await ctx.db.insert("shares", {
        serverId: server._id,
        ownerId: server.ownerId,
        botId: inv.botId,
        botName: inv.botName,
        botMascot: inv.botMascot,
        granteeId: user._id,
        role: inv.role,
        computer: inv.computer,
        createdAt: now,
        updatedAt: now,
      });
    }
    await ctx.db.patch(inv._id, { usedBy: user._id, usedAt: now });
    await bumpShares(ctx, server._id);
    return { ok: true as const, shareId, serverId: server._id, botId: inv.botId, already: Boolean(existing) };
  },
});

/** „Mit mir geteilt“: geteilte Scoops inkl. Server-Adresse und Online-Status. */
export const mine = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await viewer(ctx);
    const now = Date.now();
    const rows = await ctx.db
      .query("shares")
      .withIndex("by_grantee", (q) => q.eq("granteeId", user._id))
      .collect();
    const out = [];
    for (const s of rows.sort((a, b) => a.createdAt - b.createdAt)) {
      const server = await ctx.db.get(s.serverId);
      if (!server) continue;
      const owner = await ctx.db.get(server.ownerId);
      out.push({
        shareId: s._id,
        serverId: server._id,
        botId: s.botId,
        botName: s.botName,
        botMascot: s.botMascot ?? null,
        role: s.role,
        computer: s.computer,
        ownerId: server.ownerId,
        ownerName: owner?.name ?? null,
        serverName: server.name,
        publicUrl: server.publicUrl,
        tailnetUrl: server.tailnetUrl ?? null,
        version: server.version,
        online: server.lastSeenAt > 0 && now - server.lastSeenAt < ONLINE_WINDOW_MS,
        lastSeenAt: server.lastSeenAt || null,
        createdAt: s.createdAt,
      });
    }
    return out;
  },
});

export const leave = mutation({
  args: { shareId: v.string() },
  handler: async (ctx, { shareId }) => {
    const { user } = await viewer(ctx);
    const id = ctx.db.normalizeId("shares", shareId);
    const share = id ? await ctx.db.get(id) : null;
    if (!share || share.granteeId !== user._id) return fail("not_found", "Freigabe nicht gefunden.");
    await ctx.db.delete(share._id);
    await bumpShares(ctx, share.serverId);
    return { ok: true as const };
  },
});

// -- Server (HTTP /shares/sync, Bearer serverSecret) ---------------------------------------

export const syncForServer = internalMutation({
  args: {
    secretHash: v.string(),
    bots: v.array(v.object({ botId: v.string(), name: v.string(), mascot: v.optional(v.any()) })),
    removeBots: v.array(v.string()),
  },
  handler: async (ctx, a) => {
    const server = await ctx.db
      .query("servers")
      .withIndex("by_secretHash", (q) => q.eq("secretHash", a.secretHash))
      .unique();
    if (!server) return null;
    let changed = false;
    for (const botId of a.removeBots.slice(0, 200)) {
      if ((await deleteSharesOfBot(ctx, server._id, botId)) > 0) changed = true;
    }
    // Name/Maskottchen aktuell halten (Liste „Mit mir geteilt“, Einladungs-Vorschau)
    for (const b of a.bots.slice(0, 500)) {
      const name = cleanName(b.name);
      if (!name) continue;
      const mascot = cleanMascot(b.mascot);
      for (const table of ["shares", "invites"] as const) {
        for (const row of await ctx.db
          .query(table)
          .withIndex("by_server_bot", (q) => q.eq("serverId", server._id).eq("botId", b.botId))
          .collect()) {
          if (row.botName !== name || (mascot && JSON.stringify(row.botMascot) !== JSON.stringify(mascot))) {
            await ctx.db.patch(row._id, { botName: name, ...(mascot ? { botMascot: mascot } : {}) });
          }
        }
      }
    }
    if (changed) await bumpShares(ctx, server._id);
    const fresh = (await ctx.db.get(server._id))!;
    const shares = [];
    for (const s of await ctx.db
      .query("shares")
      .withIndex("by_server", (q) => q.eq("serverId", server._id))
      .collect()) {
      const u = await ctx.db.get(s.granteeId);
      shares.push({
        shareId: s._id,
        botId: s.botId,
        granteeId: s.granteeId,
        granteeName: u?.name ?? null,
        role: s.role,
        computer: s.computer,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
      });
    }
    return { sharesVersion: fresh.sharesVersion ?? 0, shares };
  },
});

/** Cron: benutzte oder abgelaufene Einladungen nach einem Tag löschen. */
export const cleanupInvites = internalMutation({
  args: {},
  handler: async (ctx) => {
    const now = Date.now();
    const old = await ctx.db
      .query("invites")
      .withIndex("by_expiresAt", (q) => q.lt("expiresAt", now - 24 * 60 * 60 * 1000))
      .take(500);
    for (const i of old) await ctx.db.delete(i._id);
    for (const i of await ctx.db.query("invites").take(1000)) {
      if (i.usedAt && now - i.usedAt > 24 * 60 * 60 * 1000) await ctx.db.delete(i._id);
    }
  },
});
