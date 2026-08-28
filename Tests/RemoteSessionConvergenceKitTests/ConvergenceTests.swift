import XCTest
@testable import RemoteSessionConvergenceKit

private let speaker = OriginID.speaker

private func envelope(_ sequence: UInt64, _ updates: [FieldUpdate], causedBy: CommandID? = nil) -> StateEnvelope {
    StateEnvelope(
        stamp: Stamp(sequence: sequence, origin: speaker),
        emittedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
        causedBy: causedBy,
        updates: updates
    )
}

final class StampOrderingTests: XCTestCase {

    func testStampOrderIsTotal() {
        let a = Stamp(sequence: 1, origin: OriginID("a", priority: 1))
        let b = Stamp(sequence: 1, origin: OriginID("b", priority: 1))
        let c = Stamp(sequence: 1, origin: OriginID("a", priority: 2))
        let d = Stamp(sequence: 2, origin: OriginID("a", priority: 0))

        // Sequence dominates priority, priority dominates the key.
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
        XCTAssertLessThan(c, d)
        // Totality: for any two distinct stamps exactly one ordering holds.
        for (x, y) in [(a, b), (a, c), (a, d), (b, c), (b, d), (c, d)] {
            XCTAssertNotEqual(x < y, y < x, "\(x) and \(y) are unordered")
        }
    }

    /// Same stamp, different values, is the case that quietly breaks commutativity if
    /// the merge stops at max-by-stamp. Both orders must still agree.
    func testEqualStampsWithDifferingValuesStillConverge() {
        let left = Stamped("alpha", stamp: Stamp(sequence: 7, origin: speaker))
        let right = Stamped("beta", stamp: Stamp(sequence: 7, origin: speaker))
        XCTAssertEqual(left.merged(with: right), right.merged(with: left))
    }

    func testMergeIsIdempotent() {
        let value = Stamped(0.5, stamp: Stamp(sequence: 3, origin: speaker))
        XCTAssertEqual(value.merged(with: value), value)
    }

    func testOlderStampDoesNotOverwriteNewer() {
        let newer = Stamped("new", stamp: Stamp(sequence: 9, origin: speaker))
        let older = Stamped("old", stamp: Stamp(sequence: 2, origin: speaker))
        XCTAssertEqual(newer.merged(with: older).value, "new")
        XCTAssertEqual(older.merged(with: newer).value, "new")
    }
}

final class MergeConvergenceTests: XCTestCase {

    private var stream: [StateEnvelope] {
        [
            envelope(1, [.title("First"), .duration(200), .volume(0.2)]),
            envelope(2, [.elapsed(5)]),
            envelope(3, [.volume(0.6)]),
            envelope(4, [.title("Second"), .elapsed(10)]),
            envelope(5, [.playbackRate(1)]),
            envelope(6, [.volume(0.9), .elapsed(15)])
        ]
    }

    /// The headline claim, checked over every ordering rather than a lucky one.
    /// 720 permutations of six envelopes is the whole space, so this is exhaustive.
    func testExhaustivePermutationsAgree() {
        let merger = StampedFieldMerger()
        let envelopes = stream
        let reference = envelopes.reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }

        var seen = 0
        permute(envelopes) { ordering in
            let result = ordering.reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }
            seen += 1
            XCTAssertEqual(result, reference)
        }
        XCTAssertEqual(seen, 720, "expected every permutation of 6 envelopes")
    }

    func testDroppedEnvelopesStillConvergeToTheSurvivingMaximum() {
        let merger = StampedFieldMerger()
        let envelopes = stream
        // Delivery loses seq 3 and 5 entirely.
        let delivered = envelopes.filter { $0.stamp.sequence != 3 && $0.stamp.sequence != 5 }
        let state = delivered.reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }
        XCTAssertEqual(state.title.value, "Second")
        XCTAssertEqual(state.volume.value, 0.9, accuracy: 0.0001)
        // seq 5 was the only playbackRate update; losing it must leave the field at its
        // initial value rather than inventing one.
        XCTAssertEqual(state.playbackRate.value, 0)
        XCTAssertEqual(state.playbackRate.stamp, .zero)
    }

    func testTransportMangledStreamConvergesToOrderedResult() {
        let merger = StampedFieldMerger()
        let script = SessionScript()
        let ordered = script.envelopes(ticks: 20)
        let transport = LossyTransport(profile: .hostile)
        let delivered = transport.deliver(ordered, seed: 99)

        XCTAssertFalse(delivered.isEmpty)
        XCTAssertNotEqual(delivered.map(\.stamp), ordered.map(\.stamp),
                          "the hostile profile should have actually mangled the stream")

        let mangled = delivered.reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }
        let sorted = delivered.sorted { $0.stamp < $1.stamp }
            .reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }
        XCTAssertEqual(mangled, sorted)
    }

    func testMergerSanitisesHostileNumbers() {
        let merger = StampedFieldMerger()
        let poisoned = envelope(1, [
            .elapsed(.nan),
            .duration(.infinity),
            .volume(42),
            .playbackRate(-3)
        ])
        let state = merger.apply(poisoned, to: .unknown)
        XCTAssertEqual(state.elapsed.value, 0)
        XCTAssertEqual(state.duration.value, 0)
        XCTAssertEqual(state.volume.value, 1)
        XCTAssertEqual(state.playbackRate.value, 0)
    }

    private func permute(_ items: [StateEnvelope], _ body: ([StateEnvelope]) -> Void) {
        var working = items
        func step(_ k: Int) {
            if k >= working.count { body(working); return }
            for i in k..<working.count {
                working.swapAt(k, i)
                step(k + 1)
                working.swapAt(k, i)
            }
        }
        step(0)
    }
}

final class ConvergencePropertyCheckerTests: XCTestCase {

    private var stream: [StateEnvelope] {
        [
            envelope(1, [.title("A"), .volume(0.1)]),
            envelope(2, [.volume(0.5)]),
            envelope(3, [.title("B")]),
            envelope(4, [.volume(0.8), .elapsed(30)])
        ]
    }

    func testCheckerPassesTheRealMerger() {
        let report = ConvergenceProperties.check(merger: StampedFieldMerger(), envelopes: stream)
        XCTAssertTrue(report.passed, report.summary)
        XCTAssertEqual(report.permutationsChecked, 64)
    }

    /// **The test that gives the checker teeth.**
    ///
    /// A property checker that has only ever been observed to pass proves nothing — it
    /// might be asserting something trivially true. So here it is handed a merger that
    /// is wrong in exactly the way this package claims to prevent, and required to
    /// *fail*. If someone later weakens the checker into a no-op, this goes red.
    func testCheckerFailsADeliberatelyBrokenMerger() {
        let report = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: stream)
        XCTAssertFalse(report.passed, "the naive merger must not pass: \(report.summary)")
        XCTAssertTrue(report.kinds.contains(.commutativity),
                      "expected a commutativity counterexample, got \(report.kinds)")
        XCTAssertTrue(report.kinds.contains(.monotonicity),
                      "overwriting ignores stamps, so a field must be seen regressing")
        XCTAssertFalse(report.violations.isEmpty)
        XCTAssertTrue(report.summary.hasPrefix("FAIL"))
    }

    /// `stream` is already in ascending stamp order, which is exactly the input that
    /// hides a stamp-ignoring merger: fed in ascending order it never regresses
    /// anything. This pins the behaviour that the checker must construct the
    /// descending worst case itself rather than trusting the order it was handed.
    func testMonotonicityIsCaughtEvenWhenTheInputIsAlreadySorted() {
        XCTAssertEqual(stream.map(\.stamp), stream.map(\.stamp).sorted(), "precondition: input is sorted")
        let report = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: stream, permutations: 1)
        XCTAssertTrue(report.kinds.contains(.monotonicity), report.summary)
    }

    /// The mirror of the above for the real merger: it must stay monotonic under the
    /// same descending worst case rather than merely surviving a friendly order.
    func testRealMergerStaysMonotonicUnderDescendingDelivery() {
        let report = ConvergenceProperties.check(
            merger: StampedFieldMerger(),
            envelopes: stream.sorted { $0.stamp > $1.stamp })
        XCTAssertTrue(report.passed, report.summary)
    }

    /// A single envelope has one ordering, so a "pass" there would be meaningless.
    /// The checker reports zero permutations rather than a green tick.
    func testTrivialInputIsReportedAsUncheckedNotAsPassing() {
        let report = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: [envelope(1, [.title("A")])])
        XCTAssertEqual(report.permutationsChecked, 0)
        XCTAssertEqual(report.envelopeCount, 1)
    }

    /// Reproducibility alone is a weak assertion — a checker that always returned an
    /// empty report would satisfy it — so this also requires the reproduced report to
    /// carry real content, and requires a *different* seed to still find the bug.
    /// A failure that only one seed can see is a rumour, not a regression test.
    func testCheckerIsReproducibleForAGivenSeedAndSeedIndependentInVerdict() {
        let a = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: stream, permutations: 32, seed: 7)
        let b = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: stream, permutations: 32, seed: 7)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.violations.isEmpty, "an always-empty report would pass equality trivially")

        let other = ConvergenceProperties.check(merger: NaiveOverwriteMerger(), envelopes: stream, permutations: 32, seed: 999)
        XCTAssertFalse(other.passed, "the verdict must not depend on a lucky seed")
        XCTAssertEqual(other.kinds, a.kinds)
    }
}

final class DeterministicRandomTests: XCTestCase {

    /// Golden values, computed independently from the SplitMix64 reference definition.
    ///
    /// This is the load-bearing test of the three. "Same seed gives the same sequence"
    /// below would hold for *any* deterministic function — including one that ignored
    /// the seed — so on its own it proves almost nothing. Pinning actual outputs means
    /// the algorithm cannot be altered without this failing, which matters because
    /// every seeded permutation the property checker explores is derived from it.
    func testMatchesSplitMix64ReferenceOutput() {
        var rng = DeterministicRandom(seed: 42)
        XCTAssertEqual(
            (0..<4).map { _ in rng.next() },
            [13_679_457_532_755_275_413,
             2_949_826_092_126_892_291,
             5_139_283_748_462_763_858,
             6_349_198_060_258_255_764]
        )
        var zero = DeterministicRandom(seed: 0)
        XCTAssertEqual(
            (0..<3).map { _ in zero.next() },
            [16_294_208_416_658_607_535,
             7_960_286_522_194_355_700,
             487_617_019_471_545_679]
        )
    }

    func testSameSeedProducesSameSequence() {
        var a = DeterministicRandom(seed: 42)
        var b = DeterministicRandom(seed: 42)
        let left = (0..<16).map { _ in a.next() }
        let right = (0..<16).map { _ in b.next() }
        XCTAssertEqual(left, right)
    }

    /// Distinct seeds must actually diverge, otherwise "seeded" would be a fancy way of
    /// saying "constant" and every permutation the checker explores would be the same one.
    func testDifferentSeedsDiverge() {
        var a = DeterministicRandom(seed: 1)
        var b = DeterministicRandom(seed: 2)
        XCTAssertNotEqual((0..<8).map { _ in a.next() }, (0..<8).map { _ in b.next() })
    }

    /// The in-range half of this is nearly free — `next() % 7` is in `0..<7` by
    /// construction, so it would hold for an implementation that always returned zero.
    /// The coverage assertion is what has teeth: every residue must actually occur.
    func testIntBelowCoversItsWholeRangeAndToleratesDegenerateBounds() {
        var rng = DeterministicRandom(seed: 5)
        var seen: Set<Int> = []
        for _ in 0..<500 {
            let value = rng.int(below: 7)
            XCTAssertTrue((0..<7).contains(value))
            seen.insert(value)
        }
        XCTAssertEqual(seen, Set(0..<7), "a constant generator would satisfy the range check alone")
        XCTAssertEqual(rng.int(below: 0), 0)
        XCTAssertEqual(rng.int(below: -3), 0)
        XCTAssertEqual(rng.int(below: 1), 0)
    }

    func testShuffleIsAPermutationAndActuallyShuffles() {
        var rng = DeterministicRandom(seed: 11)
        let input = Array(0..<32)
        let shuffled = rng.shuffled(input)
        XCTAssertEqual(shuffled.sorted(), input)
        XCTAssertNotEqual(shuffled, input)
        XCTAssertEqual(rng.shuffled([Int]()), [])
        XCTAssertEqual(rng.shuffled([9]), [9])
    }

    /// Range alone is guaranteed by construction, so this also checks the distribution
    /// is not degenerate — `LossyTransport` compares `unitInterval()` against a drop
    /// rate, and a generator stuck near one end would silently drop everything or
    /// nothing while still passing a bounds check.
    func testUnitIntervalIsInRangeAndNotDegenerate() {
        var rng = DeterministicRandom(seed: 3)
        var sum = 0.0
        var lower = 0
        let count = 2000
        for _ in 0..<count {
            let value = rng.unitInterval()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
            sum += value
            if value < 0.5 { lower += 1 }
        }
        XCTAssertEqual(sum / Double(count), 0.5, accuracy: 0.05, "mean is not near 0.5")
        XCTAssertGreaterThan(lower, count / 4, "too few samples below 0.5")
        XCTAssertLessThan(lower, count * 3 / 4, "too few samples above 0.5")
    }
}

final class LossyTransportTests: XCTestCase {

    func testPerfectProfileIsTheIdentity() {
        let ordered = SessionScript().envelopes(ticks: 10)
        let delivered = LossyTransport(profile: .perfect).deliver(ordered, seed: 1)
        XCTAssertEqual(delivered.map(\.stamp), ordered.map(\.stamp))
    }

    func testEmptyInputIsHandled() {
        XCTAssertTrue(LossyTransport(profile: .hostile).deliver([], seed: 1).isEmpty)
    }

    func testProfileClampsNonsenseConfiguration() {
        let profile = LossyTransport.Profile(dropRate: 5, reorderWindow: -2, coalesceRun: 0)
        XCTAssertEqual(profile.dropRate, 1)
        XCTAssertEqual(profile.reorderWindow, 1)
        XCTAssertEqual(profile.coalesceRun, 1)
    }

    func testDeliveryIsReproducible() {
        let ordered = SessionScript().envelopes(ticks: 15)
        let transport = LossyTransport(profile: .hostile)
        XCTAssertEqual(
            transport.deliver(ordered, seed: 77).map(\.id),
            transport.deliver(ordered, seed: 77).map(\.id)
        )
    }

    func testHostileProfileActuallyDropsAndReorders() {
        let ordered = SessionScript().envelopes(ticks: 30)
        let delivered = LossyTransport(profile: .hostile).deliver(ordered, seed: 5)
        XCTAssertLessThan(delivered.count, ordered.count, "nothing was dropped")
        let sequences = delivered.map(\.stamp.sequence)
        XCTAssertNotEqual(sequences, sequences.sorted(), "nothing was reordered")
    }

    /// Collapse is per-topic. A session announcement must not be swallowed by the run of
    /// progress ticks around it — otherwise a memoryless extension could never recover
    /// the track title after one unlucky burst.
    func testCoalescingIsScopedToATopic() {
        let script = SessionScript()
        let ordered = script.envelopes(ticks: 12)
        let coalesced = LossyTransport(profile: LossyTransport.Profile(dropRate: 0, reorderWindow: 1, coalesceRun: 3))
            .deliver(ordered, seed: 1)
        let announcements = coalesced.filter { $0.touchedFields.contains(.title) }
        XCTAssertGreaterThanOrEqual(announcements.count, 3,
                                    "identity announcements were collapsed into the tick stream")
        XCTAssertLessThan(coalesced.count, ordered.count, "ticks were not collapsed at all")
    }
}
