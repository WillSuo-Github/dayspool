import CoreServices
import Darwin
import Foundation

/// All stream and batch state is confined to the worker queue. Only compacted records
/// cross over to the main actor. Neither the callback nor the reducer reads file data.
final class FileChangeMonitor: @unchecked Sendable {
    enum Update: Sendable {
        case started
        case changes([FileChange])
        case unavailable
    }

    private final class CallbackContext {
        weak var owner: FileChangeMonitor?
        init(owner: FileChangeMonitor) { self.owner = owner }
    }

    private let worker = DispatchQueue(label: "com.willsuo.dayspool.files", qos: .utility)
    private let root: String
    private let policy: FileChangePolicy
    private let latency: TimeInterval
    private let batchInterval: TimeInterval
    private let receive: @Sendable (UUID, Update) -> Void
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var generation: UUID?
    private var batch = FileChangeBatcher()
    private var knownFiles: Set<String> = []
    private var metadataChecks = 0
    private static let callbackLimit = 4_096
    private static let knownFileLimit = 2_048
    private static let metadataCheckLimit = 32

    static var startupRoot: String {
        let data = "/System/Volumes/Data"
        return FileManager.default.fileExists(atPath: data) ? data : "/"
    }

    init(root: String = FileChangeMonitor.startupRoot, policy: FileChangePolicy = .desktop(), latency: TimeInterval = 3,
         batchInterval: TimeInterval = 12, receive: @escaping @Sendable (UUID, Update) -> Void) {
        self.root = root
        self.policy = policy
        self.latency = latency
        self.batchInterval = batchInterval
        self.receive = receive
    }

    func setRecording(_ generation: UUID?) {
        worker.async { [self] in
            close()
            guard let generation else { return }
            self.generation = generation
            open(generation)
        }
    }

    private func open(_ token: UUID) {
        let holder = CallbackContext(owner: self)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(holder).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in if let info { Unmanaged<CallbackContext>.fromOpaque(info).release() } },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let holder = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            holder.owner?.accept(count: count, paths: paths, flags: flags)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                                            kFSEventStreamCreateFlagIgnoreSelf |
                                            kFSEventStreamCreateFlagWatchRoot)
        let created = withExtendedLifetime(holder) {
            FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        }
        guard let stream = created else {
            receive(token, .unavailable)
            return
        }
        self.stream = stream
        if !policy.streamExclusions.isEmpty {
            _ = FSEventStreamSetExclusionPaths(stream, policy.streamExclusions as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, worker)
        if FSEventStreamStart(stream) {
            receive(token, .started)
        } else {
            close()
            receive(token, .unavailable)
        }
    }

    private func accept(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard generation != nil else { return }
        let observedAt = Date()
        // Without UseCFTypes the callback carries an array of UTF-8 C strings.
        let names = paths.assumingMemoryBound(to: Optional<UnsafePointer<CChar>>.self)
        var accepted = false
        for index in 0..<min(count, Self.callbackLimit) {
            let bits = Int(flags[index])
            if bits & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                       kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                batch.markIncomplete(at: observedAt)
                accepted = true
                continue
            }
            let relevant = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
            guard bits & kFSEventStreamEventFlagItemIsFile != 0, bits & relevant != 0,
                  let name = names[index], let decoded = String(validatingUTF8: name),
                  let path = policy.acceptedPath(decoded), let action = action(bits, path: path) else { continue }
            batch.observe(action, path: path, at: observedAt)
            accepted = true
        }
        if count > Self.callbackLimit {
            batch.markIncomplete(at: observedAt, notifications: count - Self.callbackLimit)
            accepted = true
        }
        if accepted && timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now() + batchInterval, leeway: .milliseconds(300))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.timer = timer
            timer.resume()
        }
    }

    private func action(_ bits: Int, path: String) -> FileChange.Action? {
        let created = bits & kFSEventStreamEventFlagItemCreated != 0
        let removed = bits & kFSEventStreamEventFlagItemRemoved != 0
        let renamed = bits & kFSEventStreamEventFlagItemRenamed != 0
        let modified = bits & kFSEventStreamEventFlagItemModified != 0
        if renamed && !created && !removed {
            knownFiles.remove(path)
            return .renamedOrMoved
        }
        // FSEvents can deliver the union of earlier flags for the same path.
        // For a conflicting removal, check only this path, with a per-batch cap.
        if removed {
            if !created && !modified && !renamed {
                knownFiles.remove(path)
                return .removed
            }
            guard metadataChecks < Self.metadataCheckLimit else {
                knownFiles.remove(path)
                return .changed
            }
            metadataChecks += 1
            var metadata = stat()
            let status = path.withCString { lstat($0, &metadata) }
            if status != 0, errno == ENOENT || errno == ENOTDIR {
                knownFiles.remove(path)
                return .removed
            }
            if status == 0 { remember(path) } else { knownFiles.remove(path) }
            return .changed
        }
        let seen = knownFiles.contains(path)
        if created || modified { remember(path) }
        if created && !seen { return .appeared }
        if modified { return .modified }
        return created ? .changed : nil
    }

    private func remember(_ path: String) {
        if knownFiles.contains(path) { return }
        if knownFiles.count >= Self.knownFileLimit { knownFiles.removeAll(keepingCapacity: true) }
        knownFiles.insert(path)
    }

    private func flush() {
        timer?.cancel()
        timer = nil
        let changes = batch.drain()
        metadataChecks = 0
        guard let generation, !changes.isEmpty else { return }
        receive(generation, .changes(changes))
    }

    private func close() {
        generation = nil
        timer?.cancel()
        timer = nil
        batch = FileChangeBatcher()
        knownFiles.removeAll(keepingCapacity: true)
        metadataChecks = 0
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        // A queued start/stop retains this object until it returns. No callback can
        // race destruction after invalidating the stream.
        timer?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
