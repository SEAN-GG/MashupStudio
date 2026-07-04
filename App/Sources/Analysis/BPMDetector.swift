import Foundation
import Accelerate

struct BPMResult {
    var bpm: Double
    var confidence: Double     // 0...1
    var beatTimes: [Double]    // seconds, relative to the analyzed audio start
}

/// Tempo estimation: spectral-flux onset envelope → autocorrelation with a
/// log-tempo prior → parabolic refinement → dynamic-programming beat tracking.
enum BPMDetector {
    static let sampleRate = 22050.0
    static let frameSize = 1024
    static let hopSize = 256
    static var envelopeRate: Double { sampleRate / Double(hopSize) }

    static func detect(samples: [Float]) -> BPMResult? {
        guard samples.count > Int(sampleRate) * 8 else { return nil }
        let envelope = onsetEnvelope(samples: samples)
        guard envelope.count > 512 else { return nil }

        guard let (period, confidence) = estimatePeriod(envelope: envelope) else { return nil }
        let bpm = 60.0 * envelopeRate / period
        let beats = trackBeats(envelope: envelope, period: period)
        let beatTimes = beats.map { Double($0) / envelopeRate }
        return BPMResult(bpm: bpm, confidence: confidence, beatTimes: beatTimes)
    }

    // MARK: - Onset envelope

    static func onsetEnvelope(samples: [Float]) -> [Float] {
        let fft = FFT(size: frameSize)
        let bins = frameSize / 2
        var previous = [Float](repeating: 0, count: bins)
        var magnitudes = [Float](repeating: 0, count: bins)
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hopSize)

        var frame = [Float](repeating: 0, count: frameSize)
        var position = 0
        while position + frameSize <= samples.count {
            for i in 0..<frameSize { frame[i] = samples[position + i] }
            fft.magnitudes(of: frame, into: &magnitudes)
            // log compression
            var flux: Float = 0
            for i in 1..<bins {
                let current = log1pf(magnitudes[i] * 10)
                let diff = current - previous[i]
                if diff > 0 { flux += diff }
                previous[i] = current
            }
            envelope.append(flux)
            position += hopSize
        }

        // Remove local mean (adaptive) and half-wave rectify.
        let smoothWindow = Int(envelopeRate * 1.0) | 1
        var mean = movingAverage(envelope, window: smoothWindow)
        var detrended = [Float](repeating: 0, count: envelope.count)
        for i in 0..<envelope.count {
            detrended[i] = max(envelope[i] - mean[i], 0)
        }
        // Standardize
        var m: Float = 0
        var sd: Float = 0
        vDSP_normalize(detrended, 1, nil, 1, &m, &sd, vDSP_Length(detrended.count))
        if sd > 0 {
            var negMean = -m
            var invSD = 1 / sd
            vDSP_vsadd(detrended, 1, &negMean, &detrended, 1, vDSP_Length(detrended.count))
            vDSP_vsmul(detrended, 1, &invSD, &detrended, 1, vDSP_Length(detrended.count))
        }
        mean.removeAll()
        return detrended
    }

    private static func movingAverage(_ x: [Float], window: Int) -> [Float] {
        guard x.count > window, window > 2 else { return [Float](repeating: 0, count: x.count) }
        var result = [Float](repeating: 0, count: x.count)
        let half = window / 2
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }
        for i in 0..<x.count {
            let lo = max(0, i - half)
            let hi = min(x.count, i + half + 1)
            result[i] = (prefix[hi] - prefix[lo]) / Float(hi - lo)
        }
        return result
    }

    // MARK: - Period estimation

    /// Returns (period in envelope frames, confidence 0...1).
    static func estimatePeriod(envelope: [Float]) -> (Double, Double)? {
        let fps = envelopeRate
        let minBPM = 55.0, maxBPM = 210.0
        let minLag = Int(60.0 * fps / maxBPM)
        let maxLag = min(Int(60.0 * fps / minBPM), envelope.count / 3)
        guard maxLag > minLag + 4 else { return nil }

        let n = envelope.count
        var ac = [Float](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { buf in
            for lag in minLag...maxLag {
                var dot: Float = 0
                vDSP_dotpr(buf.baseAddress!, 1, buf.baseAddress! + lag, 1, &dot, vDSP_Length(n - lag))
                ac[lag] = dot / Float(n - lag)
            }
        }

        // Log-tempo prior centered at 125 BPM.
        func prior(_ bpm: Double) -> Double {
            let x = log2(bpm / 125.0) / 0.75
            return exp(-0.5 * x * x)
        }

        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let bpm = 60.0 * fps / Double(lag)
            // Harmonic support: reward lags whose double also autocorrelates.
            var support = Double(ac[lag])
            if lag * 2 <= maxLag { support += 0.5 * Double(ac[lag * 2]) }
            if lag % 2 == 0 && lag / 2 >= minLag { support += 0.25 * Double(ac[lag / 2]) }
            let score = support * prior(bpm)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }

        // Parabolic interpolation around the peak for sub-frame precision.
        var refined = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let y0 = Double(ac[bestLag - 1]), y1 = Double(ac[bestLag]), y2 = Double(ac[bestLag + 1])
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 1e-9 {
                let delta = 0.5 * (y0 - y2) / denom
                if abs(delta) < 1 { refined += delta }
            }
        }

        // Confidence: peak vs mean of the autocorrelation in range.
        var meanAC: Float = 0
        ac[minLag...maxLag].withUnsafeBufferPointer { seg in
            vDSP_meanv(seg.baseAddress!, 1, &meanAC, vDSP_Length(seg.count))
        }
        let peak = Double(ac[bestLag])
        let confidence = min(max((peak - Double(meanAC)) / max(peak, 1e-6), 0), 1)
        return (refined, confidence)
    }

    // MARK: - Beat tracking (dynamic programming, Ellis 2007)

    static func trackBeats(envelope: [Float], period: Double) -> [Int] {
        let n = envelope.count
        guard n > 8, period > 4 else { return [] }
        let alpha: Float = 100
        var score = [Float](repeating: 0, count: n)
        var backlink = [Int](repeating: -1, count: n)

        let windowLo = Int((period * 0.5).rounded())
        let windowHi = Int((period * 2.0).rounded())

        for t in 0..<n {
            score[t] = envelope[t]
            let lo = t - windowHi
            let hi = t - windowLo
            guard hi >= 0 else { continue }
            var best: Float = -.infinity
            var bestIdx = -1
            for tau in max(lo, 0)...hi {
                let delta = Float(t - tau)
                let logRatio = logf(delta / Float(period))
                let transition = score[tau] - alpha * logRatio * logRatio
                if transition > best {
                    best = transition
                    bestIdx = tau
                }
            }
            if bestIdx >= 0 && best > -.infinity {
                score[t] += best
                backlink[t] = bestIdx
            }
        }

        // Start from the best score near the end.
        var endT = n - 1
        var bestEnd: Float = -.infinity
        let searchStart = max(0, n - Int(period * 2))
        for t in searchStart..<n where score[t] > bestEnd {
            bestEnd = score[t]
            endT = t
        }

        var beats: [Int] = []
        var t = endT
        while t >= 0 {
            beats.append(t)
            t = backlink[t]
        }
        return beats.reversed()
    }
}
