//
//  CommandProtocol.swift
//  MediaRemoteApp
//
//  Typed wrappers over the raw line-based wire protocol. See the macOS
//  server's CommandHandler.h for the full grammar.
//

import Foundation

struct CommandProtocol {

    static func playpause() -> String { "playpause" }
    static func next()      -> String { "next" }
    static func previous()  -> String { "previous" }
    static func getVol()    -> String { "getVol" }
    static func setVol(_ value: Float) -> String {
        // Always send 0.0 … 1.0 form with 3-digit precision.
        String(format: "setVol %.3f", min(max(value, 0), 1))
    }
    static func getSong()   -> String { "getSong" }
    static func getPlayer() -> String { "getPlayer" }
    /// Combined snapshot: one reply carries volume, track, and player.
    /// The server added this in place of calling getVol+getSong+getPlayer
    /// separately; polling uses it to drop per-tick SSH channels 3 → 1.
    static func getState()  -> String { "getState" }
    static func ping()      -> String { "ping" }

    // MARK: - Parsers ----------------------------------------------------

    /// Split a server reply into its status and payload:
    ///   "OK 0.47"       -> (true,  "0.47")
    ///   "ERR no_song"   -> (false, "no_song")
    static func parseStatus(_ reply: String) -> (ok: Bool, payload: String) {
        let trimmed = reply.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("OK") {
            let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return (true, String(rest))
        }
        if trimmed.hasPrefix("ERR") {
            let rest = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (false, String(rest))
        }
        return (false, trimmed)
    }

    static func parseVolume(_ reply: String) throws -> Float {
        let (ok, body) = parseStatus(reply)
        guard ok else { throw RemoteError.serverError(body) }
        guard let v = Float(body) else {
            throw RemoteError.protocolError("bad volume: \(body)")
        }
        return v
    }

    static func parseSong(_ reply: String) throws -> TrackInfo {
        let (ok, body) = parseStatus(reply)
        if !ok && body == "no_song" { return .empty }
        guard ok else { throw RemoteError.serverError(body) }
        guard let data = body.data(using: .utf8) else {
            throw RemoteError.protocolError("bad song JSON")
        }
        let decoder = JSONDecoder()
        // The server uses the "elapsed" / "duration" keys directly.
        return (try? decoder.decode(TrackInfo.self, from: data)) ?? .empty
    }

    static func parsePlayer(_ reply: String) throws -> PlayerInfo {
        let (ok, body) = parseStatus(reply)
        if !ok && body == "none" { return .none }
        guard ok else { throw RemoteError.serverError(body) }
        guard let data = body.data(using: .utf8) else {
            throw RemoteError.protocolError("bad player JSON")
        }
        return (try? JSONDecoder().decode(PlayerInfo.self, from: data)) ?? .none
    }

    /// A full snapshot from the `getState` endpoint. Fields are all
    /// optional — `volume` may be nil if CoreAudio can't read the
    /// default device, and `track`/`player` are nil when nothing is
    /// playing. Callers merge the non-nil parts into their UI state.
    struct StateSnapshot: Decodable {
        var vol:    Float?
        var song:   TrackInfo?
        var player: PlayerInfo?
    }

    static func parseState(_ reply: String) throws -> StateSnapshot {
        let (ok, body) = parseStatus(reply)
        guard ok else { throw RemoteError.serverError(body) }
        guard let data = body.data(using: .utf8) else {
            throw RemoteError.protocolError("bad state JSON")
        }
        do {
            return try JSONDecoder().decode(StateSnapshot.self, from: data)
        } catch {
            throw RemoteError.protocolError("bad state JSON: \(error.localizedDescription)")
        }
    }
}
