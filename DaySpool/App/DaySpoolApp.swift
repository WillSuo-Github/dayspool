import AppKit
import SwiftUI

@main
struct DaySpoolApp: App {
    @NSApplicationDelegateAdaptor(DaySpoolDelegate.self) private var delegate
    @State private var model = DaySpoolModel()

    var body: some Scene {
        WindowGroup("DaySpool", id: "journal") {
            JournalView(model: model)
                .frame(minWidth: 760, minHeight: 490)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 960, height: 630)

        MenuBarExtra {
            JournalMenu(model: model)
        } label: {
            Label(model.isRecording ? "DaySpool recording" : "DaySpool",
                  systemImage: model.isRecording ? "record.circle" : "circle.dashed")
        }

        Settings {
            PreferencesView(model: model)
        }
    }
}

@MainActor
final class DaySpoolDelegate: NSObject, NSApplicationDelegate {
    weak var model: DaySpoolModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.pauseForTermination()
    }
}

struct JournalMenu: View {
    let model: DaySpoolModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(!model.accepted ? "Setup required" : model.isRecording ? "Recording enabled" : "Recording paused")
        Button("Open DaySpool") {
            openWindow(id: "journal")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.accepted {
            Button(model.isRecording ? "Pause recording" : "Resume recording") { model.togglePause() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit DaySpool") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
