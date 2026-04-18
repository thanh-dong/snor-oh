import Foundation
import Network

/// Discovers peers on the local network via Bonjour (DNS-SD).
/// Advertises this instance and browses for other snor-oh instances.
///
/// Service type: `_snor-oh._tcp`
/// TXT records: `nickname`, `pet`, `port` (HTTP port for visits)
///
/// NWListener uses an ephemeral port (not the HTTP port) to avoid conflicts
/// with the SwiftNIO HTTP server. The actual HTTP port is advertised in the
/// TXT record so peers know where to send /visit requests.
///
/// Main-thread only for state mutations (peers dict).
final class PeerDiscovery {
    private let sessionManager: SessionManager
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.snoroh.discovery", qos: .utility)

    /// Our advertised instance name, used to filter self-discovery.
    private(set) var instanceName: String = ""

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func start() {
        instanceName = "\(sessionManager.nickname)-\(ProcessInfo.processInfo.processIdentifier)"
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
    }

    /// Update TXT records when nickname/pet changes.
    func updateTXT() {
        instanceName = "\(sessionManager.nickname)-\(ProcessInfo.processInfo.processIdentifier)"
        stop()
        start()
    }

    // MARK: - Advertising

    private func startAdvertising() {
        do {
            // Ephemeral port — avoids conflict with SwiftNIO HTTP server on :1234
            listener = try NWListener(using: .tcp)
        } catch {
            print("[discovery] failed to create listener: \(error)")
            return
        }

        // Advertise with TXT records including the HTTP port for visits
        var txtRecord = NWTXTRecord()
        txtRecord["nickname"] = sessionManager.nickname
        txtRecord["pet"] = sessionManager.pet
        txtRecord["port"] = "\(sessionManager.httpPort)"
        listener?.service = NWListener.Service(
            name: instanceName,
            type: "_snor-oh._tcp",
            txtRecord: txtRecord
        )

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[discovery] advertising as \(self?.instanceName ?? "?")")
            case .failed(let error):
                print("[discovery] listener failed: \(error)")
            default:
                break
            }
        }

        // We don't accept connections — HTTP server handles traffic
        listener?.newConnectionHandler = { connection in
            connection.cancel()
        }

        listener?.start(queue: queue)
    }

    // MARK: - Browsing

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_snor-oh._tcp", domain: "local.")
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            self?.handleBrowseChanges(results: results, changes: changes)
        }

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[discovery] browsing for peers")
            case .failed(let error):
                print("[discovery] browser failed: \(error)")
            default:
                break
            }
        }

        browser?.start(queue: queue)
    }

    private func handleBrowseChanges(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                handlePeerFound(result)
            case .removed(let result):
                handlePeerRemoved(result)
            case .changed(old: _, new: let result, flags: _):
                handlePeerFound(result)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func handlePeerFound(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        // Skip self
        guard name != instanceName else { return }

        // Extract TXT record
        var nickname = "Unknown"
        var pet = "sprite"
        var httpPort: UInt16 = 1234
        if case .bonjour(let txtRecord) = result.metadata {
            nickname = txtRecord["nickname"] ?? "Unknown"
            pet = txtRecord["pet"] ?? "sprite"
            if let portStr = txtRecord["port"], let p = UInt16(portStr) {
                httpPort = p
            }
        }

        // Resolve endpoint to get IP address (with 5s timeout to prevent leaked connections)
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        var resolved = false
        connection.stateUpdateHandler = { [weak self, name, nickname, pet, httpPort] state in
            guard let self else {
                connection.cancel()
                return
            }
            switch state {
            case .ready:
                resolved = true
                if let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint,
                   case .hostPort(let host, _) = endpoint {
                    let ip: String
                    switch host {
                    case .ipv4(let addr):
                        ip = "\(addr)"
                    case .ipv6(let addr):
                        ip = "[\(addr)]"
                    default:
                        ip = "127.0.0.1"
                    }
                    let peer = PeerInfo(
                        instanceName: name,
                        nickname: nickname,
                        pet: pet,
                        ip: ip,
                        port: httpPort  // Use TXT record port, not the NWListener port
                    )
                    DispatchQueue.main.async {
                        self.sessionManager.addPeer(peer)
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                resolved = true
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Cancel the connection after 5s if it hasn't resolved
        queue.asyncAfter(deadline: .now() + 5) {
            if !resolved {
                connection.cancel()
            }
        }
    }

    private func handlePeerRemoved(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.removePeer(instanceName: name)
        }
    }
}
