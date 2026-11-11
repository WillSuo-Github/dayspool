import Foundation
import XCTest
@testable import DaySpool

final class FileActivityTests: XCTestCase {
    func testFiltersNoiseButKeepsDocumentsOutsideStandardFolders() {
        let policy = FileChangePolicy.desktop(home: "/Users/example")
        XCTAssertEqual(policy.acceptedPath("/System/Volumes/Data/Users/example/My Folder/trip.pdf"),
                       "/Users/example/My Folder/trip.pdf")
        XCTAssertEqual(policy.acceptedPath("/Users/example/Library/CloudStorage/Drive/trip.pdf"),
                       "/Users/example/Library/CloudStorage/Drive/trip.pdf")
        XCTAssertEqual(policy.acceptedPath("/Users/example/Library Notes/trip.pdf"),
                       "/Users/example/Library Notes/trip.pdf")
        XCTAssertNil(policy.acceptedPath("/Volumes/External/trip.pdf"))
        XCTAssertNil(policy.acceptedPath("/Users/example/Library/Application Support/DaySpool/journal.sqlite"))
        XCTAssertNil(policy.acceptedPath("/Users/example/Downloads/trip.pdf.crdownload"))
    }

    func testAutosavesMergeAndLargeFoldersAreCompacted() throws {
        var batch = FileChangeBatcher()
        let at = Date(timeIntervalSince1970: 123)
        batch.observe(.appeared, path: "/Users/example/Custom/budget.xlsx", at: at)
        for i in 1...8 {
            batch.observe(.modified, path: "/Users/example/Custom/budget.xlsx", at: at.addingTimeInterval(Double(i)))
        }
        for i in 0..<3_000 {
            batch.observe(.appeared, path: "/Users/example/Unpacked/part-\(i).pdf", at: at)
        }
        let events = batch.drain()
        let document = try XCTUnwrap(events.first { $0.name == "budget.xlsx" })
        XCTAssertEqual(document.action, .appeared)
        XCTAssertEqual(document.notifications, 9)
        XCTAssertEqual(document.lastSeen, at.addingTimeInterval(8))
        let group = try XCTUnwrap(events.first { $0.action == .batch })
        XCTAssertEqual(group.path, "/Users/example/Unpacked")
        XCTAssertEqual(group.notifications, 3_000)
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(batch.drain().isEmpty)
    }

    func testUnrelatedEventFloodProducesBoundedOutputAndAnExplicitGap() {
        var batch = FileChangeBatcher(maxFiles: 4, maxFolders: 2, groupAt: 3)
        let at = Date()
        for i in 0..<200 {
            batch.observe(.modified, path: "/data/collection-\(i)/file.txt", at: at)
        }
        let output = batch.drain()
        XCTAssertLessThanOrEqual(output.count, 7)
        XCTAssertEqual(output.filter { $0.action == .incomplete }.count, 1)
        XCTAssertEqual(output.reduce(0) { $0 + $1.notifications }, 200)
    }

    func testFileRecordsStayLocalUnlessReportEvidenceIsOptedIn() throws {
        let store = try JournalStore(path: ":memory:")
        let at = Date(timeIntervalSince1970: 300)
        let change = FileChange(action: .modified, path: "/Users/example/Custom/budget.xlsx",
                                firstSeen: at, lastSeen: at, notifications: 1)
        try store.insertBatch([change.journalEvent])
        XCTAssertEqual(try store.recent(search: "budget", kind: .file).first?.fileChange, change)
        let period = ReportPeriod(kind: .hour, start: Date(timeIntervalSince1970: 0),
                                  end: Date(timeIntervalSince1970: 3600))
        XCTAssertTrue(try store.evidence(for: period).isEmpty)
        XCTAssertEqual(try store.evidence(for: period, includeFiles: true).first?.fileChange, change)
    }

    @MainActor
    func testDisablingFileReportsDoesNotResendAnEarlierFileBasedSummary() async throws {
        let store = try JournalStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 0)
        let hour = ReportPeriod(kind: .hour, start: start, end: start.addingTimeInterval(3600))
        let day = ReportPeriod(kind: .day, start: start, end: start.addingTimeInterval(86_400))
        let item = ReportContent.Item(project: "Fixture", update: "A private name", status: .observed,
                                      evidenceIDs: ["synthetic"])
        try store.enqueue(hour)
        try store.save(.init(items: [item], includesFileEvidence: true), for: hour)
        // The executable must never be invoked when the only evidence is an excluded summary.
        let generator = ReportGenerator(store: store, client: .init(executable: URL(fileURLWithPath: "/usr/bin/false")))
        let report = try await generator.generate(period: day, language: "English")
        XCTAssertTrue(report.items.isEmpty)
    }

    func testRootStreamObservesSyntheticFileOutsideStandardFolders() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DaySpool-FileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("timeline-fixture.txt")
        let started = expectation(description: "FSEvents stream started")
        let created = expectation(description: "The root stream delivered the synthetic file")
        let modified = expectation(description: "The root stream delivered a later write")
        let removed = expectation(description: "The root stream delivered the removal")
        [created, modified, removed].forEach { $0.assertForOverFulfill = false }
        let policy = FileChangePolicy(excludedTrees: [], includedTrees: [], onlyWithin: folder.path)
        let token = UUID()
        let fixturePath = FileChangePolicy.canonicalPath(file.path)
        let monitor = FileChangeMonitor(policy: policy, latency: 0.1, batchInterval: 0.3) { generation, update in
            XCTAssertEqual(generation, token)
            switch update {
            case .started: started.fulfill()
            case .changes(let changes):
                if changes.contains(where: { $0.path == fixturePath && $0.action == .appeared }) { created.fulfill() }
                if changes.contains(where: { $0.path == fixturePath && $0.action == .modified }) { modified.fulfill() }
                if changes.contains(where: { $0.path == fixturePath && $0.action == .removed }) { removed.fulfill() }
            case .unavailable: XCTFail("Native file stream failed to start")
            }
        }
        monitor.setRecording(token)
        defer { monitor.setRecording(nil) }
        await fulfillment(of: [started], timeout: 4)

        // Use a child process because the real monitor intentionally ignores its own writes.
        try runChild("/bin/sh", ["-c", "printf 'synthetic' > \"$1\"", "fixture", file.path])
        await fulfillment(of: [created], timeout: 8)
        try runChild("/bin/sh", ["-c", "printf 'edited' >> \"$1\"", "fixture", file.path])
        await fulfillment(of: [modified], timeout: 8)
        try runChild("/bin/unlink", [file.path])
        await fulfillment(of: [removed], timeout: 8)
    }

    private func runChild(_ executable: String, _ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
    }
}
