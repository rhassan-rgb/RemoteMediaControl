//
//  NetworkDiscovery.swift
//  MediaRemoteApp
//
//  Uses Bonjour (via Network.framework) to find SSH-capable hosts on the
//  local network, and the older `NetService` API to resolve each hit to
//  its `.local` hostname – SSH clients connect much more reliably to
//  `macbook-pro.local` than to a DHCP-assigned IP that might change
//  between sessions.
//
//  Macs publish `_ssh._tcp` when Remote Login is turned on in
//  System Settings → General → Sharing, so we can just browse for that
//  service type.
//
//  Requires Info.plist entries:
//      NSLocalNetworkUsageDescription   – "Find your Mac on the Wi-Fi …"
//      NSBonjourServices                – ["_ssh._tcp"]
//

import Foundation
import Network
import Observation

/// A single host discovered on the LAN.
struct DiscoveredHost: Identifiable, Hashable {
    let id: String          // stable key (service name + type + domain)
    var name: String        // the Bonjour instance name, e.g. "MacBook Pro"
    var hostname: String?   // resolved .local hostname, e.g. "macbook.local"
    var address: String?    // resolved IP, kept for display only
    var port: Int           // resolved port, or 22 as a fallback
}

/// Browses the local network for SSH services. All callbacks run on the
/// main thread (NWBrowser via `queue: .main`, NetService via
/// `scheduleIn(.main, forMode: .default)`), so SwiftUI sees mutations
/// immediately via `@Observable`.
@Observable
final class NetworkDiscovery: NSObject {

    private(set) var hosts: [DiscoveredHost] = []
    private(set) var isBrowsing = false

    @ObservationIgnored private var browser: NWBrowser?
    /// Keeps a strong reference to each in-flight NetService, keyed by the
    /// same stable id we use in `hosts`. Needed because NetService
    /// resolution is delegate-based and the service must outlive the call.
    @ObservationIgnored private var resolvers: [String: NetService] = [:]

    // MARK: - Lifecycle ---------------------------------------------------

    /// Starts a Bonjour browse for `_ssh._tcp`. Safe to call repeatedly –
    /// a second call replaces the running browser and clears the list.
    func start() {
        stop()
        hosts = []
        isBrowsing = true

        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(
            for: .bonjour(type: "_ssh._tcp.", domain: nil),
            using: params
        )

        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.isBrowsing = false
            default:
                break
            }
        }

        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.apply(results)
        }

        b.start(queue: .main)
        browser = b
    }

    /// Stops the browse and tears down any in-flight resolvers. The list
    /// of already-found hosts is retained so the UI can keep showing
    /// them until the sheet closes.
    func stop() {
        browser?.cancel()
        browser = nil
        for (_, ns) in resolvers { ns.stop() }
        resolvers.removeAll()
        isBrowsing = false
    }

    // MARK: - Private -----------------------------------------------------

    private func apply(_ results: Set<NWBrowser.Result>) {
        var next: [DiscoveredHost] = []
        var seenIds = Set<String>()

        for r in results {
            guard case let .service(name, type, domain, _) = r.endpoint else {
                continue
            }
            let id = "\(name).\(type).\(domain)"
            seenIds.insert(id)

            // Preserve anything we already resolved for this host.
            let existing = hosts.first { $0.id == id }
            next.append(DiscoveredHost(
                id: id,
                name: name,
                hostname: existing?.hostname,
                address: existing?.address,
                port: existing?.port ?? 22
            ))

            // Kick off resolution the first time we see this service.
            if resolvers[id] == nil {
                resolve(name: name, type: type, domain: domain, seedId: id)
            }
        }

        // Stop resolvers for services that have vanished.
        for (id, ns) in resolvers where !seenIds.contains(id) {
            ns.stop()
            resolvers.removeValue(forKey: id)
        }

        hosts = next.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolves a discovered service to a hostname + addresses via
    /// `NetService`. `NWConnection` would give us an IP only, which
    /// defeats the point of Bonjour.
    private func resolve(name: String, type: String, domain: String, seedId id: String) {
        let ns = NetService(domain: domain, type: type, name: name)
        ns.delegate = self
        ns.schedule(in: .main, forMode: .default)
        ns.resolve(withTimeout: 5.0)
        resolvers[id] = ns
    }

    private func id(for sender: NetService) -> String? {
        resolvers.first { $0.value === sender }?.key
    }

    fileprivate func updateHost(
        id: String,
        hostname: String?,
        address: String?,
        port: Int?
    ) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        var h = hosts[idx]
        if let hostname, !hostname.isEmpty { h.hostname = hostname }
        if let address,  !address.isEmpty  { h.address  = address  }
        if let port,     port > 0          { h.port     = port     }
        hosts[idx] = h
    }
}

// MARK: - NetServiceDelegate ----------------------------------------------

extension NetworkDiscovery: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let id = id(for: sender) else { return }

        // .hostName is typically "macbook-pro.local." – trim the trailing
        // dot, which some resolvers choke on.
        let hostname = sender.hostName.map {
            $0.hasSuffix(".") ? String($0.dropLast()) : $0
        }

        let address = sender.addresses?
            .lazy
            .compactMap(Self.ipString(from:))
            .first

        updateHost(
            id: id,
            hostname: hostname,
            address: address,
            port: sender.port > 0 ? sender.port : nil
        )

        sender.stop()
        resolvers.removeValue(forKey: id)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if let id = id(for: sender) {
            resolvers.removeValue(forKey: id)
        }
        sender.stop()
    }

    /// Decodes the first address inside a NetService `sockaddr` blob into
    /// a printable IPv4/IPv6 string. Used only for the subtitle; the
    /// Host field itself prefers `.hostName`.
    private static func ipString(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sa,
                socklen_t(data.count),
                &buf,
                socklen_t(buf.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            return rc == 0 ? String(cString: buf) : nil
        }
    }
}
