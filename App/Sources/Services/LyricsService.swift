import Foundation
import AVFoundation
import Speech
import Observation

enum LyricsError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case exportFailed
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "אין הרשאה לזיהוי דיבור — אפשר לאשר תחת הגדרות iOS ← פרטיות ← זיהוי דיבור"
        case .recognizerUnavailable:
            return "זיהוי דיבור לא זמין לשפה הזו במכשיר — נסה שפה אחרת"
        case .exportFailed:
            return "הכנת האודיו לתמלול נכשלה"
        case .recognitionFailed:
            return "התמלול נכשל — בדוק חיבור לאינטרנט ונסה שוב"
        }
    }
}

/// Word-level transcription of a song using Apple's speech recognition.
/// Audio is fed in ~50s chunks (the service limit) with a small overlap.
enum LyricsService {
    static let languages: [(code: String, label: String)] = [
        ("he-IL", "עברית"),
        ("en-US", "אנגלית"),
        ("ar-SA", "ערבית"),
        ("ru-RU", "רוסית"),
        ("fr-FR", "צרפתית"),
        ("es-ES", "ספרדית"),
    ]

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated static func transcribe(audioURL: URL,
                                       duration: Double,
                                       localeIdentifier: String,
                                       isCancelled: @escaping @Sendable () -> Bool,
                                       progress: @escaping @Sendable (Double) -> Void) async throws -> [LyricWord] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw LyricsError.recognizerUnavailable
        }

        let chunkLength = 50.0
        let overlap = 2.0
        var words: [LyricWord] = []
        var start = 0.0
        var lastError: Error?
        var anyChunkSucceeded = false

        while start < duration - 0.3 {
            if isCancelled() { break }
            let length = min(chunkLength, duration - start)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyrics-\(UUID().uuidString).m4a")
            do {
                try await exportChunk(from: audioURL, start: start, length: length, to: chunkURL)
                let segments = try await recognize(url: chunkURL, recognizer: recognizer)
                anyChunkSucceeded = true
                let minTime = words.last.map { $0.time + 0.05 } ?? -1
                for segment in segments {
                    let t = start + segment.timestamp
                    guard t > minTime else { continue }
                    let text = segment.substring.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    words.append(LyricWord(time: t,
                                           duration: max(segment.duration, 0.15),
                                           text: text))
                }
            } catch {
                // A silent chunk legitimately errors ("no speech") — keep going.
                lastError = error
            }
            try? FileManager.default.removeItem(at: chunkURL)
            progress(min((start + length) / duration, 1))
            start += chunkLength - overlap
        }

        if !anyChunkSucceeded, let lastError {
            throw (lastError as? LyricsError) ?? LyricsError.recognitionFailed
        }
        return words
    }

    private nonisolated static func exportChunk(from url: URL, start: Double, length: Double, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw LyricsError.exportFailed
        }
        export.outputURL = out
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
        await export.export()
        guard export.status == .completed else { throw LyricsError.exportFailed }
    }

    private nonisolated static func recognize(url: URL,
                                              recognizer: SFSpeechRecognizer) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .unspecified

        // Keeps the task alive until the final callback (released there).
        final class TaskBox: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
        }
        let box = TaskBox()

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let result, result.isFinal {
                    finished = true
                    box.task = nil
                    continuation.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    finished = true
                    box.task = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Job manager

/// Runs one transcription at a time and keeps UI-visible progress, so the
/// sheet can be dismissed while a song is being transcribed.
@Observable
@MainActor
final class LyricsJobManager {
    static let shared = LyricsJobManager()

    private(set) var activeAssetID: UUID?
    private(set) var progress: Double = 0
    var lastError: String?

    private final class CancelFlag: @unchecked Sendable {
        var cancelled = false
    }
    private var flag: CancelFlag?

    private init() {}

    /// True when the song's separated vocals will be used (much more accurate).
    func willUseVocalsStem(for assetID: UUID) -> Bool {
        guard let asset = AssetLibrary.shared.asset(assetID), asset.stems.isReady else { return false }
        return FileManager.default.fileExists(atPath: AppPaths.stemFile(assetID: assetID, kind: .vocals).path)
    }

    func transcribe(assetID: UUID, localeIdentifier: String) {
        guard activeAssetID == nil, let asset = AssetLibrary.shared.asset(assetID) else { return }
        activeAssetID = assetID
        progress = 0
        lastError = nil
        let flag = CancelFlag()
        self.flag = flag

        let audioURL = willUseVocalsStem(for: assetID)
            ? AppPaths.stemFile(assetID: assetID, kind: .vocals)
            : AppPaths.assetAudioFile(asset)
        let duration = asset.duration

        Task {
            defer { activeAssetID = nil }
            guard await LyricsService.requestAuthorization() else {
                lastError = LyricsError.notAuthorized.errorDescription
                return
            }
            do {
                let words = try await LyricsService.transcribe(
                    audioURL: audioURL,
                    duration: duration,
                    localeIdentifier: localeIdentifier,
                    isCancelled: { flag.cancelled }
                ) { p in
                    Task { @MainActor in
                        if LyricsJobManager.shared.activeAssetID == assetID {
                            LyricsJobManager.shared.progress = p
                        }
                    }
                }
                guard !flag.cancelled else { return }
                if var updated = AssetLibrary.shared.asset(assetID) {
                    updated.lyrics = words.isEmpty ? nil : words
                    updated.lyricsLanguage = localeIdentifier
                    AssetLibrary.shared.update(updated)
                }
                if words.isEmpty {
                    lastError = "לא זוהו מילים בשיר — נסה שפה אחרת, או הפרד כלים קודם כדי לתמלל את ערוץ השירה בלבד"
                }
            } catch {
                lastError = (error as? LyricsError)?.errorDescription
                    ?? LyricsError.recognitionFailed.errorDescription
            }
        }
    }

    func cancel() {
        flag?.cancelled = true
    }
}
