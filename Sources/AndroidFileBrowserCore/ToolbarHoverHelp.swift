import SwiftUI

#if os(macOS)
import AppKit

private struct ToolbarHoverHelpBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipBridgeView {
        TooltipBridgeView()
    }

    func updateNSView(_ view: TooltipBridgeView, context: Context) {
        view.text = text
    }

    final class TooltipBridgeView: NSView {
        private struct TrackingRegistration {
            weak var view: NSView?
            let area: NSTrackingArea
        }

        private var trackingRegistration: TrackingRegistration?
        private var activeHost: NSView?
        private var showWorkItem: DispatchWorkItem?

        var text = "" {
            didSet { installHoverTrackingSoon() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installHoverTrackingSoon()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installHoverTrackingSoon()
        }

        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil {
                removeHoverTracking()
                hideHelp()
            }
            super.viewWillMove(toSuperview: newSuperview)
        }

        override func mouseEntered(with event: NSEvent) {
            guard let host = activeHost else { return }
            scheduleHelp(for: host)
        }

        override func mouseExited(with event: NSEvent) {
            hideHelp()
        }

        private func installHoverTrackingSoon() {
            DispatchQueue.main.async { [weak self] in
                self?.installHoverTracking()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.installHoverTracking()
            }
        }

        private func installHoverTracking() {
            guard !text.isEmpty else { return }

            var current: NSView? = self
            var toolbarItemHost: NSView?
            var controlHost: NSView?

            for _ in 0..<24 {
                guard let view = current else { break }

                if controlHost == nil, view is NSControl {
                    controlHost = view
                }

                let className = String(describing: type(of: view))
                if toolbarItemHost == nil,
                   className.contains("ToolbarItem") || className.contains("ItemViewer") {
                    toolbarItemHost = view
                }

                current = view.superview
            }

            guard let hoverHost = toolbarItemHost ?? controlHost ?? superview,
                  activeHost !== hoverHost else {
                updateVisibleHelpIfNeeded()
                return
            }

            removeHoverTracking()
            activeHost = hoverHost

            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            hoverHost.addTrackingArea(trackingArea)
            trackingRegistration = TrackingRegistration(view: hoverHost, area: trackingArea)

            if hoverHost.containsCurrentMouseLocation {
                scheduleHelp(for: hoverHost)
            }
        }

        private func scheduleHelp(for host: NSView) {
            showWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self, weak host] in
                Task { @MainActor in
                    guard let self, let host, self.activeHost === host, host.containsCurrentMouseLocation else { return }
                    ToolbarHoverHelpPanel.shared.show(text: self.text, relativeTo: host)
                }
            }
            showWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
        }

        private func updateVisibleHelpIfNeeded() {
            guard let host = activeHost, host.containsCurrentMouseLocation else { return }
            ToolbarHoverHelpPanel.shared.show(text: text, relativeTo: host)
        }

        private func hideHelp() {
            showWorkItem?.cancel()
            showWorkItem = nil
            ToolbarHoverHelpPanel.shared.hide()
        }

        private func removeHoverTracking() {
            if let trackingRegistration {
                trackingRegistration.view?.removeTrackingArea(trackingRegistration.area)
            }
            trackingRegistration = nil
            activeHost = nil
        }
    }

    @MainActor
    final class ToolbarHoverHelpPanel {
        static let shared = ToolbarHoverHelpPanel()

        private let panel: NSPanel
        private let label: NSTextField
        private let horizontalPadding: CGFloat = 14
        private let verticalPadding: CGFloat = 9
        private let maxTextWidth: CGFloat = 320

        private init() {
            label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false

            let contentView = NSVisualEffectView()
            contentView.material = .popover
            contentView.blendingMode = .behindWindow
            contentView.state = .active
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 9
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
            contentView.layer?.borderWidth = 0.5
            contentView.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
                label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
                label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: verticalPadding),
                label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -verticalPadding)
            ])

            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.contentView = contentView
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.transient, .ignoresCycle]
        }

        func show(text: String, relativeTo view: NSView) {
            guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }

            label.stringValue = text
            label.preferredMaxLayoutWidth = maxTextWidth

            let textSize = label.intrinsicContentSize
            let panelWidth = min(max(textSize.width + horizontalPadding * 2, 150), maxTextWidth + horizontalPadding * 2)
            label.preferredMaxLayoutWidth = panelWidth - horizontalPadding * 2
            let wrappedTextSize = label.intrinsicContentSize
            let panelHeight = wrappedTextSize.height + verticalPadding * 2

            let hostRect = window.convertToScreen(view.convert(view.bounds, to: nil))
            let visibleFrame = screen.visibleFrame
            var origin = NSPoint(
                x: hostRect.midX - panelWidth / 2,
                y: hostRect.minY - panelHeight - 8
            )

            if origin.y < visibleFrame.minY + 8 {
                origin.y = hostRect.maxY + 8
            }
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - panelWidth - 8)

            panel.setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: true)
            panel.orderFront(nil)
        }

        func hide() {
            panel.orderOut(nil)
        }
    }
}

private extension NSView {
    var containsCurrentMouseLocation: Bool {
        guard let window else { return false }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(windowPoint, from: nil)
        return bounds.contains(localPoint)
    }
}
#endif

extension View {
    @ViewBuilder
    func toolbarHoverHelp(_ text: String) -> some View {
        #if os(macOS)
        self
            .background {
                ToolbarHoverHelpBridge(text: text)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
        #else
        self.help(text)
        #endif
    }
}
