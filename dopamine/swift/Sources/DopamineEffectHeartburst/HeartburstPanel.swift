// Heartburst — the offscreen Canvas2D PANEL, ported to Core Graphics as a
// `PanelDrawing` conformance on `HeartburstConfig`.
//
// HYBRID effect: the crisp vector hearts (the big swelling HERO heart + the
// flurry of little BURST hearts that fly out) are NOT procedural in the shader —
// the web traces them as parametric heart curves into an offscreen Canvas2D
// ("panel") and the fragment shader (Heartburst.metal) samples that texture and
// adds the warm bloom / gloss / halftone blush / beat flash / cast light on top.
// The Swift backbone owns the panel runner (MetalOverlayHost builds + uploads it
// in `prepare()` from any config conforming to `PanelDrawing`); this file
// supplies ONLY the per-effect draw, a faithful port of
// `packages/effect-heartburst/src/heartburst-renderer.ts`.
//
// PANEL CHANNEL ENCODING (must match Heartburst.metal exactly):
//   R = hero heart FILL   G = INK (outline) + gloss seed   B = burst hearts FILL
// The shader samples the panel at fragment texture(0), sampler(0) in a y-up vUv;
// the host flips the CGContext to a TOP-LEFT origin so this draw matches the web
// Canvas2D coordinate space verbatim (y-down, origin top-left).
//
// STATIC-SNAPSHOT SIMPLIFICATION: the web redraws the panel EVERY frame with the
// live beat scale + burst progress + presence, so the little hearts animate
// outward over the panel. The Swift backbone builds the panel ONCE in `prepare()`,
// so we bake a representative mid-burst pose: hero heart at rest scale (the shader
// still pulses it via u.beat) and the burst hearts at b ≈ 0.45 of their flight
// (mid-flurry, so they read as spilling out). The shader still drives the warm
// bloom / beat / burst flash via its uniforms; only the vector geometry is frozen.

#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import DopamineCore

extension HeartburstConfig: PanelDrawing {
    public func panelSizePx(canvasPx: CGSize, params: [String: DopeValue]) -> CGSize { canvasPx }

    public func drawPanel(_ ctx: CGContext, sizePx: CGSize, params: [String: DopeValue]) {
        let w = sizePx.width, h = sizePx.height
        guard w > 1, h > 1 else { return }

        func num(_ k: String, _ d: Double) -> Double {
            if case let .number(v)? = params[k] { return v }; return d
        }
        let seedParam   = num("heartburstSeed", 0)
        let heartScale  = num("heartScale", 0.22)
        let burstCount  = num("burstCount", 14)
        let burstSpread = num("burstSpread", 0.4)
        let inkWeight   = num("inkWeight", 3)

        // The web additive compositing keeps the R/G/B channel masks independent.
        ctx.setBlendMode(.plusLighter)

        let cx = w * 0.5, cy = h * 0.5
        let minDim = min(w, h)
        // The web rng seeds from (heartburstSeed * 1000) >>> 0.
        let rng = mulberry32(UInt32(truncatingIfNeeded: Int((seedParam * 1000).rounded(.towardZero))))

        let dpr: CGFloat = 1.0   // host re-rasterizes at the device size already.
        let ink = max(1, CGFloat(inkWeight) * dpr)

        // STATIC snapshot pose.
        let presence: CGFloat = 1.0
        let heartScaleMul: CGFloat = 1.0   // shader pulses the hero via u.beat.
        let b: CGFloat = 0.45              // representative mid-burst flight.

        // ---- Parametric heart trace (classic 16 sin³ curve, cusp UP) ----------
        // Matches heartburst-renderer.ts `traceHeart` exactly. `s` is the half-size.
        func traceHeart(_ s: CGFloat, _ rot: CGFloat) {
            let steps = 48
            ctx.beginPath()
            for i in 0 ... steps {
                let t = (CGFloat(i) / CGFloat(steps)) * .pi * 2
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                let nx = (x / 17) * s
                let ny = (-y / 17) * s       // flip Y so lobes are at the top (canvas y-down).
                let px = nx * cos(rot) - ny * sin(rot)
                let py = nx * sin(rot) + ny * cos(rot)
                if i == 0 { ctx.move(to: CGPoint(x: px, y: py)) }
                else { ctx.addLine(to: CGPoint(x: px, y: py)) }
            }
            ctx.closePath()
        }

        // ---------- HERO HEART (R fill, G outline + gloss seed) --------------
        let heroS = minDim * CGFloat(heartScale) * heartScaleMul
        let tilt = CGFloat((seedParam.truncatingRemainder(dividingBy: 1)) - 0.5) * 0.12
        // As the burst takes over the hero shrinks a touch (web heroPresence).
        let heroPresence = presence * (1 - 0.65 * b)

        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        if heroPresence > 0.002 {
            let heroFillA = heroPresence   // 0..1 channel value.
            // FILL -> RED.
            traceHeart(heroS, tilt)
            ctx.setFillColor(red: heroFillA, green: 0, blue: 0, alpha: 1)
            ctx.fillPath()
            // OUTLINE -> GREEN.
            traceHeart(heroS, tilt)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(ink * 1.6)
            ctx.setStrokeColor(red: 0, green: heroFillA, blue: 0, alpha: 1)
            ctx.strokePath()
            // GLOSS SEED -> GREEN, clipped to the heart (upper-left lobe). The shader
            // reads ink∩fill as the specular highlight.
            ctx.saveGState()
            traceHeart(heroS, tilt)
            ctx.clip()
            let gx = -heroS * 0.34, gy = -heroS * 0.42, gr = heroS * 0.42
            let cs = CGColorSpaceCreateDeviceRGB()
            let solid: [CGFloat] = [0, heroFillA, 0, 1]
            let clear: [CGFloat] = [0, 0, 0, 0]
            let cols = [
                CGColor(colorSpace: cs, components: solid)!,
                CGColor(colorSpace: cs, components: clear)!,
            ] as CFArray
            let locs: [CGFloat] = [0, 1]
            if let grad = CGGradient(colorsSpace: cs, colors: cols, locations: locs) {
                ctx.drawRadialGradient(grad, startCenter: CGPoint(x: gx, y: gy), startRadius: 0,
                                       endCenter: CGPoint(x: gx, y: gy), endRadius: gr, options: [])
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // ---------- BURST HEARTS (B fill) ------------------------------------
        if b > 0.001 {
            let count = max(0, Int(burstCount.rounded()))
            let maxDist = minDim * CGFloat(burstSpread)
            for i in 0 ..< count {
                // deterministic per-heart launch params (web order: ang, speed, spin,
                // littleS, stagger — the rng pulls MUST stay in this order for parity).
                let ang = (CGFloat(i) / CGFloat(max(1, count))) * .pi * 2 + (CGFloat(rng()) - 0.5) * 0.9
                let speed = 0.55 + CGFloat(rng()) * 0.45
                let spin = (CGFloat(rng()) - 0.5) * 2.0
                let littleS = minDim * (0.035 + CGFloat(rng()) * 0.04) * CGFloat(heartScale) * 1.6
                let stagger = CGFloat(rng()) * 0.25
                let lp = max(0, min(1, (b - stagger) / (1 - stagger)))
                if lp <= 0 { continue }
                let dist = maxDist * speed * lp
                let arc = minDim * 0.10 * speed * (lp - lp * lp) * 4.0
                let px = cx + cos(ang) * dist
                let py = cy + sin(ang) * dist - arc
                let fade = 1 - pow(lp, 2.2)
                if fade <= 0.01 { continue }
                let a = presence * fade
                let s = littleS * (0.6 + 0.4 * (1 - lp))
                ctx.saveGState()
                ctx.translateBy(x: px, y: py)
                traceHeart(s, spin * lp * .pi)
                ctx.setFillColor(red: 0, green: 0, blue: a, alpha: 1)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }
}
#endif
