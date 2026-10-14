import Foundation
import AIProvidersCore
import DictatorCore

public struct DictatorProvider: AISpeechProviding, AITranslationProviding {
    private let client: DictatorClient
    private let http: AIHTTP
    public init(endpoint: URL, token: String, http: AIHTTP = AIHTTP()) throws {
        try AIEndpoint.validate(endpoint)
        self.http = http
        client = try DictatorClient(gatewayURL: endpoint, apiKey: token, session: http.session)
    }
    public static let profiles: [AIModel] = ["fast", "hybrid", "quality"].map {
        .init(id: $0, name: "Dictator · \($0.capitalized)", kind: .speechProfile, operations: [.transcription, .streamingTranscription])
    }
    public static func canonicalEndpoint(_ endpoint: URL) throws -> URL { try DictatorClient.canonicalGatewayURL(endpoint) }
    public func checkConnection() async throws {
        do { try await client.checkConnection() }
        catch { throw Self.publicError(error) }
    }
    private func tier(_ model: String) throws -> Tier {
        guard let tier = Tier(rawValue: model.uppercased()) else { throw AIProviderError.unsupported }; return tier
    }
    public func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String {
        do {
            let result = try await client.transcribe(audio: audio, options: .init(language: request.language == "auto" ? nil : request.language, tier: tier(request.model)))
            guard !result.degraded || request.model == "fast" else { throw AIProviderError.degradedRecognition }
            return result.text
        }
        catch { throw Self.publicError(error) }
    }
    public func translate(_ text: String, from: String, to: String, model: String) async throws -> String {
        do { return try await client.translate(text: text, from: from, to: to).translation }
        catch { throw Self.publicError(error) }
    }
    public func stream(_ request: AISpeechRequest) async throws -> any AISpeechStreaming {
        guard request.sampleRate == 16_000 else { throw AIProviderError.unsupported }
        let socket = try await client.stream(options: .init(language: request.language, tier: tier(request.model)))
        return DictatorSpeechStream(socket: socket, http: http)
    }
    private static func publicError(_ error: Error) -> Error {
        guard let error = error as? DictatorError else { return error }
        switch error {
        case .unauthorized: return AIProviderError.refused(401)
        case .insufficientCredits: return AIProviderError.refused(402)
        case .unavailable: return AIProviderError.refused(503)
        case .rejected(let status, _): return AIProviderError.refused(status)
        default: return AIProviderError.invalidResponse
        }
    }
}
private final class DictatorSpeechStream: AISpeechStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AISpeechEvent, Error>
    private let socket: DictatorStream
    private let http: AIHTTP
    private let reader: Task<Void, Never>
    init(socket: DictatorStream, http: AIHTTP) {
        self.socket = socket
        self.http = http
        let pair = AsyncThrowingStream<AISpeechEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = pair.stream
        reader = Task {
            var completed = false
            do {
                for try await event in socket.events {
                    try Task.checkCancellation()
                    let value: AISpeechEvent?
                    switch event.type {
                    case .partial, .fast: value = .partial(event.text ?? "")
                    case .final:
                        guard let segment = event.segment, segment >= 0, let text = event.text,
                              let start = event.startSample, let end = event.endSample, start >= 0, end > start else { throw AIProviderError.invalidResponse }
                        value = .final(.init(id: UInt64(segment) + 1, text: text, startSample: start, endSample: end))
                    case .done: value = .completed; completed = true
                    case .error: throw AIProviderError.refused(event.code ?? 503)
                    default: value = nil
                    }
                    if let value, case .dropped = pair.continuation.yield(value) { throw AIProviderError.outputLimit }
                }
                guard completed else { throw AIProviderError.interrupted }; pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
    }
    deinit { reader.cancel(); let socket = socket; Task { await socket.close() } }
    func send(_ pcm16: Data) async throws { try await socket.sendAudio(pcm16) }
    func finish() async throws { try await socket.stop() }
    func cancel() async { reader.cancel(); await socket.close() }
}
