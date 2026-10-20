// Bloom chain on the HDR scene: 13-tap downsample (first pass thresholds with a
// soft knee and a Karis average against fireflies), 9-tap tent upsample
// accumulated additively back up the chain.
struct Bloom {
    texel: vec4<f32>,   // xy source texel size, z threshold, w knee
    params: vec4<f32>,  // x prefilter on, y upsample radius (texels), zw free
};
@group(0) @binding(0) var<uniform> B: Bloom;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var src: texture_2d<f32>;

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

fn lum(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn prefilter(c: vec3<f32>) -> vec3<f32> {
    let br = max(max(c.r, c.g), c.b);
    let th = B.texel.z;
    let knee = B.texel.w;
    var soft = clamp(br - th + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    let contrib = max(soft, br - th) / max(br, 1e-4);
    return c * contrib;
}

fn karis(c: vec3<f32>) -> f32 {
    return 1.0 / (1.0 + lum(c));
}

@fragment
fn fs_down(v: VOut) -> @location(0) vec4<f32> {
    let o = B.texel.xy;
    let uv = v.uv;
    let a = textureSample(src, samp, uv + o * vec2<f32>(-2.0, -2.0)).rgb;
    let b = textureSample(src, samp, uv + o * vec2<f32>(0.0, -2.0)).rgb;
    let c = textureSample(src, samp, uv + o * vec2<f32>(2.0, -2.0)).rgb;
    let d = textureSample(src, samp, uv + o * vec2<f32>(-2.0, 0.0)).rgb;
    let e = textureSample(src, samp, uv).rgb;
    let f = textureSample(src, samp, uv + o * vec2<f32>(2.0, 0.0)).rgb;
    let g = textureSample(src, samp, uv + o * vec2<f32>(-2.0, 2.0)).rgb;
    let h = textureSample(src, samp, uv + o * vec2<f32>(0.0, 2.0)).rgb;
    let i = textureSample(src, samp, uv + o * vec2<f32>(2.0, 2.0)).rgb;
    let j = textureSample(src, samp, uv + o * vec2<f32>(-1.0, -1.0)).rgb;
    let k = textureSample(src, samp, uv + o * vec2<f32>(1.0, -1.0)).rgb;
    let l = textureSample(src, samp, uv + o * vec2<f32>(-1.0, 1.0)).rgb;
    let m = textureSample(src, samp, uv + o * vec2<f32>(1.0, 1.0)).rgb;
    var col: vec3<f32>;
    if (B.params.x > 0.5) {
        // prefilter each group, weight by Karis to tame single bright pixels
        let g0 = prefilter((j + k + l + m) * 0.25);
        let g1 = prefilter((a + b + d + e) * 0.25);
        let g2 = prefilter((b + c + e + f) * 0.25);
        let g3 = prefilter((d + e + g + h) * 0.25);
        let g4 = prefilter((e + f + h + i) * 0.25);
        let w0 = karis(g0) * 0.5;
        let w1 = karis(g1) * 0.125;
        let w2 = karis(g2) * 0.125;
        let w3 = karis(g3) * 0.125;
        let w4 = karis(g4) * 0.125;
        col = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / max(w0 + w1 + w2 + w3 + w4, 1e-4);
    } else {
        col = e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
    }
    return vec4<f32>(max(col, vec3<f32>(0.0)), 1.0);
}

@fragment
fn fs_up(v: VOut) -> @location(0) vec4<f32> {
    let o = B.texel.xy * B.params.y;
    let uv = v.uv;
    var s = textureSample(src, samp, uv).rgb * 4.0;
    s += (textureSample(src, samp, uv + vec2<f32>(-o.x, 0.0)).rgb
        + textureSample(src, samp, uv + vec2<f32>(o.x, 0.0)).rgb
        + textureSample(src, samp, uv + vec2<f32>(0.0, -o.y)).rgb
        + textureSample(src, samp, uv + vec2<f32>(0.0, o.y)).rgb) * 2.0;
    s += textureSample(src, samp, uv + vec2<f32>(-o.x, -o.y)).rgb
        + textureSample(src, samp, uv + vec2<f32>(o.x, -o.y)).rgb
        + textureSample(src, samp, uv + vec2<f32>(-o.x, o.y)).rgb
        + textureSample(src, samp, uv + vec2<f32>(o.x, o.y)).rgb;
    return vec4<f32>(s / 16.0, 1.0);
}
