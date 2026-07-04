import SwiftUI

/// Per-clip stem faders (vocals / drums / bass / other). Uses real AI stems
/// when separated; until then an approximate EQ mode, clearly labeled.
struct StemMixerSheet: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss

    private var clip: Clip? { model.project.clip(withID: clipID) }
    private var asset: AudioAsset? {
        guard let clip else { return nil }
        return AssetLibrary.shared.asset(clip.assetID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let clip {
                    VStack(spacing: 18) {
                        statusHeader
                        HStack(alignment: .bottom, spacing: 22) {
                            ForEach(StemKind.allCases) { kind in
                                fader(kind: kind, clip: clip)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        resetButton(clip: clip)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("מיקסר כלים")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        if let asset {
            switch asset.stems {
            case .ready:
                Label("הפרדת כלים מלאה (AI) פעילה", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
            case .processing(let progress):
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                    Text("מפריד כלים… \(Int(progress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    approximateLabel
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            case .none:
                VStack(spacing: 8) {
                    approximateLabel
                    if StemJobManager.backendAvailable {
                        Button {
                            StemJobManager.shared.requestSeparation(assetID: asset.id)
                        } label: {
                            Label("הפרדה מלאה (AI)", systemImage: "sparkles")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.accent.opacity(0.2), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var approximateLabel: some View {
        Label("מצב משוער (EQ) — עובד מיד, מדויק פחות", systemImage: "waveform.and.magnifyingglass")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
    }

    private func fader(kind: StemKind, clip: Clip) -> some View {
        VStack(spacing: 10) {
            Text(String(format: "%.0f%%", clip.stemGains[kind] * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(
                get: { model.project.clip(withID: clipID)?.stemGains[kind] ?? 1 },
                set: { newValue in
                    guard var current = model.project.clip(withID: clipID) else { return }
                    current.stemGains[kind] = newValue
                    model.previewClip(current)
                }
            ), in: 0...1.5)
            .frame(width: 170)
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 170)
            Image(systemName: kind.symbol)
                .font(.body)
                .foregroundStyle(Theme.accent)
            Text(kind.label)
                .font(.caption2)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func resetButton(clip: Clip) -> some View {
        Button {
            var current = clip
            current.stemGains = StemGains()
            model.updateClip(current)
        } label: {
            Text("איפוס")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Theme.surfaceRaised, in: Capsule())
        }
    }
}
