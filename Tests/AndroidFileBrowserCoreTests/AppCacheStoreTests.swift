import Foundation
import XCTest
@testable import AndroidFileBrowserCore

final class AppCacheStoreTests: XCTestCase {
    func testUsageAndSeparateClearOperations() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(cacheRoot: root)

        try write(bytes: 120, to: root.appending(path: "AndroidFileBrowserPreviews/preview.bin"))
        try write(bytes: 80, to: root.appending(path: "AndroidFileBrowserAPKIcons/icon.png"))
        try write(bytes: 40, to: root.appending(path: "AndroidFileBrowserThumbnails/thumb.png"))
        try write(bytes: 500, to: root.appending(path: "UnrelatedAppCache/data.bin"))

        let initialUsage = await store.usage()
        XCTAssertEqual(initialUsage, AppCacheUsage(previewBytes: 200, thumbnailBytes: 40))

        try await store.clearPreviewFiles()
        let thumbnailOnlyUsage = await store.usage()
        XCTAssertEqual(thumbnailOnlyUsage, AppCacheUsage(previewBytes: 0, thumbnailBytes: 40))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "UnrelatedAppCache/data.bin").path))

        try await store.clearThumbnails()
        let emptyUsage = await store.usage()
        XCTAssertEqual(emptyUsage, .zero)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: AppCacheStore.thumbnailFolderName).path
        ))
    }

    func testTrimRemovesOldestFilesAndProtectsActivePreview() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(cacheRoot: root)
        let oldURL = root.appending(path: "AndroidFileBrowserPreviews/old.bin")
        let protectedURL = root.appending(path: "AndroidFileBrowserPreviews/active.bin")
        let newURL = root.appending(path: "AndroidFileBrowserThumbnails/new.bin")

        try write(bytes: 100, to: oldURL)
        try write(bytes: 100, to: protectedURL)
        try write(bytes: 100, to: newURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: protectedURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newURL.path)

        let usage = try await store.trim(toByteLimit: 150, protecting: [protectedURL])

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: AppCacheStore.thumbnailFolderName).path
        ))
        XCTAssertEqual(usage.totalBytes, 100)
    }

    func testEncryptedPreviewIsStoredAsCiphertextAndReadableCopyIsRemovedOnRelease() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x2A, count: 32))
        let cacheURL = root.appending(path: "AndroidFileBrowserPreviews/photo.jpg")
        let stagingDirectory = try await store.makePreviewStagingDirectory()
        let sourceURL = stagingDirectory.appending(path: "photo.jpg")
        let contents = Data("private preview contents".utf8)
        try contents.write(to: sourceURL)

        try await store.storePreview(from: sourceURL, at: cacheURL, encrypt: true)

        let encryptedURL = cacheURL.appendingPathExtension("afbpreview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        XCTAssertNil(try Data(contentsOf: encryptedURL).range(of: contents))

        let encryptedReadableURL = try await store.readablePreviewURL(for: cacheURL, encrypt: true)
        let readableURL = try XCTUnwrap(encryptedReadableURL)
        XCTAssertEqual(try Data(contentsOf: readableURL), contents)
        XCTAssertEqual(try posixPermissions(for: readableURL), 0o600)

        await store.releaseReadablePreview(readableURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: readableURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
    }

    func testUnencryptedPreviewUsesNormalCacheFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x2A, count: 32))
        let cacheURL = root.appending(path: "AndroidFileBrowserPreviews/video.mp4")
        let stagingDirectory = try await store.makePreviewStagingDirectory()
        let sourceURL = stagingDirectory.appending(path: "video.mp4")
        let contents = Data("fast preview".utf8)
        try contents.write(to: sourceURL)

        try await store.storePreview(from: sourceURL, at: cacheURL, encrypt: false)
        let unencryptedReadableURL = try await store.readablePreviewURL(for: cacheURL, encrypt: false)
        let readableURL = try XCTUnwrap(unencryptedReadableURL)

        XCTAssertEqual(readableURL.standardizedFileURL, cacheURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: readableURL), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.appendingPathExtension("afbpreview").path))
        await store.releaseReadablePreview(readableURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testExpirationProtectsOpenPreviewThenDeletesItAfterRelease() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x2A, count: 32))
        let cacheURL = root.appending(path: "AndroidFileBrowserPreviews/document.pdf")
        try write(bytes: 64, to: cacheURL)
        try await store.reprotectPreviewFiles(encrypt: true)
        let encryptedURL = cacheURL.appendingPathExtension("afbpreview")
        let encryptedReadableURL = try await store.readablePreviewURL(for: cacheURL, encrypt: true)
        let readableURL = try XCTUnwrap(encryptedReadableURL)
        let oldDate = Date(timeIntervalSince1970: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: encryptedURL.path)

        _ = try await store.expirePreviewFiles(olderThan: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))

        await store.releaseReadablePreview(readableURL)
        _ = try await store.expirePreviewFiles(olderThan: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: encryptedURL.path))
    }

    func testTurningOffEncryptionDiscardsEncryptedCacheWithoutLoadingKey() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryptedStore = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x2A, count: 32))
        let cacheURL = root.appending(path: "AndroidFileBrowserUSBTransferPreviews/song.flac")
        let contents = Data("audio preview".utf8)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: cacheURL)

        _ = try await encryptedStore.reprotectPreviewFiles(encrypt: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.appendingPathExtension("afbpreview").path))

        let keyProvider = EncryptionKeyProviderSpy()
        let unencryptedStore = AppCacheStore(
            cacheRoot: root,
            encryptionKeyProvider: { keyProvider.loadKey() }
        )
        _ = try await unencryptedStore.reprotectPreviewFiles(encrypt: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.appendingPathExtension("afbpreview").path))
        XCTAssertEqual(keyProvider.callCount, 0)
    }

    func testUnencryptedPreviewDoesNotLoadEncryptionKey() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keyProvider = EncryptionKeyProviderSpy()
        let store = AppCacheStore(
            cacheRoot: root,
            encryptionKeyProvider: { keyProvider.loadKey() }
        )
        let cacheURL = root.appending(path: "AndroidFileBrowserPreviews/photo.jpg")
        let stagingDirectory = try await store.makePreviewStagingDirectory()
        let sourceURL = stagingDirectory.appending(path: "photo.jpg")
        try Data("ordinary preview".utf8).write(to: sourceURL)

        try await store.storePreview(from: sourceURL, at: cacheURL, encrypt: false)
        _ = try await store.readablePreviewURL(for: cacheURL, encrypt: false)

        XCTAssertEqual(keyProvider.callCount, 0)
    }

    func testStartupRemovesAbandonedRuntimeCopiesWithoutTouchingCurrentProcess() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appending(path: AppCacheStore.runtimePreviewFolderName)
        let abandonedURL = runtimeRoot.appending(path: "99999999-old/readable.txt")
        let currentURL = runtimeRoot.appending(
            path: "\(ProcessInfo.processInfo.processIdentifier)-active/readable.txt"
        )
        try write(bytes: 12, to: abandonedURL)
        try write(bytes: 12, to: currentURL)

        _ = AppCacheStore(cacheRoot: root, encryptionKeyData: Data(repeating: 0x2A, count: 32))

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "AndroidFileBrowserCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func posixPermissions(for url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class EncryptionKeyProviderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func loadKey() -> Data? {
        lock.withLock { calls += 1 }
        return Data(repeating: 0x2A, count: 32)
    }
}
