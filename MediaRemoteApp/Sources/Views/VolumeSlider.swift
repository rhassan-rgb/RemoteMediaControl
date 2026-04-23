//
//  VolumeSlider.swift
//  MediaRemoteApp
//
//  Bi-directional slider: drags push `setVol` to the server, and the slider
//  value updates from polled `getVol` replies when the user isn't dragging
//  (so AirPods / keyboard changes to the Mac reflect back on the phone).
//

import SwiftUI
import UIKit

struct VolumeSlider: View {
    @Environment(RemoteController.self) private var controller

    // A subtle haptic when the user lifts their finger off the slider —
    // mirrors the system volume HUD on iPad. We deliberately don't
    // haptic mid-drag (would be constant noise) or at drag-start
    // (interferes with the drag gesture).
    private let selection = UISelectionFeedbackGenerator()

    var body: some View {
        // `@Bindable var` creates a local Bindable wrapper around the
        // environment-provided @Observable instance, giving us $binding
        // syntax without duplicating state.
        @Bindable var controller = controller

        VStack(spacing: 8) {
            HStack {
                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
                Slider(
                    value: $controller.volume,
                    in: 0...1,
                    onEditingChanged: { editing in
                        controller.isScrubbingVolume = editing
                        if editing {
                            selection.prepare()
                        } else {
                            if controller.status.isConnected {
                                selection.selectionChanged()
                            }
                            Task { await controller.setVolume(controller.volume) }
                        }
                    }
                )
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(controller.volume * 100)) percent")
                Image(systemName: "speaker.wave.3.fill")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(controller.status.isConnected ? .primary : .secondary)

            Text("\(Int(controller.volume * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal)
        .disabled(!controller.status.isConnected)
    }
}
