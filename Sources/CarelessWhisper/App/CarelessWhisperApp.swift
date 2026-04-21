import AppKit
import os

private let appLogger = Logger(subsystem: "com.carelesswhisper", category: "AppDelegate")

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
        terminateOtherInstances()

        statusBarController.setup(appState: appState)

        Task { @MainActor in
            await appState.setup()
            if appState.agentOverlayEnabled {
                appState.startOverlayServer()
                AgentSkillInstaller.installIfNeeded()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if appState.overlayServer.isRunning {
            appState.overlayServer.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func terminateOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for app in others {
            appLogger.info("Terminating stale instance pid=\(app.processIdentifier, privacy: .public) at \(app.bundleURL?.path ?? "unknown", privacy: .public)")
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }
}
