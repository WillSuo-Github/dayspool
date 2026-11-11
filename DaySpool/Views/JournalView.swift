import AppKit
import SwiftUI

struct JournalView: View {
    let model: DaySpoolModel
    @State private var selection: String? = "timeline"
    @State private var eventID: String?
    @State private var reportID: String?
    @State private var pendingDelete: JournalEvent?

    var body: some View {
        if !model.accepted {
            WelcomeView(model: model)
        } else {
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Library") {
                        Label("Timeline", systemImage: "list.bullet.rectangle").tag("timeline")
                        Label("File Activity", systemImage: "doc").tag("files")
                    }
                    Section("Reports") {
                        ForEach(ReportKind.allCases) { kind in
                            Label(kind.title, systemImage: kind == .hour ? "clock" : kind == .day ? "calendar" : "calendar.badge.clock")
                                .tag(kind.rawValue)
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 150, ideal: 165)
            } detail: {
                if let selection, let kind = ReportKind(rawValue: selection) {
                    ReportsView(model: model, kind: kind, selectedID: $reportID)
                } else {
                    timeline
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(action: model.togglePause) {
                        Label(model.isRecording ? "Pause Recording" : "Resume Recording",
                              systemImage: model.isRecording ? "pause.circle" : "play.circle")
                    }
                    .help(model.isRecording ? "Recording is enabled" : "Recording is paused")
                }
                ToolbarItem {
                    SettingsLink { Label("Settings", systemImage: "gear") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.captureError {
                    Label(error, systemImage: "exclamationmark.triangle").padding(10)
                        .frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .onChange(of: selection, initial: true) {
                model.journalKind = selection == "files" ? .file : nil
            }
            .confirmationDialog("Delete this record?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { event in
                Button("Delete and Pause Recording", role: .destructive) {
                    model.delete(event)
                    if eventID == event.id { eventID = nil }
                }
            } message: { event in
                Text(event.kind == .activity
                     ? "Text and OCR attached to this activity will also be deleted. Affected reports will be rebuilt."
                     : "Reports that used this record will be rebuilt.")
            }
        }
    }

    private var timeline: some View {
        let selected = model.journal.first { $0.id == eventID }
        return HSplitView {
            VStack(spacing: 0) {
                TextField(selection == "files" ? "Search file activity" : "Search recent activity",
                          text: Binding(get: { model.search }, set: { model.search = $0 }))
                    .textFieldStyle(.roundedBorder).padding(10)
                if model.journal.isEmpty {
                    ContentUnavailableView(model.search.isEmpty ? "No activity yet" : "No matches",
                                           systemImage: model.search.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                                           description: Text(model.search.isEmpty
                                             ? (selection == "files" ? "Enable File Activity in Capture settings to start monitoring." : "Switch to another app to start building your timeline.")
                                             : "Try an app name, title, or text fragment."))
                } else {
                    List(model.journal, selection: $eventID) { event in
                        HStack(alignment: .top) {
                            Image(systemName: event.kind.icon).foregroundStyle(.secondary).frame(width: 17)
                            VStack(alignment: .leading, spacing: 3) {
                                if let change = event.fileChange {
                                    Text(verbatim: change.name).lineLimit(1)
                                    Text(change.action.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                } else {
                                    Text(event.appName).lineLimit(1)
                                    Text(event.body.isEmpty ? (event.window.isEmpty ? event.kind.title : event.window) : event.body)
                                        .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(event.start, format: .dateTime.month().day().hour().minute())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .tag(event.id)
                        .contextMenu { Button("Delete Record", role: .destructive) { pendingDelete = event } }
                    }
                }
            }
            .frame(minWidth: 235, idealWidth: 320)
            if let selected {
                EventDetail(event: selected) { pendingDelete = selected }
                    .frame(minWidth: 255, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a record", systemImage: "text.magnifyingglass")
                    .frame(minWidth: 255, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(selection == "files" ? "File Activity" : "Timeline")
    }
}

struct EventDetail: View {
    let event: JournalEvent
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(event.kind.title, systemImage: event.kind.icon)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(verbatim: event.fileChange?.name ?? event.appName).font(.title2.weight(.semibold))
                Text(event.start.formatted(date: .long, time: .standard))
                    .font(.callout).foregroundStyle(.secondary)
                if !event.window.isEmpty { Text(verbatim: event.window).foregroundStyle(.secondary) }
                if event.kind == .activity {
                    Text("Duration: \(Duration.seconds(max(0, event.end.timeIntervalSince(event.start))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                }
                if let change = event.fileChange {
                    Text(change.action.title)
                    if change.notifications > 1 {
                        Text("\(change.notifications) filesystem notifications combined").foregroundStyle(.secondary)
                    }
                    if change.action == .incomplete {
                        Text("Some changes were not recorded during a burst of disk activity.")
                            .foregroundStyle(.secondary)
                    }
                    if let path = change.path, FileManager.default.fileExists(atPath: path) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                } else if !event.body.isEmpty {
                    Divider()
                    Text(verbatim: event.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let onDelete {
                    Button("Delete Record…", role: .destructive, action: onDelete)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
    }
}
