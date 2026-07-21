import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AndroidFileBrowserCore

final class CaptureCompositionServiceTests: XCTestCase {
    func testSideBySideLayoutAspectFitsDifferentDisplayShapesWithBlackSpace() {
        let layout = SideBySideCaptureLayout.make(sourceSizes: [
            CGSize(width: 40, height: 80),
            CGSize(width: 80, height: 40)
        ])

        XCTAssertEqual(layout.renderSize, CGSize(width: 168, height: 80))
        XCTAssertEqual(layout.frames.count, 2)
        XCTAssertEqual(layout.frames[0], CGRect(x: 20, y: 0, width: 40, height: 80))
        XCTAssertEqual(layout.frames[1], CGRect(x: 88, y: 20, width: 80, height: 40))
        XCTAssertLessThan(layout.frames[0].maxX, layout.frames[1].minX)
    }

    func testSideBySideLayoutStaysWithinExportLimitAndUsesEvenPixels() {
        let layout = SideBySideCaptureLayout.make(sourceSizes: [
            CGSize(width: 1_080, height: 2_400),
            CGSize(width: 2_560, height: 1_440),
            CGSize(width: 1_440, height: 2_560)
        ])

        XCTAssertLessThanOrEqual(layout.renderSize.width, 3_840)
        XCTAssertLessThanOrEqual(layout.renderSize.height, 2_160)
        XCTAssertEqual(Int(layout.renderSize.width) % 2, 0)
        XCTAssertEqual(Int(layout.renderSize.height) % 2, 0)
        XCTAssertEqual(layout.frames.count, 3)
    }

    func testCombiningScreenshotsWritesOneImageWithBlackPaddingAndGutter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portraitURL = directory.appending(path: "portrait.png")
        let landscapeURL = directory.appending(path: "landscape.png")
        try writeSolidImage(size: CGSize(width: 40, height: 80), color: CGColor(red: 1, green: 0, blue: 0, alpha: 1), to: portraitURL)
        try writeSolidImage(size: CGSize(width: 80, height: 40), color: CGColor(red: 0, green: 1, blue: 0, alpha: 1), to: landscapeURL)

        let outputURL = try await CaptureCompositionService().combineScreenshots([portraitURL, landscapeURL])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let providerData = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(providerData) else {
            return XCTFail("Combined screenshot could not be decoded.")
        }
        XCTAssertEqual(image.width, 168)
        XCTAssertEqual(image.height, 80)

        let gutterOffset = 40 * image.bytesPerRow + 84 * 4
        XCTAssertEqual(bytes[gutterOffset], 0)
        XCTAssertEqual(bytes[gutterOffset + 1], 0)
        XCTAssertEqual(bytes[gutterOffset + 2], 0)
    }

    func testCombiningRecordingsExportsOneSideBySideVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionVideoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let portraitURL = directory.appending(path: "portrait.mov")
        let landscapeURL = directory.appending(path: "landscape.mov")
        try await writeSolidVideo(
            size: CGSize(width: 40, height: 80),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            to: portraitURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 40),
            color: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            to: landscapeURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: portraitURL, startedAt: startedAt),
            CapturedVideoSource(url: landscapeURL, startedAt: startedAt.addingTimeInterval(0.1))
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(naturalSize, CGSize(width: 168, height: 80))
        XCTAssertGreaterThan(duration.seconds, 0.5)
    }

    func testCombiningRecordingsHoldsSingleFrameSourceForTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionStaticVideoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movingURL = directory.appending(path: "moving.mov")
        let singleFrameURL = directory.appending(path: "single-frame.mov")
        try await writeSolidVideo(
            size: CGSize(width: 40, height: 80),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            to: movingURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            frameCount: 1,
            to: singleFrameURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: movingURL, startedAt: startedAt),
            CapturedVideoSource(url: singleFrameURL, startedAt: startedAt)
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.5)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let tenthFrameTime = CMTime(value: 9, timescale: 30)
        let tenthFrame = try await generator.image(at: tenthFrameTime).image
        XCTAssertGreaterThan(tenthFrame.width, 0)
        XCTAssertGreaterThan(tenthFrame.height, 0)
    }

    func testCombiningRecordingsSkipsStartupWarmupBeforeTenthFrame() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CaptureCompositionWarmupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let warmingURL = directory.appending(path: "warming.mov")
        let staticURL = directory.appending(path: "static.mov")
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        try await writeVideo(
            size: CGSize(width: 40, height: 80),
            colors: Array(repeating: CGColor.black, count: 8) + Array(repeating: red, count: 20),
            to: warmingURL
        )
        try await writeSolidVideo(
            size: CGSize(width: 80, height: 80),
            color: CGColor.black,
            frameCount: 1,
            to: staticURL
        )

        let startedAt = Date()
        let outputURL = try await CaptureCompositionService().combineRecordings([
            CapturedVideoSource(url: warmingURL, startedAt: startedAt),
            CapturedVideoSource(url: staticURL, startedAt: startedAt)
        ])
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let tenthFrame = try await generator.image(at: CMTime(value: 9, timescale: 30)).image
        let pixel = try pixelRGBA(in: tenthFrame, x: 40, y: 40)
        XCTAssertGreaterThan(pixel[0], 180)
        XCTAssertLessThan(pixel[1], 60)
        XCTAssertLessThan(pixel[2], 60)
    }

    private func writeSolidImage(size: CGSize, color: CGColor, to url: URL) throws {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(color)
        context.fill(CGRect(origin: .zero, size: size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeSolidVideo(size: CGSize, color: CGColor, to url: URL) async throws {
        try await writeSolidVideo(size: size, color: color, frameCount: 10, to: url)
    }

    private func writeSolidVideo(
        size: CGSize,
        color: CGColor,
        frameCount: Int,
        to url: URL
    ) async throws {
        try await writeVideo(
            size: size,
            colors: Array(repeating: color, count: frameCount),
            to: url
        )
    }

    private func writeVideo(size: CGSize, colors: [CGColor], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.jpeg,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for (frameIndex, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw CocoaError(.fileWriteUnknown)
            }
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 10)
            ) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private func pixelRGBA(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        context.draw(
            image,
            in: CGRect(x: -x, y: -y, width: image.width, height: image.height)
        )
        return pixel
    }
}
