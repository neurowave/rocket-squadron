// Cel-shaded lit mesh, instanced. Three hard bands, bluish shadow tint,
// screen-space halftone in shadow, rim light, toon specular (aux.w), HDR
// emissive, glowing dissolve edge, aerial fog.
//
// Unlit surface flags (aux.z = 1), selected by aux.w:
//   0.00 plain unlit color
//   0.25 animated shoreline foam lace (flat bands on the water)
//   0.50 waterfall: scrolling toon stripes, foam at the base (y < 3 m)
//   0.75 energy: pulsing HDR glow bands (engines, runes, portal frames)
// Unlit + no ink + near-white + y < 0.5 m is also treated as shoreline foam.
// Frame struct is shared by every world shader; keep all copies identical (see DESIGN.md).
struct Frame {
    viewProj: mat4x4<f32>,
    invViewProj: mat4x4<f32>,
    camPos: vec4<f32>,       // xyz, w = time
    camRight: vec4<f32>,
    camUp: vec4<f32>,
    sunDir: vec4<f32>,       // xyz toward sun, w = sun disc size
    sunColor: vec4<f32>,
    skyTop: vec4<f32>,
    skyHorizon: vec4<f32>,
    ambient: vec4<f32>,      // rgb, w = shadow strength
    shadowTint: vec4<f32>,
    fogColor: vec4<f32>,     // rgb, w = fog density
    ink: vec4<f32>,          // rgb outline color, w = outline width
    waterDeep: vec4<f32>,
    waterShallow: vec4<f32>,
    foam: vec4<f32>,
    clip: vec4<f32>,         // x clip on, y clip height, z reflection pass, w halftone
    screen: vec4<f32>,       // w, h, 1/w, 1/h
    params: vec4<f32>,       // x biome blend, y speed, z flash, w cloud cover
    params2: vec4<f32>,      // xy flow dir (world xz), z boost 0..1, w pixel scale (target h / 1080)
    player: vec4<f32>,       // xyz player position, w wake strength 0..1
    camFwd: vec4<f32>,       // xyz camera forward, w tan(fovY / 2)
};
@group(0) @binding(0) var<uniform> F: Frame;

struct VIn {
    @location(0) pos: vec3<f32>,
    @location(1) nrm: vec3<f32>,
    @location(2) col: vec4<f32>,
    @location(3) aux: vec4<f32>,   // x emissive, y outline weight, z unlit, w shiny / unlit mode
    @location(4) m0: vec4<f32>,
    @location(5) m1: vec4<f32>,
    @location(6) m2: vec4<f32>,
    @location(7) m3: vec4<f32>,
    @location(8) tint: vec4<f32>,  // rgb multiply, a = hit flash
    @location(9) extra: vec4<f32>, // x emissive boost, y dissolve, z outline scale, w extra fog 0..1 (< 0: sky fade 0..1)
};

struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) wpos: vec3<f32>,
    @location(1) nrm: vec3<f32>,
    @location(2) col: vec4<f32>,
    @location(3) aux: vec4<f32>,
    @location(4) tint: vec4<f32>,
    @location(5) extra: vec4<f32>,
    // 1 = mirrored rock for water.wgsl: lit, non-emissive, non-shiny paint
    // on static scenery (identity instance, baked in world space)
    @location(6) rock: f32,
};

struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

// Clip position from the eye-relative point. viewProj * wp rounds world
// coordinates (km out) per vertex in f32: ~0.1 m of depth noise at 115 m,
// so paint layers a few cm apart (Stormcrow's emblem) z-fought, different
// every frame. The eye's own term is one value for every vertex.
// Same function in outline.wgsl.
fn worldClip(wp: vec3<f32>) -> vec4<f32> {
    return F.viewProj * vec4<f32>(wp - F.camPos.xyz, 0.0) + F.viewProj * vec4<f32>(F.camPos.xyz, 1.0);
}

@vertex
fn vs_main(i: VIn) -> VOut {
    let m = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
    let wp = m * vec4<f32>(i.pos, 1.0);
    var o: VOut;
    o.clip = worldClip(wp.xyz);
    o.wpos = wp.xyz;
    o.nrm = normalize((m * vec4<f32>(i.nrm, 0.0)).xyz);
    o.col = i.col;
    o.aux = i.aux;
    o.tint = i.tint;
    o.extra = i.extra;
    let ident = all(i.m3.xyz == vec3<f32>(0.0)) && i.m0.x == 1.0 && i.m1.y == 1.0 && i.m2.z == 1.0;
    o.rock = select(0.0, 1.0, ident && i.aux.z < 0.3 && i.aux.x < 0.03 && i.aux.w < 0.2);
    return o;
}

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn hashi(x: i32, y: i32) -> f32 {
    return f32(pcg(bitcast<u32>(x) + pcg(bitcast<u32>(y)))) * (1.0 / 4294967295.0);
}
fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let ii = vec2<i32>(i);
    return mix(mix(hashi(ii.x, ii.y), hashi(ii.x + 1, ii.y), u.x),
               mix(hashi(ii.x, ii.y + 1), hashi(ii.x + 1, ii.y + 1), u.x), u.y);
}
fn h3(q: vec3<i32>) -> f32 {
    return hashi(q.x + q.z * 7919, q.y);
}
fn noise3(p: vec3<f32>) -> f32 {
    let i = vec3<i32>(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(mix(h3(i), h3(i + vec3<i32>(1, 0, 0)), u.x), mix(h3(i + vec3<i32>(0, 1, 0)), h3(i + vec3<i32>(1, 1, 0)), u.x), u.y);
    let b = mix(mix(h3(i + vec3<i32>(0, 0, 1)), h3(i + vec3<i32>(1, 0, 1)), u.x), mix(h3(i + vec3<i32>(0, 1, 1)), h3(i + vec3<i32>(1, 1, 1)), u.x), u.y);
    return mix(a, b, u.z);
}

// Cheaper value noise for the cloud material (one hash per lattice corner).
fn hq(q: vec3<i32>) -> f32 {
    let h = pcg((bitcast<u32>(q.x) * 73856093u) ^ (bitcast<u32>(q.y) * 19349663u) ^ (bitcast<u32>(q.z) * 83492791u));
    return f32(h) * (1.0 / 4294967295.0);
}
fn cnoise3(p: vec3<f32>) -> f32 {
    let i = vec3<i32>(floor(p));
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(mix(hq(i), hq(i + vec3<i32>(1, 0, 0)), u.x), mix(hq(i + vec3<i32>(0, 1, 0)), hq(i + vec3<i32>(1, 1, 0)), u.x), u.y);
    let b = mix(mix(hq(i + vec3<i32>(0, 0, 1)), hq(i + vec3<i32>(1, 0, 1)), u.x), mix(hq(i + vec3<i32>(0, 1, 1)), hq(i + vec3<i32>(1, 1, 1)), u.x), u.y);
    return mix(a, b, u.z);
}

// Dissolving objects (collected rings, dying enemies) melt away near the eye
// instead of filling the screen.
fn melting(v: VOut) -> bool {
    return v.extra.y > 0.0;
}

// Dissolve value + threshold: smooth 3D value noise (two octaves, ~45 cm and
// ~15 cm), so objects melt into organic lace instead of square cells; a
// dissolving object also melts away as it nears the camera, fully gone by
// 5 m. Same function in outline.wgsl.
fn dissolveAt(wp: vec3<f32>, amount: f32) -> vec2<f32> {
    let d = length(F.camPos.xyz - wp);
    let n = noise3(wp * 2.2) * 0.62 + noise3(wp * 6.5 + vec3<f32>(17.0, 3.0, 9.0)) * 0.38;
    let th = max(amount, 1.0 - smoothstep(5.0, 18.0, d));
    return vec2<f32>(clamp((n - 0.5) * 2.3 + 0.5, 0.0, 1.0), th);
}

// Rotated dot screen; returns 1 inside a dot. `amount` = dot radius (0..0.7).
fn halftone(fragXY: vec2<f32>, amount: f32, cell: f32) -> f32 {
    let a = 0.7853982;
    let r = mat2x2<f32>(cos(a), -sin(a), sin(a), cos(a)) * fragXY / cell;
    let f = fract(r) - vec2<f32>(0.5);
    let d = length(f);
    let aa = 1.2 / cell;
    return 1.0 - smoothstep(amount - aa, amount + aa, d);
}

fn band(x: f32, edge: f32, aa: f32) -> f32 {
    return smoothstep(edge - aa, edge + aa, x);
}

// sky.wgsl horizonColor() and its clear-sky gradient (no clouds / ridges):
// what the sky shows along `dir`. Keep in step with sky.wgsl.
fn skyBehind(dir: vec3<f32>) -> vec3<f32> {
    let coastHaze = mix(F.skyHorizon.rgb, vec3<f32>(1.0), 0.28);
    let violetHaze = mix(F.skyHorizon.rgb, F.fogColor.rgb, 0.35) * vec3<f32>(1.05, 1.0, 1.08);
    let hz = mix(coastHaze, violetHaze, clamp(F.params.x, 0.0, 1.0));
    let el = asin(clamp(dir.y, -1.0, 1.0));
    var col = mix(hz, F.skyHorizon.rgb, smoothstep(0.0, 0.07, el));
    return mix(col, F.skyTop.rgb, pow(smoothstep(0.0, 0.75, el), 0.55));
}

// Toon cumulus material: aux.z = 0.4 (lit, cloud), or geo.cloud's paint
// (lit, near white, emissive 10/255, not shiny). Same test in outline.wgsl.
fn isCloud(aux: vec4<f32>, col: vec3<f32>) -> bool {
    let flagged = aux.z > 0.3 && aux.z < 0.45;
    let painted = aux.z < 0.01 && aux.w < 0.01 && abs(aux.x - 10.0 / 255.0) < 0.002 && min(min(col.r, col.g), col.b) > 0.85;
    return flagged || painted;
}

// toSky: mix toward skyBehind by the sky fade (opaque path); the sky-fade
// path blends with alpha instead, over the real sky / water / clouds.
fn shade(v: VOut, ff: bool, toSky: bool) -> vec3<f32> {
    let t = F.camPos.w;
    var n = normalize(v.nrm);
    if (!ff) {
        n = -n;
    }
    let base = v.col.rgb * v.tint.rgb;
    let toCam = F.camPos.xyz - v.wpos;
    let dist = length(toCam);
    let V = toCam / max(dist, 1e-4);
    let L = normalize(F.sunDir.xyz);
    let ndl = dot(n, L);
    let pxs = max(F.params2.w, 0.5);
    let biome = clamp(F.params.x, 0.0, 1.0);
    let aaN = max(fwidth(ndl), 0.002);
    let dotCell = 5.2 * pxs;
    let ht = halftone(v.clip.xy, 0.3, dotCell);
    let ht2 = halftone(v.clip.xy + vec2<f32>(dotCell * 0.5), 0.2, dotCell);
    var color: vec3<f32>;
    let mode = v.aux.w;
    if (v.aux.z > 0.5) {
        color = base;
        let whiteish = min(min(base.r, base.g), base.b) > 0.8;
        let isFoam = (mode > 0.15 && mode < 0.38) || (mode < 0.1 && v.aux.y < 0.01 && whiteish && v.wpos.y < 0.5);
        if (isFoam) {
            // lace: drifting holes, lapping pulse
            let p = v.wpos.xz;
            let n1 = noise2(p * 0.45 + vec2<f32>(t * 0.6, -t * 0.35));
            let n2 = noise2(p * 1.3 - vec2<f32>(t * 0.9, t * 0.5));
            let pulse = 0.5 + 0.5 * sin(t * 1.7 + (p.x + p.y) * 0.08);
            let lace = n1 * 0.7 + n2 * 0.3;
            let thr = mix(0.34, 0.5, pulse);
            if (lace < thr - 0.12) {
                discard;
            }
            let fr = smoothstep(thr - 0.12, thr, lace);
            color = mix(mix(F.foam.rgb, F.waterShallow.rgb, 0.5), F.foam.rgb, fr);
        } else if (mode > 0.38 && mode < 0.62) {
            // waterfall: vertical toon streaks scrolling down, foam at the base.
            // Every across-the-sheet term is a function of world (x, z) only,
            // so edges stay vertical whatever the sheet's normal does (a
            // coordinate along cross(n, up) sheared into diagonal shards as
            // the interpolated normal turned with height).
            let xz = v.wpos.xz;
            let y = v.wpos.y + t * 16.0;
            let flow = clamp(v.col.a, 0.0, 1.0);
            let foot = dist * 2.0 * F.camFwd.w * F.screen.w;
            let colN = noise2(xz * 0.8) * 0.7 + noise2(xz * 2.1 + vec2<f32>(7.0, 3.0)) * 0.3;
            // thin columns carry the streak dashes; they resolve up close only
            let cell = vec2<i32>(floor(xz * 2.6));
            let hd = hashi(cell.x, cell.y + 29);
            let hl = hashi(cell.x + 17, cell.y + 5);
            let dash = fract(y * (0.03 + 0.03 * hd) + hd * 7.0);
            let dlen = mix(0.35, 0.8, hl) + flow * 0.15;
            let dashOn = smoothstep(0.0, 0.04, dash) * (1.0 - smoothstep(dlen - 0.04, dlen, dash));
            let detail = 1.0 - smoothstep(0.12, 0.35, foot * 2.6);
            var wc = mix(base * 0.8, base, smoothstep(0.3, 0.36, colN));
            wc = mix(wc, mix(base, vec3<f32>(1.0), 0.5), smoothstep(0.62, 0.66, colN));
            // brighter, denser streaks toward the foam line (col.a = flow: 0 lip .. 1 pool)
            let streak = step(0.62 - flow * 0.22, hd) * dashOn * detail;
            wc = mix(wc, mix(vec3<f32>(0.86, 0.97, 1.0), vec3<f32>(1.0), hl), streak);
            // soft white lip where the water pours over
            let lip = 1.0 - smoothstep(0.035, 0.1, flow + (hl - 0.5) * 0.03);
            wc = mix(wc, mix(base, vec3<f32>(1.0), 0.82), lip);
            let foamLine = 2.6 + noise2(vec2<f32>(xz.x * 0.7 + t * 1.5, xz.y * 0.7)) * 2.2;
            let fb = 1.0 - smoothstep(foamLine - 0.15, foamLine + 0.15, v.wpos.y);
            let bub = smoothstep(0.35, 0.4, noise2(vec2<f32>((xz.x + xz.y * 0.61) * 1.6, (v.wpos.y - t * 4.0) * 0.9)));
            color = mix(wc, mix(vec3<f32>(0.88, 0.96, 1.0), vec3<f32>(1.0), bub), fb);
        } else if (mode > 0.62 && mode < 0.88) {
            // energy: bright bands crawling upward, HDR
            let e = fract(v.wpos.y * 0.35 + (v.wpos.x + v.wpos.z) * 0.05 - t * 1.4);
            let b = smoothstep(0.0, 0.05, e) * (1.0 - smoothstep(0.35, 0.4, e));
            color = base * (1.6 + b * 1.6) + vec3<f32>(b * 0.35);
        }
    } else if (isCloud(v.aux, v.col.rgb)) {
        // toon cumulus: white body lit from above, one cool shade band whose
        // edge billows (world-space noise, 36 / 13 / 5 m: the band curls
        // across each puff and hides the steps where puff meshes meet), a
        // deeper tone on flat undersides, a thin sunlit rim; no halftone.
        // Octaves finer than ~3 px fade out (no shimmer on far banks).
        let foot = dist * 2.0 * F.camFwd.w * F.screen.w;
        let w2 = 1.0 - smoothstep(0.12, 0.3, 0.075 * foot);
        let w3 = 1.0 - smoothstep(0.12, 0.3, 0.19 * foot);
        var bil = cnoise3(v.wpos * 0.028) * 0.5 + 0.25;
        if (w2 > 0.0) {
            bil += (cnoise3(v.wpos * 0.075 + vec3<f32>(5.0, 1.0, 3.0)) - 0.5) * 0.34 * w2;
        }
        if (w3 > 0.0) {
            bil += (cnoise3(v.wpos * 0.19 + vec3<f32>(2.0, 7.0, 4.0)) - 0.5) * 0.2 * w3;
        }
        let nd = ndl * 0.5 + n.y * 0.28 + (bil - 0.5) * 1.0 + 0.1;
        // AA: ndl's own derivative plus the noise term's, from the pixel
        // footprint (no derivatives in this non-uniform branch)
        let aaC = aaN + (0.028 * 0.5 + 0.075 * 0.34 * w2 + 0.19 * 0.2 * w3) * 0.6 * foot + 0.002;
        let lit = band(nd, 0.0, aaC);
        let shadeC = base * mix(vec3<f32>(0.72, 0.82, 0.93), F.shadowTint.rgb, 0.22);
        let litC = base * mix(vec3<f32>(1.0), F.sunColor.rgb, 0.25);
        color = mix(shadeC, litC, lit);
        color = mix(color, shadeC * 0.92, band(-n.y, 0.8, 0.02) * (1.0 - lit));
        let fr = 1.0 - max(dot(n, V), 0.0);
        color += F.sunColor.rgb * smoothstep(0.7, 0.74, fr) * 0.12 * lit;
        color = min(color, vec3<f32>(1.0));
    } else {
        // three hard bands
        let lit = band(ndl, 0.22, aaN);
        let mid = band(ndl, -0.18, aaN);
        let shadowCol = base * mix(vec3<f32>(1.0), F.shadowTint.rgb, F.ambient.w);
        let midCol = mix(shadowCol, base * F.sunColor.rgb, 0.58);
        color = mix(shadowCol, midCol, mid);
        color = mix(color, base * F.sunColor.rgb, lit);
        // hemisphere / sky bounce
        let hemi = 0.5 + 0.5 * n.y;
        color += F.ambient.rgb * base * mix(0.18, 0.4, hemi) * 0.45;
        // halftone dots in the shade (comic print), stronger in violet
        let htAmt = F.clip.w * mix(0.8, 1.2, biome);
        let inShade = 1.0 - lit;
        let dots = max(ht * (1.0 - mid), ht2 * (mid - lit) * 0.5) * htAmt;
        color = mix(color, color * mix(0.7, 0.62, biome), clamp(dots, 0.0, 1.0));
        // rim light on the lit side, cool back-rim on the shadow side
        let fr = 1.0 - max(dot(n, V), 0.0);
        let rim = smoothstep(0.62, 0.66, fr);
        color += F.sunColor.rgb * rim * 0.22 * lit;
        color += F.skyHorizon.rgb * rim * 0.12 * inShade * (0.5 + 0.5 * n.y);
        // toon specular / gold shine (aux.w)
        let h = normalize(L + V);
        let nh = max(dot(n, h), 0.0);
        let shiny = v.aux.w;
        var hot = vec3<f32>(0.0);
        if (shiny > 0.01) {
            // metallic: view-dependent bands plus a crisp hot highlight
            let env = dot(reflect(-V, n), vec3<f32>(0.0, 1.0, 0.0));
            let envB = smoothstep(0.05, 0.12, env);
            color = mix(color, mix(color * 0.82, color * 1.18 + base * 0.12, envB), shiny * 0.7);
            let sp1 = smoothstep(0.955, 0.965, nh);
            let sp2 = smoothstep(0.86, 0.87, nh) * 0.35;
            color += base * sp2 * shiny;
            hot = vec3<f32>(1.0, 0.98, 0.9) * sp1 * 1.6 * shiny;
        }
        // lit surfaces stay in display range; only emissives / glints go HDR (bloom)
        color = min(color, vec3<f32>(1.0)) + hot;
    }
    // emissive (HDR so it blooms)
    let em = v.aux.x + v.extra.x;
    color += base * em * 2.2;
    // glowing dissolve edge (not for the fade near the eye: no screen-filling glow)
    var nearFade = 0.0;
    if (melting(v)) {
        let dd = dissolveAt(v.wpos, v.extra.y);
        nearFade = smoothstep(0.0, 0.3, dd.y - v.extra.y);
        // no hot edge on flat unlit foam lying on the water (it just thins out)
        let flatFoam = select(1.0, 0.0, v.aux.z > 0.5 && v.wpos.y < 0.5);
        let edge = (1.0 - smoothstep(0.0, 0.08, dd.x - dd.y)) * (1.0 - nearFade) * flatFoam;
        color = mix(color, vec3<f32>(3.2, 1.6, 0.5), edge);
        // the lace left near the lens is lit paint, not shade-band blotches
        color = mix(color, min(base * F.sunColor.rgb * 1.05, vec3<f32>(1.0)), nearFade * 0.75);
    }
    // hit flash: in display range (it does not bloom) and keeping the paint's value contrast, so dark paint
    // flashes darker than light paint (a target under a stream of hits, the Watcher's pupil in its iris, stayed
    // readable instead of washing out into one bloomed white disc: QA CD-4)
    let flum = dot(base, vec3<f32>(0.3, 0.59, 0.11));
    let fcol = vec3<f32>(1.0, 0.96, 0.9) * mix(0.55, 1.0, smoothstep(0.06, 0.5, flum));
    color = mix(color, fcol, v.tint.a * (1.0 - nearFade));
    // close to the lens nothing blooms (a collected ring sweeping past the
    // camera flooded the hero with a white-gold halo)
    let nearEye = 1.0 - smoothstep(7.0, 22.0, dist);
    color = mix(color, min(color, vec3<f32>(0.96)), nearEye);
    // aerial fog, thinner with altitude
    let fog = 1.0 - exp(-dist * F.fogColor.w);
    // extra.w > 0: extra fog per instance (scenery chunks fading in at the far edge)
    let fogH = max(clamp(fog * (1.0 - clamp(v.wpos.y / 400.0, 0.0, 0.6)), 0.0, 1.0), clamp(v.extra.w, 0.0, 1.0));
    color = mix(color, F.fogColor.rgb, fogH);
    // extra.w < 0: fade toward the clear sky behind the pixel (no fogColor
    // silhouette, no hit-flash trick): -1 = sky, 0 = solid
    let skyFade = clamp(-v.extra.w, 0.0, 1.0);
    if (toSky && skyFade > 0.0) {
        color = mix(color, skyBehind(-V), skyFade);
    }
    return color;
}

fn clipAndDissolve(v: VOut) {
    if (F.clip.x > 0.5 && v.wpos.y < F.clip.y) {
        discard;
    }
    if (melting(v)) {
        let dd = dissolveAt(v.wpos, v.extra.y);
        if (dd.x < dd.y) {
            discard;
        }
    }
}

// gbuffer normal for post ink: its length carries the instance fade
// (1 + 0.45 |extra.w|), post scales the ink by it, so a fading chunk's ink
// fades with it (its distance stays true: no new edges against the water)
fn inkNormal(n: vec3<f32>, v: VOut) -> vec3<f32> {
    return n * (1.0 + 0.45 * clamp(abs(v.extra.w), 0.0, 1.0));
}

fn gbufOut(v: VOut, ff: bool) -> vec4<f32> {
    // cumulus: no screen-space ink between overlapping puffs (the pushed-back
    // hull inks the silhouette); marked like a sprite, distance kept
    if (v.aux.z <= 0.5 && isCloud(v.aux, v.col.rgb)) {
        return vec4<f32>(3.0, 3.0, 3.0, length(F.camPos.xyz - v.wpos));
    }
    var n = normalize(v.nrm);
    if (!ff) {
        n = -n;
    }
    // unlit flat bands (foam, waterfalls) do not produce ink edges
    let edgeN = select(n, vec3<f32>(0.0, 1.0, 0.0), v.aux.z > 0.5 && v.wpos.y < 0.5);
    return vec4<f32>(inkNormal(edgeN, v), length(F.camPos.xyz - v.wpos));
}

// alpha of the sky-fade path (extra.w < 0): 1 solid .. 0 gone
fn fadeAlpha(v: VOut) -> f32 {
    return 1.0 - clamp(-v.extra.w, 0.0, 1.0);
}

@fragment
fn fs_main(v: VOut, @builtin(front_facing) ff: bool) -> MRT {
    clipAndDissolve(v);
    var o: MRT;
    o.color = vec4<f32>(shade(v, ff, true), 1.0);
    o.gbuf = gbufOut(v, ff);
    return o;
}

// Sky-fade path (renderer: batches with an instance at extra.w < 0, drawn
// after the sky): depth prepass, then the shaded front surface blended by
// alpha over what is really behind (sky, clouds, ridges, water). The
// prepass keeps overlapping faces from showing through each other (no
// x-ray); sprites / particles behind a fading chunk are hidden by it.
@fragment
fn fs_pre(v: VOut) -> MRT {
    clipAndDissolve(v);
    var o: MRT;
    o.color = vec4<f32>(0.0);
    o.gbuf = vec4<f32>(0.0);
    return o;
}

@fragment
fn fs_fade(v: VOut, @builtin(front_facing) ff: bool) -> MRT {
    clipAndDissolve(v);
    var o: MRT;
    o.color = vec4<f32>(shade(v, ff, false), fadeAlpha(v));
    o.gbuf = gbufOut(v, ff);
    return o;
}

// Reflection alpha marks mirrored objects for water.wgsl (sky writes 0), so
// a fading instance fades out of the mirror too. Rock writes up to 2: the
// violet water maps only alpha > 1 to indigo (sprites, rings, ships and
// splashes blend in at <= 1 and keep their own colors).
fn reflAlpha(v: VOut) -> f32 {
    return fadeAlpha(v) * (1.0 + v.rock);
}

@fragment
fn fs_refl(v: VOut, @builtin(front_facing) ff: bool) -> @location(0) vec4<f32> {
    clipAndDissolve(v);
    // the mirrored view flips the winding: visible faces arrive back-facing,
    // so keep their normals as authored (camPos is the mirrored eye here)
    return vec4<f32>(shade(v, !ff, true), reflAlpha(v));
}

// sky-fade prepass: color untouched, alpha = max (renderer REFL_PRE); the
// blended fade pass keeps that alpha, so fading rock keeps its mark
@fragment
fn fs_refl_pre(v: VOut) -> @location(0) vec4<f32> {
    clipAndDissolve(v);
    return vec4<f32>(0.0, 0.0, 0.0, reflAlpha(v));
}

@fragment
fn fs_refl_fade(v: VOut, @builtin(front_facing) ff: bool) -> @location(0) vec4<f32> {
    clipAndDissolve(v);
    return vec4<f32>(shade(v, !ff, false), fadeAlpha(v));
}
