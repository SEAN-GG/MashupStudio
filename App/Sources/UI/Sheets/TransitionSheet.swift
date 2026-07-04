import SwiftUI

/// The transition assistant: pick two clips, see BPM/key compatibility, choose
/// tempo strategy, key match, overlap/crossfade and stem pattern — then apply.
struct TransitionSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var clipAID: UUID?
    @State private var clipBID: UUID?
    @State private var options = TransitionPlanner.Options()

    private var orderedClips: [Clip] {
        model.project.clips.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        NavigationStack {
            List {
                clipPickerSection
                if let a = clipAID, let b = clipBID, a != b,
                   let preview = TransitionPlanner.preview(project: model.project, clipAID: a, clipBID: b) {
                    analysisSection(preview)
                    optionsSection
                    applySection(a: a, b: b)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("עוזר מעברים")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
            .onAppear { pickDefaults() }
        }
    }

    private func pickDefaults() {
        let clips = orderedClips
        guard clips.count >= 2 else { return }
        if let selected = model.selectedClipID,
           let index = clips.firstIndex(where: { $0.id == selected }),
           index + 1 < clips.count {
            clipAID = clips[index].id
            clipBID = clips[index + 1].id
        } else {
            clipAID = clips[clips.count - 2].id
            clipBID = clips[clips.count - 1].id
        }
        options.overlapSeconds = AppSettings.shared.defaultCrossfade
    }

    private var clipPickerSection: some View {
        Section("בחירת קליפים") {
            Picker("השיר היוצא", selection: $clipAID) {
                Text("בחר…").tag(UUID?.none)
                ForEach(orderedClips) { clip in
                    Text("\(clip.name) (\(TimeFormat.short(clip.startTime)))").tag(UUID?.some(clip.id))
                }
            }
            Picker("השיר הנכנס", selection: $clipBID) {
                Text("בחר…").tag(UUID?.none)
                ForEach(orderedClips) { clip in
                    Text("\(clip.name) (\(TimeFormat.short(clip.startTime)))").tag(UUID?.some(clip.id))
                }
            }
        }
    }

    private func analysisSection(_ preview: TransitionPlanner.Preview) -> some View {
        Section("ניתוח") {
            HStack {
                Text("BPM")
                Spacer()
                Text("\(format(preview.bpmA)) ← \(format(preview.bpmB))")
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Text("סולם")
                Spacer()
                let style = AppSettings.shared.keyNotation
                Text("\(preview.keyA?.displayName(style: style) ?? "—") ← \(preview.keyB?.displayName(style: style) ?? "—")")
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Text("תאימות הרמונית")
                Spacer()
                if preview.keysCompatible {
                    Label("תואם", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(preview.suggestedSemitones == 0
                          ? "לא תואם"
                          : "הזזה של \(preview.suggestedSemitones > 0 ? "+" : "")\(preview.suggestedSemitones) חצאי טונים תתאים",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
    }

    private var optionsSection: some View {
        Group {
            Section("קצב") {
                Picker("אסטרטגיית קצב", selection: $options.tempoStrategy) {
                    ForEach(TransitionPlanner.TempoStrategy.allCases) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if options.tempoStrategy != .none {
                    HStack {
                        Text("משך שינוי הקצב")
                        Slider(value: $options.tempoRampSeconds, in: 2...24, step: 1)
                        Text("\(Int(options.tempoRampSeconds)) שנ׳")
                            .monospacedDigit()
                            .frame(width: 46)
                    }
                }
            }
            Section("סולם וחפיפה") {
                Toggle("התאמת סולם אוטומטית", isOn: $options.matchKey)
                HStack {
                    Text("חפיפה בין השירים")
                    Slider(value: $options.overlapSeconds, in: 1...30, step: 1)
                    Text("\(Int(options.overlapSeconds)) שנ׳")
                        .monospacedDigit()
                        .frame(width: 46)
                }
                Toggle("קרוספייד אוטומטי", isOn: $options.crossfade)
                Toggle("הצמדה לביט", isOn: $options.snapToBeat)
            }
            Section("תבנית כלים (דורש הפרדת AI או מצב EQ)") {
                Picker("תבנית", selection: $options.stemPattern) {
                    ForEach(TransitionPlanner.StemPattern.allCases) { pattern in
                        Text(pattern.label).tag(pattern)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }

    private func applySection(a: UUID, b: UUID) -> some View {
        Section {
            Button {
                if let updated = TransitionPlanner.apply(project: model.project,
                                                         clipAID: a, clipBID: b,
                                                         options: options) {
                    model.mutate { $0 = updated }
                    dismiss()
                }
            } label: {
                Label("בניית המעבר", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } footer: {
            Text("המעבר נבנה כעריכה רגילה על הטיימליין — אפשר לבטל (Undo) ולכוונן כל פרט ידנית אחר כך.")
        }
    }

    private func format(_ bpm: Double?) -> String {
        guard let bpm else { return "—" }
        return String(format: "%.0f", bpm)
    }
}
