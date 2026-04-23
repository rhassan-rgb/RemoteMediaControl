//
//  CitadelSSHTransport.swift
//  MediaRemoteApp
//
//  Uses Citadel (pure-Swift SSH) to open a session to the Mac and then, for
//  every command, spawn a short-lived `nc -U <socket>` process on the other
//  end. The overhead per command is one SSH channel, which is much cheaper
//  than opening a fresh SSH connection each time.
//
//  Dependency: https://github.com/orlandos-nl/Citadel  (add via SwiftPM).
//
//  Host-key verification: TOFU (trust-on-first-use).
//    The first time we see a host we pin its SHA-256 fingerprint via
//    `HostKeyStore`. Every subsequent connection must present the same
//    fingerprint or the connection is refused. See `HostKeyStore.swift`.
//

import Foundation
import NIOCore
import NIOSSH
import Crypto
import Citadel

actor CitadelSSHTransport: RemoteTransport {

    private let device: Device
    private let credential: String
    private var client: SSHClient?

    init(device: Device, credential: String) {
        self.device     = device
        self.credential = credential
    }

    // ---- Lifecycle ------------------------------------------------------

    func connect() async throws {
        if client != nil { return }

        let auth: SSHAuthenticationMethod
        switch device.authMethod {
        case .privateKey:
            // The credential string is the 32-byte Ed25519 seed, base64
            // encoded — that's what SSHKeyManager.generate() writes into
            // the keychain.
            guard let key = SSHKeyManager.privateKey(fromBase64: credential) else {
                throw RemoteError.protocolError(
                    "Stored private key is not a valid Ed25519 seed. Re-generate the key from the Add Device screen.")
            }
            auth = .ed25519(username: device.username, privateKey: key)
        case .password:
            // Password auth was removed; surface a clear migration message
            // rather than a generic failure.
            throw RemoteError.protocolError(
                "Password auth has been removed for security. Open this device, delete it, and re-add it using an SSH key.")
        }

        // ---- Host-key validation -----------------------------------------
        //
        // TOFU via HostKeyStore. Citadel's SSHHostKeyValidator.custom(_:)
        // takes an `NIOSSHClientServerAuthenticationDelegate` (the protocol
        // SwiftNIO SSH uses), not a closure — we implement that protocol in
        // the TOFUHostKeyDelegate class below, which does the fingerprint
        // comparison and records any mismatch so `connect()` can translate
        // the thrown error into a friendly RemoteError.hostKeyMismatch.
        let tofu = TOFUHostKeyDelegate(host: device.host, port: device.port)
        let validator = SSHHostKeyValidator.custom(tofu)

        do {
            client = try await SSHClient.connect(
                host: device.host,
                port: device.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            if let m = tofu.recordedMismatch {
                throw RemoteError.hostKeyMismatch(
                    host: device.host, port: device.port,
                    expected: m.expected, got: m.got)
            }
            throw RemoteError.underlying(error)
        }
    }

    func disconnect() async {
        try? await client?.close()
        client = nil
    }

    // ---- Command I/O ----------------------------------------------------

    func send(_ command: String) async throws -> String {
        if client == nil { try await connect() }
        guard let client else { throw RemoteError.notConnected }

        // Build a safe shell invocation:
        //   printf '%s\n' 'playpause' | nc -U '/Users/x/.media-remote/sock'
        //
        // `nc -U` reads its stdin until EOF (the pipe from `printf`
        // closes after one line) before closing its write side. The
        // server then sees peerClosed=YES after the single reply has
        // been written, notices pending==0, and closes the connection —
        // so `nc` exits cleanly.
        //
        // Each call still opens a fresh SSH exec channel plus a fresh
        // `nc` process on the Mac. That's fine for user-initiated
        // commands (tapping playpause, dragging the volume slider),
        // which happen at human rates; the real cost was in polling,
        // which used to fire 3 channels every 2 seconds. Polling now
        // uses the combined `getState` endpoint on the server, so the
        // poll path is 1 channel per tick. True bidirectional
        // streaming (one long-lived exec channel, multiple \n-framed
        // commands over its stdin) would collapse that further to
        // zero per-tick channel setup — that's a future refactor
        // waiting on Citadel's exec-stream API to stabilise.
        let line   = shellSingleQuote(command)
        let socket = shellSingleQuote(device.resolvedSocketPath)
        let shell  = "printf '%s\\n' \(line) | nc -U \(socket)"

        let raw: ByteBuffer
        do {
            raw = try await client.executeCommand(shell)
        } catch {
            throw RemoteError.underlying(error)
        }

        var buf = raw
        let string = buf.readString(length: buf.readableBytes) ?? ""
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw RemoteError.protocolError("empty reply")
        }
        return trimmed
    }

    // ---- Utilities ------------------------------------------------------

    /// POSIX-safe single-quote escaper. `foo'bar` -> `'foo'\''bar'`.
    private func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

// -----------------------------------------------------------------------------
// TOFU host-key delegate
// -----------------------------------------------------------------------------
//
// Implements `NIOSSHClientServerAuthenticationDelegate` — the SwiftNIO SSH
// protocol Citadel's `SSHHostKeyValidator.custom(_:)` wraps.
//
// The delegate is used for one handshake only: a fresh instance is built
// per `connect()` call. If the pinned fingerprint doesn't match, the
// mismatch is recorded on the instance *and* the NIO promise is failed.
// The outer `connect()` picks up the recorded value after the thrown
// error to build a user-facing RemoteError.hostKeyMismatch.
//
// `@unchecked Sendable` is fine here: `recordedMismatch` is written
// exactly once from the NIO event loop inside `validateHostKey`, and
// is only read by the outer task after the `connect()` future has
// completed — NIO's completion provides the happens-before.
final class TOFUHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Mismatch: Error {
        let expected: String
        let got: String
    }

    private let host: String
    private let port: Int
    private(set) var recordedMismatch: Mismatch?

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise: EventLoopPromise<Void>) {
        // Build a stable byte representation of the presented host key so
        // we can SHA-256 it for the pinned fingerprint.
        //
        // In the Citadel / NIOSSH version this project is pinned to,
        // `ByteBuffer.writeSSHHostKey(_:)` is marked `internal`, and
        // `NIOSSHPublicKey` does not expose its raw wire bytes through
        // any public accessor. We therefore fall back to the type's
        // deterministic reflected representation, which changes iff the
        // underlying key changes — exactly what TOFU needs.
        //
        // Trade-off to be aware of:
        //   • The fingerprint is stable across app launches for a given
        //     NIOSSH version, so pinning and mismatch-detection work as
        //     intended.
        //   • The fingerprint **will not** match the `SHA256:…` string
        //     produced by `ssh-keygen -l -E sha256` on the Mac. If/when
        //     NIOSSH exposes a public wire-format serializer, swap the
        //     two lines below for a proper `buf.writeSSHHostKey(hostKey)`
        //     and the fingerprint will then align with ssh-keygen.
        let identity = String(reflecting: hostKey)
        let blob = Data(identity.utf8)

        let (decision, fingerprint) = HostKeyStore.check(
            host: host, port: port, hostKeyBlob: blob)

        switch decision {
        case .match:
            validationCompletePromise.succeed(())
        case .firstUse:
            // Pin silently on first contact. A future UI enhancement
            // could prompt the user to confirm; for now we record the
            // fingerprint so any subsequent MITM attempt is rejected.
            HostKeyStore.pin(host: host, port: port, fingerprint: fingerprint)
            validationCompletePromise.succeed(())
        case .mismatch(let expected):
            let info = Mismatch(expected: expected, got: fingerprint)
            self.recordedMismatch = info
            NSLog("""
            [MediaRemote] ⚠️  HOST KEY MISMATCH for \(host):\(port)
                expected \(expected)
                got      \(fingerprint)
            """)
            validationCompletePromise.fail(info)
        }
    }
}
