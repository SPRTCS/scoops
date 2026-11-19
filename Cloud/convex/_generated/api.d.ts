/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as apns from "../apns.js";
import type * as auth from "../auth.js";
import type * as claims from "../claims.js";
import type * as crons from "../crons.js";
import type * as devtools from "../devtools.js";
import type * as http from "../http.js";
import type * as lib_crypto from "../lib/crypto.js";
import type * as lib_push from "../lib/push.js";
import type * as lib_session from "../lib/session.js";
import type * as lib_shares from "../lib/shares.js";
import type * as lib_tokens from "../lib/tokens.js";
import type * as push from "../push.js";
import type * as servers from "../servers.js";
import type * as sessions from "../sessions.js";
import type * as shares from "../shares.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  apns: typeof apns;
  auth: typeof auth;
  claims: typeof claims;
  crons: typeof crons;
  devtools: typeof devtools;
  http: typeof http;
  "lib/crypto": typeof lib_crypto;
  "lib/push": typeof lib_push;
  "lib/session": typeof lib_session;
  "lib/shares": typeof lib_shares;
  "lib/tokens": typeof lib_tokens;
  push: typeof push;
  servers: typeof servers;
  sessions: typeof sessions;
  shares: typeof shares;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
