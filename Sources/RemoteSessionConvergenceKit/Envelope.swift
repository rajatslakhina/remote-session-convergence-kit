import Foundation

/// A locally-generated identifier for a command the user issued.
///
/// It travels out on the command channel and comes back embedded in a later envelope
/// on the push channel. That round trip is the only thing linking the two directions,
/// and it is what makes echo suppression possible at all.
public struct CommandID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// One field's worth of new value. Envelopes are deliberately **sparse**: a push
/// payload has a hard size limit, so "here is the whole session" is not an option
/// on a busy stream.
public enum FieldUpdate: Sendable, Equatable {
    case title(String)
    case artist(String)
    case playbackRate(Double)
    case elapsed(Double)
    case duration(Double)
    case volume(Double)
    case device(MediaDeviceID)
    case capabilities(CapabilitySet)

    public var field: SessionField {
        switch self {
        case .title: return .title
        case .artist: return .artist
        case .playbackRate: return .playbackRate
        case .elapsed: return .elapsed
        case .duration: return .duration
        case .volume: return .volume
        case .device: return .device
        case .capabilities: return .capabilities
        }
    }
}

/// A single push payload.
///
/// Nothing here may be trusted for ordering except `stamp`. In particular `emittedAt`
/// is a producer-clock timestamp and is used only for display and staleness, never for
/// merge decisions — clock skew between a speaker, a server and a phone is real, and
/// ordering on wall-clock time is how sync engines acquire their haunted bugs.
public struct StateEnvelope: Sendable, Equatable, Identifiable {
    public let stamp: Stamp
    public let emittedAt: Date
    /// Set when this envelope is the remote acknowledgement of a local command.
    public let causedBy: CommandID?
    public let updates: [FieldUpdate]

    public init(stamp: Stamp, emittedAt: Date, causedBy: CommandID? = nil, updates: [FieldUpdate]) {
        self.stamp = stamp
        self.emittedAt = emittedAt
        self.causedBy = causedBy
        self.updates = updates
    }

    public var id: String { "\(stamp.origin.rawValue):\(stamp.sequence)" }

    public var touchedFields: Set<SessionField> {
        Set(updates.map(\.field))
    }
}

// MARK: - Merging

/// The seam that lets the merge strategy be swapped out.
///
/// This protocol exists for one reason beyond tidiness: it lets the test suite hand
/// `ConvergenceProperties` a **deliberately broken** merger and assert that the
/// property checker rejects it. A checker nobody has ever seen fail is not evidence.
public protocol EnvelopeMerging: Sendable {
    func apply(_ envelope: StateEnvelope, to state: RemoteSessionState) -> RemoteSessionState
}

/// The real merger: every update becomes a stamped register write, joined field-wise.
public struct StampedFieldMerger: EnvelopeMerging {
    public init() {}

    public func apply(_ envelope: StateEnvelope, to state: RemoteSessionState) -> RemoteSessionState {
        var next = state
        let stamp = envelope.stamp
        for update in envelope.updates {
            switch update {
            case .title(let v):
                next.title = next.title.merged(with: Stamped(v, stamp: stamp))
            case .artist(let v):
                next.artist = next.artist.merged(with: Stamped(v, stamp: stamp))
            case .playbackRate(let v):
                // Sanitised on the way in: a non-finite rate from the wire would
                // otherwise reach the extrapolator and poison every later frame.
                next.playbackRate = next.playbackRate.merged(
                    with: Stamped(Saturating.clamp(v, 0, 16), stamp: stamp))
            case .elapsed(let v):
                next.elapsed = next.elapsed.merged(
                    with: Stamped(max(0, Saturating.finite(v)), stamp: stamp))
            case .duration(let v):
                next.duration = next.duration.merged(
                    with: Stamped(max(0, Saturating.finite(v)), stamp: stamp))
            case .volume(let v):
                next.volume = next.volume.merged(
                    with: Stamped(Saturating.clamp(v, 0, 1), stamp: stamp))
            case .device(let v):
                next.device = next.device.merged(with: Stamped(v, stamp: stamp))
            case .capabilities(let v):
                next.capabilities = next.capabilities.merged(with: Stamped(v, stamp: stamp))
            }
        }
        return next
    }

}

extension EnvelopeMerging {
    /// Which fields an envelope would actually move forward, without committing it.
    ///
    /// Defined once, on the protocol, rather than inside each merger — "did this
    /// envelope carry news?" should have exactly one answer in the codebase, and it
    /// must be computed the same way for a correct merger and a broken one.
    public func advancedFields(applying envelope: StateEnvelope, to state: RemoteSessionState) -> Set<SessionField> {
        let after = apply(envelope, to: state)
        return RemoteSessionState.divergentFields(state, after).intersection(envelope.touchedFields)
    }
}
