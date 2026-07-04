import Foundation

/// An imported audio file plus its analysis results. Stored once in the shared
/// asset library and referenced by clips from any project.
struct AudioAsset: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var fileName: String          // relative to the asset's folder
    var duration: Double          // seconds
    var sampleRate: Double
    var channelCount: Int
    var importedAt: Date

    // Analysis (filled in asynchronously after import)
    var bpm: Double?
    var bpmConfidence: Double?
    var key: MusicalKey?
    var keyConfidence: Double?
    var beatGrid: [Double]?       // beat times in seconds from the start of the file
    var analysisDone: Bool = false
    var stems: StemsState = .none

    var displayBPM: String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}
