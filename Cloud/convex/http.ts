// Öffentliche HTTP-Endpunkte (https://<deployment>.convex.site/…). Format siehe docs/accounts.md.
import { httpRouter } from "convex/server";
import { internal } from "./_generated/api";
import { httpAction, type ActionCtx } from "./_generated/server";
import { formatCode, randomCode, randomToken, sha256hex } from "./lib/crypto";
import { AuthError, publicJwks, signSession, verifyAppleToken } from "./lib/tokens";
import { isJobError, type Job, MAX_JOBS_PER_REQUEST, MAX_PAYLOAD_BYTES, parseJob, payloadBytes, validChannelId } from "./lib/push";

const http = httpRouter();

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

/** Fehler: `error` = lesbarer Text (wie beim Python-Server), `code` = maschinenlesbar. */
function fail(status: number, code: string, message: string): Response {
  return json({ error: message, code }, status);
}

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const body = await req.json();
    return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function str(v: unknown, max = 500): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim().slice(0, max) : undefined;
}

function clientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for") ?? req.headers.get("x-real-ip") ?? "";
  return fwd.split(",")[0].trim() || "unknown";
}

async function allowed(ctx: ActionCtx, key: string, limit: number, windowMs: number): Promise<boolean> {
  return ctx.runMutation(internal.auth.allow, { key, limit, windowMs });
}

const PLATFORMS = new Set(["ios", "ipados", "macos", "visionos"]);

// -- Anmeldung ----------------------------------------------------------------
http.route({
  path: "/auth/apple",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    if (!(await allowed(ctx, `apple:${clientIp(req)}`, 30, 10 * 60_000))) {
      return fail(429, "rate_limited", "Zu viele Anmeldeversuche. Bitte später erneut versuchen.");
    }
    const body = await readJson(req);
    const identityToken = str(body?.identityToken, 10_000);
    if (!body || !identityToken) return fail(400, "bad_request", "identityToken fehlt");
    let apple;
    try {
      apple = await verifyAppleToken(identityToken, str(body.nonce, 500));
    } catch (e) {
      if (e instanceof AuthError) return fail(401, e.code, e.message);
      throw e;
    }
    const platform = (str(body.platform, 20) ?? "ios").toLowerCase();
    const refreshToken = randomToken(32);
    const out = await ctx.runMutation(internal.auth.signIn, {
      appleSub: apple.sub,
      email: apple.email ?? str(body.email, 320),
      name:
        str(body.fullName, 200) ??
        (([str(body.givenName, 100), str(body.familyName, 100)].filter(Boolean).join(" ") || undefined) as string | undefined),
      deviceName: str(body.deviceName, 100) ?? "Unbekanntes Gerät",
      platform: PLATFORMS.has(platform) ? platform : "ios",
      refreshHash: await sha256hex(refreshToken),
    });
    const { token, expiresAt } = await signSession(out.userId, out.sessionId);
    return json({ token, expiresAt, refreshToken, sessionId: out.sessionId, user: out.user });
  }),
});

http.route({
  path: "/auth/refresh",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    if (!(await allowed(ctx, `refresh:${clientIp(req)}`, 60, 10 * 60_000))) {
      return fail(429, "rate_limited", "Zu viele Anfragen. Bitte später erneut versuchen.");
    }
    const body = await readJson(req);
    const refreshToken = str(body?.refreshToken, 200);
    if (!refreshToken) return fail(400, "bad_request", "refreshToken fehlt");
    const out = await ctx.runMutation(internal.auth.refresh, { refreshHash: await sha256hex(refreshToken) });
    if (!out) return fail(401, "invalid_session", "Sitzung abgelaufen oder abgemeldet. Bitte neu anmelden.");
    const { token, expiresAt } = await signSession(out.userId, out.sessionId);
    return json({ token, expiresAt, refreshToken, sessionId: out.sessionId, user: out.user });
  }),
});

http.route({
  path: "/.well-known/jwks.json",
  method: "GET",
  handler: httpAction(async () => json(await publicJwks(), 200, { "cache-control": "public, max-age=300" })),
});

// -- Server koppeln ---------------------------------------------------------------
http.route({
  path: "/servers/claim/start",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    if (!(await allowed(ctx, `claimstart:${clientIp(req)}`, 20, 60 * 60_000))) {
      return fail(429, "rate_limited", "Zu viele Kopplungscodes angefordert. Bitte später erneut versuchen.");
    }
    const body = (await readJson(req)) ?? {};
    const claimSecret = randomToken(32);
    const fields = {
      claimSecretHash: await sha256hex(claimSecret),
      name: str(body.name, 80) ?? "AIS-Scoops-Server",
      publicUrl: str(body.publicUrl, 500) ?? "",
      tailnetUrl: str(body.tailnetUrl, 500),
      version: str(body.version, 40) ?? "?",
    };
    for (let i = 0; i < 5; i++) {
      const code = randomCode();
      const out = await ctx.runMutation(internal.claims.create, { code, ...fields });
      if (out) {
        return json({
          code: formatCode(code),
          claimId: out.claimId,
          claimSecret,
          expiresAt: out.expiresAt,
          ttlSeconds: Math.round((out.expiresAt - Date.now()) / 1000),
        });
      }
    }
    return fail(503, "busy", "Bitte erneut versuchen.");
  }),
});

http.route({
  path: "/servers/claim/poll",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const body = await readJson(req);
    const claimId = str(body?.claimId, 100);
    const claimSecret = str(body?.claimSecret, 200);
    if (!claimId || !claimSecret) return fail(400, "bad_request", "claimId und claimSecret nötig");
    const serverSecret = randomToken(32);
    const out = await ctx.runMutation(internal.claims.poll, {
      claimId,
      claimSecretHash: await sha256hex(claimSecret),
      newSecretHash: await sha256hex(serverSecret),
    });
    switch (out.status) {
      case "pending":
        return json({ status: "pending", expiresAt: out.expiresAt });
      case "expired":
        return json({ status: "expired", code: "expired", error: "Code abgelaufen" }, 410);
      case "claimed":
        return json({
          status: "claimed",
          serverId: out.serverId,
          serverSecret,
          ownerId: out.ownerId,
          name: out.name,
          ownerName: out.ownerName,
        });
      default:
        return fail(404, "unknown_claim", "Kopplung unbekannt");
    }
  }),
});

http.route({
  path: "/servers/heartbeat",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const h = req.headers.get("authorization") ?? "";
    const secret = h.toLowerCase().startsWith("bearer ") ? h.slice(7).trim() : "";
    if (!secret) return fail(401, "unknown_server", "serverSecret fehlt");
    const body = (await readJson(req)) ?? {};
    const out = await ctx.runMutation(internal.claims.heartbeat, {
      secretHash: await sha256hex(secret),
      publicUrl: str(body.publicUrl, 500),
      tailnetUrl: str(body.tailnetUrl, 500),
      version: str(body.version, 40),
    });
    if (!out) return fail(401, "unknown_server", "Server ist nicht (mehr) mit einem Konto gekoppelt");
    return json({ ok: true, ...out });
  }),
});

// -- Push-Relay (für gekoppelte Server ohne eigenen APNs-Schlüssel) ---------------------------
// Authentifizierung wie beim Herzschlag: Authorization: Bearer <serverSecret>. Format siehe docs/accounts.md.

function bearer(req: Request): string {
  const h = req.headers.get("authorization") ?? "";
  return h.toLowerCase().startsWith("bearer ") ? h.slice(7).trim() : "";
}

const UNKNOWN_SERVER = () => fail(401, "unknown_server", "Server ist nicht (mehr) mit einem Konto gekoppelt");
const RATE_LIMITED = () => fail(429, "rate_limited", "Zu viele Mitteilungen. Bitte später erneut versuchen.");
const REMOVE_REASONS = new Set(["Unregistered", "ExpiredToken", "BadDeviceToken"]);

function relayConfigured(): boolean {
  return Boolean(process.env.APNS_KEY_P8 && process.env.APNS_KEY_ID);
}

http.route({
  path: "/push/status",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const known = await ctx.runQuery(internal.push.serverKnown, { secretHash: await sha256hex(secret) });
    if (!known) return UNKNOWN_SERVER();
    return json({ ok: true, configured: relayConfigured(), maxPayloadBytes: MAX_PAYLOAD_BYTES });
  }),
});

http.route({
  path: "/push/register",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const body = await readJson(req);
    const list = Array.isArray(body?.tokens) ? (body!.tokens as unknown[]) : null;
    if (!list || list.length > MAX_JOBS_PER_REQUEST) return fail(400, "bad_request", `tokens: Liste mit höchstens ${MAX_JOBS_PER_REQUEST} Einträgen nötig`);
    const entries = list.map((e) => {
      const o = (e && typeof e === "object" ? e : {}) as Record<string, unknown>;
      return {
        token: typeof o.token === "string" ? o.token.slice(0, 400) : "",
        platform: typeof o.platform === "string" ? o.platform.slice(0, 40) : "",
        ...(typeof o.userId === "string" && o.userId ? { userId: o.userId.slice(0, 100) } : {}),
      };
    });
    const out = await ctx.runMutation(internal.push.register, { secretHash: await sha256hex(secret), entries });
    if (out.status === "unknown_server") return UNKNOWN_SERVER();
    if (out.status === "rate_limited") return RATE_LIMITED();
    return json({ ok: true, registered: out.registered, rejected: out.rejected });
  }),
});

http.route({
  path: "/push/send",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const body = await readJson(req);
    const list = Array.isArray(body?.pushes) ? (body!.pushes as unknown[]) : null;
    if (!list || !list.length || list.length > MAX_JOBS_PER_REQUEST) {
      return fail(400, "bad_request", `pushes: Liste mit 1 bis ${MAX_JOBS_PER_REQUEST} Einträgen nötig`);
    }
    const nowS = Math.floor(Date.now() / 1000);
    const parsed = list.map((raw) => parseJob(raw, nowS));
    const jobs = parsed.filter((j): j is Job => !isJobError(j));
    const prep = await ctx.runMutation(internal.push.prepareSend, {
      secretHash: await sha256hex(secret),
      jobs: jobs.map((j) => ({ token: j.token, pushType: j.pushType })),
    });
    if (prep.status === "unknown_server") return UNKNOWN_SERVER();
    if (prep.status === "rate_limited") return RATE_LIMITED();
    if (!relayConfigured()) return fail(503, "relay_not_configured", "Push-Relay ist nicht eingerichtet");
    // prep.verdicts und delivered haben dieselbe Reihenfolge wie jobs bzw. toSend (Zuordnung per Index,
    // weil dasselbe Token mehrfach mit verschiedenen Push-Arten vorkommen darf).
    const toSend = jobs.map((j, i) => ({ j, i, v: prep.verdicts[i] })).filter((x) => x.v.ok);
    const delivered: { token: string; status: number; reason?: string; env?: "production" | "sandbox" }[] = toSend.length
      ? await ctx.runAction(internal.apns.deliver, {
          jobs: toSend.map(({ j, v }) => ({
            token: j.token,
            pushType: j.pushType,
            topic: j.topic,
            priority: j.priority,
            payload: j.payload,
            ...(j.expiration !== undefined ? { expiration: j.expiration } : {}),
            ...(v.env ? { env: v.env } : {}),
          })),
        })
      : [];
    const outcome = new Map<number, (typeof delivered)[number]>(toSend.map((x, k) => [x.i, delivered[k]]));
    if (delivered.length) {
      await ctx.runMutation(internal.push.recordResults, {
        ownerId: prep.ownerId,
        results: delivered
          .map((d, k) => ({ d, ownerId: toSend[k]?.v.ownerId }))
          .filter(({ d }) => d.status === 200 || REMOVE_REASONS.has(d.reason ?? ""))
          .map(({ d, ownerId }) => ({
            token: d.token,
            ...(ownerId ? { ownerId } : {}),
            env: d.status === 200 ? d.env : undefined,
            remove: d.status !== 200,
          })),
      });
    }
    let k = 0;
    const results = parsed.map((j) => {
      if (isJobError(j)) return { token: j.token, status: j.status, reason: j.reason };
      const i = k++;
      const v = prep.verdicts[i];
      if (!v?.ok) return { token: j.original, status: 403, reason: v?.reason ?? "UnknownToken" };
      const d = outcome.get(i);
      return d
        ? { token: j.original, status: d.status, ...(d.reason ? { reason: d.reason } : {}), ...(d.env ? { env: d.env } : {}) }
        : { token: j.original, status: 502, reason: "NoResponse" };
    });
    return json({ ok: true, sent: results.filter((r) => r.status === 200).length, results });
  }),
});

http.route({
  path: "/push/channel",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const body = (await readJson(req)) ?? {};
    const action = body.action === "delete" ? "delete" : body.action === "create" ? "create" : null;
    if (!action) return fail(400, "bad_request", "action: create oder delete");
    const channelId = action === "delete" ? validChannelId(body.channelId) : null;
    if (action === "delete" && !channelId) return fail(400, "bad_request", "channelId fehlt oder ist ungültig");
    const prep = await ctx.runMutation(internal.push.prepareChannel, {
      secretHash: await sha256hex(secret),
      op: action,
      ...(channelId ? { channelId } : {}),
    });
    if (prep.status === "unknown_server") return UNKNOWN_SERVER();
    if (prep.status === "rate_limited") return RATE_LIMITED();
    if (prep.status === "too_many_channels") return fail(429, "too_many_channels", "Zu viele offene Kanäle – erst alte löschen");
    if (prep.status === "unknown_channel") return fail(404, "unknown_channel", "Kanal unbekannt oder gehört einem anderen Server");
    if (!relayConfigured()) return fail(503, "relay_not_configured", "Push-Relay ist nicht eingerichtet");
    if (action === "create") {
      const r = await ctx.runAction(internal.apns.createChannel, {});
      if (r.status !== 200 || !r.channelId) return json({ ok: false, status: r.status, reason: r.reason });
      await ctx.runMutation(internal.push.addChannel, { channelId: r.channelId, serverId: prep.serverId, ownerId: prep.ownerId });
      return json({ ok: true, channelId: r.channelId });
    }
    const r = await ctx.runAction(internal.apns.deleteChannel, { channelId: channelId! });
    return json(r.status === 200 ? { ok: true } : { ok: false, status: r.status, reason: r.reason });
  }),
});

http.route({
  path: "/push/broadcast",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const body = (await readJson(req)) ?? {};
    const channelId = validChannelId(body.channelId);
    if (!channelId) return fail(400, "bad_request", "channelId fehlt oder ist ungültig");
    const p = body.payload as Record<string, unknown> | undefined;
    if (!p || typeof p !== "object" || Array.isArray(p) || !p.aps || typeof p.aps !== "object") {
      return fail(400, "bad_request", "payload mit aps nötig");
    }
    const payload = JSON.stringify(p);
    if (payloadBytes(payload) > MAX_PAYLOAD_BYTES) return fail(413, "payload_too_large", `payload größer als ${MAX_PAYLOAD_BYTES} Byte`);
    const priority = String(body.priority ?? "10");
    if (!["10", "5", "1"].includes(priority)) return fail(400, "bad_request", "priority: 10, 5 oder 1");
    const nowS = Math.floor(Date.now() / 1000);
    const exp = body.expiration === undefined || body.expiration === null ? nowS + 3600 : Math.floor(Number(body.expiration));
    if (!Number.isFinite(exp) || exp < 0 || exp > nowS + 86400) return fail(400, "bad_request", "expiration: höchstens 24 h in der Zukunft");
    const prep = await ctx.runMutation(internal.push.prepareChannel, { secretHash: await sha256hex(secret), op: "broadcast", channelId });
    if (prep.status === "unknown_server") return UNKNOWN_SERVER();
    if (prep.status === "rate_limited") return RATE_LIMITED();
    if (prep.status === "unknown_channel") return fail(404, "unknown_channel", "Kanal unbekannt oder gehört einem anderen Server");
    if (prep.status !== "ok") return fail(400, "bad_request", "Unerwartet");
    if (!relayConfigured()) return fail(503, "relay_not_configured", "Push-Relay ist nicht eingerichtet");
    const r = await ctx.runAction(internal.apns.broadcast, { channelId, payload, priority, expiration: exp });
    return json(r.status === 200 ? { ok: true } : { ok: false, status: r.status, reason: r.reason });
  }),
});

// -- Geteilte Scoops (docs/sharing.md) -------------------------------------------------------

/** Server-Cache der Shares. Optional meldet der Server aktuelle Namen/Maskottchen seiner geteilten Scoops
 *  (`bots`) und gelöschte Scoops (`removeBots`, deren Shares und Einladungen werden entfernt). */
http.route({
  path: "/shares/sync",
  method: "POST",
  handler: httpAction(async (ctx, req) => {
    const secret = bearer(req);
    if (!secret) return UNKNOWN_SERVER();
    const body = (await readJson(req)) ?? {};
    const bots = (Array.isArray(body.bots) ? body.bots : [])
      .map((b) => (b && typeof b === "object" ? (b as Record<string, unknown>) : {}))
      .filter((b) => typeof b.botId === "string" && typeof b.name === "string")
      .slice(0, 500)
      .map((b) => ({
        botId: (b.botId as string).slice(0, 60),
        name: (b.name as string).slice(0, 200),
        ...(b.mascot && typeof b.mascot === "object" ? { mascot: b.mascot } : {}),
      }));
    const removeBots = (Array.isArray(body.removeBots) ? body.removeBots : [])
      .filter((x): x is string => typeof x === "string")
      .slice(0, 200)
      .map((x) => x.slice(0, 60));
    const out = await ctx.runMutation(internal.shares.syncForServer, { secretHash: await sha256hex(secret), bots, removeBots });
    if (!out) return UNKNOWN_SERVER();
    return json({ ok: true, ...out });
  }),
});

/** Einladungslink https://<site>/i/<code>: kleine Seite, die AIS Scoops öffnet (aisscoops://invite/<code>). */
http.route({
  pathPrefix: "/i/",
  method: "GET",
  handler: httpAction(async (_ctx, req) => {
    const code = new URL(req.url).pathname.slice(3).replace(/[^A-Za-z0-9_-]/g, "").slice(0, 100);
    const app = `aisscoops://invite/${code}`;
    const html = `<!doctype html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>Einladung zu AIS Scoops</title>
<style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f6f4ff;color:#1d1b2e}
main{max-width:420px;padding:32px;text-align:center}a.b{display:inline-block;margin-top:18px;padding:14px 22px;border-radius:14px;background:#7C5CFF;color:#fff;text-decoration:none;font-weight:600}
p{line-height:1.45}@media(prefers-color-scheme:dark){body{background:#15131f;color:#eee}}</style></head>
<body><main><h1>🍦 Einladung zu einem Scoop</h1>
<p>Jemand möchte einen Scoop mit dir teilen. Öffne die Einladung in der App <b>AIS Scoops</b> und tippe auf „Annehmen“.</p>
<a class="b" href="${app}">In AIS Scoops öffnen</a>
<p style="font-size:14px;opacity:.7;margin-top:24px">Noch keine App? AIS Scoops gibt es für iPhone, iPad und Mac.</p>
</main><script>setTimeout(function(){location.href=${JSON.stringify(app)}},300)</script></body></html>`;
    return new Response(code ? html : "Not found", {
      status: code ? 200 : 404,
      headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" },
    });
  }),
});

export default http;
