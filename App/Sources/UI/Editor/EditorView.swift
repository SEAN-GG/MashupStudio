import SwiftUI
import UniformTypeIdentifiers

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
                                 onVolume: { showVolume = true })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.selectedClip != nil)
        .statusBarHidden(false)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.importSongs(urls: urls)
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
