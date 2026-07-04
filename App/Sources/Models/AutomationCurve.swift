import Foundation

/// Shape of the transition from the previous point INTO this point.
enum TransitionShape: String, Codable, Hashable {
    case step      // value jumps at this point's time
    case linear    // value ramps linearly from the previous point
}

struct AutomationPoint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: Double          // seconds, clip-output-local
    var value: Double
    var shapeIn: TransitionShape = .step

    enum CodingKeys: String, CodingKey { case id, time, value, shapeIn }
}

/// Piecewise automation curve. Before the first point the value is
/// `defaultValue` (a .step first point jumps at its time; a .linear first point
/// holds its own value since there is nothing to ramp from). After the last
/// point the value holds. With no points, `defaultValue` everywhere.
struct AutomationCurve: Codable, Hashable {
    var points: [AutomationPoint] = []
    var defaultValue: Double

    init(defaultValue: Double) {
        self.defaultValue = defaultValue
    }

    var isTrivial: Bool {
        points.allSatisfy { abs($0.value - defaultValue) < 0.0001 }
    }

    mutating func normalize() {
        points.sort { $0.time < $1.time }
    }

    /// Value held before the first point.
    private var leadInValue: Double {
        guard let first = points.first else { return defaultValue }
        return first.shapeIn == .step ? defaultValue : first.value
    }

    func value(at t: Double) -> Double {
        guard !points.isEmpty else { return defaultValue }
        if t < points[0].time { return leadInValue }
        var previous = points[0]
        for point in points.dropFirst() {
            if t < point.time {
                switch point.shapeIn {
                case .step:
                    return previous.value
                case .linear:
                    let span = point.time - previous.time
                    guard span > 0 else { return point.value }
                    let f = (t - previous.time) / span
                    return previous.value + (point.value - previous.value) * f
                }
            }
            previous = point
        }
        return points[points.count - 1].value
    }

    /// ∫ value dt over [0, t]. Assumes t >= 0. Used for playback-rate curves,
    /// where the integral is "source seconds consumed after t output seconds".
    func integral(upTo t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard !points.isEmpty else { return defaultValue * t }
        var total = 0.0
        var cursor = 0.0
        var currentValue = leadInValue

        for point in points {
            let segmentEnd = min(point.time, t)
            if segmentEnd > cursor {
                switch point.shapeIn {
                case .step:
                    total += currentValue * (segmentEnd - cursor)
                case .linear:
                    // linear from currentValue @cursor→point.value @point.time
                    let fullSpan = point.time - cursor
                    if fullSpan <= 0 {
                        total += currentValue * (segmentEnd - cursor)
                    } else {
                        let vEnd = currentValue + (point.value - currentValue) * ((segmentEnd - cursor) / fullSpan)
                        total += (currentValue + vEnd) / 2 * (segmentEnd - cursor)
                    }
                }
            }
            if t <= point.time {
                return total
            }
            cursor = max(cursor, point.time)
            currentValue = point.value
        }
        if t > cursor {
            total += currentValue * (t - cursor)
        }
        return total
    }

    /// Inverse of `integral`: smallest t such that integral(upTo: t) == target.
    /// Requires all values > 0 (validated at write time for rate curves).
    func timeWhereIntegral(equals target: Double) -> Double {
        guard target > 0 else { return 0 }
        guard !points.isEmpty else { return target / max(defaultValue, 0.001) }

        var accumulated = 0.0
        var cursor = 0.0
        var currentValue = max(leadInValue, 0.001)

        func solveConstant(_ v: Double, remaining: Double) -> Double {
            remaining / max(v, 0.001)
        }
        func solveLinear(v0: Double, v1: Double, span: Double, remaining: Double) -> Double {
            let k = (v1 - v0) / span
            if abs(k) < 1e-9 { return solveConstant(v0, remaining: remaining) }
            let disc = v0 * v0 + 2 * k * remaining
            guard disc >= 0 else { return span }
            let tau = (-v0 + disc.squareRoot()) / k
            return min(max(tau, 0), span * 4)
        }

        for point in points {
            let span = point.time - cursor
            if span > 0 {
                let segmentArea: Double
                switch point.shapeIn {
                case .step:
                    segmentArea = currentValue * span
                case .linear:
                    segmentArea = (currentValue + point.value) / 2 * span
                }
                if accumulated + segmentArea >= target {
                    let remaining = target - accumulated
                    switch point.shapeIn {
                    case .step:
                        return cursor + solveConstant(currentValue, remaining: remaining)
                    case .linear:
                        return cursor + solveLinear(v0: currentValue, v1: point.value, span: span, remaining: remaining)
                    }
                }
                accumulated += segmentArea
            }
            cursor = max(cursor, point.time)
            currentValue = max(point.value, 0.001)
        }
        return cursor + (target - accumulated) / currentValue
    }

    // MARK: - Editing

    /// Replaces everything from `time` onward with an instant jump to `value`.
    mutating func setInstantChange(at time: Double, to value: Double) {
        points.removeAll { $0.time >= time - 0.0005 }
        if points.isEmpty && abs(value - defaultValue) < 0.0001 && time < 0.0005 {
            return
        }
        points.append(AutomationPoint(time: max(0, time), value: value, shapeIn: .step))
        normalize()
    }

    /// Replaces everything from `time` onward with a linear ramp to `value` over `duration`.
    mutating func setRamp(at time: Double, duration: Double, to value: Double) {
        let startValue = self.value(at: max(0, time - 0.001))
        points.removeAll { $0.time >= time - 0.0005 }
        points.append(AutomationPoint(time: max(0, time), value: startValue, shapeIn: .step))
        points.append(AutomationPoint(time: max(0, time) + max(0.05, duration), value: value, shapeIn: .linear))
        normalize()
    }

    mutating func removePoint(id: UUID) {
        points.removeAll { $0.id == id }
    }

    mutating func reset() {
        points.removeAll()
    }

    /// Splits at output-local time `t`; returns the curve for the right part,
    /// re-based so the split moment becomes time 0. Mutates self into the left part.
    mutating func split(at t: Double) -> AutomationCurve {
        var right = AutomationCurve(defaultValue: defaultValue)
        let valueAtSplit = value(at: t)
        var rightPoints: [AutomationPoint] = [AutomationPoint(time: 0, value: valueAtSplit, shapeIn: .step)]
        for p in points where p.time > t {
            var moved = p
            moved.time = p.time - t
            moved.id = UUID()
            rightPoints.append(moved)
        }
        right.points = rightPoints
        right.normalize()
        let hadLaterPoints = points.contains { $0.time > t }
        points.removeAll { $0.time > t }
        if hadLaterPoints {
            // Preserve any in-progress ramp value at the cut for the left part.
            points.append(AutomationPoint(time: t, value: valueAtSplit, shapeIn: .linear))
            normalize()
        }
        return right
    }

    /// Shifts all points in time (for trims from the left).
    mutating func shift(by delta: Double) {
        let anchor = value(at: max(-delta, 0))
        var shifted: [AutomationPoint] = []
        for p in points {
            let t = p.time + delta
            if t >= 0 { var m = p; m.time = t; shifted.append(m) }
        }
        if delta < 0 {
            // If the value at the new start differs from the default (e.g. we
            // trimmed into or past a change), anchor it explicitly at t=0.
            let needsAnchor = shifted.first.map { $0.time > 0.0005 } ?? true
            if needsAnchor && abs(anchor - defaultValue) > 1e-9 {
                shifted.insert(AutomationPoint(time: 0, value: anchor, shapeIn: .step), at: 0)
            }
        }
        points = shifted
        normalize()
    }
}
