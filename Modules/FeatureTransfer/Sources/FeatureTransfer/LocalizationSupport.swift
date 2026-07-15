import Foundation

public enum FeatureTransferLocalization {
    public static let bundle: Bundle = .module
    private static let catalog: StringCatalog? = {
        guard
            let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data)
        else {
            return nil
        }
        return catalog
    }()
    private static let lock = NSLock()
    private static var preferredLanguageKeys: [String] = []

    static func setLanguage(_ language: LanguageSetting) {
        setLocaleIdentifier(language.locale?.identifier)
    }

    static func setLocaleIdentifier(_ identifier: String?) {
        lock.lock()
        preferredLanguageKeys = localizationKeys(for: identifier)
        lock.unlock()
    }

    public static func string(forKey key: String) -> String {
        if let override = localizedValue(forKey: key, preferredKeys: currentPreferredLanguageKeys()) {
            return override
        }

        let localized = String(localized: .init(key), bundle: bundle)
        if localized != key {
            return localized
        }

        return localizedValue(forKey: key, preferredKeys: ["en"]) ?? localized
    }

    public static func resource(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(bundle.bundleURL))
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(forKey: key), arguments: arguments)
    }

    private static func currentPreferredLanguageKeys() -> [String] {
        lock.lock()
        let keys = preferredLanguageKeys
        lock.unlock()
        return keys
    }

    private static func localizedValue(forKey key: String, preferredKeys: [String]) -> String? {
        guard let entry = catalog?.strings[key] else { return nil }

        for preferredKey in preferredKeys {
            if
                let value = entry.localizations?[preferredKey]?.stringUnit?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                value.isEmpty == false
            {
                return value
            }
        }

        return nil
    }

    private static func localizationKeys(for identifier: String?) -> [String] {
        guard let identifier, identifier.isEmpty == false else { return [] }

        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let base = normalized.split(separator: "-").first.map(String.init)

        if let base, base != normalized {
            return [normalized, base]
        }
        return [normalized]
    }
}

private struct StringCatalog: Decodable {
    struct Entry: Decodable {
        struct Localization: Decodable {
            struct StringUnit: Decodable {
                let value: String?
            }

            let stringUnit: StringUnit?
        }

        let localizations: [String: Localization]?
    }

    let strings: [String: Entry]
}
