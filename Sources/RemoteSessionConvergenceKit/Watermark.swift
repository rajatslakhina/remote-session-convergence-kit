import Foundation

/// The highest sequence seen per origin, small enough to persist alongside a push.
///
/// This is the *only* thing that survives between wakes. A cold-launched extension has
/// no in-memory log to reconcile against, so the watermark is not used to replay
/// anything — it exists purely so the extension can tell the difference between
/// "the next update" and "the next update I happened to receive".
public struct Watermark: Sendable, Equatable, Codable {
    public private(set) var perOrigin: [String: UInt64]
    /// Hard cap on tracked origins. The map is persisted into a size-limited container,
    /// so it must not grow with the number of endpoints seen over the app's lifetime.
    public let capacity: Int

    public init(perOrigin: [String: UInt64] = [:], capacity: Int = 8) {
        self.capacity = max(1, capacity)
        self.perOrigin = perOrigin
        self.trim()
    }

    public func sequence(for origin: OriginID) -> UInt64? {
        perOrigin[origin.rawValue]
    }

    public mutating func advance(to stamp: Stamp) {
        let key = stamp.origin.rawValue
        if let existing = perOrigin[key], existing >= stamp.sequence { return }
        perOrigin[key] = stamp.sequence
        trim()
    }

    /// Evicts the lowest-sequence origins when over capacity. Deterministic: ties break
    /// on the origin key so two replicas trim identically.
    private mutating func trim() {
        guard perOrigin.count > capacity else { return }
        let ordered = perOrigin.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        perOrigin = Dictionary(uniqueKeysWithValues: ordered.prefix(capacity).map { ($0.key, $0.value) })
    }
}

/// A hole in the sequence for one origin.
public struct SequenceGap: Sendable, Equatable {
    public let origin: OriginID
    public let lastSeen: UInt64
    public let received: UInt64
    /// How many envelopes went missing. Saturating: a server that resets its counter
    /// can produce an enormous nominal gap, and `UInt64` subtraction underflows.
    public var missingCount: UInt64 {
        received > lastSeen ? received &- lastSeen &- 1 : 0
    }
}

/// What a cold launch produced.
public struct WakeOutcome: Sendable, Equatable {
    /// State rebuilt from the push payload alone.
    public let state: RemoteSessionState
    /// Non-nil when the arriving sequence skipped ahead of the persisted watermark —
    /// meaning APNs dropped or coalesced at least one update we will never see.
    public let gap: SequenceGap?
    /// True when the envelope is at or below the watermark: a redelivery of something
    /// already accounted for.
    public let isReplay: Bool
    public let watermark: Watermark

    /// The honest summary for the UI: a reconstructed session with a known hole in its
    /// history should not be rendered with the same confidence as a clean one.
    public var isFullyReconciled: Bool { gap == nil && !isReplay }
}

/// Rebuilds session state on a cold launch.
///
/// The design decision worth defending: **every wake is a full re-derivation, never a
/// delta application.** It is tempting to persist the last known state and apply the
/// push on top, but the extension is memoryless by design and the transport coalesces,
/// so a persisted snapshot is of unknowable age and merging into it silently
/// resurrects fields the session may have abandoned. Rebuilding from the payload and
/// *reporting the gap* is strictly more honest than reconstructing a plausible lie.
public struct ColdStartReconciler: Sendable {
    private let merger: any EnvelopeMerging

    public init(merger: any EnvelopeMerging = StampedFieldMerger()) {
        self.merger = merger
    }

    public func wake(with envelope: StateEnvelope, watermark: Watermark) -> WakeOutcome {
        let state = merger.apply(envelope, to: .unknown)
        var next = watermark

        let previous = watermark.sequence(for: envelope.stamp.origin)
        var gap: SequenceGap?
        var isReplay = false

        if let previous {
            if envelope.stamp.sequence <= previous {
                isReplay = true
            } else if envelope.stamp.sequence > previous &+ 1 {
                gap = SequenceGap(
                    origin: envelope.stamp.origin,
                    lastSeen: previous,
                    received: envelope.stamp.sequence
                )
            }
        }
        // No previous watermark is a genuine first launch, not a gap — there is nothing
        // to have missed yet.

        next.advance(to: envelope.stamp)
        return WakeOutcome(state: state, gap: gap, isReplay: isReplay, watermark: next)
    }
}
