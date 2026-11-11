import Foundation

enum ReportKind: String, CaseIterable, Identifiable {
    case hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hour: "Hourly"
        case .day: "Daily"
        case .week: "Weekly"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        }
    }

    var dependency: ReportKind? {
        switch self {
        case .hour: nil
        case .day: .hour
        case .week: .day
        }
    }
}

struct ReportPeriod: Identifiable, Equatable {
    let kind: ReportKind
    let start: Date
    let end: Date
    var isManual = false
    var id: String {
        let prefix = isManual ? "manual:" : ""
        return "\(prefix)\(kind.rawValue):\(Int(start.timeIntervalSince1970)):\(Int(end.timeIntervalSince1970))"
    }
    var label: String {
        if isManual {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        if kind == .hour { return start.formatted(date: .abbreviated, time: .shortened) }
        if kind == .day { return start.formatted(date: .abbreviated, time: .omitted) }
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
    }
}

enum ReportCalendar {
    static func local() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    static func closedPeriods(kind: ReportKind, first: Date, now: Date, calendar: Calendar) -> [ReportPeriod] {
        guard first <= now else { return [] }
        var result: [ReportPeriod] = []
        var cursor = first
        while let interval = calendar.dateInterval(of: kind.component, for: cursor),
              interval.end <= now, interval.end > cursor {
            result.append(.init(kind: kind, start: interval.start, end: interval.end))
            cursor = interval.end
        }
        return result
    }
}

enum ReportState: String { case pending, ready, failed }

struct StoredReport: Identifiable {
    let period: ReportPeriod
    let state: ReportState
    let content: ReportContent?
    let nextAttempt: Date
    var id: String { period.id }
}

struct ReportContent: Codable, Equatable {
    struct Item: Codable, Equatable {
        let project: String
        let update: String
        let status: Status
        let evidenceIDs: [String]
    }

    enum Status: String, Codable, CaseIterable {
        case observed, inProgress, completed, blocked, next
        var title: String {
            switch self {
            case .observed: "Observed"
            case .inProgress: "In progress"
            case .completed: "Completed"
            case .blocked: "Blocked"
            case .next: "Next"
            }
        }
    }

    let items: [Item]
    /// Set by DaySpool from the inputs, not from model-provided metadata.
    let includesFileEvidence: Bool?
    let fileActivitySince: Date?

    init(items: [Item], includesFileEvidence: Bool? = nil, fileActivitySince: Date? = nil) {
        self.items = items
        self.includesFileEvidence = includesFileEvidence
        self.fileActivitySince = fileActivitySince
    }

    func markdown(for period: ReportPeriod) -> String {
        var parts = ["# \(period.kind.title) report · \(period.label)"]
        for status in Status.allCases {
            let lines = items.filter { $0.status == status }.map {
                let evidence = $0.evidenceIDs.joined(separator: ", ")
                return "- **\($0.project)**: \($0.update) (Evidence: \(evidence))"
            }
            if !lines.isEmpty { parts.append("## \(status.title)\n\n" + lines.joined(separator: "\n")) }
        }
        if items.isEmpty { parts.append("No supported updates for this period.") }
        return parts.joined(separator: "\n\n") + "\n"
    }
}
