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
            Image(systemName: "slider.horizontal.3")
            if appState.status == .running {
                if let title = appState.nowPlayingTitle, !title.isEmpty {
                    MarqueeText(text: title, anchor: appState.titleChangedAt)
                    Text("· \(appState.menuBarSuffix)")
                } else {
                    Text(appState.menuBarSuffix)
                }
            }
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
