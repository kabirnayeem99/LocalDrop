import Foundation
import Testing
@testable import LocalSendKit

/// Deterministic in-memory stand-in for the real keychain.
///
/// `swift test` builds an unsigned binary where real keychain I/O is unreliable, so all migration
/// sequencing assertions run against this fake instead of `Security.framework`.
private final class FakeKeychainBackend: KeychainItemBackend, @unchecked Sendable {
    enum Mode {
        /// Behaves like a normal keychain.
        case normal
        /// Accepts writes but always reports the item as missing (simulates a write that silently
        /// did not land).
        case readsAlwaysEmpty
        /// Accepts writes but returns a corrupted payload on read-back.
        case readsReturnDifferentPayload
        /// Fails every write with a raw OSStatus.
        case writesFail(Int32)
    }

    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var mode: Mode = .normal
    private(set) var deleteCount = 0

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func readItem(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .readsAlwaysEmpty:
            return nil
        case .readsReturnDifferentPayload:
            guard storage[key(service, account)] != nil else { return nil }
            return Data("{\"not\":\"an identity\"}".utf8)
        default:
            return storage[key(service, account)]
        }
    }

    func writeItem(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if case let .writesFail(status) = mode {
            throw KeychainCertificateStoreError.keychainOperationFailed(operation: "add", status: status)
        }
        storage[key(service, account)] = data
    }

    func deleteItem(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        deleteCount += 1
        storage[key(service, account)] = nil
    }

    func rawItem(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service, account)]
    }
}

private struct KeychainFixture {
    let directory: URL
    let legacyURL: URL
    let backend: FakeKeychainBackend
    let service: String
    let account: String

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keychain-store-tests-\(UUID().uuidString)")
        legacyURL = directory.appendingPathComponent("identity.json")
        backend = FakeKeychainBackend()
        service = "com.localdrop.tests.identity.\(UUID().uuidString)"
        account = "tls-identity"
    }

    func makeStore() -> KeychainCertificateStore {
        KeychainCertificateStore(
            service: service,
            account: account,
            legacyIdentityURL: legacyURL,
            backend: backend
        )
    }

    func writeLegacyFile(_ identity: LocalIdentity) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileCertificateStore(identityURL: legacyURL).saveIdentity(identity)
    }

    var legacyFileExists: Bool {
        FileManager.default.fileExists(atPath: legacyURL.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeIdentity() throws -> LocalIdentity {
    try CertificateAuthority(store: InMemoryTestCertificateStore())
        .generateIdentity(now: Date(timeIntervalSince1970: 1_700_000_000))
}

private struct InMemoryTestCertificateStore: CertificateStore {
    func loadIdentity() throws -> LocalIdentity? { nil }
    func saveIdentity(_ identity: LocalIdentity) throws {}
    func removeIdentity() throws {}
}

struct KeychainCertificateStoreTests {
    @Test func migratesLegacyFileAndDeletesItAfterVerifiedReadBack() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)

        let store = fixture.makeStore()
        let loaded = try store.loadIdentity()

        #expect(loaded == identity)
        #expect(fixture.backend.rawItem(service: fixture.service, account: fixture.account) != nil)
        #expect(fixture.legacyFileExists == false)
    }

    @Test func migrationPreservesFingerprintAndPrivateKeyByteForByte() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)

        let loaded = try #require(try fixture.makeStore().loadIdentity())

        // TOFU-pin preservation: peers pin this fingerprint, so it must survive migration exactly.
        #expect(loaded.fingerprint == identity.fingerprint)
        #expect(loaded.certificateDER == identity.certificateDER)
        #expect(loaded.privateKeyRawRepresentation == identity.privateKeyRawRepresentation)
        #expect(loaded.notValidBefore == identity.notValidBefore)
        #expect(loaded.notValidAfter == identity.notValidAfter)
    }

    @Test func legacyFileSurvivesWhenReadBackReturnsNothing() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)
        fixture.backend.mode = .readsAlwaysEmpty

        #expect(throws: KeychainCertificateStoreError.migrationVerificationFailed) {
            _ = try fixture.makeStore().loadIdentity()
        }
        #expect(fixture.legacyFileExists)
    }

    @Test func legacyFileSurvivesWhenReadBackDoesNotRoundTrip() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)
        fixture.backend.mode = .readsReturnDifferentPayload

        #expect(throws: KeychainCertificateStoreError.corruptKeychainPayload) {
            _ = try fixture.makeStore().loadIdentity()
        }
        #expect(fixture.legacyFileExists)
    }

    @Test func legacyFileSurvivesWhenKeychainWriteFails() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)
        fixture.backend.mode = .writesFail(-25_308)

        #expect(throws: KeychainCertificateStoreError.keychainOperationFailed(operation: "add", status: -25_308)) {
            _ = try fixture.makeStore().loadIdentity()
        }
        #expect(fixture.legacyFileExists)
    }

    @Test func keychainValueWinsOverDivergedLegacyFile() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let keychainIdentity = try makeIdentity()
        let legacyIdentity = try makeIdentity()
        #expect(keychainIdentity != legacyIdentity)

        let store = fixture.makeStore()
        try store.saveIdentity(keychainIdentity)
        try fixture.writeLegacyFile(legacyIdentity)

        #expect(try store.loadIdentity() == keychainIdentity)
        // A legacy file that does NOT match the keychain may be the only copy of a different
        // TOFU-pinned identity, so it is left strictly alone.
        #expect(fixture.legacyFileExists)
    }

    /// The repair for a crash between the keychain write and the legacy delete. Without it
    /// `loadIdentity()` returns from the keychain forever and never revisits `identity.json`,
    /// leaving the plaintext private key on disk permanently.
    @Test func matchingLegacyFileIsDeletedOnTheKeychainHitPath() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()

        let store = fixture.makeStore()
        try store.saveIdentity(identity)
        // Simulates the interrupted migration: keychain already written, file not yet removed.
        try fixture.writeLegacyFile(identity)
        #expect(fixture.legacyFileExists)

        #expect(try store.loadIdentity() == identity)
        #expect(fixture.legacyFileExists == false)
        // Idempotent: a second load with the file already gone still succeeds.
        #expect(try store.loadIdentity() == identity)
    }

    @Test func corruptLegacyFileIsPreservedAndDoesNotFailTheKeychainHitPath() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()

        let store = fixture.makeStore()
        try store.saveIdentity(identity)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.legacyURL)

        // Undecodable is not "equal", so it is left alone — and it must not fail a load that
        // already has a good identity in hand.
        #expect(try store.loadIdentity() == identity)
        #expect(fixture.legacyFileExists)
    }

    @Test func returnsNilWhenNeitherKeychainNorLegacyFileExist() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        #expect(try fixture.makeStore().loadIdentity() == nil)
    }

    @Test func returnsNilWhenNoLegacyURLIsConfigured() throws {
        let backend = FakeKeychainBackend()
        let store = KeychainCertificateStore(
            service: "com.localdrop.tests.identity.\(UUID().uuidString)",
            account: "tls-identity",
            legacyIdentityURL: nil,
            backend: backend
        )
        #expect(try store.loadIdentity() == nil)
    }

    @Test func migrationIsIdempotent() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        try fixture.writeLegacyFile(identity)

        let store = fixture.makeStore()
        let first = try store.loadIdentity()
        let second = try store.loadIdentity()
        let third = try fixture.makeStore().loadIdentity()

        #expect(first == identity)
        #expect(second == identity)
        #expect(third == identity)
        #expect(fixture.legacyFileExists == false)
    }

    @Test func corruptLegacyFileSurfacesTypedErrorAndIsPreserved() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.legacyURL)

        #expect(throws: KeychainCertificateStoreError.corruptLegacyIdentityFile) {
            _ = try fixture.makeStore().loadIdentity()
        }
        #expect(fixture.legacyFileExists)
    }

    @Test func removeIdentityClearsKeychainAndLegacyFile() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let identity = try makeIdentity()
        let store = fixture.makeStore()
        try store.saveIdentity(identity)
        try fixture.writeLegacyFile(identity)

        try store.removeIdentity()

        #expect(fixture.backend.rawItem(service: fixture.service, account: fixture.account) == nil)
        #expect(fixture.legacyFileExists == false)
        #expect(try store.loadIdentity() == nil)
        // Idempotent: removing again is a no-op, not an error.
        try store.removeIdentity()
    }

    @Test func saveOverwritesExistingKeychainIdentity() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let first = try makeIdentity()
        let second = try makeIdentity()
        let store = fixture.makeStore()

        try store.saveIdentity(first)
        try store.saveIdentity(second)

        #expect(try store.loadIdentity() == second)
    }

    @Test func certificateAuthorityRoundTripsThroughKeychainStore() throws {
        let fixture = KeychainFixture()
        defer { fixture.cleanUp() }
        let authority = CertificateAuthority(store: fixture.makeStore())

        let first = try authority.loadOrCreateIdentity(now: Date(timeIntervalSince1970: 1_700_000_000))
        let second = try authority.loadOrCreateIdentity(now: Date(timeIntervalSince1970: 1_700_000_100))

        #expect(first == second)
        try authority.reset()
        #expect(try fixture.makeStore().loadIdentity() == nil)
    }

    /// Exercises the real `Security.framework` backend. `swift test` produces an unsigned binary
    /// where keychain access can be denied outright, so this skips gracefully rather than failing.
    @Test func realKeychainBackendRoundTripsWhenAvailable() throws {
        let backend = SecurityKeychainItemBackend()
        let service = "com.localdrop.tests.identity.\(UUID().uuidString)"
        let account = "tls-identity"
        defer { try? backend.deleteItem(service: service, account: account) }

        let identity = try makeIdentity()
        let store = KeychainCertificateStore(
            service: service,
            account: account,
            legacyIdentityURL: nil,
            backend: backend
        )

        do {
            try store.saveIdentity(identity)
        } catch let error as KeychainCertificateStoreError {
            withKnownIssue("Real keychain unavailable in this environment: \(error)") {
                Issue.record("\(error)")
            }
            return
        }

        #expect(try store.loadIdentity() == identity)
        try store.removeIdentity()
        #expect(try store.loadIdentity() == nil)
    }
}
