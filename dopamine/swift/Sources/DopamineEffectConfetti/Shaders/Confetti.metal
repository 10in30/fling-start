// Confetti — MSL fragment shader, ported from `confetti-shader.ts`
// (GLSL ES 3.00). macOS/iOS only (compiled into the effect's metallib by the
// Swift build on an Apple toolchain; on Linux it is an inert resource).
//
// One full-screen pass renders a burst of paper confetti as light (presented
// through the `screen`-blended light layer; the shadow pass through a `multiply`
// layer). Each of MAX_PIECES pieces:
//   1. LAUNCHES upward from `u.origin` in a cone (a sharp pop at t≈0), then
//   2. TUMBLES DOWN under gravity — the signature physical, fluttering fall. The
//      shared `dop_ballisticPos` (launch dir * speed * t − gravity * t²) gives the
//      up-then-down arc; on top of it we add an air-drag FLUTTER: a sideways sway
//      whose amplitude grows as the piece slows + falls (paper catching air), and
//   3. SPINS — each rectangle/petal rotates on its own axis, so it flashes wide
//      then edge-on (a brightness flicker as it presents face vs edge to "light").
// Pieces settle near the bottom and fade out over their life. A faint downward
// shadow silhouette is cast on the multiply pass. Finished with a filmic (ACES)
// tonemap + an ordered dither.
//
// Deliberately distinct from Solarbloom's motes (which drift UPWARD on buoyant
// curls): confetti is gravity-bound, sways, spins, and is shaped paper, not soft
// photons. Reuses the shared particle fade (dop_particleFade) so the lifetime
// curve stays canonical; the emit cone, flutter, spin + paper shape are
// confetti's own identity. The shared building blocks come from DopamineLook.metal
// (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `ConfettiUniforms` struct is now GENERATED from the
// `.dope` by scripts/gen-uniforms.mjs (into ConfettiUniforms.metal) — the SAME
// source that emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "ConfettiUniforms.metal"   // @generated — struct ConfettiUniforms
using namespace metal;

#define MAX_PIECES 120

// ballisticPos + rot2 are NOT in the shared DopamineLook chunk (which Solarbloom
// uses; copied here VERBATIM). The web composes them from `look/particles.glsl`
// (ballisticPos) + `look/glsl` (rot2); transcribed here as local `dop_`-prefixed
// helpers so DopamineLook.metal stays the byte-identical canonical copy.
//
// Ballistic arc: launch from `origin` along `dir` at `speed`, pulled down by
// `gravity` (device px) over normalized particle life `t` (0..1). Screen y is up,
// so gravity subtracts on y.
inline float2 dop_ballisticPos(float2 origin, float2 dir, float speed, float gravity, float t) {
    return origin + dir * speed * t - float2(0.0, 1.0) * gravity * t * t;
}
// 2D rotation. GLSL `mat2(c,-s,s,c)` is COLUMN-major: columns (c,-s), (s,c). MSL
// `float2x2(c0, c1)` takes COLUMNS, so it is transcribed as those column vectors.
inline float2x2 dop_rot2(float a) {
    float s = sin(a), c = cos(a);
    return float2x2(float2(c, -s), float2(s, c));
}

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut confetti_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Per-piece deterministic motion + pose. Given piece index i and minDim, returns
// the piece's current centre and writes its half-extents, rotation, face-flash
// factor + spawn-staggered life. All a pure function of u.timeS so a fixed-
// timestep capture reproduces the frame.
struct Piece {
    float2 pos;      // current centre, device px
    float2 halfSize; // half width/height of the paper rect, device px (face-scaled)
    float rot;       // current rotation (radians)
    float face;      // 0..1 how face-on the piece is (drives brightness flicker)
    float life;      // normalized particle life 0..1 (after spawn stagger)
    float hue;       // palette param 0..1
    float petal;     // 0..1 rectangle -> rounded petal blend
};

Piece pieceAt(int i, float minDim, constant ConfettiUniforms &u) {
    Piece pc;
    float fi = float(i);
    float2 h  = dop_hash21(fi * 12.13 + u.pieceSeed);
    float2 h2 = dop_hash21(fi * 7.37 + u.pieceSeed + 2.7);
    float h3 = dop_hash11(fi * 3.91 + u.pieceSeed + 9.1);

    // Spawn stagger: most pieces fire in the first ~12% (a sharp burst), a few
    // trail. life is renormalized so each piece runs its full arc within u.life.
    float delay = h2.x * 0.12;
    pc.life = clamp((u.life - delay) / (1.0 - delay), 0.0, 1.0);

    // Launch direction: a mostly-UP cone, fanned left/right by spread. Screen y is
    // up here, so the launch dir has a strong +y and a spread-scaled x.
    float fan = (h.x - 0.5) * 2.0;                 // -1..1
    float2 dir = normalize(float2(fan * (0.35 + u.spread), 1.0));
    float speed = (0.85 + h.y * 0.6) * u.launchSpeed * minDim * 1.15;
    float gravity = (0.9 + h3 * 0.4) * u.gravity * minDim * 1.5;

    // Ballistic arc (shared helper): up, then DOWN under gravity. This is the
    // signature — pieces rise off the launch then tumble back down past the origin.
    float2 base = dop_ballisticPos(u.origin, dir, speed, gravity, pc.life);

    // Air-drag FLUTTER: paper doesn't fall straight — it sways side to side, and
    // the sway grows as the piece slows + descends (more air resistance felt).
    // A per-piece phase + frequency keeps every piece swaying independently.
    float swayPhase = h.x * TAU + h2.y * 3.0;
    float swayFreq  = 3.0 + h2.x * 4.0;
    float fallT = smoothstep(0.12, 0.7, pc.life);  // ramps in as it starts to fall
    float swayAmp = u.flutter * minDim * 0.06 * (0.4 + fallT);
    float sway = sin(pc.life * swayFreq + swayPhase) * swayAmp
               + sin(pc.life * swayFreq * 0.37 + swayPhase * 1.7) * swayAmp * 0.4;
    // Sway is perpendicular to the launch dir (mostly horizontal).
    pc.pos = base + float2(1.0, 0.0) * sway;

    // SPIN: the piece tumbles. Rotation accumulates over its life; flutter also
    // modulates it (paper flips faster while sliding through air). The face-flash
    // is the |cos| of the spin: wide (bright) when face-on, dim edge-on.
    float spinRate = (3.0 + h3 * 6.0) * u.spin;
    pc.rot = pc.life * spinRate * TAU + swayPhase;
    float flip = abs(cos(pc.rot * 0.5 + sway * 0.02));
    pc.face = mix(0.18, 1.0, flip);

    // Paper shape: small rectangles, a few squarer, a few elongated streamers.
    float aspect = mix(0.5, 1.6, h2.y);
    float s = minDim * 0.011 * u.pieceSize * (0.7 + h.y * 0.7);
    pc.halfSize = float2(s * aspect, s) * mix(1.0, pc.face, 0.65); // foreshorten by face
    pc.hue = fract(h2.y * 0.9 + h3 * 0.31);
    pc.petal = step(0.78, h3);                                // ~22% petals
    return pc;
}

// Coverage of one paper piece at frag p. Rotate p into the piece's local frame
// then test a rounded box (rect) or a soft ellipse (petal). Returns 0..1.
float pieceCoverage(Piece pc, float2 p) {
    float2 q = dop_rot2(-pc.rot) * (p - pc.pos);
    float2 he = max(pc.halfSize, float2(0.5));
    if (pc.petal > 0.5) {
        // Rounded petal: normalized radial falloff.
        float2 e = q / he;
        float r = length(e);
        return 1.0 - smoothstep(0.7, 1.05, r);
    }
    // Rounded rectangle (soft edges so it antialiases + reads as paper, not pixels).
    float2 d = abs(q) - he;
    float outside = length(max(d, 0.0));
    float inside = min(max(d.x, d.y), 0.0);
    float sd = outside + inside;
    float edge = max(min(he.x, he.y) * 0.35, 1.0);
    return 1.0 - smoothstep(-edge, edge, sd);
}

// ---------------------------------------------------------------------------
// SHADOW silhouette — a cheap occlusion field of the falling pieces for the
// multiply pass. We only need where paper is "solid enough" to block light; no
// face-flash or palette, just mass. Cheaper than the light pass.
// ---------------------------------------------------------------------------
float confettiOcclusion(float2 p, float minDim, constant ConfettiUniforms &u) {
    float occ = 0.0;
    for (int i = 0; i < MAX_PIECES; i++) {
        if (float(i) >= u.pieceCount) break;
        Piece pc = pieceAt(i, minDim, u);
        if (pc.life <= 0.0 || pc.life >= 1.0) continue;
        float cov = pieceCoverage(pc, p);
        float fade = dop_particleFade(pc.life, 1.4);
        occ += cov * fade * 0.6;
    }
    return clamp(occ * u.amp, 0.0, 1.0);
}

float4 shadowColor(float2 frag, float minDim, constant ConfettiUniforms &u) {
    float2 sp = frag - u.shadowOffset;
    float occ = confettiOcclusion(sp, minDim, u);
    // 4-tap cross blur for a soft penumbra (pieces are small; a light blur is enough).
    float soft = u.shadowSoft;
    occ += confettiOcclusion(sp + float2( soft, 0.0), minDim, u);
    occ += confettiOcclusion(sp + float2(-soft, 0.0), minDim, u);
    occ += confettiOcclusion(sp + float2(0.0,  soft), minDim, u);
    occ += confettiOcclusion(sp + float2(0.0, -soft), minDim, u);
    occ /= 5.0;
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength;
    float3 tint = mix(float3(1.0), 0.6 + 0.4 * normalize(u.c0 + 1e-3), 0.2);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 confetti_fragment(
    VSOut in [[stage_in]],
    constant ConfettiUniforms &u [[buffer(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math and
    // u.origin are bottom-left (y up). Flip y once here so the whole shader works
    // in the y-up space it was written for (otherwise the launch arc + sway
    // render upside down — pieces would fall UP).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float minDim = min(u.resolution.x, u.resolution.y);

    if (u.shadow > 0.5) {
        return shadowColor(frag, minDim, u);
    }

    float3 col = float3(0.0);
    float gain = u.amp * u.exposure;

    for (int i = 0; i < MAX_PIECES; i++) {
        if (float(i) >= u.pieceCount) break;
        Piece pc = pieceAt(i, minDim, u);
        if (pc.life <= 0.0 || pc.life >= 1.0) continue;

        float cov = pieceCoverage(pc, frag);
        if (cov <= 0.0) continue;

        float fade = dop_particleFade(pc.life, 1.4);
        float3 base = dop_paletteMix(pc.hue, u.c0, u.c1, u.c2);

        // PHOTOREAL (style 0): soft paper shading. The face-flash darkens/brightens
        // the piece as it spins (face-on = lit, edge-on = dim), plus a soft inner
        // gradient so it reads as a curved sheet, not a flat sticker. A faint
        // specular catch at the brightest face angles sells the glossy paper.
        float shade = mix(0.45, 1.15, pc.face);
        float3 paper = base * shade;
        float spec = smoothstep(0.85, 1.0, pc.face) * 0.5;
        paper += float3(1.0) * spec * cov;

        // CEL (style 1): flat, posterized shapes with a hard rim — animate-on-twos
        // (the clock is already snapped by style in the runner). Two-tone face/edge.
        float3 cel = base * mix(0.55, 1.1, step(0.5, pc.face));
        // Hard bright rim on the leading edge of the shape.
        float rim = smoothstep(0.0, 0.25, cov) * (1.0 - smoothstep(0.55, 0.9, cov));
        cel = mix(cel, base + 0.35, rim * 0.5);

        float3 lit = mix(paper, cel, u.style);
        col += lit * cov * fade * gain * 1.35;
    }

    // Filmic tonemap (graceful highlight rolloff at dense electric bursts).
    col = dop_tonemapACES(col * 0.85);

    // Cel posterize at the whimsy end: punch saturation + quantize into hard bands.
    if (u.style > 0.001) {
        float l = dot(col, float3(0.299, 0.587, 0.114));
        float3 neon = clamp(l + (col - l) * 1.5, 0.0, 1.0);
        float3 styled = mix(col, neon, 0.65);
        float bands = mix(40.0, 5.0, u.style);
        styled = floor(styled * bands + 0.5) / bands;
        col = mix(col, styled, u.style);
    }

    // Ordered dither (shared dop_ditherAdd) to break screen-blend banding; faded
    // out toward the cel end where hard bands are the intended look.
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark
    // regions become transparent so the UI beneath shows through, and bright
    // confetti reads as cast light over it (the web composites the black canvas
    // with `mix-blend-mode: screen`; here the equivalent premultiplied alpha is
    // the max channel — col is the emitted light, so col_channel <= alpha holds).
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
