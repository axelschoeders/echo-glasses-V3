import Foundation
import UIKit

enum EchoError: LocalizedError {
    case notConfigured, badPairing, badResponse, searchUnsupported
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "ECHO is nog niet gekoppeld. Open Instellingen en plak de koppelcode."
        case .badPairing: return "Dit is geen geldige ECHO-koppelcode."
        case .badResponse: return "Onverwacht antwoord van de AI."
        case .searchUnsupported: return "Zoeken op internet werkt alleen met Gemini of Groq. Pas je AI-instellingen aan."
        case .http(let code, let msg): return "AI-fout \(code): \(msg)"
        }
    }
}

struct ChatTurn { let role: String; let content: String }

/// Talks to the SAME OpenAI-compatible endpoint the ECHO webapp uses. No second assistant.
struct EchoClient {
    let cfg: EchoConfig

    private var persona: String {
        let who = cfg.name.isEmpty ? "de gebruiker" : cfg.name
        return "Je bent Echo, een persoonlijke spraakassistent in de stijl van Jarvis, voor \(who). "
            + "Antwoord in het Nederlands, kort (maximaal 3 zinnen), als gesproken taal, zonder opmaak of emoji."
    }

    func ask(_ text: String, history: [ChatTurn]) async throws -> String {
        var msgs: [[String: Any]] = [["role": "system", "content": persona]]
        for t in history { msgs.append(["role": t.role, "content": t.content]) }
        msgs.append(["role": "user", "content": text])
        return try await send(model: cfg.model, messages: msgs)
    }

    func describe(jpeg: Data, prompt: String) async throws -> String {
        let system = persona + " De afbeelding komt van de camera van de bril van de gebruiker; beschrijf wat je ziet vanuit zijn standpunt."
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
        ]
        let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": content]]
        return try await send(model: cfg.effectiveVisionModel, messages: msgs)
    }

    // MARK: web search (Gemini = Google Search grounding, Groq = compound web search)

    func search(_ query: String) async throws -> String {
        guard cfg.isComplete, let url = URL(string: cfg.url) else { throw EchoError.notConfigured }
        let host = url.host ?? ""
        let today = Date().formatted(date: .complete, time: .omitted)
        let system = persona + " Je mag het internet gebruiken voor actuele informatie. Vandaag is het \(today). Noem geen web-adressen."
        if host.contains("generativelanguage.googleapis.com") {
            return try await geminiSearch(query, system: system)
        }
        if host.contains("groq.com") {
            let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": query]]
            return try await send(model: "groq/compound-mini", messages: msgs)
        }
        throw EchoError.searchUnsupported
    }

    /// Gemini's OpenAI-compatible endpoint has no Google Search tool, so this uses the native endpoint.
    private func geminiSearch(_ query: String, system: String) async throws -> String {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(cfg.model):generateContent"
        guard let url = URL(string: endpoint) else { throw EchoError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": query]]]],
            "tools": [["google_search": [String: Any]()]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(String(data: data, encoding: .utf8)?.prefix(160) ?? "")
            throw EchoError.http(code, "\(msg) [zoeken, model: \(cfg.model)]")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cand = (obj["candidates"] as? [[String: Any]])?.first,
              let content = cand["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw EchoError.badResponse }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw EchoError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func askRaw(system: String, user: String, maxTokens: Int = 4000) async throws -> String {
        let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": user]]
        return try await send(model: cfg.model, messages: msgs, maxTokens: maxTokens)
    }

    private func send(model: String, messages: [[String: Any]], maxTokens: Int = 600) async throws -> String {
        guard cfg.isComplete, let url = URL(string: cfg.url) else { throw EchoError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "max_tokens": maxTokens])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let body = String(String(data: data, encoding: .utf8)?.prefix(160) ?? "")
            throw EchoError.http(code, "\(body) [model: \(model), server: \(url.host ?? "?")]")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String else { throw EchoError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension UIImage {
    /// Downscale + compress before upload (keeps requests small and fast).
    func jpegForAI(maxSide: CGFloat = 1024, quality: CGFloat = 0.7) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
        return img.jpegData(compressionQuality: quality)
    }
}
