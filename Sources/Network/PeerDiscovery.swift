import Foundation
import Network

/// Discovers peers on the local network via Bonjour (DNS-SD).
/// Advertises this instance and browses for other snor-oh instances.
///
/// Service type: `_snor-oh._tcp`
/// TXT records: `nickname`, `pet`, `port`, `hostname`
final class PeerDiscovery {
    private let sessionManager: SessionManager
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.snoroh.discovery", qos: .utility)

    private(set) var instanceName: String = ""
    private let pidSuffix = "-\(ProcessInfo.processInfo.processIdentifier)"

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func start() {
        instanceName = sessionManager.nickname + pidSuffix
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
    }

    func updateTXT() {
        instanceName = sessionManager.nickname + pidSuffix
        stop()
        start()
    }

    // MARK: - Advertising

    private func startAdvertising() {
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            print("[discovery] failed to create listener: \(error)")
            return
        }

        // Get local hostname for direct addressing (e.g. "MacBook-Pro.local")
        let hostname = ProcessInfo.processInfo.hostName

        var txtRecord = NWTXTRecord()
        txtRecord["nickname"] = sessionManager.nickname
        txtRecord["pet"] = sessionManager.pet
        txtRecord["port"] = "\(sessionManager.httpPort)"
        txtRecord["hostname"] = hostname

        listener?.service = NWListener.Service(
            name: instanceName,
            type: "_snor-oh._tcp",
            txtRecord: txtRecord
        )

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[discovery] advertising as \(self?.instanceName ?? "?"), hostname=\(hostname)")
            case .failed(let error):
                print("[discovery] listener failed: \(error)")
            case .waiting(let error):
                print("[discovery] listener waiting: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { connection in
            connection.cancel()
        }

        listener?.start(queue: queue)
    }

    // MARK: - Browsing

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_snor-oh._tcp", domain: nil)
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
            case .waiting(let error):
                print("[discovery] browser waiting: \(error) — check System Settings > Privacy > Local Network")
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
        if name == instanceName || name.hasSuffix(pidSuffix) {
            return
        }

        // Extract TXT record
        var nickname = name
        var pet = "sprite"
        var httpPort: UInt16 = 1234
        var hostname: String?

        switch result.metadata {
        case .bonjour(let txtRecord):
            var txtDict: [String: String] = [:]
            for entry in txtRecord {
                if let val = txtRecord[entry.key] {
                    txtDict[entry.key.lowercased()] = val
                }
            }
            print("[discovery] TXT for \(name): \(txtDict)")
            if let n = txtDict["nickname"], !n.isEmpty { nickname = n }
            if let p = txtDict["pet"], !p.isEmpty { pet = p }
            if let portStr = txtDict["port"], let p = UInt16(portStr) { httpPort = p }
            if let h = txtDict["hostname"], !h.isEmpty { hostname = h }
        case .none:
            print("[discovery] no metadata for \(name)")
        default:
            print("[discovery] unknown metadata type for \(name): \(result.metadata)")
        }

        // Use advertised hostname (e.g. "MacBook-Pro.local") — mDNS resolves it
        // reliably without needing manual IP resolution via NWConnection
        let host = hostname ?? "\(name).local"

        print("[discovery] found peer: \(nickname) host=\(host) port=\(httpPort)")

        let peer = PeerInfo(
            instanceName: name,
            nickname: nickname,
            pet: pet,
            host: host,
            port: httpPort
        )
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.addPeer(peer)
        }
    }

    private func handlePeerRemoved(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        print("[discovery] peer removed: \(name)")
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.removePeer(instanceName: name)
        }
    }
}
