// Swirling vortex portal: toon spiral bands (cream / cyan / blue) inside an
// HDR energy rim, soft outer glow and orbiting sparks. One instance per portal.
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
    @location(0) c0: vec4<f32>,  // center xyz, radius
    @location(1) c1: vec4<f32>,  // facing xyz, time
    @location(2) c2: vec4<f32>,  // intensity 0..1, spin direction, seed, free
    @location(3) c3: vec4<f32>,  // rim tint rgb, core tint amount
};
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) q: vec2<f32>,
    @location(1) c1: vec4<f32>,
    @location(2) c2: vec4<f32>,
    @location(3) c3: vec4<f32>,
    @location(4) wy: f32,
    @location(5) dist: f32,
};
struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

const EXT: f32 = 1.75;
const TAU: f32 = 6.2831853;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, i: VIn) -> VOut {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0));
    let c = corners[vi] * EXT;
    let f = normalize(i.c1.xyz);
    var up0 = vec3<f32>(0.0, 1.0, 0.0);
    if (abs(f.y) > 0.95) {
        up0 = vec3<f32>(0.0, 0.0, 1.0);
    }
    let rt = normalize(cross(f, up0));
    let up = cross(rt, f);
    let wp = i.c0.xyz + (rt * c.x + up * c.y) * i.c0.w;
    var o: VOut;
    o.clip = F.viewProj * vec4<f32>(wp, 1.0);
    o.q = c;
    o.c1 = i.c1;
    o.c2 = i.c2;
    o.c3 = i.c3;
    o.wy = wp.y;
    o.dist = length(F.camPos.xyz - wp);
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

fn shadePortal(v: VOut) -> vec4<f32> {
    let t = v.c1.w;
    let I = clamp(v.c2.x, 0.0, 1.0);
    let spin = select(-1.0, 1.0, v.c2.y >= 0.0);
    let q = v.q;
    let rr = length(q);
    let ang = atan2(q.y, q.x) * spin;
    let open = smoothstep(0.0, 1.0, I);
    let R = max(open, 0.001);
    let rn = rr / R;
    // spiral coordinate: arms twist inward
    let s = ang / TAU * 3.0 + log(max(rn, 0.02)) * 1.25 + t * 0.85;
    // AA width from a copy whose atan2 branch cut sits on the other side:
    // fwidth jumps across a cut, which drew a dashed line left of the eye
    let angB = (atan2(-q.y, -q.x) + 3.14159265) * spin;
    let sB = angB / TAU * 3.0 + log(max(rn, 0.02)) * 1.25;
    let fs = min(fwidth(s), fwidth(sB));
    let fr = fwidth(rr);
    let b = fract(s);
    let cream = vec3<f32>(1.0, 0.96, 0.84);
    let cyan = vec3<f32>(0.52, 0.88, 1.0);
    let blue = vec3<f32>(0.2, 0.5, 0.94);
    let deep = vec3<f32>(0.1, 0.24, 0.66);
    var disc = blue;
    disc = mix(disc, cyan, 1.0 - smoothstep(0.42 - fs, 0.42 + fs, b));
    disc = mix(disc, cream, 1.0 - smoothstep(0.2 - fs, 0.2 + fs, b));
    // ink seam trailing each cream arm
    let seam = 1.0 - smoothstep(fs * 0.8, fs * 2.2, abs(b - 0.62));
    disc = mix(disc, deep, seam * 0.55);
    // depth toward the rim, hot white eye in the center
    disc = mix(disc, deep, smoothstep(0.72, 1.0, rn) * 0.55);
    let eye = 1.0 - smoothstep(0.1, 0.2, rn);
    disc = mix(disc, vec3<f32>(2.2, 2.2, 2.0), eye);
    disc *= 1.0 + 0.25 * sin(t * 3.0);
    let cov = (1.0 - smoothstep(R - fr, R + fr, rr)) * step(0.001, I);
    // rim ring (HDR) + outer glow + orbiting sparks
    let rimTint = v.c3.rgb;
    let ringD = abs(rr - R);
    let ring = 1.0 - smoothstep(0.035, 0.075, ringD);
    let halo = exp(-max(rr - R, 0.0) * 5.0) * step(R, rr);
    let sa = atan2(q.y, q.x) / TAU + t * 0.08 * spin;
    let cell = floor(sa * 28.0);
    let hs = hashi(i32(cell), 7);
    let orbit = R + 0.08 + hs * 0.35;
    let sp = vec2<f32>(fract(sa * 28.0) - 0.5, (rr - orbit) * 9.0);
    let spark = (1.0 - smoothstep(0.1, 0.3, length(sp))) * step(0.55, hs);
    let glow = (cream * rimTint * ring * 2.6 + cyan * halo * 0.9 + cream * spark * 1.8) * I;
    let fade = exp(-v.dist * F.fogColor.w * 0.5);
    let rgb = disc * cov * fade + glow * (1.0 - cov * 0.6);
    return vec4<f32>(rgb, cov * fade);
}


// "no ink here" gbuffer mark for translucent layers (see MARK in renderer.luau)
fn inkMark(c: vec4<f32>) -> vec4<f32> {
    let m = step(0.5, max(c.a, max(c.r, max(c.g, c.b)) * 0.4));
    return vec4<f32>(3.0 * m, 3.0 * m, 3.0 * m, m);
}

@fragment
fn fs_main(v: VOut) -> MRT {
    var o: MRT;
    let c = shadePortal(v);
    o.color = c;
    // the whole swirl disc and its rim hide the ink of whatever lies behind,
    // even when fog thins the disc
    let I = clamp(v.c2.x, 0.0, 1.0);
    let disc = step(length(v.q), max(smoothstep(0.0, 1.0, I), 0.001) + 0.08) * step(0.001, I);
    o.gbuf = max(inkMark(c), vec4<f32>(3.0, 3.0, 3.0, 1.0) * disc);
    return o;
}

@fragment
fn fs_refl(v: VOut) -> @location(0) vec4<f32> {
    if (F.clip.x > 0.5 && v.wy < F.clip.y) { discard; }
    return shadePortal(v);
}
