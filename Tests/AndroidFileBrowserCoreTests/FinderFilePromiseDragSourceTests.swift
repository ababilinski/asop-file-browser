import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class FinderFilePromiseDragSourceTests: XCTestCase {
    func testInternalFolderDragUsesCustomPayloadWithoutExternalCopy() throws {
        let payload = RemoteBrowserDragPayload(
            backend: .mtp,
            deviceID: "phone",
            items: [
                RemoteBrowserDragItem(
                    id: "folder-id",
                    path: "/Download/Folder",
                    name: "Folder",
                    isFolder: true,
                    size: nil
                )
            ]
        )
        let dragItem = try XCTUnwrap(
            FinderFilePromiseDragItem.internalOnly(
                fileName: "Folder",
                typeIdentifier: UTType.folder.identifier,
                isFolder: true,
                remoteDragPayload: payload
            )
        )
        let pasteboard = NSPasteboard(name: .init("FinderFilePromiseDragSourceTests.internal"))

        XCTAssertFalse(dragItem.supportsExternalCopy)
        XCTAssertEqual(
            dragItem.pasteboardWriter.writableTypes(for: pasteboard),
            [RemoteBrowserDragPayload.internalPasteboardType]
        )

        let data = try XCTUnwrap(
            dragItem.pasteboardWriter.pasteboardPropertyList(
                forType: RemoteBrowserDragPayload.internalPasteboardType
            ) as? Data
        )
        let decoded = try JSONDecoder().decode(RemoteBrowserDragPayload.self, from: data)
        XCTAssertEqual(decoded.backend, .mtp)
        XCTAssertEqual(decoded.deviceID, "phone")
        XCTAssertEqual(decoded.items.first?.path, "/Download/Folder")
    }

    func testFilePromiseDragStillAdvertisesExternalCopy() {
        let provider = RemoteFileDragProvider.filePromiseProvider(
            fileName: "photo.jpg",
            typeIdentifier: UTType.jpeg.identifier
        ) { _ in }
        let dragItem = FinderFilePromiseDragItem(
            provider: provider,
            fileName: "photo.jpg",
            typeIdentifier: UTType.jpeg.identifier,
            isFolder: false,
            remoteDragPayload: nil
        )
        let pasteboard = NSPasteboard(name: .init("FinderFilePromiseDragSourceTests.promise"))

        XCTAssertTrue(dragItem.supportsExternalCopy)
        XCTAssertFalse(
            dragItem.pasteboardWriter.writableTypes(for: pasteboard)
                .contains(RemoteBrowserDragPayload.internalPasteboardType)
        )
    }

    func testFolderFilePromiseAdvertisesExternalCopy() {
        let provider = RemoteFileDragProvider.filePromiseProvider(
            fileName: "Pictures",
            typeIdentifier: UTType.folder.identifier
        ) { _ in }
        let dragItem = FinderFilePromiseDragItem(
            provider: provider,
            fileName: "Pictures",
            typeIdentifier: UTType.folder.identifier,
            isFolder: true,
            remoteDragPayload: nil
        )

        XCTAssertTrue(dragItem.supportsExternalCopy)
        XCTAssertTrue(dragItem.isFolder)
        XCTAssertEqual(dragItem.typeIdentifier, UTType.folder.identifier)
    }
}
