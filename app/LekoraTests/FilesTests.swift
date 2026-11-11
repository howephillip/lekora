import XCTest
@testable import Lekora

/// Files both ways (docs/files.md).
@MainActor
final class FilesTests: XCTestCase {
    private var host: FakeHost!
    private var cacheRoot: URL!

    override func setUp() async throws {
        host = try FakeHost()
        host.profiles = [["profile_id": "default", "name": "Default", "avatar": "sparkles"]]
        host.history = []
        try await host.start()
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lk-files-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        host.stop()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func connected() async throws -> GatewayClient {
        let store = InMemoryCredentialStore()
        try SavedHost(instanceId: host.instanceId, instanceName: host.instanceName, deviceId: "dev_1",
                      deviceToken: host.acceptedDeviceToken, endpoints: [host.endpoint],
                      enabledProfileIds: ["default"], activeProfileId: "default").save(to: store)
        let gateway = GatewayClient(keychain: store, requireTLS: false)
        gateway.fileCacheRoot = cacheRoot
        await gateway.resumeSavedSession()
        return gateway
    }

    private func tempFile(_ contents: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testUploadThenSend() async throws {
        let gateway = try await connected()
        let source = try tempFile("hello, agent", name: "notes.txt")
        var progress: [Double] = []
        let file = try await gateway.uploadFile(at: source, name: "notes.txt", mime: "text/plain", to: "default") {
            progress.append($0)
        }
        XCTAssertEqual(file.name, "notes.txt")
        XCTAssertEqual(file.size, 12)
        XCTAssertEqual(host.storedFiles[file.file_id]?.data, Data("hello, agent".utf8), "sent in 4-byte pieces")
        XCTAssertEqual(progress.last, 1)
        XCTAssertGreaterThan(progress.count, 3)
        XCTAssertNotNil(gateway.cachedFileURL(file), "a copy stays on the phone")

        await gateway.sendMessage("", files: [file])
        let received = await waitUntil { self.host.sentFiles.count == 1 }
        XCTAssertTrue(received)
        XCTAssertEqual(host.sentFiles, [[file.file_id]])
        let ok = await waitUntil { gateway.timeline.entries(for: "default").first?.seq != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(gateway.timeline.entries(for: "default").first?.files, [file])
    }

    func testAFailedUploadSaysWhy() async throws {
        let gateway = try await connected()
        host.failUploads = true
        let source = try tempFile("data", name: "a.bin")
        do {
            _ = try await gateway.uploadFile(at: source, name: "a.bin", mime: "application/octet-stream", to: "default")
            XCTFail("should fail")
        } catch {
            XCTAssertEqual((error as? HostError)?.reason, "Disk full")
        }
    }

    func testAgentFilesArriveAndDownload() async throws {
        let gateway = try await connected()
        let meta = host.storeFile(Data("%PDF-1.7 report".utf8), name: "report.pdf", mime: "application/pdf")
        host.sendFiles(profile: "default", files: [meta], text: "Here you go")
        let arrived = await waitUntil { gateway.timeline.entries(for: "default").last?.files?.isEmpty == false }
        XCTAssertTrue(arrived)
        let entry = try XCTUnwrap(gateway.timeline.entries(for: "default").last)
        XCTAssertEqual(entry.text, "Here you go")
        let file = try XCTUnwrap(entry.files?.first)
        XCTAssertEqual(file.kind, "document")
        XCTAssertNil(gateway.cachedFileURL(file))
        let url = try await gateway.fileURL(for: file)
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.7 report".utf8), "fetched in pieces")
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
        let reads = host.received(type: "file.read").count
        _ = try await gateway.fileURL(for: file)
        XCTAssertEqual(host.received(type: "file.read").count, reads, "then from the phone's copy")
    }

    func testUsage() async throws {
        let gateway = try await connected()
        _ = host.storeFile(Data(count: 10), name: "a", mime: "image/png")
        let usage = await gateway.filesUsage()
        XCTAssertEqual(usage, FilesUsage(bytes: 10, count: 1))
    }

    func testFilesSurviveTheCache() throws {
        let file = ChatFile(file_id: "f_1", name: "a.png", mime: "image/png", size: 3, kind: "image")
        let entry = ChatEntry(id: "seq-1", profileId: "default", role: .agent, text: "", seq: 1, files: [file])
        let decoded = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.files, [file])
        // Entries cached before files decode without them.
        let old = #"{"id":"seq-2","profileId":"default","role":{"agent":{}},"text":"hi","seq":2,"status":{"sent":{}}}"#
        XCTAssertNil(try JSONDecoder().decode(ChatEntry.self, from: Data(old.utf8)).files)
    }

    func testPreviewsAndSizes() {
        let photo = ChatFile(file_id: "1", name: "a.jpg", mime: "image/jpeg", size: 1, kind: "image")
        let pdf = ChatFile(file_id: "2", name: "r.pdf", mime: "application/pdf", size: 1, kind: "document")
        XCTAssertEqual(LKFileText.preview([photo]), "Photo")
        XCTAssertEqual(LKFileText.preview([photo, photo]), "2 photos")
        XCTAssertEqual(LKFileText.preview([pdf]), "r.pdf")
        XCTAssertEqual(LKFileText.preview([photo, pdf]), "2 files")
        XCTAssertEqual(LKFileText.symbol(name: "r.pdf", mime: "application/pdf"), "doc.richtext")
    }
}
