import Foundation

enum StemKind: String, Codable, CaseIterable, Identifiable {
    case vocals, drums, bass, guitar, piano, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vocals: return "שירה"
        case .drums: return "תופים"
        case .bass: return "בס"
        case .guitar: return "גיטרה"
        case .piano: return "פסנתר"
        case .other: return "כלים אחרים"
        }
    }

    var symbol: String {
        switch self {
        case .vocals: return "music.mic"
        case .drums: return "metronome"
        case .bass: return "waveform.path"
        case .guitar: return "guitars"
        case .piano: return "pianokeys"
        case .other: return "music.quarternote.3"
        }
    }

    /// Order of sources in the htdemucs_6s output tensor.
    static let demucsOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]
}

/// Per-stem gain multipliers (1.0 = untouched). guitar/piano are optional so
/// projects saved by older versions still decode.
struct StemGains: Codable, Hashable {
    var vocals: Double = 1
    var drums: Double = 1
    var bass: Double = 1
    var other: Double = 1
    var guitar: Double? = 1
    var piano: Double? = 1

    subscript(kind: StemKind) -> Double {
        get {
            switch kind {
            case .vocals: return vocals
            case .drums: return drums
            case .bass: return bass
            case .other: return other
            case .guitar: return guitar ?? 1
            case .piano: return piano ?? 1
            }
        }
        set {
            switch kind {
            case .vocals: vocals = newValue
            case .drums: drums = newValue
            case .bass: bass = newValue
            case .other: other = newValue
            case .guitar: guitar = newValue
            case .piano: piano = newValue
            }
        }
    }

    var isNeutral: Bool {
        StemKind.allCases.allSatisfy { abs(self[$0] - 1) < 0.001 }
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

// MARK: - Stem effects

/// An effect added on top of a stem (or the whole clip before separation).
enum EffectKind: String, Codable, CaseIterable, Identifiable {
    case reverb, cathedral, room, delay, echo, distortion, telephone,
         bassBoost, treble, underwater, muffle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reverb: return "ריוורב (אולם)"
        case .cathedral: return "קתדרלה"
        case .room: return "חדר קטן"
        case .delay: return "דיליי"
        case .echo: return "אקו"
        case .distortion: return "דיסטורשן"
        case .telephone: return "טלפון (לו-פיי)"
        case .bassBoost: return "הגברת בס"
        case .treble: return "הגברת גבוהים"
        case .underwater: return "מתחת למים"
        case .muffle: return "עמום / מרוחק"
        }
    }

    var symbol: String {
        switch self {
        case .reverb: return "building.columns"
        case .cathedral: return "building.2"
        case .room: return "square.split.bottomrightquarter"
        case .delay: return "arrow.clockwise"
        case .echo: return "wave.3.right"
        case .distortion: return "bolt.fill"
        case .telephone: return "phone"
        case .bassBoost: return "speaker.wave.3.fill"
        case .treble: return "sparkles"
        case .underwater: return "drop.fill"
        case .muffle: return "cloud.fog"
        }
    }
}

struct StemEffectSetting: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: EffectKind
    /// 0...1 — mapped per effect (wet/dry, gain, cutoff).
    var amount: Double = 0.6
}

/// Named effect combos shown as a preset gallery per stem — each ADDS its
/// chain on top of the stem (never replaces the original instrument).
struct StemEffectPreset: Identifiable {
    let id: String
    let name: String
    let effects: [StemEffectSetting]

    static let all: [StemEffectPreset] = [
        StemEffectPreset(id: "arena", name: "אצטדיון",
                         effects: [.init(kind: .reverb, amount: 0.8), .init(kind: .treble, amount: 0.3)]),
        StemEffectPreset(id: "cathedral", name: "קתדרלה",
                         effects: [.init(kind: .cathedral, amount: 0.8)]),
        StemEffectPreset(id: "room", name: "חדר קטן",
                         effects: [.init(kind: .room, amount: 0.6)]),
        StemEffectPreset(id: "disco", name: "דיסקו",
                         effects: [.init(kind: .treble, amount: 0.5), .init(kind: .echo, amount: 0.35)]),
        StemEffectPreset(id: "lofi", name: "לו-פיי",
                         effects: [.init(kind: .telephone, amount: 0.7)]),
        StemEffectPreset(id: "oldradio", name: "רדיו ישן",
                         effects: [.init(kind: .telephone, amount: 0.5), .init(kind: .distortion, amount: 0.25)]),
        StemEffectPreset(id: "heavy", name: "רוק כבד",
                         effects: [.init(kind: .distortion, amount: 0.5), .init(kind: .bassBoost, amount: 0.4)]),
        StemEffectPreset(id: "dreamy", name: "חלומי",
                         effects: [.init(kind: .reverb, amount: 0.6), .init(kind: .delay, amount: 0.45)]),
        StemEffectPreset(id: "deepbass", name: "באס כבד",
                         effects: [.init(kind: .bassBoost, amount: 0.8)]),
        StemEffectPreset(id: "far", name: "מרוחק",
                         effects: [.init(kind: .muffle, amount: 0.6), .init(kind: .reverb, amount: 0.5)]),
        StemEffectPreset(id: "underwater", name: "מתחת למים",
                         effects: [.init(kind: .underwater, amount: 0.7)]),
        StemEffectPreset(id: "space", name: "חלל",
                         effects: [.init(kind: .cathedral, amount: 0.7), .init(kind: .delay, amount: 0.5), .init(kind: .muffle, amount: 0.3)])
    ]
}
