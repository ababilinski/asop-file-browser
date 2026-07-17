import AppKit
import SwiftUI

public enum MediaThumbnailPurpose: Sendable {
    case browser
    case detail
}

struct MediaThumbnailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let file: AndroidFile
    let size: CGFloat
    let purpose: MediaThumbnailPurpose
    let automaticallyPrepares: Bool

    init(
        model: AppModel,
        file: AndroidFile,
        size: CGFloat,
        purpose: MediaThumbnailPurpose = .browser,
        automaticallyPrepares: Bool = true
    ) {
        self.model = model
        self.settings = model.settings
        self.file = file
        self.size = size
        self.purpose = purpose
        self.automaticallyPrepares = automaticallyPrepares
    }

    var body: some View {
        let uploadPresentation = model.uploadPresentation(for: file)
        ZStack(alignment: .bottomTrailing) {
            thumbnailContent(uploadPresentation: uploadPresentation)
                .opacity(uploadPresentation?.isGhosted == true ? 0.48 : 1)
            if let uploadPresentation {
                UploadProgressBadge(presentation: uploadPresentation, iconSize: size)
            }
        }
        .help(uploadPresentation?.statusText ?? "")
        .task(id: preparationID) {
            guard automaticallyPrepares, shouldShowPreview else { return }

            // Fast scrolling should not start an ADB pull for every transient row.
            // SwiftUI cancels this task as soon as the cell leaves the lazy stack.
            if purpose == .browser {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }

            await model.prepareThumbnail(for: file, purpose: purpose)
        }
    }

    @ViewBuilder
    private func thumbnailContent(uploadPresentation: UploadFilePresentation?) -> some View {
        if let uploadPresentation,
           let localImage = localUploadImage(for: uploadPresentation) {
            Image(nsImage: localImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: min(10, size / 4), style: .continuous))
        } else {
            ZStack {
                fileFallback
                if shouldShowPreview, let thumbnailURL = model.thumbnailURLs[file.id] {
                    ThumbnailFileImageView(url: thumbnailURL, size: size)
                }
            }
        }
    }

    private var fileFallback: some View {
        FinderStyleIconView(
            symbol: file.fallbackSymbol,
            kind: FinderStyleIconKind(
                symbol: file.fallbackSymbol,
                fileExtension: file.fileExtension,
                isFolder: file.kind == .directory,
                isLocked: file.kind == .locked
            ),
            size: size,
            usesFinderColors: settings.useFinderStyleIconColors,
            showsMediaPlaceholderBackground: shouldShowPreview && file.mediaKind != nil
        )
    }

    private func localUploadImage(for presentation: UploadFilePresentation) -> NSImage? {
        guard file.mediaKind == .image,
              let sourceURL = presentation.sourceURL else {
            return nil
        }
        return NSImage(contentsOf: sourceURL)
    }

    private var shouldShowPreview: Bool {
        switch purpose {
        case .browser:
            settings.loadMediaThumbnails
        case .detail:
            settings.showDetailMediaPreviews
        }
    }

    private var preparationID: String {
        let size = file.size.map(String.init) ?? "unknown-size"
        let modified = file.modified
            .map { String(Int64($0.timeIntervalSince1970 * 1_000)) }
            ?? "unknown-date"
        let purposeID = purpose == .browser ? "browser" : "detail"
        return "\(model.selectedDeviceID ?? "no-device")|\(file.id)|\(size)|\(modified)|\(purposeID)|\(shouldShowPreview)|\(settings.thumbnailMaxFileSizeMB)"
    }
}

struct USBTransferThumbnailView: View {
    @ObservedObject var manager: USBTransferManager
    @ObservedObject var settings: AppSettings
    let item: USBTransferItem
    let size: CGFloat
    let purpose: MediaThumbnailPurpose
    @State private var thumbnailURL: URL?
    @State private var isLoadingThumbnail = false

    init(
        manager: USBTransferManager,
        settings: AppSettings,
        item: USBTransferItem,
        size: CGFloat,
        purpose: MediaThumbnailPurpose = .browser
    ) {
        self.manager = manager
        self.settings = settings
        self.item = item
        self.size = size
        self.purpose = purpose
    }

    var body: some View {
        ZStack {
            FinderStyleIconView(
                symbol: item.fallbackSymbol,
                kind: FinderStyleIconKind(
                    symbol: item.fallbackSymbol,
                    fileExtension: item.fileExtension,
                    isFolder: item.kind == .folder
                ),
                size: size,
                usesFinderColors: settings.useFinderStyleIconColors,
                showsMediaPlaceholderBackground: shouldShowPreview && item.mediaKind != nil
            )
            if shouldShowPreview, let thumbnailURL {
                ThumbnailFileImageView(url: thumbnailURL, size: size)
            } else if isLoadingThumbnail {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(size < 32 ? 0.72 : 0.9)
                    .frame(width: size, height: size)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: min(10, size / 4), style: .continuous))
            }
        }
        .task(id: preparationID) {
            thumbnailURL = nil
            isLoadingThumbnail = false
            guard shouldShowPreview else { return }

            // Let fast-scrolled cells disappear before they claim the single-lane MTP
            // session. The task is automatically cancelled when its row leaves view.
            if purpose == .browser {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }

            isLoadingThumbnail = true
            defer { isLoadingThumbnail = false }
            thumbnailURL = await manager.prepareThumbnail(
                for: item,
                maxFileSizeMB: settings.thumbnailMaxFileSizeMB,
                allowsFullFileFallback: purpose == .detail
            )
        }
    }

    private var shouldShowPreview: Bool {
        switch purpose {
        case .browser:
            settings.loadMediaThumbnails
        case .detail:
            settings.showDetailMediaPreviews
        }
    }

    private var preparationID: String {
        let size = item.size.map(String.init) ?? "unknown-size"
        let modified = item.modified
            .map { String(Int64($0.timeIntervalSince1970 * 1_000)) }
            ?? "unknown-date"
        return "\(item.id)|\(item.path)|\(size)|\(modified)|\(shouldShowPreview)|\(settings.thumbnailMaxFileSizeMB)"
    }
}

private struct ThumbnailFileImageView: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: size, height: size)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: min(10, size / 4), style: .continuous))
            }
        }
        .task(id: url) {
            image = nil
            guard let cgImage = await ThumbnailImageLoader.shared.image(at: url),
                  !Task.isCancelled else {
                return
            }
            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
    }
}

private struct UploadProgressBadge: View {
    let presentation: UploadFilePresentation
    let iconSize: CGFloat

    private var badgeSize: CGFloat {
        min(24, max(13, iconSize * 0.48))
    }

    private var lineWidth: CGFloat {
        iconSize < 28 ? 1.7 : 2.4
    }

    private var progressFraction: Double {
        switch presentation.state {
        case .queued:
            0.08
        case .running:
            max(0.03, presentation.progressFraction ?? 0.08)
        case .completed:
            1
        case .failed, .canceled:
            0
        }
    }

    private var tint: Color {
        switch presentation.state {
        case .queued, .running:
            .accentColor
        case .completed:
            .green
        case .failed:
            .red
        case .canceled:
            .secondary
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            Circle()
                .stroke(Color.secondary.opacity(0.24), lineWidth: lineWidth)
            if presentation.state == .running || presentation.state == .queued || presentation.state == .completed {
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            statusSymbol
        }
        .frame(width: badgeSize, height: badgeSize)
        .padding(max(0, iconSize * 0.04))
        .help(presentation.statusText)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch presentation.state {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: badgeSize * 0.48, weight: .semibold))
                .foregroundStyle(tint)
        case .running:
            EmptyView()
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: badgeSize * 0.52, weight: .bold))
                .foregroundStyle(tint)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: badgeSize * 0.56, weight: .bold))
                .foregroundStyle(tint)
        case .canceled:
            Image(systemName: "xmark")
                .font(.system(size: badgeSize * 0.48, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
