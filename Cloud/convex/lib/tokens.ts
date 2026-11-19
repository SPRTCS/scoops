// Sitzungs-JWTs (eigener RS256-Schlüssel) und Prüfung von Apples identityToken.
import {
  calculateJwkThumbprint,
  createLocalJWKSet,
  createRemoteJWKSet,
  exportJWK,
  importPKCS8,
  jwtVerify,
  SignJWT,
  type JSONWebKeySet,
  type JWK,
} from "jose";
import { sha256hex } from "./crypto";

export const SESSION_AUDIENCE = "ais-scoops";
export const SESSION_TTL_S = 30 * 24 * 60 * 60; // 30 Tage
const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";

export class AuthError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

function issuer(): string {
  const site = process.env.CONVEX_SITE_URL;
  if (!site) throw new Error("CONVEX_SITE_URL fehlt");
  return site;
}

type SessionKey = { privateKey: CryptoKey; publicJwk: JWK; kid: string };
let cachedKey: { pem: string; key: SessionKey } | null = null;

/** Lädt den privaten Schlüssel (PKCS#8-PEM) aus SESSION_PRIVATE_KEY. */
async function sessionKey(): Promise<SessionKey> {
  const pem = process.env.SESSION_PRIVATE_KEY;
  if (!pem) throw new Error("SESSION_PRIVATE_KEY ist nicht gesetzt");
  if (cachedKey && cachedKey.pem === pem) return cachedKey.key;
  // Umgebungsvariablen speichern Zeilenumbrüche manchmal als „\n“
  const normalized = pem.includes("\\n") ? pem.replace(/\\n/g, "\n") : pem;
  const privateKey = (await importPKCS8(normalized, "RS256", { extractable: true })) as CryptoKey;
  const jwk = await exportJWK(privateKey);
  const publicJwk: JWK = { kty: jwk.kty, n: jwk.n, e: jwk.e };
  const kid = await calculateJwkThumbprint(publicJwk);
  const key = { privateKey, publicJwk: { ...publicJwk, kid, alg: "RS256", use: "sig" }, kid };
  cachedKey = { pem, key };
  return key;
}

export async function publicJwks(): Promise<JSONWebKeySet> {
  return { keys: [(await sessionKey()).publicJwk] };
}

export async function signSession(userId: string, sessionId: string): Promise<{ token: string; expiresAt: number }> {
  const { privateKey, kid } = await sessionKey();
  const now = Math.floor(Date.now() / 1000);
  const exp = now + SESSION_TTL_S;
  const token = await new SignJWT({ sid: sessionId })
    .setProtectedHeader({ alg: "RS256", kid, typ: "JWT" })
    .setIssuer(issuer())
    .setAudience(SESSION_AUDIENCE)
    .setSubject(userId)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .sign(privateKey);
  return { token, expiresAt: exp * 1000 };
}

// -- Apple ---------------------------------------------------------------------
let appleRemote: ReturnType<typeof createRemoteJWKSet> | null = null;
let testJwks: JSONWebKeySet | null = null;

/** Nur für Tests: eigenes JWKS statt Apples Schlüsseln (null = wieder Apple). */
export function setAppleJwksForTesting(jwks: JSONWebKeySet | null): void {
  testJwks = jwks;
}

function appleKeys() {
  if (testJwks) return createLocalJWKSet(testJwks);
  appleRemote ??= createRemoteJWKSet(new URL(APPLE_JWKS_URL), { cooldownDuration: 60_000, cacheMaxAge: 6 * 3600_000 });
  return appleRemote;
}

export function appleAudiences(): string[] {
  return (process.env.APPLE_AUDIENCES ?? "com.ais.aisbot")
    .split(",")
    .map((s: string) => s.trim())
    .filter(Boolean);
}

export type AppleIdentity = { sub: string; email?: string; emailVerified: boolean };

/** Prüft Apples identityToken: Signatur (Apple-JWKS), iss, aud (Bundle-ID), exp, optional nonce. */
export async function verifyAppleToken(identityToken: string, nonce?: string): Promise<AppleIdentity> {
  let payload;
  try {
    ({ payload } = await jwtVerify(identityToken, appleKeys(), {
      issuer: APPLE_ISSUER,
      audience: appleAudiences(),
      algorithms: ["RS256", "ES256"],
      clockTolerance: 60,
    }));
  } catch (e) {
    throw new AuthError("invalid_apple_token", `Apple-Anmeldung ungültig: ${(e as Error).message}`);
  }
  if (typeof payload.sub !== "string" || !payload.sub) {
    throw new AuthError("invalid_apple_token", "Apple-Anmeldung ohne Nutzerkennung");
  }
  if (nonce !== undefined && nonce !== "") {
    const claimed = payload.nonce;
    if (claimed !== nonce && claimed !== (await sha256hex(nonce))) {
      throw new AuthError("invalid_nonce", "Apple-Anmeldung: nonce stimmt nicht");
    }
  }
  const ev = payload.email_verified;
  return {
    sub: payload.sub,
    email: typeof payload.email === "string" ? payload.email : undefined,
    emailVerified: ev === true || ev === "true",
  };
}
