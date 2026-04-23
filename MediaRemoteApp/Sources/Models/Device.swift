//
//  Device.swift
//  MediaRemoteApp
//
//  A saved remote endpoint: an SSH host plus the Unix-socket path on that
//  host. Credentials (password or private key) are *not* stored in this
//  struct — they live in the Keychain keyed by `id`.
//

import Foundation

struct Device: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String                     // Display name, e.g. "MacBook Pro"
    var host: String                     // DNS name or IP
    var port: Int                        // SSH port (22)
    var username: String
    var socketPath: String               // e.g. "/Users/ragab/.media-remote/sock"
    var authMethod: AuthMethod

    enum AuthMethod: String, Codable, Hashable, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }
        var label: String {
            switch self {
            case .password:   return "Password"
            case .privateKey: return "Private Key"
            }
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        socketPath: String = "~/.media-remote/sock",
        authMethod: AuthMethod = .privateKey
    ) {
        self.id         = id
        self.name       = name
        self.host       = host
        self.port       = port
        self.username   = username
        self.socketPath = socketPath
        self.authMethod = authMethod
    }

    /// Expands a leading ~ to the remote user's home directory. The SSH
    /// server will expand ~ for us too, but some `nc -U` invocations don't —
    /// so we do it client-side when we can.
    var resolvedSocketPath: String {
        if socketPath.hasPrefix("~") {
            return "/Users/\(username)" + socketPath.dropFirst()
        }
        return socketPath
    }
}
