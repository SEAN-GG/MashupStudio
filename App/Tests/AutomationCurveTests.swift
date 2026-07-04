import XCTest
@testable import MashupStudio

final class AutomationCurveTests: XCTestCase {
    func testEmptyCurve() {
        let curve = AutomationCurve(defaultValue: 1.0)
        XCTAssertEqual(curve.value(at: 5), 1.0)
        XCTAssertEqual(curve.integral(upTo: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(curve.timeWhereIntegral(equals: 10), 10, accuracy: 1e-9)
    }

    func testInstantChange() {
        var curve = AutomationCurve(defaultValue: 1.0)
        curve.setInstantChange(at: 10, to: 2.0)
        XCTAssertEqual(curve.value(at: 5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 10.001), 2.0, accuracy: 1e-9)
        // 10s at 1.0 + 10s at 2.0 = 30 source seconds after 20 output seconds.
        XCTAssertEqual(curve.integral(upTo: 20), 30, accuracy: 1e-6)
        XCTAssertEqual(curve.timeWhereIntegral(equals: 30), 20, accuracy: 1e-6)
    }

    func testLinearRamp() {
        var curve = AutomationCurve(defaultValue: 1.0)
        curve.setRamp(at: 10, duration: 10, to: 2.0)
        XCTAssertEqual(curve.value(at: 15), 1.5, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 25), 2.0, accuracy: 1e-9)
        // ∫: 10·1 + ramp avg 1.5·10 + 5·2 = 10 + 15 + 10 = 35 at t=25.
        XCTAssertEqual(curve.integral(upTo: 25), 35, accuracy: 1e-6)
    }

    func testIntegralInverseRoundTrip() {
        var curve = AutomationCurve(defaultValue: 1.0)
        curve.setRamp(at: 4, duration: 6, to: 1.8)
        curve.setRamp(at: 20, duration: 5, to: 0.7)
        for t in stride(from: 0.5, through: 40.0, by: 0.7) {
            let s = curve.integral(upTo: t)
            let back = curve.timeWhereIntegral(equals: s)
            XCTAssertEqual(back, t, accuracy: 1e-4, "roundtrip failed at t=\(t)")
        }
    }

    func testSplit() {
        var curve = AutomationCurve(defaultValue: 1.0)
        curve.setRamp(at: 5, duration: 10, to: 2.0)
        let original = curve
        var left = curve
        let right = left.split(at: 8)
        // Value continuity at the split point.
        XCTAssertEqual(right.value(at: 0), original.value(at: 8), accuracy: 1e-9)
        XCTAssertEqual(right.value(at: 7), original.value(at: 15), accuracy: 1e-9)
        XCTAssertEqual(left.value(at: 7.5), original.value(at: 7.5), accuracy: 1e-9)
    }

    func testShift() {
        var curve = AutomationCurve(defaultValue: 1.0)
        curve.setInstantChange(at: 10, to: 1.5)
        curve.shift(by: -4)
        XCTAssertEqual(curve.value(at: 6.001), 1.5, accuracy: 1e-9)
        XCTAssertEqual(curve.value(at: 5.9), 1.0, accuracy: 1e-9)
    }
}

final class ClipTimeMappingTests: XCTestCase {
    private func makeClip(rate: Double? = nil) -> Clip {
        var clip = Clip(assetID: UUID(), name: "t", laneIndex: 0,
                        startTime: 0, sourceStart: 0, sourceDuration: 100)
        if let rate {
            clip.rateCurve.setInstantChange(at: 0, to: rate)
        }
        return clip
    }

    func testConstantRateDuration() {
        XCTAssertEqual(makeClip().outputDuration, 100, accuracy: 1e-6)
        XCTAssertEqual(makeClip(rate: 2.0).outputDuration, 50, accuracy: 1e-4)
        XCTAssertEqual(makeClip(rate: 0.5).outputDuration, 200, accuracy: 1e-4)
    }

    func testRampDuration() {
        var clip = makeClip()
        // Speed up from 1.0 to 2.0 over the first 20 output seconds:
        // consumes 30 source seconds; remaining 70 at rate 2 → 35s. Total 55s.
        clip.rateCurve.setRamp(at: 0, duration: 20, to: 2.0)
        XCTAssertEqual(clip.outputDuration, 55, accuracy: 0.01)
    }

    func testSourceOffsetRoundTrip() {
        var clip = makeClip()
        clip.rateCurve.setRamp(at: 10, duration: 10, to: 1.7)
        for t in stride(from: 1.0, to: clip.outputDuration - 1, by: 2.3) {
            let s = clip.sourceOffset(atOutputTime: t)
            let back = clip.outputTime(forSourceOffset: s)
            XCTAssertEqual(back, t, accuracy: 1e-3)
        }
    }

    func testSplitPreservesSource() {
        var clip = makeClip()
        clip.rateCurve.setRamp(at: 5, duration: 20, to: 1.5)
        guard let (left, right) = clip.split(atTimelineTime: 12) else {
            XCTFail("split failed"); return
        }
        XCTAssertEqual(left.sourceDuration + right.sourceDuration, clip.sourceDuration, accuracy: 1e-6)
        XCTAssertEqual(right.sourceStart, clip.sourceStart + left.sourceDuration, accuracy: 1e-6)
        XCTAssertEqual(left.outputDuration + right.outputDuration, clip.outputDuration, accuracy: 0.02)
        XCTAssertEqual(right.startTime, 12, accuracy: 1e-9)
    }

    func testTrimRight() {
        var clip = makeClip(rate: 2.0)
        clip.trimRight(toTimelineTime: 25, assetDuration: 100)   // half the stretched length
        XCTAssertEqual(clip.outputDuration, 25, accuracy: 0.01)
        XCTAssertEqual(clip.sourceDuration, 50, accuracy: 0.05)
    }

    func testTrimLeft() {
        var clip = makeClip()
        clip.trimLeft(toTimelineTime: 10)
        XCTAssertEqual(clip.startTime, 10, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceStart, 10, accuracy: 1e-4)
        XCTAssertEqual(clip.sourceDuration, 90, accuracy: 1e-4)
    }

    func testEffectiveKeyAndBPM() {
        var clip = makeClip()
        clip.pitchCurve.setInstantChange(at: 0, to: 200)   // +2 semitones
        let key = MusicalKey(root: 9, isMinor: true)       // Am → Bm
        XCTAssertEqual(clip.effectiveKey(assetKey: key, at: 1).traditionalName, "Bm")
        clip.rateCurve.setInstantChange(at: 0, to: 1.1)
        XCTAssertEqual(clip.effectiveBPM(assetBPM: 100, at: 1), 110, accuracy: 1e-6)
    }
}

final class TimeFormatTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(TimeFormat.short(65), "01:05")
        XCTAssertEqual(TimeFormat.position(65.25), "01:05.25")
    }

    func testParse() {
        XCTAssertEqual(TimeFormat.parse("01:05") ?? -1, 65, accuracy: 1e-9)
        XCTAssertEqual(TimeFormat.parse("1:05.5") ?? -1, 65.5, accuracy: 1e-9)
        XCTAssertEqual(TimeFormat.parse("90") ?? -1, 90, accuracy: 1e-9)
        XCTAssertEqual(TimeFormat.parse("1:00:00") ?? -1, 3600, accuracy: 1e-9)
        XCTAssertNil(TimeFormat.parse("abc"))
    }
}
