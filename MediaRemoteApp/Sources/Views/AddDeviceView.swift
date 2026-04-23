//
//  AddDeviceView.swift
//  MediaRemoteApp
//
//  New-device sheet. Private-key auth only:
//
//    1. Discovery section at the top – tap a Bonjour-advertised Mac to
//       auto-fill Name, Host and Port.
//    2. The app generates an Ed25519 key pair on-device, shows the
//       public key, and offers a "Copy install command" button that puts
//       a ready-to-paste shell snippet on the clipboard. The user runs it
//       once on the Mac and that host is wired up for good.
//
//  Password authentication was removed in the security pass — storing a
//  macOS login password on an iPhone traded too much blast-radius for
//  too little convenience. See SECURITY_REVIEW.md (iOS H-2).
//

import SwiftUI
import UIKit

struct AddDeviceView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss)        private var dismiss

    @State private var discovery = NetworkDiscovery()

    @State private var name       = "My Mac"
    @State private var host       = ""
    @State private var port       = "22"
    @State private var username   = ""
    @State private var socketPath = "~/.media-remote/sock"

    // Private-key path.
    @State private var generatedKey: SSHKeyManager.GeneratedKey?
    @State private var showCopiedHint = false

    var body: some View {
        NavigationStack {
            Form {
                discoverySection
                displaySection
                sshSection
                authSection
                serverSection
            }
            .navigationTitle("Add device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        discovery.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
        }
    }

    // MARK: - Sections ---------------------------------------------------

    private var discoverySection: some View {
        Section {
            if discovery.hosts.isEmpty {
                HStack {
                    ProgressView()
                    Text(discovery.isBrowsing
                         ? "Searching the local network…"
                         : "No devices found")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(discovery.hosts) { h in
                    Button { apply(h) } label: {
                        HStack {
                            Image(systemName: "laptopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.name).font(.body)
                                Text(subtitle(for: h))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        } header: {
            HStack {
                Text("Discovered on Wi-Fi")
                Spacer()
                Button {
                    discovery.start()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        } footer: {
            Text("Turn on Remote Login (System Settings → General → Sharing) on your Mac so it appears here.")
                .font(.caption)
        }
    }

    private var displaySection: some View {
        Section("Display") {
            TextField("Name", text: $name)
        }
    }

    private var sshSection: some View {
        Section("SSH") {
            TextField("Host or IP", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: $port)
                .keyboardType(.numberPad)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var authSection: some View {
        Section("Authentication") {
            keyBlock
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Socket path", text: $socketPath)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Text("The path of the Unix domain socket that the Media Remote Server listens on. Defaults to ~/.media-remote/sock.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keyBlock: some View {
        if let key = generatedKey {
            VStack(alignment: .leading, spacing: 8) {
                Text("Public key")
                    .font(.caption).foregroundStyle(.secondary)
                Text(key.openSSHPublicKey)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                Button {
                    UIPasteboard.general.string =
                        SSHKeyManager.installCommand(for: key.openSSHPublicKey)
                    withAnimation { showCopiedHint = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        withAnimation { showCopiedHint = false }
                    }
                } label: {
                    Label(showCopiedHint ? "Copied!" : "Copy install command",
                          systemImage: showCopiedHint ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                Text("Paste the copied command into Terminal on your Mac to authorise this app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    generatedKey = SSHKeyManager.generate(
                        comment: "media-remote@\(UIDevice.current.name)")
                } label: {
                    Label("Regenerate key", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                generatedKey = SSHKeyManager.generate(
                    comment: "media-remote@\(UIDevice.current.name)")
            } label: {
                Label("Generate SSH key", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)

            Text("We'll create a new Ed25519 key on this device. The private key stays in the iOS Keychain — only the public key leaves the phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers ----------------------------------------------------

    private func subtitle(for h: DiscoveredHost) -> String {
        let where_: String
        if let hn = h.hostname { where_ = hn }
        else if let a = h.address { where_ = a }
        else { where_ = "resolving…" }
        return "\(where_):\(h.port)"
    }

    private func apply(_ h: DiscoveredHost) {
        name = h.name
        // Prefer the resolved .local hostname so the user isn't pinned to
        // whatever DHCP lease the Mac happens to hold right now.
        host = h.hostname ?? h.address ?? "\(h.name).local"
        port = "\(h.port)"
    }

    private var isValid: Bool {
        !host.isEmpty && !username.isEmpty && generatedKey != nil
    }

    private func save() {
        guard let key = generatedKey else { return }
        let d = Device(
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            socketPath: socketPath,
            authMethod: .privateKey
        )
        store.add(d, credential: key.privateKeyBase64)
        discovery.stop()
        dismiss()
    }
}
