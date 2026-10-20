// Final composite: screen-space ink edges from the normal/depth buffer, bloom,
// highlight shoulder, per-biome grade, radial speed lines, vignette, damage
// pulse, grain, flash, fades, letterbox, the portal lens and the portal dive
// (swirl + zoom blur + toon tunnel), and the set-piece sting looks: the
// bullet-time grade and the print flash (ROCKET SQUADRON print palette).
struct Post {
    screen: vec4<f32>,     // w, h, 1/w, 1/h (output)
    a: vec4<f32>,          // x exposure, y vignette, z speed lines, w chroma
    b: vec4<f32>,          // x damage, y fade, z letterbox, w time
    fadeColor: vec4<f32>,  // rgb, w 2 = a quality tier scaled the world (edgesUp), else 1
    grade: vec4<f32>,      // x saturation, y contrast, z warmth, w grain
    flash: vec4<f32>,      // rgb, a amount
    portal: vec4<f32>,     // x dive 0..1, y cx, z cy, w radius (uv units)
    focus: vec4<f32>,      // xy speed-line center in uv, z bloom strength, w ink edge strength
    ink: vec4<f32>,        // rgb ink color, w edge fade distance (m)
    src: vec4<f32>,        // render target w, h, 1/w, 1/h
    lens: vec4<f32>,       // portal lens: cx, cy, radius (uv y units), strength
    tone: vec4<f32>,       // x biome, y fog blend for ink, z crease ink amount, w portal lens distance (m)
    fog: vec4<f32>,        // rgb fog color, w boost-kick zoom smear 0..1
    sting: vec4<f32>,      // x bullet-time grade 0..1, y print flash 0..1, z plate angle, w seconds since the print fired
    split: vec4<f32>,      // x 3.1: near-side ink weight added on MED / LOW in fs_head (0 on every tier today); yzw spare
    plate0: vec4<f32>,     // JOB 26 print plates: x PrintScreen red, y blue amount, z its roller edge, w the sting card's (px)
    plate1: vec4<f32>,     // x sting crimson, y dense, z blue amount, w 1 = composite the visor offscreen first
};
@group(0) @binding(0) var<uniform> P: Post;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var scene: texture_2d<f32>;
@group(0) @binding(3) var gbuf: texture_2d<f32>;
@group(0) @binding(4) var bloom: texture_2d<f32>;
@group(0) @binding(6) var visorTex: texture_2d<f32>;   // JOB 26: the visor alone (premultiplied), on plate frames

// JOB 26: the print plates (the one-ink print of the title / pause / results / game over screens and the sting
// cards), done here instead of 4 blend layers per plate in the screens (PrintScreen, StingCard). Each
// plate applies, in the old layers' order, every step mixed by its amount (the layers took the node opacity each):
// saturation with grey (luminosity .30 / .59 / .11), colorBurn with grey b, screen the ink, multiply the paper.
// On gamma-encoded values, as Rive blended them in the 8-bit target.
fn plateInk(c: vec3<f32>, a: f32, ink: vec3<f32>, paper: vec3<f32>, b: f32) -> vec3<f32> {
    let l = dot(c, vec3<f32>(0.30, 0.59, 0.11));
    var x = mix(c, vec3<f32>(l), a);
    let bu = select(max(vec3<f32>(0.0), vec3<f32>(1.0) - (vec3<f32>(1.0) - x) / b), vec3<f32>(1.0), x >= vec3<f32>(1.0));
    x = mix(x, bu, a);
    x = x + a * ink * (vec3<f32>(1.0) - x);
    return x * (vec3<f32>(1.0 - a) + a * paper);
}

// the plates up over a final colour at pixel px (the visor composited first when the plates print it)
fn printPlates(c0: vec3<f32>, px: vec2<f32>) -> vec3<f32> {
    var c = c0;
    if (P.plate1.w > 0.5) {
        let vz = textureLoad(visorTex, vec2<i32>(px), 0);
        // (clamped as the 8-bit target clamped the visor's blend: its glow / sheen / rim add more colour than alpha)
        c = min(vz.rgb + c * (1.0 - vz.a), vec3<f32>(1.0));
    }
    let amt = P.plate0.x + P.plate0.y + P.plate1.x + P.plate1.y + P.plate1.z;
    if (amt <= 0.0) {
        return c;
    }
    // the rollers' masks: printed past the edge, along (cos 0.3, sin 0.3) from the centre (antialiased over a pixel)
    let d = dot(px - 0.5 * P.screen.xy, vec2<f32>(0.95533649, 0.29552021));
    let kp = clamp(d - P.plate0.z + 0.5, 0.0, 1.0);
    let ks = clamp(d - P.plate0.w + 0.5, 0.0, 1.0);
    let paper = vec3<f32>(242.0, 236.0, 222.0) / 255.0;
    let blue = vec3<f32>(36.0, 51.0, 181.0) / 255.0;
    c = plateInk(c, P.plate0.x * kp, vec3<f32>(158.0, 24.0, 70.0) / 255.0, vec3<f32>(246.0, 232.0, 228.0) / 255.0, 168.0 / 255.0);
    c = plateInk(c, P.plate0.y * kp, blue, paper, 178.0 / 255.0);
    c = plateInk(c, P.plate1.x * ks, vec3<f32>(216.0, 36.0, 95.0) / 255.0, vec3<f32>(244.0, 230.0, 218.0) / 255.0, 158.0 / 255.0);
    c = plateInk(c, P.plate1.y * ks, vec3<f32>(23.0, 32.0, 127.0) / 255.0, paper, 147.0 / 255.0);
    c = plateInk(c, P.plate1.z * ks, blue, paper, 178.0 / 255.0);
    return clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
}

struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VOut {
    let x = f32((idx << 1u) & 2u);
    let y = f32(idx & 2u);
    var o: VOut;
    o.clip = vec4<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    o.uv = vec2<f32>(x, y);
    return o;
}

const TAU: f32 = 6.2831853;
// brand print palette: cobalt ink, cream paper, crimson spot
const INK_C: vec3<f32> = vec3<f32>(0.141, 0.2, 0.71);
const PAPER_C: vec3<f32> = vec3<f32>(0.949, 0.925, 0.871);
const CRIMSON_C: vec3<f32> = vec3<f32>(0.847, 0.141, 0.373);

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn hashi(x: i32, y: i32) -> f32 {
    return f32(pcg(bitcast<u32>(x) + pcg(bitcast<u32>(y)))) * (1.0 / 4294967295.0);
}
fn hash2(p: vec2<f32>) -> f32 {
    let q = vec2<i32>(floor(p));
    return hashi(q.x, q.y);
}

// Distance outside the hero safe zone (DIRECTION #16), in zone half-extents:
// 0 inside. Landscape x 0.30-0.70, y 0.42-0.72; portrait x 0.25-0.75,
// y 0.34-0.58. Boost smear and speed lines stay out of it at every aspect.
fn heroZone(uv: vec2<f32>, aspect: f32) -> f32 {
    let portrait = aspect < 1.0;
    let c = select(vec2<f32>(0.5, 0.57), vec2<f32>(0.5, 0.46), portrait);
    let hs = select(vec2<f32>(0.2, 0.15), vec2<f32>(0.25, 0.12), portrait);
    let e = max(abs(uv - c) / hs - vec2<f32>(1.0), vec2<f32>(0.0));
    return length(e);
}

fn lum(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

// Print halftone: 1 inside a dot of radius `rad` (cell units, 0..0.72) on a
// screen of `cell` output pixels turned by `ang`; ~1 px antialiased edge.
fn screenDot(px: vec2<f32>, ang: f32, cell: f32, rad: f32) -> f32 {
    let c = cos(ang);
    let s = sin(ang);
    let q = vec2<f32>(c * px.x - s * px.y, s * px.x + c * px.y) / cell;
    let d = length(fract(q) - vec2<f32>(0.5));
    let aa = 0.8 / cell;
    return (1.0 - smoothstep(rad - aa, rad + aa, d)) * step(0.002, rad);
}

fn swirlAround(uv: vec2<f32>, c: vec2<f32>, amount: f32, radius: f32, aspect: f32) -> vec2<f32> {
    var d = uv - c;
    d.x *= aspect;
    let r = length(d);
    let k = amount * exp(-r / max(radius, 0.001));
    let ang = k * 6.0;
    let cs = cos(ang);
    let sn = sin(ang);
    var rd = vec2<f32>(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
    rd.x /= aspect;
    return c + rd * (1.0 - k * 0.3);
}

// Second difference of inverse depth along one axis (flat planes cancel).
// One-pixel features (mesh cracks, the pixel beside one) are ignored.
fn axisEdge(zl2: f32, zl: f32, zc: f32, zr: f32, zr2: f32) -> f32 {
    let dl = zl - zc;
    let dr = zr - zc;
    if (dl * dr > 0.0 && min(abs(dl), abs(dr)) > 0.3 * max(abs(dl), abs(dr))) {
        return 0.0;
    }
    var e = abs(dl + dr);
    if (abs(dr) > abs(dl)) {
        if (abs(zr2 - zc) < 0.5 * abs(dr)) {
            e = 0.0;
        }
    } else {
        if (abs(zl2 - zc) < 0.5 * abs(dl)) {
            e = 0.0;
        }
    }
    return e;
}

fn invd(g: vec4<f32>) -> f32 {
    return 1.0 / max(g.w, 0.05);
}

// Ink weight of a gbuffer texel: toon.wgsl writes fading instances' normals
// longer (1 + 0.45 fade, squared 1..2.1); sky / water / unit normals give 1.
fn inkW(g: vec4<f32>) -> f32 {
    return 1.0 - clamp((dot(g.xyz, g.xyz) - 1.04) * 0.94, 0.0, 1.0);
}

// (distance, ink weight) of the nearer of the two: an edge belongs to the
// silhouette in front, so a solid object keeps its ink over a fading chunk
fn nearW(best: vec2<f32>, g: vec4<f32>) -> vec2<f32> {
    return select(best, vec2<f32>(g.w, inkW(g)), g.w < best.x);
}

// Ink from depth discontinuities and creases (normal differences).
// Returns (edge, min depth).
fn edgesT(c: vec4<f32>, l: vec4<f32>, r: vec4<f32>, u: vec4<f32>, d: vec4<f32>, l2: vec4<f32>, r2: vec4<f32>, u2: vec4<f32>, d2: vec4<f32>) -> vec2<f32> {
    let dmin0 = min(c.w, min(min(l.w, r.w), min(u.w, d.w)));
    // solid sprites (billboard fs_mask, normal.x = 3): no ink traced through them
    let mk = max(max(max(c.x, l.x), max(r.x, u.x)), max(max(d.x, l2.x), max(max(r2.x, u2.x), d2.x)));
    if (mk > 1.5) {
        return vec2<f32>(0.0, dmin0);
    }
    let zc = invd(c);
    let zmax = max(zc, max(max(invd(l), invd(r)), max(invd(u), invd(d))));
    let ex = axisEdge(invd(l2), invd(l), zc, invd(r), invd(r2));
    let ey = axisEdge(invd(u2), invd(u), zc, invd(d), invd(d2));
    let lap = (ex + ey) / max(zmax, 1e-6);
    let de = smoothstep(0.12, 0.3, lap);
    // creases (normals) are left to the ink hulls: the faceted rock meshes would
    // ink every seam. P.tone.z > 0 re-enables them for smooth-shaded content.
    let nc = c.xyz;
    let nd = max(max(1.0 - dot(nc, l.xyz), 1.0 - dot(nc, r.xyz)), max(1.0 - dot(nc, u.xyz), 1.0 - dot(nc, d.xyz)));
    let hasN = step(0.5, dot(nc, nc)) * step(0.5, min(min(dot(l.xyz, l.xyz), dot(r.xyz, r.xyz)), min(dot(u.xyz, u.xyz), dot(d.xyz, d.xyz))));
    let ne = smoothstep(0.62, 0.78, nd) * hasN * P.tone.z;
    let dmin = min(c.w, min(min(l.w, r.w), min(u.w, d.w)));
    // a fading instance's ink fades with it (weight of the nearest texel)
    var wk = vec2<f32>(c.w, inkW(c));
    wk = nearW(nearW(nearW(nearW(wk, l), r), u), d);
    wk = nearW(nearW(nearW(nearW(wk, l2), r2), u2), d2);
    return vec2<f32>(max(de, ne) * wk.y, dmin);
}

fn gtap(uv: vec2<f32>) -> vec4<f32> {
    return textureSampleLevel(gbuf, samp, uv, 0.0);
}

fn edges(uv: vec2<f32>) -> vec2<f32> {
    let o = P.src.zw;
    return edgesT(gtap(uv), gtap(uv - vec2<f32>(o.x, 0.0)), gtap(uv + vec2<f32>(o.x, 0.0)), gtap(uv - vec2<f32>(0.0, o.y)), gtap(uv + vec2<f32>(0.0, o.y)),
        gtap(uv - vec2<f32>(o.x * 2.0, 0.0)), gtap(uv + vec2<f32>(o.x * 2.0, 0.0)), gtap(uv - vec2<f32>(0.0, o.y * 2.0)), gtap(uv + vec2<f32>(0.0, o.y * 2.0)));
}

// ink amount of an edge, premultiplied fog mix
fn inkOf(e: vec2<f32>, w: f32) -> vec2<f32> {
    let a = e.x * (1.0 - smoothstep(P.ink.w * 0.35, P.ink.w, e.y)) * w;
    return vec2<f32>(a, a * smoothstep(P.ink.w * 0.15, P.ink.w, e.y) * P.tone.y);
}

// An edge inks the texel on both sides of the step: 2 render texels, wider
// on screen the lower the render scale (thin rings filled with ink). The
// near-side texel (on the object) is weighted 2 x scale - 1, so the line
// keeps its ~2 output px.
fn nearK(c: vec4<f32>, l: vec4<f32>, r: vec4<f32>, u: vec4<f32>, d: vec4<f32>) -> f32 {
    let zn = max(max(invd(l), invd(r)), max(invd(u), invd(d)));
    return select(1.0, clamp(2.0 * P.src.y / P.screen.y - 1.0, 0.0, 1.0), invd(c) >= zn);
}

// Upscaled world on a quality tier (render size < output size; high keeps
// edges() even when the pixel cap scales it, so it looks as it always did):
// edges() on the bilinear gbuffer loses the step between two texels (its
// second difference cancels on the ramp), which speckled every ink line with
// the beat of the two grids. Here: edges at the 4 texel centres around uv,
// blended. 12 taps where the block is flat (most of the frame), 20 on edges.
// Returns (ink amount, fog mix).
fn edgesUp(uv: vec2<f32>) -> vec2<f32> {
    let st = uv * P.src.xy - vec2<f32>(0.5);
    let i0 = floor(st);
    let f = st - i0;
    let c0 = (i0 + vec2<f32>(0.5)) * P.src.zw;
    let ox = vec2<f32>(P.src.z, 0.0);
    let oy = vec2<f32>(0.0, P.src.w);
    let g00 = gtap(c0);
    let g10 = gtap(c0 + ox);
    let g01 = gtap(c0 + oy);
    let g11 = gtap(c0 + ox + oy);
    let gm0 = gtap(c0 - ox);
    let gm1 = gtap(c0 - ox + oy);
    let g20 = gtap(c0 + ox * 2.0);
    let g21 = gtap(c0 + ox * 2.0 + oy);
    let g0m = gtap(c0 - oy);
    let g1m = gtap(c0 + ox - oy);
    let g02 = gtap(c0 + oy * 2.0);
    let g12 = gtap(c0 + ox + oy * 2.0);
    // lap <= 4 x range / min: below the edge threshold (0.12) everywhere
    let za = vec4<f32>(invd(g00), invd(g10), invd(g01), invd(g11));
    let zb = vec4<f32>(invd(gm0), invd(gm1), invd(g20), invd(g21));
    let zc = vec4<f32>(invd(g0m), invd(g1m), invd(g02), invd(g12));
    let lo = min(min(za, zb), zc);
    let hi = max(max(za, zb), zc);
    let zlo = min(min(lo.x, lo.y), min(lo.z, lo.w));
    let zhi = max(max(hi.x, hi.y), max(hi.z, hi.w));
    if (zhi - zlo < 0.029 * zlo && P.tone.z <= 0.0) {
        return vec2<f32>(0.0);
    }
    let gn0 = gtap(c0 - ox * 2.0);
    let gn1 = gtap(c0 - ox * 2.0 + oy);
    let g30 = gtap(c0 + ox * 3.0);
    let g31 = gtap(c0 + ox * 3.0 + oy);
    let g0n = gtap(c0 - oy * 2.0);
    let g1n = gtap(c0 + ox - oy * 2.0);
    let g03 = gtap(c0 + oy * 3.0);
    let g13 = gtap(c0 + ox + oy * 3.0);
    let k = inkOf(edgesT(g00, gm0, g10, g0m, g01, gn0, g20, g0n, g02), (1.0 - f.x) * (1.0 - f.y) * nearK(g00, gm0, g10, g0m, g01))
        + inkOf(edgesT(g10, g00, g20, g1m, g11, gm0, g30, g1n, g12), f.x * (1.0 - f.y) * nearK(g10, g00, g20, g1m, g11))
        + inkOf(edgesT(g01, gm1, g11, g00, g02, gn1, g21, g0m, g03), (1.0 - f.x) * f.y * nearK(g01, gm1, g11, g00, g02))
        + inkOf(edgesT(g11, g01, g21, g10, g12, gm1, g31, g1m, g13), f.x * f.y * nearK(g11, g01, g21, g10, g12));
    return vec2<f32>(k.x, k.y / max(k.x, 1e-5));
}

// gbuffer distance; pixels marked by a sprite / particle / trail / portal
// (normal.x = 3, distance of what is behind kept) count as near
fn gdist(uv: vec2<f32>) -> f32 {
    let g = textureSampleLevel(gbuf, samp, clamp(uv, vec2<f32>(0.0), vec2<f32>(1.0)), 0.0);
    return select(g.w, 0.0, g.x > 1.5);
}

// nearest gbuffer distance at uv and on a ring of radius o around it (8 taps
// at o and 4 at o / 2): covers ink hulls, which keep the depth behind them
fn gcross(uv: vec2<f32>, o: vec2<f32>) -> f32 {
    var m = gdist(uv);
    let dg = o * 0.7071;
    m = min(m, min(gdist(uv + vec2<f32>(o.x, 0.0)), gdist(uv - vec2<f32>(o.x, 0.0))));
    m = min(m, min(gdist(uv + vec2<f32>(0.0, o.y)), gdist(uv - vec2<f32>(0.0, o.y))));
    m = min(m, min(gdist(uv + dg), gdist(uv - dg)));
    m = min(m, min(gdist(uv + vec2<f32>(dg.x, -dg.y)), gdist(uv + vec2<f32>(-dg.x, dg.y))));
    let h = o * 0.5;
    m = min(m, min(gdist(uv + vec2<f32>(h.x, h.y)), gdist(uv - vec2<f32>(h.x, h.y))));
    m = min(m, min(gdist(uv + vec2<f32>(h.x, -h.y)), gdist(uv + vec2<f32>(-h.x, h.y))));
    return m;
}

// 1 where the gbuffer at uv lies beyond the lens gate (portal rim + debris)
fn beyond(uv: vec2<f32>, L: f32) -> f32 {
    return smoothstep(L, L * 1.1, gdist(uv));
}

fn lensAt(d: vec2<f32>, r: f32, R: f32, m: f32, t: f32, aspect: f32) -> vec2<f32> {
    let ang = m * 0.12 * P.lens.w;
    let cs = cos(ang);
    let sn = sin(ang);
    var rd = vec2<f32>(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
    rd *= 1.0 + sin(r / R * 12.0 - t * 4.0) * 0.012 * m * P.lens.w;
    rd.x /= aspect;
    return P.lens.xy + rd;
}

@fragment
fn fs_main(v: VOut) -> @location(0) vec4<f32> {
    if (keepLayout()) { discard; }
    var uv = v.uv;
    let t = P.b.w;
    let aspect = P.screen.x * P.screen.w;
    let dive = clamp(P.portal.x, 0.0, 1.0);

    // portal lens: rippling swirl just outside a projected portal rim. Only what
    // lies beyond the portal plane ripples, and the displaced source is depth
    // tested too: nothing nearer (hero, wingmen, rings, rim blocks) is pulled
    // into the ripple, so foreground objects stay single and unbent.
    if (P.lens.w > 0.001) {
        var d = uv - P.lens.xy;
        d.x *= aspect;
        let r = length(d);
        let R = max(P.lens.z, 0.001);
        let L = P.tone.w;
        // the dive has its own swirl + zoom blur: the ripple bows out as it
        // starts (mixing both ghosted the ink hulls around the rim debris)
        var m = smoothstep(0.85, 1.0, r / R) * (1.0 - smoothstep(1.2, 1.9, r / R)) * (1.0 - smoothstep(0.0, 0.08, dive));
        if (m > 0.0005) {
            // ink hulls keep the depth behind them: test a small cross so the
            // outline around a near object counts as near too
            let o = P.src.zw * 6.0 * max(P.src.y / 1080.0, 1.0);
            m *= smoothstep(L, L * 1.1, gcross(v.uv, o));
            let uvL = lensAt(d, r, R, m, t, aspect);
            let dv = uvL - v.uv;
            let pv = vec2<f32>(-dv.y / aspect, dv.x * aspect);
            let g = (beyond(uvL, L) + beyond(v.uv + dv * 0.5, L) + beyond(uvL + dv * 0.7, L)
                   + beyond(uvL + pv * 0.7, L) + beyond(uvL - pv * 0.7, L)) * 0.2;
            m *= g * g * (3.0 - 2.0 * g);
            // hard guard: if the final source (or a texel beside it: resolved
            // edges average depths) is nearer than the gate, do not displace
            let uvF = lensAt(d, r, R, m, t, aspect);
            uv = select(v.uv, uvF, gcross(uvF, o) > L);
        }
    }
    // portal dive: the dive center slides to the view center as we enter
    let pc = mix(P.portal.yz, vec2<f32>(0.5, 0.47), smoothstep(0.55, 0.88, dive));
    let burst = pow(clamp((dive - 0.6) / 0.3, 0.0, 1.0), 2.2);
    if (dive > 0.0) {
        uv = swirlAround(uv, pc, dive * dive * 0.8 + burst * 0.6, max(P.portal.w, 0.05) * (0.5 + dive), aspect);
    }

    // scene with subtle radial chroma
    let ctr = uv - vec2<f32>(0.5);
    let slowK = clamp(P.sting.x, 0.0, 1.0);
    // bullet time adds a chromatic kiss toward the frame edges
    let ca = P.a.w * dot(ctr, ctr) * 0.0065 + slowK * dot(ctr, ctr) * 0.024;
    var col = vec3<f32>(
        textureSampleLevel(scene, samp, uv + ctr * ca, 0.0).r,
        textureSampleLevel(scene, samp, uv, 0.0).g,
        textureSampleLevel(scene, samp, uv - ctr * ca, 0.0).b);
    // boost kick (P.fog.w, ~0.3 s at boost start): radial zoom smear toward the
    // frame edges. Many jittered taps make it a continuous blur (no ghost
    // copies); the hero safe zone (hero, reticle) stays crisp at every aspect.
    var smearK = 0.0;
    let hz = heroZone(v.uv, aspect);
    if (P.fog.w > 0.01) {
        smearK = clamp(P.fog.w, 0.0, 1.0) * smoothstep(0.1, 1.3, hz);
        if (smearK > 0.002) {
            let zd = uv - P.focus.xy;
            let jit = fract(52.9829189 * fract(dot(v.clip.xy, vec2<f32>(0.06711056, 0.00583715))));
            var acc = col;
            for (var k = 0; k < 10; k = k + 1) {
                let s = (f32(k) + jit) / 10.0 * smearK * 0.07;
                acc += textureSampleLevel(scene, samp, uv - zd * s, 0.0).rgb;
            }
            col = acc / 11.0;
        }
    }
    // portal dive: radial zoom blur toward the portal
    if (dive > 0.01) {
        var acc = col;
        let dir = uv - pc;
        for (var k = 1; k < 7; k = k + 1) {
            let s = f32(k) / 6.0 * (0.03 + 0.1 * burst) * dive;
            acc += textureSampleLevel(scene, samp, uv - dir * s, 0.0).rgb;
        }
        col = mix(col, acc / 7.0, clamp(dive * 1.5, 0.0, 1.0));
    }

    // ink edges
    if (P.focus.w > 0.001 && P.fadeColor.w > 1.5 && (abs(P.src.x - P.screen.x) > 0.5 || abs(P.src.y - P.screen.y) > 0.5)) {
        let k = edgesUp(uv);
        col = mix(col, mix(P.ink.rgb, P.fog.rgb, k.y), k.x * P.focus.w * (1.0 - smearK));
    } else if (P.focus.w > 0.001) {
        let e = edges(uv);
        let fade = 1.0 - smoothstep(P.ink.w * 0.35, P.ink.w, e.y);
        let inkC = mix(P.ink.rgb, P.fog.rgb, smoothstep(P.ink.w * 0.15, P.ink.w, e.y) * P.tone.y);
        col = mix(col, inkC, e.x * fade * P.focus.w * (1.0 - smearK));
    }

    // bloom
    let bl = textureSampleLevel(bloom, samp, uv, 0.0).rgb;
    col += bl * P.focus.z;

    col *= P.a.x;
    // highlight shoulder: keep the toon range, roll off HDR peaks
    let pk = max(max(col.r, col.g), col.b);
    if (pk > 0.8) {
        let k = 0.8 + (1.0 - exp(-(pk - 0.8) * 2.2)) * 0.45;
        col *= k / pk;
    }

    // grade
    let l0 = lum(col);
    col = mix(vec3<f32>(l0), col, P.grade.x);
    col = (col - 0.5) * P.grade.y + 0.5;
    col *= vec3<f32>(1.0 + P.grade.z * 0.06, 1.0, 1.0 - P.grade.z * 0.06);
    // biome split-tone: violet lifts shadows toward magenta, coast warms highlights
    let biome = clamp(P.tone.x, 0.0, 1.0);
    let lsh = 1.0 - smoothstep(0.0, 0.5, l0);
    col += mix(vec3<f32>(0.0, 0.004, 0.012), vec3<f32>(0.035, 0.0, 0.05), biome) * lsh;

    let px = v.clip.xy;
    // print screens scale with the short side (phones in portrait too)
    let cellS = max(min(P.screen.x, P.screen.y) / 1080.0, 0.5);
    // bullet time (sting holds, kill cams): desaturate toward a cobalt / cream
    // duotone, and a cobalt halftone vignette whose dots swell toward the
    // edges (the hero safe zone stays clean)
    if (slowK > 0.001) {
        let ls = lum(col);
        let duo = mix(INK_C * 0.5, PAPER_C, smoothstep(0.04, 0.96, ls));
        // warm hues (the hero, gold rings, fire) keep more of their color
        let warmK = smoothstep(0.1, 0.4, col.r - col.b);
        col = mix(col, vec3<f32>(ls), 0.55 * slowK * (1.0 - 0.65 * warmK));
        col = mix(col, duo, 0.22 * slowK);
        let vdS = length(ctr * vec2<f32>(aspect, 1.0) * 0.86);
        let pm = smoothstep(0.3, 1.0, vdS) * smoothstep(0.0, 0.6, heroZone(v.uv, aspect));
        let dt = screenDot(px, 0.7854, 7.0 * cellS, pm * slowK * 0.62);
        col = mix(col, INK_C * 0.72, dt * 0.78);
    }

    // print flash (sting slams): the frame re-printed as two halftone plates,
    // crimson and cobalt on cream, misregistered along the plate angle; the
    // plates slide back into register as the flash decays into color
    let pr = clamp(P.sting.y, 0.0, 1.0);
    if (pr > 0.001) {
        let dir = vec2<f32>(cos(P.sting.z), sin(P.sting.z));
        let offPx = (2.5 + 10.0 * pr * pr) * cellS;
        let o = dir * offPx * P.screen.zw;
        let sA = textureSampleLevel(scene, samp, uv + o, 0.0).rgb * P.a.x;
        let sB = textureSampleLevel(scene, samp, uv - o, 0.0).rgb * P.a.x;
        let lA = lum(sA);
        let lB = lum(sB);
        // cobalt key plate carries the shadows, crimson the mids and warm hues
        let kB = smoothstep(0.8, 0.1, lB);
        let kA = clamp((sA.r - sA.b) * 1.1 + (0.8 - lA) * 0.25, 0.0, 1.0);
        let cell = 6.5 * cellS;
        let cB = screenDot(px, 0.2618, cell, pow(kB, 0.8) * 0.68);
        let cA = screenDot(px + vec2<f32>(cell * 0.31, cell * 0.17), 1.309, cell, sqrt(kA) * 0.58);
        var pc = PAPER_C;
        pc *= mix(vec3<f32>(1.0), CRIMSON_C, cA * 0.92);
        pc *= mix(vec3<f32>(1.0), INK_C, cB);
        let k = smoothstep(0.0, 0.75, pr);
        col = mix(col, pc, k * 0.94);
    }

    // portal dive tunnel: toon spiral rushing out of the portal
    if (burst > 0.0) {
        var d = v.uv - pc;
        d.x *= aspect;
        let r = length(d);
        let ang = atan2(d.y, d.x);
        let tr = burst * 1.5;
        let s = ang / TAU * 4.0 - log(max(r, 0.002)) * 1.6 + t * 2.6;
        // AA width without the atan2 branch-cut jump (no seam left of center)
        let sB = (atan2(-d.y, -d.x) + 3.14159265) / TAU * 4.0 - log(max(r, 0.002)) * 1.6;
        let fs = min(fwidth(s), fwidth(sB));
        let b = fract(s);
        var tc = vec3<f32>(0.22, 0.46, 0.95);
        tc = mix(tc, vec3<f32>(0.55, 0.9, 1.0), 1.0 - smoothstep(0.45 - fs, 0.45 + fs, b));
        tc = mix(tc, vec3<f32>(1.0, 0.96, 0.84), 1.0 - smoothstep(0.2 - fs, 0.2 + fs, b));
        let rings = abs(fract(log(max(r, 0.002)) * 3.0 - t * 3.5) - 0.5);
        tc = mix(tc, vec3<f32>(0.1, 0.2, 0.55), (1.0 - smoothstep(0.02, 0.05, rings)) * 0.5);
        tc = mix(tc, vec3<f32>(1.3, 1.3, 1.2), 1.0 - smoothstep(0.0, 0.08 + dive * 0.1, r));
        let inside = 1.0 - smoothstep(tr - 0.02, tr + 0.02, r);
        let rim = (1.0 - smoothstep(0.0, 0.035, abs(r - tr))) * (1.0 - step(0.999, burst));
        col = mix(col, tc, inside);
        col += vec3<f32>(1.0, 0.95, 0.8) * rim * 0.9;
    }

    // speed lines: thin dashes streaming out of the focus point
    if (P.a.z > 0.001) {
        var d = v.uv - P.focus.xy;
        d.x *= aspect;
        let ang = atan2(d.y, d.x);
        let rr = length(d);
        let rays = 170.0;
        let ac = (ang / TAU + 0.5) * rays;
        let id = floor(ac);
        let h = hashi(i32(id), 3);
        let thin = abs(fract(ac) - 0.5) * (TAU / rays) * rr * P.screen.y;
        let seg = fract(rr * (1.6 + h) - t * (2.6 + h * 2.5) + h * 7.0);
        let dlen = 0.18 + 0.2 * h;
        let dash = smoothstep(0.0, 0.03, seg) * (1.0 - smoothstep(dlen - 0.05, dlen, seg));
        // tapered: thick at the head (outer end), hairline at the tail
        let wpx = (0.5 + h * 1.6) * (0.35 + 0.65 * smoothstep(0.0, dlen, seg)) * P.screen.y / 1080.0;
        let line = 1.0 - smoothstep(wpx, wpx + 1.0, thin);
        // concentrated at the frame edges, away from the pilot and the aim
        let mask = smoothstep(0.42, 1.0, rr) * step(0.45, h) * smoothstep(0.05, 0.6, hz);
        let slc = mix(vec3<f32>(0.86, 0.96, 1.0), vec3<f32>(1.0, 0.93, 0.8), step(0.8, h));
        col = mix(col, slc, line * dash * mask * P.a.z * 0.6);
    }

    // vignette
    let vd = length(ctr * vec2<f32>(aspect, 1.0) * 0.86);
    col *= mix(1.0, smoothstep(1.12, 0.38, vd), P.a.y);

    // damage: red edge pulse + desaturation
    if (P.b.x > 0.0) {
        let edge = smoothstep(0.32, 0.95, vd);
        let dl = lum(col);
        col = mix(col, vec3<f32>(dl) * vec3<f32>(1.1, 0.8, 0.8), P.b.x * 0.35);
        col = mix(col, vec3<f32>(0.95, 0.1, 0.06), edge * P.b.x * 0.7);
    }

    // flash
    col = mix(col, P.flash.rgb, clamp(P.flash.a, 0.0, 1.0));

    // grain (luma, subtle)
    let gr = hash2(v.uv * P.screen.xy + vec2<f32>(floor(t * 24.0) * 37.0, floor(t * 24.0) * 11.0)) - 0.5;
    col += gr * P.grade.w;

    // fade
    col = mix(col, P.fadeColor.rgb, clamp(P.b.y, 0.0, 1.0));

    // letterbox
    let lb = P.b.z * 0.12;
    if (v.uv.y < lb || v.uv.y > 1.0 - lb) {
        col = vec3<f32>(0.0);
    }
    return vec4<f32>(printPlates(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), v.clip.xy), 1.0);
}

// --- 3.1 (post at render resolution; JOB 25) ----------------------------------
// On the mobile tier (and on desktop HIGH when the render size is pixel-capped
// below the output, JOB 26), when the render size differs from the output,
// fs_main is split in two (renderer.luau, POST_SPLIT): fs_head runs its first half (lens,
// dive, chroma, smear, ink, bloom, exposure, shoulder, grade, split-tone) at the
// render size into an rgba16float target (colour is unclamped there), and
// fs_tail runs its second half (bullet time, print flash, tunnel, speed lines,
// vignette, damage, flash, grain, fade, letterbox) at the output size on the
// bilinear upscale. Both are verbatim copies of fs_main's halves (fs_main runs
// wherever post is not split); P.screen is the output size in both passes,
// so the halftone cells, grain, speed lines and letterbox keep today's pixels.
// MED / LOW ink: at render texel centres edgesUp reduces to today's per-texel
// near-weighted ink, and the upscale does the blend it did by hand. These
// entries sit AFTER fs_main: a pipeline stage that names no entry point takes
// the module's first @fragment (every post, visor and blit pipeline names its
// entries anyway).

@group(0) @binding(5) var postA: texture_2d<f32>;

// web 2.45+ binds exactly the auto layout, and compilers differ on whether it holds a module's unused bindings:
// every entry point touches 2-6, so every layout is the same and bgPost / bgPostB bind all of them
fn keepLayout() -> bool {
    return textureDimensions(scene).x + textureDimensions(gbuf).x + textureDimensions(bloom).x
        + textureDimensions(postA).x + textureDimensions(visorTex).x == 0u;
}

// 3.1 ink on MED / LOW: edgesUp with the near-side weight raised by P.split.x
// (a knob: 0 on every tier). Mixed at render texel centres before the upscale,
// the line keeps its total ink and is a little less crisp than edgesUp at the
// output size (RENDERER_SHARE_JOB25.md); the knob did not change that.
fn nearKS(c: vec4<f32>, l: vec4<f32>, r: vec4<f32>, u: vec4<f32>, d: vec4<f32>) -> f32 {
    let zn = max(max(invd(l), invd(r)), max(invd(u), invd(d)));
    return select(1.0, clamp(2.0 * P.src.y / P.screen.y - 1.0 + P.split.x, 0.0, 1.0), invd(c) >= zn);
}

fn edgesUpS(uv: vec2<f32>) -> vec2<f32> {
    let st = uv * P.src.xy - vec2<f32>(0.5);
    let i0 = floor(st);
    let f = st - i0;
    let c0 = (i0 + vec2<f32>(0.5)) * P.src.zw;
    let ox = vec2<f32>(P.src.z, 0.0);
    let oy = vec2<f32>(0.0, P.src.w);
    let g00 = gtap(c0);
    let g10 = gtap(c0 + ox);
    let g01 = gtap(c0 + oy);
    let g11 = gtap(c0 + ox + oy);
    let gm0 = gtap(c0 - ox);
    let gm1 = gtap(c0 - ox + oy);
    let g20 = gtap(c0 + ox * 2.0);
    let g21 = gtap(c0 + ox * 2.0 + oy);
    let g0m = gtap(c0 - oy);
    let g1m = gtap(c0 + ox - oy);
    let g02 = gtap(c0 + oy * 2.0);
    let g12 = gtap(c0 + ox + oy * 2.0);
    // lap <= 4 x range / min: below the edge threshold (0.12) everywhere
    let za = vec4<f32>(invd(g00), invd(g10), invd(g01), invd(g11));
    let zb = vec4<f32>(invd(gm0), invd(gm1), invd(g20), invd(g21));
    let zc = vec4<f32>(invd(g0m), invd(g1m), invd(g02), invd(g12));
    let lo = min(min(za, zb), zc);
    let hi = max(max(za, zb), zc);
    let zlo = min(min(lo.x, lo.y), min(lo.z, lo.w));
    let zhi = max(max(hi.x, hi.y), max(hi.z, hi.w));
    if (zhi - zlo < 0.029 * zlo && P.tone.z <= 0.0) {
        return vec2<f32>(0.0);
    }
    let gn0 = gtap(c0 - ox * 2.0);
    let gn1 = gtap(c0 - ox * 2.0 + oy);
    let g30 = gtap(c0 + ox * 3.0);
    let g31 = gtap(c0 + ox * 3.0 + oy);
    let g0n = gtap(c0 - oy * 2.0);
    let g1n = gtap(c0 + ox - oy * 2.0);
    let g03 = gtap(c0 + oy * 3.0);
    let g13 = gtap(c0 + ox + oy * 3.0);
    let k = inkOf(edgesT(g00, gm0, g10, g0m, g01, gn0, g20, g0n, g02), (1.0 - f.x) * (1.0 - f.y) * nearKS(g00, gm0, g10, g0m, g01))
        + inkOf(edgesT(g10, g00, g20, g1m, g11, gm0, g30, g1n, g12), f.x * (1.0 - f.y) * nearKS(g10, g00, g20, g1m, g11))
        + inkOf(edgesT(g01, gm1, g11, g00, g02, gn1, g21, g0m, g03), (1.0 - f.x) * f.y * nearKS(g01, gm1, g11, g00, g02))
        + inkOf(edgesT(g11, g01, g21, g10, g12, gm1, g31, g1m, g13), f.x * f.y * nearKS(g11, g01, g21, g10, g12));
    return vec2<f32>(k.x, k.y / max(k.x, 1e-5));
}

@fragment
fn fs_head(v: VOut) -> @location(0) vec4<f32> {
    if (keepLayout()) { discard; }
    var uv = v.uv;
    let t = P.b.w;
    let aspect = P.screen.x * P.screen.w;
    let dive = clamp(P.portal.x, 0.0, 1.0);

    // portal lens: rippling swirl just outside a projected portal rim. Only what
    // lies beyond the portal plane ripples, and the displaced source is depth
    // tested too: nothing nearer (hero, wingmen, rings, rim blocks) is pulled
    // into the ripple, so foreground objects stay single and unbent.
    if (P.lens.w > 0.001) {
        var d = uv - P.lens.xy;
        d.x *= aspect;
        let r = length(d);
        let R = max(P.lens.z, 0.001);
        let L = P.tone.w;
        // the dive has its own swirl + zoom blur: the ripple bows out as it
        // starts (mixing both ghosted the ink hulls around the rim debris)
        var m = smoothstep(0.85, 1.0, r / R) * (1.0 - smoothstep(1.2, 1.9, r / R)) * (1.0 - smoothstep(0.0, 0.08, dive));
        if (m > 0.0005) {
            // ink hulls keep the depth behind them: test a small cross so the
            // outline around a near object counts as near too
            let o = P.src.zw * 6.0 * max(P.src.y / 1080.0, 1.0);
            m *= smoothstep(L, L * 1.1, gcross(v.uv, o));
            let uvL = lensAt(d, r, R, m, t, aspect);
            let dv = uvL - v.uv;
            let pv = vec2<f32>(-dv.y / aspect, dv.x * aspect);
            let g = (beyond(uvL, L) + beyond(v.uv + dv * 0.5, L) + beyond(uvL + dv * 0.7, L)
                   + beyond(uvL + pv * 0.7, L) + beyond(uvL - pv * 0.7, L)) * 0.2;
            m *= g * g * (3.0 - 2.0 * g);
            // hard guard: if the final source (or a texel beside it: resolved
            // edges average depths) is nearer than the gate, do not displace
            let uvF = lensAt(d, r, R, m, t, aspect);
            uv = select(v.uv, uvF, gcross(uvF, o) > L);
        }
    }
    // portal dive: the dive center slides to the view center as we enter
    let pc = mix(P.portal.yz, vec2<f32>(0.5, 0.47), smoothstep(0.55, 0.88, dive));
    let burst = pow(clamp((dive - 0.6) / 0.3, 0.0, 1.0), 2.2);
    if (dive > 0.0) {
        uv = swirlAround(uv, pc, dive * dive * 0.8 + burst * 0.6, max(P.portal.w, 0.05) * (0.5 + dive), aspect);
    }

    // scene with subtle radial chroma
    let ctr = uv - vec2<f32>(0.5);
    let slowK = clamp(P.sting.x, 0.0, 1.0);
    // bullet time adds a chromatic kiss toward the frame edges
    let ca = P.a.w * dot(ctr, ctr) * 0.0065 + slowK * dot(ctr, ctr) * 0.024;
    var col = vec3<f32>(
        textureSampleLevel(scene, samp, uv + ctr * ca, 0.0).r,
        textureSampleLevel(scene, samp, uv, 0.0).g,
        textureSampleLevel(scene, samp, uv - ctr * ca, 0.0).b);
    // boost kick (P.fog.w, ~0.3 s at boost start): radial zoom smear toward the
    // frame edges. Many jittered taps make it a continuous blur (no ghost
    // copies); the hero safe zone (hero, reticle) stays crisp at every aspect.
    var smearK = 0.0;
    let hz = heroZone(v.uv, aspect);
    if (P.fog.w > 0.01) {
        smearK = clamp(P.fog.w, 0.0, 1.0) * smoothstep(0.1, 1.3, hz);
        if (smearK > 0.002) {
            let zd = uv - P.focus.xy;
            let jit = fract(52.9829189 * fract(dot(v.clip.xy, vec2<f32>(0.06711056, 0.00583715))));
            var acc = col;
            for (var k = 0; k < 10; k = k + 1) {
                let s = (f32(k) + jit) / 10.0 * smearK * 0.07;
                acc += textureSampleLevel(scene, samp, uv - zd * s, 0.0).rgb;
            }
            col = acc / 11.0;
        }
    }
    // portal dive: radial zoom blur toward the portal
    if (dive > 0.01) {
        var acc = col;
        let dir = uv - pc;
        for (var k = 1; k < 7; k = k + 1) {
            let s = f32(k) / 6.0 * (0.03 + 0.1 * burst) * dive;
            acc += textureSampleLevel(scene, samp, uv - dir * s, 0.0).rgb;
        }
        col = mix(col, acc / 7.0, clamp(dive * 1.5, 0.0, 1.0));
    }

    // ink edges
    if (P.focus.w > 0.001 && P.fadeColor.w > 1.5 && (abs(P.src.x - P.screen.x) > 0.5 || abs(P.src.y - P.screen.y) > 0.5)) {
        let k = edgesUpS(uv);
        col = mix(col, mix(P.ink.rgb, P.fog.rgb, k.y), k.x * P.focus.w * (1.0 - smearK));
    } else if (P.focus.w > 0.001) {
        let e = edges(uv);
        let fade = 1.0 - smoothstep(P.ink.w * 0.35, P.ink.w, e.y);
        let inkC = mix(P.ink.rgb, P.fog.rgb, smoothstep(P.ink.w * 0.15, P.ink.w, e.y) * P.tone.y);
        col = mix(col, inkC, e.x * fade * P.focus.w * (1.0 - smearK));
    }

    // bloom
    let bl = textureSampleLevel(bloom, samp, uv, 0.0).rgb;
    col += bl * P.focus.z;

    col *= P.a.x;
    // highlight shoulder: keep the toon range, roll off HDR peaks
    let pk = max(max(col.r, col.g), col.b);
    if (pk > 0.8) {
        let k = 0.8 + (1.0 - exp(-(pk - 0.8) * 2.2)) * 0.45;
        col *= k / pk;
    }

    // grade
    let l0 = lum(col);
    col = mix(vec3<f32>(l0), col, P.grade.x);
    col = (col - 0.5) * P.grade.y + 0.5;
    col *= vec3<f32>(1.0 + P.grade.z * 0.06, 1.0, 1.0 - P.grade.z * 0.06);
    // biome split-tone: violet lifts shadows toward magenta, coast warms highlights
    let biome = clamp(P.tone.x, 0.0, 1.0);
    let lsh = 1.0 - smoothstep(0.0, 0.5, l0);
    col += mix(vec3<f32>(0.0, 0.004, 0.012), vec3<f32>(0.035, 0.0, 0.05), biome) * lsh;
    return vec4<f32>(col, 1.0);
}

// The lens / dive warp of fs_main (same code), for fs_tail's masks and the print
// plates, which read the scene at the warped uv
fn warpUV(vuv: vec2<f32>, aspect: f32, dive: f32, t: f32) -> vec2<f32> {
    var uv = vuv;
    let v_uv = vuv;
    // portal lens: rippling swirl just outside a projected portal rim. Only what
    // lies beyond the portal plane ripples, and the displaced source is depth
    // tested too: nothing nearer (hero, wingmen, rings, rim blocks) is pulled
    // into the ripple, so foreground objects stay single and unbent.
    if (P.lens.w > 0.001) {
        var d = uv - P.lens.xy;
        d.x *= aspect;
        let r = length(d);
        let R = max(P.lens.z, 0.001);
        let L = P.tone.w;
        // the dive has its own swirl + zoom blur: the ripple bows out as it
        // starts (mixing both ghosted the ink hulls around the rim debris)
        var m = smoothstep(0.85, 1.0, r / R) * (1.0 - smoothstep(1.2, 1.9, r / R)) * (1.0 - smoothstep(0.0, 0.08, dive));
        if (m > 0.0005) {
            // ink hulls keep the depth behind them: test a small cross so the
            // outline around a near object counts as near too
            let o = P.src.zw * 6.0 * max(P.src.y / 1080.0, 1.0);
            m *= smoothstep(L, L * 1.1, gcross(v_uv, o));
            let uvL = lensAt(d, r, R, m, t, aspect);
            let dv = uvL - v_uv;
            let pv = vec2<f32>(-dv.y / aspect, dv.x * aspect);
            let g = (beyond(uvL, L) + beyond(v_uv + dv * 0.5, L) + beyond(uvL + dv * 0.7, L)
                   + beyond(uvL + pv * 0.7, L) + beyond(uvL - pv * 0.7, L)) * 0.2;
            m *= g * g * (3.0 - 2.0 * g);
            // hard guard: if the final source (or a texel beside it: resolved
            // edges average depths) is nearer than the gate, do not displace
            let uvF = lensAt(d, r, R, m, t, aspect);
            uv = select(v_uv, uvF, gcross(uvF, o) > L);
        }
    }
    // portal dive: the dive center slides to the view center as we enter
    let pc = mix(P.portal.yz, vec2<f32>(0.5, 0.47), smoothstep(0.55, 0.88, dive));
    let burst = pow(clamp((dive - 0.6) / 0.3, 0.0, 1.0), 2.2);
    if (dive > 0.0) {
        uv = swirlAround(uv, pc, dive * dive * 0.8 + burst * 0.6, max(P.portal.w, 0.05) * (0.5 + dive), aspect);
    }

    return uv;
}

@fragment
fn fs_tail(v: VOut) -> @location(0) vec4<f32> {
    if (keepLayout()) { discard; }
    let t = P.b.w;
    let aspect = P.screen.x * P.screen.w;
    let dive = clamp(P.portal.x, 0.0, 1.0);
    let uv = warpUV(v.uv, aspect, dive, t);
    let pc = mix(P.portal.yz, vec2<f32>(0.5, 0.47), smoothstep(0.55, 0.88, dive));
    let burst = pow(clamp((dive - 0.6) / 0.3, 0.0, 1.0), 2.2);
    let ctr = uv - vec2<f32>(0.5);
    let slowK = clamp(P.sting.x, 0.0, 1.0);
    let hz = heroZone(v.uv, aspect);
    var col = textureSampleLevel(postA, samp, v.uv, 0.0).rgb;

    let px = v.clip.xy;
    // print screens scale with the short side (phones in portrait too)
    let cellS = max(min(P.screen.x, P.screen.y) / 1080.0, 0.5);
    // bullet time (sting holds, kill cams): desaturate toward a cobalt / cream
    // duotone, and a cobalt halftone vignette whose dots swell toward the
    // edges (the hero safe zone stays clean)
    if (slowK > 0.001) {
        let ls = lum(col);
        let duo = mix(INK_C * 0.5, PAPER_C, smoothstep(0.04, 0.96, ls));
        // warm hues (the hero, gold rings, fire) keep more of their color
        let warmK = smoothstep(0.1, 0.4, col.r - col.b);
        col = mix(col, vec3<f32>(ls), 0.55 * slowK * (1.0 - 0.65 * warmK));
        col = mix(col, duo, 0.22 * slowK);
        let vdS = length(ctr * vec2<f32>(aspect, 1.0) * 0.86);
        let pm = smoothstep(0.3, 1.0, vdS) * smoothstep(0.0, 0.6, heroZone(v.uv, aspect));
        let dt = screenDot(px, 0.7854, 7.0 * cellS, pm * slowK * 0.62);
        col = mix(col, INK_C * 0.72, dt * 0.78);
    }

    // print flash (sting slams): the frame re-printed as two halftone plates,
    // crimson and cobalt on cream, misregistered along the plate angle; the
    // plates slide back into register as the flash decays into color
    let pr = clamp(P.sting.y, 0.0, 1.0);
    if (pr > 0.001) {
        let dir = vec2<f32>(cos(P.sting.z), sin(P.sting.z));
        let offPx = (2.5 + 10.0 * pr * pr) * cellS;
        let o = dir * offPx * P.screen.zw;
        let sA = textureSampleLevel(scene, samp, uv + o, 0.0).rgb * P.a.x;
        let sB = textureSampleLevel(scene, samp, uv - o, 0.0).rgb * P.a.x;
        let lA = lum(sA);
        let lB = lum(sB);
        // cobalt key plate carries the shadows, crimson the mids and warm hues
        let kB = smoothstep(0.8, 0.1, lB);
        let kA = clamp((sA.r - sA.b) * 1.1 + (0.8 - lA) * 0.25, 0.0, 1.0);
        let cell = 6.5 * cellS;
        let cB = screenDot(px, 0.2618, cell, pow(kB, 0.8) * 0.68);
        let cA = screenDot(px + vec2<f32>(cell * 0.31, cell * 0.17), 1.309, cell, sqrt(kA) * 0.58);
        var pc = PAPER_C;
        pc *= mix(vec3<f32>(1.0), CRIMSON_C, cA * 0.92);
        pc *= mix(vec3<f32>(1.0), INK_C, cB);
        let k = smoothstep(0.0, 0.75, pr);
        col = mix(col, pc, k * 0.94);
    }

    // portal dive tunnel: toon spiral rushing out of the portal
    if (burst > 0.0) {
        var d = v.uv - pc;
        d.x *= aspect;
        let r = length(d);
        let ang = atan2(d.y, d.x);
        let tr = burst * 1.5;
        let s = ang / TAU * 4.0 - log(max(r, 0.002)) * 1.6 + t * 2.6;
        // AA width without the atan2 branch-cut jump (no seam left of center)
        let sB = (atan2(-d.y, -d.x) + 3.14159265) / TAU * 4.0 - log(max(r, 0.002)) * 1.6;
        let fs = min(fwidth(s), fwidth(sB));
        let b = fract(s);
        var tc = vec3<f32>(0.22, 0.46, 0.95);
        tc = mix(tc, vec3<f32>(0.55, 0.9, 1.0), 1.0 - smoothstep(0.45 - fs, 0.45 + fs, b));
        tc = mix(tc, vec3<f32>(1.0, 0.96, 0.84), 1.0 - smoothstep(0.2 - fs, 0.2 + fs, b));
        let rings = abs(fract(log(max(r, 0.002)) * 3.0 - t * 3.5) - 0.5);
        tc = mix(tc, vec3<f32>(0.1, 0.2, 0.55), (1.0 - smoothstep(0.02, 0.05, rings)) * 0.5);
        tc = mix(tc, vec3<f32>(1.3, 1.3, 1.2), 1.0 - smoothstep(0.0, 0.08 + dive * 0.1, r));
        let inside = 1.0 - smoothstep(tr - 0.02, tr + 0.02, r);
        let rim = (1.0 - smoothstep(0.0, 0.035, abs(r - tr))) * (1.0 - step(0.999, burst));
        col = mix(col, tc, inside);
        col += vec3<f32>(1.0, 0.95, 0.8) * rim * 0.9;
    }

    // speed lines: thin dashes streaming out of the focus point
    if (P.a.z > 0.001) {
        var d = v.uv - P.focus.xy;
        d.x *= aspect;
        let ang = atan2(d.y, d.x);
        let rr = length(d);
        let rays = 170.0;
        let ac = (ang / TAU + 0.5) * rays;
        let id = floor(ac);
        let h = hashi(i32(id), 3);
        let thin = abs(fract(ac) - 0.5) * (TAU / rays) * rr * P.screen.y;
        let seg = fract(rr * (1.6 + h) - t * (2.6 + h * 2.5) + h * 7.0);
        let dlen = 0.18 + 0.2 * h;
        let dash = smoothstep(0.0, 0.03, seg) * (1.0 - smoothstep(dlen - 0.05, dlen, seg));
        // tapered: thick at the head (outer end), hairline at the tail
        let wpx = (0.5 + h * 1.6) * (0.35 + 0.65 * smoothstep(0.0, dlen, seg)) * P.screen.y / 1080.0;
        let line = 1.0 - smoothstep(wpx, wpx + 1.0, thin);
        // concentrated at the frame edges, away from the pilot and the aim
        let mask = smoothstep(0.42, 1.0, rr) * step(0.45, h) * smoothstep(0.05, 0.6, hz);
        let slc = mix(vec3<f32>(0.86, 0.96, 1.0), vec3<f32>(1.0, 0.93, 0.8), step(0.8, h));
        col = mix(col, slc, line * dash * mask * P.a.z * 0.6);
    }

    // vignette
    let vd = length(ctr * vec2<f32>(aspect, 1.0) * 0.86);
    col *= mix(1.0, smoothstep(1.12, 0.38, vd), P.a.y);

    // damage: red edge pulse + desaturation
    if (P.b.x > 0.0) {
        let edge = smoothstep(0.32, 0.95, vd);
        let dl = lum(col);
        col = mix(col, vec3<f32>(dl) * vec3<f32>(1.1, 0.8, 0.8), P.b.x * 0.35);
        col = mix(col, vec3<f32>(0.95, 0.1, 0.06), edge * P.b.x * 0.7);
    }

    // flash
    col = mix(col, P.flash.rgb, clamp(P.flash.a, 0.0, 1.0));

    // grain (luma, subtle)
    let gr = hash2(v.uv * P.screen.xy + vec2<f32>(floor(t * 24.0) * 37.0, floor(t * 24.0) * 11.0)) - 0.5;
    col += gr * P.grade.w;

    // fade
    col = mix(col, P.fadeColor.rgb, clamp(P.b.y, 0.0, 1.0));

    // letterbox
    let lb = P.b.z * 0.12;
    if (v.uv.y < lb || v.uv.y > 1.0 - lb) {
        col = vec3<f32>(0.0);
    }
    return vec4<f32>(printPlates(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), v.clip.xy), 1.0);
}
