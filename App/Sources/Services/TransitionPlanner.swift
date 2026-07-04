import Foundation

/// Rule-based transition builder between two clips ("the app helps, the user
/// keeps control"): tempo matching via rate ramps, key matching via pitch
/// shift, beat-aligned overlap with crossfades, and stem patterns implemented
/// by splitting clips.
enum TransitionPlanner {

    enum TempoStrategy: String, CaseIterable, Identifiable {
        case none
        case rampOutgoing     // A ramps into B's tempo before the switch
        case rampIncoming     // B starts at A's tempo and relaxes to its own
        case meetMiddle       // both meet at the average during the overlap

        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "בלי שינוי קצב"
            case .rampOutgoing: return "השיר היוצא מאיץ/מאט אל הנכנס"
            case .rampIncoming: return "השיר הנכנס מתחיל בקצב היוצא"
            case .meetMiddle: return "נפגשים באמצע"
            }
        }
    }

    enum StemPattern: String, CaseIterable, Identifiable {
        case none
        case vocalsOutgoingOff    // outgoing tail becomes instrumental
        case drumsIncomingOff     // incoming head enters without drums
        case swapDrums            // outgoing keeps only drums, incoming enters without them

        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "בלי תבנית"
            case .vocalsOutgoingOff: return "היוצא בלי שירה בסוף"
            case .drumsIncomingOff: return "הנכנס בלי תופים בהתחלה"
            case .swapDrums: return "החלפת תופים (היוצא רק תופים, הנכנס בלעדיהם)"
            }
        }
    }

    struct Options {
        var tempoStrategy: TempoStrategy = .rampOutgoing
        var tempoRampSeconds: Double = 8
        var matchKey: Bool = true
        var overlapSeconds: Double = 8
        var crossfade: Bool = true
        var snapToBeat: Bool = true
        var stemPattern: StemPattern = .none
    }

    struct Preview {
        var bpmA: Double?
        var bpmB: Double?
        var keyA: MusicalKey?
        var keyB: MusicalKey?
        var suggestedSemitones: Int
        var keysCompatible: Bool
    }

    @MainActor
    static func preview(project: MixProject, clipAID: UUID, clipBID: UUID) -> Preview? {
        guard let clipA = project.clip(withID: clipAID),
              let clipB = project.clip(withID: clipBID),
              let assetA = AssetLibrary.shared.asset(clipA.assetID),
              let assetB = AssetLibrary.shared.asset(clipB.assetID) else { return nil }

        var semitones = 0
        var compatible = true
        if let keyA = assetA.key, let keyB = assetB.key {
            let effectiveA = clipA.effectiveKey(assetKey: keyA, at: max(clipA.outputDuration - 0.5, 0))
            compatible = keyB.isCompatible(with: effectiveA)
            semitones = keyB.smallestShiftForCompatibility(with: effectiveA)
        }
        return Preview(bpmA: assetA.bpm, bpmB: assetB.bpm,
                       keyA: assetA.key, keyB: assetB.key,
                       suggestedSemitones: semitones,
                       keysCompatible: compatible)
    }

    /// Applies the transition, mutating a copy of the project. Returns the new
    /// project, or nil when the input is invalid.
    @MainActor
    static func apply(project: MixProject, clipAID: UUID, clipBID: UUID, options: Options) -> MixProject? {
        var result = project
        guard var clipA = result.clip(withID: clipAID),
              var clipB = result.clip(withID: clipBID),
              let assetA = AssetLibrary.shared.asset(clipA.assetID),
              let assetB = AssetLibrary.shared.asset(clipB.assetID) else { return nil }

        let bpmA = assetA.bpm
        let bpmB = assetB.bpm
        let overlap = max(options.overlapSeconds, 0.5)

        // 1. Tempo strategy (rate automation).
        if options.tempoStrategy != .none, let bpmA, let bpmB, bpmA > 20, bpmB > 20 {
            switch options.tempoStrategy {
            case .rampOutgoing:
                let currentEndRate = clipA.rate(at: clipA.outputDuration)
                let targetRate = clampRate(bpmB / bpmA)
                if abs(targetRate - currentEndRate) > 0.005 {
                    let rampStart = max(clipA.outputDuration - options.tempoRampSeconds, 0)
                    clipA.rateCurve.setRamp(at: rampStart, duration: options.tempoRampSeconds, to: targetRate)
                }
            case .rampIncoming:
                let endRateA = clipA.rate(at: clipA.outputDuration)
                let effectiveBPMA = bpmA * endRateA
                let startRate = clampRate(effectiveBPMA / bpmB)
                if abs(startRate - 1) > 0.005 {
                    clipB.rateCurve.setInstantChange(at: 0, to: startRate)
                    clipB.rateCurve.setRamp(at: overlap, duration: options.tempoRampSeconds, to: 1.0)
                }
            case .meetMiddle:
                let target = (bpmA + bpmB) / 2
                let rateA = clampRate(target / bpmA)
                let rateB = clampRate(target / bpmB)
                let rampStartA = max(clipA.outputDuration - options.tempoRampSeconds, 0)
                clipA.rateCurve.setRamp(at: rampStartA, duration: options.tempoRampSeconds, to: rateA)
                clipB.rateCurve.setInstantChange(at: 0, to: rateB)
                clipB.rateCurve.setRamp(at: overlap, duration: options.tempoRampSeconds, to: 1.0)
            case .none:
                break
            }
        }

        // 2. Key matching (instant shift on the incoming clip).
        if options.matchKey, let keyA = assetA.key, let keyB = assetB.key {
            let effectiveA = clipA.effectiveKey(assetKey: keyA, at: max(clipA.outputDuration - 0.5, 0))
            let shift = keyB.smallestShiftForCompatibility(with: effectiveA)
            if shift != 0 {
                clipB.pitchCurve.setInstantChange(at: 0, to: Double(shift * 100))
            }
        }

        // 3. Position B to overlap A's (possibly re-stretched) tail.
        let newAEnd = clipA.startTime + clipA.outputDuration
        var targetStart = max(newAEnd - overlap, 0)
        if options.snapToBeat, let grid = assetA.beatGrid, !grid.isEmpty {
            targetStart = snapToBeat(timeline: targetStart, clip: clipA, grid: grid) ?? targetStart
        }
        clipB.startTime = targetStart
        if clipB.laneIndex == clipA.laneIndex {
            clipB.laneIndex = clipA.laneIndex + 1
        }

        // 4. Crossfade.
        if options.crossfade {
            let actualOverlap = max(newAEnd - clipB.startTime, 0.5)
            clipA.fades.fadeOut = actualOverlap
            clipA.fades.shapeOut = .equalPower
            clipB.fades.fadeIn = actualOverlap
            clipB.fades.shapeIn = .equalPower
        }

        result.update(clipA)
        result.update(clipB)

        // 5. Stem pattern via clip splitting (per-piece stem gains).
        let overlapStart = clipB.startTime
        let overlapEnd = min(newAEnd, clipB.startTime + clipB.outputDuration)
        if options.stemPattern != .none {
            switch options.stemPattern {
            case .vocalsOutgoingOff:
                muteStemOnTail(&result, clipID: clipA.id, from: overlapStart) { $0.vocals = 0 }
            case .drumsIncomingOff:
                muteStemOnHead(&result, clipID: clipB.id, until: overlapEnd) { $0.drums = 0 }
            case .swapDrums:
                muteStemOnTail(&result, clipID: clipA.id, from: overlapStart) {
                    $0.vocals = 0; $0.other = 0.25; $0.bass = 0.4
                }
                muteStemOnHead(&result, clipID: clipB.id, until: overlapEnd) { $0.drums = 0 }
            case .none:
                break
            }
        }

        result.normalizeLanes()
        return result
    }

    private static func clampRate(_ r: Double) -> Double {
        min(max(r, Clip.minRate), Clip.maxRate)
    }

    /// Snaps a timeline moment to the nearest beat of clip A's grid (grid times
    /// are in asset seconds; map through the clip's time warp).
    private static func snapToBeat(timeline: Double, clip: Clip, grid: [Double]) -> Double? {
        var bestTime: Double?
        var bestDistance = Double.infinity
        for beat in grid {
            let sourceOffset = beat - clip.sourceStart
            guard sourceOffset >= 0, sourceOffset <= clip.sourceDuration else { continue }
            let t = clip.startTime + clip.outputTime(forSourceOffset: sourceOffset)
            let d = abs(t - timeline)
            if d < bestDistance {
                bestDistance = d
                bestTime = t
            }
        }
        guard let bestTime, bestDistance < 2.0 else { return nil }
        return bestTime
    }

    private static func muteStemOnTail(_ project: inout MixProject, clipID: UUID,
                                       from timelineTime: Double,
                                       mutate: (inout StemGains) -> Void) {
        guard let clip = project.clip(withID: clipID) else { return }
        if let (left, right) = clip.split(atTimelineTime: timelineTime) {
            var tail = right
            mutate(&tail.stemGains)
            project.remove(clipID: clip.id)
            project.clips.append(left)
            project.clips.append(tail)
        } else if clip.contains(timelineTime: timelineTime) || timelineTime <= clip.startTime {
            var whole = clip
            mutate(&whole.stemGains)
            project.update(whole)
        }
    }

    private static func muteStemOnHead(_ project: inout MixProject, clipID: UUID,
                                       until timelineTime: Double,
                                       mutate: (inout StemGains) -> Void) {
        guard let clip = project.clip(withID: clipID) else { return }
        if let (left, right) = clip.split(atTimelineTime: timelineTime) {
            var head = left
            mutate(&head.stemGains)
            project.remove(clipID: clip.id)
            project.clips.append(head)
            project.clips.append(right)
        } else if clip.contains(timelineTime: timelineTime) || timelineTime >= clip.endTime {
            var whole = clip
            mutate(&whole.stemGains)
            project.update(whole)
        }
    }
}
