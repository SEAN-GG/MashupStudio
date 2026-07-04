import Foundation
import AVFoundation

/// Approximate "stem" control for clips whose real AI stems aren't ready yet:
/// maps stem faders onto EQ bands. Clearly labeled as approximate in the UI.
enum StemEQMapper {
    static let bandCount = 4

    static func configure(eq: AVAudioUnitEQ) {
        guard eq.bands.count >= bandCount else { return }
        let bands = eq.bands
        bands[0].filterType = .lowShelf       // bass
        bands[0].frequency = 130
        bands[1].filterType = .parametric     // vocals / mids
        bands[1].frequency = 1400
        bands[1].bandwidth = 1.2
        bands[2].filterType = .parametric     // body / other instruments
        bands[2].frequency = 420
        bands[2].bandwidth = 1.1
        bands[3].filterType = .highShelf      // drums brightness (hats, snare air)
        bands[3].frequency = 7500
        for band in bands.prefix(bandCount) {
            band.bypass = false
            band.gain = 0
        }
        eq.globalGain = 0
    }

    static func apply(gains: StemGains, to eq: AVAudioUnitEQ) {
        guard eq.bands.count >= bandCount else { return }
        eq.bands[0].gain = dB(gains.bass)
        eq.bands[1].gain = dB(gains.vocals)
        eq.bands[2].gain = dB(gains.other)
        eq.bands[3].gain = dB(gains.drums)
    }

    private static func dB(_ linear: Double) -> Float {
        let clamped = max(linear, 0.0005)
        return Float(min(max(20 * log10(clamped), -60), 12))
    }
}
