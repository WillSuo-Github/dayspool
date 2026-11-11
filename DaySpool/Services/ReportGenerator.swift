import Foundation

struct ReportInput: Encodable {
    let detail: String
    let evidenceIDs: [String]
    var includesFileEvidence = false

    private enum CodingKeys: String, CodingKey { case detail, evidenceIDs }
}

struct ReportGenerator {
    private let store: JournalStore
    private let client: CodexCLI

    init(store: JournalStore, client: CodexCLI) {
        self.store = store
        self.client = client
    }

    @MainActor
    func generate(period: ReportPeriod, language: String, after cutoff: Date = .distantPast,
                  includeFiles: Bool = false) async throws -> ReportContent {
        let evidence: [ReportInput]
        if let dependency = period.kind.dependency {
            let children = try store.reports(kind: dependency, inside: period, after: cutoff)
            let byChild = children.map { child -> [ReportInput] in
                guard let content = child.content, includeFiles || content.includesFileEvidence != true else { return [] }
                return content.items.map { item in
                    ReportInput(detail: "[\(child.period.label)] \(item.status.rawValue) · \(item.project): \(item.update)",
                                evidenceIDs: Array(item.evidenceIDs.prefix(5)),
                                includesFileEvidence: content.includesFileEvidence == true)
                }
            }
            // Give each hour/day a turn before including additional items from it.
            evidence = (0..<6).flatMap { index in
                byChild.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        } else {
            let evidenceStart = max(period.start, cutoff)
            guard evidenceStart < period.end else { return ReportContent(items: []) }
            let range = ReportPeriod(kind: period.kind, start: evidenceStart, end: period.end)
            evidence = try store.evidence(for: range, includeFiles: includeFiles).compactMap { event in
                let begin = max(event.start, evidenceStart)
                let end = min(event.end, period.end)
                if event.kind == .file {
                    guard let change = event.fileChange, change.action != .incomplete else { return nil }
                    return ReportInput(detail: "\(begin.formatted(date: .omitted, time: .shortened)) · observed file event · \(change.action.title): \(Self.redact(change.name).prefix(180))",
                                       evidenceIDs: [event.id], includesFileEvidence: true)
                }
                let context = Self.redact(event.window.isEmpty ? event.appName : "\(event.appName) / \(event.window)")
                let duration = event.kind == .activity ? " · \(max(0, Int(end.timeIntervalSince(begin))))s" : ""
                return ReportInput(detail: "\(begin.formatted(date: .omitted, time: .shortened)) · \(event.kind.rawValue) · \(context)\(duration)\n\(Self.redact(event.body).prefix(400))",
                                   evidenceIDs: [event.id])
            }
        }
        var budget = 7_000
        var selected: [ReportInput] = []
        for input in evidence {
            let cost = input.detail.utf8.count + input.evidenceIDs.reduce(0) { $0 + $1.utf8.count } + 42
            guard cost <= budget else { continue }
            budget -= cost
            selected.append(input)
        }
        guard !selected.isEmpty else { return ReportContent(items: []) }
        let output = try await client.summarize(kind: period.kind, input: selected, language: language)
        let validated = try Self.validate(output, allowed: Set(selected.flatMap(\.evidenceIDs)))
        return ReportContent(items: validated.items, includesFileEvidence: selected.contains(where: \.includesFileEvidence))
    }

    private static let credentialLine = try! NSRegularExpression(
        pattern: #"(?i)-----BEGIN .*PRIVATE KEY|\b(?:authorization|password|passwd|api[ _-]?key|access[ _-]?token|client[ _-]?secret)\s*[:=]|\bbearer\s+\S+|\b(?:sk-[a-z0-9_-]{10,}|gh[pousr]_[a-z0-9_]{10,}|AKIA[A-Z0-9]{16})\b|https?://\S+\?\S*(?:token|signature|sig|key|code)="#
    )

    private static func redact(_ text: String) -> String {
        if text.contains("PRIVATE KEY-----") { return "[redacted key material]" }
        return text.components(separatedBy: .newlines).map { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return credentialLine.firstMatch(in: line, range: range) == nil ? line : "[redacted credential line]"
        }.joined(separator: "\n")
    }

    static func validate(_ output: ReportContent, allowed: Set<String>) throws -> ReportContent {
        guard output.items.count <= 12 else { throw CodexCLI.Failure.invalidReport }
        let items = output.items.compactMap { item -> ReportContent.Item? in
            let ids = item.evidenceIDs.filter(allowed.contains)
            guard !ids.isEmpty,
                  !item.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.update.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var seen: Set<String> = []
            return .init(project: String(item.project.prefix(100)), update: String(item.update.prefix(450)),
                         status: item.status, evidenceIDs: Array(ids.filter { seen.insert($0).inserted }.prefix(6)))
        }
        if items.isEmpty && !output.items.isEmpty { throw CodexCLI.Failure.invalidReport }
        return ReportContent(items: items)
    }
}
