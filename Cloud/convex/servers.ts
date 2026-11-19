// App-Funktionen für „Deine Server“ (mit Sitzungs-JWT).
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { normalizeCode } from "./lib/crypto";
import { deleteServer, ONLINE_WINDOW_MS, rateLimit, viewer } from "./lib/session";

const CLAIM_FAILS = 10; // Fehlversuche pro Nutzer …
const CLAIM_WINDOW_MS = 10 * 60 * 1000; // … in 10 Minuten

export const myServers = query({
  args: {},
  handler: async (ctx) => {
    const { user } = await viewer(ctx);
    const rows = await ctx.db
      .query("servers")
      .withIndex("by_owner", (q) => q.eq("ownerId", user._id))
      .collect();
    const now = Date.now();
    return rows
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((s) => ({
        id: s._id,
        name: s.name,
        publicUrl: s.publicUrl,
        tailnetUrl: s.tailnetUrl ?? null,
        version: s.version,
        lastSeenAt: s.lastSeenAt || null,
        online: s.lastSeenAt > 0 && now - s.lastSeenAt < ONLINE_WINDOW_MS,
        createdAt: s.createdAt,
      }));
  },
});

/** Code aus der App einlösen. Antwortet mit {ok: true, serverId, name} oder {ok: false, error, message}
 *  (kein Throw, damit der Fehlversuchszähler erhalten bleibt). */
export const claimServer = mutation({
  args: { code: v.string(), name: v.optional(v.string()) },
  handler: async (ctx, { code, name }) => {
    const { user } = await viewer(ctx);
    const key = `claim:${user._id}`;
    if (!(await rateLimit(ctx, key, CLAIM_FAILS, CLAIM_WINDOW_MS, { count: false }))) {
      return { ok: false as const, error: "rate_limited", message: "Zu viele Fehlversuche. Bitte in ein paar Minuten erneut versuchen." };
    }
    const now = Date.now();
    const norm = normalizeCode(code);
    const claim =
      norm.length === 8
        ? await ctx.db
            .query("serverClaims")
            .withIndex("by_code", (q) => q.eq("code", norm))
            .filter((q) => q.and(q.eq(q.field("status"), "pending"), q.gt(q.field("expiresAt"), now)))
            .first()
        : null;
    if (!claim) {
      await rateLimit(ctx, key, CLAIM_FAILS, CLAIM_WINDOW_MS);
      return { ok: false as const, error: "invalid_code", message: "Code ungültig oder abgelaufen." };
    }
    const serverName = (name ?? "").trim() || claim.name;
    const serverId = await ctx.db.insert("servers", {
      ownerId: user._id,
      name: serverName.slice(0, 80),
      publicUrl: claim.publicUrl,
      tailnetUrl: claim.tailnetUrl,
      version: claim.version,
      lastSeenAt: 0,
      createdAt: now,
    });
    await ctx.db.patch(claim._id, { status: "claimed", serverId, ownerId: user._id });
    return { ok: true as const, serverId, name: serverName };
  },
});

async function ownServer(ctx: Parameters<typeof viewer>[0], serverId: string) {
  const { user } = await viewer(ctx);
  const id = ctx.db.normalizeId("servers", serverId);
  const server = id ? await ctx.db.get(id) : null;
  if (!server || server.ownerId !== user._id) return null;
  return server;
}

export const renameServer = mutation({
  args: { serverId: v.string(), name: v.string() },
  handler: async (ctx, { serverId, name }) => {
    const server = await ownServer(ctx, serverId);
    const clean = name.trim().slice(0, 80);
    if (!server || !clean) return { ok: false as const };
    await ctx.db.patch(server._id, { name: clean });
    return { ok: true as const };
  },
});

/** Entfernt den Server aus dem Konto. Sein nächster Herzschlag bekommt 401 und er löst die Kopplung. */
export const removeServer = mutation({
  args: { serverId: v.string() },
  handler: async (ctx, { serverId }) => {
    const server = await ownServer(ctx, serverId);
    if (!server) return { ok: false as const };
    await deleteServer(ctx, server._id);
    return { ok: true as const };
  },
});
