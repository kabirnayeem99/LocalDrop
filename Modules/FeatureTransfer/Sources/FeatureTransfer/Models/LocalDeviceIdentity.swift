import Foundation

enum LocalDeviceIdentity {
    private static let fallbackSystemName = "LocalDrop Mac"

    static func systemName() -> String {
        normalizedCustomName(Host.current().localizedName) ?? fallbackSystemName
    }

    static func randomAlias(excluding existingNames: Set<String> = []) -> String {
        RetroDeviceNameGenerator.generate(excluding: existingNames)
    }

    static func normalizedCustomName(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        return trimmed.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
