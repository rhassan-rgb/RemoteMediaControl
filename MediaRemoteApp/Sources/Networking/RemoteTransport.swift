//
//  RemoteTransport.swift
//  MediaRemoteApp
//
//  Abstract transport for sending line-oriented commands to the Mac server.
//  The concrete implementation is `CitadelSSHTransport`, but any class that
//  can turn a command string into a reply string will do.
//

import Foundation

protocol RemoteTransport: AnyObject, Sendable {
    /// Resolve any heavy setup (DNS, TCP connect, SSH handshake, auth).
    func connect() async throws

    /// Send one line of command; receive one line of reply (without trailing \n).
    func send(_ command: String) async throws -> String

    /// Tear down.
    func disconnect() async
}

enum RemoteError: Error, LocalizedError {
    case notConnected
    case authFailed
    case serverError(String)
    case protocolError(String)
    case timeout
    case hostKeyMismatch(host: String, port: Int, expected: String, got: String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected:          return "Not connected."
        case .authFailed:            return "Authentication failed."
        case .serverError(let s):    return "Server error: \(s)"
        case .protocolError(let s):  return "Protocol error: \(s)"
        case .timeout:               return "Request timed out."
        case .hostKeyMismatch(let host, let port, let expected, let got):
            return """
            Host key mismatch for \(host):\(port). Someone may be impersonating your Mac.
            Expected \(expected)
            Got      \(got)
            If you recently reinstalled macOS or regenerated the host key, delete this device in Media Remote and re-add it.
            """
        case .underlying(let e):     return e.localizedDescription
        }
    }
}
