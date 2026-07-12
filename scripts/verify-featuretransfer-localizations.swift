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

    let strings: [String: Entry]
}

enum VerificationError: Error, CustomStringConvertible {
    case missingArgument
    case unreadableCatalog(URL)
    case decodingFailed(URL, Error)
    case missingEnglishTranslations([String])

    var description: String {
        switch self {
        case .missingArgument:
            return "usage: verify-featuretransfer-localizations.swift <path-to-Localizable.xcstrings>"
        case .unreadableCatalog(let url):
            return "could not read catalog at \(url.path)"
        case .decodingFailed(let url, let error):
            return "could not decode catalog at \(url.path): \(error)"
        case .missingEnglishTranslations(let keys):
            let joined = keys.joined(separator: "\n")
            return "missing English translations for:\n\(joined)"
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

func verifyEnglishTranslations(in catalog: StringCatalog) throws {
    let missingKeys = catalog.strings.keys.sorted().filter { key in
        guard
            let english = catalog.strings[key]?.localizations?["en"]?.stringUnit,
            english.state == "translated",
            let value = english.value?.trimmingCharacters(in: .whitespacesAndNewlines),
            value.isEmpty == false
        else {
            return true
        }
        return false
    }

    guard missingKeys.isEmpty else {
        throw VerificationError.missingEnglishTranslations(missingKeys)
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw VerificationError.missingArgument
    }

    let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let catalog = try loadCatalog(from: catalogURL)
    try verifyEnglishTranslations(in: catalog)
} catch let error as VerificationError {
    fputs("error: \(error)\n", stderr)
    exit(1)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
