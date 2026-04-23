//
//  MediaRemoteApp.swift
//  MediaRemoteApp
//
//  App entry point. Owns the DeviceStore and RemoteController as environment
//  objects so every view can reach them without prop-drilling.
//

import SwiftUI

@main
struct MediaRemoteApp: App {

    // @State + @Bindable in iOS 17+ is the "new" way to do @StateObject for
    // @Observable classes.
    @State private var store      = DeviceStore()
    @State private var controller = RemoteController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(controller)
        }
    }
}
