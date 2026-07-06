import Foundation
import Security

public final class TOFUSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String
    private let nowProvider: @Sendable () -> Date

    public init(expectedFingerprint: String, nowProvider: @escaping @Sendable () -> Date = { Date() }) {
        self.expectedFingerprint = expectedFingerprint
        self.nowProvider = nowProvider
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              TLSCertificateValidator.validate(trust: trust, expectedFingerprint: expectedFingerprint, now: nowProvider())
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
