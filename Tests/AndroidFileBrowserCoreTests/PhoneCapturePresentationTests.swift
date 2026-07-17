import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class PhoneCapturePresentationTests: XCTestCase {
    func testAttachedCaptureRequestsUseOneSharedPresentationMode() {
        let model = makeModel()

        model.requestScreenshot()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .screenshot)

        model.requestScreenRecording()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)

        model.requestPhoneControl()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .phoneControl)
    }

    func testDismissingCaptureControlsOnlyClearsTheMatchingMode() {
        let model = makeModel()
        model.requestScreenRecording()

        model.dismissPhoneCapturePopover(.screenshot)
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .recording)

        model.dismissPhoneCapturePopover(.recording)
        XCTAssertNil(model.activePhoneCapturePopoverMode)
    }

    func testChangingToWindowPresentationClearsPendingAttachedControls() {
        let model = makeModel()
        model.requestScreenshot()
        XCTAssertEqual(model.activePhoneCapturePopoverMode, .screenshot)

        model.settings.phoneCapturePresentation = .separateWindow
        model.phoneCapturePresentationDidChange()

        XCTAssertNil(model.activePhoneCapturePopoverMode)
    }

    func testDismissedCaptureModeDoesNotReturnAfterAnotherRequest() {
        let model = makeModel()
        model.requestScreenshot()
        model.dismissPhoneCapturePopover(.screenshot)

        model.requestPhoneControl()

        XCTAssertEqual(model.activePhoneCapturePopoverMode, .phoneControl)
    }

    private func makeModel() -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.PhoneCapturePresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }
}
