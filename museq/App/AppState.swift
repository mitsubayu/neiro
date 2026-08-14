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

    /// "44.1k" / "48k" / "96k" — shown in the menu bar next to the icon.
    var sampleRateLabel: String {
        let kilohertz = engineSampleRate / 1000
        let text = kilohertz == kilohertz.rounded()
            ? String(format: "%.0f", kilohertz)
            : String(format: "%.1f", kilohertz)
        return "\(text)k"
    }

    let deviceMonitor = OutputDeviceMonitor()

    @ObservationIgnored private let processor = EQProcessor()
    @ObservationIgnored private let engine: ProcessTapEngine
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var musicWaitTask: Task<Void, Never>?
    @ObservationIgnored private var activeOutputUID: String?

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        engine = ProcessTapEngine(processor: processor)
        processor.update(settings: loaded)

        engine.onSampleRateChange = { [weak self] rate in
            Task { @MainActor [weak self] in self?.engineSampleRate = rate }
        }

        deviceMonitor.onChange = { [weak self] in self?.handleDeviceListChange() }
        observeMusicLifecycle()

        if settings.isEnabled {
            startEngine()
        }
    }

    // MARK: - Settings flow

    private func handleSettingsChange(oldValue: EQSettings) {
        processor.update(settings: settings)
        scheduleSave()

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

    private func startEngine() {
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
        let engine = self.engine
        engine.controlQueue.async { [weak self] in
            do {
                try engine.start(musicProcess: musicProcess, outputDeviceUID: outputUID)
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
