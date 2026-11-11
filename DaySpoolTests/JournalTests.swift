import AppKit
import Foundation
import XCTest
@testable import DaySpool

final class JournalTests: XCTestCase {
    func testTextDeltaHandlesChineseAndReplacements() {
        XCTAssertEqual(TextEdit.inserted(from: "昨天明天", to: "昨天你好🌱明天"), "你好🌱")
        XCTAssertEqual(TextEdit.inserted(from: "a旧b", to: "a新b"), "新")
        XCTAssertNil(TextEdit.inserted(from: "a新b", to: "ab"))
    }

    func testReportQueueOrdersDependenciesAndDeduplicatesAcrossScans() throws {
        let store = try JournalStore(path: ":memory:")
        let cal = utcCalendar
        let time = date("2026-11-02T08:30:00Z")
        let now = date("2026-11-09T00:00:00Z")
        let event = JournalEvent(kind: .activity, start: time, end: time.addingTimeInterval(60),
                                 bundleID: "com.apple.TextEdit", appName: "TextEdit")
        try store.insert(event)
        try store.enqueueClosed(now: now, calendar: cal)
        try store.enqueueClosed(now: now.addingTimeInterval(10), calendar: cal)
        XCTAssertEqual(try store.reports().count, 3)
        for kind in ReportKind.allCases {
            let job = try XCTUnwrap(store.due(now: now))
            XCTAssertEqual(job.period.kind, kind)
            try store.save(.init(items: []), for: job.period)
        }
        XCTAssertNil(try store.due(now: now))
    }

    func testScheduledReportsSkipOldAndManualPeriods() throws {
        let store = try JournalStore(path: ":memory:")
        let old = ReportPeriod(kind: .hour, start: date("2026-11-09T08:00:00Z"), end: date("2026-11-09T09:00:00Z"))
        let next = ReportPeriod(kind: .hour, start: old.end, end: date("2026-11-09T10:00:00Z"))
        let manual = ReportPeriod(kind: .hour, start: date("2026-11-09T08:30:00Z"),
                                  end: date("2026-11-09T09:30:00Z"), isManual: true)
        let day = ReportPeriod(kind: .day, start: date("2026-11-09T00:00:00Z"), end: date("2026-11-10T00:00:00Z"))
        let cutoff = date("2026-11-09T09:30:00Z")
        try [old, next, manual, day].forEach(store.enqueue)
        XCTAssertEqual(try store.due(now: day.end, after: cutoff)?.period, next)
        try store.save(.init(items: []), for: next)
        XCTAssertEqual(try store.due(now: day.end, after: cutoff)?.period, day)
        XCTAssertEqual(try store.reports(kind: .hour, inside: day, after: cutoff).map(\.period), [next])
        XCTAssertEqual(try store.reports(kind: .hour).filter { $0.period.isManual }.map(\.period), [manual])
    }

    func testDeleteRemovesChildAndInvalidatesAllDerivedReports() throws {
        let store = try JournalStore(path: ":memory:")
        let start = date("2026-11-02T08:30:00Z")
        let now = date("2026-11-09T00:00:00Z")
        let first = JournalEvent(kind: .activity, start: start, bundleID: "com.apple.TextEdit", appName: "TextEdit")
        let typed = JournalEvent(kind: .edit, start: start.addingTimeInterval(3), bundleID: first.bundleID,
                                 appName: first.appName, body: "私有文字", sessionID: first.id)
        let second = JournalEvent(kind: .activity, start: start.addingTimeInterval(120), bundleID: "test", appName: "Second")
        try [first, typed, second].forEach(store.insert)
        try store.enqueueClosed(now: now, calendar: utcCalendar)
        for report in try store.reports() {
            try store.save(.init(items: [.init(project: "Project", update: "Update", status: .observed,
                                              evidenceIDs: [typed.id])]), for: report.period)
        }
        try store.remove(first)
        XCTAssertNil(try store.event(id: typed.id))
        XCTAssertEqual(try store.recent().map(\.id), [second.id])
        let invalidated = try store.reports()
        XCTAssertEqual(invalidated.count, 3)
        XCTAssertTrue(invalidated.allSatisfy { $0.state == .pending && $0.content == nil })
    }

    func testEvidenceIDsCannotBeInvented() throws {
        let output = ReportContent(items: [.init(project: "X", update: "Y", status: .observed,
                                                 evidenceIDs: ["fake", "real", "real"])])
        XCTAssertEqual(try ReportGenerator.validate(output, allowed: ["real"]).items.first?.evidenceIDs, ["real"])
        XCTAssertThrowsError(try ReportGenerator.validate(output, allowed: []))
    }

    func testCalendarBackfillsHoursThroughDST() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let periods = ReportCalendar.closedPeriods(kind: .hour, first: date("2026-11-01T04:00:00Z"),
                                                   now: date("2026-11-02T05:00:00Z"), calendar: cal)
        XCTAssertEqual(periods.count, 25)
        XCTAssertEqual(Set(periods.map(\.id)).count, 25)
    }

    @MainActor
    func testVisionRecognizesTextFromSyntheticWindowImage() throws {
        let image = NSImage(size: NSSize(width: 840, height: 240), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            ("DaySpool 4827" as NSString).draw(at: NSPoint(x: 36, y: 89), withAttributes: [
                .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black
            ])
            return true
        }
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let text = try ScreenTextReader.recognizeText(in: bitmap)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("DaySpool 4827"), text)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
}
