import SwiftUI

@main
struct NeiroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The status item is pure AppKit (StatusItemController): MenuBarExtra's
    // label snapshots custom views once, so neither the Core Animation
    // marquee nor dynamic width survive there. This scene is never shown.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        appState = state
        statusItemController = StatusItemController(appState: state)
    }

    // Destroying the tap un-mutes Music.app; without this, quitting neiro
    // mid-session leaves Music silenced until it relaunches.
    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdownForTermination()
    }
}
