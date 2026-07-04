import SwiftUI

struct TimelineView: View {
    @Bindable var model: EditorModel

    static let laneHeight: CGFloat = 88
    static let laneGap: CGFloat = 6
    static let rulerHeight: CGFloat = 30
    static let headerWidth: CGFloat = 40

    @State private var panStartOffset: CGPoint?
    @State private var zoomStartPPS: Double?

    var body: some View {
        GeometryReader { geo in
            let timelineWidth = geo.size.width - Self.headerWidth
            ZStack(alignment: .topLeading) {
                Theme.background

                // Lanes + clips (scrolls with offset)
                VStack(spacing: Self.laneGap) {
                    ForEach(Array(model.project.lanes.enumerated()), id: \.element.id) { index, lane in
                        LaneRow(model: model, laneIndex: index, lane: lane, timelineWidth: timelineWidth)
                            .frame(height: Self.laneHeight)
                    }
                    Spacer(minLength: 40)
                }
                .padding(.top, Self.rulerHeight + 4)
                .offset(y: -model.contentOffsetY)

                // Ruler
                RulerView(model: model, width: geo.size.width)
                    .frame(height: Self.rulerHeight)
                    .background(Theme.surface)

                // Playhead
                PlayheadLine(model: model)
                    .allowsHitTesting(false)

                if model.project.clips.isEmpty {
                    emptyHint
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .gesture(panGesture.simultaneously(with: zoomGesture))
            .onTapGesture {
                model.selectedClipID = nil
            }
            .onChange(of: model.engine.playhead) { _, newValue in
                guard model.engine.isPlaying, AppSettings.shared.followPlayhead else { return }
                let x = newValue * model.pixelsPerSecond - model.contentOffsetX
                if x > timelineWidth * 0.72 || x < 0 {
                    model.contentOffsetX = max(0, newValue * model.pixelsPerSecond - timelineWidth * 0.3)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text("הוסף שירים עם כפתור ה-+ למעלה")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
        .allowsHitTesting(false)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if panStartOffset == nil {
                    panStartOffset = CGPoint(x: model.contentOffsetX, y: model.contentOffsetY)
                }
                guard let start = panStartOffset else { return }
                model.contentOffsetX = max(0, Double(start.x - value.translation.width))
                let maxY = max(0, Double(model.project.lanes.count) * Double(Self.laneHeight + Self.laneGap) - 200)
                model.contentOffsetY = min(max(0, Double(start.y - value.translation.height)), maxY)
            }
            .onEnded { _ in
                panStartOffset = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStartPPS == nil { zoomStartPPS = model.pixelsPerSecond }
                guard let startPPS = zoomStartPPS else { return }
                let newPPS = min(max(startPPS * value.magnification, 2), 160)
                // Keep the time under the gesture anchor fixed.
                let anchorX = value.startLocation.x - Self.headerWidth
                let anchorTime = (model.contentOffsetX + anchorX) / model.pixelsPerSecond
                model.pixelsPerSecond = newPPS
                model.contentOffsetX = max(0, anchorTime * newPPS - anchorX)
            }
            .onEnded { _ in
                zoomStartPPS = nil
            }
    }
}

// MARK: - Ruler

private struct RulerView: View {
    @Bindable var model: EditorModel
    let width: CGFloat

    var body: some View {
        // Read observable state in body (not inside the Canvas closure) so
        // Observation invalidates this view when it changes.
        let pps = model.pixelsPerSecond
        let offsetX = model.contentOffsetX
        Canvas { context, size in
            let headerWidth = TimelineView.headerWidth

            // Choose tick interval by zoom level.
            let target = 70.0 / pps
            let intervals: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120]
            let interval = intervals.first { $0 >= target } ?? 120
            let firstTick = (offsetX / pps / interval).rounded(.down) * interval
            var t = max(firstTick, 0)
            while t * pps - offsetX < size.width - headerWidth {
                let x = headerWidth + t * pps - offsetX
                if x >= headerWidth {
                    let line = Path { p in
                        p.move(to: CGPoint(x: x, y: size.height - 8))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(line, with: .color(Theme.ruler), lineWidth: 1)
                    let label = Text(TimeFormat.short(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 9), anchor: .topLeading)
                }
                t += interval
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = (model.contentOffsetX + value.location.x - TimelineView.headerWidth) / model.pixelsPerSecond
                    model.engine.seek(to: max(0, time))
                }
        )
    }
}

// MARK: - Playhead

private struct PlayheadLine: View {
    @Bindable var model: EditorModel

    var body: some View {
        let x = TimelineView.headerWidth + model.engine.playhead * model.pixelsPerSecond - model.contentOffsetX
        return Group {
            if x >= TimelineView.headerWidth - 1 {
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.playhead)
                        .offset(y: 4)
                    Rectangle()
                        .fill(Theme.playhead)
                        .frame(width: 1.5)
                }
                .frame(maxHeight: .infinity)
                .offset(x: x - 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Lane row

private struct LaneRow: View {
    @Bindable var model: EditorModel
    let laneIndex: Int
    let lane: Lane
    let timelineWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Lane header: mute / solo
            VStack(spacing: 6) {
                Button {
                    model.mutateWithoutReschedule { $0.lanes[laneIndex].isMuted.toggle() }
                } label: {
                    Text("M")
                        .font(.caption2.bold())
                        .frame(width: 24, height: 24)
                        .background(lane.isMuted ? Color.orange.opacity(0.85) : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(lane.isMuted ? .black : Theme.textSecondary)
                }
                Button {
                    model.mutateWithoutReschedule { $0.lanes[laneIndex].isSoloed.toggle() }
                } label: {
                    Text("S")
                        .font(.caption2.bold())
                        .frame(width: 24, height: 24)
                        .background(lane.isSoloed ? Theme.accent : Theme.surfaceRaised,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(lane.isSoloed ? .black : Theme.textSecondary)
                }
            }
            .frame(width: TimelineView.headerWidth)

            // Clips
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface.opacity(0.55))
                ForEach(model.project.clips(onLane: laneIndex)) { clip in
                    ClipView(model: model, clip: clip)
                        .offset(x: clip.startTime * model.pixelsPerSecond - model.contentOffsetX)
                }
            }
            .clipped()
        }
    }
}
