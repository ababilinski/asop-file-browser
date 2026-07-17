import AppKit
import SwiftUI

@MainActor
enum FileInfoWindowPresenter {
    private static var windows: [String: NSWindow] = [:]
    private static var delegates: [String: FileInfoWindowDelegate] = [:]

    static func show(model: AppModel, file: AndroidFile) {
        showWindow(
            key: "adb-\(file.id)",
            title: "Info - \(file.name)",
            rootView: AndroidFileInfoWindow(model: model, file: file)
        )
    }

    static func show(manager: USBTransferManager, item: USBTransferItem) {
        showWindow(
            key: "usb-\(item.id)",
            title: "Info - \(item.name)",
            rootView: USBTransferFileInfoWindow(manager: manager, item: item)
        )
    }

    fileprivate static func removeWindow(for key: String) {
        windows[key] = nil
        delegates[key] = nil
    }

    private static func showWindow<Content: View>(key: String, title: String, rootView: Content) {
        if let existing = windows[key] {
            existing.title = title
            existing.contentView = NSHostingView(rootView: rootView)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let delegate = FileInfoWindowDelegate(key: key)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        windows[key] = window
        delegates[key] = delegate
    }
}

private final class FileInfoWindowDelegate: NSObject, NSWindowDelegate {
    let key: String

    init(key: String) {
        self.key = key
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            FileInfoWindowPresenter.removeWindow(for: key)
        }
    }
}

private extension View {
    func fileInfoGlassCard() -> some View {
        padding(18)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                fallbackMaterial: .thinMaterial
            )
    }

    func fileInfoActionBar() -> some View {
        controlSize(.small)
            .buttonBorderShape(.roundedRectangle)
            .padding(10)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                fallbackMaterial: .regularMaterial
            )
    }
}

private struct AndroidFileInfoWindow: View {
    @ObservedObject var model: AppModel
    let file: AndroidFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                DetailGrid(rows: detailRows)
                MediaMetadataDisclosure(
                    metadata: model.mediaMetadataByFileID[file.id],
                    isLoading: model.loadingMediaMetadataFileIDs.contains(file.id),
                    errorMessage: model.failedMediaMetadataFileMessages[file.id]
                )
                actions
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fileInfoGlassCard()
        }
        .background(.ultraThinMaterial)
        .task(id: file.path) {
            await model.prepareFolderSize(for: file)
            await model.prepareMediaMetadata(for: file)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            MediaThumbnailView(model: model, file: file, size: 82, purpose: .detail)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(file.kind.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Kind", file.kind.displayName),
            ("Size", model.displaySize(for: file)),
            ("Modified", file.displayModified),
            ("Created", file.displayCreated),
            ("Extension", file.fileExtension.isEmpty ? "-" : file.fileExtension),
            ("Permissions", file.permissions ?? "-"),
            ("Path", file.path)
        ]
        if let metadata = model.mediaMetadataByFileID[file.id] {
            rows.insert(contentsOf: metadata.summaryRows.map { ($0.label, $0.value) }, at: min(3, rows.count))
        } else if model.loadingMediaMetadataFileIDs.contains(file.id) {
            rows.insert(("Media", "Reading metadata..."), at: min(3, rows.count))
        }
        return rows
    }

    @ViewBuilder
    private var actions: some View {
        if file.kind == .file {
            HStack(spacing: 10) {
                Button {
                    Task { await model.preview(file: file) }
                } label: {
                    Label("Preview", systemImage: "eye")
                }

                Button {
                    Task { await model.download(file: file) }
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .fileInfoActionBar()
        }
    }
}

private struct USBTransferFileInfoWindow: View {
    @ObservedObject var manager: USBTransferManager
    let item: USBTransferItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                DetailGrid(rows: detailRows)
                MediaMetadataDisclosure(
                    metadata: manager.mediaMetadataByItemID[item.id],
                    isLoading: manager.loadingMediaMetadataItemIDs.contains(item.id),
                    errorMessage: manager.failedMediaMetadataItemMessages[item.id]
                )
                actions
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fileInfoGlassCard()
        }
        .background(.ultraThinMaterial)
        .task(id: item.id) {
            await manager.prepareFolderSize(for: item)
            await manager.prepareMediaMetadata(for: item)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            FinderStyleIconView(
                symbol: item.fallbackSymbol,
                kind: FinderStyleIconKind(
                    symbol: item.fallbackSymbol,
                    fileExtension: item.fileExtension,
                    isFolder: item.isFolder
                ),
                size: 82,
                usesFinderColors: true
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(item.kind.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Kind", item.kind.displayName),
            ("Size", manager.displaySize(for: item)),
            ("Modified", item.displayModified),
            ("Extension", item.fileExtension.isEmpty ? "-" : item.fileExtension),
            ("UTI", item.uti ?? "-"),
            ("Path", item.path)
        ]
        if let metadata = manager.mediaMetadataByItemID[item.id] {
            rows.insert(contentsOf: metadata.summaryRows.map { ($0.label, $0.value) }, at: min(3, rows.count))
        } else if manager.loadingMediaMetadataItemIDs.contains(item.id) {
            rows.insert(("Media", "Reading metadata..."), at: min(3, rows.count))
        }
        return rows
    }

    @ViewBuilder
    private var actions: some View {
        if item.isDownloadable {
            HStack(spacing: 10) {
                Button {
                    manager.preview(item: item)
                } label: {
                    Label("Preview", systemImage: "eye")
                }

                Button {
                    manager.download(item: item)
                } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .fileInfoActionBar()
        }
    }
}
