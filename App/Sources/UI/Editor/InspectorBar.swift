import SwiftUI

/// Bottom quick-edit bar for the selected clip: gain, fades, and entry points
/// to the stem mixer and pitch/tempo editors.
struct InspectorBar: View {
    @Bindable var model: EditorModel
    let onStems: () -> Void
    let onPitchTempo: () -> Void
    let onVolume: () -> Void
    let onLyrics: () -> Void

    var body: some View {
        if let clip = model.selectedClip {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text(clip.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    infoBadges(clip: clip)
                    Button {
                        model.deleteClip(clip.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                }

                HStack(spacing: 14) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: gainBinding(clip: clip), in: 0...2)
                        .frame(maxWidth: .infinity)
                    Text(String(format: "%.0f%%", clip.gain * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    fadeControl(label: "פייד־אין", value: clip.fades.fadeIn) { newValue in
                        updateFades(clip: clip) { $0.fadeIn = newValue }
                    }
                    fadeControl(label: "פייד־אאוט", value: clip.fades.fadeOut) { newValue in
                        updateFades(clip: clip) { $0.fadeOut = newValue }
                    }
                    Spacer()
                    laneButton(system: "arrow.up.square", delta: -1, clip: clip)
                    laneButton(system: "arrow.down.square", delta: 1, clip: clip)
                }

                // Action buttons on their own row so the Hebrew labels never
                // get squeezed into wrapping letter-by-letter.
                HStack(spacing: 8) {
                    actionButton("ווליום", system: "speaker.wave.2", action: onVolume)
                    actionButton("כלים", system: "slider.vertical.3", action: onStems)
                    actionButton("קצב", system: "dial.medium", action: onPitchTempo)
                    actionButton("מילים", system: "music.mic", action: onLyrics)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface)
        }
    }

    private func actionButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Theme.surfaceRaised, in: Capsule())
        }
    }

    private func laneButton(system: String, delta: Int, clip: Clip) -> some View {
        Button {
            model.moveClipLane(clip.id, delta: delta)
        } label: {
            Image(systemName: system)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .disabled(delta < 0 && clip.laneIndex == 0)
    }

    @ViewBuilder
    private func infoBadges(clip: Clip) -> some View {
        let asset = AssetLibrary.shared.asset(clip.assetID)
        HStack(spacing: 6) {
            if let bpm = asset?.bpm {
                Text("BPM \(String(format: "%.1f", clip.effectiveBPM(assetBPM: bpm, at: 0)))")
            }
            if let key = asset?.key {
                Text(clip.effectiveKey(assetKey: key, at: 0).bothNames())
            }
            if asset?.analysisDone != true {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("מנתח…")
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
    }

    private func gainBinding(clip: Clip) -> Binding<Double> {
        Binding {
            model.selectedClip?.gain ?? clip.gain
        } set: { newValue in
            guard var current = model.selectedClip else { return }
            current.gain = newValue
            model.previewClip(current)
        }
    }

    private func updateFades(clip: Clip, _ change: (inout ClipFades) -> Void) {
        guard var current = model.selectedClip else { return }
        change(&current.fades)
        current.fades.fadeIn = min(max(current.fades.fadeIn, 0), current.outputDuration)
        current.fades.fadeOut = min(max(current.fades.fadeOut, 0), current.outputDuration)
        model.updateClip(current)
    }

    private func fadeControl(label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Menu {
                ForEach([0.0, 1, 2, 4, 8, 12, 16], id: \.self) { seconds in
                    Button(seconds == 0 ? "בלי" : "\(Int(seconds)) שנ׳") {
                        onChange(seconds)
                    }
                }
            } label: {
                Text(value < 0.01 ? "—" : String(format: "%.0f שנ׳", value))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }
}
