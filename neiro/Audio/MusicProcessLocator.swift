import AppKit
import CoreAudio

enum MusicProcessLocator {
    static let bundleID = "com.apple.Music"

    static func runningMusicApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Returns the Core Audio process object for Music.app, or nil when Music
    /// is not running or has not yet created an audio process (it only exists
    /// once Music initializes audio, which may lag app launch).
    static func musicProcessObjectID() -> AudioObjectID? {
        guard let app = runningMusicApp() else { return nil }
        var pid = app.processIdentifier
        var objectID = AudioObjectID.unknown
        do {
            try withUnsafeMutablePointer(to: &pid) { pidPtr in
                try AudioObjectID.system.read(kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              into: &objectID,
                                              qualifier: UnsafeMutableRawPointer(pidPtr),
                                              qualifierSize: UInt32(MemoryLayout<pid_t>.size))
            }
        } catch {
            return nil
        }
        return objectID.isValid ? objectID : nil
    }
}
