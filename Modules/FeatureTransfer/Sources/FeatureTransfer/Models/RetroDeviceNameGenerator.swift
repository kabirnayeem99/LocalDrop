import Foundation

enum RetroDeviceNameGenerator {
    private static let retroNames = [
        "Midnight Macintosh",
        "Signal Macintosh",
        "Blue Box Macintosh",
        "Wiretap Macintosh",
        "Carbon Terminal",
        "Phosphor Terminal",
        "Basement Terminal",
        "Amber Console",
        "Neon Mainframe",
        "Cipher System"
    ]

    private static let preferredDigits = [2, 3, 5, 7, 8, 9]
    private static let fallbackDigits = [1, 4, 6]
    private static let ascendingSequences = [123, 234, 345, 456, 567, 678, 789]
    private static let descendingSequences = [987, 876, 765, 654, 543, 432, 321]

    enum Pattern: CaseIterable {
        case aba
        case aab
        case abb
        case sequence
        case step

        static func select<T: RandomNumberGenerator>(using generator: inout T) -> Self {
            let roll = Int.random(in: 0..<100, using: &generator)
            switch roll {
            case 0..<50: return .aba
            case 50..<65: return .aab
            case 65..<80: return .abb
            case 80..<90: return .sequence
            default: return .step
            }
        }
    }

    static func generate(excluding existingNames: Set<String> = []) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(excluding: existingNames, using: &generator)
    }

    static func generate<T: RandomNumberGenerator>(
        excluding existingNames: Set<String> = [],
        using generator: inout T
    ) -> String {
        for _ in 0..<64 {
            let retroName = retroNames.randomElement(using: &generator) ?? "Amber Console"
            let pattern = Pattern.select(using: &generator)
            let number = makeNumber(for: pattern, using: &generator)
            let candidate = "\(retroName) \(number)"
            if isAcceptable(candidate, number: number, excluding: existingNames) {
                return candidate
            }
        }

        return "Amber Console 727"
    }

    private static func isAcceptable(
        _ candidate: String,
        number: Int,
        excluding existingNames: Set<String>
    ) -> Bool {
        let digits = paddedDigits(number)
        guard digits.first != "0" else { return false }
        guard Set(digits).count > 1 else { return false }
        guard number != 123 else { return false }
        guard candidate.count <= 24 else { return false }
        return existingNames.contains(candidate) == false
    }

    private static func makeNumber<T: RandomNumberGenerator>(
        for pattern: Pattern,
        using generator: inout T
    ) -> Int {
        switch pattern {
        case .aba:
            let a = preferredLeadDigit(using: &generator)
            let b = distinctDigit(from: a, using: &generator)
            return a * 100 + b * 10 + a
        case .aab:
            let a = preferredLeadDigit(using: &generator)
            let b = distinctDigit(from: a, using: &generator)
            return a * 100 + a * 10 + b
        case .abb:
            let a = preferredLeadDigit(using: &generator)
            let b = distinctDigit(from: a, using: &generator)
            return a * 100 + b * 10 + b
        case .sequence:
            let pool = Bool.random(using: &generator) ? ascendingSequences : descendingSequences
            return pool.randomElement(using: &generator) ?? 727
        case .step:
            let options = validStepSeeds()
            let seed = options.randomElement(using: &generator) ?? 2
            let direction = seed == 9 ? -1 : (seed == 1 ? 1 : (Bool.random(using: &generator) ? 1 : -1))
            let middle = seed + direction
            return seed * 100 + middle * 10 + seed
        }
    }

    private static func validStepSeeds() -> [Int] {
        Array(1...9)
    }

    private static func preferredLeadDigit<T: RandomNumberGenerator>(using generator: inout T) -> Int {
        let pool = preferredDigits + fallbackDigits
        return pool.randomElement(using: &generator) ?? 7
    }

    private static func distinctDigit<T: RandomNumberGenerator>(from digit: Int, using generator: inout T) -> Int {
        let pool = (preferredDigits + fallbackDigits + [0]).filter { $0 != digit }
        return pool.randomElement(using: &generator) ?? (digit == 7 ? 2 : 7)
    }

    private static func paddedDigits(_ number: Int) -> [Character] {
        String(format: "%03d", number).map(\.self)
    }
}
