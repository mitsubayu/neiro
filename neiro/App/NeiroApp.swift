import SwiftUI

@main
struct NeiroApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        } label: {
            // AppKit-backed so the marquee runs as a Core Animation loop on
            // the render server — no SwiftUI re-render per frame (animating
            // the label with TimelineView pinned the main thread).
            MarqueeLabel(title: appState.status == .running ? (appState.nowPlayingTitle ?? "") : "",
                         suffix: appState.status == .running ? appState.menuBarSuffix : "")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    // Destroying the tap un-mutes Music.app; without this, quitting neiro
    // mid-session leaves Music silenced until it relaunches.
    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdownForTermination()
    }
}
