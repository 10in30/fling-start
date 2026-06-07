// Fail / error — MSL fragment shader, ported from `fail-shader.ts` (GLSL ES
// 3.00). macOS/iOS only (compiled into the effect's metallib by the Swift build
// on an Apple toolchain; on Linux it is an inert resource).
//
// The emotional OPPOSITE of the three success effects: a red/amber ✗ cross is
// STAMPED in light over a tight, recoiling error flare; the whole frame
// desaturates and collapses fast. One full-screen pass renders, all summed as
// light (presented through the `screen`-blended light layer; the shadow pass
// through a `multiply` layer):
//   1. a tight, angry error flare around the cross (collapses with amp)
//   2. the ✗ cross, stamped in light along a diagonal slash (baked-SDF / analytic)
//   3. a hot stamp FLASH at the instant of impact
// finished with a filmic (ACES) tonemap, an optional stylized GLITCH/desaturate
// collapse (whimsy), and an ordered dither.
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `FailUniforms` struct is GENERATED from the `.dope` by
// scripts/gen-uniforms.mjs (into FailUniforms.metal) — the SAME source that emits
// the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "FailUniforms.metal"   // @generated — struct FailUniforms
using namespace metal;

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut fail_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Map a device-pixel sample to the SDF box UV (origin bottom-left, y up).
inline float2 boxUV(float2 frag, constant FailUniforms &u) {
    return (frag - u.origin) / (2.0 * u.boxPx) + 0.5;
}

// ✗ stroke distance (device px) from the baked SDF, or an analytic two-bar
// fallback when no SDF is bound. Both reveal as a fast diagonal "slash" stamp.
inline float crossDist(float2 frag, constant FailUniforms &u,
                       texture2d<float> sdfTex, sampler texSampler) {
    if (u.sdfOn > 0.5) {
        float2 uv = boxUV(frag, u);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1e9;
        return sdfTex.sample(texSampler, uv).r * u.sdfRangePx;
    }
    // Analytic ✗: two diagonal bars (fallback if the SDF failed to bake/load).
    float r = u.boxPx * 0.62;
    float2 a1 = u.origin + float2(-r, -r), b1 = u.origin + float2(r, r);
    float2 a2 = u.origin + float2(-r,  r), b2 = u.origin + float2(r, -r);
    return min(dop_sdSeg(frag, a1, b1), dop_sdSeg(frag, a2, b2));
}

// The ✗ is stamped along a diagonal slash: the \ bar reveals first, then the /.
// Returns a 0..1 reveal gate at this point given the stamp progress.
inline float stampGate(float2 frag, constant FailUniforms &u) {
    float2 uv = boxUV(frag, u) - 0.5;       // -0.5..0.5
    // Slash axis: lower-left -> upper-right then the second bar. Use |.| so both
    // diagonals fill outward from the center as the stamp lands.
    float axis = clamp(0.5 + 0.5 * (abs(uv.x) + abs(uv.y)), 0.0, 1.0);
    float frontier = u.stamp * 1.15;
    return smoothstep(frontier, frontier - 0.12, axis);
}

// Tight angry error flare around the cross — collapses with amp. Hotter +
// larger with severity. Unlike the bloom, this stays compact and punchy.
inline float flare(float2 frag, float minDim, constant FailUniforms &u) {
    float d = length(frag - u.origin);
    float r = minDim * mix(0.16, 0.30, u.severity);
    float dn = d / r;
    return (exp(-dn * dn * 2.2) * 0.9 + exp(-dn * 1.6) * 0.25);
}

inline float occlusion(float2 p, float minDim, constant FailUniforms &u,
                       texture2d<float> sdfTex, sampler texSampler) {
    float occ = flare(p, minDim, u) * 0.7;
    float dc = crossDist(p, u, sdfTex, texSampler);
    occ += (1.0 - smoothstep(u.sdfStrokePx * 0.6, u.sdfStrokePx * 1.5, dc)) * stampGate(p, u) * 0.9;
    return clamp(occ * u.amp, 0.0, 1.0);
}

inline float4 shadowColor(float2 frag, constant FailUniforms &u,
                          texture2d<float> sdfTex, sampler texSampler) {
    float minDim = min(u.resolution.x, u.resolution.y);
    float2 sp = frag - u.shadowOffset;
    float occ = occlusion(sp, minDim, u, sdfTex, texSampler);
    float s = u.shadowSoft;
    occ += occlusion(sp + float2(s, 0.0), minDim, u, sdfTex, texSampler);
    occ += occlusion(sp + float2(-s, 0.0), minDim, u, sdfTex, texSampler);
    occ += occlusion(sp + float2(0.0, s), minDim, u, sdfTex, texSampler);
    occ += occlusion(sp + float2(0.0, -s), minDim, u, sdfTex, texSampler);
    occ /= 5.0;
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength;
    // A cold, slightly desaturated shadow tint (error grey, not coloured glow).
    float3 tint = mix(float3(1.0), float3(0.72, 0.66, 0.66), 1.0);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 fail_fragment(
    VSOut in [[stage_in]],
    constant FailUniforms &u [[buffer(0)]],
    texture2d<float> sdfTex [[texture(1)]],
    sampler texSampler [[sampler(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin are bottom-left (y up). Flip y once here so the whole shader works
    // in the y-up space it was written for (otherwise the ✗ + flare render
    // upside down).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float minDim = min(u.resolution.x, u.resolution.y);

    if (u.shadow > 0.5) {
        return shadowColor(frag, u, sdfTex, texSampler);
    }

    // Recoil SHAKE: jitter the whole sample horizontally (a "no" head-shake), plus
    // a per-frame glitch slice offset toward the stylized end.
    float shakePx = u.shake * minDim * 0.012;
    float glitch = 0.0;
    if (u.style > 0.001) {
        float band = floor(frag.y / max(2.0, minDim * 0.02));
        float g = dop_hash11(band + floor(u.timeS * 30.0));
        glitch = (step(0.82, g) * (g - 0.82) / 0.18) * minDim * 0.05 * u.style * u.amp;
    }
    float2 sf = frag - float2(shakePx + glitch, 0.0);

    float3 col = float3(0.0);

    // ---- Angry error flare (summed as light) --------------------------------
    // The error palette is generated OKLCH biased to reds/ambers; we keep the
    // flare IN-BAND by ramping the HOT core hue (u.c0) from bright at the center
    // to a deeper ember toward the rim (instead of fanning to the golden-angle
    // stops, which would drift out of the error band). u.c0 still varies per fire.
    float fl = flare(sf, minDim, u);
    float rn = clamp(length(sf - u.origin) / (minDim * 0.3), 0.0, 1.0);
    float3 ember = u.c0 * mix(1.0, 0.45, rn);       // bright core → deep ember rim
    col += ember * fl * u.amp * u.exposure * mix(0.9, 1.25, u.severity);

    // ---- The ✗ cross, stamped in light --------------------------------------
    float dc = crossDist(sf, u, sdfTex, texSampler);
    float gate = stampGate(sf, u);
    float sw = u.sdfStrokePx;
    float soft = smoothstep(sw, sw * 0.3, dc);
    float hard = 1.0 - smoothstep(sw * 0.85, sw, dc);
    float core = mix(soft, hard, u.style) * gate;
    float rim = exp(-dc / (sw * 2.2)) * 0.7 * gate;
    // The cross is the unambiguous "no" — it must out-shine the flare. Hot white
    // core biased toward the error hue; a sharp rim sells the stamp.
    float3 crossTint = mix(float3(1.0), u.c0 + 0.35, 0.5);
    float collapse = 1.0 - smoothstep(0.6, 1.0, u.life);
    col += (float3(1.0) * core * 1.7 + crossTint * rim) * collapse * u.exposure;

    // A hot stamp FLASH at the instant of impact (first ~1/3 of the stamp).
    float flash = exp(-u.stamp * 6.0) * (1.0 - u.stamp);
    col += crossTint * flash * core * 1.2 * u.exposure;

    // ---- Filmic tonemap -----------------------------------------------------
    col = dop_tonemapACES(col * 0.7);

    // ---- Stylized GLITCH / DESATURATE collapse (whimsy) ----------------------
    if (u.style > 0.001) {
        // RGB split along the shake axis.
        float sep = minDim * 0.004 * u.style * u.amp;
        float dr = crossDist(sf - float2(sep, 0.0), u, sdfTex, texSampler);
        float db = crossDist(sf + float2(sep, 0.0), u, sdfTex, texSampler);
        float gr = (1.0 - smoothstep(sw * 0.85, sw, dr)) * gate * collapse;
        float gb = (1.0 - smoothstep(sw * 0.85, sw, db)) * gate * collapse;
        col.r = max(col.r, gr * 1.2 * u.exposure);
        col.b = max(col.b, gb * 1.2 * u.exposure);
        // Desaturate the whole frame toward a sick grey as it collapses.
        float l = dot(col, float3(0.299, 0.587, 0.114));
        col = mix(col, float3(l), u.style * 0.5 * smoothstep(0.4, 1.0, u.life));
        // Scanlines.
        float scan = 0.92 + 0.08 * sin(frag.y * 3.14159);
        col *= mix(1.0, scan, u.style * 0.6);
    }

    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);
    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. The web
    // returns vec4(col, 1.0) and `screen`-blends at the canvas layer; Core
    // Animation has no layer-level `screen`, so (mirroring Solarbloom) we emit
    // premultiplied alpha through the runner's screen-blend pipeline. Dark
    // regions become transparent so the UI beneath shows through, and the hot
    // flare/✗ read as cast light over it. col is the emitted light, so
    // col_channel <= max(col) = alpha holds → valid premultiplied.
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
