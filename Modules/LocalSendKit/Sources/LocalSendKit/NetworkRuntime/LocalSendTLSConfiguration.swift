import Crypto
import Foundation
import Network
import Security

public struct LocalSendTLSConfiguration: Sendable {
    public let identity: LocalIdentity
    public let queue: DispatchQueue

    public init(identity: LocalIdentity, queue: DispatchQueue = DispatchQueue(label: "LocalSendTLSConfiguration")) {
        self.identity = identity
        self.queue = queue
    }

    /// LocalSend's trust model is one-directional TOFU: the client verifies the server's
    /// self-signed cert (see `TOFUSessionDelegate`/`TLSCertificateValidator`), and the server
    /// never requests a client certificate. There is no `sec_protocol_options_set_verify_block`
    /// here because without `sec_protocol_options_set_peer_authentication_required` the server
    /// never receives a peer cert to verify — registering a verify block anyway is dead code.
    public func makeListenerParameters() throws -> NWParameters {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
        sec_protocol_options_set_local_identity(secOptions, try makeSecIdentity())

        let parameters = NWParameters(tls: options)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    public func makeSecIdentity() throws -> sec_identity_t {
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificateDER as CFData) else {
            throw LocalSendRuntimeError.tlsIdentityUnavailable
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeEC,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256
        ]
        var error: Unmanaged<CFError>?
        let privateKeyData = try Self.x963PrivateKeyData(from: identity.privateKeyRawRepresentation)
        guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? LocalSendRuntimeError.tlsIdentityUnavailable
        }
        guard let secIdentity = SecIdentityCreate(nil, certificate, privateKey),
              let protocolIdentity = sec_identity_create(secIdentity) else {
            throw LocalSendRuntimeError.tlsIdentityUnavailable
        }
        return protocolIdentity
    }

    /// `SecKeyCreateWithData` for `kSecAttrKeyClassPrivate`+EC does NOT take PKCS#8/DER —
    /// it wants the ANSI X9.63 public point (`04||X||Y`) concatenated with the raw big-endian
    /// private scalar. Passing a DER blob fails with OSStatus -50 ("EC private key creation
    /// from data failed").
    private static func x963PrivateKeyData(from rawRepresentation: Data) throws -> Data {
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        return signingKey.publicKey.x963Representation + rawRepresentation
    }
}

enum TLSCertificateValidator {
    static func validate(trust: SecTrust, expectedFingerprint: String?, now: Date) -> Bool {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return false
        }

        let der = SecCertificateCopyData(certificate) as Data
        if let expectedFingerprint, Fingerprint.make(from: der) != expectedFingerprint {
            return false
        }

        let authority = CertificateAuthority(store: InMemoryCertificateStore())
        do {
            try authority.validate(certificateDER: der, now: now)
            return true
        } catch {
            return false
        }
    }
}

private struct InMemoryCertificateStore: CertificateStore {
    func loadIdentity() throws -> LocalIdentity? { nil }
    func saveIdentity(_ identity: LocalIdentity) throws {}
    func removeIdentity() throws {}
}
