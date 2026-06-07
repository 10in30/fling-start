// Comic Impact — MSL fragment shader, ported from `comic-shader.ts`
// (GLSL ES 3.00). macOS/iOS only (compiled into the effect's metallib by the
// Swift build on an Apple toolchain; on Linux it is an inert resource).
//
// HYBRID effect: the jagged starburst + hand-lettered word + ink contours are
// drawn into ONE offscreen panel texture (`uPanel`) by the host renderer; this
// shader adds the procedural, screen-space comic-book look and casts the light:
//   1. RADIATING action / speed lines bursting from the impact centre
//   2. the STARBURST balloon fill + the word fill, shaded by a Ben-Day halftone
//   3. INK contours that carve the lit forms (black == unlit on a screen blend)
//   4. an IMPACT FLASH that throws colored light onto the page (the cast light)
// finished with a filmic (ACES) tonemap, a pop-art posterize, + an ordered dither.
//
// Everything is summed as light (presented through the `screen`-blended light
// layer; the shadow pass through a `multiply` layer), exactly as the web canvas
// is composited with `mix-blend-mode: screen`.
//
// Panel texture channel encoding (host renderer, see web comic-renderer.ts):
//   R = word FILL mask   G = INK mask   B = burst FILL mask   A = unused
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
// `comic_rot2` / `comic_benday` are the Ben-Day halftone screen — they are NOT
// in DopamineLook.metal (the shared lib notes the halftone as "unused there"),
// so they live here as this effect's bespoke shader surface (port of the GLSL
// chunks GLSL_ROT2 + GLSL_HALFTONE, kept function-for-function identical).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `ComicUniforms` struct is GENERATED from the `.dope` by
// scripts/gen-uniforms.mjs (into ComicUniforms.metal) — the SAME source that
// emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "ComicUniforms.metal"   // @generated — struct ComicUniforms
using namespace metal;

// Full-screen triangle from vertex_id (no vertex buffers). vUv (0..1, y-up) is
// passed through to the fragment, mirroring the web vertex shader.
struct VSOut { float4 position [[position]]; float2 vUv; };
vertex VSOut comic_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.vUv = pos;
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// --- Ben-Day halftone screen (port of GLSL_ROT2 + GLSL_HALFTONE). ---
// GLSL mat2(c,-s,s,c) is column-major: columns (c,-s),(s,c). MSL float2x2 takes
// columns directly, so the rotation transcribes as those two column vectors.
inline float2x2 comic_rot2(float a) {
    float s = sin(a), c = cos(a);
    return float2x2(float2(c, -s), float2(s, c));
}
// 1 inside a dot, 0 outside, antialiased. Dot RADIUS grows with tone `v`; the
// screen is rotated by `ang` (classic per-channel screen angle).
inline float comic_benday(float2 frag, float cell, float v, float ang) {
    float2 p = (comic_rot2(ang) * frag) / cell;
    float2 g = fract(p) - 0.5;
    float d = length(g);
    float r = 0.52 * sqrt(clamp(v, 0.0, 1.0));
    float aa = 0.7 / cell + fwidth(d);
    return 1.0 - smoothstep(r - aa, r + aa, d);
}

fragment float4 comic_fragment(
    VSOut in [[stage_in]],
    constant ComicUniforms &u [[buffer(0)]],
    texture2d<float> uPanel [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin (the impact centre) are bottom-left (y up). Flip y once here so the
    // whole shader works in the y-up space it was written for. vUv tracks the same
    // y-up space the host uploads the panel in.
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float2 vUv = frag / u.resolution;
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);

    // ---- SHADOW PASS (multiply layer) ---------------------------------------
    // Cheap occlusion: the panel's solid forms (word fill + burst fill) sampled
    // at an offset toward the implied key light, with a small ring blur for a
    // penumbra. White = no shadow (multiply identity); darker = cast shadow. The
    // panel already encodes presence, so the shadow fades with the effect.
    if (u.shadow > 0.5) {
        float2 px = 1.0 / res;
        float2 souv = vUv - u.shadowOffset * px;
        float occ = 0.0;
        for (int i = 0; i < 8; i++) {
            float a = float(i) / 8.0 * TAU;
            float2 o = float2(cos(a), sin(a)) * u.shadowSoft * px;
            float2 tuv = souv + o;
            // Gate samples that fall OUTSIDE the panel: the texture is
            // CLAMP_TO_EDGE, so without this an offset sample past an edge smears
            // that edge row into a phantom band. Outside == no occluder.
            float2 inb = step(float2(0.0), tuv) * step(tuv, float2(1.0));
            float mask = inb.x * inb.y;
            float4 s = uPanel.sample(texSampler, tuv);
            occ += clamp(s.r + s.b, 0.0, 1.0) * mask;
        }
        occ /= 8.0;
        float dark = clamp(occ * u.shadowStrength, 0.0, 1.0);
        return float4(float3(1.0 - dark), 1.0);
    }

    float2 fromC = frag - u.origin;
    float rad = length(fromC);
    float ang = atan2(fromC.y, fromC.x);

    float4 panel = uPanel.sample(texSampler, vUv);
    float wordFill = panel.r;
    float inkMask  = clamp(panel.g * u.inkBoost, 0.0, 1.0);
    float burstFill = panel.b;

    float3 col = float3(0.0);

    // ---- RADIATING ACTION / SPEED LINES -------------------------------------
    // Thin wedges bursting outward from the impact centre. Procedural so they're
    // crisp and cheap. They live in a ring OUTSIDE the burst balloon (so they
    // read as motion lines streaking off the hit, not hatching on the word).
    float lineN = max(u.actionLines, 1.0);
    float a01 = (ang / TAU) + 0.5;                 // 0..1 around the circle
    float idx = floor(a01 * lineN);
    // per-line random angular jitter + length so they aren't a clean fan.
    float jr = dop_hash11(idx + u.comicSeed * 3.1);
    float jr2 = dop_hash11(idx * 1.7 + u.comicSeed * 7.3);
    float cellPhase = fract(a01 * lineN);
    float wedge = abs(cellPhase - 0.5);
    // Thin tapered streaks: a sharp spine that fattens slightly outward (classic
    // motion-line wedge), kept narrow so they read as speed lines, not pie slices.
    float thick = mix(0.05, 0.14, jr);
    float lineBody = 1.0 - smoothstep(thick * 0.35, thick, wedge);
    // radial extent: lines start OUTSIDE the burst and streak outward to the edge.
    float innerR = minDim * (0.30 + 0.05 * jr2);
    float outerR = minDim * (0.46 + 0.30 * jr);
    float radialMask = smoothstep(innerR, innerR + minDim * 0.015, rad)
                     * (1.0 - smoothstep(outerR - minDim * 0.10, outerR, rad));
    // fade the lines in fast on impact, hold, then they thin out late.
    float linePresence = smoothstep(0.0, 0.06, u.life) * (1.0 - smoothstep(0.6, 1.0, u.life));
    // taper opacity along the line so the inner end is boldest (ink-streak feel).
    float taper = 1.0 - smoothstep(innerR, outerR, rad);
    float lines = lineBody * radialMask * linePresence * taper;
    // animate-on-twos flicker toward the pop end (snappy comic motion).
    float beat = floor(u.timeS * 12.0);
    float flick = mix(1.0, step(0.25, dop_hash11(idx + beat + u.comicSeed)), u.style * 0.5);
    lines *= flick;

    // Action lines cast a thin streak of light off the hit. White/cool ink at the
    // noir end (a hard glint), the accent hue at the pop end. Kept dim so they
    // read as speed lines around the panel rather than flooding the frame.
    float3 lineCol = mix(float3(0.7, 0.74, 0.82), u.c2, u.style);
    col += lineCol * lines * 0.32 * u.exposure;

    // ---- STARBURST BALLOON (behind the word) --------------------------------
    // Filled with the secondary hue; gets the strongest Ben-Day shading so it
    // reads as a flat printed color field. In noir it's a pale near-white field
    // with a fine subtle screen; in pop-art it's a saturated yellow/red blast.
    float3 burstBase = mix(float3(0.9), u.c1, u.saturation);
    // tone for the dots: more dots where the field is "darker" value. We want a
    // lively mid coverage so the classic dot field shows.
    float burstTone = mix(0.35, 0.7, u.halftone);
    float dots = comic_benday(frag, u.dotSize, burstTone, radians(15.0) + u.comicSeed);
    // Ben-Day strength: subtle at noir, dominant at pop. The dots ADD the accent
    // color on the printed field.
    float3 burstCol = burstBase + (u.c2 - burstBase) * dots * u.halftone * 0.55;
    col += burstCol * burstFill * u.presence * u.exposure;

    // A second, finer rotated screen on the word fill for that printed sheen at
    // the pop end (kept subtle so letters stay legible). The word is the HERO:
    // a bright, saturated fill that screams off the page (pop) or a luminous
    // near-white with a spot tint (noir). Brighter than the burst so it reads
    // as the foreground shout.
    float wordDots = comic_benday(frag, u.dotSize * 0.7, 0.5, radians(75.0) + u.comicSeed);
    float3 wordBright = clamp(u.c0 * 1.35 + 0.25, 0.0, 1.4);
    float3 wordBase = mix(float3(0.96, 0.97, 1.0), wordBright, clamp(u.saturation + 0.2, 0.0, 1.0));
    float3 wordCol = wordBase + (u.c2 - wordBase) * wordDots * u.halftone * 0.25 * u.style;
    // Word fill is largely PROTECTED from ink suppression (its own outline should
    // frame it, not eat it), so render it after a softened ink mask below.
    col += wordCol * wordFill * u.presence * u.exposure * 1.7;

    // ---- INK ----------------------------------------------------------------
    // Bold black contours. Ink is the ABSENCE of light on a screen-blend canvas,
    // so we can't literally darken the page from here — instead we let ink CARVE
    // the lit shapes (it suppresses the fills it overlaps) and, at the noir end,
    // we add a faint cool rim so the chiaroscuro edge still reads as light catches
    // the ink ridge. The actual black is achieved by NOT lighting those pixels.
    float ink = inkMask * u.presence;
    // Suppress fills under ink (so outlines punch through as unlit black). But
    // where the ink overlaps the WORD fill we soften the carve a lot, so the
    // outline frames the letters instead of eating their bright bodies.
    float carve = ink * (0.96 - 0.7 * wordFill);
    col *= (1.0 - carve);
    // Subtle chiaroscuro rim-light on ink edges toward the noir end (a glint).
    float rim = ink * (1.0 - u.style) * 0.18;
    col += mix(u.c2, float3(0.8, 0.85, 1.0), 0.5) * rim * u.exposure;

    // ---- IMPACT FLASH -------------------------------------------------------
    // A hot radial flash at the moment of impact that throws colored light onto
    // the page (the cast-light proof). Fast spike, quick decay (driven by uFlash).
    float flashFall = exp(-rad / (minDim * 0.42));
    float3 flashCol = mix(mix(u.c0, u.c1, 0.5), float3(1.0), 0.45 + 0.3 * u.style);
    col += flashCol * flashFall * u.flash * u.exposure * 1.4;
    // a tight white-hot core right at the centre on the very first frames.
    float core = exp(-rad / (minDim * 0.10));
    col += float3(1.0) * core * u.flash * u.flash * 1.6;

    // ---- TONE + FINISH ------------------------------------------------------
    // ACES filmic tonemap (shared look) for a cleaner highlight rolloff than the
    // old x/(1+x) compress — the impact flash highlights roll off gracefully
    // while the saturated printed mids stay rich. A mild pre-exposure keeps the
    // pop-art color from dimming.
    col = dop_tonemapACES(col * 0.85);

    // Pop-art posterize: snap the lit panel to a few flat ink levels toward the
    // pop end (flat printed color), leaving the dark page untouched so we don't
    // shatter it into camouflage. Noir stays smooth chiaroscuro.
    if (u.style > 0.001) {
        float lit = smoothstep(0.02, 0.2, max(max(col.r, col.g), col.b));
        float3 q = floor(col * 4.0 + 0.5) / 4.0;
        col = mix(col, mix(col, q, lit), u.style * 0.7);
    }

    // Ordered dither (shared look) to kill banding the screen-blend reveals
    // (faded toward the pop end where the flat printed look is intended).
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style * 0.7);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark
    // regions become transparent so the UI beneath shows through, and bright
    // cast light reads over it. The web returns alpha=1 onto a screen-blended
    // canvas; on the Metal screen-blend light layer we mirror Solarbloom and
    // emit alpha = max channel so col_channel <= alpha holds (valid premultiplied).
    float3 outCol = max(col, 0.0);
    float outA = clamp(max(max(outCol.r, outCol.g), outCol.b), 0.0, 1.0);
    return float4(outCol, outA);
}
