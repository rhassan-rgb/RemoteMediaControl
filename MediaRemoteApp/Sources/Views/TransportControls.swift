//
//  TransportControls.swift
//  MediaRemoteApp
//

import SwiftUI
import UIKit

struct TransportControls: View {
    @Environment(RemoteController.self) private var controller

    // Pre-built so we don't recreate one per tap; `.prepare()` warms up
    // the Taptic engine so the first hit doesn't show the usual ~50 ms
    // lazy-init delay.
    private let impact = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 48) {
            Button {
                tap()
                Task { await controller.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
            }
            .accessibilityLabel("Previous track")

            Button {
                tap()
                Task { await controller.playPause() }
            } label: {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 42))
            }
            .accessibilityLabel("Play or pause")

            Button {
                tap()
                Task { await controller.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
            }
            .accessibilityLabel("Next track")
        }
        .buttonStyle(.plain)
        .foregroundStyle(controller.status.isConnected ? .primary : .secondary)
        .disabled(!controller.status.isConnected)
        .padding(.vertical, 12)
        .onAppear { impact.prepare() }
    }

    private func tap() {
        // Only haptic when we can actually do something — vibrating for
        // a no-op would feel worse than silent. `prepare()` again so
        // back-to-back taps stay crisp.
        guard controller.status.isConnected else { return }
        impact.impactOccurred()
        impact.prepare()
    }
}
