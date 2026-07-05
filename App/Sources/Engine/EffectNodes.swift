import Foundation
import AVFoundation

/// Builds AVAudioEngine effect nodes from stem-effect settings. Used by both
/// realtime playback and offline export so they sound identical.
enum EffectNodes {
    /// Creates one engine node per setting, in order.
    static func makeNodes(for settings: [StemEffectSetting]) -> [AVAudioNode] {
        settings.map { make(setting: $0) }
    }

    private static func make(setting: StemEffectSetting) -> AVAudioNode {
        let amount = min(max(setting.amount, 0), 1)
        switch setting.kind {
        case .reverb:
            let node = AVAudioUnitReverb()
            node.loadFactoryPreset(.largeHall2)
            node.wetDryMix = Float(amount * 80)
            return node
        case .cathedral:
            let node = AVAudioUnitReverb()
            node.loadFactoryPreset(.cathedral)
            node.wetDryMix = Float(amount * 85)
            return node
        case .room:
            let node = AVAudioUnitReverb()
            node.loadFactoryPreset(.mediumRoom)
            node.wetDryMix = Float(amount * 70)
            return node
        case .muffle:
            let node = AVAudioUnitEQ(numberOfBands: 1)
            node.bands[0].filterType = .lowPass
            node.bands[0].frequency = Float(3500 - amount * 2600)
            node.bands[0].bypass = false
            return node
        case .delay:
            let node = AVAudioUnitDelay()
            node.delayTime = 0.36
            node.feedback = 42
            node.lowPassCutoff = 12000
            node.wetDryMix = Float(amount * 60)
            return node
        case .echo:
            let node = AVAudioUnitDelay()
            node.delayTime = 0.11
            node.feedback = 55
            node.lowPassCutoff = 9000
            node.wetDryMix = Float(amount * 55)
            return node
        case .distortion:
            let node = AVAudioUnitDistortion()
            node.loadFactoryPreset(.multiDistortedFunk)
            node.preGain = Float(amount * 12)
            node.wetDryMix = Float(amount * 70)
            return node
        case .telephone:
            let node = AVAudioUnitEQ(numberOfBands: 2)
            node.bands[0].filterType = .highPass
            node.bands[0].frequency = 550
            node.bands[0].bypass = false
            node.bands[1].filterType = .lowPass
            node.bands[1].frequency = Float(4200 - amount * 2600)
            node.bands[1].bypass = false
            return node
        case .bassBoost:
            let node = AVAudioUnitEQ(numberOfBands: 1)
            node.bands[0].filterType = .lowShelf
            node.bands[0].frequency = 110
            node.bands[0].gain = Float(amount * 12)
            node.bands[0].bypass = false
            return node
        case .treble:
            let node = AVAudioUnitEQ(numberOfBands: 1)
            node.bands[0].filterType = .highShelf
            node.bands[0].frequency = 7500
            node.bands[0].gain = Float(amount * 12)
            node.bands[0].bypass = false
            return node
        case .underwater:
            let node = AVAudioUnitEQ(numberOfBands: 1)
            node.bands[0].filterType = .lowPass
            node.bands[0].frequency = Float(900 - amount * 550)
            node.bands[0].bypass = false
            return node
        }
    }

    /// Attaches the nodes and wires source → effects… → destination.
    /// With no effects, connects source directly to destination.
    static func install(engine: AVAudioEngine,
                        settings: [StemEffectSetting],
                        from source: AVAudioNode,
                        to destination: AVAudioNode,
                        format: AVAudioFormat) -> [AVAudioNode] {
        let nodes = makeNodes(for: settings)
        var previous = source
        for node in nodes {
            engine.attach(node)
            engine.connect(previous, to: node, format: format)
            previous = node
        }
        engine.connect(previous, to: destination, format: format)
        return nodes
    }
}
