// Comic Impact — the offscreen Canvas2D PANEL, ported to Core Graphics / Core
// Text as a `PanelDrawing` conformance on `ComicConfig`.
//
// HYBRID effect: the crisp vector forms (the jagged starburst balloon, the
// blocky onomatopoeia word, the bold ink contours) are NOT procedural in the
// shader — the web draws them into an offscreen Canvas2D ("panel") and the
// fragment shader (Comic.metal) samples that texture and adds the Ben-Day
// halftone / action lines / flash / pop-art look on top. The Swift backbone owns
// the panel runner (MetalOverlayHost builds + uploads it in `prepare()` from any
// config that conforms to `PanelDrawing`); this file supplies ONLY the per-effect
// draw, a faithful port of `packages/effect-comic/src/comic-renderer.ts`.
//
// PANEL CHANNEL ENCODING (must match Comic.metal exactly):
//   R = word FILL mask   G = INK mask   B = burst FILL mask   A = unused
// The shader samples the panel at fragment texture(0), sampler(0), in a y-up vUv;
// the host flips the CGContext to a TOP-LEFT origin so this draw matches the web
// Canvas2D coordinate space verbatim (y-down, origin top-left).
//
// STATIC-SNAPSHOT SIMPLIFICATION: the web redraws the panel every frame with the
// live slam `scale` + `presence`; the Swift backbone builds the panel ONCE in
// `prepare()`. So we bake it at the fully-landed slam (scale = 1, presence = 1) —
// the shader still animates the slam in/flash/halftone via its uniforms, so the
// motion reads; only the panel geometry is frozen at its rest pose (which is what
// is on screen for the long hold anyway).
//
// TYPOGRAPHY SIMPLIFICATION: the web resolves a mood-picked bundled display face
// (Bangers / Anton / Luckiest Guy) plus per-letter skew/stretch/tilt/bounce. That
// font + typography pipeline is host-side and does not port cleanly without the
// embedded faces, so here we render the word with a bold system font sized to fit
// the burst, drawn as filled + stroked glyph runs (fill -> R, ink contour -> G).
// The word itself is still the SAME seed-picked token the effect would choose
// (`pickFromList(pool, comicSeed*1000)`), so the content matches the web.

#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import DopamineCore

#if canImport(CoreText)
import CoreText
#endif

extension ComicConfig: PanelDrawing {
    /// The per-fire SLAMMED token pool — the comic.dope `content.pool` (the seven
    /// affirmations + the checkmark sentinel, equal odds). Kept in sync with the
    /// `.dope`; reskinning the word list is a `.dope` edit on the `Comic` factory
    /// (this static mirror only feeds the host-side panel draw).
    static let wordPool: [String] = ["YES!", "DONE!", "NICE!", "OKAY!", "WIN!", "GREAT!", "WOO!", "✓"]

    // The whole canvas — the panel is a full-frame overlay (web `panelSizePx`).
    public func panelSizePx(canvasPx: CGSize, params: [String: DopeValue]) -> CGSize { canvasPx }

    public func drawPanel(_ ctx: CGContext, sizePx: CGSize, params: [String: DopeValue]) {
        let w = sizePx.width, h = sizePx.height
        guard w > 1, h > 1 else { return }

        // Resolved-bag scalars (defaults mirror comic.dope authored ranges).
        func num(_ k: String, _ d: Double) -> Double {
            if case let .number(v)? = params[k] { return v }; return d
        }
        let comicSeed   = num("comicSeed", 0)
        let rawSeed     = num("seed", 0)   // the raw fire seed (word pick uses this)
        let scaleParam  = num("scale", 0.34)
        let burstPoints = num("burstPoints", 14)
        let inkWeight   = num("inkWeight", 3)

        // STATIC snapshot at the fully-landed slam.
        let presence: CGFloat = 1.0
        let slamScale: CGFloat = 1.0
        let dpr: CGFloat = 1.0   // the host re-rasterizes at the device size already.

        // The web draws every layer with `globalCompositeOperation = "lighter"`
        // (additive) so the R/G/B channel masks accumulate INDEPENDENTLY — a red
        // word fill must not zero the blue burst it overlaps. `.plusLighter` is the
        // Core Graphics equivalent; set once for the whole panel.
        ctx.setBlendMode(.plusLighter)

        let cx = w * 0.5, cy = h * 0.5
        let minDim = min(w, h)
        // The web rng seeds the burst jitter from (comicSeed * 1000) >>> 0.
        let rng = mulberry32(UInt32(truncatingIfNeeded: Int((comicSeed * 1000).rounded(.towardZero))))

        // Per-fire tilt, hand-placed feel (~±5deg) — web `(comicSeed % 1 - 0.5)*0.18`.
        let tilt = CGFloat((comicSeed.truncatingRemainder(dividingBy: 1)) - 0.5) * 0.18

        // ---------- STARBURST BALLOON (B fill + G outline) -------------------
        let points = max(8, Int(burstPoints.rounded()))
        let outerR = minDim * CGFloat(scaleParam) * 1.3 * slamScale
        let innerR = outerR * 0.64
        var burstPts: [CGPoint] = []
        burstPts.reserveCapacity(points * 2)
        for i in 0 ..< (points * 2) {
            let t = CGFloat(i) / CGFloat(points * 2)
            let a = t * .pi * 2 - .pi / 2 + tilt
            let even = (i % 2 == 0)
            let jitter = 0.82 + CGFloat(rng()) * 0.36
            let r = (even ? outerR : innerR) * jitter
            burstPts.append(CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r))
        }
        func tracePath() {
            ctx.beginPath()
            for (i, p) in burstPts.enumerated() {
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.closePath()
        }

        let ink = CGFloat(inkWeight) * dpr * slamScale
        let fillA = presence  // 0..1 channel value at full presence.

        // Burst FILL -> BLUE.
        ctx.saveGState()
        tracePath()
        ctx.setFillColor(red: 0, green: 0, blue: fillA, alpha: 1)
        ctx.fillPath()
        ctx.restoreGState()

        // Burst OUTLINE -> GREEN (ink).
        ctx.saveGState()
        ctx.setLineJoin(.miter)
        ctx.setMiterLimit(2)
        tracePath()
        ctx.setLineWidth(ink * 1.3)
        ctx.setStrokeColor(red: 0, green: fillA, blue: 0, alpha: 1)
        ctx.strokePath()
        ctx.restoreGState()

        // ---------- WORD / CHECKMARK -----------------------------------------
        // The seed-picked token. The web picks with the RAW fire seed
        // (`pickFromList(pool, feeling.seed)`), NOT the scatter offset. The pool is
        // the comic.dope `content.pool` (words + the checkmark sentinel, equal odds);
        // mirrored here verbatim so the panel content matches the effect's word.
        let pool = ComicConfig.wordPool
        let word = pickFromList(pool, seed: UInt32(truncatingIfNeeded: Int(rawSeed.rounded(.towardZero))))
        let inkColor = CGColor(red: 0, green: fillA, blue: 0, alpha: 1)
        let fillColor = CGColor(red: fillA, green: 0, blue: 0, alpha: 1)

        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        if tilt != 0 { ctx.rotate(by: tilt) }
        ctx.setLineJoin(.miter)
        ctx.setMiterLimit(2)

        if word == "✓" {
            // ----- VECTOR CHECKMARK (web isCheckmark path) --------------------
            let span = innerR * 1.25
            let strokeW = span * 0.24 * 0.85
            let pts: [CGPoint] = [
                CGPoint(x: -span * 0.42, y: span * 0.02),
                CGPoint(x: -span * 0.12, y: span * 0.34),
                CGPoint(x:  span * 0.46, y: -span * 0.36),
            ]
            func traceCheck() {
                ctx.beginPath()
                for (i, p) in pts.enumerated() { i == 0 ? ctx.move(to: p) : ctx.addLine(to: p) }
            }
            // Bold ink contour, then bright fill body (both stroked).
            traceCheck()
            ctx.setLineWidth(strokeW + ink * 1.2)
            ctx.setStrokeColor(inkColor)
            ctx.strokePath()
            traceCheck()
            ctx.setLineWidth(strokeW)
            ctx.setStrokeColor(fillColor)
            ctx.strokePath()
            ctx.restoreGState()
            return
        }

        #if canImport(CoreText)
        // ----- WORD RUN (bold system font, shrink-to-fit) ---------------------
        // Target size then shrink so longer words never spill the burst.
        var fontPx = minDim * CGFloat(scaleParam) * 0.92 * slamScale
        let maxW = innerR * 1.7
        // Simplification (documented in the file header): a reliable bold system
        // face stands in for the web's mood-picked bundled display faces.
        func makeRun(_ px: CGFloat) -> CTLine {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, px, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fillColor,
            ]
            let s = NSAttributedString(string: word, attributes: attrs)
            return CTLineCreateWithAttributedString(s)
        }
        var line = makeRun(fontPx)
        var bounds = CTLineGetImageBounds(line, ctx)
        if bounds.width > maxW, bounds.width > 0 {
            fontPx *= maxW / bounds.width
            line = makeRun(fontPx)
            bounds = CTLineGetImageBounds(line, ctx)
        }
        let inkLine = ink * 1.3

        // The host flipped the CGContext to a TOP-LEFT (y-down) origin to match
        // Canvas2D. Core Text glyph outlines + CTLineDraw assume a y-UP space, so
        // flip y back locally for the text block (then it draws right-side-up).
        ctx.saveGState()
        ctx.scaleBy(x: 1, y: -1)

        // Center the run in the now-y-up space (bounds are in that space).
        let originX = -bounds.width / 2 - bounds.origin.x
        let originY = -bounds.height / 2 - bounds.origin.y

        // INK contour: stroke the glyph paths into GREEN under the fill.
        let runs = CTLineGetGlyphRuns(line) as NSArray
        ctx.saveGState()
        ctx.translateBy(x: originX, y: originY)
        for r in runs {
            let run = r as! CTRun
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let fontVal = attrs[kCTFontAttributeName as String],
                  CFGetTypeID(fontVal as CFTypeRef) == CTFontGetTypeID() else { continue }
            let f = fontVal as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var posns = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, n), &posns)
            for i in 0 ..< n {
                guard let path = CTFontCreatePathForGlyph(f, glyphs[i], nil) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: posns[i].x, y: posns[i].y)
                ctx.addPath(path)
                ctx.setLineWidth(inkLine)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(inkColor)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()

        // Bright FILL body on top (RED). CTLine uses its foreground color = fillColor.
        ctx.textPosition = CGPoint(x: originX, y: originY)
        CTLineDraw(line, ctx)

        ctx.restoreGState()   // undo the y-flip for the text block.
        #endif

        ctx.restoreGState()
    }
}
#endif
