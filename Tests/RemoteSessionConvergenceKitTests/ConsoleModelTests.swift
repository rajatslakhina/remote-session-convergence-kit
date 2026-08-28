import XCTest
@testable import RemoteSessionConvergenceKit

/// These cover the demo's on-screen claims.
///
/// Everything the demo README promises a reader will see is asserted here rather than
/// left to "trace the view by hand and hope". The view is layout over this model, so if
/// these pass, the screen shows what the README says it shows.
///
/// The test case is deliberately **not** annotated `@MainActor`, even though the model
/// is. Two reasons: Linux's generated XCTest discovery shim cannot call a main-actor
/// isolated test case under the Swift 6 language mode, and crossing the boundary
/// explicitly with `await` on every access is a more faithful exercise of the model's
/// isolation than erasing the boundary would be. Every value that crosses back —
/// `SessionSnapshot`, `ConvergenceReport`, `DeliveryRecord`, `CommandDisposition` — is
/// `Sendable`, which is what makes this legal at all.
final class ConvergenceConsoleModelTests: XCTestCase {

    private func makeModel(
        transport: LossyTransport.Profile = .hostile,
        logLimit: Int = 60
    ) async -> ConvergenceConsoleModel {
        await ConvergenceConsoleModel(
            configuration: ConvergenceConsoleConfiguration(
                transport: transport,
                ticksPerBurst: 12,
                permutations: 32,
                seed: 0xC0FF_EE00_1234_5678
            ),
            logLimit: logLimit
        )
    }

    /// The headline requirement: the screen must be populated *before* the reader
    /// touches anything. A demo whose default state is empty demonstrates nothing.
    func testBootstrapPopulatesTheDefaultScreen() async {
        let model = await makeModel()
        let before = await model.snapshot
        XCTAssertNil(before)

        await model.bootstrap()

        guard let snapshot = await model.snapshot else { return XCTFail("no snapshot after bootstrap") }
        let log = await model.log
        let report = await model.report
        XCTAssertFalse(log.isEmpty, "delivery log must not be empty on first render")
        XCTAssertNotNil(report)

        // Identity survives a hostile transport because the script re-announces it.
        XCTAssertEqual(snapshot.displayed.title.value, "Ashes of Orion")
        XCTAssertEqual(snapshot.displayed.artist.value, "Kepler Field")
        XCTAssertEqual(snapshot.displayed.device.value, MediaDeviceID("living-room-speaker"))
        XCTAssertGreaterThan(snapshot.displayed.duration.value, 0)
        XCTAssertFalse(snapshot.advertisedCapabilities.isEmpty)
    }

    func testBootstrapIsIdempotent() async {
        let model = await makeModel()
        await model.bootstrap()
        let firstCount = await model.log.count
        await model.bootstrap()
        let secondCount = await model.log.count
        let bursts = await model.burstCount
        XCTAssertEqual(secondCount, firstCount, "bootstrap must not double-deliver")
        XCTAssertEqual(bursts, 1)
    }

    /// The demo's whole reason to exist: same envelopes, same transport, one merge rule
    /// apart, and the panel flips from PASS to FAIL where the reader can see it.
    func testStrategyToggleFlipsThePropertyPanelFromPassToFail() async {
        let model = await makeModel()
        await model.bootstrap()

        guard let passing = await model.report else { return XCTFail("no report") }
        XCTAssertTrue(passing.passed, "stamped merge must pass: \(passing.summary)")
        XCTAssertTrue(passing.summary.hasPrefix("PASS"))
        XCTAssertGreaterThan(passing.permutationsChecked, 1,
                             "a report over a single ordering would prove nothing")

        await model.setStrategy(.naive)

        guard let failing = await model.report else { return XCTFail("no report after toggle") }
        XCTAssertFalse(failing.passed, "naive merge must fail on a reordering transport")
        XCTAssertTrue(failing.summary.hasPrefix("FAIL"))
        XCTAssertTrue(failing.kinds.contains(.commutativity))
        XCTAssertFalse(failing.violations.isEmpty, "the panel must have something to print")

        // And back again, so the toggle is genuinely reversible on screen.
        await model.setStrategy(.stamped)
        let restored = await model.report?.passed
        XCTAssertEqual(restored, true)
    }

    func testSettingTheSameStrategyIsANoOp() async {
        let model = await makeModel()
        await model.bootstrap()
        let bursts = await model.burstCount
        await model.setStrategy(.stamped)
        let after = await model.burstCount
        XCTAssertEqual(after, bursts)
    }

    /// The sequence the demo README tells the reader to try, executed. If it ever stops
    /// producing a degrade, the README is lying and this test says so.
    func testDocumentedDegradeSequenceReachesADegrade() async {
        let model = await makeModel()
        await model.bootstrap()

        guard let start = await model.snapshot else { return XCTFail("no snapshot") }
        XCTAssertTrue(start.advertisedCapabilities.contains(.absoluteVolume))
        XCTAssertTrue(start.effectiveCapabilities.contains(.absoluteVolume),
                      "absolute volume must start trusted, or there is nothing to withdraw")

        for round in 0..<3 {
            await model.issueVolume(0.9)
            let disposition = await model.lastDisposition
            guard case .dispatched = disposition else {
                return XCTFail("round \(round) should dispatch, got \(String(describing: disposition))")
            }
            await model.expirePending()
        }

        guard let after = await model.snapshot else { return XCTFail("no snapshot") }
        XCTAssertTrue(after.advertisedCapabilities.contains(.absoluteVolume),
                      "the device still claims it — that is the point")
        XCTAssertFalse(after.effectiveCapabilities.contains(.absoluteVolume),
                       "trust must be withdrawn after three unacknowledged commands")

        await model.issueVolume(0.9)
        let final = await model.lastDisposition
        guard case .degraded(let sent, let from, _) = final else {
            return XCTFail("expected a degrade, got \(String(describing: final))")
        }
        XCTAssertEqual(from, .absoluteVolume)
        guard case .adjustVolume = sent.intent else {
            return XCTFail("expected a relative nudge, got \(sent.intent)")
        }
    }

    func testOptimisticVolumeIsVisibleImmediatelyAndOnlyInDisplayedState() async {
        let model = await makeModel()
        await model.bootstrap()
        let convergedBefore = await model.snapshot?.converged.volume.value
        await model.issueVolume(0.9)

        let snapshot = await model.snapshot
        XCTAssertEqual(snapshot?.displayed.volume.value, 0.9)
        XCTAssertEqual(snapshot?.converged.volume.value, convergedBefore,
                       "local intent must not leak into converged state")
        XCTAssertEqual(snapshot?.pendingCommands.count, 1)
    }

    func testExpiringPendingCommandsClearsTheInFlightCount() async {
        let model = await makeModel()
        await model.bootstrap()
        await model.issueVolume(0.9)
        let during = await model.snapshot?.pendingCommands.count
        XCTAssertEqual(during, 1)
        await model.expirePending()
        let after = await model.snapshot?.pendingCommands.count
        XCTAssertEqual(after, 0)
    }

    func testTogglePlaybackFlipsBetweenPlayAndPause() async {
        let model = await makeModel()
        await model.bootstrap()
        let start = await model.snapshot?.displayed.playbackRate.value
        XCTAssertEqual(start, 1, "the script starts playing")

        await model.togglePlayback()
        let paused = await model.snapshot?.displayed.playbackRate.value
        XCTAssertEqual(paused, 0)

        await model.togglePlayback()
        let resumed = await model.snapshot?.displayed.playbackRate.value
        XCTAssertEqual(resumed, 1)
    }

    func testResetReturnsToAFreshlyBootstrappedScreen() async {
        let model = await makeModel()
        await model.bootstrap()
        await model.deliverBurst()
        await model.issueVolume(0.9)
        let bursts = await model.burstCount
        XCTAssertEqual(bursts, 2)

        await model.reset()
        let afterBursts = await model.burstCount
        let disposition = await model.lastDisposition
        let pending = await model.snapshot?.pendingCommands.count
        let log = await model.log
        XCTAssertEqual(afterBursts, 1)
        XCTAssertNil(disposition)
        XCTAssertEqual(pending, 0)
        XCTAssertFalse(log.isEmpty)
    }

    /// The log is the one unbounded-growth risk in the demo, so the cap is asserted
    /// rather than assumed.
    func testDeliveryLogIsBounded() async {
        let model = await makeModel(logLimit: 10)
        for _ in 0..<8 {
            await model.deliverBurst()
        }
        let log = await model.log
        XCTAssertEqual(log.count, 10)
        // FIFO: the survivors are the most recent ids, still in order.
        let ids = log.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(ids.last, ids.max())
    }

    func testDegenerateLogLimitIsClamped() async {
        let model = await ConvergenceConsoleModel(logLimit: 0)
        let limit = await model.logLimit
        XCTAssertEqual(limit, 1)
    }

    func testDeliveryVerdictsCoverTheRealOutcomes() async {
        let model = await makeModel()
        await model.bootstrap()
        await model.deliverBurst()
        let log = await model.log
        let verdicts = Set(log.map(\.verdict))
        XCTAssertTrue(verdicts.contains("applied"), "nothing was applied: \(verdicts)")
        // A second burst replays sequences already seen, so those must show up too.
        XCTAssertTrue(verdicts.contains("replay") || verdicts.contains("superseded"),
                      "a redelivered burst should produce replays or supersessions: \(verdicts)")
        XCTAssertFalse(log.contains { $0.label.isEmpty })
    }

    /// The control case: a lossless transport must also converge, proving the PASS is
    /// not an artefact of the specific mangling profile.
    func testPerfectTransportAlsoPasses() async {
        let model = await makeModel(transport: .perfect)
        await model.bootstrap()
        let passed = await model.report?.passed
        let gap = await model.snapshot?.hasUnreconciledGap
        XCTAssertEqual(passed, true)
        XCTAssertEqual(gap, false, "a lossless delivery must not report a gap")
    }

    /// Conversely the hostile transport must genuinely lose things, otherwise the demo
    /// would be quietly showing a clean stream while claiming otherwise.
    func testHostileTransportActuallyLosesUpdates() async {
        let model = await makeModel()
        await model.bootstrap()
        let gap = await model.snapshot?.hasUnreconciledGap
        XCTAssertEqual(gap, true, "the hostile profile should have dropped at least one update")
    }

    /// Pins the exact figures the demo app's README quotes.
    ///
    /// The demo repository has no test target of its own, so its `DemoConfiguration`
    /// values are mirrored here — same script, profile, seed and tick count. The point
    /// is not to test the transport again but to make a stale README a **failing test**
    /// rather than something a reader has to catch. If these numbers move, the README
    /// sentence quoting them is wrong and this says so by name.
    func testHostileDemoStreamNumbersAreStable() {
        let script = SessionScript(
            device: MediaDeviceID("living-room-speaker"),
            capabilities: [.transport, .seek, .absoluteVolume, .relativeVolume, .skip],
            title: "Ashes of Orion",
            artist: "Kepler Field",
            duration: 214
        )
        let seed: UInt64 = 0xC0FF_EE00_1234_5678
        let ordered = script.envelopes(ticks: 36)
        let delivered = LossyTransport(profile: .hostile).deliver(ordered, seed: seed)

        XCTAssertEqual(ordered.count, 46, "envelopes generated per burst")
        XCTAssertEqual(delivered.count, 13, "envelopes surviving the hostile transport")

        let passing = ConvergenceProperties.check(
            merger: StampedFieldMerger(), envelopes: delivered, permutations: 96, seed: seed)
        XCTAssertEqual(passing.summary, "PASS — 13 envelopes, 96 orderings agree")

        let failing = ConvergenceProperties.check(
            merger: NaiveOverwriteMerger(), envelopes: delivered, permutations: 96, seed: seed)
        XCTAssertEqual(failing.summary, "FAIL — 2 violation(s): commutativity, monotonicity")
    }
}
