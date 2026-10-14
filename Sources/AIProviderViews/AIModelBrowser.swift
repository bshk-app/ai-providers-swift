import AIProvidersCore
import SwiftUI

/// A searchable list of one provider's models, for a sheet: type to search on
/// the server, page through the results, pick one. The current model stays
/// visible whatever the search shows, and nothing changes until a model is
/// picked: `onSelect` is the only way out that changes anything.
///
/// System controls only; the app's accent comes from `.tint`.
public struct AIModelBrowser: View {
    private let title: String
    private let message: String?
    private let selectedModelID: String?
    private let selectedModelName: String?
    private let onSelect: @MainActor (AIModel) -> Void
    private let onCancel: @MainActor () -> Void
    @State private var model: AIModelSearch
    @State private var text = ""
    @FocusState private var searchFocused: Bool

    /// - Parameters:
    ///   - title: what is being chosen, e.g. "Corrector model · OpenRouter".
    ///   - message: one line under the title, e.g. which models are listed.
    ///   - selectedModelID: the model in use now, shown pinned above the results.
    ///   - selectedModelName: its display name when known (else its id is shown).
    ///   - search: one page of models matching a query; `cursor` nil is the first page.
    public init(title: String, message: String? = nil, selectedModelID: String?, selectedModelName: String? = nil,
                search: @escaping AIModelSearch.Search,
                onSelect: @escaping @MainActor (AIModel) -> Void,
                onCancel: @escaping @MainActor () -> Void) {
        self.title = title
        self.message = message
        self.selectedModelID = selectedModelID
        self.selectedModelName = selectedModelName
        self.onSelect = onSelect
        self.onCancel = onCancel
        _model = State(initialValue: AIModelSearch(search: search))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            searchField
            if let selectedModelID { current(selectedModelID) }
            results
            HStack {
                Text(countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(Strings.cancel, role: .cancel) { model.cancel(); onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 480, idealHeight: 560)
        #endif
        .task { searchFocused = true; await model.searchNow() }
        .onDisappear { model.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(Strings.searchPrompt, text: $text)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: text) { _, new in model.setQuery(new) }
                .onSubmit { Task { await model.searchNow() } }
                .accessibilityLabel(Strings.searchLabel)
            if model.phase == .loading {
                ProgressView().controlSize(.small).accessibilityLabel(Strings.searching)
            } else if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(Strings.clearSearch)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func current(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.current).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedModelName ?? id)
                    if selectedModelName != nil, selectedModelName != id {
                        Text(verbatim: id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)
        }
    }

    @ViewBuilder private var results: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.results).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            switch model.phase {
            case .loading where model.results.isEmpty, .idle:
                placeholder { ProgressView(Strings.searching) }
            case .failed(let error) where model.results.isEmpty:
                placeholder { failure(error) }
            case .loaded where model.results.isEmpty:
                // A filtered page can be empty while later pages still match.
                placeholder {
                    VStack(spacing: 8) {
                        Text(model.canLoadMore ? Strings.noneOnThisPage
                             : model.query.isEmpty ? Strings.noModels : Strings.noMatch(model.query))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if model.canLoadMore { Button(Strings.loadMore) { Task { await model.loadMore() } } }
                    }
                }
            default:
                List {
                    ForEach(model.results) { row($0) }
                    footer
                }
                #if os(macOS)
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                #else
                .listStyle(.plain)
                #endif
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .loadingMore:
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .accessibilityLabel(Strings.loadingMore)
        case .failed(let error):
            failure(error)
        default:
            if model.canLoadMore {
                Button(Strings.loadMore) { Task { await model.loadMore() } }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func row(_ item: AIModel) -> some View {
        let unavailable = item.available == false
        return Button { model.cancel(); onSelect(item) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(unavailable ? .secondary : .primary)
                    Text(verbatim: details(item)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if unavailable {
                    Text(Strings.unavailable).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else if item.id == selectedModelID {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .accessibilityLabel(item.name)
        .accessibilityValue(details(item) + (unavailable ? ", " + Strings.unavailable : ""))
        .accessibilityAddTraits(item.id == selectedModelID ? [.isSelected] : [])
    }

    private func details(_ item: AIModel) -> String {
        let context = item.contextLength.map { Strings.context(Self.tokens($0)) }
        return [item.id == item.name ? nil : item.id, context].compactMap { $0 }.joined(separator: " · ")
    }

    private func failure(_ error: String) -> some View {
        VStack(spacing: 8) {
            Text(Strings.couldNotLoad(error)).foregroundStyle(.red).multilineTextAlignment(.center).textSelection(.enabled)
            Button(Strings.tryAgain) { Task { await model.retry() } }
        }
        .frame(maxWidth: .infinity)
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    private var countText: String {
        guard !model.results.isEmpty else { return "" }
        return model.total.map { Strings.showing(model.results.count, of: $0) } ?? Strings.showing(model.results.count)
    }

    /// 131072 → "131K", 1048576 → "1M".
    static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? "\(count / 1_000_000)M" : count >= 1_000 ? "\(count / 1_000)K" : "\(count)"
    }
}

enum Strings {
    private static func t(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }

    static var cancel: String { t("Cancel") }
    static var searchPrompt: String { t("Search by name or ID") }
    static var searchLabel: String { t("Search models") }
    static var clearSearch: String { t("Clear search") }
    static var searching: String { t("Searching…") }
    static var current: String { t("Current") }
    static var results: String { t("Results") }
    static var noModels: String { t("No models are available for this step.") }
    static var loadMore: String { t("Load more") }
    static var noneOnThisPage: String { t("No matching models on this page yet.") }
    static var loadingMore: String { t("Loading more models") }
    static var unavailable: String { t("Unavailable") }
    static var tryAgain: String { t("Try again") }
    static func noMatch(_ query: String) -> String { String(format: t("No models match “%@”."), query) }
    static func context(_ tokens: String) -> String { String(format: t("%@ context"), tokens) }
    static func couldNotLoad(_ error: String) -> String { String(format: t("Couldn’t load models: %@"), error) }
    static func showing(_ count: Int) -> String { String(format: t("Showing %lld"), count) }
    static func showing(_ count: Int, of total: Int) -> String { String(format: t("Showing %lld of %lld"), count, total) }
}
