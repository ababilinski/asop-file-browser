import AppKit
import SwiftUI

struct MainWindowKeyCapture: NSViewRepresentable {
    let shouldHandleFileModeShortcuts: () -> Bool
    let onQuickLook: () -> Void
    let onDelete: () -> Void
    let onNewFolder: () -> Void
    let onCopy: () -> Void
    let onCopyToQueue: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onRefresh: () -> Void
    let onFolderUp: () -> Void
    let onSelectAll: () -> Void
    let onRename: () -> Void
    let onSwitchTab: () -> Void
    let onOpen: () -> Void
    let onMoveSelection: (Int, Bool) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            shouldHandleFileModeShortcuts: shouldHandleFileModeShortcuts,
            onQuickLook: onQuickLook,
            onDelete: onDelete,
            onNewFolder: onNewFolder,
            onCopy: onCopy,
            onCopyToQueue: onCopyToQueue,
            onCut: onCut,
            onPaste: onPaste,
            onRefresh: onRefresh,
            onFolderUp: onFolderUp,
            onSelectAll: onSelectAll,
            onRename: onRename,
            onSwitchTab: onSwitchTab,
            onOpen: onOpen,
            onMoveSelection: onMoveSelection,
            onUndo: onUndo,
            onRedo: onRedo
        )
    }

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        context.coordinator.shouldHandleFileModeShortcuts = shouldHandleFileModeShortcuts
        context.coordinator.onQuickLook = onQuickLook
        context.coordinator.onDelete = onDelete
        context.coordinator.onNewFolder = onNewFolder
        context.coordinator.onCopy = onCopy
        context.coordinator.onCopyToQueue = onCopyToQueue
        context.coordinator.onCut = onCut
        context.coordinator.onPaste = onPaste
        context.coordinator.onRefresh = onRefresh
        context.coordinator.onFolderUp = onFolderUp
        context.coordinator.onSelectAll = onSelectAll
        context.coordinator.onRename = onRename
        context.coordinator.onSwitchTab = onSwitchTab
        context.coordinator.onOpen = onOpen
        context.coordinator.onMoveSelection = onMoveSelection
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
    }

    final class Coordinator {
        var shouldHandleFileModeShortcuts: () -> Bool
        var onQuickLook: () -> Void
        var onDelete: () -> Void
        var onNewFolder: () -> Void
        var onCopy: () -> Void
        var onCopyToQueue: () -> Void
        var onCut: () -> Void
        var onPaste: () -> Void
        var onRefresh: () -> Void
        var onFolderUp: () -> Void
        var onSelectAll: () -> Void
        var onRename: () -> Void
        var onSwitchTab: () -> Void
        var onOpen: () -> Void
        var onMoveSelection: (Int, Bool) -> Void
        var onUndo: () -> Void
        var onRedo: () -> Void

        init(
            shouldHandleFileModeShortcuts: @escaping () -> Bool,
            onQuickLook: @escaping () -> Void,
            onDelete: @escaping () -> Void,
            onNewFolder: @escaping () -> Void,
            onCopy: @escaping () -> Void,
            onCopyToQueue: @escaping () -> Void,
            onCut: @escaping () -> Void,
            onPaste: @escaping () -> Void,
            onRefresh: @escaping () -> Void,
            onFolderUp: @escaping () -> Void,
            onSelectAll: @escaping () -> Void,
            onRename: @escaping () -> Void,
            onSwitchTab: @escaping () -> Void,
            onOpen: @escaping () -> Void,
            onMoveSelection: @escaping (Int, Bool) -> Void,
            onUndo: @escaping () -> Void,
            onRedo: @escaping () -> Void
        ) {
            self.shouldHandleFileModeShortcuts = shouldHandleFileModeShortcuts
            self.onQuickLook = onQuickLook
            self.onDelete = onDelete
            self.onNewFolder = onNewFolder
            self.onCopy = onCopy
            self.onCopyToQueue = onCopyToQueue
            self.onCut = onCut
            self.onPaste = onPaste
            self.onRefresh = onRefresh
            self.onFolderUp = onFolderUp
            self.onSelectAll = onSelectAll
            self.onRename = onRename
            self.onSwitchTab = onSwitchTab
            self.onOpen = onOpen
            self.onMoveSelection = onMoveSelection
            self.onUndo = onUndo
            self.onRedo = onRedo
        }
    }

    @MainActor final class KeyCaptureView: NSView {
        weak var coordinator: Coordinator?
        private var keyMonitor: EventMonitorToken?
        private var mouseMonitor: EventMonitorToken?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor.value)
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor.value)
            }
        }

        private func installMonitorIfNeeded() {
            if keyMonitor == nil,
               let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard let self,
                      self.isEventForThisWindow(event) else {
                    return event
                }

                if self.shouldHandleQuickLook(event) {
                    self.coordinator?.onQuickLook()
                    return nil
                }

                if self.coordinator?.shouldHandleFileModeShortcuts() == true,
                   let shortcut = self.fileModeShortcut(for: event) {
                    switch shortcut {
                    case .delete:
                        self.coordinator?.onDelete()
                    case .newFolder:
                        self.coordinator?.onNewFolder()
                    case .copyToQueue:
                        self.coordinator?.onCopyToQueue()
                    case .refresh:
                        self.coordinator?.onRefresh()
                    case .folderUp:
                        self.coordinator?.onFolderUp()
                    case .selectAll:
                        self.coordinator?.onSelectAll()
                    case .rename:
                        self.coordinator?.onRename()
                    case .switchTab:
                        self.coordinator?.onSwitchTab()
                    case .open:
                        self.coordinator?.onOpen()
                    case .move(let delta, let extending):
                        self.coordinator?.onMoveSelection(delta, extending)
                    }
                    return nil
                }

                if let shortcut = self.fileHistoryShortcut(for: event) {
                    switch shortcut {
                    case .undo:
                        self.coordinator?.onUndo()
                    case .redo:
                        self.coordinator?.onRedo()
                    }
                    return nil
                }

                if let shortcut = self.clipboardShortcut(for: event) {
                    switch shortcut {
                    case .copy:
                        self.coordinator?.onCopy()
                    case .cut:
                        self.coordinator?.onCut()
                    case .paste:
                        self.coordinator?.onPaste()
                    }
                    return nil
                }

                return event
            }) {
                keyMonitor = EventMonitorToken(token)
            }

            if mouseMonitor == nil,
               let token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                guard let self, event.window === self.window else {
                    return event
                }
                self.clearTextFocusIfClickingOutsideTextInput(event)
                return event
            }) {
                mouseMonitor = EventMonitorToken(token)
            }
        }

        private func shouldHandleQuickLook(_ event: NSEvent) -> Bool {
            guard event.keyCode == 49 else { return false }
            let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else { return false }
            guard !isEditingText else { return false }
            return true
        }

        private func fileModeShortcut(for event: NSEvent) -> FileModeShortcut? {
            guard !isEditingText else { return nil }
            let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            switch event.keyCode {
            case 51 where relevantModifiers.isEmpty:
                return .delete
            case 36 where relevantModifiers.isEmpty,
                 76 where relevantModifiers.isEmpty:
                return .open
            case 123 where relevantModifiers.isEmpty:
                return .move(delta: -1, extending: false)
            case 123 where relevantModifiers == .shift:
                return .move(delta: -1, extending: true)
            case 124 where relevantModifiers.isEmpty:
                return .move(delta: 1, extending: false)
            case 124 where relevantModifiers == .shift:
                return .move(delta: 1, extending: true)
            case 126 where relevantModifiers.isEmpty:
                return .move(delta: -1, extending: false)
            case 126 where relevantModifiers == .shift:
                return .move(delta: -1, extending: true)
            case 125 where relevantModifiers.isEmpty:
                return .move(delta: 1, extending: false)
            case 125 where relevantModifiers == .shift:
                return .move(delta: 1, extending: true)
            case 45 where relevantModifiers == .command:
                return .newFolder
            case 8 where relevantModifiers == [.command, .shift]:
                return .copyToQueue
            case 15 where relevantModifiers == .command:
                return .refresh
            case 11 where relevantModifiers == .command:
                return .folderUp
            case 0 where relevantModifiers == .command:
                return .selectAll
            case 2 where relevantModifiers == .command:
                return .rename
            case 18 where relevantModifiers == .command:
                return .switchTab
            default:
                return nil
            }
        }

        private func fileHistoryShortcut(for event: NSEvent) -> FileHistoryShortcut? {
            let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !isEditingText, event.keyCode == 6 else { return nil }

            if relevantModifiers == .command {
                return .undo
            }
            if relevantModifiers == [.command, .shift] {
                return .redo
            }
            return nil
        }

        private func isEventForThisWindow(_ event: NSEvent) -> Bool {
            if event.window === window {
                return true
            }
            return event.window == nil && window?.isKeyWindow == true
        }

        private func clipboardShortcut(for event: NSEvent) -> ClipboardShortcut? {
            let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard relevantModifiers == .command, !isEditingText else { return nil }

            switch event.keyCode {
            case 8:
                return .copy
            case 7:
                return .cut
            case 9:
                return .paste
            default:
                return nil
            }
        }

        private func clearTextFocusIfClickingOutsideTextInput(_ event: NSEvent) {
            guard isEditingText,
                  let window,
                  let contentView = window.contentView else {
                return
            }

            let hitView = contentView.hitTest(event.locationInWindow)
            guard hitView?.isTextInputDescendant != true else { return }
            window.makeFirstResponder(nil)
        }

        private var isEditingText: Bool {
            guard let responder = window?.firstResponder else { return false }
            if responder is NSTextView {
                return true
            }
            if let control = responder as? NSControl,
               control.currentEditor() != nil {
                return true
            }
            return false
        }
    }

    final class EventMonitorToken: @unchecked Sendable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }
    }

    enum ClipboardShortcut {
        case copy
        case cut
        case paste
    }

    enum FileModeShortcut {
        case delete
        case newFolder
        case copyToQueue
        case refresh
        case folderUp
        case selectAll
        case rename
        case switchTab
        case open
        case move(delta: Int, extending: Bool)
    }

    enum FileHistoryShortcut {
        case undo
        case redo
    }
}

private extension NSView {
    var isTextInputDescendant: Bool {
        var current: NSView? = self
        while let view = current {
            if view is NSTextField || view is NSTextView {
                return true
            }
            if let control = view as? NSControl,
               control.currentEditor() != nil {
                return true
            }
            current = view.superview
        }
        return false
    }
}
