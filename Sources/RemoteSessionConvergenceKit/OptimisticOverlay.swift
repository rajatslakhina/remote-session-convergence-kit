import Foundation

/// What an arriving envelope means relative to our own in-flight commands.
public enum EchoDecision: Sendable, Equatable {
    /// Genuine news from the remote endpoint.
    case remoteUpdate
    /// The acknowledgement of a command we issued. The overlay for it retires and the
    /// envelope's values become authoritative — but it is *not* re-notified as a
    /// remote change, which is what stops a volume drag from fighting itself.
    case confirmation(CommandID)
    /// Carries a command id we no longer track: it expired, or was evicted, or this is
    /// a duplicate delivery of an already-confirmed command. Applied as state, but the
    /// command is not credited as honoured.
    case unmatchedEcho(CommandID)
}

/// A local intent that has been sent but not yet acknowledged.
public struct PendingCommand: Sendable, Equatable, Identifiable {
    public let id: CommandID
    public let field: SessionField
    public let capability: CapabilitySet
    /// The endpoint this was aimed at — carried so that when the command expires
    /// unacknowledged, the trust ledger knows *whose* capability to withdraw.
    public let device: MediaDeviceID
    public let optimistic: FieldUpdate
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: CommandID,
        field: SessionField,
        capability: CapabilitySet,
        device: MediaDeviceID,
        optimistic: FieldUpdate,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.field = field
        self.capability = capability
        self.device = device
        self.optimistic = optimistic
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

/// The optimistic layer sitting on top of converged state.
///
/// Two jobs, deliberately fused because they are the same bookkeeping:
///  1. show the user's intent immediately, before the round trip completes;
///  2. recognise that intent when it comes back around and refuse to replay it.
///
/// **Bounded by construction.** `capacity` is enforced with FIFO eviction, so a user
/// mashing a volume slider — or a hostile command channel — cannot grow this table
/// without limit inside a memory-constrained extension.
public struct OptimisticOverlay: Sendable {
    public let capacity: Int
    public let commandTimeout: TimeInterval

    private var entries: [CommandID: PendingCommand] = [:]
    /// Insertion order, oldest first. Kept alongside the dictionary so eviction is
    /// deterministic rather than dependent on hash order.
    private var order: [CommandID] = []

    public init(capacity: Int = 32, commandTimeout: TimeInterval = 6) {
        // A zero or negative capacity would make `track` a silent no-op and a negative
        // timeout would expire commands before they were issued; clamp both.
        self.capacity = max(1, capacity)
        self.commandTimeout = max(0.1, commandTimeout)
    }

    public var pending: [PendingCommand] {
        order.compactMap { entries[$0] }
    }

    public var count: Int { entries.count }

    public func contains(_ id: CommandID) -> Bool { entries[id] != nil }

    /// Records an intent. Returns the entries displaced to stay within `capacity`,
    /// so the caller can account for them as unhonoured rather than losing them.
    @discardableResult
    public mutating func track(_ command: PendingCommand) -> [PendingCommand] {
        var evicted: [PendingCommand] = []
        if let existing = entries[command.id] {
            // Re-issuing the same id replaces in place; do not double-append to `order`.
            evicted.append(existing)
            entries[command.id] = command
            return evicted
        }
        entries[command.id] = command
        order.append(command.id)
        while order.count > capacity {
            // `order` is non-empty here because count > capacity >= 1.
            let oldest = order.removeFirst()
            if let dropped = entries.removeValue(forKey: oldest) {
                evicted.append(dropped)
            }
        }
        return evicted
    }

    /// Classifies an envelope. Mutating because a confirmation retires its entry.
    public mutating func classify(_ envelope: StateEnvelope) -> EchoDecision {
        guard let commandID = envelope.causedBy else { return .remoteUpdate }
        guard entries[commandID] != nil else { return .unmatchedEcho(commandID) }
        remove(commandID)
        return .confirmation(commandID)
    }

    /// Drops everything past its deadline and hands the caller the casualties so the
    /// trust ledger can mark those capabilities unhonoured.
    public mutating func expire(now: Date) -> [PendingCommand] {
        guard !order.isEmpty else { return [] }
        var expired: [PendingCommand] = []
        var survivors: [CommandID] = []
        survivors.reserveCapacity(order.count)
        for id in order {
            guard let entry = entries[id] else { continue }
            if entry.expiresAt <= now {
                entries.removeValue(forKey: id)
                expired.append(entry)
            } else {
                survivors.append(id)
            }
        }
        order = survivors
        return expired
    }

    private mutating func remove(_ id: CommandID) {
        entries.removeValue(forKey: id)
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
    }

    /// Paints in-flight intents over converged state for display.
    ///
    /// Applied newest-last so the most recent intent on a field wins, matching what the
    /// user just did with their thumb.
    public func overlaid(on state: RemoteSessionState) -> RemoteSessionState {
        var displayed = state
        for command in pending {
            switch command.optimistic {
            case .title(let v): displayed.title = Stamped(v, stamp: displayed.title.stamp)
            case .artist(let v): displayed.artist = Stamped(v, stamp: displayed.artist.stamp)
            case .playbackRate(let v):
                displayed.playbackRate = Stamped(Saturating.clamp(v, 0, 16), stamp: displayed.playbackRate.stamp)
            case .elapsed(let v):
                displayed.elapsed = Stamped(max(0, Saturating.finite(v)), stamp: displayed.elapsed.stamp)
            case .duration(let v):
                displayed.duration = Stamped(max(0, Saturating.finite(v)), stamp: displayed.duration.stamp)
            case .volume(let v):
                displayed.volume = Stamped(Saturating.clamp(v, 0, 1), stamp: displayed.volume.stamp)
            case .device(let v): displayed.device = Stamped(v, stamp: displayed.device.stamp)
            case .capabilities(let v): displayed.capabilities = Stamped(v, stamp: displayed.capabilities.stamp)
            }
        }
        return displayed
    }
}
