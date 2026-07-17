import AppKit
import SwiftUI

@MainActor
enum ConnectionStatusWindowPresenter {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Device Connection Status"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ConnectionStatusWindow(model: model))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct ConnectionStatusWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var usbTransferManager: USBTransferManager
    @ObservedObject private var toolchainManager: ToolchainManager

    init(model: AppModel) {
        self.model = model
        self.usbTransferManager = model.usbTransferManager
        self.toolchainManager = model.toolchainManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Device Connection Status", systemImage: "cable.connector")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task {
                        await model.refreshDevicesAndRequestUSBTransferIfNoADB()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            VStack(spacing: 12) {
                ConnectionStatusCard(
                    title: "Developer Options",
                    symbol: "terminal",
                    status: adbStatus.title,
                    statusStyle: adbStatus.style,
                    detail: adbStatus.detail
                )

                ConnectionStatusCard(
                    title: "File Transfer",
                    symbol: "externaldrive.connected.to.line.below",
                    status: usbStatus.title,
                    statusStyle: usbStatus.style,
                    detail: usbStatus.detail
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Try This", systemImage: "checklist")
                    .font(.headline)

                Text("Unlock the phone and keep the USB notification set to File transfer / Android Auto for limited macOS transfer access.")
                Text("For full app features, enable USB debugging and accept the authorization prompt on the phone.")
                Text("File Transfer may ask macOS for removable media access when launch scanning is enabled or when you open that tool.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                if needsPhoneTools {
                    Button {
                        model.requestPhoneToolsSetup()
                    } label: {
                        Label("Set Up Phone Tools", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !model.hasReadyADBDevice {
                    Button {
                        model.open(destination: .usbTransfer)
                    } label: {
                        Label("Open File Transfer", systemImage: "externaldrive")
                    }
                    .disabled(usbTransferManager.didEnumerateLocalDevices && usbTransferManager.devices.isEmpty)
                }

                Spacer()
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 460, alignment: .topLeading)
    }

    private var adbStatus: ConnectionDisplayStatus {
        if let issue = model.adbRuntimeIssue {
            return ConnectionDisplayStatus(
                title: "Needs attention",
                style: .warning,
                detail: issue
            )
        }

        switch toolchainManager.status(for: .adb) {
        case .missing:
            return ConnectionDisplayStatus(
                title: "Setup needed",
                style: .warning,
                detail: "Phone Tools are not installed. File Transfer is still available."
            )
        case .needsRepair(let message):
            return ConnectionDisplayStatus(
                title: "Needs repair",
                style: .warning,
                detail: message
            )
        default:
            break
        }

        if let ready = model.devices.first(where: { $0.state == .device }) {
            return ConnectionDisplayStatus(
                title: "Connected",
                style: .success,
                detail: "\(ready.title) is ready for full file browsing and Phone Tools."
            )
        }

        if let unauthorized = model.devices.first(where: { $0.state == .unauthorized }) {
            return ConnectionDisplayStatus(
                title: "Authorization needed",
                style: .warning,
                detail: "Unlock \(unauthorized.title) and accept the USB debugging prompt."
            )
        }

        if let offline = model.devices.first(where: { $0.state == .offline }) {
            return ConnectionDisplayStatus(
                title: "Offline",
                style: .warning,
                detail: "\(offline.title) is visible but the debugging connection is not ready."
            )
        }

        return ConnectionDisplayStatus(
            title: "Not detected",
            style: .failure,
            detail: "No debugging connection was found. Check USB debugging or Wi-Fi pairing."
        )
    }

    private var needsPhoneTools: Bool {
        if model.adbRuntimeIssue != nil {
            return true
        }
        switch toolchainManager.status(for: .adb) {
        case .missing, .needsRepair:
            return true
        default:
            return false
        }
    }

    private var usbStatus: ConnectionDisplayStatus {
        if let device = usbTransferManager.devices.first {
            return ConnectionDisplayStatus(
                title: "Detected",
                style: .success,
                detail: "\(device.name) is visible to macOS transfer APIs. Use File Transfer for browsing and downloads."
            )
        }

        if !usbTransferManager.hasStartedBrowsing {
            return ConnectionDisplayStatus(
                title: "Ready",
                style: .neutral,
                detail: "File Transfer can check a cable connection automatically when you open it."
            )
        }

        if !usbTransferManager.didEnumerateLocalDevices {
            return ConnectionDisplayStatus(
                title: "Scanning",
                style: .warning,
                detail: "The app is still checking the cable connection."
            )
        }

        return ConnectionDisplayStatus(
            title: "Not visible to macOS",
            style: .failure,
            detail: "No File Transfer connection was found. Unlock the phone and choose File transfer / Android Auto from its USB notification."
        )
    }
}

private struct ConnectionStatusCard: View {
    let title: String
    let symbol: String
    let status: String
    let statusStyle: ConnectionStatusStyle
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Label(status, systemImage: statusStyle.symbol)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusStyle.color)
                }

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ConnectionDisplayStatus {
    let title: String
    let style: ConnectionStatusStyle
    let detail: String
}

private enum ConnectionStatusStyle {
    case neutral
    case success
    case warning
    case failure

    var symbol: String {
        switch self {
        case .neutral: "minus.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}
