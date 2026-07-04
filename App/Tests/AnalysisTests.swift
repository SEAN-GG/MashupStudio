import XCTest
@testable import MashupStudio

final class AnalysisTests: XCTestCase {

    /// Click track at 120 BPM should be detected within ±2 BPM.
    func testBPMDetectionOnClickTrack() {
        let sr = BPMDetector.sampleRate
        let seconds = 40.0
        let bpm = 120.0
        let interval = 60.0 / bpm
        var samples = [Float](repeating: 0, count: Int(sr * seconds))
        var t = 0.25
        var generator = SeededGenerator(seed: 42)
        while t < seconds - 0.1 {
            let start = Int(t * sr)
            // 6 ms noise burst with fast decay — click-like.
            for i in 0..<Int(sr * 0.006) {
                let decay = expf(-Float(i) / Float(sr * 0.002))
                samples[start + i] += (Float.random(in: -1...1, using: &generator)) * decay
            }
            t += interval
        }
        guard let result = BPMDetector.detect(samples: samples) else {
            XCTFail("no BPM detected"); return
        }
        var detected = result.bpm
        while detected > 170 { detected /= 2 }
        while detected < 70 { detected *= 2 }
        XCTAssertEqual(detected, bpm, accuracy: 2.0)
        XCTAssertGreaterThan(result.beatTimes.count, 20)
    }

    /// A sustained C-major chord should be detected as C major (8B).
    func testKeyDetectionOnCMajorChord() {
        let sr = KeyDetector.sampleRate
        let seconds = 25.0
        let n = Int(sr * seconds)
        var samples = [Float](repeating: 0, count: n)
        // C4, E4, G4, C5 with a few harmonics.
        let freqs: [(Double, Float)] = [
            (261.63, 1.0), (329.63, 0.8), (392.00, 0.9), (523.25, 0.5),
            (523.25 * 2, 0.15), (659.26, 0.2), (784.0, 0.2)
        ]
        for i in 0..<n {
            let time = Double(i) / sr
            var v: Float = 0
            for (f, a) in freqs {
                v += a * Float(sin(2 * .pi * f * time))
            }
            samples[i] = v * 0.2
        }
        guard let result = KeyDetector.detect(samples: samples) else {
            XCTFail("no key detected"); return
        }
        XCTAssertEqual(result.key.root, 0, "expected C, got \(result.key.traditionalName)")
        XCTAssertFalse(result.key.isMinor)
        XCTAssertEqual(result.key.camelotName, "8B")
    }

    /// A minor chord should be classified as minor with the right root.
    func testKeyDetectionOnAMinorChord() {
        let sr = KeyDetector.sampleRate
        let seconds = 25.0
        let n = Int(sr * seconds)
        var samples = [Float](repeating: 0, count: n)
        // A3, C4, E4, A4 (A minor triad).
        let freqs: [(Double, Float)] = [
            (220.0, 1.0), (261.63, 0.85), (329.63, 0.9), (440.0, 0.5), (880.0, 0.15)
        ]
        for i in 0..<n {
            let time = Double(i) / sr
            var v: Float = 0
            for (f, a) in freqs {
                v += a * Float(sin(2 * .pi * f * time))
            }
            samples[i] = v * 0.2
        }
        guard let result = KeyDetector.detect(samples: samples) else {
            XCTFail("no key detected"); return
        }
        XCTAssertEqual(result.key.root, 9, "expected A, got \(result.key.traditionalName)")
    }

    func testFFTMagnitudePeak() {
        let size = 1024
        let fft = FFT(size: size)
        let sr = 8192.0
        let freq = 512.0    // lands exactly on bin 64
        var frame = [Float](repeating: 0, count: size)
        for i in 0..<size {
            frame[i] = Float(sin(2 * .pi * freq * Double(i) / sr))
        }
        var mags = [Float](repeating: 0, count: size / 2)
        fft.magnitudes(of: frame, into: &mags)
        let peakBin = mags.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(peakBin, 64)
    }
}

/// Deterministic RNG so the DSP tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
