import Foundation

struct FileChange: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case appeared, modified, removed, renamedOrMoved, changed, batch, incomplete

        var title: String {
            switch self {
            case .appeared: "File appeared"
            case .modified: "File modified"
            case .removed: "File removed"
            case .renamedOrMoved: "File renamed or moved"
            case .changed: "File changed"
            case .batch: "Multiple file changes"
            case .incomplete: "File activity may be incomplete"
            }
        }

        func combined(with later: Action) -> Action {
            if self == later { return self }
            // Keep a clear initial creation when the same file is saved shortly afterward.
            if self == .appeared && later == .modified { return .appeared }
            return .changed
        }
    }

    let action: Action
    let path: String?
    let firstSeen: Date
    let lastSeen: Date
    let notifications: Int

    var name: String {
        guard let path else { return action.title }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    var journalEvent: JournalEvent {
        let encoded = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return .init(kind: .file, start: firstSeen, end: lastSeen, bundleID: "local.files",
                     appName: "Files", window: path ?? "", body: encoded)
    }
}

extension JournalEvent {
    var fileChange: FileChange? {
        guard kind == .file else { return nil }
        return try? JSONDecoder().decode(FileChange.self, from: Data(body.utf8))
    }
}
