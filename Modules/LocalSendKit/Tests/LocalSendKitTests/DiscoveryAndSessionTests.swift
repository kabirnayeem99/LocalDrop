import Foundation
import Testing
@testable import LocalSendKit

struct DiscoveryAndSessionTests {
    @Test func multicastFiltersSelfAndPreservesReplySignal() throws {
        let message = MulticastMessage(alias: "Mac", fingerprint: "SELF", port: 53317, protocolType: .https, announce: true)
        let data = try JSONEncoder().encode(message)
        #expect(try MulticastListener.decodeAnnouncement(data, selfFingerprint: "SELF") == nil)

        let other = try #require(try MulticastListener.decodeAnnouncement(data, selfFingerprint: "OTHER"))
        #expect(other.shouldReplyViaRegister == true)
    }

    @Test func announcerCreatesThreeRetries() throws {
        let attempts = try MulticastAnnouncer.makeAttempts(
            for: MulticastMessage(alias: "Mac", fingerprint: "X", port: 53317, protocolType: .https, announce: true)
        )
        #expect(attempts.map(\.delayMilliseconds) == [100, 500, 2000])
    }

    @Test func legacyScannerFallsBackWhenRegisterFails() async {
        struct StubClient: LegacyScannerClient {
            func register(host: String, info: RegisterInfo) async throws -> RegisterInfo {
                struct Failure: Error {}
                if host == "ok" {
                    return RegisterInfo(alias: "A", fingerprint: "1")
                }
                throw Failure()
            }
        }

        let scanner = LegacyHTTPScanner(client: StubClient())
        let results = await scanner.scan(
            hosts: ["fallback", "ok"],
            info: RegisterInfo(alias: "Sender", fingerprint: "S")
        ) { host in
            host == "fallback" ? RegisterInfo(alias: "B", fingerprint: "2") : nil
        }

        #expect(results.map(\.alias) == ["A", "B"])
        let emptyResults = await scanner.scan(
            hosts: ["missing"],
            info: RegisterInfo(alias: "Sender", fingerprint: "S")
        ) { _ in
            nil
        }
        #expect(emptyResults.isEmpty)
    }

    @Test func pinAttemptTrackerIsConcurrencySafe() async {
        let tracker = PinAttemptTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = await tracker.validate(ipAddress: "10.0.0.1", providedPIN: "wrong", expectedPIN: "123")
                }
            }
        }
        #expect(await tracker.attempts(for: "10.0.0.1") >= 3)
        #expect(await tracker.validate(ipAddress: "10.0.0.2", providedPIN: "ok", expectedPIN: nil) == .allowed)
    }
}
