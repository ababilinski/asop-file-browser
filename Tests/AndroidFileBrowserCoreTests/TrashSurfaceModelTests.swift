import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class TrashSurfaceModelTests: XCTestCase {
    func testTrashFileKeepsTrashLocationAndRecordedKind() {
        let record = makeRecord(kind: .directory)
        let model = makeModel(records: [record])

        let file = model.trashFile(for: record)

        XCTAssertEqual(file.name, record.name)
        XCTAssertEqual(file.path, record.trashPath)
        XCTAssertEqual(file.kind, .directory)
        XCTAssertEqual(file.size, record.size)
    }

    func testRenameTrashUpdatesRemoteAndPersistedPresentation() async throws {
        let runner = TrashRenameProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let record = makeRecord(kind: .file)
        let model = makeModel(adb: adb, records: [record])
        let device = AndroidDevice(
            serial: record.deviceSerial,
            state: .device,
            model: "Test Phone",
            product: nil,
            transport: nil
        )
        model.devices = [device]
        model.selectedDeviceID = device.id

        await model.renameTrash(record: record, to: "Renamed.jpg")

        let renamed = try XCTUnwrap(model.trashRecords.first)
        XCTAssertEqual(renamed.id, record.id)
        XCTAssertEqual(renamed.name, "Renamed.jpg")
        XCTAssertEqual(renamed.originalPath, "/storage/emulated/0/Download/Renamed.jpg")
        XCTAssertEqual(
            renamed.trashPath,
            "/storage/emulated/0/.AndroidFileBrowserTrash/123-Renamed.jpg"
        )
        XCTAssertEqual(renamed.kind, .file)
        XCTAssertEqual(model.statusMessage, "Renamed Photo.jpg to Renamed.jpg.")
        let moveCommand = await runner.moveCommand()
        XCTAssertEqual(
            moveCommand,
            "mv '/storage/emulated/0/.AndroidFileBrowserTrash/123-Photo.jpg' '/storage/emulated/0/.AndroidFileBrowserTrash/123-Renamed.jpg'"
        )
    }

    private func makeModel(
        adb: ADBClient = ADBClient(),
        records: [TrashRecord]
    ) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.TrashSurface.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            adb: adb,
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: records
        )
    }

    private func makeRecord(kind: AndroidFileKind) -> TrashRecord {
        TrashRecord(
            id: UUID(),
            deviceSerial: "test-device",
            originalPath: "/storage/emulated/0/Download/Photo.jpg",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/123-Photo.jpg",
            name: "Photo.jpg",
            deletedAt: Date(timeIntervalSince1970: 123),
            size: 42,
            kind: kind
        )
    }
}

private actor TrashRenameProcessRunner: ProcessRunning {
    private var recordedMoveCommand: String?

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }

        let command = arguments.last ?? ""
        if command.contains("test -e") {
            return result("1")
        }
        if command.hasPrefix("mv ") {
            recordedMoveCommand = command
            return result("")
        }
        if command.contains("content call --uri content://media") {
            return result("")
        }
        return result("")
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ADBCommandResult {
        throw CancellationError()
    }

    func launchDetached(executable: URL, arguments: [String]) async throws {
        throw CancellationError()
    }

    func launchObserved(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        observationDuration: TimeInterval
    ) async throws -> DetachedLaunchObservation {
        throw CancellationError()
    }

    func moveCommand() -> String? {
        recordedMoveCommand
    }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}
