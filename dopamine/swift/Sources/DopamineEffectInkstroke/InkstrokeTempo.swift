// Inkstroke's bespoke timing — port of `inkstroke-tempo.ts`.
//
// A confident gesture: a touch longer than a checkmark tick so the pressure
// belly + flick read, but still inside the ~250–360 ms confirmation band so it
// lands as "done" immediately rather than as a slow build. Built on the GENERIC
// `easeOutCubic` primitive from DopamineCore — this bespoke window is the ONLY
// timing code that lives in the effect package (matching the web boundary).

import DopamineCore

/// Window (ms) over which the calligraphic stroke writes itself.
public let STROKE_DRAW_MS: Double = 360

/// Calligraphic stroke / pen progress (0..1) over elapsed ms. The pen
/// accelerates into the gesture then eases off the flick — modelled as ease-out
/// cubic so the heavy belly is laid quickly and the exit decelerates into the
/// upward flick.
public func strokeProgress(_ elapsedMs: Double) -> Double {
    easeOutCubic(elapsedMs / STROKE_DRAW_MS)
}
