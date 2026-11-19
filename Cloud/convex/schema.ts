// Datenmodell von AIS Scoops Cloud: nur Konten, Server-Verzeichnis, Kopplungscodes und Sitzungen.
// Keine Chats, keine API-Schlüssel, keine Inhalte (siehe docs/accounts.md).
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    appleSub: v.string(),
    email: v.optional(v.string()),
    name: v.optional(v.string()),
    createdAt: v.number(),
    lastLoginAt: v.number(),
  }).index("by_appleSub", ["appleSub"]),

  servers: defineTable({
    ownerId: v.id("users"),
    name: v.string(),
    publicUrl: v.string(),
    tailnetUrl: v.optional(v.string()),
    version: v.string(),
    lastSeenAt: v.number(), // 0 = noch kein Herzschlag
    secretHash: v.optional(v.string()), // SHA-256 (hex) des serverSecret; erst nach dem ersten Abholen gesetzt
    createdAt: v.number(),
    // Zähler für Änderungen an den Shares dieses Servers (docs/sharing.md). Der Herzschlag meldet ihn,
    // der Server lädt bei Abweichung sofort neu (/shares/sync).
    sharesVersion: v.optional(v.number()),
  })
    .index("by_owner", ["ownerId"])
    .index("by_secretHash", ["secretHash"]),

  serverClaims: defineTable({
    code: v.string(), // 8 Zeichen ohne Bindestrich, z. B. K7QX29PL
    claimSecretHash: v.string(), // nur der Server, der den Code angefordert hat, darf das Ergebnis abholen
    name: v.string(),
    publicUrl: v.string(),
    tailnetUrl: v.optional(v.string()),
    version: v.string(),
    serverId: v.optional(v.id("servers")),
    ownerId: v.optional(v.id("users")),
    expiresAt: v.number(),
    status: v.union(v.literal("pending"), v.literal("claimed")),
    createdAt: v.number(),
  })
    .index("by_code", ["code"])
    .index("by_server", ["serverId"])
    .index("by_expiresAt", ["expiresAt"]),

  sessions: defineTable({
    userId: v.id("users"),
    deviceName: v.string(),
    platform: v.string(),
    refreshHash: v.optional(v.string()), // SHA-256 (hex) des Refresh-Tokens; entfällt beim Abmelden
    createdAt: v.number(),
    lastUsedAt: v.number(),
    revokedAt: v.optional(v.number()),
  })
    .index("by_user", ["userId"])
    .index("by_refreshHash", ["refreshHash"])
    .index("by_revokedAt", ["revokedAt"]),

  // Push-Relay (docs/accounts.md, „Push-Relay“): Geräte-Tokens, die ein Server des Inhabers gemeldet hat.
  // Nur an diese Tokens darf ein Server des Inhabers über Convex pushen. Ein Token kann mehreren Konten gehören
  // (je ein Eintrag), ein Konto kann fremde Einträge nie überschreiben.
  pushTokens: defineTable({
    ownerId: v.id("users"),
    token: v.string(), // hex, kleingeschrieben
    kind: v.union(v.literal("app"), v.literal("widgets"), v.literal("liveactivity")),
    platform: v.string(), // wie vom Server gemeldet (ios, macos, ios-widgets, ios-scoops-live-start, liveactivity …)
    serverId: v.id("servers"), // zuletzt meldender Server
    env: v.optional(v.union(v.literal("production"), v.literal("sandbox"))), // gelernt beim ersten Versand
    createdAt: v.number(),
    lastUsedAt: v.number(),
  })
    .index("by_owner_token", ["ownerId", "token"])
    .index("by_token", ["token"])
    .index("by_owner_lastUsed", ["ownerId", "lastUsedAt"])
    .index("by_lastUsedAt", ["lastUsedAt"]),

  // Broadcast-Kanäle (Live-Aktivitäten), die Convex im Auftrag eines Servers bei APNs angelegt hat.
  pushChannels: defineTable({
    channelId: v.string(),
    serverId: v.id("servers"),
    ownerId: v.id("users"),
    createdAt: v.number(),
  })
    .index("by_channel", ["channelId"])
    .index("by_server", ["serverId"])
    .index("by_createdAt", ["createdAt"]),

  // Geteilte Scoops (docs/sharing.md): nur Verzeichnis – wer welchen Scoop auf welchem Server mit welcher Rolle
  // sieht. Inhalte bleiben auf dem Server des Admins.
  shares: defineTable({
    serverId: v.id("servers"),
    ownerId: v.id("users"), // Admin = Inhaber des Servers beim Teilen
    botId: v.string(), // Scoop-ID auf dem Server (b_…)
    botName: v.string(),
    botMascot: v.optional(v.any()), // kleines JSON für die Liste „Mit mir geteilt“ (≤ 2 KB)
    granteeId: v.id("users"),
    role: v.union(v.literal("read"), v.literal("write"), v.literal("edit")),
    computer: v.union(v.literal("none"), v.literal("view"), v.literal("control")),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_server", ["serverId"])
    .index("by_server_bot", ["serverId", "botId"])
    .index("by_grantee", ["granteeId"])
    .index("by_owner", ["ownerId"]),

  invites: defineTable({
    codeHash: v.string(), // SHA-256 (hex) des Einladungscodes; der Code selbst wird nie gespeichert
    serverId: v.id("servers"),
    ownerId: v.id("users"),
    botId: v.string(),
    botName: v.string(),
    botMascot: v.optional(v.any()),
    role: v.union(v.literal("read"), v.literal("write"), v.literal("edit")),
    computer: v.union(v.literal("none"), v.literal("view"), v.literal("control")),
    createdAt: v.number(),
    expiresAt: v.number(),
    usedBy: v.optional(v.id("users")),
    usedAt: v.optional(v.number()),
  })
    .index("by_codeHash", ["codeHash"])
    .index("by_server_bot", ["serverId", "botId"])
    .index("by_server", ["serverId"])
    .index("by_owner", ["ownerId"])
    .index("by_expiresAt", ["expiresAt"]),

  rateLimits: defineTable({
    key: v.string(),
    windowStart: v.number(),
    count: v.number(),
  }).index("by_key", ["key"]),
});
