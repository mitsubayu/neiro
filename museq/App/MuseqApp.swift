import SwiftUI

@main
struct MuseqApp: App {
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
                Text(appState.sampleRateLabel)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    // Destroying the tap un-mutes Music.app; without this, quitting museq
    // mid-session leaves Music silenced until it relaunches.
    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdownForTermination()
    }
}
