// Camera-facing textured quads sampling a Rive artboard canvas. Instanced.
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

@group(1) @binding(0) var samp: sampler;
@group(1) @binding(1) var tex: texture_2d<f32>;

struct VIn {
    @location(0) center: vec4<f32>,  // xyz, w = roll
    @location(1) size: vec4<f32>,    // xy size (m), z pivot y (0..1), w opacity
    @location(2) tint: vec4<f32>,    // rgb multiply, a = flash
    @location(3) uvr: vec4<f32>,     // uv rect x0,y0,x1,y1
};
struct VOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
    @location(2) op: f32,
    @location(3) wy: f32,
    @location(4) dist: f32,
    @location(5) twin: f32,         // 1 = reflection-only sprite (the hero's underside twin)
};

struct MRT {
    @location(0) color: vec4<f32>,
    @location(1) gbuf: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, i: VIn) -> VOut {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0));
    let c = corners[vi];
    let local = vec2<f32>((c.x - 0.5) * i.size.x, (c.y - i.size.z) * i.size.y);
    let cr = cos(i.center.w);
    let sr = sin(i.center.w);
    let rl = vec2<f32>(local.x * cr - local.y * sr, local.x * sr + local.y * cr);
    let wp = i.center.xyz + F.camRight.xyz * rl.x + F.camUp.xyz * rl.y;
    var o: VOut;
    o.clip = F.viewProj * vec4<f32>(wp, 1.0);
    o.uv = vec2<f32>(mix(i.uvr.x, i.uvr.z, c.x), mix(i.uvr.w, i.uvr.y, c.y));
    o.tint = i.tint;
    // the renderer negates the opacity of reflection-only sprites
    o.op = abs(i.size.w);
    o.twin = select(0.0, 1.0, i.size.w < 0.0);
    o.wy = wp.y;
    o.dist = length(F.camPos.xyz - wp);
    return o;
}

fn shadeSprite(v: VOut) -> vec4<f32> {
    let c = textureSample(tex, samp, v.uv);   // premultiplied
    var rgb = c.rgb * v.tint.rgb;
    rgb = mix(rgb, vec3<f32>(c.a) * 1.4, v.tint.a);
    // aerial fog for distant sprites (premultiplied)
    let fog = clamp(1.0 - exp(-v.dist * F.fogColor.w), 0.0, 1.0);
    rgb = mix(rgb, F.fogColor.rgb * c.a, fog);
    return vec4<f32>(rgb, c.a) * v.op;
}


// "no ink here" gbuffer mark for translucent layers (see MARK in renderer.luau)
fn inkMark(c: vec4<f32>) -> vec4<f32> {
    let m = step(0.5, max(c.a, max(c.r, max(c.g, c.b)) * 0.4));
    return vec4<f32>(3.0 * m, 3.0 * m, 3.0 * m, m);
}

@fragment
fn fs_main(v: VOut) -> MRT {
    let c = shadeSprite(v);
    var o: MRT;
    o.color = c;
    o.gbuf = inkMark(c);
    return o;
}

// Solid sprites (R.setSpriteSolid): opaque texels write depth and a gbuffer
// mark (normal.x = 3) so post ink edges from geometry behind stop here.
@fragment
fn fs_mask(v: VOut) -> MRT {
    let c = textureSample(tex, samp, v.uv);
    if (c.a < 0.5 || v.op < 0.9) { discard; }
    var o: MRT;
    o.color = vec4<f32>(0.0);
    o.gbuf = vec4<f32>(3.0, 3.0, 3.0, v.dist);
    return o;
}

// Reflection-pass fade at the bottom screen edge (reflection target rows):
// mirrored flyers (wingmen) cut off by the frame read as stray fire blobs.
fn bottomFade(clipY: f32) -> f32 {
    return 1.0 - smoothstep(0.93, 0.995, clipY * F.screen.w);
}

@fragment
fn fs_refl(v: VOut) -> @location(0) vec4<f32> {
    if (F.clip.x > 0.5 && v.wy < F.clip.y) { discard; }
    // the hero's underside twin is exempt (DIRECTION #3: keep it whole)
    return shadeSprite(v) * max(bottomFade(v.clip.y), v.twin);
}
