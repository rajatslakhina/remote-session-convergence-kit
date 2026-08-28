import Foundation

/// Total, non-trapping arithmetic.
///
/// Every operation in this file is chosen because the *natural* Swift spelling of it
/// traps at runtime for at least one input that this library can genuinely receive:
///
/// | natural spelling | traps on |
/// |---|---|
/// | `Int(someDouble)` | `NaN`, `±infinity`, and anything outside `Int`'s range |
/// | `a / b`, `a % b`  | `b == 0`, and `Int.min / -1` / `Int.min % -1` |
/// | `a + b`, `a * b`  | overflow |
///
/// A remote media session is fed by a transport we do not control: a malformed or
/// hostile push payload carrying `duration: 0` or `elapsed: NaN` must degrade the
/// Lock Screen, not kill the extension. So the rule in this package is that no
/// arithmetic on transport-sourced numbers is ever written in its trapping form.
///
/// Bounds are derived from `Int.max` / `Int.min` rather than hardcoded 64-bit
/// literals, so this stays correct if the package is ever built for a 32-bit `Int`.
public enum Saturating {

    /// `Int(d)` without the trap. `NaN` maps to `0`; out-of-range values clamp.
    ///
    /// The subtle case is the upper bound. `Double(Int.max)` is **not** `Int.max` on a
    /// 64-bit platform: `Int.max` (2^63 - 1) is not representable as a `Double`, so the
    /// conversion rounds *up* to 2^63. Comparing with `<=` would therefore admit exactly
    /// 2^63 and trap on the subsequent `Int(_:)`. Using `>=` excludes it. On a 32-bit
    /// platform `Double(Int.max)` is exact and `>=` returns the correct value anyway.
    public static func int(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= Double(Int.max) { return .max }
        if d <= Double(Int.min) { return .min }
        return Int(d)
    }

    /// Clamps a `Double` into a closed range, mapping `NaN` to `lower`.
    /// `lower > upper` is treated as a programmer error at the call site and resolved
    /// in favour of `lower` rather than trapping on an invalid `ClosedRange`.
    public static func clamp(_ d: Double, _ lower: Double, _ upper: Double) -> Double {
        if d.isNaN { return lower }
        if upper < lower { return lower }
        if d < lower { return lower }
        if d > upper { return upper }
        return d
    }

    /// A finite `Double`, or `fallback` when the input is `NaN` or infinite.
    public static func finite(_ d: Double, fallback: Double = 0) -> Double {
        d.isFinite ? d : fallback
    }

    public static func add(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return value }
        return b > 0 ? .max : .min
    }

    public static func subtract(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return value }
        return b < 0 ? .max : .min
    }

    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return value }
        // Overflow only happens away from zero, so the sign of the true product is
        // the product of the signs of the operands.
        return (a > 0) == (b > 0) ? .max : .min
    }

    /// Division by zero yields `0`; `Int.min / -1` (the one overflowing division) saturates.
    public static func divide(_ a: Int, by b: Int) -> Int {
        if b == 0 { return 0 }
        if a == .min && b == -1 { return .max }
        return a / b
    }

    /// Remainder by zero yields `0`. `a % -1` is mathematically `0` for every `a`,
    /// and is short-circuited because `Int.min % -1` traps.
    public static func remainder(_ a: Int, _ b: Int) -> Int {
        if b == 0 { return 0 }
        if b == -1 { return 0 }
        return a % b
    }

    /// `value / total` as an integer percentage clamped to `0...100`.
    /// Non-finite inputs and a non-positive total both yield `0` — a progress bar that
    /// reads zero is a survivable bug; one that traps is not.
    public static func percentage(_ value: Double, of total: Double) -> Int {
        guard value.isFinite, total.isFinite, total > 0 else { return 0 }
        let ratio = clamp(value / total, 0, 1)
        return int((ratio * 100).rounded())
    }
}
