import Foundation

/// A clip on the timeline: a window into an audio asset, placed on a lane,
/// with gain, fades, per-stem gains, and tempo (rate) / pitch automation.
///
/// Time model:
/// - "source time": seconds within the audio file.
/// - "output time": seconds of audible clip playback (clip-local, 0 at clip start).
/// - The playback-rate curve maps between them: source consumed after t output
///   seconds = ∫ rate. Timeline position of output time t = startTime + t.
struct Clip: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var assetID: UUID
    var name: String
    var laneIndex: Int
    var startTime: Double            // timeline seconds
    var sourceStart: Double          // seconds into the asset
    var sourceDuration: Double       // seconds of source material used
    var gain: Double = 1.0           // 0...2
    var fades = ClipFades()
    var stemGains = StemGains()
    var rateCurve = AutomationCurve(defaultValue: 1.0)     // playback rate (tempo stretch)
    var pitchCurve = AutomationCurve(defaultValue: 0.0)    // cents
    var varispeed: Bool = false      // speed change also shifts pitch (classic vinyl-style)

    // Newer fields are optional so projects saved by older builds still decode.
    /// Gradual overall-volume automation (multiplies gain × fades).
    var volumeCurve: AutomationCurve? = nil
    /// Gradual per-stem volume automation (multiplies the stem fader).
    var stemCurves: [StemKind: AutomationCurve]? = nil
    /// Effects added per stem (before separation they apply to the whole clip).
    var stemEffects: [StemKind: [StemEffectSetting]]? = nil

    static let minRate = 0.25
    static let maxRate = 4.0

    // MARK: - Time mapping

    /// Playback rate at output-local time t (clamped to safe bounds).
    func rate(at t: Double) -> Double {
        min(max(rateCurve.value(at: t), Clip.minRate), Clip.maxRate)
    }

    /// Pitch shift in cents at output-local time t. In varispeed mode, the rate
    /// itself changes pitch by 1200·log2(rate) on top of the explicit pitch curve.
    func pitchCents(at t: Double) -> Double {
        var cents = pitchCurve.value(at: t)
        if varispeed {
            cents += 1200 * log2(rate(at: t))
        }
        return min(max(cents, -2400), 2400)
    }

    /// Audible duration of the clip on the timeline.
    var outputDuration: Double {
        if rateCurve.isTrivial {
            let r = min(max(rateCurve.defaultValue, Clip.minRate), Clip.maxRate)
            return sourceDuration / r
        }
        return rateCurve.timeWhereIntegral(equals: sourceDuration)
    }

    var endTime: Double { startTime + outputDuration }

    /// Source seconds consumed after t output-local seconds.
    func sourceOffset(atOutputTime t: Double) -> Double {
        guard t > 0 else { return 0 }
        let consumed = rateCurve.isTrivial
            ? min(max(rateCurve.defaultValue, Clip.minRate), Clip.maxRate) * t
            : rateCurve.integral(upTo: t)
        return min(consumed, sourceDuration)
    }

    /// Output-local time at which the given source offset is reached.
    func outputTime(forSourceOffset s: Double) -> Double {
        guard s > 0 else { return 0 }
        if rateCurve.isTrivial {
            let r = min(max(rateCurve.defaultValue, Clip.minRate), Clip.maxRate)
            return s / r
        }
        return rateCurve.timeWhereIntegral(equals: min(s, sourceDuration))
    }

    func contains(timelineTime t: Double) -> Bool {
        t >= startTime && t < endTime
    }

    // MARK: - Edit operations

    /// Splits the clip at a timeline time. Returns nil if the time isn't inside.
    func split(atTimelineTime t: Double) -> (left: Clip, right: Clip)? {
        let localT = t - startTime
        guard localT > 0.05, localT < outputDuration - 0.05 else { return nil }
        let consumedSource = sourceOffset(atOutputTime: localT)

        var left = self
        var right = self
        right.id = UUID()

        var leftRate = rateCurve
        let rightRate = leftRate.split(at: localT)
        var leftPitch = pitchCurve
        let rightPitch = leftPitch.split(at: localT)

        left.sourceDuration = consumedSource
        left.rateCurve = leftRate
        left.pitchCurve = leftPitch
        left.fades.fadeOut = 0

        right.startTime = t
        right.sourceStart = sourceStart + consumedSource
        right.sourceDuration = sourceDuration - consumedSource
        right.rateCurve = rightRate
        right.pitchCurve = rightPitch
        right.fades.fadeIn = 0

        if var leftVolume = volumeCurve {
            right.volumeCurve = leftVolume.split(at: localT)
            left.volumeCurve = leftVolume
        }
        if let curves = stemCurves {
            var leftMap: [StemKind: AutomationCurve] = [:]
            var rightMap: [StemKind: AutomationCurve] = [:]
            for (kind, curve) in curves {
                var l = curve
                rightMap[kind] = l.split(at: localT)
                leftMap[kind] = l
            }
            left.stemCurves = leftMap
            right.stemCurves = rightMap
        }
        return (left, right)
    }

    /// Trims the clip's left edge to a new timeline start (moves both startTime and sourceStart).
    mutating func trimLeft(toTimelineTime newStart: Double) {
        let localT = newStart - startTime
        guard localT > 0 else { return }
        let maxTrim = outputDuration - 0.1
        let clamped = min(localT, maxTrim)
        let consumed = sourceOffset(atOutputTime: clamped)
        sourceStart += consumed
        sourceDuration -= consumed
        startTime += clamped
        rateCurve.shift(by: -clamped)
        pitchCurve.shift(by: -clamped)
        volumeCurve?.shift(by: -clamped)
        if let curves = stemCurves {
            var shifted: [StemKind: AutomationCurve] = [:]
            for (kind, curve) in curves {
                var c = curve
                c.shift(by: -clamped)
                shifted[kind] = c
            }
            stemCurves = shifted
        }
        fades.fadeIn = min(fades.fadeIn, max(0, outputDuration - 0.1))
    }

    /// Trims the clip's right edge to a new timeline end.
    mutating func trimRight(toTimelineTime newEnd: Double, assetDuration: Double) {
        let localT = newEnd - startTime
        let desired = min(max(localT, 0.1), maxOutputDuration(assetDuration: assetDuration))
        sourceDuration = sourceOffset(atOutputTime: desired)
        fades.fadeOut = min(fades.fadeOut, max(0, outputDuration - 0.1))
    }

    /// Longest possible output duration given how much source material remains.
    func maxOutputDuration(assetDuration: Double) -> Double {
        let remainingSource = max(assetDuration - sourceStart, 0.1)
        var probe = self
        probe.sourceDuration = remainingSource
        return probe.outputDuration
    }

    /// Combined gain (clip gain × fades × volume automation) at output-local time t.
    func combinedGain(at t: Double) -> Double {
        var g = gain * fades.gain(at: t, duration: outputDuration)
        if let curve = volumeCurve {
            g *= min(max(curve.value(at: t), 0), 2)
        }
        return g
    }

    /// Effective per-stem gain (fader × per-stem automation) at output time t.
    func stemGain(_ kind: StemKind, at t: Double) -> Double {
        var g = stemGains[kind]
        if let curve = stemCurves?[kind] {
            g *= min(max(curve.value(at: t), 0), 2)
        }
        return min(max(g, 0), 2)
    }

    /// True when any stem control differs from passthrough.
    var hasStemWork: Bool {
        !stemGains.isNeutral
            || stemCurves?.values.contains { !$0.isTrivial } == true
            || stemEffects?.values.contains { !$0.isEmpty } == true
    }

    /// Effects for one stem (empty when none).
    func effects(for kind: StemKind) -> [StemEffectSetting] {
        stemEffects?[kind] ?? []
    }

    /// All effects across stems (used before separation, applied to the whole clip).
    var allEffects: [StemEffectSetting] {
        guard let stemEffects else { return [] }
        return StemKind.allCases.flatMap { stemEffects[$0] ?? [] }
    }

    mutating func setEffects(_ effects: [StemEffectSetting], for kind: StemKind) {
        var map = stemEffects ?? [:]
        map[kind] = effects.isEmpty ? nil : effects
        stemEffects = map.isEmpty ? nil : map
    }

    mutating func modifyStemCurve(_ kind: StemKind, _ change: (inout AutomationCurve) -> Void) {
        var map = stemCurves ?? [:]
        var curve = map[kind] ?? AutomationCurve(defaultValue: 1.0)
        change(&curve)
        map[kind] = curve
        stemCurves = map
    }

    mutating func modifyVolumeCurve(_ change: (inout AutomationCurve) -> Void) {
        var curve = volumeCurve ?? AutomationCurve(defaultValue: 1.0)
        change(&curve)
        volumeCurve = curve
    }

    /// Effective BPM at output time t, given the asset's detected BPM.
    func effectiveBPM(assetBPM: Double, at t: Double) -> Double {
        assetBPM * rate(at: t)
    }

    /// Effective key at output time t given the asset's key (rounded to nearest semitone).
    func effectiveKey(assetKey: MusicalKey, at t: Double) -> MusicalKey {
        let semitones = Int((pitchCents(at: t) / 100).rounded())
        return assetKey.transposed(by: semitones)
    }
}
