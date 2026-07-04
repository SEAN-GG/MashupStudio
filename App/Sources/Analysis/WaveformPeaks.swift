import Foundation
import AVFoundation
import Accelerate

/// Downsampled waveform for drawing: RMS + peak per bucket.
/// Stored on disk next to the asset as a compact binary file.
struct WaveformPeaks: Codable {
    var bucketsPerSecond: Double
    var peaks: [Float]      // 0...1, one per bucket
    var rms: [Float]        // 0...1

    static let defaultBucketsPerSecond = 50.0

    func bucketIndex(forTime t: Double) -> Int {
        min(max(Int(t * bucketsPerSecond), 0), max(peaks.count - 1, 0))
    }

    /// Extracts peaks directly from a file without loading it all into memory.
    static func extract(url: URL, bucketsPerSecond: Double = defaultBucketsPerSecond) throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = Int(format.channelCount)
        let samplesPerBucket = max(Int(sr / bucketsPerSecond), 1)

        let chunkFrames: AVAudioFrameCount = 262144
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioFileLoaderError.unreadable
        }

        var peaks: [Float] = []
        var rmsValues: [Float] = []
        let totalBuckets = Int(Double(file.length) / Double(samplesPerBucket)) + 1
        peaks.reserveCapacity(totalBuckets)
        rmsValues.reserveCapacity(totalBuckets)

        var carry: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { throw AudioFileLoaderError.unreadable }

            // Downmix to mono
            var mono = [Float](repeating: 0, count: frames)
            for ch in 0..<channels {
                vDSP_vadd(mono, 1, data[ch], 1, &mono, 1, vDSP_Length(frames))
            }
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))

            var work = carry + mono
            carry.removeAll(keepingCapacity: true)
            var index = 0
            while index + samplesPerBucket <= work.count {
                work[index..<(index + samplesPerBucket)].withUnsafeBufferPointer { seg in
                    var maxMag: Float = 0
                    vDSP_maxmgv(seg.baseAddress!, 1, &maxMag, vDSP_Length(samplesPerBucket))
                    var meanSquare: Float = 0
                    vDSP_measqv(seg.baseAddress!, 1, &meanSquare, vDSP_Length(samplesPerBucket))
                    peaks.append(min(maxMag, 1))
                    rmsValues.append(min(sqrt(meanSquare), 1))
                }
                index += samplesPerBucket
            }
            if index < work.count {
                carry = Array(work[index...])
            }
        }
        if !carry.isEmpty {
            var maxMag: Float = 0
            var meanSquare: Float = 0
            carry.withUnsafeBufferPointer { seg in
                vDSP_maxmgv(seg.baseAddress!, 1, &maxMag, vDSP_Length(carry.count))
                vDSP_measqv(seg.baseAddress!, 1, &meanSquare, vDSP_Length(carry.count))
            }
            peaks.append(min(maxMag, 1))
            rmsValues.append(min(sqrt(meanSquare), 1))
        }
        return WaveformPeaks(bucketsPerSecond: sr / Double(samplesPerBucket), peaks: peaks, rms: rmsValues)
    }

    // MARK: - Binary persistence

    func write(to url: URL) throws {
        var data = Data()
        var magic: UInt32 = 0x57465031 // "WFP1"
        var bps = bucketsPerSecond
        var count = UInt32(peaks.count)
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &bps) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        peaks.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        rms.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> WaveformPeaks {
        let data = try Data(contentsOf: url)
        var offset = 0
        func load<T>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw AudioFileLoaderError.unreadable }
            let value = data.subdata(in: offset..<(offset + size)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            offset += size
            return value
        }
        let magic = try load(UInt32.self)
        guard magic == 0x57465031 else { throw AudioFileLoaderError.unreadable }
        let bps = try load(Double.self)
        let count = Int(try load(UInt32.self))
        let floatBytes = count * MemoryLayout<Float>.size
        guard offset + floatBytes * 2 <= data.count else { throw AudioFileLoaderError.unreadable }
        let peaks = data.subdata(in: offset..<(offset + floatBytes)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        offset += floatBytes
        let rms = data.subdata(in: offset..<(offset + floatBytes)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return WaveformPeaks(bucketsPerSecond: bps, peaks: peaks, rms: rms)
    }
}
