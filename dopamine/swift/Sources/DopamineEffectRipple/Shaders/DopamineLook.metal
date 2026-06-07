// Shared MSL "look" library — the Metal mirror of `engine/look/glsl.ts` (+ the
// particle chunk from `look/particles.glsl.ts`).
//
// The web ships ONE canonical GLSL copy of each building block (fbm/domain-warp,
// the 3-stop palette mix, the IQ-cosine iridescence, the dispersion amount, the
// segment SDF, the ACES tonemap, the ordered dither, the particle sprite) so
// every shader composes the SAME function instead of a private fork. This file
// is that canonical copy in MSL, kept FUNCTION-FOR-FUNCTION identical so adopting
// it changes no effect's look — it only removes duplication.
//
// PORT DIVERGENCES (GLSL→MSL), report (c):
//   - `mat2(a,b,c,d)` is COLUMN-major in GLSL; MSL `float2x2(c0, c1)` takes
//     COLUMNS, so the rotation matrices are transcribed as column vectors.
//   - GLSL `mix/fract/clamp` → MSL `mix/fract/clamp` (same), `inversesqrt` etc.
//     unchanged. `texture(samp, uv)` → `tex.sample(s, uv)` (done in the shader).
//   - `fwidth` exists in MSL (`fwidth`), used only by the (unused-here) halftone.
//   - GLSL implicit `float`/`vec` promotion is stricter in MSL; literals are
//     written with explicit `float()` where needed.
//
// The palette-mix reads the three palette stops from the per-effect uniform
// struct; we pass them in as args (uC0/uC1/uC2) to keep this file effect-neutral.

#include <metal_stdlib>
using namespace metal;

constant float TAU = 6.28318530718;

// --- Hash helpers (Dave Hoskins style) — hash11 (1→1), hash21 (1→2). ---
inline float dop_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}
inline float2 dop_hash21(float p) {
    float3 p3 = fract(float3(p) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// --- Value noise + 4-octave fbm with per-octave rotation. ---
inline float dop_vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = dop_hash11(dot(i, float2(1.0, 57.0)));
    float b = dop_hash11(dot(i + float2(1.0, 0.0), float2(1.0, 57.0)));
    float c = dop_hash11(dot(i + float2(0.0, 1.0), float2(1.0, 57.0)));
    float d = dop_hash11(dot(i + float2(1.0, 1.0), float2(1.0, 57.0)));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
inline float dop_fbm(float2 p) {
    float s = 0.0, a = 0.5;
    // GLSL mat2(0.80,-0.60, 0.60,0.80) is column-major: columns (0.80,-0.60),
    // (0.60,0.80). MSL float2x2 takes columns directly.
    float2x2 rot = float2x2(float2(0.80, -0.60), float2(0.60, 0.80));
    for (int i = 0; i < 4; i++) { s += a * dop_vnoise(p); p = (rot * p) * 2.03; a *= 0.5; }
    return s;
}

// --- Two-level domain warp — the smoke-like living interior. ---
inline float dop_domainWarp(float2 p, float t, float amount) {
    float2 warp = float2(dop_fbm(p + t * 0.18), dop_fbm(p.yx - t * 0.12)) - 0.5;
    return dop_fbm(p + warp * 1.2 * amount + t * 0.25);
}

// --- 3-stop palette mix (inner→mid→outer). Stops passed in. ---
inline float3 dop_paletteMix(float t, float3 c0, float3 c1, float3 c2) {
    t = clamp(t, 0.0, 1.0);
    return t < 0.5 ? mix(c0, c1, t * 2.0) : mix(c1, c2, (t - 0.5) * 2.0);
}

// --- IQ cosine palette — thin-film iridescence. ---
inline float3 dop_iridescent(float t) {
    return 0.55 + 0.45 * cos(TAU * (float3(1.0) * t + float3(0.0, 0.33, 0.67)));
}

// --- Spectral dispersion amount at a refractive edge. ---
inline float dop_dispersionAmount(float strength, float dn, float amp) {
    return strength * (0.06 + 0.12 * smoothstep(0.2, 1.1, dn)) * (0.7 + 0.5 * amp);
}

// --- Capsule/segment SDF (guards zero-length segments). ---
inline float dop_sdSeg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-3), 0.0, 1.0);
    return length(pa - ba * h);
}

// --- ACES filmic tonemap (Narkowicz). ---
inline float3 dop_tonemapACES(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// --- Ordered/triangular-hash dither, ~1/255. ---
inline float3 dop_ditherAdd(float3 col, float2 frag, float t, float fade) {
    float dz = dop_hash11(dot(frag, float2(12.989, 78.233)) + t) - 0.5;
    return col + (dz / 255.0) * fade;
}

// --- Particle chunk (look/particles.glsl): soft round sprite. ---
inline float dop_particleSprite(float d, float size) {
    float s = size / (d + size * 0.5);
    return s * s;
}
inline float dop_particleFade(float t, float tailPow) {
    return (1.0 - pow(t, tailPow)) * smoothstep(0.0, 0.08, t);
}
