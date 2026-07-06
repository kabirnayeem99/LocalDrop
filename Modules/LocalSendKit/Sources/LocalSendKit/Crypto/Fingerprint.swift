import Crypto
import Foundation

public enum Fingerprint {
    public static func make(from certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined()
    }
}
