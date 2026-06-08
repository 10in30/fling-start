// Fail's bespoke timing — port of `fail-tempo.ts`.
//
// Where success swells and lingers, failure is a hard NEGATIVE jolt: the ✗ is
// STAMPED in almost instantly, the frame RECOILS with a fast damped SHAKE (a
// "no" head-shake / error buzz), then the whole thing DESATURATES and COLLAPSES
// out quickly. Short and punchy — no afterglow, no celebration. Built on the
// GENERIC `easeOutCubic` / `tempoClamp01` primitives from DopamineCore — this
// bespoke timing is the ONLY timing code that lives in the effect package
// (matching the web boundary).

import Foundation
import DopamineCore

/// Window (ms) over which the ✗ cross is stamped/slashed in. Hard + fast.
public let FAIL_STAMP_MS: Double = 170

/// Total nominal length the shake + collapse occupy after the stamp.
public let FAIL_SHAKE_MS: Double = 300

/// Stamp progress (0..1) of the ✗ over elapsed ms. Eased so the cross lands hard
/// and immediately (most of the draw happens in the first third), reading as a
/// stamp/slash rather than a gentle write-on.
public func stampProgress(_ elapsedMs: Double) -> Double {
    let x = tempoClamp01(elapsedMs / FAIL_STAMP_MS)
    // ease-out quint: very fast in, abrupt settle.
    return 1 - pow(1 - x, 5)
}

/// Fail presence/amplitude over normalized life (0..1): a near-instant slam to
/// full, a brief hold, then a fast collapse. The fade is steeper + earlier than
/// the comic's so the moment reads as curt/negative, not a proud hold.
public func failEnvelope(_ life: Double) -> Double {
    let t = tempoClamp01(life)
    if t < 0.05 { return easeOutCubic(t / 0.05) } // hard slam in
    if t < 0.55 { return 1 } // brief, curt hold
    let fade = tempoClamp01(1 - (t - 0.55) / 0.45)
    return pow(fade, 1.7) // quick collapse
}

/// Damped recoil SHAKE offset over elapsed ms — a horizontal "no" head-shake that
/// decays fast. Returns a signed multiplier (~-1..1) the renderer scales into px.
/// `amount` (driven by intensity) scales the initial swing. Settles to ~0 quickly
/// so the effect doesn't jitter through its whole life.
public func shakeOffset(_ elapsedMs: Double, amount: Double = 1) -> Double {
    if elapsedMs <= 0 { return 0 }
    let decay = exp(-elapsedMs / (FAIL_SHAKE_MS * 0.35))
    // ~3.5 oscillations over the shake window.
    let osc = sin((elapsedMs / FAIL_SHAKE_MS) * Double.pi * 7.0)
    return osc * decay * amount
}
