import AppKit
import SwiftUI

@MainActor
enum PreviewWindowPresenter {
    enum SessionEntryKind: Hashable {
        case file
        case folder
    }

    struct SessionEntry: Identifiable, Hashable {
        let id: String
        let title: String
        let kind: SessionEntryKind
        let symbol: String
        let details: [(String, String)]

        init(
            id: String,
            title: String,
            kind: SessionEntryKind = .file,
            symbol: String = "doc",
            details: [(String, String)] = []
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.symbol = symbol
            self.details = details
        }

        static func == (lhs: SessionEntry, rhs: SessionEntry) -> Bool {
            lhs.id == rhs.id
                && lhs.title == rhs.title
                && lhs.kind == rhs.kind
                && lhs.symbol == rhs.symbol
                && lhs.details.elementsEqual(rhs.details) { $0.0 == $1.0 && $0.1 == $1.1 }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(title)
            hasher.combine(kind)
            hasher.combine(symbol)
            for detail in details {
                hasher.combine(detail.0)
                hasher.combine(detail.1)
            }
        }
    }

    private static var windows: [URL: NSWindow] = [:]
    private static var windowDelegates: [URL: DetachedPreviewWindowDelegate] = [:]
    private static var sessionWindow: QuickLookSessionWindow?
    private static var sessionController: QuickLookSessionController?

    static var isSessionVisible: Bool {
        sessionWindow?.isVisible == true
    }

    static func show(url: URL, onClose: @escaping @MainActor () -> Void = {}) {
        if let existing = windows[url] {
            existing.makeKeyAndOrderFront(nil)
            onClose()
            return
        }

        let contentSize = preferredWindowSize(for: url)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        window.contentView = NSHostingView(rootView: DetachedPreviewWindow(url: url))
        let delegate = DetachedPreviewWindowDelegate {
            windows[url] = nil
            windowDelegates[url] = nil
            onClose()
        }
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        windows[url] = window
        windowDelegates[url] = delegate
    }

    static func showSession(
        title: String,
        entries: [SessionEntry],
        selectedID: SessionEntry.ID,
        loadURL: @escaping @MainActor (SessionEntry) async throws -> URL,
        releaseURL: @escaping @MainActor (URL) -> Void,
        onSelect: @escaping @MainActor (SessionEntry) -> Void
    ) {
        guard !entries.isEmpty else { return }
        let selectedIndex = entries.firstIndex { $0.id == selectedID } ?? 0

        let controller = QuickLookSessionController(
            title: title,
            entries: entries,
            selectedIndex: selectedIndex,
            loadURL: loadURL,
            releaseURL: releaseURL,
            onSelect: onSelect,
            onPreferredSizeChange: { entry in
                sessionWindow?.applyPreferredContentSize(preferredSessionWindowSize(for: entry), animated: true)
            }
        )

        if let window = sessionWindow {
            sessionController?.cancel()
            sessionController = controller
            window.title = title
            window.contentView = NSHostingView(rootView: QuickLookSessionView(controller: controller))
            window.applyPreferredContentSize(preferredSessionWindowSize(for: controller.selectedEntry), animated: true)
            bringSessionWindowToFront(activating: true)
            controller.loadCurrent()
            return
        }

        let contentSize = preferredSessionWindowSize(for: controller.selectedEntry)
        let window = QuickLookSessionWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.onMovePrevious = { sessionController?.movePrevious() }
        window.onMoveNext = { sessionController?.moveNext() }
        window.onCloseSession = {
            sessionController?.cancel()
            sessionController = nil
            sessionWindow = nil
        }
        window.center()
        window.contentView = NSHostingView(rootView: QuickLookSessionView(controller: controller))
        window.makeKeyAndOrderFront(nil)
        sessionWindow = window
        sessionController = controller
        controller.loadCurrent()
    }

    static func closeSession() {
        sessionWindow?.performClose(nil)
    }

    static func closeAll() {
        closeSession()
        for window in Array(windows.values) {
            window.performClose(nil)
        }
    }

    @discardableResult
    static func updateSessionSelection(selectedID: SessionEntry.ID) -> Bool {
        let didSelect = sessionController?.selectExternal(id: selectedID) ?? false
        if didSelect {
            bringSessionWindowToFront(activating: false)
        }
        return didSelect
    }

    private static func bringSessionWindowToFront(activating: Bool) {
        guard let window = sessionWindow else { return }
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        if activating {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private static func preferredSessionWindowSize(for entry: SessionEntry?) -> NSSize {
        guard let entry else { return NSSize(width: 820, height: 600) }
        switch entry.kind {
        case .folder:
            let rowCount = min(max(entry.details.count, 2), 6)
            return NSSize(width: 760, height: CGFloat(340 + rowCount * 28))
        case .file:
            return NSSize(width: 860, height: 640)
        }
    }

    private static func preferredWindowSize(for url: URL) -> NSSize {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            return NSSize(width: 820, height: 600)
        }

        let chromeHeight: CGFloat = 86
        let maxPreviewSize = NSSize(width: 1040, height: 740)
        let minPreviewSize = NSSize(width: 420, height: 260)
        let scale = min(
            maxPreviewSize.width / image.size.width,
            maxPreviewSize.height / image.size.height,
            1
        )
        let previewWidth = max(minPreviewSize.width, image.size.width * scale)
        let previewHeight = max(minPreviewSize.height, image.size.height * scale)
        return NSSize(width: previewWidth + 48, height: previewHeight + chromeHeight)
    }
}

@MainActor
private final class DetachedPreviewWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct DetachedPreviewWindow: View {
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .help("Open: open this cached preview file with the default Mac app.")

                Button {
                    saveAs()
                } label: {
                    Label("Save to Mac", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .help("Save to Mac: choose where to keep this preview file permanently.")
            }
            .padding(14)
            .background(.bar)

            Divider()

            QuickLookPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
final class QuickLookSessionController: ObservableObject {
    @Published var title: String
    @Published var entries: [PreviewWindowPresenter.SessionEntry]
    @Published var selectedIndex: Int
    @Published var previewURL: URL?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let loadURL: @MainActor (PreviewWindowPresenter.SessionEntry) async throws -> URL
    private let releaseURL: @MainActor (URL) -> Void
    private let onSelect: @MainActor (PreviewWindowPresenter.SessionEntry) -> Void
    private let onPreferredSizeChange: @MainActor (PreviewWindowPresenter.SessionEntry?) -> Void
    private var loadTask: Task<Void, Never>?

    init(
        title: String,
        entries: [PreviewWindowPresenter.SessionEntry],
        selectedIndex: Int,
        loadURL: @escaping @MainActor (PreviewWindowPresenter.SessionEntry) async throws -> URL,
        releaseURL: @escaping @MainActor (URL) -> Void,
        onSelect: @escaping @MainActor (PreviewWindowPresenter.SessionEntry) -> Void,
        onPreferredSizeChange: @escaping @MainActor (PreviewWindowPresenter.SessionEntry?) -> Void = { _ in }
    ) {
        self.title = title
        self.entries = entries
        self.selectedIndex = min(max(0, selectedIndex), max(0, entries.count - 1))
        self.loadURL = loadURL
        self.releaseURL = releaseURL
        self.onSelect = onSelect
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    var selectedEntry: PreviewWindowPresenter.SessionEntry? {
        guard entries.indices.contains(selectedIndex) else { return nil }
        return entries[selectedIndex]
    }

    var positionText: String {
        guard !entries.isEmpty else { return "" }
        return "\(selectedIndex + 1) of \(entries.count)"
    }

    var canMovePrevious: Bool {
        selectedIndex > 0
    }

    var canMoveNext: Bool {
        selectedIndex + 1 < entries.count
    }

    func movePrevious() {
        guard canMovePrevious else { return }
        selectedIndex -= 1
        loadCurrent()
    }

    func moveNext() {
        guard canMoveNext else { return }
        selectedIndex += 1
        loadCurrent()
    }

    @discardableResult
    func selectExternal(id: PreviewWindowPresenter.SessionEntry.ID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard index != selectedIndex else {
            return true
        }
        selectedIndex = index
        loadCurrent(syncSelection: false)
        return true
    }

    func loadCurrent(syncSelection: Bool = true) {
        guard let entry = selectedEntry else { return }
        loadTask?.cancel()
        releaseCurrentPreview()
        errorMessage = nil
        isLoading = entry.kind == .file
        onPreferredSizeChange(entry)
        if syncSelection {
            onSelect(entry)
        }

        guard entry.kind == .file else {
            return
        }

        loadTask = Task { @MainActor [weak self, entry] in
            guard let self else { return }
            do {
                let url = try await loadURL(entry)
                guard !Task.isCancelled, self.selectedEntry?.id == entry.id else {
                    releaseURL(url)
                    return
                }
                self.previewURL = url
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.selectedEntry?.id == entry.id else { return }
                self.previewURL = nil
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func openCurrentInDefaultApp() {
        guard let previewURL else { return }
        NSWorkspace.shared.open(previewURL)
    }

    func saveCurrentAs() {
        guard let previewURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedEntry?.title ?? previewURL.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: previewURL, to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        releaseCurrentPreview()
    }

    private func releaseCurrentPreview() {
        guard let previewURL else { return }
        self.previewURL = nil
        releaseURL(previewURL)
    }
}

private struct QuickLookSessionView: View {
    @ObservedObject var controller: QuickLookSessionController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    controller.movePrevious()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!controller.canMovePrevious)
                .help("Previous file")

                Button {
                    controller.moveNext()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!controller.canMoveNext)
                .help("Next file")

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.selectedEntry?.title ?? controller.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(controller.positionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    controller.openCurrentInDefaultApp()
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .disabled(controller.previewURL == nil)
                .help("Open this cached preview file with the default Mac app.")

                Button {
                    controller.saveCurrentAs()
                } label: {
                    Label("Save to Mac", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.previewURL == nil)
                .help("Save this preview file permanently on this Mac.")
            }
            .padding(14)
            .background(.bar)

            Divider()

            ZStack {
                if let url = controller.previewURL {
                    QuickLookPreview(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.selectedEntry?.kind == .folder, let entry = controller.selectedEntry {
                    QuickLookFolderPreview(entry: entry)
                } else if controller.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing Preview")
                            .font(.headline)
                    }
                } else if let errorMessage = controller.errorMessage {
                    CompatibleContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
        }
    }
}

private struct QuickLookFolderPreview: View {
    let entry: PreviewWindowPresenter.SessionEntry

    var body: some View {
        VStack(spacing: 18) {
            FinderStyleIconView(
                symbol: entry.symbol,
                kind: FinderStyleIconKind(symbol: entry.symbol, fileExtension: "", isFolder: true),
                size: 96,
                usesFinderColors: true
            )

            VStack(spacing: 5) {
                Text(entry.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !entry.details.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(entry.details, id: \.0) { label, value in
                        GridRow {
                            Text(label)
                                .foregroundStyle(.secondary)
                            Text(value)
                                .lineLimit(label == "Path" ? 4 : 1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 6)
                .frame(maxWidth: 520)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .frame(width: 620)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallbackMaterial: .regularMaterial)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class QuickLookSessionWindow: NSWindow {
    var onMovePrevious: (() -> Void)?
    var onMoveNext: (() -> Void)?
    var onCloseSession: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126:
            onMovePrevious?()
        case 124, 125:
            onMoveNext?()
        case 49, 53:
            performClose(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func close() {
        onCloseSession?()
        super.close()
    }

    func applyPreferredContentSize(_ size: NSSize, animated: Bool) {
        let currentContentSize = contentLayoutRect.size
        let widthDelta = abs(currentContentSize.width - size.width)
        let heightDelta = abs(currentContentSize.height - size.height)
        guard widthDelta > 12 || heightDelta > 12 else { return }

        var frame = frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = self.frame.midX - frame.width / 2
        frame.origin.y = self.frame.maxY - frame.height

        if let screenFrame = screen?.visibleFrame {
            frame.size.width = min(frame.width, screenFrame.width - 48)
            frame.size.height = min(frame.height, screenFrame.height - 48)
            frame.origin.x = min(max(frame.origin.x, screenFrame.minX + 24), screenFrame.maxX - frame.width - 24)
            frame.origin.y = min(max(frame.origin.y, screenFrame.minY + 24), screenFrame.maxY - frame.height - 24)
        }

        setFrame(frame, display: true, animate: animated)
    }
}
