// Tests für AIS Scoops Cloud (convex-test). Apple-Tokens werden mit einem eigenen Testschlüssel signiert,
// das Test-JWKS wird über setAppleJwksForTesting eingeschleust.
import { convexTest } from "convex-test";
import { exportJWK, exportPKCS8, generateKeyPair, jwtVerify, createLocalJWKSet, SignJWT } from "jose";
import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from "vitest";
import { api, internal } from "../convex/_generated/api";
import schema from "../convex/schema";
import { setAppleJwksForTesting } from "../convex/lib/tokens";
import { sha256hex } from "../convex/lib/crypto";

const modules = import.meta.glob("../convex/**/*.*s");
const SITE = "https://test-site.example.convex.site";

let appleKey: CryptoKey;
let otherKey: CryptoKey;

beforeAll(async () => {
  const session = await generateKeyPair("RS256", { extractable: true });
  process.env.SESSION_PRIVATE_KEY = await exportPKCS8(session.privateKey);
  process.env.CONVEX_SITE_URL = SITE;
  const apple = await generateKeyPair("RS256", { extractable: true });
  appleKey = apple.privateKey as CryptoKey;
  otherKey = (await generateKeyPair("RS256")).privateKey as CryptoKey;
  const jwk = await exportJWK(apple.publicKey);
  setAppleJwksForTesting({ keys: [{ ...jwk, kid: "apple-test", alg: "RS256", use: "sig" }] });
});

beforeEach(() => {
  delete process.env.APPLE_AUDIENCES;
});

afterEach(() => {
  vi.useRealTimers();
});

async function appleToken(opts: {
  sub?: string;
  aud?: string;
  iss?: string;
  exp?: number;
  key?: CryptoKey;
  email?: string;
  nonce?: string;
} = {}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const claims: Record<string, unknown> = { email: opts.email ?? "kunde@privaterelay.appleid.com", email_verified: "true" };
  if (opts.nonce) claims.nonce = opts.nonce;
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "apple-test" })
    .setIssuer(opts.iss ?? "https://appleid.apple.com")
    .setAudience(opts.aud ?? "com.ais.aisbot")
    .setSubject(opts.sub ?? "001234.apple.sub")
    .setIssuedAt(now)
    .setExpirationTime(opts.exp ?? now + 600)
    .sign(opts.key ?? appleKey);
}

function setup() {
  return convexTest(schema, modules);
}
type T = ReturnType<typeof setup>;

async function post(t: T, path: string, body: unknown, headers: Record<string, string> = {}) {
  const res = await t.fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as any };
}

async function signIn(t: T, extra: Record<string, unknown> = {}) {
  const r = await post(t, "/auth/apple", {
    identityToken: await appleToken({ sub: (extra.sub as string) ?? undefined }),
    fullName: "Arman Samary",
    deviceName: "iPhone",
    platform: "ios",
    ...extra,
  });
  expect(r.status).toBe(200);
  return r.body as { token: string; refreshToken: string; sessionId: string; expiresAt: number; user: any };
}

/** Identität so, wie Convex sie aus unserem JWT ableiten würde (Signatur prüft auth.config in echt). */
function as(t: T, s: { token: string }) {
  const payload = JSON.parse(atob(s.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
  return t.withIdentity({ subject: payload.sub, issuer: payload.iss, sid: payload.sid } as any);
}

describe("Anmeldung mit Apple", () => {
  test("gültiges Token → Nutzer, Sitzung und Sitzungs-JWT (RS256, 30 Tage, JWKS)", async () => {
    const t = setup();
    const s = await signIn(t);
    expect(s.user).toMatchObject({ name: "Arman Samary", email: "kunde@privaterelay.appleid.com" });
    expect(s.refreshToken.length).toBeGreaterThan(30);
    const jwks = await (await t.fetch("/.well-known/jwks.json")).json();
    expect(jwks.keys[0]).not.toHaveProperty("d");
    const { payload, protectedHeader } = await jwtVerify(s.token, createLocalJWKSet(jwks), {
      issuer: SITE,
      audience: "ais-scoops",
    });
    expect(protectedHeader.alg).toBe("RS256");
    expect(payload.sid).toBe(s.sessionId);
    expect(payload.sub).toBe(s.user.id);
    const days = (payload.exp! - payload.iat!) / 86400;
    expect(days).toBe(30);
    expect(s.expiresAt).toBe(payload.exp! * 1000);
    const me = await as(t, s).query(api.users.me, {});
    expect(me).toMatchObject({ id: s.user.id, name: "Arman Samary", sessionId: s.sessionId });
  });

  test("zweite Anmeldung: gleicher Nutzer, Name bleibt, neue Sitzung", async () => {
    const t = setup();
    const a = await signIn(t);
    const b = await signIn(t, { fullName: undefined, deviceName: "Mac", platform: "macos" });
    const g = await signIn(t, { identityToken: await appleToken({ sub: "555.given" }), fullName: undefined, givenName: "Ada", familyName: "Lovelace" });
    expect(g.user.name).toBe("Ada Lovelace");
    expect(b.user.id).toBe(a.user.id);
    expect(b.user.name).toBe("Arman Samary");
    const sessions = await as(t, b).query(api.sessions.mySessions, {});
    expect(sessions.map((s: any) => [s.deviceName, s.current]).sort()).toEqual([["Mac", true], ["iPhone", false]]);
  });

  test.each([
    ["falsche Audience", { aud: "com.fremde.app" }],
    ["falscher Aussteller", { iss: "https://evil.example" }],
    ["abgelaufen", { exp: Math.floor(Date.now() / 1000) - 3600 }],
    ["falsche Signatur", { key: "other" }],
  ])("abgelehnt: %s", async (_name, opts: any) => {
    const t = setup();
    const r = await post(t, "/auth/apple", {
      identityToken: await appleToken({ ...opts, key: opts.key === "other" ? otherKey : undefined }),
      deviceName: "iPhone",
    });
    expect(r.status).toBe(401);
    expect(r.body.code).toBe("invalid_apple_token");
    expect(r.body.error).toMatch(/Apple-Anmeldung ungültig/);
  });

  test("macOS-Build: gleiche Bundle-ID als Audience; weitere Audiences per APPLE_AUDIENCES", async () => {
    const t = setup();
    process.env.APPLE_AUDIENCES = "com.ais.aisbot,com.ais.aisbot.mac";
    const r = await post(t, "/auth/apple", { identityToken: await appleToken({ aud: "com.ais.aisbot.mac" }), platform: "macos" });
    expect(r.status).toBe(200);
  });

  test("nonce: roh oder als SHA-256 im Token, sonst abgelehnt", async () => {
    const t = setup();
    const raw = "abc123";
    const hashed = await sha256hex(raw);
    expect((await post(t, "/auth/apple", { identityToken: await appleToken({ nonce: hashed }), nonce: raw })).status).toBe(200);
    expect((await post(t, "/auth/apple", { identityToken: await appleToken({ nonce: raw }), nonce: raw })).status).toBe(200);
    const bad = await post(t, "/auth/apple", { identityToken: await appleToken({ nonce: "x" }), nonce: raw });
    expect([bad.status, bad.body.code]).toEqual([401, "invalid_nonce"]);
  });

  test("ohne identityToken → 400", async () => {
    const t = setup();
    expect((await post(t, "/auth/apple", { deviceName: "x" })).status).toBe(400);
  });

  test("Refresh: neues JWT für dieselbe Sitzung; nach Abmelden 401", async () => {
    const t = setup();
    const s = await signIn(t);
    const r = await post(t, "/auth/refresh", { refreshToken: s.refreshToken });
    expect(r.status).toBe(200);
    expect(r.body.sessionId).toBe(s.sessionId);
    expect(r.body.refreshToken).toBe(s.refreshToken);
    expect(r.body.token).toBeTruthy();
    expect((await post(t, "/auth/refresh", { refreshToken: "falsch" })).status).toBe(401);
    expect(await as(t, s).mutation(api.sessions.revokeSession, {})).toEqual({ ok: true });
    expect((await post(t, "/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);
    await expect(as(t, s).query(api.users.me, {})).rejects.toThrow(/abgemeldet|Sitzung/);
  });

  test("ohne Anmeldung: Queries werfen", async () => {
    const t = setup();
    await expect(t.query(api.servers.myServers, {})).rejects.toThrow(/Nicht angemeldet/);
  });
});

async function startClaim(t: T, body: Record<string, unknown> = {}) {
  const r = await post(t, "/servers/claim/start", { name: "Agenten-Air", version: "1.12.0", publicUrl: "https://air.example.ts.net", ...body });
  expect(r.status).toBe(200);
  return r.body as { code: string; claimId: string; claimSecret: string; expiresAt: number; ttlSeconds: number };
}

describe("Server koppeln", () => {
  test("Code-Format wie Scoops Connect, 10 Minuten gültig", async () => {
    const t = setup();
    const c = await startClaim(t);
    expect(c.code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{4}$/);
    expect(c.ttlSeconds).toBeGreaterThanOrEqual(599);
    expect(c.ttlSeconds).toBeLessThanOrEqual(600);
    const p = await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret });
    expect(p).toEqual({ status: 200, body: { status: "pending", expiresAt: c.expiresAt } });
  });

  test("ganzer Ablauf: start → claimServer → poll (Secret) → Herzschlag → myServers online", async () => {
    const t = setup();
    const s = await signIn(t);
    const c = await startClaim(t);
    // fremdes claimSecret bekommt nichts
    expect((await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: "falsch" })).status).toBe(404);
    const typed = c.code.toLowerCase().replace("-", " ");
    const res = await as(t, s).mutation(api.servers.claimServer, { code: typed });
    expect(res).toMatchObject({ ok: true, name: "Agenten-Air" });
    let list = await as(t, s).query(api.servers.myServers, {});
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ name: "Agenten-Air", online: false, version: "1.12.0", lastSeenAt: null });
    // Code ist verbraucht
    const again = await as(t, s).mutation(api.servers.claimServer, { code: c.code });
    expect(again).toMatchObject({ ok: false, error: "invalid_code" });

    const p = await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret });
    expect(p.status).toBe(200);
    expect(p.body).toMatchObject({ status: "claimed", serverId: list[0].id, ownerId: s.user.id });
    const secret = p.body.serverSecret as string;
    const db = await t.run((ctx) => ctx.db.get(list[0].id as any));
    expect((db as any).secretHash).toBe(await sha256hex(secret));
    expect(JSON.stringify(db)).not.toContain(secret);

    const hb = await post(t, "/servers/heartbeat", { publicUrl: "https://neu.example.ts.net", version: "1.12.1" }, { authorization: `Bearer ${secret}` });
    expect(hb.status).toBe(200);
    expect(hb.body).toMatchObject({ ok: true, serverId: list[0].id, ownerId: s.user.id, revokedSessions: [] });
    list = await as(t, s).query(api.servers.myServers, {});
    expect(list[0]).toMatchObject({ online: true, publicUrl: "https://neu.example.ts.net", version: "1.12.1" });
    // nach dem ersten Herzschlag kann das Secret nicht mehr abgeholt werden
    expect((await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).status).toBe(404);
    // falsches Secret
    expect((await post(t, "/servers/heartbeat", {}, { authorization: "Bearer falsch" })).status).toBe(401);
    expect((await post(t, "/servers/heartbeat", {})).status).toBe(401);
  });

  test("online nur, wenn der letzte Herzschlag < 3 Minuten her ist", async () => {
    vi.useFakeTimers();
    const t = setup();
    const s = await signIn(t);
    const c = await startClaim(t);
    await as(t, s).mutation(api.servers.claimServer, { code: c.code, name: "Büro" });
    const secret = (await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).body.serverSecret;
    await post(t, "/servers/heartbeat", { version: "1.12.0" }, { authorization: `Bearer ${secret}` });
    expect((await as(t, s).query(api.servers.myServers, {}))[0]).toMatchObject({ name: "Büro", online: true });
    vi.advanceTimersByTime(4 * 60_000);
    expect((await as(t, s).query(api.servers.myServers, {}))[0].online).toBe(false);
  });

  test("abgelaufener Code: poll → 410, claimServer → invalid_code", async () => {
    vi.useFakeTimers();
    const t = setup();
    const s = await signIn(t);
    const c = await startClaim(t);
    vi.advanceTimersByTime(10 * 60_000 + 1000);
    expect((await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).status).toBe(410);
    expect(await as(t, s).mutation(api.servers.claimServer, { code: c.code })).toMatchObject({ ok: false, error: "invalid_code" });
  });

  test("Rate-Limit: nach 10 Fehlversuchen in 10 Minuten gesperrt, auch für richtige Codes", async () => {
    vi.useFakeTimers();
    const t = setup();
    const s = await signIn(t);
    const c = await startClaim(t);
    const results = [];
    for (let i = 0; i < 11; i++) results.push((await as(t, s).mutation(api.servers.claimServer, { code: `ZZZZ${i}ZZZ` })).error);
    expect(results.filter((e) => e === "invalid_code")).toHaveLength(10);
    expect(results[10]).toBe("rate_limited");
    expect(await as(t, s).mutation(api.servers.claimServer, { code: c.code })).toMatchObject({ ok: false, error: "rate_limited" });
    vi.advanceTimersByTime(10 * 60_000 + 1);
    const c2 = await startClaim(t);
    expect(await as(t, s).mutation(api.servers.claimServer, { code: c2.code })).toMatchObject({ ok: true });
  });

  test("Rate-Limit claim/start: höchstens 20 Codes pro Stunde und IP", async () => {
    const t = setup();
    const statuses = [];
    for (let i = 0; i < 21; i++) {
      statuses.push((await post(t, "/servers/claim/start", {}, { "x-forwarded-for": "203.0.113.9" })).status);
    }
    expect(statuses.slice(0, 20).every((s) => s === 200)).toBe(true);
    expect(statuses[20]).toBe(429);
    expect((await post(t, "/servers/claim/start", {}, { "x-forwarded-for": "203.0.113.10" })).status).toBe(200);
  });

  test("umbenennen, entfernen (Herzschlag danach 401), fremde Server unantastbar", async () => {
    const t = setup();
    const s = await signIn(t);
    const other = await signIn(t, { identityToken: await appleToken({ sub: "999.other" }) });
    const c = await startClaim(t);
    const { serverId } = (await as(t, s).mutation(api.servers.claimServer, { code: c.code })) as any;
    const secret = (await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).body.serverSecret;
    expect(await as(t, other).mutation(api.servers.renameServer, { serverId, name: "Meins" })).toEqual({ ok: false });
    expect(await as(t, other).mutation(api.servers.removeServer, { serverId })).toEqual({ ok: false });
    expect(await as(t, other).query(api.servers.myServers, {})).toEqual([]);
    expect(await as(t, s).mutation(api.servers.renameServer, { serverId, name: "  Mac mini  " })).toEqual({ ok: true });
    expect((await as(t, s).query(api.servers.myServers, {}))[0].name).toBe("Mac mini");
    expect(await as(t, s).mutation(api.servers.removeServer, { serverId })).toEqual({ ok: true });
    expect(await as(t, s).query(api.servers.myServers, {})).toEqual([]);
    const hb = await post(t, "/servers/heartbeat", {}, { authorization: `Bearer ${secret}` });
    expect([hb.status, hb.body.code]).toEqual([401, "unknown_server"]);
  });
});

describe("Sitzungen und Konto", () => {
  test("Gerät abmelden: taucht im Herzschlag als widerrufen auf; fremde Sitzungen nicht abmeldbar", async () => {
    const t = setup();
    const phone = await signIn(t);
    const mac = await signIn(t, { deviceName: "Mac", platform: "macos" });
    const stranger = await signIn(t, { identityToken: await appleToken({ sub: "777.stranger" }) });
    expect(await as(t, stranger).mutation(api.sessions.revokeSession, { sessionId: phone.sessionId })).toEqual({ ok: false });
    const c = await startClaim(t);
    await as(t, mac).mutation(api.servers.claimServer, { code: c.code });
    const secret = (await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).body.serverSecret;
    expect(await as(t, mac).mutation(api.sessions.revokeSession, { sessionId: phone.sessionId })).toEqual({ ok: true });
    const sessions = await as(t, mac).query(api.sessions.mySessions, {});
    expect(sessions.map((s: any) => s.deviceName)).toEqual(["Mac"]);
    const hb = await post(t, "/servers/heartbeat", {}, { authorization: `Bearer ${secret}` });
    expect(hb.body.revokedSessions).toEqual([phone.sessionId]);
  });

  test("Konto löschen: alles weg, Server bekommt 401, Apple-Anmeldung legt neues Konto an", async () => {
    const t = setup();
    const s = await signIn(t);
    const c = await startClaim(t);
    await as(t, s).mutation(api.servers.claimServer, { code: c.code });
    const secret = (await post(t, "/servers/claim/poll", { claimId: c.claimId, claimSecret: c.claimSecret })).body.serverSecret;
    expect(await as(t, s).mutation(api.users.deleteAccount, {})).toEqual({ ok: true });
    const counts = await t.run(async (ctx) => ({
      users: (await ctx.db.query("users").collect()).length,
      sessions: (await ctx.db.query("sessions").collect()).length,
      servers: (await ctx.db.query("servers").collect()).length,
      claims: (await ctx.db.query("serverClaims").collect()).length,
    }));
    expect(counts).toEqual({ users: 0, sessions: 0, servers: 0, claims: 0 });
    expect((await post(t, "/servers/heartbeat", {}, { authorization: `Bearer ${secret}` })).status).toBe(401);
    await expect(as(t, s).query(api.servers.myServers, {})).rejects.toThrow();
    const fresh = await signIn(t);
    expect(fresh.user.id).not.toBe(s.user.id);
  });

  test("Aufräumen löscht alte Codes und lange widerrufene Sitzungen", async () => {
    vi.useFakeTimers();
    const t = setup();
    const s = await signIn(t);
    await startClaim(t);
    await as(t, s).mutation(api.sessions.revokeSession, {});
    vi.advanceTimersByTime(32 * 24 * 3600_000);
    await t.mutation(internal.claims.cleanup, {});
    const left = await t.run(async (ctx) => [
      (await ctx.db.query("serverClaims").collect()).length,
      (await ctx.db.query("sessions").collect()).length,
    ]);
    expect(left).toEqual([0, 0]);
  });

  test("devtools sind ohne ALLOW_DEV_TOOLS gesperrt", async () => {
    const t = setup();
    delete process.env.ALLOW_DEV_TOOLS;
    await expect(t.action(internal.devtools.issueTestSession, { appleSub: "test.x" })).rejects.toThrow(/abgeschaltet/);
  });
});
