//
//  RemoteController.swift
//  MediaRemoteApp
//
//  Owns the currently-connected device and exposes all UI-facing state as
//  @Observable properties. Views bind to this class; they never talk to the
//  transport directly.
//

import Foundation
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class RemoteController {

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(FailureReason)

        var isConnected: Bool { self == .connected }

        /// A short, user-facing label for this status. Used by StatusPill
        /// so we don't render raw NIO/Citadel error strings in a caption.
        var shortLabel: String {
            switch self {
            case .connected:           return "Connected"
            case .connecting:          return "Connecting…"
            case .disconnected:        return "Disconnected"
            case .failed(let reason):  return reason.shortLabel
            }
        }

        /// The raw, longer message (if any) for a detail alert. nil when
        /// there is nothing useful to show.
        var detailMessage: String? {
            switch self {
            case .failed(let reason):  return reason.detail
            default:                   return nil
            }
        }
    }

    /// A structured reason for a `.failed` status. Keeps the raw
    /// transport error around for a detail alert while giving the pill
    /// a short, human label.
    struct FailureReason: Equatable {
        enum Kind: Equatable {
            case unreachable         // DNS/TCP/SSH handshake failed
            case authFailed          // bad key / wrong user
            case hostKeyChanged      // TOFU pin mismatch
            case serverError         // server replied ERR ...
            case protocolError       // malformed reply
            case timeout
            case unknown
        }
        let kind: Kind
        let detail: String

        var shortLabel: String {
            switch kind {
            case .unreachable:    return "Can't reach Mac"
            case .authFailed:     return "Auth failed"
            case .hostKeyChanged: return "Host key changed"
            case .serverError:    return "Server error"
            case .protocolError:  return "Protocol error"
            case .timeout:        return "Timed out"
            case .unknown:        return "Error"
            }
        }

        static func from(_ error: Error) -> FailureReason {
            if let re = error as? RemoteError {
                switch re {
                case .notConnected:
                    return .init(kind: .unreachable, detail: re.errorDescription ?? "Not connected.")
                case .authFailed:
                    return .init(kind: .authFailed, detail: re.errorDescription ?? "Authentication failed.")
                case .hostKeyMismatch:
                    return .init(kind: .hostKeyChanged, detail: re.errorDescription ?? "Host key changed.")
                case .serverError(let msg):
                    return .init(kind: .serverError, detail: msg)
                case .protocolError(let msg):
                    return .init(kind: .protocolError, detail: msg)
                case .timeout:
                    return .init(kind: .timeout, detail: "Request timed out.")
                case .underlying(let inner):
                    // NIO/Citadel transport errors bubble up here. Map
                    // the common ones to a friendly kind; the raw text
                    // still lives in `detail` for the info alert.
                    let raw = inner.localizedDescription
                    let lower = raw.lowercased()
                    if lower.contains("auth") || lower.contains("permission denied") {
                        return .init(kind: .authFailed, detail: raw)
                    }
                    if lower.contains("timeout") || lower.contains("timed out") {
                        return .init(kind: .timeout, detail: raw)
                    }
                    return .init(kind: .unreachable, detail: raw)
                }
            }
            return .init(kind: .unknown, detail: error.localizedDescription)
        }
    }

    // ---- Public, observable state --------------------------------------

    var status: Status       = .disconnected
    var volume: Float        = 0       // 0.0 – 1.0
    var track: TrackInfo     = .empty
    var player: PlayerInfo   = .none
    /// True while the user is dragging the slider; suppresses server pushes.
    var isScrubbingVolume    = false

    private(set) var currentDevice: Device?

    // ---- Private --------------------------------------------------------

    private var transport: RemoteTransport?
    private var pollTask:  Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var retryAttempt: Int = 0

    // Adaptive poll cadence. Fast while something is playing (so scrubber
    // / now-playing title stay fresh); slow when idle (so we don't burn
    // the user's battery while nothing's happening). Snap to fast on any
    // user-initiated action and reset to slow after a few idle ticks.
    private let pollIntervalActive: Duration = .seconds(2)
    private let pollIntervalIdle:   Duration = .seconds(8)
    private var lastSnapshotHadPlayer = false

    // Reconnect backoff schedule. After a transport error we go back to
    // .connecting and retry on this cadence; only after exhausting the
    // list do we settle into .failed and require an explicit user
    // refresh.
    private let reconnectDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    // ---- Connect / disconnect ------------------------------------------

    func connect(to device: Device, credential: String) async {
        await disconnect()
        currentDevice = device
        status = .connecting

        await performConnect(device: device, credential: credential, resetAttempt: true)
    }

    /// Internal connect worker. Separated from `connect(to:credential:)`
    /// so reconnect attempts can reuse the same credential without
    /// tearing down the currentDevice reference.
    private func performConnect(device: Device,
                                credential: String,
                                resetAttempt: Bool) async {
        if resetAttempt { retryAttempt = 0 }
        status = .connecting

        let t = CitadelSSHTransport(device: device, credential: credential)
        do {
            try await t.connect()
            transport = t
            status = .connected
            retryAttempt = 0
            await refreshAll()
            startPolling()
        } catch {
            transport = nil
            handleTransportError(error)
        }
    }

    func disconnect() async {
        pollTask?.cancel()
        pollTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        retryAttempt = 0
        await transport?.disconnect()
        transport = nil
        status = .disconnected
    }

    /// Lightweight pause used when the app is backgrounded. Stops the poll
    /// loop and tears down the SSH socket (iOS will kill it shortly anyway)
    /// but does not flip `status` to `.failed` — the UI would then briefly
    /// flash an error on return to foreground. We park on `.connecting`
    /// instead so the caller can rebuild cleanly.
    func suspendForBackground() async {
        pollTask?.cancel()
        pollTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await transport?.disconnect()
        transport = nil
        if currentDevice != nil {
            status = .connecting
        } else {
            status = .disconnected
        }
    }

    /// Manual retry entry point used by the pull-to-refresh handler and
    /// the tappable StatusPill. Cancels any pending reconnect timer and
    /// tries immediately, resetting the backoff counter.
    func requestRetry() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        retryAttempt = 0
        guard let device = currentDevice,
              let credential = await credentialForCurrentDevice() else {
            status = .disconnected
            return
        }
        await performConnect(device: device, credential: credential, resetAttempt: true)
    }

    /// DeviceStore lives in the environment, not here; to keep this
    /// class testable we expose a hook that the view layer can set.
    /// The default returns nil, which makes manual retry a no-op on
    /// previews where no store is wired up.
    var credentialProvider: ((Device) -> String?)?

    private func credentialForCurrentDevice() async -> String? {
        guard let device = currentDevice else { return nil }
        return credentialProvider?(device)
    }

    // ---- Polling --------------------------------------------------------

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                guard !Task.isCancelled else { break }
                // Re-read interval every iteration so cadence can react
                // to the snapshot we just received.
                let interval = self?.currentPollInterval ?? .seconds(2)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var currentPollInterval: Duration {
        lastSnapshotHadPlayer ? pollIntervalActive : pollIntervalIdle
    }

    /// One round-trip: request the full state snapshot and fold it into
    /// the observable properties. Replaces the old three-call fanout
    /// (`getVol` + `getSong` + `getPlayer`) — see server CommandHandler
    /// `getstate` for the reply shape.
    func refreshAll() async {
        guard let reply = await runCommand(CommandProtocol.getState()) else { return }
        guard let snap = try? CommandProtocol.parseState(reply) else { return }

        if let v = snap.vol, !isScrubbingVolume {
            volume = v
        }
        track  = snap.song   ?? .empty
        player = snap.player ?? .none
        lastSnapshotHadPlayer = !(snap.player?.isNone ?? true)
    }

    // ---- Commands -------------------------------------------------------

    func playPause() async {
        await runCommand(CommandProtocol.playpause())
        // Don't wait for the next poll tick — the user just changed
        // transport state, so a fresh snapshot now makes the play/pause
        // icon reflect the new truth within roughly the round-trip time
        // instead of up to `pollIntervalActive` seconds later.
        await refreshAll()
    }

    func next() async {
        await runCommand(CommandProtocol.next())
        await refreshAll()
    }

    func previous() async {
        await runCommand(CommandProtocol.previous())
        await refreshAll()
    }

    func setVolume(_ v: Float) async {
        // Optimistic UI update
        volume = v
        _ = await runCommand(CommandProtocol.setVol(v), expectOK: true)
    }

    // ---- Fetchers (individual commands retained for compatibility) -----
    //
    // We keep these around so anything driving single-property refreshes
    // still works. The main poll path now uses `getState` via
    // `refreshAll`, which is one SSH channel instead of three.

    private func fetchVolume() async {
        guard let reply = await runCommand(CommandProtocol.getVol()) else { return }
        if let v = try? CommandProtocol.parseVolume(reply), !isScrubbingVolume {
            volume = v
        }
    }

    private func fetchSong() async {
        guard let reply = await runCommand(CommandProtocol.getSong()) else { return }
        if let t = try? CommandProtocol.parseSong(reply) {
            track = t
        }
    }

    private func fetchPlayer() async {
        guard let reply = await runCommand(CommandProtocol.getPlayer()) else { return }
        if let p = try? CommandProtocol.parsePlayer(reply) {
            player = p
        }
    }

    // ---- Low-level ------------------------------------------------------

    @discardableResult
    private func runCommand(_ cmd: String, expectOK: Bool = false) async -> String? {
        guard let t = transport else { return nil }
        do {
            let reply = try await t.send(cmd)
            if expectOK {
                let (ok, body) = CommandProtocol.parseStatus(reply)
                if !ok {
                    handleTransportError(RemoteError.serverError(body))
                    return nil
                }
            }
            return reply
        } catch {
            handleTransportError(error)
            return nil
        }
    }

    // ---- Error + reconnect handling -------------------------------------

    /// Central point for every transport error. Decides whether to park
    /// on `.failed` immediately (auth/host-key — user has to act) or to
    /// schedule a backed-off reconnect attempt (network blips).
    private func handleTransportError(_ error: Error) {
        let reason = FailureReason.from(error)

        // Kill the current poll loop — we'll rebuild it after a
        // successful reconnect.
        pollTask?.cancel()
        pollTask = nil

        switch reason.kind {
        case .authFailed, .hostKeyChanged, .serverError, .protocolError:
            // Bad credentials, MITM pin mismatch, or a protocol-level
            // disagreement. Retrying blindly won't fix any of these, so
            // surface the error to the user and stop.
            status = .failed(reason)
            triggerErrorHaptic()
            return
        case .unreachable, .timeout, .unknown:
            break
        }

        // Transient: park on `.connecting` and try again on a backoff
        // schedule. After the schedule is exhausted, settle into
        // `.failed` so the user can decide to retry manually.
        guard retryAttempt < reconnectDelays.count else {
            status = .failed(reason)
            triggerErrorHaptic()
            return
        }

        let delay = reconnectDelays[retryAttempt]
        retryAttempt += 1
        status = .connecting

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard let device = currentDevice,
              let credential = await credentialForCurrentDevice() else {
            status = .disconnected
            return
        }
        // `resetAttempt: false` so we don't lose the backoff index; on
        // success performConnect clears it back to 0 itself.
        await performConnect(device: device,
                             credential: credential,
                             resetAttempt: false)
    }

    private func triggerErrorHaptic() {
        // A single warning buzz when the app transitions into a
        // surface-able failure. Views also haptic-tap on successful
        // button presses; this one is the "something's wrong" cue.
        let gen = UINotificationFeedbackGenerator()
        gen.notificationOccurred(.warning)
    }
}
