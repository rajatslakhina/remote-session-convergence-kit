import Foundation

/// How much the displayed state should be trusted right now.
///
/// A best-effort transport means "no update" and "nothing changed" are the same
/// observation, so the only honest design is to make age a first-class part of what
/// gets rendered rather than letting the last known frame sit there indefinitely
/// pretending to be current.
public enum Freshness: String, Sendable, Equatable, CaseIterable, Comparable {
    case fresh
    case aging
    case stale
    case presumedLost

    private var rank: Int {
        switch self {
        case .fresh: return 0
        case .aging: return 1
        case .stale: return 2
        case .presumedLost: return 3
        }
    }

    public static func < (lhs: Freshness, rhs: Freshness) -> Bool { lhs.rank < rhs.rank }
}

/// The contract for what the system UI shows as an update ages.
public struct StalenessPolicy: Sendable, Equatable {
    public let agingAfter: TimeInterval
    public let staleAfter: TimeInterval
    public let presumedLostAfter: TimeInterval

    /// Thresholds are forced into ascending order rather than trusted, because an
    /// out-of-order configuration would silently make one band unreachable.
    public init(agingAfter: TimeInterval = 5, staleAfter: TimeInterval = 20, presumedLostAfter: TimeInterval = 90) {
        let a = max(0, Saturating.finite(agingAfter, fallback: 5))
        let s = max(a, Saturating.finite(staleAfter, fallback: 20))
        let l = max(s, Saturating.finite(presumedLostAfter, fallback: 90))
        self.agingAfter = a
        self.staleAfter = s
        self.presumedLostAfter = l
    }

    public static let `default` = StalenessPolicy()

    public func freshness(lastEnvelopeAt: Date?, now: Date) -> Freshness {
        guard let lastEnvelopeAt else { return .presumedLost }
        // A producer clock ahead of ours yields a negative age; treat it as fresh
        // rather than letting skew masquerade as staleness.
        let age = max(0, now.timeIntervalSince(lastEnvelopeAt))
        if age < agingAfter { return .fresh }
        if age < staleAfter { return .aging }
        if age < presumedLostAfter { return .stale }
        return .presumedLost
    }

    /// Whether local extrapolation of the playhead is permitted at this freshness.
    ///
    /// Extrapolating a `stale` session is how a progress bar ends up confidently
    /// sliding past the end of a track that stopped playing two minutes ago.
    public func allowsExtrapolation(_ freshness: Freshness) -> Bool {
        freshness <= .aging
    }
}

/// What the UI should actually draw for the playhead.
public struct PlaybackProjection: Sendable, Equatable {
    public let elapsed: Double
    public let duration: Double
    public let isExtrapolated: Bool
    public let freshness: Freshness
    /// `0...100`, computed with saturating arithmetic. `0` when duration is unknown.
    public let percentComplete: Int

    public var isLive: Bool { duration <= 0 }
}

public enum PlaybackProjector {

    /// Projects the playhead forward from the last anchored position.
    ///
    /// Every input here arrives from an untrusted transport, so each one is sanitised:
    /// a `NaN` elapsed, an infinite duration, a negative rate or a clock that ran
    /// backwards all produce a degraded-but-drawable result instead of a trap.
    public static func project(
        state: RemoteSessionState,
        anchoredAt: Date?,
        now: Date,
        policy: StalenessPolicy
    ) -> PlaybackProjection {
        let freshness = policy.freshness(lastEnvelopeAt: anchoredAt, now: now)
        let duration = max(0, Saturating.finite(state.duration.value))
        let anchoredElapsed = max(0, Saturating.finite(state.elapsed.value))
        let rate = Saturating.clamp(state.playbackRate.value, 0, 16)

        var elapsed = anchoredElapsed
        var extrapolated = false

        if let anchoredAt, rate > 0, policy.allowsExtrapolation(freshness) {
            let drift = now.timeIntervalSince(anchoredAt)
            // A negative drift means our clock moved backwards relative to the anchor
            // (NTP correction, or a producer timestamp from the future). Advancing by a
            // negative amount would visibly rewind the playhead, so it is floored.
            let advance = max(0, Saturating.finite(drift)) * rate
            if advance > 0 {
                elapsed = anchoredElapsed + advance
                extrapolated = true
            }
        }

        if duration > 0 {
            elapsed = Saturating.clamp(elapsed, 0, duration)
        } else {
            elapsed = max(0, Saturating.finite(elapsed))
        }

        return PlaybackProjection(
            elapsed: elapsed,
            duration: duration,
            isExtrapolated: extrapolated,
            freshness: freshness,
            percentComplete: Saturating.percentage(elapsed, of: duration)
        )
    }
}
