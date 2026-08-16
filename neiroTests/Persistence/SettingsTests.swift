import Testing
@testable import neiro
import Foundation

/// Settings are read back from disk on every launch, so old files written
/// before a key existed have to keep working.
struct SettingsTests {
    @Test func settingsCarryBypassAndBindings() throws {
        var settings = EQSettings.makeDefault()
        settings.isBypassed = true
        settings.presetBindings = ["uid-1": "Bass Boost"]
        let restored = try JSONDecoder().decode(EQSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.isBypassed)
        #expect(restored.presetBindings["uid-1"] == "Bass Boost")

        // Settings written before these keys existed must still load.
        let legacy = #"{"isEnabled":true,"preGainDB":0}"#
        let old = try JSONDecoder().decode(EQSettings.self, from: Data(legacy.utf8))
        #expect(!old.isBypassed)
        #expect(old.presetBindings.isEmpty)
    }

    @Test func settingsDecodeWithoutNewerKeys() throws {
        let legacy = #"{"isEnabled":true,"preGainDB":-3}"#
        let settings = try JSONDecoder().decode(EQSettings.self, from: Data(legacy.utf8))
        #expect(settings.isEnabled)
        #expect(settings.followTrackRate)
        #expect(!settings.bands.isEmpty)
    }

    @Test func builtInPresetsAreWellFormed() {
        #expect(!BuiltInPresets.all.isEmpty)
        for preset in BuiltInPresets.all {
            #expect(preset.bands.count == 10)
            #expect(preset.bands.allSatisfy { abs($0.gainDB) <= 24 })
        }
        let flat = BuiltInPresets.all.first { $0.name == "Flat" }
        #expect(flat?.bands.allSatisfy { $0.gainDB == 0 } == true)
    }
}
