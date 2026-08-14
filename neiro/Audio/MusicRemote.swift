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

    /// "playing", "paused", "stopped" — nil if Music is unreachable.
    static func playerState() -> String? {
        run("tell application \"Music\" to get player state")
    }

    /// Playback position in seconds within the current track.
    static func playerPosition() -> Double? {
        guard let output = run("tell application \"Music\" to get player position") else { return nil }
        return Double(output.replacingOccurrences(of: ",", with: "."))
    }

    static func setPosition(to seconds: Double) {
        run("tell application \"Music\" to set player position to \(seconds)")
    }

    /// osascript can block indefinitely — most notably while the Automation
    /// consent dialog is unanswered, or when Music stops servicing Apple
    /// Events. A hard timeout keeps the rate-switch pipeline from hanging;
    /// callers treat nil as "Music unreachable" and degrade gracefully.
    @discardableResult
    private static func run(_ script: String, timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
