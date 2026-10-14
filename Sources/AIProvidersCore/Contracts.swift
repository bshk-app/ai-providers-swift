import Foundation

public enum AIAuthMode: String, Codable, Sendable { case apiKey, chatGPTPlan }
public enum AIModelKind: String, Codable, Sendable { case text, speech, translation, speechProfile }
public enum AIOperation: String, Codable, CaseIterable, Sendable { case textEditing, transcription, streamingTranscription, translation }
/// Persistable metadata only. Credentials belong to the caller's vault namespace.
public struct AIConnection: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: String
    public var name: String
    public var endpoint: URL
    public var auth: AIAuthMode
    public init(id: UUID = UUID(), provider: String, name: String, endpoint: URL, auth: AIAuthMode = .apiKey) {
        self.id = id; self.provider = provider; self.name = name; self.endpoint = endpoint; self.auth = auth
    }
}
public struct AIModel: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: AIModelKind
    public var operations: Set<AIOperation>
    public init(id: String, name: String, kind: AIModelKind, operations: Set<AIOperation>) {
        self.id = id; self.name = name; self.kind = kind; self.operations = operations
    }
}
public struct AISelection: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let modelID: String
    public init(connectionID: UUID, modelID: String) { self.connectionID = connectionID; self.modelID = modelID }
}
public struct AITextRequest: Sendable {
    public let model: String
    public let instructions: String
    public let text: String
    public init(model: String, instructions: String, text: String) { self.model = model; self.instructions = instructions; self.text = text }
}
public protocol AITextProviding: Sendable {
    func models() async throws -> [AIModel]
    func generate(_ request: AITextRequest) async throws -> String
}
public struct AISpeechRequest: Sendable {
    public let model: String
    public let language: String
    public let sampleRate: Int
    public init(model: String, language: String, sampleRate: Int = 16_000) { self.model = model; self.language = language; self.sampleRate = sampleRate }
}
public struct AISpeechSegment: Sendable, Equatable {
    public let id: UInt64
    public let text: String
    public let startSample: Int
    public let endSample: Int
    public init(id: UInt64, text: String, startSample: Int, endSample: Int) { self.id = id; self.text = text; self.startSample = startSample; self.endSample = endSample }
}
public enum AISpeechEvent: Sendable { case partial(String), final(AISpeechSegment), completed }
public protocol AISpeechStreaming: Sendable {
    var events: AsyncThrowingStream<AISpeechEvent, Error> { get }
    func send(_ pcm16: Data) async throws
    func finish() async throws
    func cancel() async
}
public protocol AISpeechProviding: Sendable {
    func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String
    func stream(_ request: AISpeechRequest) async throws -> any AISpeechStreaming
}
public extension AISpeechProviding {
    func stream(_ request: AISpeechRequest) async throws -> any AISpeechStreaming { throw AIProviderError.unsupported }
}
public protocol AITranslationProviding: Sendable {
    func translate(_ text: String, from: String, to: String, model: String) async throws -> String
}
public enum AIProviderError: Error, LocalizedError, Equatable {
    case insecureEndpoint, missingCredential, unsupported, invalidResponse, interrupted, outputLimit
    case degradedRecognition
    case refused(Int)
    public var errorDescription: String? {
        switch self {
        case .insecureEndpoint: return "Use a secure HTTPS endpoint without credentials or query parameters."
        case .missingCredential: return "Reconnect this provider or add your API key."
        case .unsupported: return "This connection does not support the selected operation."
        case .invalidResponse: return "The provider returned an invalid response."
        case .interrupted: return "Processing was interrupted before completion. Your original text has been kept."
        case .outputLimit: return "The provider response exceeded its size limit."
        case .degradedRecognition: return "The provider's accurate model was unavailable. The live transcript has been kept."
        case .refused(let status):
            if status == 401 || status == 403 { return "Access denied. Check this connection and model permissions." }
            if status == 402 || status == 429 { return "The provider's usage or balance limit was reached." }
            return "The provider could not complete the request (HTTP \(status))."
        }
    }
}
public enum AIEndpoint {
    public static func validate(_ url: URL) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw AIProviderError.insecureEndpoint }
    }
    public static func url(_ base: URL, path: String) throws -> URL {
        try validate(base)
        return base.appendingPathComponent(path)
    }
}
