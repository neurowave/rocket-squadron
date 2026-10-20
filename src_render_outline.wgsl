// Inverted-hull ink outline. Same vertex layout as toon.wgsl. Drawn with front-face culling.
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
    @location(3) aux: vec4<f32>,
    @location(4) m0: vec4<f32>,
    @location(5) m1: vec4<f32>,
    @location(6) m2: vec4<f32>,
    @location(7) m3: vec4<f32>,
    @location(8) tint: vec4<f32>,
    @location(9) extra: vec4<f32>,
};

struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) wpos: vec3<f32>,
    @location(1) fog: f32,
    @location(2) keep: f32,
    @location(3) wsrc: vec3<f32>,   // un-inflated world position (dissolve cells)
    @location(4) dis: f32,          // dissolve 0..1
    @location(5) sky: f32,          // sky fade 0..1 (extra.w < 0)
    @location(6) cloud: f32,        // 1 = toon cumulus (blue ink)
};

// same test as toon.wgsl isCloud
fn isCloud(aux: vec4<f32>, col: vec3<f32>) -> bool {
    let flagged = aux.z > 0.3 && aux.z < 0.45;
    let painted = aux.z < 0.01 && aux.w < 0.01 && abs(aux.x - 10.0 / 255.0) < 0.002 && min(min(col.r, col.g), col.b) > 0.85;
    return flagged || painted;
}

// eye-relative clip position (toon.wgsl worldClip: no per-vertex f32 depth noise)
fn worldClip(wp: vec3<f32>) -> vec4<f32> {
    return F.viewProj * vec4<f32>(wp - F.camPos.xyz, 0.0) + F.viewProj * vec4<f32>(F.camPos.xyz, 1.0);
}

@vertex
fn vs_main(i: VIn) -> VOut {
    let m = mat4x4<f32>(i.m0, i.m1, i.m2, i.m3);
    let wp = m * vec4<f32>(i.pos, 1.0);
    let wn = normalize((m * vec4<f32>(i.nrm, 0.0)).xyz);
    let dist = length(F.camPos.xyz - wp.xyz);
    // proportional to distance -> roughly constant width in pixels (ink.w ~ px / 935 at 1080p)
    // tiny on screen (gull flocks, far debris): the pixel-constant hull
    // would swallow the object into a black speck, so it thins out below
    // ~8 px of object radius (vertex distance from the mesh origin x scale)
    let objR = max(length(i.pos), 0.25) * length(i.m0.xyz);
    let pxR = objR / max(dist * F.camFwd.w, 1e-3) * F.screen.y * 0.5;
    let w = F.ink.w * i.aux.y * i.extra.z * max(dist, 1.0) * mix(0.15, 1.0, smoothstep(2.0, 8.0, pxR));
    var p = wp.xyz + wn * w;
    let cloud = isCloud(i.aux, i.col.rgb);
    if (cloud) {
        // cumulus: the hull sits a few meters deeper, so where puffs of one
        // cloud overlap, the puff behind hides it: ink only on the outer
        // silhouette against the sky (no stack of inked balloons)
        p += normalize(p - F.camPos.xyz) * (3.0 + dist * 0.15);
    }
    var o: VOut;
    o.clip = worldClip(p);
    o.wpos = p;
    o.fog = max(1.0 - exp(-dist * F.fogColor.w), clamp(i.extra.w, 0.0, 1.0));
    o.sky = clamp(-i.extra.w, 0.0, 1.0);
    o.cloud = select(0.0, 1.0, cloud);
    o.keep = i.aux.y * i.extra.z;
    o.wsrc = wp.xyz;
    o.dis = i.extra.y;
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
// same pattern as toon.wgsl dissolveAt
fn dissolveAt(wp: vec3<f32>, amount: f32) -> vec2<f32> {
    let d = length(F.camPos.xyz - wp);
    let n = noise3(wp * 2.2) * 0.62 + noise3(wp * 6.5 + vec3<f32>(17.0, 3.0, 9.0)) * 0.38;
    let th = max(amount, 1.0 - smoothstep(5.0, 18.0, d));
    return vec2<f32>(clamp((n - 0.5) * 2.3 + 0.5, 0.0, 1.0), th);
}

// same as toon.wgsl skyBehind (sky.wgsl clear-sky gradient)
fn skyBehind(dir: vec3<f32>) -> vec3<f32> {
    let coastHaze = mix(F.skyHorizon.rgb, vec3<f32>(1.0), 0.28);
    let violetHaze = mix(F.skyHorizon.rgb, F.fogColor.rgb, 0.35) * vec3<f32>(1.05, 1.0, 1.08);
    let hz = mix(coastHaze, violetHaze, clamp(F.params.x, 0.0, 1.0));
    let el = asin(clamp(dir.y, -1.0, 1.0));
    var col = mix(hz, F.skyHorizon.rgb, smoothstep(0.0, 0.07, el));
    return mix(col, F.skyTop.rgb, pow(smoothstep(0.0, 0.75, el), 0.55));
}

struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

fn inkDiscard(v: VOut) {
    if (v.keep <= 0.001) { discard; }
    if (F.clip.x > 0.5 && v.wpos.y < F.clip.y) { discard; }
    // dissolving: the ink goes first (never a dark shell behind the holes)
    if (v.dis > 0.0) {
        let dd = dissolveAt(v.wsrc, v.dis);
        if (dd.y > 0.35 || dd.x < dd.y * 2.5) { discard; }
    }
}

fn inkColor(v: VOut) -> vec3<f32> {
    // clouds take a blue ink (the sky banks' rim colour), not the navy line
    let inkC = mix(F.ink.rgb, mix(F.skyTop.rgb, vec3<f32>(0.16, 0.22, 0.46), 0.7), v.cloud);
    return mix(inkC, F.fogColor.rgb, clamp(v.fog * 1.1, 0.0, 1.0));
}

@fragment
fn fs_main(v: VOut) -> MRT {
    inkDiscard(v);
    var c = inkColor(v);
    if (v.sky > 0.0) {
        c = mix(c, skyBehind(normalize(v.wpos - F.camPos.xyz)), v.sky);
    }
    var o: MRT;
    o.color = vec4<f32>(c, 1.0);
    o.gbuf = vec4<f32>(0.0);  // not written (blend keeps the destination)
    return o;
}

// sky-fade path (toon.wgsl fs_fade): blended by alpha over what is behind
@fragment
fn fs_fade(v: VOut) -> MRT {
    inkDiscard(v);
    var o: MRT;
    o.color = vec4<f32>(inkColor(v), 1.0 - v.sky);
    o.gbuf = vec4<f32>(0.0);
    return o;
}
