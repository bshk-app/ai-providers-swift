import Foundation
import XCTest
import AIProvidersCore
import AIProvidersAuth
import AITextProviders
import AISpeechProviders
import AIServiceProviders

final class MockHTTP: URLProtocol, @unchecked Sendable {
    static var handle: ((URLRequest) throws -> (Int, Data))?
    static var finishesLoading = true
    static var finishDelay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            if Self.finishesLoading {
                if Self.finishDelay == 0 { client?.urlProtocolDidFinishLoading(self) }
                else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.finishDelay) { [self] in
                        client?.urlProtocolDidFinishLoading(self)
                    }
                }
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? AIProviderError.invalidResponse }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
final class ProviderTests: XCTestCase {
    private func http() -> AIHTTP {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        return AIHTTP(session: URLSession(configuration: config))
    }
    func testBYOKDictatorMakesOneDirectRequestWithoutAccountOrTemporaryKey() async throws {
        var calls = 0
        MockHTTP.handle = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "user-test-key")
            return (200, Data("{\"text\":\"recognized\",\"engine\":\"server-owned\",\"audio_s\":1,\"degraded\":false}".utf8))
        }
        let provider = try DictatorProvider(endpoint: URL(string: "https://gateway.example/v1")!, token: "user-test-key", http: http())
        let text = try await provider.transcribe(Data([1, 2]), request: .init(model: "quality", language: "ru"))
        XCTAssertEqual(text, "recognized"); XCTAssertEqual(calls, 1)
    }
    func testBillingRefusalIsNotRetriedOrConvertedToAccountLogin() async throws {
        var calls = 0
        MockHTTP.handle = { request in calls += 1; XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions"); return (402, Data("{}".utf8)) }
        let provider = try DictatorProvider(endpoint: URL(string: "https://gateway.example")!, token: "test", http: http())
        do { _ = try await provider.transcribe(Data([0,0]), request: .init(model: "fast", language: "ru")); XCTFail() } catch {}
        XCTAssertEqual(calls, 1)
    }
    func testChatGPTCatalogCannotOfferAudioAndUsesPlanSchema() async throws {
        MockHTTP.handle = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer plan-test-token")
            return (200, Data("{\"models\":[{\"slug\":\"gpt-current\",\"display_name\":\"Current\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"visibility\":\"hide\"}]}".utf8))
        }
        let provider = OpenAITextProvider(auth: .chatGPTPlan, http: http(), credential: { "plan-test-token" })
        let models = try await provider.models()
        XCTAssertEqual(models.map(\.id), ["gpt-current"])
        XCTAssertFalse(models[0].operations.contains(.transcription)); XCTAssertEqual(models[0].kind, .text)
    }
    func testAPIKeyCatalogSeparatesSpeechImageEmbeddingFromText() async throws {
        MockHTTP.handle = { _ in (200, Data("{\"data\":[{\"id\":\"gpt-current\"},{\"id\":\"gpt-transcribe\"},{\"id\":\"gpt-image\"},{\"id\":\"text-embedding\"}]}".utf8)) }
        let models = try await OpenAITextProvider(http: http(), credential: { "test" }).models()
        XCTAssertEqual(models.map(\.id), ["gpt-current"])
    }
    func testGenerateConsumesActualWireSSEIncludingBlankFrameBoundaries() async throws {
        let wire = """
        data: {"type":"response.output_text.delta","delta":"Проверяю "}

        data: {"type":"response.output_text.delta","delta":"корректор."}

        data: {"type":"response.completed","response":{"status":"completed","output":[{"content":[{"type":"output_text","text":"Проверяю корректор."}]}]}}

        """
        MockHTTP.handle = { _ in (200, Data(wire.utf8)) }
        let provider = OpenAITextProvider(auth: .chatGPTPlan, http: http(), credential: { "test-token" })
        let result = try await provider.generate(.init(model: "test-model", instructions: "Correct text.", text: "Проверяю корректор"))
        XCTAssertEqual(result, "Проверяю корректор.")
    }
    func testByteDecoderPreservesEmptyLinesForAllSSELineEndings() throws {
        for ending in ["\n", "\r\n", "\r"] {
            var decoder = SSEByteLines()
            var lines: [String] = []
            for byte in Data(("\u{FEFF}data: Привет" + ending + ending + "data: Мир" + ending + ending).utf8) {
                if let line = try decoder.accept(byte) { lines.append(line) }
            }
            XCTAssertEqual(lines, ["data: Привет", "", "data: Мир", ""])
        }
    }
    func testCompletedResponseReturnsWithoutWaitingForConnectionEOF() async throws {
        MockHTTP.finishesLoading = false
        defer { MockHTTP.finishesLoading = true }
        MockHTTP.handle = { _ in
            (200, Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Finished.\"}]}]}}\n\n".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = OpenAITextProvider(http: AIHTTP(session: session), credential: { "test" })
        let result = try await provider.generate(.init(model: "test", instructions: "Edit.", text: "Finished"))
        XCTAssertEqual(result, "Finished.")
    }
    func testWireStreamRejectsLateQuotaAndTruncatedOutput() async throws {
        for terminal in ["", "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\r\n\r\n"] {
            let wire = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\r\n\r\n" + terminal
            MockHTTP.handle = { _ in (200, Data(wire.utf8)) }
            let provider = OpenAITextProvider(auth: .chatGPTPlan, http: http(), credential: { "test-token" })
            do { _ = try await provider.generate(.init(model: "test-model", instructions: "Edit.", text: "Original")); XCTFail("Incomplete output must not be committed") }
            catch { XCTAssertEqual(error as? AIProviderError, .interrupted) }
        }
    }
    func testInteractiveCorrectionSetsOnlySupportedReasoningEffort() async throws {
        for (model, effort) in [("gpt-5.6-terra", "none"), ("gpt-6-luna", "none"), ("gpt-6-astra", "low"), ("gpt-6.1-sol", "low"), ("custom-model", nil)] {
            MockHTTP.handle = { request in
                let body = try JSONSerialization.jsonObject(with: MockHTTP.body(request)) as! [String: Any]
                XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], effort)
                return (200, Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Final.\"}]}]}}\n\n".utf8))
            }
            let provider = OpenAITextProvider(auth: .chatGPTPlan, http: http(), credential: { "test" })
            _ = try await provider.generate(.init(model: model, instructions: "Edit.", text: "Final", latency: .interactive))
        }
    }
    func testPartialResponsesAreRejectedOnEOF() throws {
        var parser = ResponsesStreamParser()
        try parser.accept("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}"); try parser.accept("")
        XCTAssertThrowsError(try parser.result())
    }
    func testLateQuotaErrorRejectsAlreadyReceivedText() throws {
        var parser = ResponsesStreamParser()
        try parser.accept("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}"); try parser.accept("")
        try parser.accept("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}")
        XCTAssertThrowsError(try parser.accept(""))
    }
    func testCompletedStreamUsesCanonicalOutput() throws {
        var parser = ResponsesStreamParser()
        try parser.accept(": comment"); try parser.accept("event: response.completed")
        try parser.accept("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Final.\"}]}]}}")
        XCTAssertEqual(try parser.result(), "Final.")
    }
    func testIncompleteTerminalCannotBecomeSuccess() throws {
        var parser = ResponsesStreamParser()
        try parser.accept("data: {\"type\":\"response.incomplete\"}")
        XCTAssertThrowsError(try parser.result())
    }
    func testDeepgramRevisionsKeepIdentityAndSampleRanges() throws {
        var parser = DeepgramEventParser(sampleRate: 16000)
        func frame(_ text: String) -> Data { Data("{\"type\":\"Results\",\"is_final\":true,\"start\":1,\"duration\":2,\"channel\":{\"alternatives\":[{\"transcript\":\"\(text)\"}]}}".utf8) }
        guard case .final(let first) = try parser.parse(frame("draft"), finishing: false), case .final(let second) = try parser.parse(frame("final"), finishing: false) else { return XCTFail() }
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(second.startSample, 16000); XCTAssertEqual(second.endSample, 48000)
    }
    func testDeepgramMetadataIsTerminalOnlyAfterUserStop() throws {
        var parser = DeepgramEventParser(sampleRate: 16000)
        let bytes = Data("{\"type\":\"Metadata\"}".utf8)
        XCTAssertNil(try parser.parse(bytes, finishing: false))
        guard case .completed = try parser.parse(bytes, finishing: true) else { return XCTFail() }
    }
    func testDynamicRegistrationUsesOwnIdentityPKCEAndPlanScope() throws {
        let auth = try ChatGPTAuthorization(hostID: "urn:uuid:fixture", appName: "Test App", callback: URL(string: "http://127.0.0.1:32123/auth/callback")!)
        let items = URLComponents(url: auth.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
        XCTAssertEqual(items.first { $0.name == "agent_name_hint" }?.value, "Test App")
        XCTAssertTrue(items.first { $0.name == "scope" }!.value!.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(auth.verifier.count, 43); XCTAssertEqual(auth.state.count, 43)
    }
    func testOAuthBadStateDoesNotExchangeAnyCode() async throws {
        MockHTTP.handle = { _ in XCTFail("Must reject before network"); return (500, Data()) }
        let auth = try ChatGPTAuthorization(hostID: "test", appName: "Test", callback: URL(string: "http://127.0.0.1:32123/auth/callback")!)
        do { _ = try await auth.exchange(URL(string: "http://127.0.0.1:32123/auth/callback?state=wrong&code=test&client_id=issued")!, http: http()); XCTFail() } catch {}
    }
    func testCredentialsCannotBeEmbeddedInEndpoints() {
        for address in ["http://example.com", "https://key@example.com", "https://example.com?api_key=test", "https://example.com/#token"] { XCTAssertThrowsError(try AIEndpoint.validate(URL(string: address)!)) }
    }
    func testChatGPTTokenCannotBeSentToCustomEndpoint() async throws {
        let provider = OpenAITextProvider(endpoint: URL(string: "https://custom.example/v1")!, auth: .chatGPTPlan,
            http: http(), credential: { XCTFail("Reject destination before reading OAuth token"); return "test" })
        do { _ = try await provider.models(); XCTFail() } catch { XCTAssertEqual(error as? AIProviderError, .unsupported) }
    }
}
