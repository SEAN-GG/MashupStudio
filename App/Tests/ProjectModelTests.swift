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
}
