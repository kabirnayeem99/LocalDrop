#!/usr/bin/swift

import Foundation

struct StringCatalog: Decodable {
    struct Entry: Decodable {
        struct Localization: Decodable {
            struct StringUnit: Decodable {
                let state: String?
                let value: String?
            }

            let stringUnit: StringUnit?
        }

        let localizations: [String: Localization]?
    }

    let sourceLanguage: String
    let strings: [String: Entry]
}

enum VerificationError: Error, CustomStringConvertible {
    case missingArgument
    case unreadableInfoPlist(URL)
    case unreadableCatalog(URL)
    case invalidInfoPlist(URL)
    case decodingFailed(URL, Error)
    case missingTranslations([String])
    case placeholderMismatches([String])

    var description: String {
        switch self {
        case .missingArgument:
            return "usage: verify-featuretransfer-localizations.swift <path-to-Localizable.xcstrings> [path-to-Info.plist]"
        case .unreadableInfoPlist(let url):
            return "could not read Info.plist at \(url.path)"
        case .unreadableCatalog(let url):
            return "could not read catalog at \(url.path)"
        case .invalidInfoPlist(let url):
            return "could not parse CFBundleLocalizations from \(url.path)"
        case .decodingFailed(let url, let error):
            return "could not decode catalog at \(url.path): \(error)"
        case .missingTranslations(let keys):
            let joined = keys.joined(separator: "\n")
            return "missing translations for:\n\(joined)"
        case .placeholderMismatches(let keys):
            let joined = keys.joined(separator: "\n")
            return "placeholder mismatches for:\n\(joined)"
        }
    }
}

func loadCatalog(from url: URL) throws -> StringCatalog {
    guard let data = try? Data(contentsOf: url) else {
        throw VerificationError.unreadableCatalog(url)
    }
    do {
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    } catch {
        throw VerificationError.decodingFailed(url, error)
    }
}

func loadRequiredLocales(from infoPlistURL: URL, sourceLanguage: String) throws -> [String] {
    guard let data = try? Data(contentsOf: infoPlistURL) else {
        throw VerificationError.unreadableInfoPlist(infoPlistURL)
    }

    guard
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let rawLocales = dictionary["CFBundleLocalizations"] as? [String]
    else {
        throw VerificationError.invalidInfoPlist(infoPlistURL)
    }

    var locales: [String] = []
    for locale in [sourceLanguage] + rawLocales where locales.contains(locale) == false {
        locales.append(locale)
    }
    return locales
}

func placeholderTokens(in value: String) -> [String] {
    let pattern = #"%(?:\d+\$)?[@dDfFuUxXoOcCsSpaAeEgG]"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let nsValue = value as NSString
    return regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length)).map {
        nsValue.substring(with: $0.range)
    }
}

func verifyTranslations(in catalog: StringCatalog, requiredLocales: [String]) throws {
    var missing: [String] = []
    var placeholderMismatches: [String] = []

    for key in catalog.strings.keys.sorted() {
        guard
            let english = catalog.strings[key]?.localizations?["en"]?.stringUnit,
            english.state == "translated",
            let englishValue = english.value?.trimmingCharacters(in: .whitespacesAndNewlines),
            englishValue.isEmpty == false
        else {
            missing.append("\(key) [en]")
            continue
        }

        let englishPlaceholders = placeholderTokens(in: englishValue)

        for locale in requiredLocales {
            guard
                let localized = catalog.strings[key]?.localizations?[locale]?.stringUnit,
                localized.state == "translated",
                let value = localized.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                value.isEmpty == false
            else {
                missing.append("\(key) [\(locale)]")
                continue
            }

            if placeholderTokens(in: value) != englishPlaceholders {
                placeholderMismatches.append("\(key) [\(locale)]")
            }
        }
    }

    guard missing.isEmpty else {
        throw VerificationError.missingTranslations(missing)
    }
    guard placeholderMismatches.isEmpty else {
        throw VerificationError.placeholderMismatches(placeholderMismatches)
    }
}

do {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw VerificationError.missingArgument
    }

    let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let catalog = try loadCatalog(from: catalogURL)
    let infoPlistURL: URL
    if CommandLine.arguments.count == 3 {
        infoPlistURL = URL(fileURLWithPath: CommandLine.arguments[2])
    } else {
        infoPlistURL = catalogURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/LocalDropApp/Info.plist")
    }
    let requiredLocales = try loadRequiredLocales(from: infoPlistURL, sourceLanguage: catalog.sourceLanguage)
    try verifyTranslations(in: catalog, requiredLocales: requiredLocales)
} catch let error as VerificationError {
    fputs("error: \(error)\n", stderr)
    exit(1)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
