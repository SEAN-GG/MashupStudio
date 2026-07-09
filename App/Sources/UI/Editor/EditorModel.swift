import Foundation
import SwiftUI
import Observation

/// View model for the editor: owns the working project, undo history,
/// selection, timeline view state and the playback engine.
@Observable
@MainActor
final class EditorModel {
    var project: MixProject
    private var savedSnapshot: MixProject?
    let wasEverSaved: Bool
    let engine = PlaybackEngine()

    // Undo
    private var undoStack: [MixProject] = []
    private var redoStack: [MixProject] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Selection & view state
    var selectedClipID: UUID?
    var pixelsPerSecond: Double = 14
    var contentOffsetX: Double = 0
    var contentOffsetY: Double = 0
    var importError: String?
    /// True while a clip drag/trim gesture is in flight — the timeline must
    /// not pan, zoom or seek underneath it (that caused random view jumps).
    var isClipGestureActive = false

    var selectedClip: Clip? {
        guard let selectedClipID else { return nil }
        return project.clip(withID: selectedClipID)
    }

    var hasUnsavedChanges: Bool {
        guard let savedSnapshot else { return !project.clips.isEmpty }
        return savedSnapshot != project
    }

    init(project: MixProject) {
        self.project = project
        let fileExists = FileManager.default.fileExists(atPath: AppPaths.projectFile(project.id).path)
        self.wasEverSaved = fileExists
        self.savedSnapshot = fileExists ? project : nil
        engine.projectProvider = { [weak self] in self?.project }
    }

    // MARK: - Mutation with undo

    /// Every edit goes through here: snapshot for undo, apply, notify engine.
    func mutate(_ change: (inout MixProject) -> Void) {
        undoStack.append(project)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&project)
        project.normalizeLanes()
        engine.projectDidChange()
    }

    /// For live-applied parameters (lane mute/solo/volume) that the engine
    /// pump picks up every frame — no reschedule, so no audio hiccup.
    func mutateWithoutReschedule(_ change: (inout MixProject) -> Void) {
        undoStack.append(project)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&project)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        if let id = selectedClipID, project.clip(withID: id) == nil { selectedClipID = nil }
        engine.projectDidChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        if let id = selectedClipID, project.clip(withID: id) == nil { selectedClipID = nil }
        engine.projectDidChange()
    }

    // MARK: - Import

    func importSongs(urls: [URL]) {
        Task {
            for url in urls {
                do {
                    let asset = try await AssetLibrary.shared.importMedia(from: url)
                    addClip(for: asset)
                } catch {
                    importError = "לא ניתן לייבא את \(url.lastPathComponent)"
                }
            }
        }
    }

    private func addClip(for asset: AudioAsset) {
        mutate { project in
            let playhead = engine.playhead
            var lane = 0
            var start = playhead
            // First lane where a clip of this length fits at the playhead;
            // otherwise append to the end of lane 0 or open a new lane.
            let duration = asset.duration
            var placed = false
            for laneIndex in 0..<project.lanes.count {
                let overlapping = project.clips.contains {
                    $0.laneIndex == laneIndex && $0.startTime < playhead + duration && $0.endTime > playhead
                }
                if !overlapping {
                    lane = laneIndex
                    placed = true
                    break
                }
            }
            if !placed {
                lane = project.lanes.count
                start = playhead
            }
            let clip = Clip(assetID: asset.id,
                            name: asset.title,
                            laneIndex: lane,
                            startTime: max(0, start),
                            sourceStart: 0,
                            sourceDuration: duration)
            project.clips.append(clip)
        }
    }

    // MARK: - Clip operations

    func updateClip(_ clip: Clip) {
        mutate { $0.update(clip) }
    }

    /// Live-updates a clip without pushing an undo snapshot (used mid-gesture).
    func previewClip(_ clip: Clip) {
        project.update(clip)
    }

    func beginGesture() {
        undoStack.append(project)
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
        isClipGestureActive = true
    }

    func endGesture() {
        isClipGestureActive = false
        project.normalizeLanes()
        engine.projectDidChange()
    }

    /// Moves a clip one lane up or down (drag is horizontal-only now).
    func moveClipLane(_ id: UUID, delta: Int) {
        guard var clip = project.clip(withID: id) else { return }
        let target = clip.laneIndex + delta
        guard target >= 0, target <= project.lanes.count else { return }
        clip.laneIndex = target
        mutate { $0.update(clip) }
    }

    /// "Glues" the clip right after the nearest clip that ends at or before its
    /// start (any lane); with nothing before it, snaps to the timeline start.
    func snapToPreviousClip(_ id: UUID) {
        guard var clip = project.clip(withID: id) else { return }
        let previousEnd = project.clips
            .filter { $0.id != id && $0.endTime <= clip.startTime + 0.001 }
            .map(\.endTime)
            .max() ?? 0
        guard abs(previousEnd - clip.startTime) > 0.0001 else { return }
        clip.startTime = previousEnd
        mutate { $0.update(clip) }
    }

    func deleteClip(_ id: UUID) {
        mutate { $0.remove(clipID: id) }
        if selectedClipID == id { selectedClipID = nil }
    }

    func duplicateClip(_ id: UUID) {
        guard let clip = project.clip(withID: id) else { return }
        mutate { project in
            var copy = clip
            copy.id = UUID()
            copy.startTime = clip.endTime + 0.2
            project.clips.append(copy)
        }
    }

    func splitSelectedClipAtPlayhead() {
        guard let clip = selectedClip ?? project.clips.first(where: { $0.contains(timelineTime: engine.playhead) }),
              let (left, right) = clip.split(atTimelineTime: engine.playhead) else { return }
        mutate { project in
            project.remove(clipID: clip.id)
            project.clips.append(left)
            project.clips.append(right)
        }
        selectedClipID = left.id
    }

    // MARK: - Snapping

    /// Snap candidates: other clips' edges, whole seconds grid, and the
    /// dragged clip's own beat grid.
    func snappedTime(_ proposed: Double, for clip: Clip) -> Double {
        guard AppSettings.shared.snapEnabled else { return max(0, proposed) }
        let threshold = 10.0 / max(pixelsPerSecond, 0.5)   // ~10 px
        var candidates: [Double] = [0]
        for other in project.clips where other.id != clip.id {
            candidates.append(other.startTime)
            candidates.append(other.endTime)
        }
        if AppSettings.shared.snapToBeats,
           let asset = AssetLibrary.shared.asset(clip.assetID),
           let grid = asset.beatGrid {
            // Beats of other clips near the proposal.
            for other in project.clips where other.id != clip.id {
                guard let otherAsset = AssetLibrary.shared.asset(other.assetID),
                      let otherGrid = otherAsset.beatGrid else { continue }
                for beat in otherGrid {
                    let sourceOffset = beat - other.sourceStart
                    guard sourceOffset >= 0, sourceOffset <= other.sourceDuration else { continue }
                    let t = other.startTime + other.outputTime(forSourceOffset: sourceOffset)
                    if abs(t - proposed) < threshold * 2 { candidates.append(t) }
                }
            }
            _ = grid
        }
        var best = proposed
        var bestDistance = threshold
        for c in candidates {
            let d = abs(c - proposed)
            if d < bestDistance {
                bestDistance = d
                best = c
            }
        }
        return max(0, best)
    }

    // MARK: - Save / exit

    enum ExitPrompt {
        case none
        case firstSave      // save as draft / delete
        case changes        // save / discard
    }

    func exitPrompt() -> ExitPrompt {
        if !wasEverSaved { return project.clips.isEmpty ? .none : .firstSave }
        return hasUnsavedChanges ? .changes : .none
    }

    func saveProject(asDraft: Bool? = nil) {
        if let asDraft { project.isDraft = asDraft }
        ProjectStore.shared.save(project)
        savedSnapshot = project
    }

    func discardNewProject() {
        // Never saved — nothing on disk to remove but clean up unused assets.
        var referenced = Set<UUID>()
        for summary in ProjectStore.shared.summaries {
            if let other = ProjectStore.shared.load(summary.id) {
                referenced.formUnion(other.usedAssetIDs)
            }
        }
        AssetLibrary.shared.garbageCollect(referencedIDs: referenced)
    }

    func stopPlayback() {
        if engine.isPlaying { engine.pause() }
    }
}
