import Foundation

/// What to do about a detected source rate. Kept separate from AppState so the
/// rules — the part that broke most often during development — are pure and
/// testable instead of being tangled up with AppleScript round-trips and
/// engine lifecycle.
enum RateSwitchDecision: Equatable {
    /// Nothing pending; make sure a stale head-mute is lifted.
    case idle
    /// A switch is already running — re-check once it finishes.
    case waitForInFlightSwitch
    /// Rebuild at the new rate without touching playback. Used when the player
    /// is idle, and when the engine was built before the track's rate was
    /// known (app launch mid-track): playback continues where it is rather
    /// than restarting.
    case switchKeepingPosition
    /// Pause, rebuild, seek back to 0:00, resume — the track is at its head so
    /// the listener hears the intro exactly once, at the right rate.
    case switchRestartingTrack
    /// Not enough information locally; ask Music for its state and position.
    case queryPlayer
    /// This is Music pre-rolling the next item mid-track. Leave the current
    /// track alone and re-check later.
    case deferToTrackBoundary(milliseconds: Int)
}

struct RateSwitchContext {
    var detectedRate: Double?
    var engineRate: Double
    var isEnabled: Bool
    var followTrackRate: Bool
    var isEngineRunning: Bool
    var isSwitchInFlight: Bool
    /// playerInfo told us a track started moments ago and is playing.
    var isAtKnownTrackHead: Bool
    /// The running engine was built without knowing the track's source rate
    /// (launch or enable during playback), so correcting it now is expected.
    var engineBuiltWithoutTrackRate: Bool
}

enum RateSwitchPolicy {
    static let deferRetryMilliseconds = 2000
    /// Playback position under which a track counts as "at the head".
    static let headWindowSeconds: Double = 5

    static func decide(_ context: RateSwitchContext) -> RateSwitchDecision {
        guard let detected = context.detectedRate,
              context.isEnabled, context.followTrackRate,
              context.isEngineRunning,
              detected != context.engineRate else {
            return .idle
        }
        if context.isSwitchInFlight {
            return .waitForInFlightSwitch
        }
        if context.engineBuiltWithoutTrackRate {
            return .switchKeepingPosition
        }
        if context.isAtKnownTrackHead {
            return .switchRestartingTrack
        }
        return .queryPlayer
    }

    /// Second phase, once Music has answered. `playerState` is nil when Music
    /// could not be reached (AppleScript timeout).
    static func decideAfterQuery(playerState: String?, position: Double?) -> RateSwitchDecision {
        guard playerState == "playing" else {
            return .switchKeepingPosition
        }
        guard let position, position <= headWindowSeconds else {
            return .deferToTrackBoundary(milliseconds: deferRetryMilliseconds)
        }
        return .switchRestartingTrack
    }
}
