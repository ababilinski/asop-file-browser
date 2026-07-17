import Foundation

public struct ParsedSearchQuery: Equatable, Sendable {
    public let rawText: String
    public let text: String
    public let kindFilter: FileSearchKindFilter?

    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasCriteria: Bool {
        hasText || kindFilter != nil
    }
}

public enum SearchQueryParser {
    public static func parse(_ rawText: String) -> ParsedSearchQuery {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            return ParsedSearchQuery(rawText: rawText, text: "", kindFilter: nil)
        }

        var kindFilter: FileSearchKindFilter?
        var remainingTerms: [String] = []

        for term in trimmedRaw.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let parsedKind = kindFilterToken(in: term) {
                kindFilter = parsedKind
                continue
            }
            remainingTerms.append(term)
        }

        let remainingText = remainingTerms.joined(separator: " ")

        return ParsedSearchQuery(rawText: rawText, text: remainingText, kindFilter: kindFilter)
    }

    public static func removingKindFilters(from rawText: String) -> String {
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return "" }

        let remainingTerms = trimmedRaw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { kindFilterToken(in: $0) == nil }

        return remainingTerms.joined(separator: " ")
    }

    private static func kindFilterToken(in term: String) -> FileSearchKindFilter? {
        guard let separator = term.firstIndex(of: ":") else { return nil }

        let prefix = term[..<separator].lowercased()
        guard prefix == "type" || prefix == "kind" else { return nil }

        let valueStart = term.index(after: separator)
        let value = String(term[valueStart...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return FileSearchKindFilter(searchAlias: value)
    }
}
