// Heartburst's bespoke timing — port of `heartburst-tempo.ts`.
//
// The shape of time is a "lub-dub" double-pulse: the heart swells on a first
// (loud) beat, relaxes, swells again on a second (softer) beat, then on the
// release it BURSTS into a flurry of little hearts that fly outward and fade.
// All pure functions of normalized life so a frame is reproducible. Built on the
// GENERIC `easeOutCubic`/`tempoClamp01` primitives from DopamineCore — this
// bespoke window is the ONLY timing code that lives in the effect package
// (matching the web boundary).
//
//   life 0.00 .. 0.30  : LUB-DUB — two beats; the second tucked behind the first
//   life 0.30 .. 1.00  : BURST + AFTERGLOW — little hearts fly out, big heart fades

import Foundation
import DopamineCore

/// Fraction of life occupied by the lub-dub beat phase before the burst.
public let HEARTBEAT_PHASE: Double = 0.3

/// A single soft beat pulse centred at `center` (in life units) with half-width
/// `width`: rises fast, eases back down. Returns 0..1 (peak 1 at `center`).
private func beatPulse(_ t: Double, _ center: Double, _ width: Double) -> Double {
    let x = (t - center) / width
    if x <= -1 || x >= 1 { return 0 }
    let lobe = 0.5 + 0.5 * cos(x * Double.pi)
    return x < 0 ? pow(lobe, 0.7) : pow(lobe, 1.4)
}

/// Heart SCALE multiplier over normalized life. A resting 1.0 with two beats
/// superimposed, then it settles to rest through the burst and gently shrinks as
/// it fades. `strength` scales beat swell; `doubleBeat` blends single → lub-dub.
public func heartbeatScale(_ life: Double, strength: Double = 1, doubleBeat: Double = 1) -> Double {
    let t = tempoClamp01(life)
    let lub = beatPulse(t, 0.1, 0.1)
    let dub = beatPulse(t, 0.21, 0.075) * 0.62 * tempoClamp01(doubleBeat)
    let beat = max(lub, dub)
    let sag = t > HEARTBEAT_PHASE ? 0.06 * easeOutCubic((t - HEARTBEAT_PHASE) / (1 - HEARTBEAT_PHASE)) : 0
    return 1 + beat * 0.42 * strength - sag
}

/// The amplitude/energy envelope (→ amp + shadow strength). Tracks the beats
/// during the lub-dub then a bright flare at the burst, decaying through the
/// afterglow. `heartburstEnvelope(0) ~ 0`, peaks on the beats + burst, → 0 by life 1.
public func heartburstEnvelope(_ life: Double, strength: Double = 1, doubleBeat: Double = 1) -> Double {
    let t = tempoClamp01(life)
    if t <= 0 || t >= 1 { return 0 }
    let lub = beatPulse(t, 0.1, 0.1)
    let dub = beatPulse(t, 0.21, 0.075) * 0.62 * tempoClamp01(doubleBeat)
    let beats = max(lub, dub) * 0.9 * strength
    let b = burstProgress(life)
    let flare = b * pow(1 - b, 1.1) * 2.4
    return tempoClamp01(max(beats, flare * (0.7 + 0.3 * strength)))
}

/// Burst progress 0..1 over the post-beat phase: 0 until the dub finishes, then
/// eases out to 1 as the little hearts fly out and fade.
public func burstProgress(_ life: Double) -> Double {
    let t = tempoClamp01(life)
    if t <= HEARTBEAT_PHASE { return 0 }
    return easeOutCubic((t - HEARTBEAT_PHASE) / (1 - HEARTBEAT_PHASE))
}
