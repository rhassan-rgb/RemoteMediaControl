//
//  DeviceSelectorBar.swift
//  MediaRemoteApp
//

import SwiftUI

struct DeviceSelectorBar: View {
    @Environment(DeviceStore.self) private var store
    @Binding var showingSheet: Bool

    var body: some View {
        Button { showingSheet = true } label: {
            HStack {
                Image(systemName: "laptopcomputer")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedDevice?.name ?? "No device")
                        .font(.headline)
                    if let d = store.selectedDevice {
                        Text("\(d.username)@\(d.host):\(d.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tap to add one")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct DeviceListSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("Devices") {
                    ForEach(store.devices) { d in
                        Button {
                            store.select(d.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.name).font(.headline)
                                    Text("\(d.username)@\(d.host)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if d.id == store.selectedDeviceId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { idx in
                        for i in idx { store.remove(id: store.devices[i].id) }
                    }
                }
            }
            .navigationTitle("Select device")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) { AddDeviceView() }
        }
    }
}
