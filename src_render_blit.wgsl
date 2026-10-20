// One bilinear copy of a finished frame into Rive's render target
// (renderer.luau final path 'blit': past the output pixel cap).
@group(0) @binding(0) var samp: sampler;
@group(0) @binding(1) var src: texture_2d<f32>;

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

@fragment
fn fs_main(v: VOut) -> @location(0) vec4<f32> {
    return vec4<f32>(textureSampleLevel(src, samp, v.uv, 0.0).rgb, 1.0);
}
