import Foundation
import Observation

@Observable
@MainActor
final class ProjectStore {
    static let shared = ProjectStore()

    private(set) var summaries: [ProjectSummary] = []

    private init() {
        refresh()
    }

    func refresh() {
        var found: [ProjectSummary] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.projectsDir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let project = try? JSONDecoder().decode(MixProject.self, from: data) {
                found.append(ProjectSummary(id: project.id,
                                            name: project.name,
                                            modifiedAt: project.modifiedAt,
                                            duration: project.duration,
                                            clipCount: project.clips.count,
                                            isDraft: project.isDraft))
            }
        }
        summaries = found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func load(_ id: UUID) -> MixProject? {
        guard let data = try? Data(contentsOf: AppPaths.projectFile(id)) else { return nil }
        var project = try? JSONDecoder().decode(MixProject.self, from: data)
        project?.normalizeLanes()
        return project
    }

    func save(_ project: MixProject) {
        var updated = project
        updated.modifiedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(updated) {
            try? data.write(to: AppPaths.projectFile(project.id), options: .atomic)
        }
        refresh()
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: AppPaths.projectFile(id))
        refresh()
        // Clean up audio files no other project references.
        var referenced = Set<UUID>()
        for summary in summaries {
            if let project = load(summary.id) {
                referenced.formUnion(project.usedAssetIDs)
            }
        }
        AssetLibrary.shared.garbageCollect(referencedIDs: referenced)
    }

    func duplicate(_ id: UUID) {
        guard var project = load(id) else { return }
        project.id = UUID()
        project.name += " (עותק)"
        project.createdAt = Date()
        project.isDraft = false
        save(project)
    }

    func rename(_ id: UUID, to name: String) {
        guard var project = load(id) else { return }
        project.name = name
        save(project)
    }

    func newProject() -> MixProject {
        let numbers = summaries.compactMap { summary -> Int? in
            guard summary.name.hasPrefix("פרויקט ") else { return nil }
            return Int(summary.name.dropFirst("פרויקט ".count))
        }
        let next = (numbers.max() ?? 0) + 1
        return MixProject(name: "פרויקט \(next)")
    }
}
