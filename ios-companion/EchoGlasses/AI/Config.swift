import Foundation
import Security

/// Same settings the ECHO webapp uses: an OpenAI-compatible chat endpoint + model + key.
struct EchoConfig: Codable, Equatable {
    var url = ""
    var model = ""
    var visionModel = ""     // optional; falls back to `model`. Must accept images.
    var name = ""
    var key = ""             // kept in Keychain, never in UserDefaults

    enum CodingKeys: String, CodingKey { case url, model, visionModel, name }

    var isComplete: Bool { !url.isEmpty && !model.isEmpty && !key.isEmpty }
    var effectiveVisionModel: String { visionModel.isEmpty ? model : visionModel }
}

/// JSON copied by the webapp's "Koppel bril-app" button.
struct PairPayload: Decodable {
    let echo: Int
    let url: String
    let model: String
    let key: String
    let name: String?
}

struct BridgeConfig: Equatable {
    var address = ""   // full address incl. token, e.g. http://192.168.1.20:8765/#t=abc

    var parsed: (base: URL, token: String)? {
        var c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let frag = c?.fragment, frag.hasPrefix("t=") else { return nil }
        let token = String(frag.dropFirst(2))
        c?.fragment = nil; c?.query = nil; c?.path = ""
        guard let url = c?.url, url.host != nil else { return nil }
        return (url, token)
    }
}

enum Keychain {
    private static let service = "echo.glasses"
    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: EchoConfig { didSet { saveConfig() } }
    @Published var bridgeAddress: String { didSet { Keychain.set(bridgeAddress, account: "bridge") } }
    @Published var mode: GlassesMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    @Published var glassesMic: Bool { didSet { UserDefaults.standard.set(glassesMic, forKey: "glassesMic") } }
    @Published var jarvisVoice: Bool { didSet { UserDefaults.standard.set(jarvisVoice, forKey: "jarvisVoice") } }
    @Published var clapOn: Bool { didSet { UserDefaults.standard.set(clapOn, forKey: "clapOn") } }
    @Published var clapSensitivity: Double { didSet { UserDefaults.standard.set(clapSensitivity, forKey: "clapSens") } }

    init() {
        var c = EchoConfig()
        if let d = UserDefaults.standard.data(forKey: "config"),
           let decoded = try? JSONDecoder().decode(EchoConfig.self, from: d) { c = decoded }
        c.key = Keychain.get(account: "apikey")
        config = c
        bridgeAddress = Keychain.get(account: "bridge")
        mode = GlassesMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .simulated
        glassesMic = UserDefaults.standard.bool(forKey: "glassesMic")
        jarvisVoice = UserDefaults.standard.object(forKey: "jarvisVoice") as? Bool ?? true
        clapOn = UserDefaults.standard.bool(forKey: "clapOn")
        clapSensitivity = UserDefaults.standard.object(forKey: "clapSens") as? Double ?? 6
    }

    private func saveConfig() {
        if let d = try? JSONEncoder().encode(config) { UserDefaults.standard.set(d, forKey: "config") }
        Keychain.set(config.key, account: "apikey")
    }

    /// Accepts the JSON from the webapp's "Koppel bril-app" button.
    func applyPairing(_ text: String) throws {
        let p = try JSONDecoder().decode(PairPayload.self, from: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        guard p.echo == 1 else { throw EchoError.badPairing }
        var c = config
        c.url = p.url; c.model = p.model; c.key = p.key
        if let n = p.name, !n.isEmpty { c.name = n }
        config = c
    }

    var bridge: BridgeConfig { BridgeConfig(address: bridgeAddress) }
}
