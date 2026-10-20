// Port of src/lib/meshgen.luau: CPU mesh builder for the toon pipeline.
//
// Vertex layout (32 bytes): pos f32x3, normal f32x3, color unorm8x4, aux
// unorm8x4. Indices u32. Luau's `buffer` becomes an ArrayBuffer with f32 /
// u32 / u8 views (offsets / 4 for the word views). Luau `Vector`s (f32) stay
// `Vector` where the Luau code rounds through them.
import { Vector } from "rive/vector";
import { Mat4 } from "rive/mat4";
import { clock } from "rive/os";
import * as mathx from "./mathx";
import { Rng } from "./compat";
import { HUGE, lmin, lclamp, mod, getOr } from "./compat";

export class InkJob {
    v0: i32 = 0;
    i0: i32 = 0;
    v1: i32 = 0;
    i1: i32 = 0;
    w: f64 = 1;
    phase: i32 = 0;
    k: i32 = 0;
    n: i32 = 0;
    nIds: i32 = 0;
    base: i32 = 0;
}

export class Builder {
    vb: ArrayBuffer;
    vf: Float32Array;
    vu: Uint32Array;
    v8: Uint8Array;
    vcap: i32 = 0;
    vcount: i32 = 0;
    ib: ArrayBuffer;
    iu: Uint32Array;
    icap: i32 = 0;
    icount: i32 = 0;
    col: u32 = 0;
    aux: u32 = 0;
    stack: Array<Mat4?> = [];
    xf: Mat4? = null;
    minx: f64 = HUGE;
    miny: f64 = HUGE;
    minz: f64 = HUGE;
    maxx: f64 = -HUGE;
    maxy: f64 = -HUGE;
    maxz: f64 = -HUGE;
    inkQueue: Array<InkJob>? = null; // deferred ink shells (0-based queue)

    constructor(vcap: i32) {
        this.vcap = vcap;
        this.vb = new ArrayBuffer(vcap * 32);
        this.vf = Float32Array.wrap(this.vb);
        this.vu = Uint32Array.wrap(this.vb);
        this.v8 = Uint8Array.wrap(this.vb);
        this.icap = vcap * 2;
        this.ib = new ArrayBuffer(this.icap * 4);
        this.iu = Uint32Array.wrap(this.ib);
    }

    setVB(nb: ArrayBuffer): void {
        this.vb = nb;
        this.vf = Float32Array.wrap(nb);
        this.vu = Uint32Array.wrap(nb);
        this.v8 = Uint8Array.wrap(nb);
    }

    setIB(nb: ArrayBuffer): void {
        this.ib = nb;
        this.iu = Uint32Array.wrap(nb);
    }
}

export const STRIDE: i32 = 32;
export const SHELL_W: i32 = 1; // aux.w byte of an ink-shell vertex

@inline function c8(v: f64): f64 {
    return Math.floor(mathx.clamp(v, 0, 1) * 255 + 0.5);
}

export function pack8(r: f64, g: f64, b: f64, a: f64): u32 {
    return <u32>(c8(r) + c8(g) * 256 + c8(b) * 65536 + c8(a) * 16777216);
}

export function create(estVerts: i32 = 1024): Builder {
    let b = new Builder(estVerts);
    b.col = pack8(1, 1, 1, 1);
    b.aux = pack8(0, 1, 0, 0);
    return b;
}

// Paint state -----------------------------------------------------------------

export function color(b: Builder, hex: f64, alpha: f64 = 1): void {
    mathx.rgb(hex);
    b.col = pack8(mathx.RGB_R, mathx.RGB_G, mathx.RGB_B, alpha);
}

export function colorf(b: Builder, r: f64, g: f64, bl: f64, a: f64 = 1): void {
    b.col = pack8(r, g, bl, a);
}

// emissive 0..1, outline weight 0..1 (0 = no ink), unlit 0/1, shiny 0..1
export function aux(b: Builder, emissive: f64, outline: f64, unlit: f64 = 0, shiny: f64 = 0): void {
    b.aux = pack8(emissive, outline, unlit, shiny);
}

// Transform stack -------------------------------------------------------------

export function push(b: Builder, m: Mat4): void {
    let cur = b.xf;
    b.stack.push(cur != null ? cur : Mat4.identity());
    if (cur != null) {
        b.xf = cur * m;
    } else {
        b.xf = m;
    }
}

export function pop(b: Builder): void {
    let n = b.stack.length;
    if (n == 0) return;
    let prev = b.stack[n - 1];
    b.stack.pop();
    if (n == 1) {
        b.xf = null;
    } else {
        b.xf = prev;
    }
}

// Low level -------------------------------------------------------------------

function growV(b: Builder, need: i32): void {
    if (b.vcount + need <= b.vcap) return;
    let cap = b.vcap;
    while (cap < b.vcount + need) cap *= 2;
    let nb = new ArrayBuffer(cap * 32);
    Uint8Array.wrap(nb).set(Uint8Array.wrap(b.vb, 0, b.vcount * 32));
    b.setVB(nb);
    b.vcap = cap;
}

function growI(b: Builder, need: i32): void {
    if (b.icount + need <= b.icap) return;
    let cap = b.icap;
    while (cap < b.icount + need) cap *= 2;
    let nb = new ArrayBuffer(cap * 4);
    Uint8Array.wrap(nb).set(Uint8Array.wrap(b.ib, 0, b.icount * 4));
    b.setIB(nb);
    b.icap = cap;
}

const V4 = new StaticArray<f32>(4);

// Adds one vertex (transformed by the current stack) and returns its index.
export function vertex(b: Builder, px: f64, py: f64, pz: f64, nx: f64, ny: f64, nz: f64): i32 {
    let xf = b.xf;
    if (xf != null) {
        let p = xf.transformPoint(<f32>px, <f32>py, <f32>pz);
        px = <f64>p.x;
        py = <f64>p.y;
        pz = <f64>p.z;
        xf.transformVec4(V4, <f32>nx, <f32>ny, <f32>nz, 0);
        let tx = <f64>V4[0], ty = <f64>V4[1], tz = <f64>V4[2];
        let l = Math.sqrt(tx * tx + ty * ty + tz * tz);
        if (l > 1e-9) {
            nx = tx / l;
            ny = ty / l;
            nz = tz / l;
        }
    }
    growV(b, 1);
    let o = b.vcount * 8;
    let vf = b.vf;
    let vu = b.vu;
    vf[o] = <f32>px;
    vf[o + 1] = <f32>py;
    vf[o + 2] = <f32>pz;
    vf[o + 3] = <f32>nx;
    vf[o + 4] = <f32>ny;
    vf[o + 5] = <f32>nz;
    vu[o + 6] = b.col;
    vu[o + 7] = b.aux;
    if (px < b.minx) b.minx = px;
    if (py < b.miny) b.miny = py;
    if (pz < b.minz) b.minz = pz;
    if (px > b.maxx) b.maxx = px;
    if (py > b.maxy) b.maxy = py;
    if (pz > b.maxz) b.maxz = pz;
    let i = b.vcount;
    b.vcount += 1;
    return i;
}

export function tri(b: Builder, i0: i32, i1: i32, i2: i32): void {
    growI(b, 3);
    let o = b.icount;
    let iu = b.iu;
    iu[o] = <u32>i0;
    iu[o + 1] = <u32>i1;
    iu[o + 2] = <u32>i2;
    b.icount += 3;
}

// Flat triangle from three points (counter-clockwise seen from the front).
export function flatTri(b: Builder, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, cx: f64, cy: f64, cz: f64): void {
    let ux = bx - ax, uy = by - ay, uz = bz - az;
    let vx = cx - ax, vy = cy - ay, vz = cz - az;
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-12) return;
    nx = nx / l;
    ny = ny / l;
    nz = nz / l;
    let i0 = vertex(b, ax, ay, az, nx, ny, nz);
    let i1 = vertex(b, bx, by, bz, nx, ny, nz);
    let i2 = vertex(b, cx, cy, cz, nx, ny, nz);
    tri(b, i0, i1, i2);
}

// Flat quad p0..p3 counter-clockwise.
export function flatQuad(b: Builder, p0: Vector, p1: Vector, p2: Vector, p3: Vector): void {
    flatTri(b, p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, p2.x, p2.y, p2.z);
    flatTri(b, p0.x, p0.y, p0.z, p2.x, p2.y, p2.z, p3.x, p3.y, p3.z);
}

@inline function V(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

// Primitives ------------------------------------------------------------------

// Axis-aligned box centered at (cx, cy, cz) with full size (sx, sy, sz). Flat shaded.
export function box(b: Builder, cx: f64, cy: f64, cz: f64, sx: f64, sy: f64, sz: f64): void {
    let hx = sx / 2, hy = sy / 2, hz = sz / 2;
    let x0 = cx - hx, x1 = cx + hx, y0 = cy - hy, y1 = cy + hy, z0 = cz - hz, z1 = cz + hz;
    flatQuad(b, V(x0, y0, z1), V(x1, y0, z1), V(x1, y1, z1), V(x0, y1, z1));
    flatQuad(b, V(x1, y0, z0), V(x0, y0, z0), V(x0, y1, z0), V(x1, y1, z0));
    flatQuad(b, V(x1, y0, z1), V(x1, y0, z0), V(x1, y1, z0), V(x1, y1, z1));
    flatQuad(b, V(x0, y0, z0), V(x0, y0, z1), V(x0, y1, z1), V(x0, y1, z0));
    flatQuad(b, V(x0, y1, z1), V(x1, y1, z1), V(x1, y1, z0), V(x0, y1, z0));
    flatQuad(b, V(x0, y0, z0), V(x1, y0, z0), V(x1, y0, z1), V(x0, y0, z1));
}

// Cylinder / frustum along +Y from y0 with height h. r0 bottom, r1 top.
export function cylinder(b: Builder, cx: f64, y0: f64, cz: f64, r0: f64, r1: f64, h: f64, seg: i32, caps: bool, smooth: bool = false): void {
    let slope = (r0 - r1) / h;
    for (let i = 0; i < seg; i++) {
        let a0 = <f64>i / <f64>seg * mathx.TAU;
        let a1 = <f64>(i + 1) / <f64>seg * mathx.TAU;
        let c0 = Math.cos(a0), s0 = Math.sin(a0), c1 = Math.cos(a1), s1 = Math.sin(a1);
        let p00 = V(cx + c0 * r0, y0, cz + s0 * r0);
        let p10 = V(cx + c1 * r0, y0, cz + s1 * r0);
        let p11 = V(cx + c1 * r1, y0 + h, cz + s1 * r1);
        let p01 = V(cx + c0 * r1, y0 + h, cz + s0 * r1);
        if (smooth) {
            let ny = slope;
            let l0 = Math.sqrt(c0 * c0 + ny * ny + s0 * s0);
            let l1 = Math.sqrt(c1 * c1 + ny * ny + s1 * s1);
            let i0 = vertex(b, p00.x, p00.y, p00.z, c0 / l0, ny / l0, s0 / l0);
            let i1 = vertex(b, p10.x, p10.y, p10.z, c1 / l1, ny / l1, s1 / l1);
            let i2 = vertex(b, p11.x, p11.y, p11.z, c1 / l1, ny / l1, s1 / l1);
            let i3 = vertex(b, p01.x, p01.y, p01.z, c0 / l0, ny / l0, s0 / l0);
            tri(b, i0, i2, i1);
            tri(b, i0, i3, i2);
        } else {
            flatQuad(b, p00, p01, p11, p10);
        }
        if (caps) {
            if (r1 > 0) flatTri(b, cx, y0 + h, cz, p11.x, p11.y, p11.z, p01.x, p01.y, p01.z);
            if (r0 > 0) flatTri(b, cx, y0, cz, p00.x, p00.y, p00.z, p10.x, p10.y, p10.z);
        }
    }
}

// Low-poly UV sphere. flat=true gives faceted shading.
let PT_X: f64 = 0, PT_Y: f64 = 0, PT_Z: f64 = 0;
@inline function spherePt(i: i32, j: i32, seg: i32, rings: i32): void {
    let th = <f64>i / <f64>seg * mathx.TAU;
    let ph = <f64>j / <f64>rings * Math.PI;
    PT_X = Math.sin(ph) * Math.cos(th);
    PT_Y = Math.cos(ph);
    PT_Z = Math.sin(ph) * Math.sin(th);
}

export function sphere(b: Builder, cx: f64, cy: f64, cz: f64, rx: f64, ry: f64, rz: f64, seg: i32, rings: i32, flat: bool = false): void {
    for (let j = 0; j < rings; j++) {
        for (let i = 0; i < seg; i++) {
            spherePt(i, j, seg, rings);
            let ax = PT_X, ay = PT_Y, az = PT_Z;
            spherePt(i + 1, j, seg, rings);
            let bx = PT_X, by = PT_Y, bz = PT_Z;
            spherePt(i + 1, j + 1, seg, rings);
            let ccx = PT_X, ccy = PT_Y, ccz = PT_Z;
            spherePt(i, j + 1, seg, rings);
            let dx = PT_X, dy = PT_Y, dz = PT_Z;
            if (flat) {
                let A = V(cx + ax * rx, cy + ay * ry, cz + az * rz);
                let B = V(cx + bx * rx, cy + by * ry, cz + bz * rz);
                let C = V(cx + ccx * rx, cy + ccy * ry, cz + ccz * rz);
                let D = V(cx + dx * rx, cy + dy * ry, cz + dz * rz);
                if (j == 0) {
                    flatTri(b, A.x, A.y, A.z, C.x, C.y, C.z, D.x, D.y, D.z);
                } else if (j == rings - 1) {
                    flatTri(b, A.x, A.y, A.z, B.x, B.y, B.z, D.x, D.y, D.z);
                } else {
                    flatQuad(b, A, B, C, D);
                }
            } else {
                let ia = vertex(b, cx + ax * rx, cy + ay * ry, cz + az * rz, ax, ay, az);
                let ib = vertex(b, cx + bx * rx, cy + by * ry, cz + bz * rz, bx, by, bz);
                let ic = vertex(b, cx + ccx * rx, cy + ccy * ry, cz + ccz * rz, ccx, ccy, ccz);
                let id = vertex(b, cx + dx * rx, cy + dy * ry, cz + dz * rz, dx, dy, dz);
                tri(b, ia, ib, ic);
                tri(b, ia, ic, id);
            }
        }
    }
}

// Torus around the Z axis. Smooth shaded.
export function torus(b: Builder, R: f64, r: f64, segU: i32, segV: i32): void {
    let base = b.vcount;
    for (let i = 0; i <= segU; i++) {
        let u = <f64>i / <f64>segU * mathx.TAU;
        let cu = Math.cos(u), su = Math.sin(u);
        for (let j = 0; j <= segV; j++) {
            let v = <f64>j / <f64>segV * mathx.TAU;
            let cv = Math.cos(v), sv = Math.sin(v);
            vertex(b, (R + r * cv) * cu, (R + r * cv) * su, r * sv, cv * cu, cv * su, sv);
        }
    }
    for (let i = 0; i < segU; i++) {
        for (let j = 0; j < segV; j++) {
            let a = base + i * (segV + 1) + j;
            let c = a + segV + 1;
            tri(b, a, c, a + 1);
            tri(b, a + 1, c, c + 1);
        }
    }
}

// Noisy faceted boulder (displaced sphere). Points as f32 (Luau Vector rows).
const ROCK_X = new Array<f32>(0);
const ROCK_Y = new Array<f32>(0);
const ROCK_Z = new Array<f32>(0);

export function rock(b: Builder, cx: f64, cy: f64, cz: f64, rx: f64, ry: f64, rz: f64, seed: f64, sg: i32 = 9, rg: i32 = 6): void {
    // pts[j][i] (1-based in Luau) at (j - 1) * sg + (i - 1)
    let PX = ROCK_X, PY = ROCK_Y, PZ = ROCK_Z;
    let k = 0;
    for (let j = 0; j <= rg; j++) {
        for (let i = 0; i < sg; i++) {
            let th = <f64>i / <f64>sg * mathx.TAU;
            let ph = <f64>j / <f64>rg * Math.PI;
            let x = Math.sin(ph) * Math.cos(th);
            let y = Math.cos(ph);
            let z = Math.sin(ph) * Math.sin(th);
            let n = 0.78 + 0.44 * mathx.hash3(x * 3.1 + seed, y * 2.7 - seed, z * 1.9 + seed * 0.37);
            if (j == 0 || j == rg) n = 0.9;
            PX[k] = <f32>(cx + x * rx * n);
            PY[k] = <f32>(cy + y * ry * n);
            PZ[k] = <f32>(cz + z * rz * n);
            k++;
        }
    }
    for (let j = 1; j <= rg; j++) {
        for (let i = 1; i <= sg; i++) {
            let i2 = (i % sg) + 1;
            let a = (j - 1) * sg + i - 1, bb = (j - 1) * sg + i2 - 1, c = j * sg + i2 - 1, d = j * sg + i - 1;
            if (j == 1) {
                flatTri(b, PX[a], PY[a], PZ[a], PX[c], PY[c], PZ[c], PX[d], PY[d], PZ[d]);
            } else if (j == rg) {
                flatTri(b, PX[a], PY[a], PZ[a], PX[bb], PY[bb], PZ[bb], PX[d], PY[d], PZ[d]);
            } else {
                flatTri(b, PX[a], PY[a], PZ[a], PX[bb], PY[bb], PZ[bb], PX[c], PY[c], PZ[c]);
                flatTri(b, PX[a], PY[a], PZ[a], PX[c], PY[c], PZ[c], PX[d], PY[d], PZ[d]);
            }
        }
    }
}

// Flat XZ grid (y = 0) centered on the origin, facing +Y.
export function grid(b: Builder, w: f64, d: f64, nx: i32, nz: i32): void {
    let base = b.vcount;
    for (let j = 0; j <= nz; j++) {
        for (let i = 0; i <= nx; i++) {
            vertex(b, (<f64>i / <f64>nx - 0.5) * w, 0, (<f64>j / <f64>nz - 0.5) * d, 0, 1, 0);
        }
    }
    for (let j = 0; j < nz; j++) {
        for (let i = 0; i < nx; i++) {
            let a = base + j * (nx + 1) + i;
            let c = a + nx + 1;
            tri(b, a, c, a + 1);
            tri(b, a + 1, c, c + 1);
        }
    }
}

// Prism from a closed 2D outline (x, z as Vector x, y; 1-based, slot 0 unused)
// extruded between y0 and y1. topHex / sideHex: NaN = keep the paint.
export function prism(b: Builder, outline0: Array<Vector>, y0: f64, y1: f64, topHex: f64 = NaN, sideHex: f64 = NaN): void {
    let n = outline0.length - 1;
    let area = 0.0;
    for (let i = 1; i <= n; i++) {
        let p = outline0[i];
        let q = outline0[(i % n) + 1];
        area += <f64>p.x * <f64>q.y - <f64>q.x * <f64>p.y;
    }
    let outline = outline0;
    if (area > 0) {
        outline = [Vector.xy(0, 0)];
        for (let i = n; i >= 1; i--) outline.push(outline0[i]);
    }
    if (!isNaN(sideHex)) color(b, sideHex);
    for (let i = 1; i <= n; i++) {
        let p = outline[i];
        let q = outline[(i % n) + 1];
        flatQuad(b, V(p.x, y0, p.y), V(q.x, y0, q.y), V(q.x, y1, q.y), V(p.x, y1, p.y));
    }
    if (!isNaN(topHex)) color(b, topHex);
    let cx = 0.0, cz = 0.0;
    for (let i = 1; i <= n; i++) {
        cx += <f64>outline[i].x;
        cz += <f64>outline[i].y;
    }
    cx /= <f64>n;
    cz /= <f64>n;
    for (let i = 1; i <= n; i++) {
        let p = outline[i];
        let q = outline[(i % n) + 1];
        flatTri(b, cx, y1, cz, p.x, y1, p.y, q.x, y1, q.y);
    }
}

// Ink shells ------------------------------------------------------------------

// Scratch reused by every inkShell call (1-based like the Luau tables).
const S_key = new Map<f64, i32>();
const S_ids: Array<i32> = [0];
const S_px: Array<f64> = [0.0];
const S_py: Array<f64> = [0.0];
const S_pz: Array<f64> = [0.0];
const S_nx: Array<f64> = [0.0];
const S_ny: Array<f64> = [0.0];
const S_nz: Array<f64> = [0.0];
const S_col: Array<u32> = [0];

@inline function weldKey(x: f64, y: f64, z: f64): f64 {
    return (Math.floor(x * 32 + 0.5) * 73856093.0) + (Math.floor(y * 32 + 0.5) * 19349663.0) * 0.5 + Math.floor(z * 32 + 0.5) * 83492791.0 * 0.25;
}

export function inkShell(b: Builder, v0: i32, i0: i32, w: f64 = 1): void {
    let i1 = b.icount;
    if (i1 <= i0) return;
    let dq = b.inkQueue;
    if (dq != null) {
        let j = new InkJob();
        j.v0 = v0;
        j.i0 = i0;
        j.v1 = b.vcount;
        j.i1 = i1;
        j.w = w;
        dq.push(j);
        return;
    }
    let vf = b.vf, vu = b.vu, iu = b.iu;
    let keyToId = S_key;
    let ids = S_ids;
    let px = S_px, py = S_py, pz = S_pz;
    let nx = S_nx, ny = S_ny, nz = S_nz;
    let cols = S_col;
    keyToId.clear();
    let n = 0;
    let nIds = 0;
    for (let k = i0; k < i1; k++) {
        let vi = <i32>iu[k];
        let o = vi * 8;
        let x = <f64>vf[o], y = <f64>vf[o + 1], z = <f64>vf[o + 2];
        let key = weldKey(x, y, z);
        let id = getOr<f64>(keyToId, key, 0);
        if (id == 0 || px[id] != x || py[id] != y || pz[id] != z) {
            if (id != 0) {
                let probe = key + 0.5;
                while (true) {
                    let id2 = getOr<f64>(keyToId, probe, 0);
                    if (id2 == 0) {
                        id = 0;
                        key = probe;
                        break;
                    }
                    if (px[id2] == x && py[id2] == y && pz[id2] == z) {
                        id = id2;
                        break;
                    }
                    probe += 0.5;
                }
            }
            if (id == 0) {
                n += 1;
                id = n;
                keyToId.set(key, id);
                px[id] = x;
                py[id] = y;
                pz[id] = z;
                nx[id] = 0;
                ny[id] = 0;
                nz[id] = 0;
                cols[id] = vu[o + 6];
            }
        }
        nIds += 1;
        ids[nIds] = id;
    }
    let t = 1;
    while (t + 2 <= nIds) {
        let a = ids[t], bb = ids[t + 1], c = ids[t + 2];
        let ux = px[bb] - px[a], uy = py[bb] - py[a], uz = pz[bb] - pz[a];
        let vx = px[c] - px[a], vy = py[c] - py[a], vz = pz[c] - pz[a];
        let fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
        nx[a] += fx;
        ny[a] += fy;
        nz[a] += fz;
        nx[bb] += fx;
        ny[bb] += fy;
        nz[bb] += fz;
        nx[c] += fx;
        ny[c] += fy;
        nz[c] += fz;
        t += 3;
    }
    let v8 = b.v8;
    for (let v = v0; v < b.vcount; v++) v8[v * 32 + 29] = 0;
    let base = b.vcount;
    growV(b, n);
    growI(b, nIds);
    vf = b.vf;
    vu = b.vu;
    iu = b.iu;
    let auxW = pack8(0, w, 0, <f64>SHELL_W / 255);
    let minx = b.minx, miny = b.miny, minz = b.minz, maxx = b.maxx, maxy = b.maxy, maxz = b.maxz;
    for (let id = 1; id <= n; id++) {
        let ax = 0.0, ay = 1.0, az = 0.0;
        let sx = nx[id], sy = ny[id], sz = nz[id];
        let l = Math.sqrt(sx * sx + sy * sy + sz * sz);
        if (l > 1e-12) {
            ax = sx / l;
            ay = sy / l;
            az = sz / l;
        }
        let x = px[id], y = py[id], z = pz[id];
        let o = (base + id - 1) * 8;
        vf[o] = <f32>x;
        vf[o + 1] = <f32>y;
        vf[o + 2] = <f32>z;
        vf[o + 3] = <f32>ax;
        vf[o + 4] = <f32>ay;
        vf[o + 5] = <f32>az;
        vu[o + 6] = cols[id];
        vu[o + 7] = auxW;
        if (x < minx) minx = x;
        if (y < miny) miny = y;
        if (z < minz) minz = z;
        if (x > maxx) maxx = x;
        if (y > maxy) maxy = y;
        if (z > maxz) maxz = z;
    }
    b.minx = minx; b.miny = miny; b.minz = minz; b.maxx = maxx; b.maxy = maxy; b.maxz = maxz;
    b.vcount = base + n;
    let io = b.icount;
    for (let k = 1; k <= nIds; k++) iu[io + k - 1] = <u32>(base + ids[k] - 1);
    b.icount += nIds;
}

// Deferred ink shells (own scratch: an immediate inkShell may run between slices).
const D_key = new Map<f64, i32>();
const D_ids: Array<i32> = [0];
const D_px: Array<f64> = [0.0];
const D_py: Array<f64> = [0.0];
const D_pz: Array<f64> = [0.0];
const D_nx: Array<f64> = [0.0];
const D_ny: Array<f64> = [0.0];
const D_nz: Array<f64> = [0.0];
const D_col: Array<u32> = [0];

export const INK_SLICE: f64 = 256; // items between clock checks

export function inkDefer(b: Builder, on: bool): void {
    if (on) {
        if (b.inkQueue == null) b.inkQueue = [];
    } else {
        b.inkQueue = null;
    }
}

export function inkPending(b: Builder): bool {
    let q = b.inkQueue;
    return q != null && q.length > 0;
}

// Works through the deferred shells until done (true) or past `untilT`
// (clock(); checked every INK_SLICE items).
export function inkStep(b: Builder, untilT: f64): bool {
    let q = b.inkQueue;
    if (q == null) return true;
    let left = INK_SLICE;
    let px = D_px, py = D_py, pz = D_pz;
    let nx = D_nx, ny = D_ny, nz = D_nz;
    let ids = D_ids, cols = D_col, keyToId = D_key;
    while (q.length > 0) {
        let j = q[0];
        if (j.phase == 0) {
            keyToId.clear();
            j.n = 0;
            j.nIds = 0;
            j.k = j.i0;
            j.phase = 1;
        }
        if (j.phase == 1) {
            let vf = b.vf, vu = b.vu, iu = b.iu;
            let n = j.n, nIds = j.nIds;
            let k = j.k;
            while (k < j.i1) {
                let vi = <i32>iu[k];
                let o = vi * 8;
                let x = <f64>vf[o], y = <f64>vf[o + 1], z = <f64>vf[o + 2];
                let key = weldKey(x, y, z);
                let id = getOr<f64>(keyToId, key, 0);
                if (id == 0 || px[id] != x || py[id] != y || pz[id] != z) {
                    if (id != 0) {
                        let probe = key + 0.5;
                        while (true) {
                            let id2 = getOr<f64>(keyToId, probe, 0);
                            if (id2 == 0) {
                                id = 0;
                                key = probe;
                                break;
                            }
                            if (px[id2] == x && py[id2] == y && pz[id2] == z) {
                                id = id2;
                                break;
                            }
                            probe += 0.5;
                        }
                    }
                    if (id == 0) {
                        n += 1;
                        id = n;
                        keyToId.set(key, id);
                        px[id] = x;
                        py[id] = y;
                        pz[id] = z;
                        nx[id] = 0;
                        ny[id] = 0;
                        nz[id] = 0;
                        cols[id] = vu[o + 6];
                    }
                }
                nIds += 1;
                ids[nIds] = id;
                k += 1;
                left -= 1;
                if (left <= 0) {
                    if (clock() >= untilT) {
                        j.n = n;
                        j.nIds = nIds;
                        j.k = k;
                        return false;
                    }
                    left = INK_SLICE;
                }
            }
            j.n = n;
            j.nIds = nIds;
            j.k = 1;
            j.phase = 2;
        }
        if (j.phase == 2) {
            let t = j.k;
            let nIds = j.nIds;
            while (t + 2 <= nIds) {
                let a = ids[t], bb = ids[t + 1], c = ids[t + 2];
                let ux = px[bb] - px[a], uy = py[bb] - py[a], uz = pz[bb] - pz[a];
                let vx = px[c] - px[a], vy = py[c] - py[a], vz = pz[c] - pz[a];
                let fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
                nx[a] += fx;
                ny[a] += fy;
                nz[a] += fz;
                nx[bb] += fx;
                ny[bb] += fy;
                nz[bb] += fz;
                nx[c] += fx;
                ny[c] += fy;
                nz[c] += fz;
                t += 3;
                left -= 3;
                if (left <= 0) {
                    if (clock() >= untilT) {
                        j.k = t;
                        return false;
                    }
                    left = INK_SLICE;
                }
            }
            j.k = j.v0;
            j.phase = 3;
        }
        if (j.phase == 3) {
            let v8 = b.v8;
            let v = j.k;
            while (v < j.v1) {
                v8[v * 32 + 29] = 0;
                v += 1;
                left -= 0.25;
                if (left <= 0) {
                    if (clock() >= untilT) {
                        j.k = v;
                        return false;
                    }
                    left = INK_SLICE;
                }
            }
            j.phase = 4;
        }
        if (j.phase == 4) {
            // make room at the call's position: what came after moves up
            let n = j.n, nIds = j.nIds;
            let v1 = j.v1, i1 = j.i1;
            let tailV = b.vcount - v1, tailI = b.icount - i1;
            growV(b, n);
            growI(b, nIds);
            if (tailV > 0) b.v8.copyWithin((v1 + n) * 32, v1 * 32, (v1 + tailV) * 32);
            if (tailI > 0) {
                let iu = b.iu;
                iu.copyWithin(i1 + nIds, i1, i1 + tailI);
                for (let k = i1 + nIds; k <= i1 + nIds + tailI - 1; k++) {
                    let vi = iu[k];
                    if (<i32>vi >= v1) iu[k] = vi + <u32>n;
                }
            }
            b.vcount += n;
            b.icount += nIds;
            for (let qi = 1; qi < q.length; qi++) {
                let r = q[qi];
                if (r.v0 >= v1) r.v0 += n;
                if (r.v1 >= v1) r.v1 += n;
                if (r.i0 >= i1) r.i0 += nIds;
                if (r.i1 >= i1) r.i1 += nIds;
            }
            left -= <f64>(tailV + tailI) * 0.1;
            j.base = v1;
            j.k = 1;
            j.phase = 5;
        }
        if (j.phase == 5) {
            let vf = b.vf, vu = b.vu;
            let auxW = pack8(0, j.w, 0, <f64>SHELL_W / 255);
            let base = j.base, n = j.n;
            let minx = b.minx, miny = b.miny, minz = b.minz, maxx = b.maxx, maxy = b.maxy, maxz = b.maxz;
            let id = j.k;
            while (id <= n) {
                let ax = 0.0, ay = 1.0, az = 0.0;
                let sx = nx[id], sy = ny[id], sz = nz[id];
                let l = Math.sqrt(sx * sx + sy * sy + sz * sz);
                if (l > 1e-12) {
                    ax = sx / l;
                    ay = sy / l;
                    az = sz / l;
                }
                let x = px[id], y = py[id], z = pz[id];
                let o = (base + id - 1) * 8;
                vf[o] = <f32>x;
                vf[o + 1] = <f32>y;
                vf[o + 2] = <f32>z;
                vf[o + 3] = <f32>ax;
                vf[o + 4] = <f32>ay;
                vf[o + 5] = <f32>az;
                vu[o + 6] = cols[id];
                vu[o + 7] = auxW;
                if (x < minx) minx = x;
                if (y < miny) miny = y;
                if (z < minz) minz = z;
                if (x > maxx) maxx = x;
                if (y > maxy) maxy = y;
                if (z > maxz) maxz = z;
                id += 1;
                left -= 1;
                if (left <= 0) {
                    if (clock() >= untilT) {
                        b.minx = minx; b.miny = miny; b.minz = minz; b.maxx = maxx; b.maxy = maxy; b.maxz = maxz;
                        j.k = id;
                        return false;
                    }
                    left = INK_SLICE;
                }
            }
            b.minx = minx; b.miny = miny; b.minz = minz; b.maxx = maxx; b.maxy = maxy; b.maxz = maxz;
            j.k = 1;
            j.phase = 6;
        }
        if (j.phase == 6) {
            let iu = b.iu;
            let io = j.i1;
            let base = j.base;
            let k = j.k;
            while (k <= j.nIds) {
                iu[io + k - 1] = <u32>(base + ids[k] - 1);
                k += 1;
                left -= 0.25;
                if (left <= 0) {
                    if (clock() >= untilT) {
                        j.k = k;
                        return false;
                    }
                    left = INK_SLICE;
                }
            }
            q.shift();
        }
    }
    return true;
}

// Empties a builder for reuse (keeps its buffers and capacity).
export function reset(b: Builder): void {
    b.vcount = 0;
    b.icount = 0;
    b.col = pack8(1, 1, 1, 1);
    b.aux = pack8(0, 1, 0, 0);
    b.stack.length = 0;
    b.xf = null;
    b.minx = HUGE; b.miny = HUGE; b.minz = HUGE;
    b.maxx = -HUGE; b.maxy = -HUGE; b.maxz = -HUGE;
}

// Smooth-shaded quad strip helpers -------------------------------------------

export function vertexC(b: Builder, px: f64, py: f64, pz: f64, nx: f64, ny: f64, nz: f64, col: u32, auxv: u32): i32 {
    let sc = b.col, sa = b.aux;
    b.col = col;
    b.aux = auxv;
    let i = vertex(b, px, py, pz, nx, ny, nz);
    b.col = sc;
    b.aux = sa;
    return i;
}

// Flat triangle whose winding is fixed so its normal points along (hx, hy, hz).
export function flatTriFacing(b: Builder, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, cx: f64, cy: f64, cz: f64, hx: f64, hy: f64, hz: f64): void {
    let ux = bx - ax, uy = by - ay, uz = bz - az;
    let vx = cx - ax, vy = cy - ay, vz = cz - az;
    let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    if (nx * hx + ny * hy + nz * hz >= 0) {
        flatTri(b, ax, ay, az, bx, by, bz, cx, cy, cz);
    } else {
        flatTri(b, ax, ay, az, cx, cy, cz, bx, by, bz);
    }
}

export function setPaint(b: Builder, col: u32, auxv: u32): void {
    b.col = col;
    b.aux = auxv;
}

// Quad with one shared normal (Newell) oriented along the hint (hx, hy, hz).
export function quadFlat(
    b: Builder,
    ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64,
    dx: f64, dy: f64, dz: f64,
    hx: f64, hy: f64, hz: f64
): void {
    let nx = (ay - by) * (az + bz) + (by - cy) * (bz + cz) + (cy - dy) * (cz + dz) + (dy - ay) * (dz + az);
    let ny = (az - bz) * (ax + bx) + (bz - cz) * (bx + cx) + (cz - dz) * (cx + dx) + (dz - az) * (dx + ax);
    let nz = (ax - bx) * (ay + by) + (bx - cx) * (by + cy) + (cx - dx) * (cy + dy) + (dx - ax) * (dy + ay);
    let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-12) return;
    nx = nx / l;
    ny = ny / l;
    nz = nz / l;
    let flip = nx * hx + ny * hy + nz * hz < 0;
    if (flip) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
    }
    let i0 = vertex(b, ax, ay, az, nx, ny, nz);
    let i1 = vertex(b, bx, by, bz, nx, ny, nz);
    let i2 = vertex(b, cx, cy, cz, nx, ny, nz);
    let i3 = vertex(b, dx, dy, dz, nx, ny, nz);
    if (flip) {
        tri(b, i0, i2, i1);
        tri(b, i0, i3, i2);
    } else {
        tri(b, i0, i1, i2);
        tri(b, i0, i2, i3);
    }
}

// Broken foam lace on the water (y 0.07) around a closed ring of waterline
// points (xs, zs: 1-based) about (cx, cz). gaps / tuck: NaN = default.
class Lace {
    xs: Array<f64> = [0.0];
    zs: Array<f64> = [0.0];
    ox: Array<f64> = [0.0];
    oz: Array<f64> = [0.0];
    cum: Array<f64> = [0.0];
    n: i32 = 0;
    total: f64 = 0;
    hint: i32 = 1;
    x: f64 = 0;
    z: f64 = 0;
    ux: f64 = 0;
    uz: f64 = 0;

    // point and outward direction at arc length d (wraps)
    at(d: f64): void {
        let cum = this.cum, n = this.n;
        d = mod(d, this.total);
        if (cum[this.hint] > d) this.hint = 1;
        while (this.hint < n && cum[this.hint + 1] <= d) this.hint += 1;
        let i = this.hint;
        let j = (i % n) + 1;
        let seg = (j == 1 ? this.total : cum[j]) - cum[i];
        let t = seg > 1e-6 ? (d - cum[i]) / seg : 0.0;
        let ox = this.ox, oz = this.oz, xs = this.xs, zs = this.zs;
        let ux = ox[i] + (ox[j] - ox[i]) * t, uz = oz[i] + (oz[j] - oz[i]) * t;
        let ul = Math.sqrt(ux * ux + uz * uz);
        if (ul > 1e-6) {
            ux = ux / ul;
            uz = uz / ul;
        }
        this.x = xs[i] + (xs[j] - xs[i]) * t;
        this.z = zs[i] + (zs[j] - zs[i]) * t;
        this.ux = ux;
        this.uz = uz;
    }
}

export function laceRing(b: Builder, r: Rng, xs: Array<f64>, zs: Array<f64>, cx: f64, cz: f64, width: f64, gaps: f64 = NaN, tuck: f64 = NaN): void {
    let n = xs.length - 1;
    if (n < 3) return;
    let L = new Lace();
    L.xs = xs;
    L.zs = zs;
    L.n = n;
    let ox = L.ox, oz = L.oz, cum = L.cum;
    let total = 0.0;
    for (let i = 1; i <= n; i++) {
        let dx = xs[i] - cx, dz = zs[i] - cz;
        let l = Math.sqrt(dx * dx + dz * dz);
        if (l < 1e-6) {
            ox[i] = 1;
            oz[i] = 0;
        } else {
            ox[i] = dx / l;
            oz[i] = dz / l;
        }
        cum[i] = total;
        let j = (i % n) + 1;
        total += Math.sqrt(Math.pow(xs[j] - xs[i], 2) + Math.pow(zs[j] - zs[i], 2));
    }
    if (total < 1e-3) return;
    L.total = total;
    let y = 0.07;
    let gp = isNaN(gaps) ? 0.12 : gaps;
    let tk = isNaN(tuck) ? lmin(0.8, width * 0.5) : tuck;
    let d = mathx.rand(r) * total;
    let dEnd = d + total - width * 0.3;
    let guard = 0;
    while (d < dEnd && guard < 200) {
        guard += 1;
        let e = lmin(d + lmin(width * mathx.randRange(r, 2.5, 6.5), total * 0.4), dEnd);
        if (mathx.rand(r) >= gp && e - d > width * 0.8) {
            let wmax = width * mathx.randRange(r, 0.55, 1.2);
            let outer = mathx.rand(r) < 0.35;
            let o2 = wmax * 0.75 + width * mathx.randRange(r, 0.35, 0.8);
            let th2 = width * mathx.randRange(r, 0.14, 0.28);
            let ta = mathx.randRange(r, 0.08, 0.3);
            let tb = mathx.randRange(r, 0.7, 0.92);
            let steps = <i32>lclamp(Math.ceil((e - d) / Math.max(width * 1.1, 1.2)), 3, 6);
            let px = 0.0, pz = 0.0, pox = 0.0, poz = 0.0, pw = 0.0, pw2 = 0.0, pt = 0.0;
            for (let i = 0; i <= steps; i++) {
                let t = <f64>i / <f64>steps;
                L.at(d + (e - d) * t);
                let x = L.x, z = L.z, ux = L.ux, uz = L.uz;
                let env = Math.pow(mathx.smoothstep(0, 0.3, t) * mathx.smoothstep(1, 0.7, t), 0.6);
                let rag = mathx.randRange(r, 0.75, 1.25);
                let w = wmax * env * rag + 0.1;
                let t2 = mathx.saturate((t - ta) / Math.max(tb - ta, 0.05));
                let w2 = th2 * Math.pow(Math.sin(Math.PI * t2), 0.7) * rag;
                if (i > 0) {
                    quadFlat(b, px - pox * tk, y, pz - poz * tk, x - ux * tk, y, z - uz * tk, x + ux * w, y, z + uz * w, px + pox * pw, y, pz + poz * pw, 0, 1, 0);
                    if (outer && t > ta && pt < tb && (w2 > 0.01 || pw2 > 0.01)) {
                        quadFlat(b, px + pox * o2, y, pz + poz * o2, x + ux * o2, y, z + uz * o2, x + ux * (o2 + w2), y, z + uz * (o2 + w2), px + pox * (o2 + pw2), y, pz + poz * (o2 + pw2), 0, 1, 0);
                    }
                }
                px = x; pz = z; pox = ux; poz = uz; pw = w; pw2 = w2; pt = t;
            }
        }
        d = e + width * mathx.randRange(r, 0.25, 1.4);
    }
}
