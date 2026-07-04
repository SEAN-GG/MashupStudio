import SwiftUI

extension View {
    /// Attaches a gesture only when `condition` is true (selected clips are
    /// draggable; unselected clips let the timeline pan through).
    @ViewBuilder
    func gestureIf<G: Gesture>(_ condition: Bool, _ gesture: G) -> some View {
        if condition {
            self.gesture(gesture)
        } else {
            self
        }
    }
}

struct ClipView: View {
    @Bindable var model: EditorModel
    let clip: Clip

    @State private var dragStartClip: Clip?
    @State private var trimStartClip: Clip?

    private var isSelected: Bool { model.selectedClipID == clip.id }
    private var width: CGFloat { max(clip.outputDuration * model.pixelsPerSecond, 14) }
    private var color: Color { Theme.clipColor(lane: clip.laneIndex) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(isSelected ? 0.42 : 0.30))

            WaveformShape(model: model, clip: clip, width: width)
                .foregroundStyle(color.opacity(0.95))
                .frame(height: TimelineView.laneHeight - 26)
                .offset(y: 20)

            FadeOverlay(clip: clip, pps: model.pixelsPerSecond)
                .foregroundStyle(Color.black.opacity(0.35))

            // Title + badges
            HStack(spacing: 4) {
                Text(clip.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                Spacer(minLength: 2)
                badges
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.white : color.opacity(0.6),
                        lineWidth: isSelected ? 2 : 1)

            if isSelected {
                trimHandles
            }
        }
        .frame(width: width, height: TimelineView.laneHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedClipID = isSelected ? nil : clip.id
        }
        .gestureIf(isSelected, moveGesture)
        .contextMenu {
            Button {
                model.selectedClipID = clip.id
                model.splitSelectedClipAtPlayhead()
            } label: {
                Label("פיצול בנקודת הנגינה", systemImage: "scissors")
            }
            Button {
                model.duplicateClip(clip.id)
            } label: {
                Label("שכפול", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                model.deleteClip(clip.id)
            } label: {
                Label("מחיקה", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        let asset = AssetLibrary.shared.asset(clip.assetID)
        HStack(spacing: 3) {
            if let bpm = asset?.bpm {
                badge(String(format: "%.0f", clip.effectiveBPM(assetBPM: bpm, at: 0)))
            }
            if let key = asset?.key {
                badge(clip.effectiveKey(assetKey: key, at: 0)
                    .displayName(style: AppSettings.shared.keyNotation))
            }
            if asset?.stems.isReady == true {
                Image(systemName: "square.split.2x2")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if !clip.rateCurve.isTrivial || !clip.pitchCurve.isTrivial {
                Image(systemName: "dial.medium")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(Color.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
    }

    // MARK: - Move (horizontal = time, vertical = lane)

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStartClip == nil {
                    dragStartClip = clip
                    model.beginGesture()
                }
                guard let original = dragStartClip else { return }
                var moved = original
                let proposedStart = original.startTime + value.translation.width / model.pixelsPerSecond
                moved.startTime = model.snappedTime(proposedStart, for: original)
                let laneDelta = Int((value.translation.height / (TimelineView.laneHeight + TimelineView.laneGap)).rounded())
                moved.laneIndex = min(max(original.laneIndex + laneDelta, 0), model.project.lanes.count)
                model.previewClip(moved)
            }
            .onEnded { _ in
                dragStartClip = nil
                model.endGesture()
            }
    }

    // MARK: - Trim handles

    private var trimHandles: some View {
        HStack {
            handle(system: "chevron.compact.left")
                .gesture(trimGesture(isLeft: true))
            Spacer()
            handle(system: "chevron.compact.right")
                .gesture(trimGesture(isLeft: false))
        }
    }

    private func handle(system: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.white.opacity(0.9))
            .frame(width: 14, height: 40)
            .overlay(Image(systemName: system).font(.caption2).foregroundStyle(.black))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -8))
    }

    private func trimGesture(isLeft: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if trimStartClip == nil {
                    trimStartClip = clip
                    model.beginGesture()
                }
                guard let original = trimStartClip,
                      let asset = AssetLibrary.shared.asset(clip.assetID) else { return }
                var trimmed = original
                let deltaT = value.translation.width / model.pixelsPerSecond
                if isLeft {
                    let target = model.snappedTime(original.startTime + deltaT, for: original)
                    if target > original.startTime {
                        trimmed.trimLeft(toTimelineTime: target)
                    } else {
                        // Extend left: recover earlier source material if available.
                        let extendBy = min(original.startTime - target,
                                           original.sourceStart / max(original.rate(at: 0), 0.05))
                        if extendBy > 0.01 {
                            let sourceRecovered = extendBy * original.rate(at: 0)
                            trimmed.startTime = original.startTime - extendBy
                            trimmed.sourceStart = original.sourceStart - sourceRecovered
                            trimmed.sourceDuration = original.sourceDuration + sourceRecovered
                            trimmed.rateCurve.shift(by: extendBy)
                            trimmed.pitchCurve.shift(by: extendBy)
                        }
                    }
                } else {
                    let target = model.snappedTime(original.endTime + deltaT, for: original)
                    trimmed.trimRight(toTimelineTime: target, assetDuration: asset.duration)
                }
                model.previewClip(trimmed)
            }
            .onEnded { _ in
                trimStartClip = nil
                model.endGesture()
            }
    }
}

// MARK: - Waveform

private struct WaveformShape: View {
    let model: EditorModel
    let clip: Clip
    let width: CGFloat

    var body: some View {
        // Read observable state in body so Observation tracks it.
        let pps = model.pixelsPerSecond
        let peaks = AssetLibrary.shared.peaks(for: clip.assetID)
        Canvas { context, size in
            guard let peaks else {
                // Analysis not done yet: placeholder line.
                let mid = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: mid))
                path.addLine(to: CGPoint(x: size.width, y: mid))
                context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1)
                return
            }
            let step: CGFloat = 2
            let mid = size.height / 2
            var x: CGFloat = 0
            var path = Path()
            while x < size.width {
                let outputT = Double(x) / pps
                let sourceT = clip.sourceStart + clip.sourceOffset(atOutputTime: outputT)
                let bucket = peaks.bucketIndex(forTime: sourceT)
                guard bucket < peaks.peaks.count else { break }
                let peak = CGFloat(peaks.peaks[bucket])
                let rms = CGFloat(peaks.rms[bucket])
                let peakH = max(peak * (size.height * 0.48), 0.7)
                let rmsH = max(rms * (size.height * 0.48), 0.5)
                path.move(to: CGPoint(x: x, y: mid - peakH))
                path.addLine(to: CGPoint(x: x, y: mid + peakH))
                _ = rmsH
                x += step
            }
            context.stroke(path, with: .style(.foreground), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Fade triangles

private struct FadeOverlay: View {
    let clip: Clip
    let pps: Double

    var body: some View {
        Canvas { context, size in
            if clip.fades.fadeIn > 0.01 {
                let w = min(clip.fades.fadeIn * pps, Double(size.width))
                var path = Path()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .style(.foreground))
            }
            if clip.fades.fadeOut > 0.01 {
                let w = min(clip.fades.fadeOut * pps, Double(size.width))
                var path = Path()
                path.move(to: CGPoint(x: size.width, y: 0))
                path.addLine(to: CGPoint(x: size.width - w, y: 0))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .style(.foreground))
            }
        }
        .allowsHitTesting(false)
    }
}
