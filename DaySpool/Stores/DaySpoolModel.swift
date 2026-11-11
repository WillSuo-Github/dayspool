import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class DaySpoolModel {
    var accepted: Bool
    var paused: Bool
    var textEnabled: Bool
    var ocrEnabled: Bool
    var filesEnabled: Bool
    var filesInReports: Bool
    var excludedApps: Set<String>
    private(set) var codexEnabled: Bool
    private(set) var codexPath: String
    var reportLanguage: String
    var generating = false
    var statusMessage: String?
    var captureError: String?
    var accessibilityGranted = false
    var screenGranted = false
    var journal: [JournalEvent] = []
    var reportList: [StoredReport] = []
    var search = "" { didSet { reloadJournal() } }
    var journalKind: EventKind? { didSet { reloadJournal() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: JournalStore?
    @ObservationIgnored private var capture: CaptureCoordinator?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var jobID: UUID?
    @ObservationIgnored private var calendar = ReportCalendar.local()
    @ObservationIgnored private var nextQueueScan = Date.distantPast
    @ObservationIgnored private var nextCodexAttempt = Date.distantPast
    @ObservationIgnored private var codexSince: Date?
    private let testing: Bool
    private let fixtureWindow: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        testing = ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        fixtureWindow = arguments.firstIndex(of: "--textedit-fixture-window").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }.flatMap { $0.isEmpty ? nil : $0 }
        #else
        fixtureWindow = nil
        #endif
        accepted = defaults.bool(forKey: "captureConsentV2")
        paused = defaults.bool(forKey: "paused")
        textEnabled = defaults.object(forKey: "textEnabled") as? Bool ?? true
        ocrEnabled = defaults.bool(forKey: "ocrEnabled")
        filesEnabled = defaults.bool(forKey: "fileActivityEnabled")
        filesInReports = defaults.bool(forKey: "fileActivityInCodexReports")
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? [])
        codexEnabled = defaults.bool(forKey: "codexReportsEnabled")
        codexPath = defaults.string(forKey: "codexPath") ?? ""
        codexSince = defaults.object(forKey: "codexReportsSince") as? Date
        reportLanguage = defaults.string(forKey: "reportLanguage") ?? "Auto"
        if let zone = defaults.string(forKey: "journalTimeZone").flatMap(TimeZone.init(identifier:)) {
            calendar.timeZone = zone
        }
        do {
            if testing {
                store = try JournalStore(path: ":memory:")
            } else if fixtureWindow != nil {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DaySpool-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                store = try JournalStore(path: folder.appendingPathComponent("journal.sqlite").path)
            } else {
                store = try JournalStore.local()
            }
        }
        catch { store = nil; captureError = error.localizedDescription }
        if let store, !testing {
            capture = CaptureCoordinator(store: store, fixtureWindow: fixtureWindow,
                                         onChange: { [weak self] in self?.reloadJournal() },
                                         onError: { [weak self] in self?.captureError = $0 })
            capture?.start()
            applyCaptureSettings()
            if fixtureWindow == nil, ProcessInfo.processInfo.arguments.contains("--enable-codex-reports") {
                if !codexEnabled { codexSince = Date() }
                codexEnabled = true
                persistReportSettings()
            }
            reloadReports()
            if ProcessInfo.processInfo.arguments.contains("--generate-last-hour") {
                generateLastHour()
            }
            watch = Task { [weak self] in
                while !Task.isCancelled {
                    self?.poll()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        }
    }

    var isRecording: Bool { accepted && !paused && store != nil && !testing }

    func acceptCapture() {
        guard store != nil else { return }
        accepted = true
        paused = false
        defaults.set(calendar.timeZone.identifier, forKey: "journalTimeZone")
        applyCaptureSettings()
    }

    func togglePause() {
        guard accepted else { return }
        paused.toggle()
        applyCaptureSettings()
    }

    func pauseForTermination() {
        capture?.configure(CaptureOptions())
        job?.cancel()
    }

    func requestAccessibility() {
        AccessibilityReader.requestPermission()
        refreshPermissions()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    func applyCaptureSettings() {
        defaults.set(accepted, forKey: "captureConsentV2")
        defaults.set(paused, forKey: "paused")
        defaults.set(textEnabled, forKey: "textEnabled")
        defaults.set(ocrEnabled, forKey: "ocrEnabled")
        defaults.set(filesEnabled, forKey: "fileActivityEnabled")
        defaults.set(excludedApps.sorted(), forKey: "excludedApps")
        capture?.configure(.init(active: isRecording, textEnabled: textEnabled, ocrEnabled: ocrEnabled,
                                 filesEnabled: filesEnabled, excludedApps: excludedApps))
        refreshPermissions()
    }

    var codexExecutable: URL? { CodexCLI.locate(override: codexPath) }

    func setCodexEnabled(_ enabled: Bool) {
        if enabled && !codexEnabled { codexSince = Date() }
        codexEnabled = enabled
        saveReportSettings()
    }

    func selectCodex(at path: String) {
        guard codexPath != path else { return }
        codexPath = path
        codexEnabled = false
        saveReportSettings()
    }

    func saveReportSettings() {
        persistReportSettings()
        cancelJob()
        retryReports()
    }

    private func persistReportSettings() {
        defaults.set(codexEnabled, forKey: "codexReportsEnabled")
        defaults.set(codexPath, forKey: "codexPath")
        defaults.set(reportLanguage, forKey: "reportLanguage")
        defaults.set(filesInReports, forKey: "fileActivityInCodexReports")
        defaults.set(codexSince, forKey: "codexReportsSince")
    }

    func generateLastHour() {
        guard codexEnabled, job == nil, !testing, fixtureWindow == nil, let store else { return }
        guard let executable = codexExecutable else {
            statusMessage = "Codex CLI was not found. Choose its executable in Settings."
            return
        }
        let end = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let period = ReportPeriod(kind: .hour, start: end.addingTimeInterval(-3600), end: end, isManual: true)
        do {
            try store.enqueue(period)
            reloadReports()
            run(.init(period: period, state: .pending, content: nil, nextAttempt: .distantPast),
                store: store, executable: executable)
        } catch { statusMessage = error.localizedDescription }
    }

    func retryReports() {
        do { try store?.retryFailed() }
        catch { statusMessage = error.localizedDescription; return }
        statusMessage = nil
        nextQueueScan = .distantPast
        nextCodexAttempt = .distantPast
        poll()
    }

    func delete(_ event: JournalEvent) {
        cancelJob()
        if !paused {
            paused = true
            applyCaptureSettings()
        }
        do {
            try store?.remove(event)
            reloadJournal()
            reloadReports()
        } catch { captureError = error.localizedDescription }
    }

    func clearJournal() {
        cancelJob()
        paused = true
        applyCaptureSettings()
        do {
            try store?.removeAll()
            nextQueueScan = .distantPast
            reloadJournal()
            reloadReports()
        } catch { captureError = error.localizedDescription }
    }

    func evidence(_ ids: [String]) -> [JournalEvent] {
        ids.compactMap { try? store?.event(id: $0) }
    }

    private func reloadJournal() {
        do { journal = try store?.recent(search: search, kind: journalKind) ?? [] }
        catch { captureError = error.localizedDescription }
    }

    private func reloadReports() {
        do {
            let cutoff = codexSince ?? .distantPast
            reportList = try store?.reports().filter { $0.period.isManual || $0.state == .ready || $0.period.end > cutoff } ?? []
        }
        catch { statusMessage = error.localizedDescription }
    }

    private func cancelJob() {
        job?.cancel()
        // Keep the active slot occupied until the cancelled request actually returns.
    }

    private func poll() {
        refreshPermissions()
        guard let store, !testing, fixtureWindow == nil else { return }
        let now = Date()
        do {
            if now >= nextQueueScan {
                try store.enqueueClosed(now: now.addingTimeInterval(-45), calendar: calendar)
                nextQueueScan = now.addingTimeInterval(20)
                reloadReports()
            }
            guard codexEnabled, job == nil, now >= nextCodexAttempt,
                  let next = try store.due(now: now, after: codexSince ?? .distantPast) else { return }
            guard let executable = codexExecutable else {
                statusMessage = "Codex CLI was not found. Choose its executable in Settings."
                nextCodexAttempt = now.addingTimeInterval(5 * 60)
                return
            }
            run(next, store: store, executable: executable)
        } catch { statusMessage = error.localizedDescription }
    }

    private func run(_ report: StoredReport, store: JournalStore, executable: URL) {
        let cutoff = report.period.isManual ? Date.distantPast : codexSince ?? .distantPast
        let includeFiles = filesInReports
        let lang = reportLanguage == "Auto"
            ? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "Simplified Chinese" : "English")
            : reportLanguage
        let id = UUID()
        jobID = id
        generating = true
        job = Task { [weak self] in
            defer {
                if let self, self.jobID == id {
                    self.job = nil
                    self.jobID = nil
                    self.generating = false
                    self.reloadReports()
                }
            }
            do {
                let output = try await ReportGenerator(store: store, client: .init(executable: executable))
                    .generate(period: report.period, language: lang, after: cutoff, includeFiles: includeFiles)
                try Task.checkCancellation()
                try store.save(output, for: report.period)
                self?.statusMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                let retry = Date().addingTimeInterval(5 * 60)
                try? store.fail(report.period, retry: retry)
                self?.nextCodexAttempt = retry
                self?.statusMessage = error.localizedDescription
            }
        }
    }
}
