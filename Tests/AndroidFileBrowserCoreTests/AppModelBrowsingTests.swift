import Foundation
import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class AppModelBrowsingTests: XCTestCase {
    func testFolderSizePreparationFollowsTheBrowserSetting() {
        let model = makeModel()

        XCTAssertTrue(model.automaticallyPreparesFolderSizes)

        model.settings.calculateFolderSizes = false

        XCTAssertFalse(model.automaticallyPreparesFolderSizes)
    }

    func testLatestFolderNavigationWinsAndCancelsPreviousListing() async throws {
        let runner = DelayedNavigationProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id

        let home = QuickLocation(id: "home", title: "Phone", path: "/storage/emulated/0", symbol: "iphone")
        let pictures = QuickLocation(id: "pictures", title: "Pictures", path: "/storage/emulated/0/Pictures", symbol: "photo")
        model.open(destination: .location(home))
        try await Task.sleep(for: .milliseconds(30))
        model.open(destination: .location(pictures))

        try await waitUntil(timeout: .seconds(2)) {
            model.files.map(\.name) == ["picture.jpg"] && !model.isLoadingCurrentFolder
        }
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(model.currentPath, pictures.path)
        XCTAssertEqual(model.files.map(\.name), ["picture.jpg"])
        let rootCancellationCount = await runner.rootCancellationCount()
        XCTAssertGreaterThanOrEqual(rootCancellationCount, 1)
    }

    func testSelectionChangesPathBarButNotNavigationBreadcrumb() {
        let model = makeModel()
        let child = AndroidFile(
            name: ".hidden",
            path: "/storage/emulated/0/Download/Test/.hidden",
            kind: .file,
            size: 1,
            modified: nil,
            permissions: nil
        )
        model.currentPath = "/storage/emulated/0/Download"
        model.files = [child]
        model.selectedFileIDs = [child.id]

        XCTAssertEqual(model.breadcrumbPath, "/storage/emulated/0/Download")
        XCTAssertEqual(model.pathBarPath, child.path)
    }

    func testMultipleSelectionKeepsCurrentFolderAndFolderIconInPathBar() {
        let model = makeModel()
        let first = AndroidFile(
            name: "one.txt",
            path: "/storage/emulated/0/Download/one.txt",
            kind: .file,
            size: 1,
            modified: nil,
            permissions: nil
        )
        let second = AndroidFile(
            name: "two.txt",
            path: "/storage/emulated/0/Download/two.txt",
            kind: .file,
            size: 1,
            modified: nil,
            permissions: nil
        )
        model.currentPath = "/storage/emulated/0/Download"
        model.files = [first, second]
        model.selectedFileIDs = [first.id, second.id]

        XCTAssertEqual(model.pathBarPath, model.currentPath)
        XCTAssertTrue(model.pathBarShowsFolder)
    }

    func testBackAndForwardRestoreADBFolderHistory() async throws {
        let runner = DelayedNavigationProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        model.settings.calculateFolderSizes = false
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id

        model.navigate(to: "/storage/emulated/0/Pictures")
        try await waitUntil(timeout: .seconds(2)) { !model.isLoadingCurrentFolder }
        XCTAssertTrue(model.canNavigateBack)

        model.navigateBack()
        try await waitUntil(timeout: .seconds(2)) {
            model.currentPath == "/storage/emulated/0" && !model.isLoadingCurrentFolder
        }
        XCTAssertTrue(model.canNavigateForward)

        model.navigateForward()
        try await waitUntil(timeout: .seconds(2)) {
            model.currentPath == "/storage/emulated/0/Pictures" && !model.isLoadingCurrentFolder
        }
    }

    func testSidebarShortcutCanBeRevealedInItsEnclosingFolder() async throws {
        let runner = DelayedNavigationProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        model.settings.calculateFolderSizes = false
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        let pictures = QuickLocation(
            id: "pictures",
            title: "Pictures",
            path: "/storage/emulated/0/Pictures",
            symbol: "photo"
        )

        model.showQuickLocationInEnclosingFolder(pictures)

        try await waitUntil(timeout: .seconds(2)) {
            model.currentPath == "/storage/emulated/0"
                && model.selectedFileIDs == [pictures.path]
                && !model.isLoadingCurrentFolder
        }
        XCTAssertEqual(model.breadcrumbPath, "/storage/emulated/0")
        XCTAssertEqual(model.selectedFile?.path, pictures.path)
    }

    func testFolderSizesAreSerializedAndEmptyFoldersDisplayZeroBytes() async throws {
        let runner = FolderSizeProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        model.open(destination: .location(QuickLocation(
            id: "home",
            title: "Phone",
            path: "/storage/emulated/0",
            symbol: "iphone"
        )))

        try await waitUntil(timeout: .seconds(3)) {
            model.folderSizeBytesByPath.count == 2
        }

        let maximumConcurrentSizeCommands = await runner.maximumConcurrentSizeCommands()
        XCTAssertEqual(maximumConcurrentSizeCommands, 1)
        XCTAssertEqual(Set(model.folderSizeBytesByPath.values), [0])
        let commands = await runner.sizeCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.contains("-mindepth 1 -type f") })
        XCTAssertTrue(commands.allSatisfy { !$0.contains("! -name '.'") && !$0.contains("-not -path") })
    }

    func testInternalDropMovesFileIntoExpandedFolderWithoutNavigating() async throws {
        let runner = RemoteMoveProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        model.settings.calculateFolderSizes = false
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        model.sidebarSelection = .location(QuickLocation(id: "test", title: "Test", path: RemoteMoveProcessRunner.root, symbol: "folder"))
        model.currentPath = RemoteMoveProcessRunner.root

        let source = AndroidFile(
            name: "move-me.txt",
            path: "\(RemoteMoveProcessRunner.root)/move-me.txt",
            kind: .file,
            size: 9,
            modified: nil,
            permissions: nil
        )
        let destination = AndroidFile(
            name: "More",
            path: RemoteMoveProcessRunner.destination,
            kind: .directory,
            size: nil,
            modified: nil,
            permissions: nil
        )
        model.files = [source, destination]
        let payload = RemoteBrowserDragPayload(
            backend: .adb,
            deviceID: device.serial,
            items: [RemoteBrowserDragItem(id: source.id, path: source.path, name: source.name, isFolder: false, size: source.size)]
        )

        XCTAssertTrue(model.canAcceptRemoteDrop(payload, into: destination))
        model.moveRemoteDrop(payload, into: destination)

        try await waitUntil(timeout: .seconds(1)) {
            model.treeChildrenByPath[destination.path]?.contains(where: { $0.name == source.name }) == true
        }

        let moveHadFinishedWhenRowChanged = await runner.didMoveFile()
        XCTAssertFalse(moveHadFinishedWhenRowChanged, "The browser should relocate the row before the phone command finishes.")
        XCTAssertEqual(model.currentPath, RemoteMoveProcessRunner.root)
        XCTAssertEqual(model.breadcrumbPath, RemoteMoveProcessRunner.root)

        try await waitUntil(timeout: .seconds(2)) {
            model.statusMessage == "Moved 1 item to More."
        }

        XCTAssertEqual(model.currentPath, RemoteMoveProcessRunner.root)
        XCTAssertEqual(model.breadcrumbPath, RemoteMoveProcessRunner.root)
        XCTAssertTrue(model.expandedTreePaths.contains(destination.path))
        XCTAssertEqual(model.treeChildrenByPath[destination.path]?.map(\.name), [source.name])
        XCTAssertFalse(model.files.contains(where: { $0.path == source.path }))
        let didMoveFile = await runner.didMoveFile()
        XCTAssertTrue(didMoveFile)
    }

    func testTrashRemovalIsImmediateAndPreservesNavigationState() async throws {
        let runner = DelayedTrashProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        model.settings.calculateFolderSizes = false
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        model.currentPath = DelayedTrashProcessRunner.root

        let file = AndroidFile(
            name: "delete-me.txt",
            path: "\(DelayedTrashProcessRunner.root)/delete-me.txt",
            kind: .file,
            size: 12,
            modified: nil,
            permissions: nil
        )
        let expandedFolderPath = "\(DelayedTrashProcessRunner.root)/Keep-Expanded"
        model.files = [
            file,
            AndroidFile(
                name: "Keep-Expanded",
                path: expandedFolderPath,
                kind: .directory,
                size: nil,
                modified: nil,
                permissions: nil
            )
        ]
        model.expandedTreePaths = [expandedFolderPath]
        model.selectedFileIDs = [file.id]

        let deletion = Task { await model.deleteSelectedToTrash() }
        try await waitUntil(timeout: .seconds(1)) {
            !model.files.contains(where: { $0.path == file.path })
        }

        let trashMoveHadFinishedWhenRowChanged = await runner.didFinishTrashMove()
        XCTAssertFalse(trashMoveHadFinishedWhenRowChanged, "The row should disappear before the phone finishes moving it.")
        XCTAssertEqual(model.currentPath, DelayedTrashProcessRunner.root)
        XCTAssertTrue(model.expandedTreePaths.contains(expandedFolderPath))

        await deletion.value
        let didFinishTrashMove = await runner.didFinishTrashMove()
        XCTAssertTrue(didFinishTrashMove)
        XCTAssertEqual(model.trashRecords.map(\.name), [file.name])
        XCTAssertEqual(model.currentPath, DelayedTrashProcessRunner.root)
        XCTAssertTrue(model.expandedTreePaths.contains(expandedFolderPath))
    }

    func testExpandedFolderShowsCachedChildrenWhileItRefreshes() async throws {
        let runner = CachedTreeProcessRunner()
        let adb = ADBClient(
            locator: ToolchainLocator(adbOverride: URL(fileURLWithPath: "/tmp/test-adb")),
            runner: runner
        )
        let model = makeModel(adb: adb)
        model.settings.calculateFolderSizes = false
        let device = AndroidDevice(serial: "test-device", state: .device, model: "Test Phone", product: nil, transport: nil)
        model.devices = [device]
        model.selectedDeviceID = device.id
        model.currentPath = CachedTreeProcessRunner.root
        let folder = AndroidFile(
            name: "Pictures",
            path: CachedTreeProcessRunner.folder,
            kind: .directory,
            size: nil,
            modified: nil,
            permissions: nil
        )
        model.files = [folder]

        model.setTreeExpanded(folder, expanded: true)
        try await waitUntil(timeout: .seconds(1)) {
            model.treeChildrenByPath[folder.path]?.map(\.name) == ["first.jpg"]
                && !model.loadingTreePaths.contains(folder.path)
        }

        model.setTreeExpanded(folder, expanded: false)
        model.setTreeExpanded(folder, expanded: true)

        XCTAssertEqual(model.treeChildrenByPath[folder.path]?.map(\.name), ["first.jpg"])
        XCTAssertTrue(model.loadingTreePaths.contains(folder.path))

        try await waitUntil(timeout: .seconds(2)) {
            model.treeChildrenByPath[folder.path]?.map(\.name) == ["first.jpg", "second.jpg"]
                && !model.loadingTreePaths.contains(folder.path)
        }
    }

    private func makeModel(adb: ADBClient = ADBClient()) -> AppModel {
        let suiteName = "AndroidFileBrowserCoreTests.AppModelBrowsing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(
            adb: adb,
            settings: AppSettings(defaults: defaults),
            initialTrashRecords: []
        )
    }

    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor RemoteMoveProcessRunner: ProcessRunning {
    static let root = "/storage/emulated/0/Download/.drag-test"
    static let destination = "\(root)/Test/More"
    private var movedFile = false

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }
        let command = arguments.last ?? ""
        if command.hasPrefix("mv ") {
            try await Task.sleep(for: .milliseconds(350))
            movedFile = true
            return result("")
        }
        if command.contains("test -e") {
            return result("1")
        }
        if command.contains("find '\(Self.destination)' -mindepth 1 -maxdepth 1") {
            return movedFile
                ? result("-rw-r--r--|9|1770000000|1770000000|\(Self.destination)/move-me.txt\n")
                : result("")
        }
        if command.contains("find '\(Self.root)' -mindepth 1 -maxdepth 1") {
            return result("drwxr-xr-x|0|1770000000|1770000000|\(Self.root)/Test\n")
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

    func didMoveFile() -> Bool { movedFile }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}

private actor DelayedTrashProcessRunner: ProcessRunning {
    static let root = "/storage/emulated/0/Download/AndroidFileBrowserShowcase/Test"
    private var finishedTrashMove = false

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }

        let command = arguments.last ?? ""
        if command.hasPrefix("mkdir -p ") {
            return result("")
        }
        if command.hasPrefix("mv "), command.contains(".AndroidFileBrowserTrash") {
            try await Task.sleep(for: .milliseconds(350))
            finishedTrashMove = true
            return result("")
        }
        if command.contains("find '\(Self.root)' -mindepth 1 -maxdepth 1") {
            return result("drwxr-xr-x|0|1770000000|1770000000|\(Self.root)/Keep-Expanded\n")
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

    func didFinishTrashMove() -> Bool { finishedTrashMove }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}

private actor CachedTreeProcessRunner: ProcessRunning {
    static let root = "/storage/emulated/0"
    static let folder = "\(root)/Pictures"
    private var listingCount = 0

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }
        let command = arguments.last ?? ""
        guard command.contains("find '\(Self.folder)' -mindepth 1 -maxdepth 1") else {
            return result("")
        }
        listingCount += 1
        if listingCount > 1 {
            try await Task.sleep(for: .milliseconds(350))
            return result("""
            -rw-r--r--|10|1770000000|1770000000|\(Self.folder)/first.jpg
            -rw-r--r--|11|1770000001|1770000001|\(Self.folder)/second.jpg
            """)
        }
        return result("-rw-r--r--|10|1770000000|1770000000|\(Self.folder)/first.jpg\n")
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

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}

private actor FolderSizeProcessRunner: ProcessRunning {
    private var activeSizeCommands = 0
    private var maximumActiveSizeCommands = 0
    private var recordedSizeCommands: [String] = []

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }
        let command = arguments.last ?? ""
        if command.contains("-mindepth 1 -type f") {
            activeSizeCommands += 1
            maximumActiveSizeCommands = max(maximumActiveSizeCommands, activeSizeCommands)
            recordedSizeCommands.append(command)
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                activeSizeCommands -= 1
                throw error
            }
            activeSizeCommands -= 1
            return result("0")
        }
        if command.contains("-maxdepth 1") {
            return result("""
            drwxr-xr-x|0|1770000000|1770000000|/storage/emulated/0/Recordings
            drwxr-xr-x|0|1770000000|1770000000|/storage/emulated/0/.thumbnails
            """)
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

    func maximumConcurrentSizeCommands() -> Int { maximumActiveSizeCommands }
    func sizeCommands() -> [String] { recordedSizeCommands }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(stdoutData: Data(output.utf8), stderrData: Data(), exitCode: 0)
    }
}

private actor DelayedNavigationProcessRunner: ProcessRunning {
    private var canceledRootListings = 0

    func run(executable: URL, arguments: [String]) async throws -> ADBCommandResult {
        if arguments == ["version"] {
            return result("Android Debug Bridge version 1.0.41\nVersion 37.0.0-test\n")
        }

        let command = arguments.last ?? ""
        if command.contains("/storage/emulated/0/Pictures") {
            try await Task.sleep(for: .milliseconds(40))
            return result("-rw-r--r--|42|1770000000|1770000000|/storage/emulated/0/Pictures/picture.jpg\n")
        }
        if command.contains("/storage/emulated/0") {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch is CancellationError {
                canceledRootListings += 1
                throw CancellationError()
            }
            return result("drwxr-xr-x|0|1770000000|1770000000|/storage/emulated/0/Pictures\n")
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

    func rootCancellationCount() -> Int {
        canceledRootListings
    }

    private func result(_ output: String) -> ADBCommandResult {
        ADBCommandResult(
            stdoutData: Data(output.utf8),
            stderrData: Data(),
            exitCode: 0
        )
    }
}
