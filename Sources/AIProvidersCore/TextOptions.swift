import Foundation

public enum AIReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none, instant, minimal, low, medium, high, xhigh, max
}

/// Catalog capabilities, not a vendor/model-name allowlist. An absent value
/// means unknown; an empty supported list means no effort selector is exposed.
public struct AIReasoningCapabilities: Codable, Equatable, Sendable {
    public var supportedEfforts: [AIReasoningEffort]
    public var mandatory: Bool
    public init(supportedEfforts: [AIReasoningEffort], mandatory: Bool = false) {
        self.supportedEfforts = supportedEfforts; self.mandatory = mandatory
    }
    public var availableEfforts: [AIReasoningEffort] {
        AIReasoningEffort.allCases.filter { supportedEfforts.contains($0) && (!mandatory || $0 != .none) }
    }
    public var fastestEffort: AIReasoningEffort? { availableEfforts.first }
}

public enum AIRoutingSort: String, Codable, CaseIterable, Sendable { case latency, throughput, price }

/// OpenRouter server preferences. An empty `only` permits all servers; disabling
/// fallbacks never overrides an explicit server allowlist.
public struct AIProviderRouting: Codable, Equatable, Sendable {
    public var sort: AIRoutingSort?
    public var only: [String]
    public var allowFallbacks: Bool
    public init(sort: AIRoutingSort? = nil, only: [String] = [], allowFallbacks: Bool = true) {
        self.sort = sort; self.only = only; self.allowFallbacks = allowFallbacks
    }
    public var isDefault: Bool { sort == nil && only.isEmpty && allowFallbacks }
    public func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.:+")
        guard only.count <= 16, Set(only).count == only.count,
              only.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw AIProviderError.invalidConfiguration
        }
    }
}

/// Saved per operation/model. Nil effort preserves the caller's existing
/// automatic behavior. Credentials and provider URLs never belong here.
public struct AITextOptions: Codable, Equatable, Sendable {
    public var reasoningEffort: AIReasoningEffort?
    public var routing: AIProviderRouting?
    public init(reasoningEffort: AIReasoningEffort? = nil, routing: AIProviderRouting? = nil) {
        self.reasoningEffort = reasoningEffort; self.routing = routing
    }
    public var isDefault: Bool { reasoningEffort == nil && (routing == nil || routing?.isDefault == true) }
}
