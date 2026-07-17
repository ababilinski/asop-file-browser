import XCTest
import MTPKit
@testable import AndroidFileBrowserCore

final class USBTransferRecoveryTests: XCTestCase {
    func testUnableToSendIORequiresMTPConnectionReset() {
        let error = NSError(
            domain: "IOUSBHostErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to send IO."]
        )

        XCTAssertTrue(USBTransferManager.requiresMTPConnectionReset(after: error))
    }

    func testOrdinaryOperationFailureDoesNotResetMTPConnection() {
        let error = NSError(
            domain: "MTP",
            code: 0x2005,
            userInfo: [NSLocalizedDescriptionKey: "Operation not supported."]
        )

        XCTAssertFalse(USBTransferManager.requiresMTPConnectionReset(after: error))
    }

    func testTypedDisconnectErrorsRequireMTPConnectionReset() {
        XCTAssertTrue(USBTransferManager.requiresMTPConnectionReset(after: MTPError.noDevice))
        XCTAssertTrue(USBTransferManager.requiresMTPConnectionReset(after: MTPError.interfaceNotFound))
        XCTAssertTrue(USBTransferManager.requiresMTPConnectionReset(after: MTPError.usb("disconnected")))
        XCTAssertTrue(USBTransferManager.requiresMTPConnectionReset(after: TransportError.notConnected))
    }

    func testTypedProtocolErrorKeepsCachedListingVisible() {
        XCTAssertFalse(USBTransferManager.requiresMTPConnectionReset(after: MTPError.protocolError("bad response")))
    }
}
