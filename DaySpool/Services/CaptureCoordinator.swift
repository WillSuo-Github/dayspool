import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import OSLog

struct CaptureOptions {
    var active = false
    var textEnabled = true
    var ocrEnabled = false
    var filesEnabled = false
    var excludedApps: Set<String> = []
}

@MainActor
final class CaptureCoordinator {
    private let store: JournalStore
    private let onChange: () -> Void
    private let onError: (String) -> Void
    private let fixtureWindow: String?
    private var options = CaptureOptions()
    private var session: JournalEvent?
    private var sessionPID: pid_t?
    private var suspended = Set<String>()
    private var tokens: Set<AnyCancellable> = []
    private var timer: Timer?
    private var ocrTask: Task<Void, Never>?
    private var ocrToken: UUID?
    private var nextOCR = Date.distantPast
    private var lastOCR = ""
    private var lastFingerprint: Data?
    private var field: AXUIElement?
    private var baseline: String?
    private var lastSeen: String?
    private var lastEdit: Date?
    private var firstEdit: Date?
    private var lastHeartbeat = Date.distantPast
    private var fixtureStages: [String: String] = [:]
    private var fileGeneration: UUID?
    private lazy var fileMonitor = FileChangeMonitor { [weak self] token, update in
        Task { @MainActor [weak self] in
            self?.handleFiles(update, generation: token)
        }
    }
    private static let fixtureLogger = Logger(subsystem: "com.willsuo.dayspool", category: "CaptureFixture")
    private static let idleSeconds: TimeInterval = 120

    init(store: JournalStore, fixtureWindow: String? = nil,
         onChange: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.store = store
        self.fixtureWindow = fixtureWindow
        self.onChange = onChange
        self.onError = onError
    }

    func configure(_ options: CaptureOptions) {
        endSession()
        self.options = options
        if options.active { tick() }
        else { setFileRecording(false) }
    }

    func start() {
        guard timer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }.store(in: &tokens)
        listen(NSWorkspace.willSleepNotification, at: workspace, reason: "sleep", suspend: true)
        listen(NSWorkspace.didWakeNotification, at: workspace, reason: "sleep", suspend: false)
        listen(NSWorkspace.screensDidSleepNotification, at: workspace, reason: "display", suspend: true)
        listen(NSWorkspace.screensDidWakeNotification, at: workspace, reason: "display", suspend: false)
        listen(NSWorkspace.sessionDidResignActiveNotification, at: workspace, reason: "session", suspend: true)
        listen(NSWorkspace.sessionDidBecomeActiveNotification, at: workspace, reason: "session", suspend: false)
        let distributed = DistributedNotificationCenter.default()
        listen(.init("com.apple.screenIsLocked"), at: distributed, reason: "lock", suspend: true)
        listen(.init("com.apple.screenIsUnlocked"), at: distributed, reason: "lock", suspend: false)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func listen(_ name: Notification.Name, at center: NotificationCenter, reason: String, suspend: Bool) {
        center.publisher(for: name)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if suspend {
                        self.suspended.insert(reason)
                        self.setFileRecording(false)
                        self.endSession()
                    } else {
                        self.suspended.remove(reason)
                        self.tick()
                    }
                }
            }.store(in: &tokens)
    }

    private func tick() {
        guard options.active, suspended.isEmpty else { setFileRecording(false); return }
        guard !screenLocked else { setFileRecording(false); endSession(); return }
        setFileRecording(options.filesEnabled && fixtureWindow == nil)
        let now = Date()
        let foreground = fixtureWindow == nil ? NSWorkspace.shared.frontmostApplication :
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
        if let sessionPID, foreground?.processIdentifier != sessionPID { flushObservedEdit() }
        guard let app = foreground, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, !ContentPolicy.excludes(id), !options.excludedApps.contains(id),
              fixtureWindow != nil || inputAge < Self.idleSeconds else {
            endSession()
            return
        }
        let contentEnabled = options.textEnabled || options.ocrEnabled
        let focus = contentEnabled && AXIsProcessTrusted() ? AccessibilityReader.focus(pid: app.processIdentifier) : nil
        if let fixtureWindow, focus?.window?.title != fixtureWindow {
            fixtureStage("window", "waiting for exact accessible fixture window")
            endSession()
            return
        }
        fixtureStage("window", "matched the fixture window")
        let title = focus.flatMap { $0.canReadText || $0.canCaptureWindow ? $0.window?.title : nil } ?? ""
        // Protected fields suppress all content and start a new metadata-only segment.
        let window = String(title.prefix(240))
        if session?.bundleID != id || sessionPID != app.processIdentifier || session?.window != window {
            flushObservedEdit()
            endSession()
            let event = JournalEvent(kind: .activity, start: now, bundleID: id,
                                     appName: app.localizedName ?? id, window: window)
            do { try store.insert(event) } catch { onError("Could not save an activity."); return }
            session = event
            sessionPID = app.processIdentifier
            lastHeartbeat = now
            nextOCR = now.addingTimeInterval(2)
            onChange()
        } else if now.timeIntervalSince(lastHeartbeat) >= 5, let id = session?.id {
            do { try store.extend(id, to: now); session?.end = now; lastHeartbeat = now; onChange() }
            catch { onError("Could not update an activity.") }
        }
        guard let session, let focus else { clearText(); return }
        if options.textEnabled && focus.canReadText {
            sampleText(focus, now: now)
        } else {
            fixtureStage("text", "focused element is not a supported text area")
            clearText()
        }
        if options.ocrEnabled, now >= nextOCR, ocrTask == nil, focus.canCaptureWindow,
           let target = focus.window, CGPreflightScreenCaptureAccess() {
            nextOCR = now.addingTimeInterval(30)
            scheduleOCR(session: session, pid: app.processIdentifier, target: target, at: now)
        }
    }

    private func setFileRecording(_ enabled: Bool) {
        guard enabled != (fileGeneration != nil) else { return }
        fileGeneration = enabled ? UUID() : nil
        fileMonitor.setRecording(fileGeneration)
    }

    private func handleFiles(_ update: FileChangeMonitor.Update, generation: UUID) {
        guard generation == fileGeneration, options.active, options.filesEnabled,
              suspended.isEmpty, !screenLocked else { return }
        switch update {
        case .started: break
        case .unavailable:
            onError("File monitoring could not start. Turn File Activity off and on to retry.")
        case .changes(let changes):
            do { try store.insertBatch(changes.map(\.journalEvent)); onChange() }
            catch { onError("Could not save file activity.") }
        }
    }

    private var inputAge: TimeInterval {
        [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }

    private var screenLocked: Bool {
        // A launch can occur after the lock notification was sent.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    private func sampleText(_ focus: FocusSnapshot, now: Date) {
        guard let next = focus.element, let text = AccessibilityReader.readText(focus) else {
            fixtureStage("text", "text area did not return a readable value")
            clearText(); return
        }
        if field.map({ CFEqual($0, next) }) != true {
            flushObservedEdit()
            field = next
            baseline = text
            lastSeen = text
            lastEdit = nil
            firstEdit = nil
            fixtureStage("text", "read text and set a baseline")
            return
        }
        if text != lastSeen {
            fixtureStage("text", "observed text change")
            lastSeen = text
            lastEdit = now
            if firstEdit == nil { firstEdit = now }
            if let firstEdit, now.timeIntervalSince(firstEdit) >= 8 { flushObservedEdit() }
        } else if let lastEdit, now.timeIntervalSince(lastEdit) >= 1.2 {
            flushObservedEdit()
        }
    }

    private func flushObservedEdit() {
        guard let session, let baseline, let lastSeen, let lastEdit else { return }
        self.baseline = lastSeen
        self.lastEdit = nil
        self.firstEdit = nil
        guard let added = TextEdit.inserted(from: baseline, to: lastSeen),
              !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        insertContent(added, kind: .edit, at: lastEdit, session: session)
        fixtureStage("text", "submitted text change to journal")
    }

    private func clearText() {
        field = nil; baseline = nil; lastSeen = nil; lastEdit = nil; firstEdit = nil
    }

    private func scheduleOCR(session: JournalEvent, pid: pid_t, target: FocusedWindow, at date: Date) {
        let token = UUID()
        let previous = lastFingerprint
        fixtureStage("ocr", "requested window capture")
        ocrToken = token
        ocrTask = Task { [weak self] in
            defer {
                if let self, self.ocrToken == token { self.ocrTask = nil; self.ocrToken = nil }
            }
            do {
                let snapshot = try await ScreenTextReader.read(pid: pid, target: target, previous: previous)
                guard let self, !Task.isCancelled, self.ocrToken == token, self.session?.id == session.id,
                      self.options.active, self.suspended.isEmpty, !self.screenLocked, CGPreflightScreenCaptureAccess(),
                      self.fixtureWindow != nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let focus = AccessibilityReader.focus(pid: pid), focus.canCaptureWindow, focus.window == target
                else { return }
                guard let snapshot else {
                    self.fixtureStage("ocr", "window match absent or screenshot unchanged")
                    return
                }
                self.lastFingerprint = snapshot.fingerprint
                let trimmed = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != self.lastOCR else { return }
                self.lastOCR = trimmed
                self.insertContent(trimmed, kind: .ocr, at: date, session: session)
                self.fixtureStage("ocr", "submitted OCR text to journal")
            } catch {
                // Windows may disappear between enumeration and capture; try again on the next sample.
                self?.fixtureStage("ocr", "screen capture or recognition failed")
            }
        }
    }

    private func insertContent(_ body: String, kind: EventKind, at date: Date, session: JournalEvent) {
        let event = JournalEvent(kind: kind, start: date, bundleID: session.bundleID, appName: session.appName,
                                 window: session.window, body: body, sessionID: session.id)
        do { try store.insert(event); onChange() } catch { onError("Could not save captured content.") }
    }

    private func fixtureStage(_ channel: String, _ stage: String) {
        guard fixtureWindow != nil, fixtureStages[channel] != stage else { return }
        fixtureStages[channel] = stage
        Self.fixtureLogger.notice("\(channel, privacy: .public): \(stage, privacy: .public)")
    }

    private func endSession() {
        clearText()
        ocrTask?.cancel(); ocrTask = nil; ocrToken = nil
        lastOCR = ""
        lastFingerprint = nil
        guard let old = session else { return }
        session = nil; sessionPID = nil
        // Never add locked/sleep time, even if delivery of a workspace event is delayed.
        let end = min(Date(), max(old.end, lastHeartbeat.addingTimeInterval(5)))
        do { try store.extend(old.id, to: end); onChange() } catch { onError("Could not close an activity.") }
    }
}
