// Painterly toon ocean: saturated teal bands, mirror reflections sliced by
// ripples near the camera, bright fresnel horizon, long white foam brush
// strokes streaming along the flight direction, a V wake behind the pilot,
// blob contact shadows, churning foam spots and sun glints.
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

struct Water {
    wake: array<vec4<f32>, 16>,    // xyz pilot path history (newest first), w strength there
    shadow: array<vec4<f32>, 16>,  // x, z, radius, strength
    spot: array<vec4<f32>, 8>,     // churning foam: x, z, radius, strength
    info: vec4<f32>,               // x wake count, y shadow count, z spot count, w reflection strength
    rail: array<vec4<f32>, 24>,    // flight path around the camera: xz pairs (x0, z0, x1, z1), 48 points
    railInfo: vec4<f32>,           // x s of point 0, y spacing (m), z point count, w on
};

@group(1) @binding(0) var reflSamp: sampler;
@group(1) @binding(1) var reflTex: texture_2d<f32>;
@group(1) @binding(2) var<uniform> W: Water;

struct VIn { @location(0) pos: vec3<f32> };
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) wpos: vec3<f32>,
};
struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

@vertex
fn vs_main(i: VIn) -> VOut {
    // grid is authored around the origin; follow the camera, snapped to the grid step
    let snap = floor(F.camPos.xz / 8.0) * 8.0;
    let wp = vec3<f32>(i.pos.x + snap.x, 0.0, i.pos.z + snap.y);
    var o: VOut;
    o.clip = F.viewProj * vec4<f32>(wp, 1.0);
    o.wpos = wp;
    return o;
}

const PI: f32 = 3.14159265;

fn pcg(v: u32) -> u32 {
    let s = v * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn hashi(x: i32, y: i32) -> f32 {
    return f32(pcg(bitcast<u32>(x) + pcg(bitcast<u32>(y)))) * (1.0 / 4294967295.0);
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

// value noise + its analytic gradient (x value, yz d/dp): one lattice lookup
// instead of four finite-difference samples
fn noiseD(p: vec2<f32>) -> vec3<f32> {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let du = 6.0 * f * (1.0 - f);
    let ii = vec2<i32>(i);
    let a = hashi(ii.x, ii.y);
    let b = hashi(ii.x + 1, ii.y);
    let c = hashi(ii.x, ii.y + 1);
    let d = hashi(ii.x + 1, ii.y + 1);
    let k = a - b - c + d;
    return vec3<f32>(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
                     du.x * ((b - a) + k * u.y),
                     du.y * ((c - a) + k * u.x));
}

fn horizonColor() -> vec3<f32> {
    let coastHaze = mix(F.skyHorizon.rgb, vec3<f32>(1.0), 0.28);
    let violetHaze = mix(F.skyHorizon.rgb, F.fogColor.rgb, 0.35) * vec3<f32>(1.05, 1.0, 1.08);
    return mix(coastHaze, violetHaze, clamp(F.params.x, 0.0, 1.0));
}

fn lum(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.299, 0.587, 0.114));
}

// Long brush strokes in a flow-aligned frame (u across, v along), meters.
// Tapered, curving, with ragged dry-brush edges and bristle gaps.
// Returns (core coverage, fringe coverage).
// alt 0..1: seen from altitude the strokes get longer, smoother and straighter
// (long whitecap streaks instead of a hail of short dashes).
// fade: presence band (centred) over which a stroke fades in (0: on / off).
fn strokes(u: f32, v: f32, fu: f32, weight: f32, seed: f32, curl: f32, S: f32, wScale: f32, presence: f32, alt: f32, fade: f32) -> vec2<f32> {
    let lane = floor(u / S);
    var core = 0.0;
    var fringe = 0.0;
    let wm = smoothstep(0.0, 0.7, weight);
    for (var k = -1; k <= 1; k = k + 1) {
        let L = lane + f32(k);
        let hl = hash4(L, seed);
        let segLen = (45.0 + 130.0 * hl.x) * (1.0 + alt * 2.0);
        let vv = v + hl.y * 997.0;
        let si = floor(vv / segLen);
        let hs = hash4(L * 31.0 + si, seed + 0.5);
        if (hs.x > presence + fade * 0.5) {
            continue;
        }
        let pk = select(1.0, clamp((presence - hs.x) / fade + 0.5, 0.0, 1.0), fade > 1e-4);
        let tv = fract(vv / segLen);
        let a0 = 0.03 + 0.15 * hs.y;
        let a1 = 0.62 + 0.35 * hs.z;
        let local = (tv - a0) / (a1 - a0);
        if (local <= 0.0 || local >= 1.0) {
            continue;
        }
        // meandering lane + a per-stroke S bend short enough to read up close
        let wob = (sin(v * 0.011 + hl.z * 6.28) * 5.5 + sin(v * 0.031 + hl.w * 6.28) * 2.0 + sin(v * 0.083 + hs.w * 6.28) * 0.5
                 + sin(v * 0.12 + hs.x * 6.28) * 1.1 * (1.0 - alt)) * curl;
        // a slight slant per stroke so they converge like painted lines, and a
        // bow along the stroke (a brush arc, ~150 m radius)
        let slant = (hs.z - 0.5) * 0.12 * (tv - 0.5) * segLen;
        let bow = (hs.w - 0.5) * 2.0 * sin(3.14159 * clamp(local, 0.0, 1.0)) * segLen * segLen * 0.00042 * curl * (1.0 - alt * 0.85) / (1.0 + alt * 2.0);
        let cu = (L + 0.5 + (hs.w - 0.5) * 0.4) * S + wob + slant + bow;
        let taper = pow(sin(3.14159 * local), 0.65) * mix(0.6, 1.0, local);
        let wbase = (0.45 + 1.0 * hs.y) * wm * wScale;
        // cheap rejects before any noise: too thin to show, or this pixel lies
        // beyond the widest the stroke + fringe can reach
        let wmax = wbase * taper * 1.22;
        let du = u - cu;
        let d = abs(du);
        if (wmax < fu * 0.35 || d > wmax * 2.25 + 0.15 + fu * 1.5) {
            continue;
        }
        let rough = mix(noise2(vec2<f32>(v * 0.22, L * 7.13 + seed)) * 0.6 + noise2(vec2<f32>(v * 0.9, L * 3.1)) * 0.4, 0.75, alt * 0.8);
        let wdt0 = wbase * taper * (0.62 + 0.6 * rough);
        let vis = smoothstep(0.35, 1.3, wdt0 / fu);
        // torn dry-brush edges where the stroke is wide on screen: each edge
        // frays on its own (two octaves along the stroke)
        let es = select(0.0, 2.7, du > 0.0);
        let tear = (noise2(vec2<f32>(v * 0.55, L * 5.3 + es + seed)) - 0.5) * 0.9
                 + (noise2(vec2<f32>(v * 2.3, L * 1.7 + es * 1.6 + seed)) - 0.5) * 0.5;
        let wdt = wdt0 * max(1.0 + tear * smoothstep(2.0, 9.0, wdt0 / fu), 0.1);
        // bristle gaps running along the stroke (only where they resolve), more
        // of them toward the dry tail
        let br = noise2(vec2<f32>(du / max(wdt0, 0.05) * 2.2 + L * 5.0, v * 0.045));
        let gap = step(br, 0.22 + 0.2 * smoothstep(0.55, 1.0, local)) * smoothstep(2.5, 5.0, wdt0 / fu) * step(0.2, local);
        let c = (1.0 - smoothstep(wdt - fu, wdt + fu, d)) * vis * (1.0 - gap) * pk;
        core = max(core, c);
        // pale wet fringe in patches only (a continuous band reads as road paint)
        let fw = wdt * 1.3 + 0.15;
        let fpatch = smoothstep(0.5, 0.62, noise2(vec2<f32>(v * 0.08, L * 2.3 + seed)));
        fringe = max(fringe, (1.0 - smoothstep(fw - fu, fw + fu, d)) * vis * fpatch * pk);
    }
    return vec2<f32>(core, fringe);
}

// Violet: long sinuous foam ribbons from a domain-warped stripe field (world
// anchored), painted like the coast strokes: broken into segments with dry
// tails, torn edges and bristle gaps where wide on screen, narrower toward
// the camera and never wider than ~70 px (no flat slab up close).
fn swirls(p: vec2<f32>, t: f32, foot: f32, dist: f32) -> vec2<f32> {
    let q = p * 0.012;
    let w = q + vec2<f32>(noise2(q * 0.7 + vec2<f32>(t * 0.02, 0.0)), noise2(q * 0.7 + vec2<f32>(3.1, -t * 0.015))) * 2.4
              + vec2<f32>(noise2(q * 2.1 + 7.0), noise2(q * 2.1 + 1.3)) * 0.45;
    let sv = w.y * 1.3 + w.x * 0.35;
    // along the ribbon (stripe units, ~83 m each)
    let along = w.x * 1.3 - w.y * 0.35;
    let lane = floor(sv);
    let sd = fract(sv) - 0.5;
    let d = abs(sd);
    // one pixel in stripe units
    let px = max(foot * 0.0156, 1e-5);
    let fs = px * 1.2;
    let m = noise2(w * vec2<f32>(0.9, 0.5) + vec2<f32>(5.0, 9.0));
    // each lane breaks into strokes (~25-50 m) that taper to dry tails
    let seg = smoothstep(0.3, 0.52, noise2(vec2<f32>(along * 3.2 + lane * 7.7, lane * 1.9 + 4.0)));
    var width = 0.07 * smoothstep(0.38, 0.62, m) * (0.3 + 0.7 * seg);
    width *= mix(0.5, 1.0, smoothstep(10.0, 60.0, dist));
    // near the camera (the lower third of the frame, out to ~60 m) the
    // ribbon breaks into short dabs (~2-5 m, shorter the closer; world-space
    // noise, so it varies along any heading) that taper to ragged points:
    // dry brush, never one long stroke or an arrow-like hook
    let nearK = 1.0 - smoothstep(35.0, 75.0, dist);
    let dabN = mix(noise2(p * 0.2 + vec2<f32>(lane * 7.3, lane * 3.1)), noise2(p * 0.42 + vec2<f32>(lane * 2.9, 4.0)), 1.0 - smoothstep(14.0, 40.0, dist));
    let dab = dabN * 0.7 + noise2(p * 0.7 + vec2<f32>(lane * 1.7, 9.0)) * 0.3;
    // (after the screen-width cap, or the cap hides the taper)
    width = min(width, px * mix(34.0, 13.0, nearK) * max(F.params2.w, 0.5));
    width *= mix(1.0, smoothstep(0.46, 0.7, dab), nearK);
    let onScreen = width / px;
    if (onScreen < 0.3) {
        return vec2<f32>(0.0);
    }
    // torn edges, each side on its own (two octaves along the ribbon)
    let es = select(0.0, 3.7, sd > 0.0);
    let tear = (noise2(vec2<f32>(along * 40.0, lane * 5.3 + es)) - 0.5) * 0.85
             + (noise2(vec2<f32>(along * 150.0, lane * 2.1 + es * 1.7)) - 0.5) * 0.45
             + (noise2(vec2<f32>(along * 520.0, lane * 4.7 + es * 2.3)) - 0.5) * 0.6 * nearK;
    let wT = width * max(1.0 + tear * smoothstep(2.0, 8.0, onScreen), 0.12);
    // bristle gaps streaking along the ribbon, more toward the dry ends
    let br = noise2(vec2<f32>(sd / max(width, 1e-5) * 2.4 + lane * 5.0, along * 12.0));
    let gap = step(br, 0.2 + 0.25 * (1.0 - seg)) * smoothstep(3.0, 7.0, onScreen);
    let vis = smoothstep(0.3, 1.2, onScreen);
    let body = (1.0 - smoothstep(wT - fs, wT + fs, d)) * vis * (1.0 - gap);
    let fw = wT * 1.8 + px * 2.0;
    let fr = (1.0 - smoothstep(fw - fs, fw + fs, d)) * vis * smoothstep(20.0, 45.0, dist);
    return vec2<f32>(body, fr);
}

// Thin foam dashes lying across the flow (distant wave crests), at least ~1px thick.
fn crests(u: f32, v: f32, fu: f32, fv: f32, seed: f32) -> f32 {
    let cellV = 26.0;
    let cellU = 44.0;
    let cv = floor(v / cellV);
    let cuI = floor(u / cellU);
    let h = hash4(cv * 57.0 + cuI, seed);
    if (h.x > 0.3) {
        return 0.0;
    }
    let lv = v - (cv + 0.2 + 0.6 * h.y) * cellV - sin(u * 0.05 + h.z * 6.0) * 2.0;
    let lu = u - (cuI + 0.5) * cellU;
    let len = cellU * (0.2 + 0.25 * h.z);
    let along = 1.0 - smoothstep(len - fu * 2.0, len, abs(lu));
    let wv = max(0.18, fv * 0.75);
    let line = 1.0 - smoothstep(wv - fv * 0.5, wv + fv * 0.5, abs(lv));
    return line * along * smoothstep(0.08, 0.5, 0.18 / fv + 0.2);
}

fn railPt(i: i32) -> vec2<f32> {
    let q = W.rail[i / 2];
    return select(q.xy, q.zw, (i & 1) == 1);
}

// Rail coordinates of a water point: x = signed lateral offset from the
// flight path (m), y = distance along it (s, world anchored). Level sets of
// x never cross, so strokes built on it are parallel curves that bend with
// the canyon.
fn railUV(p: vec2<f32>) -> vec2<f32> {
    let n = i32(W.railInfo.z);
    let sp = W.railInfo.y;
    // coarse: chords over every 4th point find the neighborhood...
    var bestC = 0;
    var bestC2 = 1e18;
    var ca = railPt(0);
    for (var c = 0; c < 12; c = c + 1) {
        let i1 = min(c * 4 + 4, n - 1);
        if (c * 4 >= n - 1) {
            break;
        }
        let cb = railPt(i1);
        let ab = cb - ca;
        let t = clamp(dot(p - ca, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
        let dq = p - (ca + ab * t);
        let d2 = dot(dq, dq);
        if (d2 < bestC2) {
            bestC2 = d2;
            bestC = c;
        }
        ca = cb;
    }
    // ...then the exact segments around it (12 of 47)
    let k0 = max(bestC * 4 - 4, 0);
    let k1 = min(bestC * 4 + 8, n - 1);
    var best = 1e18;
    var uv = vec2<f32>(0.0);
    var a = railPt(k0);
    for (var k = k0; k < k1; k = k + 1) {
        let b = railPt(k + 1);
        let ab = b - a;
        let l = max(length(ab), 1e-3);
        let dk = ab / l;
        let ap = p - a;
        let raw = dot(ap, dk);
        let lo = select(0.0, -1e9, k == 0);
        let hi = select(l, 1e9, k + 2 >= n);
        let q = a + dk * clamp(raw, lo, hi);
        let dq = p - q;
        let d2 = dot(dq, dq);
        if (d2 < best) {
            best = d2;
            uv = vec2<f32>(dk.x * ap.y - dk.y * ap.x, W.railInfo.x + (f32(k) + raw / l) * sp);
        }
        a = b;
    }
    return uv;
}

@fragment
fn fs_main(v: VOut) -> MRT {
    let t = F.camPos.w;
    let p = v.wpos.xz;
    let toCam = F.camPos.xyz - v.wpos;
    let dist = length(toCam);
    let V = toCam / dist;
    let biome = clamp(F.params.x, 0.0, 1.0);
    let dpx = dpdx(p);
    let dpy = dpdy(p);
    let foot = max(max(length(dpx), length(dpy)), 1e-4);

    // ripple normal (two scrolling octaves), calmer with distance
    let calm = smoothstep(25.0, 600.0, dist);
    let s1 = p * 0.075 + vec2<f32>(t * 0.3, t * 0.19);
    let s2 = p * 0.21 - vec2<f32>(t * 0.47, -t * 0.33);
    let g1 = noiseD(s1);
    let g2 = noiseD(s2);
    let hx = (g1.y + 0.5 * g2.y) * 0.8;
    let hz = (g1.z + 0.5 * g2.z) * 0.8;
    let N = normalize(vec3<f32>(-hx * 0.4 * (1.0 - calm), 1.0, -hz * 0.4 * (1.0 - calm)));

    // flow frame for foam
    var fl = F.params2.xy;
    if (dot(fl, fl) < 1e-4) {
        fl = vec2<f32>(0.0, -1.0);
    }
    fl = normalize(fl);
    let flPerp = vec2<f32>(-fl.y, fl.x);

    // mirror reflection, cut into long horizontal ripple dashes near the camera
    let suv = v.clip.xy * F.screen.zw;
    let nearK = 1.0 - smoothstep(12.0, 320.0, dist);
    // thin horizontal ripple bands (constant distance ~ a screen row), each
    // shifting the mirror sideways by a ramp: sawtooth painted edges, not blocks
    // (across them: eye relative, or the heading turns them about the origin,
    // km away: they raced sideways whenever the view turned)
    let pAcross = dot(p - F.camPos.xz, flPerp);
    let bandV = dist * 0.5 - t * 1.1 + sin(pAcross * 0.04 + t * 0.4) * 0.45;
    let bandI = floor(bandV);
    // the shift varies smoothly along each band (no vertical seams); bands
    // with little shift fade out softly, so the ends are wavy, never square
    let hb = noise2(vec2<f32>(pAcross * 0.035 + bandI * 3.7, bandI * 1.31 + 5.0));
    let sh0 = (hb - 0.5) * 2.0;
    // a triangle ramp across each band: mirrored edges zig-zag (continuous
    // from band to band) instead of stepping like a staircase
    let tri = 1.0 - abs(fract(bandV) * 2.0 - 1.0);
    let slice = sh0 * (0.2 + 0.8 * tri) * smoothstep(0.15, 0.45, abs(sh0));
    let ro = vec2<f32>(slice * 0.0075 * nearK + N.x * 0.012 * (1.0 - calm), N.z * 0.008 * (1.0 - calm) + abs(slice) * 0.002 * nearK);
    let ruv = clamp(suv + ro, vec2<f32>(0.001), vec2<f32>(0.999));
    // four taps streaked down the view (rough water stretches reflections
    // vertically) soften the half-res target's stair steps before posterizing
    // (and a horizontal tent: the x taps span a full half-res texel each way)
    let rt = F.screen.zw * 2.0;
    let r0 = textureSampleLevel(reflTex, reflSamp, ruv, 0.0);
    let r1 = textureSampleLevel(reflTex, reflSamp, clamp(ruv + vec2<f32>(rt.x * 1.0, rt.y * 1.1), vec2<f32>(0.001), vec2<f32>(0.999)), 0.0);
    let r2 = textureSampleLevel(reflTex, reflSamp, clamp(ruv + vec2<f32>(-rt.x * 1.0, rt.y * 2.2), vec2<f32>(0.001), vec2<f32>(0.999)), 0.0);
    let r3 = textureSampleLevel(reflTex, reflSamp, clamp(ruv - vec2<f32>(0.0, rt.y * 1.1), vec2<f32>(0.001), vec2<f32>(0.999)), 0.0);
    let reflS = r0 * 0.34 + r1 * 0.24 + r2 * 0.16 + r3 * 0.26;
    // emissive / HDR objects (rings, glows) mirror in display range: the
    // water never outshines what it reflects
    let refl = min(reflS.rgb, vec3<f32>(1.0));
    // alpha marks mirrored objects (sky writes 0): keep those crisp and strong
    // so the pilot, rocks, spires and ships read in the water
    // (faint alpha, e.g. a sprite's soft glow, does not count: no pale boxes)
    let objA = smoothstep(0.3, 0.75, reflS.a);
    // alpha above 1 marks mirrored rock (toon.wgsl reflAlpha: lit static
    // scenery writes 2); the hero's twin, wingmen, ships, rings and splashes
    // stay at or under 1 (a sprite over rock pulls it back down)
    let rockA = smoothstep(1.1, 1.7, reflS.a);
    let objM = objA * (1.0 - smoothstep(300.0, 1400.0, dist));

    // base teal in calm toon bands
    // deep saturated teal up close, lighter toward the middle distance (reference)
    let nearCol = mix(F.waterDeep.rgb, F.waterShallow.rgb, 0.24);
    let midCol = mix(F.waterDeep.rgb, F.waterShallow.rgb, 0.7);
    var base = mix(nearCol, midCol, smoothstep(20.0, 420.0, dist));
    let bn = noise2(p * 0.0045 + vec2<f32>(t * 0.012, 0.0)) * 0.65 + noise2(p * 0.013 - vec2<f32>(0.0, t * 0.02)) * 0.35;
    let bandT = smoothstep(0.64 - foot * 0.002, 0.64 + foot * 0.002 + 0.004, bn);
    base = mix(base, base * 1.1 + vec3<f32>(0.015, 0.03, 0.035), bandT * (1.0 - calm * 0.5));
    let bandD = 1.0 - smoothstep(0.3 - 0.004, 0.3 + 0.004, bn);
    base = mix(base, base * 0.9, bandD * (1.0 - calm * 0.6));

    // reflection: fresnel-weighted, luminance posterized; grey mirrored rock
    // picks up the water hue, saturated shapes keep their color
    let fres = pow(1.0 - clamp(V.y, 0.0, 1.0), 5.0);
    let rsat = max(max(refl.r, refl.g), refl.b) - min(min(refl.r, refl.g), refl.b);
    let tint = mix(vec3<f32>(1.0), F.waterShallow.rgb / max(lum(F.waterShallow.rgb), 0.2), 0.35 * (1.0 - smoothstep(0.12, 0.35, rsat)));
    let rlum = lum(refl);
    let rq = (floor(rlum * 4.0) + smoothstep(0.3, 0.7, fract(rlum * 4.0))) / 4.0;
    var rl = refl * (rq / max(rlum, 1e-3)) * tint;
    // bright, saturated objects (gold rings, fire) mirror darker and softer
    // than themselves: muted dashes, never a neon halo
    let rmax = max(max(rl.r, rl.g), rl.b);
    let hot = objA * smoothstep(0.55, 0.95, rmax) * smoothstep(0.25, 0.6, rsat);
    rl = mix(rl, mix(vec3<f32>(lum(rl)), rl, 0.7) * 0.66, hot);
    // violet: mirrored rock is a muted indigo that keeps some of the lagoon
    // (reference: #345F97 .. #4A3FA8), never saturated RGB blue; everything
    // else mirrors in its own colors (reference: brown hero, gold rings)
    let rlL = lum(rl);
    let indigo = mix(vec3<f32>(0.2, 0.24, 0.52), vec3<f32>(0.33, 0.31, 0.66), smoothstep(0.12, 0.7, rlL));
    let rlV = mix(indigo, mix(vec3<f32>(rlL), rl, 0.4), 0.22);
    rl = mix(rl, rlV, biome * objA * rockA * (1.0 - hot));
    // objects mirror strongly (reference: bold dark shapes under every rock,
    // ring and pilot); open sky only lightens the water toward the horizon
    let contrast = clamp(abs(rlum - lum(base)) * 2.2 + rsat * 0.8, 0.0, 1.0);
    let rAmt = clamp(max(mix(0.26, 0.92, fres), objM * mix(0.72, 0.9, contrast)), 0.0, 1.0) * W.info.w;
    // dark reflections darken the water multiplicatively (painted shadow shapes)
    // (coast only: against the violet cyan lagoon it turned rock pure blue;
    // violet leans toward the deep water instead)
    let darkK = objA * (1.0 - smoothstep(0.1, 0.45, rlum));
    var objCol = mix(rl, base * rl / max(lum(base), 0.15), darkK * 0.35 * (1.0 - biome));
    objCol = mix(objCol, mix(objCol, F.waterDeep.rgb * 0.7, 0.3), darkK * biome);
    var col = mix(base, mix(base * 0.6 + rl * 0.45, objCol, max(fres, objA * 0.85)), rAmt);
    // light ripple dashes cutting across mirrored shapes (reference: the
    // lagoon shows through the reflections in broken horizontal lines)
    let bw = 0.1 + clamp(foot * 0.6, 0.0, 0.3);
    let rip = (1.0 - smoothstep(bw * 0.5, bw, fract(bandV))) * step(0.62, hashi(i32(bandI), 77))
            * step(0.45, noise2(vec2<f32>(pAcross * 0.05 + bandI * 5.3, bandI * 0.7)));
    col = mix(col, mix(base, vec3<f32>(1.0), 0.1), rip * objM * (1.0 - smoothstep(25.0, 90.0, dist)) * 0.6);

    // bright fresnel toward the horizon
    col = mix(col, horizonColor(), pow(1.0 - clamp(V.y * 1.1, 0.0, 1.0), 14.0) * 0.55);

    // foam strokes: one family of long painted streaks along the flight path
    // (rail space: they curve with the canyon and never cross). Without a rail
    // they fall back to a heading-aligned frame with a hash dissolve between
    // 22.5 deg steps. Every stroke is fixed in rail / world space and drifts
    // along it at 3.5 m/s; nothing about the eye moves one.
    let drift = t * 3.5;
    let coastK = 1.0 - biome;
    // low graphics quality (main-pass clip.y <= -2000): no crest dashes (the fine near streaks stay: they are the
    // sea's speed cue, cheap within 160 m; LOW kept 1 of 3, QA QUAL-1)
    let lite = F.clip.y < -1500.0;
    let hiK = smoothstep(25.0, 110.0, F.camPos.y);
    var foamC = 0.0;
    var foamF = 0.0;
    if (coastK > 0.001 && dist < 1100.0) {
        var nfam = 1;
        var uu0 = 0.0;
        var vv0 = 0.0;
        var uu1 = 0.0;
        var vv1 = 0.0;
        var w0 = 1.0;
        var w1 = 0.0;
        var fu0 = foot;
        var fu1 = foot;
        var fv0 = foot;
        if (W.railInfo.w > 0.5) {
            let ruvp = railUV(p);
            uu0 = ruvp.x;
            vv0 = ruvp.y + drift;
            // footprint of one pixel across / along the rail frame
            fu0 = max(length(vec2<f32>(dot(dpx, flPerp), dot(dpy, flPerp))), 1e-4);
            fv0 = max(length(vec2<f32>(dot(dpx, fl), dot(dpy, fl))), 1e-4);
        } else {
            let ang = atan2(fl.x, -fl.y);
            let secf = (ang + PI) / (PI * 0.125);
            let i0 = floor(secf);
            let wf = smoothstep(0.3, 0.7, fract(secf));
            let a0 = i0 * PI * 0.125;
            let a1 = a0 + PI * 0.125;
            let al0 = vec2<f32>(sin(a0), -cos(a0));
            let ac0 = vec2<f32>(cos(a0), sin(a0));
            let al1 = vec2<f32>(sin(a1), -cos(a1));
            let ac1 = vec2<f32>(cos(a1), sin(a1));
            uu0 = dot(p, ac0);
            vv0 = dot(p, al0) + drift;
            uu1 = dot(p, ac1);
            vv1 = dot(p, al1) + drift;
            fu0 = max(length(vec2<f32>(dot(dpx, ac0), dot(dpy, ac0))), 1e-4);
            fu1 = max(length(vec2<f32>(dot(dpx, ac1), dot(dpy, ac1))), 1e-4);
            fv0 = max(length(vec2<f32>(dot(dpx, al0), dot(dpy, al0))), 1e-4);
            w0 = 1.0 - wf;
            w1 = wf;
            nfam = 2;
        }
        for (var j = 0; j < nfam; j = j + 1) {
            let uu = select(uu0, uu1, j == 1);
            let vv = select(vv0, vv1, j == 1);
            let fu = select(fu0, fu1, j == 1);
            let wgt = select(w0, w1, j == 1);
            if (wgt < 0.001) {
                continue;
            }
            let seed = 3.1 + f32(j) * 1.7;
            // main strokes: wide near the camera, fewer; presence scales with the
            // family weight so a turn swaps strokes one by one, never crossing sets.
            // Four fixed sets by eye height (hiK 0, 1/3, 2/3, 1), the two
            // nearest dissolved: scaling one set by it re-laid every stroke
            // (spacing x |u|, length x s: km/s slides as the eye climbed)
            let nearW = mix(0.72, 1.0, smoothstep(12.0, 110.0, dist));
            let hq = hiK * 3.0;
            let h0 = min(floor(hq), 2.0);
            for (var a = 0; a < 2; a = a + 1) {
                let al = (h0 + f32(a)) / 3.0;
                let wa = wgt * select(1.0 - (hq - h0), hq - h0, a == 1);
                if (wa < 0.001) {
                    continue;
                }
                let sc = strokes(uu, vv, fu, coastK, seed, 1.0, 17.0 + al * 23.0, (1.1 + al * 1.4) * nearW, (0.58 - al * 0.2) * wa, al, 0.2 * wa * (1.0 - wa));
                foamC = max(foamC, sc.x);
                foamF = max(foamF, sc.y * 0.7);
            }
            // finer streaks close to the camera
            if (dist < 160.0) {
                let w2 = wgt * (1.0 - hiK);
                let s2 = strokes(uu + 7.3, vv * 1.3, fu, coastK, seed + 6.6, 0.7, 9.0, 0.5, 0.26 * w2, 0.0, 0.1 * w2 * (1.0 - w2));
                foamC = max(foamC, s2.x * (1.0 - smoothstep(60.0, 160.0, dist)));
            }
            // thin crest dashes across the flow in the middle distance, low only
            if (j == 0 && dist > 40.0 && hiK < 0.99 && !lite) {
                let cr = crests(uu, vv, fu, fv0, 7.7) * coastK * (1.0 - hiK) * wgt;
                foamC = max(foamC, cr * smoothstep(40.0, 110.0, dist) * 0.7);
            }
        }
    }
    if (biome > 0.001) {
        // drift along a fixed world heading (the reach runs +x): along the
        // view heading the offset (1 m/s x clock) swung with every turn
        let sw = swirls(p + vec2<f32>(drift * 0.3, 0.0), t, foot, dist);
        foamC = max(foamC, sw.x * biome);
        foamF = max(foamF, sw.y * biome);
    }
    let foamFade = 1.0 - smoothstep(500.0, 1100.0, dist);
    foamC *= foamFade;
    foamF *= foamFade;

    // pilot wake: V arms + churn along the recent path
    var wake = 0.0;
    var wakeF = 0.0;
    let nw = i32(W.info.x);
    if (F.player.w > 0.001 && nw >= 2) {
        let pp = W.wake[0].xz;
        if (length(p - pp) < 110.0) {
            var best = 1e9;
            var alongD = 0.0;
            var side = 0.0;
            var str = 0.0;
            var ahead = false;
            var cum = 0.0;
            for (var k = 0; k < 15; k = k + 1) {
                if (k + 1 >= nw) {
                    break;
                }
                let a = W.wake[k];
                let b = W.wake[k + 1];
                let ab = b.xz - a.xz;
                let l = max(length(ab), 1e-3);
                let dk = ab / l;
                let raw = dot(p - a.xz, dk);
                let tq = clamp(raw, 0.0, l);
                let q = a.xz + dk * tq;
                let d = length(p - q);
                if (d < best) {
                    best = d;
                    alongD = cum + tq;
                    side = dk.x * (p.y - a.z) - dk.y * (p.x - a.x);
                    str = mix(a.w, b.w, tq / l);
                    ahead = (k == 0 && raw < 0.0);
                }
                cum += l;
            }
            if (!ahead) {
                // arms: two torn brush strands per side that bow outward, taper
                // and break into dashes within a few meters (painted, not bars)
                let a = alongD;
                let sd = sign(side);
                var armC = 0.0;
                var armFr = 0.0;
                for (var k = 0; k < 2; k = k + 1) {
                    let fk = f32(k);
                    let hk = hashi(i32(sd + 3.0) * 7 + k, 41);
                    let armOff = 0.45 + fk * 0.35 + a * (0.2 + 0.07 * fk) + a * a * (0.028 + 0.014 * fk);
                    let armD = abs(side) - armOff;
                    let es = select(0.0, 3.3, armD > 0.0);
                    // stroke body: swells over the first meters, tapers to a dry tail
                    let len = 16.0 + 14.0 * hk - fk * 5.0;
                    let body = smoothstep(0.0, 2.5 + fk * 2.0, a) * (1.0 - smoothstep(len * 0.45, len, a));
                    let n1 = noise2(vec2<f32>(a * 0.9 - t * 0.7, sd * 7.0 + fk * 13.0 + es));
                    let n2 = noise2(vec2<f32>(a * 3.4 - t * 1.1, sd * 11.0 + fk * 5.0 + es));
                    let armW = (0.16 + a * 0.02) * (1.0 - fk * 0.35) * body * (0.45 + 1.0 * n1) + (n2 - 0.5) * 0.12 * body;
                    let brk = noise2(vec2<f32>(a * (0.45 + fk * 0.2) - t * 0.6, sd * 5.0 + fk * 9.0 + 2.0));
                    let dashes = smoothstep(0.34 + a * 0.012, 0.42 + a * 0.012, brk);
                    // bristle streaks inside the stroke
                    let bri = noise2(vec2<f32>(armD / max(armW, 0.05) * 2.4 + fk * 4.0, a * 0.3 + sd));
                    let bristle = 1.0 - step(bri, 0.24) * smoothstep(3.0, 6.0, armW / foot);
                    armC = max(armC, (1.0 - smoothstep(armW - foot, armW + foot, abs(armD))) * dashes * bristle * step(0.02, armW));
                    armFr = max(armFr, (1.0 - smoothstep(armW * 2.0 - foot, armW * 2.0 + foot, abs(armD))) * body * smoothstep(0.3, 0.5, brk) * 0.6);
                }
                // churn under and just behind the pilot: broken blobs, not a tongue
                let cw = 0.4 + a * 0.06;
                let turb = noise2(vec2<f32>(side * 1.6, a * 0.8 - t * 2.4)) * 0.65 + noise2(vec2<f32>(side * 4.1, a * 2.3 - t * 3.1)) * 0.35;
                let ctr = (1.0 - smoothstep(cw - foot, cw + foot, abs(side))) * smoothstep(0.5 + a * 0.012, 0.56 + a * 0.012, turb) * (1.0 - smoothstep(5.0, 18.0, a));
                wake = max(armC, ctr) * str;
                wakeF = max(armFr, ctr * 0.6) * str;
            }
            // downwash rings right under the pilot
            let dp = length(p - pp);
            let ph = dp / 2.6 - t * 1.4;
            let ring = abs(fract(ph) - 0.5) * 2.6;
            let ra = atan2(p.y - pp.y, p.x - pp.x);
            let gaps = smoothstep(0.38, 0.5, noise2(vec2<f32>(ra * 2.6 + floor(ph) * 3.1, floor(ph) * 1.7)));
            let rw = 0.1 + 0.12 * noise2(vec2<f32>(ra * 5.0, floor(ph) * 2.3 + 9.0));
            let rc = (1.0 - smoothstep(rw - foot, rw + foot, ring)) * (1.0 - smoothstep(1.2, 4.5, dp)) * smoothstep(0.35, 0.7, F.player.w) * gaps;
            wake = max(wake, rc * 0.85);
        }
    }

    // churning foam spots (waterfall pools, splashes)
    var spotC = 0.0;
    let ns = i32(W.info.z);
    for (var k = 0; k < 8; k = k + 1) {
        if (k >= ns) {
            break;
        }
        let s = W.spot[k];
        let d = length(p - s.xy) / max(s.z, 0.01);
        if (d < 1.45) {
            let n = noise2(p * 0.55 + vec2<f32>(t * 1.3, -t * 0.9)) * 0.4;
            let body = 1.0 - smoothstep(0.62 + n, 0.7 + n, d);
            let holes = smoothstep(0.28, 0.34, noise2(p * 1.4 - vec2<f32>(t * 2.1, t * 1.2)));
            // one or two ripple rings, broken into arcs of uneven spacing,
            // gone by 1.4 radii (not a sonar ping across the channel)
            let ph = d * 2.2 + noise2(vec2<f32>(atan2(p.y - s.y, p.x - s.x) * 1.3, f32(k) * 3.0)) * 0.35 - t * 0.7;
            let rr = abs(fract(ph) - 0.5);
            let arc = smoothstep(0.42, 0.56, noise2(vec2<f32>(atan2(p.y - s.y, p.x - s.x) * 2.6 + floor(ph) * 3.1, floor(ph) * 1.7 + f32(k) * 5.0)));
            let rings = (1.0 - smoothstep(0.06, 0.11, rr)) * arc * smoothstep(0.72, 0.9, d) * (1.0 - smoothstep(1.15, 1.4, d));
            spotC = max(spotC, max(body * holes, rings * 0.8) * s.w);
        }
    }

    // compose foam: pale teal fringe, white core
    let foamCol = F.foam.rgb;
    let fringeCol = mix(foamCol, F.waterShallow.rgb, 0.5);
    // the pilot's own wake thins where something is mirrored right around him,
    // so his underside reflection reads through the foam
    let reflK = objM * (1.0 - smoothstep(5.0, 10.0, length(p - F.player.xz)));
    let fr = max(foamF, wakeF) * (1.0 - calm * 0.7) * (1.0 - reflK * 0.6);
    col = mix(col, fringeCol, fr * 0.4);
    let fc = max(max(foamC, wake), spotC) * (1.0 - reflK * 0.7);
    col = mix(col, foamCol, fc);

    // blob contact shadows (toon: hard core + soft penumbra)
    var sh = 0.0;
    let nsh = i32(W.info.y);
    for (var k = 0; k < 16; k = k + 1) {
        if (k >= nsh) {
            break;
        }
        let s = W.shadow[k];
        let d = length(p - s.xy) / max(s.z, 0.01);
        let aa = foot / max(s.z, 0.01);
        let core = 1.0 - smoothstep(0.62 - aa, 0.62 + aa, d);
        let pen = 1.0 - smoothstep(1.0 - aa * 3.0, 1.0 + aa, d);
        sh = max(sh, (core * 0.7 + pen * 0.3) * s.w);
    }
    let shadowCol = mix(F.waterDeep.rgb, F.shadowTint.rgb, 0.35) * 0.75;
    col = mix(col, shadowCol, clamp(sh, 0.0, 1.0) * 0.55);

    // reflections and foam stay under the bloom threshold (glints may bloom)
    col = min(col, vec3<f32>(0.97));

    // sun glints: sparse soft dashes lying across the view where the ripples
    // face the sun (near), fine glitter far out; no pixel-block clusters
    let L = normalize(F.sunDir.xyz);
    let H = normalize(L + V);
    let lobe = pow(max(dot(N, H), 0.0), 80.0);
    let cr = normalize(F.camRight.xz + vec2<f32>(1e-4, 0.0));
    let crP = vec2<f32>(-cr.y, cr.x);
    let gcs = 2.4;
    let gc = floor(p / gcs);
    let hg = hashi(i32(gc.x), i32(gc.y));
    let gpos = (gc + vec2<f32>(0.25 + 0.5 * hashi(i32(gc.x) + 5, i32(gc.y) + 9), 0.25 + 0.5 * hashi(i32(gc.x) + 13, i32(gc.y) + 2))) * gcs;
    let gq = p - gpos;
    let glen = 0.25 + 0.35 * hashi(i32(gc.x) + 21, i32(gc.y) + 17);
    let gthk = max(0.05, foot * 0.9);
    let ge = length(vec2<f32>(dot(gq, cr) / glen, dot(gq, crP) / gthk));
    let tw = 0.5 + 0.5 * sin(t * 4.0 + hg * 40.0);
    let dashM = (1.0 - smoothstep(0.55, 1.0, ge)) * step(0.82, hg) * tw;
    let nearG = 1.0 - smoothstep(60.0, 160.0, dist);
    let glintNear = dashM * smoothstep(0.08, 0.5, lobe + 0.12 * step(0.965, hg)) * nearG * (1.0 - calm * 0.8);
    let glintFar = smoothstep(0.55, 0.9, lobe) * step(0.6, noise2(p * 0.12 + t * 0.3)) * (1.0 - nearG) * (1.0 - calm * 0.6);
    col += F.sunColor.rgb * (glintNear * 1.2 + glintFar * 0.9) * (1.0 - fc);

    // far water melts into the horizon haze, then aerial fog
    col = mix(col, horizonColor(), smoothstep(1100.0, 2900.0, dist));
    let fog = 1.0 - exp(-dist * F.fogColor.w * 0.55);
    col = mix(col, F.fogColor.rgb, clamp(fog, 0.0, 1.0) * 0.8);

    var o: MRT;
    o.color = vec4<f32>(col, 1.0);
    o.gbuf = vec4<f32>(0.0, 1.0, 0.0, dist);
    return o;
}
