import Foundation

public enum DictatorError: Error, Equatable, Sendable {
    case unauthorized(String)
    case insufficientCredits(String)
    case unavailable(String)
    case rejected(status: Int, message: String)
    case invalidResponse
    case invalidAudio
    case notReady
    case readinessTimeout
    case connectionClosed
    case insecureURL
}

public enum Tier: String, Codable, Sendable { case fast = "FAST", quality = "QUALITY", hybrid = "HYBRID" }
public enum AuthenticationResult: Sendable { case signedIn, requiresSecondFactor }

public struct Account: Decodable, Sendable {
    public let userId: String
    public let organizationId: String
    public let availableCredits: Double
    public let reservedCredits: Double
    public let purchaseChannel: String
    public let sessionExpiresAt: Int64
}
public struct Organization: Decodable, Sendable {
    public let id: String
    public let name: String
}
public struct LanguagePair: Codable, Sendable { public let source: String; public let target: String }
public struct TranslationPolicy: Decodable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let pairs: [LanguagePair]
    public let textCreditsPer1000: Double?
    public let transcriptMode: String
    public let transcriptCreditsPer1000: Double?
    public let maxInputChars: Int
    public let maxOutputChars: Int
    public let timeoutSeconds: Int
}
public struct Capabilities: Decodable, Sendable {
    public let gatewayUrl: URL
    public let languages: [String]
    public let tiers: [Tier]
    public let creditsPerMinute: [String: Double]
    public let maxAudioSeconds: Double
    public let maxUploadBytes: Int
    public let readyTimeoutSeconds: Double
    public let translation: TranslationPolicy
    public let purchaseChannel: String
}
public struct TranscriptionOptions: Sendable {
    public var language: String?
    public var tier: Tier
    public var targetLanguage: String?
    public var filename: String
    public init(language: String? = nil, tier: Tier = .quality, targetLanguage: String? = nil, filename: String = "audio.wav") {
        self.language = language; self.tier = tier; self.targetLanguage = targetLanguage; self.filename = filename
    }
}
public struct TranscriptionResult: Decodable, Sendable {
    public let text: String
    public let engine: String
    public let audioSeconds: Double
    public let degraded: Bool
    public let translation: String?
    public let translationError: String?
    enum CodingKeys: String, CodingKey {
        case text, engine, degraded, translation
        case audioSeconds = "audio_s", translationError = "translation_error"
    }
}
public struct TranslationResult: Decodable, Sendable {
    public let translation: String
    public let targetLanguage: String
    public let credits: Double?
    public let operationId: String?
    public let policyVersion: Int?
    enum CodingKeys: String, CodingKey {
        case translation, credits
        case targetLanguage = "target_language", operationId = "operation_id", policyVersion = "policy_version"
    }
}
public struct StreamOptions: Sendable {
    public var language: String
    public var tier: Tier
    public var targetLanguage: String?
    public var readyTimeoutSeconds: Double
    public init(language: String, tier: Tier = .quality, targetLanguage: String? = nil, readyTimeoutSeconds: Double = 240) {
        self.language = language; self.tier = tier; self.targetLanguage = targetLanguage; self.readyTimeoutSeconds = readyTimeoutSeconds
    }
}
public struct StreamEvent: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case ready, partial, final, fast, warning, error, translation, done
        case translationError = "translation_error"
    }
    public let type: Kind
    public let segment: Int?
    public let text: String?
    public let translation: String?
    public let detail: String?
    public let code: Int?
    public let engine: String?
    public let credits: Double?
    public let audioSeconds: Double?
    public let startSample: Int?
    public let endSample: Int?
    public let maxAudioSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case type, segment, text, translation, detail, code, engine, credits, maxAudioSeconds
        case audioSeconds = "audio_s", startSample = "start_sample", endSample = "end_sample"
    }
}
public struct AppleChallenge: Decodable, Sendable {
    public let id: String
    public let nonce: String
    public let expiresAt: Int64
}
