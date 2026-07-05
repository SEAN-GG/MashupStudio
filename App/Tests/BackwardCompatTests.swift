import XCTest
@testable import MashupStudio

/// Projects saved by builds 6-8 (before 6 stems / effects / volume automation)
/// must still decode.
final class BackwardCompatTests: XCTestCase {
    func testOldClipDecodes() throws {
        let oldJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "assetID": "22222222-2222-2222-2222-222222222222",
          "name": "שיר ישן",
          "laneIndex": 0,
          "startTime": 5,
          "sourceStart": 0,
          "sourceDuration": 60,
          "gain": 1.2,
          "fades": {"fadeIn": 2, "fadeOut": 4, "shapeIn": "linear", "shapeOut": "equalPower"},
          "stemGains": {"vocals": 0.5, "drums": 1, "bass": 1, "other": 1},
          "rateCurve": {"points": [], "defaultValue": 1},
          "pitchCurve": {"points": [], "defaultValue": 0},
          "varispeed": false
        }
        """
        let clip = try JSONDecoder().decode(Clip.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(clip.gain, 1.2, accuracy: 1e-9)
        XCTAssertEqual(clip.stemGains[.vocals], 0.5, accuracy: 1e-9)
        XCTAssertEqual(clip.stemGains[.guitar], 1.0, accuracy: 1e-9)   // default for new stem
        XCTAssertEqual(clip.stemGains[.piano], 1.0, accuracy: 1e-9)
        XCTAssertNil(clip.volumeCurve)
        XCTAssertEqual(clip.combinedGain(at: 30), 1.2, accuracy: 1e-9)
        XCTAssertEqual(clip.stemGain(.drums, at: 10), 1.0, accuracy: 1e-9)
    }

    func testStemCurveFades() {
        var clip = Clip(assetID: UUID(), name: "t", laneIndex: 0,
                        startTime: 0, sourceStart: 0, sourceDuration: 100)
        clip.modifyStemCurve(.drums) { $0.setFadeIn(duration: 4) }
        XCTAssertEqual(clip.stemGain(.drums, at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(clip.stemGain(.drums, at: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(clip.stemGain(.drums, at: 10), 1.0, accuracy: 1e-6)

        clip.modifyStemCurve(.vocals) { $0.setFadeOut(duration: 10, totalDuration: 100) }
        XCTAssertEqual(clip.stemGain(.vocals, at: 50), 1.0, accuracy: 1e-6)
        XCTAssertEqual(clip.stemGain(.vocals, at: 95), 0.5, accuracy: 1e-6)
        XCTAssertEqual(clip.stemGain(.vocals, at: 100), 0.0, accuracy: 1e-6)
    }

    func testVolumeCurveAffectsCombinedGain() {
        var clip = Clip(assetID: UUID(), name: "t", laneIndex: 0,
                        startTime: 0, sourceStart: 0, sourceDuration: 100)
        clip.modifyVolumeCurve { $0.setRamp(at: 10, duration: 8, to: 0.2) }
        XCTAssertEqual(clip.combinedGain(at: 5), 1.0, accuracy: 1e-6)
        XCTAssertEqual(clip.combinedGain(at: 14), 0.6, accuracy: 1e-6)  // halfway down the ramp
        XCTAssertEqual(clip.combinedGain(at: 30), 0.2, accuracy: 1e-6)
    }

    func testEffectsRoundTrip() throws {
        var clip = Clip(assetID: UUID(), name: "t", laneIndex: 0,
                        startTime: 0, sourceStart: 0, sourceDuration: 10)
        clip.setEffects([StemEffectSetting(kind: .reverb, amount: 0.7),
                         StemEffectSetting(kind: .telephone, amount: 0.4)], for: .vocals)
        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(decoded.effects(for: .vocals).count, 2)
        XCTAssertEqual(decoded.allEffects.count, 2)
        XCTAssertTrue(decoded.hasStemWork)
    }

    func testOldProjectDecodesWithoutMasterVolume() throws {
        var project = MixProject(name: "בדיקה")
        project.masterVolume = nil
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MixProject.self, from: data)
        XCTAssertEqual(decoded.effectiveMasterVolume, 1.0, accuracy: 1e-9)
    }
}
