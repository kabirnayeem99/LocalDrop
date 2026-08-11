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
    /// literally and reject every sender that did not send `?pin=`. It is kept because "no PIN
    /// required" is the recoverable outcome of the two — the alternative locks the user's own
    /// senders out of a receiver they cannot fix from the sending side.
    ///
    /// It is also unreachable in this app, but NOT because of anything on
    /// `TransferProtocolSettings` itself: `incomingPIN` is a plain `var` with no `didSet`, and
    /// `TransferFeatureContainer.testing(incomingPIN:)` writes it directly, so neither the
    /// initializer nor the decode normalizer is the load-bearing guard. What actually holds the
    /// invariant is `TransferFeatureStore.resolvedIncomingPIN`, which substitutes a freshly
    /// generated PIN for any non-conforming value on the way into `currentProtocolSettings`, plus
    /// the initial runtime configuration at `TransferFeatureContainer.swift:414/427`, which reads a
    /// snapshot that came through the normalizing decode. Both feed
    /// `LocalSendServerConfiguration.pin`, so the empty string never reaches `expectedPIN`.
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
