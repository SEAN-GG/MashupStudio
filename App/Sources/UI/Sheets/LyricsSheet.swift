import SwiftUI

/// Lyrics for the selected clip's song: automatic word-level transcription,
/// inline correction of any word, and time nudging — the base for karaoke.
struct LyricsSheet: View {
    @Bindable var model: EditorModel
    let assetID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var jobs = LyricsJobManager.shared
    @State private var language = "he-IL"

    private var asset: AudioAsset? { AssetLibrary.shared.asset(assetID) }
    private var isTranscribing: Bool { jobs.activeAssetID == assetID }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let words = asset?.lyrics, !words.isEmpty {
                    wordsSection(words: words)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("מילות השיר")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("סגירה") { dismiss() }
                }
            }
            .onAppear {
                if let saved = asset?.lyricsLanguage { language = saved }
            }
        }
    }

    // MARK: - Status / transcription

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if isTranscribing {
                VStack(spacing: 10) {
                    ProgressView(value: jobs.progress)
                    Text("מתמלל… \(Int(jobs.progress * 100))%")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Button("ביטול", role: .destructive) { jobs.cancel() }
                        .font(.footnote)
                }
                .padding(.vertical, 6)
            } else {
                Picker("שפת השיר", selection: $language) {
                    ForEach(LyricsService.languages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                Button {
                    jobs.transcribe(assetID: assetID, localeIdentifier: language)
                } label: {
                    Label(asset?.lyrics?.isEmpty == false ? "תמלול מחדש" : "תמלול אוטומטי",
                          systemImage: "waveform.and.mic")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(jobs.activeAssetID != nil)
            }
            if let error = jobs.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            if jobs.willUseVocalsStem(for: assetID) {
                Text("התמלול ירוץ על ערוץ השירה המופרד — דיוק גבוה 🎯")
            } else {
                Text("טיפ: הפרדת כלים (בכפתור ״כלים״) לפני התמלול משפרת מאוד את הדיוק — התמלול ירוץ אז על ערוץ השירה בלבד. נדרש חיבור לאינטרנט.")
            }
        }
    }

    // MARK: - Words list

    private func wordsSection(words: [LyricWord]) -> some View {
        Section {
            ForEach(words) { word in
                HStack(spacing: 10) {
                    VStack(spacing: 2) {
                        Text(TimeFormat.short(word.time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 6) {
                            nudgeButton("minus", word: word, delta: -0.1)
                            nudgeButton("plus", word: word, delta: 0.1)
                        }
                    }
                    TextField("מילה", text: wordBinding(word))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .onDelete { offsets in
                updateWords { $0.remove(atOffsets: offsets) }
            }
            Button("מחיקת כל המילים", role: .destructive) {
                if var updated = asset {
                    updated.lyrics = nil
                    AssetLibrary.shared.update(updated)
                }
            }
            .font(.footnote)
        } header: {
            Text("מילים (\(words.count)) — אפשר לתקן כל מילה ולכוון את הזמן שלה")
        }
    }

    private func nudgeButton(_ system: String, word: LyricWord, delta: Double) -> some View {
        Button {
            updateWords { list in
                if let i = list.firstIndex(where: { $0.id == word.id }) {
                    list[i].time = max(0, list[i].time + delta)
                }
            }
        } label: {
            Image(systemName: "\(system).circle")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func wordBinding(_ word: LyricWord) -> Binding<String> {
        Binding {
            asset?.lyrics?.first(where: { $0.id == word.id })?.text ?? word.text
        } set: { newValue in
            updateWords { list in
                if let i = list.firstIndex(where: { $0.id == word.id }) {
                    list[i].text = newValue
                }
            }
        }
    }

    private func updateWords(_ change: (inout [LyricWord]) -> Void) {
        guard var updated = asset, var words = updated.lyrics else { return }
        change(&words)
        updated.lyrics = words.isEmpty ? nil : words
        AssetLibrary.shared.update(updated)
    }
}
