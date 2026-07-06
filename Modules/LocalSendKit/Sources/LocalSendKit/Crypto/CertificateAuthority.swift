import Crypto
import Foundation
import Security
import X509

public struct LocalIdentity: Codable, Equatable, Sendable {
    public var certificateDER: Data
    public var privateKeyRawRepresentation: Data
    public var fingerprint: String
    public var notValidBefore: Date
    public var notValidAfter: Date

    public init(
        certificateDER: Data,
        privateKeyRawRepresentation: Data,
        fingerprint: String,
        notValidBefore: Date,
        notValidAfter: Date
    ) {
        self.certificateDER = certificateDER
        self.privateKeyRawRepresentation = privateKeyRawRepresentation
        self.fingerprint = fingerprint
        self.notValidBefore = notValidBefore
        self.notValidAfter = notValidAfter
    }
}

public enum CertificateAuthorityError: Error, Equatable {
    case invalidCertificate
    case expiredCertificate
    case unexpectedPublicKey
}

public protocol CertificateStore: Sendable {
    func loadIdentity() throws -> LocalIdentity?
    func saveIdentity(_ identity: LocalIdentity) throws
    func removeIdentity() throws
}

public struct FileCertificateStore: CertificateStore {
    private let identityURL: URL

    public init(identityURL: URL) {
        self.identityURL = identityURL
    }

    public func loadIdentity() throws -> LocalIdentity? {
        guard FileManager.default.fileExists(atPath: identityURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: identityURL)
        return try JSONDecoder().decode(LocalIdentity.self, from: data)
    }

    public func saveIdentity(_ identity: LocalIdentity) throws {
        let directoryURL = identityURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(identity)
        try data.write(to: identityURL, options: Data.WritingOptions.atomic)
    }

    public func removeIdentity() throws {
        guard FileManager.default.fileExists(atPath: identityURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: identityURL)
    }
}

public struct CertificateAuthority: Sendable {
    private let store: any CertificateStore

    public init(store: any CertificateStore) {
        self.store = store
    }

    public func loadOrCreateIdentity(now: Date = .now) throws -> LocalIdentity {
        if let existing = try store.loadIdentity() {
            try validate(certificateDER: existing.certificateDER, now: now)
            return existing
        }

        let identity = try generateIdentity(now: now)
        try store.saveIdentity(identity)
        return identity
    }

    public func reset() throws {
        try store.removeIdentity()
    }

    public func generateIdentity(now: Date = .now) throws -> LocalIdentity {
        let privateKey = P256.Signing.PrivateKey()
        let notValidBefore = now.addingTimeInterval(-300)
        let notValidAfter = now.addingTimeInterval(60 * 60 * 24 * 365 * 10)
        let subject = try DistinguishedName {
            CommonName("LocalDrop")
        }

        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(privateKey.publicKey),
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            },
            issuerPrivateKey: .init(privateKey)
        )

        let secCertificate = try SecCertificate.makeWithCertificate(certificate)
        let certificateDER = SecCertificateCopyData(secCertificate) as Data
        return LocalIdentity(
            certificateDER: certificateDER,
            privateKeyRawRepresentation: privateKey.rawRepresentation,
            fingerprint: Fingerprint.make(from: certificateDER),
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter
        )
    }

    public func validate(
        certificateDER: Data,
        now: Date = .now,
        expectedPublicKeyDER: Data? = nil
    ) throws {
        let parsedCertificate: Certificate
        do {
            parsedCertificate = try Certificate(derEncoded: Array(certificateDER))
        } catch {
            throw CertificateAuthorityError.invalidCertificate
        }

        guard parsedCertificate.notValidBefore <= now, parsedCertificate.notValidAfter >= now else {
            throw CertificateAuthorityError.expiredCertificate
        }

        guard parsedCertificate.publicKey.isValidSignature(parsedCertificate.signature, for: parsedCertificate) else {
            throw CertificateAuthorityError.invalidCertificate
        }

        if let expectedPublicKeyDER {
            guard let expectedPublicKey = try? P256.Signing.PublicKey(rawRepresentation: expectedPublicKeyDER),
                  parsedCertificate.publicKey == Certificate.PublicKey(expectedPublicKey) else {
                throw CertificateAuthorityError.unexpectedPublicKey
            }
        }
    }
}
