import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class DeviceCaptureServiceTests: XCTestCase {
    func testScreenRecordingProcessWaitReturnsAfterTheProcessAlreadyExited() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "ScreenRecordingProcessTests-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()

        let handle = ADBScreenRecordingProcess(
            serial: "test-device",
            remotePath: "/sdcard/test.mp4",
            startedAt: Date(),
            logURL: logURL,
            process: process,
            logHandle: logHandle
        )

        XCTAssertTrue(handle.waitUntilExit(timeout: 0.1))
    }

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
