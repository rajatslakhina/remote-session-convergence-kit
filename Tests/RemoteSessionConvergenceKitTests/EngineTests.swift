import XCTest
@testable import RemoteSessionConvergenceKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let speaker = OriginID.speaker
private let device = MediaDeviceID("living-room-speaker")

private func envelope(
    _ sequence: UInt64,
    _ updates: [FieldUpdate],
    causedBy: CommandID? = nil,
    origin: OriginID = speaker
) -> StateEnvelope {
    StateEnvelope(
        stamp: Stamp(sequence: sequence, origin: origin),
        emittedAt: t0.addingTimeInterval(Double(sequence)),
        causedBy: causedBy,
        updates: updates
    )
}

private let announce = envelope(1, [
    .device(device),
    .capabilities([.transport, .seek, .absoluteVolume, .relativeVolume]),
    .title("Ashes of Orion"),
    .duration(200),
    .volume(0.4),
    .playbackRate(1),
    .elapsed(0)
])

// MARK: - Optimistic overlay / echo suppression

final class OptimisticOverlayTests: XCTestCase {

    private func pending(_ id: String, at date: Date = t0, timeout: TimeInterval = 6) -> PendingCommand {
        PendingCommand(
            id: CommandID(id),
            field: .volume,
            capability: .absoluteVolume,
            device: device,
            optimistic: .volume(0.9),
            issuedAt: date,
            expiresAt: date.addingTimeInterval(timeout)
        )
    }

    func testCapacityIsEnforcedWithFIFOEviction() {
        var overlay = OptimisticOverlay(capacity: 3, commandTimeout: 60)
        for index in 0..<10 {
            overlay.track(pending("cmd-\(index)"))
        }
        XCTAssertEqual(overlay.count, 3)
        XCTAssertFalse(overlay.contains(CommandID("cmd-0")))
        XCTAssertTrue(overlay.contains(CommandID("cmd-9")))
        XCTAssertEqual(overlay.pending.map(\.id.rawValue), ["cmd-7", "cmd-8", "cmd-9"])
    }

    func testEvictionReturnsTheDisplacedEntries() {
        var overlay = OptimisticOverlay(capacity: 2, commandTimeout: 60)
        XCTAssertTrue(overlay.track(pending("a")).isEmpty)
        XCTAssertTrue(overlay.track(pending("b")).isEmpty)
        let evicted = overlay.track(pending("c"))
        XCTAssertEqual(evicted.map(\.id.rawValue), ["a"])
    }

    func testDegenerateCapacityIsClamped() {
        var overlay = OptimisticOverlay(capacity: 0, commandTimeout: -5)
        XCTAssertEqual(overlay.capacity, 1)
        XCTAssertGreaterThan(overlay.commandTimeout, 0)
        overlay.track(pending("only"))
        XCTAssertEqual(overlay.count, 1)
    }

    func testConfirmationRetiresTheEntryExactlyOnce() {
        var overlay = OptimisticOverlay()
        overlay.track(pending("a"))
        let ack = envelope(2, [.volume(0.9)], causedBy: CommandID("a"))
        XCTAssertEqual(overlay.classify(ack), .confirmation(CommandID("a")))
        // A retried delivery of the same acknowledgement must not confirm twice.
        XCTAssertEqual(overlay.classify(ack), .unmatchedEcho(CommandID("a")))
        XCTAssertEqual(overlay.count, 0)
    }

    func testEnvelopeWithoutCommandIDIsARemoteUpdate() {
        var overlay = OptimisticOverlay()
        XCTAssertEqual(overlay.classify(envelope(2, [.volume(0.1)])), .remoteUpdate)
    }

    func testExpiryReturnsCasualtiesAndLeavesSurvivors() {
        var overlay = OptimisticOverlay(capacity: 8, commandTimeout: 6)
        overlay.track(pending("old", at: t0, timeout: 1))
        overlay.track(pending("new", at: t0, timeout: 100))
        let expired = overlay.expire(now: t0.addingTimeInterval(5))
        XCTAssertEqual(expired.map(\.id.rawValue), ["old"])
        XCTAssertEqual(overlay.pending.map(\.id.rawValue), ["new"])
        XCTAssertTrue(overlay.expire(now: t0.addingTimeInterval(5)).isEmpty)
    }

    func testOverlayPaintsIntentWithoutTouchingConvergedStamps() {
        var overlay = OptimisticOverlay()
        overlay.track(pending("a"))
        let converged = StampedFieldMerger().apply(announce, to: .unknown)
        let displayed = overlay.overlaid(on: converged)
        XCTAssertEqual(displayed.volume.value, 0.9)
        // Crucially the *stamp* is untouched: local intent must never be able to win a
        // future merge against a genuine remote update.
        XCTAssertEqual(displayed.volume.stamp, converged.volume.stamp)
        XCTAssertEqual(converged.volume.value, 0.4, "converged state must not be mutated")
    }
}

// MARK: - Capability trust

final class CapabilityTrustLedgerTests: XCTestCase {

    func testCapabilityIsWithdrawnOnlyAfterTheThreshold() {
        var ledger = CapabilityTrustLedger(distrustThreshold: 3)
        XCTAssertTrue(ledger.isTrusted(device: device, capability: .absoluteVolume))
        ledger.recordUnhonoured(device: device, capability: .absoluteVolume)
        ledger.recordUnhonoured(device: device, capability: .absoluteVolume)
        XCTAssertTrue(ledger.isTrusted(device: device, capability: .absoluteVolume),
                      "two strikes is not three")
        ledger.recordUnhonoured(device: device, capability: .absoluteVolume)
        XCTAssertFalse(ledger.isTrusted(device: device, capability: .absoluteVolume))
    }

    func testOneSuccessRestoresTrust() {
        var ledger = CapabilityTrustLedger(distrustThreshold: 2)
        ledger.recordUnhonoured(device: device, capability: .seek)
        ledger.recordUnhonoured(device: device, capability: .seek)
        XCTAssertFalse(ledger.isTrusted(device: device, capability: .seek))
        ledger.recordHonoured(device: device, capability: .seek)
        XCTAssertTrue(ledger.isTrusted(device: device, capability: .seek))
    }

    func testDistrustIsScopedToOneCapabilityAndOneDevice() {
        var ledger = CapabilityTrustLedger(distrustThreshold: 1)
        ledger.recordUnhonoured(device: device, capability: .absoluteVolume)
        let advertised: CapabilitySet = [.transport, .seek, .absoluteVolume, .relativeVolume]
        let effective = ledger.effectiveCapabilities(advertised: advertised, device: device)
        XCTAssertFalse(effective.contains(.absoluteVolume))
        XCTAssertTrue(effective.contains(.relativeVolume))
        XCTAssertTrue(effective.contains(.transport))
        let other = MediaDeviceID("kitchen")
        XCTAssertEqual(ledger.effectiveCapabilities(advertised: advertised, device: other), advertised)
    }

    func testDeviceTableIsBoundedWithLRUEviction() {
        var ledger = CapabilityTrustLedger(distrustThreshold: 1, maxTrackedDevices: 4)
        for index in 0..<40 {
            ledger.recordUnhonoured(device: MediaDeviceID("device-\(index)"), capability: .seek)
        }
        XCTAssertEqual(ledger.trackedDeviceCount, 4)
        // The oldest device's record is gone, so it is trusted again by default rather
        // than silently retaining state for every endpoint ever seen.
        XCTAssertTrue(ledger.isTrusted(device: MediaDeviceID("device-0"), capability: .seek))
        XCTAssertFalse(ledger.isTrusted(device: MediaDeviceID("device-39"), capability: .seek))
    }

    func testEffectiveCapabilitiesNeverAddsAnythingUnadvertised() {
        var ledger = CapabilityTrustLedger()
        ledger.recordHonoured(device: device, capability: .skip)
        let advertised: CapabilitySet = [.transport]
        XCTAssertEqual(ledger.effectiveCapabilities(advertised: advertised, device: device), advertised)
        XCTAssertEqual(ledger.effectiveCapabilities(advertised: .none, device: device), .none)
    }
}

// MARK: - Staleness and projection

final class StalenessTests: XCTestCase {

    func testThresholdsAreForcedIntoOrder() {
        let policy = StalenessPolicy(agingAfter: 50, staleAfter: 10, presumedLostAfter: 1)
        XCTAssertLessThanOrEqual(policy.agingAfter, policy.staleAfter)
        XCTAssertLessThanOrEqual(policy.staleAfter, policy.presumedLostAfter)
    }

    func testNonFiniteThresholdsFallBackInsteadOfPoisoningComparisons() {
        let policy = StalenessPolicy(agingAfter: .nan, staleAfter: .infinity, presumedLostAfter: .nan)
        XCTAssertTrue(policy.agingAfter.isFinite)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0, now: t0), .fresh)
    }

    func testFreshnessBands() {
        let policy = StalenessPolicy(agingAfter: 5, staleAfter: 20, presumedLostAfter: 90)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0, now: t0.addingTimeInterval(1)), .fresh)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0, now: t0.addingTimeInterval(10)), .aging)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0, now: t0.addingTimeInterval(30)), .stale)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0, now: t0.addingTimeInterval(300)), .presumedLost)
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: nil, now: t0), .presumedLost)
    }

    func testClockSkewIsNotMistakenForStaleness() {
        let policy = StalenessPolicy.default
        // Producer timestamp from the future.
        XCTAssertEqual(policy.freshness(lastEnvelopeAt: t0.addingTimeInterval(600), now: t0), .fresh)
    }

    func testExtrapolationAdvancesThePlayheadWhilePlaying() {
        var state = RemoteSessionState.unknown
        let stamp = Stamp(sequence: 1, origin: speaker)
        state.elapsed = Stamped(10, stamp: stamp)
        state.duration = Stamped(100, stamp: stamp)
        state.playbackRate = Stamped(1, stamp: stamp)

        let projection = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(3), policy: .default)
        XCTAssertEqual(projection.elapsed, 13, accuracy: 0.0001)
        XCTAssertTrue(projection.isExtrapolated)
        XCTAssertEqual(projection.percentComplete, 13)
    }

    func testExtrapolationStopsWhenPausedAndWhenStale() {
        var state = RemoteSessionState.unknown
        let stamp = Stamp(sequence: 1, origin: speaker)
        state.elapsed = Stamped(10, stamp: stamp)
        state.duration = Stamped(100, stamp: stamp)

        state.playbackRate = Stamped(0, stamp: stamp)
        let paused = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(30), policy: .default)
        XCTAssertEqual(paused.elapsed, 10)
        XCTAssertFalse(paused.isExtrapolated)

        state.playbackRate = Stamped(1, stamp: stamp)
        let stale = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(60), policy: .default)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.elapsed, 10, "a stale session must not keep sliding forward")
        XCTAssertFalse(stale.isExtrapolated)
    }

    func testExtrapolationIsClampedToDuration() {
        var state = RemoteSessionState.unknown
        let stamp = Stamp(sequence: 1, origin: speaker)
        state.elapsed = Stamped(95, stamp: stamp)
        state.duration = Stamped(100, stamp: stamp)
        state.playbackRate = Stamped(1, stamp: stamp)
        let projection = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(4), policy: .default)
        XCTAssertEqual(projection.elapsed, 99, accuracy: 0.0001)
        let policy = StalenessPolicy(agingAfter: 1000, staleAfter: 2000, presumedLostAfter: 3000)
        let overrun = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(500), policy: policy)
        XCTAssertEqual(overrun.elapsed, 100)
        XCTAssertEqual(overrun.percentComplete, 100)
    }

    func testProjectionSurvivesPoisonedState() {
        var state = RemoteSessionState.unknown
        let stamp = Stamp(sequence: 1, origin: speaker)
        state.elapsed = Stamped(.nan, stamp: stamp)
        state.duration = Stamped(.infinity, stamp: stamp)
        state.playbackRate = Stamped(.nan, stamp: stamp)
        let projection = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(2), policy: .default)
        XCTAssertEqual(projection.elapsed, 0)
        XCTAssertEqual(projection.duration, 0)
        XCTAssertTrue(projection.isLive)
        XCTAssertEqual(projection.percentComplete, 0)
    }

    func testPlayheadNeverRewindsWhenTheClockGoesBackwards() {
        var state = RemoteSessionState.unknown
        let stamp = Stamp(sequence: 1, origin: speaker)
        state.elapsed = Stamped(50, stamp: stamp)
        state.duration = Stamped(100, stamp: stamp)
        state.playbackRate = Stamped(1, stamp: stamp)
        let projection = PlaybackProjector.project(
            state: state, anchoredAt: t0, now: t0.addingTimeInterval(-20), policy: .default)
        XCTAssertEqual(projection.elapsed, 50)
        XCTAssertFalse(projection.isExtrapolated)
    }
}

// MARK: - Watermark and cold start

final class ColdStartTests: XCTestCase {

    func testFirstLaunchIsNotReportedAsAGap() {
        let outcome = ColdStartReconciler().wake(with: envelope(97, [.title("A")]), watermark: Watermark())
        XCTAssertNil(outcome.gap)
        XCTAssertFalse(outcome.isReplay)
        XCTAssertTrue(outcome.isFullyReconciled)
        XCTAssertEqual(outcome.watermark.sequence(for: speaker), 97)
    }

    func testContiguousSequenceIsClean() {
        var watermark = Watermark()
        watermark.advance(to: Stamp(sequence: 10, origin: speaker))
        let outcome = ColdStartReconciler().wake(with: envelope(11, [.title("A")]), watermark: watermark)
        XCTAssertNil(outcome.gap)
        XCTAssertTrue(outcome.isFullyReconciled)
    }

    func testSkippedSequenceIsReportedWithAnAccurateCount() {
        var watermark = Watermark()
        watermark.advance(to: Stamp(sequence: 10, origin: speaker))
        let outcome = ColdStartReconciler().wake(with: envelope(15, [.title("A")]), watermark: watermark)
        XCTAssertEqual(outcome.gap?.missingCount, 4)
        XCTAssertFalse(outcome.isFullyReconciled)
    }

    func testRedeliveryIsFlaggedAsReplay() {
        var watermark = Watermark()
        watermark.advance(to: Stamp(sequence: 10, origin: speaker))
        let outcome = ColdStartReconciler().wake(with: envelope(4, [.title("A")]), watermark: watermark)
        XCTAssertTrue(outcome.isReplay)
        XCTAssertNil(outcome.gap)
        XCTAssertEqual(outcome.watermark.sequence(for: speaker), 10, "a replay must not lower the watermark")
    }

    /// A server that resets its counter produces a nominal gap that would underflow a
    /// naive `UInt64` subtraction.
    func testGapCountDoesNotUnderflow() {
        let gap = SequenceGap(origin: speaker, lastSeen: 500, received: 3)
        XCTAssertEqual(gap.missingCount, 0)
        XCTAssertEqual(SequenceGap(origin: speaker, lastSeen: 0, received: 0).missingCount, 0)
        XCTAssertEqual(SequenceGap(origin: speaker, lastSeen: 0, received: .max).missingCount, .max - 1)
    }

    func testWakeRebuildsFromTheEnvelopeAloneRatherThanMerging() {
        let outcome = ColdStartReconciler().wake(with: envelope(50, [.title("Only This")]), watermark: Watermark())
        XCTAssertEqual(outcome.state.title.value, "Only This")
        // Nothing else may be resurrected from a previous life of the process.
        XCTAssertEqual(outcome.state.artist.value, "")
        XCTAssertEqual(outcome.state.device.value, .none)
    }

    func testWatermarkIsBoundedAndTrimsTheLowestSequences() {
        var watermark = Watermark(capacity: 3)
        for index in 0..<20 {
            watermark.advance(to: Stamp(sequence: UInt64(index) + 1, origin: OriginID("origin-\(index)")))
        }
        XCTAssertEqual(watermark.perOrigin.count, 3)
        XCTAssertNotNil(watermark.sequence(for: OriginID("origin-19")))
        XCTAssertNil(watermark.sequence(for: OriginID("origin-0")))
    }

    func testWatermarkNeverMovesBackwards() {
        var watermark = Watermark()
        watermark.advance(to: Stamp(sequence: 10, origin: speaker))
        watermark.advance(to: Stamp(sequence: 3, origin: speaker))
        XCTAssertEqual(watermark.sequence(for: speaker), 10)
    }
}

// MARK: - Engine

final class ConvergenceEngineTests: XCTestCase {

    private func makeEngine() -> ConvergenceEngine {
        ConvergenceEngine(overlay: OptimisticOverlay(capacity: 8, commandTimeout: 6))
    }

    func testIngestReportsAdvancedFieldsAndSupersession() async {
        let engine = makeEngine()
        let first = await engine.ingest(announce, now: t0)
        XCTAssertTrue(first.didAdvance)
        XCTAssertTrue(first.advancedFields.contains(.title))

        // A late arrival carrying an older volume must change nothing.
        let late = envelope(0, [.volume(0.99)])
        let second = await engine.ingest(late, now: t0.addingTimeInterval(1))
        XCTAssertFalse(second.didAdvance)
        XCTAssertTrue(second.isReplay)
        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(1))
        XCTAssertEqual(snapshot.converged.volume.value, 0.4)
    }

    func testDuplicateDeliveryDoesNotRefreshTheStalenessAnchor() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        // Same envelope redelivered a minute later — it carries no news, so the session
        // must still read as stale rather than being scrubbed fresh by a retry.
        await engine.ingest(announce, now: t0.addingTimeInterval(60))
        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(60))
        XCTAssertEqual(snapshot.projection.freshness, .stale)
    }

    func testGapIsSurfacedOnTheSnapshot() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        let outcome = await engine.ingest(envelope(9, [.elapsed(40)]), now: t0.addingTimeInterval(1))
        XCTAssertEqual(outcome.gap?.missingCount, 7)
        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(1))
        XCTAssertTrue(snapshot.hasUnreconciledGap)
    }

    func testCommandIsRejectedBeforeADeviceExists() async {
        let engine = makeEngine()
        let disposition = await engine.issue(RemoteCommand(id: CommandID("a"), intent: .play), now: t0)
        XCTAssertEqual(disposition, .rejectedNoDevice)
    }

    func testUnadvertisedCapabilityIsRefusedRatherThanSentIntoTheVoid() async {
        let engine = makeEngine()
        await engine.ingest(envelope(1, [.device(device), .capabilities([.transport])]), now: t0)
        let disposition = await engine.issue(RemoteCommand(id: CommandID("s"), intent: .seek(to: 30)), now: t0)
        XCTAssertEqual(disposition, .rejectedUnsupported(.seek))
        let snapshot = await engine.snapshot(now: t0)
        XCTAssertTrue(snapshot.pendingCommands.isEmpty, "a refused command must not be shown as in flight")
    }

    func testDispatchPaintsOptimisticallyWithoutTouchingConvergedState() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        let disposition = await engine.issue(RemoteCommand(id: CommandID("v"), intent: .setVolume(0.9)), now: t0)
        guard case .dispatched(_, let optimistic) = disposition else {
            return XCTFail("expected dispatch, got \(disposition)")
        }
        XCTAssertEqual(optimistic, .volume(0.9))
        let snapshot = await engine.snapshot(now: t0)
        XCTAssertEqual(snapshot.displayed.volume.value, 0.9)
        XCTAssertEqual(snapshot.converged.volume.value, 0.4)
        XCTAssertEqual(snapshot.pendingCommands.count, 1)
    }

    func testEchoOfOurOwnCommandIsConfirmedNotReplayed() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        _ = await engine.issue(RemoteCommand(id: CommandID("v"), intent: .setVolume(0.9)), now: t0)
        let ack = envelope(2, [.volume(0.9)], causedBy: CommandID("v"))
        let outcome = await engine.ingest(ack, now: t0.addingTimeInterval(1))
        XCTAssertEqual(outcome.decision, .confirmation(CommandID("v")))

        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(1))
        XCTAssertTrue(snapshot.pendingCommands.isEmpty)
        XCTAssertEqual(snapshot.converged.volume.value, 0.9)
        // The acknowledgement credited the capability, so it stays trusted.
        let record = await engine.trustRecord(device: device, capability: .absoluteVolume)
        XCTAssertEqual(record.honoured, 1)
        XCTAssertEqual(record.consecutiveUnhonoured, 0)
    }

    /// The full degrade-don't-lie path, end to end: an endpoint that advertises absolute
    /// volume and then never acknowledges anything loses the control, and the next
    /// command is expressed as a relative nudge instead of pretending to have worked.
    func testRepeatedSilenceDegradesAbsoluteVolumeToRelative() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)

        var now = t0
        for attempt in 0..<3 {
            let disposition = await engine.issue(
                RemoteCommand(id: CommandID("v-\(attempt)"), intent: .setVolume(0.8)), now: now)
            guard case .dispatched = disposition else {
                return XCTFail("attempt \(attempt) should still dispatch, got \(disposition)")
            }
            now = now.addingTimeInterval(10)
            let expired = await engine.tick(now: now)
            XCTAssertEqual(expired.count, 1)
        }

        let snapshot = await engine.snapshot(now: now)
        XCTAssertTrue(snapshot.advertisedCapabilities.contains(.absoluteVolume))
        XCTAssertFalse(snapshot.effectiveCapabilities.contains(.absoluteVolume),
                       "the control must be withdrawn once the device has proven it ignores it")
        XCTAssertTrue(snapshot.effectiveCapabilities.contains(.relativeVolume))

        let degraded = await engine.issue(
            RemoteCommand(id: CommandID("v-final"), intent: .setVolume(0.8)), now: now)
        guard case .degraded(let sent, let from, _) = degraded else {
            return XCTFail("expected a degrade, got \(degraded)")
        }
        XCTAssertEqual(from, .absoluteVolume)
        guard case .adjustVolume(let delta) = sent.intent else {
            return XCTFail("expected a relative nudge, got \(sent.intent)")
        }
        // Converged volume is still 0.4, so "go to 0.8" becomes "+0.4".
        XCTAssertEqual(delta, 0.4, accuracy: 0.0001)
    }

    func testDegradeRefusesWhenNoWeakerCapabilityExists() async {
        let engine = makeEngine()
        await engine.ingest(envelope(1, [.device(device), .capabilities([.absoluteVolume])]), now: t0)
        var now = t0
        for attempt in 0..<3 {
            _ = await engine.issue(RemoteCommand(id: CommandID("v-\(attempt)"), intent: .setVolume(0.8)), now: now)
            now = now.addingTimeInterval(10)
            await engine.tick(now: now)
        }
        let disposition = await engine.issue(RemoteCommand(id: CommandID("last"), intent: .setVolume(0.8)), now: now)
        XCTAssertEqual(disposition, .rejectedUnsupported(.absoluteVolume))
    }

    func testWakeDiscardsInProcessStateAndClearsPendingCommands() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        _ = await engine.issue(RemoteCommand(id: CommandID("v"), intent: .setVolume(0.9)), now: t0)

        let outcome = await engine.wake(with: envelope(9, [.title("After Relaunch")]), now: t0.addingTimeInterval(5))
        XCTAssertEqual(outcome.gap?.missingCount, 7)
        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(5))
        XCTAssertEqual(snapshot.converged.title.value, "After Relaunch")
        XCTAssertEqual(snapshot.converged.device.value, .none, "state must not survive a cold launch")
        XCTAssertTrue(snapshot.pendingCommands.isEmpty, "in-flight intent must not survive a cold launch")
    }

    /// The engine is an actor whose methods have no internal suspension points, so a
    /// burst of concurrent ingests can interleave in any order and must still converge
    /// on the same state as an ordered delivery. This drives real concurrent writers —
    /// a "concurrency test" with a single writer would prove nothing.
    func testConcurrentIngestConvergesToTheOrderedResult() async {
        let script = SessionScript()
        let envelopes = script.envelopes(ticks: 24)

        let concurrent = ConvergenceEngine()
        await withTaskGroup(of: Void.self) { group in
            for envelope in envelopes {
                group.addTask {
                    await concurrent.ingest(envelope, now: t0)
                }
            }
        }

        let sequential = ConvergenceEngine()
        for envelope in envelopes {
            await sequential.ingest(envelope, now: t0)
        }

        let a = await concurrent.snapshot(now: t0)
        let b = await sequential.snapshot(now: t0)
        XCTAssertEqual(a.converged, b.converged)
        XCTAssertEqual(a.converged.title.value, script.title)
    }

    func testEmptyEnvelopeIsHarmless() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        let outcome = await engine.ingest(envelope(2, []), now: t0.addingTimeInterval(1))
        XCTAssertTrue(outcome.advancedFields.isEmpty)
        let snapshot = await engine.snapshot(now: t0.addingTimeInterval(1))
        XCTAssertEqual(snapshot.converged.title.value, "Ashes of Orion")
    }

    func testCommandsFromMultipleOriginsDoNotCrossContaminateWatermarks() async {
        let engine = makeEngine()
        await engine.ingest(announce, now: t0)
        let fromServer = envelope(1, [.playbackRate(0)], origin: .server)
        let outcome = await engine.ingest(fromServer, now: t0.addingTimeInterval(1))
        XCTAssertNil(outcome.gap, "a first sighting of a new origin is not a gap")
        XCTAssertFalse(outcome.isReplay)
        let watermark = await engine.currentWatermark()
        XCTAssertEqual(watermark.sequence(for: .speaker), 1)
        XCTAssertEqual(watermark.sequence(for: .server), 1)
    }
}

// MARK: - Commands

final class RemoteCommandTests: XCTestCase {

    func testRelativeVolumeIsComputedFromWhatIsOnScreen() {
        var state = RemoteSessionState.unknown
        state.volume = Stamped(0.5, stamp: Stamp(sequence: 1, origin: speaker))
        let command = RemoteCommand(id: CommandID("a"), intent: .adjustVolume(delta: 0.3))
        XCTAssertEqual(command.optimisticUpdate(given: state), .volume(0.8))
    }

    func testOptimisticValuesAreClampedAgainstHostileInput() {
        var state = RemoteSessionState.unknown
        state.volume = Stamped(0.9, stamp: Stamp(sequence: 1, origin: speaker))
        state.duration = Stamped(100, stamp: Stamp(sequence: 1, origin: speaker))
        XCTAssertEqual(
            RemoteCommand(id: CommandID("a"), intent: .adjustVolume(delta: 5)).optimisticUpdate(given: state),
            .volume(1))
        XCTAssertEqual(
            RemoteCommand(id: CommandID("b"), intent: .adjustVolume(delta: .nan)).optimisticUpdate(given: state),
            .volume(0.9))
        XCTAssertEqual(
            RemoteCommand(id: CommandID("c"), intent: .seek(to: 5000)).optimisticUpdate(given: state),
            .elapsed(100))
        XCTAssertEqual(
            RemoteCommand(id: CommandID("d"), intent: .seek(to: -5)).optimisticUpdate(given: state),
            .elapsed(0))
    }

    func testRequiredCapabilityMapping() {
        XCTAssertEqual(RemoteCommand(id: CommandID("a"), intent: .play).requiredCapability, .transport)
        XCTAssertEqual(RemoteCommand(id: CommandID("b"), intent: .setVolume(1)).requiredCapability, .absoluteVolume)
        XCTAssertEqual(
            RemoteCommand(id: CommandID("c"), intent: .adjustVolume(delta: 0.1)).requiredCapability,
            .relativeVolume)
        XCTAssertEqual(RemoteCommand(id: CommandID("d"), intent: .seek(to: 1)).requiredCapability, .seek)
    }
}
