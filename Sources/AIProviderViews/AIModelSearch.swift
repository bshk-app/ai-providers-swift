import AIProvidersCore
import Foundation
import Observation

/// Server-side model search with paging, for catalogs too large to load
/// (Featherless lists tens of thousands of models). Typing is debounced; only
/// the latest request may write results, so a slow answer to an old query, or
/// to a provider that was switched away from, never replaces newer ones.
@MainActor @Observable
public final class AIModelSearch {
    public enum Phase: Equatable {
        case idle, loading, loadingMore, loaded
        case failed(String)
    }

    public typealias Search = @MainActor (_ query: String, _ cursor: String?) async throws -> AIModelPage

    public private(set) var query = ""
    public private(set) var results: [AIModel] = []
    public private(set) var total: Int?
    public private(set) var phase: Phase = .idle
    public var canLoadMore: Bool { nextCursor != nil && phase == .loaded }

    private let search: Search
    private let debounce: Duration
    private var nextCursor: String?
    private var generation = 0
    private var pending: Task<Void, Never>?
    /// What a retry repeats: the first page, or the page after the last one shown.
    private var failedWhileLoadingMore = false

    public init(debounce: Duration = .milliseconds(300), search: @escaping Search) {
        self.debounce = debounce
        self.search = search
    }

    /// Typing: waits for a pause, then asks for the first page of `text`.
    public func setQuery(_ text: String) {
        query = text
        pending?.cancel()
        generation += 1   // an answer still in flight is for the old text: drop it now, not after the pause
        // Nothing of the old text's paging may act on the new one while the pause runs.
        nextCursor = nil
        failedWhileLoadingMore = false
        phase = .loading
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.load(reset: true)
        }
    }

    /// The first page now, without waiting (on appear, on Return).
    public func searchNow() async {
        pending?.cancel()
        await load(reset: true)
    }

    public func loadMore() async {
        guard canLoadMore else { return }
        await load(reset: false)
    }

    public func retry() async {
        await load(reset: !failedWhileLoadingMore)
    }

    /// Stops whatever is in flight; its answer will be dropped.
    public func cancel() {
        pending?.cancel()
        generation += 1
    }

    private func load(reset: Bool) async {
        generation += 1
        let mine = generation
        let text = query
        phase = reset ? .loading : .loadingMore
        do {
            let page = try await search(text, reset ? nil : nextCursor)
            guard mine == generation, !Task.isCancelled else { return }
            var known = reset ? [] : Set(results.map(\.id))
            let fresh = page.models.filter { known.insert($0.id).inserted }
            results = reset ? fresh : results + fresh
            nextCursor = page.nextCursor
            total = page.total
            failedWhileLoadingMore = false
            phase = .loaded
        } catch is CancellationError {
            guard mine == generation, !Task.isCancelled else { return }
            phase = results.isEmpty ? .idle : .loaded
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            failedWhileLoadingMore = !reset
            if reset { results = []; nextCursor = nil; total = nil }
            phase = .failed(error.localizedDescription)
        }
    }
}
