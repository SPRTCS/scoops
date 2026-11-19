// Geteilte Scoops: gemeinsame Regeln und Aufräum-Helfer (docs/sharing.md).
import { v } from "convex/values";
import type { Doc, Id } from "../_generated/dataModel";
import type { MutationCtx, QueryCtx } from "../_generated/server";

export const roleV = v.union(v.literal("read"), v.literal("write"), v.literal("edit"));
export const computerV = v.union(v.literal("none"), v.literal("view"), v.literal("control"));
export type Role = "read" | "write" | "edit";
export type ComputerLevel = "none" | "view" | "control";

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 Tage, einmalig
export const MAX_INVITES_PER_BOT = 20; // offene Einladungen je Scoop
export const MAX_SHARES_PER_BOT = 50; // Personen je Scoop
export const INVITE_LIMIT = { limit: 30, windowMs: 60 * 60_000 }; // neue Einladungen je Admin und Stunde
export const ACCEPT_FAILS = { limit: 10, windowMs: 10 * 60_000 }; // Fehlversuche beim Annehmen je Nutzer
export const MAX_MASCOT_BYTES = 2048;

const BOT_ID = /^b_[A-Za-z0-9_-]{1,40}$/;

export function validBotId(id: string): boolean {
  return BOT_ID.test(id);
}

export function cleanName(name: string): string {
  return name.replace(/\s+/g, " ").trim().slice(0, 80);
}

/** Maskottchen nur als kleines Objekt (für die Liste), sonst weglassen. */
export function cleanMascot(m: unknown): Record<string, unknown> | undefined {
  if (!m || typeof m !== "object" || Array.isArray(m)) return undefined;
  const json = JSON.stringify(m);
  if (new TextEncoder().encode(json).length > MAX_MASCOT_BYTES) return undefined;
  return JSON.parse(json);
}

/** Einladungscode aus Link oder Eingabe: …/i/<code>, aisscoops://invite/<code> oder der Code selbst. */
export function normalizeInviteCode(input: string): string {
  const t = input.trim();
  const m = t.match(/(?:\/i\/|invite\/)([A-Za-z0-9_-]+)\s*$/);
  return (m ? m[1] : t).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 100);
}

/** Server-Cache ungültig machen: Der nächste Herzschlag meldet die neue Version, der Server lädt neu. */
export async function bumpShares(ctx: MutationCtx, serverId: Id<"servers">): Promise<void> {
  const s = await ctx.db.get(serverId);
  if (s) await ctx.db.patch(serverId, { sharesVersion: (s.sharesVersion ?? 0) + 1 });
}

/** Nur der Inhaber des Servers ist Admin seiner Scoops. */
export async function ownedServer(ctx: QueryCtx | MutationCtx, userId: Id<"users">, serverId: string) {
  const id = ctx.db.normalizeId("servers", serverId);
  const server = id ? await ctx.db.get(id) : null;
  return server && server.ownerId === userId ? server : null;
}

/** Share, den der Nutzer als Admin verwalten darf (Server gehört ihm). */
export async function adminShare(ctx: QueryCtx | MutationCtx, userId: Id<"users">, shareId: string) {
  const id = ctx.db.normalizeId("shares", shareId);
  const share = id ? await ctx.db.get(id) : null;
  if (!share) return null;
  const server = await ctx.db.get(share.serverId);
  return server && server.ownerId === userId ? share : null;
}

export async function deleteSharesOfServer(ctx: MutationCtx, serverId: Id<"servers">): Promise<void> {
  for (const s of await ctx.db
    .query("shares")
    .withIndex("by_server", (q) => q.eq("serverId", serverId))
    .collect()) {
    await ctx.db.delete(s._id);
  }
  for (const i of await ctx.db
    .query("invites")
    .withIndex("by_server", (q) => q.eq("serverId", serverId))
    .collect()) {
    await ctx.db.delete(i._id);
  }
}

/** Scoop auf dem Server gelöscht: Shares und Einladungen dieses Scoops entfernen. */
export async function deleteSharesOfBot(ctx: MutationCtx, serverId: Id<"servers">, botId: string): Promise<number> {
  let n = 0;
  for (const s of await ctx.db
    .query("shares")
    .withIndex("by_server_bot", (q) => q.eq("serverId", serverId).eq("botId", botId))
    .collect()) {
    await ctx.db.delete(s._id);
    n++;
  }
  for (const i of await ctx.db
    .query("invites")
    .withIndex("by_server_bot", (q) => q.eq("serverId", serverId).eq("botId", botId))
    .collect()) {
    await ctx.db.delete(i._id);
  }
  return n;
}

/** Konto gelöscht: alle Shares, in denen der Nutzer Gast ist (Admin-Seite räumt deleteServer auf). */
export async function deleteSharesOfUser(ctx: MutationCtx, userId: Id<"users">): Promise<void> {
  const touched = new Set<Id<"servers">>();
  for (const s of await ctx.db
    .query("shares")
    .withIndex("by_grantee", (q) => q.eq("granteeId", userId))
    .collect()) {
    await ctx.db.delete(s._id);
    touched.add(s.serverId);
  }
  for (const s of await ctx.db
    .query("shares")
    .withIndex("by_owner", (q) => q.eq("ownerId", userId))
    .collect()) {
    await ctx.db.delete(s._id);
  }
  for (const i of await ctx.db
    .query("invites")
    .withIndex("by_owner", (q) => q.eq("ownerId", userId))
    .collect()) {
    await ctx.db.delete(i._id);
  }
  for (const id of touched) await bumpShares(ctx, id);
}

/** Gäste mit Share auf diesem Server (für Push-Relay und widerrufene Sitzungen). */
export async function granteesOf(ctx: QueryCtx | MutationCtx, serverId: Id<"servers">): Promise<Set<Id<"users">>> {
  const rows: Doc<"shares">[] = await ctx.db
    .query("shares")
    .withIndex("by_server", (q) => q.eq("serverId", serverId))
    .collect();
  return new Set(rows.map((r) => r.granteeId));
}
