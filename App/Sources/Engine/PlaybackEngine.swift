import Foundation
import AVFoundation
import Observation

/// Realtime multitrack playback of a project.
///
/// Graph per clip: player(s) → stemMixer → [EQ when using approximate stems]
/// → timePitch → clipMixer → laneMixer → mainMixer. Every chain includes a
/// timePitch node so processing latency is identical across clips and the
/// timeline stays aligned.
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
        var started = false
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

    // Anchors for the wall-clock ↔ timeline mapping while playing.
    private var anchorMediaTime: Double = 0
    private var anchorPlayhead: Double = 0

    /// Supplies the current project state; set by the editor.
    var projectProvider: (() -> MixProject?)?

    private let scheduleLookahead: Double = 45.0

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
            stopAllPlayback(keepTransport: true)
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
        stopAllPlayback(keepTransport: true)
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
        rebuildLaneMixers(count: project.lanes.count)

        let startDelay = 0.15
        anchorMediaTime = CACurrentMediaTime() + startDelay
        anchorPlayhead = time
        playhead = time

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            return
        }

        isPlaying = true
        let horizon = time + scheduleLookahead
        for clip in project.clips(intersecting: time, horizon) {
            buildAndScheduleChain(for: clip, playheadAtStart: time)
        }
        driver?.start()
    }

    private func stopAllPlayback(keepTransport: Bool = false) {
        for chain in chains.values {
            for (player, _) in chain.players {
                player.stop()
            }
        }
        for chain in chains.values {
            for node in chain.allNodes {
                engine.detach(node)
            }
        }
        chains.removeAll()
        if !keepTransport {
            isPlaying = false
            driver?.stop()
        }
    }

    /// Explicit connection format everywhere: connecting with `format: nil`
    /// from a node whose output format is still undefined (a fresh mixer with
    /// no inputs) raises an NSException on device and crashes the app.
    private var busFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            ?? engine.outputNode.outputFormat(forBus: 0)
    }

    private func rebuildLaneMixers(count: Int) {
        guard laneMixers.count != count else { return }
        // Lane mixers only change while stopped (edits trigger a rebuild anyway).
        for mixer in laneMixers { engine.detach(mixer) }
        laneMixers = (0..<count).map { _ in AVAudioMixerNode() }
        for mixer in laneMixers {
            engine.attach(mixer)
            engine.connect(mixer, to: engine.mainMixerNode, format: busFormat)
        }
    }

    /// Builds the node chain for a clip and schedules its audio.
    private func buildAndScheduleChain(for clip: Clip, playheadAtStart: Double) {
        guard chains[clip.id] == nil else { return }
        guard let asset = AssetLibrary.shared.asset(clip.assetID) else { return }
        guard clip.laneIndex < laneMixers.count else { return }

        let outputOffset = max(0, playheadAtStart - clip.startTime)
        guard outputOffset < clip.outputDuration - 0.02 else { return }
        let sourceOffset = clip.sourceOffset(atOutputTime: outputOffset)

        let chain = ClipChain(clipID: clip.id)
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
                return
            }
            files.append((file, stem))
        }
        guard !files.isEmpty else { return }

        // One explicit format for the whole chain (players feed the stem mixer
        // in their own file format; the mixer converts).
        let chainRate = files[0].0.processingFormat.sampleRate
        guard let chainFormat = AVAudioFormat(standardFormatWithSampleRate: chainRate > 0 ? chainRate : 44100,
                                              channels: 2) else { return }

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
            guard frameCount > 0, startFrame < file.length else { continue }
            player.scheduleSegment(file, startingFrame: max(0, startFrame),
                                   frameCount: frameCount, at: nil)
        }

        // Initial parameter state.
        let t0 = outputOffset
        chain.timePitch.rate = Float(clip.rate(at: t0))
        chain.timePitch.pitch = Float(clip.pitchCents(at: t0))
        chain.clipMixer.outputVolume = Float(clip.combinedGain(at: t0))
        applyStemGains(clip: clip, chain: chain)

        // Start exactly on time relative to the shared anchor:
        // mediaTime(T) = anchorMediaTime + (T - anchorPlayhead).
        let effectiveStart = max(clip.startTime, playheadAtStart)
        let startMedia = anchorMediaTime + (effectiveStart - anchorPlayhead)
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: startMedia))
        for (player, _) in chain.players {
            player.play(at: when)
        }
        chain.started = true
        chains[clip.id] = chain
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

    /// 60 Hz update: playhead, automation, lookahead scheduling, loop, teardown.
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

        var anySolo = false
        for lane in project.lanes where lane.isSoloed { anySolo = true }
        for (index, mixer) in laneMixers.enumerated() {
            guard index < project.lanes.count else { continue }
            let lane = project.lanes[index]
            let audible: Bool = anySolo ? lane.isSoloed : !lane.isMuted
            mixer.outputVolume = audible ? Float(min(max(lane.volume, 0), 2)) : 0
        }

        // Update automation for live chains; schedule chains entering the window.
        for clip in project.clips {
            let t = now - clip.startTime
            if let chain = chains[clip.id] {
                if t >= 0 && t <= clip.outputDuration {
                    chain.timePitch.rate = Float(clip.rate(at: t))
                    chain.timePitch.pitch = Float(clip.pitchCents(at: t))
                    chain.clipMixer.outputVolume = Float(clip.combinedGain(at: t))
                    applyStemGains(clip: clip, chain: chain)
                } else if t > clip.outputDuration + 0.3 && !chain.finished {
                    chain.finished = true
                    for (player, _) in chain.players { player.stop() }
                }
            } else if clip.startTime > now, clip.startTime < now + 2.0 {
                buildAndScheduleChain(for: clip, playheadAtStart: now)
            }
        }
    }
}
