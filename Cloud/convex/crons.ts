import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();
crons.interval("cleanup", { hours: 6 }, internal.claims.cleanup, {});
crons.interval("push tokens", { hours: 12 }, internal.push.cleanupTokens, {});
crons.interval("push channels", { hours: 1 }, internal.apns.cleanupChannels, {});
crons.interval("invites", { hours: 6 }, internal.shares.cleanupInvites, {});
export default crons;
