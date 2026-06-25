import SwiftUI
import AppKit

// A plain SwiftUI executable (no Xcode/.app bundle) needs a nudge to show a
// real window and a dock icon when launched via `swift run`: become a regular
// foreground app and activate.
@main
struct SpotifySanitizerApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Spotify Sanitizer") {
            ContentView()
        }
        .defaultSize(width: 900, height: 640)
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Spotify Sanitizer")
                .font(.largeTitle.bold())
            Text("Scaffold OK — engine port next.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
