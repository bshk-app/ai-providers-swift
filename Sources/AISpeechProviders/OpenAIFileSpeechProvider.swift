import Foundation
import AIProvidersCore

/// File ASR uses API keys; ChatGPT plan tokens cannot enter this initializer.
public struct OpenAIFileSpeechProvider: AISpeechProviding {
    private let endpoint: URL
    private let token: String
    private let http: AIHTTP
    public init(endpoint: URL, apiKey: String, http: AIHTTP = AIHTTP()) { self.endpoint = endpoint; token = apiKey; self.http = http }
    public func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String {
        guard audio.count < 25 * 1024 * 1024 else { throw AIProviderError.outputLimit }
        let boundary = "audio-\(UUID())"
        var data = Data()
        func field(_ name: String, _ value: String) {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", request.model); field("response_format", "json")
        if request.language != "auto" { field("language", request.language) }
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        data.append(audio); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var query = try AIHTTP.request(AIEndpoint.url(endpoint, path: "audio/transcriptions"), token: token, method: "POST")
        query.httpBody = data; query.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let result = try await http.json(query)
        guard let text = result["text"] as? String else { throw AIProviderError.invalidResponse }; return text
    }
}
