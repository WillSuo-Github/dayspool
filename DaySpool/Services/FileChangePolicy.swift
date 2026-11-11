import Foundation

struct FileChangePolicy: Sendable {
    private static let dataPrefix = "/System/Volumes/Data"
    private static let tempNames: Set<Substring> = [".DS_Store", ".git", "node_modules", "DerivedData", "__pycache__"]
    private static let tempSuffixes = [".tmp", ".crdownload", ".part", ".swp", ".sqlite-wal", ".sqlite-shm"]
    let excludedTrees: [String]
    let includedTrees: [String]
    var onlyWithin: String? = nil

    static func desktop(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Self {
        .init(excludedTrees: [
            "/System", "/Network", "/Volumes", "/dev", "/private/var", "/private/tmp", "/tmp", "/var",
            "/Library/Caches", "/Library/Logs", "/Library/Updates", "/.fseventsd", "/.Spotlight-V100",
            "/.DocumentRevisions-V100", "/.Trashes", "/.TemporaryItems", home + "/.Trash", home + "/Library"
        ], includedTrees: [home + "/Library/CloudStorage", home + "/Library/Mobile Documents"])
    }

    /// Only exclusion paths without exceptions are suitable for the OS-side filter.
    var streamExclusions: [String] {
        let heavy = excludedTrees.filter { ["/private/var", "/private/tmp", "/Library/Caches", "/Library/Updates"].contains($0) }
        return Array((heavy + heavy.map { Self.dataPrefix + $0 }).prefix(8))
    }

    static func canonicalPath(_ raw: String) -> String {
        var path = raw
        if raw.hasPrefix(Self.dataPrefix + "/") {
            path = String(raw.dropFirst(Self.dataPrefix.count))
        }
        // The system can emit /private/var where a client URL spells /var.
        for alias in ["/var", "/tmp", "/etc"] where inTree(path, alias) { return "/private" + path }
        return path
    }

    func acceptedPath(_ raw: String) -> String? {
        let path = Self.canonicalPath(raw)
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return nil }
        if let onlyWithin, !Self.inTree(path, Self.canonicalPath(onlyWithin)) { return nil }
        if !includedTrees.contains(where: { Self.inTree(path, $0) }),
           excludedTrees.contains(where: { Self.inTree(path, $0) }) { return nil }
        let parts = path.split(separator: "/")
        guard let name = parts.last, !parts.contains(where: { Self.tempNames.contains($0) }),
              !name.hasPrefix("._"), !name.hasSuffix("~") else { return nil }
        let lower = name.lowercased()
        guard !Self.tempSuffixes.contains(where: lower.hasSuffix)
        else { return nil }
        return path
    }

    private static func inTree(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

struct FileChangeBatcher {
    private struct Entry {
        var action: FileChange.Action
        var first: Date
        var last: Date
        var count: Int

        mutating func merge(_ other: Entry, as action: FileChange.Action) {
            self.action = action
            first = min(first, other.first)
            last = max(last, other.last)
            count += other.count
        }

        func change(path: String?) -> FileChange {
            .init(action: action, path: path, firstSeen: first, lastSeen: last, notifications: count)
        }
    }

    let maxFiles: Int
    let maxFolders: Int
    let groupAt: Int
    private var files: [String: Entry] = [:]
    private var overflowFolders: [String: Entry] = [:]
    private var gap: Entry?

    init(maxFiles: Int = 256, maxFolders: Int = 32, groupAt: Int = 12) {
        self.maxFiles = maxFiles
        self.maxFolders = maxFolders
        self.groupAt = groupAt
    }

    mutating func observe(_ action: FileChange.Action, path: String, at date: Date) {
        let new = Entry(action: action, first: date, last: date, count: 1)
        if var existing = files[path] {
            existing.merge(new, as: existing.action.combined(with: action))
            files[path] = existing
        } else if files.count < maxFiles {
            files[path] = new
        } else {
            let parent = Self.parent(of: path)
            if var existing = overflowFolders[parent] {
                existing.merge(new, as: .batch)
                overflowFolders[parent] = existing
            } else if overflowFolders.count < maxFolders {
                overflowFolders[parent] = .init(action: .batch, first: date, last: date, count: 1)
            } else {
                markIncomplete(at: date, notifications: 1)
            }
        }
    }

    mutating func markIncomplete(at date: Date, notifications: Int = 0) {
        let entry = Entry(action: .incomplete, first: date, last: date, count: notifications)
        if var gap { gap.merge(entry, as: .incomplete); self.gap = gap } else { gap = entry }
    }

    mutating func drain() -> [FileChange] {
        let groups = Dictionary(grouping: files, by: { Self.parent(of: $0.key) })
        var output: [FileChange] = []
        var grouped = overflowFolders
        for (parent, entries) in groups {
            if entries.count >= groupAt || grouped[parent] != nil {
                for entry in entries {
                    if var existing = grouped[parent] {
                        existing.merge(entry.value, as: .batch)
                        grouped[parent] = existing
                    } else {
                        let e = entry.value
                        grouped[parent] = .init(action: .batch, first: e.first, last: e.last, count: e.count)
                    }
                }
            } else {
                output.append(contentsOf: entries.map { $0.value.change(path: $0.key) })
            }
        }
        output.append(contentsOf: grouped.map { $0.value.change(path: $0.key) })
        if let gap { output.append(gap.change(path: nil)) }
        files.removeAll(keepingCapacity: true)
        overflowFolders.removeAll(keepingCapacity: true)
        gap = nil
        return output.sorted {
            $0.firstSeen == $1.firstSeen ? ($0.path ?? "") < ($1.path ?? "") : $0.firstSeen < $1.firstSeen
        }
    }

    private static func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }
}
