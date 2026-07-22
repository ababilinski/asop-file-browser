import AppKit
import SwiftUI

@MainActor
private enum PackageArtworkImageCache {
    static let images = NSCache<NSString, NSImage>()
}

struct PackageArtwork: View {
    let package: AndroidPackage
    let size: CGFloat
    let usesFinderColors: Bool

    var body: some View {
        Group {
            if let image = iconImage {
                Image(nsImage: image)
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
    }

    private var iconImage: NSImage? {
        guard let data = package.iconPNGData else { return nil }
        let prefix = data.prefix(12).base64EncodedString()
        let key = "\(package.packageName)|\(data.count)|\(prefix)" as NSString
        if let cached = PackageArtworkImageCache.images.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(data: data) else { return nil }
        PackageArtworkImageCache.images.setObject(image, forKey: key)
        return image
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
