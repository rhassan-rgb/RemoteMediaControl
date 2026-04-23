//
//  Keychain.swift
//  MediaRemoteApp
//
//  Minimal Keychain wrapper that stores a single UTF-8 string per device UUID.
//  The stored value is either a login password or a base64-encoded raw
//  Ed25519 seed (32 bytes) – see `SSHKeyManager`.
//

import Foundation
import Security

enum Keychain {
    private static let service = "com.ragab.MediaRemoteApp.credentials"

    private static func baseQuery(_ account: UUID) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
    }

    static func set(_ value: String, for account: UUID) {
        let data = Data(value.utf8)
        var q = baseQuery(account)
        SecItemDelete(q as CFDictionary)  // idempotent
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: UUID) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String]  = true
        q[kSecMatchLimit as String]  = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(_ account: UUID) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
