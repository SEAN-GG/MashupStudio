import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A video picked from the photo library, copied to a temp file for import.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }
}

struct EditorView: View {
    @State private var model: EditorModel
    let onClose: () -> Void

    @State private var showImporter = false
    @State private var showExitDialog = false
    @State private var showExport = false
    @State private var showStemMixer = false
    @State private var showPitchTempo = false
    @State private var showTransition = false
    @State private var showSettings = false
    @State private var showVolume = false
    @State private var showLyrics = false
    @State private var showVideoPicker = false
    @State private var pickedVideos: [PhotosPickerItem] = []

    init(project: MixProject, onClose: @escaping () -> Void) {
        _model = State(initialValue: EditorModel(project: project))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                TransportBar(model: model,
                             onBack: { attemptExit() },
                             onImport: { showImporter = true },
                             onImportGallery: { showVideoPicker = true },
                             onExport: { model.stopPlayback(); showExport = true },
                             onTransition: { showTransition = true },
                             onSettings: { showSettings = true })
                if AppSettings.shared.showRhythm {
                    RhythmWindow(model: model)
                }
                TimelineView(model: model)
                if model.selectedClip != nil {
                    InspectorBar(model: model,
                                 onStems: { showStemMixer = true },
                                 onPitchTempo: { showPitchTempo = true },
                                 onVolume: { showVolume = true },
                                 onLyrics: { showLyrics = true })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.selectedClip != nil)
        .statusBarHidden(false)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.audio, UTType.movie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.importSongs(urls: urls)
            }
        }
        .photosPicker(isPresented: $showVideoPicker,
                      selection: $pickedVideos,
                      matching: .videos)
        .onChange(of: pickedVideos) { _, items in
            guard !items.isEmpty else { return }
            pickedVideos = []
            Task {
                for item in items {
                    if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                        model.importSongs(urls: [video.url])
                    } else {
                        model.importError = "לא ניתן לטעון את הסרטון מהגלריה"
                    }
                }
            }
        }
        .confirmationDialog("יציאה מהפרויקט", isPresented: $showExitDialog, titleVisibility: .visible) {
            if !model.wasEverSaved {
                Button("שמירה כטיוטה") {
                    model.saveProject(asDraft: true)
                    close()
                }
                Button("מחיקת הפרויקט", role: .destructive) {
                    model.discardNewProject()
                    close()
                }
            } else {
                Button("שמירת שינויים") {
                    model.saveProject()
                    close()
                }
                Button("יציאה בלי לשמור", role: .destructive) {
                    close()
                }
            }
            Button("ביטול", role: .cancel) {}
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .sheet(isPresented: $showStemMixer) {
            if let clip = model.selectedClip {
                StemMixerSheet(model: model, clipID: clip.id)
                    .environment(\.layoutDirection, .rightToLeft)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showPitchTempo) {
            if let clip = model.selectedClip {
                PitchTempoSheet(model: model, clipID: clip.id)
                    .environment(\.layoutDirection, .rightToLeft)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showVolume) {
            if let clip = model.selectedClip {
                VolumeSheet(model: model, clipID: clip.id)
                    .environment(\.layoutDirection, .rightToLeft)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showLyrics) {
            if let clip = model.selectedClip {
                LyricsSheet(model: model, assetID: clip.assetID)
                    .environment(\.layoutDirection, .rightToLeft)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showTransition) {
            TransitionSheet(model: model)
                .environment(\.layoutDirection, .rightToLeft)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .alert("שגיאת ייבוא", isPresented: Binding(get: { model.importError != nil },
                                                    set: { if !$0 { model.importError = nil } })) {
            Button("אישור") { model.importError = nil }
        } message: {
            Text(model.importError ?? "")
        }
        .alert("שגיאת נגינה", isPresented: Binding(get: { model.engine.lastError != nil },
                                                    set: { if !$0 { model.engine.lastError = nil } })) {
            Button("אישור") { model.engine.lastError = nil }
        } message: {
            Text(model.engine.lastError ?? "")
        }
        .onDisappear {
            model.stopPlayback()
        }
    }

    private func attemptExit() {
        model.stopPlayback()
        switch model.exitPrompt() {
        case .none:
            close()
        case .firstSave, .changes:
            showExitDialog = true
        }
    }

    private func close() {
        model.stopPlayback()
        onClose()
    }
}
