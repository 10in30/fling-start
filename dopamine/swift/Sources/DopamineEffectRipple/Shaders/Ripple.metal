// Ripple — MSL fragment shader, ported from `ripple-shader.ts` (GLSL ES 3.00).
// macOS/iOS only (compiled into the effect's metallib by the Swift build on an
// Apple toolchain; on Linux it is an inert resource).
//
// Governing metaphor: a single drop strikes a calm water surface at u.origin.
// Concentric WAVES expand outward, and each travelling wavefront REFRACTS bright
// caustic light that dances across the UI as the ring passes; behind the front,
// the surface settles back to still. A deliberate DIVERGENCE from Solarbloom's
// soft radial CORE — Ripple's light lives only on thin, moving RING crests + the
// caustics they refract.
//
// One full-screen pass renders, all summed as light (presented through the
// `screen`-blended light layer; the shadow pass through a `multiply` layer):
//   1. WAVEFIELD — a sum of `rings` radially-travelling cosine wave packets.
//   2. CRESTS    — the bright wet ridge of each travelling wavefront (h > 0).
//   3. CAUSTICS  — the wave SLOPE refracts/focuses light into bright filaments.
//   4. CREST GLINT — a thin specular line riding each leading crest.
// finished with a filmic (ACES) tonemap, an optional cel-ring pass, + a dither.
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `RippleUniforms` struct is now GENERATED from the `.dope`
// by scripts/gen-uniforms.mjs (into RippleUniforms.metal) — the SAME source that
// emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "RippleUniforms.metal"   // @generated — struct RippleUniforms
using namespace metal;

#define MAX_RINGS 7

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut ripple_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// A travelling ring's launch time as a fraction of life. The drop strikes at
// t=0 and successive rings (the secondary swells of a real impact) follow in a
// quick stagger, so the pool reads as one event rippling out, not N drops.
inline float ringLaunch(int i) {
    return float(i) * 0.045;
}

// The wave surface as a function of normalized radius rn (= r / minDim) and the
// life clock. Returns height in h; the radial SLOPE (dHeight/dr) in slope; and a
// 0..1 wavefront ENVELOPE in front (1 where a ring currently is, 0 in the still
// water ahead/behind). Shared by the light pass and the shadow so the cast
// occlusion tracks exactly the troughs that are drawn.
//
// Each ring is a radially-expanding wave packet: a cosine carrier (phase =
// k*r - w*t) under a gaussian envelope that travels outward at u.speed and
// spreads/decays as 1/sqrt(r) (energy conservation on an expanding circle).
inline void waveField(float rn, constant RippleUniforms &u,
                      thread float &h, thread float &slope, thread float &front) {
    h = 0.0; slope = 0.0; front = 0.0;
    float k = TAU / max(u.wavelength, 0.001);        // angular wavenumber (per rn)
    float w = k * u.speed;                           // angular frequency
    int rings = int(clamp(u.rings, 0.0, float(MAX_RINGS)) + 0.5);
    for (int i = 0; i < MAX_RINGS; i++) {
        if (i >= rings) break;
        float t0 = ringLaunch(i);
        float age = u.life - t0;                       // 0..(1-t0)
        if (age <= 0.0) continue;
        // Front radius travels outward; the packet has a finite, slowly-growing width.
        float front_r = u.speed * age;                 // expected crest of this ring
        float width = u.wavelength * (1.4 + 1.8 * age); // packet half-extent (spreads)
        float d = rn - front_r;                         // signed distance to the front
        float pkt = exp(-(d * d) / (2.0 * width * width));
        if (pkt < 0.002) continue;
        // Gentle global fade so late rings don't outshine the settle.
        float decay = (1.0 - smoothstep(0.6, 1.0, age));
        // 1/sqrt(r) spreading (clamped near the origin so the drop isn't a spike).
        float spread = 1.0 / sqrt(max(rn, u.wavelength * 0.5));
        // On the cel end, quantize the carrier phase so the rings advance "on twos"
        // (discrete posed crests) instead of sliding smoothly.
        float phase = k * rn - w * u.life;
        float qstep = TAU * 0.5;
        float qphase = floor(phase / qstep) * qstep;
        phase = mix(phase, qphase, u.style * 0.85);
        float amp = u.amplitude * pkt * decay * spread;
        h += amp * cos(phase);
        // d(h)/d(rn): carrier derivative dominates (the steep part that bends light).
        slope += -amp * k * sin(phase);
        front = max(front, pkt * decay);
    }
}

// ---------------------------------------------------------------------------
// SHADOW silhouette — the wave TROUGHS cast a faint soft occlusion (a real
// rippled surface dimples the light it sits in). We sample the wave height at
// the offset shadow point and darken where the surface dips below rest (h < 0),
// gated by the wavefront envelope so still water casts nothing. Kept subtle.
inline float rippleOcclusion(float2 frag, constant RippleUniforms &u) {
    float minDim = min(u.resolution.x, u.resolution.y);
    float rn = length(frag - u.origin) / minDim;
    float h, slope, front;
    waveField(rn, u, h, slope, front);
    float trough = max(-h, 0.0);                       // depth below rest
    return clamp(trough * 2.2 * front * u.amp, 0.0, 1.0);
}

inline float4 rippleShadowColor(float2 frag, constant RippleUniforms &u) {
    float2 sp = frag - u.shadowOffset;
    float soft = u.shadowSoft;
    float occ = rippleOcclusion(sp, u);
    occ += rippleOcclusion(sp + float2( soft, 0.0), u);
    occ += rippleOcclusion(sp + float2(-soft, 0.0), u);
    occ += rippleOcclusion(sp + float2(0.0,  soft), u);
    occ += rippleOcclusion(sp + float2(0.0, -soft), u);
    occ /= 5.0;
    // Troughs are a faint dimple, so cap the darkening well below full strength.
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength * 0.5;
    float3 tint = mix(float3(1.0), 0.6 + 0.4 * normalize(u.c0 + 1e-3), 0.2);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 ripple_fragment(
    VSOut in [[stage_in]],
    constant RippleUniforms &u [[buffer(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin are bottom-left (y up). Flip y once here so the whole shader works
    // in the y-up space it was written for (otherwise the waves emanate from a
    // mirrored point).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float minDim = min(u.resolution.x, u.resolution.y);

    if (u.shadow > 0.5) {
        return rippleShadowColor(frag, u);
    }

    float3 col = float3(0.0);
    float2 rel = frag - u.origin;
    float r = length(rel);
    float rn = r / minDim;                             // normalized radius
    float2 rdir = rel / max(r, 1e-3);                  // outward unit (toward rim)

    // ---- The wave surface at this fragment. ----
    float h, slope, front;
    waveField(rn, u, h, slope, front);

    float gain = u.amp * u.exposure;

    // Colour register: hue drifts gently OUTWARD across the rings (OKLCH palette
    // C0->C1->C2), so each expanding crest reads as a slightly different light —
    // unique per fire (the palette is seeded). A touch of slow temporal drift +
    // tiny fbm break keeps it alive without going rainbow.
    float tcol = clamp(rn / (u.wavelength * float(MAX_RINGS) * 0.9), 0.0, 1.0);
    tcol = fract(tcol + u.timeS * 0.04 + dop_fbm(rel / minDim * 5.0 + u.rippleSeed) * 0.06);
    float3 ringCol = dop_paletteMix(tcol, u.c0, u.c1, u.c2);

    // ---- 1. CRESTS: the bright wet ridge of each travelling wavefront. ----
    // Light lives on the positive crests (h > 0), masked to where a ring is.
    float crest = smoothstep(0.0, u.amplitude * 0.5, h) * front;
    col += ringCol * crest * gain * 0.9;

    // ---- 2. CAUSTICS: the wave SLOPE refracts/focuses light. A curved surface
    // bends parallel light into bright filaments; |slope| peaks on the steep
    // flanks between crest and trough, so the caustic web sits BETWEEN the rings
    // and dances as they travel. Sharpened to thin, bright lines. ----
    float foc = abs(slope);
    float caustic = pow(clamp(foc / (u.amplitude * 1.2 + 1e-3), 0.0, 1.0), 1.8);
    // A little noise breaks the caustic into a living, glittering web.
    float glit = 0.6 + 0.6 * dop_fbm(rel / minDim * 22.0 - u.timeS * 0.5 + u.rippleSeed);
    caustic *= glit * front;
    // The accent hue carries the caustic light (a brighter, whiter highlight on top).
    col += mix(u.c2, float3(1.0), 0.35) * caustic * u.caustic * gain * 1.3;

    // ---- 3. CREST GLINT: a thin specular line riding each leading crest. ----
    float glint = smoothstep(0.85, 1.0, front) * smoothstep(u.amplitude * 0.55, u.amplitude * 0.9, h);
    col += float3(1.0) * glint * gain * 0.5 * (0.5 + 0.5 * u.caustic);

    // ---- Tone + finishing ----
    col = dop_tonemapACES(col * 0.95);

    // ---- Non-photoreal pass: cel rings + posterized caustics (whimsy). ----
    // Toward the cel end the smooth refraction becomes hard concentric BANDS: the
    // crest mask is thresholded into a flat ring, and the caustic web is posterized
    // into chunky light cells. The phase quantization in waveField already steps
    // the rings "on twos"; here we flatten their tone.
    if (u.style > 0.001) {
        // Hard ring: a flat band where the crest is strong, with a brighter inner core.
        float band = smoothstep(0.18, 0.30, crest);
        float core = smoothstep(0.45, 0.60, crest);
        float3 celRing = clamp(ringCol * 1.3, 0.0, 1.2) * band
                       + clamp(u.c0 * 1.6 + 0.1, 0.0, 1.3) * core;
        // Posterize the caustic light into 2 chunky levels (Ben-Day-ish cells),
        // and keep only the BRIGHT cells (drop the dim wash so the cel read stays
        // clean white-on-dark rings instead of a muddy mid-tone field).
        float caus = clamp(caustic * u.caustic, 0.0, 1.0);
        float causQ = step(0.5, caus) * 0.6 + step(0.8, caus) * 0.4;
        float3 celCaustic = mix(u.c2, float3(1.0), 0.5) * causQ;
        float3 cel = (celRing + celCaustic) * gain;
        col = mix(col, cel, u.style);
    }

    // Ordered dither (~1/255) to kill banding the screen blend reveals; faded out
    // toward the cel end where hard bands are intended.
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);

    col = max(col, 0.0);
    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark
    // regions become transparent so the UI beneath shows through, and bright
    // crests/caustics read as cast light over it (returning opaque alpha=1 would
    // paint the whole overlay black over the card). col is the emitted light, so
    // col_channel <= max(col) = alpha holds → valid premultiplied. (The web
    // returns alpha=1 because its `mix-blend-mode: screen` canvas composites
    // differently; on the Metal layer the runner's screen-blend needs the
    // brightness-as-alpha form — same convention as Solarbloom.)
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
