import Foundation

public actor PinAttemptTracker {
    private var attemptsByIP: [String: Int] = [:]

    public init() {}

    public enum ValidationResult: Equatable, Sendable {
        case allowed
        case unauthorized
        case rateLimited
    }

    /// Mirrors the reference implementation (`app/lib/provider/network/server/controller/common.dart`).
    ///
    /// Notable properties of the reference semantics that are deliberate here:
    /// - The counter is **never** reset — not on success, and not when no PIN is configured.
    /// - A missing/empty `providedPIN` is a failed authentication but does **not** consume an
    ///   attempt. Counting it would burn attempt 1 on the sender's very first (PIN-less)
    ///   `prepare-upload`, leaving only two real tries before lockout.
    ///
    /// One deliberate divergence: an `expectedPIN` of `""` is treated as "no PIN configured" and
    /// allows everything, whereas the reference's `if (pin != null)` would enforce the empty string
    /// literally and reject every sender that did not send `?pin=`. The settings UI cannot produce
    /// an empty configured PIN, and "no PIN required" is the recoverable outcome, so this is not
    /// changed — but it is not the reference's semantics.
    public func validate(ipAddress: String, providedPIN: String?, expectedPIN: String?) -> ValidationResult {
        guard let expectedPIN, expectedPIN.isEmpty == false else {
            return .allowed
        }

        let attempts = attemptsByIP[ipAddress, default: 0]
        if attempts >= 3 {
            return .rateLimited
        }

        if providedPIN == expectedPIN {
            return .allowed
        }

        guard let providedPIN, providedPIN.isEmpty == false else {
            // "PIN required" — the sender has not guessed yet, so nothing is counted.
            return .unauthorized
        }

        let next = attempts + 1
        attemptsByIP[ipAddress] = next
        return next >= 3 ? .rateLimited : .unauthorized
    }

    public func attempts(for ipAddress: String) -> Int {
        attemptsByIP[ipAddress, default: 0]
    }
}
