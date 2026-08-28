import Foundation

/// A user intent travelling *out* on the command channel.
///
/// Commands and state updates move on different wires in opposite directions, which is
/// the structural reason the read path and the write path can disagree.
public struct RemoteCommand: Sendable, Equatable, Identifiable {
    public enum Intent: Sendable, Equatable {
        case play
        case pause
        case setVolume(Double)
        case adjustVolume(delta: Double)
        case seek(to: Double)
    }

    public let id: CommandID
    public let intent: Intent

    public init(id: CommandID, intent: Intent) {
        self.id = id
        self.intent = intent
    }

    /// The single capability this intent requires the endpoint to support.
    public var requiredCapability: CapabilitySet {
        switch intent {
        case .play, .pause: return .transport
        case .setVolume: return .absoluteVolume
        case .adjustVolume: return .relativeVolume
        case .seek: return .seek
        }
    }

    public var touchedField: SessionField {
        switch intent {
        case .play, .pause: return .playbackRate
        case .setVolume, .adjustVolume: return .volume
        case .seek: return .elapsed
        }
    }

    /// The value to show immediately, computed against what is on screen right now.
    ///
    /// Returns `nil` when there is nothing sensible to show optimistically, in which
    /// case the UI simply keeps the last converged value — a correct stale reading is
    /// better than an invented one.
    public func optimisticUpdate(given displayed: RemoteSessionState) -> FieldUpdate? {
        switch intent {
        case .play:
            return .playbackRate(1)
        case .pause:
            return .playbackRate(0)
        case .setVolume(let target):
            return .volume(Saturating.clamp(target, 0, 1))
        case .adjustVolume(let delta):
            let base = Saturating.clamp(displayed.volume.value, 0, 1)
            let step = Saturating.finite(delta)
            return .volume(Saturating.clamp(base + step, 0, 1))
        case .seek(let target):
            let duration = max(0, Saturating.finite(displayed.duration.value))
            let clean = max(0, Saturating.finite(target))
            return .elapsed(duration > 0 ? Saturating.clamp(clean, 0, duration) : clean)
        }
    }
}

/// What the engine decided to do with a command.
public enum CommandDisposition: Sendable, Equatable {
    /// Sent, with an optimistic value painted on screen while it is in flight.
    case dispatched(RemoteCommand, optimistic: FieldUpdate?)
    /// The endpoint demonstrably does not honour the capability this needed, but a
    /// weaker one it *does* honour can express the same intent approximately.
    case degraded(to: RemoteCommand, from: CapabilitySet, optimistic: FieldUpdate?)
    /// The endpoint never advertised the capability, or advertised it and then proved
    /// it does not honour it, with no weaker fallback available. Refused at the policy
    /// layer rather than sent into a void and rendered as if it worked.
    case rejectedUnsupported(CapabilitySet)
    /// No device is attached to the session yet.
    case rejectedNoDevice
}
