import Foundation

enum LocalDeviceIdentity {
    private static let fallbackSystemName = "LocalDrop Mac"

    private static let aliasAdjectives = [
        "Amber", "Cedar", "Cobalt", "Copper", "Ember", "Frost",
        "Golden", "Harbor", "Juniper", "Maple", "Nova", "Silver"
    ]

    private static let aliasNouns = [
        "Atlas", "Bloom", "Comet", "Dawn", "Echo", "Grove",
        "Harbor", "Horizon", "Meadow", "Orchard", "Summit", "Tide"
    ]

    static func systemName() -> String {
        normalizedCustomName(Host.current().localizedName) ?? fallbackSystemName
    }

    static func randomAlias() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomAlias(using: &generator)
    }

    static func randomAlias<T: RandomNumberGenerator>(using generator: inout T) -> String {
        let adjective = aliasAdjectives.randomElement(using: &generator) ?? "LocalDrop"
        let noun = aliasNouns.randomElement(using: &generator) ?? "Mac"
        return "\(adjective) \(noun)"
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
