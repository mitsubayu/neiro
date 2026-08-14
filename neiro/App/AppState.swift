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
    private(set) var userPresets: [EQPreset] = PresetStore.load()
    private(set) var activePresetName: String?
    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingArtist: String?
    private(set) var nowPlayingArtwork: NSImage?

    /// "96kHz/24bit" (bit depth omitted for float/unknown sources) — shown in
    /// the menu bar next to the icon and in the status row.
    var formatLabel: String {
        let kilohertz = engineSampleRate / 1000
        let rateText = kilohertz == kilohertz.rounded()
            ? String(format: "%.0fkHz", kilohertz)
            : String(format: "%.1fkHz", kilohertz)
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

    private func startEngine(resumePlaybackAfterStart: Bool = false, restartTrackFromHead: Bool = false) {
        musicWaitTask?.cancel()

        // A switch sequence that can't reach its resume closure must release
        // the in-progress flag, or evaluations deadlock on it forever.
        func abandonSwitch() {
            if resumePlaybackAfterStart {
                processor.setMuted(false)
                isSwitchingRate = false
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

        activeOutputUID = outputUID
        let preferredRate = settings.followTrackRate ? lastTrackRate : nil
        let engine = self.engine
        engine.controlQueue.async { [weak self] in
            do {
                try engine.start(musicProcess: musicProcess, outputDeviceUID: outputUID,
                                 preferredRate: preferredRate)
                let rate = engine.sampleRate
                Task { @MainActor [weak self] in
                    self?.status = .running
                    self?.engineSampleRate = rate
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.status = .error(error.localizedDescription)
                    self?.activeOutputUID = nil
                }
            }
        }
        if resumePlaybackAfterStart {
            // Serial queue: runs after the start block above has finished.
            engine.controlQueue.async { [weak self] in
                usleep(300_000)
                if restartTrackFromHead {
                    MusicRemote.setPosition(to: 0)
                }
                MusicRemote.play()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.processor.setMuted(false)
                    self.isSwitchingRate = false
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

    /// Music logs the source rate when it builds a track's AudioQueue. Around
    /// track transitions it can build several queues at *different* rates
    /// within a couple of seconds (pre-rolling the next item), so detections
    /// are debounced: we act on the last rate that stays stable for 1.2s.
    private func handleDetectedTrackRate(_ rate: Double) {
        lastTrackRate = rate
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
              !isSwitchingRate, !muteCheckInFlight else { return }
        muteCheckInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.muteCheckInFlight = false }
            guard let self else { return }
            let state = await Task.detached { MusicRemote.playerState() }.value
            guard state == "playing" else { return }
            let position = await Task.detached { MusicRemote.playerPosition() }.value ?? .infinity
            if position <= 5, self.lastTrackRate != self.engineSampleRate, !self.isSwitchingRate {
                Self.logger.info("muting head at \(position)s pending rate switch")
                self.processor.setMuted(true)
            }
        }
    }

    private func scheduleRateSwitchEvaluation(afterMilliseconds delay: Int = 1200) {
        pendingRateTask?.cancel()
        pendingRateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluateRateSwitch()
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
    private func evaluateRateSwitch() {
        Self.logger.info("evaluate: track=\(self.lastTrackRate ?? 0) engine=\(self.engineSampleRate) status=\(String(describing: self.status)) follow=\(self.settings.followTrackRate) switching=\(self.isSwitchingRate)")
        guard let rate = lastTrackRate, settings.isEnabled, settings.followTrackRate,
              status == .running, rate != engineSampleRate else {
            // No switch needed after all (e.g. rate flapped back) — make sure
            // a head-mute from a premature detection doesn't stick.
            processor.setMuted(false)
            return
        }
        if isSwitchingRate {
            scheduleRateSwitchEvaluation()
            return
        }
        beginSwitching()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await Task.detached { MusicRemote.playerState() }.value
            guard state == "playing" else {
                Self.logger.info("switching silently (player \(state ?? "unreachable"))")
                self.processor.setMuted(false)
                self.startEngine()
                self.isSwitchingRate = false
                return
            }
            let position = await Task.detached { MusicRemote.playerPosition() }.value ?? 0
            guard position <= 5 else {
                Self.logger.info("deferring switch: mid-track at \(position)s")
                self.processor.setMuted(false)
                self.isSwitchingRate = false
                self.scheduleRateSwitchEvaluation(afterMilliseconds: 2000)
                return
            }
            Self.logger.info("switching engine \(self.engineSampleRate), restarting track from head (was at \(position)s)")
            await Task.detached { MusicRemote.pause() }.value
            self.startEngine(resumePlaybackAfterStart: true, restartTrackFromHead: true)
        }
    }

    /// Marks the switch in progress with a failsafe: if anything in the
    /// pause→rebuild→resume chain dies without clearing the flag, every later
    /// evaluation would silently reschedule forever. Reset it after 10s.
    private func beginSwitching() {
        isSwitchingRate = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isSwitchingRate else { return }
            Self.logger.error("switch watchdog fired: clearing stuck isSwitchingRate")
            self.isSwitchingRate = false
            self.processor.setMuted(false)
            self.scheduleRateSwitchEvaluation()
        }
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
                guard let self, self.settings.isEnabled else { return }
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
            Task { @MainActor [weak self] in
                self?.nowPlayingTitle = title
                self?.nowPlayingArtist = artist
                self?.refreshNowPlaying(havePayloadTitle: title != nil)
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
