import Foundation
import XCTest
import AIProvidersCore
import AITextProviders

final class TextOptionsTests: XCTestCase {
    private func http() -> AIHTTP {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        return AIHTTP(session: URLSession(configuration: config))
    }
    private let answer = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Corrected."}}]}"#.utf8)

    func testExistingSavedSelectionsDecodeWithoutChangingProviderOrModel() throws {
        let id = UUID()
        let old = Data("{\"connectionID\":\"\(id)\",\"modelID\":\"original\"}".utf8)
        let value = try JSONDecoder().decode(AISelection.self, from: old)
        XCTAssertEqual(value.connectionID, id); XCTAssertEqual(value.modelID, "original"); XCTAssertNil(value.options)
        let configured = AISelection(connectionID: id, modelID: "original", options: .init(reasoningEffort: .low,
            routing: .init(sort: .latency, only: ["groq"], allowFallbacks: false)))
        XCTAssertEqual(try JSONDecoder().decode(AISelection.self, from: JSONEncoder().encode(configured)), configured)
    }

    func testCatalogDeterminesFastestSupportedEffortWithoutGuessingFromModelName() async throws {
        MockHTTP.handle = { _ in (200, Data(#"{"data":[{"id":"any/qwen","reasoning":{"supported_efforts":["xhigh","medium","low","none"],"mandatory":false}},{"id":"any/oss","reasoning":{"supported_efforts":["high","medium","low","none"],"mandatory":true}},{"id":"future","reasoning":{"supported_efforts":["unknown-effort","low"]}},{"id":"plain"},{"id":"all","reasoning":{"supported_efforts":null,"mandatory":true}}]}"#.utf8)) }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://broker.example/v1")!, service: .openRouter, http: http(), credential: { "fixture" })
        let models = try await provider.models()
        XCTAssertEqual(models[0].reasoning?.fastestEffort, AIReasoningEffort.none)
        XCTAssertEqual(models[1].reasoning?.fastestEffort, .low)
        XCTAssertFalse(models[1].reasoning!.availableEfforts.contains(.none))
        XCTAssertEqual(models[2].reasoning?.availableEfforts, [.low])
        XCTAssertNil(models[3].reasoning)
        XCTAssertEqual(models[4].reasoning?.fastestEffort, .minimal)
        XCTAssertEqual(try JSONDecoder().decode([AIModel].self, from: JSONEncoder().encode(models)), models)
    }

    func testOpenRouterSendsExplicitEffortAndPinnedServerWithoutFallback() async throws {
        MockHTTP.handle = { [answer] request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockHTTP.body(request)) as? [String: Any])
            let reason = try XCTUnwrap(body["reasoning"] as? [String: Any])
            XCTAssertEqual(reason["effort"] as? String, "low"); XCTAssertEqual(reason["exclude"] as? Bool, true)
            XCTAssertNil(body["reasoning_effort"])
            let routing = try XCTUnwrap(body["provider"] as? [String: Any])
            XCTAssertEqual(routing["only"] as? [String], ["groq"])
            XCTAssertEqual(routing["allow_fallbacks"] as? Bool, false)
            XCTAssertEqual(routing["require_parameters"] as? Bool, true)
            XCTAssertEqual(routing["sort"] as? String, "latency")
            return (200, answer)
        }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://broker.example/v1")!, service: .openRouter, http: http(), credential: { "fixture" })
        let result = try await provider.generate(.init(model: "openai/gpt-oss-120b", instructions: "Correct.", text: "Original.", options: .init(reasoningEffort: .low,
            routing: .init(sort: .latency, only: ["groq"], allowFallbacks: false))))
        XCTAssertEqual(result, "Corrected.")
    }

    func testDirectCompatibleServerReceivesNativeEffortWithoutBrokerFields() async throws {
        MockHTTP.handle = { [answer] request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockHTTP.body(request)) as? [String: Any])
            XCTAssertEqual(body["reasoning_effort"] as? String, "none")
            XCTAssertNil(body["reasoning"]); XCTAssertNil(body["provider"])
            return (200, answer)
        }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://direct.example/v1")!, http: http(), credential: { "fixture" })
        _ = try await provider.generate(.init(model: "qwen-3.8-27b", instructions: "Correct.", text: "Original.", options: .init(reasoningEffort: AIReasoningEffort.none)))
    }

    func testBrokerOptionsCannotBeSilentlySentToAnotherProvider() async throws {
        MockHTTP.handle = { _ in XCTFail("Must reject before any HTTP request"); return (500, Data()) }
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://direct.example/v1")!, http: http(), credential: {
            XCTFail("Must reject before reading credentials"); return "fixture"
        })
        do {
            _ = try await provider.generate(.init(model: "m", instructions: "Correct.", text: "Original.", options: .init(routing: .init(only: ["groq"]))))
            XCTFail("Direct services do not implement OpenRouter routing")
        } catch { XCTAssertEqual(error as? AIProviderError, .unsupported) }
    }

    func testInvalidServerAllowlistIsRejectedBeforeCredentialRead() async throws {
        let provider = CompatibleTextProvider(endpoint: URL(string: "https://broker.example/v1")!, service: .openRouter, http: http(), credential: {
            XCTFail("Invalid settings must not read credentials"); return "fixture"
        })
        do {
            _ = try await provider.generate(.init(model: "m", instructions: "Correct.", text: "Original.", options: .init(routing: .init(only: ["https://unrelated.example/?key=value"]))))
            XCTFail("Server IDs must be slugs, not URLs or credentials")
        } catch { XCTAssertEqual(error as? AIProviderError, .invalidConfiguration) }
    }

    func testExplicitOpenAIEffortOverridesExistingInteractivePreset() async throws {
        MockHTTP.handle = { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: MockHTTP.body(request)) as? [String: Any])
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")
            return (200, Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"Corrected.\"}]}]}}\n\n".utf8))
        }
        let provider = OpenAITextProvider(http: http(), credential: { "fixture" })
        let result = try await provider.generate(.init(model: "gpt-6-luna", instructions: "Correct.", text: "Original.", latency: .interactive, options: .init(reasoningEffort: .high)))
        XCTAssertEqual(result, "Corrected.")
    }
}
