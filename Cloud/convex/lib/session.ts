// Zugriff aus Queries/Mutations: angemeldeter Nutzer + nicht widerrufene Sitzung.
import { ConvexError } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { deleteSharesOfServer } from "./shares";

export type Viewer = { user: Doc<"users">; session: Doc<"sessions"> };

export async function viewer(ctx: QueryCtx | MutationCtx): Promise<Viewer> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) throw new ConvexError({ code: "unauthenticated", message: "Nicht angemeldet" });
  const userId = ctx.db.normalizeId("users", identity.subject);
  const sid = typeof identity.sid === "string" ? ctx.db.normalizeId("sessions", identity.sid) : null;
  const user = userId ? await ctx.db.get(userId) : null;
  const session = sid ? await ctx.db.get(sid) : null;
  if (!user || !session || session.userId !== user._id || session.revokedAt !== undefined) {
    throw new ConvexError({ code: "unauthenticated", message: "Sitzung abgelaufen oder abgemeldet" });
  }
  return { user, session };
}

/** Fester Zeitfenster-Zähler. `count: false` prüft nur, ohne zu zählen. */
export async function rateLimit(
  ctx: MutationCtx,
  key: string,
  limit: number,
  windowMs: number,
  opts: { count: boolean; amount?: number } = { count: true },
): Promise<boolean> {
  const amount = opts.amount ?? 1;
  const now = Date.now();
  const row = await ctx.db
    .query("rateLimits")
    .withIndex("by_key", (q) => q.eq("key", key))
    .unique();
  const fresh = !row || now - row.windowStart >= windowMs;
  const current = fresh ? 0 : row.count;
  if (current + amount > limit) return false;
  if (opts.count) {
    if (!row) await ctx.db.insert("rateLimits", { key, windowStart: now, count: amount });
    else await ctx.db.patch(row._id, fresh ? { windowStart: now, count: amount } : { count: current + amount });
  }
  return true;
}

export async function deleteServer(ctx: MutationCtx, serverId: Id<"servers">): Promise<void> {
  await deleteSharesOfServer(ctx, serverId); // Gäste verlieren den Zugriff, Einladungen verfallen
  for (const c of await ctx.db
    .query("serverClaims")
    .withIndex("by_server", (q) => q.eq("serverId", serverId))
    .collect()) {
    await ctx.db.delete(c._id);
  }
  await ctx.db.delete(serverId);
}

export const ONLINE_WINDOW_MS = 3 * 60 * 1000;
export const REVOKED_KEEP_MS = 31 * 24 * 60 * 60 * 1000; // länger als ein JWT lebt
