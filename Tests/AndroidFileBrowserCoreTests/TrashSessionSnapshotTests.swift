import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class TrashSessionSnapshotTests: XCTestCase {
    func testLegacyTrashRecordWithoutKindStillDecodes() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "deviceSerial": "test-device",
          "originalPath": "/storage/emulated/0/photo.jpg",
          "trashPath": "/storage/emulated/0/.AndroidFileBrowserTrash/photo.jpg",
          "name": "photo.jpg",
          "deletedAt": 0,
          "size": 42
        }
        """

        let record = try JSONDecoder().decode(TrashRecord.self, from: Data(json.utf8))

        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.kind)
    }

    func testTrashRecordKindRoundTripsForThumbnailAndFolderPresentation() throws {
        let original = TrashRecord(
            id: UUID(),
            deviceSerial: "test-device",
            originalPath: "/storage/emulated/0/Pictures",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/Pictures",
            name: "Pictures",
            deletedAt: Date(timeIntervalSince1970: 1),
            size: 128,
            kind: .directory
        )

        let decoded = try JSONDecoder().decode(TrashRecord.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.kind, .directory)
    }

    func testReportsOnlyRecordsAddedAfterSessionStart() {
        let existingRecord = makeRecord(name: "Before.txt")
        let snapshot = TrashSessionSnapshot(recordsAtStart: [existingRecord])
        let newRecord = makeRecord(name: "During.txt")

        XCTAssertEqual(snapshot.addedRecords(in: [existingRecord, newRecord]), [newRecord])
    }

    func testStopsReportingSessionRecordAfterItLeavesTrash() {
        let existingRecord = makeRecord(name: "Before.txt")
        let snapshot = TrashSessionSnapshot(recordsAtStart: [existingRecord])
        let newRecord = makeRecord(name: "During.txt")

        XCTAssertEqual(snapshot.addedRecords(in: [existingRecord, newRecord]).count, 1)
        XCTAssertTrue(snapshot.addedRecords(in: [existingRecord]).isEmpty)
    }

    func testDoesNotTreatAnExistingRecordAsNewAfterOtherRecordsAreRemoved() {
        let firstRecord = makeRecord(name: "First.txt")
        let secondRecord = makeRecord(name: "Second.txt")
        let snapshot = TrashSessionSnapshot(recordsAtStart: [firstRecord, secondRecord])

        XCTAssertTrue(snapshot.addedRecords(in: [secondRecord]).isEmpty)
    }

    private func makeRecord(name: String) -> TrashRecord {
        TrashRecord(
            id: UUID(),
            deviceSerial: "test-device",
            originalPath: "/storage/emulated/0/\(name)",
            trashPath: "/storage/emulated/0/.AndroidFileBrowserTrash/\(name)",
            name: name,
            deletedAt: Date(timeIntervalSince1970: 0),
            size: 1
        )
    }
}
