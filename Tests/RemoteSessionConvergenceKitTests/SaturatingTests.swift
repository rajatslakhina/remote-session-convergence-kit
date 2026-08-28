import XCTest
@testable import RemoteSessionConvergenceKit

/// Every case here corresponds to an input that makes the *natural* Swift spelling of
/// the same operation trap. If any of these regress, the crash they cause is a hard
/// crash inside a system-launched extension, which is about the worst place to have one.
final class SaturatingTests: XCTestCase {

    func testIntConversionHandlesNonFiniteInput() {
        XCTAssertEqual(Saturating.int(.nan), 0)
        XCTAssertEqual(Saturating.int(.infinity), .max)
        XCTAssertEqual(Saturating.int(-.infinity), .min)
        XCTAssertEqual(Saturating.int(.signalingNaN), 0)
    }

    /// The trap this function exists for. `Double(Int.max)` rounds *up* to 2^63 on a
    /// 64-bit platform, so a `<=` bound would admit exactly 2^63 and then trap.
    func testIntConversionAtAndAboveTheUpperBound() {
        XCTAssertEqual(Saturating.int(Double(Int.max)), .max)
        XCTAssertEqual(Saturating.int(Double(Int.max) * 2), .max)
        XCTAssertEqual(Saturating.int(Double(Int.min)), .min)
        XCTAssertEqual(Saturating.int(Double(Int.min) * 2), .min)
    }

    func testIntConversionTruncatesTowardZeroInRange() {
        XCTAssertEqual(Saturating.int(3.9), 3)
        XCTAssertEqual(Saturating.int(-3.9), -3)
        XCTAssertEqual(Saturating.int(0), 0)
    }

    func testDivisionAndRemainderEdgeCases() {
        XCTAssertEqual(Saturating.divide(10, by: 0), 0)
        XCTAssertEqual(Saturating.remainder(10, 0), 0)
        // Int.min / -1 is the one division that overflows.
        XCTAssertEqual(Saturating.divide(.min, by: -1), .max)
        XCTAssertEqual(Saturating.remainder(.min, -1), 0)
        XCTAssertEqual(Saturating.divide(-7, by: 2), -3)
        XCTAssertEqual(Saturating.remainder(-7, 2), -1)
    }

    func testAdditiveAndMultiplicativeOverflowSaturates() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
    }

    func testClampRejectsNaNAndInvertedBounds() {
        XCTAssertEqual(Saturating.clamp(.nan, 0, 1), 0)
        XCTAssertEqual(Saturating.clamp(5, 0, 1), 1)
        XCTAssertEqual(Saturating.clamp(-5, 0, 1), 0)
        // An inverted range would trap if spelled `min...max`.
        XCTAssertEqual(Saturating.clamp(0.5, 1, 0), 1)
    }

    func testPercentageIsBoundedAndSurvivesDegenerateTotals() {
        XCTAssertEqual(Saturating.percentage(50, of: 200), 25)
        XCTAssertEqual(Saturating.percentage(500, of: 200), 100)
        XCTAssertEqual(Saturating.percentage(-5, of: 200), 0)
        XCTAssertEqual(Saturating.percentage(5, of: 0), 0)
        XCTAssertEqual(Saturating.percentage(5, of: -1), 0)
        XCTAssertEqual(Saturating.percentage(.nan, of: 100), 0)
        XCTAssertEqual(Saturating.percentage(5, of: .infinity), 0)
    }

    /// Exercises the saturation path against bounds expressed in terms of `Int.max`
    /// rather than a literal.
    ///
    /// Being honest about its limits: run on a 64-bit host, this cannot actually prove
    /// 32-bit correctness — a hardcoded 64-bit literal would pass it here too. Only
    /// building for a 32-bit target would prove that, and no CI job does. What this
    /// does pin is that the bounds stay *expressed* relative to `Int.max`/`Int.min`,
    /// so the property survives if such a target is ever added.
    func testSaturationBoundsAreExpressedRelativeToIntWidth() {
        XCTAssertEqual(Saturating.int(Double(Int.max) + Double(Int.max)), Int.max)
        XCTAssertEqual(Saturating.int(Double(Int.min) + Double(Int.min)), Int.min)
        XCTAssertEqual(Saturating.add(Int.max, Int.max), Int.max)
        XCTAssertEqual(Saturating.subtract(Int.min, Int.max), Int.min)
    }
}
