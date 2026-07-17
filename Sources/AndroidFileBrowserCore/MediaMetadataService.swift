import AVFoundation
import Foundation
import ImageIO

public struct FileMetadataRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.id = "\(label)-\(value)"
        self.label = label
        self.value = value
    }
}

public struct FileMetadataGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let rows: [FileMetadataRow]

    public init(title: String, rows: [FileMetadataRow]) {
        self.id = title
        self.title = title
        self.rows = rows
    }
}

public struct RemoteFileMetadata: Hashable, Sendable {
    public let summaryRows: [FileMetadataRow]
    public let groups: [FileMetadataGroup]

    public init(summaryRows: [FileMetadataRow], groups: [FileMetadataGroup]) {
        self.summaryRows = summaryRows
        self.groups = groups
    }
}

@MainActor
enum MediaMetadataService {
    static func readMetadata(for url: URL, originalName: String) async -> RemoteFileMetadata? {
        guard let mediaKind = AndroidMediaKind(fileExtension: (originalName as NSString).pathExtension) else {
            return nil
        }

        switch mediaKind {
        case .image:
            return readImageMetadata(for: url)
        case .video:
            return await readVideoMetadata(for: url)
        }
    }

    private static func readImageMetadata(for url: URL) -> RemoteFileMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else {
            return nil
        }

        var summaryRows: [FileMetadataRow] = []
        let width = numberValue(properties[kCGImagePropertyPixelWidth])
        let height = numberValue(properties[kCGImagePropertyPixelHeight])
        if let width, let height {
            summaryRows.append(FileMetadataRow(label: "Dimensions", value: "\(width) x \(height)"))
        }

        let topLevelRows = metadataRows(from: properties, skipping: [
            String(describing: kCGImagePropertyPixelWidth),
            String(describing: kCGImagePropertyPixelHeight)
        ])

        var groups: [FileMetadataGroup] = []
        if !topLevelRows.isEmpty {
            groups.append(FileMetadataGroup(title: "Image", rows: topLevelRows))
        }

        for key in properties.allKeys {
            let rawKey = String(describing: key)
            guard let dictionary = properties[key] as? NSDictionary else {
                continue
            }
            let rows = metadataRows(from: dictionary)
            if !rows.isEmpty {
                groups.append(FileMetadataGroup(title: cleanMetadataLabel(rawKey), rows: rows))
            }
        }

        return summaryRows.isEmpty && groups.isEmpty ? nil : RemoteFileMetadata(summaryRows: summaryRows, groups: groups)
    }

    private static func readVideoMetadata(for url: URL) async -> RemoteFileMetadata? {
        let asset = AVURLAsset(url: url)
        var summaryRows: [FileMetadataRow] = []

        if let duration = try? await asset.load(.duration),
           duration.seconds.isFinite,
           duration.seconds > 0 {
            summaryRows.append(FileMetadataRow(label: "Duration", value: durationFormatter.string(from: duration.seconds) ?? "\(Int(duration.seconds)) sec"))
        }

        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        if let track = tracks.first,
           let naturalSize = try? await track.load(.naturalSize),
           let preferredTransform = try? await track.load(.preferredTransform) {
            let transformed = naturalSize.applying(preferredTransform)
            let width = Int(abs(transformed.width).rounded())
            let height = Int(abs(transformed.height).rounded())
            if width > 0, height > 0 {
                summaryRows.append(FileMetadataRow(label: "Dimensions", value: "\(width) x \(height)"))
            }
        }

        var metadataRows: [FileMetadataRow] = []
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in commonMetadata {
            guard let value = await metadataValueDescription(item),
                  let label = videoMetadataLabel(for: item) else {
                continue
            }
            metadataRows.append(FileMetadataRow(label: label, value: value))
        }

        var groups: [FileMetadataGroup] = []
        if !metadataRows.isEmpty {
            groups.append(FileMetadataGroup(title: "Video Metadata", rows: metadataRows))
        }

        return summaryRows.isEmpty && groups.isEmpty ? nil : RemoteFileMetadata(summaryRows: summaryRows, groups: groups)
    }

    private static func metadataRows(from dictionary: NSDictionary, skipping skippedKeys: Set<String> = []) -> [FileMetadataRow] {
        dictionary.allKeys.compactMap { key -> FileMetadataRow? in
            let rawKey = String(describing: key)
            guard !skippedKeys.contains(rawKey),
                  !(dictionary[key] is NSDictionary),
                  let value = metadataValueDescription(dictionary[key]) else {
                return nil
            }
            return FileMetadataRow(label: cleanMetadataLabel(rawKey), value: value)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func metadataValueDescription(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let date = value as? Date {
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        }
        if let array = value as? [Any] {
            let values = array.compactMap(metadataValueDescription)
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }
        let description = String(describing: value)
        return description.isEmpty ? nil : description
    }

    private static func metadataValueDescription(_ item: AVMetadataItem) async -> String? {
        if let string = try? await item.load(.stringValue), !string.isEmpty {
            return string
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        }
        return nil
    }

    private static func videoMetadataLabel(for item: AVMetadataItem) -> String? {
        if let commonKey = item.commonKey?.rawValue {
            return cleanMetadataLabel(commonKey)
        }
        if let identifier = item.identifier?.rawValue {
            return cleanMetadataLabel(identifier)
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func cleanMetadataLabel(_ rawLabel: String) -> String {
        var label = rawLabel
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "kCGImageProperty", with: "")
            .replacingOccurrences(of: "com.apple.quicktime.", with: "")
            .replacingOccurrences(of: "mdta/", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")

        label = label.replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return label.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
