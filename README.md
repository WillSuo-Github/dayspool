# DaySpool

**Your day, ready to revisit.**

DaySpool is an open-source macOS journal for your computer activity. It records a local timeline and turns it into hourly, daily, and weekly reports you can trace back to their sources.

## Run the developer build

Requires macOS 15 or later and Xcode with a macOS SDK. Open `DaySpool.xcodeproj` in Xcode, or run:

```sh
./script/build_and_run.sh
./script/build_and_run.sh --test
```

The checked-in project is generated from `project.yml`. After adding or removing source files, run `xcodegen generate`. The default source build uses an ad hoc signature.

To keep macOS privacy permissions across development builds, copy `Config/LocalDevelopment.example.xcconfig` to `Config/LocalDevelopment.xcconfig`, then enter the Team ID for an Apple Development identity already installed in your keychain. Xcode and the Run script use it for Debug builds. The local file is ignored by Git. If you switch from ad hoc signing, grant permissions once for the new identity.

## What it records

- **App activity:** foreground app and time. DaySpool pauses on inactivity, sleep, or session lock. With Accessibility permission, it can also show the focused window title.
- **Text edits:** enabled by default across supported apps after onboarding and macOS Accessibility permission. DaySpool records observed changes to a focused text area. It can include typed text, paste, or automatic edits; it does not record global keystrokes. A field can be skipped if the app does not expose a usable accessibility value. Compatibility varies by app.
- **Window OCR:** opt in under **Settings → Capture** and grant Screen Recording permission. Only the focused window is sampled. Screenshots are processed in memory and only recognized text is saved.
- **File activity:** turn on **Record and summarize file changes** under **Settings → Capture**. DaySpool listens to changes across the internal disk where macOS allows access, including folders outside Desktop, Documents, and Downloads. It records paths and change metadata, without reading or copying file contents. The **File Activity** sidebar filters the timeline and lets you reveal existing files in Finder.
- **Controls:** pause from the menu bar, exclude apps from all recording, and delete records or the entire journal. Deleting a record also invalidates reports derived from that period.

Password fields and known credential apps are excluded. macOS does not always identify private browser windows or other sensitive contexts through accessibility; use app exclusions or pause for those sessions. App data lives in `~/Library/Application Support/DaySpool`. Files you export are independent copies.

On macOS 27 and later, the Accessibility permission is labeled **Device Control and Data Access** in **System Settings → Privacy & Security**. If a rebuilt ad hoc development copy still reports missing access with its switch enabled, remove the stale DaySpool entry and add the current bundle again.

## File monitoring behavior

The monitor starts from the moment you turn it on. It does not scan the disk or import a backlog. It skips common cache and temporary paths, app data, external volumes, and its own writes. It also stops while paused, locked, or asleep; changes during those periods are not replayed. Sync and other background processes can produce file events. A rename notification does not reliably identify both paths.

Repeated saves are combined before writing. Large folders become a single batch, and an incomplete-activity entry marks dropped events instead of triggering a full disk scan. The event stream and batch reducer run on a background queue.

## Reports with Codex CLI

1. Install [Codex CLI](https://developers.openai.com/codex/cli/) and sign in with `codex login` if needed.
2. In **DaySpool → Settings → Reports**, confirm the executable path (or choose it manually) and turn on **Generate reports with Codex**.
3. Leave DaySpool running in the menu bar. Automatic reports cover activity recorded after you turn reports on. To review an existing hour immediately, choose **Generate Last Hour Now**. Hours summarize events, days summarize hours, and ISO weeks (Monday–Sunday) summarize days. Unavailable inference does not interrupt recording.
4. Open a report to review its sources or export Markdown.

DaySpool invokes your installed CLI with its saved sign-in, using the CLI's default model configuration without loading personal agent settings. When enabled, selected excerpts of app activity, window titles, text edits, and OCR go to the Codex model service. Screenshots and the journal database stay on your Mac. The **Record and summarize file changes** switch controls both file collection and use in reports. When it and Codex reports are both on, selected file or folder names, change types, and times from after you enabled it may be sent to Codex. The file activity collector does not send full paths or file contents. An older local-only opt-in does not turn on the combined setting. DaySpool runs one report at a time, with an ephemeral Codex session, no approval prompts, and shell, web search, hooks, plugins, and apps disabled.

For a quick manual check, enable recording, type a short Chinese and English sentence into a new TextEdit document, wait a few seconds, then switch back to DaySpool and look for a **Text edit** record. Turn on OCR and repeat with Screen Recording permission to check **Screen text**. With both permissions denied, app activity should still work.

MIT licensed.
