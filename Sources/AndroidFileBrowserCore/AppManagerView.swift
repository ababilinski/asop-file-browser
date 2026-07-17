import AppKit
import SwiftUI

struct AppManagerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("App Type", selection: $model.appKind) {
                    ForEach(AppKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .help("App Type: switch between user-installed apps and system apps.")
                .onChange(of: model.appKind) { _, _ in
                    Task { await model.loadPackages() }
                }

                Spacer()

                InlineSearchField(text: $model.searchText, prompt: "Search")

                Button {
                    Task { await model.forceStopSelectedPackages() }
                } label: {
                    Label("Force Close", systemImage: "xmark.octagon")
                }
                .disabled(model.selectedPackageIDs.isEmpty)
                .help("Force Close: stop the selected running apps on the Android device.")
                .accessibilityLabel("Force Close Apps")

                Button(role: .destructive) {
                    Task { await model.uninstallSelectedPackages() }
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .disabled(model.selectedPackageIDs.isEmpty)
                .help("Uninstall: remove the selected apps from the Android device.")
                .accessibilityLabel("Uninstall Apps")
                .accessibilityHint("Uninstall the selected Android apps.")

                Button {
                    model.showAPKImporter = true
                } label: {
                    Label("Install APK", systemImage: "plus.app")
                }
                .help("Install APK: choose an APK on this Mac and install it on the Android device.")
                .accessibilityLabel("Install APK")
                .accessibilityHint("Choose an APK file on this Mac and install it on the Android device.")
            }
            .padding(14)

            Divider()

            ZStack {
                AppPackageList(model: model)

                if model.isLoadingApps {
                    AppLoadingView(hasPackages: !model.packages.isEmpty)
                        .transition(.opacity)
                }
            }
        }
    }
}

struct AppLoadingView: View {
    let hasPackages: Bool

    var body: some View {
        ZStack {
            if !hasPackages {
                Rectangle()
                    .fill(.background)
            }

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading apps...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppPackageList: View {
    @ObservedObject var model: AppModel
    var showsStorageDisclosure = false
    @State private var columnWidths: [AppColumn: CGFloat] = [:]
    @State private var resizeStartWidths: [AppColumn: CGFloat]?

    private var visibleColumns: [AppColumn] {
        AppColumn.allCases.filter { column in
            model.visibleAppColumns.contains(column) && (!showsStorageDisclosure || column != .apk)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = AppColumnMetrics.layout(
                for: visibleColumns.isEmpty ? [.package] : visibleColumns,
                availableWidth: proxy.size.width,
                preferredWidths: columnWidths
            )
            VStack(spacing: 0) {
                AppPackageHeader(
                    model: model,
                    columns: layout.columns,
                    layout: layout
                ) { column, translation in
                    resizeColumn(column, translation: translation, layout: layout)
                } onResizeEnded: {
                    resizeStartWidths = nil
                }
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredPackages) { package in
                            AppPackageRow(
                                model: model,
                                package: package,
                                columns: layout.columns,
                                layout: layout,
                                showsStorageDisclosure: showsStorageDisclosure
                            )
                            if showsStorageDisclosure && model.expandedStorageAppPackageIDs.contains(package.id) {
                                StorageAppPackageExpansionView(model: model, package: package)
                                    .padding(.leading, 44)
                                    .padding(.trailing, 12)
                                    .padding(.vertical, 8)
                            }
                            Divider()
                                .padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
    }

    private func resizeColumn(_ column: AppColumn, translation: CGFloat, layout: AppColumnLayout) {
        guard let nextColumn = layout.nextColumn(after: column) else { return }
        let start: [AppColumn: CGFloat]
        if let resizeStartWidths {
            start = resizeStartWidths
        } else {
            start = layout.widths
            resizeStartWidths = start
            columnWidths = start
        }

        let currentStart = start[column] ?? layout.width(for: column)
        let nextStart = start[nextColumn] ?? layout.width(for: nextColumn)
        let currentMinimum = AppColumnMetrics.minimumWidth(for: column)
        let nextMinimum = AppColumnMetrics.minimumWidth(for: nextColumn)
        let clampedTranslation = min(max(translation, currentMinimum - currentStart), nextStart - nextMinimum)
        columnWidths[column] = currentStart + clampedTranslation
        columnWidths[nextColumn] = nextStart - clampedTranslation
    }
}

struct AppPackageHeader: View {
    @ObservedObject var model: AppModel
    let columns: [AppColumn]
    let layout: AppColumnLayout
    let resize: (AppColumn, CGFloat) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                AppPackageHeaderCell(model: model, column: column)
                    .frame(width: layout.width(for: column), height: 32)
                    .overlay(alignment: .trailing) {
                        if layout.nextColumn(after: column) != nil {
                            ColumnResizeHandle {
                                resize(column, $0)
                            } onEnded: {
                                onResizeEnded()
                            }
                        }
                    }
            }
        }
        .frame(width: layout.totalWidth, height: 32, alignment: .leading)
        .background(.regularMaterial)
        .contextMenu {
            AppColumnVisibilityMenu(model: model)
        }
    }
}

struct ColumnResizeHandle: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    var body: some View {
        ColumnResizeHandleRepresentable(onChanged: onChanged, onEnded: onEnded)
            .frame(width: 12)
            .help("Drag to resize column")
    }
}

private struct ColumnResizeHandleRepresentable: NSViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> ColumnResizeHandleView {
        let view = ColumnResizeHandleView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: ColumnResizeHandleView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }
}

private final class ColumnResizeHandleView: NSView {
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: (() -> Void)?

    private var dragStartX: CGFloat?
    private var isHovering = false
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        postsFrameChangedNotifications = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartX = event.locationInWindow.x
        isDragging = true
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onChanged?(event.locationInWindow.x - dragStartX)
        NSCursor.resizeLeftRight.set()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        isDragging = false
        onEnded?()
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dividerWidth = isDragging || isHovering ? 2.0 : 1.0
        let dividerX = bounds.maxX - dividerWidth
        let color = isDragging
            ? NSColor.controlAccentColor.withAlphaComponent(0.9)
            : NSColor.separatorColor.withAlphaComponent(isHovering ? 0.85 : 0.6)
        color.setFill()
        NSRect(x: dividerX, y: bounds.minY, width: dividerWidth, height: bounds.height).fill()
    }
}

struct AppColumnLayout {
    let columns: [AppColumn]
    let widths: [AppColumn: CGFloat]
    let totalWidth: CGFloat

    func width(for column: AppColumn) -> CGFloat {
        widths[column] ?? column.idealWidth
    }

    func nextColumn(after column: AppColumn) -> AppColumn? {
        guard let index = columns.firstIndex(of: column),
              index < columns.index(before: columns.endIndex) else {
            return nil
        }
        return columns[columns.index(after: index)]
    }
}

enum AppColumnMetrics {
    static func layout(
        for columns: [AppColumn],
        availableWidth: CGFloat,
        preferredWidths: [AppColumn: CGFloat]
    ) -> AppColumnLayout {
        let columns = columns.isEmpty ? [.package] : columns
        var widths = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column, preferredWidths[column] ?? column.idealWidth)
        })
        let targetWidth = max(1, availableWidth)
        let currentTotal = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? $1.idealWidth) }

        if currentTotal < targetWidth {
            let extra = targetWidth - currentTotal
            let totalWeight = columns.reduce(CGFloat(0)) { $0 + expansionWeight(for: $1) }
            for column in columns where totalWeight > 0 {
                widths[column, default: column.idealWidth] += extra * expansionWeight(for: column) / totalWeight
            }
        } else if currentTotal > targetWidth {
            let shrink = currentTotal - targetWidth
            let capacity = columns.reduce(CGFloat(0)) { total, column in
                total + max(0, (widths[column] ?? column.idealWidth) - minimumWidth(for: column))
            }
            if capacity > 0 {
                for column in columns {
                    let width = widths[column] ?? column.idealWidth
                    let availableShrink = max(0, width - minimumWidth(for: column))
                    widths[column] = max(minimumWidth(for: column), width - shrink * availableShrink / capacity)
                }
            } else {
                let scale = targetWidth / max(1, currentTotal)
                for column in columns {
                    widths[column, default: column.idealWidth] *= scale
                }
            }
        }

        let totalWidth = columns.reduce(CGFloat(0)) { $0 + (widths[$1] ?? $1.idealWidth) }
        return AppColumnLayout(columns: columns, widths: widths, totalWidth: totalWidth)
    }

    static func minimumWidth(for column: AppColumn) -> CGFloat {
        switch column {
        case .package: 220
        case .status: 82
        case .kind: 64
        case .enabled: 74
        case .size: 82
        case .apk: 150
        }
    }

    private static func expansionWeight(for column: AppColumn) -> CGFloat {
        switch column {
        case .package: 1
        case .apk: 0.5
        case .status, .kind, .enabled, .size: 0.16
        }
    }
}

struct AppPackageHeaderCell: View {
    @ObservedObject var model: AppModel
    let column: AppColumn

    var body: some View {
        HStack(spacing: 6) {
            Text(column.label)
                .font(.caption.weight(.semibold))
            if let sortIndicator = model.appSortIndicator(for: column) {
                Image(systemName: sortIndicator.ascending ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                SortPriorityBadge(priority: sortIndicator.priority)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(model.appSortIndicator(for: column) == nil ? Color.clear : Color.accentColor.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture {
            model.sortBy(appColumn: column)
        }
        .contextMenu {
            AppColumnVisibilityMenu(model: model)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 1)
        }
        .help("Sort by \(column.label). Command-click to add this column to the current sort. Right-click to show or hide columns.")
    }
}

struct AppColumnVisibilityMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(AppColumn.allCases) { column in
            Button {
                model.toggleAppColumn(column)
            } label: {
                if model.visibleAppColumns.contains(column) {
                    Label(column.label, systemImage: "checkmark")
                } else {
                    Text(column.label)
                }
            }
            .disabled(!column.isHideable)
        }
    }
}

struct AppPackageRow: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage
    let columns: [AppColumn]
    let layout: AppColumnLayout
    var showsStorageDisclosure = false

    private var isSelected: Bool {
        model.selectedPackageIDs.contains(package.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                AppPackageCell(
                    model: model,
                    package: package,
                    column: column,
                    showsStorageDisclosure: showsStorageDisclosure
                )
                    .frame(width: layout.width(for: column), alignment: .leading)
            }
        }
        .frame(height: 42)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            Task { await model.viewData(package: package) }
        })
        .onTapGesture {
            model.selectPackage(package)
        }
        .contextMenu { PackageMenu(model: model, package: package) }
    }
}

struct AppPackageCell: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage
    let column: AppColumn
    var showsStorageDisclosure = false

    var body: some View {
        Group {
            switch column {
            case .package:
                HStack {
                    if showsStorageDisclosure {
                        Button {
                            Task { await model.toggleStorageAppExpansion(package: package) }
                        } label: {
                            Image(systemName: model.expandedStorageAppPackageIDs.contains(package.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                        }
                        .buttonStyle(.plain)
                        .help(model.expandedStorageAppPackageIDs.contains(package.id) ? "Hide app storage details" : "Show app storage details")
                    }
                    PackageBadge(package: package, usesFinderColors: model.settings.useFinderStyleIconColors)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.packageName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let version = package.versionName {
                            Text(version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .status:
                HStack(spacing: 6) {
                    if package.isRunning {
                        Image(systemName: "play.circle.fill")
                        Text("Running")
                    } else {
                        Text("Idle")
                    }
                }
                .font(.caption.weight(package.isRunning ? .semibold : .regular))
                .foregroundStyle(package.isRunning ? Color.green : Color.secondary)
            case .kind:
                Text(package.kind.label)
                    .foregroundStyle(.secondary)
            case .enabled:
                Text(package.enabled.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    .foregroundStyle(.secondary)
            case .size:
                Text(package.displayTotalSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .apk:
                Text(package.apkPath ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct StorageAppPackageExpansionView: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage

    private var locations: [AppStorageLocation] {
        let primaryKinds: [AppStorageLocation.Kind] = [.data, .userData, .cache]
        let extraKinds: [AppStorageLocation.Kind] = [.files, .media, .obb]
        let all = package.appStorageLocations
        let primary: [AppStorageLocation] = primaryKinds.compactMap { kind in all.first { $0.kind == kind } }
        let extras: [AppStorageLocation] = extraKinds.compactMap { kind in
            guard package.hasStorageLocation(kind) else { return nil }
            return all.first { $0.kind == kind }
        }
        return primary + extras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Label("App Storage", systemImage: "externaldrive.badge.person.crop")
                    .font(.callout.weight(.semibold))
                if model.loadingStorageAppPackageIDs.contains(package.id) {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                StorageAppLegend()
            }

            VStack(spacing: 8) {
                ForEach(locations) { location in
                    StorageAppLocationRow(model: model, package: package, location: location)
                }
            }

            HStack {
                Text("Private user data is managed by Android. Browseable rows open in the file browser; protected rows can only be reset with Android package actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await model.clearAppCache(package: package) }
                } label: {
                    Label("Clear Cache", systemImage: "clock.arrow.circlepath")
                }
                .help("Clear only this app's cache for Android user 0.")

                Button(role: .destructive) {
                    Task { await model.clearAppStorage(package: package) }
                } label: {
                    Label("Clear Storage...", systemImage: "eraser")
                }
                .help("Clear this app's user data and cache after a warning.")
            }
        }
        .padding(12)
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallbackMaterial: .thinMaterial)
    }
}

private struct StorageAppLocationRow: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage
    let location: AppStorageLocation

    private var isSelected: Bool {
        model.selectedAppStorageLocation?.id == "\(package.packageName):\(location.kind.rawValue)"
    }

    private var canView: Bool {
        switch location.kind {
        case .userData:
            return package.hasStorageLocation(location.kind)
        case .cache:
            return package.hasStorageLocation(location.kind)
        case .data, .files, .media, .obb:
            return package.hasStorageLocation(location.kind)
        }
    }

    private var status: StorageAppLocationStatus {
        if location.kind == .userData && !canView {
            return .protected
        }
        if canView {
            return .browseable
        }
        return .notVisible
    }

    var body: some View {
        HStack(spacing: 10) {
            FinderStyleIconView(
                symbol: location.symbol,
                kind: iconKind,
                size: 24,
                usesFinderColors: model.settings.useFinderStyleIconColors
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(location.title)
                    .font(.callout.weight(.medium))
                Text(location.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(status.color.opacity(0.12), in: Capsule())

            Text(package.displayStorageSize(for: location))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, alignment: .trailing)

            Button {
                Task { await model.openAppStorageLocationOrExplain(package: package, location: location) }
            } label: {
                Label("View", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .disabled(!canView)
            .help(canView ? "View \(location.title) in the file browser." : "\(location.title) is not individually browseable from this Android connection.")
        }
        .padding(9)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .liquidGlassPanel(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fallbackMaterial: .regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectAppStorageLocation(package: package, location: location)
        }
        .contextMenu {
            Button {
                Task { await model.openAppStorageLocationOrExplain(package: package, location: location) }
            } label: {
                Label("View", systemImage: "folder")
            }
            .disabled(!canView)
            if location.kind == .cache {
                Button {
                    Task { await model.clearAppCache(package: package) }
                } label: {
                    Label("Clear Cache", systemImage: "clock.arrow.circlepath")
                }
            }
            Button {
                model.copyPathToPasteboard(location.path)
            } label: {
                Label("Copy Path", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
                Task { await model.clearAppStorage(package: package) }
            } label: {
                Label("Clear Storage...", systemImage: "eraser")
            }
        }
    }

    private var iconKind: FinderStyleIconKind {
        switch location.kind {
        case .data, .files, .cache, .userData:
            .folder
        case .media:
            .image
        case .obb:
            .archive
        }
    }
}

private enum StorageAppLocationStatus {
    case browseable
    case protected
    case notVisible

    var title: String {
        switch self {
        case .browseable: "Browseable"
        case .protected: "Protected"
        case .notVisible: "No visible files"
        }
    }

    var color: Color {
        switch self {
        case .browseable: .green
        case .protected: .orange
        case .notVisible: .secondary
        }
    }
}

private struct StorageAppLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            LegendPill(title: "Browseable", color: .green)
            LegendPill(title: "Protected", color: .orange)
            LegendPill(title: "No visible files", color: .secondary)
        }
    }
}

private struct LegendPill: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct PackageBadge: View {
    let package: AndroidPackage
    let usesFinderColors: Bool

    var body: some View {
        ZStack {
            Image(systemName: package.kind == .user ? "app.fill" : "gearshape.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(usesFinderColors ? .white : .primary)
        }
        .frame(width: 24, height: 24)
        .background(backgroundGradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: usesFinderColors ? accentColors : [.clear, .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accentColors: [Color] {
        package.kind == .user ? [.blue, .teal] : [.secondary, .gray]
    }
}

struct PackageMenu: View {
    @ObservedObject var model: AppModel
    let package: AndroidPackage

    var body: some View {
        Button("Load Details") {
            Task { await model.loadPackageDetails(package: package) }
        }
        Button("Open App") {
            Task { await model.openApp(package: package) }
        }
        Button("Force Close") {
            Task { await model.forceStop(package: package) }
        }
        Button("Clear Cache") {
            Task { await model.clearAppCache(package: package) }
        }
        Button("Clear Storage...", role: .destructive) {
            Task { await model.clearAppStorage(package: package) }
        }
        Button("Pull APK...") {
            Task { await model.pullAPK(package: package) }
        }
        .disabled(package.apkPath == nil)
        Divider()
        Button("Open App Data") {
            Task { await model.viewData(package: package) }
        }
        Button("Open App Media") {
            if let location = package.appStorageLocations.first(where: { $0.kind == .media }) {
                Task { await model.openAppStorageLocation(package: package, location: location) }
            }
        }
        Button("Open OBB Folder") {
            Task { await model.openAppStorageLocation(package: package, location: package.obbStorageLocation) }
        }
        Button("Upload OBB Files...") {
            model.beginUpload(to: package.obbStorageLocation.path)
        }
        Divider()
        Button("Enable") {
            Task { await model.setEnabled(true, package: package) }
        }
        Button("Disable") {
            Task { await model.setEnabled(false, package: package) }
        }
        Divider()
        Button("Uninstall", role: .destructive) {
            Task { await model.uninstall(package: package) }
        }
    }
}
