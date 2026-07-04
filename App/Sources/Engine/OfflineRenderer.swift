import Foundation
import AVFoundation
import Accelerate

enum ExportFormat: String, CaseIterable, Identifiable {
    case m4a, wav, mp3
    var id: String { rawValue }

    var label: String {
        switch self {
        case .m4a: return "M4A (AAC)"
        case .wav: return "WAV"
        case .mp3: return "MP3"
        }
    }

    var fileExtension: String { rawValue }

    static var available: [ExportFormat] {
        MP3Encoder.isAvailable ? [.mp3, .m4a, .wav] : [.m4a, .wav]
    }
}

enum RenderError: Error, LocalizedError {
    case emptyRange
    case engineFailure
    case cancelled
    case encodingFailure

    var errorDescription: String? {
        switch self {
        case .emptyRange: return "הטווח שנבחר ריק"
        case .engineFailure: return "שגיאת מנוע אודיו"
        case .cancelled: return "הייצוא בוטל"
        case .encodingFailure: return "שגיאה בקידוד הקובץ"
        }
    }
}

/// Offline (faster-than-realtime) rendering of a project range to an audio file.
/// Pass 1 renders every clip (with its tempo/pitch automation, stem mix, fades
/// and gain) to a temp PCM file; pass 2 streams a windowed mixdown to the encoder.
final class OfflineRenderer {
    static let sampleRate = 44100.0
    static let channels: AVAudioChannelCount = 2
    private static let blockFrames: AVAudioFrameCount = 2048

    struct ClipRender {
        let tempURL: URL
        let startFrameInRange: Int64   // may be negative (clip starts before range)
        let frameCount: Int64
    }

    /// Audio sources resolved on the main actor before rendering starts, so the
    /// render itself can run on any thread.
    struct RenderAsset {
        let audioURL: URL
        let stemURLs: [StemKind: URL]?   // non-nil when real stems are ready

        @MainActor
        static func resolveAll(for project: MixProject) -> [UUID: RenderAsset] {
            var map: [UUID: RenderAsset] = [:]
            for id in project.usedAssetIDs {
                guard let asset = AssetLibrary.shared.asset(id) else { continue }
                var stems: [StemKind: URL]?
                if asset.stems.isReady {
                    var urls: [StemKind: URL] = [:]
                    for kind in StemKind.allCases {
                        urls[kind] = AppPaths.stemFile(assetID: id, kind: kind)
                    }
                    stems = urls
                }
                map[id] = RenderAsset(audioURL: AppPaths.assetAudioFile(asset), stemURLs: stems)
            }
            return map
        }
    }

    /// Renders `project` over [rangeStart, rangeEnd) and writes the result.
    /// `progress` is called with 0...1. Check `isCancelled` between steps.
    static func render(project: MixProject,
                       assets: [UUID: RenderAsset],
                       rangeStart: Double,
                       rangeEnd: Double,
                       format: ExportFormat,
                       to destination: URL,
                       isCancelled: @escaping () -> Bool,
                       progress: @escaping (Double) -> Void) throws {
        let rangeLength = rangeEnd - rangeStart
        guard rangeLength > 0.05 else { throw RenderError.emptyRange }

        let clips = project.clips(intersecting: rangeStart, rangeEnd)
        guard !clips.isEmpty else { throw RenderError.emptyRange }

        var anySolo = false
        for lane in project.lanes where lane.isSoloed { anySolo = true }
        func laneGain(_ index: Int) -> Double {
            guard index < project.lanes.count else { return 1 }
            let lane = project.lanes[index]
            let audible: Bool = anySolo ? lane.isSoloed : !lane.isMuted
            return audible ? min(max(lane.volume, 0), 2) : 0
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Pass 1: render clips.
        var renders: [ClipRender] = []
        for (index, clip) in clips.enumerated() {
            if isCancelled() { throw RenderError.cancelled }
            let gain = laneGain(clip.laneIndex)
            guard gain > 0.0001 else { continue }
            let tempURL = tempDir.appendingPathComponent("\(clip.id.uuidString).pcm")
            if let source = assets[clip.assetID],
               let render = try renderClip(clip, source: source, laneGain: gain,
                                           rangeStart: rangeStart, to: tempURL) {
                renders.append(render)
            }
            progress(0.75 * Double(index + 1) / Double(clips.count))
        }

        // Pass 2: streamed mixdown + encode.
        let pcmDestination = format == .mp3
            ? tempDir.appendingPathComponent("mix.wav")
            : destination
        try mixdown(renders: renders,
                    rangeFrames: Int64(rangeLength * sampleRate),
                    format: format == .mp3 ? .wav : format,
                    to: pcmDestination,
                    isCancelled: isCancelled) { p in
            progress(0.75 + 0.2 * p)
        }

        if format == .mp3 {
            if isCancelled() { throw RenderError.cancelled }
            try MP3Encoder.encode(wavURL: pcmDestination, to: destination) { p in
                progress(0.95 + 0.05 * p)
            }
        }
        progress(1.0)
    }

    // MARK: - Pass 1: single clip → temp PCM

    /// Renders one clip through a mini offline engine. Returns nil for clips
    /// that produce no audio in range.
    private static func renderClip(_ clip: Clip,
                                   source: RenderAsset,
                                   laneGain: Double,
                                   rangeStart: Double,
                                   to tempURL: URL) throws -> ClipRender? {
        let engine = AVAudioEngine()
        guard let renderFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: channels,
                                               interleaved: false) else {
            throw RenderError.engineFailure
        }

        let stemMixer = AVAudioMixerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(stemMixer)
        engine.attach(timePitch)

        var eq: AVAudioUnitEQ?
        let useRealStems = source.stemURLs != nil && !clip.stemGains.isNeutral
        if !useRealStems && !clip.stemGains.isNeutral {
            let unit = AVAudioUnitEQ(numberOfBands: StemEQMapper.bandCount)
            StemEQMapper.configure(eq: unit)
            StemEQMapper.apply(gains: clip.stemGains, to: unit)
            engine.attach(unit)
            engine.connect(stemMixer, to: unit, format: nil)
            engine.connect(unit, to: timePitch, format: nil)
            eq = unit
        } else {
            engine.connect(stemMixer, to: timePitch, format: nil)
        }
        _ = eq
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)

        var sources: [(URL, StemKind?)] = []
        if useRealStems, let stemURLs = source.stemURLs {
            for kind in StemKind.allCases {
                if let url = stemURLs[kind] { sources.append((url, kind)) }
            }
        } else {
            sources.append((source.audioURL, nil))
        }

        var players: [AVAudioPlayerNode] = []
        for (url, stem) in sources {
            guard let file = try? AVAudioFile(forReading: url) else {
                if stem != nil { continue } else { return nil }
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: stemMixer, format: file.processingFormat)
            if let stem {
                player.volume = Float(min(max(clip.stemGains[stem], 0), 2))
            }
            let sr = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(clip.sourceStart * sr)
            let frames = AVAudioFrameCount(max(0, min(clip.sourceDuration * sr,
                                                      Double(file.length - startFrame))))
            guard frames > 0, startFrame >= 0, startFrame < file.length else { continue }
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
            players.append(player)
        }
        guard !players.isEmpty else { return nil }

        try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                             maximumFrameCount: blockFrames)
        try engine.start()
        for player in players { player.play() }

        guard let block = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: blockFrames) else {
            throw RenderError.engineFailure
        }

        let outputDuration = clip.outputDuration
        let totalFrames = Int64(outputDuration * sampleRate)
        guard totalFrames > 0 else { return nil }

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            throw RenderError.engineFailure
        }
        defer { try? handle.close() }

        var rendered: Int64 = 0
        var interleaved = [Float](repeating: 0, count: Int(blockFrames) * Int(channels))
        var ramp = [Float](repeating: 0, count: Int(blockFrames))

        while rendered < totalFrames {
            let t = Double(rendered) / sampleRate
            timePitch.rate = Float(clip.rate(at: t))
            timePitch.pitch = Float(clip.pitchCents(at: t))

            let toRender = AVAudioFrameCount(min(Int64(blockFrames), totalFrames - rendered))
            block.frameLength = 0
            let status = try engine.renderOffline(toRender, to: block)
            guard status == .success || status == .insufficientDataFromInputNode else {
                break
            }
            let frames = Int(block.frameLength)
            if frames == 0 {
                // Source exhausted (e.g. rate drift) — stop early.
                break
            }

            // Per-sample gain ramp: clip gain × fades × lane gain.
            let tEnd = Double(rendered + Int64(frames)) / sampleRate
            let g0 = Float(clip.combinedGain(at: t) * laneGain)
            let g1 = Float(clip.combinedGain(at: tEnd) * laneGain)
            var start = g0
            var step = frames > 1 ? (g1 - g0) / Float(frames - 1) : 0
            ramp.withUnsafeMutableBufferPointer { r in
                vDSP_vramp(&start, &step, r.baseAddress!, 1, vDSP_Length(frames))
            }

            guard let data = block.floatChannelData else { break }
            for ch in 0..<Int(channels) {
                vDSP_vmul(data[ch], 1, ramp, 1, data[ch], 1, vDSP_Length(frames))
            }
            // Interleave L/R for the temp file.
            for ch in 0..<Int(channels) {
                data[ch].withMemoryRebound(to: Float.self, capacity: frames) { src in
                    var i = ch
                    for f in 0..<frames {
                        interleaved[i] = src[f]
                        i += Int(channels)
                    }
                }
            }
            interleaved.withUnsafeBufferPointer { buf in
                let byteCount = frames * Int(channels) * MemoryLayout<Float>.size
                handle.write(Data(bytes: buf.baseAddress!, count: byteCount))
            }
            rendered += Int64(frames)
        }
        engine.stop()

        guard rendered > 0 else { return nil }
        let clipStartInRange = Int64((clip.startTime - rangeStart) * sampleRate)
        return ClipRender(tempURL: tempURL, startFrameInRange: clipStartInRange, frameCount: rendered)
    }

    // MARK: - Pass 2: streamed mixdown

    private static func mixdown(renders: [ClipRender],
                                rangeFrames: Int64,
                                format: ExportFormat,
                                to destination: URL,
                                isCancelled: @escaping () -> Bool,
                                progress: (Double) -> Void) throws {
        guard rangeFrames > 0 else { throw RenderError.emptyRange }
        try? FileManager.default.removeItem(at: destination)

        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .m4a, .mp3:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channels),
                AVEncoderBitRateKey: 256_000
            ]
        }

        guard let bufferFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: sampleRate,
                                               channels: channels,
                                               interleaved: false) else {
            throw RenderError.engineFailure
        }
        let outFile = try AVAudioFile(forWriting: destination, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)

        let windowFrames: Int64 = 44100 * 4
        guard let window = AVAudioPCMBuffer(pcmFormat: bufferFormat,
                                            frameCapacity: AVAudioFrameCount(windowFrames)) else {
            throw RenderError.engineFailure
        }

        var handles: [(FileHandle, ClipRender)] = []
        for render in renders {
            if let h = try? FileHandle(forReadingFrom: render.tempURL) {
                handles.append((h, render))
            }
        }
        defer { for (h, _) in handles { try? h.close() } }

        var written: Int64 = 0
        let chVals = Int(channels)
        while written < rangeFrames {
            if isCancelled() { throw RenderError.cancelled }
            let frames = Int(min(windowFrames, rangeFrames - written))
            guard let data = window.floatChannelData else { throw RenderError.engineFailure }
            for ch in 0..<chVals {
                vDSP_vclr(data[ch], 1, vDSP_Length(frames))
            }

            let windowStart = written
            let windowEnd = written + Int64(frames)
            for (handle, render) in handles {
                let clipStart = render.startFrameInRange
                let clipEnd = clipStart + render.frameCount
                let overlapStart = max(clipStart, windowStart)
                let overlapEnd = min(clipEnd, windowEnd)
                guard overlapEnd > overlapStart else { continue }
                let framesToRead = Int(overlapEnd - overlapStart)
                let offsetInClip = overlapStart - clipStart
                let byteOffset = UInt64(offsetInClip) * UInt64(chVals * MemoryLayout<Float>.size)
                try? handle.seek(toOffset: byteOffset)
                guard let raw = try? handle.read(upToCount: framesToRead * chVals * MemoryLayout<Float>.size),
                      !raw.isEmpty else { continue }
                let sampleCount = raw.count / MemoryLayout<Float>.size
                let readFrames = sampleCount / chVals
                let destOffset = Int(overlapStart - windowStart)
                raw.withUnsafeBytes { rawBuf in
                    let floats = rawBuf.bindMemory(to: Float.self)
                    for ch in 0..<chVals {
                        var i = ch
                        let dst = data[ch]
                        for f in 0..<readFrames {
                            dst[destOffset + f] += floats[i]
                            i += chVals
                        }
                    }
                }
            }

            // Gentle protection against clipping.
            for ch in 0..<chVals {
                var lo: Float = -0.985
                var hi: Float = 0.985
                vDSP_vclip(data[ch], 1, &lo, &hi, data[ch], 1, vDSP_Length(frames))
            }

            window.frameLength = AVAudioFrameCount(frames)
            try outFile.write(from: window)
            written += Int64(frames)
            progress(Double(written) / Double(rangeFrames))
        }
    }
}
