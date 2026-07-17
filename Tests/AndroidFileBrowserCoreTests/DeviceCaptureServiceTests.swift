import XCTest
@testable import AndroidFileBrowserCore

final class DeviceCaptureServiceTests: XCTestCase {
    func testTargetNightModeUsesRequestedAppearance() {
        XCTAssertEqual(
            DeviceCaptureService.targetNightMode(for: .light, originalNightMode: "yes"),
            "no"
        )
        XCTAssertEqual(
            DeviceCaptureService.targetNightMode(for: .dark, originalNightMode: "no"),
            "yes"
        )
    }

    func testTargetNightModeKeepsOriginalAppearance() {
        XCTAssertEqual(
            DeviceCaptureService.targetNightMode(for: .unchanged, originalNightMode: "auto"),
            "auto"
        )
        XCTAssertNil(
            DeviceCaptureService.targetNightMode(for: .unchanged, originalNightMode: nil)
        )
    }

    func testMatchingAppearanceDoesNotNeedTransition() {
        XCTAssertFalse(
            DeviceCaptureService.appearanceTransitionIsNeeded(
                currentNightMode: "yes",
                targetNightMode: "yes"
            )
        )
        XCTAssertTrue(
            DeviceCaptureService.appearanceTransitionIsNeeded(
                currentNightMode: "no",
                targetNightMode: "yes"
            )
        )
        XCTAssertTrue(
            DeviceCaptureService.appearanceTransitionIsNeeded(
                currentNightMode: nil,
                targetNightMode: "yes"
            )
        )
    }
}
