import AppKit

enum ArchiveExtractionConfirmation {
    @MainActor
    static func confirm(fileName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Uncompress \(fileName)?"
        alert.informativeText = "This will create an extracted folder next to the archive on the device."
        alert.addButton(withTitle: "Uncompress")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
