// Aurora — MSL fragment shader, ported from `aurora-shader.ts` (GLSL ES 3.00).
// macOS/iOS only (compiled into the effect's metallib by the Swift build on an
// Apple toolchain; on Linux it is an inert resource).
//
// Governing metaphor: HANGING CURTAINS OF POLAR LIGHT. The composition is a
// horizontal BAND of vertical light RIBBONS that drape across the upper field,
// sway, and sweep sideways, then gently brighten and fade. It is
// DIRECTIONAL/curtain — emphatically NOT a radial bloom: no bright core, no
// concentric falloff, no origin read. Layers, all summed as light (presented
// through the `screen`-blended light layer; the shadow pass through a `multiply`
// layer):
//   1. SKY WASH — a faint cool gradient hugging the top of the band.
//   2. THE CURTAINS — several vertical ribbons, fbm-displaced + swept sideways,
//      with vertical striations riding each ribbon.
//   3. RAYS — faint searchlight pillars inside the curtains, twinkling.
//   4. CROWN SHIMMER — a slow hue/intensity breathing as the band settles.
// finished with a filmic (ACES) tonemap + an ordered dither (+ an optional hard
// cel posterize toward the whimsy end).
//
// The shared building blocks come from DopamineLook.metal (one canonical copy).
//
// UNIFORM STRUCT — the GLSL→MSL binding seam. WebGL sets `u*` one-by-one; Metal
// reads ONE struct. The `AuroraUniforms` struct is GENERATED from the `.dope` by
// scripts/gen-uniforms.mjs (into AuroraUniforms.metal) — the SAME source that
// emits the Swift packer, so the two layouts cannot drift.

#include <metal_stdlib>
#include "DopamineLook.metal"
#include "AuroraUniforms.metal"   // @generated — struct AuroraUniforms
using namespace metal;

#define CURTAINS 7

// Full-screen triangle from vertex_id (no vertex buffers).
struct VSOut { float4 position [[position]]; };
vertex VSOut aurora_vertex(uint vid [[vertex_id]]) {
    VSOut o;
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// Vertical envelope of the curtain band: bright high in the band, feathering to
// nothing at the draped hem below and to a soft top above. ny is the normalized
// vertical position WITHIN the band (0 = hem/bottom, 1 = top), so the curtains
// hang from the top and fade downward like real sheets of light.
inline float bandProfile(float ny) {
    // Feather the bottom hem (long, soft) and the top (soft, generous) so the
    // curtain reads as a hanging SHEET — no hard edges top or bottom.
    float hem = smoothstep(0.0, 0.45, ny);          // long fade up from the hem
    float top = 1.0 - smoothstep(0.7, 1.0, ny);      // soft, early top falloff
    // Bias brightness upward (the top of a curtain glows hardest).
    float bias = mix(0.6, 1.0, smoothstep(0.1, 0.85, ny));
    return clamp(hem * top * bias, 0.0, 1.0);
}

// One curtain ribbon's coverage at horizontal position x (fraction 0..1) for a
// given band-vertical ny. Each ribbon has its OWN base x, sway phase and width;
// its centre is displaced by slow layered fbm (the living drift) + the global
// sweep, and is bowed slightly with height so the sheet drapes rather than
// standing dead-vertical. Returns 0..1 soft horizontal coverage.
inline float curtain(int i, float x, float ny, constant AuroraUniforms &u, thread float &along) {
    float fi = float(i);
    float2 h = dop_hash21(fi * 3.17 + u.auroraSeed);
    // Base horizontal slot, spread across the frame with a little jitter.
    float base = (fi + 0.5) / float(CURTAINS) + (h.x - 0.5) * 0.10;
    // Slow nature-informed drift: two fbm samples at different rates, scrolled by
    // time, so the ribbon wanders organically rather than oscillating mechanically.
    float n1 = dop_fbm(float2(fi * 1.7 + u.auroraSeed, ny * 1.3 + u.timeS * 0.13)) - 0.5;
    float n2 = dop_fbm(float2(fi * 0.9 + u.auroraSeed + 7.0, ny * 2.6 - u.timeS * 0.07)) - 0.5;
    float drift = (n1 * 0.7 + n2 * 0.3) * u.sway;
    // Drape bow: the hem swings further than the top (parallax of a hanging sheet).
    float bow = (h.y - 0.5) * u.sway * 0.6 * (1.0 - ny);
    float cx = base + drift + bow + u.sweep;
    along = x - cx;
    // Ribbon width breathes a touch per-ribbon; soft horizontal lobe.
    float w = mix(0.045, 0.085, h.y) * (0.85 + 0.3 * u.coverage);
    float cov = exp(-pow(along / w, 2.0));
    return cov;
}

// The full curtain field at fragment uv (0..1, y up): sum the ribbons (capped by
// coverage so low intensity shows fewer sheets), shaped vertically by the band
// profile, with vertical striations + searchlight rays riding the light. Outputs
// total coverage 'cov' and a 0..1 hue coordinate 'hue' (left->right across the
// band, wandering with the crown shimmer) for the palette.
inline float auroraField(float2 uv, constant AuroraUniforms &u, thread float &cov, thread float &hue) {
    // Vertical position within the band.
    float top = u.bandY + u.bandHeight;
    float bot = u.bandY - u.bandHeight;
    float ny = (uv.y - bot) / max(top - bot, 1e-3);     // 0 at hem, 1 at top
    float vprof = bandProfile(ny);
    cov = 0.0;
    hue = 0.0;
    if (vprof <= 0.0) return 0.0;

    // How many ribbons are "lit" scales with coverage (intensity): low intensity
    // shows a few calm sheets, high shows the full curtain.
    float lit = mix(2.5, float(CURTAINS), clamp(u.coverage, 0.0, 1.0));

    float total = 0.0;
    float hueAccum = 0.0;
    for (int i = 0; i < CURTAINS; i++) {
        float gate = clamp(lit - float(i), 0.0, 1.0);       // soft last-ribbon fade-in
        if (gate <= 0.0) break;
        float along;
        float c = curtain(i, uv.x, ny, u, along) * gate;
        if (c <= 0.001) continue;
        total += c;
        // Hue coordinate: ribbon's place across the band, nudged by its own offset.
        float hi = (float(i) + 0.5) / float(CURTAINS);
        hueAccum += c * hi;
    }
    cov = total * vprof;
    hue = total > 1e-3 ? hueAccum / total : 0.5;

    // Vertical STRIATIONS: fine fluting along the curtains (the characteristic
    // ribbon texture). A medium-frequency noise in x that gently darkens/brightens
    // narrow vertical lanes, only inside the lit region so the background stays
    // clean. Kept bounded so it textures the sheet without shredding its edge.
    float flute = dop_fbm(float2(uv.x * 55.0 + u.auroraSeed, uv.y * 4.0 - u.timeS * 0.2));
    float striate = 1.0 + u.striation * (flute - 0.5) * 0.7;
    cov *= striate;

    // SEARCHLIGHT RAYS: a few brighter vertical pillars that twinkle — soft, fairly
    // wide bands in x gated by a slow noise so they come and go. Scaled by the
    // existing coverage so rays live INSIDE the curtains, never as bare spikes.
    float rayBand = pow(max(0.0, sin(uv.x * 60.0 + dop_fbm(float2(uv.x * 5.0, u.timeS * 0.3)) * 5.0)), 3.0);
    float rayGate = smoothstep(0.5, 0.95, dop_fbm(float2(uv.x * 9.0 + u.auroraSeed, u.timeS * 0.25)));
    cov += rayBand * rayGate * u.rays * smoothstep(0.05, 0.5, cov) * 0.5;

    return cov;
}

// SHADOW silhouette — a cheap occlusion field for the curtain mass (no striation
// detail / rays), so the faint cast shadow tracks the hanging sheets without an
// extra heavy pass.
inline float auroraOcclusion(float2 frag, constant AuroraUniforms &u) {
    float2 uv = frag / u.resolution;
    float top = u.bandY + u.bandHeight;
    float bot = u.bandY - u.bandHeight;
    float ny = (uv.y - bot) / max(top - bot, 1e-3);
    float vprof = bandProfile(ny);
    if (vprof <= 0.0) return 0.0;
    float lit = mix(2.5, float(CURTAINS), clamp(u.coverage, 0.0, 1.0));
    float total = 0.0;
    for (int i = 0; i < CURTAINS; i++) {
        float gate = clamp(lit - float(i), 0.0, 1.0);
        if (gate <= 0.0) break;
        float along;
        total += curtain(i, uv.x, ny, u, along) * gate;
    }
    return clamp(total * vprof * u.amp, 0.0, 1.0);
}

inline float4 auroraShadowColor(float2 frag, constant AuroraUniforms &u) {
    float2 sp = frag - u.shadowOffset;
    float occ = auroraOcclusion(sp, u);
    float soft = u.shadowSoft;
    occ += auroraOcclusion(sp + float2( soft, 0.0), u);
    occ += auroraOcclusion(sp + float2(-soft, 0.0), u);
    occ += auroraOcclusion(sp + float2(0.0,  soft), u);
    occ += auroraOcclusion(sp + float2(0.0, -soft), u);
    occ /= 5.0;
    // A real aurora casts almost no shadow; keep it very faint.
    float dark = clamp(occ, 0.0, 1.0) * u.shadowStrength * 0.35;
    float3 tint = mix(float3(1.0), 0.6 + 0.4 * normalize(u.c0 + 1e-3), 0.2);
    float3 mul = mix(float3(1.0), tint, dark);
    return float4(mul, 1.0);
}

fragment float4 aurora_fragment(
    VSOut in [[stage_in]],
    constant AuroraUniforms &u [[buffer(0)]]
) {
    // Metal's [[position]] is TOP-left origin (y down); the ported GLSL math
    // (gl_FragCoord, uv.y up, the band hanging from the top) is bottom-left
    // (y up). Flip y once here so the whole shader works in the y-up space it was
    // written for (otherwise the curtains hang from the bottom).
    float2 frag = float2(in.position.x, u.resolution.y - in.position.y);
    float2 res = u.resolution;

    if (u.shadow > 0.5) {
        return auroraShadowColor(frag, u);
    }

    float2 uv = frag / res;
    float3 col = float3(0.0);
    float gain = u.amp * u.exposure;

    // ---- SKY WASH: a faint cool glow the curtains hang from. ----
    // A soft horizontal band centred near the top of the curtain band, so there is
    // a gentle ground for the light without a radial core.
    float washY = exp(-pow((uv.y - (u.bandY + u.bandHeight * 0.45)) / max(u.bandHeight, 1e-3), 2.0));
    col += mix(u.c0, u.c2, 0.5) * washY * 0.06 * gain;

    // ---- THE CURTAINS ----
    float cov, hue;
    auroraField(uv, u, cov, hue);

    // CROWN SHIMMER: the aurora pulses — a slow drift of the hue coordinate and a
    // gentle global breathing of intensity, so the colour wanders as it settles.
    float pulse = 0.85 + 0.15 * sin(u.timeS * 0.9 + hue * 4.0 + u.auroraSeed);
    float hueShift = hue + 0.15 * sin(u.timeS * 0.4 + u.auroraSeed * 6.28) + 0.1 * (dop_fbm(float2(uv.x * 3.0, u.timeS * 0.2)) - 0.5);

    float3 curtainCol = dop_paletteMix(clamp(hueShift, 0.0, 1.0), u.c0, u.c1, u.c2);
    col += curtainCol * clamp(cov, 0.0, 4.0) * pulse * gain;

    // A subtle brighter crown along the very top edge of each lit column (where a
    // real curtain glows hottest), tinted toward the accent.
    float crown = smoothstep(0.0, 0.5, cov) * smoothstep(u.bandY + u.bandHeight * 0.2, u.bandY + u.bandHeight, uv.y);
    col += u.c2 * crown * 0.4 * gain;

    // ---- Tone + finishing (ACES filmic, shared look) ----
    col = dop_tonemapACES(col * 0.9);

    // ---- Non-photoreal pass: hard CEL posterized ribbons (whimsy) ----
    // Toward the cel end the soft volumetric curtains snap into flat posterized
    // bands with crisp edges + a bright rim — a stylized stained-glass aurora.
    if (u.style > 0.001) {
        // Posterize the curtain luminance into a few hard tones (don't quantize the
        // dark background — that shatters the wash into camouflage blocks).
        float lum = clamp(cov * pulse * u.exposure * u.amp, 0.0, 1.5);
        float steps = mix(6.0, 3.0, u.style);              // fewer bands at full cel
        float q = floor(lum * steps) / steps;
        float3 celCol = dop_paletteMix(clamp(hueShift, 0.0, 1.0), u.c0, u.c1, u.c2) * (q * 1.15 + 0.05);
        // Bright crisp rim at each posterized step edge.
        float band = lum * steps;
        float edge = abs(fract(band) - 0.5);
        float rim = (1.0 - smoothstep(0.0, 0.12, edge)) * smoothstep(0.06, 0.2, lum);
        celCol += clamp(u.c2 * 1.5 + 0.1, 0.0, 1.4) * rim * 0.6;
        float mask = smoothstep(0.04, 0.14, lum);          // only inside the curtains
        float3 styled = mix(col, celCol, mask);
        col = mix(col, styled, u.style);
    }

    // Ordered dither (~1/255, shared look) to kill banding the screen blend would
    // reveal on the page beneath; faded out toward the cel end.
    col = dop_ditherAdd(col, frag, u.timeS, 1.0 - u.style);

    // PREMULTIPLIED-alpha output: alpha = the light's own brightness. Dark regions
    // become transparent so the UI beneath shows through, and bright curtains read
    // as cast light over it. col is the emitted light, so col_channel <= max(col)
    // = alpha holds → valid premultiplied. (The web returns opaque alpha=1 over a
    // black canvas composited `screen`; on Metal we encode that brightness as
    // premultiplied alpha, exactly as Solarbloom does.)
    col = max(col, 0.0);
    float outA = clamp(max(max(col.r, col.g), col.b), 0.0, 1.0);
    return float4(col, outA);
}
