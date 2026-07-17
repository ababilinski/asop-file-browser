import Foundation

/// Keeps opportunistic ADB thumbnail pulls from flooding the shared ADB server.
///
/// Browser rows are served in request order. A detail request can move ahead of
/// queued browser work, while an already-running pull is allowed to finish or be
/// cancelled by the task that owns it.
actor ADBThumbnailRequestScheduler {
    enum Priority: Int, Sendable {
        case browser
        case detail
    }

    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let permit: Permit
        let priority: Priority
        let order: UInt64
        let continuation: CheckedContinuation<Permit, Error>
    }

    private let maximumConcurrentRequests: Int
    private var activePermits = Set<Permit>()
    private var waiters: [Waiter] = []
    private var nextOrder: UInt64 = 0

    init(maximumConcurrentRequests: Int = 1) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func acquire(priority: Priority) async throws -> Permit {
        try Task.checkCancellation()

        let permit = Permit(id: UUID())
        if activePermits.count < maximumConcurrentRequests {
            activePermits.insert(permit)
            return permit
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let waiter = Waiter(
                    permit: permit,
                    priority: priority,
                    order: nextOrder,
                    continuation: continuation
                )
                nextOrder &+= 1
                waiters.append(waiter)
            }
        } onCancel: {
            Task { await self.cancelWaitingRequest(permit) }
        }
    }

    func release(_ permit: Permit) {
        guard activePermits.remove(permit) != nil else { return }
        resumeNextWaiterIfPossible()
    }

    func cancelAllWaitingRequests() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pending {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaitingRequest(_ permit: Permit) {
        guard let index = waiters.firstIndex(where: { $0.permit == permit }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeNextWaiterIfPossible() {
        guard activePermits.count < maximumConcurrentRequests,
              !waiters.isEmpty else {
            return
        }

        let nextIndex = waiters.indices.min { lhs, rhs in
            let left = waiters[lhs]
            let right = waiters[rhs]
            if left.priority != right.priority {
                return left.priority.rawValue > right.priority.rawValue
            }
            return left.order < right.order
        }!
        let waiter = waiters.remove(at: nextIndex)
        activePermits.insert(waiter.permit)
        waiter.continuation.resume(returning: waiter.permit)
    }
}
