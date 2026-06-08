// Inkstroke (Calligraphic Verdict) — MSL fragment shader, ported from
// `inkstroke-shader.ts` (GLSL ES 3.00). macOS/iOS only (compiled into the
// effect's metallib by the Swift build on an Apple toolchain; on Linux it is an
// inert resource).
//
// A deliberate DIVERGENCE from Solarbloom's centered radial bloom: instead of
// light radiating from a point, a single calligraphic ink/light gesture WRITES
// ITSELF across the frame as a real CHECKMARK — a short down-stroke into the
// vertex, then a long up-flick to the right. The composition is directional and
// asymmetric (it ignores u.origin), composed entirely from ANALYTIC SDF stroke
// rendering (no baked-SDF / glyph texture). Layers, summed as light:
//   1. PAPER WASH — a faint glow hugging the stroke spine.
//   2. THE STROKE — a two-leg checkmark brush path with pressure-modulated
//      width, FBM wet-edge bleed, bristle/dry-brush rake, and a bright wet tip.
//   3. DROPLET SPRAY — ink flung off the flick, arcing under gravity.
//   4. AFTER-SHIMMER — a brief calligraphic underline that settles.
// finished with a filmic (ACES) tonemap + an ordered dither (and a cel/neon
// flattening toward the whimsy end).
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `InkstrokeUniforms` struct is GENERATED from the `.dope`
// by scripts/gen-uniforms.mjs (into InkstrokeUniforms.metal) — the SAME source
// that emits the Swift packer, so the two layouts cannot drift.
//
// PORT DIVERGENCE: the web shader calls the shared `ballisticPos()` from
// look/particles.glsl; the Swift DopamineLook.metal (copied verbatim) only
// carries `dop_particleSprite`/`dop_particleFade`, so the ballistic arc is
// inlined here exactly as `origin + dir*speed*t - vec2(0,1)*gravity*t*t`
// (matching the web `ballisticPos` body, which the shadow pass already inlines).

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "InkstrokeUniforms.metal"   // @generated — struct InkstrokeUniforms
using namespace metal;

#define MAX_DROPS 64

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut inkstroke_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// The gesture is a real CHECKMARK: two straight legs A->B->C. A is the
// upper-left start, B is the bottom vertex (a SHORT down-stroke), C is the far
// upper-right (a LONG up-flick) — a confident tick. The pen writes leg1 then
// leg2; u.draw advances along TOTAL ARC LENGTH so the wet tip rides the corner.
// (y is up in the flipped frag space below.)
//
// Shared by the light pass and the shadow silhouette so the cast shadow tracks
// exactly what's drawn. jitterScale lets the shadow drop the cel "on twos"
// jitter (a shadow shouldn't shimmer).
inline void strokeGeom(float jitterScale, constant InkstrokeUniforms &u,
                       thread float2 &A, thread float2 &B, thread float2 &C) {
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);
    float len = u.scale * res.x;
    float2 mid = float2(res.x * 0.5, res.y * 0.46);
    float bt = floor(u.timeS * 12.0);
    float2 jit = (dop_hash21(bt + u.inkSeed) - 0.5) * minDim * 0.02 * u.style * jitterScale;
    A = mid + float2(-0.42, 0.18) * len + jit;   // upper-left: pen touches down
    B = mid + float2(-0.12, -0.30) * len + jit;  // bottom vertex: short down-stroke
    C = mid + float2(0.55, 0.42) * len + jit;    // far upper-right: long up-flick
}

// Sample the checkmark path at arc-distance fraction uu in [0,1]: returns the
// position, and outputs the local segment param (segT in 0..1) plus which leg
// (0 = down-stroke, 1 = up-flick) so callers can shape pressure along travel.
inline float2 checkPos(float2 A, float2 B, float2 C, float uu,
                      thread float &segT, thread float &leg) {
    float l1 = length(B - A);
    float l2 = length(C - B);
    float total = max(l1 + l2, 1e-3);
    float d = uu * total;
    if (d <= l1) {
        segT = d / max(l1, 1e-3);
        leg = 0.0;
        return mix(A, B, segT);
    }
    segT = (d - l1) / max(l2, 1e-3);
    leg = 1.0;
    return mix(B, C, segT);
}

// PRESSURE profile along the whole tick (arc fraction uu in 0..1): thin where
// the pen first touches down, swelling into a heavy BELLY through the vertex and
// the base of the up-flick, then tapering to a thin exit on the flick's tip.
inline float inkPressure(float uu, constant InkstrokeUniforms &u) {
    return exp(-pow((uu - 0.46) * 2.2, 2.0)) * u.pressure;
}

// End-cap taper (arc fraction uu): fade the very entry and the very exit so the
// stroke reads as a written tick with thin terminals, not a blunt bar.
inline float inkTaper(float uu) {
    return smoothstep(0.0, 0.05, uu) * (1.0 - smoothstep(0.88, 1.0, uu));
}

// ---------------------------------------------------------------------------
// SHADOW silhouette — a cheap occlusion field for the bright forms (the drawn
// stroke body + the flung droplets). Just the mass, no wet bleed / bristle /
// tip-glow, so the extra pass stays light.
inline float inkOcclusion(float2 p, constant InkstrokeUniforms &u) {
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);
    float2 A, B, C;
    strokeGeom(0.0, u, A, B, C);   // drop the cel jitter for the shadow
    float base = minDim * 0.045;
    float occ = 0.0;

    // Walk the two-leg tick by arc fraction; only the drawn portion casts shadow.
    float segT, leg;
    const int STEPS = 16;
    for (int i = 0; i < STEPS; i++) {
        float u0 = float(i) / float(STEPS);
        float u1 = float(i + 1) / float(STEPS);
        if (u0 > u.draw) break;
        float uc = clamp((u0 + u1) * 0.5, 0.0, u.draw);
        float2 a = checkPos(A, B, C, u0, segT, leg);
        float2 b = checkPos(A, B, C, min(u1, u.draw), segT, leg);
        float belly = inkPressure(uc, u);
        float taper = inkTaper(uc);
        float rad = base * (0.55 + 1.25 * belly) * (0.4 + 0.6 * taper);
        float dist = dop_sdSeg(p, a, b);
        occ = max(occ, 1.0 - smoothstep(rad * 0.7, rad, dist));
    }

    // Droplets: soft round mass, flung off the up-flick near its tip.
    float2 launch = checkPos(A, B, C, 0.86, segT, leg);
    float2 launchDir = normalize(checkPos(A, B, C, 0.92, segT, leg)
                               - checkPos(A, B, C, 0.78, segT, leg));
    float len = u.scale * res.x;
    for (int i = 0; i < MAX_DROPS; i++) {
        if (float(i) >= u.droplets) break;
        float2 hh = dop_hash21(float(i) * 5.3 + u.inkSeed + 11.0);
        float dl = 0.6 + hh.x * 0.25;
        float dlife = clamp((u.life - dl) / max(1.0 - dl, 0.001), 0.0, 1.0);
        if (dlife <= 0.0) continue;
        float spd = (0.4 + hh.y) * len * 0.9;
        float spread = (hh.x - 0.5) * 1.4;
        float2 dir = normalize(launchDir + float2(-launchDir.y, launchDir.x) * spread);
        float2 dp = launch + dir * spd * dlife - float2(0.0, 1.0) * (minDim * 0.9) * dlife * dlife;
        float dsz = minDim * 0.006 * (0.4 + hh.y * 0.9) * (1.0 - 0.5 * dlife);
        float dd = length(p - dp);
        occ = max(occ, (1.0 - smoothstep(dsz * 0.5, dsz * 1.2, dd)) * (1.0 - dlife) * 0.7);
    }

    return clamp(occ * u.amp, 0.0, 1.0);
}

inline float4 inkShadowColor(float2 frag, constant InkstrokeUniforms &u) {
    float2 sp = frag - u.shadowOffset;
    float occ = inkOcclusion(sp, u);
    float soft = u.shadowSoft;
    occ += inkOcclusion(sp + float2( soft, 0.0), u);
    occ += inkOcclusion(sp + float2(-soft, 0.0), u);
    occ += inkOcclusion(sp + float2(0.0,  soft), u);
    occ += inkOcclusion(sp + float2(0.0, -soft), u);
    float s2 = soft * 0.7071;
    occ += inkOcclusion(sp + float2( s2,  s2), u);
    occ += inkOcclusion(sp + float2(-s2,  s2), u);
    occ += inkOcclusion(sp + float2( s2, -s2), u);
    occ += inkOcclusion(sp + float2(-s2, -s2), u);
    occ /= 9.0;
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength;
    float3 tint = mix(float3(1.0), 0.6 + 0.4 * normalize(u.c0 + 1e-3), 0.25);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 inkstroke_fragment(
    VSOut in [[stage_in]],
    constant InkstrokeUniforms &u [[buffer(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math is
    // bottom-left (y up). Flip y once here so the whole shader works in the y-up
    // space it was written for (otherwise the tick + buoyant spray render upside
    // down).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float2 res = u.resolution;
    float minDim = min(res.x, res.y);
    float3 col = float3(0.0);

    if (u.shadow > 0.5) {
        return inkShadowColor(frag, u);
    }

    // ---- Stroke geometry: a real CHECKMARK written in one motion. ----
    float len = u.scale * res.x;
    float2 A, B, C;
    strokeGeom(1.0, u, A, B, C);   // includes the cel "on twos" jitter (whimsy)

    // The pen has written up to arc fraction u.draw along the tick. Walk the path
    // in a few steps; for each, treat it as a capsule with pressure-varying
    // radius and accumulate coverage. (Cheap analytic approximation of a brush.)
    float base = minDim * 0.045;                     // base half-width (bold)
    float ink = 0.0;       // 0..1 ink coverage (solid body)
    float edge = 0.0;      // proximity to the wet outer edge (for bleed/spray)
    float bodyT = 0.0;     // arc fraction at the nearest body sample (0..1)
    float nearAcross = 0.0;// signed across-offset / radius at nearest point
    float2 tipPos = A; float tipR = base;            // running leading-tip pos
    float bestDist = 1e9;
    float segT, leg;

    const int STEPS = 28;
    for (int i = 0; i < STEPS; i++) {
        float u0 = float(i) / float(STEPS);
        float u1 = float(i + 1) / float(STEPS);
        // Only consider the written portion of the path.
        if (u0 > u.draw) break;
        float uc = clamp((u0 + u1) * 0.5, 0.0, u.draw);
        float2 a = checkPos(A, B, C, u0, segT, leg);
        float2 b = checkPos(A, B, C, min(u1, u.draw), segT, leg);

        // Across-direction of THIS leg (the two legs travel differently), so the
        // bristle rake and the signed offset stay true to the local travel.
        float2 ba = b - a;
        float2 dirL = normalize(length(ba) > 1e-3 ? ba : (leg < 0.5 ? B - A : C - B));
        float2 across2 = float2(-dirL.y, dirL.x);

        // PRESSURE profile along arc length: thin in, heavy belly through the
        // vertex/flick base, thin flick out. Applied identically on both legs.
        float belly = inkPressure(uc, u);
        float taper = inkTaper(uc);
        float rad = base * (0.55 + 1.25 * belly) * (0.4 + 0.6 * taper);

        // Wet-edge wobble: perturb radius with FBM so the contour is irregular
        // (only really visible at high wetness; bounded so the body stays solid).
        float wob = (dop_fbm(float2(uc * 8.0 + u.inkSeed, u.timeS * 0.2)) - 0.5) * u.wetness;
        rad *= (1.0 + 0.30 * wob);

        // Capsule SDF for this short segment.
        float2 pa = frag - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-3), 0.0, 1.0);
        float2 near = a + ba * h;
        float dist = length(frag - near);

        if (dist < bestDist) {
            bestDist = dist;
            bodyT = uc;
            tipR = rad;
            // signed normalized across-offset of this fragment from the spine
            nearAcross = clamp(dot(frag - near, across2) / max(rad, 1.0), -1.0, 1.0);
        }
        // Coverage: a wide solid interior with a soft contact edge.
        float cov = 1.0 - smoothstep(rad * 0.85, rad, dist);
        ink = max(ink, cov);
        edge = max(edge, (1.0 - smoothstep(rad, rad * 1.7, dist)) * (1.0 - cov));
        tipPos = b;
    }

    // BRISTLE / dry-brush: a SUBTLE rake. A handful of fine streaks parallel to
    // travel, sampled by the across-offset so they sit correctly inside the
    // stroke; the central spine is protected so the mark always reads as one
    // confident gesture, not hatching. Bristle only darkens slightly.
    float bristleField = 0.5 + 0.5 * sin(nearAcross * 14.0 + u.inkSeed * 6.28
                         + dop_fbm(float2(bodyT * 6.0, nearAcross * 3.0) + u.inkSeed) * 4.0);
    float spine = smoothstep(0.9, 0.2, abs(nearAcross));          // protect centre
    float rake = 1.0 - u.bristle * (1.0 - spine) * (1.0 - bristleField) * 0.7;
    ink *= rake;

    // INK BLEED HALO: the wet edge spreads into the paper as a soft, FBM-broken
    // stain — like the "darkest value spreads" fluid reveal, but baked analytic.
    float bleed = edge * u.wetness * (0.5 + 0.7 * dop_fbm(frag / minDim * 18.0 + u.inkSeed));

    // PAPER WASH: a faint halo that HUGS the gesture — a soft glow falling off
    // from the stroke spine (NOT a radial core, NOT a full-width band): it traces
    // the same directional arc, so the light it casts follows the mark.
    float wash = exp(-bestDist / (minDim * 0.10)) * 0.10 * smoothstep(0.02, 0.12, u.draw);

    float gain = u.amp * u.exposure;
    // Compose the ink as a COHERENT mark: the body holds the core hue (c0/c1),
    // drifting only gently along its length; the bleeding wet edge is where the
    // accent hue (c2) shows. This keeps the gesture reading as a single confident
    // stroke of one ink, not a spectrum.
    float3 inkCol = mix(u.c0, u.c1, 0.2 + 0.3 * bodyT);
    col += inkCol * ink * gain;
    col += mix(u.c1, u.c2, 0.6) * bleed * gain * 0.85;
    col += mix(u.c0, u.c1, 0.4) * wash * gain;

    // WET-EDGE IRIDESCENCE + DISPERSION (borrowed from Solarbloom): on the wet,
    // serene end the bleeding edge catches an oil-on-water sheen — a faint
    // IQ-cosine spectral tint riding the wet halo — plus a slight chromatic split
    // that fringes the contact edge. Gated by wetness and faded out toward the
    // cel/neon end. The body keeps its single-ink identity; only the wet rim
    // shimmers.
    float wetSheen = bleed * u.wetness * (1.0 - u.style);
    if (wetSheen > 0.001) {
        float irPhase = bodyT * 0.7 + nearAcross * 0.5 + u.timeS * 0.25
                      + dop_fbm(frag / minDim * 9.0 + u.inkSeed) * 1.2;
        float3 irid = dop_iridescent(fract(irPhase));
        col = mix(col, col * (0.55 + 1.2 * irid), wetSheen * 0.35);
        col += irid * wetSheen * 0.10 * gain;
        // Chromatic split at the wet contact edge: a thin per-channel offset.
        float disp = (0.04 + 0.08 * edge) * u.wetness * (1.0 - u.style) * (0.7 + 0.5 * u.amp);
        col.r += edge * disp * 0.6 * gain;
        col.b -= edge * disp * 0.5 * gain;
    }

    // WET LEADING TIP: a bright hot point that races at the pen head while
    // drawing, with a short afterglow. This is the "it's happening now" spark.
    float drawing = smoothstep(0.0, 0.05, u.draw) * (1.0 - smoothstep(0.9, 1.04, u.draw));
    float td = length(frag - tipPos);
    float tipGlow = (tipR * 1.7) / (td + tipR * 0.5); tipGlow *= tipGlow;
    col += float3(1.0) * tipGlow * drawing * gain * 1.8;

    // DROPLET SPRAY: ink flung off the up-flick. Each droplet launches from near
    // the flick tip once the stroke passes ~0.6, arcs out along the flick's
    // travel direction and falls under gravity, fading.
    float2 launch = checkPos(A, B, C, 0.86, segT, leg);
    float2 launchDir = normalize(checkPos(A, B, C, 0.92, segT, leg)
                               - checkPos(A, B, C, 0.78, segT, leg));
    for (int i = 0; i < MAX_DROPS; i++) {
        if (float(i) >= u.droplets) break;
        float2 hh = dop_hash21(float(i) * 5.3 + u.inkSeed + 11.0);
        float dl = 0.6 + hh.x * 0.25;                 // launches as the flick happens
        float dlife = clamp((u.life - dl) / max(1.0 - dl, 0.001), 0.0, 1.0);
        if (dlife <= 0.0) continue;
        float spd = (0.4 + hh.y) * len * 0.9;
        float spread = (hh.x - 0.5) * 1.4;
        float2 dir = normalize(launchDir + float2(-launchDir.y, launchDir.x) * spread);
        // Ballistic arc (inlined from look/particles `ballisticPos`; outward +
        // gravity; y is up): origin + dir*speed*t - vec2(0,1)*gravity*t*t.
        float2 dp = launch + dir * spd * dlife - float2(0.0, 1.0) * (minDim * 0.9) * dlife * dlife;
        float dsz = minDim * 0.006 * (0.4 + hh.y * 0.9) * (1.0 - 0.5 * dlife);
        float dd = length(frag - dp);
        float drop = dop_particleSprite(dd, dsz);   // shared soft round sprite
        // toon: crisp the droplet into a hard dot toward the cel end.
        if (u.style > 0.001) {
            float crisp = 1.0 - smoothstep(dsz * 0.9, dsz, dd);
            drop = mix(drop, crisp, u.style * 0.9);
        }
        float dfade = (1.0 - dlife) * smoothstep(0.0, 0.1, dlife);
        col += dop_paletteMix(0.6 + hh.y * 0.4, u.c0, u.c1, u.c2) * drop * dfade * gain * 1.1;
    }

    // AFTER-SHIMMER underline: once the stroke is essentially done, a quick
    // horizontal sweep of light settles beneath the gesture (a confident
    // "signed" underline) then fades — reinforces the success read without a core.
    float ul = smoothstep(0.78, 0.92, u.draw) * (1.0 - smoothstep(0.45, 1.0, u.life));
    // Settle the underline just below the tick's bottom vertex, spanning its width.
    float ulY = B.y - len * 0.10;
    float uy = exp(-pow((frag.y - ulY) / (minDim * 0.012), 2.0));
    float ux = smoothstep(A.x, A.x + len * 0.1, frag.x) * (1.0 - smoothstep(C.x - len * 0.05, C.x, frag.x));
    col += dop_paletteMix(0.4, u.c0, u.c1, u.c2) * uy * ux * ul * gain * 0.8;

    // ---- Tone + finishing ----
    // ACES filmic tonemap (shared look/glsl, borrowed from Solarbloom) for a
    // cleaner highlight rolloff + richer mid-ink. A mild pre-exposure keeps the
    // wet mid-ink from dimming while letting the wet highlights roll off.
    col = dop_tonemapACES(col * 0.82);

    // ---- Non-photoreal pass: cel / neon flattening (whimsy) ----
    // Toward the cel end we want a FLAT, bold neon slash with a clean glowing
    // rim — NOT a posterized photo. So instead of quantizing the whole frame
    // (which shatters the soft wash into camouflage blocks), rebuild the stroke
    // as flat cel cells: a hard-edged solid fill + a bright outline, keyed off
    // the analytic coverage we already have.
    if (u.style > 0.001) {
        // Hard silhouette of the drawn body (a couple of cel "tones", not 40).
        float fillMask = smoothstep(0.55, 0.62, ink);
        float coreMask = smoothstep(0.8, 0.86, ink);
        float3 neonCore = clamp(u.c0 * 1.5 + 0.15, 0.0, 1.2);
        float3 neonMid = clamp(mix(u.c0, u.c1, 0.6) * 1.3, 0.0, 1.1);
        float3 cel = neonMid * fillMask + (neonCore - neonMid) * coreMask;
        // Bright neon rim just outside the fill — the glowing cyberpunk outline.
        float rim = smoothstep(0.4, 0.56, ink) * (1.0 - fillMask);
        cel += clamp(u.c2 * 1.6 + 0.2, 0.0, 1.3) * rim;
        // Replace the stroke region with the flat cel stroke, but DON'T posterize
        // the dark wash/background. The soft wash, droplets and tip stay as they
        // are; only the body flattens.
        float strokeMask = clamp(fillMask + rim, 0.0, 1.0);
        float3 styled = mix(col, cel * gain, strokeMask);
        col = mix(col, styled, u.style);
    }

    // Ordered dither (~1/255, shared look/glsl) to kill banding the screen blend
    // would reveal; faded out toward the cel end where hard bands are intended.
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. The web
    // emits opaque alpha=1 over a `mix-blend-mode: screen` canvas (black == no
    // change); the Swift light layer is a per-pass `screen` blend onto a
    // premultiplied overlay, so dark regions must become transparent (alpha = the
    // emitted brightness) for the UI beneath to show through — matching how
    // Solarbloom outputs premultiplied alpha. col is the emitted light, so
    // col_channel <= max(col) = alpha holds → valid premultiplied.
    col = max(col, 0.0);
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
