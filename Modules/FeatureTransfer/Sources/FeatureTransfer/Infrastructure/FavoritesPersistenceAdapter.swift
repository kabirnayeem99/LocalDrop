import Foundation

/// UserDefaults-backed persistence for favorited devices, mirroring
/// `SettingsPersistenceAdapter`: a single JSON blob under one key, failing safe
/// to an empty list on a missing or corrupt payload rather than throwing.
///
/// Favorites are stored separately from `TransferSettingsSnapshot` deliberately.
/// Saving the snapshot runs through `TransferFeatureStore.persistSettings()`,
/// which also pushes `TransferProtocolSettings` at the runtime and shows a
/// "settings saved" banner — neither of which should happen when a user stars a
/// row in the device list.
///
/// Fingerprints are normalized to lowercase on both load and save so a favorite
/// written by an older build (or a peer that announced uppercase hex) still
/// matches, consistent with `Fingerprint.matches(_:_:)`.
struct FavoritesPersistenceAdapter: FavoritesPersisting {
    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults,
        key: String = "FeatureTransfer.favorites"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> [FavoriteDevice] {
        guard let data = userDefaults.data(forKey: key) else {
            return []
        }
        let decoded = (try? JSONDecoder().decode([FavoriteDevice].self, from: data)) ?? []
        return Self.deduplicated(decoded)
    }

    func save(_ favorites: [FavoriteDevice]) {
        guard let data = try? JSONEncoder().encode(Self.deduplicated(favorites)) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }

    /// Two entries can normalize onto the same key (e.g. one written in uppercase
    /// hex before the lowercase change). First write wins, order preserved.
    private static func deduplicated(_ favorites: [FavoriteDevice]) -> [FavoriteDevice] {
        var seen: Set<String> = []
        return favorites.filter { seen.insert($0.fingerprint).inserted }
    }
}
