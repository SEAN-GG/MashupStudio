import SwiftUI

/// Clip volume (with gradual automation) + project master volume.
struct VolumeSheet: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var gradualTarget: Double = 20
    @State private var gradualSeconds: Double = 8
    @State private var gradualFromPlayhead = true

    private var clip: Clip? { model.project.clip(withID: clipID) }

    var body: some View {
        NavigationStack {
            List {
                clipVolumeSection
                gradualSection
                automationListSection
                masterSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("ווליום")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var clipVolumeSection: some View {
        if clip != nil {
            Section("ווליום הקליפ") {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Theme.textSecondary)
                    Slider(value: Binding(
                        get: { model.project.clip(withID: clipID)?.gain ?? 1 },
                        set: { newValue in
                            guard var current = model.project.clip(withID: clipID) else { return }
                            current.gain = newValue
                            model.previewClip(current)
                        }
                    ), in: 0...2)
                    Text(String(format: "%.0f%%", (clip?.gain ?? 1) * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 48)
                }
            }
        }
    }

    @ViewBuilder
    private var gradualSection: some View {
        if let clip {
            Section {
                HStack {
                    Text("יעד")
                    Slider(value: $gradualTarget, in: 0...150, step: 5)
                    Text("\(Int(gradualTarget))%")
                        .monospacedDigit()
                        .frame(width: 48)
                }
                HStack {
                    Text("משך")
                    Slider(value: $gradualSeconds, in: 1...30, step: 1)
                    Text("\(Int(gradualSeconds)) שנ׳")
                        .monospacedDigit()
                        .frame(width: 48)
                }
                Toggle("החל מנקודת הנגינה (אחרת מתחילת הקליפ)", isOn: $gradualFromPlayhead)
                Button {
                    applyGradual(clip: clip)
                } label: {
                    Label("החלת שינוי הדרגתי", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } header: {
                Text("שינוי הדרגתי בווליום")
            } footer: {
                Text("לדוגמה: מ-100% ל-20% לאורך 8 שניות — בדיוק כמו פיידר בהופעה חיה.")
            }
        }
    }

    @ViewBuilder
    private var automationListSection: some View {
        if let clip, let curve = clip.volumeCurve, !curve.points.isEmpty {
            Section("שינויי ווליום קיימים") {
                ForEach(curve.points) { point in
                    HStack {
                        Image(systemName: "speaker.wave.1")
                            .foregroundStyle(Theme.accent)
                        Text(pointDescription(point))
                            .font(.footnote)
                        Spacer()
                        Button(role: .destructive) {
                            modifyClip { $0.modifyVolumeCurve { $0.removePoint(id: point.id) } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(role: .destructive) {
                    modifyClip { $0.volumeCurve = nil }
                } label: {
                    Label("איפוס כל שינויי הווליום", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private var masterSection: some View {
        Section {
            HStack {
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(Theme.accent)
                Slider(value: Binding(
                    get: { model.project.effectiveMasterVolume },
                    set: { newValue in
                        model.mutateWithoutReschedule { $0.effectiveMasterVolume = newValue }
                    }
                ), in: 0...2)
                Text(String(format: "%.0f%%", model.project.effectiveMasterVolume * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48)
            }
        } header: {
            Text("ווליום כללי (כל הפרויקט)")
        } footer: {
            Text("משפיע על הנגינה וגם על הייצוא.")
        }
    }

    private func pointDescription(_ point: AutomationPoint) -> String {
        let time = TimeFormat.short(point.time)
        let percent = Int((point.value * 100).rounded())
        return point.shapeIn == .linear
            ? "מעבר הדרגתי עד \(time) → \(percent)%"
            : "מ־\(time) → \(percent)%"
    }

    private func applyGradual(clip: Clip) {
        let t0: Double
        if gradualFromPlayhead {
            t0 = min(max(model.engine.playhead - clip.startTime, 0), clip.outputDuration - 0.1)
        } else {
            t0 = 0
        }
        modifyClip { $0.modifyVolumeCurve { $0.setRamp(at: t0, duration: gradualSeconds, to: gradualTarget / 100) } }
    }

    private func modifyClip(_ change: (inout Clip) -> Void) {
        guard var current = clip else { return }
        change(&current)
        model.updateClip(current)
    }
}
