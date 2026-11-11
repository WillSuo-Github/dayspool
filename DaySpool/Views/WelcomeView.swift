import SwiftUI

struct WelcomeView: View {
    let model: DaySpoolModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("DaySpool", systemImage: "clock.arrow.circlepath")
                .font(.largeTitle.weight(.semibold))
            Text("Your day, ready to revisit.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Label("Keep a local timeline of the apps you use.", systemImage: "rectangle.on.rectangle")
                Label("Text edits are on by default in supported apps. macOS calls the required permission \(AccessibilityReader.permissionName).", systemImage: "character.cursor.ibeam")
                Label("Window OCR is optional. Exclude individual apps in Settings.", systemImage: "text.viewfinder")
                Label("You can opt in to report generation with Codex CLI.", systemImage: "sparkles")
            }
            Text("You can pause from the menu bar at any time.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.captureError {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Start Recording") { model.acceptCapture() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Review Settings") { openSettings() }
                if !model.accessibilityGranted, model.textEnabled {
                    Button("Grant Text Access") { model.requestAccessibility() }
                }
            }
        }
        .padding(36)
        .frame(maxWidth: 625, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
