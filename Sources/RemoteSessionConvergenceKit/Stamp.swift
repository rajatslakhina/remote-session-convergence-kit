import Foundation

// MARK: - Origin

/// Which upstream producer the *server* relayed a given envelope for.
///
/// Note what this is **not**: it is not an independent sequencing authority. Every
/// envelope that reaches the device is sequenced by the server (see `Stamp`), so
/// `OriginID` never has to be compared against a foreign sequence space. Its ordering
/// exists purely as a deterministic tiebreak for the pathological case where a server
/// batches two producers into the same sequence number.
public struct OriginID: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let rawValue: String
    /// Higher wins a same-sequence tie. Ordering only; carries no semantic authority.
    public let priority: UInt8

    public init(_ rawValue: String, priority: UInt8 = 0) {
        self.rawValue = rawValue
        self.priority = priority
    }

    public static func < (lhs: OriginID, rhs: OriginID) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String { "\(rawValue)#\(priority)" }
}

extension OriginID {
    /// The remote endpoint itself (speaker, TV, receiver).
    public static let speaker = OriginID("speaker", priority: 10)
    /// The session server's own derived state (e.g. queue advance).
    public static let server = OriginID("server", priority: 20)
}

// MARK: - Stamp

/// A server-assigned position in the single global ordering of a session.
///
/// The whole convergence story rests on this being *server-assigned*. The device has
/// no shared memory with the speaker and no local log, so nothing on-device can order
/// two updates on its own. Making the server the sole sequencer is what turns
/// "unordered coalescing push" into a set of points on one line that can be merged in
/// any order and still land in the same place.
public struct Stamp: Hashable, Sendable, Comparable, Codable {
    public let sequence: UInt64
    public let origin: OriginID

    public init(sequence: UInt64, origin: OriginID) {
        self.sequence = sequence
        self.origin = origin
    }

    /// A **total** order — not merely a partial one. Totality is the requirement:
    /// `max` over a totally ordered set is associative, commutative and idempotent,
    /// which is exactly what makes per-field merge a join-semilattice and therefore
    /// order-insensitive.
    public static func < (lhs: Stamp, rhs: Stamp) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.origin < rhs.origin
    }

    public static let zero = Stamp(sequence: 0, origin: OriginID("", priority: 0))
}

// MARK: - Convergence-comparable values

/// A value that can be totally ordered *by content* as a last-resort tiebreak.
///
/// Same-stamp/different-value should never happen: a correct producer does not emit
/// two different values at one sequence. But "should never happen" is not a guarantee
/// when the producer is third-party hardware, and if it does happen, plain
/// max-by-stamp becomes ambiguous and the merge silently stops being commutative —
/// the exact failure this package claims to prevent. So the merge falls through to
/// `convergenceKey`, which restores totality unconditionally.
public protocol ConvergenceComparable: Sendable, Equatable {
    var convergenceKey: String { get }
}

extension String: ConvergenceComparable {
    public var convergenceKey: String { self }
}

extension Bool: ConvergenceComparable {
    public var convergenceKey: String { self ? "1" : "0" }
}

extension Double: ConvergenceComparable {
    /// Keyed on the bit pattern rather than the numeric value, so the key is total and
    /// stable even for `NaN` (which is not equal to itself under `==`).
    public var convergenceKey: String { String(bitPattern) }
}

// MARK: - Stamped register

/// A last-writer-wins register: a value plus the stamp that wrote it.
///
/// `merged(with:)` is commutative, associative and idempotent, which is what lets the
/// engine apply a dropped-then-resent, reordered, coalesced push stream in whatever
/// order it happens to arrive.
public struct Stamped<Value: ConvergenceComparable>: Sendable, Equatable {
    public var value: Value
    public var stamp: Stamp

    public init(_ value: Value, stamp: Stamp) {
        self.value = value
        self.stamp = stamp
    }

    public func merged(with other: Stamped<Value>) -> Stamped<Value> {
        if other.stamp > stamp { return other }
        if other.stamp < stamp { return self }
        // Equal stamps. Identical values → idempotent, keep self.
        if other.value == value { return self }
        // Equal stamps, differing values: a misbehaving producer. Break the tie on
        // content so both replicas still reach the same answer.
        return other.value.convergenceKey > value.convergenceKey ? other : self
    }

    /// True when `other` would actually move this register forward.
    public func isAdvanced(by other: Stamped<Value>) -> Bool {
        merged(with: other) != self
    }
}
