import Foundation

public actor PinAttemptTracker {
    private var attemptsByIP: [String: Int] = [:]

    public init() {}

    public enum ValidationResult: Equatable, Sendable {
        case allowed
        case unauthorized
        case rateLimited
    }

    public func validate(ipAddress: String, providedPIN: String?, expectedPIN: String?) -> ValidationResult {
        guard let expectedPIN, expectedPIN.isEmpty == false else {
            attemptsByIP[ipAddress] = 0
            return .allowed
        }

        let attempts = attemptsByIP[ipAddress, default: 0]
        if attempts >= 3 {
            return .rateLimited
        }

        if providedPIN == expectedPIN {
            attemptsByIP[ipAddress] = 0
            return .allowed
        }

        let next = attempts + 1
        attemptsByIP[ipAddress] = next
        return next >= 3 ? .rateLimited : .unauthorized
    }

    public func attempts(for ipAddress: String) -> Int {
        attemptsByIP[ipAddress, default: 0]
    }
}
