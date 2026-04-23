//
//  ContentView.swift
//  MediaRemoteApp
//
//  Single-screen remote: device picker at top, now-playing card, transport
//  buttons, volume slider.
//

import SwiftUI

struct ContentView: View {

    @Environment(DeviceStore.self)        private var store
    @Environment(RemoteController.self)   private var controller
    @Environment(\.scenePhase)             private var scenePhase

    @State private var showingDeviceSheet = false
    @State private var showingAddSheet    = false
    /// Sticky flag: we passed through `.background` since the last time we
    /// were `.active`. Tells us we need to rebuild the SSH socket on
    /// return – `scenePhase` transitions go `background → inactive → active`,
    /// so the plain `old` value on the active edge is `.inactive`.
    @State private var needsReconnect     = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    DeviceSelectorBar(showingSheet: $showingDeviceSheet)
                    StatusPill()
                    NowPlayingCard()
                    TransportControls()
                    VolumeSlider()
                }
                .padding()
            }
            // Pull-to-refresh: a quick manual reconnect so the user has
            // a discoverable way to re-establish the session when
            // something's gone wrong (Mac went to sleep, key rotated,
            // Wi-Fi hiccuped) without having to background the app.
            .refreshable {
                await controller.requestRetry()
            }
            .navigationTitle("Media Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingDeviceSheet) {
                DeviceListSheet()
            }
            .sheet(isPresented: $showingAddSheet) {
                AddDeviceView()
            }
            .task {
                // Teach the controller how to find a credential on its
                // own — that's what `requestRetry` needs to reconnect
                // without a fresh `connect(to:credential:)` from this
                // view. `store` is stable for the lifetime of the app,
                // so capturing it here is safe.
                controller.credentialProvider = { [weak store = store] device in
                    store?.credential(for: device.id)
                }
                // Auto-connect to the selected device on launch.
                await connectIfPossible()
            }
            .onChange(of: store.selectedDeviceId) { _, _ in
                Task { await connectIfPossible() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                Task { await handleScenePhase(newPhase) }
            }
        }
    }

    /// iOS suspends the app's networking a few seconds after backgrounding,
    /// so the SSH TCP socket and the NIO event loop die with it. Without
    /// this hook the controller sees every subsequent command fail, lands
    /// on `.failed`, and stays there until the app is killed.
    ///
    /// Strategy:
    ///   • `.background`   → tear the transport down cleanly and mark the
    ///     session as dirty.
    ///   • `.active` while dirty → rebuild the connection.
    ///   • `.inactive` is a transient UI state (Control Centre, the app
    ///     switcher peek) – leave the connection alone.
    private func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            needsReconnect = true
            await controller.suspendForBackground()
        case .active:
            if needsReconnect {
                needsReconnect = false
                await connectIfPossible()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func connectIfPossible() async {
        guard let dev = store.selectedDevice,
              let cred = store.credential(for: dev.id) else {
            await controller.disconnect()
            return
        }
        await controller.connect(to: dev, credential: cred)
    }
}

#Preview {
    ContentView()
        .environment(DeviceStore())
        .environment(RemoteController())
}
