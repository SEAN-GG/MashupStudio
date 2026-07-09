import Foundation
import AVFoundation
import CoreText
import UIKit

enum KaraokeError: LocalizedError {
    case noLyrics
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noLyrics: return "אין מילים מתומללות בטווח הייצוא — תמלל שיר קודם (כפתור ״מילים״)"
        case .writerFailed: return "יצירת וידאו הקריוקי נכשלה"
        }
    }
}

/// Renders a karaoke MP4: the project's mixed audio with the transcribed
/// lyrics on screen, the current word highlighted as it is sung.
enum KaraokeExporter {
    struct TimedWord: Sendable {
        let start: Double     // seconds from the start of the export range
        let end: Double
        let text: String
    }

    struct Line: Sendable {
        let words: [TimedWord]
        var start: Double { words.first?.start ?? 0 }
        var end: Double { words.last?.end ?? 0 }
    }

    /// Maps every clip's lyrics through its trim/tempo to export-range time.
    @MainActor
    static func timelineWords(project: MixProject,
                              rangeStart: Double,
                              rangeEnd: Double) -> [TimedWord] {
        var result: [TimedWord] = []
        for clip in project.clips {
            guard let asset = AssetLibrary.shared.asset(clip.assetID),
                  let lyrics = asset.lyrics else { continue }
            for word in lyrics {
                let sourceOffset = word.time - clip.sourceStart
                guard sourceOffset >= 0, sourceOffset <= clip.sourceDuration else { continue }
                let local = clip.outputTime(forSourceOffset: sourceOffset)
                let t = clip.startTime + local
                guard t >= rangeStart, t < rangeEnd else { continue }
                let duration = max(word.duration / clip.rate(at: local), 0.15)
                result.append(TimedWord(start: t - rangeStart,
                                        end: t - rangeStart + duration,
                                        text: word.text))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func groupLines(_ words: [TimedWord]) -> [Line] {
        var lines: [Line] = []
        var current: [TimedWord] = []
        for word in words {
            if let last = current.last, word.start - last.end > 1.4 || current.count >= 7 {
                lines.append(Line(words: current))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { lines.append(Line(words: current)) }
        return lines
    }

    // MARK: - Render

    nonisolated static func render(words: [TimedWord],
                                   audioURL: URL,
                                   duration: Double,
                                   title: String,
                                   to destination: URL,
                                   isCancelled: @escaping @Sendable () -> Bool,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !words.isEmpty else { throw KaraokeError.noLyrics }
        let width = 1280, height = 720
        let fps = 10.0

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(videoInput)

        // Audio: pass the already-rendered AAC mix straight through.
        let audioAsset = AVURLAsset(url: audioURL)
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw KaraokeError.writerFailed
        }
        let formatHint = try await audioTrack.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: audioAsset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(readerOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatHint)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else { throw KaraokeError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw KaraokeError.writerFailed }

        let lines = groupLines(words)
        let size = CGSize(width: width, height: height)
        let frameCount = max(Int(duration * fps), 1)
        for i in 0..<frameCount {
            if isCancelled() { break }
            let t = Double(i) / fps
            while !videoInput.isReadyForMoreMediaData {
                usleep(5000)
            }
            guard let buffer = makeFrame(t: t, lines: lines, size: size,
                                         pool: adaptor.pixelBufferPool, title: title) else {
                throw KaraokeError.writerFailed
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i) * 60, timescale: 600))
            if i % 20 == 0 { progress(0.05 + Double(i) / Double(frameCount) * 0.85) }
        }
        videoInput.markAsFinished()

        while let sample = readerOutput.copyNextSampleBuffer() {
            if isCancelled() { break }
            while !audioInput.isReadyForMoreMediaData {
                usleep(5000)
            }
            audioInput.append(sample)
        }
        audioInput.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if isCancelled() {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        guard writer.status == .completed else { throw KaraokeError.writerFailed }
        progress(1)
    }

    // MARK: - Frame drawing

    private nonisolated static func makeFrame(t: Double,
                                              lines: [Line],
                                              size: CGSize,
                                              pool: CVPixelBufferPool?,
                                              title: String) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        }
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }

        // Background
        context.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        // Title, small at the top
        draw(text: attributed(title, size: 30, weight: .semibold,
                              color: UIColor(white: 1, alpha: 0.45).cgColor),
             centeredAtY: size.height - 70, in: context, canvasWidth: size.width)

        // Current line: the one being sung, or the next one coming up.
        guard let index = lines.lastIndex(where: { $0.start - 1.2 <= t }) else {
            if let first = lines.first {
                draw(line: first, t: -1, dimmed: true, y: size.height / 2, in: context, canvasWidth: size.width)
            }
            return buffer
        }
        let line = lines[index]
        let active = t <= line.end + 0.8
        draw(line: line, t: active ? t : line.end + 1, dimmed: false,
             y: size.height / 2, in: context, canvasWidth: size.width)
        if index + 1 < lines.count {
            draw(line: lines[index + 1], t: -1, dimmed: true,
                 y: size.height / 2 - 90, in: context, canvasWidth: size.width)
        }
        return buffer
    }

    private nonisolated static func draw(line: Line, t: Double, dimmed: Bool, y: CGFloat,
                                         in context: CGContext, canvasWidth: CGFloat) {
        let accent = CGColor(red: 0.30, green: 0.87, blue: 0.72, alpha: 1)
        let plain = UIColor(white: 1, alpha: dimmed ? 0.35 : 0.95).cgColor
        let result = NSMutableAttributedString()
        for (i, word) in line.words.enumerated() {
            let sung = t >= word.start
            let piece = attributed((i == 0 ? "" : " ") + word.text,
                                   size: dimmed ? 38 : 54,
                                   weight: .bold,
                                   color: sung && !dimmed ? accent : plain)
            result.append(piece)
        }
        draw(text: result, centeredAtY: y, in: context, canvasWidth: canvasWidth)
    }

    private nonisolated static func attributed(_ text: String, size: CGFloat,
                                               weight: UIFont.Weight,
                                               color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String):
                UIFont.systemFont(ofSize: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    private nonisolated static func draw(text: NSAttributedString, centeredAtY y: CGFloat,
                                         in context: CGContext, canvasWidth: CGFloat) {
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        var scale: CGFloat = 1
        if textWidth > canvasWidth - 80 {
            scale = (canvasWidth - 80) / textWidth
        }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: (canvasWidth - textWidth * scale) / 2, y: y)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
