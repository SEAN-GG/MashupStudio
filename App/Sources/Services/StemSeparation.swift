import Foundation
import AVFoundation
import Observation

/// Interface to an AI source-separation backend producing 4 stems.
protocol StemSeparating {
    /// Separates interleaved stereo 44.1 kHz audio. Returns per-stem interleaved
    /// stereo buffers of the same length. `progress` is 0...1.
    func separate(left: [Float], right: [Float],
                  progress: @escaping (Double) -> Void) throws -> [StemKind: (left: [Float], right: [Float])]
}

enum StemSeparationError: Error, LocalizedError {
    case backendUnavailable
    case audioTooLong
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .backendUnavailable: return "הפרדת כלים מלאה תתווסף בעדכון הבא — בינתיים פועל מצב EQ משוער"
        case .audioTooLong: return "השיר ארוך מדי להפרדת כלים (מקסימום 10 דקות)"
        case .processingFailed: return "הפרדת הכלים נכשלה"
        }
    }
}

/// Queues and runs stem-separation jobs, one at a time, updating the asset library.
@Observable
@MainActor
final class StemJobManager {
    static let shared = StemJobManager()

    static var backendAvailable: Bool {
        #if DEMUCS_ENABLED
        return true
        #else
        return false
        #endif
    }

    private var runningAssetID: UUID?

    private init() {}

    func requestSeparation(assetID: UUID) {
        guard Self.backendAvailable else {
            AssetLibrary.shared.setStemsState(.failed(message: StemSeparationError.backendUnavailable.localizedDescription ?? ""), for: assetID)
            return
        }
        guard runningAssetID == nil else { return }
        guard let asset = AssetLibrary.shared.asset(assetID), !asset.stems.isReady else { return }
        guard asset.duration <= 600 else {
            AssetLibrary.shared.setStemsState(.failed(message: StemSeparationError.audioTooLong.localizedDescription ?? ""), for: assetID)
            return
        }

        runningAssetID = assetID
        AssetLibrary.shared.setStemsState(.processing(progress: 0), for: assetID)
        let url = AppPaths.assetAudioFile(asset)

        Task.detached(priority: .userInitiated) {
            do {
                let stems = try Self.runSeparation(url: url) { p in
                    Task { @MainActor in
                        AssetLibrary.shared.setStemsState(.processing(progress: p), for: assetID)
                    }
                }
                try Self.writeStems(stems, assetID: assetID)
                await MainActor.run {
                    AssetLibrary.shared.setStemsState(.ready, for: assetID)
                    StemJobManager.shared.runningAssetID = nil
                }
            } catch {
                await MainActor.run {
                    AssetLibrary.shared.setStemsState(.failed(message: error.localizedDescription), for: assetID)
                    StemJobManager.shared.runningAssetID = nil
                }
            }
        }
    }

    // MARK: - Job body (off main thread)

    private nonisolated static func runSeparation(url: URL,
                                                  progress: @escaping (Double) -> Void) throws -> [StemKind: (left: [Float], right: [Float])] {
        #if DEMUCS_ENABLED
        let (left, right) = try loadStereo(url: url, sampleRate: 44100)
        let separator = DemucsSeparator()
        return try separator.separate(left: left, right: right, progress: progress)
        #else
        throw StemSeparationError.backendUnavailable
        #endif
    }

    nonisolated static func loadStereo(url: URL, sampleRate: Double) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: 2,
                                               interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw StemSeparationError.processingFailed
        }
        let chunkFrames: AVAudioFrameCount = 65536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames * 2) else {
            throw StemSeparationError.processingFailed
        }
        var left: [Float] = []
        var right: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: inBuffer, frameCount: chunkFrames)
            if inBuffer.frameLength == 0 { break }
            var consumed = false
            var done = false
            while !done {
                outBuffer.frameLength = 0
                var err: NSError?
                let status = converter.convert(to: outBuffer, error: &err) { _, inputStatus in
                    if consumed { inputStatus.pointee = .noDataNow; return nil }
                    consumed = true
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .error { throw StemSeparationError.processingFailed }
                if outBuffer.frameLength > 0, let data = outBuffer.floatChannelData {
                    left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength)))
                    right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: Int(outBuffer.frameLength)))
                }
                if status == .inputRanDry || outBuffer.frameLength == 0 { done = true }
            }
        }
        return (left, right)
    }

    /// Writes stems as AAC files next to the asset.
    private nonisolated static func writeStems(_ stems: [StemKind: (left: [Float], right: [Float])],
                                               assetID: UUID) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 44100, channels: 2, interleaved: false) else {
            throw StemSeparationError.processingFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]
        for (kind, channels) in stems {
            let url = AppPaths.stemFile(assetID: assetID, kind: kind)
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = channels.left.count
            let chunk = 65536
            var offset = 0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
                throw StemSeparationError.processingFailed
            }
            while offset < total {
                let n = min(chunk, total - offset)
                guard let data = buffer.floatChannelData else { throw StemSeparationError.processingFailed }
                channels.left.withUnsafeBufferPointer { src in
                    data[0].update(from: src.baseAddress! + offset, count: n)
                }
                channels.right.withUnsafeBufferPointer { src in
                    data[1].update(from: src.baseAddress! + offset, count: n)
                }
                buffer.frameLength = AVAudioFrameCount(n)
                try file.write(from: buffer)
                offset += n
            }
        }
    }
}
