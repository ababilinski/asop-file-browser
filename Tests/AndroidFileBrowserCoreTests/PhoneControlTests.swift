import AppKit
import XCTest
@testable import AndroidFileBrowserCore

final class PhoneControlTests: XCTestCase {
    func testScrcpyArgumentsTargetOneDeviceAndUseItsUniqueWindowTitle() {
        let options = ScreenRecordingOptions(
            showTouches: true,
            resolutionPreset: .hd720,
            videoBitRateMbps: 18,
            appPackageName: "com.example.photos"
        )
        let placement = ScrcpyWindowPlacement(x: 20, y: 30, width: 400, height: 700, alwaysOnTop: false)

        let arguments = ADBClient.scrcpyArguments(
            serial: "glasses-serial",
            windowTitle: "ASOP File Browser — Glasses [s-serial]",
            options: options,
            placement: placement
        )

        XCTAssertEqual(Array(arguments.prefix(4)), [
            "--serial", "glasses-serial",
            "--window-title", "ASOP File Browser — Glasses [s-serial]"
        ])
        XCTAssertTrue(arguments.contains("--show-touches"))
        XCTAssertEqual(value(after: "--max-size", in: arguments), "1280")
        XCTAssertEqual(value(after: "--video-bit-rate", in: arguments), "18M")
        XCTAssertEqual(value(after: "--start-app", in: arguments), "com.example.photos")
        XCTAssertEqual(value(after: "--window-width", in: arguments), "400")
        XCTAssertFalse(arguments.contains("--always-on-top"))
    }

    func testSeparateSessionsReceiveSeparateInitialPlacements() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 918)

        let first = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 0
        )
        let second = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 1
        )
        let fourth = PhoneControlWindowLayout.placement(
            screenFrame: screen,
            visibleFrame: visible,
            sessionIndex: 3
        )

        XCTAssertNotEqual(first.x, second.x)
        XCTAssertEqual(first.y, second.y)
        XCTAssertNotEqual(first.x, fourth.x)
        XCTAssertNotEqual(first.y, fourth.y)
        XCTAssertGreaterThanOrEqual(first.width, 300)
        XCTAssertGreaterThanOrEqual(first.height, 420)
        XCTAssertTrue(first.alwaysOnTop)
    }

    func testCompanionBarStaysInsideVisibleScreen() {
        let visible = CGRect(x: 0, y: 40, width: 900, height: 700)
        let phone = CGRect(x: 20, y: 45, width: 360, height: 640)

        let companion = PhoneControlWindowLayout.companionFrame(for: phone, visibleFrame: visible)

        XCTAssertGreaterThanOrEqual(companion.minX, visible.minX)
        XCTAssertLessThanOrEqual(companion.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(companion.minY, visible.minY)
        XCTAssertLessThanOrEqual(companion.maxY, visible.maxY)
    }

    func testIntegratedControlsUseStandardAndroidInputCommands() {
        XCTAssertEqual(PhoneControlShortcut.back.adbCommand, "input keyevent 4")
        XCTAssertEqual(PhoneControlShortcut.home.adbCommand, "input keyevent 3")
        XCTAssertEqual(PhoneControlShortcut.recentApps.adbCommand, "input keyevent 187")
        XCTAssertEqual(PhoneControlShortcut.power.adbCommand, "input keyevent 26")
        XCTAssertEqual(
            PhoneControlShortcut.automaticRotation.adbCommand,
            "settings put system accelerometer_rotation 1"
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
