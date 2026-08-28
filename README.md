# RemoteSessionConvergenceKit

**Your Now Playing widget is a distributed replica, and a best-effort push is the only wire feeding it.**

When media plays on a speaker or TV you don't own, the Lock Screen, Control Center, Dynamic Island, StandBy and CarPlay are all rendering a copy of state that lives somewhere else entirely. There is no shared memory anywhere on that path. The speaker changes, your server hears about it, your server pushes, and the system **cold-launches a memoryless extension** with that payload — which then has to reconstruct an entire session from one push and nothing else.

Meanwhile commands travel the *opposite* direction on a *different* channel: system UI → your command handler → your server → the speaker. Two channels, opposite directions, no shared clock, no shared log.

So the read path and the write path can disagree. And normally, they do.

This package is the convergence layer that makes them agree anyway.

---

## Why this matters

Every individual failure here is mundane. Together they are a distributed-systems problem wearing a media-UI hat:

| What the platform gives you | What it costs |
|---|---|
| Push delivery is **best-effort** | Updates vanish with no error surfaced anywhere |
| Push delivery is **unordered** | A newer update can land before an older one and lose |
| Push delivery **coalesces** | Intermediate states are discarded *by design*, not by congestion |
| The extension is **system-launched and memoryless** | No local log to reconcile against — every wake starts from nothing |
| Commands are a **separate channel** | Your own command comes back as a "remote update" and fights your UI |
| Capabilities are **advertised, not guaranteed** | The system renders a real volume slider for a device that may ignore it |
| Device ids must be **stable across sessions** | While the device set itself churns all evening |

The naive handler — take the payload, write the fields in — is correct on an ordered transport and silently wrong on this one. It doesn't crash. It produces two phones showing two different screens for one speaker, and nobody can reproduce it.

**The deliverable here is a convergence policy and a degradation contract, not a screen.**

---

## The design, and what it rejects

### 1. The server is the sole sequencer

Every envelope carries a `Stamp` — a server-assigned `sequence` plus the `OriginID` it was relayed for. Ordering is decided in exactly one place.

**Rejected: per-device sequences.** Letting the speaker and the server each number their own updates means the device is comparing two unrelated integer spaces and pretending the result is an ordering. It looks fine in a demo with one producer.

**Rejected: ordering on `emittedAt`.** Wall-clock ordering across a speaker, a server and a phone is how sync engines acquire their haunted bugs. `emittedAt` is kept, but it is used only for staleness and display — never for merge decisions.

### 2. Every field is a last-writer-wins register

`Stamped<Value>` holds a value and the stamp that wrote it. `merged(with:)` takes the max under a **total** order — and totality is the whole requirement, because `max` over a totally ordered set is associative, commutative and idempotent. That makes `RemoteSessionState.merged(with:)` a join-semilattice, so **arrival order cannot change the result**.

There is a subtle third tiebreak. If two envelopes carry the same stamp with different values, max-by-stamp is ambiguous and commutativity silently dies — the exact failure this package exists to prevent. A correct producer never does that, but "should never happen" isn't a guarantee when the producer is third-party hardware, so the merge falls through to a content key and stays total unconditionally.

**Rejected: whole-state versioning.** One version number for the whole session means a coalesced burst that dropped the intermediate update can't be partially applied, and a late arrival carrying one genuinely newer field has to be thrown away wholesale.

### 3. Local intent never enters converged state

This is the fix for echo suppression, and it's structural rather than a heuristic.

`RemoteSessionState` contains **only** server-sequenced values. A user's volume drag goes into `OptimisticOverlay` — painted on top for display, never merged in. When the acknowledgement comes back carrying that `CommandID`, the overlay entry retires and the envelope's value becomes authoritative *without* being re-notified as a remote change.

The alternative — writing optimistic values into the same state and filtering echoes by comparing values — requires the device to guess whether a volume of `0.9` is its own echo or a second user in the room turning it up. It cannot know. Keeping the two layers apart means it never has to ask.

The overlay is **bounded**: FIFO eviction at `capacity`, expiry at `commandTimeout`. A user mashing a slider inside a memory-constrained extension must not be able to grow a table without limit.

### 4. Capabilities are earned, not announced

A device advertising `.absoluteVolume` gets a real, draggable system slider. If it then ignores every value sent to it, the slider still moves — it's bound to local intent — and the user watches a control that does nothing. There is no "the speaker declined" callback.

`CapabilityTrustLedger` therefore scores *observed behaviour*. Three consecutive commands expiring unacknowledged withdraws the capability; one success restores it. The command layer then either **degrades** (`setVolume(0.8)` becomes `adjustVolume(+0.4)` if relative volume is still trusted) or **refuses outright**.

**Degrade, don't lie.** A control that visibly isn't offered beats a control that pretends.

The ledger is bounded too — LRU eviction over a churning device set.

### 5. Every wake is a full re-derivation

`ColdStartReconciler` rebuilds from the push payload alone, and reports a `SequenceGap` when the arriving sequence skipped past the persisted watermark.

**Rejected: persist a snapshot and apply the delta.** Tempting, and wrong. The extension is memoryless by contract and the transport coalesces, so a persisted snapshot is of unknowable age — merging into it silently resurrects fields the session has since abandoned. Rebuilding from the payload and *reporting the hole* is strictly more honest than reconstructing a plausible lie.

The watermark exists only to tell "the next update" apart from "the next update I happened to receive."

### 6. Staleness is part of what gets rendered

On a best-effort transport, "no update" and "nothing changed" are the same observation. So `Freshness` (`fresh` → `aging` → `stale` → `presumedLost`) is first-class, and the playhead only extrapolates while `fresh` or `aging`. A stale session's progress bar stops rather than confidently sliding past the end of a track that stopped playing two minutes ago.

### 7. No trapping arithmetic on transport-sourced numbers

Everything numeric arrives from a wire nobody controls. `Saturating` replaces every operation whose natural spelling traps: `Int(someDouble)` (NaN, infinity, out-of-range), `/` and `%` by zero, `Int.min / -1`, `+`/`*` overflow.

The upper bound is the interesting one. `Double(Int.max)` is **not** `Int.max` on a 64-bit platform — 2^63−1 isn't representable, so it rounds *up* to 2^63. A `<=` bound admits exactly 2^63 and then traps on the conversion; `Saturating.int` uses `>=`.

Bounds are derived from `Int.max`/`Int.min` rather than hardcoded, so the code stays correct where `Int` is 32 bits — but that is *reasoning, not a measurement*: no CI job builds a 32-bit target, and a test running on a 64-bit host cannot tell a derived bound from a hardcoded one. What the suite does pin is that the bounds stay expressed relative to `Int.max`.

A malformed payload carrying `elapsed: NaN` must degrade the Lock Screen, not kill the extension.

### 8. The actor has no suspension points inside critical sections

`ConvergenceEngine` is an `actor`, and **every method body is fully synchronous**.

Actor isolation guarantees mutual exclusion but *not* atomicity across a suspension point: a method that awaited mid-way through a read-modify-write can be re-entered, letting another task observe half-applied state. Keeping every critical section suspension-free makes that entire class of bug unrepresentable.

The cost is deliberate — I/O lives at the call site, using values the engine returns. This type is the policy, not the plumbing.

---

## The properties are executable

"Order doesn't matter" is easy to write in a README and hard to keep true through six months of edits. So it runs:

```swift
let report = ConvergenceProperties.check(merger: StampedFieldMerger(), envelopes: captured)
report.passed   // commutativity, idempotence, monotonicity
```

`ConvergenceProperties` is public rather than test-only for two reasons: the demo app runs it live on screen, and an integrating app can point it at its own captured production envelopes.

**And the checker is proven to have teeth.** `NaiveOverwriteMerger` ships *in the library* — a merger that is wrong on purpose, doing the obvious thing every first-draft push handler does. The suite hands it to the checker and asserts the checker **fails**. A checker that has only ever been seen to pass is not evidence of anything.

That test caught a real bug in the checker during development: the monotonicity pass originally scanned only the caller's order, so a pre-sorted input — the common case when someone passes a captured log — never gave a stamp-ignoring merger the chance to regress anything, and the check reported a clean bill of health for an implementation with no ordering logic at all. It now always constructs the descending worst case itself. `testMonotonicityIsCaughtEvenWhenTheInputIsAlreadySorted` pins that.

---

## What's in it

| Type | Responsibility |
|---|---|
| `Stamp`, `OriginID`, `Stamped<Value>` | The total order and the LWW register that convergence rests on |
| `RemoteSessionState`, `StateEnvelope`, `FieldUpdate` | Converged state, and the sparse deltas that reach the device |
| `StampedFieldMerger` | The real merge — field-wise join |
| `NaiveOverwriteMerger` | The shipped counterexample the property tests must catch |
| `OptimisticOverlay` | Optimistic display + echo suppression; bounded and expiring |
| `CapabilityTrustLedger` | Advertised vs. demonstrated capability; LRU-bounded |
| `StalenessPolicy`, `PlaybackProjector` | Freshness bands, and clamped playhead extrapolation |
| `Watermark`, `SequenceGap`, `ColdStartReconciler` | Cold-launch re-derivation and gap reporting |
| `ConvergenceEngine` | The actor tying it together; suspension-free critical sections |
| `ConvergenceProperties` | Executable commutativity / idempotence / monotonicity |
| `LossyTransport`, `SessionScript`, `DeterministicRandom` | Reproducible drop / reorder / coalesce simulation |
| `ConvergenceConsoleView` | SwiftUI console the demo app hosts |

The package has **no dependency on the `NowPlaying` framework**, deliberately. The convergence core is transport- and framework-agnostic, which is what lets it be tested exhaustively on Linux CI and reused behind any remote-session transport; the `NowPlaying` adaptation is a thin boundary the host app owns.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/remote-session-convergence-kit.git", from: "1.0.0")
```

```swift
let engine = ConvergenceEngine()

// Cold launch: rebuild from the payload alone, and find out what you missed.
let wake = await engine.wake(with: pushEnvelope, now: .now)
if let gap = wake.gap { logger.warning("lost \(gap.missingCount) updates") }

// Steady state: feed whatever arrives, in whatever order it arrives.
await engine.ingest(envelope, now: .now)

// Commands go through the policy layer, not straight to the wire.
switch await engine.issue(RemoteCommand(id: id, intent: .setVolume(0.8)), now: .now) {
case .dispatched(let command, _):        send(command)
case .degraded(let weaker, let from, _): logger.notice("\(from.labels) withdrawn"); send(weaker)
case .rejectedUnsupported(let capability): hideControl(for: capability)
case .rejectedNoDevice:                  break
}

let frame = await engine.snapshot(now: .now)   // render `frame.displayed`
```

## Running it

```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

## Demo app

A runnable SwiftUI app that hosts `ConvergenceConsoleView` — with a live merge-strategy toggle you can watch fail — lives in its own repository:

**[remote-session-convergence-kit-demo-app](https://github.com/rajatslakhina/remote-session-convergence-kit-demo-app)** — consumes this package as a version-pinned remote dependency.

*Neither repository has been published yet — see [Verification](#verification) below and [PUBLISH.md](PUBLISH.md).*

## Verification

> **Publication status.** Neither this repository nor the demo repository has been pushed to GitHub yet, so **every GitHub link on this page — including the package URL in the dependency snippet above — will 404 until they are.** Repository creation was blocked in the automated run that produced this code; see [PUBLISH.md](PUBLISH.md) for the exact steps. Everything below describes what was actually executed locally.

Measured on **Swift 6.0.3** (`swift-6.0.3-RELEASE`, `aarch64-unknown-linux-gnu`), from a clean tree — `rm -rf .build` first, because `swift build` on an up-to-date tree compiles nothing and still prints `Build complete!`:

| Check | Result |
|---|---|
| `swift build --build-tests -Xswiftc -warnings-as-errors` | `Build complete!` — no warnings, no errors |
| `swift test` | **94 tests, 0 failures**, across 13 suites |
| `swiftc -swift-version 6 -parse` on `ConvergenceConsole.swift` | parses |

The `-warnings-as-errors` flag is in the CI workflow rather than only in this sentence, so the zero-warning claim is machine-enforced rather than asserted in prose.

### What was *not* verified

Stated separately and specifically, because "it builds" and "it runs" are different claims and conflating them is the most common way a portfolio README misleads:

- **CI has never executed.** Both workflows are committed and are what the repositories will run on first push, but no run exists yet, so there is no green tick to point at and none is claimed.
- **The `.macOS(.v14)` platform declaration is unverified** — the macOS job that would prove it has not run.
- **Remote package resolution is unverified.** The demo app was compiled and run against a local-path copy of these sources, because this package is not published. Whether Xcode resolves it from GitHub at `1.0.0` is unproven until it is.

### The SwiftUI layer was type-checked the hard way

`ConvergenceConsoleView` sits behind `#if canImport(SwiftUI)`, so the Linux job skips it. It passed `swiftc -parse` and 94 tests and a zero-warning build — and then failed to compile the first time it met a real SwiftUI SDK, with three errors, plus one fault that only appeared at runtime:

1. `ForEach(MergeStrategy.allCases) { Text($0.rawValue) }` bound to `ForEach`'s **binding** overload, making `$0.rawValue` a `Binding<String>`.
2. `Array(someSlice)` inside a `ViewBuilder` produced `missing argument label '_immutableCocoaArray:'` — the diagnostic Swift emits after overload resolution has already collapsed.
3. `foregroundStyle(cond ? .secondary : .orange)` — `HierarchicalShapeStyle` and `Color` have no common type.
4. `String(format: "%.2f", …)` logged `NSCocoaErrorDomain Code=2048 "Format '%.2f' does not match expected '%lld'"` on every frame while rendering the correct value. `CVarArg` erasure means the compiler cannot see this; only running it does. `String(format:)` is now gone from that file.

All four are fixed, and the app has been built and run on iPhone 17 Pro / iOS 26.3 — see the [demo repository](https://github.com/rajatslakhina/remote-session-convergence-kit-demo-app) for screenshots.

This is the concrete argument for the `Observation`/`SwiftUI` split in this package: everything with a decision in it lives in `ConvergenceConsoleModel`, which Linux compiles and tests, so the code that can only be checked by an Apple toolchain is confined to layout — and layout is exactly where all four of those bugs were.

### What the tests actually cover

Not a coverage percentage — the specific failure modes:

- **Convergence** — all 720 permutations of a six-envelope stream agree; a transport-mangled stream converges to the same state as its ordered delivery; dropped envelopes converge to the surviving maximum.
- **The checker itself** — `NaiveOverwriteMerger` is handed to `ConvergenceProperties` and the checker is **required to fail**, including on a pre-sorted input that would otherwise hide a stamp-ignoring merge.
- **Crash edges** — `NaN`/`±infinity` conversions, division and remainder by zero, `Int.min / -1`, `+`/`*` overflow, empty collections, inverted ranges, degenerate capacities, `UInt64` gap underflow.
- **Bounds** — overlay FIFO eviction, ledger LRU eviction, watermark trimming, demo log cap.
- **Concurrency** — a `TaskGroup` of genuinely concurrent `ingest` calls must converge to the same state as sequential delivery. Real concurrent writers, not a single-writer test wearing the label.
- **The demo's on-screen claims** — bootstrap populates the default screen, the strategy toggle flips `PASS` to `FAIL`, and the documented three-round degrade sequence actually reaches a degrade.

## Licence

MIT — see [LICENSE](LICENSE).
