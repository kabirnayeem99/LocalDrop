import Crypto
import Foundation
import Testing
@testable import LocalSendKit

struct CryptoTests {
    @Test func fingerprintIsLowercaseSHA256() {
        let data = Data("hello".utf8)
        let fingerprint = Fingerprint.make(from: data)
        #expect(fingerprint == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test func fingerprintMatchingIsCaseInsensitive() {
        let data = Data("hello".utf8)
        let fingerprint = Fingerprint.make(from: data)
        #expect(Fingerprint.matches(fingerprint, fingerprint.uppercased()))
        #expect(Fingerprint.matches(fingerprint, "deadbeef") == false)
    }

    @Test func loadOrCreatePersistsIdentity() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let identityURL = directory.appendingPathComponent("identity.json")
        let store = FileCertificateStore(identityURL: identityURL)
        let authority = CertificateAuthority(store: store)

        let first = try authority.loadOrCreateIdentity(now: Date(timeIntervalSince1970: 1_700_000_000))
        let second = try authority.loadOrCreateIdentity(now: Date(timeIntervalSince1970: 1_700_000_100))

        #expect(first == second)
        try authority.reset()
        #expect(FileManager.default.fileExists(atPath: identityURL.path) == false)
        try authority.reset()
    }

    @Test func generatedIdentityHasExpectedValidityWindow() throws {
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = try authority.generateIdentity(now: now)

        #expect(identity.fingerprint.isEmpty == false)
        #expect(identity.notValidBefore <= now)
        #expect(identity.notValidAfter.timeIntervalSince(now) > 60 * 60 * 24 * 365 * 9)
        try authority.validate(certificateDER: identity.certificateDER, now: now)
    }

    @Test func expiredCertificateFailsValidation() throws {
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = try authority.generateIdentity(now: now)

        #expect(throws: CertificateAuthorityError.self) {
            try authority.validate(certificateDER: identity.certificateDER, now: now.addingTimeInterval(60 * 60 * 24 * 365 * 20))
        }
    }

    @Test func expiredStoredIdentityIsRegenerated() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let identityURL = directory.appendingPathComponent("identity.json")
        let store = FileCertificateStore(identityURL: identityURL)
        let authority = CertificateAuthority(store: store)

        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let farFuture = past.addingTimeInterval(60 * 60 * 24 * 365 * 20)

        let first = try authority.loadOrCreateIdentity(now: past)
        let second = try authority.loadOrCreateIdentity(now: farFuture)

        #expect(first != second)
        try authority.validate(certificateDER: second.certificateDER, now: farFuture)
        #expect(try store.loadIdentity() == second)
        try authority.reset()
    }

    @Test func nonExpiredStoredIdentityIsNotRegenerated() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let identityURL = directory.appendingPathComponent("identity.json")
        let store = FileCertificateStore(identityURL: identityURL)
        let authority = CertificateAuthority(store: store)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try authority.loadOrCreateIdentity(now: now)
        let second = try authority.loadOrCreateIdentity(now: now.addingTimeInterval(60 * 60))

        #expect(first == second)
        try authority.reset()
    }

    @Test func tamperedCertificateFailsValidation() throws {
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        let identity = try authority.generateIdentity()
        var tampered = identity.certificateDER
        tampered[tampered.startIndex] ^= 0xFF

        #expect(throws: Error.self) {
            try authority.validate(certificateDER: tampered)
        }
    }

    @Test func unexpectedPublicKeyFailsValidation() throws {
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        let identity = try authority.generateIdentity()
        let wrongKey = P256.Signing.PrivateKey().publicKey.rawRepresentation

        #expect(throws: CertificateAuthorityError.self) {
            try authority.validate(certificateDER: identity.certificateDER, expectedPublicKeyDER: wrongKey)
        }
    }

    @Test func invalidCertificateFailsValidation() throws {
        let authority = CertificateAuthority(store: FileCertificateStore(identityURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)))
        #expect(throws: CertificateAuthorityError.self) {
            try authority.validate(certificateDER: Data("nope".utf8))
        }
    }
}
