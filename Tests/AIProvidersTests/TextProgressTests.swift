import XCTest
import Foundation
import AIProvidersCore
import AITextProviders

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AITextProgress] = []
    func append(_ value: AITextProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [AITextProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class TextProgressTests: XCTestCase {
    private func http() -> AIHTTP {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        return AIHTTP(session: URLSession(configuration: config))
    }
    func testResponsesReportsCredentialHeaderFirstTextAndCompletionWithoutLeakingDiagnosticsIntoBody() async throws {
        let captured = ProgressRecorder(), id = UUID()
        MockHTTP.handle = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockHTTP.body(request)) as? [String: Any])
            XCTAssertNil(body["requestID"]); XCTAssertNil(body["onProgress"])
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Request-ID"), "correlation stays local")
            return (200, Data("""
            data: {"type":"response.created"}

            data: {"type":"response.output_text.delta","delta":"Finished."}

            data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":100,"output_tokens":12,"input_tokens_details":{"cached_tokens":80},"output_tokens_details":{"reasoning_tokens":3}},"output":[{"content":[{"type":"output_text","text":"Finished."}]}]}}

            """.utf8))
        }
        let provider = OpenAITextProvider(http: http(), credential: { try await Task.sleep(for: .milliseconds(20)); return "synthetic-key" })
        let text = try await provider.generate(.init(model: "test", instructions: "Correct.", text: "Finished", requestID: id, onProgress: { captured.append($0) }))
        XCTAssertEqual(text, "Finished.")
        let events = captured.values
        XCTAssertEqual(events.map(\.stage), [.credentialsReady, .responseHeaders, .firstOutput, .completed])
        XCTAssertGreaterThanOrEqual(events[0].elapsedSeconds, 0.015, "token wait is measured separately")
        XCTAssertEqual(events.map(\.elapsedSeconds), events.map(\.elapsedSeconds).sorted())
        XCTAssertEqual(events[1].statusCode, 200)
        XCTAssertEqual(events.last?.usage, .init(inputTokens: 100, outputTokens: 12, cachedInputTokens: 80, reasoningTokens: 3))
    }
    func testCompletedOnlyStreamStillReportsFirstOutputOnce() async throws {
        let captured = ProgressRecorder()
        MockHTTP.handle = { _ in (200, Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Complete.\"}]}]}}\n\n".utf8)) }
        _ = try await OpenAITextProvider(http: http(), credential: { "test" }).generate(.init(model: "test", instructions: "Correct", text: "Complete", onProgress: { captured.append($0) }))
        XCTAssertEqual(captured.values.map(\.stage), [.credentialsReady, .responseHeaders, .firstOutput, .completed])
        XCTAssertNil(captured.values.last?.usage)
    }
    func testRefusalReportsStatusAndNeverClaimsFirstOutputOrCompletion() async throws {
        let captured = ProgressRecorder()
        MockHTTP.handle = { _ in (429, Data("{}".utf8)) }
        do {
            _ = try await OpenAITextProvider(http: http(), credential: { "test" }).generate(.init(model: "test", instructions: "Correct", text: "Original", onProgress: { captured.append($0) }))
            XCTFail()
        } catch { XCTAssertEqual(error as? AIProviderError, .refused(429)) }
        XCTAssertEqual(captured.values.map(\.stage), [.credentialsReady, .responseHeaders])
        XCTAssertEqual(captured.values.last?.statusCode, 429)
    }
    func testCompatibleNonStreamingCompletionReportsHeadersAndTokenUsage() async throws {
        let captured = ProgressRecorder()
        MockHTTP.handle = { _ in (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Finished."}}],"usage":{"prompt_tokens":20,"completion_tokens":4,"completion_tokens_details":{"reasoning_tokens":0}}}"#.utf8)) }
        _ = try await CompatibleTextProvider(endpoint: URL(string: "https://compatible.example/v1")!, http: http(), credential: { "test" }).generate(.init(model: "test", instructions: "Correct", text: "Finished", onProgress: { captured.append($0) }))
        XCTAssertEqual(captured.values.map(\.stage), [.credentialsReady, .responseHeaders, .firstOutput, .completed])
        XCTAssertEqual(captured.values[1].statusCode, 200)
        XCTAssertEqual(captured.values.last?.usage, .init(inputTokens: 20, outputTokens: 4, reasoningTokens: 0))
    }
    func testRequestSpecificTransportStillRefusesRedirects() async throws {
        let captured = ProgressRecorder()
        MockHTTP.handle = { _ in (302, Data("{}".utf8)) }
        do {
            _ = try await CompatibleTextProvider(endpoint: URL(string: "https://compatible.example/v1")!, http: http(), credential: { "test" }).generate(.init(model: "test", instructions: "Correct", text: "Original", onProgress: { captured.append($0) }))
            XCTFail()
        } catch { XCTAssertEqual(error as? AIProviderError, .refused(302)) }
        XCTAssertEqual(captured.values.map(\.stage), [.credentialsReady, .responseHeaders])
    }
}
