import AppKit
import SwiftUI

struct LocalFileDropTarget: NSViewRepresentable {
    let isEnabled: Bool
    let acceptsDrop: ([URL]) -> Bool
    let setTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> LocalFileDropTargetView {
        LocalFileDropTargetView()
    }

    func updateNSView(_ nsView: LocalFileDropTargetView, context: Context) {
        nsView.configuration = LocalFileDropTargetConfiguration(
            isEnabled: isEnabled,
            acceptsDrop: acceptsDrop,
            setTargeted: setTargeted,
            onDrop: onDrop
        )
    }
}

extension View {
    func localFileDropTarget(
        isEnabled: Bool = true,
        acceptsDrop: @escaping ([URL]) -> Bool = { _ in true },
        setTargeted: @escaping (Bool) -> Void,
        onDrop: @escaping ([URL]) -> Void
    ) -> some View {
        overlay {
            LocalFileDropTarget(
                isEnabled: isEnabled,
                acceptsDrop: acceptsDrop,
                setTargeted: setTargeted,
                onDrop: onDrop
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

fileprivate struct LocalFileDropTargetConfiguration {
    var isEnabled = true
    var acceptsDrop: ([URL]) -> Bool = { _ in true }
    var setTargeted: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }
}

final class LocalFileDropTargetView: NSView {
    fileprivate var configuration = LocalFileDropTargetConfiguration() {
        didSet {
            if configuration.isEnabled {
                registerForDraggedTypes([.fileURL, .URL])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = localFileURLs(from: sender.draggingPasteboard)
        guard configuration.isEnabled, !urls.isEmpty, configuration.acceptsDrop(urls) else {
            return []
        }
        configuration.setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = localFileURLs(from: sender.draggingPasteboard)
        guard configuration.isEnabled, !urls.isEmpty, configuration.acceptsDrop(urls) else {
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        configuration.setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        configuration.setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = localFileURLs(from: sender.draggingPasteboard)
        guard configuration.isEnabled, !urls.isEmpty, configuration.acceptsDrop(urls) else { return false }
        configuration.setTargeted(false)
        configuration.onDrop(urls)
        return true
    }

    private func localFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL]
        return urls?.map { $0 as URL } ?? []
    }
}
