import SwiftUI

struct TransportBar: View {
    @Bindable var model: EditorModel
    let onBack: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let onTransition: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                }
                Text(model.project.name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button(action: onImport) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                Button(action: onTransition) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                }
                .disabled(model.project.clips.count < 2)
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                }
                .disabled(model.project.clips.isEmpty)
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
            }
            .padding(.horizontal, 14)

            HStack(spacing: 18) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)

                Spacer()

                Button {
                    model.engine.stopToStart()
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title3)
                }
                Button {
                    if model.engine.isPlaying {
                        model.engine.pause()
                    } else {
                        model.engine.play()
                    }
                } label: {
                    Image(systemName: model.engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.accent)
                }
                Button {
                    model.splitSelectedClipAtPlayhead()
                } label: {
                    Image(systemName: "scissors")
                        .font(.title3)
                }
                .disabled(model.selectedClip.map { !$0.contains(timelineTime: model.engine.playhead) } ?? true)

                Spacer()

                Text(TimeFormat.position(model.engine.playhead))
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    AppSettings.shared.setSnapEnabled(!AppSettings.shared.snapEnabled)
                } label: {
                    Image(systemName: AppSettings.shared.snapEnabled ? "arrow.right.and.line.vertical.and.arrow.left" : "arrow.left.and.right")
                        .font(.footnote)
                        .padding(6)
                        .background(AppSettings.shared.snapEnabled ? Theme.accent.opacity(0.25) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Theme.surface)
    }
}
