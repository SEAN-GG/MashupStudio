import Foundation
import AVFoundation
import Observation
import UIKit

enum StemSeparationError: Error, LocalizedError {
    case backendUnavailable
    case audioTooLong
    case processingFailed
    case modelDownloadFailed

    var errorDescription: String? {
        switch self {
        case .backendUnavailable: return "הפרדת כלים מלאה לא זמינה בבילד הזה — פועל מצב EQ משוער"
        case .audioTooLong: return "השיר ארוך מדי להפרדת כלים (מקסימום 12 דקות)"
        case .processingFailed: return "הפרדת הכלים נכשלה"
        case .modelDownloadFailed: return "הורדת מודל ה-AI נכשלה — בדוק חיבור לאינטרנט ונסה שוב"
        }
    }
}

// MARK: - Model download

/// Downloads the htdemucs_6s ggml model (~55 MB) on first use.
final class StemModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let modelRemoteURL = URL(string: "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-6s-f16.bin")!

    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double) -> Void)?
    private var session: URLSession?

    static var isModelReady: Bool {
        let path = AppPaths.demucsModelFile.path
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 40_000_000   // sanity: a partial file won't pass
    }

    func download(progress: @escaping (Double) -> Void) async throws -> URL {
        if Self.isModelReady { return AppPaths.demucsModelFile }
        progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: Self.modelRemoteURL).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            let destination = AppPaths.demucsModelFile
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: StemSeparationError.modelDownloadFailed)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Job manager

/// Queues and runs stem-separation jobs, one at a time, updating the asset
/// library. Downloads the AI model on first use.
@Observable
@MainActor
final class StemJobManager {
    static let shared = StemJobManager()

    static var backendAvailable: Bool {
        DemucsBridge.isCompiledIn()
    }

    private var runningAssetID: UUID?
    var isBusy: Bool { runningAssetID != nil }

    private init() {}

    func requestSeparation(assetID: UUID) {
        guard Self.backendAvailable else {
            AssetLibrary.shared.setStemsState(.failed(message: StemSeparationError.backendUnavailable.localizedDescription ?? ""), for: assetID)
            return
        }
        guard runningAssetID == nil else { return }
        guard let asset = AssetLibrary.shared.asset(assetID), !asset.stems.isReady else { return }
        guard asset.duration <= 720 else {
            AssetLibrary.shared.setStemsState(.failed(message: StemSeparationError.audioTooLong.localizedDescription ?? ""), for: assetID)
            return
        }

        runningAssetID = assetID
        AssetLibrary.shared.setStemsState(.processing(progress: 0), for: assetID)
        UIApplication.shared.isIdleTimerDisabled = true
        let url = AppPaths.assetAudioFile(asset)

        Task.detached(priority: .userInitiated) {
            do {
                // 1. Model (10% of the progress bar)
                let downloader = StemModelDownloader()
                let modelURL = try await downloader.download { p in
                    Task { @MainActor in
                        AssetLibrary.shared.setStemsState(.processing(progress: p * 0.1), for: assetID)
                    }
                }

                // 2. Separation (90%)
                try DemucsSeparator.separate(audioURL: url,
                                             modelPath: modelURL.path,
                                             assetID: assetID) { p in
                    Task { @MainActor in
                        AssetLibrary.shared.setStemsState(.processing(progress: 0.1 + p * 0.9), for: assetID)
                    }
                }
                await MainActor.run {
                    AssetLibrary.shared.setStemsState(.ready, for: assetID)
                    StemJobManager.shared.finishJob()
                }
            } catch {
                await MainActor.run {
                    AssetLibrary.shared.setStemsState(.failed(message: error.localizedDescription), for: assetID)
                    StemJobManager.shared.finishJob()
                }
            }
        }
    }

    private func finishJob() {
        runningAssetID = nil
        UIApplication.shared.isIdleTimerDisabled = false
        DemucsBridge.unloadModel()
    }
}

// MARK: - Separator (chunked, memory-bounded)

/// Runs demucs on the file in ~70-second chunks with a 3-second crossfaded
/// overlap, streaming each stem straight into its AAC file so memory stays
/// bounded regardless of song length.
enum DemucsSeparator {
    static let sampleRate = 44100.0
    static let chunkSeconds = 70.0
    static let overlapSeconds = 3.0

    static func separate(audioURL: URL,
                         modelPath: String,
                         assetID: UUID,
                         progress: @escaping (Double) -> Void) throws {
        let (left, right) = try loadStereo(url: audioURL, sampleRate: sampleRate)
        let frames = left.count
        guard frames > Int(sampleRate) else { throw StemSeparationError.processingFailed }

        let chunk = Int(chunkSeconds * sampleRate)
        let overlap = Int(overlapSeconds * sampleRate)

        // Open one AAC writer per stem.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw StemSeparationError.processingFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256_000
        ]
        var writers: [StemKind: AVAudioFile] = [:]
        for kind in StemKind.allCases {
            let url = AppPaths.stemFile(assetID: assetID, kind: kind)
            try? FileManager.default.removeItem(at: url)
            writers[kind] = try AVAudioFile(forWriting: url, settings: settings,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        // Held tails (the last `overlap` frames of the previous chunk, per stem/channel).
        var tails: [StemKind: (l: [Float], r: [Float])] = [:]

        var position = 0    // next frame that still needs final output
        var chunkIndex = 0
        let totalChunks = max(1, Int(ceil(Double(frames - overlap) / Double(chunk - overlap))))

        while position < frames {
            let start = max(position - (position > 0 ? overlap : 0), 0)
            let end = min(start + chunk, frames)
            let len = end - start
            let baseProgress = Double(chunkIndex) / Double(totalChunks)

            let lChunk = Array(left[start..<end])
            let rChunk = Array(right[start..<end])
            var separated: [NSData]?
            lChunk.withUnsafeBufferPointer { lp in
                rChunk.withUnsafeBufferPointer { rp in
                    separated = DemucsBridge.separate(withModelPath: modelPath,
                                                      left: lp.baseAddress!,
                                                      right: rp.baseAddress!,
                                                      frames: Int64(len),
                                                      progress: { p in
                                                          progress(baseProgress + Double(p) / Double(totalChunks))
                                                      })
                }
            }
            guard let separated, separated.count >= StemKind.demucsOrder.count else {
                throw StemSeparationError.processingFailed
            }

            let isFinal = end >= frames
            let holdFrames = isFinal ? 0 : overlap        // keep for next blend
            let writeEnd = len - holdFrames               // exclusive, chunk-local

            for (sourceIndex, kind) in StemKind.demucsOrder.enumerated() {
                let blob = separated[sourceIndex]
                let floats = blob.bytes.assumingMemoryBound(to: Float.self)
                var lOut = [Float](repeating: 0, count: max(writeEnd, 0))
                var rOut = [Float](repeating: 0, count: max(writeEnd, 0))
                for i in 0..<max(writeEnd, 0) {
                    lOut[i] = floats[i]
                    rOut[i] = floats[len + i]
                }
                // Crossfade the first `overlap` frames with the held tail.
                if position > 0, let tail = tails[kind] {
                    let blend = min(overlap, writeEnd, tail.l.count)
                    for i in 0..<blend {
                        let w = Float(i) / Float(max(overlap, 1))
                        lOut[i] = tail.l[i] * (1 - w) + lOut[i] * w
                        rOut[i] = tail.r[i] * (1 - w) + rOut[i] * w
                    }
                }
                // Hold this chunk's tail for the next blend.
                if holdFrames > 0 {
                    var tl = [Float](repeating: 0, count: holdFrames)
                    var tr = [Float](repeating: 0, count: holdFrames)
                    for i in 0..<holdFrames {
                        tl[i] = floats[writeEnd + i]
                        tr[i] = floats[len + writeEnd + i]
                    }
                    tails[kind] = (tl, tr)
                }
                try append(lOut, rOut, to: writers[kind], format: format)
            }

            position = end - holdFrames
            chunkIndex += 1
            if isFinal { break }
        }
        progress(1.0)
    }

    private static func append(_ left: [Float], _ right: [Float],
                               to file: AVAudioFile?, format: AVAudioFormat) throws {
        guard let file, !left.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(left.count)),
              let data = buffer.floatChannelData else {
            throw StemSeparationError.processingFailed
        }
        left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress!, count: right.count) }
        buffer.frameLength = AVAudioFrameCount(left.count)
        try file.write(from: buffer)
    }

    static func loadStereo(url: URL, sampleRate: Double) throws -> ([Float], [Float]) {
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
}
