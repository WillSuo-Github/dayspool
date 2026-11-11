import Foundation
import XCTest
@testable import DaySpool

final class CodexCLITests: XCTestCase {
    func testSyntheticJournalFlowsThroughCLIAndKeepsOnlyKnownEvidence() async throws {
        let fake = try fixture(script: """
            #!/bin/sh
            out=
            schema=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --output-last-message) out="$2"; shift ;;
                --output-schema) schema="$2"; shift ;;
              esac
              shift
            done
            [ -f "$schema" ] || exit 41
            prompt="$(cat)"
            case "$prompt" in *"Created a synthetic test note"*) ;; *) exit 42 ;; esac
            case "$prompt" in *"fixture-id"*) ;; *) exit 43 ;; esac
            case "$prompt" in *"before-opt-in"*|*"not-a-real-secret"*) exit 44 ;; esac
            printf '%s' '{"items":[{"project":"Test","update":"Created a synthetic note","status":"observed","evidenceIDs":["fixture-id","not-a-source"]}]}' > "$out"
            """)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        try await runSyntheticJournal(using: fake)
    }

    @MainActor
    private func runSyntheticJournal(using executable: URL) async throws {
        let store = try JournalStore(path: ":memory:")
        let time = Date(timeIntervalSince1970: 360)
        let event = JournalEvent(id: "fixture-id", kind: .edit, start: time, bundleID: "test.fixture",
                                 appName: "Fixture", body: "Created a synthetic test note\napi_key=not-a-real-secret")
        let old = JournalEvent(kind: .edit, start: time.addingTimeInterval(-60), bundleID: "test.fixture",
                               appName: "Fixture", body: "before-opt-in")
        try store.insert(old)
        try store.insert(event)
        let result = try await ReportGenerator(store: store, client: .init(executable: executable))
            .generate(period: .init(kind: .hour, start: Date(timeIntervalSince1970: 0),
                                    end: Date(timeIntervalSince1970: 3600)), language: "English", after: time)
        XCTAssertEqual(result.items.map(\.evidenceIDs), [["fixture-id"]])
    }

    func testUnresponsiveCLIIsInterrupted() async throws {
        let fake = try fixture(script: "#!/bin/sh\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let client = CodexCLI(executable: fake, timeout: .milliseconds(200))
        let start = ContinuousClock.now
        do {
            _ = try await client.summarize(kind: .hour, input: [], language: "English")
            XCTFail("Expected a timeout")
        } catch CodexCLI.Failure.timedOut {
            XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        }
    }

    @MainActor
    func testUnifiedFileActivitySendsOnlyNewNames() async throws {
        let fake = try fixture(script: """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in --output-last-message) out="$2"; shift ;; esac
              shift
            done
            prompt="$(cat)"
            case "$prompt" in *"new-budget.pdf"*) ;; *) exit 51 ;; esac
            case "$prompt" in *"prior-file.pdf"*|*"/private-demo"*) exit 52 ;; esac
            printf '%s' '{"items":[{"project":"Fixture","update":"Observed a file modification","status":"observed","evidenceIDs":["file-new"]}]}' > "$out"
            """)
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let store = try JournalStore(path: ":memory:")
        let since = Date(timeIntervalSince1970: 600)
        let prior = FileChange(action: .modified, path: "/private-demo/prior-file.pdf",
                               firstSeen: since.addingTimeInterval(-10), lastSeen: since, notifications: 1)
        let new = FileChange(action: .modified, path: "/private-demo/new-budget.pdf",
                             firstSeen: since, lastSeen: since, notifications: 1).journalEvent
        try store.insertBatch([prior.journalEvent, .init(id: "file-new", kind: new.kind, start: new.start,
                                                        end: new.end, bundleID: new.bundleID, appName: new.appName,
                                                        window: new.window, body: new.body)])
        let period = ReportPeriod(kind: .hour, start: Date(timeIntervalSince1970: 0),
                                  end: Date(timeIntervalSince1970: 3600))
        let result = try await ReportGenerator(store: store, client: .init(executable: fake))
            .generate(period: period, language: "English", filesSince: since)
        XCTAssertEqual(result.items.first?.evidenceIDs, ["file-new"])
        XCTAssertEqual(result.fileActivitySince, since)
    }

    private func fixture(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("codex")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
}
