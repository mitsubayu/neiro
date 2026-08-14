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
