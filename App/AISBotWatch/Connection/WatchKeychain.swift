import Foundation
import Security

/// Zugangsdaten der Uhr: nur im Schlüsselbund (nur dieses Gerät, nach dem ersten Entsperren lesbar).
/// Werte werden nie protokolliert.
enum WatchKeychain {
    private static let service = "com.ais.aisbot.watch"
    private static let account = "credentials"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> WatchCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return WatchCredentials.decode(data)
    }

    static func save(_ credentials: WatchCredentials) {
        guard let data = credentials.encoded() else { return }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
