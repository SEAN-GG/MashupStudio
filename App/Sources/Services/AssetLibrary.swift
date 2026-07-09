import Foundation
import AVFoundation
import Observation

enum MediaImportError: Error {
    case noAudioTrack
    case extractionFailed
}

/// Shared library of imported audio files and their analysis state.
@Observable
@MainActor
final class AssetLibrary {
    static let shared = AssetLibrary()

    private(set) var assets: [UUID: AudioAsset] = [:]
    private var peaksCache: [UUID: WaveformPeaks] = [:]

    private init() {
        load()
    }

    func asset(_ id: UUID) -> AudioAsset? { assets[id] }

    func audioURL(for assetID: UUID) -> URL? {
        guard let asset = assets[assetID] else { return nil }
        return AppPaths.assetAudioFile(asset)
    }

    func peaks(for assetID: UUID) -> WaveformPeaks? {
        if let cached = peaksCache[assetID] { return cached }
        guard assets[assetID] != nil else { return nil }
        guard let loaded = try? WaveformPeaks.read(from: AppPaths.assetPeaksFile(assetID)) else { return nil }
        peaksCache[assetID] = loaded
        return loaded
    }

    func update(_ asset: AudioAsset) {
        assets[asset.id] = asset
        persist()
    }

    func setStemsState(_ state: StemsState, for assetID: UUID) {
        guard var asset = assets[assetID] else { return }
        asset.stems = state
        assets[assetID] = asset
        // Progress updates are frequent; only persist meaningful transitions.
        if !state.isProcessing { persist() }
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "mpg", "mpeg"]

    /// Imports audio files directly; for videos, extracts the audio track first.
    func importMedia(from sourceURL: URL) async throws -> AudioAsset {
        guard Self.videoExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            return try importFile(from: sourceURL)
        }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let fileName = "audio.m4a"
        let folder = AppPaths.assetFolder(id)
        let destination = folder.appendingPathComponent(fileName)

        let avAsset = AVURLAsset(url: sourceURL)
        guard let audioTracks = try? await avAsset.loadTracks(withMediaType: .audio),
              !audioTracks.isEmpty else {
            throw MediaImportError.noAudioTrack
        }
        guard let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaImportError.extractionFailed
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: folder)
            throw MediaImportError.extractionFailed
        }

        let info = try AudioFileLoader.info(url: destination)
        var title = sourceURL.deletingPathExtension().lastPathComponent
        if title.isEmpty { title = "שיר ללא שם" }

        let asset = AudioAsset(id: id,
                               title: title,
                               fileName: fileName,
                               duration: info.duration,
                               sampleRate: info.sampleRate,
                               channelCount: info.channels,
                               importedAt: Date())
        assets[id] = asset
        persist()
        AudioAnalyzer.analyzeInBackground(asset: asset)
        return asset
    }

    /// Copies a picked file into the library and starts analysis in the background.
    func importFile(from sourceURL: URL) throws -> AudioAsset {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased()
        let fileName = "audio.\(ext)"
        let folder = AppPaths.assetFolder(id)
        let destination = folder.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let info = try AudioFileLoader.info(url: destination)
        var title = sourceURL.deletingPathExtension().lastPathComponent
        if title.isEmpty { title = "שיר ללא שם" }

        let asset = AudioAsset(id: id,
                               title: title,
                               fileName: fileName,
                               duration: info.duration,
                               sampleRate: info.sampleRate,
                               channelCount: info.channels,
                               importedAt: Date())
        assets[id] = asset
        persist()
        AudioAnalyzer.analyzeInBackground(asset: asset)
        return asset
    }

    func deleteAsset(_ id: UUID) {
        assets.removeValue(forKey: id)
        peaksCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: AppPaths.assetsDir.appendingPathComponent(id.uuidString, isDirectory: true))
        persist()
    }

    /// Removes assets referenced by no project (called after project deletion).
    func garbageCollect(referencedIDs: Set<UUID>) {
        for id in assets.keys where !referencedIDs.contains(id) {
            deleteAsset(id)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.assetIndexFile),
              let list = try? JSONDecoder().decode([AudioAsset].self, from: data) else { return }
        for var asset in list {
            // A stale "processing" state from a previous run means the job died.
            if asset.stems.isProcessing { asset.stems = .none }
            assets[asset.id] = asset
        }
    }

    private func persist() {
        let list = Array(assets.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: AppPaths.assetIndexFile, options: .atomic)
        }
    }
}
