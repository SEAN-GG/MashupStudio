import SwiftUI

/// Per-clip stem control: 6 instruments, each with a fader, fades, gradual
/// volume changes, and additive effects (individual or preset combos).
/// Uses real AI stems once separated; until then an approximate EQ mode.
struct StemMixerSheet: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<StemKind> = []

    private var clip: Clip? { model.project.clip(withID: clipID) }
    private var asset: AudioAsset? {
        guard let clip else { return nil }
        return AssetLibrary.shared.asset(clip.assetID)
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if clip != nil {
                    Section("כלים") {
                        ForEach(StemKind.allCases) { kind in
                            StemRow(model: model, clipID: clipID, kind: kind,
                                    isExpanded: expanded.contains(kind)) {
                                if expanded.contains(kind) {
                                    expanded.remove(kind)
                                } else {
                                    expanded.insert(kind)
                                }
                            }
                        }
                    }
                    Section {
                        Button {
                            resetAll()
                        } label: {
                            Label("איפוס כל הכלים", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
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
    private var statusSection: some View {
        if let asset {
            Section {
                switch asset.stems {
                case .ready:
                    Label("הפרדת כלים מלאה (AI) פעילה", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.footnote)
                case .processing(let progress):
                    VStack(alignment: .trailing, spacing: 6) {
                        ProgressView(value: progress)
                        Text(progress < 0.1
                             ? "מוריד מודל AI (חד-פעמי, ‏55MB)… \(Int(progress * 1000))%"
                             : "מפריד כלים… \(Int(progress * 100))% — אפשר להשאיר את האפליקציה פתוחה ברקע המסך")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                case .failed(let message):
                    VStack(alignment: .trailing, spacing: 8) {
                        approximateLabel
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        separateButton
                    }
                case .none:
                    VStack(alignment: .trailing, spacing: 8) {
                        approximateLabel
                        if StemJobManager.backendAvailable {
                            separateButton
                            Text("ההפרדה רצה על המכשיר ולוקחת כמה דקות לשיר (תלוי באורך). התוצאה נשמרת — פעם אחת לכל שיר.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var approximateLabel: some View {
        Label("כרגע מצב משוער (EQ) — הפרדה אמיתית תיתן שליטה מלאה", systemImage: "waveform.and.magnifyingglass")
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
    }

    private var separateButton: some View {
        Button {
            if let asset {
                StemJobManager.shared.requestSeparation(assetID: asset.id)
            }
        } label: {
            Label("הפרדת כלים מלאה (AI)", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .disabled(StemJobManager.shared.isBusy)
    }

    private func resetAll() {
        guard var current = clip else { return }
        current.stemGains = StemGains()
        current.stemCurves = nil
        current.stemEffects = nil
        model.updateClip(current)
    }
}

// MARK: - Single stem row

private struct StemRow: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    let kind: StemKind
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var gradualTarget: Double = 20
    @State private var gradualSeconds: Double = 8
    @State private var gradualFromPlayhead = true

    private var clip: Clip? { model.project.clip(withID: clipID) }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    Text(kind.label)
                        .foregroundStyle(Theme.textPrimary)
                    if let clip, !clip.effects(for: kind).isEmpty {
                        Image(systemName: "fx")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    Text(String(format: "%.0f%%", (clip?.stemGains[kind] ?? 1) * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { model.project.clip(withID: clipID)?.stemGains[kind] ?? 1 },
                set: { newValue in
                    guard var current = model.project.clip(withID: clipID) else { return }
                    current.stemGains[kind] = newValue
                    model.previewClip(current)
                }
            ), in: 0...1.5)

            if isExpanded {
                expandedControls
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var expandedControls: some View {
        if let clip {
            VStack(alignment: .trailing, spacing: 12) {
                // Fades
                HStack(spacing: 10) {
                    fadeMenu(label: "פייד־אין") { seconds in
                        modify { $0.modifyStemCurve(kind) { $0.setFadeIn(duration: seconds) } }
                    }
                    fadeMenu(label: "פייד־אאוט") { seconds in
                        let dur = clip.outputDuration
                        modify { $0.modifyStemCurve(kind) { $0.setFadeOut(duration: seconds, totalDuration: dur) } }
                    }
                    Spacer()
                    if clip.stemCurves?[kind]?.isTrivial == false {
                        Button("איפוס שינויים") {
                            modify { $0.modifyStemCurve(kind) { $0.reset() } }
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                // Gradual volume change
                VStack(alignment: .trailing, spacing: 6) {
                    Text("שינוי הדרגתי בעוצמה")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack {
                        Text("יעד")
                            .font(.caption2)
                        Slider(value: $gradualTarget, in: 0...150, step: 5)
                        Text("\(Int(gradualTarget))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44)
                    }
                    HStack {
                        Text("משך")
                            .font(.caption2)
                        Slider(value: $gradualSeconds, in: 1...20, step: 1)
                        Text("\(Int(gradualSeconds)) שנ׳")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44)
                    }
                    Toggle("מנקודת הנגינה", isOn: $gradualFromPlayhead)
                        .font(.caption)
                    Button {
                        applyGradual(clip: clip)
                    } label: {
                        Label("החלה", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Theme.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                // Effects
                effectsControls(clip: clip)
            }
        }
    }

    private func effectsControls(clip: Clip) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Menu {
                    ForEach(EffectKind.allCases) { effectKind in
                        Button {
                            var list = clip.effects(for: kind)
                            list.append(StemEffectSetting(kind: effectKind))
                            modify { $0.setEffects(list, for: kind) }
                        } label: {
                            Label(effectKind.label, systemImage: effectKind.symbol)
                        }
                    }
                } label: {
                    Label("הוספת אפקט", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Text("אפקטים")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            // Preset gallery — each ADDS its combo on top.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StemEffectPreset.all) { preset in
                        Button {
                            var list = clip.effects(for: kind)
                            list.append(contentsOf: preset.effects.map {
                                StemEffectSetting(kind: $0.kind, amount: $0.amount)
                            })
                            modify { $0.setEffects(list, for: kind) }
                        } label: {
                            Text(preset.name)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.16), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            ForEach(clip.effects(for: kind)) { effect in
                HStack(spacing: 8) {
                    Button {
                        var list = clip.effects(for: kind)
                        list.removeAll { $0.id == effect.id }
                        modify { $0.setEffects(list, for: kind) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: {
                            model.project.clip(withID: clipID)?
                                .effects(for: kind).first { $0.id == effect.id }?.amount ?? effect.amount
                        },
                        set: { newValue in
                            guard var current = model.project.clip(withID: clipID) else { return }
                            var list = current.effects(for: kind)
                            if let i = list.firstIndex(where: { $0.id == effect.id }) {
                                list[i].amount = newValue
                                current.setEffects(list, for: kind)
                                model.previewClip(current)
                            }
                        }
                    ), in: 0...1)
                    Label(effect.kind.label, systemImage: effect.kind.symbol)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(minWidth: 90, alignment: .trailing)
                }
            }

            if let asset = AssetLibrary.shared.asset(clip.assetID), !asset.stems.isReady,
               !clip.allEffects.isEmpty {
                Text("לפני הפרדת AI האפקטים חלים על כל השיר; אחריה — רק על הכלי שנבחר.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func fadeMenu(label: String, apply: @escaping (Double) -> Void) -> some View {
        Menu {
            ForEach([0.0, 1, 2, 4, 8, 12], id: \.self) { seconds in
                Button(seconds == 0 ? "בלי" : "\(Int(seconds)) שנ׳") {
                    apply(seconds)
                }
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func applyGradual(clip: Clip) {
        let t0: Double
        if gradualFromPlayhead {
            t0 = min(max(model.engine.playhead - clip.startTime, 0), clip.outputDuration - 0.1)
        } else {
            t0 = 0
        }
        let target = gradualTarget / 100
        modify { $0.modifyStemCurve(kind) { $0.setRamp(at: t0, duration: gradualSeconds, to: target) } }
    }

    private func modify(_ change: (inout Clip) -> Void) {
        guard var current = model.project.clip(withID: clipID) else { return }
        change(&current)
        model.updateClip(current)
    }
}
