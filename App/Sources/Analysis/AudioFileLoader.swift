import Foundation
import AVFoundation

enum AudioFileLoaderError: Error {
    case unreadable
    case conversionFailed
}

/// Loads audio files into mono float arrays, optionally resampled — the input
/// for all analysis (waveform, BPM, key).
enum AudioFileLoader {
    /// Reads the whole file as mono at the given sample rate.
    static func loadMono(url: URL, targetSampleRate: Double, maxDuration: Double? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw AudioFileLoaderError.conversionFailed
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioFileLoaderError.conversionFailed
        }

        var frameLimit = file.length
        if let maxDuration {
            frameLimit = min(frameLimit, AVAudioFramePosition(maxDuration * sourceFormat.sampleRate))
        }

        let chunkFrames: AVAudioFrameCount = 65536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: AVAudioFrameCount(Double(chunkFrames) * targetSampleRate / sourceFormat.sampleRate) + 4096) else {
            throw AudioFileLoaderError.conversionFailed
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(frameLimit) * targetSampleRate / sourceFormat.sampleRate) + 4096)
        file.framePosition = 0
        var reachedEnd = false

        while !reachedEnd && file.framePosition < frameLimit {
            let remaining = AVAudioFrameCount(min(Int64(chunkFrames), frameLimit - file.framePosition))
            try file.read(into: inBuffer, frameCount: remaining)
            if inBuffer.frameLength == 0 { break }
            if file.framePosition >= frameLimit { reachedEnd = true }

            var consumed = false
            var conversionDone = false
            while !conversionDone {
                outBuffer.frameLength = 0
                var convertError: NSError?
                let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                    if consumed {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .error { throw AudioFileLoaderError.conversionFailed }
                if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
                }
                if status == .inputRanDry || outBuffer.frameLength == 0 { conversionDone = true }
            }
        }
        return samples
    }

    /// Basic file properties without reading audio data.
    static func info(url: URL) throws -> (duration: Double, sampleRate: Double, channels: Int) {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate
        return (Double(file.length) / sr, sr, Int(file.processingFormat.channelCount))
    }
}
