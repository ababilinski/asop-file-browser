import AppKit
import SwiftUI

struct BrowserPathStatusBar: View {
    let path: String
    let showsFolder: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: showsFolder ? "folder" : "doc")
                .foregroundStyle(.secondary)

            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
        .contextMenu {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Path")
        .accessibilityValue(path)
    }
}
