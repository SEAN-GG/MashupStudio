import SwiftUI

/// Export: whole project or a time range, to MP3 (when available) / M4A / WAV.
/// Files land in Documents/Exports — visible in the Files app — plus a share sheet.
struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    private final class CancelFlag: @unchecked Sendable {
        var cancelled = false
    }

    @State private var wholeProject = true
    @State private var fromText = "00:00"
    @State private var toText = "00:00"
    @State private var format: ExportFormat = ExportFormat.available.first ?? .m4a
    @State private var karaokeVideo = false
    @State private var fileName = ""
    @State private var isExporting = false
    @State private var progress: Double = 0
    @State private var resultURL: URL?
    @State private var errorMessage: String?
    @State private var cancelFlag = CancelFlag()

    var body: some View {
        NavigationStack {
            List {
                if let resultURL {
                    doneSection(url: resultURL)
                } else if isExporting {
                    progressSection
                } else {
                    settingsSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("ייצוא")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isExporting ? "ביטול הייצוא" : "סגירה") {
                        if isExporting {
                            cancelFlag.cancelled = true
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                fileName = model.project.name
                toText = TimeFormat.short(model.project.duration)
            }
            .interactiveDismissDisabled(isExporting)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var settingsSections: some View {
        Section("טווח") {
            Picker("מה לייצא", selection: $wholeProject) {
                Text("כל הפרויקט").tag(true)
                Text("קטע מסוים").tag(false)
            }
            .pickerStyle(.segmented)
            if !wholeProject {
                HStack {
                    Text("מ־")
                    TextField("00:00", text: $fromText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Spacer()
                    Text("עד")
                    TextField("00:00", text: $toText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Button("קביעת הטווח לפי נקודת הנגינה") {
                    fromText = TimeFormat.short(model.engine.playhead)
                }
                .font(.footnote)
            }
        }
        Section("פורמט") {
            if !karaokeVideo {
                Picker("פורמט", selection: $format) {
                    ForEach(ExportFormat.available) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                if !MP3Encoder.isAvailable {
                    Text("ייצוא MP3 יופעל בגרסה הקרובה; בינתיים M4A נשמע זהה ונתמך בכל מקום.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if projectHasLyrics {
                Toggle("וידאו קריוקי (MP4) 🎤", isOn: $karaokeVideo)
                if karaokeVideo {
                    Text("הווידאו יציג את מילות השיר על המסך, עם הדגשת המילה הנוכחית בזמן שהיא מושרת.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        Section("שם הקובץ") {
            TextField("שם", text: $fileName)
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        Section {
            Button {
                startExport()
            } label: {
                Label("ייצוא", systemImage: "square.and.arrow.down.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.project.clips.isEmpty)
        }
    }

    private var progressSection: some View {
        Section {
            VStack(spacing: 14) {
                ProgressView(value: progress)
                Text("מייצא… \(Int(progress * 100))%")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 10)
        }
    }

    private func doneSection(url: URL) -> some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                Text("הייצוא הושלם")
                    .font(.headline)
                Text("הקובץ נשמר באפליקציית ״קבצים״ תחת: במכשיר שלי ← סטודיו מיקס ← Exports")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: url) {
                    Label("שיתוף / שמירה למקום אחר", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("סגירה") { dismiss() }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Export

    private var projectHasLyrics: Bool {
        model.project.clips.contains {
            AssetLibrary.shared.asset($0.assetID)?.lyrics?.isEmpty == false
        }
    }

    private func startExport() {
        errorMessage = nil
        let project = model.project
        let duration = project.duration

        var start = 0.0
        var end = duration
        if !wholeProject {
            guard let from = TimeFormat.parse(fromText),
                  let to = TimeFormat.parse(toText),
                  to > from else {
                errorMessage = "טווח לא תקין — בדוק את הזמנים (mm:ss)"
                return
            }
            start = min(from, duration)
            end = min(to, duration)
            guard end - start > 0.1 else {
                errorMessage = "הטווח קצר מדי"
                return
            }
        }
        guard end - start > 0.1 else {
            errorMessage = "הפרויקט ריק"
            return
        }

        let fileExtension = karaokeVideo ? "mp4" : format.fileExtension
        let cleanName = fileName.trimmingCharacters(in: .whitespaces).isEmpty
            ? project.name : fileName.trimmingCharacters(in: .whitespaces)
        var destination = AppPaths.exportsDir
            .appendingPathComponent(cleanName)
            .appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = AppPaths.exportsDir
                .appendingPathComponent("\(cleanName) \(counter)")
                .appendingPathExtension(fileExtension)
            counter += 1
        }

        let assets = OfflineRenderer.RenderAsset.resolveAll(for: project)
        let flag = CancelFlag()
        cancelFlag = flag
        isExporting = true
        progress = 0
        model.stopPlayback()

        let chosenFormat = format
        let rangeStart = start
        let rangeEnd = end

        if karaokeVideo {
            let words = KaraokeExporter.timelineWords(project: project,
                                                      rangeStart: rangeStart,
                                                      rangeEnd: rangeEnd)
            guard !words.isEmpty else {
                isExporting = false
                errorMessage = KaraokeError.noLyrics.errorDescription
                return
            }
            let title = cleanName
            Task.detached(priority: .userInitiated) {
                let tempAudio = FileManager.default.temporaryDirectory
                    .appendingPathComponent("karaoke-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: tempAudio) }
                do {
                    // Stage 1: mix the audio; stage 2: draw the video frames.
                    try OfflineRenderer.render(project: project,
                                               assets: assets,
                                               rangeStart: rangeStart,
                                               rangeEnd: rangeEnd,
                                               format: .m4a,
                                               to: tempAudio,
                                               isCancelled: { flag.cancelled }) { p in
                        Task { @MainActor in progress = p * 0.4 }
                    }
                    try await KaraokeExporter.render(words: words,
                                                     audioURL: tempAudio,
                                                     duration: rangeEnd - rangeStart,
                                                     title: title,
                                                     to: destination,
                                                     isCancelled: { flag.cancelled }) { p in
                        Task { @MainActor in progress = 0.4 + p * 0.6 }
                    }
                    await MainActor.run {
                        isExporting = false
                        resultURL = destination
                    }
                } catch {
                    await MainActor.run {
                        isExporting = false
                        if flag.cancelled {
                            dismiss()
                        } else {
                            errorMessage = (error as? KaraokeError)?.errorDescription
                                ?? (error as? RenderError)?.errorDescription
                                ?? "הייצוא נכשל"
                        }
                    }
                }
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            do {
                try OfflineRenderer.render(project: project,
                                           assets: assets,
                                           rangeStart: rangeStart,
                                           rangeEnd: rangeEnd,
                                           format: chosenFormat,
                                           to: destination,
                                           isCancelled: { flag.cancelled }) { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run {
                    isExporting = false
                    resultURL = destination
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    if flag.cancelled {
                        dismiss()
                    } else {
                        errorMessage = (error as? RenderError)?.errorDescription ?? "הייצוא נכשל"
                    }
                }
            }
        }
    }
}
