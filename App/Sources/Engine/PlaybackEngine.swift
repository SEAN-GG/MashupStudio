import Foundation
import AVFoundation
import Observation

/// Realtime multitrack playback of a project.
///
/// Graph per clip: player(s) → stemMixer → [EQ when using approximate stems]
/// → timePitch → clipMixer → laneMixer → mainMixer. Every chain includes a
/// timePitch node so processing latency is identical across clips and the
/// timeline stays aligned.
///
/// IMPORTANT invariant (crash fix, confirmed by a device crash log in
/// -[AVAudioPlayerNode playAtTime:]): the graph is ONLY mutated while the
/// engine is stopped. Every transport change stops the engine, rebuilds all
/// chains for clips ahead of the playhead, starts the engine, and only then
/// starts the players. No nodes are attached/connected while rendering.
@Observable
@MainActor
final class PlaybackEngine {
    private final class ClipChain {
        let clipID: UUID
        var players: [(player: AVAudioPlayerNode, stem: StemKind?)] = []
        var stemMixer = AVAudioMixerNode()
        var eq: AVAudioUnitEQ?
        var timePitch = AVAudioUnitTimePitch()
        var clipMixer = AVAudioMixerNode()
        /// Seconds after the playback anchor at which this clip becomes audible.
        var startOffset: Double = 0
        var finished = false

        init(clipID: UUID) {
            self.clipID = clipID
        }

        var allNodes: [AVAudioNode] {
            var nodes: [AVAudioNode] = players.map { $0.player }
            nodes.append(stemMixer)
            if let eq { nodes.append(eq) }
            nodes.append(timePitch)
            nodes.append(clipMixer)
            return nodes
        }
    }

    private let engine = AVAudioEngine()
    private var laneMixers: [AVAudioMixerNode] = []
    private var chains: [UUID: ClipChain] = [:]
    private var driver: DisplayLinkDriver?

    // Transport state (observable)
    private(set) var isPlaying = false
    private(set) var playhead: Double = 0
    var loopEnabled = false
    var loopStart: Double = 0
    var loopEnd: Double = 0

    /// Set when the audio engine reports a failure; shown as an alert.
    var lastError: String?

    // Anchors for the wall-clock ↔ timeline mapping while playing.
    private var anchorMediaTime: Double = 0
    private var anchorPlayhead: Double = 0

    /// Supplies the current project state; set by the editor.
    var projectProvider: (() -> MixProject?)?

    init() {
        driver = DisplayLinkDriver { [weak self] in
            self?.pump()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    private var project: MixProject? { projectProvider?() }

    // MARK: - Transport

    func play() {
        guard !isPlaying, let project, !project.clips.isEmpty else { return }
        AudioSessionManager.activatePlayback()
        if playhead >= project.duration - 0.01 { playhead = 0 }
        startPlayback(from: playhead)
    }

    func pause() {
        guard isPlaying else { return }
        playhead = currentTime()
        stopAllPlayback()
    }

    func stopToStart() {
        stopAllPlayback()
        playhead = 0
    }

    func seek(to time: Double) {
        let clamped = max(0, time)
        if isPlaying {
            stopAllPlayback()
            playhead = clamped
            startPlayback(from: clamped)
        } else {
            playhead = clamped
        }
    }

    /// Call after any edit that changes clips while playing.
    func projectDidChange() {
        guard isPlaying else { return }
        let t = currentTime()
        stopAllPlayback()
        playhead = t
        startPlayback(from: t)
    }

    func currentTime() -> Double {
        guard isPlaying else { return playhead }
        return anchorPlayhead + max(0, CACurrentMediaTime() - anchorMediaTime)
    }

    // MARK: - Playback internals

    private func startPlayback(from time: Double) {
        guard let project else { return }
        playhead = time

        // 1. Build the whole graph with the engine stopped.
        engine.stop()
        if let exception = MSCatchException({ [self] in
            teardownChains()
            rebuildLaneMixers(count: project.lanes.count)
            for clip in project.clips where clip.endTime > time + 0.02 {
                if let chain = buildChain(for: clip, playheadAtStart: time) {
                    chains[clip.id] = chain
                }
            }
        }) {
            reportFailure(exception)
            return
        }
        guard !chains.isEmpty else { return }
        applyLaneLevels(project: project)

        // 2. Start the engine.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lastError = "מנוע האודיו לא הצליח להתחיל: \(error.localizedDescription)"
            teardownChains()
            return
        }

        // 3. Anchor the clock and start the players.
        let startDelay = 0.20
        anchorMediaTime = CACurrentMediaTime() + startDelay
        anchorPlayhead = time
        if let exception = MSCatchException({ [self] in
            for chain in chains.values {
                let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: anchorMediaTime + chain.startOffset))
                for (player, _) in chain.players {
                    player.play(at: when)
                }
            }
        }) {
            engine.stop()
            reportFailure(exception)
            return
        }

        isPlaying = true
        driver?.start()
    }

    private func stopAllPlayback() {
        isPlaying = false
        driver?.stop()
        _ = MSCatchException { [self] in
            for chain in chains.values {
                for (player, _) in chain.players {
                    player.stop()
                }
            }
            engine.stop()
            teardownChains()
        }
    }

    private func teardownChains() {
        for chain in chains.values {
            for node in chain.allNodes {
                engine.detach(node)
            }
        }
        chains.removeAll()
    }

    private func reportFailure(_ exception: NSException) {
        _ = MSCatchException { [self] in
            engine.stop()
            teardownChains()
        }
        isPlaying = false
        driver?.stop()
        lastError = "שגיאת מנוע אודיו: \(exception.reason ?? exception.name.rawValue)"
    }

    /// Explicit connection format everywhere: connecting with `format: nil`
    /// from a node whose output format is still undefined (a fresh mixer with
    /// no inputs) raises an NSException on device.
    private var busFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            ?? engine.outputNode.outputFormat(forBus: 0)
    }

    private func rebuildLaneMixers(count: Int) {
        guard laneMixers.count != count else { return }
        for mixer in laneMixers { engine.detach(mixer) }
        laneMixers = (0..<count).map { _ in AVAudioMixerNode() }
        for mixer in laneMixers {
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: busFormat)
        }
    }

    /// Builds and schedules the node chain for one clip (engine must be stopped).
    private func buildChain(for clip: Clip, playheadAtStart: Double) -> ClipChain? {
        guard let asset = AssetLibrary.shared.asset(clip.assetID) else { return nil }
        guard clip.laneIndex < laneMixers.count else { return nil }

        let outputOffset = max(0, playheadAtStart - clip.startTime)
        guard outputOffset < clip.outputDuration - 0.02 else { return nil }
        let sourceOffset = clip.sourceOffset(atOutputTime: outputOffset)

        let chain = ClipChain(clipID: clip.id)
        chain.startOffset = max(clip.startTime - playheadAtStart, 0)
        let useRealStems = asset.stems.isReady && !clip.stemGains.isNeutral

        var sources: [(URL, StemKind?)] = []
        if useRealStems {
            for kind in StemKind.allCases {
                sources.append((AppPaths.stemFile(assetID: asset.id, kind: kind), kind))
            }
        } else {
            sources.append((AppPaths.assetAudioFile(asset), nil))
        }

        // Open files first; bail cleanly if any is unreadable.
        var files: [(AVAudioFile, StemKind?)] = []
        for (url, stem) in sources {
            guard let file = try? AVAudioFile(forReading: url) else {
                if stem != nil { continue }
                return nil
            }
            files.append((file, stem))
        }
        guard !files.isEmpty else { return nil }

        // One explicit format for the whole chain (players feed the stem mixer
        // in their own file format; the mixer converts).
        let chainRate = files[0].0.processingFormat.sampleRate
        guard let chainFormat = AVAudioFormat(standardFormatWithSampleRate: chainRate > 0 ? chainRate : 44100,
                                              channels: 2) else { return nil }

        engine.attach(chain.stemMixer)
        engine.attach(chain.timePitch)
        engine.attach(chain.clipMixer)

        if !useRealStems && !clip.stemGains.isNeutral {
            let eq = AVAudioUnitEQ(numberOfBands: StemEQMapper.bandCount)
            StemEQMapper.configure(eq: eq)
            StemEQMapper.apply(gains: clip.stemGains, to: eq)
            chain.eq = eq
            engine.attach(eq)
            engine.connect(chain.stemMixer, to: eq, format: chainFormat)
            engine.connect(eq, to: chain.timePitch, format: chainFormat)
        } else {
            engine.connect(chain.stemMixer, to: chain.timePitch, format: chainFormat)
        }
        engine.connect(chain.timePitch, to: chain.clipMixer, format: chainFormat)
        engine.connect(chain.clipMixer, to: laneMixers[clip.laneIndex], format: chainFormat)

        for (file, stem) in files {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: chain.stemMixer, format: file.processingFormat)
            chain.players.append((player, stem))

            let sr = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition((clip.sourceStart + sourceOffset) * sr)
            let remainingSource = clip.sourceDuration - sourceOffset
            let frameCount = AVAudioFrameCount(max(0, min(remainingSource * sr,
                                                          Double(file.length - startFrame))))
            guard frameCount > 0, startFrame >= 0, startFrame < file.length else { continue }
            player.scheduleSegment(file, startingFrame: startFrame,
                                   frameCount: frameCount, at: nil)
        }

        // Initial parameter state.
        let t0 = outputOffset
        chain.timePitch.rate = Float(clip.rate(at: t0))
        chain.timePitch.pitch = Float(clip.pitchCents(at: t0))
        chain.clipMixer.outputVolume = Float(clip.combinedGain(at: t0))
        applyStemGains(clip: clip, chain: chain)
        return chain
    }

    private func applyStemGains(clip: Clip, chain: ClipChain) {
        for (player, stem) in chain.players {
            if let stem {
                player.volume = Float(min(max(clip.stemGains[stem], 0), 2))
            } else {
                player.volume = 1
            }
        }
        if let eq = chain.eq {
            StemEQMapper.apply(gains: clip.stemGains, to: eq)
        }
    }

    private func applyLaneLevels(project: MixProject) {
        var anySolo = false
        for lane in project.lanes where lane.isSoloed { anySolo = true }
        for (index, mixer) in laneMixers.enumerated() {
            guard index < project.lanes.count else { continue }
            let lane = project.lanes[index]
            let audible: Bool = anySolo ? lane.isSoloed : !lane.isMuted
            mixer.outputVolume = audible ? Float(min(max(lane.volume, 0), 2)) : 0
        }
    }

    /// 60 Hz update: playhead, automation values, loop, end-of-project.
    /// No graph mutation happens here — every chain already exists.
    private func pump() {
        guard isPlaying, let project else { return }
        let now = currentTime()
        playhead = now

        // Loop region
        if loopEnabled, loopEnd > loopStart + 0.1, now >= loopEnd {
            seek(to: loopStart)
            return
        }

        // End of project
        if now > project.duration + 0.2 {
            pause()
            playhead = project.duration
            return
        }

        applyLaneLevels(project: project)

        for clip in project.clips {
            guard let chain = chains[clip.id] else { continue }
            let t = now - clip.startTime
            if t >= 0 && t <= clip.outputDuration {
                chain.timePitch.rate = Float(clip.rate(at: t))
                chain.timePitch.pitch = Float(clip.pitchCents(at: t))
                chain.clipMixer.outputVolume = Float(clip.combinedGain(at: t))
                applyStemGains(clip: clip, chain: chain)
            } else if t > clip.outputDuration + 0.3 && !chain.finished {
                chain.finished = true
                for (player, _) in chain.players { player.stop() }
            }
        }
    }
}
