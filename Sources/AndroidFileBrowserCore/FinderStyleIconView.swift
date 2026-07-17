import SwiftUI

enum FinderStyleIconKind {
    case folder
    case locked
    case app
    case systemApp
    case image
    case video
    case audio
    case pdf
    case archive
    case code
    case spreadsheet
    case presentation
    case document
    case storage
    case unknown

    init(symbol: String, fileExtension: String = "", isFolder: Bool = false, isLocked: Bool = false) {
        if isLocked {
            self = .locked
            return
        }
        if isFolder || symbol == "folder" || symbol.hasPrefix("folder.") {
            self = .folder
            return
        }

        switch fileExtension.lowercased() {
        case "apk", "apks", "aab":
            self = .app
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "raw", "dng":
            self = .image
        case "mp4", "mov", "m4v", "3gp", "mkv", "webm", "avi":
            self = .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "amr":
            self = .audio
        case "pdf":
            self = .pdf
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz":
            self = .archive
        case "json", "xml", "html", "htm", "css", "js", "ts", "kt", "java", "swift", "py", "sh", "gradle", "properties":
            self = .code
        case "csv", "xls", "xlsx", "ods":
            self = .spreadsheet
        case "ppt", "pptx", "key":
            self = .presentation
        case "txt", "md", "rtf", "log", "doc", "docx", "odt", "pages":
            self = .document
        default:
            switch symbol {
            case "photo":
                self = .image
            case "film":
                self = .video
            case "waveform":
                self = .audio
            case "doc.richtext":
                self = .pdf
            case "doc.zipper":
                self = .archive
            case "curlybraces":
                self = .code
            case "tablecells":
                self = .spreadsheet
            case "chart.bar.doc.horizontal":
                self = .presentation
            case "app", "app.fill":
                self = .app
            case "internaldrive", "externaldrive", "sdcard":
                self = .storage
            default:
                self = .unknown
            }
        }
    }

    var tint: Color {
        switch self {
        case .folder:
            Color(red: 0.14, green: 0.55, blue: 0.96)
        case .locked:
            .orange
        case .app:
            .blue
        case .systemApp:
            .gray
        case .image:
            .green
        case .video:
            .purple
        case .audio:
            .pink
        case .pdf:
            .red
        case .archive:
            .brown
        case .code:
            .indigo
        case .spreadsheet:
            .mint
        case .presentation:
            .orange
        case .document:
            .cyan
        case .storage:
            .secondary
        case .unknown:
            .secondary
        }
    }
}

struct FinderStyleIconView: View {
    let symbol: String
    let kind: FinderStyleIconKind
    let size: CGFloat
    let usesFinderColors: Bool
    var showsMediaPlaceholderBackground = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.58, weight: usesFinderColors ? .medium : .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(usesFinderColors ? kind.tint : defaultTint)
            .frame(width: size, height: size)
            .background(backgroundFill, in: RoundedRectangle(cornerRadius: min(10, size / 4), style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: min(10, size / 4), style: .continuous))
    }

    private var defaultTint: Color {
        kind == .locked ? .orange : .primary
    }

    private var backgroundFill: Color {
        if usesFinderColors {
            return kind.tint.opacity(kind == .folder ? 0.10 : 0.14)
        }
        return showsMediaPlaceholderBackground ? Color.secondary.opacity(0.10) : .clear
    }
}
