import Foundation

/// A merger that is **wrong on purpose**, shipped as part of the library.
///
/// It does the obvious thing: take whatever arrived last and write it in, ignoring
/// stamps entirely. This is not a straw man — it is what almost every first draft of a
/// push handler does, because on a transport that delivers in order it is correct, and
/// it stays correct right up until the first reordering.
///
/// It exists here, in the shipping target rather than in the tests, for two reasons:
///
/// * `ConvergencePropertiesTests` runs the property checker against it and asserts the
///   checker **fails**. A checker that has only ever been seen to pass is not evidence
///   of anything; this is what proves it has teeth.
/// * The demo app exposes it as a toggle, so the failure is something a reader can
///   watch happen rather than a paragraph asking them to take it on faith.
public struct NaiveOverwriteMerger: EnvelopeMerging {
    public init() {}

    public func apply(_ envelope: StateEnvelope, to state: RemoteSessionState) -> RemoteSessionState {
        var next = state
        let stamp = envelope.stamp
        for update in envelope.updates {
            switch update {
            case .title(let v): next.title = Stamped(v, stamp: stamp)
            case .artist(let v): next.artist = Stamped(v, stamp: stamp)
            case .playbackRate(let v): next.playbackRate = Stamped(Saturating.clamp(v, 0, 16), stamp: stamp)
            case .elapsed(let v): next.elapsed = Stamped(max(0, Saturating.finite(v)), stamp: stamp)
            case .duration(let v): next.duration = Stamped(max(0, Saturating.finite(v)), stamp: stamp)
            case .volume(let v): next.volume = Stamped(Saturating.clamp(v, 0, 1), stamp: stamp)
            case .device(let v): next.device = Stamped(v, stamp: stamp)
            case .capabilities(let v): next.capabilities = Stamped(v, stamp: stamp)
            }
        }
        return next
    }
}

/// Which merge strategy the demo console is currently running.
public enum MergeStrategy: String, Sendable, CaseIterable, Identifiable {
    case stamped = "Stamped LWW"
    case naive = "Naive overwrite"

    public var id: String { rawValue }

    public func makeMerger() -> any EnvelopeMerging {
        switch self {
        case .stamped: return StampedFieldMerger()
        case .naive: return NaiveOverwriteMerger()
        }
    }

    public var explanation: String {
        switch self {
        case .stamped:
            return "Every field is a last-writer-wins register keyed on a server sequence. "
                + "Order of arrival cannot change the result."
        case .naive:
            return "Last payload to arrive overwrites the field. Correct on an ordered "
                + "transport; wrong on this one."
        }
    }
}
