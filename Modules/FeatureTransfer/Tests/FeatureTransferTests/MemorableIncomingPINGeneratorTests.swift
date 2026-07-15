import XCTest
@testable import FeatureTransfer

final class MemorableIncomingPINGeneratorTests: XCTestCase {
    func testCandidateBuildsABCABCPattern() {
        let candidate = MemorableIncomingPINGenerator.candidate(
            from: .init(pattern: .abcABC, digits: [7, 1, 0])
        )

        XCTAssertEqual(candidate, "710710")
    }

    func testCandidateBuildsMirrorPattern() {
        let candidate = MemorableIncomingPINGenerator.candidate(
            from: .init(pattern: .abCCBA, digits: [7, 1, 0])
        )

        XCTAssertEqual(candidate, "710017")
    }

    func testScoreRewardsRepeatedThreeDigitBlock() {
        XCTAssertGreaterThan(
            MemorableIncomingPINGenerator.score("710710"),
            MemorableIncomingPINGenerator.score("710217")
        )
    }

    func testScoreRewardsMirrorAndDoubleDigits() {
        XCTAssertGreaterThanOrEqual(MemorableIncomingPINGenerator.score("123321"), 6)
    }

    func testIsValidRejectsLeadingZero() {
        XCTAssertFalse(MemorableIncomingPINGenerator.isValid("010101"))
    }

    func testIsValidRejectsFourConsecutiveDigits() {
        XCTAssertFalse(MemorableIncomingPINGenerator.isValid("111123"))
    }

    func testIsValidRejectsMostlyRandomCandidate() {
        XCTAssertFalse(MemorableIncomingPINGenerator.isValid("123450"))
    }

    func testBestCandidatePrefersHigherScoringRhythmicPattern() {
        let best = MemorableIncomingPINGenerator.bestCandidate(from: [
            .init(pattern: .ababCB, digits: [7, 1, 0]),
            .init(pattern: .abcABC, digits: [7, 1, 0]),
            .init(pattern: .abCCBA, digits: [7, 1, 0]),
        ])

        XCTAssertEqual(best, "710710")
    }

    func testGeneratedPINsStayWithinContract() {
        for _ in 0..<250 {
            let pin = MemorableIncomingPINGenerator.generate()

            XCTAssertEqual(pin.count, MemorableIncomingPINGenerator.pinLength)
            XCTAssertFalse(pin.hasPrefix("0"))
            XCTAssertLessThanOrEqual(Set(pin).count, 3)
            XCTAssertTrue(MemorableIncomingPINGenerator.isValid(pin))
        }
    }

    func testTransferProtocolSettingsUsesGeneratorLengthContract() {
        let pin = TransferProtocolSettings.generateIncomingPIN()

        XCTAssertEqual(pin.count, TransferProtocolSettings.incomingPINLength)
        XCTAssertEqual(
            TransferProtocolSettings.normalizedIncomingPIN(from: pin),
            pin
        )
    }
}
