import Foundation

/// A deterministic model of what a best-effort push transport does to a stream.
///
/// Three behaviours, applied in the order a real system applies them:
///
/// 1. **Coalescing** — a burst of pushes sharing a collapse identifier is reduced to
///    the most recent one. This is the behaviour people forget: it is not loss under
///    congestion, it is designed, deliberate discarding of intermediate states.
/// 2. **Drop** — best-effort delivery means some payloads simply never arrive, with no
///    error surfaced anywhere.
/// 3. **Reorder** — delivery order is not send order, so a later update can land first.
///
/// Given a seed this is fully reproducible, which is the point: a convergence failure
/// found here is a seed a developer can replay.
public struct LossyTransport: Sendable {

    public struct Profile: Sendable, Equatable {
        /// Probability in `0...1` that any surviving envelope is dropped.
        public let dropRate: Double
        /// Width of the sliding window envelopes may be shuffled within. `1` = in order.
        public let reorderWindow: Int
        /// Length of a coalescing run. `1` = no coalescing; `3` keeps 1 of every 3.
        public let coalesceRun: Int

        public init(dropRate: Double = 0.2, reorderWindow: Int = 4, coalesceRun: Int = 3) {
            self.dropRate = Saturating.clamp(dropRate, 0, 1)
            self.reorderWindow = max(1, reorderWindow)
            self.coalesceRun = max(1, coalesceRun)
        }

        /// Everything arrives, in order. Useful as a control in tests and as the
        /// "perfect network" toggle in the demo.
        public static let perfect = Profile(dropRate: 0, reorderWindow: 1, coalesceRun: 1)
        /// Roughly what a phone on a congested network behind a sleeping radio sees.
        public static let hostile = Profile(dropRate: 0.35, reorderWindow: 5, coalesceRun: 3)
    }

    public let profile: Profile

    public init(profile: Profile = Profile()) {
        self.profile = profile
    }

    public func deliver(_ envelopes: [StateEnvelope], seed: UInt64) -> [StateEnvelope] {
        guard !envelopes.isEmpty else { return [] }
        var rng = DeterministicRandom(seed: seed)
        let coalesced = coalesce(envelopes)
        let survived = drop(coalesced, rng: &rng)
        return reorder(survived, rng: &rng)
    }

    /// Keeps the last envelope of each run — the collapse semantics, not a random pick.
    ///
    /// Runs are bounded by the **set of fields an envelope touches**, standing in for a
    /// push collapse identifier. That detail matters: real collapsing is per-topic, so a
    /// stream of progress ticks collapses among themselves while a session-identity
    /// announcement sitting in the middle of them does not get swallowed by the burst
    /// around it. Modelling collapse as "every third payload regardless of topic" would
    /// be both wrong and conveniently more dramatic.
    private func coalesce(_ envelopes: [StateEnvelope]) -> [StateEnvelope] {
        guard profile.coalesceRun > 1 else { return envelopes }
        var result: [StateEnvelope] = []
        result.reserveCapacity(envelopes.count)
        var index = 0
        while index < envelopes.count {
            let topic = envelopes[index].touchedFields
            var end = index + 1
            while end < envelopes.count,
                  end - index < profile.coalesceRun,
                  envelopes[end].touchedFields == topic {
                end += 1
            }
            // `end - 1` is in `index..<count` because `end > index` and `end <= count`.
            result.append(envelopes[end - 1])
            index = end
        }
        return result
    }

    private func drop(_ envelopes: [StateEnvelope], rng: inout DeterministicRandom) -> [StateEnvelope] {
        guard profile.dropRate > 0 else { return envelopes }
        return envelopes.filter { _ in rng.unitInterval() >= profile.dropRate }
    }

    private func reorder(_ envelopes: [StateEnvelope], rng: inout DeterministicRandom) -> [StateEnvelope] {
        guard profile.reorderWindow > 1, envelopes.count > 1 else { return envelopes }
        var result: [StateEnvelope] = []
        result.reserveCapacity(envelopes.count)
        var index = 0
        while index < envelopes.count {
            let end = min(index + profile.reorderWindow, envelopes.count)
            result.append(contentsOf: rng.shuffled(Array(envelopes[index..<end])))
            index = end
        }
        return result
    }
}

// MARK: - Scenario

/// Generates a plausible remote session as a server would sequence it.
///
/// Shared by the tests and the demo app so both are exercising the same traffic shape
/// rather than two different idealisations of it.
public struct SessionScript: Sendable {
    public let device: MediaDeviceID
    public let capabilities: CapabilitySet
    public let title: String
    public let artist: String
    public let duration: Double
    public let start: Date

    public init(
        device: MediaDeviceID = MediaDeviceID("living-room-speaker"),
        capabilities: CapabilitySet = [.transport, .seek, .absoluteVolume, .relativeVolume, .skip],
        title: String = "Ashes of Orion",
        artist: String = "Kepler Field",
        duration: Double = 214,
        start: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) {
        self.device = device
        self.capabilities = capabilities
        self.title = title
        self.artist = artist
        self.duration = max(0, Saturating.finite(duration))
        self.start = start
    }

    /// How often the server re-announces session identity, in ticks.
    ///
    /// Not decoration. The extension is memoryless and the transport is lossy, so if
    /// identity were announced exactly once, a single dropped payload would leave the
    /// Lock Screen permanently blank with no mechanism anywhere in the system to
    /// recover it. Periodic re-announcement is the cheapest repair: it costs a few
    /// bytes on a cadence and it makes "blank forever" unreachable.
    public static let reannounceEvery = 4

    private var announcement: [FieldUpdate] {
        [
            .device(device),
            .capabilities(capabilities),
            .title(title),
            .artist(artist),
            .duration(duration)
        ]
    }

    /// `ticks` progress updates after the initial session announcement.
    public func envelopes(ticks: Int, origin: OriginID = .speaker) -> [StateEnvelope] {
        let count = max(0, ticks)
        var out: [StateEnvelope] = []
        out.reserveCapacity(count * 2 + 1)

        out.append(StateEnvelope(
            stamp: Stamp(sequence: 1, origin: origin),
            emittedAt: start,
            updates: announcement + [.elapsed(0), .volume(0.4), .playbackRate(1)]
        ))

        var sequence: UInt64 = 1
        var step = 1
        while step <= count {
            let seconds = Double(step) * 5
            sequence &+= 1
            out.append(StateEnvelope(
                stamp: Stamp(sequence: sequence, origin: origin),
                emittedAt: start.addingTimeInterval(seconds),
                updates: [.elapsed(duration > 0 ? min(seconds, duration) : seconds)]
            ))
            if step % Self.reannounceEvery == 0 {
                sequence &+= 1
                out.append(StateEnvelope(
                    stamp: Stamp(sequence: sequence, origin: origin),
                    emittedAt: start.addingTimeInterval(seconds),
                    updates: announcement
                ))
            }
            step += 1
        }
        return out
    }
}
