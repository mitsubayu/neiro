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
    var status: EngineStatus = .disabled
    private(set) var engineSampleRate: Double = 44_100
    private(set) var trackBitDepth: Int?
    private(set) var trackCodec: String?
    private(set) var userPresets: [EQPreset] = PresetStore.load()
    /// Undo history for the EQ. Observable so the buttons enable themselves.
    private var history = EQHistory()
    @ObservationIgnored private var settledSnapshot: EQSnapshot
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingHistory = false

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
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

    /// Live audio for the spectrum display. The view drives its own refresh
    /// loop from this; nothing about it flows through observable state.
    var spectrumTap: SpectrumTap { engine.spectrumTap }


    @ObservationIgnored let processor = EQProcessor()
    @ObservationIgnored let engine: ProcessTapEngine
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var musicWaitTask: Task<Void, Never>?
    @ObservationIgnored var activeOutputUID: String?
    // MARK: Rate-following state
    //
    // Owned here but driven from AppState+RateFollowing.swift, which is why
    // these are internal rather than private — nothing outside those two files
    // should be reading or writing them.

    @ObservationIgnored let rateDetector = TrackRateDetector()
    @ObservationIgnored var lastTrackRate: Double?
    @ObservationIgnored var isSwitchingRate = false
    @ObservationIgnored var pendingRateTask: Task<Void, Never>?
    @ObservationIgnored var muteCheckInFlight = false
    /// Rate we are switching to while the change is in flight — surfaced in
    /// the UI so the silence during a switch is explained rather than
    /// mysterious.
    var switchTargetRate: Double?
    /// The running engine was built before we knew the playing track's source
    /// rate (launch or enable mid-playback), so a correction is expected and
    /// should not restart the track.
    @ObservationIgnored var engineBuiltWithoutTrackRate = false
    @ObservationIgnored var switchWatchdogTask: Task<Void, Never>?
    @ObservationIgnored var trackStartedAt: Date?
    @ObservationIgnored var lastNotifiedTitle: String?
    @ObservationIgnored var isPlayingPerNotification = false
    @ObservationIgnored var lastDetectionAt: Date?
    @ObservationIgnored var pendingEvaluationSince: Date?
    @ObservationIgnored var muteDeadlineTask: Task<Void, Never>?
    @ObservationIgnored var headMuteApplied = false
    @ObservationIgnored var trackStartsSinceDetection = 0
    /// Ceiling on how long detections may keep pushing the evaluation back.
    static let maxDebounceWait: TimeInterval = 2.5
    /// A head mute must never outlive this without a switch taking over.
    static let muteDeadline: TimeInterval = 4
    @ObservationIgnored var detectorHealthTask: Task<Void, Never>?
    @ObservationIgnored var lastDetectorRestartAt: Date?
    /// How long after a playerInfo track start we still treat playback as
    /// being at the head (covers unified-log delivery lag).
    static let trackHeadWindow: TimeInterval = 6

    // MARK: -

    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingObserver: NSObjectProtocol?
    /// Set by StatusItemController so the UI can dismiss its own panel.
    @ObservationIgnored var closePanelHandler: (() -> Void)?
    /// Set by StatusItemController: help lives in a real window, which only
    /// AppKit can own.
    @ObservationIgnored var showHelpHandler: (() -> Void)?
    static let logger = Logger(subsystem: "com.mitsuba.neiro", category: "rate")

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        settledSnapshot = EQSnapshot(loaded)
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
        recordHistory()
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
    func startEngine(resumePlaybackAfterStart: Bool = false,
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
                // Music is busy loading right after the rebuild and often lets
                // the query time out; a nil answer is "don't know", not "a
                // different track", and treating it as a change silently
                // dropped the intro we had just muted. Ask twice, and only a
                // definite different title cancels the rewind.
                var currentTitle = MusicRemote.nowPlaying()?.title
                if currentTitle == nil {
                    usleep(300_000)
                    currentTitle = MusicRemote.nowPlaying()?.title
                }
                let changedTrack = expectedTrackTitle != nil && currentTitle != nil
                    && currentTitle != expectedTrackTitle
                if restartTrackFromHead, !changedTrack {
                    MusicRemote.setPosition(to: 0)
                } else if changedTrack {
                    Self.logger.info("track changed during the switch (\(currentTitle ?? "?", privacy: .public) ≠ \(expectedTrackTitle ?? "?", privacy: .public)) — leaving playback position alone")
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
            let artworkPath = NSTemporaryDirectory() + "neiro-artwork"
            // A streaming track's artwork is not there the instant the track
            // starts — it arrives a few seconds later. One attempt left the
            // panel showing the placeholder for the rest of the song, so keep
            // asking for a while. A new track cancels this task.
            for delay in [Duration.milliseconds(400), .seconds(1.5), .seconds(3), .seconds(6)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
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
                if result.1, let image = NSImage(contentsOfFile: artworkPath) {
                    self.nowPlayingArtwork = image
                    return
                }
                // Nothing playing at all — no point retrying.
                if result.0 == nil { self.nowPlayingArtwork = nil; return }
                self.nowPlayingArtwork = nil
            }
        }
    }

    func closePanel() {
        closePanelHandler?()
    }

    func showHelp() {
        closePanel()
        showHelpHandler?()
    }

    // MARK: - Undo / redo

    /// Dragging a slider produces hundreds of changes, so a history entry is
    /// only committed once the value has stopped moving.
    private func recordHistory() {
        guard !isApplyingHistory else { return }
        guard EQSnapshot(settings) != settledSnapshot else { return }
        historyTask?.cancel()
        historyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let settled = EQSnapshot(self.settings)
            guard settled != self.settledSnapshot else { return }
            self.history.commit(previous: self.settledSnapshot)
            self.settledSnapshot = settled
        }
    }

    func undo() {
        guard let previous = history.undo(current: EQSnapshot(settings)) else { return }
        applyHistory(previous)
    }

    func redo() {
        guard let next = history.redo(current: EQSnapshot(settings)) else { return }
        applyHistory(next)
    }

    private func applyHistory(_ snapshot: EQSnapshot) {
        historyTask?.cancel()
        isApplyingHistory = true
        settings.bands = snapshot.bands
        settings.preGainDB = snapshot.preGainDB
        settledSnapshot = snapshot
        isApplyingHistory = false
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
