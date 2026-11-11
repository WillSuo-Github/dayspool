import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @Bindable var model: DaySpoolModel
    @State private var confirmingClear = false

    var body: some View {
        TabView {
            capture.tabItem { Label("Capture", systemImage: "record.circle") }
            reports.tabItem { Label("Reports", systemImage: "sparkles") }
            data.tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .padding(12)
        .frame(width: 620, height: 510)
    }

    private var capture: some View {
        Form {
            Section("Content") {
                Toggle("Record text edits", isOn: $model.textEnabled)
                Toggle("Read text from window screenshots", isOn: $model.ocrEnabled)
                LabeledContent(AccessibilityReader.permissionName, value: model.accessibilityGranted ? "Granted" : "Required for text and OCR")
                if !model.accessibilityGranted {
                    Button("Grant Text Access…", action: model.requestAccessibility)
                }
                if model.ocrEnabled {
                    LabeledContent("Screen Recording", value: model.screenGranted ? "Granted" : "Not granted")
                    if !model.screenGranted {
                        Button("Grant Screen Recording…", action: model.requestScreenRecording)
                    }
                }
            }
            Section("File Activity") {
                Toggle("Record and summarize file changes", isOn: Binding(
                    get: { model.filesEnabled }, set: model.setFileActivityEnabled
                ))
                Text("Records changes on the internal disk where macOS allows access. When Codex reports are enabled, selected file and folder names, times, and change types recorded after turning this on can be sent to Codex. File Activity does not send full paths or read file contents.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Excluded from app and screen recording") {
                appRows(model.excludedApps) { model.excludedApps.remove($0) }
                Button("Exclude App…", action: excludeApp)
                Text("Recording covers supported apps by default. Password fields and known credential apps are skipped. Private windows can’t always be identified; exclude the browser or pause to keep that activity out of the journal.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.textEnabled) { model.applyCaptureSettings() }
        .onChange(of: model.ocrEnabled) { model.applyCaptureSettings() }
        .onChange(of: model.excludedApps) { model.applyCaptureSettings() }
        .onAppear(perform: model.refreshPermissions)
    }

    private var reports: some View {
        Form {
            Section("Codex CLI") {
                LabeledContent("Executable") {
                    Text(model.codexExecutable?.path ?? "Not found").lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Executable…", action: chooseCodex)
                    if !model.codexPath.isEmpty {
                        Button("Use Detected Codex") { model.selectCodex(at: "") }
                    }
                }
                Toggle("Generate reports with Codex", isOn: Binding(
                    get: { model.codexEnabled }, set: model.setCodexEnabled
                )).disabled(model.codexExecutable == nil && !model.codexEnabled)
                Text("Automatic reports start with activity recorded after you enable this. Reports send selected app activity, window titles, text edits, and OCR excerpts to the Codex model service. Screenshots and the journal database stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("DaySpool uses your existing Codex CLI login. If you haven’t signed in, run codex login in Terminal.")
                    .font(.callout).foregroundStyle(.secondary)
                if let message = model.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Reports") {
                Picker("Language", selection: $model.reportLanguage) {
                    ForEach(["Auto", "English", "Simplified Chinese", "Traditional Chinese"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Button("Retry Pending Reports", action: model.retryReports)
                    .disabled(!model.codexEnabled || model.generating)
                Button("Generate Last Hour Now", action: model.generateLastHour)
                    .disabled(!model.codexEnabled || model.generating)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.reportLanguage) { model.saveReportSettings() }
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.directoryURL = model.codexExecutable?.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.selectCodex(at: url.path)
        }
    }

    private var data: some View {
        Form {
            Section("Local journal") {
                Text("Activity, text edits, OCR, file activity, and reports are stored on this Mac. Screenshots used for OCR are kept only in memory.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete All Records…", role: .destructive) { confirmingClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete your DaySpool journal?", isPresented: $confirmingClear) {
            Button("Delete All and Pause", role: .destructive, action: model.clearJournal)
        } message: {
            Text("Activity, text edits, OCR, file activity, and generated reports will be removed. Markdown files you exported are kept.")
        }
    }

    private func appRows(_ ids: Set<String>, remove: @escaping (String) -> Void) -> some View {
        ForEach(ids.sorted(), id: \.self) { id in
            HStack {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Text(FileManager.default.displayName(atPath: url.path))
                        .help(id)
                } else {
                    Text(id)
                }
                Spacer()
                Button(role: .destructive) { remove(id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(id)")
            }
        }
    }

    private func excludeApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Exclude"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            model.excludedApps.insert(id)
        }
    }
}
