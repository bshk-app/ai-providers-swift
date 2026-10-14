import AIProvidersCore
import XCTest
@testable import AIProviderViews

/// Search over a catalog too big to load: debounced typing, paging, and
/// answers that arrive late never replace newer ones.
/// A wait that missed its deadline: the test fails instead of hanging the run.
struct TestTimeout: Error, CustomStringConvertible {
    let waitingFor: String
    var description: String { "Timed out after 2 s waiting until \(waitingFor)" }
}

@MainActor
func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestTimeout(waitingFor: what) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class AIModelSearchTests: XCTestCase {
    private func model(_ id: String) -> AIModel { .init(id: id, name: id, kind: .text, operations: [.textEditing]) }

    /// Each call parks until the test answers it, so the order of answers is the test's.
    private final class Server {
        var calls: [(query: String, cursor: String?, answer: CheckedContinuation<AIModelPage, Error>)] = []
        func search(_ query: String, _ cursor: String?) async throws -> AIModelPage {
            try await withCheckedThrowingContinuation { calls.append((query, cursor, $0)) }
        }
        func waitForCalls(_ count: Int) async throws {
            try await waitUntil("the server was asked \(count) time(s)") { calls.count >= count }
        }
    }

    func testTypingWaitsForAPauseAndAsksOnce() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .milliseconds(200)) { try await server.search($0, $1) }
        for text in ["l", "ll", "llama"] {
            search.setQuery(text)
            try await Task.sleep(for: .milliseconds(30))   // keystrokes, each shorter than the pause
        }
        XCTAssertTrue(server.calls.isEmpty, "nothing is asked while typing goes on")
        try await server.waitForCalls(1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.calls.map(\.query), ["llama"], "only the settled query reaches the server")
        server.calls[0].answer.resume(returning: .init(models: [model("llama-3")], nextCursor: nil, total: 1))
        try await waitUntil("the search loaded") { search.phase == .loaded }
        XCTAssertEqual(search.results.map(\.id), ["llama-3"])
    }

    /// The server filters by step, so a page can come back empty with more to follow.
    func testAnEmptyPageWithACursorStillOffersMore() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [], nextCursor: "2"))
        await first.value
        XCTAssertTrue(search.results.isEmpty)
        XCTAssertTrue(search.canLoadMore)
    }

    func testALateAnswerToAnOldQueryIsDropped() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let old = Task { await search.searchNow() }          // query ""
        try await server.waitForCalls(1)
        search.setQuery("qwen")
        try await server.waitForCalls(2)
        server.calls[1].answer.resume(returning: .init(models: [model("qwen-3")]))
        try await waitUntil("the search loaded") { search.phase == .loaded }
        server.calls[0].answer.resume(returning: .init(models: [model("everything-else")]))
        await old.value
        XCTAssertEqual(search.results.map(\.id), ["qwen-3"])
    }

    /// The old answer lands after the text changed but before the pause ends
    /// and the new request starts: it must change nothing.
    func testAnAnswerArrivingDuringTheNewQuerysPauseIsDropped() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .seconds(30)) { try await server.search($0, $1) }
        let old = Task { await search.searchNow() }        // query ""
        try await server.waitForCalls(1)
        XCTAssertEqual(search.phase, .loading)
        search.setQuery("qwen")                             // its request waits 30 s
        server.calls[0].answer.resume(returning: .init(models: [model("old")], nextCursor: "2", total: 9))
        await old.value
        XCTAssertTrue(search.results.isEmpty, "results of \"\" must not show for \"qwen\"")
        XCTAssertEqual(search.phase, .loading)
        XCTAssertNil(search.total)
        XCTAssertFalse(search.canLoadMore, "the old page's cursor must not be kept")
        XCTAssertEqual(server.calls.count, 1)
        search.cancel()
    }

    /// During the pause after typing, Load more and Try again belong to the
    /// old text and must not run with its cursor.
    func testTypingStopsTheOldPagingAtOnce() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .seconds(30)) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [model("a")], nextCursor: "2"))
        await first.value
        XCTAssertTrue(search.canLoadMore)
        search.setQuery("qwen")
        XCTAssertFalse(search.canLoadMore)
        await search.loadMore()
        XCTAssertEqual(server.calls.count, 1, "no request with the old cursor")
        let retry = Task { await search.retry() }
        try await server.waitForCalls(2)
        XCTAssertEqual(server.calls[1].query, "qwen")
        XCTAssertNil(server.calls[1].cursor, "a retry now is the new text's first page")
        server.calls[1].answer.resume(returning: .init(models: [model("qwen-3")]))
        await retry.value
        XCTAssertEqual(search.results.map(\.id), ["qwen-3"])
        search.cancel()
    }

    func testRepeatedIDsInsideOnePageAreShownOnce() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [model("a"), model("a"), model("b")], nextCursor: "2"))
        await first.value
        XCTAssertEqual(search.results.map(\.id), ["a", "b"])
        let more = Task { await search.loadMore() }
        try await server.waitForCalls(2)
        server.calls[1].answer.resume(returning: .init(models: [model("b"), model("c"), model("c")]))
        await more.value
        XCTAssertEqual(search.results.map(\.id), ["a", "b", "c"])
    }

    func testLoadMoreAppendsTheNextPageWithoutDuplicates() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [model("a"), model("b")], nextCursor: "2", total: 3))
        await first.value
        XCTAssertTrue(search.canLoadMore)
        let more = Task { await search.loadMore() }
        try await server.waitForCalls(2)
        XCTAssertEqual(server.calls[1].cursor, "2")
        server.calls[1].answer.resume(returning: .init(models: [model("b"), model("c")], nextCursor: nil, total: 3))
        await more.value
        XCTAssertEqual(search.results.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(search.canLoadMore)
        XCTAssertEqual(search.total, 3)
    }

    func testAFailedPageKeepsWhatIsShownAndRetriesThatPage() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [model("a")], nextCursor: "2"))
        await first.value
        let more = Task { await search.loadMore() }
        try await server.waitForCalls(2)
        server.calls[1].answer.resume(throwing: URLError(.timedOut))
        await more.value
        guard case .failed = search.phase else { return XCTFail("\(search.phase)") }
        XCTAssertEqual(search.results.map(\.id), ["a"], "a failed next page doesn't wipe the first")
        let retry = Task { await search.retry() }
        try await server.waitForCalls(3)
        XCTAssertEqual(server.calls[2].cursor, "2", "retry asks for the page that failed")
        server.calls[2].answer.resume(returning: .init(models: [model("b")]))
        await retry.value
        XCTAssertEqual(search.results.map(\.id), ["a", "b"])
    }

    func testAFailedFirstPageShowsTheErrorAndNoStaleResults() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        server.calls[0].answer.resume(returning: .init(models: [model("a")]))
        await first.value
        search.setQuery("b")
        try await server.waitForCalls(2)
        server.calls[1].answer.resume(throwing: URLError(.notConnectedToInternet))
        try await waitUntil("the search finished") { search.phase != .loading }
        guard case .failed(let message) = search.phase else { return XCTFail("\(search.phase)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(search.results.isEmpty, "results of the previous query must not pass for this one")
    }

    func testCancelDropsTheAnswerInFlight() async throws {
        let server = Server()
        let search = AIModelSearch(debounce: .zero) { try await server.search($0, $1) }
        let first = Task { await search.searchNow() }
        try await server.waitForCalls(1)
        search.cancel()                      // the sheet closed or the provider changed
        server.calls[0].answer.resume(returning: .init(models: [model("late")]))
        await first.value
        XCTAssertTrue(search.results.isEmpty)
    }

    func testContextLengthsReadShort() {
        XCTAssertEqual(AIModelBrowser.tokens(131_072), "131K")
        XCTAssertEqual(AIModelBrowser.tokens(1_048_576), "1M")
        XCTAssertEqual(AIModelBrowser.tokens(512), "512")
    }
}
