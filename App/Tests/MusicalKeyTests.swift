import XCTest
@testable import MashupStudio

final class MusicalKeyTests: XCTestCase {
    func testCamelotMajors() {
        XCTAssertEqual(MusicalKey(root: 0, isMinor: false).camelotName, "8B")   // C
        XCTAssertEqual(MusicalKey(root: 7, isMinor: false).camelotName, "9B")   // G
        XCTAssertEqual(MusicalKey(root: 2, isMinor: false).camelotName, "10B")  // D
        XCTAssertEqual(MusicalKey(root: 11, isMinor: false).camelotName, "1B")  // B
        XCTAssertEqual(MusicalKey(root: 5, isMinor: false).camelotName, "7B")   // F
        XCTAssertEqual(MusicalKey(root: 3, isMinor: false).camelotName, "5B")   // Eb
    }

    func testCamelotMinors() {
        XCTAssertEqual(MusicalKey(root: 9, isMinor: true).camelotName, "8A")    // Am
        XCTAssertEqual(MusicalKey(root: 4, isMinor: true).camelotName, "9A")    // Em
        XCTAssertEqual(MusicalKey(root: 11, isMinor: true).camelotName, "10A")  // Bm
        XCTAssertEqual(MusicalKey(root: 8, isMinor: true).camelotName, "1A")    // Abm
        XCTAssertEqual(MusicalKey(root: 5, isMinor: true).camelotName, "4A")    // Fm
    }

    func testCamelotRoundTrip() {
        for root in 0..<12 {
            for minor in [true, false] {
                let key = MusicalKey(root: root, isMinor: minor)
                let parsed = MusicalKey(camelot: key.camelotName)
                XCTAssertEqual(parsed, key, "round trip failed for \(key.camelotName)")
            }
        }
    }

    func testTransposition() {
        let em = MusicalKey(root: 4, isMinor: true)          // 9A
        XCTAssertEqual(em.transposed(by: 1).camelotName, "4A")   // Fm
        XCTAssertEqual(em.transposed(by: 7).camelotName, "10A")  // Bm
        XCTAssertEqual(em.transposed(by: -12), em)
    }

    func testCompatibility() {
        let am = MusicalKey(root: 9, isMinor: true)   // 8A
        let c = MusicalKey(root: 0, isMinor: false)   // 8B (relative major)
        let em = MusicalKey(root: 4, isMinor: true)   // 9A (neighbor)
        let dm = MusicalKey(root: 2, isMinor: true)   // 7A (neighbor)
        let fsm = MusicalKey(root: 6, isMinor: true)  // 11A (not compatible)
        XCTAssertTrue(am.isCompatible(with: c))
        XCTAssertTrue(am.isCompatible(with: em))
        XCTAssertTrue(am.isCompatible(with: dm))
        XCTAssertFalse(am.isCompatible(with: fsm))
    }

    func testSmallestShift() {
        let am = MusicalKey(root: 9, isMinor: true)
        XCTAssertEqual(am.smallestShiftForCompatibility(with: am), 0)
        // Bbm (3A) needs -1 to become Am (8A, compatible with itself).
        let bbm = MusicalKey(root: 10, isMinor: true)
        let shift = bbm.smallestShiftForCompatibility(with: am)
        XCTAssertTrue(bbm.transposed(by: shift).isCompatible(with: am))
        XCTAssertLessThanOrEqual(abs(shift), 2)
    }
}
