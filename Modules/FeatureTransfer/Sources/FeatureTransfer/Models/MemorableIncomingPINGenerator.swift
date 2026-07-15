import Foundation

struct MemorableIncomingPINGenerator {
    static let pinLength = 6
    static let minimumRhythmScore = 4
    static let candidateCount = 24
    static let fallbackPIN = "710710"
    static let preferredPrefix = "710"
    static let preferredPrefixFrequency = 10

    enum Pattern: CaseIterable {
        case ababAB
        case abcABC
        case aaBBCC
        case abCCBA
        case ababCB

        var slotOrder: [Int] {
            switch self {
            case .ababAB:
                return [0, 1, 0, 1, 0, 1]
            case .abcABC:
                return [0, 1, 2, 0, 1, 2]
            case .aaBBCC:
                return [0, 0, 1, 1, 2, 2]
            case .abCCBA:
                return [0, 1, 2, 2, 1, 0]
            case .ababCB:
                return [0, 1, 0, 1, 2, 1]
            }
        }

        var requiredDistinctDigits: Int {
            Set(slotOrder).count
        }
    }

    struct CandidateSpec {
        let pattern: Pattern
        let digits: [Int]
    }

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate(
        prefixRoll: Int,
        suffixValue: Int,
        fallbackValue: Int
    ) -> String {
        if prefixRoll == 0 {
            return preferredPrefix + String(format: "%03d", max(0, suffixValue) % 1000)
        }
        return String(format: "%06d", max(0, fallbackValue) % 1_000_000)
    }

    static func generate<R: RandomNumberGenerator>(using random: inout R) -> String {
        var specs = [CandidateSpec]()
        if Int.random(in: 0..<preferredPrefixFrequency, using: &random) == 0 {
            specs.append(CandidateSpec(pattern: .abcABC, digits: [7, 1, 0]))
            specs.append(CandidateSpec(pattern: .abCCBA, digits: [7, 1, 0]))
        }

        while specs.count < candidateCount {
            specs.append(randomSpec(using: &random))
        }

        return bestCandidate(from: specs) ?? fallbackPIN
    }

    static func bestCandidate(from specs: [CandidateSpec]) -> String? {
        let candidates = specs.map(candidate(from:)).filter { isValid($0) }
        guard let first = candidates.first else { return nil }

        return candidates.dropFirst().reduce(first) { currentBest, candidate in
            if shouldPrefer(candidate, over: currentBest) {
                return candidate
            }
            return currentBest
        }
    }

    static func candidate(from spec: CandidateSpec) -> String {
        let digits = Array(spec.digits.prefix(spec.pattern.requiredDistinctDigits))
        precondition(digits.count == spec.pattern.requiredDistinctDigits, "Pattern digit count mismatch")
        precondition(Set(digits).count == digits.count, "Candidate digits must be distinct")

        return spec.pattern.slotOrder.map { String(digits[$0]) }.joined()
    }

    static func score(_ candidate: String) -> Int {
        let characters = Array(candidate)
        let distinctDigitCount = Set(characters).count
        var total = 0

        if candidate.prefix(3) == candidate.suffix(3) {
            total += 4
        }

        let pairChunks = chunks(of: candidate, size: 2)
        if pairChunks.count == 3, Set(pairChunks).count == 1 {
            total += 4
        }

        if String(characters.reversed()) == candidate {
            total += 3
        }

        if pairChunks.count == 3, pairChunks.allSatisfy({ $0.first == $0.last }) {
            total += 3
        }

        if distinctDigitCount <= 3 {
            total += 2
        } else {
            total -= 3
        }

        if isEasilyGrouped(candidate) {
            total += 2
        }

        if hasAdjacentDouble(candidate) {
            total += 1
        }

        if hasRun(of: 4, in: candidate) {
            total -= 3
        }

        if candidate.hasPrefix("0") {
            total -= 2
        }

        if lacksRhythm(candidate) {
            total -= 2
        }

        return total
    }

    static func isValid(_ candidate: String, minimumScore: Int = minimumRhythmScore) -> Bool {
        guard candidate.count == pinLength else { return false }
        guard candidate.hasPrefix("0") == false else { return false }
        guard Set(candidate).count <= 3 else { return false }
        guard hasRun(of: 4, in: candidate) == false else { return false }
        guard lacksRhythm(candidate) == false else { return false }
        return score(candidate) >= minimumScore
    }

    private static func randomSpec<R: RandomNumberGenerator>(using random: inout R) -> CandidateSpec {
        let pattern = Pattern.allCases.randomElement(using: &random) ?? .abcABC
        var digits = [Int]()
        digits.reserveCapacity(pattern.requiredDistinctDigits)

        while digits.count < pattern.requiredDistinctDigits {
            let nextDigit: Int
            if digits.isEmpty {
                nextDigit = Int.random(in: 1...9, using: &random)
            } else {
                nextDigit = Int.random(in: 0...9, using: &random)
            }

            if digits.contains(nextDigit) == false {
                digits.append(nextDigit)
            }
        }

        return CandidateSpec(pattern: pattern, digits: digits)
    }

    private static func shouldPrefer(_ lhs: String, over rhs: String) -> Bool {
        let lhsScore = score(lhs)
        let rhsScore = score(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        let lhsPrefers710 = lhs.hasPrefix(preferredPrefix)
        let rhsPrefers710 = rhs.hasPrefix(preferredPrefix)
        if lhsPrefers710 != rhsPrefers710 {
            return lhsPrefers710
        }

        return lhs < rhs
    }

    private static func isEasilyGrouped(_ candidate: String) -> Bool {
        let pairChunks = chunks(of: candidate, size: 2)
        let tripletChunks = chunks(of: candidate, size: 3)

        let repeatedPairs = pairChunks.count == 3 && Set(pairChunks).count < pairChunks.count
        let mirroredPairs = pairChunks.count == 3 && pairChunks.allSatisfy { $0.first == $0.last }
        let repeatedTriplets = tripletChunks.count == 2 && Set(tripletChunks).count == 1

        return repeatedPairs || mirroredPairs || repeatedTriplets
    }

    private static func hasAdjacentDouble(_ candidate: String) -> Bool {
        let characters = Array(candidate)
        return zip(characters, characters.dropFirst()).contains { $0 == $1 }
    }

    private static func hasRun(of length: Int, in candidate: String) -> Bool {
        var runLength = 1
        let characters = Array(candidate)

        for index in 1..<characters.count {
            if characters[index] == characters[index - 1] {
                runLength += 1
                if runLength >= length {
                    return true
                }
            } else {
                runLength = 1
            }
        }

        return false
    }

    private static func lacksRhythm(_ candidate: String) -> Bool {
        hasAdjacentDouble(candidate) == false
            && hasRepeatedBlock(in: candidate, size: 2) == false
            && hasRepeatedBlock(in: candidate, size: 3) == false
    }

    private static func hasRepeatedBlock(in candidate: String, size: Int) -> Bool {
        let blocks = chunks(of: candidate, size: size)
        return Set(blocks).count < blocks.count
    }

    private static func chunks(of candidate: String, size: Int) -> [Substring] {
        stride(from: 0, to: candidate.count, by: size).map { start in
            let lowerBound = candidate.index(candidate.startIndex, offsetBy: start)
            let upperBound = candidate.index(lowerBound, offsetBy: size, limitedBy: candidate.endIndex) ?? candidate.endIndex
            return candidate[lowerBound..<upperBound]
        }
    }
}
