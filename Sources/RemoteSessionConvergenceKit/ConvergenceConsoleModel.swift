import Foundation
import Observation

/// Everything the console needs, supplied by the host app.
///
/// The library does not compile in a scenario of its own: what a demo should show is an
/// application decision, so the app owns this and hands it in. That keeps the package
/// free of sample data an integrator would have to strip out.
public struct ConvergenceConsoleConfiguration: Sendable {
    public let script: SessionScript
    public let transport: LossyTransport.Profile
    public let ticksPerBurst: Int
    public let permutations: Int
    public let seed: UInt64
    public let policy: StalenessPolicy

    public init(
        script: SessionScript = SessionScript(),
        transport: LossyTransport.Profile = .hostile,
        ticksPerBurst: Int = 12,
        permutations: Int = 96,
        seed: UInt64 = 0xA11C_E5C0_DEC0_FFEE,
        policy: StalenessPolicy = .default
    ) {
        self.script = script
        self.transport = transport
        self.ticksPerBurst = max(1, ticksPerBurst)
        self.permutations = max(1, permutations)
        self.seed = seed
        self.policy = policy
    }
}

/// One delivered envelope and what the engine made of it.
public struct DeliveryRecord: Identifiable, Sendable, Equatable {
    public let id: Int
    public let envelope: StateEnvelope
    public let outcome: IngestOutcome

    public var label: String {
        "seq \(envelope.stamp.sequence) · "
            + envelope.touchedFields.map(\.rawValue).sorted().joined(separator: ",")
    }

    public var verdict: String {
        if outcome.isReplay { return "replay" }
        if let gap = outcome.gap { return "gap +\(gap.missingCount)" }
        if case .confirmation = outcome.decision { return "confirmed" }
        return outcome.didAdvance ? "applied" : "superseded"
    }
}

/// The console's view-model.
///
/// It lives in the shipping target rather than in the demo app, and it deliberately
/// imports `Observation` rather than `SwiftUI`, so that **Linux CI compiles and tests
/// it**. Only the `View` struct itself is Apple-only. That split matters: without it,
/// every claim this demo makes on screen would rest on code no CI job had ever
/// type-checked, let alone run.
@MainActor
@Observable
public final class ConvergenceConsoleModel {
    public private(set) var snapshot: SessionSnapshot?
    public private(set) var report: ConvergenceReport?
    public private(set) var log: [DeliveryRecord] = []
    public private(set) var lastDisposition: CommandDisposition?
    public private(set) var burstCount: Int = 0
    public private(set) var strategy: MergeStrategy = .stamped

    public let configuration: ConvergenceConsoleConfiguration

    private var engine: ConvergenceEngine
    private var clock: Date
    private var nextRecordID = 0
    private var commandCounter = 0

    /// Cap on the on-screen log. Without it a long-running demo grows an unbounded
    /// array — the same mistake the library itself is careful to avoid everywhere else.
    public let logLimit: Int

    public init(configuration: ConvergenceConsoleConfiguration = ConvergenceConsoleConfiguration(), logLimit: Int = 60) {
        self.configuration = configuration
        self.logLimit = max(1, logLimit)
        self.clock = configuration.script.start
        self.engine = ConvergenceEngine(
            merger: MergeStrategy.stamped.makeMerger(),
            policy: configuration.policy
        )
    }

    /// Runs one lossy delivery so the screen is populated before the reader touches
    /// anything. Idempotent — calling it twice does not double-deliver.
    public func bootstrap() async {
        guard snapshot == nil else { return }
        await deliverBurst()
    }

    /// Switching strategy rebuilds the engine, because the merge rule is the thing
    /// under test and re-using state merged under the other rule would muddy it.
    public func setStrategy(_ next: MergeStrategy) async {
        guard next != strategy else { return }
        strategy = next
        await reset()
    }

    public func reset() async {
        engine = ConvergenceEngine(merger: strategy.makeMerger(), policy: configuration.policy)
        clock = configuration.script.start
        log.removeAll()
        nextRecordID = 0
        commandCounter = 0
        burstCount = 0
        snapshot = nil
        report = nil
        lastDisposition = nil
        await deliverBurst()
    }

    /// Generates a burst, mangles it through the lossy transport, and feeds whatever
    /// survives into the engine in exactly the order it arrived.
    public func deliverBurst() async {
        let ordered = configuration.script.envelopes(ticks: configuration.ticksPerBurst)
        let transport = LossyTransport(profile: configuration.transport)
        // The seed varies per burst so successive bursts differ, while the whole
        // session stays reproducible from `configuration.seed`.
        let delivered = transport.deliver(
            ordered,
            seed: configuration.seed &+ UInt64(truncatingIfNeeded: burstCount)
        )
        burstCount += 1

        for envelope in delivered {
            clock = clock.addingTimeInterval(0.25)
            let outcome = await engine.ingest(envelope, now: clock)
            append(DeliveryRecord(id: nextRecordID, envelope: envelope, outcome: outcome))
            nextRecordID += 1
        }

        report = ConvergenceProperties.check(
            merger: strategy.makeMerger(),
            envelopes: delivered,
            permutations: configuration.permutations,
            seed: configuration.seed
        )
        await refresh()
    }

    /// Issues a volume command. Repeatedly doing this without the endpoint ever
    /// acknowledging is what walks the trust ledger down to a degrade.
    public func issueVolume(_ target: Double) async {
        commandCounter += 1
        lastDisposition = await engine.issue(
            RemoteCommand(id: CommandID("cmd-\(commandCounter)"), intent: .setVolume(target)),
            now: clock
        )
        await refresh()
    }

    public func togglePlayback() async {
        commandCounter += 1
        let playing = (snapshot?.displayed.playbackRate.value ?? 0) > 0
        lastDisposition = await engine.issue(
            RemoteCommand(id: CommandID("cmd-\(commandCounter)"), intent: playing ? .pause : .play),
            now: clock
        )
        await refresh()
    }

    /// Advances the clock past the command timeout so in-flight intents expire
    /// unacknowledged — the "the speaker never answered" path.
    public func expirePending() async {
        clock = clock.addingTimeInterval(30)
        await engine.tick(now: clock)
        await refresh()
    }

    private func refresh() async {
        snapshot = await engine.snapshot(now: clock)
    }

    private func append(_ record: DeliveryRecord) {
        log.append(record)
        if log.count > logLimit {
            log.removeFirst(log.count - logLimit)
        }
    }
}
