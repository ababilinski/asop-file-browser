import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class LiveADBFileRepositoryTests: XCTestCase {
    func testListsFilesAndCreationDatesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AFB_LIVE_ADB_TEST"] == "1" else {
            throw XCTSkip("Set AFB_LIVE_ADB_TEST=1 to check file metadata on a connected phone.")
        }

        let adb = ADBClient()
        let manager = DeviceManager(adb: adb)
        guard let device = try await manager.devices().first(where: { $0.state == .device }) else {
            throw XCTSkip("Connect and authorize an Android phone first.")
        }
        let repository = AndroidFileRepository(adb: adb, scanner: MediaStoreScanner(adb: adb))
        let files = try await repository.listFiles(device: device, path: "/storage/emulated/0")

        if files.isEmpty {
            let result = try await adb.shell(
                serial: device.serial,
                "find '/storage/emulated/0' -mindepth 1 -maxdepth 1 -exec stat -c '%A|%s|%Y|%Z|%n' {} + 2>/dev/null",
                allowFailure: true
            )
            print("stat exit=\(result.exitCode) stdout=\(result.stdout.debugDescription) stderr=\(result.stderr.debugDescription)")
        }

        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.contains(where: { $0.created != nil }))
    }
}
