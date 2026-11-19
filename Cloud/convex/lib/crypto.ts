// Kleine Krypto-Helfer. Zufallswerte nur in Actions/HTTP-Actions erzeugen (dort echte Zufälligkeit).

export const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // wie Scoops Connect: ohne 0/O/1/I
export const CODE_TTL_MS = 10 * 60 * 1000;

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomToken(bytes = 32): string {
  return b64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

/** 8 Zeichen aus CODE_ALPHABET (ohne Modulo-Verzerrung: 256 ist ein Vielfaches von 32). */
export function randomCode(): string {
  const raw = crypto.getRandomValues(new Uint8Array(8));
  return Array.from(raw, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

/** Anzeigeform wie Scoops Connect: K7QX-29PL */
export function formatCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

/** Tolerant: Groß-/Kleinschreibung, Bindestriche und Leerzeichen sind egal. */
export function normalizeCode(input: string): string {
  return input.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

export async function sha256hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
