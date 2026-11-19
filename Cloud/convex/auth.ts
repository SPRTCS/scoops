// Interne Mutations für Anmeldung und Erneuern (aufgerufen aus den HTTP-Actions in http.ts).
import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import { rateLimit } from "./lib/session";

export const REFRESH_IDLE_MS = 180 * 24 * 60 * 60 * 1000; // Sitzung verfällt nach 180 Tagen ohne Nutzung

export const signIn = internalMutation({
  args: {
    appleSub: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    deviceName: v.string(),
    platform: v.string(),
    refreshHash: v.string(),
  },
  handler: async (ctx, a) => {
    const now = Date.now();
    let user = await ctx.db
      .query("users")
      .withIndex("by_appleSub", (q) => q.eq("appleSub", a.appleSub))
      .unique();
    if (!user) {
      const id = await ctx.db.insert("users", {
        appleSub: a.appleSub,
        email: a.email,
        name: a.name,
        createdAt: now,
        lastLoginAt: now,
      });
      user = (await ctx.db.get(id))!;
    } else {
      // Apple liefert Name/E-Mail nur beim ersten Mal; Vorhandenes nie mit leeren Werten überschreiben.
      await ctx.db.patch(user._id, {
        lastLoginAt: now,
        ...(a.email ? { email: a.email } : {}),
        ...(a.name && !user.name ? { name: a.name } : {}),
      });
      user = (await ctx.db.get(user._id))!;
    }
    const sessionId = await ctx.db.insert("sessions", {
      userId: user._id,
      deviceName: a.deviceName,
      platform: a.platform,
      refreshHash: a.refreshHash,
      createdAt: now,
      lastUsedAt: now,
    });
    return { userId: user._id, sessionId, user: { id: user._id, name: user.name ?? null, email: user.email ?? null } };
  },
});

export const refresh = internalMutation({
  args: { refreshHash: v.string() },
  handler: async (ctx, { refreshHash }) => {
    const s = await ctx.db
      .query("sessions")
      .withIndex("by_refreshHash", (q) => q.eq("refreshHash", refreshHash))
      .unique();
    const now = Date.now();
    if (!s || s.revokedAt !== undefined || now - s.lastUsedAt > REFRESH_IDLE_MS) return null;
    const user = await ctx.db.get(s.userId);
    if (!user) return null;
    await ctx.db.patch(s._id, { lastUsedAt: now });
    return { userId: user._id, sessionId: s._id, user: { id: user._id, name: user.name ?? null, email: user.email ?? null } };
  },
});

/** Grobe Bremse gegen Missbrauch der öffentlichen Endpunkte (pro IP und Zeitfenster). */
export const allow = internalMutation({
  args: { key: v.string(), limit: v.number(), windowMs: v.number() },
  handler: async (ctx, a) => rateLimit(ctx, a.key, a.limit, a.windowMs),
});
