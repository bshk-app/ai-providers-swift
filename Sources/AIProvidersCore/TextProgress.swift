import Foundation

/// Numeric diagnostics only: never carries prompts, output, URLs or secrets.
public struct AITextProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case credentialsReady, responseHeaders, firstOutput, completed }
    public let stage: Stage
    /// Cumulative monotonic time since generate() began.
    public let elapsedSeconds: Double
    public let statusCode: Int?
    public let usage: AITextUsage?
    public init(stage: Stage, elapsedSeconds: Double, statusCode: Int? = nil, usage: AITextUsage? = nil) {
        self.stage = stage; self.elapsedSeconds = elapsedSeconds; self.statusCode = statusCode; self.usage = usage
    }
}

public struct AITextUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let reasoningTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens; self.reasoningTokens = reasoningTokens
    }
}

public extension AITextRequest {
    func report(_ stage: AITextProgress.Stage, since start: ContinuousClock.Instant, statusCode: Int? = nil, usage: AITextUsage? = nil) {
        let elapsed = start.duration(to: .now).components
        onProgress?(.init(stage: stage, elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, statusCode: statusCode, usage: usage))
    }
}
