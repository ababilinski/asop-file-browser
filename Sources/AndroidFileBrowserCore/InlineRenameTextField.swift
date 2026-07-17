import AppKit
import SwiftUI

struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let selectedPrefixLength: Int
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> RenameTextField {
        let textField = RenameTextField()
        textField.delegate = context.coordinator
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.focusRingType = .default
        textField.isBezeled = true
        textField.isBordered = true
        textField.drawsBackground = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.onMoveToWindow = { [weak textField, weak coordinator = context.coordinator] in
            guard let textField, let coordinator else { return }
            focus(textField, coordinator: coordinator)
        }
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: RenameTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.selectedPrefixLength = selectedPrefixLength
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        focus(nsView, coordinator: context.coordinator)
    }

    private func focus(_ textField: RenameTextField, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard !coordinator.didApplyInitialSelection else { return }
            textField.window?.makeFirstResponder(textField)
            guard let editor = textField.currentEditor() else { return }
            let selectionLength = min(coordinator.selectedPrefixLength, textField.stringValue.utf16.count)
            editor.selectedRange = NSRange(location: 0, length: selectionLength)
            coordinator.didApplyInitialSelection = true
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var selectedPrefixLength: Int = 0
        var onCommit: () -> Void
        var onCancel: () -> Void
        var didApplyInitialSelection = false
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                finish(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true
            default:
                return false
            }
        }

        private func finish(commit: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if commit {
                onCommit()
            } else {
                onCancel()
            }
        }
    }

    final class RenameTextField: NSTextField {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }
}

enum InlineRenameSelection {
    static func selectedPrefixLength(for name: String, isFolder: Bool) -> Int {
        guard !isFolder,
              let dotIndex = name.lastIndex(of: "."),
              dotIndex != name.startIndex else {
            return name.utf16.count
        }
        return name[..<dotIndex].utf16.count
    }
}
