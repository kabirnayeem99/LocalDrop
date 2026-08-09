import Foundation
import Security

/// Errors surfaced by ``KeychainCertificateStore``.
///
/// These are deliberately distinct and diagnosable: the store NEVER silently falls back to
/// plaintext-file storage on failure, because a quiet fallback would recreate the exact
/// plaintext-private-key vulnerability this type exists to fix while making it invisible.
public enum KeychainCertificateStoreError: Error, Equatable, CustomStringConvertible {
    /// A raw Security-framework call failed. `operation` names the call site
    /// ("read"/"add"/"update"/"delete") and `status` is the raw `OSStatus`.
    case keychainOperationFailed(operation: String, status: Int32)
    /// The keychain item exists but its payload could not be decoded as a `LocalIdentity`.
    case corruptKeychainPayload
    /// The legacy plaintext identity file exists but could not be decoded.
    case corruptLegacyIdentityFile
    /// The legacy identity was written to the keychain but the verification read-back did not
    /// return a byte-identical identity. The legacy file is intentionally left on disk in this
    /// case so the device's TOFU-pinned identity is never destroyed.
    case migrationVerificationFailed

    public var description: String {
        switch self {
        case let .keychainOperationFailed(operation, status):
            return "KeychainCertificateStore: keychain \(operation) failed with OSStatus \(status)"
        case .corruptKeychainPayload:
            return "KeychainCertificateStore: keychain item could not be decoded as a LocalIdentity"
        case .corruptLegacyIdentityFile:
            return "KeychainCertificateStore: legacy identity file could not be decoded as a LocalIdentity"
        case .migrationVerificationFailed:
            return "KeychainCertificateStore: migration read-back verification failed; legacy identity file was preserved"
        }
    }
}

/// Narrow seam over the raw keychain item operations.
///
/// Extracted so that the migration sequencing in ``KeychainCertificateStore`` can be unit-tested
/// deterministically against an in-memory fake. `swift test` on this package produces an unsigned
/// binary, where real keychain I/O is unreliable; the migration logic must not depend on it.
protocol KeychainItemBackend: Sendable {
    func readItem(service: String, account: String) throws -> Data?
    func writeItem(_ data: Data, service: String, account: String) throws
    func deleteItem(service: String, account: String) throws
}

/// Real `Security.framework` implementation of ``KeychainItemBackend``.
struct SecurityKeychainItemBackend: KeychainItemBackend {
    init() {}

    // NOTE ON ITEM ATTRIBUTES AND WHAT THEY DO / DO NOT BUY:
    //
    // This project is not signed with a Developer ID team, so we deliberately DO NOT set
    // `kSecAttrAccessGroup` and DO NOT set `kSecUseDataProtectionKeychain`. Both require a Team ID
    // plus `keychain-access-groups` entitlements we do not have. The accepted trade-off is looser
    // access control: the item lands in the legacy (file-based) macOS keychain.
    //
    // Consequence, stated honestly: on the legacy macOS keychain `kSecAttrAccessible*` is IGNORED.
    // We set `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` purely to future-proof a later move
    // to the data-protection keychain. It provides NO at-rest accessibility guarantee today. What
    // this store actually buys over the previous plaintext JSON file is: the private key is no
    // longer sitting in a world-readable, trivially-copied file in Application Support, and it is
    // covered by keychain ACLs and login-keychain encryption at rest. It is NOT hardware-bound, NOT
    // Secure-Enclave-backed, and NOT protected against a determined attacker already running code
    // as this user.
    //
    // `kSecAttrSynchronizable` is set to `false` EXPLICITLY rather than left to the default: an
    // iCloud-synced TLS identity would clone one device's LocalSend identity onto another, breaking
    // the one-device-one-identity invariant that peer TOFU pinning depends on.
    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    func readItem(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainCertificateStoreError.corruptKeychainPayload
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCertificateStoreError.keychainOperationFailed(operation: "read", status: status)
        }
    }

    func writeItem(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCertificateStoreError.keychainOperationFailed(operation: "update", status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCertificateStoreError.keychainOperationFailed(operation: "add", status: addStatus)
        }
    }

    func deleteItem(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCertificateStoreError.keychainOperationFailed(operation: "delete", status: status)
        }
    }
}

/// Stores the device's ``LocalIdentity`` in the macOS keychain instead of a plaintext JSON file.
///
/// The whole `LocalIdentity` (certificate, private key, fingerprint, validity dates) is encoded and
/// stored as a single keychain item's data. The key is deliberately NOT split out from the
/// certificate: two halves in two places can desync, which is a worse failure mode than the
/// plaintext storage this replaces, because the certificate fingerprint IS the device's LocalSend
/// identity and every peer TOFU-pins it.
public struct KeychainCertificateStore: CertificateStore {
    /// Default keychain service string for the LocalDrop TLS identity.
    public static let defaultService = "com.localdrop.LocalDrop.identity"
    /// Default keychain account for the LocalDrop TLS identity.
    public static let defaultAccount = "tls-identity"

    private let service: String
    private let account: String
    private let legacyIdentityURL: URL?
    private let backend: any KeychainItemBackend

    /// - Parameters:
    ///   - service: Keychain service string. Injectable so tests can use a throwaway namespace.
    ///   - account: Keychain account string. Injectable for the same reason.
    ///   - legacyIdentityURL: Location of the pre-keychain plaintext `identity.json`, if any. When
    ///     present it is one-way migrated into the keychain on first `loadIdentity()`.
    public init(
        service: String = KeychainCertificateStore.defaultService,
        account: String = KeychainCertificateStore.defaultAccount,
        legacyIdentityURL: URL? = nil
    ) {
        self.init(
            service: service,
            account: account,
            legacyIdentityURL: legacyIdentityURL,
            backend: SecurityKeychainItemBackend()
        )
    }

    init(
        service: String,
        account: String,
        legacyIdentityURL: URL?,
        backend: any KeychainItemBackend
    ) {
        self.service = service
        self.account = account
        self.legacyIdentityURL = legacyIdentityURL
        self.backend = backend
    }

    /// Loads the identity, migrating a legacy plaintext file into the keychain if needed.
    ///
    /// Migration ordering is write -> verified read-back -> delete, never delete-then-write and
    /// never delete without a verified read-back. If the read-back does not round-trip equal, the
    /// legacy file is left untouched and ``KeychainCertificateStoreError/migrationVerificationFailed``
    /// is thrown, so the only copy of a TOFU-pinned identity can never be destroyed. The whole
    /// sequence is idempotent: once the keychain item exists it always wins.
    ///
    /// The keychain-hit path still inspects the legacy file, because a crash between step 2 and step
    /// 3 would otherwise leave the plaintext key on disk forever — `loadIdentity()` would return
    /// from the keychain on every later launch and never revisit `identity.json` again. The
    /// verified-equality invariant is unchanged, just evaluated later: the file is deleted only when
    /// it decodes to exactly the keychain identity. A file that has *diverged* is left alone, since
    /// it may be the only copy of a different TOFU-pinned identity.
    public func loadIdentity() throws -> LocalIdentity? {
        if let stored = try readKeychainIdentity() {
            deleteLegacyFileIfIdenticalTo(stored)
            return stored
        }

        guard let legacyIdentityURL, FileManager.default.fileExists(atPath: legacyIdentityURL.path) else {
            return nil
        }

        let legacyData = try Data(contentsOf: legacyIdentityURL)
        let legacyIdentity: LocalIdentity
        do {
            legacyIdentity = try JSONDecoder().decode(LocalIdentity.self, from: legacyData)
        } catch {
            throw KeychainCertificateStoreError.corruptLegacyIdentityFile
        }

        // 1. Write into the keychain.
        try writeKeychainIdentity(legacyIdentity)

        // 2. Verify by reading it back out of the keychain and comparing byte-for-byte.
        guard let readBack = try readKeychainIdentity(), readBack == legacyIdentity else {
            throw KeychainCertificateStoreError.migrationVerificationFailed
        }

        // 3. Only now is it safe to remove the plaintext copy.
        try FileManager.default.removeItem(at: legacyIdentityURL)

        return readBack
    }

    /// Finishes an interrupted migration: removes `legacyIdentityURL` when — and only when — it
    /// decodes to an identity equal to the one already in the keychain.
    ///
    /// Never throws. A load that already has a good identity in hand must not be failed by a
    /// leftover file that is unreadable or corrupt; the worst case is that the file survives to be
    /// re-examined on the next launch, which is exactly the status quo this repairs.
    private func deleteLegacyFileIfIdenticalTo(_ keychainIdentity: LocalIdentity) {
        guard let legacyIdentityURL,
              FileManager.default.fileExists(atPath: legacyIdentityURL.path),
              let legacyData = try? Data(contentsOf: legacyIdentityURL),
              let legacyIdentity = try? JSONDecoder().decode(LocalIdentity.self, from: legacyData),
              legacyIdentity == keychainIdentity else {
            return
        }
        try? FileManager.default.removeItem(at: legacyIdentityURL)
    }

    public func saveIdentity(_ identity: LocalIdentity) throws {
        try writeKeychainIdentity(identity)
    }

    /// Clears both the keychain item and any legacy plaintext file.
    public func removeIdentity() throws {
        try backend.deleteItem(service: service, account: account)
        if let legacyIdentityURL, FileManager.default.fileExists(atPath: legacyIdentityURL.path) {
            try FileManager.default.removeItem(at: legacyIdentityURL)
        }
    }

    private func readKeychainIdentity() throws -> LocalIdentity? {
        guard let data = try backend.readItem(service: service, account: account) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(LocalIdentity.self, from: data)
        } catch {
            throw KeychainCertificateStoreError.corruptKeychainPayload
        }
    }

    private func writeKeychainIdentity(_ identity: LocalIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try backend.writeItem(data, service: service, account: account)
    }
}
