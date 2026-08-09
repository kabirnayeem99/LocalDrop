import Crypto
import Foundation

public enum Fingerprint {
    /// The reference implementation (`common/lib/util/security_helper.dart`) emits lowercase hex,
    /// so LocalDrop does too. Peers (and previously persisted LocalDrop identities) may still send
    /// uppercase hex, so every fingerprint equality check goes through ``matches(_:_:)``.
    public static func make(from certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    /// Case-insensitive fingerprint equality.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
