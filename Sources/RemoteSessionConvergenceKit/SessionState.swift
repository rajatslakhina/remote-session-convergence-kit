import Foundation

// MARK: - Device identity

/// A device id that must stay stable across sessions while the device *set* churns.
///
/// The system UI keys its rendering off this, so deriving it from anything volatile
/// (IP address, discovery index, connection handle) produces a Lock Screen that thinks
/// the speaker changed every time the network hiccups.
public struct MediaDeviceID: Hashable, Sendable, ConvergenceComparable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var convergenceKey: String { rawValue }
    public var description: String { rawValue }
    public static let none = MediaDeviceID("")
}

// MARK: - Capabilities

/// What a remote endpoint claims it can do.
///
/// These are *claims*. `CapabilityTrustLedger` is what turns them into something the
/// command layer is willing to act on.
public struct CapabilitySet: OptionSet, Sendable, Hashable, ConvergenceComparable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let transport = CapabilitySet(rawValue: 1 << 0)
    public static let seek = CapabilitySet(rawValue: 1 << 1)
    /// Endpoint accepts "set volume to exactly x".
    public static let absoluteVolume = CapabilitySet(rawValue: 1 << 2)
    /// Endpoint accepts "nudge volume by ±x" only.
    public static let relativeVolume = CapabilitySet(rawValue: 1 << 3)
    public static let skip = CapabilitySet(rawValue: 1 << 4)

    public static let none: CapabilitySet = []

    public var convergenceKey: String { String(rawValue) }

    public var labels: [String] {
        var out: [String] = []
        if contains(.transport) { out.append("transport") }
        if contains(.seek) { out.append("seek") }
        if contains(.absoluteVolume) { out.append("absoluteVolume") }
        if contains(.relativeVolume) { out.append("relativeVolume") }
        if contains(.skip) { out.append("skip") }
        return out
    }
}

// MARK: - Fields

public enum SessionField: String, CaseIterable, Sendable, Hashable, Codable {
    case title
    case artist
    case playbackRate
    case elapsed
    case duration
    case volume
    case device
    case capabilities
}

// MARK: - Converged state

/// The session state as reconstructed from server-sequenced envelopes **only**.
///
/// Local optimistic values deliberately never land here — they live in
/// `OptimisticOverlay` until an echo confirms them. Keeping the two apart is what
/// stops a user's own volume drag from being replayed back as a remote update.
public struct RemoteSessionState: Sendable, Equatable {
    public var title: Stamped<String>
    public var artist: Stamped<String>
    /// 0 = paused, 1 = normal speed.
    public var playbackRate: Stamped<Double>
    /// Seconds into the item at the moment the envelope was stamped.
    public var elapsed: Stamped<Double>
    /// Total seconds; `<= 0` means "live / unknown length".
    public var duration: Stamped<Double>
    /// Normalised `0...1`.
    public var volume: Stamped<Double>
    public var device: Stamped<MediaDeviceID>
    public var capabilities: Stamped<CapabilitySet>

    public init(
        title: Stamped<String> = .init("", stamp: .zero),
        artist: Stamped<String> = .init("", stamp: .zero),
        playbackRate: Stamped<Double> = .init(0, stamp: .zero),
        elapsed: Stamped<Double> = .init(0, stamp: .zero),
        duration: Stamped<Double> = .init(0, stamp: .zero),
        volume: Stamped<Double> = .init(0, stamp: .zero),
        device: Stamped<MediaDeviceID> = .init(.none, stamp: .zero),
        capabilities: Stamped<CapabilitySet> = .init(.none, stamp: .zero)
    ) {
        self.title = title
        self.artist = artist
        self.playbackRate = playbackRate
        self.elapsed = elapsed
        self.duration = duration
        self.volume = volume
        self.device = device
        self.capabilities = capabilities
    }

    /// The empty state a cold-launched extension starts from. Named rather than
    /// spelled `RemoteSessionState()` at call sites so the intent is legible.
    public static let unknown = RemoteSessionState()

    /// Field-wise join. Commutative, associative and idempotent because every field's
    /// `merged(with:)` is.
    public func merged(with other: RemoteSessionState) -> RemoteSessionState {
        RemoteSessionState(
            title: title.merged(with: other.title),
            artist: artist.merged(with: other.artist),
            playbackRate: playbackRate.merged(with: other.playbackRate),
            elapsed: elapsed.merged(with: other.elapsed),
            duration: duration.merged(with: other.duration),
            volume: volume.merged(with: other.volume),
            device: device.merged(with: other.device),
            capabilities: capabilities.merged(with: other.capabilities)
        )
    }

    public func stamp(of field: SessionField) -> Stamp {
        switch field {
        case .title: return title.stamp
        case .artist: return artist.stamp
        case .playbackRate: return playbackRate.stamp
        case .elapsed: return elapsed.stamp
        case .duration: return duration.stamp
        case .volume: return volume.stamp
        case .device: return device.stamp
        case .capabilities: return capabilities.stamp
        }
    }

    /// Fields whose stamped register differs between two states.
    ///
    /// The single definition of "these two states disagree here", shared by the engine,
    /// the property checker and the merge preview, so all three cannot drift apart.
    public static func divergentFields(_ a: RemoteSessionState, _ b: RemoteSessionState) -> Set<SessionField> {
        var out: Set<SessionField> = []
        if a.title != b.title { out.insert(.title) }
        if a.artist != b.artist { out.insert(.artist) }
        if a.playbackRate != b.playbackRate { out.insert(.playbackRate) }
        if a.elapsed != b.elapsed { out.insert(.elapsed) }
        if a.duration != b.duration { out.insert(.duration) }
        if a.volume != b.volume { out.insert(.volume) }
        if a.device != b.device { out.insert(.device) }
        if a.capabilities != b.capabilities { out.insert(.capabilities) }
        return out
    }

    /// The newest stamp across every field — the session's high-water mark.
    public var highWaterStamp: Stamp {
        SessionField.allCases.reduce(Stamp.zero) { best, field in
            let candidate = stamp(of: field)
            return candidate > best ? candidate : best
        }
    }
}
