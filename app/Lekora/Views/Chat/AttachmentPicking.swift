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
    /// Pasted into the message bar: a photo, or a file copied in Files or another app.
    static func fromPasted(_ provider: NSItemProvider, index: Int) async throws -> LKPendingAttachment {
        let suffix = index > 0 ? " \(index + 1)" : ""
        // A file copied in Files: the file itself, with its name.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let source: URL? = try? await withCheckedThrowingContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url { done.resume(returning: url) } else { done.resume(throwing: error ?? Problem.unreadable) }
                }
            }
            if let source, source.isFileURL, FileManager.default.fileExists(atPath: source.path) { return try fromFile(source) }
        }
        // The richest real kind it comes as (the original photo or document), not text or an in-app kind.
        let types = provider.registeredContentTypes.filter {
            !$0.isDynamic && $0.preferredFilenameExtension != nil && !$0.conforms(to: .plainText) && !$0.conforms(to: .url)
        }
        if let type = types.first, let url = try? await copyFile(provider, type: type, suffix: suffix) {
            if type.conforms(to: .heic) || type.conforms(to: .heif),
               let image = UIImage(contentsOfFile: url.path), let jpeg = image.jpegData(compressionQuality: 0.9) {
                let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
                try jpeg.write(to: jpg)
                return try make(jpg, name: jpg.lastPathComponent, type: .jpeg)
            }
            return try make(url, name: url.lastPathComponent, type: type)
        }
        guard provider.canLoadObject(ofClass: UIImage.self) else { throw Problem.unreadable }
        let image: UIImage = try await withCheckedThrowingContinuation { done in
            _ = provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage { done.resume(returning: image) } else { done.resume(throwing: error ?? Problem.unreadable) }
            }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { throw Problem.unreadable }
        let url = try tempFolder().appendingPathComponent("Photo \(stamp())\(suffix).jpg")
        try jpeg.write(to: url)
        return try make(url, name: url.lastPathComponent, type: .jpeg)
    }

    /// A pasted item as a file of `type`, named as it was (or "Pasted …").
    private static func copyFile(_ provider: NSItemProvider, type: UTType, suffix: String) async throws -> URL {
        let ext = type.preferredFilenameExtension ?? "bin"
        let base = type.conforms(to: .image) ? "Photo" : "Pasted"
        var name = provider.suggestedName ?? "\(base) \(stamp())\(suffix)"
        // "Photo 2026-11-18 at 20.30.58" ends in ".58": only a real file kind counts as its extension.
        if UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) == nil || provider.suggestedName == nil {
            name += "." + ext
        }
        let folder = try tempFolder()
        return try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                guard let source else { return done.resume(throwing: error ?? Problem.unreadable) }
                do {
                    let target = folder.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: source, to: target)  // the original goes when this returns
                    done.resume(returning: target)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

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
