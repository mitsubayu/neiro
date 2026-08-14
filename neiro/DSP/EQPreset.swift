import Foundation

struct EQPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var preGainDB: Double
    var bands: [EQBand]
}

enum BuiltInPresets {
    /// Gains for the standard 10 bands (31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k).
    private static func preset(_ name: String, preGain: Double, _ gains: [Double]) -> EQPreset {
        var bands = EQSettings.makeDefault().bands
        for (index, gain) in gains.enumerated() where index < bands.count {
            bands[index].gainDB = gain
        }
        return EQPreset(name: name, preGainDB: preGain, bands: bands)
    }

    static let all: [EQPreset] = [
        preset("Flat", preGain: 0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        preset("Bass Boost", preGain: -4, [5, 4, 3, 1.5, 0, 0, 0, 0, 0, 0]),
        preset("Bass Cut", preGain: 0, [-5, -4, -3, -1.5, 0, 0, 0, 0, 0, 0]),
        preset("Treble Boost", preGain: -3, [0, 0, 0, 0, 0, 0, 1.5, 3, 4, 4]),
        preset("V-Shape", preGain: -5, [4, 3, 1.5, 0, -1, -1, 0, 1.5, 3, 4]),
        preset("Vocal", preGain: -3, [-2, -1.5, 0, 1.5, 3, 3, 2, 1, 0, -1]),
    ]
}

enum PresetStore {
    private static let key = "eqPresets.v1"

    static func load() -> [EQPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data) else {
            return []
        }
        return presets
    }

    static func save(_ presets: [EQPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
