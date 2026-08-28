import Foundation

public struct PropertyViolation: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// Two deliveries of the same envelopes in different orders disagreed. On a
        /// transport that reorders, this is the bug that makes two phones show two
        /// different Now Playing screens for one speaker.
        case commutativity
        /// Redelivering an envelope changed the answer. APNs retries; this must not matter.
        case idempotence
        /// A field's stamp moved backwards, i.e. an old update overwrote a newer one.
        case monotonicity
    }

    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(kind.rawValue): \(detail)" }
}

public struct ConvergenceReport: Sendable, Equatable {
    public let violations: [PropertyViolation]
    public let permutationsChecked: Int
    public let envelopeCount: Int

    public var passed: Bool { violations.isEmpty }

    public var kinds: Set<PropertyViolation.Kind> { Set(violations.map(\.kind)) }

    public var summary: String {
        guard !passed else {
            return "PASS — \(envelopeCount) envelopes, \(permutationsChecked) orderings agree"
        }
        let names = PropertyViolation.Kind.allCases
            .filter { kinds.contains($0) }
            .map(\.rawValue)
            .joined(separator: ", ")
        return "FAIL — \(violations.count) violation(s): \(names)"
    }
}

/// Executable statements of the three properties this package claims.
///
/// The claim "order does not matter" is easy to write in a README and hard to keep
/// true through six months of edits. This checker turns it into something that runs:
/// give it a merger and a bag of envelopes, and it will fold them in many orders and
/// report where the answers diverged.
///
/// It is public — not test-only — for two reasons. The demo app runs it live on screen,
/// and, more usefully, an app integrating this package can run it against its own
/// captured production envelopes to confirm its real traffic converges.
public enum ConvergenceProperties {

    public static func check(
        merger: any EnvelopeMerging,
        envelopes: [StateEnvelope],
        permutations: Int = 64,
        seed: UInt64 = 0x5EED_C0FF_EE12_3456
    ) -> ConvergenceReport {
        guard envelopes.count > 1 else {
            // A single envelope has exactly one ordering, so the properties hold
            // vacuously. Reported as zero permutations rather than as a pass, so the
            // caller cannot mistake "nothing was checked" for "everything is fine".
            return ConvergenceReport(violations: [], permutationsChecked: 0, envelopeCount: envelopes.count)
        }

        var violations: [PropertyViolation] = []

        // Reference: the canonical stamp-sorted delivery.
        let canonical = envelopes.sorted { $0.stamp < $1.stamp }
        let reference = fold(canonical, with: merger)

        // 1. Commutativity across seeded permutations.
        let rounds = max(1, permutations)
        var rng = DeterministicRandom(seed: seed)
        var checked = 0
        for round in 0..<rounds {
            let order = rng.shuffled(envelopes)
            let result = fold(order, with: merger)
            checked += 1
            if result != reference {
                violations.append(PropertyViolation(
                    kind: .commutativity,
                    detail: "permutation \(round) (seed \(seed)) disagreed with stamp-sorted delivery; "
                        + "first divergent field: \(firstDivergentField(reference, result)?.rawValue ?? "unknown")"
                ))
                // One counterexample is enough to falsify the claim; the rest would be
                // noise in the report.
                break
            }
        }

        // 2. Idempotence: redelivering everything must be a no-op.
        var replayed = reference
        for envelope in canonical {
            replayed = merger.apply(envelope, to: replayed)
        }
        if replayed != reference {
            violations.append(PropertyViolation(
                kind: .idempotence,
                detail: "redelivering all \(canonical.count) envelopes changed the state; "
                    + "first divergent field: \(firstDivergentField(reference, replayed)?.rawValue ?? "unknown")"
            ))
        }

        // 3. Monotonicity: no field's stamp may ever move backwards.
        //
        // Checked against the caller's order *and* against strictly-descending order.
        // The second one is not padding: if the envelopes were handed over already
        // sorted — which is the common case when someone passes a captured log — then a
        // merger that ignores stamps entirely never gets the chance to regress one, and
        // a monotonicity check over that order alone would report a clean bill of health
        // for an implementation that has no ordering logic at all. Descending order is
        // the deterministic worst case, so it is always exercised.
        for order in [envelopes, canonical.reversed()] {
            var running = RemoteSessionState.unknown
            var regressed = false
            for envelope in order {
                let next = merger.apply(envelope, to: running)
                for field in SessionField.allCases where next.stamp(of: field) < running.stamp(of: field) {
                    violations.append(PropertyViolation(
                        kind: .monotonicity,
                        detail: "field \(field.rawValue) regressed from "
                            + "\(running.stamp(of: field).sequence) to \(next.stamp(of: field).sequence) "
                            + "on envelope \(envelope.id)"
                    ))
                    regressed = true
                }
                running = next
                if regressed { break }
            }
            if regressed { break }
        }

        return ConvergenceReport(
            violations: violations,
            permutationsChecked: checked,
            envelopeCount: envelopes.count
        )
    }

    private static func fold(_ envelopes: [StateEnvelope], with merger: any EnvelopeMerging) -> RemoteSessionState {
        envelopes.reduce(RemoteSessionState.unknown) { merger.apply($1, to: $0) }
    }

    private static func firstDivergentField(_ a: RemoteSessionState, _ b: RemoteSessionState) -> SessionField? {
        let divergent = RemoteSessionState.divergentFields(a, b)
        // Ordered by `allCases` rather than by `Set` iteration so the reported
        // counterexample is stable between runs.
        return SessionField.allCases.first { divergent.contains($0) }
    }
}
