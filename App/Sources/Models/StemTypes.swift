import Foundation

enum StemKind: String, Codable, CaseIterable, Identifiable {
    case vocals, drums, bass, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vocals: return "שירה"
        case .drums: return "תופים"
        case .bass: return "בס"
        case .other: return "כלים אחרים"
        }
    }

    var symbol: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "metronome"
        case .bass: return "waveform.path"
        case .other: return "pianokeys"
        }
    }
}

/// Per-stem gain multipliers (1.0 = untouched).
struct StemGains: Codable, Hashable {
    var vocals: Double = 1
    var drums: Double = 1
    var bass: Double = 1
    var other: Double = 1

    subscript(kind: StemKind) -> Double {
        get {
            switch kind {
            case .vocals: return vocals
            case .drums: return drums
            case .bass: return bass
            case .other: return other
            }
        }
        set {
            switch kind {
            case .vocals: vocals = newValue
            case .drums: drums = newValue
            case .bass: bass = newValue
            case .other: other = newValue
            }
        }
    }

    var isNeutral: Bool {
        [vocals, drums, bass, other].allSatisfy { abs($0 - 1) < 0.001 }
    }
}

/// Status of AI stem separation for an audio asset.
enum StemsState: Codable, Hashable {
    case none
    case processing(progress: Double)
    case ready
    case failed(message: String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }
    var isProcessing: Bool { if case .processing = self { return true } else { return false } }
}
