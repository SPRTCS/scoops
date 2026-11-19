// Tests für geteilte Scoops (convex/shares.ts, /shares/sync, Herzschlag, Push-Relay für Gäste).
// Rechtefälle: Admin = Inhaber des Servers; Gäste nur eigene Shares; Fremde nichts.
import { convexTest } from "convex-test";
import { exportPKCS8, generateKeyPair } from "jose";
import { EventEmitter } from "node:events";
import { beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import schema from "../convex/schema";
import { sha256hex } from "../convex/lib/crypto";

const apns = vi.hoisted(() => ({ calls: [] as { headers: Record<string, string> }[] }));

vi.mock("node:http2", () => {
  function connect() {
    const session = new EventEmitter() as EventEmitter & Record<string, unknown>;
    session.closed = false;
    session.destroyed = false;
    session.close = () => {
      session.closed = true;
    };
    session.request = (headers: Record<string, string>) => {
      const stream = new EventEmitter() as EventEmitter & Record<string, unknown>;
      stream.close = () => {};
      stream.end = () => {
        apns.calls.push({ headers });
        setTimeout(() => {
          stream.emit("response", { ":status": 200, "apns-id": "id-1" });
          stream.emit("end");
        }, 0);
      };
      return stream;
    };
    return session;
  }
  const mod = { connect, constants: { NGHTTP2_CANCEL: 8 } };
  return { default: mod, ...mod };
});

const modules = import.meta.glob("../convex/**/*.*s");
const SITE = "https://test-site.example.convex.site";
const GUEST_TOKEN = "e".repeat(64);

beforeAll(async () => {
  process.env.CONVEX_SITE_URL = SITE;
  const kp = await generateKeyPair("ES256", { extractable: true });
  process.env.APNS_KEY_P8 = await exportPKCS8(kp.privateKey);
  process.env.APNS_KEY_ID = "TESTKEY123";
  process.env.APNS_TEAM_ID = "MYXQKK3T2Z";
});

beforeEach(() => {
  apns.calls.length = 0;
});

function setup() {
  return convexTest(schema, modules);
}
type T = ReturnType<typeof setup>;

type Person = { userId: string; sessionId: string };

async function person(t: T, name: string): Promise<Person> {
  return t.run(async (ctx) => {
    const now = Date.now();
    const userId = await ctx.db.insert("users", { appleSub: `sub-${name}`, name, createdAt: now, lastLoginAt: now });
    const sessionId = await ctx.db.insert("sessions", {
      userId, deviceName: "iPhone", platform: "ios", createdAt: now, lastUsedAt: now,
    });
    return { userId, sessionId };
  });
}

async function server(t: T, owner: Person, name = "Armans Air") {
  const secret = "secret-" + name + "-" + Math.random();
  const secretHash = await sha256hex(secret);
  const serverId = await t.run(async (ctx) => {
    const now = Date.now();
    return ctx.db.insert("servers", {
      ownerId: owner.userId as any, name, publicUrl: "https://air.example.ts.net", version: "1.14.0",
      lastSeenAt: now, secretHash, createdAt: now,
    });
  });
  return { serverId: serverId as string, secret };
}

function as(t: T, p: Person) {
  return t.withIdentity({ subject: p.userId, issuer: SITE, sid: p.sessionId } as any);
}

async function post(t: T, path: string, body: unknown, secret?: string) {
  const res = await t.fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(secret ? { authorization: `Bearer ${secret}` } : {}) },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as any };
}

/** Admin mit Server und Scoop, Einladung → Gast nimmt an. */
async function shared(t: T, opts: { role?: "read" | "write" | "edit"; computer?: "none" | "view" | "control" } = {}) {
  const admin = await person(t, "Arman");
  const guest = await person(t, "Lea");
  const srv = await server(t, admin);
  const inv = await as(t, admin).action(api.shares.createInvite, {
    serverId: srv.serverId, botId: "b_0123456789", botName: "Mila", botMascot: { shape: "bean", color: "#FF8FB1" },
    ...opts,
  });
  expect(inv.ok).toBe(true);
  const acc = await as(t, guest).mutation(api.shares.accept, { code: (inv as any).code });
  expect(acc).toMatchObject({ ok: true, botId: "b_0123456789", already: false });
  return { admin, guest, srv, inv: inv as any, shareId: (acc as any).shareId as string };
}

async function version(t: T, serverId: string): Promise<number> {
  return t.run(async (ctx) => ((await ctx.db.get(serverId as any)) as any).sharesVersion ?? 0);
}

describe("Einladen", () => {
  test("Admin legt Einladung an: Code nur gehasht gespeichert, Link + App-Link, 7 Tage gültig, Standard write/none", async () => {
    const t = setup();
    const admin = await person(t, "Arman");
    const srv = await server(t, admin);
    const before = Date.now();
    const inv: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: " Mila " });
    expect(inv).toMatchObject({ ok: true, role: "write", computer: "none" });
    expect(inv.code).toMatch(/^[A-Za-z0-9_-]{22}$/);
    expect(inv.url).toBe(`${SITE}/i/${inv.code}`);
    expect(inv.appUrl).toBe(`aisscoops://invite/${inv.code}`);
    expect(inv.expiresAt - before).toBeGreaterThanOrEqual(7 * 86400_000 - 1000);
    const rows = await t.run((ctx) => ctx.db.query("invites").collect());
    expect(rows).toHaveLength(1);
    expect(rows[0].codeHash).toBe(await sha256hex(inv.code));
    expect(JSON.stringify(rows)).not.toContain(inv.code);
    expect(rows[0].botName).toBe("Mila");
  });

  test("nur der Inhaber des Servers darf einladen; ohne Anmeldung wirft es", async () => {
    const t = setup();
    const admin = await person(t, "Arman");
    const other = await person(t, "Fremd");
    const srv = await server(t, admin);
    const r: any = await as(t, other).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    expect(r).toMatchObject({ ok: false, error: "not_owner" });
    await expect(t.action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" })).rejects.toThrow(/unauthenticated|Nicht angemeldet/);
    const bad: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "../evil", botName: "Mila" });
    expect(bad).toMatchObject({ ok: false, error: "bad_request" });
    expect(await t.run((ctx) => ctx.db.query("invites").collect())).toHaveLength(0);
  });

  test("Grenzen: 20 offene Einladungen je Scoop, 30 neue je Stunde", async () => {
    const t = setup();
    const admin = await person(t, "Arman");
    const srv = await server(t, admin);
    for (let i = 0; i < 20; i++) {
      expect((await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_aaaaaaaaaa", botName: "A" })).ok).toBe(true);
    }
    const r: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_aaaaaaaaaa", botName: "A" });
    expect(r.error).toBe("too_many_invites");
    for (let i = 0; i < 10; i++) {
      expect((await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_bbbbbbbbbb", botName: "B" })).ok).toBe(true);
    }
    const limited: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_cccccccccc", botName: "C" });
    expect(limited.error).toBe("rate_limited");
  });

  test("inviteInfo ohne Anmeldung: Vorschau; unbekannt, benutzt, abgelaufen", async () => {
    vi.useFakeTimers();
    try {
      const t = setup();
      const admin = await person(t, "Arman");
      const guest = await person(t, "Lea");
      const srv = await server(t, admin);
      const inv: any = await as(t, admin).action(api.shares.createInvite, {
        serverId: srv.serverId, botId: "b_0123456789", botName: "Mila", role: "read", computer: "view", botMascot: { color: "#fff" },
      });
      const info = await t.query(api.shares.inviteInfo, { code: inv.url }); // ganzer Link wird verstanden
      expect(info).toMatchObject({ valid: true, botName: "Mila", ownerName: "Arman", serverName: "Armans Air", role: "read", computer: "view", botMascot: { color: "#fff" } });
      expect(await t.query(api.shares.inviteInfo, { code: "x".repeat(22) })).toMatchObject({ valid: false, reason: "unknown" });
      await as(t, guest).mutation(api.shares.accept, { code: inv.appUrl });
      expect(await t.query(api.shares.inviteInfo, { code: inv.code })).toMatchObject({ valid: false, reason: "used" });
      const inv2: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
      vi.advanceTimersByTime(7 * 86400_000 + 1000);
      expect(await t.query(api.shares.inviteInfo, { code: inv2.code })).toMatchObject({ valid: false, reason: "expired" });
      const late: any = await as(t, await person(t, "Spät")).mutation(api.shares.accept, { code: inv2.code });
      expect(late).toMatchObject({ ok: false, error: "expired" });
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("Annehmen", () => {
  test("Gast nimmt an: Share mit Rolle und Rechner-Stufe, sharesVersion steigt; erscheint in mine", async () => {
    const t = setup();
    const { guest, srv, shareId } = await shared(t, { role: "edit", computer: "control" });
    expect(await version(t, srv.serverId)).toBe(1);
    const mine = await as(t, guest).query(api.shares.mine, {});
    expect(mine).toHaveLength(1);
    expect(mine[0]).toMatchObject({
      shareId, serverId: srv.serverId, botId: "b_0123456789", botName: "Mila", role: "edit", computer: "control",
      ownerName: "Arman", serverName: "Armans Air", publicUrl: "https://air.example.ts.net", online: true,
    });
  });

  test("einmalig: ein zweiter Gast bekommt „used“; derselbe Gast „already“; nach Entfernen bringt der Link nichts zurück", async () => {
    const t = setup();
    const { admin, guest, inv, shareId } = await shared(t);
    const second = await person(t, "Zweit");
    expect(await as(t, second).mutation(api.shares.accept, { code: inv.code })).toMatchObject({ ok: false, error: "used" });
    expect(await as(t, guest).mutation(api.shares.accept, { code: inv.code })).toMatchObject({ ok: true, already: true, shareId });
    expect(await as(t, admin).mutation(api.shares.remove, { shareId })).toEqual({ ok: true });
    expect(await as(t, guest).mutation(api.shares.accept, { code: inv.code })).toMatchObject({ ok: false, error: "used" });
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(0);
  });

  test("eigener Scoop kann nicht angenommen werden", async () => {
    const t = setup();
    const admin = await person(t, "Arman");
    const srv = await server(t, admin);
    const inv: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    expect(await as(t, admin).mutation(api.shares.accept, { code: inv.code })).toMatchObject({ ok: false, error: "own_scoop" });
  });

  test("zweite Einladung an denselben Gast aktualisiert den Share statt ihn zu verdoppeln", async () => {
    const t = setup();
    const { admin, guest, srv, shareId } = await shared(t, { role: "read" });
    const inv2: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila", role: "edit" });
    expect(await as(t, guest).mutation(api.shares.accept, { code: inv2.code })).toMatchObject({ ok: true, already: true, shareId });
    const mine = await as(t, guest).query(api.shares.mine, {});
    expect(mine.map((m: any) => m.role)).toEqual(["edit"]);
  });

  test("Rate-Limit: nach 10 falschen Codes in 10 Minuten gesperrt (auch für richtige)", async () => {
    const t = setup();
    const admin = await person(t, "Arman");
    const guest = await person(t, "Lea");
    const srv = await server(t, admin);
    const inv: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    for (let i = 0; i < 10; i++) {
      expect(await as(t, guest).mutation(api.shares.accept, { code: "falsch" + "x".repeat(20) + i })).toMatchObject({ error: "invalid_code" });
    }
    expect(await as(t, guest).mutation(api.shares.accept, { code: inv.code })).toMatchObject({ ok: false, error: "rate_limited" });
  });
});

describe("Verwalten: nur Admin, Gäste nur eigene Shares", () => {
  test("listForBot: Admin sieht Personen und offene Einladungen (ohne Codes); Gast und Fremde nicht", async () => {
    const t = setup();
    const { admin, guest, srv, shareId } = await shared(t, { role: "read", computer: "view" });
    await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    const list = await as(t, admin).query(api.shares.listForBot, { serverId: srv.serverId, botId: "b_0123456789" });
    expect(list.members).toEqual([expect.objectContaining({ shareId, userId: guest.userId, name: "Lea", role: "read", computer: "view" })]);
    expect(list.invites).toHaveLength(1);
    expect(JSON.stringify(list)).not.toMatch(/code/i);
    await expect(as(t, guest).query(api.shares.listForBot, { serverId: srv.serverId, botId: "b_0123456789" })).rejects.toThrow(/forbidden|Admin/);
    const other = await person(t, "Fremd");
    await expect(as(t, other).query(api.shares.listForBot, { serverId: srv.serverId, botId: "b_0123456789" })).rejects.toThrow(/forbidden|Admin/);
    expect(await as(t, admin).query(api.shares.listForServer, { serverId: srv.serverId })).toEqual([{ botId: "b_0123456789", count: 1 }]);
    await expect(as(t, guest).query(api.shares.listForServer, { serverId: srv.serverId })).rejects.toThrow(/forbidden|Admin/);
  });

  test("update/remove/revokeInvite: Gast und Fremde scheitern, Admin darf; Version steigt bei jeder Änderung", async () => {
    const t = setup();
    const { admin, guest, srv, shareId } = await shared(t);
    const other = await person(t, "Fremd");
    for (const p of [guest, other]) {
      expect(await as(t, p).mutation(api.shares.update, { shareId, role: "edit", computer: "control" })).toMatchObject({ ok: false });
      expect(await as(t, p).mutation(api.shares.remove, { shareId })).toMatchObject({ ok: false });
    }
    expect((await as(t, guest).query(api.shares.mine, {}))[0]).toMatchObject({ role: "write", computer: "none" });
    const v0 = await version(t, srv.serverId);
    expect(await as(t, admin).mutation(api.shares.update, { shareId, role: "read", computer: "view" })).toEqual({ ok: true });
    expect(await version(t, srv.serverId)).toBe(v0 + 1);
    expect((await as(t, guest).query(api.shares.mine, {}))[0]).toMatchObject({ role: "read", computer: "view" });
    const inv: any = await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    expect(await as(t, guest).mutation(api.shares.revokeInvite, { inviteId: inv.inviteId })).toMatchObject({ ok: false });
    expect(await as(t, other).mutation(api.shares.revokeInvite, { inviteId: inv.inviteId })).toMatchObject({ ok: false });
    expect(await as(t, admin).mutation(api.shares.revokeInvite, { inviteId: inv.inviteId })).toEqual({ ok: true });
    expect(await t.query(api.shares.inviteInfo, { code: inv.code })).toMatchObject({ valid: false });
    expect(await as(t, admin).mutation(api.shares.remove, { shareId })).toEqual({ ok: true });
    expect(await version(t, srv.serverId)).toBe(v0 + 2);
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(0);
  });

  test("leave: Gast kann selbst austreten, aber nicht für andere", async () => {
    const t = setup();
    const { admin, guest, shareId } = await shared(t);
    const other = await person(t, "Fremd");
    expect(await as(t, other).mutation(api.shares.leave, { shareId })).toMatchObject({ ok: false });
    expect(await as(t, admin).mutation(api.shares.leave, { shareId })).toMatchObject({ ok: false }); // Admin entfernt mit remove
    expect(await as(t, guest).mutation(api.shares.leave, { shareId })).toEqual({ ok: true });
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(0);
  });

  test("Server übernommen (anderer Inhaber): früherer Admin verliert die Verwaltungsrechte", async () => {
    const t = setup();
    const { admin, srv, shareId } = await shared(t);
    const neu = await person(t, "Neu");
    await t.run(async (ctx) => ctx.db.patch(srv.serverId as any, { ownerId: neu.userId as any }));
    expect(await as(t, admin).mutation(api.shares.remove, { shareId })).toMatchObject({ ok: false });
    expect(await as(t, neu).mutation(api.shares.remove, { shareId })).toEqual({ ok: true });
  });

  test("ohne Anmeldung werfen alle Funktionen außer inviteInfo", async () => {
    const t = setup();
    await expect(t.query(api.shares.mine, {})).rejects.toThrow(/unauthenticated|Nicht angemeldet/);
    await expect(t.mutation(api.shares.accept, { code: "x".repeat(22) })).rejects.toThrow(/unauthenticated|Nicht angemeldet/);
    await expect(t.mutation(api.shares.leave, { shareId: "x" })).rejects.toThrow(/unauthenticated|Nicht angemeldet/);
    await expect(t.query(api.shares.listForBot, { serverId: "x", botId: "b_1" })).rejects.toThrow(/unauthenticated|Nicht angemeldet/);
  });
});

describe("Server-Seite", () => {
  test("/shares/sync: nur mit serverSecret; Shares mit Namen; Namen aktualisieren; gelöschter Scoop entfernt Shares", async () => {
    const t = setup();
    const { guest, srv } = await shared(t, { role: "read", computer: "view" });
    expect((await post(t, "/shares/sync", {})).status).toBe(401);
    expect((await post(t, "/shares/sync", {}, "falsch")).status).toBe(401);
    const r = await post(t, "/shares/sync", {}, srv.secret);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ ok: true, sharesVersion: 1 });
    expect(r.body.shares).toEqual([expect.objectContaining({ botId: "b_0123456789", granteeId: guest.userId, granteeName: "Lea", role: "read", computer: "view" })]);
    // anderer Server sieht diese Shares nicht
    const otherSrv = await server(t, await person(t, "Fremd"), "Fremder Mac");
    expect((await post(t, "/shares/sync", {}, otherSrv.secret)).body.shares).toEqual([]);
    // Name/Maskottchen aktualisieren
    await post(t, "/shares/sync", { bots: [{ botId: "b_0123456789", name: "Mila Neu", mascot: { color: "#000" } }] }, srv.secret);
    expect((await as(t, guest).query(api.shares.mine, {}))[0]).toMatchObject({ botName: "Mila Neu", botMascot: { color: "#000" } });
    // fremder Server kann keine Scoops anderer Server entfernen
    await post(t, "/shares/sync", { removeBots: ["b_0123456789"] }, otherSrv.secret);
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(1);
    const gone = await post(t, "/shares/sync", { removeBots: ["b_0123456789"] }, srv.secret);
    expect(gone.body).toMatchObject({ sharesVersion: 2, shares: [] });
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(0);
  });

  test("Herzschlag meldet sharesVersion und abgemeldete Sitzungen der Gäste", async () => {
    const t = setup();
    const { guest, srv } = await shared(t);
    await t.run(async (ctx) => ctx.db.patch(guest.sessionId as any, { revokedAt: Date.now() }));
    const stranger = await person(t, "Fremd");
    await t.run(async (ctx) => ctx.db.patch(stranger.sessionId as any, { revokedAt: Date.now() }));
    const hb = await post(t, "/servers/heartbeat", {}, srv.secret);
    expect(hb.body).toMatchObject({ ok: true, sharesVersion: 1 });
    expect(hb.body.revokedSessions).toContain(guest.sessionId);
    expect(hb.body.revokedSessions).not.toContain(stranger.sessionId);
  });

  test("Server entfernen räumt Shares und Einladungen auf", async () => {
    const t = setup();
    const { admin, guest, srv } = await shared(t);
    await as(t, admin).action(api.shares.createInvite, { serverId: srv.serverId, botId: "b_0123456789", botName: "Mila" });
    expect(await as(t, admin).mutation(api.servers.removeServer, { serverId: srv.serverId })).toEqual({ ok: true });
    expect(await as(t, guest).query(api.shares.mine, {})).toHaveLength(0);
    expect(await t.run((ctx) => ctx.db.query("invites").collect())).toHaveLength(0);
  });

  test("Konto löschen: als Gast verschwinden seine Shares (Version steigt), als Admin alle Shares seiner Server", async () => {
    const t = setup();
    const a = await shared(t);
    await as(t, a.guest).mutation(api.users.deleteAccount, {});
    expect(await t.run((ctx) => ctx.db.query("shares").collect())).toHaveLength(0);
    expect(await version(t, a.srv.serverId)).toBe(2);
    const b = await shared(t);
    await as(t, b.admin).mutation(api.users.deleteAccount, {});
    expect(await t.run((ctx) => ctx.db.query("shares").collect())).toHaveLength(0);
    const left = await t.run((ctx) => ctx.db.query("invites").collect());
    expect(left.filter((i) => i.serverId === (b.srv.serverId as any))).toHaveLength(0);
    expect(await as(t, b.guest).query(api.shares.mine, {})).toHaveLength(0);
  });

  test("Einladungslink /i/<code> öffnet die App", async () => {
    const t = setup();
    const res = await t.fetch("/i/abcDEF_123-xyz", { method: "GET" });
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("aisscoops://invite/abcDEF_123-xyz");
    expect((await t.fetch("/i/<script>", { method: "GET" })).status).toBe(200);
    expect(await (await t.fetch("/i/%3Cscript%3E", { method: "GET" })).text()).not.toContain("<script>alert");
  });
});

describe("Push-Relay für Gäste", () => {
  const alert = (token: string) => ({ token, pushType: "alert", priority: "10", payload: { aps: { alert: { title: "Mila", body: "Hallo" } } } });

  test("Server meldet Gast-Gerät nur mit Share; Versand nur, solange der Share besteht", async () => {
    const t = setup();
    const { admin, guest, srv, shareId } = await shared(t);
    const stranger = await person(t, "Fremd");
    const reg = await post(t, "/push/register", { tokens: [
      { token: GUEST_TOKEN, platform: "ios", userId: guest.userId },
      { token: "f".repeat(64), platform: "ios", userId: stranger.userId },
    ] }, srv.secret);
    expect(reg.body).toMatchObject({ ok: true, registered: 1, rejected: [{ token: "f".repeat(64), reason: "NotShared" }] });
    const row = await t.run((ctx) => ctx.db.query("pushTokens").collect());
    expect(row).toEqual([expect.objectContaining({ ownerId: guest.userId, token: GUEST_TOKEN })]);
    const sent = await post(t, "/push/send", { pushes: [alert(GUEST_TOKEN)] }, srv.secret);
    expect(sent.body.results[0]).toMatchObject({ status: 200 });
    expect(apns.calls).toHaveLength(1);
    // anderer Server ohne Share auf diesen Gast darf nicht
    const otherSrv = await server(t, stranger, "Fremder Mac");
    const blocked = await post(t, "/push/send", { pushes: [alert(GUEST_TOKEN)] }, otherSrv.secret);
    expect(blocked.body.results[0]).toMatchObject({ status: 403, reason: "UnknownToken" });
    // Share entfernt → kein Versand mehr
    await as(t, admin).mutation(api.shares.remove, { shareId });
    const after = await post(t, "/push/send", { pushes: [alert(GUEST_TOKEN)] }, srv.secret);
    expect(after.body.results[0]).toMatchObject({ status: 403, reason: "UnknownToken" });
    expect(apns.calls).toHaveLength(1);
  });

  test("Gast-Gerät: gelernte Umgebung landet beim Gast-Eintrag", async () => {
    const t = setup();
    const { guest, srv } = await shared(t);
    await post(t, "/push/register", { tokens: [{ token: GUEST_TOKEN, platform: "ios", userId: guest.userId }] }, srv.secret);
    await post(t, "/push/send", { pushes: [alert(GUEST_TOKEN)] }, srv.secret);
    const rows = await t.run((ctx) => ctx.db.query("pushTokens").collect());
    expect(rows[0]).toMatchObject({ ownerId: guest.userId, env: "production" });
    void internal;
  });
});
