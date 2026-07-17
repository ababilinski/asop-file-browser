import XCTest
@testable import AndroidFileBrowserCore

final class ADBThumbnailRequestSchedulerTests: XCTestCase {
    func testLimitsConcurrentThumbnailRequests() async throws {
        let scheduler = ADBThumbnailRequestScheduler(maximumConcurrentRequests: 1)
        let blocker = try await scheduler.acquire(priority: .browser)
        let probe = ThumbnailConcurrencyProbe()

        let tasks = (0..<8).map { _ in
            Task {
                let permit = try await scheduler.acquire(priority: .browser)
                await probe.enter()
                try await Task.sleep(for: .milliseconds(4))
                await probe.leave()
                await scheduler.release(permit)
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        await scheduler.release(blocker)
        for task in tasks {
            try await task.value
        }

        let maximumActiveCount = await probe.maximumActiveCount
        XCTAssertEqual(maximumActiveCount, 1)
    }

    func testDetailRequestMovesAheadOfQueuedBrowserRequests() async throws {
        let scheduler = ADBThumbnailRequestScheduler(maximumConcurrentRequests: 1)
        let blocker = try await scheduler.acquire(priority: .browser)
        let order = ThumbnailCompletionOrder()

        let firstBrowser = Task {
            let permit = try await scheduler.acquire(priority: .browser)
            await order.append("browser-1")
            await scheduler.release(permit)
        }
        let secondBrowser = Task {
            let permit = try await scheduler.acquire(priority: .browser)
            await order.append("browser-2")
            await scheduler.release(permit)
        }
        try await Task.sleep(for: .milliseconds(20))
        let detail = Task {
            let permit = try await scheduler.acquire(priority: .detail)
            await order.append("detail")
            await scheduler.release(permit)
        }
        try await Task.sleep(for: .milliseconds(20))

        await scheduler.release(blocker)
        try await detail.value
        try await firstBrowser.value
        try await secondBrowser.value

        let completed = await order.values
        XCTAssertEqual(completed.first, "detail")
        XCTAssertEqual(Set(completed.dropFirst()), ["browser-1", "browser-2"])
    }

    func testCancelledQueuedRequestDoesNotConsumeTheLane() async throws {
        let scheduler = ADBThumbnailRequestScheduler(maximumConcurrentRequests: 1)
        let blocker = try await scheduler.acquire(priority: .browser)
        let queued = Task {
            try await scheduler.acquire(priority: .browser)
        }

        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("A cancelled queued request should not receive a permit.")
        } catch is CancellationError {
            // Expected.
        }

        await scheduler.release(blocker)
        let next = try await scheduler.acquire(priority: .browser)
        await scheduler.release(next)
    }
}

private actor ThumbnailConcurrencyProbe {
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func enter() {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}

private actor ThumbnailCompletionOrder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
