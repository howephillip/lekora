import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Lekora

/// Pasting photos and files into the message bar, and copying messages (owner, 2026-11-18).
final class CopyPasteTests: XCTestCase {
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
    }

    func testOnlyPhotosAndFilesCountAsAttachments() {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "just words"
        XCTAssertFalse(PastingTextView.hasAttachment(board), "text pastes as text")
        board.image = image()
        XCTAssertTrue(PastingTextView.hasAttachment(board))
        board.itemProviders = [NSItemProvider(item: Data("%PDF-1.4".utf8) as NSData, typeIdentifier: UTType.pdf.identifier)]
        XCTAssertTrue(PastingTextView.hasAttachment(board), "a copied file")
        board.url = URL(string: "https://example.com")
        XCTAssertFalse(PastingTextView.hasAttachment(board), "a link pastes as text")
    }

    func testAPastedPhotoBecomesAnAttachment() async throws {
        let provider = NSItemProvider(object: image())
        let item = try await AttachmentImport.fromPasted(provider, index: 0)
        XCTAssertTrue(item.mime.hasPrefix("image/"), item.mime)
        XCTAssertTrue(item.name.hasPrefix("Photo "), item.name)
        XCTAssertGreaterThan(item.size, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }

    func testAPastedFileKeepsItsNameAndKind() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("Quarterly report.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        let item = try await AttachmentImport.fromPasted(provider, index: 0)
        XCTAssertEqual(item.name, "Quarterly report.pdf")
        XCTAssertEqual(item.mime, "application/pdf")
    }

    func testCopiedMessagesLeaveOutMarkdownMarks() {
        XCTAssertEqual(String(LKMessageBubble.markdown("**Done.** See `notes.md`").characters), "Done. See notes.md")
    }
}
