"use node";
// Push-Relay: Versand an APNs über HTTP/2 (node:http2) mit Token-Authentifizierung (JWT ES256).
// Der Schlüssel kommt ausschließlich aus den Umgebungsvariablen APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID
// und verlässt Convex nie. Aufgerufen aus http.ts (/push/*) nach den Prüfungen in push.ts.
import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import http2 from "node:http2";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import { BUNDLE_ID } from "./lib/push";

const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" } as const;
const BROADCAST_MANAGE = "https://api-manage-broadcast.push.apple.com:2196";
const TIMEOUT_MS = 10_000;
const JWT_TTL_MS = 40 * 60 * 1000; // Apple: höchstens alle 20 Min. erneuern, gültig 60 Min.

type Env = "production" | "sandbox";
type H2Response = { status: number; headers: Record<string, unknown>; body: string };

// -- Schlüssel und JWT ---------------------------------------------------------------
let keyCache: { raw: string; key: KeyObject } | null = null;
let jwtCache: { kid: string; at: number; jwt: string } | null = null;

function loadKey(): { key: KeyObject; kid: string; team: string } {
  const raw = process.env.APNS_KEY_P8;
  const kid = process.env.APNS_KEY_ID;
  const team = process.env.APNS_TEAM_ID || "MYXQKK3T2Z";
  if (!raw || !kid) throw new Error("APNs-Schlüssel ist nicht eingerichtet (APNS_KEY_P8/APNS_KEY_ID)");
  if (keyCache?.raw !== raw) {
    let pem = raw.trim();
    if (!pem.includes("PRIVATE KEY")) {
      // erlaubt auch Hex (wie `security -w` mehrzeilige Werte ausgibt) oder Base64 der PEM-Datei
      const fromHex = /^[0-9a-fA-F]+$/.test(pem) ? Buffer.from(pem, "hex").toString("utf8") : "";
      pem = fromHex.includes("PRIVATE KEY") ? fromHex : Buffer.from(pem, "base64").toString("utf8");
    }
    pem = pem.replace(/\\n/g, "\n");
    keyCache = { raw, key: createPrivateKey(pem) };
  }
  return { key: keyCache.key, kid, team };
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

function providerToken(now = Date.now()): string {
  const { key, kid, team } = loadKey();
  if (jwtCache && jwtCache.kid === kid && now - jwtCache.at < JWT_TTL_MS) return jwtCache.jwt;
  const head = b64url(JSON.stringify({ alg: "ES256", kid }));
  const claims = b64url(JSON.stringify({ iss: team, iat: Math.floor(now / 1000) }));
  const sig = createSign("SHA256").update(`${head}.${claims}`).sign({ key, dsaEncoding: "ieee-p1363" });
  jwtCache = { kid, at: now, jwt: `${head}.${claims}.${b64url(sig)}` };
  return jwtCache.jwt;
}

// -- HTTP/2 ------------------------------------------------------------------------
class Sessions {
  private open = new Map<string, http2.ClientHttp2Session>();

  get(origin: string): http2.ClientHttp2Session {
    let s = this.open.get(origin);
    if (!s || s.closed || s.destroyed) {
      s = http2.connect(origin);
      s.on("error", () => this.open.delete(origin));
      this.open.set(origin, s);
    }
    return s;
  }

  closeAll(): void {
    for (const s of this.open.values()) {
      try {
        s.close();
      } catch {
        /* egal */
      }
    }
    this.open.clear();
  }
}

function request(
  sessions: Sessions,
  origin: string,
  headers: Record<string, string>,
  body?: string,
): Promise<H2Response> {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn: () => void) => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        fn();
      }
    };
    const req = sessions.get(origin).request(headers);
    const timer = setTimeout(() => {
      done(() => reject(new Error("APNs antwortet nicht (Zeitüberschreitung)")));
      try {
        req.close(http2.constants.NGHTTP2_CANCEL);
      } catch {
        /* egal */
      }
    }, TIMEOUT_MS);
    let status = 0;
    let resHeaders: Record<string, unknown> = {};
    const chunks: Buffer[] = [];
    req.on("response", (h: Record<string, unknown>) => {
      status = Number(h[":status"]);
      resHeaders = h;
    });
    req.on("data", (c: Buffer | string) => chunks.push(Buffer.from(c)));
    req.on("end", () => done(() => resolve({ status, headers: resHeaders, body: Buffer.concat(chunks).toString("utf8") })));
    req.on("error", (e: Error) => done(() => reject(e)));
    req.end(body);
  });
}

function reasonOf(r: H2Response): string {
  try {
    return (JSON.parse(r.body || "{}") as { reason?: string }).reason ?? "";
  } catch {
    return "";
  }
}

// -- Versand an Geräte ---------------------------------------------------------------
const jobValidator = v.object({
  token: v.string(),
  pushType: v.string(),
  topic: v.string(),
  priority: v.string(),
  payload: v.string(),
  expiration: v.optional(v.number()),
  env: v.optional(v.union(v.literal("production"), v.literal("sandbox"))),
});

export type DeliverResult = { token: string; status: number; reason?: string; env?: Env; apnsId?: string };

/** Schickt jeden Job an APNs: erst die gelernte bzw. Produktionsumgebung, bei BadDeviceToken die andere. */
export const deliver = internalAction({
  args: { jobs: v.array(jobValidator) },
  handler: async (_ctx, { jobs }): Promise<DeliverResult[]> => {
    const sessions = new Sessions();
    const out: DeliverResult[] = [];
    try {
      let jwt: string;
      try {
        jwt = providerToken();
      } catch (e) {
        console.error("APNs-Schlüssel:", (e as Error).message);
        return jobs.map((j) => ({ token: j.token, status: 500, reason: "RelayNotConfigured" }));
      }
      for (const j of jobs) {
        const order: Env[] = j.env === "sandbox" ? ["sandbox", "production"] : ["production", "sandbox"];
        let last: DeliverResult = { token: j.token, status: 0, reason: "NoResponse" };
        for (const env of order) {
          const headers: Record<string, string> = {
            ":method": "POST",
            ":path": `/3/device/${j.token}`,
            authorization: `bearer ${jwt}`,
            "apns-topic": j.topic,
            "apns-push-type": j.pushType,
            "apns-priority": j.priority,
            "content-type": "application/json",
          };
          if (j.expiration !== undefined) headers["apns-expiration"] = String(j.expiration);
          try {
            const r = await request(sessions, HOSTS[env], headers, j.payload);
            const apnsId = typeof r.headers["apns-id"] === "string" ? (r.headers["apns-id"] as string) : undefined;
            if (r.status === 200) {
              last = { token: j.token, status: 200, env, apnsId };
              break;
            }
            const reason = reasonOf(r) || `HTTP ${r.status}`;
            // Schlüssel nur für eine Umgebung freigegeben: das Ergebnis der ersten Umgebung zählt.
            if (reason === "BadEnvironmentKeyInToken" && last.reason === "BadDeviceToken") break;
            last = { token: j.token, status: r.status, reason, env };
            if (reason !== "BadDeviceToken") break; // nur bei falscher Umgebung die andere versuchen
          } catch (e) {
            last = { token: j.token, status: 502, reason: "ApnsUnreachable" };
            console.error(`APNs ${env}:`, (e as Error).message);
            break;
          }
        }
        out.push(last);
      }
    } finally {
      sessions.closeAll();
    }
    return out;
  },
});

// -- Broadcast-Kanäle (Live-Aktivitäten) ---------------------------------------------------
export const createChannel = internalAction({
  args: {},
  handler: async (): Promise<{ status: number; channelId?: string; reason?: string }> => {
    const sessions = new Sessions();
    try {
      const r = await request(
        sessions,
        BROADCAST_MANAGE,
        {
          ":method": "POST",
          ":path": `/1/apps/${BUNDLE_ID}/channels`,
          authorization: `bearer ${providerToken()}`,
          "content-type": "application/json",
        },
        JSON.stringify({ "message-storage-policy": 1, "push-type": "LiveActivity" }),
      );
      const id = r.headers["apns-channel-id"];
      if ((r.status === 200 || r.status === 201) && typeof id === "string") return { status: 200, channelId: id };
      return { status: r.status, reason: reasonOf(r) || `HTTP ${r.status}` };
    } catch (e) {
      console.error("APNs-Kanal:", (e as Error).message);
      return { status: 502, reason: "ApnsUnreachable" };
    } finally {
      sessions.closeAll();
    }
  },
});

async function deleteChannelAtApple(sessions: Sessions, channelId: string): Promise<{ status: number; reason?: string }> {
  const r = await request(sessions, BROADCAST_MANAGE, {
    ":method": "DELETE",
    ":path": `/1/apps/${BUNDLE_ID}/channels`,
    authorization: `bearer ${providerToken()}`,
    "apns-channel-id": channelId,
  });
  return r.status === 200 || r.status === 204 ? { status: 200 } : { status: r.status, reason: reasonOf(r) || `HTTP ${r.status}` };
}

export const deleteChannel = internalAction({
  args: { channelId: v.string() },
  handler: async (ctx, { channelId }): Promise<{ status: number; reason?: string }> => {
    const sessions = new Sessions();
    try {
      const r = await deleteChannelAtApple(sessions, channelId);
      // Auch wenn Apple den Kanal nicht (mehr) kennt: unser Eintrag ist danach wertlos.
      if (r.status === 200 || r.status === 404 || r.status === 400) await ctx.runMutation(internal.push.removeChannel, { channelId });
      return r;
    } catch (e) {
      console.error("APNs-Kanal löschen:", (e as Error).message);
      return { status: 502, reason: "ApnsUnreachable" };
    } finally {
      sessions.closeAll();
    }
  },
});

export const broadcast = internalAction({
  args: { channelId: v.string(), payload: v.string(), priority: v.string(), expiration: v.number() },
  handler: async (_ctx, a): Promise<{ status: number; reason?: string; apnsId?: string }> => {
    const sessions = new Sessions();
    try {
      const r = await request(
        sessions,
        HOSTS.production,
        {
          ":method": "POST",
          ":path": `/4/broadcasts/apps/${BUNDLE_ID}`,
          authorization: `bearer ${providerToken()}`,
          "apns-channel-id": a.channelId,
          "apns-push-type": "LiveActivity",
          "apns-priority": a.priority,
          "apns-expiration": String(a.expiration), // Pflicht bei Broadcast
          "content-type": "application/json",
        },
        a.payload,
      );
      const apnsId = typeof r.headers["apns-id"] === "string" ? (r.headers["apns-id"] as string) : undefined;
      return r.status === 200 ? { status: 200, apnsId } : { status: r.status, reason: reasonOf(r) || `HTTP ${r.status}` };
    } catch (e) {
      console.error("APNs-Broadcast:", (e as Error).message);
      return { status: 502, reason: "ApnsUnreachable" };
    } finally {
      sessions.closeAll();
    }
  },
});

/** Cron: alte und verwaiste Kanäle bei APNs löschen. */
export const cleanupChannels = internalAction({
  args: {},
  handler: async (ctx) => {
    const ids: string[] = await ctx.runQuery(internal.push.staleChannels, {});
    if (!ids.length || !process.env.APNS_KEY_P8) return;
    const sessions = new Sessions();
    try {
      for (const channelId of ids) {
        try {
          const r = await deleteChannelAtApple(sessions, channelId);
          if (r.status === 200 || r.status === 404 || r.status === 400) await ctx.runMutation(internal.push.removeChannel, { channelId });
        } catch (e) {
          console.error("APNs-Kanal aufräumen:", (e as Error).message);
        }
      }
    } finally {
      sessions.closeAll();
    }
  },
});
