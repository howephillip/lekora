import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Photos and files in the chat, and attachments waiting to be sent (docs/files.md).
public enum LKFileText {
    /// "2.4 MB"
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// For the agents list when a message is only photos or files: "Photo", "3 photos", "report.pdf".
    public static func preview(_ files: [ChatFile]) -> String {
        guard let first = files.first else { return "" }
        if files.allSatisfy(\.isImage) { return files.count == 1 ? "Photo" : "\(files.count) photos" }
        return files.count == 1 ? first.name : "\(files.count) files"
    }

    /// An SF Symbol for the kind of file.
    public static func symbol(name: String, mime: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if ["xls", "xlsx", "csv", "tsv", "numbers"].contains(ext) { return "tablecells" }
        if ["zip", "gz", "tar", "tgz", "7z", "rar"].contains(ext) { return "doc.zipper" }
        if ["py", "js", "ts", "swift", "json", "html", "css", "sh", "rb", "go", "rs", "java", "c", "cpp", "yaml", "yml", "sql"].contains(ext) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if ["ppt", "pptx", "key"].contains(ext) { return "rectangle.on.rectangle" }
        return "doc.text"
    }
}

#if canImport(UIKit)
/// A small picture of an image file, made without loading the whole image.
enum LKThumbnail {
    static func make(from url: URL, maxPixels: CGFloat = 900) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
#endif

/// The photos and files of one message: photos as pictures, everything else as a row with
/// its icon, name and size. Tapping opens it (Quick Look).
public struct LKMessageFiles: View {
    private let files: [ChatFile]
    private let fromUser: Bool
    private let load: (ChatFile) async -> URL?
    private let open: (ChatFile) -> Void
    private let opening: String?

    /// - Parameters:
    ///   - load: the file on the phone (fetched if needed), for pictures.
    ///   - opening: the file being fetched to open, shown with a spinner.
    public init(_ files: [ChatFile], fromUser: Bool, opening: String? = nil,
                load: @escaping (ChatFile) async -> URL?, open: @escaping (ChatFile) -> Void) {
        self.files = files
        self.fromUser = fromUser
        self.opening = opening
        self.load = load
        self.open = open
    }

    private var images: [ChatFile] { files.filter(\.isImage) }
    private var others: [ChatFile] { files.filter { !$0.isImage } }

    public var body: some View {
        HStack {
            if fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
            VStack(alignment: fromUser ? .trailing : .leading, spacing: LK.Spacing.xs) {
                if !images.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: images.count == 1 ? 1 : 2),
                              spacing: 4) {
                        ForEach(images) { file in
                            Button { open(file) } label: {
                                LKImageThumb(file: file, single: images.count == 1, load: load)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Photo \(file.name)")
                            .accessibilityHint("Opens it")
                        }
                    }
                    .frame(maxWidth: images.count == 1 ? 240 : 260)
                }
                ForEach(others) { file in
                    Button { open(file) } label: {
                        LKFileRow(file: file, fromUser: fromUser, busy: opening == file.file_id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens it")
                }
            }
            if !fromUser { Spacer(minLength: LK.Size.bubbleSideMargin) }
        }
    }
}

/// One file as a row: icon, name, size (like a file in Messages).
struct LKFileRow: View {
    let file: ChatFile
    let fromUser: Bool
    var busy = false

    var body: some View {
        HStack(spacing: LK.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fromUser ? Color.white.opacity(0.2) : LK.Palette.accent.opacity(0.14))
                if busy {
                    ProgressView()
                } else {
                    Image(systemName: LKFileText.symbol(name: file.name, mime: file.mime))
                        .font(.system(size: 18, weight: .medium))
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(LK.Typography.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(LKFileText.size(file.size))
                    .font(LK.Typography.caption)
                    .opacity(0.75)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(fromUser ? LK.Palette.onAccent : .primary)
        .padding(LK.Spacing.sm)
        .frame(maxWidth: 260, alignment: .leading)
        .background(fromUser ? LK.Surface.accent : LK.Surface.inset,
                    in: RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File \(file.name), \(LKFileText.size(file.size))")
    }
}

/// A photo in a message, loaded from the phone's copy (fetched from the instance first if needed).
struct LKImageThumb: View {
    let file: ChatFile
    let single: Bool
    let load: (ChatFile) async -> URL?
    #if canImport(UIKit)
    @State private var image: UIImage?
    #endif
    @State private var failed = false

    var body: some View {
        // The frame decides the size; the picture only fills it (a filled image's own size
        // would otherwise push the bubble past the screen's edge).
        Rectangle()
            .fill(LK.Surface.inset)
            .frame(height: single ? 220 : 128)
            .frame(maxWidth: .infinity)
            .overlay {
                #if canImport(UIKit)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                #endif
            }
            .clipShape(RoundedRectangle(cornerRadius: LK.Radius.bubble, style: .continuous))
        .contentShape(Rectangle())
        .task(id: file.file_id) {
            #if canImport(UIKit)
            guard image == nil else { return }
            guard let url = await load(file) else { failed = true; return }
            let made = await Task.detached(priority: .userInitiated) { LKThumbnail.make(from: url) }.value
            if let made { image = made } else { failed = true }
            #endif
        }
    }
}

/// An attachment chosen but not sent yet.
public struct LKPendingAttachment: Identifiable, Equatable {
    public let id = UUID()
    /// A copy in the app's temporary folder.
    public var url: URL
    public var name: String
    public var mime: String
    public var size: Int
    /// 0…1 while uploading.
    public var progress: Double?
    public var failure: String?
    public var uploaded: ChatFile?

    public init(url: URL, name: String, mime: String, size: Int) {
        self.url = url
        self.name = name
        self.mime = mime
        self.size = size
    }

    public var isImage: Bool { mime.hasPrefix("image/") }
}

/// Attachments above the message bar: small previews with × to remove and upload progress.
public struct LKAttachmentStrip: View {
    private let items: [LKPendingAttachment]
    private let onRemove: (LKPendingAttachment) -> Void

    public init(_ items: [LKPendingAttachment], onRemove: @escaping (LKPendingAttachment) -> Void) {
        self.items = items
        self.onRemove = onRemove
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LK.Spacing.sm) {
                ForEach(items) { item in
                    LKAttachmentChip(item: item, onRemove: { onRemove(item) })
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.top, LK.Spacing.sm)
        }
    }
}

struct LKAttachmentChip: View {
    let item: LKPendingAttachment
    let onRemove: () -> Void
    #if canImport(UIKit)
    @State private var thumb: UIImage?
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LK.Surface.inset)
                #if canImport(UIKit)
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: LKFileText.symbol(name: item.name, mime: item.mime)).font(.title3)
                        Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 4)
                    }
                    .foregroundStyle(.secondary)
                }
                #endif
                if let progress = item.progress, item.uploaded == nil {
                    Color.black.opacity(0.35)
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                if item.failure != nil {
                    Color.black.opacity(0.35)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LK.Palette.warning)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove \(item.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .task(id: item.id) {
            #if canImport(UIKit)
            guard item.isImage else { return }
            let url = item.url
            thumb = await Task.detached { LKThumbnail.make(from: url, maxPixels: 200) }.value
            #endif
        }
    }
}
