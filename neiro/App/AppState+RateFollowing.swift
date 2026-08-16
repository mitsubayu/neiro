import AppKit
import Foundation
import os

/// Following the track's own sample rate: what the log detector reports, when
/// that is worth a switch, and how to perform one without the listener losing
/// (or hearing twice) the start of the track.
///
/// Split out of AppState because it is the part with the most moving pieces —
/// a debounce, a head mute with a deadline, an in-flight switch with a
/// watchdog — and it is where every regression has come from.
@MainActor
extension AppState {
    func updateRateDetectorState() {
        if settings.isEnabled && settings.followTrackRate {
            rateDetector.start()
        } else {
            rateDetector.stop()
        }
    }

    /// playerInfo tells us a track just began (new title, or a transition into
    /// Playing) without any AppleScript round-trip. That timestamp is what lets
    /// the rate switch mute instantly instead of leaking a moment of audio.
    func noteTrackStart(title: String?, playerState: String?, at date: Date) {
        let isPlaying = playerState == "Playing"
        defer {
            lastNotifiedTitle = title
            isPlayingPerNotification = isPlaying
        }
        guard isPlaying else { return }
        if title != lastNotifiedTitle || !isPlayingPerNotification {
            trackStartedAt = date
            trackStartsSinceDetection += 1
            scheduleDetectorHealthCheck()
        }
    }

    /// A track just started, so the log stream owes us a format line. If none
    /// arrives the stream is alive but no longer delivering (logd restarted,
    /// child wedged) — restart it, which also re-reads the recent log and
    /// recovers the current track's rate.
    private func scheduleDetectorHealthCheck() {
        guard settings.isEnabled, settings.followTrackRate else { return }
        detectorHealthTask?.cancel()
        detectorHealthTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            // Not every track start logs a format line (a gapless
            // same-format continuation reuses the queue), so one silent start
            // proves nothing. Two in a row with no line at all does.
            guard self.trackStartsSinceDetection >= 2 else { return }
            if let last = self.lastDetectionAt, Date().timeIntervalSince(last) < 60 { return }
            if let restarted = self.lastDetectorRestartAt,
               Date().timeIntervalSince(restarted) < 60 { return }
            Self.logger.error("no format detected 8s after a track start — restarting the detector")
            self.lastDetectorRestartAt = Date()
            self.rateDetector.restart()
        }
    }

    /// True while we can be certain, without asking Music, that playback is at
    /// the head of a freshly started track.
    private var isAtKnownTrackHead: Bool {
        guard isPlayingPerNotification, let startedAt = trackStartedAt else { return false }
        return Date().timeIntervalSince(startedAt) <= Self.trackHeadWindow
    }

    /// Music logs the source rate when it builds a track's AudioQueue. Around
    /// track transitions it can build several queues at *different* rates
    /// within a couple of seconds (pre-rolling the next item), so detections
    /// are debounced: we act on the last rate that stays stable for 1.2s.
    func handleDetectedTrackRate(_ rate: Double) {
        lastTrackRate = rate
        lastDetectionAt = Date()
        trackStartsSinceDetection = 0
        Self.logger.info("detected track rate \(rate)")
        muteHeadIfSwitchPending()
        scheduleRateSwitchEvaluation()
    }

    /// A switch is coming: silence our output right away so the track head
    /// isn't heard at the wrong rate (it will be replayed from 0:00 after the
    /// switch — without this the listener hears the intro twice). Only mutes
    /// near the track head; mid-track detections are next-item pre-rolls and
    /// the current track must keep playing.
    private func muteHeadIfSwitchPending() {
        guard let rate = lastTrackRate, rate != engineSampleRate,
              status == .running, settings.followTrackRate,
              !isSwitchingRate else { return }
        // Fast path: playerInfo already told us a track just started, so mute
        // now. Waiting for the two AppleScript round-trips below let a moment
        // of audio through at the wrong rate before the switch — that audible
        // blip is exactly the "plays briefly, then stops" symptom.
        if isAtKnownTrackHead {
            Self.logger.info("muting head immediately (track start known) pending switch to \(rate)")
            armHeadMute()
            return
        }
        guard !muteCheckInFlight else { return }
        muteCheckInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.muteCheckInFlight = false }
            guard let self else { return }
            let state = await Task.detached { MusicRemote.playerState() }.value
            guard state == "playing" else { return }
            let position = await Task.detached { MusicRemote.playerPosition() }.value ?? .infinity
            if position <= 5, self.lastTrackRate != self.engineSampleRate, !self.isSwitchingRate {
                Self.logger.info("muting head at \(position)s pending rate switch")
                self.armHeadMute()
            }
        }
    }

    private func scheduleRateSwitchEvaluation(afterMilliseconds delay: Int = 1200) {
        let now = Date()
        if pendingEvaluationSince == nil { pendingEvaluationSince = now }
        // A track change that crosses codecs (ALAC → AAC) makes Music log both
        // formats for several seconds. Detections then arrive faster than the
        // debounce window and, without this ceiling, keep pushing the
        // evaluation back forever — the head mute never lifts and playback
        // goes silent.
        var effectiveDelay = delay
        if let since = pendingEvaluationSince,
           now.timeIntervalSince(since) >= Self.maxDebounceWait {
            effectiveDelay = 0
        }
        pendingRateTask?.cancel()
        pendingRateTask = Task { @MainActor [weak self] in
            if effectiveDelay > 0 {
                try? await Task.sleep(for: .milliseconds(effectiveDelay))
            }
            guard !Task.isCancelled else { return }
            self?.evaluateRateSwitch()
        }
    }

    /// Mutes for an upcoming switch with a hard deadline, so no failure path
    /// can leave the output silent.
    private func armHeadMute() {
        headMuteApplied = true
        processor.setMuted(true)
        guard muteDeadlineTask == nil else { return }
        muteDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.muteDeadline))
            guard !Task.isCancelled, let self else { return }
            self.muteDeadlineTask = nil
            guard !self.isSwitchingRate else { return }   // the switch owns it now
            Self.logger.error("head mute expired without a switch — unmuting")
            self.processor.setMuted(false)
        }
    }

    /// The controlled switch, tuned to never chop audio the listener cares
    /// about:
    /// - Music idle/paused → retarget silently, no transport commands.
    /// - Near the track head (≤5s) → pause, rebuild at the new rate, seek back
    ///   to 0:00 and resume, so the track restarts cleanly instead of losing
    ///   its head (the user's complaint with LosslessSwitcher-style behavior).
    /// - Mid-track (>5s) → this is Music pre-rolling the *next* item at a
    ///   different rate; defer and re-check until the boundary passes.
    private var rateSwitchContext: RateSwitchContext {
        RateSwitchContext(detectedRate: lastTrackRate,
                          engineRate: engineSampleRate,
                          isEnabled: settings.isEnabled,
                          followTrackRate: settings.followTrackRate,
                          isEngineRunning: status == .running,
                          isSwitchInFlight: isSwitchingRate,
                          isAtKnownTrackHead: isAtKnownTrackHead,
                          engineBuiltWithoutTrackRate: engineBuiltWithoutTrackRate)
    }

    private func evaluateRateSwitch() {
        pendingEvaluationSince = nil
        let decision = RateSwitchPolicy.decide(rateSwitchContext)
        Self.logger.info("evaluate: track=\(self.lastTrackRate ?? 0) engine=\(self.engineSampleRate) → \(String(describing: decision), privacy: .public)")
        switch decision {
        case .idle:
            // The policy reports idle as soon as the rates match, which also
            // happens in the tail of a *successful* switch while its resume is
            // still seeking and playing. That switch owns the mute, the
            // watchdog and the rewind — stepping in here would seek a second
            // time and the intro would be heard twice.
            guard !isSwitchingRate else {
                engineBuiltWithoutTrackRate = false
                return
            }
            // Otherwise no switch was needed after all (e.g. the rate flapped
            // back). If we had already muted the intro for a switch that never
            // came, the listener lost those seconds — play them back.
            let recoverIntro = headMuteApplied && isAtKnownTrackHead
            endSwitching()
            if recoverIntro {
                Self.logger.info("head was muted but no switch followed — restarting the track")
                Task.detached { MusicRemote.setPosition(to: 0) }
            }
            // The engine's rate is confirmed against a real detection now, so
            // it no longer counts as built blind.
            engineBuiltWithoutTrackRate = false
        case .waitForInFlightSwitch:
            scheduleRateSwitchEvaluation()
        case .deferToTrackBoundary(let milliseconds):
            endSwitching()
            scheduleRateSwitchEvaluation(afterMilliseconds: milliseconds)
        case .switchKeepingPosition:
            beginSwitching()
            performSwitch(restartingTrack: false)
        case .switchRestartingTrack:
            beginSwitching()
            Task { @MainActor [weak self] in
                await Task.detached { MusicRemote.pause() }.value
                self?.performSwitch(restartingTrack: true)
            }
        case .queryPlayer:
            beginSwitching()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = await Task.detached { MusicRemote.playerState() }.value
                let position = state == "playing"
                    ? await Task.detached { MusicRemote.playerPosition() }.value
                    : nil
                let followUp = RateSwitchPolicy.decideAfterQuery(playerState: state, position: position)
                Self.logger.info("after query: state=\(state ?? "unreachable") position=\(position ?? -1) → \(String(describing: followUp), privacy: .public)")
                switch followUp {
                case .switchRestartingTrack:
                    await Task.detached { MusicRemote.pause() }.value
                    self.performSwitch(restartingTrack: true)
                case .deferToTrackBoundary(let milliseconds):
                    self.endSwitching()
                    self.scheduleRateSwitchEvaluation(afterMilliseconds: milliseconds)
                default:
                    self.performSwitch(restartingTrack: false)
                }
            }
        }
    }

    /// Rebuilds the engine at the detected rate. `restartingTrack` means we
    /// paused first and must seek back to 0:00 and resume.
    private func performSwitch(restartingTrack: Bool) {
        switchTargetRate = lastTrackRate
        Self.logger.info("switching engine \(self.engineSampleRate) -> \(self.lastTrackRate ?? 0) (restart=\(restartingTrack))")
        if !restartingTrack {
            // Nothing pauses playback on this path, so silence our output for
            // the rebuild instead of letting the old rate leak through.
            processor.setMuted(true)
        }
        engineBuiltWithoutTrackRate = false
        // When playback isn't touched there is no resume closure, so the
        // engine-ready callback is where that path ends.
        var onReady: (@MainActor () -> Void)?
        if !restartingTrack {
            onReady = { [weak self] in
                self?.endSwitching()
            }
        }
        startEngine(resumePlaybackAfterStart: restartingTrack,
                    restartTrackFromHead: restartingTrack,
                    expectedTrackTitle: restartingTrack ? nowPlayingTitle : nil,
                    onEngineReady: onReady)
    }

    /// Marks the switch in progress with a failsafe: if anything in the
    /// pause→rebuild→resume chain dies without finishing, every later
    /// evaluation would silently reschedule forever.
    private func beginSwitching() {
        isSwitchingRate = true
        switchWatchdogTask?.cancel()
        switchWatchdogTask = Task { @MainActor [weak self] in
            // Generous: AppleScript round-trips against a busy Music can take
            // seconds each, and a switch that is merely slow must not be
            // mistaken for a stuck one.
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isSwitchingRate else { return }
            Self.logger.error("switch watchdog fired: clearing stuck switch")
            self.endSwitching()
            self.scheduleRateSwitchEvaluation()
        }
    }

    /// Single exit point for a switch: unmute, drop the pending-target text,
    /// and stand the watchdog down.
    func endSwitching() {
        muteDeadlineTask?.cancel()
        muteDeadlineTask = nil
        headMuteApplied = false
        processor.setMuted(false)
        isSwitchingRate = false
        switchTargetRate = nil
        switchWatchdogTask?.cancel()
        switchWatchdogTask = nil
    }

    func stopEngine() {
        musicWaitTask?.cancel()
        pendingRateTask?.cancel()
        processor.setMuted(false)
        activeOutputUID = nil
        let engine = self.engine
        engine.controlQueue.async { engine.stop() }
        status = .disabled
    }

}
