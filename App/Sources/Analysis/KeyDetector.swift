import Foundation
import Accelerate

struct KeyResult {
    var key: MusicalKey
    var confidence: Double   // 0...1
}

/// Key estimation: chromagram from FFT magnitudes, correlated against
/// Krumhansl-Kessler major/minor profiles in all 12 rotations.
enum KeyDetector {
    static let sampleRate = 11025.0
    static let frameSize = 4096
    static let hopSize = 2048

    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detect(samples: [Float]) -> KeyResult? {
        guard samples.count > frameSize * 4 else { return nil }
        let chroma = averageChroma(samples: samples)
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        return bestKey(chroma: chroma)
    }

    static func averageChroma(samples: [Float]) -> [Double] {
        let fft = FFT(size: frameSize)
        let bins = frameSize / 2
        var magnitudes = [Float](repeating: 0, count: bins)
        var chroma = [Double](repeating: 0, count: 12)

        // Precompute bin → pitch-class mapping for 55 Hz ... 2200 Hz.
        let binHz = sampleRate / Double(frameSize)
        var pitchClass = [Int](repeating: -1, count: bins)
        for bin in 1..<bins {
            let f = Double(bin) * binHz
            guard f >= 55, f <= 2200 else { continue }
            let midi = 12 * log2(f / 440.0) + 69
            let fractional = midi - midi.rounded()
            // Skip energy that falls between semitones (reduces smearing).
            guard abs(fractional) < 0.35 else { continue }
            pitchClass[bin] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var frame = [Float](repeating: 0, count: frameSize)
        var position = 0
        var frameCount = 0
        while position + frameSize <= samples.count {
            for i in 0..<frameSize { frame[i] = samples[position + i] }
            fft.magnitudes(of: frame, into: &magnitudes)

            var energy: Float = 0
            vDSP_sve(magnitudes, 1, &energy, vDSP_Length(bins))
            if energy > 0.5 {
                for bin in 1..<bins where pitchClass[bin] >= 0 {
                    chroma[pitchClass[bin]] += Double(log1pf(magnitudes[bin] * 10))
                }
                frameCount += 1
            }
            position += hopSize
        }
        guard frameCount > 0 else { return chroma }
        let total = chroma.reduce(0, +)
        if total > 0 {
            for i in 0..<12 { chroma[i] /= total }
        }
        return chroma
    }

    static func bestKey(chroma: [Double]) -> KeyResult? {
        precondition(chroma.count == 12)
        var scores: [(key: MusicalKey, score: Double)] = []
        for root in 0..<12 {
            scores.append((MusicalKey(root: root, isMinor: false),
                           pearson(chroma, rotated(majorProfile, by: root))))
            scores.append((MusicalKey(root: root, isMinor: true),
                           pearson(chroma, rotated(minorProfile, by: root))))
        }
        scores.sort { $0.score > $1.score }
        guard let best = scores.first else { return nil }
        let second = scores.count > 1 ? scores[1].score : 0
        let spread = best.score - second
        let confidence = min(max(spread * 5 + max(best.score, 0) * 0.3, 0), 1)
        return KeyResult(key: best.key, confidence: confidence)
    }

    /// Profile rotated so that index 0 corresponds to pitch class 0 (C) for a key rooted at `root`.
    private static func rotated(_ profile: [Double], by root: Int) -> [Double] {
        var out = [Double](repeating: 0, count: 12)
        for i in 0..<12 {
            out[(i + root) % 12] = profile[i]
        }
        return out
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var num = 0.0, denA = 0.0, denB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            num += da * db
            denA += da * da
            denB += db * db
        }
        let den = (denA * denB).squareRoot()
        return den > 0 ? num / den : 0
    }
}
