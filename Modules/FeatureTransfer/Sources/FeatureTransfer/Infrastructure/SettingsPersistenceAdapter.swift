import Foundation

struct SettingsPersistenceAdapter: TransferSettingsPersisting {
    private let userDefaults: UserDefaults
    private let key: String
    private let fallback: TransferSettingsSnapshot

    init(
        userDefaults: UserDefaults,
        key: String = "FeatureTransfer.settings",
        fallback: TransferSettingsSnapshot
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.fallback = fallback
    }

    func load() -> TransferSettingsSnapshot {
        guard let data = userDefaults.data(forKey: key) else {
            return fallback
        }
        return (try? JSONDecoder().decode(TransferSettingsSnapshot.self, from: data)) ?? fallback
    }

    func save(_ snapshot: TransferSettingsSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}
