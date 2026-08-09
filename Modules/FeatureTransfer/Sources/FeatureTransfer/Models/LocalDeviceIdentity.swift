import Darwin
import Foundation

enum LocalDeviceIdentity {
    private static let fallbackSystemName = "LocalDrop Mac"
    private static let fallbackHardwareModel = "Mac"

    /// Computed once: this is read on every `/info` and `/register` response.
    private static let cachedDeviceModel: String = makeDeviceModel()

    static func systemName() -> String {
        normalizedCustomName(Host.current().localizedName) ?? fallbackSystemName
    }

    /// Hardware model plus macOS version, e.g. `"MacBookPro18,3 (macOS 15.3)"`.
    /// Reference LocalSend peers display this verbatim in their device list.
    static func deviceModel() -> String {
        cachedDeviceModel
    }

    private static func makeDeviceModel() -> String {
        let hardware = hardwareModel() ?? fallbackHardwareModel
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionText = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"

        return "\(hardware) (macOS \(versionText))"
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }

        // sysctl returns a NUL-terminated C string; drop the terminator (and anything after it).
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
