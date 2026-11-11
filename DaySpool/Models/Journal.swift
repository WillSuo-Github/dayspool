import Foundation

enum EventKind: String, Codable {
    case activity, edit, ocr, file

    var title: String {
        switch self {
        case .activity: "App activity"
        case .edit: "Text edit"
        case .ocr: "Screen text"
        case .file: "File activity"
        }
    }

    var icon: String {
        switch self {
        case .activity: "app"
        case .edit: "character.cursor.ibeam"
        case .ocr: "text.viewfinder"
        case .file: "doc"
        }
    }
}

struct JournalEvent: Identifiable, Equatable {
    let id: String
    let kind: EventKind
    let start: Date
    var end: Date
    let bundleID: String
    let appName: String
    let window: String
    let body: String
    let sessionID: String?

    init(id: String = UUID().uuidString, kind: EventKind, start: Date, end: Date? = nil,
         bundleID: String, appName: String, window: String = "", body: String = "", sessionID: String? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.bundleID = bundleID
        self.appName = appName
        self.window = window
        self.body = body
        self.sessionID = sessionID
    }
}

enum TextEdit {
    /// Treat a changed control as text evidence, not proof of physical keystrokes.
    static func inserted(from old: String, to new: String) -> String? {
        guard old != new else { return nil }
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let oldTail = old.dropFirst(prefix), newTail = new.dropFirst(prefix)
        let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix(while: { $0 == $1 }).count
        let change = newTail.dropLast(suffix)
        return change.isEmpty ? nil : String(change.prefix(4_000))
    }
}

enum ContentPolicy {
    private static let blocked = Set([
        "com.apple.Passwords", "com.apple.keychainaccess", "com.agilebits.onepassword7",
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.SecurityAgent",
        "com.apple.loginwindow", "com.apple.systempreferences", "com.apple.systemuiserver"
    ].map { $0.lowercased() })

    static func excludes(_ bundleID: String) -> Bool {
        let value = bundleID.lowercased()
        return blocked.contains(value) || value.contains("1password") || value.contains("bitwarden") ||
            value.contains("keepass") || value.contains("keychain") || value.contains("dashlane")
    }

    static func isPrivateTitle(_ title: String) -> Bool {
        let markers = ["incognito", "private browsing", "private window", "inprivate", "无痕", "隐私浏览", "私密浏览"]
        return markers.contains { title.localizedCaseInsensitiveContains($0) }
    }
}
