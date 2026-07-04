import Foundation

struct Lane: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var volume: Double = 1.0
    var isMuted: Bool = false
    var isSoloed: Bool = false
}

struct MixProject: Codable, Identifiable, Hashable {
    static let schemaVersion = 1

    var version: Int = MixProject.schemaVersion
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var lanes: [Lane] = [Lane(), Lane()]
    var clips: [Clip] = []
    var isDraft: Bool = true

    var duration: Double {
        clips.map(\.endTime).max() ?? 0
    }

    var usedAssetIDs: Set<UUID> {
        Set(clips.map(\.assetID))
    }

    func clips(onLane index: Int) -> [Clip] {
        clips.filter { $0.laneIndex == index }.sorted { $0.startTime < $1.startTime }
    }

    func clip(withID id: UUID) -> Clip? {
        clips.first { $0.id == id }
    }

    mutating func update(_ clip: Clip) {
        if let i = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[i] = clip
        }
    }

    mutating func remove(clipID: UUID) {
        clips.removeAll { $0.id == clipID }
    }

    /// Ensures lanes cover all clip lane indices plus one spare lane at the bottom.
    mutating func normalizeLanes() {
        let maxUsed = clips.map(\.laneIndex).max() ?? -1
        let needed = max(maxUsed + 2, 2)
        while lanes.count < needed { lanes.append(Lane()) }
        while lanes.count > needed && lanes.count > 2 {
            let lastUsed = clips.contains { $0.laneIndex >= lanes.count - 2 }
            if lastUsed { break }
            lanes.removeLast()
        }
    }

    /// Clips whose audible range intersects [from, to).
    func clips(intersecting from: Double, _ to: Double) -> [Clip] {
        clips.filter { $0.endTime > from && $0.startTime < to }
    }
}

/// Lightweight summary for the home screen.
struct ProjectSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var modifiedAt: Date
    var duration: Double
    var clipCount: Int
    var isDraft: Bool
}
