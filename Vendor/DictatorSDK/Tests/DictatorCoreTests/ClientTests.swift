import XCTest
import Foundation
@testable import DictatorCore

final class MockProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data, headers) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ClientTests: XCTestCase {
    func makeClient() throws -> DictatorClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
        return try DictatorClient(controlURL: URL(string: "https://control.example")!, gatewayURL: URL(string: "https://speech.example/v1")!, session: URLSession(configuration: config))
    }
    func testExistingBalanceUsesSessionWithoutPurchaseRequests() async throws {
        MockProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/mobile/account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-session")
            return (200, Data("{\"userId\":\"u\",\"organizationId\":\"org\",\"availableCredits\":20000,\"reservedCredits\":12,\"purchaseChannel\":\"web\",\"sessionExpiresAt\":1791140000000}".utf8), [:])
        }
        let client = try makeClient(); await client.setSessionToken("signed-session")
        let account = try await client.account()
        XCTAssertEqual(account.availableCredits, 20000); XCTAssertEqual(account.organizationId, "org")
    }
    func testUploadIsNotRetriedAfter402() async throws {
        var uploads = 0
        MockProtocol.handler = { request in
            if request.url?.path == "/api/mobile/key" {
                return (200, Data("{\"key\":\"temporary\",\"expiresAt\":9999999999999}".utf8), [:])
            }
            uploads += 1
            XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "temporary")
            XCTAssertFalse(request.url!.absoluteString.contains("temporary"))
            return (402, Data("{\"error\":\"no credits\"}".utf8), [:])
        }
        let client = try makeClient()
        do { _ = try await client.transcribe(audio: Data([1,2])); XCTFail("Expected refusal") }
        catch { XCTAssertEqual(error as? DictatorError, .insufficientCredits("no credits")) }
        XCTAssertEqual(uploads, 1)
    }
    func testTranscriptSurvivesTranslationError() throws {
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: Data("{\"text\":\"original\",\"engine\":\"speech-01\",\"audio_s\":12,\"degraded\":false,\"translation\":null,\"translation_error\":\"unavailable\"}".utf8))
        XCTAssertEqual(result.text, "original"); XCTAssertNil(result.translation)
        XCTAssertEqual(result.translationError, "unavailable")
    }
    func testSecondFactorResponseDoesNotPersistPrematureSession() async throws {
        MockProtocol.handler = { _ in (200, Data("{\"twoFactorRedirect\":true}".utf8), [:]) }
        let client = try makeClient()
        let result = try await client.signIn(email: "owner", password: "password")
        guard case .requiresSecondFactor = result else { return XCTFail("Expected second factor") }
        let stored = await client.storedSessionToken(); XCTAssertNil(stored)
    }
    func testCompletedAuthenticationUsesSignedBearerHeader() async throws {
        MockProtocol.handler = { _ in (200, Data("{\"token\":\"raw-token\"}".utf8), ["set-auth-token":"signed-token"]) }
        let client = try makeClient(); _ = try await client.signIn(email: "owner", password: "password")
        let token = await client.storedSessionToken(); XCTAssertEqual(token, "signed-token")
    }
    func testRejectsInsecureEndpoints() {
        XCTAssertThrowsError(try DictatorClient(controlURL: URL(string: "http://example.com")!))
    }
}

actor FakeSocket: StreamTransport {
    private var messages: [URLSessionWebSocketTask.Message]
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private(set) var sent: [URLSessionWebSocketTask.Message] = []
    private(set) var closed = false
    init(_ frames: [String]) { messages = frames.map { .string($0) } }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) { sent.append(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard !closed else { throw DictatorError.connectionClosed }
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { closed = true; waiter?.resume(throwing: DictatorError.connectionClosed); waiter = nil }
}
final class StreamTests: XCTestCase {
    func testFinalsAndTranslationsKeepWireOrderAndOriginalOnFailure() async throws {
        let socket = FakeSocket(["{\"type\":\"ready\"}", "{\"type\":\"partial\",\"text\":\"draft\"}",
            "{\"type\":\"final\",\"segment\":1,\"text\":\"original\"}",
            "{\"type\":\"translation_error\",\"segment\":1,\"detail\":\"unavailable\"}", "{\"type\":\"done\"}"])
        let stream = DictatorStream(transport: socket)
        try await stream.start(key: "key", options: .init(language: "ru", targetLanguage: "en"))
        var events: [StreamEvent] = []
        for try await event in stream.events { events.append(event) }
        XCTAssertEqual(events.map(\.type), [.ready,.partial,.final,.translationError,.done])
        XCTAssertEqual(events[2].text, "original")
        let frames = await socket.sent
        if case .string(let frame) = frames.first { XCTAssertTrue(frame.contains("target_language")); XCTAssertTrue(frame.contains("key")) }
        else { XCTFail("Missing start frame") }
    }
    func testProtocolReadinessAndPCMValidation() async throws {
        let socket = FakeSocket(["{\"type\":\"ready\"}"])
        let stream = DictatorStream(transport: socket)
        do { try await stream.sendAudio(Data([1,2])); XCTFail("Not ready") }
        catch { XCTAssertEqual(error as? DictatorError, .notReady) }
        try await stream.start(key: "key", options: .init(language: "ru"))
        do { try await stream.sendAudio(Data([1])); XCTFail("Invalid PCM") }
        catch { XCTAssertEqual(error as? DictatorError, .invalidAudio) }
        try await stream.sendAudio(Data([1,2])); await stream.close()
    }
    func testReadinessTimeoutClosesHungConnection() async {
        let stream = DictatorStream(transport: FakeSocket([]))
        do { try await stream.start(key: "key", options: .init(language: "ru", readyTimeoutSeconds: 1)); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? DictatorError, .readinessTimeout) }
    }
    func testCancelledStartupClosesConnectionWithoutWaitingForReadinessDeadline() async {
        let socket = FakeSocket([])
        let stream = DictatorStream(transport: socket)
        let startup = Task { try await stream.start(key: "key", options: .init(language: "ru", readyTimeoutSeconds: 240)) }
        startup.cancel()
        do { try await startup.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let closed = await socket.closed
        XCTAssertTrue(closed)
    }
}
