import AppKit

@main
enum CarelessWhisperApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        // Must retain delegate — stored in a local, so we hold it here
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.setup(appState: appState)

        Task { @MainActor in
            await appState.setup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
