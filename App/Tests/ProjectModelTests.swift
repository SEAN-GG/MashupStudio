import XCTest
@testable import MashupStudio

final class ProjectModelTests: XCTestCase {
    func testCodableRoundTrip() throws {
        var project = MixProject(name: "בדיקה")
        var clip = Clip(assetID: UUID(), name: "שיר", laneIndex: 1,
                        startTime: 12.5, sourceStart: 3, sourceDuration: 90)
        clip.gain = 1.2
        clip.fades = ClipFades(fadeIn: 2, fadeOut: 6, shapeIn: .linear, shapeOut: .equalPower)
        clip.stemGains.vocals = 0
        clip.rateCurve.setRamp(at: 10, duration: 8, to: 1.4)
        clip.pitchCurve.setInstantChange(at: 0, to: -200)
        project.clips.append(clip)
        project.lanes[0].isMuted = true

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MixProject.self, from: data)
        XCTAssertEqual(decoded, project)
    }

    func testNormalizeLanesKeepsSpare() {
        var project = MixProject(name: "x")
        project.clips.append(Clip(assetID: UUID(), name: "a", laneIndex: 3,
                                  startTime: 0, sourceStart: 0, sourceDuration: 10))
        project.normalizeLanes()
        XCTAssertGreaterThanOrEqual(project.lanes.count, 5)
    }

    func testDurationIsMaxClipEnd() {
        var project = MixProject(name: "x")
        project.clips.append(Clip(assetID: UUID(), name: "a", laneIndex: 0,
                                  startTime: 0, sourceStart: 0, sourceDuration: 30))
        project.clips.append(Clip(assetID: UUID(), name: "b", laneIndex: 1,
                                  startTime: 25, sourceStart: 0, sourceDuration: 30))
        XCTAssertEqual(project.duration, 55, accuracy: 1e-6)
    }

    func testFadeGains() {
        let fades = ClipFades(fadeIn: 4, fadeOut: 4, shapeIn: .linear, shapeOut: .linear)
        XCTAssertEqual(fades.gain(at: 0, duration: 20), 0, accuracy: 1e-6)
        XCTAssertEqual(fades.gain(at: 2, duration: 20), 0.5, accuracy: 1e-6)
        XCTAssertEqual(fades.gain(at: 10, duration: 20), 1.0, accuracy: 1e-6)
        XCTAssertEqual(fades.gain(at: 18, duration: 20), 0.5, accuracy: 1e-6)
        XCTAssertEqual(fades.gain(at: 20, duration: 20), 0, accuracy: 1e-6)
    }

    func testTrimRightCanReExtendAfterShortening() {
        var clip = Clip(assetID: UUID(), name: "x", laneIndex: 0,
                        startTime: 0, sourceStart: 0, sourceDuration: 100)
        clip.trimRight(toTimelineTime: 40, assetDuration: 100)
        XCTAssertEqual(clip.sourceDuration, 40, accuracy: 0.01)
        // Re-extend past the shortened length: trimmed material comes back.
        clip.trimRight(toTimelineTime: 80, assetDuration: 100)
        XCTAssertEqual(clip.sourceDuration, 80, accuracy: 0.01)
        // But never past the end of the file.
        clip.trimRight(toTimelineTime: 500, assetDuration: 100)
        XCTAssertEqual(clip.sourceDuration, 100, accuracy: 0.01)
    }

    func testTrimRightReExtendRespectsRate() {
        var clip = Clip(assetID: UUID(), name: "x", laneIndex: 0,
                        startTime: 0, sourceStart: 10, sourceDuration: 60)
        clip.rateCurve = AutomationCurve(defaultValue: 2.0)   // plays twice as fast
        XCTAssertEqual(clip.outputDuration, 30, accuracy: 0.01)
        clip.trimRight(toTimelineTime: 10, assetDuration: 100)
        XCTAssertEqual(clip.sourceDuration, 20, accuracy: 0.01)
        clip.trimRight(toTimelineTime: 40, assetDuration: 100)
        // 40 output seconds at 2x would need 80 source seconds; only 90 remain
        // after sourceStart=10, so it fits fully.
        XCTAssertEqual(clip.sourceDuration, 80, accuracy: 0.01)
    }

    func testLyricWordsCodableOnAsset() throws {
        var asset = AudioAsset(id: UUID(), title: "שיר", fileName: "audio.m4a",
                               duration: 120, sampleRate: 44100, channelCount: 2,
                               importedAt: Date())
        asset.lyrics = [LyricWord(time: 1.5, duration: 0.4, text: "שלום"),
                        LyricWord(time: 2.1, duration: 0.3, text: "עולם")]
        asset.lyricsLanguage = "he-IL"
        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(AudioAsset.self, from: data)
        XCTAssertEqual(decoded.lyrics?.count, 2)
        XCTAssertEqual(decoded.lyrics?.first?.text, "שלום")

        // An asset JSON without the new fields still decodes.
        var old = asset
        old.lyrics = nil
        old.lyricsLanguage = nil
        let oldData = try JSONEncoder().encode(old)
        let oldDecoded = try JSONDecoder().decode(AudioAsset.self, from: oldData)
        XCTAssertNil(oldDecoded.lyrics)
    }
}
