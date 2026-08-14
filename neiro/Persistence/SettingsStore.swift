import Foundation

enum SettingsStore {
    private static let key = "eqSettings.v1"

    static func load() -> EQSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EQSettings.self, from: data) else {
            return EQSettings.makeDefault()
        }
        return settings
    }

    static func save(_ settings: EQSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
