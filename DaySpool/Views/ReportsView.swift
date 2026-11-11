import SwiftUI
import UniformTypeIdentifiers

struct ReportsView: View {
    let model: DaySpoolModel
    let kind: ReportKind
    @Binding var selectedID: String?
    @State private var showingExport = false
    @State private var document = MarkdownDocument()
    @State private var fileName = "DaySpool"
    @State private var exportError: String?
    @State private var evidence: JournalEvent?

    var body: some View {
        let reports = model.reportList.filter { $0.period.kind == kind }
        let selected = reports.first { $0.id == selectedID }
        VStack(spacing: 0) {
            if reports.isEmpty {
                ContentUnavailableView("No \(kind.title.lowercased()) reports yet", systemImage: "doc.text",
                                       description: Text("A report is queued when a period with recorded activity ends."))
            } else {
                HSplitView {
                    List(reports, selection: $selectedID) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.period.label)
                            if report.state != .ready {
                                Text(report.state == .failed ? "Needs retry" : "Queued")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(report.id)
                    }
                    .frame(minWidth: 170, idealWidth: 215)
                    if let selected {
                        reportDetail(selected)
                            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Select a report", systemImage: "doc.text.magnifyingglass")
                            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if !model.codexEnabled {
                HStack {
                    Text("Enable Codex CLI in Settings to generate reports.")
                    Spacer()
                    SettingsLink { Text("Open Settings") }
                }
                .padding(10)
                .background(.regularMaterial)
            }
        }
        .navigationTitle("\(kind.title) Reports")
        .onChange(of: kind, initial: true) {
            if !reports.contains(where: { $0.id == selectedID }) { selectedID = reports.first?.id }
        }
        .onChange(of: reports.first?.id) {
            if selectedID == nil { selectedID = reports.first?.id }
        }
        .sheet(item: $evidence) { event in
            VStack(spacing: 0) {
                HStack { Text("Source Record").font(.headline); Spacer(); Button("Done") { evidence = nil } }
                    .padding(15)
                Divider()
                EventDetail(event: event)
            }
            .frame(width: 530, height: 360)
        }
        .fileExporter(isPresented: $showingExport, document: document, contentType: MarkdownDocument.contentType,
                      defaultFilename: fileName) { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn’t export report", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
    }

    @ViewBuilder
    private func reportDetail(_ report: StoredReport) -> some View {
        if let content = report.content {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(report.period.label).font(.title2.weight(.semibold))
                        Spacer()
                        Button("Export Markdown…") {
                            document = MarkdownDocument(text: content.markdown(for: report.period))
                            fileName = "DaySpool-\(report.period.kind.rawValue)-\(Int(report.period.start.timeIntervalSince1970))"
                            showingExport = true
                        }
                    }
                    if content.items.isEmpty { Text("No supported updates for this period.").foregroundStyle(.secondary) }
                    ForEach(Array(content.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.status.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(verbatim: item.project).font(.headline)
                            Text(verbatim: item.update).textSelection(.enabled)
                            ForEach(model.evidence(item.evidenceIDs)) { source in
                                Button {
                                    evidence = source
                                } label: {
                                    Label("\(source.appName) · \(source.start.formatted(date: .abbreviated, time: .shortened))",
                                          systemImage: "link")
                                    .lineLimit(1)
                                }
                                .buttonStyle(.link)
                            }
                        }
                        Divider()
                    }
                }.padding(20)
            }
        } else {
            VStack(spacing: 10) {
                ContentUnavailableView(report.state == .failed ? "Report needs retry" : "Report queued",
                                       systemImage: "hourglass",
                                       description: Text(model.statusMessage ??
                                         "Reports generate after the earlier summaries are ready."))
                if model.codexEnabled {
                    Button(model.generating ? "Generating…" : report.period.isManual ? "Generate Last Hour Again" : "Retry Reports") {
                        if report.period.isManual { model.generateLastHour() } else { model.retryReports() }
                    }
                        .disabled(model.generating)
                }
            }
        }
    }
}

struct MarkdownDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "md") ?? .plainText
    static let readableContentTypes = [contentType]
    var text: String

    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
