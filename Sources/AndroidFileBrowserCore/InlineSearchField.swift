import SwiftUI

struct InlineSearchField: View {
    @Binding var text: String
    let prompt: String
    private let kindFilter: Binding<FileSearchKindFilter>?
    @State private var isSuggestionPopoverPresented = false
    @State private var suppressSuggestions = false
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, prompt: String) {
        self._text = text
        self.prompt = prompt
        self.kindFilter = nil
    }

    init(text: Binding<String>, prompt: String, kindFilter: Binding<FileSearchKindFilter>) {
        self._text = text
        self.prompt = prompt
        self.kindFilter = kindFilter
    }

    var body: some View {
        searchControl
            .popover(
                isPresented: $isSuggestionPopoverPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                SearchSuggestionPanel(
                    query: trimmedText,
                    kindSuggestions: kindSuggestions,
                    selectNameSearch: selectNameSearch,
                    selectKind: selectKind
                )
                .compatiblePresentationBackground(Color(nsColor: .windowBackgroundColor))
            }
            .frame(width: 300)
            .onValueChange(of: isFocused) { _, focused in
                if focused {
                    updateSuggestionPresentation()
                }
            }
    }

    private var searchControl: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            if let kindFilter, activeKindFilter != .any {
                SearchKindToken(filter: kindFilter)
            }

            TextField(activePrompt, text: $text)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($isFocused)
                .onValueChange(of: text) { _, _ in
                    suppressSuggestions = false
                    updateSuggestionPresentation()
                }

            if hasActiveSearch {
                Button {
                    kindFilter?.wrappedValue = .any
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 300)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            if !trimmedText.isEmpty {
                suppressSuggestions = false
                isFocused = true
                updateSuggestionPresentation()
            }
        }
    }

    private var activeKindFilter: FileSearchKindFilter {
        kindFilter?.wrappedValue ?? .any
    }

    private var hasActiveSearch: Bool {
        !text.isEmpty || activeKindFilter != .any
    }

    private var activePrompt: String {
        activeKindFilter == .any ? prompt : ""
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kindSuggestions: [FileSearchKindFilter] {
        guard kindFilter != nil else { return [] }
        return Array(FileSearchKindFilter.searchSuggestions(for: trimmedText).prefix(8))
    }

    private func updateSuggestionPresentation() {
        isSuggestionPopoverPresented = kindFilter != nil
            && !suppressSuggestions
            && !trimmedText.isEmpty
            && isFocused
    }

    private func selectNameSearch() {
        kindFilter?.wrappedValue = .any
        suppressSuggestions = true
        isSuggestionPopoverPresented = false
        isFocused = false
    }

    private func selectKind(_ filter: FileSearchKindFilter) {
        kindFilter?.wrappedValue = filter
        text = ""
        suppressSuggestions = true
        isSuggestionPopoverPresented = false
        isFocused = false
    }
}

private struct SearchKindToken: View {
    @Binding var filter: FileSearchKindFilter

    var body: some View {
        Menu {
            Button("Any") {
                filter = .any
            }

            Divider()

            ForEach(FileSearchKindFilter.allCases.filter { $0 != .any }) { option in
                Button {
                    filter = option
                } label: {
                    Label(option.searchTokenLabel, systemImage: option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    Text("KIND")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

                Rectangle()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 1, height: 18)

                Text(filter.searchTokenLabel)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            .foregroundStyle(.primary)
            .background(Color.secondary.opacity(0.24), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Kind Filter: \(filter.searchTokenLabel)")
    }
}

private struct SearchSuggestionPanel: View {
    let query: String
    let kindSuggestions: [FileSearchKindFilter]
    let selectNameSearch: () -> Void
    let selectKind: (FileSearchKindFilter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchSuggestionSectionTitle("Filenames")
            SearchSuggestionRow(
                title: "Name Contains \"\(query)\"",
                systemImage: "text.magnifyingglass",
                action: selectNameSearch
            )

            if !kindSuggestions.isEmpty {
                Divider()
                    .padding(.vertical, 8)

                SearchSuggestionSectionTitle("Kinds")
                ForEach(kindSuggestions) { filter in
                    SearchSuggestionRow(
                        title: filter.searchTokenLabel,
                        systemImage: filter.systemImage
                    ) {
                        selectKind(filter)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SearchSuggestionSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
    }
}

private struct SearchSuggestionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
