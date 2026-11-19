// Push-Relay: Regeln und Prüfungen (ohne Node-APIs, damit HTTP-Actions, Mutations und Tests sie teilen).
// Der eigentliche Versand an APNs (HTTP/2) liegt in convex/apns.ts ("use node").

export const BUNDLE_ID = "com.ais.aisbot";

export type TokenKind = "app" | "widgets" | "liveactivity";
export type PushType = "alert" | "background" | "widgets" | "liveactivity";

/** Topic je Push-Art – fest vorgegeben, der Server kann kein anderes Topic wählen. */
export const TOPIC_FOR: Record<PushType, string> = {
  alert: BUNDLE_ID,
  background: BUNDLE_ID,
  widgets: `${BUNDLE_ID}.push-type.widgets`,
  liveactivity: `${BUNDLE_ID}.push-type.liveactivity`,
};

/** Welche Token-Art eine Push-Art braucht (ein Widget-Token bekommt nie eine Mitteilung usw.). */
export const KIND_FOR: Record<PushType, TokenKind> = {
  alert: "app",
  background: "app",
  widgets: "widgets",
  liveactivity: "liveactivity",
};

/** Plattform-Angaben der App (POST /api/devices bzw. /api/live-activities am Server) → Token-Art. */
export function kindForPlatform(platform: string): TokenKind | null {
  const p = platform.trim().toLowerCase();
  if (["", "ios", "ipados", "macos", "visionos"].includes(p)) return "app";
  if (p === "ios-widgets") return "widgets";
  if (["ios-scoops-live-start", "ios-liveactivity-start", "liveactivity"].includes(p)) return "liveactivity";
  return null;
}

/** APNs-Geräte- und Live-Activity-Tokens sind Hex-Zeichenketten (32 Byte bzw. länger). */
export function normalizeToken(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim().toLowerCase();
  return /^[0-9a-f]{32,400}$/.test(t) ? t : null;
}

export const MAX_PAYLOAD_BYTES = 4096; // Mitteilungen, Live-Aktivitäten und Broadcasts: 4 KB
export const MAX_JOBS_PER_REQUEST = 100;
export const MAX_TOKENS_PER_OWNER = 200; // älteste (zuletzt ungenutzte) fallen beim Melden heraus
export const MAX_CHANNELS_PER_SERVER = 20;
export const CHANNEL_MAX_AGE_MS = 6 * 60 * 60 * 1000; // ältere Kanäle löscht der Cron bei APNs
export const PRIORITIES = new Set(["10", "5", "1"]);

/** Grenzen pro Server bzw. Konto (fester Zeitfenster-Zähler, siehe lib/session.ts rateLimit).
 *  Live-Aktivitäten aktualisieren höchstens alle 4 s → bis zu 900 Pushes pro Stunde und laufender Anzeige. */
export const LIMITS = {
  sendHour: { limit: 1800, windowMs: 60 * 60_000 },
  sendMinute: { limit: 120, windowMs: 60_000 },
  ownerHour: { limit: 3600, windowMs: 60 * 60_000 },
  broadcastHour: { limit: 1800, windowMs: 60 * 60_000 },
  broadcastMinute: { limit: 60, windowMs: 60_000 },
  channelHour: { limit: 60, windowMs: 60 * 60_000 },
  registerHour: { limit: 300, windowMs: 60 * 60_000 },
};

export function payloadBytes(json: string): number {
  return new TextEncoder().encode(json).length;
}

export type Job = {
  token: string; // normalisiert
  original: string; // wie gesendet (für die Antwort)
  pushType: PushType;
  topic: string;
  priority: string;
  payload: string; // JSON
  expiration?: number; // Sekunden seit 1970
};

export type JobError = { token: string; status: number; reason: string };

/** Prüft einen Eintrag aus POST /push/send. Liefert den Job oder einen Fehler mit APNs-ähnlichem Grund. */
export function parseJob(raw: unknown, nowS: number): Job | JobError {
  const o = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>;
  const original = typeof o.token === "string" ? o.token.slice(0, 400) : "";
  const token = normalizeToken(o.token);
  if (!token) return { token: original, status: 400, reason: "BadDeviceToken" };
  const pushType = String(o.pushType ?? "alert").toLowerCase() as PushType;
  if (!(pushType in TOPIC_FOR)) return { token: original, status: 400, reason: "InvalidPushType" };
  const topic = TOPIC_FOR[pushType];
  if (o.topic !== undefined && o.topic !== null && o.topic !== "") {
    // erlaubt: volles Topic oder nur das Suffix („.push-type.widgets“ / „widgets“) – muss zur Push-Art passen
    const given = String(o.topic);
    const suffix = topic.slice(BUNDLE_ID.length);
    const ok = given === topic || given === suffix || (suffix && given === suffix.split(".").pop());
    if (!ok) return { token: original, status: 400, reason: "TopicDisallowed" };
  }
  const priority = String(o.priority ?? (pushType === "alert" ? "10" : "5"));
  if (!PRIORITIES.has(priority)) return { token: original, status: 400, reason: "BadPriority" };
  const p = o.payload;
  if (!p || typeof p !== "object" || Array.isArray(p)) return { token: original, status: 400, reason: "PayloadEmpty" };
  const aps = (p as Record<string, unknown>).aps;
  if (!aps || typeof aps !== "object" || Array.isArray(aps)) return { token: original, status: 400, reason: "PayloadEmpty" };
  const payload = JSON.stringify(p);
  if (payloadBytes(payload) > MAX_PAYLOAD_BYTES) return { token: original, status: 413, reason: "PayloadTooLarge" };
  let expiration: number | undefined;
  if (o.expiration !== undefined && o.expiration !== null) {
    const e = Number(o.expiration);
    if (!Number.isFinite(e) || e < 0 || e > nowS + 30 * 86400) return { token: original, status: 400, reason: "BadExpirationDate" };
    expiration = Math.floor(e);
  }
  return { token, original, pushType, topic, priority, payload, expiration };
}

export function isJobError(j: Job | JobError): j is JobError {
  return (j as JobError).reason !== undefined && (j as Job).payload === undefined;
}

/** Broadcast-Kanal-IDs von APNs sind Base64 (z. B. „dHN0LXNyY2gtY2hubA==“). */
export function validChannelId(v: unknown): string | null {
  return typeof v === "string" && /^[A-Za-z0-9+/=_-]{8,200}$/.test(v) ? v : null;
}
