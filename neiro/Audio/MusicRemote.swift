import AppKit
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

    /// Title and artist of the current track, nil when nothing is loaded.
    static func nowPlaying() -> (title: String, artist: String)? {
        let script = """
        tell application "Music" to get (name of current track) & "\\n" & (artist of current track)
        """
        guard let output = run(script), !output.isEmpty else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard let title = lines.first, !title.isEmpty else { return nil }
        return (title, lines.count > 1 ? lines[1] : "")
    }

    /// Writes the current track's artwork (original bytes, usually JPEG/PNG)
    /// to `path`. Returns false when there is no track/artwork.
    @discardableResult
    static func saveArtwork(to path: String) -> Bool {
        let script = """
        tell application "Music"
        \tset artworkData to raw data of artwork 1 of current track
        end tell
        set outFile to open for access POSIX file "\(path)" with write permission
        set eof outFile to 0
        write artworkData to outFile
        close access outFile
        """
        return run(script, timeout: 5) != nil
    }

    /// osascript can block indefinitely — most notably while the Automation
    /// consent dialog is unanswered, or when Music stops servicing Apple
    /// Events. A hard timeout keeps the rate-switch pipeline from hanging;
    /// callers treat nil as "Music unreachable" and degrade gracefully.
    @discardableResult
    private static func run(_ script: String, timeout: TimeInterval = 3) -> String? {
        // AppleScript launches its target app when it isn't running — a
        // stray now-playing refresh after the user quits Music must not
        // resurrect it.
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: MusicProcessLocator.bundleID).isEmpty else { return nil }
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
