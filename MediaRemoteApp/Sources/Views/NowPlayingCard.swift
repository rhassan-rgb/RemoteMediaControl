//
//  NowPlayingCard.swift
//  MediaRemoteApp
//

import SwiftUI

struct NowPlayingCard: View {
    @Environment(RemoteController.self) private var controller

    var body: some View {
        VStack(spacing: 8) {
            // App name
            HStack {
                Image(systemName: playerSymbol(for: controller.player.bundleId))
                Text(controller.player.isNone ? "No player" : controller.player.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Title
            Text(controller.track.displayTitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Artist – album
            if !controller.track.displaySubtitle.isEmpty {
                Text(controller.track.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Best-effort icon for common macOS media apps.
    private func playerSymbol(for bundleId: String) -> String {
        switch bundleId {
        case "com.apple.Music":           return "music.note"
        case "com.apple.podcasts":        return "mic"
        case "com.apple.TV":              return "tv"
        case "com.spotify.client":        return "music.note.list"
        case "com.google.Chrome",
             "com.apple.Safari",
             "org.mozilla.firefox":       return "globe"
        default:                          return "speaker.wave.2"
        }
    }
}

struct StatusPill: View {
    @Environment(RemoteController.self) private var controller
    @State private var showingDetail = false

    var body: some View {
        // Tappable pill. On `.failed` the tap presents an alert with the
        // full error text (NIO/Citadel messages can be long, so we don't
        // want to render them in a tiny caption) and offers a Retry
        // action that kicks a fresh reconnect immediately. For other
        // statuses the tap is a no-op.
        Button {
            if case .failed = controller.status {
                showingDetail = true
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(controller.status.shortLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isFailed ? "Tap to see details and retry." : "")
        .alert("Can't connect",
               isPresented: $showingDetail,
               presenting: controller.status.detailMessage) { _ in
            Button("Retry") {
                Task { await controller.requestRetry() }
            }
            Button("Dismiss", role: .cancel) { }
        } message: { msg in
            Text(msg)
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.status { return true }
        return false
    }

    private var color: Color {
        switch controller.status {
        case .connected:         return .green
        case .connecting:        return .yellow
        case .disconnected:      return .gray
        case .failed:            return .red
        }
    }
}
