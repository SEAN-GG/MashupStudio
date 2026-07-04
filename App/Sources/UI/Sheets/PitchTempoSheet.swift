import SwiftUI

/// Tempo (BPM) and key (pitch) editing for a clip — instant or gradual over a
/// chosen number of seconds, starting at a chosen moment inside the clip.
struct PitchTempoSheet: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var targetBPM: Double = 120
    @State private var bpmGradual = false
    @State private var bpmRampSeconds: Double = 8
    @State private var bpmStartAtPlayhead = false

    @State private var semitones: Int = 0
    @State private var pitchGradual = false
    @State private var pitchRampSeconds: Double = 4
    @State private var pitchStartAtPlayhead = false

    @State private var speedPercent: Double = 100

    private var clip: Clip? { model.project.clip(withID: clipID) }
    private var asset: AudioAsset? {
        guard let clip else { return nil }
        return AssetLibrary.shared.asset(clip.assetID)
    }

    var body: some View {
        NavigationStack {
            List {
                currentStateSection
                tempoSection
                keySection
                speedSection
                automationListSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("קצב וסולם")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
            .onAppear {
                if let asset, let bpm = asset.bpm, let clip {
                    targetBPM = (bpm * clip.rate(at: 0)).rounded()
                }
                if let clip {
                    speedPercent = clip.rate(at: 0) * 100
                    semitones = Int((clip.pitchCurve.value(at: 0) / 100).rounded())
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var currentStateSection: some View {
        if let clip, let asset {
            Section("מצב נוכחי") {
                HStack {
                    Label("BPM מקורי", systemImage: "metronome")
                    Spacer()
                    Text(asset.displayBPM)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                if let key = asset.key {
                    HStack {
                        Label("סולם מקורי", systemImage: "music.note")
                        Spacer()
                        Text(key.bothNames())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        Label("סולם אחרי שינוי", systemImage: "music.note.list")
                        Spacer()
                        Text(clip.effectiveKey(assetKey: key, at: 0).bothNames())
                            .foregroundStyle(Theme.accent)
                    }
                }
                if let bpm = asset.bpm {
                    HStack {
                        Label("BPM בתחילת הקליפ", systemImage: "speedometer")
                        Spacer()
                        Text(String(format: "%.1f", clip.effectiveBPM(assetBPM: bpm, at: 0)))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    private var tempoSection: some View {
        Section("שינוי קצב (שומר על גובה הצליל)") {
            HStack {
                Text("BPM יעד")
                Spacer()
                TextField("BPM", value: $targetBPM, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $targetBPM, in: 40...240, step: 1)
                    .labelsHidden()
            }
            Toggle("שינוי הדרגתי", isOn: $bpmGradual)
            if bpmGradual {
                HStack {
                    Text("משך המעבר")
                    Slider(value: $bpmRampSeconds, in: 1...30, step: 1)
                    Text("\(Int(bpmRampSeconds)) שנ׳")
                        .monospacedDigit()
                        .frame(width: 48)
                }
            }
            Toggle("החל מנקודת הנגינה (אחרת מתחילת הקליפ)", isOn: $bpmStartAtPlayhead)
            Button {
                applyTempo()
            } label: {
                Label(bpmGradual ? "החלת שינוי הדרגתי" : "החלה מיידית", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(asset?.bpm == nil)
            if asset?.bpm == nil {
                Text(asset?.analysisDone == true ? "לא זוהה BPM לשיר הזה — אפשר להשתמש במהירות (%) למטה" : "מנתח את השיר…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var keySection: some View {
        Section("שינוי סולם") {
            HStack {
                Text("חצאי טונים")
                Spacer()
                Text(semitones > 0 ? "+\(semitones)" : "\(semitones)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                Stepper("", value: $semitones, in: -12...12)
                    .labelsHidden()
            }
            if let key = asset?.key {
                HStack {
                    Text("תוצאה")
                    Spacer()
                    Text(key.transposed(by: semitones).bothNames())
                        .foregroundStyle(Theme.accent)
                }
            }
            Toggle("שינוי הדרגתי", isOn: $pitchGradual)
            if pitchGradual {
                HStack {
                    Text("משך המעבר")
                    Slider(value: $pitchRampSeconds, in: 1...20, step: 1)
                    Text("\(Int(pitchRampSeconds)) שנ׳")
                        .monospacedDigit()
                        .frame(width: 48)
                }
            }
            Toggle("החל מנקודת הנגינה (אחרת מתחילת הקליפ)", isOn: $pitchStartAtPlayhead)
            Button {
                applyPitch()
            } label: {
                Label(pitchGradual ? "החלת שינוי הדרגתי" : "החלה מיידית", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var speedSection: some View {
        Section("מהירות (וריספיד — משנה גם את גובה הצליל)") {
            HStack {
                Text("מהירות")
                Slider(value: $speedPercent, in: 50...200, step: 1)
                Text("\(Int(speedPercent))%")
                    .monospacedDigit()
                    .frame(width: 52)
            }
            Button {
                applySpeed()
            } label: {
                Label("החלת מהירות", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var automationListSection: some View {
        if let clip, !clip.rateCurve.points.isEmpty || !clip.pitchCurve.points.isEmpty {
            Section("שינויים קיימים") {
                ForEach(clip.rateCurve.points) { point in
                    automationRow(icon: "metronome",
                                  text: rateDescription(point, clip: clip)) {
                        removeRatePoint(point.id)
                    }
                }
                ForEach(clip.pitchCurve.points) { point in
                    automationRow(icon: "music.note",
                                  text: pitchDescription(point)) {
                        removePitchPoint(point.id)
                    }
                }
                Button(role: .destructive) {
                    resetAllAutomation()
                } label: {
                    Label("איפוס כל השינויים", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func automationRow(icon: String, text: String, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.footnote)
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Descriptions

    private func rateDescription(_ point: AutomationPoint, clip: Clip) -> String {
        let time = TimeFormat.short(point.time)
        let suffix: String
        if let bpm = asset?.bpm {
            suffix = String(format: "%.0f BPM", bpm * point.value)
        } else {
            suffix = String(format: "%.0f%%", point.value * 100)
        }
        return point.shapeIn == .linear
            ? "מעבר הדרגתי עד \(time) → \(suffix)"
            : "מ־\(time) → \(suffix)"
    }

    private func pitchDescription(_ point: AutomationPoint) -> String {
        let time = TimeFormat.short(point.time)
        let st = Int((point.value / 100).rounded())
        let sign = st > 0 ? "+\(st)" : "\(st)"
        return point.shapeIn == .linear
            ? "מעבר הדרגתי עד \(time) → \(sign) חצאי טונים"
            : "מ־\(time) → \(sign) חצאי טונים"
    }

    // MARK: - Apply

    /// The moment inside the clip where a change begins.
    private func startTime(atPlayhead: Bool) -> Double {
        guard let clip else { return 0 }
        guard atPlayhead else { return 0 }
        let local = model.engine.playhead - clip.startTime
        return min(max(local, 0), clip.outputDuration - 0.1)
    }

    private func applyTempo() {
        guard var current = clip, let bpm = asset?.bpm, bpm > 20 else { return }
        let rate = min(max(targetBPM / bpm, Clip.minRate), Clip.maxRate)
        let t0 = startTime(atPlayhead: bpmStartAtPlayhead)
        if bpmGradual {
            current.rateCurve.setRamp(at: t0, duration: bpmRampSeconds, to: rate)
        } else {
            current.rateCurve.setInstantChange(at: t0, to: rate)
        }
        model.updateClip(current)
    }

    private func applyPitch() {
        guard var current = clip else { return }
        let cents = Double(semitones * 100)
        let t0 = startTime(atPlayhead: pitchStartAtPlayhead)
        if pitchGradual {
            current.pitchCurve.setRamp(at: t0, duration: pitchRampSeconds, to: cents)
        } else {
            current.pitchCurve.setInstantChange(at: t0, to: cents)
        }
        model.updateClip(current)
    }

    private func applySpeed() {
        guard var current = clip else { return }
        current.varispeed = true
        current.rateCurve.setInstantChange(at: 0, to: min(max(speedPercent / 100, Clip.minRate), Clip.maxRate))
        model.updateClip(current)
    }

    private func removeRatePoint(_ id: UUID) {
        guard var current = clip else { return }
        current.rateCurve.removePoint(id: id)
        model.updateClip(current)
    }

    private func removePitchPoint(_ id: UUID) {
        guard var current = clip else { return }
        current.pitchCurve.removePoint(id: id)
        model.updateClip(current)
    }

    private func resetAllAutomation() {
        guard var current = clip else { return }
        current.rateCurve.reset()
        current.pitchCurve.reset()
        current.varispeed = false
        model.updateClip(current)
    }
}
