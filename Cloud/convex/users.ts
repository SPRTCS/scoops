// Konto in der App: Profil und Konto löschen.
import { mutation, query } from "./_generated/server";
import { deleteServer, viewer } from "./lib/session";
import { deletePushTokensOf } from "./push";
import { deleteSharesOfUser } from "./lib/shares";

export const me = query({
  args: {},
  handler: async (ctx) => {
    const { user, session } = await viewer(ctx);
    return {
      id: user._id,
      name: user.name ?? null,
      email: user.email ?? null,
      createdAt: user.createdAt,
      sessionId: session._id,
    };
  },
});

/** Konto vollständig löschen (App-Store-Pflicht): Nutzer, Sitzungen, Server (samt deren Shares/Einladungen),
 *  Kopplungen, Push-Tokens und alle Shares, in denen der Nutzer Gast ist. */
export const deleteAccount = mutation({
  args: {},
  handler: async (ctx) => {
    const { user } = await viewer(ctx);
    for (const s of await ctx.db
      .query("servers")
      .withIndex("by_owner", (q) => q.eq("ownerId", user._id))
      .collect()) {
      await deleteServer(ctx, s._id);
    }
    for (const s of await ctx.db
      .query("sessions")
      .withIndex("by_user", (q) => q.eq("userId", user._id))
      .collect()) {
      await ctx.db.delete(s._id);
    }
    await deleteSharesOfUser(ctx, user._id);
    await deletePushTokensOf(ctx, user._id);
    for (const key of [`invite:${user._id}`, `accept:${user._id}`]) {
      const r = await ctx.db
        .query("rateLimits")
        .withIndex("by_key", (q) => q.eq("key", key))
        .unique();
      if (r) await ctx.db.delete(r._id);
    }
    const rl = await ctx.db
      .query("rateLimits")
      .withIndex("by_key", (q) => q.eq("key", `claim:${user._id}`))
      .unique();
    if (rl) await ctx.db.delete(rl._id);
    await ctx.db.delete(user._id);
    return { ok: true as const };
  },
});
