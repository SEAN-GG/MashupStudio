import Foundation

enum FadeShape: String, Codable, CaseIterable, Hashable {
    case linear
    case equalPower
    case exponential

    var label: String {
        switch self {
        case .linear: return "ליניארי"
        case .equalPower: return "עוצמה שווה"
        case .exponential: return "אקספוננציאלי"
        }
    }

    /// Gain for progress x in 0...1 (0 = silent end of the fade, 1 = full level).
    func gain(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        switch self {
        case .linear: return c
        case .equalPower: return sin(c * .pi / 2)
        case .exponential: return c * c
        }
    }
}

struct ClipFades: Codable, Hashable {
    var fadeIn: Double = 0        // seconds (clip output time)
    var fadeOut: Double = 0
    var shapeIn: FadeShape = .equalPower
    var shapeOut: FadeShape = .equalPower

    /// Combined fade gain at output-local time t for a clip of the given output duration.
    func gain(at t: Double, duration: Double) -> Double {
        var g = 1.0
        if fadeIn > 0.005, t < fadeIn {
            g *= shapeIn.gain(t / fadeIn)
        }
        if fadeOut > 0.005, t > duration - fadeOut {
            g *= shapeOut.gain((duration - t) / fadeOut)
        }
        return min(max(g, 0), 1)
    }
}
