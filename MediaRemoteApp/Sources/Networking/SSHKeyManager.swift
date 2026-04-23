//
//  SSHKeyManager.swift
//  MediaRemoteApp
//
//  Generates Ed25519 key pairs on-device, formats the public key in the
//  OpenSSH "ssh-ed25519 AAAA… comment" format that goes into the remote
//  Mac's ~/.ssh/authorized_keys, and builds a copy-pasteable shell snippet
//  the user can run on the Mac to install it.
//
//  We deliberately avoid classic OpenSSH private-key PEM files here —
//  storing the 32-byte raw seed (base64) is simpler and round-trips cleanly
//  through the existing Keychain wrapper, which expects UTF-8 strings.
//  `CitadelSSHTransport` decodes that base64 back into a
//  `Curve25519.Signing.PrivateKey` when authenticating.
//

import Foundation
import Crypto

enum SSHKeyManager {

    /// A freshly minted Ed25519 key pair in the formats the rest of the app
    /// cares about.
    struct GeneratedKey {
        /// 32-byte raw Ed25519 seed, base64-encoded. This is what gets
        /// written into the Keychain as the device credential.
        let privateKeyBase64: String
        /// Single-line OpenSSH public key, e.g.
        /// `ssh-ed25519 AAAAC3Nz… media-remote@iphone`
        let openSSHPublicKey: String
    }

    /// Generates a brand new Ed25519 key. Pure function — nothing is
    /// persisted; the caller decides what to do with the bytes.
    static func generate(comment: String = "media-remote") -> GeneratedKey {
        let priv = Curve25519.Signing.PrivateKey()
        let privateSeed = priv.rawRepresentation          // 32 bytes
        let publicKey   = priv.publicKey.rawRepresentation // 32 bytes

        let blob  = opensshWireFormat(publicKey: publicKey)
        let b64   = blob.base64EncodedString()
        let line  = "ssh-ed25519 \(b64) \(comment)"

        return GeneratedKey(
            privateKeyBase64: privateSeed.base64EncodedString(),
            openSSHPublicKey: line
        )
    }

    /// Decodes a credential string (raw private key, base64) back into a
    /// `Curve25519.Signing.PrivateKey`. Returns `nil` if the credential
    /// isn't a valid 32-byte Ed25519 seed.
    ///
    /// We zeroize the intermediate seed buffer before returning so the
    /// raw private bytes don't sit in (possibly pageable) process memory
    /// any longer than necessary. CryptoKit keeps its own protected copy
    /// internally.
    static func privateKey(fromBase64 credential: String) -> Curve25519.Signing.PrivateKey? {
        guard var data = Data(base64Encoded: credential.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { return nil }
        defer { Self.zeroize(&data) }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Best-effort in-place zeroization of a `Data` buffer. Swift's optimiser
    /// will generally honour writes through `withUnsafeMutableBytes`, but
    /// this is belt-and-braces — we can't force a fully secure wipe without
    /// dropping to C-level `memset_s`.
    private static func zeroize(_ data: inout Data) {
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            memset(base, 0, buf.count)
        }
    }

    /// One-liner the user runs on the Mac to append the public key to
    /// `~/.ssh/authorized_keys`, creating the directory and fixing file
    /// permissions so sshd will actually read it.
    static func installCommand(for openSSHPublicKey: String) -> String {
        // Single-quote the key so shell expansion can't mangle it.
        let quoted = "'" + openSSHPublicKey.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return """
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
        echo \(quoted) >> ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys
        """
    }

    // MARK: - Private -----------------------------------------------------

    /// Builds the SSH wire-format public key blob:
    ///   string  "ssh-ed25519"
    ///   string  <32-byte public key>
    /// Each "string" is 4-byte big-endian length prefix + data.
    private static func opensshWireFormat(publicKey: Data) -> Data {
        var out = Data()
        append(&out, string: Data("ssh-ed25519".utf8))
        append(&out, string: publicKey)
        return out
    }

    private static func append(_ out: inout Data, string: Data) {
        var len = UInt32(string.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(string)
    }
}
