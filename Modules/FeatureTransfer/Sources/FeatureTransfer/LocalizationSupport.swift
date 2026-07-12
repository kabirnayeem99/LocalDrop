import Foundation

enum FeatureTransferLocalization {
    static let bundle: Bundle = .module
    private static let fallbackCatalog: [String: String] = {
        guard
            let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data)
        else {
            return [:]
        }

        return catalog.strings.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = entry.value.localizations?["en"]?.stringUnit?.value
        }
    }()

    static func string(forKey key: String) -> String {
        let localized = String(localized: .init(key), bundle: bundle)
        if localized != key {
            return localized
        }
        return fallbackCatalog[key] ?? localized
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(forKey: key), arguments: arguments)
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
