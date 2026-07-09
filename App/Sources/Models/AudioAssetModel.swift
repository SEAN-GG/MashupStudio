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

    // Lyrics (optional so assets saved by older builds still decode)
    var lyrics: [LyricWord]? = nil
    var lyricsLanguage: String? = nil   // BCP-47 identifier used for transcription

    var displayBPM: String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }
}

/// One transcribed word of the song, timed in source seconds.
struct LyricWord: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var time: Double        // seconds from the start of the file
    var duration: Double
    var text: String
}
