import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SideBySideCaptureLayout: Equatable, Sendable {
    let renderSize: CGSize
    let frames: [CGRect]

    static func make(
        sourceSizes: [CGSize],
        maximumRenderSize: CGSize = CGSize(width: 3_840, height: 2_160),
        gutter: CGFloat = 8
    ) -> SideBySideCaptureLayout {
        let sizes = sourceSizes.map {
            CGSize(width: max(abs($0.width), 1), height: max(abs($0.height), 1))
        }
        guard !sizes.isEmpty else {
            return SideBySideCaptureLayout(renderSize: .zero, frames: [])
        }

        let cellWidth = sizes.map(\.width).max() ?? 1
        let cellHeight = sizes.map(\.height).max() ?? 1
        let baseWidth = cellWidth * CGFloat(sizes.count) + gutter * CGFloat(max(sizes.count - 1, 0))
        let scale = min(
            1,
            maximumRenderSize.width / baseWidth,
            maximumRenderSize.height / cellHeight
        )
        let renderWidth = evenPixel(baseWidth * scale)
        let renderHeight = evenPixel(cellHeight * scale)
        let scaledGutter = gutter * scale
        let scaledCellWidth = (renderWidth - scaledGutter * CGFloat(max(sizes.count - 1, 0)))
            / CGFloat(sizes.count)

        let frames = sizes.enumerated().map { index, size in
            let fitScale = min(scaledCellWidth / size.width, renderHeight / size.height)
            let fittedSize = CGSize(width: size.width * fitScale, height: size.height * fitScale)
            let cellOriginX = CGFloat(index) * (scaledCellWidth + scaledGutter)
            return CGRect(
                x: cellOriginX + (scaledCellWidth - fittedSize.width) / 2,
                y: (renderHeight - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }

        return SideBySideCaptureLayout(
            renderSize: CGSize(width: renderWidth, height: renderHeight),
            frames: frames
        )
    }

    private static func evenPixel(_ value: CGFloat) -> CGFloat {
        max(2, floor(value / 2) * 2)
    }
}

public struct CapturedVideoSource: Sendable {
    public let url: URL
    public let startedAt: Date

    public init(url: URL, startedAt: Date) {
        self.url = url
        self.startedAt = startedAt
    }
}

public actor CaptureCompositionService {
    public init() {}

    public func combineScreenshots(_ urls: [URL]) throws -> URL {
        guard urls.count > 1 else {
            guard let url = urls.first else { throw FileOperationError.commandFailed("No screenshots were captured.") }
            return url
        }

        let images = try urls.map { url -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FileOperationError.commandFailed("A captured screenshot could not be opened.")
            }
            return image
        }
        let layout = SideBySideCaptureLayout.make(
            sourceSizes: images.map { CGSize(width: $0.width, height: $0.height) }
        )
        let width = Int(layout.renderSize.width)
        let height = Int(layout.renderSize.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be created.")
        }

        context.setFillColor(CGColor.black)
        context.fill(CGRect(origin: .zero, size: layout.renderSize))
        context.interpolationQuality = .high
        for (image, frame) in zip(images, layout.frames) {
            context.draw(image, in: frame)
        }

        guard let outputImage = context.makeImage() else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be finished.")
        }
        let outputURL = try captureOutputURL(prefix: "Screenshot-Side-by-Side", pathExtension: "png")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be saved.")
        }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FileOperationError.commandFailed("The side-by-side screenshot could not be saved.")
        }
        return outputURL
    }

    public func combineRecordings(_ sources: [CapturedVideoSource]) async throws -> URL {
        guard sources.count > 1 else {
            guard let url = sources.first?.url else { throw FileOperationError.commandFailed("No recordings were captured.") }
            return url
        }

        let assets = sources.map { AVURLAsset(url: $0.url) }
        var videoTracks: [AVAssetTrack] = []
        var orientedSizes: [CGSize] = []
        var sourceRanges: [CMTimeRange] = []
        for asset in assets {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw FileOperationError.commandFailed("A captured recording did not contain video.")
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            videoTracks.append(track)
            orientedSizes.append(CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height)))
            sourceRanges.append(try await track.load(.timeRange))
        }

        let layout = SideBySideCaptureLayout.make(sourceSizes: orientedSizes)
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = layout.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let earliestStart = sources.map(\.startedAt).min() ?? Date()
        var layerInstructions: [AVVideoCompositionLayerInstruction] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        var endTime = CMTime.zero

        for index in sources.indices {
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw FileOperationError.commandFailed("A video track could not be created.")
            }
            let sourceRange = sourceRanges[index]
            let startOffset = CMTime(
                seconds: max(0, sources[index].startedAt.timeIntervalSince(earliestStart)),
                preferredTimescale: 600
            )
            try compositionTrack.insertTimeRange(sourceRange, of: videoTracks[index], at: startOffset)
            endTime = CMTimeMaximum(endTime, CMTimeAdd(startOffset, sourceRange.duration))

            let preferredTransform = try await videoTracks[index].load(.preferredTransform)
            let naturalSize = try await videoTracks[index].load(.naturalSize)
            let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let targetFrame = layout.frames[index]
            let normalized = preferredTransform.concatenating(
                CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
            )
            let fittedScale = min(
                targetFrame.width / max(orientedSizes[index].width, 1),
                targetFrame.height / max(orientedSizes[index].height, 1)
            )
            let transform = normalized
                .concatenating(CGAffineTransform(scaleX: fittedScale, y: fittedScale))
                .concatenating(CGAffineTransform(translationX: targetFrame.minX, y: targetFrame.minY))
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            layerInstruction.setTransform(transform, at: startOffset)
            layerInstructions.append(layerInstruction)

            if let sourceAudioTrack = try await assets[index].loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                let audioRange = try await sourceAudioTrack.load(.timeRange)
                try compositionAudioTrack.insertTimeRange(audioRange, of: sourceAudioTrack, at: startOffset)
                let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
                parameters.setVolume(1 / sqrt(Float(sources.count)), at: .zero)
                audioParameters.append(parameters)
            }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: endTime)
        instruction.backgroundColor = CGColor.black
        instruction.layerInstructions = layerInstructions.reversed()
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw FileOperationError.commandFailed("The side-by-side recording could not be prepared.")
        }
        exporter.videoComposition = videoComposition
        if !audioParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioParameters
            exporter.audioMix = audioMix
        }

        let outputURL = try captureOutputURL(prefix: "Recording-Side-by-Side", pathExtension: "mp4")
        try await exporter.export(to: outputURL, as: .mp4)
        return outputURL
    }

    private func captureOutputURL(prefix: String, pathExtension: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "AndroidFileBrowserCaptures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return directory.appending(path: "\(prefix)-\(formatter.string(from: Date())).\(pathExtension)")
    }
}
