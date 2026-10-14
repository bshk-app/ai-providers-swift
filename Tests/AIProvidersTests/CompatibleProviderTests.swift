import Foundation
import XCTest
import AIProvidersCore
import AITextProviders
import AIServiceProviders

final class CompatibleProviderTests: XCTestCase {
    private func http() -> AIHTTP {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return AIHTTP(session: URLSession(configuration: config))
    }
    func testCompatibleCatalogKeepsOpenWeightModelIDsInsteadOfOnlyGPT() async throws {
        MockHTTP.handle = { _ in
            (200, Data("{\"data\":[{\"id\":\"Qwen/Qwen3-8B\"},{\"id\":\"meta-llama/Llama-3.3-70B-Instruct\"},{\"id\":\"gpt-oss-120b\"}]}".utf8))
        }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://api.featherless.ai/v1")!, http: http(), credential: { "fixture" })
        let models = try await provider.models()
        XCTAssertEqual(Set(models.map(\.id)), ["Qwen/Qwen3-8B", "meta-llama/Llama-3.3-70B-Instruct", "gpt-oss-120b"])
    }
}

extension CompatibleProviderTests {
    func testFeatherlessSearchEncodesQueryAndRequestsOnlyOnePage() async throws {
        MockHTTP.handle = { request in
            XCTAssertEqual(request.url?.path, "/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["q"], "Qwen / + русский")
            XCTAssertEqual(query["page"], "2"); XCTAssertEqual(query["per_page"], "100")
            return (200, Data(#"{"data":[{"id":"Qwen/Qwen3-8B","context_length":32768,"available_on_current_plan":false}],"pagination":{"current_page":2,"total_items":500,"total_pages":5}}"#.utf8))
        }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://api.featherless.ai/v1")!, service: .featherless, http: http(), credential: { "fixture" })
        let page = try await provider.modelPage(query: "Qwen / + русский", cursor: "2")
        XCTAssertEqual(page.total, 500); XCTAssertEqual(page.nextCursor, "3")
        XCTAssertEqual(page.models.first?.contextLength, 32768); XCTAssertEqual(page.models.first?.available, false)
    }
    func testBrokerCatalogExcludesNonTextModalitiesWithoutVendorAllowlist() async throws {
        MockHTTP.handle = { _ in (200, Data(#"{"data":[{"id":"qwen/instruct","name":"Qwen","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},{"id":"image/model","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},{"id":"audio/model","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},{"id":"text-embedding-3-small"}]}"#.utf8)) }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://openrouter.ai/api/v1")!, service: .openRouter, http: http(), credential: { "fixture" })
        let page = try await provider.modelPage(query: "Qwen", cursor: nil)
        XCTAssertEqual(page.models.map(\.id), ["qwen/instruct"])
        XCTAssertEqual(page.models.first?.operations, [.textEditing, .translation])
    }
    func testChatUsesCompletionsContractAndPreservesFinalContent() async throws {
        MockHTTP.handle = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockHTTP.body(request)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "Qwen/Qwen3-8B")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertNil(body["reasoning"], "unknown models must not receive OpenAI-specific parameters")
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role":"system", "content":"Correct."], ["role":"user", "content":"привет мир"]])
            return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Привет, мир.","reasoning":"private reasoning is not output"}}]}"#.utf8))
        }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://openrouter.ai/api/v1")!, service: .openRouter, http: http(), credential: { "fixture" })
        let value = try await provider.generate(.init(model: "Qwen/Qwen3-8B", instructions: "Correct.", text: "привет мир", latency: .interactive))
        XCTAssertEqual(value, "Привет, мир.")
    }
    func testTruncatedAndRefusedChatCannotReplaceOriginalText() async throws {
        for response in [#"{"choices":[{"finish_reason":"length","message":{"content":"half"}}]}"#,
                         #"{"choices":[{"finish_reason":"stop","message":{"content":"text","refusal":"refused"}}]}"#] {
            MockHTTP.handle = { _ in (200, Data(response.utf8)) }
            let provider = CompatibleTextProvider(endpoint: URL(string: "https://broker.example/v1")!, http: http(), credential: { "fixture" })
            do { _ = try await provider.generate(.init(model: "test", instructions: "Correct", text: "Original")); XCTFail("incomplete output must fail") }
            catch { XCTAssertEqual(error as? AIProviderError, .interrupted) }
        }
    }
    func testPublicCatalogCannotCountAsCredentialVerification() async throws {
        for (service, path) in [(AICompatibleService.featherless, "/v1/plan"), (.openRouter, "/v1/key")] {
            MockHTTP.handle = { request in
                XCTAssertEqual(request.url?.path, path)
                return (401, Data("{}".utf8))
            }
            let provider = CompatibleTextProvider(endpoint: URL(string: "https://broker.example/v1")!, service: service, http: http(), credential: { "invalid-fixture" })
            do { try await provider.verifyConnection(); XCTFail("invalid keys must fail even with public catalogs") }
            catch { XCTAssertEqual(error as? AIProviderError, .refused(401)) }
        }
    }
    func testSavedCatalogBeforeOptionalMetadataStillDecodes() throws {
        let old = Data(#"{"id":"test","name":"Test","kind":"text","operations":["textEditing"]}"#.utf8)
        let model = try JSONDecoder().decode(AIModel.self, from: old)
        XCTAssertNil(model.contextLength); XCTAssertNil(model.available)
    }
    func testDictatorCheckUsesZeroAudioAndCanonicalBaseWithOwnAPIKeyOnly() async throws {
        var calls = 0
        MockHTTP.handle = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/prefix/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "fixture")
            XCTAssertNil(request.url?.query)
            let body = try MockHTTP.body(request)
            let riff = try XCTUnwrap(body.range(of: Data("RIFF".utf8)))
            let wave = body[riff.lowerBound..<min(body.count, riff.lowerBound + 44)]
            XCTAssertEqual(wave.count, 44)
            XCTAssertEqual(Array(wave.suffix(4)), [0,0,0,0], "data length is zero")
            return (200, Data(#"{"text":"","audio_s":0,"engine":"test","degraded":false}"#.utf8))
        }
        let endpoint = URL(string: "https://gateway.example/prefix/v1/audio/transcriptions/")!
        let provider = try AIServiceProviders.DictatorProvider(endpoint: endpoint, token: "fixture", http: http())
        try await provider.checkConnection()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try AIServiceProviders.DictatorProvider.canonicalEndpoint(endpoint).path, "/prefix/v1")
    }
    func testDictatorCheckRejectsInvalidKeyInsteadOfReportingStaticModels() async throws {
        MockHTTP.handle = { _ in (401, Data("{}".utf8)) }
        let provider = try AIServiceProviders.DictatorProvider(endpoint: URL(string: "https://gateway.example/v1")!, token: "invalid", http: http())
        do { try await provider.checkConnection(); XCTFail() }
        catch { XCTAssertEqual(error as? AIProviderError, .refused(401)) }
    }
}
