import AppKit
import CoreGraphics
import SwiftUI

enum PhoneControlShortcut: String, CaseIterable, Sendable {
    case back
    case home
    case recentApps
    case volumeDown
    case volumeUp
    case power
    case portrait
    case landscape
    case automaticRotation

    var title: String {
        switch self {
        case .back: "Back"
        case .home: "Home"
        case .recentApps: "Recent Apps"
        case .volumeDown: "Volume Down"
        case .volumeUp: "Volume Up"
        case .power: "Power"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .automaticRotation: "Automatic Rotation"
        }
    }

    var symbolName: String {
        switch self {
        case .back: "chevron.backward"
        case .home: "circle"
        case .recentApps: "square.on.square"
        case .volumeDown: "speaker.minus"
        case .volumeUp: "speaker.plus"
        case .power: "power"
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        case .automaticRotation: "rectangle.2.swap"
        }
    }

    var adbCommand: String {
        switch self {
        case .back: "input keyevent 4"
        case .home: "input keyevent 3"
        case .recentApps: "input keyevent 187"
        case .volumeDown: "input keyevent 25"
        case .volumeUp: "input keyevent 24"
        case .power: "input keyevent 26"
        case .portrait:
            "settings put system accelerometer_rotation 0; settings put system user_rotation 0"
        case .landscape:
            "settings put system accelerometer_rotation 0; settings put system user_rotation 1"
        case .automaticRotation:
            "settings put system accelerometer_rotation 1"
        }
    }

    var successMessage: String {
        switch self {
        case .portrait: "Phone Control changed to portrait."
        case .landscape: "Phone Control changed to landscape."
        case .automaticRotation: "Automatic rotation turned on."
        default: "Sent \(title) to the device."
        }
    }
}

enum PhoneControlWindowLayout {
    static let companionHeight: CGFloat = 66
    static let companionGap: CGFloat = 8
    static let screenPadding: CGFloat = 14

    static func placement(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        sessionIndex: Int
    ) -> ScrcpyWindowPlacement {
        let availableHeight = max(420, visibleFrame.height - companionHeight - companionGap - (screenPadding * 2))
        let phoneHeight = min(720, availableHeight)
        let phoneWidth = min(420, max(300, phoneHeight * 0.58))
        let slotWidth = phoneWidth + companionGap
        let columns = max(1, Int((visibleFrame.width - (screenPadding * 2) + companionGap) / slotWidth))
        let column = max(0, sessionIndex) % columns
        let cascade = max(0, sessionIndex) / columns

        let proposedX = visibleFrame.maxX
            - screenPadding
            - phoneWidth
            - (CGFloat(column) * slotWidth)
            - (CGFloat(cascade) * 22)
        let proposedTop = visibleFrame.maxY - screenPadding - (CGFloat(cascade) * 26)
        let phoneX = max(visibleFrame.minX + screenPadding, proposedX)
        let phoneBottom = max(
            visibleFrame.minY + companionHeight + companionGap + screenPadding,
            proposedTop - phoneHeight
        )
        let yFromTop = screenFrame.maxY - (phoneBottom + phoneHeight)

        return ScrcpyWindowPlacement(
            x: Int(phoneX.rounded()),
            y: Int(yFromTop.rounded()),
            width: Int(phoneWidth.rounded()),
            height: Int(phoneHeight.rounded()),
            alwaysOnTop: true
        )
    }

    static func companionFrame(for phoneFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(320, visibleFrame.width - (screenPadding * 2))
        let width = min(max(phoneFrame.width, 520), min(660, availableWidth))
        var x = phoneFrame.midX - (width / 2)
        x = min(max(x, visibleFrame.minX + screenPadding), visibleFrame.maxX - width - screenPadding)

        var y = phoneFrame.minY - companionGap - companionHeight
        if y < visibleFrame.minY + screenPadding {
            y = min(phoneFrame.maxY + companionGap, visibleFrame.maxY - companionHeight - screenPadding)
        }
        return CGRect(x: x, y: y, width: width, height: companionHeight)
    }

    static func clampedCompanionFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX + screenPadding),
            visibleFrame.maxX - frame.width - screenPadding
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY + screenPadding),
            visibleFrame.maxY - frame.height - screenPadding
        )
        return frame
    }
}

@MainActor
enum PhoneControlCompanionWindowPresenter {
    private static var controllers: [String: PhoneControlCompanionWindowController] = [:]

    static func preferredScrcpyPlacement(sessionIndex: Int) -> ScrcpyWindowPlacement? {
        guard let screen = PhoneCaptureWindowPresenter.activeScreen ?? NSApp.mainWindow?.screen ?? NSScreen.main else {
            return nil
        }
        return PhoneControlWindowLayout.placement(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            sessionIndex: sessionIndex
        )
    }

    static func show(
        model: AppModel,
        session: PhoneControlSession,
        windowTitle: String,
        sessionIndex: Int? = nil
    ) {
        if let controller = controllers[session.deviceSerial] {
            controller.update(session: session, windowTitle: windowTitle)
            controller.show()
            return
        }

        let index = sessionIndex
            ?? model.phoneControlSessions.firstIndex(where: { $0.deviceSerial == session.deviceSerial })
            ?? model.phoneControlSessions.count
        let controller = PhoneControlCompanionWindowController(
            model: model,
            session: session,
            windowTitle: windowTitle,
            initialPlacement: preferredScrcpyPlacement(sessionIndex: index)
        )
        controllers[session.deviceSerial] = controller
        controller.show()
    }

    static func close(deviceSerial: String) {
        controllers.removeValue(forKey: deviceSerial)?.close()
    }

    static func closeAll() {
        let activeControllers = controllers.values
        controllers.removeAll()
        activeControllers.forEach { $0.close() }
    }
}

@MainActor
private final class PhoneControlCompanionWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var session: PhoneControlSession
    private var windowTitle: String
    private let panel: NSPanel
    private var trackingTimer: Timer?
    private var hasTrackedScrcpyWindow = false
    private var companionOffset = CGVector.zero
    private var lastAutomaticFrame: CGRect?
    private var lastAppliedTrackedFrame: CGRect?

    init(
        model: AppModel,
        session: PhoneControlSession,
        windowTitle: String,
        initialPlacement: ScrcpyWindowPlacement?
    ) {
        self.model = model
        self.session = session
        self.windowTitle = windowTitle

        let initialFrame = Self.initialCompanionFrame(for: initialPlacement)
        self.panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        updateContent()
    }

    func update(session: PhoneControlSession, windowTitle: String) {
        self.session = session
        self.windowTitle = windowTitle
        updateContent()
    }

    func show() {
        panel.orderFrontRegardless()
        startTracking()
    }

    func close() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard let automaticFrame = lastAutomaticFrame else { return }
        if let lastAppliedTrackedFrame,
           panel.frame.nearlyEquals(lastAppliedTrackedFrame) {
            return
        }
        companionOffset = CGVector(
            dx: panel.frame.minX - automaticFrame.minX,
            dy: panel.frame.minY - automaticFrame.minY
        )
    }

    private func updateContent() {
        panel.contentView = NSHostingView(
            rootView: PhoneControlCompanionBar(model: model, session: session)
        )
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackScrcpyWindow()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackScrcpyWindow()
            }
        }
    }

    private func trackScrcpyWindow() {
        guard let phoneFrame = Self.scrcpyWindowFrame(
            processIdentifier: session.processIdentifier,
            expectedTitle: windowTitle
        ) else {
            if hasTrackedScrcpyWindow {
                panel.orderOut(nil)
            }
            return
        }

        hasTrackedScrcpyWindow = true
        let screen = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(phoneFrame).area < rhs.frame.intersection(phoneFrame).area
        } ?? NSScreen.main
        guard let screen else { return }
        let automaticFrame = PhoneControlWindowLayout.companionFrame(
            for: phoneFrame,
            visibleFrame: screen.visibleFrame
        )
        lastAutomaticFrame = automaticFrame
        let offsetFrame = automaticFrame.offsetBy(dx: companionOffset.dx, dy: companionOffset.dy)
        let targetFrame = PhoneControlWindowLayout.clampedCompanionFrame(
            offsetFrame,
            visibleFrame: screen.visibleFrame
        )
        if !panel.frame.nearlyEquals(targetFrame) {
            lastAppliedTrackedFrame = targetFrame
            panel.setFrame(targetFrame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private static func initialCompanionFrame(for placement: ScrcpyWindowPlacement?) -> CGRect {
        guard let screen = PhoneCaptureWindowPresenter.activeScreen ?? NSApp.mainWindow?.screen ?? NSScreen.main else {
            return CGRect(x: 100, y: 100, width: 520, height: PhoneControlWindowLayout.companionHeight)
        }
        guard let placement else {
            return CGRect(
                x: screen.visibleFrame.midX - 260,
                y: screen.visibleFrame.minY + PhoneControlWindowLayout.screenPadding,
                width: 520,
                height: PhoneControlWindowLayout.companionHeight
            )
        }
        let phoneFrame = CGRect(
            x: CGFloat(placement.x),
            y: screen.frame.maxY - CGFloat(placement.y + placement.height),
            width: CGFloat(placement.width),
            height: CGFloat(placement.height)
        )
        return PhoneControlWindowLayout.companionFrame(for: phoneFrame, visibleFrame: screen.visibleFrame)
    }

    private static func scrcpyWindowFrame(processIdentifier: Int32, expectedTitle: String) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let matches = windowInfo.compactMap { info -> (CGRect, Bool)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartzFrame.width > 150,
                  quartzFrame.height > 200 else { return nil }
            let titleMatches = (info[kCGWindowName as String] as? String) == expectedTitle
            return (appKitFrame(fromQuartzFrame: quartzFrame), titleMatches)
        }
        return matches.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }
            return lhs.0.area > rhs.0.area
        }.first?.0
    }

    private static func appKitFrame(fromQuartzFrame frame: CGRect) -> CGRect {
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

private struct PhoneControlCompanionBar: View {
    @ObservedObject var model: AppModel
    let session: PhoneControlSession

    var body: some View {
        LiquidGlassContainer(spacing: 8) {
            HStack(spacing: 10) {
                dragHandle

                Button {
                    model.showPhoneControl(deviceSerial: session.deviceSerial)
                } label: {
                    deviceSummary
                }
                .buttonStyle(.plain)
                .help("Bring \(session.deviceTitle) to the front")

                Divider()
                    .frame(height: 28)

                shortcutButton(.back)
                shortcutButton(.home)
                shortcutButton(.recentApps)

                Divider()
                    .frame(height: 28)

                shortcutButton(.volumeDown)
                shortcutButton(.volumeUp)

                Menu {
                    rotationButton(.automaticRotation)
                    Divider()
                    rotationButton(.portrait)
                    rotationButton(.landscape)
                } label: {
                    Image(systemName: "rectangle.2.swap")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Rotation")
                .accessibilityLabel("Rotation")

                Button {
                    Task { await model.captureScreenshotWithOptions(deviceSerial: session.deviceSerial) }
                } label: {
                    Image(systemName: "camera")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Take a screenshot")
                .accessibilityLabel("Take a screenshot")

                shortcutButton(.power)

                Button {
                    model.stopPhoneControl(deviceSerial: session.deviceSerial)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Close Phone Control")
                .accessibilityLabel("Close Phone Control")
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .liquidGlassPanel(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                fallbackMaterial: .regularMaterial
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .padding(4)
        .preferredColorScheme(model.settings.appearanceMode.colorScheme)
    }

    private var dragHandle: some View {
        Capsule(style: .continuous)
            .fill(Color.secondary.opacity(0.55))
            .frame(width: 4, height: 28)
            .frame(width: 12, height: 40)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .help("Drag to move the controls")
            .accessibilityLabel("Drag to move the controls")
    }

    private var deviceSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.deviceTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                batterySummary
            }
        }
        .frame(minWidth: 112, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var batterySummary: some View {
        if let battery = model.batteryStatuses[session.deviceSerial] {
            Label("\(battery.levelPercent)%", systemImage: battery.symbolName)
                .font(.caption2)
                .foregroundStyle(battery.isCharging ? Color.green : Color.secondary)
        } else {
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption2)
                .foregroundStyle(isConnected ? Color.secondary : Color.red)
        }
    }

    private var isConnected: Bool {
        model.devices.contains { $0.serial == session.deviceSerial && $0.state == .device }
    }

    private func shortcutButton(_ shortcut: PhoneControlShortcut) -> some View {
        Button {
            Task { await model.performPhoneControlShortcut(shortcut, deviceSerial: session.deviceSerial) }
        } label: {
            Image(systemName: shortcut.symbolName)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(shortcut.title)
        .accessibilityLabel(shortcut.title)
        .disabled(!isConnected)
    }

    private func rotationButton(_ shortcut: PhoneControlShortcut) -> some View {
        Button(shortcut.title, systemImage: shortcut.symbolName) {
            Task { await model.performPhoneControlShortcut(shortcut, deviceSerial: session.deviceSerial) }
        }
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }

    func nearlyEquals(_ other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
