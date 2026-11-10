import Foundation

struct BridgeState: Decodable {
    let tvs: [String]
    let apps: [String]
    let tvApps: [String]?
    let windows: Bool?
}

enum BridgeError: LocalizedError {
    case notConfigured
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "ECHO Bridge is niet ingesteld. Plak het bridge-adres (met #t=...) in Instellingen."
        case .failed(let m): return "Bridge: \(m)"
        }
    }
}

/// Talks to your existing echo_bridge.py (unchanged). Plain http on the LAN is allowed by the
/// app's NSAllowsLocalNetworking setting — the iPhone must be on the same Wi-Fi as the PC.
struct BridgeClient {
    let base: URL
    let token: String

    init(config: BridgeConfig) throws {
        guard let p = config.parsed else { throw BridgeError.notConfigured }
        base = p.base; token = p.token
    }

    func state() async throws -> BridgeState {
        let data = try await call("api/state", body: nil)
        return try JSONDecoder().decode(BridgeState.self, from: data)
    }

    func tvKey(tv: String, key: String) async throws { _ = try await call("api/tv", body: ["tv": tv, "key": key]) }

    func tvVolume(tv: String, change: VolumeChange) async throws -> String {
        switch change {
        case .up(let n):
            _ = try await call("api/tv", body: ["tv": tv, "key": "KEY_VOLUP", "count": n]); return "Harder."
        case .down(let n):
            _ = try await call("api/tv", body: ["tv": tv, "key": "KEY_VOLDOWN", "count": n]); return "Zachter."
        case .set(let n):
            _ = try await call("api/tv/volume", body: ["tv": tv, "level": n], timeout: 40); return "Volume \(n)."
        }
    }

    func pcVolume(_ change: VolumeChange) async throws -> String {
        switch change {
        case .up(let n): try await pc("volume_up:\(n)"); return "Harder."
        case .down(let n): try await pc("volume_down:\(n)"); return "Zachter."
        case .set(let n): try await pc("volume_set:\(n)"); return "Volume \(n)."
        }
    }
    func tvWake(tv: String) async throws { _ = try await call("api/tv/wake", body: ["tv": tv]) }
    func tvApp(tv: String, app: String) async throws { _ = try await call("api/tv/app", body: ["tv": tv, "app": app]) }
    func pc(_ action: String) async throws { _ = try await call("api/pc", body: ["action": action]) }
    func openApp(_ name: String) async throws { _ = try await call("api/pc", body: ["action": "open:\(name)"]) }
    func openEufyCamera() async throws { _ = try await call("api/eufy/open", body: [:], timeout: 20) }

    struct AlertBatch: Decodable { let alerts: [String]; let last: Int }

    /// Security alerts from the bridge (since = -1 on the first poll just returns the current position).
    func alerts(since: Int) async throws -> AlertBatch {
        let data = try await call("api/alerts?since=\(since)", body: nil)
        return try JSONDecoder().decode(AlertBatch.self, from: data)
    }

    @discardableResult
    private func call(_ path: String, body: [String: Any]?, timeout: TimeInterval = 12) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BridgeError.failed(msg ?? "HTTP \(code)")
        }
        return data
    }
}
