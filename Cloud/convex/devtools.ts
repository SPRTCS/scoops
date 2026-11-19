// Nur für Integrationstests gegen das Dev-Deployment (Server/tests/test_cloud.py).
// Intern (nicht von Clients aufrufbar) und zusätzlich nur aktiv, wenn ALLOW_DEV_TOOLS=1 gesetzt ist –
// im Produktions-Deployment ist die Variable nicht gesetzt.
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";
import { randomToken, sha256hex } from "./lib/crypto";
import { signSession } from "./lib/tokens";

export const issueTestSession = internalAction({
  args: { appleSub: v.string(), name: v.optional(v.string()) },
  handler: async (
    ctx,
    { appleSub, name },
  ): Promise<{ token: string; expiresAt: number; refreshToken: string; sessionId: string; userId: string }> => {
    if (process.env.ALLOW_DEV_TOOLS !== "1") throw new Error("devtools sind in diesem Deployment abgeschaltet");
    if (!appleSub.startsWith("test.")) throw new Error("appleSub muss mit „test.“ beginnen");
    const refreshToken = randomToken(32);
    const out: { userId: string; sessionId: string } = await ctx.runMutation(internal.auth.signIn, {
      appleSub,
      name,
      deviceName: "Testlauf",
      platform: "macos",
      refreshHash: await sha256hex(refreshToken),
    });
    const { token, expiresAt } = await signSession(out.userId, out.sessionId);
    return { token, expiresAt, refreshToken, sessionId: out.sessionId, userId: out.userId };
  },
});
