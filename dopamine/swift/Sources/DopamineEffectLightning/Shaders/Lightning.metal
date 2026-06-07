// Lightning — MSL fragment shader, ported from `lightning-shader.ts`
// (GLSL ES 3.00). macOS/iOS only (compiled into the effect's metallib by the
// Swift build on an Apple toolchain; on Linux it is an inert resource).
//
// One full-screen pass renders, all summed as light (presented through the
// `screen`-blended light layer; the shadow pass through a `multiply` layer):
//   1. a hard near-white FLASH wash on the strike instant (re-pulses on beats)
//   2. a jagged, fbm-perturbed MAIN BOLT from the top edge to uOrigin, drawn as
//      a glowing capsule chain with a hot white core inside an electric halo
//   3. a few shorter secondary FORKS branching off the main path
//   4. a bright IMPACT GLOW where the bolt meets uOrigin
// finished with a filmic (ACES) tonemap, an optional cel/comic pass, + a dither.
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `LightningUniforms` struct is now GENERATED from the
// `.dope` by scripts/gen-uniforms.mjs (into LightningUniforms.metal) — the SAME
// source that emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "LightningUniforms.metal"   // @generated — struct LightningUniforms
using namespace metal;

#define MAX_FORKS 7
#define BOLT_SEGS 14

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut lightning_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Electric channel colour ramp. The golden-angle palette fans c0/c1/c2 far apart
// in hue (a deliberately ROAMING palette), which for a bolt would cross through
// magenta/orange — wrong for an electric arc. So the bolt's colour is built as a
// tight ramp anchored on c0 (the mood's electric blue/violet base hue): rim = c0,
// blending toward a cool electric-white core as t -> 1. This keeps the bolt
// monochromatic blue/violet -> hot white. `t` in 0..1 (0 = outer halo, 1 = core).
inline float3 elecRamp(float t, constant LightningUniforms &u) {
    t = clamp(t, 0.0, 1.0);
    // A cool tint pulled slightly toward cyan/blue from c0 for the very rim, so
    // the halo's edge reads electric rather than flat.
    float3 rim = mix(u.c0, float3(0.45, 0.6, 1.0), 0.35);
    float3 mid = mix(u.c0, float3(0.8, 0.85, 1.0), 0.5);   // bright blue-white
    float3 hot = float3(1.0);                              // white-hot plasma
    return t < 0.5 ? mix(rim, mid, t * 2.0) : mix(mid, hot, (t - 0.5) * 2.0);
}

// A jagged lightning vertex at parameter t in [0,1] along a path from A to B.
// The straight lerp is perturbed PERPENDICULAR to travel by an fbm-driven offset
// (so the bolt zig-zags), tapering to 0 at both endpoints (so it stays anchored
// to the source + the strike point). `seedOff` decorrelates separate bolts/forks.
// jitterScale lets the shadow drop the cel "on twos" jitter (a shadow shouldn't
// shimmer like the lit bolt).
inline float2 boltPoint(float2 A, float2 B, float t, float seedOff, float jitterScale,
                        constant LightningUniforms &u) {
    float2 d = B - A;
    float len = max(length(d), 1.0);
    float2 dir = d / len;
    float2 nrm = float2(-dir.y, dir.x);
    // Per-frame "on twos" beat so high-whimsy strikes re-pose the jag discretely.
    float beat = floor(u.timeS * 12.0) * u.style * jitterScale;
    // Two octaves of perturbation: a big swing + a fine crackle, both faded at ends.
    float n = dop_fbm(float2(t * 6.0 + seedOff + u.boltSeed, beat * 0.5)) - 0.5;
    float fine = dop_fbm(float2(t * 22.0 + seedOff * 3.1 + u.boltSeed, beat)) - 0.5;
    float taper = sin(t * 3.14159265);           // 0 at ends, 1 mid-path
    float off = (n * 1.6 + fine * 0.5) * u.jagged * len * 0.16 * taper;
    return A + dir * (t * len) + nrm * off;
}

// Glowing coverage of a jagged bolt from A to B, drawn up to arc fraction
// `drawn` (0..1). Walks the polyline; for each lit segment accumulates an
// additive 1/d glow (the plasma falloff) plus a hot white core near the spine.
// Returns float2(coreCoverage, glow). `core` is the crisp white centre, glow
// is the soft electric halo. radFrac is the bolt half-width as a frac of minDim.
inline float2 boltGlow(float2 frag, float2 A, float2 B, float drawn, float seedOff,
                      float radFrac, float jitterScale, constant LightningUniforms &u) {
    float minDim = min(u.resolution.x, u.resolution.y);
    float rad = minDim * radFrac;
    float glow = 0.0;
    float core = 0.0;
    float2 prev = boltPoint(A, B, 0.0, seedOff, jitterScale, u);
    for (int i = 1; i <= BOLT_SEGS; i++) {
        float t = float(i) / float(BOLT_SEGS);
        if (t - 1.0 / float(BOLT_SEGS) > drawn) break;   // only the struck portion
        float tc = min(t, drawn);
        float2 cur = boltPoint(A, B, tc, seedOff, jitterScale, u);
        float dist = dop_sdSeg(frag, prev, cur);
        // Soft plasma glow: inverse-distance falloff, bounded.
        glow += rad / (dist + rad * 0.35);
        // Hot core: a crisp bright centre line.
        core = max(core, 1.0 - smoothstep(rad * 0.25, rad * 0.6, dist));
        prev = cur;
    }
    glow = clamp(glow / float(BOLT_SEGS) * 2.2, 0.0, 1.4);
    return float2(core, glow);
}

// The strike geometry: the bolt descends from a point on the TOP edge (offset
// horizontally toward the strike so it reads as coming "down to" the action) to
// the strike point at uOrigin.
inline float2 boltStart(constant LightningUniforms &u) {
    float2 res = u.resolution;
    // Start near the top, biased toward the strike's x with a seeded horizontal jog.
    float jx = (dop_hash21(u.boltSeed * 1.7).x - 0.5) * res.x * 0.5;
    return float2(clamp(u.origin.x + jx, res.x * 0.12, res.x * 0.88), res.y * 1.02);
}

// SHADOW silhouette: just the bolt mass (main + forks), no glow/core/flash — a
// cheap occlusion field so the extra multiply pass stays light under software GL.
inline float boltOcclusion(float2 p, constant LightningUniforms &u) {
    float minDim = min(u.resolution.x, u.resolution.y);
    float2 A = boltStart(u);
    float2 B = u.origin;
    float rad = minDim * u.thickness * 1.6;
    float occ = 0.0;
    float2 prev = boltPoint(A, B, 0.0, 0.0, 0.0, u);
    for (int i = 1; i <= BOLT_SEGS; i++) {
        float t = float(i) / float(BOLT_SEGS);
        if (t - 1.0 / float(BOLT_SEGS) > u.strike) break;
        float tc = min(t, u.strike);
        float2 cur = boltPoint(A, B, tc, 0.0, 0.0, u);
        float dist = dop_sdSeg(p, prev, cur);
        occ = max(occ, 1.0 - smoothstep(rad * 0.6, rad, dist));
        prev = cur;
    }
    return clamp(occ * u.amp, 0.0, 1.0);
}

inline float4 shadowColor(float2 frag, constant LightningUniforms &u) {
    float2 sp = frag - u.shadowOffset;
    float occ = boltOcclusion(sp, u);
    float soft = u.shadowSoft;
    occ += boltOcclusion(sp + float2( soft, 0.0), u);
    occ += boltOcclusion(sp + float2(-soft, 0.0), u);
    occ += boltOcclusion(sp + float2(0.0,  soft), u);
    occ += boltOcclusion(sp + float2(0.0, -soft), u);
    float s2 = soft * 0.7071;
    occ += boltOcclusion(sp + float2( s2,  s2), u);
    occ += boltOcclusion(sp + float2(-s2,  s2), u);
    occ += boltOcclusion(sp + float2( s2, -s2), u);
    occ += boltOcclusion(sp + float2(-s2, -s2), u);
    occ /= 9.0;
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength;
    // Cool the shadow toward the electric blue (NOT the roaming c1, which the
    // golden-angle palette can push into magenta) so the cast occlusion stays on-hue.
    float3 tint = mix(float3(1.0), 0.55 + 0.45 * normalize(elecRamp(0.2, u) + 1e-3), 0.25);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 lightning_fragment(
    VSOut in [[stage_in]],
    constant LightningUniforms &u [[buffer(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin are bottom-left (y up). Flip y once here so the whole shader works
    // in the y-up space it was written for (otherwise the bolt — which descends
    // from the top edge to the strike point — renders upside down).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);

    if (u.shadow > 0.5) {
        return shadowColor(frag, u);
    }

    float3 col = float3(0.0);
    float gain = u.exposure * u.amp;

    float2 A = boltStart(u);
    float2 B = u.origin;

    // Accumulate the analytic bolt geometry coverage (core = crisp white channel,
    // glow = soft halo) across the trunk + forks, so the cel pass can isolate the
    // BOLT SHAPE itself rather than thresholding the final (flash-washed) luminance.
    float boltCore = 0.0;
    float boltGlowAcc = 0.0;

    // ---- MAIN BOLT ----
    float2 mb = boltGlow(frag, A, B, u.strike, 0.0, u.thickness, 1.0, u);
    float mainCore = mb.x;
    float mainGlow = mb.y;
    boltCore = max(boltCore, mainCore);
    boltGlowAcc = max(boltGlowAcc, mainGlow);

    // Electric halo: a tight blue/violet -> white ramp keyed on the glow strength,
    // with a touch of fbm so the channel has living variation (not a flat tube).
    float haloT = clamp(mainGlow * 0.7 + 0.1 * (dop_fbm(frag / minDim * 4.0 + u.boltSeed) - 0.5), 0.0, 1.0);
    col += elecRamp(haloT, u) * mainGlow * gain * 1.3;
    // Hot white core (the plasma channel) — pushes the centre to white.
    col += float3(1.0) * mainCore * gain * 2.4;

    // ---- SECONDARY FORKS ----
    // A few shorter bolts branching off the main path. Each launches from a point
    // partway down the main bolt and shoots to an offset target, lit only once the
    // strike has progressed past its launch point.
    for (int i = 0; i < MAX_FORKS; i++) {
        if (float(i) >= u.branches) break;
        float2 hh = dop_hash21(float(i) * 9.7 + u.boltSeed + 3.0);
        float launchT = 0.18 + hh.x * 0.62;            // where it splits off the main bolt
        if (u.strike < launchT) continue;
        float2 forkA = boltPoint(A, B, launchT, 0.0, 1.0, u);
        // Fork target: out to the side + further down, length scaled by reach.
        float ang = (hh.y - 0.5) * 2.2;                 // splay angle
        float2 dir = normalize(B - A);
        float2 nrm = float2(-dir.y, dir.x);
        float reach = (0.18 + hh.x * 0.22) * length(B - A);
        float2 forkB = forkA + (dir * (0.5 + hh.y) + nrm * ang) * reach;
        float forkDrawn = clamp((u.strike - launchT) / max(1.0 - launchT, 0.05), 0.0, 1.0);
        float2 fb = boltGlow(frag, forkA, forkB, forkDrawn, float(i) * 17.0 + 5.0, u.thickness * 0.6, 1.0, u);
        // Forks fade slightly faster than the trunk (thinner channels cool quicker).
        float forkFade = 0.6 + 0.4 * (1.0 - smoothstep(0.5, 1.0, u.life));
        col += elecRamp(clamp(fb.y * 0.7 + 0.15, 0.0, 1.0), u) * fb.y * gain * 0.8 * forkFade;
        col += float3(1.0) * fb.x * gain * 1.5 * forkFade;
        boltCore = max(boltCore, fb.x * forkFade);
        boltGlowAcc = max(boltGlowAcc, fb.y * forkFade);
    }

    // ---- IMPACT GLOW ----
    // A bright radial burst at the strike point, blooming once the bolt lands.
    // The burst blooms on contact then EASES OFF (it shouldn't sit as a permanent
    // white disc through the whole afterglow), and is kept tight so the branching
    // bolt forms — not a blob — remain the read.
    float landed = smoothstep(0.7, 1.0, u.strike) * (0.4 + 0.6 * (1.0 - smoothstep(0.1, 0.5, u.life)));
    float dB = length(frag - B);
    float impact = (minDim * u.thickness * 2.0) / (dB + minDim * u.thickness * 1.4);
    impact *= impact;
    col += elecRamp(0.7, u) * impact * landed * gain * 0.8;

    // ---- FLASH / STROBE ----
    // A hard near-white full-frame wash, brightest on contact and re-pulsing on the
    // flicker beats (u.flash carries the strobe envelope). A faint radial bias keeps
    // the strike point hottest. This is the signature "boost landed" hit.
    // Concentrate the wash toward the strike point so the flash reads as the bolt
    // dumping light into the action (a low global floor keeps it from flat-washing
    // the whole page to white once it's past the first instant).
    float flashRadial = 0.28 + 0.72 * exp(-dB / (minDim * 0.5));
    float3 flashCol = mix(float3(1.0), elecRamp(0.6, u), 0.25);
    col += flashCol * u.flash * u.flashBright * flashRadial;

    // ---- Tone + finishing ----
    // Pre-expose a touch so the electric halo stays vivid, then ACES rolloff so the
    // hot core + flash don't go chalky on the page beneath.
    col = dop_tonemapACES(col * 0.9);

    // ---- Non-photoreal pass: cel / comic-book bolt (whimsy) ----
    // Toward the cel end rebuild the bolt as a FLAT comic lightning shape: a hard
    // solid white core + a single bold electric outline band, keyed off the glow we
    // already have. Don't posterize the dark background (that shatters it into
    // blocks); only the bolt forms flatten.
    if (u.style > 0.001) {
        // Key the cel cells off the analytic BOLT coverage (not the flash-washed
        // luminance), so the comic rebuild is the jagged bolt + a bold outline — the
        // background and the flash wash are left alone (posterizing them just shatters
        // the page into camouflage blocks).
        float coreMask = smoothstep(0.45, 0.65, boltCore);                  // solid white channel
        float bandMask = smoothstep(0.45, 0.8, boltGlowAcc) * (1.0 - coreMask); // bold outline
        float3 boltColor = clamp(elecRamp(0.35, u) * 1.5 + 0.05, 0.0, 1.3);
        float3 cel = float3(1.0) * coreMask + boltColor * bandMask;
        float boltMask = clamp(coreMask + bandMask, 0.0, 1.0);
        // Flatten ONLY the bolt region into the cel cells; keep the soft impact glow,
        // dither and — crucially — the full-frame STROBE FLASH as they are (the hard
        // strobe is the whole point of the comic-book bolt).
        float3 styled = mix(col, cel, boltMask);
        col = mix(col, styled, u.style);
    }

    // Ordered dither (~1/255) to kill banding the screen blend would reveal; faded
    // out toward the cel end where hard bands are intended.
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark regions
    // become transparent so the UI beneath shows through, and the bright bolt/flash
    // read as cast light over it. col is the emitted light (>= 0), so
    // col_channel <= max(col) = alpha holds → valid premultiplied. (The web returns
    // opaque alpha because it composites through a `screen`-blended layer; the Metal
    // host composites the light layer over the UI directly, so it needs the alpha.)
    col = max(col, 0.0);
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
