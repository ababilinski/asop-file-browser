import AppKit
import SwiftUI

struct TransferPanelView: View {
    @ObservedObject var queue: TransferQueue

    private var activeCount: Int {
        queue.visibleRootJobs.filter { $0.state == .running }.count
    }

    private var queuedCount: Int {
        queue.visibleRootJobs.filter { $0.state == .queued }.count
    }

    private var selectedJob: TransferJob? {
        guard let selectedJobID = queue.selectedJobID else { return nil }
        return queue.visibleJobs.first { $0.id == selectedJobID }
    }

    private var summaryText: String {
        if activeCount > 0 {
            return queuedCount > 0 ? "\(activeCount) active, \(queuedCount) queued" : "\(activeCount) active"
        }
        if queue.failedCount > 0 {
            return "\(queue.failedCount) failed, \(queue.completedCount) completed"
        }
        return "\(queue.completedCount) completed"
    }

    private var totalProgressFraction: Double {
        queue.visibleProgressFraction ?? 0
    }

    private var totalProgressText: String {
        "\(Int((totalProgressFraction * 100).rounded()))%"
    }

    private var hasIndeterminateActiveJobs: Bool {
        queue.visibleRootJobs.contains {
            ($0.state == .queued || $0.state == .running) && $0.progressFraction == nil
        }
    }

    var body: some View {
        if queue.hasVisibleJobs {
            VStack(spacing: 0) {
                if queue.isPanelExpanded {
                    expandedHeader

                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(queue.visibleRootJobs.sorted(by: sortJobs)) { job in
                                TransferJobRow(queue: queue, job: job, level: 0)
                                Divider()
                                    .padding(.leading, 46)
                                if queue.isExpanded(job.id) {
                                    ForEach(queue.children(of: job.id).sorted(by: sortChildren)) { child in
                                        TransferJobRow(queue: queue, job: child, level: 1)
                                        Divider()
                                            .padding(.leading, 74)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                } else {
                    collapsedTab
                }
            }
            .background(.regularMaterial)
        }
    }

    private var expandedHeader: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Label("Transfers", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    queue.cancelSelected()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(selectedJob?.canCancel != true)
                .help("Cancel selected transfer")
                Button {
                    queue.clearCompleted()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(queue.completedCount == 0)
                .help("Clear completed transfers")
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        queue.isPanelExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Hide transfer panel")
            }
            totalProgressRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var collapsedTab: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                queue.isPanelExpanded = true
            }
        } label: {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                    Label("Transfers", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        queue.clearCompleted()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(queue.completedCount == 0)
                    .help("Clear completed transfers")
                }
                totalProgressRow
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show transfer panel")
    }

    private var totalProgressRow: some View {
        HStack(spacing: 8) {
            if hasIndeterminateActiveJobs {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                Text("Working")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            } else {
                ProgressView(value: totalProgressFraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                Text(totalProgressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .accessibilityLabel("Total transfer progress")
        .accessibilityValue(hasIndeterminateActiveJobs ? "In progress" : totalProgressText)
    }

    private func sortJobs(_ lhs: TransferJob, _ rhs: TransferJob) -> Bool {
        if lhs.state.isFinished != rhs.state.isFinished {
            return !lhs.state.isFinished
        }
        return lhs.createdAt > rhs.createdAt
    }

    private func sortChildren(_ lhs: TransferJob, _ rhs: TransferJob) -> Bool {
        lhs.createdAt < rhs.createdAt
    }
}

private struct TransferJobRow: View {
    @ObservedObject var queue: TransferQueue
    let job: TransferJob
    let level: Int

    private var isSelected: Bool {
        queue.selectedJobID == job.id
    }

    private var hasChildren: Bool {
        job.childCount > 0
    }

    private var statusText: String {
        if job.cancelRequested, !job.isFinished {
            return "Canceling"
        }
        switch job.state {
        case .queued:
            return "Queued"
        case .running:
            return job.progress.message ?? "Running"
        case .completed:
            return "Done"
        case .failed:
            return job.errorMessage ?? "Failed"
        case .canceled:
            return "Canceled"
        }
    }

    private var progressDetailText: String {
        [byteProgressText, etaText].compactMap(\.self).joined(separator: " - ")
    }

    private var byteProgressText: String? {
        guard let totalBytes = job.progress.totalBytes, totalBytes > 0 else { return nil }
        guard let reportedCompletedBytes = job.progress.completedBytes else { return nil }
        let completedBytes = min(reportedCompletedBytes, totalBytes)
        let completed = Self.byteFormatter.string(fromByteCount: completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: totalBytes)
        return "\(completed) of \(total)"
    }

    private var etaText: String? {
        guard job.state == .running,
              let startedAt = job.startedAt,
              let totalBytes = job.progress.totalBytes,
              let completedBytes = job.progress.completedBytes,
              totalBytes > 0,
              completedBytes > 0,
              completedBytes < totalBytes else {
            return nil
        }

        let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
        let bytesPerSecond = Double(completedBytes) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        let remainingSeconds = Double(totalBytes - completedBytes) / bytesPerSecond
        return "\(Self.durationFormatter.string(from: remainingSeconds) ?? "Calculating") left"
    }

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: CGFloat(level) * 24)

            disclosureButton

            Image(systemName: itemSymbol)
                .frame(width: 22)
                .foregroundStyle(iconColor)
                .opacity(iconOpacity)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }

                HStack(spacing: 8) {
                    ProgressView(value: job.progressFraction)
                        .opacity(job.state == .running || job.state == .completed ? 1 : 0.55)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(job.state == .failed ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 180, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text(job.subtitle)
                    if !progressDetailText.isEmpty {
                        Text(progressDetailText)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            if job.canCancel {
                Button {
                    queue.cancel(jobID: job.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel transfer")
            } else if job.canRetry {
                Button {
                    queue.retry(jobID: job.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry transfer")
            } else if job.state == .failed {
                Button {
                    queue.discardFinishedJob(id: job.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss transfer")
            } else if let outputURL = job.outputURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            queue.select(jobID: job.id)
        }
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if hasChildren {
            Button {
                withAnimation(.snappy(duration: 0.16)) {
                    queue.toggleExpanded(job.id)
                }
            } label: {
                Image(systemName: queue.isExpanded(job.id) ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(queue.isExpanded(job.id) ? "Collapse transfer" : "Expand transfer")
        } else {
            Color.clear
                .frame(width: 16)
        }
    }

    private var itemSymbol: String {
        switch job.itemKind {
        case .folder:
            job.state == .completed ? "folder.fill" : "folder"
        case .file:
            job.state == .completed ? "doc.fill" : "doc"
        }
    }

    private var iconOpacity: Double {
        switch job.state {
        case .completed, .failed:
            1
        case .queued, .running, .canceled:
            0.42
        }
    }

    private var iconColor: Color {
        switch job.state {
        case .completed: .green
        case .failed: .red
        case .canceled: .secondary
        case .queued, .running: .accentColor
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
