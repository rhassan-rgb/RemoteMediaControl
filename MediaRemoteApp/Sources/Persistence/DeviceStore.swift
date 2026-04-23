//
//  DeviceStore.swift
//  MediaRemoteApp
//
//  Stores the list of devices in UserDefaults and keeps each device's
//  credential in the iOS Keychain. The store is an `@Observable` class so
//  SwiftUI views can read from it directly.
//

import Foundation
import Observation

@Observable
final class DeviceStore {
    private(set) var devices: [Device] = []
    var selectedDeviceId: UUID?

    private let defaults      = UserDefaults.standard
    private let devicesKey    = "MediaRemote.devices.v1"
    private let selectedKey   = "MediaRemote.selectedDeviceId.v1"

    init() { load() }

    // MARK: - Persistence -------------------------------------------------

    private func load() {
        if let data = defaults.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([Device].self, from: data) {
            devices = decoded
        }

        // Migration: password auth was removed in the security pass. Any
        // device stored with authMethod == .password can no longer connect,
        // so prune it and its Keychain credential. The user will need to
        // re-add the device with an SSH key. See SECURITY_REVIEW.md iOS H-2.
        let removed = devices.filter { $0.authMethod == .password }
        if !removed.isEmpty {
            for d in removed { Keychain.delete(d.id) }
            devices.removeAll { $0.authMethod == .password }
            // Persist the pruned list immediately so we don't re-run this
            // migration on every launch.
            if let data = try? JSONEncoder().encode(devices) {
                defaults.set(data, forKey: devicesKey)
            }
        }

        if let s = defaults.string(forKey: selectedKey) {
            selectedDeviceId = UUID(uuidString: s)
        }
        if selectedDeviceId == nil || !devices.contains(where: { $0.id == selectedDeviceId }) {
            selectedDeviceId = devices.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: devicesKey)
        }
        if let id = selectedDeviceId {
            defaults.set(id.uuidString, forKey: selectedKey)
        } else {
            defaults.removeObject(forKey: selectedKey)
        }
    }

    // MARK: - CRUD --------------------------------------------------------

    func add(_ device: Device, credential: String) {
        devices.append(device)
        Keychain.set(credential, for: device.id)
        if selectedDeviceId == nil { selectedDeviceId = device.id }
        save()
    }

    func update(_ device: Device, credential: String?) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
        }
        if let c = credential { Keychain.set(c, for: device.id) }
        save()
    }

    func remove(id: UUID) {
        devices.removeAll { $0.id == id }
        Keychain.delete(id)
        if selectedDeviceId == id {
            selectedDeviceId = devices.first?.id
        }
        save()
    }

    func select(_ id: UUID?) {
        selectedDeviceId = id
        save()
    }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceId }
    }

    func credential(for deviceId: UUID) -> String? {
        Keychain.get(deviceId)
    }
}
