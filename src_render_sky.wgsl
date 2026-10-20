// Stylized sky: clear gradient, sun, toon cumulus banks (towering ones near the
// horizon) with thin shadow bands and ink rims, distant ridges with aerial perspective,
// small upper puffs (coast) and cyan swirl streaks (violet). Fullscreen triangle.
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

struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) ndc: vec2<f32>,
};

struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VOut {
    let x = f32((idx << 1u) & 2u);
    let y = f32(idx & 2u);
    var o: VOut;
    o.ndc = vec2<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0);
    // at the far plane: drawn after opaque geometry, only uncovered pixels shade
    o.clip = vec4<f32>(o.ndc, 1.0, 1.0);
    return o;
}

const TAU: f32 = 6.2831853;

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
fn hash4(n: f32, s: f32) -> vec4<f32> {
    let a = i32(floor(n));
    let b = i32(floor(s * 97.0));
    return vec4<f32>(hashi(a, b), hashi(a + 17, b + 3), hashi(a + 41, b + 7), hashi(a + 73, b + 11));
}
fn noise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let ii = vec2<i32>(i);
    return mix(mix(hashi(ii.x, ii.y), hashi(ii.x + 1, ii.y), u.x),
               mix(hashi(ii.x, ii.y + 1), hashi(ii.x + 1, ii.y + 1), u.x), u.y);
}
fn fbm3(p0: vec2<f32>) -> f32 {
    var p = p0;
    var a = 0.5;
    var s = 0.0;
    for (var k = 0; k < 3; k = k + 1) {
        s += a * noise2(p);
        p = p * 2.07 + vec2<f32>(17.1, 9.3);
        a *= 0.5;
    }
    return s / 0.875;
}

// polynomial smooth minimum (union with a fillet of size k)
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

fn wrapPi(a: f32) -> f32 {
    return a - round(a / TAU) * TAU;
}

// Color the far water fades into and the sky shows just above the horizon.
fn horizonColor() -> vec3<f32> {
    let coastHaze = mix(F.skyHorizon.rgb, vec3<f32>(1.0), 0.28);
    let violetHaze = mix(F.skyHorizon.rgb, F.fogColor.rgb, 0.35) * vec3<f32>(1.05, 1.0, 1.08);
    return mix(coastHaze, violetHaze, clamp(F.params.x, 0.0, 1.0));
}

// Cumulus bank in (azimuth, elevation) space: clusters of billows on a flat
// base. A `tall` share of the clusters tower: narrower, rising from a lower
// base as a leaning, zigzag column of shrinking billows (cumulus congestus).
// Returns (sd, seam, height above the flat base of the nearest cluster);
// seam = gap between the two nearest billows.
fn bankSD(az: f32, el: f32, N: f32, seed: f32, baseLo: f32, baseHi: f32, size: f32, density: f32, tall: f32) -> vec3<f32> {
    let cellW = TAU / N;
    // tallest reach above the base: towers only where the bank has them
    let reach = select(1.25, 2.1, tall > 0.0);
    // above every cluster this bank can hold (widest w0 = 0.54 cellW size)
    if (el > baseHi + cellW * 0.54 * size * reach) {
        return vec3<f32>(1e5, 1e5, 1e5);
    }
    let cosEl = cos(el);
    let ci = floor(az / cellW);
    var sdOut = 1e5;
    var best = 1e5;
    var hb = 1e5;
    for (var k = -1; k <= 1; k = k + 1) {
        let id = ci + f32(k);
        let idw = id - floor(id / N) * N;
        // hash4(idw, seed).x first: most cells are empty or out of reach
        if (hashi(i32(floor(idw)), i32(floor(seed * 97.0))) > density) {
            continue;
        }
        let h = hash4(idw, seed);
        let cx = (id + 0.25 + 0.5 * h.y) * cellW;
        let w0 = cellW * (0.26 + 0.28 * h.z) * size;
        let b0 = mix(baseLo, baseHi, h.w);
        let dx0 = wrapPi(az - cx) * cosEl;
        // outside the widest / tallest box this cluster could have: skip
        // before hashing its shape
        if (abs(dx0) > w0 * 1.3 || el < b0 * 0.35 - w0 * 0.12 || el > b0 + w0 * reach) {
            continue;
        }
        let hT = hash4(idw, seed + 0.9);
        let tw = select(0.0, 1.0, hT.y < tall);
        let w = w0 * (1.0 - 0.25 * tw);
        let b = b0 * (1.0 - 0.65 * tw);
        let H = w * mix(0.5 + 0.35 * hT.x, 1.1 + 0.5 * hT.x, tw);
        // outside this cluster's box (billows reach ~0.65 w above the base,
        // plus the crown or the tower): nothing to evaluate
        if (abs(dx0) > w * 1.3 || el < b - w * 0.12 || el > b + H + w * 0.45) {
            continue;
        }
        var cb = 1e5;
        // billows merge with a small smooth union (no pinched waists between them)
        let kU = w * 0.06;
        let bw = b + (noise2(vec2<f32>(dx0 / w * 2.5 + idw * 3.7, seed * 11.0)) - 0.5) * w * 0.12;
        // main billows along the base
        for (var j = 0; j < 5; j = j + 1) {
            let fj = f32(j);
            let hh = hash4(idw * 7.0 + fj, seed + 0.37);
            let tx = (fj / 4.0 - 0.5) * 2.0;
            let prof = sqrt(max(1.0 - tx * tx * 0.85, 0.0));
            let r = w * (0.24 + 0.1 * hh.x) * (0.6 + 0.5 * prof);
            let c = vec2<f32>(tx * w * 0.74 + (hh.y - 0.5) * w * 0.12, b + r * 0.35 + min(H, w) * 0.35 * prof * (0.6 + 0.4 * hh.z));
            let d = length(vec2<f32>(dx0 - c.x, el - c.y)) - r;
            cb = smin(cb, d, kU);
        }
        // smaller billows crowning the top, or the tower: three levels of
        // paired billows, staggered and leaning, under a cap
        let lean = (hT.z - 0.5) * 0.5 * w;
        let nCrown = select(4, 7, tw > 0.5);
        for (var j = 0; j < nCrown; j = j + 1) {
            let fj = f32(j);
            let hh = hash4(idw * 11.0 + fj, seed + 0.71);
            var c: vec2<f32>;
            var r: f32;
            if (tw > 0.5) {
                if (j == 6) {
                    r = w * (0.17 + 0.04 * hh.y);
                    c = vec2<f32>((hh.x - 0.5) * 0.1 * w + lean, b + H - r * 0.3);
                } else {
                    let side = select(-1.0, 1.0, (j & 1) == 0);
                    let fy = (floor(fj * 0.5) + 1.0) / 3.4 + select(0.0, 0.06, side > 0.0);
                    r = w * (0.25 - 0.09 * fy + 0.05 * hh.y);
                    c = vec2<f32>((side * (0.2 - 0.07 * fy) + (hh.x - 0.5) * 0.08) * w + lean * fy, b + H * fy - r * 0.45);
                }
            } else {
                let tx = (fj / 3.0 - 0.5) * 1.4 + (hh.x - 0.5) * 0.2;
                let prof = sqrt(max(1.0 - tx * tx, 0.0));
                r = w * (0.13 + 0.07 * hh.y);
                c = vec2<f32>(tx * w * 0.6, b + H * (0.62 + 0.3 * hh.z) * prof + r * 0.2);
            }
            let d = length(vec2<f32>(dx0 - c.x, el - c.y)) - r;
            // upper arc of each crown billow is drawn as a seam line (only a
            // short cap on the tower, not whole bubble outlines)
            if (el > c.y + r * mix(-0.2, 0.45, tw)) {
                best = min(best, abs(d));
            }
            cb = smin(cb, d, kU);
        }
        if (tw > 0.5) {
            // solid core up the column: no sky holes between the billow pairs
            let p0 = vec2<f32>(0.0, b + H * 0.15);
            let p1 = vec2<f32>(lean * 0.8, b + H * 0.78);
            let pa = vec2<f32>(dx0, el) - p0;
            let ba = p1 - p0;
            let hc = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            cb = min(cb, length(pa - ba * hc) - w * (0.2 - 0.06 * hc));
        }
        let sdc = max(cb, bw - el);
        if (sdc < sdOut) {
            sdOut = sdc;
            hb = el - bw;
        }
    }
    return vec3<f32>(sdOut, best, hb);
}

struct CloudCol {
    lit: vec3<f32>,
    mid: vec3<f32>,
    shade: vec3<f32>,
    rim: vec3<f32>,
};

fn cloudColors() -> CloudCol {
    var c: CloudCol;
    c.lit = vec3<f32>(1.0, 0.995, 0.985);
    c.mid = mix(vec3<f32>(0.88, 0.91, 1.0), F.skyHorizon.rgb, 0.2);
    // cool light-blue shade band (reference #b9d3ea), dark ink rim
    c.shade = mix(vec3<f32>(0.72, 0.82, 0.92), F.shadowTint.rgb, 0.18);
    c.rim = mix(F.skyTop.rgb, vec3<f32>(0.16, 0.22, 0.46), 0.7);
    return c;
}

// Composite one bank: white body, a thin ragged shadow band along the flat
// base, shade crescents on the lower side of each billow facing away from the
// sun, seams between billows, ink rim (light along the flat base: no cut-out
// sticker edge). lite (reflection pass: half res, posterized by the water):
// one SDF lookup per bank, the base band only.
fn cloudLayer(col: vec3<f32>, az: f32, el: f32, N: f32, seed: f32, baseLo: f32, baseHi: f32, size: f32, density: f32, tall: f32, under: f32, px: f32, haze: f32, cc: CloudCol, lite: bool, sunSide: f32) -> vec3<f32> {
    let a = bankSD(az, el, N, seed, baseLo, baseHi, size, density, tall);
    // open sky: the ragged edge below moves the silhouette by 2.5 px at most
    if (a.x > px * 3.4) {
        return col;
    }
    // ragged, dry-brush silhouette
    let rag = (noise2(vec2<f32>(az, el) / max(px, 1e-5) * 0.11 + seed * 31.0) - 0.5) * px * 5.0;
    let sd = a.x + rag;
    let cov = 1.0 - smoothstep(-px * 0.7, px * 0.7, sd);
    if (cov <= 0.0) {
        return col;
    }
    let bandH = under * (0.5 + 0.35 * noise2(vec2<f32>(az / max(under, 1e-5) * 0.8, seed * 5.0)));
    var shaded = 1.0 - smoothstep(bandH - px, bandH + px, a.z);
    if (!lite) {
        let bl = bankSD(az - sunSide * under * 0.8, el - under * 0.7, N, seed, baseLo, baseHi, size, density, tall);
        shaded = max(shaded, smoothstep(-px, px, bl.x) * 0.9);
    }
    var c = mix(cc.lit, cc.shade, shaded);
    let seam = (1.0 - smoothstep(px * 0.4, px * 1.3, a.y)) * step(sd, -px * 2.5);
    c = mix(c, cc.shade, seam * 0.7 * (1.0 - shaded));
    let baseEdge = 1.0 - smoothstep(px * 2.0, px * 5.0, a.z);
    let rim = smoothstep(-px * 2.6, -px * 1.2, sd) * (0.55 + 0.45 * shaded) * (1.0 - 0.7 * baseEdge);
    c = mix(c, cc.rim, rim * 0.8);
    c = mix(c, horizonColor(), haze);
    return mix(col, c, cov);
}

fn ridgeH(az: f32, freq: f32, seed: f32, oct: i32) -> f32 {
    var p = vec2<f32>(cos(az), sin(az)) * freq + vec2<f32>(seed, seed * 1.7);
    var h = 0.0;
    var a = 0.55;
    for (var k = 0; k < oct; k = k + 1) {
        let n = 1.0 - abs(noise2(p) * 2.0 - 1.0);
        h += a * n * n;
        p = p * 2.13 + vec2<f32>(3.1, 7.7);
        a *= 0.47;
    }
    return h;
}

fn ridgeLow(az: f32, freq: f32, seed: f32) -> f32 {
    let p = vec2<f32>(cos(az), sin(az)) * freq + vec2<f32>(seed, seed * 1.7);
    let n = 1.0 - abs(noise2(p) * 2.0 - 1.0);
    return 0.55 * n * n;
}

fn ridgeLayer(col: vec3<f32>, az: f32, el: f32, freq: f32, seed: f32, amp: f32, base: f32, colLit: vec3<f32>, colShade: vec3<f32>, px: f32, sunAz: f32, inkAmt: f32, oct: i32) -> vec3<f32> {
    let m = smoothstep(0.3, 0.62, noise2(vec2<f32>(cos(az), sin(az)) * 1.6 + vec2<f32>(seed * 3.0, 1.0)));
    let e = 0.01;
    let spire = clamp(F.params.x, 0.0, 1.0);
    var h0 = ridgeH(az, freq, seed, oct);
    h0 = mix(h0, pow(h0, 2.2) * 2.4, spire);
    let h1 = ridgeLow(az + e, freq, seed);
    let hl0 = ridgeLow(az - e, freq, seed);
    let top = mix(-0.01, base + amp * mix(1.0, 1.6, spire) * h0, m);
    let sd = el - top;
    let cov = 1.0 - smoothstep(-px * 0.6, px * 0.6, sd);
    if (cov <= 0.0) {
        return col;
    }
    let slope = (h1 - hl0) / (2.0 * e);
    let sunSide = sign(wrapPi(sunAz - az));
    let lit = step(0.0, -slope * sunSide * m + 0.02 * sunSide);
    var c = mix(colShade, colLit, lit);
    // lighter crest line, ink edge
    c = mix(c, F.ink.rgb, inkAmt * smoothstep(-px * 2.0, -px * 1.0, sd));
    // base sinks into the haze
    c = mix(c, horizonColor(), (1.0 - smoothstep(0.0, max(top, 0.002) * 0.9, el)) * 0.55);
    return mix(col, c, cov);
}

// Small cumulus puffs on a high plane (they drift past overhead for parallax).
fn puffs(col: vec3<f32>, dir: vec3<f32>, px: f32, t: f32, cc: CloudCol, amount: f32) -> vec3<f32> {
    let up = max(dir.y, 0.02);
    let dist = (1400.0 - F.camPos.y) / up;
    let q = (F.camPos.xz + dir.xz * dist) / 420.0 + vec2<f32>(t * 0.004, 0.0);
    let fw = max(fwidth(q.x) + fwidth(q.y), 1e-5);
    let cell = floor(q);
    var best = 1e5;
    var nrmY = 0.0;
    for (var j = -1; j <= 1; j = j + 1) {
        for (var i = -1; i <= 1; i = i + 1) {
            let c = cell + vec2<f32>(f32(i), f32(j));
            let h = hash4(c.x * 131.0 + c.y, 3.3);
            if (h.x > 0.05 * amount) {
                continue;
            }
            let ctr = c + vec2<f32>(0.25, 0.25) + h.yz * 0.5;
            for (var k = 0; k < 4; k = k + 1) {
                let hk = hash4(c.x * 17.0 + c.y * 5.0 + f32(k), 4.1);
                let o = (hk.xy - 0.5) * vec2<f32>(0.8, 0.3);
                let r = 0.14 + 0.12 * hk.z;
                let dv = q - (ctr + o);
                let d = length(dv) - r;
                if (d < best) {
                    best = d;
                    nrmY = dv.y / max(length(dv), 1e-4);
                }
            }
        }
    }
    let cov = (1.0 - smoothstep(-fw, fw, best)) * smoothstep(0.03, 0.12, dir.y);
    if (cov <= 0.0) {
        return col;
    }
    var c = mix(cc.shade, cc.lit, smoothstep(-0.35, -0.2, -nrmY));
    c = mix(c, cc.rim, smoothstep(-fw * 2.2, -fw * 1.2, best) * 0.8);
    c = mix(c, horizonColor(), (1.0 - smoothstep(0.03, 0.35, dir.y)) * 0.5);
    return mix(col, c, cov);
}

// Violet biome: swirling cyan cloud ribbons on a plane.
fn streaks(col: vec3<f32>, dir: vec3<f32>, t: f32, amount: f32) -> vec3<f32> {
    let up = max(dir.y, 0.015);
    let dist = (900.0 - F.camPos.y) / up;
    let q = (F.camPos.xz + dir.xz * dist) * 0.0006;
    let w = q + vec2<f32>(fbm3(q * 1.1 + vec2<f32>(t * 0.012, 0.0)), fbm3(q * 1.1 + vec2<f32>(5.2, -t * 0.01))) * 1.9;
    let s = w.y * 2.4 + fbm3(w * 1.6) * 0.9;
    let d = abs(fract(s) - 0.5);
    let fw = max(fwidth(s), 1e-5);
    let m = noise2(w * vec2<f32>(1.5, 0.7) + vec2<f32>(11.0, 3.0));
    let width = 0.2 * smoothstep(0.4, 0.62, m);
    let fade = smoothstep(0.06, 0.2, dir.y) * amount * smoothstep(0.2, 0.9, width / fw);
    let body = 1.0 - smoothstep(width - fw, width + fw, d);
    let rimW = width + fw * 1.8;
    let rim = (1.0 - smoothstep(rimW - fw, rimW + fw, d)) * step(0.01, width);
    let core = 1.0 - smoothstep(width * 0.45 - fw, width * 0.45 + fw, d);
    var c = mix(vec3<f32>(0.42, 0.78, 0.98), vec3<f32>(0.93, 0.99, 1.0), core);
    let inkC = mix(F.skyTop.rgb, vec3<f32>(0.08, 0.06, 0.3), 0.55);
    var o = mix(col, inkC, rim * fade * 0.9);
    c = mix(c, horizonColor(), (1.0 - smoothstep(0.015, 0.3, dir.y)) * 0.55);
    o = mix(o, c, body * fade);
    return o;
}

fn skyColor(ndc: vec2<f32>, lite: bool) -> vec3<f32> {
    let far = F.invViewProj * vec4<f32>(ndc, 1.0, 1.0);
    let near = F.invViewProj * vec4<f32>(ndc, 0.0, 1.0);
    let dir = normalize(far.xyz / far.w - near.xyz / near.w);
    let t = F.camPos.w;
    let biome = clamp(F.params.x, 0.0, 1.0);
    let el = asin(clamp(dir.y, -1.0, 1.0));
    let az = atan2(dir.x, -dir.z);
    // angular size of one pixel
    let px = 2.0 * F.camFwd.w * F.screen.w * 1.15;
    let sd = normalize(F.sunDir.xyz);
    let sunAz = atan2(sd.x, -sd.z);

    // gradient: hazy bright horizon -> clear deep zenith
    let hz = horizonColor();
    var col = mix(hz, F.skyHorizon.rgb, smoothstep(0.0, 0.07, el));
    col = mix(col, F.skyTop.rgb, pow(smoothstep(0.0, 0.75, el), 0.55));
    // sun: crisp disc + halo (HDR so it blooms)
    let sdot = dot(dir, sd);
    let disc = smoothstep(cos(0.024 * F.sunDir.w) - 0.00002, cos(0.024 * F.sunDir.w) + 0.00002, sdot);
    col += F.sunColor.rgb * (disc * 2.2 + pow(max(sdot, 0.0), 900.0) * 0.8 + pow(max(sdot, 0.0), 24.0) * 0.12);

    let cc = cloudColors();
    let cover = F.params.w;
    let coastAmt = 1.0 - biome;
    if (coastAmt > 0.001) {
        let dens = clamp(0.5 + cover * 2.5, 0.3, 0.9);
        var cloudsCol = col;
        let sunSide = sign(wrapPi(sunAz - az));
        // towering cumulus rising from beyond the horizon: few, big, hazy
        cloudsCol = cloudLayer(cloudsCol, az + 4.0 + t * 0.0004, el, 7.0, 0.35, 0.004, 0.02, 0.85, dens * 0.75, 1.0, 0.012, px, 0.3, cc, lite, sunSide);
        // high sparse clusters
        cloudsCol = cloudLayer(cloudsCol, az + 2.1 + t * 0.0015, el, 9.0, 0.83, 0.2, 0.42, 0.42, dens * 0.45, 0.0, 0.01, px, 0.0, cc, lite, sunSide);
        // far bank: small, low, hazy
        cloudsCol = cloudLayer(cloudsCol, az + t * 0.0006, el, 31.0, 0.61, 0.003, 0.016, 0.95, dens, 0.0, 0.0035, px, 0.42, cc, lite, sunSide);
        // middle bank
        cloudsCol = cloudLayer(cloudsCol, az + 0.9 + t * 0.0008, el, 19.0, 0.47, 0.012, 0.04, 0.95, dens * 0.9, 0.3, 0.008, px, 0.22, cc, lite, sunSide);
        // near bank: big cumulus clusters, some towering
        cloudsCol = cloudLayer(cloudsCol, az - 0.3 + t * 0.001, el, 12.0, 0.23, 0.03, 0.09, 1.0, dens * 0.8, 0.4, 0.016, px, 0.05, cc, lite, sunSide);
        col = mix(col, cloudsCol, coastAmt);
    }
    if (biome > 0.001) {
        col = streaks(col, dir, t, biome);
    }

    // distant ridges: far hazy layer, nearer darker layer
    let farLit = mix(hz, mix(F.fogColor.rgb, F.shadowTint.rgb, 0.3), 0.55);
    let farShade = mix(hz, mix(F.fogColor.rgb, F.shadowTint.rgb, 0.55), 0.6);
    let oct = select(4, 2, lite);
    // ridges never rise above ~0.1 rad: skip them for the open sky
    if (el < 0.12) {
    col = ridgeLayer(col, az, el, 1.4, 2.0, 0.055, 0.004, farLit, farShade, px, sunAz, 0.0, oct);
    let nearLit = mix(F.fogColor.rgb, mix(F.shadowTint.rgb, vec3<f32>(0.62, 0.66, 0.76), 1.0 - biome), 0.45);
    let nearShade = mix(F.fogColor.rgb, F.shadowTint.rgb * 0.82, 0.62);
    col = ridgeLayer(col, az + 1.3, el, 2.3, 5.0, 0.034, 0.002, nearLit, nearShade, px, sunAz, 0.25, oct);
    }

    // below the horizon (past the end of the water grid)
    col = mix(col, hz, 1.0 - smoothstep(-0.0005, 0.0005, el));
    return col;
}

@fragment
fn fs_main(v: VOut) -> MRT {
    var o: MRT;
    // low graphics quality (main-pass clip.y <= -2000): the reflection's lite clouds
    o.color = vec4<f32>(skyColor(v.ndc, F.clip.y < -1500.0), 1.0);
    o.gbuf = vec4<f32>(0.0, 0.0, 0.0, 60000.0);
    return o;
}

@fragment
fn fs_refl(v: VOut) -> @location(0) vec4<f32> {
    // in the reflection pass sky writes alpha 0 so the water can tell mirrored
    // objects (alpha 1) from mirrored sky
    return vec4<f32>(skyColor(v.ndc, F.clip.z > 0.5), select(1.0, 0.0, F.clip.z > 0.5));
}
