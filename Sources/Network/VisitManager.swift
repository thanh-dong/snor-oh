import Foundation

/// Handles sending visits to peers and tracking our "away" state.
/// Visit protocol: POST to peer's /visit endpoint, wait duration, POST /visit-end.
final class VisitManager {
    private let sessionManager: SessionManager
    private let discovery: PeerDiscovery
    private var returnWork: DispatchWorkItem?

    static let maxVisitDuration: UInt64 = 60

    init(sessionManager: SessionManager, discovery: PeerDiscovery) {
        self.sessionManager = sessionManager
        self.discovery = discovery
    }

    /// Visit a peer. Returns error string on failure, nil on success.
    func visit(peerInstanceName: String) -> String? {
        guard sessionManager.visiting == nil else {
            print("[visit] already visiting someone")
            return "Already visiting someone"
        }

        guard let peer = sessionManager.peers[peerInstanceName] else {
            print("[visit] peer not found: \(peerInstanceName)")
            return "Peer not found"
        }

        let ourInstanceName = discovery.instanceName
        let nickname = sessionManager.nickname
        let pet = sessionManager.pet
        let duration = min(UInt64(15), Self.maxVisitDuration)
        let targetURL = "http://\(peer.ip):\(peer.port)/visit"

        print("[visit] visiting \(peer.nickname) at \(targetURL)")

        // Mark as visiting
        sessionManager.setVisiting(peerInstanceName)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let payload: [String: Any] = [
                "instance_name": ourInstanceName,
                "pet": pet,
                "nickname": nickname,
                "duration_secs": duration
            ]

            guard self.sendPost(to: targetURL, payload: payload) else {
                print("[visit] POST failed to \(targetURL)")
                DispatchQueue.main.async { self.sessionManager.clearVisiting() }
                return
            }

            print("[visit] visit started, returning in \(duration)s")

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let endURL = "http://\(peer.ip):\(peer.port)/visit-end"
                let endPayload: [String: Any] = [
                    "instance_name": ourInstanceName,
                    "nickname": nickname
                ]
                self.sendPost(to: endURL, payload: endPayload)
                print("[visit] visit ended")
                DispatchQueue.main.async {
                    self.sessionManager.clearVisiting()
                }
            }
            DispatchQueue.main.async { self.returnWork = work }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Double(duration),
                execute: work
            )
        }

        return nil
    }

    func cancelVisit() {
        returnWork?.cancel()
        returnWork = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let visiting = self.sessionManager.visiting,
               let peer = self.sessionManager.peers[visiting] {
                let endPayload: [String: Any] = [
                    "instance_name": self.discovery.instanceName,
                    "nickname": self.sessionManager.nickname
                ]
                self.sendPost(to: "http://\(peer.ip):\(peer.port)/visit-end", payload: endPayload)
            }
            DispatchQueue.main.async {
                self.sessionManager.clearVisiting()
            }
        }
    }

    // MARK: - Private

    @discardableResult
    private func sendPost(to urlString: String, payload: [String: Any]) -> Bool {
        // Clean up IPv6 link-local addresses — strip zone ID (e.g. %en0) which
        // URLSession doesn't handle
        let cleanURL = urlString.replacingOccurrences(
            of: #"%[a-zA-Z0-9]+"#,
            with: "",
            options: .regularExpression
        )

        guard let url = URL(string: cleanURL) else {
            print("[visit] invalid URL: \(cleanURL)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[visit] failed to serialize payload")
            return false
        }
        request.httpBody = body

        var success = false
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    success = true
                } else {
                    print("[visit] HTTP \(http.statusCode) from \(cleanURL)")
                }
            } else if let error {
                print("[visit] request to \(cleanURL) failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }.resume()

        let result = semaphore.wait(timeout: .now() + 10)
        if result == .timedOut {
            print("[visit] request to \(cleanURL) timed out")
            return false
        }
        return success
    }
}
