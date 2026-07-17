import XCTest
import MTPKit
@testable import AndroidFileBrowserCore

final class USBTransferManagerParityTests: XCTestCase {
    func testKnownItemsDeduplicatesCurrentListingAndTreeCacheByID() {
        let currentItem = USBTransferItem(
            id: "42",
            name: "Pictures",
            path: "/Internal storage/Pictures",
            kind: .folder,
            size: nil,
            modified: nil,
            uti: nil
        )
        let sibling = USBTransferItem(
            id: "43",
            name: "Download",
            path: "/Internal storage/Download",
            kind: .folder,
            size: nil,
            modified: nil,
            uti: nil
        )

        let result = USBTransferManager.deduplicatedItems([
            currentItem,
            sibling,
            currentItem
        ])

        XCTAssertEqual(result.map(\.id), [currentItem.id, sibling.id])
    }

    func testOptimisticRemovalMatchesOnlyItemAndItsDescendants() {
        let ancestors = ["/Internal storage/Download/Test"]

        XCTAssertTrue(USBTransferManager.path(
            "/Internal storage/Download/Test",
            isEqualToOrDescendantOfAny: ancestors
        ))
        XCTAssertTrue(USBTransferManager.path(
            "/Internal storage/Download/Test/More/photo.jpg",
            isEqualToOrDescendantOfAny: ancestors
        ))
        XCTAssertFalse(USBTransferManager.path(
            "/Internal storage/Download/Testing/photo.jpg",
            isEqualToOrDescendantOfAny: ancestors
        ))
    }

    func testObservedAddRefreshesItsParentFolder() {
        let node = FileNode(
            id: "photo",
            storageID: "primary",
            parentID: "pictures",
            name: "photo.jpg",
            isDirectory: false,
            size: 12,
            modifiedDate: nil,
            fileExtension: "jpg"
        )

        XCTAssertEqual(
            USBTransferManager.mtpObservedRefreshScopes(for: .added(node), knownNodes: []),
            [.folder(storageID: "primary", parentID: "pictures")]
        )
    }

    func testObservedMoveRefreshesOldAndNewParents() {
        let previous = FileNode(
            id: "photo",
            storageID: "primary",
            parentID: "pictures",
            name: "photo.jpg",
            isDirectory: false,
            size: 12,
            modifiedDate: nil,
            fileExtension: "jpg"
        )
        let moved = FileNode(
            id: "photo",
            storageID: "primary",
            parentID: "download",
            name: "photo.jpg",
            isDirectory: false,
            size: 12,
            modifiedDate: nil,
            fileExtension: "jpg"
        )

        XCTAssertEqual(
            USBTransferManager.mtpObservedRefreshScopes(for: .changed(moved), knownNodes: [previous]),
            [
                .folder(storageID: "primary", parentID: "pictures"),
                .folder(storageID: "primary", parentID: "download")
            ]
        )
    }

    func testObservedRemoveUsesKnownParentAndUnknownRemoveFallsBackSafely() {
        let previous = FileNode(
            id: "photo",
            storageID: "primary",
            parentID: "pictures",
            name: "photo.jpg",
            isDirectory: false,
            size: 12,
            modifiedDate: nil,
            fileExtension: "jpg"
        )

        XCTAssertEqual(
            USBTransferManager.mtpObservedRefreshScopes(for: .removed(id: "photo"), knownNodes: [previous]),
            [.folder(storageID: "primary", parentID: "pictures")]
        )
        XCTAssertEqual(
            USBTransferManager.mtpObservedRefreshScopes(for: .removed(id: "missing"), knownNodes: []),
            [.allVisibleFolders]
        )
    }

    func testStorageChangeRefreshesStorageMetadataAndVisibleFolders() {
        XCTAssertEqual(
            USBTransferManager.mtpObservedRefreshScopes(for: .storagesChanged, knownNodes: []),
            [.storageList, .allVisibleFolders]
        )
    }
}
