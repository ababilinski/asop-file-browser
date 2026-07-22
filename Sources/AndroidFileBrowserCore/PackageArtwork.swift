import AppKit
import ImageIO
import SwiftUI

private final class PackageArtworkImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private actor PackageArtworkImageLoader {
    static let shared = PackageArtworkImageLoader()

    private let images = NSCache<NSString, PackageArtworkImageBox>()

    func image(for data: Data, key: String) -> CGImage? {
        let cacheKey = key as NSString
        if let cached = images.object(forKey: cacheKey) {
            return cached.image
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              ) else {
            return nil
        }
        images.setObject(PackageArtworkImageBox(image), forKey: cacheKey)
        return image
    }
}

struct PackageArtwork: View {
    let package: AndroidPackage
    let size: CGFloat
    let usesFinderColors: Bool
    @State private var iconImage: CGImage?
    @State private var loadedIconID: String?

    var body: some View {
        Group {
            if loadedIconID == iconLoadID, let iconImage {
                Image(decorative: iconImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    LinearGradient(
                        colors: paletteColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(package.displayInitials)
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                        .padding(size * 0.08)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(.white.opacity(usesFinderColors ? 0.16 : 0.10), lineWidth: 0.5)
        }
        .accessibilityLabel("\(package.displayName) app icon")
        .task(id: iconLoadID) {
            loadedIconID = nil
            iconImage = nil
            guard let data = package.iconPNGData else { return }
            let requestedIconID = iconLoadID
            let decodedImage = await PackageArtworkImageLoader.shared.image(
                for: data,
                key: requestedIconID
            )
            guard !Task.isCancelled else { return }
            iconImage = decodedImage
            loadedIconID = decodedImage == nil ? nil : requestedIconID
        }
    }

    private var iconLoadID: String {
        guard let data = package.iconPNGData else {
            return "\(package.packageName)|fallback"
        }
        let prefix = data.prefix(12).base64EncodedString()
        return "\(package.packageName)|\(package.apkPath ?? "")|\(data.count)|\(prefix)"
    }

    private var paletteColors: [Color] {
        let palettes: [[Color]] = [
            [.blue, .cyan],
            [.indigo, .blue],
            [.purple, .pink],
            [.orange, .pink],
            [.green, .teal],
            [.mint, .cyan],
            [.red, .orange],
            [.brown, .orange]
        ]
        let colors = palettes[package.artworkPaletteIndex]
        return usesFinderColors ? colors : colors.map { $0.opacity(0.78) }
    }
}
