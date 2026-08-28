import Foundation

/// Tracks whether a device *actually honours* the capabilities it advertises.
///
/// This exists because of a specific lie the system UI is happy to tell on your behalf.
/// When a device advertises `.absoluteVolume`, the platform renders a real, draggable
/// volume slider. If the device then ignores every value you send it, the slider still
/// moves — because it is bound to local intent — and the user watches a control that
/// does nothing. There is no callback for "the speaker declined".
///
/// So trust is *earned from observed behaviour*: a capability whose commands keep
/// expiring unacknowledged is withdrawn, and the command layer degrades to something
/// the device has actually demonstrated, or refuses outright. Degrade, don't lie.
///
/// **Bounded by construction.** A device set churns — a phone can see dozens of
/// endpoints over an evening — so the table is capped and evicts least-recently-used
/// devices rather than growing for the process lifetime.
public struct CapabilityTrustLedger: Sendable {

    public struct Record: Sendable, Equatable {
        public var consecutiveUnhonoured: Int = 0
        public var honoured: Int = 0
        public var unhonoured: Int = 0
    }

    /// Consecutive unacknowledged commands before a capability is withdrawn.
    public let distrustThreshold: Int
    public let maxTrackedDevices: Int

    private struct Key: Hashable {
        let device: MediaDeviceID
        let capability: UInt16
    }

    private var records: [Key: Record] = [:]
    /// Least-recently-used first.
    private var recency: [MediaDeviceID] = []

    public init(distrustThreshold: Int = 3, maxTrackedDevices: Int = 16) {
        self.distrustThreshold = max(1, distrustThreshold)
        self.maxTrackedDevices = max(1, maxTrackedDevices)
    }

    public var trackedDeviceCount: Int { recency.count }

    public func record(device: MediaDeviceID, capability: CapabilitySet) -> Record {
        records[Key(device: device, capability: capability.rawValue)] ?? Record()
    }

    public mutating func recordHonoured(device: MediaDeviceID, capability: CapabilitySet) {
        touch(device)
        let key = Key(device: device, capability: capability.rawValue)
        var record = records[key] ?? Record()
        record.consecutiveUnhonoured = 0
        record.honoured = Saturating.add(record.honoured, 1)
        records[key] = record
    }

    public mutating func recordUnhonoured(device: MediaDeviceID, capability: CapabilitySet) {
        touch(device)
        let key = Key(device: device, capability: capability.rawValue)
        var record = records[key] ?? Record()
        record.consecutiveUnhonoured = Saturating.add(record.consecutiveUnhonoured, 1)
        record.unhonoured = Saturating.add(record.unhonoured, 1)
        records[key] = record
    }

    public func isTrusted(device: MediaDeviceID, capability: CapabilitySet) -> Bool {
        record(device: device, capability: capability).consecutiveUnhonoured < distrustThreshold
    }

    /// The advertised set minus everything this device has stopped honouring.
    ///
    /// Only capabilities that are individually representable are checked — the input is
    /// a set, so it is decomposed into single bits first. Iterating raw bit positions
    /// (rather than a hardcoded list) means a capability added later is covered without
    /// anyone remembering to update this function.
    public func effectiveCapabilities(advertised: CapabilitySet, device: MediaDeviceID) -> CapabilitySet {
        var effective = advertised
        for bit in 0..<UInt16.bitWidth {
            let single = CapabilitySet(rawValue: 1 << UInt16(bit))
            guard advertised.contains(single) else { continue }
            if !isTrusted(device: device, capability: single) {
                effective.remove(single)
            }
        }
        return effective
    }

    private mutating func touch(_ device: MediaDeviceID) {
        if let index = recency.firstIndex(of: device) {
            recency.remove(at: index)
        }
        recency.append(device)
        while recency.count > maxTrackedDevices {
            // Non-empty: count > maxTrackedDevices >= 1.
            let evicted = recency.removeFirst()
            records = records.filter { $0.key.device != evicted }
        }
    }
}
