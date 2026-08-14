import AppKit
import Foundation
import Observation

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

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        engine = ProcessTapEngine(processor: processor)
        processor.update(settings: loaded)

        engine.onSampleRateChange = { [weak self] rate in
            Task { @MainActor [weak self] in self?.engineSampleRate = rate }
        }

        deviceMonitor.onChange = { [weak self] in self?.handleDeviceListChange() }
        rateDetector.onRateDetected = { [weak self] rate in self?.handleDetectedTrackRate(rate) }
        rateDetector.onBitDepthDetected = { [weak self] rate, depth in
            guard let self else { return }
            // The decoder-output line carries the depth; trust it once its
            // rate agrees with the track rate we're following.
            if self.lastTrackRate == nil || rate == self.lastTrackRate {
                self.trackBitDepth = depth
            }
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

    private func startEngine(resumePlaybackAfterStart: Bool = false) {
        musicWaitTask?.cancel()

        guard let musicProcess = MusicProcessLocator.musicProcessObjectID() else {
            status = .waitingForMusic
            waitForMusic()
            return
        }
        guard let outputUID = resolveOutputUID() else {
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
                MusicRemote.play()
                Task { @MainActor [weak self] in self?.isSwitchingRate = false }
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

    /// Music logs the source rate when it builds a track's AudioQueue. If it
    /// differs from the rate we're running at, do a controlled switch:
    /// pause → retarget device rate + rebuild engine → resume. The pause keeps
    /// the switch from audibly cutting out mid-track (the LosslessSwitcher
    /// failure mode) — detection happens at the head of the track, and Music
    /// re-creates its AudioQueue at the new device rate on resume.
    private func handleDetectedTrackRate(_ rate: Double) {
        lastTrackRate = rate
        guard settings.isEnabled, settings.followTrackRate, status == .running,
              !isSwitchingRate, rate != engineSampleRate else { return }
        isSwitchingRate = true
        Task { @MainActor [weak self] in
            await Task.detached { MusicRemote.pause() }.value
            guard let self else { return }
            self.startEngine(resumePlaybackAfterStart: true)
        }
    }

    private func stopEngine() {
        musicWaitTask?.cancel()
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
