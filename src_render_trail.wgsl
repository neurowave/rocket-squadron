// Camera-facing ribbons from point history (jet exhaust, wingtip vapor, smoke).
// One instance per segment; tangents at both ends keep the joints seamless.
// kinds: 0 vapor (soft white), 1 exhaust (additive, white-hot core),
//        2 toon smoke (inked, erodes with age), 3 energy (additive pulsing bands)
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
    @location(0) p0: vec4<f32>,   // xyz, width
    @location(1) p1: vec4<f32>,   // xyz, width
    @location(2) t0: vec4<f32>,   // tangent xyz, alpha
    @location(3) t1: vec4<f32>,   // tangent xyz, alpha
    @location(4) col: vec4<f32>,  // rgba straight
    @location(5) misc: vec4<f32>, // kind, u0 (age at p0), u1, seed
};
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) st: vec2<f32>,    // x across -1..1, y age 0..1
    @location(1) col: vec4<f32>,
    @location(2) misc: vec4<f32>,
    @location(3) wy: f32,
    @location(4) alpha: f32,
    @location(5) len: f32,
    @location(6) dist: f32,
    @location(7) guard: f32, // hero guard gate (heroGuard)
};
struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, i: VIn) -> VOut {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0));
    let c = corners[vi];
    let e = c.x;
    let P = mix(i.p0.xyz, i.p1.xyz, e);
    var T = mix(i.t0.xyz, i.t1.xyz, e);
    if (dot(T, T) < 1e-8) {
        T = i.p1.xyz - i.p0.xyz;
    }
    T = normalize(T + vec3<f32>(1e-6, 0.0, 0.0));
    let view = normalize(F.camPos.xyz - P);
    var side = cross(T, view);
    if (dot(side, side) < 1e-8) {
        side = F.camRight.xyz;
    }
    side = normalize(side);
    var w = mix(i.p0.w, i.p1.w, e) * 0.5;
    if (i32(i.misc.x + 0.5) == 2) {
        // toon smoke billows out as it ages
        w *= 1.0 + 2.0 * clamp(mix(i.misc.y, i.misc.z, e), 0.0, 1.0);
    }
    let wp = P + side * w * c.y;
    var o: VOut;
    o.clip = F.viewProj * vec4<f32>(wp, 1.0);
    o.st = vec2<f32>(c.y, mix(i.misc.y, i.misc.z, e));
    o.col = i.col;
    o.misc = i.misc;
    o.wy = wp.y;
    o.alpha = mix(i.t0.w, i.t1.w, e);
    o.len = mix(0.0, length(i.p1.xyz - i.p0.xyz), e);
    o.dist = length(F.camPos.xyz - wp);
    // wide ribbons (bolt halos, the nova trail) at or in front of the hero
    let hd = length(F.player.xyz - F.camPos.xyz);
    o.guard = smoothstep(0.6, 1.1, mix(i.p0.w, i.p1.w, e)) * (1.0 - smoothstep(hd + 4.0, hd + 9.0, o.dist));
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

fn shadeTrail(v: VOut) -> vec4<f32> {
    let kind = i32(v.misc.x + 0.5);
    let x = v.st.x;
    let age = clamp(v.st.y, 0.0, 1.0);
    let ax = abs(x);
    let t = F.camPos.w;
    var rgb = v.col.rgb;
    var a = 0.0;
    var additive = false;
    if (kind == 0) {
        // vapor: two-step translucent white ribbon
        let body = 1.0 - smoothstep(0.75, 1.0, ax);
        let core = 1.0 - smoothstep(0.25, 0.45, ax);
        a = (body * 0.55 + core * 0.35) * (1.0 - age) * (1.0 - age);
        rgb = mix(v.col.rgb, vec3<f32>(1.0), core * 0.5);
    } else if (kind == 1) {
        // exhaust: white-hot core narrowing into colored flame, fades with age
        let wAge = mix(1.0, 0.35, age);
        let flame = 1.0 - smoothstep(0.4 * wAge, 1.0 * wAge, ax);
        // core narrows with age; edges stay ordered (reversed edges turned the tail white-hot)
        let core = 1.0 - smoothstep(0.1, max(0.3 * (1.0 - age), 0.12), ax);
        let flick = 0.8 + 0.2 * noise2(vec2<f32>(v.st.y * 12.0 - t * 30.0, v.misc.w * 13.0));
        rgb = (v.col.rgb * 2.2 * flame + vec3<f32>(2.4, 2.2, 1.9) * core * (1.0 - age)) * flick;
        a = clamp(flame, 0.0, 1.0) * (1.0 - age);
        additive = true;
    } else if (kind == 2) {
        // toon smoke: a chain of billows with scalloped edges, eroding and
        // lightening with age; the ink rim thins and breaks toward the tail
        let puff = pow(0.5 + 0.5 * sin(v.st.y * 52.0 + v.misc.w * 5.0), 0.7);
        let n = noise2(vec2<f32>(v.st.y * 22.0 + v.misc.w * 3.0, ax * 2.4 + v.misc.w * 7.0));
        // close to the lens the ribbon thins out instead of filling the frame
        let nearK = 1.0 - smoothstep(14.0, 45.0, v.dist);
        let edge = mix(0.38, 0.98, puff) * (1.0 - age * 0.3) * (1.0 - nearK * 0.5) + (n - 0.5) * 0.28;
        let holes = noise2(vec2<f32>(v.st.y * 30.0 - t * 0.5, x * 2.0 + v.misc.w)) < age * 0.55 + nearK * 0.5;
        if (ax > edge || holes) {
            discard;
        }
        let lit = step(0.0, -x + 0.15 + (puff - 0.5) * 0.3);
        let base = mix(v.col.rgb, vec3<f32>(0.66, 0.64, 0.68), age * 0.65);
        rgb = mix(base * 0.72, base, lit);
        let inkK = 0.6 * (1.0 - age) * step(0.35, noise2(vec2<f32>(v.st.y * 12.0, 3.0 + v.misc.w)) + (1.0 - age) * 0.5);
        rgb = mix(rgb, rgb * 0.4, smoothstep(edge - 0.16, edge - 0.08, ax) * inkK);
        a = 1.0;
    } else {
        // energy
        let b = fract(v.st.y * 6.0 - t * 3.0);
        let bands = smoothstep(0.0, 0.1, b) * (1.0 - smoothstep(0.4, 0.5, b));
        let body = 1.0 - smoothstep(0.3, 1.0, ax);
        rgb = v.col.rgb * (1.4 + bands * 1.4);
        a = body * (1.0 - age);
        additive = true;
    }
    a *= v.col.a * v.alpha;
    if (a < 0.003) {
        discard;
    }
    if (additive) {
        return vec4<f32>(rgb * a, 0.0);
    }
    // aerial fog
    return vec4<f32>(rgb * a, a);
}


// DIRECTION #16: big additive flashes at or in front of the hero (muzzle
// flashes, bolt halos, charge rings, the nova orb) dim to 30% over him, so a
// ring flash plus a nova burst never buries him. g: the per-instance size x
// depth gate; F.player is the pilot position (R.wake).
fn heroGuard(px: vec2<f32>, g: f32) -> f32 {
    let hc = F.viewProj * vec4<f32>(F.player.xyz, 1.0);
    if (hc.w < 1.0) {
        return 1.0;
    }
    let hs = vec2<f32>(hc.x / hc.w * 0.5 + 0.5, 0.5 - hc.y / hc.w * 0.5) * F.screen.xy;
    // meters per pixel at the hero's depth
    let d = length(px - hs) * 2.0 * hc.w * F.camFwd.w * F.screen.w;
    return 1.0 - 0.7 * g * (1.0 - smoothstep(1.2, 2.6, d));
}

// "no ink here" gbuffer mark for translucent layers (see MARK in renderer.luau)
fn inkMark(c: vec4<f32>) -> vec4<f32> {
    let m = step(0.5, max(c.a, max(c.r, max(c.g, c.b)) * 0.4));
    return vec4<f32>(3.0 * m, 3.0 * m, 3.0 * m, m);
}

@fragment
fn fs_main(v: VOut) -> MRT {
    var o: MRT;
    let c = shadeTrail(v);
    o.color = c;
    if (c.a == 0.0 && v.guard > 0.001) {
        o.color = vec4<f32>(c.rgb * heroGuard(v.clip.xy, v.guard), 0.0);
    }
    o.gbuf = inkMark(c);
    return o;
}

// Reflection-pass fade at the bottom screen edge (reflection target rows):
// mirrored flyers cut off by the frame read as stray fire blobs.
fn bottomFade(clipY: f32) -> f32 {
    return 1.0 - smoothstep(0.93, 0.995, clipY * F.screen.w);
}

@fragment
fn fs_refl(v: VOut) -> @location(0) vec4<f32> {
    if (F.clip.x > 0.5 && v.wy < F.clip.y) { discard; }
    return shadeTrail(v) * bottomFade(v.clip.y);
}
