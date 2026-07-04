import Foundation

/// A musical key: root pitch class (0 = C … 11 = B) plus mode.
struct MusicalKey: Codable, Hashable {
    var root: Int          // 0...11, 0 = C
    var isMinor: Bool

    init(root: Int, isMinor: Bool) {
        self.root = ((root % 12) + 12) % 12
        self.isMinor = isMinor
    }

    static let noteNamesSharp = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let noteNamesFlat  = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// Traditional name, e.g. "Am" / "C".
    var traditionalName: String {
        // Flat spelling for keys conventionally written with flats
        // (Db/Eb/Ab/Bb major; Ebm/Abm/Bbm minor — C#m and F#m stay sharp).
        let flatRoots: Set<Int> = isMinor ? [3, 8, 10] : [1, 3, 8, 10]
        let name = flatRoots.contains(root) ? MusicalKey.noteNamesFlat[root] : MusicalKey.noteNamesSharp[root]
        return isMinor ? "\(name)m" : name
    }

    /// Camelot wheel position 1...12.
    var camelotNumber: Int {
        // 8B = C major, 8A = A minor; +7 semitones = +1 hour.
        // number = (8 + 7 * distanceFromReference) mod 12 (1-based)
        let reference = isMinor ? 9 : 0          // A minor / C major roots
        let steps = ((root - reference) % 12 + 12) % 12
        // moving up 7 semitones adds 1 hour; 7 * 7 % 12 == 1, so hours = steps * 7 mod 12
        let hours = (steps * 7) % 12
        let n = (8 + hours - 1) % 12 + 1
        return n
    }

    var camelotName: String { "\(camelotNumber)\(isMinor ? "A" : "B")" }

    func displayName(style: KeyNotationStyle) -> String {
        switch style {
        case .camelot: return camelotName
        case .traditional: return traditionalName
        }
    }

    func bothNames() -> String { "\(camelotName) · \(traditionalName)" }

    /// The key that results from shifting this key by `semitones`.
    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(root: root + semitones, isMinor: isMinor)
    }

    /// Harmonic compatibility (Camelot rules): same slot, ±1 hour, or relative major/minor.
    func isCompatible(with other: MusicalKey) -> Bool {
        if self == other { return true }
        if camelotNumber == other.camelotNumber && isMinor != other.isMinor { return true } // relative
        if isMinor == other.isMinor {
            let d = abs(camelotNumber - other.camelotNumber)
            return d == 1 || d == 11
        }
        return false
    }

    /// Smallest pitch shift (in semitones, -6...6) that makes `self` compatible with `target`.
    func smallestShiftForCompatibility(with target: MusicalKey) -> Int {
        var best = 0
        var bestAbs = Int.max
        for shift in -6...6 {
            if transposed(by: shift).isCompatible(with: target) {
                if abs(shift) < bestAbs { best = shift; bestAbs = abs(shift) }
            }
        }
        return bestAbs == Int.max ? 0 : best
    }

    init?(camelot: String) {
        let up = camelot.uppercased().trimmingCharacters(in: .whitespaces)
        guard let last = up.last, last == "A" || last == "B",
              let n = Int(up.dropLast()), (1...12).contains(n) else { return nil }
        let minor = last == "A"
        // invert: hours = n - 8 (mod 12); steps = hours * 7 mod 12 (since 7*7=49≡1 mod 12)
        let hours = ((n - 8) % 12 + 12) % 12
        let steps = (hours * 7) % 12
        let reference = minor ? 9 : 0
        self.init(root: reference + steps, isMinor: minor)
    }
}

enum KeyNotationStyle: String, Codable, CaseIterable {
    case camelot
    case traditional

    var label: String {
        switch self {
        case .camelot: return "Camelot (8A)"
        case .traditional: return "מז'ור/מינור (Am)"
        }
    }
}
