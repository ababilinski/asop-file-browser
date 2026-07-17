import XCTest
@testable import AndroidFileBrowserCore

final class SearchQueryTests: XCTestCase {
    func testParsesTypePictureAlias() {
        let parsed = SearchQueryParser.parse("type:pictures")

        XCTAssertEqual(parsed.kindFilter, .images)
        XCTAssertEqual(parsed.text, "")
    }

    func testParsesTypeAppWithRemainingText() {
        let parsed = SearchQueryParser.parse("type:app camera")

        XCTAssertEqual(parsed.kindFilter, .applications)
        XCTAssertEqual(parsed.text, "camera")
    }

    func testBareKindAliasStaysTextSearch() {
        let parsed = SearchQueryParser.parse("movie")

        XCTAssertNil(parsed.kindFilter)
        XCTAssertEqual(parsed.text, "movie")
    }

    func testDoesNotInferKindInsideNormalTextSearch() {
        let parsed = SearchQueryParser.parse("holiday image backup")

        XCTAssertNil(parsed.kindFilter)
        XCTAssertEqual(parsed.text, "holiday image backup")
    }

    func testRemovesTypedKindToken() {
        let text = SearchQueryParser.removingKindFilters(from: "type:images DCIM")

        XCTAssertEqual(text, "DCIM")
    }

    func testRemovingKindFiltersKeepsBareAliasText() {
        let text = SearchQueryParser.removingKindFilters(from: "image")

        XCTAssertEqual(text, "image")
    }

    func testKindSuggestionsIncludeImageAliases() {
        let suggestions = FileSearchKindFilter.searchSuggestions(for: "picture")

        XCTAssertEqual(suggestions.first, .images)
    }

    func testApplicationKindMatchesAndroidPackages() {
        let apk = AndroidFile(
            name: "base.apk",
            path: "/storage/emulated/0/Download/base.apk",
            kind: .file,
            size: 10,
            modified: nil,
            permissions: nil
        )

        XCTAssertTrue(FileSearchKindFilter.applications.matches(file: apk))
        XCTAssertFalse(FileSearchKindFilter.images.matches(file: apk))
    }
}
