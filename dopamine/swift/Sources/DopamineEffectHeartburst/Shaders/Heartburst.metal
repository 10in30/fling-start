// Heartburst — MSL fragment shader, ported from `heartburst-shader.ts`
// (GLSL ES 3.00). macOS/iOS only (compiled into the effect's metallib by the
// Swift build on an Apple toolchain; on Linux it is an inert resource).
//
// HYBRID (Canvas2D-panel) effect: the crisp vector hearts — the big hero heart
// and the little burst hearts — are drawn with a parametric heart curve into an
// OFFSCREEN Canvas2D each frame (heartburst-renderer.ts; the genuinely
// code-shaped JS that does NOT port to MSL) and handed to this shader as ONE
// "panel" texture. This shader then does everything that wants to be procedural /
// screen-space, all summed as light (presented through the `screen`-blended light
// layer; the shadow pass through a `multiply` layer):
//   1. a soft warm BLOOM behind the heart (the love glow)
//   2. the HERO HEART body with a vertical light→shade gradient + gloss highlight
//   3. the BURST flurry of little hearts lit + sparkling as they fly out
//   4. the INK / CONTOUR carve, the NOIR↔POP cel styling, the beat/burst FLASH
// finished with a filmic (ACES) tonemap + cel posterize + an ordered dither.
//
// Panel texture channel encoding (see heartburst-renderer.ts):
//   R = hero heart FILL mask  (the big swelling heart's interior)
//   G = INK / contour mask    (heart outline + the gloss seed highlight)
//   B = burst hearts FILL     (all the little flying hearts)
//   A = unused
//
// The shared building blocks come from DopamineLook.metal (one canonical copy);
// the Ben-Day halftone (`benday`/`rot2`) is NOT in that shared file (Solarbloom
// never used it), so its two helpers are transcribed locally here as
// `dop_benday`/`dop_rot2` (GLSL `look/glsl.ts` GLSL_HALFTONE + GLSL_ROT2).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `HeartburstUniforms` struct is GENERATED from the `.dope`
// by scripts/gen-uniforms.mjs (into HeartburstUniforms.metal) — the SAME source
// that emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "HeartburstUniforms.metal"   // @generated — struct HeartburstUniforms
using namespace metal;

// Ring-blur taps for the shadow occlusion + the inner-rim self-shadow. Mirrors
// the web `for (int i = 0; i < 8/6; i++)` loops (panel is the geometry, so there
// is no particle cap; these are the only fixed iteration counts).
#define SHADOW_TAPS 8
#define RIM_TAPS    6

// --- Ben-Day halftone (look/glsl GLSL_ROT2 + GLSL_HALFTONE), local to this
// effect because the shared DopamineLook.metal omits it (Solarbloom never used
// it). GLSL `mat2(c,-s,s,c)` is COLUMN-major: columns (c,-s),(s,c) → MSL
// float2x2 takes columns directly. ---
inline float2x2 dop_rot2(float a) {
    float s = sin(a), c = cos(a);
    return float2x2(float2(c, -s), float2(s, c));
}
inline float dop_benday(float2 frag, float cell, float v, float ang) {
    float2 p = (dop_rot2(ang) * frag) / cell;
    float2 g = fract(p) - 0.5;
    float d = length(g);
    float r = 0.52 * sqrt(clamp(v, 0.0, 1.0));
    float aa = 0.7 / cell + fwidth(d);
    return 1.0 - smoothstep(r - aa, r + aa, d);
}

// Full-screen triangle from vertex_id (no vertex buffers). `vUv` is the 0..1
// panel sample coordinate (matches the web vertex `vUv = pos`).
struct VSOut { float4 position [[position]]; float2 vUv; };
vertex VSOut heartburst_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.vUv = pos;
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 heartburst_fragment(
    VSOut in [[stage_in]],
    constant HeartburstUniforms &u [[buffer(0)]],
    texture2d<float> panel [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin (the heart centre) are bottom-left (y up). The web sampled the
    // panel in vUv (0..1, y-up from the vertex). Build a y-up `vUv` so the whole
    // shader works in the space it was written for (otherwise the heart + its
    // vertical light→shade gradient render upside down).
    float2 vUv = float2(in.vUv.x, in.vUv.y);
    float2 res = u.resolution;
    float2 frag = vUv * res;
    float minDim = min(res.x, res.y);

    // ---- SHADOW PASS (multiply layer) ---------------------------------------
    // Cheap occlusion: the panel's solid forms (hero + burst fills) sampled at an
    // offset toward the implied key light, with a small ring blur for a penumbra.
    // White = no shadow (multiply identity); darker = cast shadow. Presence fades
    // it with the effect.
    if (u.shadow > 0.5) {
        float2 px = 1.0 / res;
        float2 souv = vUv - u.shadowOffset * px;
        float occ = 0.0;
        for (int i = 0; i < SHADOW_TAPS; i++) {
            float a = float(i) / float(SHADOW_TAPS) * TAU;
            float2 o = float2(cos(a), sin(a)) * u.shadowSoft * px;
            float2 tuv = souv + o;
            float2 inb = step(float2(0.0), tuv) * step(tuv, float2(1.0));
            float mask = inb.x * inb.y;
            float4 s = panel.sample(texSampler, tuv);
            occ += clamp(s.r + s.b, 0.0, 1.0) * mask;
        }
        occ /= float(SHADOW_TAPS);
        float dark = clamp(occ * u.shadowStrength, 0.0, 1.0);
        return float4(float3(1.0 - dark), 1.0);
    }

    float2 fromC = frag - u.origin;
    float rad = length(fromC);

    float4 panelTex = panel.sample(texSampler, vUv);
    float heartFill = panelTex.r;
    float ink = panelTex.g;
    float burstFill = panelTex.b;

    float3 col = float3(0.0);

    // ---- SOFT BLOOM behind the heart (the love glow) ------------------------
    // A warm radial glow centred on the heart, pulsing with the beat + flaring on
    // the burst. Sampled as a smooth falloff so it reads as light blooming behind
    // the form, not a hard disc. Warmer (toward u.c2) as it goes pop.
    float glowR = minDim * (0.18 + 0.30 * u.glow) * (1.0 + 0.25 * u.beat);
    float bloom = exp(-rad / glowR);
    float bloomAmp = (0.35 + 0.65 * u.beat) * (0.6 + 0.8 * u.burst * (1.0 - u.burst) * 3.0);
    float3 glowCol = mix(u.c0, u.c2, 0.45 + 0.3 * u.saturation);
    col += glowCol * bloom * bloomAmp * u.presence * u.glow * u.exposure * 0.9;

    // ---- HERO HEART ---------------------------------------------------------
    // The big swelling heart. A rich warm body with a vertical light→shade
    // gradient (top catches the key light). Photoreal end: smooth gradient + a
    // tight gloss highlight. Pop end: flatter, more saturated, with a halftone
    // blush and a crisp rim.
    // Vertical shading term: 1 at the top of the panel, 0 at the bottom.
    float vshade = clamp(1.0 - vUv.y, 0.0, 1.0);
    float3 bodyLit  = mix(u.c1, u.c0, 0.35 + 0.65 * u.saturation);        // mid body
    float3 bodyHi   = clamp(bodyLit * 1.5 + 0.18, 0.0, 1.6);             // lit top
    float3 bodyLow  = bodyLit * 0.55;                                    // shaded base
    // Photoreal: smooth top→bottom gradient. Cel: snap to two flat zones.
    float g = smoothstep(0.15, 0.95, vshade);
    float gCel = step(0.5, vshade);
    float grad = mix(g, gCel, u.style);
    float3 heartCol = mix(bodyLow, bodyHi, grad);

    // Soft inner-rim self-shadow toward the silhouette so the form reads round
    // (photoreal); fades out toward the flat cel sticker.
    // (We approximate the rim from how isolated the fill is via a small blur.)
    float edge = 0.0;
    {
        float2 px = 1.0 / res;
        for (int i = 0; i < RIM_TAPS; i++) {
            float a = float(i) / float(RIM_TAPS) * TAU;
            edge += panel.sample(texSampler, vUv + float2(cos(a), sin(a)) * px * 3.0).r;
        }
        edge /= float(RIM_TAPS);
    }
    float rimDark = clamp((heartFill - edge), 0.0, 1.0); // bright near the outline
    heartCol *= 1.0 - rimDark * 0.5 * (1.0 - u.style);

    // Halftone blush on the heart toward the pop end (printed sticker shading).
    float blush = dop_benday(frag, u.dotSize, mix(0.35, 0.6, u.halftone), radians(20.0) + u.heartburstSeed);
    heartCol += (u.c2 - heartCol) * blush * u.halftone * u.style * 0.28;

    col += heartCol * heartFill * u.presence * u.exposure * 1.6;

    // GLOSS: a tight specular highlight near the upper-left of the heart at the
    // photoreal end (a glassy gel-heart). Seeded by the ink-channel highlight blob
    // the renderer paints, modulated up by the beat (the heart "shines" as it
    // thumps). Vanishes toward the flat cel end.
    float gloss = ink * heartFill;          // ink highlight that sits ON the fill
    float glossAmt = u.gloss * (1.0 - u.style) * (0.6 + 0.6 * u.beat);
    col += float3(1.0) * gloss * glossAmt * u.presence * 1.4;

    // ---- BURST: the flurry of little hearts ---------------------------------
    // Drawn fully in the panel (positions/arc/scale computed in JS for crisp
    // vector hearts). Here we just light them — saturated warm fills with a soft
    // self-glow, fading as they fly out (u.burst late => dimmer).
    float burstFade = 1.0 - smoothstep(0.55, 1.0, u.burst);
    float3 littleCol = mix(u.c1, u.c2, 0.3 + 0.4 * u.saturation);
    littleCol = clamp(littleCol * 1.25 + 0.1, 0.0, 1.5);
    col += littleCol * burstFill * u.presence * burstFade * u.exposure * 1.5;
    // a soft sparkle bloom around the little hearts so they twinkle as they go.
    col += littleCol * burstFill * 0.4 * burstFade * (0.5 + 0.5 * sin(u.timeS * 30.0 + u.heartburstSeed));

    // ---- INK / CONTOUR ------------------------------------------------------
    // Bold outline. On a screen-blend canvas ink is the ABSENCE of light, so the
    // contour CARVES the lit shapes (reads as a dark outline) — strongest toward
    // the flat cel sticker (a clean black keyline), softer at the photoreal end.
    // The gloss seed (ink ON the fill) is NOT carved (handled above as highlight).
    float contour = ink * (1.0 - heartFill);  // outline pixels only
    float carve = contour * u.presence * mix(0.45, 0.95, u.style);
    col *= (1.0 - carve);

    // ---- BEAT / BURST FLASH -------------------------------------------------
    // A warm flash that throws colored light onto the page on each thump and at
    // the burst. Fast spike (driven by u.flash), warm core.
    float flashFall = exp(-rad / (minDim * 0.40));
    float3 flashCol = mix(u.c0, float3(1.0, 0.85, 0.8), 0.4 + 0.25 * u.style);
    col += flashCol * flashFall * u.flash * u.exposure * 1.2;
    // tiny white-hot core at the very centre on the strongest beats.
    float core = exp(-rad / (minDim * 0.08));
    col += float3(1.0, 0.92, 0.9) * core * u.flash * u.beat * 1.3;

    // ---- TONE + FINISH ------------------------------------------------------
    col = dop_tonemapACES(col * 0.9);

    // Cel posterize toward the pop/sticker end (flat printed color); leaves the
    // dark page untouched so we don't shatter it.
    if (u.style > 0.001) {
        float lit = smoothstep(0.02, 0.2, max(max(col.r, col.g), col.b));
        float3 q = floor(col * 4.0 + 0.5) / 4.0;
        col = mix(col, mix(col, q, lit), u.style * 0.7);
    }

    // Ordered dither to kill banding the screen blend reveals (faded toward cel).
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style * 0.7);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark
    // regions become transparent so the UI beneath shows through, and bright
    // bloom/heart reads as cast light over it (the web returned opaque alpha=1
    // into its own black `screen` canvas; on the Metal layer alpha must be the
    // emitted brightness so the overlay does not paint black over the card). col
    // is the emitted light, so col_channel <= max(col) = alpha holds → valid
    // premultiplied.
    col = max(col, 0.0);
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
