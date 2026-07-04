import Foundation
import AVFoundation

#if canImport(LAME)
import LAME
#endif

/// MP3 encoding via LAME when the library is bundled (see scripts/build_lame.sh).
/// Falls back gracefully: `isAvailable == false` hides MP3 from the export UI.
enum MP3Encoder {
    static var isAvailable: Bool {
        #if canImport(LAME)
        return true
        #else
        return false
        #endif
    }

    static func encode(wavURL: URL, to destination: URL, progress: (Double) -> Void) throws {
        #if canImport(LAME)
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        guard let lame = lame_init() else { throw RenderError.encodingFailure }
        defer { lame_close(lame) }

        lame_set_in_samplerate(lame, Int32(format.sampleRate))
        lame_set_num_channels(lame, Int32(format.channelCount))
        lame_set_brate(lame, 320)
        lame_set_quality(lame, 2)
        lame_init_params(lame)

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else {
            throw RenderError.encodingFailure
        }
        defer { try? out.close() }

        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw RenderError.encodingFailure
        }
        var mp3Buffer = [UInt8](repeating: 0, count: Int(chunk) * 2 + 7200)
        let totalFrames = file.length

        while file.framePosition < totalFrames {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let left = data[0]
            let right = format.channelCount > 1 ? data[1] : data[0]
            let written = lame_encode_buffer_ieee_float(lame, left, right, Int32(frames),
                                                        &mp3Buffer, Int32(mp3Buffer.count))
            if written < 0 { throw RenderError.encodingFailure }
            if written > 0 {
                out.write(Data(bytes: mp3Buffer, count: Int(written)))
            }
            progress(Double(file.framePosition) / Double(max(totalFrames, 1)))
        }
        let flushed = lame_encode_flush(lame, &mp3Buffer, Int32(mp3Buffer.count))
        if flushed > 0 {
            out.write(Data(bytes: mp3Buffer, count: Int(flushed)))
        }
        #else
        throw RenderError.encodingFailure
        #endif
    }
}
