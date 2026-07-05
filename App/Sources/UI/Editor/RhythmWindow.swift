import SwiftUI

/// Live rhythm strip: effective BPM at the playhead, a 4-dot beat indicator
/// that pulses in sync with the detected beat grid, and the current key.
struct RhythmWindow: View {
    @Bindable var model: EditorModel

    private struct BeatInfo {
        var bpm: Double
        var beatInBar: Int
        var phase: Double      // 0 at the beat, →1 just before the next
        var key: MusicalKey?
    }

    var body: some View {
        let info = currentInfo()
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "metronome.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(info.map { String(format: "%.1f BPM", $0.bpm) } ?? "— BPM")
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }

            beatDots(info: info)

            Spacer(minLength: 4)

            if let key = info?.key {
                Text(key.displayName(style: AppSettings.shared.keyNotation))
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Theme.surface.opacity(0.85))
    }

    private func beatDots(info: BeatInfo?) -> some View {
        HStack(spacing: 9) {
            ForEach(0..<4, id: \.self) { i in
                let isActive = info.map { $0.beatInBar == i } ?? false
                let phase = info?.phase ?? 1
                Circle()
                    .fill(isActive ? Theme.accent : Color.white.opacity(0.22))
                    .frame(width: 9, height: 9)
                    .scaleEffect(isActive ? 1.0 + 0.55 * max(0, 1 - phase * 2.2) : 1.0)
                    .opacity(isActive ? 1 : 0.7)
            }
        }
        .animation(nil, value: info?.beatInBar)
    }

    /// Beat state at the playhead, from the topmost clip that has analysis.
    private func currentInfo() -> BeatInfo? {
        let playhead = model.engine.playhead
        let candidates = model.project.clips
            .filter { $0.contains(timelineTime: playhead) }
            .sorted { $0.laneIndex < $1.laneIndex }
        for clip in candidates {
            guard let asset = AssetLibrary.shared.asset(clip.assetID),
                  let bpm = asset.bpm else { continue }
            let t = playhead - clip.startTime
            let effBPM = clip.effectiveBPM(assetBPM: bpm, at: t)

            var beatInBar = 0
            var phase = 1.0
            if let grid = asset.beatGrid, grid.count > 1 {
                let sourceTime = clip.sourceStart + clip.sourceOffset(atOutputTime: t)
                // Binary search: last beat at or before sourceTime.
                var lo = 0, hi = grid.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if grid[mid] <= sourceTime { lo = mid } else { hi = mid - 1 }
                }
                beatInBar = lo % 4
                let next = lo + 1 < grid.count ? grid[lo + 1] : grid[lo] + 60.0 / bpm
                let span = max(next - grid[lo], 0.01)
                phase = min(max((sourceTime - grid[lo]) / span, 0), 1)
            }
            return BeatInfo(bpm: effBPM, beatInBar: beatInBar, phase: phase,
                            key: asset.key.map { clip.effectiveKey(assetKey: $0, at: t) })
        }
        return nil
    }
}
