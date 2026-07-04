import Foundation

/// Runs the full analysis pipeline (waveform → BPM → key) off the main thread
/// and posts results back to the asset library.
enum AudioAnalyzer {
    static func analyzeInBackground(asset: AudioAsset) {
        let url = AppPaths.assetAudioFile(asset)
        let assetID = asset.id
        Task.detached(priority: .utility) {
            var updated = asset

            if let peaks = try? WaveformPeaks.extract(url: url) {
                try? peaks.write(to: AppPaths.assetPeaksFile(assetID))
            }

            // Analyze up to 3 minutes from a bit past the intro.
            let analysisStart = min(asset.duration * 0.1, 20.0)
            let analysisLength = min(asset.duration - analysisStart, 180.0)

            if analysisLength > 8,
               let bpmSamples = try? loadWindow(url: url,
                                                sampleRate: BPMDetector.sampleRate,
                                                start: analysisStart,
                                                length: analysisLength),
               let result = BPMDetector.detect(samples: bpmSamples) {
                updated.bpm = normalizeBPM(result.bpm)
                updated.bpmConfidence = result.confidence
                updated.beatGrid = extendBeatGrid(result.beatTimes.map { $0 + analysisStart },
                                                  bpm: updated.bpm ?? result.bpm,
                                                  duration: asset.duration)
            }

            if analysisLength > 8,
               let keySamples = try? loadWindow(url: url,
                                                sampleRate: KeyDetector.sampleRate,
                                                start: analysisStart,
                                                length: analysisLength),
               let keyResult = KeyDetector.detect(samples: keySamples) {
                updated.key = keyResult.key
                updated.keyConfidence = keyResult.confidence
            }

            updated.analysisDone = true
            let final = updated
            await MainActor.run {
                // Keep any stems state that changed while we were analyzing.
                if let current = AssetLibrary.shared.asset(assetID) {
                    var merged = final
                    merged.stems = current.stems
                    AssetLibrary.shared.update(merged)
                }
            }
        }
    }

    /// Loads a window of the file as mono floats at the given rate.
    private static func loadWindow(url: URL, sampleRate: Double, start: Double, length: Double) throws -> [Float] {
        let all = try AudioFileLoader.loadMono(url: url,
                                               targetSampleRate: sampleRate,
                                               maxDuration: start + length)
        let startIndex = min(Int(start * sampleRate), max(all.count - 1, 0))
        return Array(all[startIndex...])
    }

    /// Folds extreme BPM into the 70...180 usable range (half/double-time ambiguity).
    private static func normalizeBPM(_ bpm: Double) -> Double {
        var value = bpm
        while value > 185 { value /= 2 }
        while value < 65 { value *= 2 }
        return (value * 10).rounded() / 10
    }

    /// Extends detected beats across the whole file assuming a stable tempo.
    private static func extendBeatGrid(_ beats: [Double], bpm: Double, duration: Double) -> [Double] {
        guard beats.count > 4, bpm > 0 else { return beats }
        let interval = 60.0 / bpm
        var grid: [Double] = []
        // Anchor on the median beat to be robust to edge errors.
        let anchor = beats[beats.count / 2]
        var t = anchor
        while t > interval { t -= interval }
        while t < duration {
            grid.append(t)
            t += interval
        }
        return grid
    }
}
