import Testing
@testable import neiro

/// The whole "should we switch, and how" decision, kept pure so it can be
/// tested without Core Audio or Music.
struct RateSwitchPolicyTests {
    private func context(detected: Double? = 96_000,
                         engine: Double = 44_100,
                         enabled: Bool = true,
                         follow: Bool = true,
                         running: Bool = true,
                         inFlight: Bool = false,
                         atHead: Bool = false,
                         builtBlind: Bool = false) -> RateSwitchContext {
        RateSwitchContext(detectedRate: detected, engineRate: engine, isEnabled: enabled,
                          followTrackRate: follow, isEngineRunning: running,
                          isSwitchInFlight: inFlight, isAtKnownTrackHead: atHead,
                          engineBuiltWithoutTrackRate: builtBlind)
    }

    @Test func policyIdlesWhenNothingToDo() {
        #expect(RateSwitchPolicy.decide(context(detected: nil)) == .idle)
        #expect(RateSwitchPolicy.decide(context(detected: 44_100, engine: 44_100)) == .idle)
        #expect(RateSwitchPolicy.decide(context(enabled: false)) == .idle)
        #expect(RateSwitchPolicy.decide(context(follow: false)) == .idle)
        #expect(RateSwitchPolicy.decide(context(running: false)) == .idle)
    }

    @Test func policyIdlesOnMatchingRatesEvenMidSwitch() {
        // Matching rates win over the in-flight check, which is why the caller
        // must not treat idle as "the switch is over" — the resume may still
        // be seeking, and a second seek replays the intro.
        #expect(RateSwitchPolicy.decide(
            context(detected: 96_000, engine: 96_000, inFlight: true)) == .idle)
    }

    @Test func policyWaitsWhileASwitchIsRunning() {
        #expect(RateSwitchPolicy.decide(context(inFlight: true)) == .waitForInFlightSwitch)
        // Even at a track head: never start a second switch on top of one.
        #expect(RateSwitchPolicy.decide(context(inFlight: true, atHead: true)) == .waitForInFlightSwitch)
    }

    @Test func policyCorrectsABlindlyBuiltEngineWithoutRestarting() {
        // Launched mid-track: fix the rate but keep playback where it is.
        #expect(RateSwitchPolicy.decide(context(builtBlind: true)) == .switchKeepingPosition)
        // A known head still wins nothing here — not restarting is safer.
        #expect(RateSwitchPolicy.decide(context(atHead: true, builtBlind: true)) == .switchKeepingPosition)
    }

    @Test func policyRestartsTrackAtKnownHead() {
        #expect(RateSwitchPolicy.decide(context(atHead: true)) == .switchRestartingTrack)
    }

    @Test func policyQueriesWhenHeadIsUnknown() {
        #expect(RateSwitchPolicy.decide(context()) == .queryPlayer)
    }

    @Test func policyAfterQueryFollowsPlayerPosition() {
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "playing", position: 1.2) == .switchRestartingTrack)
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "playing", position: 42) ==
                .deferToTrackBoundary(milliseconds: RateSwitchPolicy.deferRetryMilliseconds))
        // Paused/stopped/unreachable: no transport commands, just rebuild.
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: "paused", position: nil) == .switchKeepingPosition)
        #expect(RateSwitchPolicy.decideAfterQuery(playerState: nil, position: nil) == .switchKeepingPosition)
    }
}
