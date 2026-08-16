import AppKit
import Foundation
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class AppState {
    enum EngineStatus: Equatable {
        case disabled
        case waitingForMusic
        case running
        case error(String)

        var label: String {
            switch self {
            case .disabled: "Off"
            case .waitingForMusic: "Waiting for Music.app…"
            case .running: "Running"
            case .error(let message): "Error: \(message)"
            }
        }
    }

    var settings: EQSettings {
        didSet { handleSettingsChange(oldValue: oldValue) }
    }
    private(set) var status: EngineStatus = .disabled
    private(set) var engineSampleRate: Double = 44_100
    private(set) var trackBitDepth: Int?
    private(set) var trackCodec: String?
    private(set) var userPresets: [EQPreset] = PresetStore.load()
    private(set) var activePresetName: String?
    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingArtist: String?
    private(set) var nowPlayingArtwork: NSImage?

    /// Codec + format suffix for the menu bar ("ALAC 96kHz/24bit"), or the
    /// pending target while a rate switch is in flight. The scrolling title
    /// itself is rendered by StatusMarqueeView.
    var menuBarSuffix: String {
        if let target = switchTargetRate {
            return "→ \(Self.rateLabel(target))"
        }
        return (trackCodec.map { "\($0) " } ?? "") + formatLabel
    }

    static func rateLabel(_ rate: Double) -> String {
        let kilohertz = rate / 1000
        return kilohertz == kilohertz.rounded()
            ? String(format: "%.0fkHz", kilohertz)
            : String(format: "%.1fkHz", kilohertz)
    }

    /// "96kHz/24bit" (bit depth omitted for float/unknown sources) — shown in
    /// the menu bar next to the icon and in the status row.
    var formatLabel: String {
        let rateText = Self.rateLabel(engineSampleRate)
        if let depth = trackBitDepth {
            return "\(rateText)/\(depth)bit"
        }
        return rateText
    }

    let deviceMonitor = OutputDeviceMonitor()

    @ObservationIgnored private let processor = EQProcessor()
    @ObservationIgnored private let engine: ProcessTapEngine
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var musicWaitTask: Task<Void, Never>?
    @ObservationIgnored private var activeOutputUID: String?
    @ObservationIgnored private let rateDetector = TrackRateDetector()
    @ObservationIgnored private var lastTrackRate: Double?
    @ObservationIgnored private var isSwitchingRate = false
    @ObservationIgnored private var pendingRateTask: Task<Void, Never>?
    @ObservationIgnored private var muteCheckInFlight = false
    /// Live audio for the spectrum display. The view drives its own refresh
    /// loop from this; nothing about it flows through observable state.
    var spectrumTap: SpectrumTap { engine.spectrumTap }

    /// Rate we are switching to while the change is in flight — surfaced in
    /// the UI so the silence during a switch is explained rather than
    /// mysterious.
    private(set) var switchTargetRate: Double?
    /// The running engine was built before we knew the playing track's source
    /// rate (launch or enable mid-playback), so a correction is expected and
    /// should not restart the track.
    @ObservationIgnored private var engineBuiltWithoutTrackRate = false
    @ObservationIgnored private var switchWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var trackStartedAt: Date?
    @ObservationIgnored private var lastNotifiedTitle: String?
    @ObservationIgnored private var isPlayingPerNotification = false
    @ObservationIgnored private var lastDetectionAt: Date?
    @ObservationIgnored private var pendingEvaluationSince: Date?
    @ObservationIgnored private var muteDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var trackStartsSinceDetection = 0
    /// Ceiling on how long detections may keep pushing the evaluation back.
    private static let maxDebounceWait: TimeInterval = 2.5
    /// A head mute must never outlive this without a switch taking over.
    private static let muteDeadline: TimeInterval = 4
    @ObservationIgnored private var detectorHealthTask: Task<Void, Never>?
    @ObservationIgnored private var lastDetectorRestartAt: Date?
    /// How long after a playerInfo track start we still treat playback as
    /// being at the head (covers unified-log delivery lag).
    private static let trackHeadWindow: TimeInterval = 6
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingObserver: NSObjectProtocol?
    private static let logger = Logger(subsystem: "com.mitsuba.neiro", category: "rate")

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        engine = ProcessTapEngine(processor: processor)
        processor.update(settings: loaded)

        engine.onSampleRateChange = { [weak self] rate in
            Task { @MainActor [weak self] in self?.engineSampleRate = rate }
        }

        deviceMonitor.onChange = { [weak self] in self?.handleDeviceListChange() }
        applyLaunchAtLogin()
        observeNowPlaying()
        activePresetName = matchingPresetName()
        rateDetector.onRateDetected = { [weak self] rate in self?.handleDetectedTrackRate(rate) }
        rateDetector.onCodecDetected = { [weak self] codec in
            self?.trackCodec = TrackRateDetector.codecDisplayName(codec)
        }
        rateDetector.onBitDepthDetected = { [weak self] rate, depth in
            guard let self else { return }
            self.trackBitDepth = depth
            // Some transitions log only decoder-output lines (no "Creating
            // AudioQueue"), so these must drive rate switching too.
            self.handleDetectedTrackRate(rate)
        }
        observeMusicLifecycle()
        updateRateDetectorState()

        if settings.isEnabled {
            startEngine()
        }
    }

    // MARK: - Settings flow

    private func handleSettingsChange(oldValue: EQSettings) {
        processor.update(settings: settings)
        scheduleSave()
        updateRateDetectorState()
        activePresetName = matchingPresetName()
        if oldValue.launchAtLogin != settings.launchAtLogin {
            applyLaunchAtLogin()
        }

        if oldValue.isEnabled != settings.isEnabled {
            settings.isEnabled ? startEngine() : stopEngine()
        } else if settings.isEnabled, oldValue.outputDeviceUID != settings.outputDeviceUID {
            startEngine()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [settings] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            SettingsStore.save(settings)
        }
    }

    // MARK: - Engine control

    /// nil UID means "follow the system default output".
    private func resolveOutputUID() -> String? {
        if let uid = settings.outputDeviceUID,
           deviceMonitor.devices.contains(where: { $0.uid == uid }) {
            return uid
        }
        return OutputDeviceMonitor.currentDefaultOutput()?.uid
    }

    /// `onEngineReady` runs on the main actor once the rebuild has finished
    /// (successfully or not). Switches that don't touch playback use it to
    /// release the in-flight flag exactly when the engine is up — a fixed
    /// delay guessed wrong and let a second switch start on top of the first.
    private func startEngine(resumePlaybackAfterStart: Bool = false,
                             restartTrackFromHead: Bool = false,
                             expectedTrackTitle: String? = nil,
                             onEngineReady: (@MainActor () -> Void)? = nil) {
        musicWaitTask?.cancel()

        // A switch sequence that can't reach its resume closure must release
        // the in-progress flag, or evaluations deadlock on it forever.
        func abandonSwitch() {
            onEngineReady?()
            if resumePlaybackAfterStart {
                endSwitching()
                MusicRemote.play()
            }
        }

        guard let musicProcess = MusicProcessLocator.musicProcessObjectID() else {
            abandonSwitch()
            status = .waitingForMusic
            waitForMusic()
            return
        }
        guard let outputUID = resolveOutputUID() else {
            abandonSwitch()
            status = .error("No output device available")
            return
        }

        if outputUID != activeOutputUID {
            applyPresetBinding(for: outputUID)
        }
        activeOutputUID = outputUID
        let preferredRate = settings.followTrackRate ? lastTrackRate : nil
        if !resumePlaybackAfterStart, preferredRate == nil {
            // Built blind: if the rate detector reports the playing track's
            // rate shortly after this, correcting it is expected.
            engineBuiltWithoutTrackRate = true
        }
        let engine = self.engine
        engine.controlQueue.async { [weak self] in
            do {
                try engine.start(musicProcess: musicProcess, outputDeviceUID: outputUID,
                                 preferredRate: preferredRate)
                let rate = engine.sampleRate
                Task { @MainActor [weak self] in
                    self?.status = .running
                    self?.engineSampleRate = rate
                    onEngineReady?()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.status = .error(error.localizedDescription)
                    self?.activeOutputUID = nil
                    onEngineReady?()
                }
            }
        }
        if resumePlaybackAfterStart {
            // Serial queue: runs after the start block above has finished.
            engine.controlQueue.async { [weak self] in
                usleep(150_000)
                // If the listener picked a different track while we were
                // rebuilding, seeking to 0:00 would yank playback away from
                // their choice — only rewind the track we actually paused.
                let currentTitle = MusicRemote.nowPlaying()?.title
                let sameTrack = expectedTrackTitle == nil || currentTitle == expectedTrackTitle
                if restartTrackFromHead, sameTrack {
                    MusicRemote.setPosition(to: 0)
                } else if !sameTrack {
                    Self.logger.info("track changed during the switch — leaving playback position alone")
                }
                // A resume that silently fails (osascript timing out while
                // Music is busy loading) leaves playback stopped for good, so
                // confirm it took and retry.
                var resumed = false
                for attempt in 1...3 {
                    MusicRemote.play()
                    // Music needs a beat to actually start after a seek;
                    // checking too eagerly just sends a redundant play.
                    usleep(500_000)
                    if MusicRemote.playerState() == "playing" {
                        resumed = true
                        break
                    }
                    Self.logger.error("resume attempt \(attempt) did not take effect")
                }
                if !resumed {
                    Self.logger.error("could not resume Music after rate switch")
                }
                Task { @MainActor [weak self] in
                    self?.endSwitching()
                }
            }
        }
    }

    // MARK: - Track-rate following

    private func updateRateDetectorState() {
        if settings.isEnabled && settings.followTrackRate {
            rateDetector.start()
        } else {
            rateDetector.stop()
        }
    }

    /// playerInfo tells us a track just began (new title, or a transition into
    /// Playing) without any AppleScript round-trip. That timestamp is what lets
    /// the rate switch mute instantly instead of leaking a moment of audio.
    private func noteTrackStart(title: String?, playerState: String?, at date: Date) {
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
    private func handleDetectedTrackRate(_ rate: Double) {
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
            // No switch needed after all (e.g. rate flapped back) — make sure
            // a head-mute from a premature detection doesn't stick.
            endSwitching()
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
    private func endSwitching() {
        muteDeadlineTask?.cancel()
        muteDeadlineTask = nil
        processor.setMuted(false)
        isSwitchingRate = false
        switchTargetRate = nil
        switchWatchdogTask?.cancel()
        switchWatchdogTask = nil
    }

    private func stopEngine() {
        musicWaitTask?.cancel()
        pendingRateTask?.cancel()
        processor.setMuted(false)
        activeOutputUID = nil
        let engine = self.engine
        engine.controlQueue.async { engine.stop() }
        status = .disabled
    }

    func shutdownForTermination() {
        engine.controlQueue.sync { [engine] in engine.stop() }
    }

    // MARK: - Music.app lifecycle

    private func observeMusicLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == MusicProcessLocator.bundleID else { return }
            Task { @MainActor [weak self] in
                guard let self, self.settings.isEnabled else { return }
                self.startEngine()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == MusicProcessLocator.bundleID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nowPlayingTitle = nil
                self.nowPlayingArtist = nil
                self.nowPlayingArtwork = nil
                self.trackCodec = nil
                self.trackBitDepth = nil
                guard self.settings.isEnabled else { return }
                let engine = self.engine
                engine.controlQueue.async { engine.stop() }
                self.status = .waitingForMusic
                self.waitForMusic()
            }
        })
    }

    /// Music's Core Audio process object can appear noticeably after the app
    /// itself launches, so poll while we're in the waiting state.
    private func waitForMusic() {
        musicWaitTask?.cancel()
        musicWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.settings.isEnabled, self.status == .waitingForMusic else { return }
                if MusicProcessLocator.musicProcessObjectID() != nil {
                    self.startEngine()
                    return
                }
            }
        }
    }

    // MARK: - Now playing

    /// Music broadcasts com.apple.Music.playerInfo on every play/pause/track
    /// change with title/artist in the payload; artwork needs an AppleScript
    /// round-trip, so refreshes are debounced.
    private func observeNowPlaying() {
        nowPlayingObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] note in
            let title = note.userInfo?["Name"] as? String
            let artist = note.userInfo?["Artist"] as? String
            let playerState = note.userInfo?["Player State"] as? String
            let observedAt = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.noteTrackStart(title: title, playerState: playerState, at: observedAt)
                self.nowPlayingTitle = title
                self.nowPlayingArtist = artist
                self.refreshNowPlaying(havePayloadTitle: title != nil)
            }
        }
        refreshNowPlaying(havePayloadTitle: false)
    }

    private func refreshNowPlaying(havePayloadTitle: Bool) {
        nowPlayingTask?.cancel()
        nowPlayingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            let artworkPath = NSTemporaryDirectory() + "neiro-artwork"
            let result = await Task.detached {
                let info = MusicRemote.nowPlaying()
                let hasArtwork = info != nil && MusicRemote.saveArtwork(to: artworkPath)
                return (info, hasArtwork)
            }.value
            guard !Task.isCancelled else { return }
            if let info = result.0 {
                self.nowPlayingTitle = info.title
                self.nowPlayingArtist = info.artist
            } else if !havePayloadTitle {
                self.nowPlayingTitle = nil
                self.nowPlayingArtist = nil
            }
            self.nowPlayingArtwork = result.1 ? NSImage(contentsOfFile: artworkPath) : nil
        }
    }

    // MARK: - Presets & login item

    func applyPreset(_ preset: EQPreset) {
        settings.bands = preset.bands
        settings.preGainDB = preset.preGainDB
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(EQPreset(name: trimmed, preGainDB: settings.preGainDB, bands: settings.bands))
        PresetStore.save(userPresets)
        activePresetName = matchingPresetName()
    }

    /// Overwrites the preset's contents with the current bands + pre-gain,
    /// keeping its name and identity.
    func updatePreset(_ preset: EQPreset) {
        guard let index = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        userPresets[index].bands = settings.bands
        userPresets[index].preGainDB = settings.preGainDB
        PresetStore.save(userPresets)
        activePresetName = matchingPresetName()
    }

    func deletePreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.id == preset.id }
        PresetStore.save(userPresets)
        activePresetName = matchingPresetName()
    }

    /// Name of the preset the current settings exactly equal, if any — the
    /// menu shows it until the user tweaks a band or the pre-gain.
    private func matchingPresetName() -> String? {
        (userPresets + BuiltInPresets.all)
            .first { $0.bands == settings.bands && $0.preGainDB == settings.preGainDB }?
            .name
    }

    /// Name of the device the current output resolves to, for menu labels.
    var currentOutputDeviceName: String? {
        guard let uid = resolveOutputUID() else { return nil }
        return deviceMonitor.devices.first { $0.uid == uid }?.name
    }

    var boundPresetNameForCurrentDevice: String? {
        guard let uid = resolveOutputUID() else { return nil }
        return settings.presetBindings[uid]
    }

    /// Remembers that the active preset belongs to whatever device is playing
    /// now — headphone correction is per device, so switching output should
    /// bring its own curve along.
    func bindActivePresetToCurrentDevice() {
        guard let uid = resolveOutputUID(), let name = activePresetName else { return }
        settings.presetBindings[uid] = name
    }

    func clearPresetBindingForCurrentDevice() {
        guard let uid = resolveOutputUID() else { return }
        settings.presetBindings.removeValue(forKey: uid)
    }

    private func applyPresetBinding(for deviceUID: String) {
        guard let name = settings.presetBindings[deviceUID], name != activePresetName,
              let preset = (userPresets + BuiltInPresets.all).first(where: { $0.name == name })
        else { return }
        Self.logger.info("applying preset bound to output device")
        applyPreset(preset)
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !settings.launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            Self.logger.warning("launch-at-login update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Device changes

    private func handleDeviceListChange() {
        guard settings.isEnabled, status == .running else { return }
        // Restart only when the resolved target actually differs from the
        // device the engine is using. Creating/destroying our own aggregate
        // fires this listener too — restarting unconditionally here put the
        // engine in a teardown/rebuild loop (audible as periodic dropouts).
        let desired = resolveOutputUID()
        guard desired != activeOutputUID else { return }
        startEngine()
    }
}
