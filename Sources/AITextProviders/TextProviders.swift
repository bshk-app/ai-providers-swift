import Foundation
import AIProvidersCore

public struct OpenAITextProvider: AITextProviding {
    public let endpoint: URL
    public let auth: AIAuthMode
    private let credential: @Sendable () async throws -> String
    private let http: AIHTTP
    public init(endpoint: URL = URL(string: "https://api.openai.com/v1")!, auth: AIAuthMode = .apiKey,
                http: AIHTTP = AIHTTP(), credential: @escaping @Sendable () async throws -> String) {
        self.endpoint = endpoint; self.auth = auth; self.http = http; self.credential = credential
    }
    public func models() async throws -> [AIModel] {
        try validateAuthEndpoint()
        let json = try await http.json(AIHTTP.request(AIEndpoint.url(endpoint, path: "models"), token: credential()))
        if auth == .chatGPTPlan {
            guard let items = json["models"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
            return items.compactMap { value in
                guard value["visibility"] as? String == "list", let id = value["slug"] as? String else { return nil }
                return AIModel(id: id, name: value["display_name"] as? String ?? id, kind: .text, operations: [.textEditing, .translation])
            }
        }
        guard let items = json["data"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
        // The API key catalog includes image/audio/embedding models. Only
        // recognizable text families enter the text picker, never the ASR picker.
        return items.compactMap { value in
            guard let id = value["id"] as? String,
                  id.hasPrefix("gpt-") || id.range(of: #"^o[1-9]"#, options: .regularExpression) != nil,
                  !["audio", "transcrib", "realtime", "live", "image", "tts", "search"].contains(where: id.contains) else { return nil }
            return AIModel(id: id, name: id, kind: .text, operations: [.textEditing, .translation])
        }.sorted { $0.id < $1.id }
    }
    public func generate(_ request: AITextRequest) async throws -> String {
        try validateAuthEndpoint()
        // This body is supported by both API keys and the ChatGPT plan route.
        // Never add preview-unsupported sampling/token fields to the plan body.
        let body: [String: Any] = ["model": request.model, "instructions": request.instructions,
            "input": [["role": "user", "content": request.text]], "store": false, "stream": true]
        let query = try await AIHTTP.request(AIEndpoint.url(endpoint, path: "responses"), token: credential(), method: "POST", json: body)
        let (bytes, response) = try await http.session.bytes(for: query)
        try AIHTTP.check(response)
        var parser = ResponsesStreamParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try parser.accept(line)
        }
        return try parser.result()
    }
    private func validateAuthEndpoint() throws {
        if auth == .chatGPTPlan, endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "https://api.openai.com/v1" { throw AIProviderError.unsupported }
    }
}

/// Consumes complete SSE data frames. Partial output is never a successful edit.
public struct ResponsesStreamParser {
    private var data: [String] = []
    private var output = ""
    private var completed = false
    public init() {}
    public mutating func accept(_ line: String) throws {
        if line.isEmpty { try flush(); return }
        if line.hasPrefix("data:") { data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        guard data.reduce(0, { $0 + $1.count }) < 1_048_576 else { throw AIProviderError.outputLimit }
    }
    private mutating func flush() throws {
        guard !data.isEmpty else { return }; defer { data = [] }
        let payload = data.joined(separator: "\n")
        if payload == "[DONE]" { return }
        guard let json = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any], let type = json["type"] as? String else { throw AIProviderError.invalidResponse }
        if type == "response.output_text.delta" {
            output += json["delta"] as? String ?? ""
            guard output.count < 1_048_576 else { throw AIProviderError.outputLimit }
        } else if ["response.failed", "response.incomplete", "error", "response.refusal.done"].contains(type) { throw AIProviderError.interrupted }
        else if type == "response.completed" {
            guard let response = json["response"] as? [String: Any], response["status"] as? String == "completed" else { throw AIProviderError.interrupted }
            completed = true
            if let items = response["output"] as? [[String: Any]] {
                let text = items.flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { output = text }
            }
        }
    }
    public mutating func result() throws -> String {
        try flush()
        guard completed, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.interrupted }
        return output
    }
}

public struct AnthropicTextProvider: AITextProviding {
    private let endpoint: URL
    private let credential: @Sendable () async throws -> String
    private let http: AIHTTP
    public init(endpoint: URL = URL(string: "https://api.anthropic.com/v1")!, http: AIHTTP = AIHTTP(), credential: @escaping @Sendable () async throws -> String) {
        self.endpoint = endpoint; self.http = http; self.credential = credential
    }
    private func query(_ path: String, body: [String: Any]? = nil) async throws -> URLRequest {
        var request = try await AIHTTP.request(AIEndpoint.url(endpoint, path: path), token: credential(), method: body == nil ? "GET" : "POST", json: body)
        let token = request.value(forHTTPHeaderField: "Authorization")!.dropFirst(7)
        request.setValue(nil, forHTTPHeaderField: "Authorization"); request.setValue(String(token), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }
    public func models() async throws -> [AIModel] {
        let response = try await http.json(query("models"))
        guard let values = response["data"] as? [[String: Any]] else { throw AIProviderError.invalidResponse }
        return values.compactMap { value in
            guard let id = value["id"] as? String else { return nil }
            return .init(id: id, name: value["display_name"] as? String ?? id, kind: .text, operations: [.textEditing, .translation])
        }
    }
    public func generate(_ request: AITextRequest) async throws -> String {
        let response = try await http.json(query("messages", body: ["model": request.model, "max_tokens": 4096,
            "system": request.instructions, "messages": [["role": "user", "content": request.text]]]))
        guard response["stop_reason"] as? String == "end_turn", let content = response["content"] as? [[String: Any]] else { throw AIProviderError.interrupted }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }; return text
    }
}
