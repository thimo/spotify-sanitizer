import SwiftUI
import AppKit

// A plain SwiftUI executable (no Xcode/.app bundle) needs a nudge to show a
// real window and a dock icon when launched via `swift run`: become a regular
// foreground app and activate.
@main
struct SpotifySanitizerApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Spotify Sanitizer") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 980, height: 700)
    }
}
