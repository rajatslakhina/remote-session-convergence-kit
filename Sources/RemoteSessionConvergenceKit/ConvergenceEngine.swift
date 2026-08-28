import Foundation

/// What ingesting one envelope did.
public struct IngestOutcome: Sendable, Equatable {
    public let decision: EchoDecision
    /// Fields this envelope actually moved forward. Empty means the envelope was
    /// entirely superseded — a late arrival carrying nothing new, which on a reordering
    /// transport is normal traffic rather than an error.
    public let advancedFields: Set<SessionField>
    public let gap: SequenceGap?
    public let isReplay: Bool

    public var didAdvance: Bool { !advancedFields.isEmpty }
}

/// Everything the UI needs for one frame.
public struct SessionSnapshot: Sendable, Equatable {
    /// Server-sequenced truth, with no local intent mixed in.
    public let converged: RemoteSessionState
    /// `converged` with in-flight local intent painted on top. This is what to render.
    public let displayed: RemoteSessionState
    public let projection: PlaybackProjection
    /// What the device claims.
    public let advertisedCapabilities: CapabilitySet
    /// What it has actually demonstrated. Bind controls to this one.
    public let effectiveCapabilities: CapabilitySet
    public let pendingCommands: [PendingCommand]
    public let lastGap: SequenceGap?
    public let lastEnvelopeAt: Date?

    /// True when a hole was detected in the sequence and never subsequently closed —
    /// the session is drawable but its history is known to be incomplete.
    public var hasUnreconciledGap: Bool { lastGap != nil }
}

/// The convergence control plane.
///
/// ## Concurrency
///
/// This is an `actor`, and every method below has a **fully synchronous body**: there
/// is no `await` anywhere between reading engine state and writing it back. That is a
/// deliberate constraint, not an accident of how it was written.
///
/// Actor isolation guarantees mutual exclusion, but it does *not* guarantee atomicity
/// across a suspension point — if a method awaited in the middle of a read-modify-write,
/// another task could be admitted into the actor and observe or mutate half-applied
/// state, and the resulting interleaving bugs are exactly the kind that reproduce once
/// a week in production. Keeping every critical section suspension-free makes the
/// entire class of reentrancy bug unrepresentable here.
///
/// The cost is that I/O — sending on the command channel, persisting the watermark —
/// belongs *outside* the engine, at the call site, using the values the engine returns.
/// That is the intended division of labour: this type is the policy, not the plumbing.
public actor ConvergenceEngine {

    private let merger: any EnvelopeMerging
    private let policy: StalenessPolicy

    private var state: RemoteSessionState = .unknown
    private var overlay: OptimisticOverlay
    private var ledger: CapabilityTrustLedger
    private var watermark: Watermark
    private var lastEnvelopeAt: Date?
    private var lastGap: SequenceGap?

    public init(
        merger: any EnvelopeMerging = StampedFieldMerger(),
        policy: StalenessPolicy = .default,
        overlay: OptimisticOverlay = OptimisticOverlay(),
        ledger: CapabilityTrustLedger = CapabilityTrustLedger(),
        watermark: Watermark = Watermark()
    ) {
        self.merger = merger
        self.policy = policy
        self.overlay = overlay
        self.ledger = ledger
        self.watermark = watermark
    }

    // MARK: - Inbound

    /// Applies one push payload.
    @discardableResult
    public func ingest(_ envelope: StateEnvelope, now: Date) -> IngestOutcome {
        let (gap, isReplay) = classifySequence(of: envelope.stamp)

        let before = state
        let after = merger.apply(envelope, to: before)
        let advanced = RemoteSessionState.divergentFields(before, after)
            .intersection(envelope.touchedFields)
        state = after

        let decision = overlay.classify(envelope)
        if case .confirmation(let id) = decision {
            // The endpoint did what it was asked. Credit the capability so a device
            // that works keeps its controls.
            if let capability = capability(forConfirmed: id, envelope: envelope) {
                ledger.recordHonoured(device: state.device.value, capability: capability)
            }
        }

        watermark.advance(to: envelope.stamp)
        if gap != nil { lastGap = gap }
        // Only advance the anchor on envelopes that carried news. A duplicate
        // redelivery must not make a stale session look freshly updated.
        if !advanced.isEmpty || lastEnvelopeAt == nil {
            lastEnvelopeAt = now
        }

        return IngestOutcome(decision: decision, advancedFields: advanced, gap: gap, isReplay: isReplay)
    }

    /// A cold launch: rebuild from the payload alone, discarding whatever this process
    /// happened to hold, because a system-launched extension is memoryless by contract
    /// and pretending otherwise is how phantom state survives across sessions.
    @discardableResult
    public func wake(with envelope: StateEnvelope, now: Date) -> WakeOutcome {
        let reconciler = ColdStartReconciler(merger: merger)
        let outcome = reconciler.wake(with: envelope, watermark: watermark)
        state = outcome.state
        watermark = outcome.watermark
        lastEnvelopeAt = now
        lastGap = outcome.gap
        overlay = OptimisticOverlay(capacity: overlay.capacity, commandTimeout: overlay.commandTimeout)
        return outcome
    }

    // MARK: - Outbound

    /// Decides what to do with a user intent, and paints it optimistically if sent.
    ///
    /// The three outcomes in order of preference: dispatch as asked, dispatch a weaker
    /// equivalent the device has actually honoured, or refuse. What it never does is
    /// dispatch into a capability the device has proven it ignores while letting the
    /// UI render success.
    public func issue(_ command: RemoteCommand, now: Date) -> CommandDisposition {
        let device = state.device.value
        guard device != .none else { return .rejectedNoDevice }

        let advertised = state.capabilities.value
        let effective = ledger.effectiveCapabilities(advertised: advertised, device: device)
        let required = command.requiredCapability

        if effective.contains(required) {
            return dispatch(command, device: device, capability: required, now: now)
        }

        // Absolute volume is the one intent with a genuine weaker equivalent: express
        // "go to x" as "move by x - current". Approximate, but honest and actionable.
        if required == .absoluteVolume,
           case .setVolume(let target) = command.intent,
           effective.contains(.relativeVolume) {
            let current = Saturating.clamp(displayedState().volume.value, 0, 1)
            let delta = Saturating.clamp(target, 0, 1) - current
            let fallback = RemoteCommand(id: command.id, intent: .adjustVolume(delta: delta))
            let disposition = dispatch(fallback, device: device, capability: .relativeVolume, now: now)
            guard case .dispatched(let sent, let optimistic) = disposition else { return disposition }
            return .degraded(to: sent, from: .absoluteVolume, optimistic: optimistic)
        }

        return .rejectedUnsupported(required)
    }

    /// Expires in-flight commands and withdraws trust from whatever they were waiting on.
    @discardableResult
    public func tick(now: Date) -> [PendingCommand] {
        let expired = overlay.expire(now: now)
        for command in expired {
            ledger.recordUnhonoured(device: command.device, capability: command.capability)
        }
        return expired
    }

    // MARK: - Read

    public func snapshot(now: Date) -> SessionSnapshot {
        let displayed = overlay.overlaid(on: state)
        let advertised = state.capabilities.value
        return SessionSnapshot(
            converged: state,
            displayed: displayed,
            projection: PlaybackProjector.project(
                state: displayed,
                anchoredAt: lastEnvelopeAt,
                now: now,
                policy: policy
            ),
            advertisedCapabilities: advertised,
            effectiveCapabilities: ledger.effectiveCapabilities(
                advertised: advertised,
                device: state.device.value
            ),
            pendingCommands: overlay.pending,
            lastGap: lastGap,
            lastEnvelopeAt: lastEnvelopeAt
        )
    }

    public func currentWatermark() -> Watermark { watermark }

    public func trustRecord(device: MediaDeviceID, capability: CapabilitySet) -> CapabilityTrustLedger.Record {
        ledger.record(device: device, capability: capability)
    }

    // MARK: - Private

    private func displayedState() -> RemoteSessionState {
        overlay.overlaid(on: state)
    }

    private func dispatch(
        _ command: RemoteCommand,
        device: MediaDeviceID,
        capability: CapabilitySet,
        now: Date
    ) -> CommandDisposition {
        let optimistic = command.optimisticUpdate(given: displayedState())
        if let optimistic {
            let pending = PendingCommand(
                id: command.id,
                field: command.touchedField,
                capability: capability,
                device: device,
                optimistic: optimistic,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(overlay.commandTimeout)
            )
            // Anything displaced to stay within capacity is accounted for immediately,
            // rather than silently vanishing.
            for evicted in overlay.track(pending) where evicted.id != command.id {
                ledger.recordUnhonoured(device: evicted.device, capability: evicted.capability)
            }
        }
        return .dispatched(command, optimistic: optimistic)
    }

    private func capability(forConfirmed id: CommandID, envelope: StateEnvelope) -> CapabilitySet? {
        // The overlay has already retired the entry by this point, so the capability is
        // recovered from what the envelope actually changed.
        if envelope.touchedFields.contains(.volume) { return .absoluteVolume }
        if envelope.touchedFields.contains(.playbackRate) { return .transport }
        if envelope.touchedFields.contains(.elapsed) { return .seek }
        return nil
    }

    private func classifySequence(of stamp: Stamp) -> (SequenceGap?, Bool) {
        guard let previous = watermark.sequence(for: stamp.origin) else { return (nil, false) }
        if stamp.sequence <= previous { return (nil, true) }
        if stamp.sequence > previous &+ 1 {
            return (SequenceGap(origin: stamp.origin, lastSeen: previous, received: stamp.sequence), false)
        }
        return (nil, false)
    }
}
