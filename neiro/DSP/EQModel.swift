import Foundation

enum BandType: String, Codable, CaseIterable {
    case lowShelf
    case peak
    case highShelf
}

struct EQBand: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: BandType
    var frequency: Double
    var gainDB: Double
    var q: Double
    var isEnabled: Bool = true
}

struct EQSettings: Codable, Equatable {
    var isEnabled = false
    var preGainDB: Double = 0
    var outputDeviceUID: String?
    var followTrackRate = true
    var launchAtLogin = true
    /// Skips all processing while true — an instant A/B against the same
    /// signal path (the enable toggle tears the tap down instead, which takes
    /// a second and changes the routing).
    var isBypassed = false
    /// Keeps the panel open when you click elsewhere — handy while dragging
    /// EQ handles against another app's audio.
    var panelPinned = false
    /// Lets the bands column fold away sideways on a small screen.
    var bandsVisible = true
    /// Output device UID → preset name, auto-applied when that device becomes
    /// the output (headphone correction differs per device).
    var presetBindings: [String: String] = [:]
    var bands: [EQBand]

    static let maxBands = 16

    static func makeDefault() -> EQSettings {
        var bands: [EQBand] = []
        bands.append(EQBand(type: .lowShelf, frequency: 31.5, gainDB: 0, q: 0.707))
        for frequency in [63.0, 125, 250, 500, 1000, 2000, 4000, 8000] {
            bands.append(EQBand(type: .peak, frequency: frequency, gainDB: 0, q: 1.0))
        }
        bands.append(EQBand(type: .highShelf, frequency: 16_000, gainDB: 0, q: 0.707))
        return EQSettings(bands: bands)
    }
}

// Tolerant decoding so settings saved by older builds (missing newer keys)
// still load instead of falling back to defaults.
extension EQSettings {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, preGainDB, outputDeviceUID, followTrackRate, launchAtLogin
        case isBypassed, presetBindings, panelPinned, bandsVisible, bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        preGainDB = try container.decodeIfPresent(Double.self, forKey: .preGainDB) ?? 0
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        followTrackRate = try container.decodeIfPresent(Bool.self, forKey: .followTrackRate) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        panelPinned = try container.decodeIfPresent(Bool.self, forKey: .panelPinned) ?? false
        bandsVisible = try container.decodeIfPresent(Bool.self, forKey: .bandsVisible) ?? true
        presetBindings = try container.decodeIfPresent([String: String].self, forKey: .presetBindings) ?? [:]
        bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? EQSettings.makeDefault().bands
    }
}
