//
//  HostKeyStore.swift
//  MediaRemoteApp
//
//  Stores SHA-256 fingerprints of SSH host keys per (host, port) and provides
//  a simple trust-on-first-use (TOFU) verification API.
//
//  Why not pin the key itself?
//    Fingerprints are shorter and give the user something printable to
//    compare if they want to verify the pin out-of-band.
//
//  Compatibility note:
//    Ideally the fingerprint format would exactly match `ssh-keygen -l`.
//    That requires the SHA-256 of the key's SSH wire-format bytes, but
//    the Citadel / NIOSSH version we build against marks that serializer
//    `internal`. `CitadelSSHTransport.TOFUHostKeyDelegate` feeds
//    `String(reflecting: hostKey)` in here instead — the identity
//    changes iff the key changes (so TOFU works), but the resulting
//    `SHA256:…` string is **not** byte-equal to `ssh-keygen`'s output.
//
//  Storage:
//    UserDefaults under "MediaRemote.hostKeys.v1" — a JSON dictionary
//    mapping "<host>:<port>" → "SHA256:<base64>". Not Keychain, because
//    the fingerprint is not a secret and should be visible/clearable from
//    the Settings app if the user wants to reset trust.
//

import Foundation
import CryptoKit

enum HostKeyStore {

    // MARK: - Public API --------------------------------------------------

    enum Decision: Equatable {
        /// We have no record for this endpoint — pin this fingerprint.
        case firstUse
        /// The fingerprint matches the previously-pinned value.
        case match
        /// The fingerprint does NOT match — refuse the connection.
        case mismatch(expected: String)
    }

    /// Check a host key blob against what we've stored for this endpoint.
    /// Does *not* persist anything on its own — caller decides whether to
    /// pin on `.firstUse` (it almost always should).
    static func check(host: String,
                      port: Int,
                      hostKeyBlob: Data) -> (decision: Decision, fingerprint: String) {
        let fp = Self.fingerprint(of: hostKeyBlob)
        let key = Self.endpointKey(host: host, port: port)
        let map = Self.load()
        if let known = map[key] {
            return (known == fp ? .match : .mismatch(expected: known), fp)
        }
        return (.firstUse, fp)
    }

    /// Persist a fingerprint for (host, port). Overwrites any prior value —
    /// callers should only do this when the user has confirmed trust or on
    /// genuine first-use.
    static func pin(host: String, port: Int, fingerprint: String) {
        var map = Self.load()
        map[Self.endpointKey(host: host, port: port)] = fingerprint
        Self.save(map)
    }

    /// Remove the pinned fingerprint for one endpoint.
    static func forget(host: String, port: Int) {
        var map = Self.load()
        map.removeValue(forKey: Self.endpointKey(host: host, port: port))
        Self.save(map)
    }

    /// Compute the canonical `SHA256:<base64>` fingerprint for a raw SSH
    /// public-key blob (the same bytes `ssh-keygen -l -E sha256 -f …`
    /// hashes).
    static func fingerprint(of hostKeyBlob: Data) -> String {
        let digest = SHA256.hash(data: hostKeyBlob)
        let b64 = Data(digest).base64EncodedString()
        // `ssh-keygen` strips the trailing "=" padding on SHA-256 fingerprints.
        let trimmed = b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(trimmed)"
    }

    // MARK: - Private -----------------------------------------------------

    private static let defaultsKey = "MediaRemote.hostKeys.v1"

    private static func endpointKey(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ map: [String: String]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
