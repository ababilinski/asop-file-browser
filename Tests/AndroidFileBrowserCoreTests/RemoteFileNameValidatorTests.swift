import XCTest
@testable import AndroidFileBrowserCore

final class RemoteFileNameValidatorTests: XCTestCase {
    func testAcceptsOrdinaryAndroidFileName() {
        XCTAssertNil(RemoteFileNameValidator.validationMessage(for: "Vacation Photos 2026"))
    }

    func testRejectsPathComponentsAndControlCharacters() {
        XCTAssertNotNil(RemoteFileNameValidator.validationMessage(for: ".."))
        XCTAssertNotNil(RemoteFileNameValidator.validationMessage(for: "More/Photos"))
        XCTAssertNotNil(RemoteFileNameValidator.validationMessage(for: "Line\nBreak"))
    }
}
