import Foundation

public enum TransferJobKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case upload
    case download
    case move
    case preview
    case paste
    case appBackup
    case export
    case other

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .upload: "Upload"
        case .download: "Download"
        case .move: "Move"
        case .preview: "Preview"
        case .paste: "Paste"
        case .appBackup: "APK Backup"
        case .export: "Export"
        case .other: "Transfer"
        }
    }

    var symbol: String {
        switch self {
        case .upload: "square.and.arrow.up"
        case .download: "square.and.arrow.down"
        case .move: "arrow.right.circle"
        case .preview: "eye"
        case .paste: "doc.on.clipboard"
        case .appBackup: "app.badge"
        case .export: "arrow.up.doc"
        case .other: "arrow.left.arrow.right"
        }
    }
}

public enum TransferItemKind: String, Codable, Sendable {
    case file
    case folder
}

public enum TransferEndpointKind: String, Codable, Sendable {
    case adb
    case usbTransfer
    case mac
}

public struct TransferEndpoint: Hashable, Codable, Sendable {
    public let kind: TransferEndpointKind
    public let deviceID: String?
    public let path: String
    public let displayName: String

    public init(kind: TransferEndpointKind, deviceID: String? = nil, path: String, displayName: String? = nil) {
        self.kind = kind
        self.deviceID = deviceID
        self.path = path
        self.displayName = displayName ?? path
    }

    var isUSBTransfer: Bool {
        kind == .usbTransfer
    }
}

public enum TransferJobState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case canceled

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .canceled:
            true
        case .queued, .running:
            false
        }
    }
}

public struct TransferProgressSnapshot: Hashable, Codable, Sendable {
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public var fractionCompleted: Double?
    public var message: String?

    public init(completedBytes: Int64? = nil, totalBytes: Int64? = nil, fractionCompleted: Double? = nil, message: String? = nil) {
        let clampedFraction = fractionCompleted.map { min(max($0, 0), 1) }
        self.totalBytes = totalBytes
        if let completedBytes {
            self.completedBytes = completedBytes
        } else if let clampedFraction, let totalBytes, totalBytes > 0 {
            self.completedBytes = Int64((Double(totalBytes) * clampedFraction).rounded())
        } else {
            self.completedBytes = nil
        }

        if let clampedFraction {
            self.fractionCompleted = clampedFraction
        } else if let completedBytes = self.completedBytes, let totalBytes, totalBytes > 0 {
            self.fractionCompleted = min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        } else {
            self.fractionCompleted = nil
        }
        self.message = message
    }
}

public struct TransferJobResult: Sendable {
    public var outputURL: URL?
    public var message: String?

    public init(outputURL: URL? = nil, message: String? = nil) {
        self.outputURL = outputURL
        self.message = message
    }
}

public struct TransferJob: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: TransferJobKind
    public var title: String
    public var subtitle: String
    public var source: TransferEndpoint
    public var destination: TransferEndpoint
    public var itemKind: TransferItemKind
    public var parentID: UUID?
    public var childCount: Int
    public var isAggregate: Bool
    public var state: TransferJobState
    public var progress: TransferProgressSnapshot
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?
    public var outputURL: URL?
    public var exclusiveGroup: String?
    public var cancelRequested = false

    public var isFinished: Bool {
        state.isFinished
    }

    public var progressFraction: Double? {
        progress.fractionCompleted
    }

    public var isVisibleInPanel: Bool {
        kind != .preview
    }

    public var canCancel: Bool {
        !isFinished && kind != .move
    }

    public var canRetry: Bool {
        state == .failed && !isAggregate && kind != .move
    }
}

public struct TransferCancellationError: LocalizedError, Sendable {
    public var errorDescription: String? { "Transfer canceled." }
}

public final class TransferJobController: @unchecked Sendable {
    public let jobID: UUID
    private weak var queue: TransferQueue?

    @MainActor
    fileprivate init(jobID: UUID, queue: TransferQueue) {
        self.jobID = jobID
        self.queue = queue
    }

    @MainActor
    public func updateProgress(
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        fractionCompleted: Double? = nil,
        message: String? = nil
    ) {
        queue?.updateProgress(
            jobID: jobID,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fractionCompleted: fractionCompleted,
            message: message
        )
    }

    @MainActor
    public func checkCancellation() throws {
        if Task.isCancelled || queue?.job(id: jobID)?.cancelRequested == true {
            throw TransferCancellationError()
        }
    }
}

public typealias TransferOperation = @MainActor (TransferJobController) async throws -> TransferJobResult?

@MainActor
public final class TransferQueue: ObservableObject {
    @Published public private(set) var jobs: [TransferJob] = []
    @Published public private(set) var deferredPresentationJobIDs = Set<UUID>()
    @Published public var isPanelExpanded = false
    @Published public var expandedJobIDs = Set<UUID>()
    @Published public var selectedJobID: UUID?

    public var maxActiveTransfers = 3
    public var maxActiveUSBTransferJobs = 1

    private var operations: [UUID: TransferOperation] = [:]
    private var continuations: [UUID: CheckedContinuation<Result<TransferJobResult?, Error>, Never>] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var failureHandler: ((Error) -> Void)?

    public init() {}

    public func configureFailureHandler(_ handler: @escaping (Error) -> Void) {
        failureHandler = handler
    }

    public var activeJobs: [TransferJob] {
        jobs.filter { $0.state == .running && !$0.isAggregate }
    }

    public var unfinishedJobs: [TransferJob] {
        jobs.filter { !$0.isFinished }
    }

    public var completedCount: Int {
        visibleRootJobs.filter { $0.state == .completed }.count
    }

    public var failedCount: Int {
        visibleRootJobs.filter { $0.state == .failed }.count
    }

    public var hasVisibleJobs: Bool {
        !visibleJobs.isEmpty
    }

    public var visibleJobs: [TransferJob] {
        jobs.filter { $0.isVisibleInPanel && !deferredPresentationJobIDs.contains($0.id) }
    }

    public var visibleRootJobs: [TransferJob] {
        visibleJobs.filter { $0.parentID == nil }
    }

    public var visibleProgressFraction: Double? {
        progressFraction(for: visibleRootJobs)
    }

    public func children(of jobID: UUID) -> [TransferJob] {
        visibleJobs.filter { $0.parentID == jobID }
    }

    public func isExpanded(_ jobID: UUID) -> Bool {
        expandedJobIDs.contains(jobID)
    }

    public func toggleExpanded(_ jobID: UUID) {
        if expandedJobIDs.contains(jobID) {
            expandedJobIDs.remove(jobID)
        } else {
            expandedJobIDs.insert(jobID)
        }
    }

    public func select(jobID: UUID) {
        selectedJobID = jobID
    }

    private func progressFraction(for jobs: [TransferJob]) -> Double? {
        guard !jobs.isEmpty else { return nil }

        let byteJobs = jobs.filter { ($0.progress.totalBytes ?? 0) > 0 }
        if byteJobs.count == jobs.count {
            let totalBytes = byteJobs.reduce(Int64(0)) { $0 + ($1.progress.totalBytes ?? 0) }
            guard totalBytes > 0 else { return unitProgressFraction(for: jobs) }

            let completedBytes = byteJobs.reduce(Int64(0)) { total, job in
                let jobTotalBytes = job.progress.totalBytes ?? 0
                if job.state == .completed {
                    return total + jobTotalBytes
                }
                if let completedBytes = job.progress.completedBytes {
                    return total + min(max(completedBytes, 0), jobTotalBytes)
                }
                let fraction = job.progressFraction ?? 0
                return total + Int64((Double(jobTotalBytes) * min(max(fraction, 0), 1)).rounded())
            }
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }

        return unitProgressFraction(for: jobs)
    }

    private func unitProgressFraction(for jobs: [TransferJob]) -> Double? {
        guard !jobs.isEmpty else { return nil }
        let completedUnits = jobs.reduce(Double(0)) { total, job in
            if job.state == .completed {
                return total + 1
            }
            return total + min(max(job.progressFraction ?? 0, 0), 1)
        }
        return min(max(completedUnits / Double(jobs.count), 0), 1)
    }

    @discardableResult
    public func enqueue(
        kind: TransferJobKind,
        title: String,
        subtitle: String,
        source: TransferEndpoint,
        destination: TransferEndpoint,
        itemKind: TransferItemKind = .file,
        parentID: UUID? = nil,
        totalBytes: Int64? = nil,
        exclusiveGroup: String? = nil,
        operation: @escaping TransferOperation
    ) -> UUID {
        let id = UUID()
        jobs.append(
            TransferJob(
                id: id,
                kind: kind,
                title: title,
                subtitle: subtitle,
                source: source,
                destination: destination,
                itemKind: itemKind,
                parentID: parentID,
                childCount: 0,
                isAggregate: false,
                state: .queued,
                progress: TransferProgressSnapshot(totalBytes: totalBytes),
                createdAt: Date(),
                exclusiveGroup: exclusiveGroup
            )
        )
        operations[id] = operation
        refreshAggregateJobs()
        startRunnableJobs()
        return id
    }

    @discardableResult
    public func enqueueGroup(
        kind: TransferJobKind,
        title: String,
        subtitle: String,
        source: TransferEndpoint,
        destination: TransferEndpoint,
        itemKind: TransferItemKind = .folder,
        totalBytes: Int64? = nil
    ) -> UUID {
        let id = UUID()
        jobs.append(
            TransferJob(
                id: id,
                kind: kind,
                title: title,
                subtitle: subtitle,
                source: source,
                destination: destination,
                itemKind: itemKind,
                parentID: nil,
                childCount: 0,
                isAggregate: true,
                state: .queued,
                progress: TransferProgressSnapshot(totalBytes: totalBytes),
                createdAt: Date()
            )
        )
        expandedJobIDs.insert(id)
        selectedJobID = id
        refreshAggregateJobs()
        return id
    }

    public func enqueueAndWait(
        kind: TransferJobKind,
        title: String,
        subtitle: String,
        source: TransferEndpoint,
        destination: TransferEndpoint,
        itemKind: TransferItemKind = .file,
        parentID: UUID? = nil,
        totalBytes: Int64? = nil,
        exclusiveGroup: String? = nil,
        defersPresentation: Bool = false,
        onEnqueued: ((UUID) -> Void)? = nil,
        operation: @escaping TransferOperation
    ) async throws -> TransferJobResult? {
        let result = await withCheckedContinuation { continuation in
            let id = UUID()
            jobs.append(
                TransferJob(
                    id: id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    source: source,
                    destination: destination,
                    itemKind: itemKind,
                    parentID: parentID,
                    childCount: 0,
                    isAggregate: false,
                    state: .queued,
                    progress: TransferProgressSnapshot(totalBytes: totalBytes),
                    createdAt: Date(),
                    exclusiveGroup: exclusiveGroup
                )
            )
            operations[id] = operation
            continuations[id] = continuation
            if defersPresentation {
                deferredPresentationJobIDs.insert(id)
            }
            onEnqueued?(id)
            refreshAggregateJobs()
            startRunnableJobs()
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }

    public func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].cancelRequested = true

        if jobs[index].isAggregate {
            let childIDs = jobs.filter { $0.parentID == jobID }.map(\.id)
            for childID in childIDs {
                cancel(jobID: childID)
            }
            refreshAggregateJobs()
            return
        }

        if jobs[index].state == .queued {
            finish(jobID: jobID, state: .canceled, result: nil, error: TransferCancellationError())
        } else if jobs[index].state == .running {
            tasks[jobID]?.cancel()
            updateProgress(jobID: jobID, completedBytes: nil, totalBytes: nil, fractionCompleted: nil, message: "Canceling")
        }
    }

    public func cancelSelected() {
        guard let selectedJobID else { return }
        cancel(jobID: selectedJobID)
    }

    public func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .failed,
              operations[jobID] != nil else {
            return
        }
        jobs[index].state = .queued
        jobs[index].progress = TransferProgressSnapshot(totalBytes: jobs[index].progress.totalBytes)
        jobs[index].errorMessage = nil
        jobs[index].startedAt = nil
        jobs[index].completedAt = nil
        jobs[index].cancelRequested = false
        tasks[jobID] = nil
        refreshAggregateJobs()
        startRunnableJobs()
    }

    public func clearCompleted() {
        let removableStates: Set<TransferJobState> = [.completed, .canceled]
        let removableIDs = Set(jobs.filter { $0.parentID == nil && removableStates.contains($0.state) }.map(\.id))
        let allRemovableIDs = Set(jobs.filter {
            removableIDs.contains($0.id) || $0.parentID.map(removableIDs.contains) == true
        }.map(\.id))
        for id in allRemovableIDs {
            operations[id] = nil
            tasks[id] = nil
        }
        jobs.removeAll { allRemovableIDs.contains($0.id) }
        deferredPresentationJobIDs.subtract(allRemovableIDs)
        expandedJobIDs.subtract(allRemovableIDs)
        if selectedJobID.map(allRemovableIDs.contains) == true {
            selectedJobID = nil
        }
    }

    @discardableResult
    public func discardFinishedJob(id jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }),
              job.isFinished,
              job.state != .failed || !job.canRetry else {
            return false
        }

        var removableIDs: Set<UUID> = [jobID]
        if job.isAggregate {
            removableIDs.formUnion(jobs.filter { $0.parentID == jobID }.map(\.id))
        }

        guard jobs.filter({ removableIDs.contains($0.id) }).allSatisfy({
            $0.isFinished && ($0.state != .failed || !$0.canRetry)
        }) else {
            return false
        }

        for id in removableIDs {
            operations[id] = nil
            tasks[id] = nil
        }
        jobs.removeAll { removableIDs.contains($0.id) }
        deferredPresentationJobIDs.subtract(removableIDs)
        expandedJobIDs.subtract(removableIDs)
        if selectedJobID.map(removableIDs.contains) == true {
            selectedJobID = nil
        }
        refreshAggregateJobs()
        return true
    }

    @discardableResult
    public func revealDeferredJob(id jobID: UUID) -> Bool {
        guard jobs.contains(where: { $0.id == jobID }), deferredPresentationJobIDs.remove(jobID) != nil else {
            return false
        }
        selectedJobID = jobID
        isPanelExpanded = true
        return true
    }

    public func job(id: UUID) -> TransferJob? {
        jobs.first { $0.id == id }
    }

    fileprivate func updateProgress(
        jobID: UUID,
        completedBytes: Int64?,
        totalBytes: Int64?,
        fractionCompleted: Double?,
        message: String?
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let current = jobs[index].progress
        jobs[index].progress = TransferProgressSnapshot(
            completedBytes: completedBytes ?? current.completedBytes,
            totalBytes: totalBytes ?? current.totalBytes,
            fractionCompleted: fractionCompleted ?? current.fractionCompleted,
            message: message ?? current.message
        )
        refreshAggregateJobs()
    }

    private func startRunnableJobs() {
        while activeJobs.count < maxActiveTransfers {
            guard let index = jobs.firstIndex(where: canStartJob) else { return }
            startJob(at: index)
        }
    }

    private func canStartJob(_ job: TransferJob) -> Bool {
        guard job.state == .queued, !job.isAggregate else { return false }
        if let exclusiveGroup = job.exclusiveGroup,
           activeJobs.contains(where: { $0.exclusiveGroup == exclusiveGroup }) {
            return false
        }
        if job.source.isUSBTransfer || job.destination.isUSBTransfer {
            let activeUSBJobs = activeJobs.filter { $0.source.isUSBTransfer || $0.destination.isUSBTransfer }
            return activeUSBJobs.count < maxActiveUSBTransferJobs
        }
        return true
    }

    private func startJob(at index: Int) {
        let id = jobs[index].id
        guard let operation = operations[id] else { return }
        jobs[index].state = .running
        jobs[index].startedAt = Date()

        let controller = TransferJobController(jobID: id, queue: self)
        let task = Task { @MainActor [weak self] in
            do {
                try controller.checkCancellation()
                let result = try await operation(controller)
                self?.finish(jobID: id, state: .completed, result: result, error: nil)
            } catch is TransferCancellationError {
                self?.finish(jobID: id, state: .canceled, result: nil, error: TransferCancellationError())
            } catch is CancellationError {
                self?.finish(jobID: id, state: .canceled, result: nil, error: TransferCancellationError())
            } catch {
                self?.finish(jobID: id, state: .failed, result: nil, error: error)
            }
        }
        tasks[id] = task
    }

    private func finish(jobID: UUID, state: TransferJobState, result: TransferJobResult?, error: Error?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        tasks[jobID] = nil
        jobs[index].state = state
        jobs[index].completedAt = Date()
        if state == .completed {
            jobs[index].progress = TransferProgressSnapshot(
                completedBytes: jobs[index].progress.totalBytes,
                totalBytes: jobs[index].progress.totalBytes,
                fractionCompleted: 1,
                message: result?.message ?? "Done"
            )
            jobs[index].outputURL = result?.outputURL
        } else {
            jobs[index].errorMessage = error?.localizedDescription
            if state == .failed, let error {
                failureHandler?(error)
            }
        }

        if state != .failed {
            operations[jobID] = nil
        }

        if let continuation = continuations.removeValue(forKey: jobID) {
            if let error {
                continuation.resume(returning: .failure(error))
            } else {
                continuation.resume(returning: .success(result))
            }
        }

        refreshAggregateJobs()
        startRunnableJobs()
    }

    private func refreshAggregateJobs() {
        let aggregateIDs = jobs.filter(\.isAggregate).map(\.id)
        for aggregateID in aggregateIDs {
            guard let index = jobs.firstIndex(where: { $0.id == aggregateID }) else { continue }
            let children = jobs.filter { $0.parentID == aggregateID }
            jobs[index].childCount = children.count

            guard !children.isEmpty else {
                continue
            }

            let totalBytes = children.compactMap(\.progress.totalBytes).reduce(Int64(0), +)
            let hasKnownTotalBytes = children.contains { $0.progress.totalBytes != nil }
            let completedBytes = children.reduce(Int64(0)) { total, child in
                if child.state == .completed {
                    return total + (child.progress.totalBytes ?? child.progress.completedBytes ?? 0)
                }
                return total + (child.progress.completedBytes ?? 0)
            }

            let fraction: Double?
            if hasKnownTotalBytes, totalBytes > 0 {
                fraction = Double(completedBytes) / Double(totalBytes)
            } else {
                let completedUnits = children.reduce(Double(0)) { total, child in
                    total + (child.state == .completed ? 1 : child.progress.fractionCompleted ?? 0)
                }
                fraction = completedUnits / Double(children.count)
            }

            let finishedCount = children.filter(\.state.isFinished).count
            let failedChildren = children.filter { $0.state == .failed }
            let canceledChildren = children.filter { $0.state == .canceled }
            let runningChildren = children.filter { $0.state == .running }
            let queuedChildren = children.filter { $0.state == .queued }

            if !runningChildren.isEmpty {
                jobs[index].state = .running
            } else if !queuedChildren.isEmpty {
                jobs[index].state = finishedCount > 0 ? .running : .queued
            } else if !failedChildren.isEmpty {
                jobs[index].state = .failed
                jobs[index].errorMessage = failedChildren.first?.errorMessage
            } else if canceledChildren.count == children.count {
                jobs[index].state = .canceled
            } else {
                jobs[index].state = .completed
            }

            jobs[index].startedAt = children.compactMap(\.startedAt).min()
            if jobs[index].state.isFinished {
                jobs[index].completedAt = children.compactMap(\.completedAt).max() ?? Date()
            } else {
                jobs[index].completedAt = nil
            }
            jobs[index].cancelRequested = children.contains { $0.cancelRequested }
            jobs[index].progress = TransferProgressSnapshot(
                completedBytes: hasKnownTotalBytes ? completedBytes : nil,
                totalBytes: hasKnownTotalBytes ? totalBytes : nil,
                fractionCompleted: fraction,
                message: "\(finishedCount) of \(children.count) items"
            )
        }
    }
}

public enum TransferConflictResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case skip
    case replace
    case keep

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .skip: "Skip"
        case .replace: "Replace"
        case .keep: "Keep Both"
        }
    }
}

public enum TransferConflictResolver {
    public static func enumeratedName(for originalName: String, existingNames: Set<String>) -> String {
        let nsName = originalName as NSString
        let base = nsName.deletingPathExtension.isEmpty ? originalName : nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existingNames.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    public static func enumeratedName(for originalName: String, existingNames: [String]) -> String {
        enumeratedName(for: originalName, existingNames: Set(existingNames.map { $0.lowercased() }))
    }
}

public enum ADBProgressParser {
    public static func fractionCompleted(from text: String) -> Double? {
        let pattern = #"(\d{1,3})%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = matches.last,
              let percentRange = Range(match.range(at: 1), in: text),
              let percent = Double(text[percentRange]) else {
            return nil
        }
        return min(max(percent / 100, 0), 1)
    }
}

public enum BatchRenameMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case findReplace
    case numberedBaseName
    case prefixSuffix
    case changeExtension

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .findReplace: "Find & Replace"
        case .numberedBaseName: "Numbered Name"
        case .prefixSuffix: "Prefix / Suffix"
        case .changeExtension: "Change Extension"
        }
    }
}

public struct BatchRenameOptions: Hashable, Codable, Sendable {
    public var mode: BatchRenameMode
    public var findText: String
    public var replaceText: String
    public var baseName: String
    public var startNumber: Int
    public var prefix: String
    public var suffix: String
    public var newExtension: String

    public init(
        mode: BatchRenameMode = .findReplace,
        findText: String = "",
        replaceText: String = "",
        baseName: String = "File",
        startNumber: Int = 1,
        prefix: String = "",
        suffix: String = "",
        newExtension: String = ""
    ) {
        self.mode = mode
        self.findText = findText
        self.replaceText = replaceText
        self.baseName = baseName
        self.startNumber = startNumber
        self.prefix = prefix
        self.suffix = suffix
        self.newExtension = newExtension
    }
}

public struct BatchRenamePreview: Identifiable, Hashable, Sendable {
    public var id: String { originalPath }
    public let originalPath: String
    public let originalName: String
    public let proposedName: String
    public let collision: Bool
}

public enum BatchRenamePlanner {
    public static func previews(
        for files: [AndroidFile],
        options: BatchRenameOptions,
        siblingNames: Set<String>
    ) -> [BatchRenamePreview] {
        var proposedNames = Set<String>()
        return files.enumerated().map { offset, file in
            let proposedName = proposedName(for: file.name, offset: offset, options: options)
            let normalized = proposedName.lowercased()
            let collidesWithSibling = siblingNames.contains(normalized) && normalized != file.name.lowercased()
            let collidesWithinBatch = proposedNames.contains(normalized)
            proposedNames.insert(normalized)
            return BatchRenamePreview(
                originalPath: file.path,
                originalName: file.name,
                proposedName: proposedName,
                collision: proposedName.isEmpty || collidesWithSibling || collidesWithinBatch
            )
        }
    }

    public static func proposedName(for fileName: String, offset: Int, options: BatchRenameOptions) -> String {
        let nsName = fileName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        switch options.mode {
        case .findReplace:
            guard !options.findText.isEmpty else { return fileName }
            return fileName.replacingOccurrences(of: options.findText, with: options.replaceText)
        case .numberedBaseName:
            let number = options.startNumber + offset
            return ext.isEmpty ? "\(options.baseName) \(number)" : "\(options.baseName) \(number).\(ext)"
        case .prefixSuffix:
            let nextBase = "\(options.prefix)\(base)\(options.suffix)"
            return ext.isEmpty ? nextBase : "\(nextBase).\(ext)"
        case .changeExtension:
            let cleanExtension = options.newExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return cleanExtension.isEmpty ? base : "\(base).\(cleanExtension)"
        }
    }
}

struct BatchRenameRequest: Identifiable, Hashable, Sendable {
    let id = UUID()
    let files: [AndroidFile]
    let siblingNames: Set<String>
}
