// Angemeldete Geräte (Sitzungen): anzeigen und abmelden.
import { v } from "convex/values";
import { mutation, query } from "./_generated/server";
import { viewer } from "./lib/session";

export const mySessions = query({
  args: {},
  handler: async (ctx) => {
    const { user, session } = await viewer(ctx);
    const rows = await ctx.db
      .query("sessions")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect();
    return rows
      .filter((s) => s.revokedAt === undefined)
      .sort((a, b) => b.lastUsedAt - a.lastUsedAt)
      .map((s) => ({
        id: s._id,
        deviceName: s.deviceName,
        platform: s.platform,
        createdAt: s.createdAt,
        lastUsedAt: s.lastUsedAt,
        current: s._id === session._id,
      }));
  },
});

/** Meldet ein Gerät ab (auch das eigene = Abmelden). Ohne sessionId: aktuelle Sitzung. */
export const revokeSession = mutation({
  args: { sessionId: v.optional(v.string()) },
  handler: async (ctx, { sessionId }) => {
    const { user, session } = await viewer(ctx);
    const id = sessionId ? ctx.db.normalizeId("sessions", sessionId) : session._id;
    const target = id ? await ctx.db.get(id) : null;
    if (!target || target.userId !== user._id) return { ok: false as const };
    if (target.revokedAt === undefined) {
      await ctx.db.patch(target._id, { revokedAt: Date.now(), refreshHash: undefined });
    }
    return { ok: true as const };
  },
});
