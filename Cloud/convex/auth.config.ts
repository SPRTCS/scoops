// Convex prüft die eigenen Sitzungs-JWTs (RS256) selbst, damit Queries/Mutations ctx.auth haben.
// Der Schlüssel liegt nur als Umgebungsvariable SESSION_PRIVATE_KEY im Deployment; die öffentliche
// Hälfte wird unter /.well-known/jwks.json ausgeliefert (siehe convex/http.ts).
import type { AuthConfig } from "convex/server";

export default {
  providers: [
    {
      type: "customJwt",
      applicationID: "ais-scoops",
      issuer: process.env.CONVEX_SITE_URL!,
      jwks: `${process.env.CONVEX_SITE_URL}/.well-known/jwks.json`,
      algorithm: "RS256",
    },
  ],
} satisfies AuthConfig;
