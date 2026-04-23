//
//  TrackInfo.swift
//  MediaRemoteApp
//

import Foundation

struct TrackInfo: Equatable, Codable {
    var title:    String?
    var artist:   String?
    var album:    String?
    var duration: Double?     // seconds
    var elapsed:  Double?     // seconds

    static let empty = TrackInfo()

    var displayTitle:    String { title  ?? "Nothing playing" }
    var displaySubtitle: String {
        [artist, album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

struct PlayerInfo: Equatable, Codable {
    var bundleId:    String
    var displayName: String

    static let none = PlayerInfo(bundleId: "", displayName: "")
    var isNone: Bool { bundleId.isEmpty && displayName.isEmpty }
}
