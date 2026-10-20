// Port of src/lib/gpu.luau: mesh upload, instance batches, shared vertex
// layouts. See DESIGN.md "Vertex formats" and "Instance format".
//
// Batch.data is the instance buffer (`df` its f32 view). Optional numbers:
// NaN = nil. Instance indices: setSkyFade takes Luau's 1-based i.
import { Mat4 } from "rive/mat4";
import { GPUBuffer, GPUVertexAttribute, GPUVertexBufferLayout } from "rive/gpu";
import { BufferUsage, VertexFormat, VertexStepMode } from "rive/gpu_enums";
import { Builder } from "./meshgen";
import { lmax, lclamp } from "./compat";

export class Mesh {
    vb: GPUBuffer? = null;
    ib: GPUBuffer? = null;
    count: i32 = 0;
    // object-space bounds
    minx: f64 = 0;
    miny: f64 = 0;
    minz: f64 = 0;
    maxx: f64 = 0;
    maxy: f64 = 0;
    maxz: f64 = 0;
    radius: f64 = 0;
    // index format of ib (null = "uint32"; uploadMesh picks "uint16" when every
    // index fits). Optional so hand-built meshes stay valid.
    ifmt: string? = null;
    // optional per-pass index lists in ib's format (scenery chunks,
    // EFFICIENCY_REVIEW 1.3): ibMain = every triangle but the ink-shell
    // copies (the opaque toon / reflection passes, where a copy always loses
    // the depth test to its original), ibHull = the inked triangles (the
    // opaque hull pass discards the rest per fragment)
    ibMain: GPUBuffer? = null;
    countMain: f64 = NaN;
    ibHull: GPUBuffer? = null;
    countHull: f64 = NaN;
}

// One instanced draw of a mesh. Fill with `add*` each frame, then the renderer
// uploads and draws it. `outline` draws the ink hull pass as well.
export class Batch {
    mesh: Mesh;
    buf: GPUBuffer? = null;
    data: ArrayBuffer;
    df: Float32Array; // f32 view of data
    cap: i32;
    n: i32 = 0;
    outline: bool = true;
    reflect: bool = true;
    name: string;
    // set by the renderer each frame (frustum culling of single-instance batches)
    hideMain: bool = false;
    hideRefl: bool = false;
    // setSkyFade was used on this batch (the renderer then checks its
    // instances each frame); fading = some instance has extra.w < 0 this
    // frame, drawn on the blended sky-fade path (Luau nil = false)
    skyFaded: bool = false;
    fading: bool = false;

    constructor(name: string, mesh: Mesh, cap: i32) {
        this.name = name;
        this.mesh = mesh;
        this.cap = cap;
        this.data = new ArrayBuffer(cap * 96);
        this.df = Float32Array.wrap(this.data);
    }
}

export const INSTANCE_STRIDE: i32 = 96;

function attr(format: VertexFormat, slot: u32, offset: u32): GPUVertexAttribute {
    return new GPUVertexAttribute(format, slot, offset);
}

function meshLayout(): GPUVertexBufferLayout {
    let l = new GPUVertexBufferLayout();
    l.stride = 32;
    l.attributes = [
        attr(VertexFormat.float3, 0, 0),
        attr(VertexFormat.float3, 1, 12),
        attr(VertexFormat.unorm8x4, 2, 24),
        attr(VertexFormat.unorm8x4, 3, 28),
    ];
    return l;
}

function instanceLayout(): GPUVertexBufferLayout {
    let l = new GPUVertexBufferLayout();
    l.stride = 96;
    l.stepMode = VertexStepMode.instance;
    l.attributes = [
        attr(VertexFormat.float4, 4, 0),
        attr(VertexFormat.float4, 5, 16),
        attr(VertexFormat.float4, 6, 32),
        attr(VertexFormat.float4, 7, 48),
        attr(VertexFormat.float4, 8, 64),
        attr(VertexFormat.float4, 9, 80),
    ];
    return l;
}

export const MESH_LAYOUT: GPUVertexBufferLayout = meshLayout();
export const INSTANCE_LAYOUT: GPUVertexBufferLayout = instanceLayout();

export function uploadMesh(b: Builder): Mesh {
    let vbytes = max(b.vcount * 32, 32);
    let ibytes = max(b.icount * 4, 4);
    let vdata = new ArrayBuffer(vbytes);
    Uint8Array.wrap(vdata).set(Uint8Array.wrap(b.vb, 0, b.vcount * 32));
    // 16-bit indices when every vertex is addressable (halves index memory)
    let small = b.vcount <= 65535;
    let ibytes2 = small ? max(((b.icount + 1) >> 1) * 4, 4) : ibytes;
    let idata = new ArrayBuffer(ibytes2);
    let iu = b.iu;
    if (small) {
        let o = Uint16Array.wrap(idata);
        for (let i = 0; i < b.icount; i++) o[i] = <u16>iu[i];
    } else {
        Uint32Array.wrap(idata).set(Uint32Array.wrap(b.ib, 0, b.icount));
    }
    let r = 0.0;
    if (b.vcount > 0) {
        let ax = lmax(Math.abs(b.minx), Math.abs(b.maxx));
        let ay = lmax(Math.abs(b.miny), Math.abs(b.maxy));
        let az = lmax(Math.abs(b.minz), Math.abs(b.maxz));
        r = Math.sqrt(ax * ax + ay * ay + az * az);
    }
    let m = new Mesh();
    m.vb = new GPUBuffer(BufferUsage.vertex, <u32>vbytes, vdata, true);
    m.ib = new GPUBuffer(BufferUsage.index, <u32>ibytes2, idata, true);
    m.count = b.icount;
    m.minx = b.minx;
    m.miny = b.miny;
    m.minz = b.minz;
    m.maxx = b.maxx;
    m.maxy = b.maxy;
    m.maxz = b.maxz;
    m.radius = r;
    m.ifmt = small ? "uint16" : "uint32";
    return m;
}

export function batch(name: string, mesh: Mesh, cap: i32, outline: bool = true, reflect: bool = true): Batch {
    let c = max(cap, 1);
    let b = new Batch(name, mesh, c);
    b.buf = new GPUBuffer(BufferUsage.vertex, <u32>(c * 96));
    b.outline = outline;
    b.reflect = reflect;
    return b;
}

export function reset(b: Batch): void {
    b.n = 0;
}

// Instance from an explicit basis. (rx,ry,rz) right, (ux,uy,uz) up and
// (fx,fy,fz) forward must be orthonormal; the mesh's -Z is mapped to forward.
export function addBasis(
    b: Batch,
    px: f64, py: f64, pz: f64,
    rx: f64, ry: f64, rz: f64,
    ux: f64, uy: f64, uz: f64,
    fx: f64, fy: f64, fz: f64,
    sx: f64, sy: f64, sz: f64,
    tr: f64, tg: f64, tb: f64, flash: f64,
    emissive: f64 = 0, dissolve: f64 = 0, outlineScale: f64 = 1
): bool {
    if (b.n >= b.cap) return false;
    let d = b.df;
    let o = b.n * 24;
    d[o] = <f32>(rx * sx);
    d[o + 1] = <f32>(ry * sx);
    d[o + 2] = <f32>(rz * sx);
    d[o + 3] = 0;
    d[o + 4] = <f32>(ux * sy);
    d[o + 5] = <f32>(uy * sy);
    d[o + 6] = <f32>(uz * sy);
    d[o + 7] = 0;
    d[o + 8] = <f32>(-fx * sz);
    d[o + 9] = <f32>(-fy * sz);
    d[o + 10] = <f32>(-fz * sz);
    d[o + 11] = 0;
    d[o + 12] = <f32>px;
    d[o + 13] = <f32>py;
    d[o + 14] = <f32>pz;
    d[o + 15] = 1;
    d[o + 16] = <f32>tr;
    d[o + 17] = <f32>tg;
    d[o + 18] = <f32>tb;
    d[o + 19] = <f32>flash;
    d[o + 20] = <f32>emissive;
    d[o + 21] = <f32>dissolve;
    d[o + 22] = <f32>outlineScale;
    d[o + 23] = 0;
    b.n += 1;
    return true;
}

// Instance from yaw (around +Y), pitch (around right), roll (around forward), uniform scale.
export function addYPR(
    b: Batch,
    px: f64, py: f64, pz: f64,
    yaw: f64, pitch: f64, roll: f64,
    scale: f64,
    tr: f64 = 1, tg: f64 = 1, tb: f64 = 1, flash: f64 = 0,
    emissive: f64 = 0, dissolve: f64 = 0, outlineScale: f64 = 1
): bool {
    let cy = Math.cos(yaw), sy = Math.sin(yaw);
    let cp = Math.cos(pitch), sp = Math.sin(pitch);
    let cr = Math.cos(roll), sr = Math.sin(roll);
    // forward: yaw 0 looks down -Z
    let fx = -sy * cp, fy = sp, fz = -cy * cp;
    // right before roll
    let rx0 = cy, ry0 = 0.0, rz0 = -sy;
    // up before roll = right x forward
    let ux0 = ry0 * fz - rz0 * fy;
    let uy0 = rz0 * fx - rx0 * fz;
    let uz0 = rx0 * fy - ry0 * fx;
    let rx = rx0 * cr + ux0 * sr;
    let ry = ry0 * cr + uy0 * sr;
    let rz = rz0 * cr + uz0 * sr;
    let ux = ux0 * cr - rx0 * sr;
    let uy = uy0 * cr - ry0 * sr;
    let uz = uz0 * cr - rz0 * sr;
    return addBasis(b, px, py, pz, rx, ry, rz, ux, uy, uz, fx, fy, fz, scale, scale, scale, tr, tg, tb, flash, emissive, dissolve, outlineScale);
}

// Instance from a Mat4 (column-major model matrix).
export function addMat(b: Batch, m: Mat4, tr: f64 = 1, tg: f64 = 1, tb: f64 = 1, flash: f64 = 0, emissive: f64 = 0, dissolve: f64 = 0, outlineScale: f64 = 1): bool {
    if (b.n >= b.cap) return false;
    let d = b.df;
    let o = b.n * 24;
    for (let i = 0; i < 16; i++) d[o + i] = m.m[i];
    d[o + 16] = <f32>tr;
    d[o + 17] = <f32>tg;
    d[o + 18] = <f32>tb;
    d[o + 19] = <f32>flash;
    d[o + 20] = <f32>emissive;
    d[o + 21] = <f32>dissolve;
    d[o + 22] = <f32>outlineScale;
    d[o + 23] = 0;
    b.n += 1;
    return true;
}

// Fade instance i (1-based, already added) out: u = 0 solid .. 1 gone.
// The renderer draws the batch after the sky, blended by 1 - u over what is
// really behind it (sky, clouds, water), its reflection and ink fading too.
// Writes extra.w = -u, the ink hull scale extra.z = 1 - u, clears tint.a.
export function setSkyFade(b: Batch, i: i32, u: f64): void {
    b.skyFaded = true;
    let o = (i - 1) * 24;
    let k = lclamp(u, 0, 1);
    let d = b.df;
    d[o + 19] = 0;
    d[o + 22] = <f32>(1 - k);
    d[o + 23] = <f32>(-k);
}

// Identity instance (static world-space geometry).
export function addIdentity(b: Batch): bool {
    return addBasis(b, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1, 1, 1, 1, 1, 1, 1, 0);
}

export function upload(b: Batch): void {
    let g = b.buf;
    if (b.n > 0 && g != null) g.update(0, b.data, <u32>(b.n * 96));
}
