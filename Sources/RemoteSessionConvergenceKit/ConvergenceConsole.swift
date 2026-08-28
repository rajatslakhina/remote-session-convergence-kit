#if canImport(SwiftUI)
import SwiftUI

/// The console UI.
///
/// Deliberately thin: everything with a decision in it lives in
/// `ConvergenceConsoleModel`, which is Apple-independent and covered by the test suite
/// on Linux CI. What is left here is layout.
public struct ConvergenceConsoleView: View {
    @State private var model: ConvergenceConsoleModel

    public init(configuration: ConvergenceConsoleConfiguration = ConvergenceConsoleConfiguration()) {
        _model = State(initialValue: ConvergenceConsoleModel(configuration: configuration))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                nowPlaying
                Divider()
                propertyPanel
                Divider()
                capabilityPanel
                Divider()
                controls
                Divider()
                deliveryLog
            }
            .padding(20)
        }
        .task { await model.bootstrap() }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Remote session")

            let displayed = model.snapshot?.displayed
            Text(displayed.map { $0.title.value.isEmpty ? "—" : $0.title.value } ?? "—")
                .font(.title2).bold()
            Text(displayed.map { $0.artist.value.isEmpty ? "—" : $0.artist.value } ?? "—")
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                badge(model.snapshot?.projection.freshness.rawValue ?? "unknown", freshnessColor)
                if model.snapshot?.projection.isExtrapolated == true {
                    badge("extrapolated", .orange)
                }
                if model.snapshot?.hasUnreconciledGap == true {
                    badge("history incomplete", .red)
                }
            }

            progress
        }
    }

    private var progress: some View {
        let projection = model.snapshot?.projection
        // `percentComplete` is produced by `Saturating.percentage`, so it is already
        // clamped to 0...100 and can never be NaN or negative here.
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(projection?.percentComplete ?? 0), total: 100)
            HStack {
                Text(timeLabel(projection?.elapsed ?? 0))
                Spacer()
                Text(projection?.isLive == true ? "live" : timeLabel(projection?.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Property panel

    private var propertyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Convergence check")

            Picker("Merge strategy", selection: strategyBinding) {
                // `id:` and a named parameter are both load-bearing. With a bare
                // `ForEach(MergeStrategy.allCases) { Text($0.rawValue) }` the compiler
                // selects `ForEach`'s *binding* overload, `$0` becomes
                // `Binding<MergeStrategy>`, and `$0.rawValue` resolves through dynamic
                // member lookup to `Binding<String>` — which fails with the memorably
                // unhelpful "initializer 'init(_:)' requires that 'Binding<Subject>'
                // conform to 'StringProtocol'".
                ForEach(MergeStrategy.allCases, id: \.self) { strategy in
                    Text(strategy.rawValue).tag(strategy)
                }
            }
            .pickerStyle(.segmented)

            Text(model.strategy.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report = model.report {
                HStack(spacing: 8) {
                    badge(report.passed ? "PASS" : "FAIL", report.passed ? .green : .red)
                    Text(report.summary).font(.caption.monospaced())
                }
                ForEach(Array(report.violations.enumerated()), id: \.offset) { _, violation in
                    Text("• \(violation.description)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("no delivery yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Written by hand rather than via `$model.strategy` because switching strategy is
    /// an async reset, and a plain property binding would make the picker's new value
    /// visible before the engine behind it had been rebuilt.
    private var strategyBinding: Binding<MergeStrategy> {
        Binding(
            get: { model.strategy },
            set: { next in Task { await model.setStrategy(next) } }
        )
    }

    // MARK: Capabilities

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Capabilities")
            row("device", model.snapshot?.displayed.device.value.rawValue ?? "—")
            row("advertised", labels(model.snapshot?.advertisedCapabilities))
            row("effective", labels(model.snapshot?.effectiveCapabilities))
            row("volume", twoDecimalPlaces(model.snapshot?.displayed.volume.value ?? 0))
            row("in flight", "\(model.snapshot?.pendingCommands.count ?? 0)")
            if let disposition = model.lastDisposition {
                row("last command", describe(disposition))
            }
        }
    }

    private func labels(_ set: CapabilitySet?) -> String {
        let values = set?.labels ?? []
        return values.isEmpty ? "none" : values.joined(separator: ", ")
    }

    private func describe(_ disposition: CommandDisposition) -> String {
        switch disposition {
        case .dispatched: return "dispatched"
        case .degraded(_, let from, _): return "degraded from \(from.labels.first ?? "?")"
        case .rejectedUnsupported(let capability): return "rejected · \(capability.labels.first ?? "?")"
        case .rejectedNoDevice: return "rejected · no device"
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Drive it")
            HStack {
                Button("Deliver burst") { Task { await model.deliverBurst() } }
                Button("Set volume 0.9") { Task { await model.issueVolume(0.9) } }
                Button("Play/pause") { Task { await model.togglePlayback() } }
            }
            HStack {
                Button("Expire pending") { Task { await model.expirePending() } }
                Button("Reset") { Task { await model.reset() } }
            }
            Text("Set volume, then expire it — three times. The endpoint never acknowledges, "
                 + "trust in absoluteVolume is withdrawn, and the next command degrades to a "
                 + "relative nudge instead of pretending to work.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Log

    /// The tail of the delivery log, as a concrete `[DeliveryRecord]`.
    ///
    /// Hoisted out of the `ViewBuilder` deliberately. `suffix` returns an `ArraySlice`,
    /// and converting it inline inside the builder sent the type checker off a cliff —
    /// it reported "missing argument label '_immutableCocoaArray:'", which is what
    /// Swift says when overload resolution has failed somewhere else entirely and is
    /// now guessing. An explicit return type here removes the inference burden and the
    /// diagnostics with it.
    private var recentLog: [DeliveryRecord] {
        let entries = model.log
        guard entries.count > 14 else { return entries }
        return entries.suffix(14).map { $0 }
    }

    private var deliveryLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Delivered (\(model.log.count))")
            if model.log.isEmpty {
                Text("nothing delivered yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(recentLog) { (record: DeliveryRecord) in
                    HStack {
                        Text(record.label).font(.caption2.monospaced())
                        Spacer()
                        Text(record.verdict)
                            .font(.caption2.monospaced())
                            // Both branches spelled `Color` on purpose: bare
                            // `.secondary` is a `HierarchicalShapeStyle` and bare
                            // `.orange` is a `Color`, so the ternary has no common
                            // type and fails to compile.
                            .foregroundStyle(record.verdict == "applied" ? Color.secondary : Color.orange)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var freshnessColor: Color {
        switch model.snapshot?.projection.freshness {
        case .fresh: return .green
        case .aging: return .yellow
        case .stale: return .orange
        case .presumedLost, .none: return .red
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption.monospaced())
    }

    // MARK: Formatting
    //
    // Both of these avoid `String(format:)` on purpose. The first Simulator run of this
    // screen logged, at runtime:
    //
    //   NSCocoaErrorDomain Code=2048 "Format '%.2f' does not match expected '%lld'"
    //
    // `String(format:)` erases its arguments to `CVarArg`, so a format/type mismatch is
    // invisible to the compiler and only surfaces as a console error — or, on a
    // stricter platform, worse. Building the strings arithmetically removes the entire
    // class of bug, and reuses the same saturating helpers as everything else here.

    private func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private func twoDecimalPlaces(_ value: Double) -> String {
        let hundredths = Saturating.int((Saturating.clamp(value, 0, 1) * 100).rounded())
        return "\(Saturating.divide(hundredths, by: 100)).\(padded(Saturating.remainder(hundredths, 100)))"
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Saturating.int(Saturating.finite(seconds).rounded(.down))
        return "\(Saturating.divide(total, by: 60)):\(padded(Saturating.remainder(total, 60)))"
    }
}
#endif
