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
        case isEnabled, preGainDB, outputDeviceUID, followTrackRate, bands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        preGainDB = try container.decodeIfPresent(Double.self, forKey: .preGainDB) ?? 0
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        followTrackRate = try container.decodeIfPresent(Bool.self, forKey: .followTrackRate) ?? true
        bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? EQSettings.makeDefault().bands
    }
}
