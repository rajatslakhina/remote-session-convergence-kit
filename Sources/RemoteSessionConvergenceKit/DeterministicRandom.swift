import Foundation

/// A seeded SplitMix64 generator.
///
/// Deliberately *not* `SystemRandomNumberGenerator`. Both the transport simulator and
/// the property checker need to be reproducible: a convergence bug that shows up under
/// one interleaving and cannot be replayed is not a bug report, it is a rumour. Every
/// run of this package's property suite explores the same interleavings in the same
/// order, so a failure is a failing seed someone can paste into an issue.
///
/// All arithmetic uses the wrapping operators; SplitMix64 is defined over `UInt64`
/// modular arithmetic, so overflow is the intended behaviour rather than a bug.
public struct DeterministicRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upperBound`. Returns `0` for a non-positive bound rather than
    /// trapping on an invalid range.
    public mutating func int(below upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform in `0..<1`.
    public mutating func unitInterval() -> Double {
        // 53 significant bits is exactly what a Double can hold without rounding, so
        // this is uniform rather than subtly clumped.
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Fisher–Yates, written out rather than using `shuffled(using:)` so the exact
    /// permutation for a given seed is fixed by this file and not by the stdlib version.
    public mutating func shuffled<T>(_ input: [T]) -> [T] {
        guard input.count > 1 else { return input }
        var result = input
        var i = result.count - 1
        while i > 0 {
            let j = int(below: i + 1)
            if j != i { result.swapAt(i, j) }
            i -= 1
        }
        return result
    }
}
