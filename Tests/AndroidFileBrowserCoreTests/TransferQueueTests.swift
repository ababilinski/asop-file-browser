import XCTest
@testable import AndroidFileBrowserCore

@MainActor
final class TransferQueueTests: XCTestCase {
    func testMoveJobUsesFinderLikePresentation() {
        XCTAssertEqual(TransferJobKind.move.title, "Move")
        XCTAssertEqual(TransferJobKind.move.symbol, "arrow.right.circle")
    }

    func testAppInstallJobUsesAppPresentation() {
        XCTAssertEqual(TransferJobKind.appInstall.title, "App Install")
        XCTAssertEqual(TransferJobKind.appInstall.symbol, "arrow.down.app")
    }

    func testQueuedInstallJobsCanBeReorderedAndRemoved() async throws {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 1
        let groupID = queue.enqueueGroup(
            kind: .appInstall,
            title: "Install 3 apps",
            subtitle: "Test phone",
            source: TransferEndpoint(kind: .mac, path: "/tmp"),
            destination: TransferEndpoint(kind: .adb, deviceID: "phone", path: "apps")
        )
        let exclusiveGroup = "app-install:phone"
        let firstID = queue.enqueue(
            kind: .appInstall,
            title: "First.apk",
            subtitle: "Installing",
            source: TransferEndpoint(kind: .mac, path: "/tmp/First.apk"),
            destination: TransferEndpoint(kind: .adb, deviceID: "phone", path: "apps"),
            parentID: groupID,
            exclusiveGroup: exclusiveGroup
        ) { _ in
            try await Task.sleep(for: .milliseconds(100))
            return TransferJobResult(message: "Installed")
        }
        let secondID = queue.enqueue(
            kind: .appInstall,
            title: "Second.apk",
            subtitle: "Waiting",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Second.apk"),
            destination: TransferEndpoint(kind: .adb, deviceID: "phone", path: "apps"),
            parentID: groupID,
            exclusiveGroup: exclusiveGroup
        ) { _ in
            TransferJobResult(message: "Installed")
        }
        let thirdID = queue.enqueue(
            kind: .appInstall,
            title: "Third.apk",
            subtitle: "Waiting",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Third.apk"),
            destination: TransferEndpoint(kind: .adb, deviceID: "phone", path: "apps"),
            parentID: groupID,
            exclusiveGroup: exclusiveGroup
        ) { _ in
            TransferJobResult(message: "Installed")
        }

        XCTAssertEqual(queue.job(id: firstID)?.state, .running)
        XCTAssertTrue(queue.moveQueuedJob(thirdID, earlier: true))
        XCTAssertEqual(queue.children(of: groupID).map(\.id), [firstID, thirdID, secondID])
        XCTAssertTrue(queue.removeQueuedJob(secondID))
        XCTAssertNil(queue.job(id: secondID))

        try await waitForQueueToFinish(queue)
        XCTAssertEqual(queue.job(id: groupID)?.state, .completed)
        XCTAssertEqual(queue.children(of: groupID).map(\.id), [firstID, thirdID])
    }

    func testDeferredMoveStaysOutOfPanelUntilRevealed() async throws {
        let queue = TransferQueue()
        var jobID: UUID?
        let task = Task { @MainActor in
            try await queue.enqueueAndWait(
                kind: .move,
                title: "Folder",
                subtitle: "Moving",
                source: TransferEndpoint(kind: .usbTransfer, deviceID: "phone", path: "/Download/Folder"),
                destination: TransferEndpoint(kind: .usbTransfer, deviceID: "phone", path: "/Pictures/Folder"),
                defersPresentation: true,
                onEnqueued: { jobID = $0 }
            ) { _ in
                try await Task.sleep(for: .milliseconds(250))
                return TransferJobResult(message: "Moved")
            }
        }

        while jobID == nil {
            await Task.yield()
        }
        let id = try XCTUnwrap(jobID)
        XCTAssertTrue(queue.visibleJobs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(queue.job(id: id)).canCancel)

        XCTAssertTrue(queue.revealDeferredJob(id: id))
        XCTAssertEqual(queue.visibleJobs.map(\.id), [id])

        _ = try await task.value
        XCTAssertFalse(try XCTUnwrap(queue.job(id: id)).canRetry)
    }

    func testConflictResolverEnumeratesBeforeExtension() {
        let name = TransferConflictResolver.enumeratedName(
            for: "Photo.jpg",
            existingNames: ["photo.jpg", "photo 2.jpg"]
        )

        XCTAssertEqual(name, "Photo 3.jpg")
    }

    func testADBProgressParserUsesLastPercentInChunk() {
        let fraction = ADBProgressParser.fractionCompleted(from: "[ 12%] one\n[ 87%] two")

        XCTAssertEqual(fraction ?? -1, 0.87, accuracy: 0.001)
    }

    func testTransferQueueRunsUpToConfiguredConcurrency() async throws {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 2
        var maxObservedActive = 0
        var completed = 0

        for index in 0..<4 {
            queue.enqueue(
                kind: .download,
                title: "Download \(index)",
                subtitle: "Test",
                source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/\(index)"),
                destination: TransferEndpoint(kind: .mac, path: "/tmp/\(index)")
            ) { controller in
                maxObservedActive = max(maxObservedActive, queue.activeJobs.count)
                controller.updateProgress(fractionCompleted: 0.5)
                try await Task.sleep(for: .milliseconds(40))
                completed += 1
                return TransferJobResult()
            }
        }

        try await waitForQueueToFinish(queue)

        XCTAssertEqual(completed, 4)
        XCTAssertEqual(queue.completedCount, 4)
        XCTAssertLessThanOrEqual(maxObservedActive, 2)
    }

    func testEnqueueAndWaitReportsQueuedIDBeforeStartingAndCanDiscardFastCompletion() async throws {
        let queue = TransferQueue()
        var reportedID: UUID?
        var stateWhenReported: TransferJobState?

        _ = try await queue.enqueueAndWait(
            kind: .move,
            title: "Move Photo.jpg",
            subtitle: "Moving",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Photo.jpg"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Photo.jpg"),
            onEnqueued: { jobID in
                reportedID = jobID
                stateWhenReported = queue.job(id: jobID)?.state
            }
        ) { _ in
            TransferJobResult()
        }

        let jobID = try XCTUnwrap(reportedID)
        XCTAssertEqual(stateWhenReported, .queued)
        XCTAssertEqual(queue.job(id: jobID)?.state, .completed)
        XCTAssertTrue(queue.discardFinishedJob(id: jobID))
        XCTAssertNil(queue.job(id: jobID))
        XCTAssertFalse(queue.discardFinishedJob(id: jobID))
    }

    func testDiscardFinishedJobRejectsActiveButAcceptsCanceledAndNonRetryableFailedMove() async throws {
        enum ExpectedFailure: Error {
            case failed
        }

        let queue = TransferQueue()
        queue.maxActiveTransfers = 1

        let runningID = queue.enqueue(
            kind: .move,
            title: "Move Large.mov",
            subtitle: "Moving",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Large.mov"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Large.mov")
        ) { _ in
            try await Task.sleep(for: .seconds(5))
            return TransferJobResult()
        }
        XCTAssertFalse(queue.discardFinishedJob(id: runningID))

        let canceledID = queue.enqueue(
            kind: .move,
            title: "Move Later.txt",
            subtitle: "Waiting",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Later.txt"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Later.txt")
        ) { _ in
            TransferJobResult()
        }
        queue.cancel(jobID: canceledID)
        XCTAssertEqual(queue.job(id: canceledID)?.state, .canceled)
        XCTAssertTrue(queue.discardFinishedJob(id: canceledID))

        queue.cancel(jobID: runningID)
        try await waitForJob(queue, jobID: runningID, state: .canceled)

        let failedID = queue.enqueue(
            kind: .move,
            title: "Move Broken.txt",
            subtitle: "Moving",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Broken.txt"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Broken.txt")
        ) { _ in
            throw ExpectedFailure.failed
        }
        try await waitForJob(queue, jobID: failedID, state: .failed)
        XCTAssertTrue(queue.discardFinishedJob(id: failedID))
        XCTAssertNil(queue.job(id: failedID))
    }

    func testPreviewJobsAreHiddenFromTransferPanel() async throws {
        let queue = TransferQueue()

        queue.enqueue(
            kind: .preview,
            title: "Preview.png",
            subtitle: "Preparing preview",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Preview.png"),
            destination: TransferEndpoint(kind: .mac, path: "/tmp/Preview.png")
        ) { _ in
            TransferJobResult()
        }

        XCTAssertFalse(queue.hasVisibleJobs)
        XCTAssertTrue(queue.visibleJobs.isEmpty)

        try await waitForQueueToFinish(queue)

        XCTAssertFalse(queue.hasVisibleJobs)
        XCTAssertEqual(queue.completedCount, 0)
    }

    func testAggregateFolderJobsTrackChildrenAndClearAsUnit() async throws {
        let queue = TransferQueue()
        let groupID = queue.enqueueGroup(
            kind: .upload,
            title: "Folder",
            subtitle: "Uploading folder",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Folder"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder"),
            totalBytes: 300
        )

        for index in 0..<2 {
            queue.enqueue(
                kind: .upload,
                title: "File \(index)",
                subtitle: "Uploading",
                source: TransferEndpoint(kind: .mac, path: "/tmp/Folder/\(index)"),
                destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/\(index)"),
                parentID: groupID,
                totalBytes: index == 0 ? 100 : 200
            ) { controller in
                controller.updateProgress(fractionCompleted: 1)
                return TransferJobResult()
            }
        }

        try await waitForQueueToFinish(queue)

        let group = try XCTUnwrap(queue.jobs.first { $0.id == groupID })
        XCTAssertEqual(group.childCount, 2)
        XCTAssertEqual(group.state, .completed)
        XCTAssertEqual(group.progress.completedBytes, 300)
        XCTAssertEqual(group.progressFraction ?? -1, 1, accuracy: 0.001)

        queue.clearCompleted()

        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testUSBTransferJobsStaySingleLane() async throws {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 3
        queue.maxActiveUSBTransferJobs = 1
        var maxObservedUSBJobs = 0

        for index in 0..<3 {
            queue.enqueue(
                kind: .download,
                title: "MTP \(index)",
                subtitle: "Test",
                source: TransferEndpoint(kind: .usbTransfer, deviceID: "mtp", path: "/remote/\(index)"),
                destination: TransferEndpoint(kind: .mac, path: "/tmp/\(index)"),
                exclusiveGroup: "mtp"
            ) { _ in
                maxObservedUSBJobs = max(
                    maxObservedUSBJobs,
                    queue.activeJobs.filter { $0.source.kind == .usbTransfer || $0.destination.kind == .usbTransfer }.count
                )
                try await Task.sleep(for: .milliseconds(20))
                return TransferJobResult()
            }
        }

        try await waitForQueueToFinish(queue)

        XCTAssertEqual(queue.completedCount, 3)
        XCTAssertEqual(maxObservedUSBJobs, 1)
    }

    func testCancelRunningChildJobStopsTaskAndStartsQueuedSibling() async throws {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 1
        let groupID = queue.enqueueGroup(
            kind: .upload,
            title: "Folder",
            subtitle: "Uploading folder",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Folder"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder")
        )

        let runningChildID = queue.enqueue(
            kind: .upload,
            title: "Large file",
            subtitle: "Uploading",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Folder/Large.mov"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Large.mov"),
            parentID: groupID
        ) { controller in
            controller.updateProgress(fractionCompleted: 0.2)
            try await Task.sleep(for: .seconds(5))
            return TransferJobResult()
        }

        let siblingID = queue.enqueue(
            kind: .upload,
            title: "Small file",
            subtitle: "Uploading",
            source: TransferEndpoint(kind: .mac, path: "/tmp/Folder/Small.txt"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/Folder/Small.txt"),
            parentID: groupID
        ) { _ in
            TransferJobResult()
        }

        try await waitForJob(queue, jobID: runningChildID, state: .running)
        queue.cancel(jobID: runningChildID)

        try await waitForJob(queue, jobID: runningChildID, state: .canceled)
        try await waitForQueueToFinish(queue)

        XCTAssertEqual(queue.job(id: runningChildID)?.state, .canceled)
        XCTAssertEqual(queue.job(id: siblingID)?.state, .completed)
    }

    func testVisibleProgressFractionAggregatesVisibleRootJobs() async throws {
        let queue = TransferQueue()
        queue.maxActiveTransfers = 1
        let firstVisibleJobProgressed = expectation(description: "First visible job reported progress")
        var finishFirstVisibleJob: CheckedContinuation<Void, Never>?

        queue.enqueue(
            kind: .preview,
            title: "Preview",
            subtitle: "Hidden",
            source: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/preview.png"),
            destination: TransferEndpoint(kind: .mac, path: "/tmp/preview.png"),
            totalBytes: 100
        ) { _ in
            TransferJobResult()
        }

        queue.enqueue(
            kind: .upload,
            title: "A",
            subtitle: "Uploading",
            source: TransferEndpoint(kind: .mac, path: "/tmp/A"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/A"),
            totalBytes: 100
        ) { controller in
            controller.updateProgress(completedBytes: 50, totalBytes: 100, fractionCompleted: 0.5)
            await withCheckedContinuation { continuation in
                finishFirstVisibleJob = continuation
                firstVisibleJobProgressed.fulfill()
            }
            return TransferJobResult()
        }

        queue.enqueue(
            kind: .upload,
            title: "B",
            subtitle: "Queued",
            source: TransferEndpoint(kind: .mac, path: "/tmp/B"),
            destination: TransferEndpoint(kind: .adb, deviceID: "device", path: "/remote/B"),
            totalBytes: 100
        ) { _ in
            TransferJobResult()
        }

        await fulfillment(of: [firstVisibleJobProgressed], timeout: 1)

        XCTAssertEqual(queue.visibleProgressFraction ?? -1, 0.25, accuracy: 0.001)

        try XCTUnwrap(finishFirstVisibleJob).resume()
        try await waitForQueueToFinish(queue)

        XCTAssertEqual(queue.visibleProgressFraction ?? -1, 1, accuracy: 0.001)
    }

    func testBatchRenamePlannerDetectsCollisions() {
        let files = [
            AndroidFile(name: "A.txt", path: "/sdcard/A.txt", kind: .file, size: nil, modified: nil, permissions: nil),
            AndroidFile(name: "B.txt", path: "/sdcard/B.txt", kind: .file, size: nil, modified: nil, permissions: nil)
        ]
        let options = BatchRenameOptions(mode: .changeExtension, newExtension: "jpg")
        let previews = BatchRenamePlanner.previews(
            for: files,
            options: options,
            siblingNames: ["a.jpg"]
        )

        XCTAssertEqual(previews.map(\.proposedName), ["A.jpg", "B.jpg"])
        XCTAssertTrue(previews[0].collision)
        XCTAssertFalse(previews[1].collision)
    }

    private func waitForQueueToFinish(_ queue: TransferQueue) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !queue.unfinishedJobs.isEmpty {
            if Date() > deadline {
                XCTFail("Timed out waiting for transfer queue.")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForJob(_ queue: TransferQueue, jobID: UUID, state: TransferJobState) async throws {
        let deadline = Date().addingTimeInterval(3)
        while queue.job(id: jobID)?.state != state {
            if Date() > deadline {
                XCTFail("Timed out waiting for transfer job \(jobID) to become \(state).")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
