import Foundation
import AIProvidersCore

public enum AICompatibleService: String, Sendable { case generic, featherless, openRouter }

/// Chat Completions is a different wire contract from OpenAI Responses.
/// Catalog pages are bounded; Featherless searches its full catalog on the server.
public struct CompatibleTextProvider: AIModelCatalogProviding {
    private let endpoint: URL
    private let service: AICompatibleService
    private let credential: @Sendable () async throws -> String
    private let http: AIHTTP
    public init(endpoint: URL, service: AICompatibleService = .generic, http: AIHTTP = AIHTTP(), credential: @escaping @Sendable () async throws -> String) {
        self.endpoint = endpoint; self.service = service; self.http = http; self.credential = credential
    }

    /// These catalogs are public. Check the authenticated account endpoint separately.
    public func verifyConnection() async throws {
        switch service {
        case .featherless:
            let json = try await http.json(AIHTTP.request(AIEndpoint.url(endpoint, path: "plan"), token: credential()))
            guard json["id"] as? String != nil else { throw AIProviderError.invalidResponse }
        case .openRouter:
            let json = try await http.json(AIHTTP.request(AIEndpoint.url(endpoint, path: "key"), token: credential()))
            guard let account = json["data"] as? [String: Any], account["label"] as? String != nil else { throw AIProviderError.invalidResponse }
        case .generic: break
        }
    }

    public func modelPage(query: String = "", cursor: String? = nil) async throws -> AIModelPage {
        try Task.checkCancellation()
        var request = try await AIHTTP.request(AIEndpoint.url(endpoint, path: "models"), token: credential())
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = cursor.flatMap(Int.init) ?? 1
        guard (1...10_000).contains(page), cursor == nil || Int(cursor!) != nil else { throw AIProviderError.invalidResponse }
        if service == .featherless {
            // Only SDK-owned query names and encoded values; the configured base
            // still rejects query strings, user-info and embedded credentials.
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "page", value: String(page)), .init(name: "per_page", value: "100"),
                                     .init(name: "conversational", value: "true"), .init(name: "sort", value: "-popularity")]
            if !query.isEmpty { components.queryItems?.append(.init(name: "q", value: query)) }
            request.url = components.url
        } else if cursor != nil { throw AIProviderError.invalidResponse }
        let json = try await http.json(request)
        guard let items = json["data"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
        var seen: Set<String> = []
        var models = items.compactMap(Self.textModel).filter { seen.insert($0.id).inserted }
        if service != .featherless, !query.isEmpty {
            models = models.filter { $0.id.localizedStandardContains(query) || $0.name.localizedStandardContains(query) }
        }
        if service == .featherless {
            let pagination = json["pagination"] as? [String: Any]
            if let returnedPage = pagination?["current_page"] as? Int, returnedPage != page { throw AIProviderError.invalidResponse }
            let total = pagination?["total_items"] as? Int ?? json["total"] as? Int
            let pages = pagination?["total_pages"] as? Int
            let more = pages.map { page < $0 } ?? false
            return .init(models: models, nextCursor: more ? String(page + 1) : nil, total: total)
        }
        return .init(models: models, total: models.count)
    }

    private static func textModel(_ item: [String: Any]) -> AIModel? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        let architecture = item["architecture"] as? [String: Any]
        let inputs = architecture?["input_modalities"] as? [String] ?? item["input_modalities"] as? [String]
        let outputs = architecture?["output_modalities"] as? [String] ?? item["output_modalities"] as? [String]
        if let inputs, !inputs.contains("text") { return nil }
        if let outputs, !outputs.contains("text") { return nil }
        if let tasks = item["tasks"] as? [String], !tasks.isEmpty,
           !tasks.contains(where: { ["text-generation", "conversational", "chat", "text2text-generation"].contains($0) }) { return nil }
        // A bare OpenAI-compatible list has no capability metadata. Exclude
        // unambiguous standard non-chat IDs, without a GPT/vendor allowlist.
        if architecture == nil, inputs == nil, outputs == nil,
           ["text-embedding-", "tts-", "whisper-", "gpt-image-", "dall-e-"].contains(where: id.hasPrefix) { return nil }
        return .init(id: id, name: item["name"] as? String ?? id, kind: .text, operations: [.textEditing, .translation],
                     contextLength: item["context_length"] as? Int, available: item["available_on_current_plan"] as? Bool)
    }

    public func generate(_ request: AITextRequest) async throws -> String {
        let body: [String: Any] = ["model": request.model, "messages": [
            ["role": "system", "content": request.instructions], ["role": "user", "content": request.text]],
            "stream": false, "max_tokens": 4096]
        let response = try await http.json(AIHTTP.request(AIEndpoint.url(endpoint, path: "chat/completions"), token: credential(), method: "POST", json: body))
        guard response["error"] == nil,
              let choices = response["choices"] as? [[String: Any]], let choice = choices.first,
              choice["finish_reason"] as? String == "stop", let message = choice["message"] as? [String: Any],
              message["refusal"] as? String == nil else { throw AIProviderError.interrupted }
        let text: String
        if let content = message["content"] as? String { text = content }
        else if let content = message["content"] as? [[String: Any]] {
            text = content.filter { ["text", "output_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined()
        } else { throw AIProviderError.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.invalidResponse }
        return text
    }
}
