// Tests für das Push-Relay (/push/*). APNs wird über einen Mock von node:http2 gespielt;
// das JWT (ES256) wird gegen den öffentlichen Testschlüssel geprüft.
import { convexTest } from "convex-test";
import { exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import { EventEmitter } from "node:events";
import { beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { internal } from "../convex/_generated/api";
import schema from "../convex/schema";
import { sha256hex } from "../convex/lib/crypto";

type Call = { origin: string; headers: Record<string, string>; body: string };
type Reply = { status: number; headers?: Record<string, string>; body?: unknown };
const apns = vi.hoisted(() => ({
  calls: [] as Call[],
  handler: (_c: Call): Reply => ({ status: 200 }),
}));

vi.mock("node:http2", () => {
  function connect(origin: string) {
    const session = new EventEmitter() as EventEmitter & Record<string, unknown>;
    session.closed = false;
    session.destroyed = false;
    session.close = () => {
      session.closed = true;
    };
    session.request = (headers: Record<string, string>) => {
      const stream = new EventEmitter() as EventEmitter & Record<string, unknown>;
      stream.close = () => {};
      stream.end = (body?: string) => {
        const call = { origin, headers, body: body ?? "" };
        apns.calls.push(call);
        const r = apns.handler(call);
        setTimeout(() => {
          stream.emit("response", { ":status": r.status, "apns-id": "id-1", ...(r.headers ?? {}) });
          if (r.body !== undefined) stream.emit("data", Buffer.from(JSON.stringify(r.body)));
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
let publicKey: CryptoKey;
const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);
const WIDGET = "c".repeat(64);
const LIVE = "d".repeat(160);

beforeAll(async () => {
  const kp = await generateKeyPair("ES256", { extractable: true });
  publicKey = kp.publicKey as CryptoKey;
  process.env.APNS_KEY_P8 = await exportPKCS8(kp.privateKey);
  process.env.APNS_KEY_ID = "TESTKEY123";
  process.env.APNS_TEAM_ID = "MYXQKK3T2Z";
  process.env.CONVEX_SITE_URL = "https://test-site.example.convex.site";
});

beforeEach(() => {
  apns.calls.length = 0;
  apns.handler = () => ({ status: 200 });
});

function setup() {
  return convexTest(schema, modules);
}
type T = ReturnType<typeof setup>;

async function post(t: T, path: string, body: unknown, secret?: string) {
  const res = await t.fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(secret ? { authorization: `Bearer ${secret}` } : {}) },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as any };
}

/** Gekoppelter Server direkt in der Datenbank (Kopplung selbst testet cloud.test.ts). */
async function pairedServer(t: T, name = "Kunden-Mac", appleSub = "sub-" + name) {
  const secret = "secret-" + name;
  const secretHash = await sha256hex(secret);
  const ids = await t.run(async (ctx) => {
    const now = Date.now();
    const ownerId = await ctx.db.insert("users", { appleSub, createdAt: now, lastLoginAt: now });
    const serverId = await ctx.db.insert("servers", {
      ownerId, name, publicUrl: "", version: "1.13.0", lastSeenAt: now, secretHash, createdAt: now,
    });
    return { ownerId, serverId };
  });
  return { secret, ...ids };
}

const alert = (token: string, extra: Record<string, unknown> = {}) => ({
  token,
  pushType: "alert",
  priority: "10",
  payload: { aps: { alert: { title: "Pip", body: "Fertig" }, badge: 2 } },
  ...extra,
});

describe("Push-Relay: Authentifizierung und Registrierung", () => {
  test("ohne oder mit falschem serverSecret → 401", async () => {
    const t = setup();
    expect((await post(t, "/push/send", { pushes: [alert(TOKEN_A)] })).status).toBe(401);
    expect((await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, "falsch")).status).toBe(401);
    expect((await post(t, "/push/register", { tokens: [] }, "falsch")).status).toBe(401);
    expect((await post(t, "/push/status", {}, "falsch")).status).toBe(401);
    expect(apns.calls).toHaveLength(0);
  });

  test("status meldet, ob der Schlüssel eingerichtet ist", async () => {
    const t = setup();
    const s = await pairedServer(t);
    expect((await post(t, "/push/status", {}, s.secret)).body).toMatchObject({ ok: true, configured: true });
  });

  test("register: gültige Tokens je Plattform, ungültige werden abgelehnt", async () => {
    const t = setup();
    const s = await pairedServer(t);
    const r = await post(t, "/push/register", {
      tokens: [
        { token: TOKEN_A.toUpperCase(), platform: "ios" },
        { token: WIDGET, platform: "ios-widgets" },
        { token: LIVE, platform: "liveactivity" },
        { token: "zz-kein-hex", platform: "ios" },
        { token: TOKEN_B, platform: "android" },
      ],
    }, s.secret);
    expect(r.status).toBe(200);
    expect(r.body.registered).toBe(3);
    expect(r.body.rejected.map((x: any) => x.reason).sort()).toEqual(["BadDeviceToken", "UnknownPlatform"]);
    const rows = await t.run((ctx) => ctx.db.query("pushTokens").collect());
    expect(rows.map((x) => [x.token.slice(0, 2), x.kind]).sort()).toEqual([["aa", "app"], ["cc", "widgets"], ["dd", "liveactivity"]]);
  });
});

describe("Push-Relay: Versand", () => {
  test("Mitteilung an gemeldetes Token: richtiges Topic, Push-Art, Priorität, gültiges ES256-JWT", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, s.secret);
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ ok: true, sent: 1, results: [{ token: TOKEN_A, status: 200, env: "production" }] });
    expect(apns.calls).toHaveLength(1);
    const c = apns.calls[0];
    expect(c.origin).toBe("https://api.push.apple.com");
    expect(c.headers).toMatchObject({
      ":method": "POST", ":path": `/3/device/${TOKEN_A}`, "apns-topic": "com.ais.aisbot",
      "apns-push-type": "alert", "apns-priority": "10",
    });
    expect(JSON.parse(c.body)).toEqual({ aps: { alert: { title: "Pip", body: "Fertig" }, badge: 2 } });
    const jwt = c.headers.authorization.replace("bearer ", "");
    const { payload, protectedHeader } = await jwtVerify(jwt, publicKey);
    expect(protectedHeader).toMatchObject({ alg: "ES256", kid: "TESTKEY123" });
    expect(payload.iss).toBe("MYXQKK3T2Z");
  });

  test("reiner Badge-Push (stilles Aktualisieren der Zahl am App-Symbol) ist erlaubt", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    const r = await post(t, "/push/send", { pushes: [{ token: TOKEN_A, pushType: "alert", priority: "5", payload: { aps: { badge: 0 } } }] }, s.secret);
    expect(r.body.results[0].status).toBe(200);
    expect(apns.calls[0].headers["apns-priority"]).toBe("5");
  });

  test("unbekanntes Token wird nicht gesendet (403 UnknownToken)", async () => {
    const t = setup();
    const s = await pairedServer(t);
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_B)] }, s.secret);
    expect(r.body.results[0]).toMatchObject({ status: 403, reason: "UnknownToken" });
    expect(apns.calls).toHaveLength(0);
  });

  test("Token eines anderen Kontos ist tabu", async () => {
    const t = setup();
    const a = await pairedServer(t, "A");
    const b = await pairedServer(t, "B");
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, a.secret);
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, b.secret);
    expect(r.body.results[0]).toMatchObject({ status: 403, reason: "UnknownToken" });
    expect(apns.calls).toHaveLength(0);
  });

  test("Topic und Push-Art: nur com.ais.aisbot(.push-type.liveactivity|widgets), passend zur Token-Art", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [
      { token: TOKEN_A, platform: "ios" }, { token: WIDGET, platform: "ios-widgets" }, { token: LIVE, platform: "ios-scoops-live-start" },
    ] }, s.secret);
    const r = await post(t, "/push/send", { pushes: [
      alert(TOKEN_A, { topic: "com.fremde.app" }),
      alert(TOKEN_A, { pushType: "voip" }),
      alert(WIDGET), // Widget-Token bekommt keine Mitteilung
      { token: WIDGET, pushType: "widgets", topic: ".push-type.widgets", priority: "5", payload: { aps: { "content-changed": true } } },
      { token: LIVE, pushType: "liveactivity", topic: "liveactivity", priority: "10", payload: { aps: { event: "start", timestamp: 1 } } },
    ] }, s.secret);
    expect(r.body.results.map((x: any) => x.reason ?? x.status)).toEqual(["TopicDisallowed", "InvalidPushType", "TopicDisallowed", 200, 200]);
    expect(apns.calls.map((c) => [c.headers["apns-topic"], c.headers["apns-push-type"]])).toEqual([
      ["com.ais.aisbot.push-type.widgets", "widgets"],
      ["com.ais.aisbot.push-type.liveactivity", "liveactivity"],
    ]);
  });

  test("Payload über 4 KB → 413 PayloadTooLarge; ohne aps → PayloadEmpty", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    const big = { aps: { alert: { body: "x".repeat(4200) } } };
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_A, { payload: big }), alert(TOKEN_A, { payload: { foo: 1 } })] }, s.secret);
    expect(r.body.results).toEqual([
      { token: TOKEN_A, status: 413, reason: "PayloadTooLarge" },
      { token: TOKEN_A, status: 400, reason: "PayloadEmpty" },
    ]);
    expect(apns.calls).toHaveLength(0);
  });

  test("BadDeviceToken in Produktion → Sandbox; Umgebung wird gemerkt", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    apns.handler = (c) => (c.origin.includes("sandbox") ? { status: 200 } : { status: 400, body: { reason: "BadDeviceToken" } });
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, s.secret);
    expect(r.body.results[0]).toMatchObject({ status: 200, env: "sandbox" });
    expect(apns.calls.map((c) => c.origin)).toEqual(["https://api.push.apple.com", "https://api.sandbox.push.apple.com"]);
    apns.calls.length = 0;
    await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, s.secret);
    expect(apns.calls.map((c) => c.origin)).toEqual(["https://api.sandbox.push.apple.com"]);
  });

  test("Fake-Token: BadDeviceToken in beiden Umgebungen → sauber gemeldet und Token entfernt", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_B, platform: "ios" }] }, s.secret);
    apns.handler = () => ({ status: 400, body: { reason: "BadDeviceToken" } });
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_B)] }, s.secret);
    expect(r.status).toBe(200);
    expect(r.body.results[0]).toMatchObject({ token: TOKEN_B, status: 400, reason: "BadDeviceToken" });
    expect(await t.run((ctx) => ctx.db.query("pushTokens").collect())).toHaveLength(0);
  });

  test("Schlüssel nur für Produktion: BadEnvironmentKeyInToken in der Sandbox → BadDeviceToken bleibt das Ergebnis", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_B, platform: "ios" }] }, s.secret);
    apns.handler = (c) =>
      c.origin.includes("sandbox") ? { status: 403, body: { reason: "BadEnvironmentKeyInToken" } } : { status: 400, body: { reason: "BadDeviceToken" } };
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_B)] }, s.secret);
    expect(r.body.results[0]).toMatchObject({ status: 400, reason: "BadDeviceToken", env: "production" });
  });

  test("Unregistered → Token entfernt, Grund an den Server", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }, { token: TOKEN_B, platform: "ios" }] }, s.secret);
    apns.handler = (c) => (c.headers[":path"].includes(TOKEN_A) ? { status: 410, body: { reason: "Unregistered" } } : { status: 200 });
    const r = await post(t, "/push/send", { pushes: [alert(TOKEN_A), alert(TOKEN_B)] }, s.secret);
    expect(r.body.results.map((x: any) => [x.status, x.reason])).toEqual([[410, "Unregistered"], [200, undefined]]);
    const left = await t.run((ctx) => ctx.db.query("pushTokens").collect());
    expect(left.map((x) => x.token)).toEqual([TOKEN_B]);
  });

  test("Ratenbegrenzung: höchstens 120 Pushes pro Minute und Server", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    const batch = { pushes: Array.from({ length: 100 }, () => alert(TOKEN_A)) };
    expect((await post(t, "/push/send", batch, s.secret)).status).toBe(200);
    const r = await post(t, "/push/send", { pushes: Array.from({ length: 30 }, () => alert(TOKEN_A)) }, s.secret);
    expect([r.status, r.body.code]).toEqual([429, "rate_limited"]);
    expect(apns.calls).toHaveLength(100);
    // ein anderer Server ist nicht betroffen
    const o = await pairedServer(t, "Anderer");
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, o.secret);
    expect((await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, o.secret)).status).toBe(200);
  });

  test("zu viele Einträge pro Anfrage → 400", async () => {
    const t = setup();
    const s = await pairedServer(t);
    expect((await post(t, "/push/send", { pushes: Array.from({ length: 101 }, () => alert(TOKEN_A)) }, s.secret)).status).toBe(400);
    expect((await post(t, "/push/send", { pushes: [] }, s.secret)).status).toBe(400);
  });

  test("ohne APNs-Schlüssel im Deployment → 503 relay_not_configured", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    const saved = process.env.APNS_KEY_P8;
    delete process.env.APNS_KEY_P8;
    try {
      expect((await post(t, "/push/status", {}, s.secret)).body.configured).toBe(false);
      expect((await post(t, "/push/send", { pushes: [alert(TOKEN_A)] }, s.secret)).status).toBe(503);
    } finally {
      process.env.APNS_KEY_P8 = saved;
    }
  });
});

describe("Push-Relay: Broadcast-Kanäle", () => {
  const CH = "dHN0LXNyY2gtY2hubA==";

  test("anlegen, senden (mit apns-expiration), löschen – nur durch den anlegenden Server", async () => {
    const t = setup();
    const s = await pairedServer(t);
    const other = await pairedServer(t, "Fremd");
    apns.handler = (c) =>
      c.origin.includes("manage-broadcast") && c.headers[":method"] === "POST"
        ? { status: 201, headers: { "apns-channel-id": CH } }
        : { status: 200 };
    const c = await post(t, "/push/channel", { action: "create" }, s.secret);
    expect(c.body).toEqual({ ok: true, channelId: CH });
    expect(apns.calls[0]).toMatchObject({ origin: "https://api-manage-broadcast.push.apple.com:2196" });
    expect(apns.calls[0].headers[":path"]).toBe("/1/apps/com.ais.aisbot/channels");
    expect(JSON.parse(apns.calls[0].body)).toEqual({ "message-storage-policy": 1, "push-type": "LiveActivity" });

    const payload = { aps: { event: "update", timestamp: 1, "content-state": { scoops: [] } } };
    expect((await post(t, "/push/broadcast", { channelId: CH, payload }, other.secret)).status).toBe(404);
    expect((await post(t, "/push/channel", { action: "delete", channelId: CH }, other.secret)).status).toBe(404);

    const b = await post(t, "/push/broadcast", { channelId: CH, payload, priority: "5" }, s.secret);
    expect(b.body).toEqual({ ok: true });
    const call = apns.calls.at(-1)!;
    expect(call.origin).toBe("https://api.push.apple.com");
    expect(call.headers).toMatchObject({
      ":path": "/4/broadcasts/apps/com.ais.aisbot", "apns-channel-id": CH, "apns-push-type": "LiveActivity", "apns-priority": "5",
    });
    const exp = Number(call.headers["apns-expiration"]);
    expect(exp).toBeGreaterThan(Date.now() / 1000 + 3000);

    const d = await post(t, "/push/channel", { action: "delete", channelId: CH }, s.secret);
    expect(d.body).toEqual({ ok: true });
    expect(apns.calls.at(-1)!.headers).toMatchObject({ ":method": "DELETE", "apns-channel-id": CH });
    expect(await t.run((ctx) => ctx.db.query("pushChannels").collect())).toHaveLength(0);
    expect((await post(t, "/push/broadcast", { channelId: CH, payload }, s.secret)).status).toBe(404);
  });

  test("Broadcast nicht freigeschaltet → ok:false mit Grund, kein Eintrag", async () => {
    const t = setup();
    const s = await pairedServer(t);
    apns.handler = () => ({ status: 403, body: { reason: "Forbidden" } });
    const c = await post(t, "/push/channel", { action: "create" }, s.secret);
    expect(c.body).toEqual({ ok: false, status: 403, reason: "Forbidden" });
    expect(await t.run((ctx) => ctx.db.query("pushChannels").collect())).toHaveLength(0);
  });

  test("Broadcast-Payload über 4 KB → 413", async () => {
    const t = setup();
    const s = await pairedServer(t);
    const r = await post(t, "/push/broadcast", { channelId: CH, payload: { aps: { x: "y".repeat(4200) } } }, s.secret);
    expect(r.status).toBe(413);
  });

  test("Cron löscht verwaiste Kanäle bei APNs", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await t.mutation(internal.push.addChannel, { channelId: CH, serverId: s.serverId, ownerId: s.ownerId });
    await t.run((ctx) => ctx.db.delete(s.serverId));
    await t.action(internal.apns.cleanupChannels, {});
    expect(apns.calls.map((c) => [c.headers[":method"], c.headers["apns-channel-id"]])).toEqual([["DELETE", CH]]);
    expect(await t.run((ctx) => ctx.db.query("pushChannels").collect())).toHaveLength(0);
  });
});

describe("Konto löschen", () => {
  test("entfernt auch die gemeldeten Push-Tokens", async () => {
    const t = setup();
    const s = await pairedServer(t);
    await post(t, "/push/register", { tokens: [{ token: TOKEN_A, platform: "ios" }] }, s.secret);
    await t.run(async (ctx) => {
      const { deletePushTokensOf } = await import("../convex/push");
      await deletePushTokensOf(ctx as any, s.ownerId);
    });
    expect(await t.run((ctx) => ctx.db.query("pushTokens").collect())).toHaveLength(0);
  });
});
