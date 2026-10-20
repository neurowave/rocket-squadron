// Curved helmet-visor glass carrying the HUD artboard texture: gentle barrel
// bow, refined edge-only chroma, holographic glow, faint sky reflection and
// fresnel on the glass edges, boot sweep and damage glitch.
struct Visor {
    mvp: mat4x4<f32>,
    a: vec4<f32>,      // x boot 0..1, y glitch 0..1, z opacity, w time
    tint: vec4<f32>,   // glass tint rgb, a glass tint amount
    b: vec4<f32>,      // x scanlines, y edge glow, z flicker, w chroma
    c: vec4<f32>,      // xy hud texel size, z glow amount, w pixel scale (output h / 1080)
    sky: vec4<f32>,    // rgb sky reflection color, w damage tint
    sway: vec4<f32>,   // x yaw, y pitch, z roll, w sheen amount
    d: vec4<f32>,      // x curvature (0 flat .. 1 helmet wrap), y rim alpha at the HUD edge, z skirt alpha, w skirt uv margin
    e: vec4<f32>,      // rim containment pulls, x axis: left at bottom / top, right at bottom / top
    f: vec4<f32>,      // rim containment pulls, y axis: bottom at left / right, top at left / right
    g: vec4<f32>,      // x NDC the skirt's outer edge is kept past, y how much (0 while booting)
};
@group(0) @binding(0) var<uniform> U: Visor;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var hud: texture_2d<f32>;

struct VIn {
    @location(0) flat: vec3<f32>,  // screen-filling pane
    @location(1) pos: vec3<f32>,   // helmet shell
    @location(2) uv: vec2<f32>,    // HUD uv; outside 0..1 is the dark glass skirt
};
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

// pulls one screen axis back toward the centre by `a` on its side: ~0 at the
// centre, ~linear toward the rim (renderer VISOR_CONTAIN_E 0.3); fades out
// across the skirt (`out`: uv past the HUD rect)
fn contain(v: f32, aN: f32, aP: f32, out: f32) -> f32 {
    let a = select(aN, aP, v > 0.0) * (1.0 - smoothstep(0.0, U.d.w, out));
    let m = min(abs(v), 1.0);
    return v - sign(v) * a * (sqrt(m * m + 0.09) - 0.3);
}

@vertex
fn vs_main(i: VIn) -> VOut {
    var o: VOut;
    var c = U.mvp * vec4<f32>(mix(i.flat, i.pos, U.d.x), 1.0);
    // HUD content stays inside the 4% screen margin (renderer writeVisor);
    // each side's pull runs linearly between its two corners
    if (c.w > 1e-4) {
        let n = c.xy / c.w;
        let ov = vec2<f32>(max(-i.uv.x, i.uv.x - 1.0), max(-i.uv.y, i.uv.y - 1.0));
        let s = saturate(n * 0.5 + 0.5);
        var p = vec2<f32>(
            contain(n.x, mix(U.e.x, U.e.y, s.y), mix(U.e.z, U.e.w, s.y), ov.x),
            contain(n.y, mix(U.f.x, U.f.y, s.x), mix(U.f.z, U.f.w, s.x), ov.y));
        // the skirt's outer edge stays past the screen edge, so the dark
        // glass always meets it (no bare world at the 21:9 top / bottom middle)
        let t = smoothstep(vec2<f32>(0.0), vec2<f32>(U.d.w), ov) * U.g.y;
        p = mix(p, sign(p) * max(abs(p), vec2<f32>(U.g.x)), t);
        c = vec4<f32>(p * c.w, c.z, c.w);
    }
    o.clip = c;
    o.uv = i.uv;
    return o;
}

fn hash1(x: f32) -> f32 {
    return fract(sin(x * 91.3458) * 47453.5453);
}

fn over(dst: vec4<f32>, src: vec4<f32>) -> vec4<f32> {
    return src + dst * (1.0 - src.a);
}

@fragment
fn fs_main(v: VOut) -> @location(0) vec4<f32> {
    let t = U.a.w;
    let boot = clamp(U.a.x, 0.0, 1.0);
    let rimCol = vec3<f32>(0.02, 0.05, 0.1);

    // skirt: dark helmet glass continuing past the HUD to the screen edge.
    // The HUD taps are explicit-LOD samples (the canvas has one mip level, so
    // the same texels as textureSample), so a skirt pixel returns here and a
    // pixel with no chroma offset skips two taps (EFFICIENCY_REVIEW 1.9)
    let outD = max(max(-v.uv.x, v.uv.x - 1.0), max(-v.uv.y, v.uv.y - 1.0));
    let skK = smoothstep(0.0, 1.0, clamp(outD / max(U.d.w, 1e-3), 0.0, 1.0));
    let skA = mix(U.d.y, U.d.z, skK);
    let dyS = abs(clamp(v.uv.y, 0.0, 1.0) - 0.5) * 2.0;
    let shownS = 1.0 - smoothstep(boot * 1.12 - 0.01, boot * 1.12, dyS);
    // a faint cool fresnel line right at the glass edge
    let edgeLine = (1.0 - smoothstep(0.0, 0.012, outD)) * 0.35;
    let skCol = mix(rimCol, rimCol * 0.4, skK) + U.sky.rgb * edgeLine * 0.5;
    let skirt = vec4<f32>(skCol * skA, skA) * shownS * U.a.z;
    if (outD > 0.0) {
        return skirt;
    }
    let glitch = clamp(U.a.y, 0.0, 1.0);
    let texel = U.c.xy;
    var uv = v.uv;

    // damage glitch: blocky slice displacement on a few rows
    if (glitch > 0.0) {
        let rows = 22.0;
        let row = floor(uv.y * rows);
        let tick = floor(t * 24.0);
        let n = hash1(row * 1.7 + tick * 3.1);
        if (n > 1.0 - glitch * 0.55) {
            uv.x += (hash1(row * 3.1 + tick) - 0.5) * 0.05 * glitch;
        }
        let blk = hash1(floor(uv.y * 6.0) * 5.3 + tick * 0.7);
        if (blk > 1.0 - glitch * 0.2) {
            uv.x += 0.012 * glitch * sign(blk - 0.95);
        }
    }

    // boot: reveal from the center line outward
    let dy = abs(v.uv.y - 0.5) * 2.0;
    let reveal = boot * 1.12;
    let shown = 1.0 - smoothstep(reveal - 0.01, reveal, dy);

    // HUD with chroma that only appears toward the edges (or while glitching)
    let rc = uv - vec2<f32>(0.5);
    // no split across the central 60%: fringes only toward the rim
    let edgeK = smoothstep(0.09, 0.3, dot(rc, rc));
    let chOff = rc * texel.x * (U.b.w * 5.0 * edgeK) + vec2<f32>(texel.x * 5.0 * glitch, 0.0);
    let cg = textureSampleLevel(hud, samp, uv, 0.0);
    var cr = cg;
    var cb = cg;
    if (chOff.x != 0.0 || chOff.y != 0.0) {
        cr = textureSampleLevel(hud, samp, uv + chOff, 0.0);
        cb = textureSampleLevel(hud, samp, uv - chOff, 0.0);
    }
    var c = vec4<f32>(cr.r, cg.g, cb.b, max(cg.a, max(cr.a, cb.a)));
    // thin the translucent glass fills (they tint the whole view blue); strokes,
    // text and solid panels keep their full strength
    c *= mix(0.6, 1.0, smoothstep(0.2, 0.6, c.a));

    // holographic glow: soft cyan halo from a few wide taps
    let go = texel * 3.0 * U.c.w;
    let g1 = textureSampleLevel(hud, samp, uv + vec2<f32>(go.x, go.y), 0.0).a;
    let g2 = textureSampleLevel(hud, samp, uv + vec2<f32>(-go.x, go.y), 0.0).a;
    let g3 = textureSampleLevel(hud, samp, uv + vec2<f32>(go.x, -go.y), 0.0).a;
    let g4 = textureSampleLevel(hud, samp, uv + vec2<f32>(-go.x, -go.y), 0.0).a;
    // only strokes and text glow (translucent panel fills would wash the view)
    let glowA = (smoothstep(0.55, 0.95, g1) + smoothstep(0.55, 0.95, g2) + smoothstep(0.55, 0.95, g3) + smoothstep(0.55, 0.95, g4)) * 0.25 * U.c.z;
    let glowC = vec3<f32>(0.35, 0.8, 1.0);

    // fine scanlines across the content only
    let scan = 0.5 + 0.5 * sin(v.clip.y * 3.14159 / max(U.c.w * 1.5, 1.0));
    c = vec4<f32>(c.rgb * (1.0 - U.b.x * 0.18 * scan), c.a);

    // boot: content arrives as a cyan hologram with jitter, then settles
    if (boot < 0.999) {
        let holo = 1.0 - smoothstep(0.55, 1.0, boot);
        let fl = step(0.3, hash1(floor(t * 30.0) + floor(uv.y * 40.0)));
        c = vec4<f32>(mix(c.rgb, glowC * c.a * 1.2, holo * 0.7) * mix(1.0, fl, holo * 0.6), c.a);
    }
    // damage: red tint on the content
    c = vec4<f32>(mix(c.rgb, vec3<f32>(1.0, 0.25, 0.2) * c.a, U.sky.w * 0.5), c.a);

    // glass: faint tint, fresnel edges carrying the sky, a soft diagonal sheen
    let ex = (v.uv.x - 0.5) * 2.0;
    let ey = (v.uv.y - 0.5) * 2.0;
    let er = length(vec2<f32>(ex * 0.92, ey));
    let fres = smoothstep(0.98, 1.32, er);
    let topLight = smoothstep(0.2, -1.0, ey);
    let skyRefl = U.sky.rgb * (0.5 + 0.5 * topLight);
    var glass = vec4<f32>(U.tint.rgb * U.tint.a, U.tint.a);
    // darken toward the HUD edge so it meets the skirt with no seam
    let eIn = min(min(v.uv.x, 1.0 - v.uv.x), min(v.uv.y, 1.0 - v.uv.y));
    let rimK = 1.0 - smoothstep(0.0, 0.07, eIn);
    glass = over(glass, vec4<f32>(rimCol * U.d.y * rimK, U.d.y * rimK));
    let rimA = fres * U.b.y * 0.4;
    glass = over(glass, vec4<f32>(skyRefl * rimA, rimA * 0.8));
    let sd = dot(vec2<f32>(ex, ey), normalize(vec2<f32>(1.0, 0.55))) + U.sway.x * 1.5 + 0.35;
    let sheen = (1.0 - smoothstep(0.0, 0.07, abs(sd))) * 0.6 + (1.0 - smoothstep(0.0, 0.03, abs(sd - 0.16))) * 0.4;
    let shA = sheen * U.sway.w * (0.4 + 0.6 * smoothstep(0.1, 0.9, er));
    glass = over(glass, vec4<f32>(vec3<f32>(1.0) * shA, shA * 0.5));

    var outc = over(glass, vec4<f32>(glowC * glowA, glowA * 0.35));
    outc = over(outc, c);
    outc = outc * shown;

    // boot scan edge
    let scanEdge = (1.0 - smoothstep(0.0, 0.012, abs(dy - reveal))) * (1.0 - step(0.999, boot));
    outc = over(outc, vec4<f32>(vec3<f32>(0.55, 0.92, 1.0) * scanEdge, scanEdge * 0.8));
    // glitch: a few bright tearing bands across the glass
    if (glitch > 0.0) {
        let band = floor(v.uv.y * 36.0);
        let tick = floor(t * 18.0);
        let dl = step(1.0 - glitch * 0.06, hash1(band * 2.7 + tick * 1.3));
        let thin = 1.0 - smoothstep(0.0, 0.18, abs(fract(v.uv.y * 36.0) - 0.5));
        outc = over(outc, vec4<f32>(vec3<f32>(0.55, 0.9, 1.0) * dl * thin * 0.35, dl * thin * 0.25));
    }

    // flicker
    let fl = 1.0 - U.b.z * step(0.5, hash1(floor(t * 24.0))) * 0.3;
    return outc * U.a.z * fl;
}
