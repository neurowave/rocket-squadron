// Instanced particles: toon puffs, sparks, streaks, rings. Procedural shapes, premultiplied output.
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
    @location(0) p0: vec4<f32>,  // pos xyz, size
    @location(1) col: vec4<f32>, // rgba (straight alpha)
    @location(2) vel: vec4<f32>, // velocity xyz (for streaks), stretch
    @location(3) p3: vec4<f32>,  // kind, age 0..1, seed, rotation
};
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) col: vec4<f32>,
    @location(2) p3: vec4<f32>,
    @location(3) wy: f32,
    @location(4) asp: f32,
    @location(5) l2: vec2<f32>,
    @location(6) dist: f32,     // eye to the particle center
    @location(7) guard: f32,    // hero guard gate (heroGuard)
    @location(8) cutG: f32,     // hero cut gate (heroCut)
};
struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, i: VIn) -> VOut {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0));
    let c = corners[vi];
    var right = F.camRight.xyz;
    var up = F.camUp.xyz;
    var sx = i.p0.w;
    let sy = i.p0.w;
    var asp = 1.0;
    var swell = 0.0;
    if (i.vel.w > 0.0) {
        // stretch along the screen-projected velocity
        let v = i.vel.xyz;
        let vr = dot(v, right);
        let vu = dot(v, up);
        let l = max(length(vec2<f32>(vr, vu)), 0.0001);
        let d = vec2<f32>(vr, vu) / l;
        let r2 = right * d.x + up * d.y;
        let u2 = cross(normalize(F.camPos.xyz - i.p0.xyz), r2);
        right = r2;
        up = normalize(u2);
        sx = i.p0.w * (1.0 + i.vel.w * l * 0.05);
        asp = sx / max(sy, 1e-4);
    } else {
        let cr = cos(i.p3.w);
        let sr = sin(i.p3.w);
        let r0 = right;
        right = r0 * cr + up * sr;
        up = up * cr - r0 * sr;
        // smoke puffs (kind 0, not fire, not foam) swell and spread sideways
        // as they age, so a plume or trail merges into one soft silhouette
        // (no column of boulders): grey smoke 2.1x, ink smoke 1.5x
        let cmin = min(min(i.col.r, i.col.g), i.col.b);
        let cmax = max(max(i.col.r, i.col.g), i.col.b);
        let warmV = i.col.r > 0.8 && i.col.b < 0.55;
        if (i32(i.p3.x + 0.5) == 0 && !warmV && cmin < 0.85) {
            swell = select(0.5, 1.1, cmax - cmin < 0.12);
            let g = 1.0 + swell * clamp(i.p3.y, 0.0, 1.0);
            sx = sx * g * 1.2;
            asp = 1.2;
        }
    }
    let sy2 = select(sy, sy * (1.0 + swell * clamp(i.p3.y, 0.0, 1.0)), swell > 0.0 && i.vel.w <= 0.0);
    let wp = i.p0.xyz + right * c.x * sx + up * c.y * sy2;
    var o: VOut;
    o.clip = F.viewProj * vec4<f32>(wp, 1.0);
    o.uv = c;
    o.col = i.col;
    o.p3 = i.p3;
    o.wy = wp.y;
    o.asp = asp;
    // sun direction in this quad's 2D frame (for toon puffs)
    let L = normalize(F.sunDir.xyz);
    o.l2 = normalize(vec2<f32>(dot(L, right), dot(L, up)) + vec2<f32>(0.0, 0.35));
    o.dist = length(F.camPos.xyz - i.p0.xyz);
    // big sprites at or in front of the hero (the hero guard)
    let hd = length(F.player.xyz - F.camPos.xyz);
    o.guard = smoothstep(0.35, 0.8, i.p0.w) * (1.0 - smoothstep(hd + 4.0, hd + 9.0, o.dist));
    // opaque puffs: also the blasts standing round him further back
    o.cutG = smoothstep(0.35, 0.8, i.p0.w) * (1.0 - smoothstep(hd + 18.0, hd + 30.0, o.dist));
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

// kinds: 0 toon puff (fire -> smoke when warm), 1 additive glow (stretched = laser bolt),
// 2 ring shockwave, 3 hard disc, 4 twinkle star (additive), 5 foam splash blob.
// cut: extra erosion of a toon puff (heroCut; 0 = none)
fn shadePart(v: VOut, cut: f32) -> vec4<f32> {
    var kind = i32(v.p3.x + 0.5);
    let age = v.p3.y;
    let seed = v.p3.z;
    let r = length(v.uv);
    var a = 0.0;
    var rgb = v.col.rgb;
    var additive = false;
    let whiteish = min(min(v.col.r, v.col.g), v.col.b) > 0.85;
    if (kind == 0 && whiteish) {
        kind = 5;
    }
    if (kind == 0 || kind == 5) {
        // toon puff: noisy disc, lit toward the sun, inked edge, erodes with age
        let ang = atan2(v.uv.y, v.uv.x);
        let edge = 0.8 + 0.16 * noise2(vec2<f32>(ang * 2.2 + seed * 17.0, seed * 3.0));
        // opaque cel paint: fading (alpha) erodes the shape instead of making
        // it translucent. Foam (kind 5) erodes into finer lace and droplets
        // (a see-through disc with an ink ring read as a soap bubble).
        let fadeE = (1.0 - clamp(v.col.a, 0.0, 1.0)) * 0.9;
        let erode = age * select(0.62, 0.0, kind == 5) + fadeE + select(cut, 0.0, kind == 5);
        let warm = v.col.r > 0.8 && v.col.b < 0.55 && kind == 0;
        // smoke (every non-warm puff: ink smoke, flak, grey smoke; fire once
        // it has burned to smoke) erodes from its rim inward into ragged
        // wisps, not into holes and floating shards (crystal fragments)
        let softK = select(select(smoothstep(0.35, 0.6, age), 1.0, !warm), 0.0, kind == 5);
        let shrink = select(1.0 - fadeE * 0.25, (1.0 - age * 0.45) * (1.0 - fadeE * 0.2), kind == 5);
        let nRaw = select(noise2(v.uv * 2.6 + vec2<f32>(seed * 9.0, seed * 5.0)),
                          noise2(v.uv * 2.2 + vec2<f32>(seed * 9.0, seed * 5.0)) * 0.55 + noise2(v.uv * 6.5 + vec2<f32>(seed * 3.0, seed * 11.0)) * 0.45,
                          kind == 5);
        let n = mix(nRaw, nRaw * 0.55 + (1.0 - r / max(edge * shrink, 0.05)) * 0.6, softK);
        if (r > edge * shrink || n < erode) {
            discard;
        }
        var body = v.col.rgb;
        var smokeK = 0.0;
        if (warm) {
            // fire ramp in the brand inks: white-hot -> brass gold -> the
            // emitter's flame color -> a crimson-magenta blush -> plum smoke
            // (kills burn colorful, never grey-brown)
            let hot = vec3<f32>(2.4, 2.1, 1.5);
            let gold = vec3<f32>(0.95, 0.72, 0.2) * 1.55;
            let crimson = vec3<f32>(0.85, 0.14, 0.37) * 1.15;
            let smoke = vec3<f32>(0.34, 0.27, 0.43);
            body = mix(hot, gold, smoothstep(0.03, 0.13, age));
            body = mix(body, v.col.rgb * 1.3, smoothstep(0.13, 0.27, age));
            body = mix(body, crimson, smoothstep(0.26, 0.42, age) * 0.7);
            body = mix(body, smoke, smoothstep(0.4, 0.64, age));
            smokeK = smoothstep(0.35, 0.6, age);
        } else if (kind == 0) {
            let sat = max(max(v.col.r, v.col.g), v.col.b) - min(min(v.col.r, v.col.g), v.col.b);
            smokeK = 1.0 - smoothstep(0.08, 0.2, sat);
            // grey smoke leans plum (the fire ramp's smoke ink)
            body = mix(body, body * vec3<f32>(1.02, 0.9, 1.22) + vec3<f32>(0.03, 0.0, 0.05), smokeK * 0.6);
        }
        // smoke thins into the sky as it rises and ages (never a stack of
        // dark boulders): lighter toward the sky tint, softer ink
        // (violet: capped, toward a greyer ink; the lavender sky tint read
        // as crystal shards there)
        let biome = clamp(F.params.x, 0.0, 1.0);
        let airK = smokeK * clamp(0.3 + smoothstep(1.0, 28.0, v.wy) * 0.4 + age * 0.35, 0.0, mix(0.85, 0.45, biome));
        let airCol = mix(mix(F.skyHorizon.rgb, vec3<f32>(0.92), 0.35), vec3<f32>(0.66, 0.64, 0.7), biome * 0.7);
        body = mix(body, airCol, airK);
        let lit = smoothstep(-0.08, 0.02, dot(v.uv, v.l2) + 0.2);
        var c = mix(body * select(mix(0.62, 0.8, smokeK), 0.72, kind == 5), body, lit);
        if (kind == 5) {
            c = mix(mix(body, vec3<f32>(0.55, 0.8, 0.95), 0.45), body, lit);
        }
        // continuous ink rim (and around erosion holes) for the fire / smoke puffs
        let rimI = smoothstep(edge * shrink - 0.13, edge * shrink - 0.07, r);
        let holeI = (1.0 - smoothstep(erode, erode + 0.06, n)) * step(0.01, erode);
        // foam's rim is a pale cyan shade that fades with it; smoke's ink
        // thins with age and height
        let fa = clamp(v.col.a, 0.0, 1.0);
        let ink = max(rimI, holeI * (1.0 - softK * 0.7)) * select(0.85 * (1.0 - airK * 0.85) * (1.0 - softK * (0.3 + 0.4 * age)), 0.35 * fa * fa, kind == 5);
        c = mix(c, c * select(vec3<f32>(mix(0.3, 0.55, smokeK)), vec3<f32>(0.66, 0.8, 0.92), kind == 5), ink);
        // bite-mark highlight
        let hl = 1.0 - smoothstep(0.2, 0.24, length(v.uv - v.l2 * 0.35));
        c = mix(c, c * 1.15 + 0.05, hl * lit * 0.6);
        rgb = c;
        a = 1.0;
    } else if (kind == 1) {
        if (v.asp > 1.2) {
            // laser bolt: capsule with a white-hot core, colored halo, brighter head
            let asp = v.asp;
            let qx = max(abs(v.uv.x) * asp - (asp - 1.0), 0.0);
            let d = length(vec2<f32>(qx, v.uv.y));
            let core = 1.0 - smoothstep(0.26, 0.36, d);
            let halo = pow(clamp(1.0 - d, 0.0, 1.0), 1.8);
            let head = mix(0.55, 1.0, smoothstep(-1.0, 0.6, v.uv.x));
            rgb = (v.col.rgb * 2.4 * halo + vec3<f32>(2.6, 2.6, 2.4) * core) * head;
            a = clamp(halo + core, 0.0, 1.0) * head;
        } else {
            let g = pow(clamp(1.0 - r, 0.0, 1.0), 1.6);
            let core = 1.0 - smoothstep(0.15, 0.3, r);
            rgb = v.col.rgb * 1.8 + vec3<f32>(core * 1.2);
            // glows closer than the hero (~8 m) fade out at the lens
            a = g * smoothstep(3.0, 7.0, v.dist);
        }
        additive = true;
    } else if (kind == 2) {
        // ring shockwave, thins with age
        let rad = 0.8;
        let w = mix(0.16, 0.04, age);
        let dr = abs(r - rad);
        a = 1.0 - smoothstep(w * 0.6, w, dr);
        rgb = mix(v.col.rgb * 1.6, vec3<f32>(1.8), 1.0 - smoothstep(0.0, w * 0.5, dr));
        // a ring closer to the lens than the hero (a collected ring sweeping
        // past the camera) melts away and stays in display range instead of
        // flooding the frame with bloom; at the hero's hands (~8-9 m: charge
        // rings, nova, close-kill shockwaves) and beyond it is untouched
        let nearE = 1.0 - smoothstep(3.5, 7.0, v.dist);
        a *= 1.0 - nearE * 0.85;
        rgb = mix(rgb, min(rgb, vec3<f32>(0.95)), nearE);
    } else if (kind == 4) {
        // twinkle star: four spikes + core
        let ax = abs(v.uv);
        let spikes = max(1.0 - smoothstep(0.0, 0.08, ax.y * (1.0 + ax.x * 3.0)) , 1.0 - smoothstep(0.0, 0.08, ax.x * (1.0 + ax.y * 3.0)));
        let fall = 1.0 - smoothstep(0.2, 1.0, r);
        let core = 1.0 - smoothstep(0.1, 0.25, r);
        a = clamp(spikes * fall + core, 0.0, 1.0);
        rgb = v.col.rgb * 1.6 + vec3<f32>(core * 1.5);
        additive = true;
    } else {
        // hard disc (bullets, droplets) with a hot center
        a = 1.0 - smoothstep(0.82, 1.0, r);
        let core = 1.0 - smoothstep(0.3, 0.5, r);
        rgb = mix(v.col.rgb, v.col.rgb * 1.5 + vec3<f32>(0.6), core);
    }
    if (kind != 0 && kind != 5) {
        a *= v.col.a;
    }
    if (a < 0.003) {
        discard;
    }
    if (additive) {
        // additive: premultiplied color with zero coverage
        return vec4<f32>(rgb * a, 0.0);
    }
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

// The same for opaque toon puffs (fire, smoke): a big puff in front of the
// hero or up to ~18 m behind him (gone by 30 m) erodes into ragged wisps
// over a 1.8 -> 3.4 m disc round him, so a blast he flies into (a mine
// chain at his legs, a squadron's fireballs) opens up round him instead of
// burying him or swallowing his outline. Returns the extra erosion.
fn heroCut(px: vec2<f32>, g: f32) -> f32 {
    let hc = F.viewProj * vec4<f32>(F.player.xyz, 1.0);
    if (hc.w < 1.0) {
        return 0.0;
    }
    let hs = vec2<f32>(hc.x / hc.w * 0.5 + 0.5, 0.5 - hc.y / hc.w * 0.5) * F.screen.xy;
    let d = length(px - hs) * 2.0 * hc.w * F.camFwd.w * F.screen.w;
    return 1.3 * g * (1.0 - smoothstep(1.8, 3.4, d));
}

// "no ink here" gbuffer mark for translucent layers (see MARK in renderer.luau)
fn inkMark(c: vec4<f32>) -> vec4<f32> {
    let m = step(0.5, max(c.a, max(c.r, max(c.g, c.b)) * 0.4));
    return vec4<f32>(3.0 * m, 3.0 * m, 3.0 * m, m);
}

@fragment
fn fs_main(v: VOut) -> MRT {
    var o: MRT;
    var cut = 0.0;
    if (v.cutG > 0.001 && i32(v.p3.x + 0.5) == 0) {
        cut = heroCut(v.clip.xy, v.cutG);
    }
    let c = shadePart(v, cut);
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
    return shadePart(v, 0.0) * bottomFade(v.clip.y);
}
