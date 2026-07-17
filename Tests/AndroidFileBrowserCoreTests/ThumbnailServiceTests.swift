import XCTest
@testable import AndroidFileBrowserCore

final class ThumbnailServiceTests: XCTestCase {
    func testSourceCacheNamesKeepExtensionsAndDoNotCollideByBasename() async {
        let service = ThumbnailService()

        let first = await service.sourceCacheFileName(
            cacheKey: "phone|/DCIM/Camera/photo.jpg|100|1",
            originalName: "photo.jpg"
        )
        let second = await service.sourceCacheFileName(
            cacheKey: "phone|/Download/photo.jpg|100|1",
            originalName: "photo.jpg"
        )

        XCTAssertTrue(first.hasSuffix(".jpg"))
        XCTAssertTrue(second.hasSuffix(".jpg"))
        XCTAssertNotEqual(first, second)
    }

    func testDeviceThumbnailDataStaysCompressedAndDecodesOffMainActor() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "ThumbnailServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let service = ThumbnailService(cacheRoot: cacheRoot)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let cacheKey = "thumbnail-service-test-\(UUID().uuidString)"
        let url = try await service.storeThumbnailImageData(png, cacheKey: cacheKey)

        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent(), cacheRoot)
        XCTAssertEqual(try Data(contentsOf: url), png)
        let image = await ThumbnailImageLoader.shared.image(at: url)
        XCTAssertEqual(image?.width, 1)
        XCTAssertEqual(image?.height, 1)
    }
}
