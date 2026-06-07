// Confetti's bespoke timing — the launch-then-fall amplitude envelope. Port of
// `confetti-tempo.ts`.
//
// Unlike the success effects' held-breath `envelope` (which decays from its
// early peak), confetti stays BRIGHT through the long fall — per-piece
// `dop_particleFade` in the shader handles each piece dimming as it lands. So
// this is a sharp POP attack (overshoot at launch), a near-full sustain while
// everything falls, then a gentle fade only at the very end as the last pieces
// settle. Built on the GENERIC `easeOutBack`/`easeOutCubic` primitives from
// DopamineCore — this bespoke envelope is the ONLY timing code that lives in the
// effect package (matching the web boundary).

import DopamineCore

/// Confetti launch-then-fall amplitude over normalized life. Peak > 1 at launch.
public func confettiAmp(_ life: Double, overshoot: Double) -> Double {
    if life <= 0 || life >= 1 { return 0 }
    let attack = 0.12
    if life < attack {
        // Sharp pop with a little overshoot (the burst leaving the action).
        return easeOutBack(life / attack, overshoot: overshoot)
    }
    // Long luminous sustain, then a soft fade over the last ~30% as pieces settle.
    let tailStart = 0.7
    if life < tailStart { return 1 }
    let x = (life - tailStart) / (1 - tailStart)
    return 1 - easeOutCubic(x) * 0.85
}
