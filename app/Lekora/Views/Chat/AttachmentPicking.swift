import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Turning photos, camera pictures and files into attachments (docs/files.md). Each becomes
/// a copy in the app's temporary folder, so it can be uploaded in pieces.
enum AttachmentImport {
    enum Problem: LocalizedError {
        case unreadable
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That item couldn't be read."
            case .tooLarge(let name): return "\(name) is over 100 MB, the most a file can be."
            }
        }
    }

    private static func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Attachments/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func make(_ url: URL, name: String, type: UTType?) throws -> LKPendingAttachment {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= GatewayClient.maxFileBytes else { throw Problem.tooLarge(name) }
        let mime = type?.preferredMIMEType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return LKPendingAttachment(url: url, name: name, mime: mime, size: size)
    }

    private static func stamp() -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return format.string(from: Date())
    }

    /// From the photo library. HEIC photos become JPEG, which every model and tool reads.
    static func fromPhotos(_ item: PhotosPickerItem, index: Int) async throws -> LKPendingAttachment {
        guard let data = try await item.loadTransferable(type: Data.self) else { throw Problem.unreadable }
        let type = item.supportedContentTypes.first
        let isMovie = type?.conforms(to: .movie) ?? false
        let base = (isMovie ? "Video " : "Photo ") + stamp() + (index > 0 ? " \(index + 1)" : "")
        let folder = try tempFolder()
        #if canImport(UIKit)
        if let type, type.conforms(to: .heic) || type.conforms(to: .heif),
           let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) {
            let url = folder.appendingPathComponent(base + ".jpg")
            try jpeg.write(to: url)
            return try make(url, name: url.lastPathComponent, type: .jpeg)
        }
        #endif
        let ext = type?.preferredFilenameExtension ?? (isMovie ? "mov" : "jpg")
        let url = folder.appendingPathComponent(base + "." + ext)
        try data.write(to: url)
        return try make(url, name: url.lastPathComponent, type: type)
    }

    /// From Files (or another app's file provider).
    static func fromFile(_ source: URL) throws -> LKPendingAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let url = try tempFolder().appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return try make(url, name: source.lastPathComponent, type: UTType(filenameExtension: source.pathExtension))
    }

    #if canImport(UIKit)
    /// A picture just taken with the camera.
    static func fromCamera(_ image: UIImage) throws -> LKPendingAttachment {
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { throw Problem.unreadable }
        let url = try tempFolder().appendingPathComponent("Photo \(stamp()).jpg")
        try jpeg.write(to: url)
        return try make(url, name: url.lastPathComponent, type: .jpeg)
    }
    #endif
}

#if canImport(UIKit)
/// The system camera, for "Take Photo".
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
