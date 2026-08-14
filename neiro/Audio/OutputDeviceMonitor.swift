import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

@Observable
final class OutputDeviceMonitor {
    private(set) var devices: [AudioOutputDevice] = []
    var onChange: (() -> Void)?

    @ObservationIgnored private var listeners: [PropertyListener] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "neiro.devices")

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let listener = PropertyListener(objectID: .system, selector: selector, queue: queue,
                                               handler: { [weak self] in self?.handleChange() }) {
                listeners.append(listener)
            }
        }
    }

    static func currentDefaultOutput() -> AudioOutputDevice? {
        var deviceID = AudioObjectID.unknown
        try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, into: &deviceID)
        guard deviceID.isValid else { return nil }
        return describe(deviceID)
    }

    private static func describe(_ deviceID: AudioObjectID) -> AudioOutputDevice? {
        guard let uid = try? deviceID.readString(kAudioDevicePropertyDeviceUID),
              let name = try? deviceID.readString(kAudioObjectPropertyName) else { return nil }
        return AudioOutputDevice(id: deviceID, uid: uid, name: name)
    }

    private func handleChange() {
        DispatchQueue.main.async {
            self.refresh()
            self.onChange?()
        }
    }

    private func refresh() {
        let ids: [AudioObjectID] = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        devices = ids.compactMap { id in
            let streams: [AudioObjectID] = (try? id.readArray(kAudioDevicePropertyStreams,
                                                              scope: kAudioObjectPropertyScopeOutput)) ?? []
            guard !streams.isEmpty else { return nil }
            guard let device = Self.describe(id),
                  // Our own aggregate is private but still visible to the
                  // process that owns it — listing it would let the user route
                  // neiro into itself, and its create/destroy churn must not
                  // look like a real device change.
                  device.uid != neiroAggregateUID else { return nil }
            return device
        }
    }
}
