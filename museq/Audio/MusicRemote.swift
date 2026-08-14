import Foundation

/// Pause/resume Music.app via AppleScript (osascript). Requires the
/// NSAppleEventsUsageDescription automation permission on first use.
enum MusicRemote {
    static func pause() {
        run("tell application \"Music\" to pause")
    }

    static func play() {
        run("tell application \"Music\" to play")
    }

    private static func run(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
