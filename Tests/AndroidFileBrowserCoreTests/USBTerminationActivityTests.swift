import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class USBTerminationActivityTests: XCTestCase {
    func testTerminationActivityStaysBlockedUntilEveryUSBOperationFinishes() {
        let manager = USBTransferManager()

        XCTAssertFalse(manager.hasTerminationBlockingActivity)

        manager.beginTerminationBlockingActivity()
        manager.beginTerminationBlockingActivity()

        XCTAssertTrue(manager.hasTerminationBlockingActivity)

        manager.endTerminationBlockingActivity()

        XCTAssertTrue(manager.hasTerminationBlockingActivity)

        manager.endTerminationBlockingActivity()

        XCTAssertFalse(manager.hasTerminationBlockingActivity)
    }
}
