// Port of src/game/models.luau: procedural toon models for enemies, bosses and
// debris. Every model type is one mesh drawn through one instanced gpu.Batch;
// animated parts (propellers, turret heads, boss pods, eyelids) are their own
// batches so a single enemy is a handful of instances. Meshes are authored
// nose toward -Z, +Y up.
//
// Multi-returns: point -> POINT_X / Y / Z, dir -> DIR_X / Y / Z,
// splashBatches -> SPLASH_CROWN / SPLASH_JET / SPLASH_RING. Luau sequences
// stay 1-based (slot 0 a dummy). Vector component math is done in f64 (as
// Luau reads them), Vector ops stay f32 (as Luau's).
import { Vector } from "rive/vector";
import { Mat4 } from "rive/mat4";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as gpu from "../lib/gpu";
import { Batch, Mesh } from "../lib/gpu";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import { mod } from "../lib/compat";

const TAU: f64 = mathx.TAU;
const RPD: f64 = Math.PI / 180.0; // Luau RADIANS_PER_DEGREE (math.rad / math.deg)

// Palette ------------------------------------------------------------------

const RED: f64 = 0xC8322C;
const RED_DK: f64 = 0x8E1F22;
const CREAM: f64 = 0xF0E4C6;
const BLUE: f64 = 0x3F78C0;
const WOOD: f64 = 0x6B4526;
const LEATHER: f64 = 0x6B4428;
const DARK: f64 = 0x2A2E3A;
const INK: f64 = 0x1A1D29;
const STEEL: f64 = 0x9AA3B5;
const IRON: f64 = 0x434A5C;
const BRASS: f64 = 0xC99A45;
const GOLD: f64 = 0xE2B84E;
const GREY: f64 = 0x6B7080;
const PINK: f64 = 0xE0579E;
const MAGENTA: f64 = 0xB02E74;
const SLATE: f64 = 0x4B5268;
// Stormcrow gasbag doped canvas: slate cobalt, alternate gores a shade down,
// raised rib tapes a shade up (the old near-black slate went black in its
// shade band and read as a plain hull in the kill cam)
const BAG: f64 = 0x5A6893;
const BAG2: f64 = 0x4F5C86;
const BAG_RIB: f64 = 0x8A97BD;

// Geometry helpers ---------------------------------------------------------

@inline function V(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

@inline function X(x: f64, y: f64): Vector {
    return Vector.xy(<f32>x, <f32>y);
}

// Luau vector * number (the number rounds to f32 first)
@inline function sc(v: Vector, s: f64): Vector {
    return v * <f32>s;
}

const V0: Vector = Vector.xyz(0, 0, 0); // slot 0 of point lists

// Convex polygon, wound to face away from (cx, cy, cz).
function poly(b: Builder, pts: Array<Vector>, cx: f64, cy: f64, cz: f64): void {
    let n = pts.length - 1;
    let nx = 0.0, ny = 0.0, nz = 0.0, mx = 0.0, my = 0.0, mz = 0.0;
    for (let i = 1; i <= n; i++) {
        let p = pts[i], q = pts[(i % n) + 1];
        let px = <f64>p.x, py = <f64>p.y, pz = <f64>p.z;
        let qx = <f64>q.x, qy = <f64>q.y, qz = <f64>q.z;
        nx += (py - qy) * (pz + qz);
        ny += (pz - qz) * (px + qx);
        nz += (px - qx) * (py + qy);
        mx += px;
        my += py;
        mz += pz;
    }
    mx /= <f64>n;
    my /= <f64>n;
    mz /= <f64>n;
    let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-10) return;
    nx = nx / l;
    ny = ny / l;
    nz = nz / l;
    let flip = (mx - cx) * nx + (my - cy) * ny + (mz - cz) * nz < 0;
    if (flip) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
    }
    let idx: Array<i32> = [0];
    for (let i = 1; i <= n; i++) {
        let p = pts[i];
        idx.push(meshgen.vertex(b, <f64>p.x, <f64>p.y, <f64>p.z, nx, ny, nz));
    }
    for (let i = 2; i <= n - 1; i++) {
        if (flip) {
            meshgen.tri(b, idx[1], idx[i + 1], idx[i]);
        } else {
            meshgen.tri(b, idx[1], idx[i], idx[i + 1]);
        }
    }
}

// Polygon facing an explicit normal (for decals / double sided cards).
function polyN(b: Builder, pts: Array<Vector>, nx: f64, ny: f64, nz: f64): void {
    let p1 = pts[1];
    poly(b, pts, <f64>p1.x - nx * 10, <f64>p1.y - ny * 10, <f64>p1.z - nz * 10);
}

// Convex hexahedron from 8 corners: [1..4] one ring, [5..8] the opposite ring (same order).
function hexa(b: Builder, c: Array<Vector>): void {
    let cx = 0.0, cy = 0.0, cz = 0.0;
    for (let i = 1; i < c.length; i++) {
        let p = c[i];
        cx += <f64>p.x;
        cy += <f64>p.y;
        cz += <f64>p.z;
    }
    cx /= 8;
    cy /= 8;
    cz /= 8;
    poly(b, [V0, c[1], c[2], c[3], c[4]], cx, cy, cz);
    poly(b, [V0, c[5], c[6], c[7], c[8]], cx, cy, cz);
    for (let i = 1; i <= 4; i++) {
        let j = (i % 4) + 1;
        poly(b, [V0, c[i], c[j], c[j + 4], c[i + 4]], cx, cy, cz);
    }
}

// Wing panel: root at x0 (leading z zl0, trailing zt0, height y0, thickness t0), tip likewise.
function wing(b: Builder, x0: f64, y0: f64, zl0: f64, zt0: f64, t0: f64, x1: f64, y1: f64, zl1: f64, zt1: f64, t1: f64): void {
    hexa(b, [V0,
        V(x0, y0 - t0 / 2, zl0), V(x1, y1 - t1 / 2, zl1), V(x1, y1 - t1 / 2, zt1), V(x0, y0 - t0 / 2, zt0),
        V(x0, y0 + t0 / 2, zl0), V(x1, y1 + t1 / 2, zl1), V(x1, y1 + t1 / 2, zt1), V(x0, y0 + t0 / 2, zt0),
    ]);
}

// Vertical fin: bottom edge at y0 from za0..zb0, top edge at y1 from za1..zb1, thickness t, at x.
function fin(b: Builder, x: f64, y0: f64, za0: f64, zb0: f64, y1: f64, za1: f64, zb1: f64, t: f64): void {
    hexa(b, [V0,
        V(x - t / 2, y0, za0), V(x - t / 2, y0, zb0), V(x - t / 2, y1, zb1), V(x - t / 2, y1, za1),
        V(x + t / 2, y0, za0), V(x + t / 2, y0, zb0), V(x + t / 2, y1, zb1), V(x + t / 2, y1, za1),
    ]);
}

// Square beam between two points.
function beam(b: Builder, p0: Vector, p1: Vector, w: f64): void {
    let d = mathx.norm(p1 - p0);
    let hint = Math.abs(<f64>d.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0);
    let u = sc(mathx.norm(mathx.cross(d, hint)), w);
    let v = sc(mathx.norm(mathx.cross(d, u)), w);
    hexa(b, [V0,
        p0 + u + v, p0 - u + v, p0 - u - v, p0 + u - v,
        p1 + u + v, p1 - u + v, p1 - u - v, p1 + u - v,
    ]);
}

// Emits one triangle, flipping its winding to agree with the reference normal.
function triAuto(b: Builder, a: Vector, c: Vector, d: Vector, na: Vector, nc: Vector, nd: Vector): void {
    let g = mathx.cross(c - a, d - a);
    if (mathx.dot(g, g) < 1e-14) return;
    let nref = na + nc + nd;
    let ia = meshgen.vertex(b, <f64>a.x, <f64>a.y, <f64>a.z, <f64>na.x, <f64>na.y, <f64>na.z);
    let ic = meshgen.vertex(b, <f64>c.x, <f64>c.y, <f64>c.z, <f64>nc.x, <f64>nc.y, <f64>nc.z);
    let id = meshgen.vertex(b, <f64>d.x, <f64>d.y, <f64>d.z, <f64>nd.x, <f64>nd.y, <f64>nd.z);
    if (mathx.dot(g, nref) >= 0) {
        meshgen.tri(b, ia, ic, id);
    } else {
        meshgen.tri(b, ia, id, ic);
    }
}

// { z, r, colorHex, emissive? }
export class Ring {
    z: f64;
    r: f64;
    hex: f64;
    em: f64;
    constructor(z: f64, r: f64, hex: f64, em: f64) {
        this.z = z;
        this.r = r;
        this.hex = hex;
        this.em = em;
    }
}

@inline function rg(z: f64, r: f64, hex: f64, em: f64 = 0): Ring {
    return new Ring(z, r, hex, em);
}

const RG0: Ring = rg(0, 0, 0); // slot 0 of profiles

// pt / at / P outputs (Luau multi-returns)
let PT_P: Vector = V0;
let PT_N: Vector = V0;

// Surface of revolution around the Z axis. Each profile entry is {z, r, hex, emissive};
// the band between entry i and i+1 takes entry i's color. Elliptic section sx/sy,
// centered at (cx, cy). Smooth normals; ends capped when radius > 0.
// outline / gores: NaN = nil.
function lathe(b: Builder, prof: Array<Ring>, seg: i32, cx: f64, cy: f64, sx: f64, sy: f64, outline: f64 = NaN, gores: f64 = NaN): void {
    let n = prof.length - 1;
    let nr: Array<f64> = [0.0], na: Array<f64> = [0.0];
    for (let i = 1; i <= n; i++) {
        let a = prof[max(i - 1, 1)];
        let c = prof[min(i + 1, n)];
        let dz = c.z - a.z, dr = c.r - a.r;
        let l = Math.sqrt(dz * dz + dr * dr);
        if (l < 1e-9) {
            nr.push(1);
            na.push(0);
        } else {
            nr.push(dz / l);
            na.push(-dr / l);
        }
    }
    let ol = isNaN(outline) ? 1.0 : outline;
    let pt = (i: i32, ang: f64): void => {
        let e = prof[i];
        let c = Math.cos(ang), s = Math.sin(ang);
        PT_P = V(cx + sx * e.r * c, cy + sy * e.r * s, e.z);
        PT_N = mathx.norm(V(nr[i] * c / sx, nr[i] * s / sy, na[i]));
    };
    let fseg = <f64>seg;
    for (let i = 1; i <= n - 1; i++) {
        let e = prof[i];
        let em = e.em;
        for (let j = 0; j < seg; j++) {
            let hex = e.hex;
            if (!isNaN(gores) && gores != 0 && j % 2 == 1 && em == 0 && hex == BAG) hex = gores;
            meshgen.color(b, hex);
            meshgen.aux(b, em, ol, 0, 0.3);
            let a0 = <f64>j / fseg * TAU, a1 = <f64>(j + 1) / fseg * TAU;
            pt(i, a0);
            let p00 = PT_P, n00 = PT_N;
            pt(i, a1);
            let p01 = PT_P, n01 = PT_N;
            pt(i + 1, a0);
            let p10 = PT_P, n10 = PT_N;
            pt(i + 1, a1);
            let p11 = PT_P, n11 = PT_N;
            triAuto(b, p00, p01, p11, n00, n01, n11);
            triAuto(b, p00, p11, p10, n00, n11, n10);
        }
    }
    // caps
    let first = prof[1], last = prof[n];
    if (first.r > 0.001) {
        meshgen.color(b, first.hex);
        let pts: Array<Vector> = [V0];
        for (let j = 0; j < seg; j++) {
            pt(1, <f64>j / fseg * TAU);
            pts.push(PT_P);
        }
        poly(b, pts, cx, cy, first.z + 1);
    }
    if (last.r > 0.001) {
        meshgen.color(b, prof[n - 1].hex);
        let pts: Array<Vector> = [V0];
        for (let j = 0; j < seg; j++) {
            pt(n, <f64>j / fseg * TAU);
            pts.push(PT_P);
        }
        poly(b, pts, cx, cy, last.z - 1);
    }
}

// Lathe along an arbitrary segment p0 -> p1 (profile z runs 0..1 along it, r absolute).
function tube(b: Builder, p0: Vector, p1: Vector, prof: Array<Ring>, seg: i32, outline: f64 = NaN): void {
    let d = p1 - p0;
    let len = mathx.len(d);
    let f = mathx.norm(d);
    let hint = Math.abs(<f64>f.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0);
    let rt = mathx.norm(mathx.cross(hint, f));
    let up = mathx.cross(f, rt);
    // map local x->rt, y->up, z->f (scaled to len), then translate
    let m = Mat4.values(
        rt.x, rt.y, rt.z, 0,
        up.x, up.y, up.z, 0,
        <f32>(<f64>f.x * len), <f32>(<f64>f.y * len), <f32>(<f64>f.z * len), 0,
        p0.x, p0.y, p0.z, 1
    );
    meshgen.push(b, m);
    // lathe with z in 0..1; radius must not be scaled by len: pre-divide not needed since
    // only the z axis is scaled.
    lathe(b, prof, seg, 0, 0, 1, 1, outline);
    meshgen.pop(b);
}

// Cone spike from base center along unit dir.
function cone(b: Builder, base: Vector, dir: Vector, r: f64, len: f64, seg: i32): void {
    let hint = Math.abs(<f64>dir.y) < 0.9 ? V(0, 1, 0) : V(1, 0, 0);
    let u = mathx.norm(mathx.cross(dir, hint));
    let v = mathx.cross(dir, u);
    let tip = base + sc(dir, len);
    let c = base + sc(dir, len * 0.25);
    let ring: Array<Vector> = [V0];
    for (let i = 0; i < seg; i++) {
        let a = <f64>i / <f64>seg * TAU;
        ring.push(base + sc(u, Math.cos(a) * r) + sc(v, Math.sin(a) * r));
    }
    let cx = <f64>c.x, cy = <f64>c.y, cz = <f64>c.z;
    for (let i = 1; i <= seg; i++) {
        let p = ring[i], q = ring[(i % seg) + 1];
        poly(b, [V0, p, q, tip], cx, cy, cz);
    }
    poly(b, ring, cx, cy, cz);
}

// Ball with per-quad paint callback (direction of the quad center, unit).
function ball(b: Builder, cx: f64, cy: f64, cz: f64, r: f64, seg: i32, rings: i32, paint: (x: f64, y: f64, z: f64) => void): void {
    let fseg = <f64>seg, frings = <f64>rings;
    let dirAt = (i: i32, j: i32): Vector => {
        let th = <f64>i / fseg * TAU;
        let ph = <f64>j / frings * Math.PI;
        return V(Math.sin(ph) * Math.cos(th), Math.cos(ph), Math.sin(ph) * Math.sin(th));
    };
    let C = V(cx, cy, cz);
    for (let j = 0; j < rings; j++) {
        for (let i = 0; i < seg; i++) {
            let a = dirAt(i, j), bb = dirAt(i + 1, j), c = dirAt(i + 1, j + 1), d = dirAt(i, j + 1);
            let m = mathx.norm(a + bb + c + d);
            paint(<f64>m.x, <f64>m.y, <f64>m.z);
            triAuto(b, C + sc(a, r), C + sc(bb, r), C + sc(c, r), a, bb, c);
            triAuto(b, C + sc(a, r), C + sc(c, r), C + sc(d, r), a, c, d);
        }
    }
}

// Ball whose "front" is -Z: re-maps the paint direction so the pole faces forward.
function frontBall(b: Builder, cx: f64, cy: f64, cz: f64, r: f64, seg: i32, rings: i32, paint: (fz: f64, x: f64, y: f64) => void): void {
    meshgen.push(b, Mat4.fromTranslation(<f32>cx, <f32>cy, <f32>cz) * Mat4.fromRotationX(<f32>(-Math.PI / 2)));
    ball(b, 0, 0, 0, r, seg, rings, (x: f64, y: f64, z: f64): void => {
        // after the push, local +Y maps to -Z (front)
        paint(y, x, -z);
    });
    meshgen.pop(b);
}

// Torus around the Z axis at offset z, with an optional tooth count (gear).
function gearRing(b: Builder, R0: f64, r0: f64, z: f64, segU: i32, segV: i32, teeth: i32, toothH: f64, hex: f64, toothHex: f64): void {
    meshgen.color(b, hex);
    meshgen.push(b, Mat4.fromTranslation(0, 0, <f32>z));
    meshgen.torus(b, R0, r0, segU, segV);
    meshgen.pop(b);
    meshgen.color(b, toothHex);
    for (let i = 0; i < teeth; i++) {
        let a = <f64>i / <f64>teeth * TAU;
        let c = Math.cos(a), s = Math.sin(a);
        let tw = 0.35 * r0 * 3;
        let rr0 = R0 + r0 * 0.6, rr1 = R0 + r0 + toothH;
        let tx = -s * tw, ty = c * tw;
        let zz = r0 * 0.7;
        hexa(b, [V0,
            V(c * rr0 - tx, s * rr0 - ty, z - zz), V(c * rr0 + tx, s * rr0 + ty, z - zz), V(c * rr1 + tx * 0.7, s * rr1 + ty * 0.7, z - zz), V(c * rr1 - tx * 0.7, s * rr1 - ty * 0.7, z - zz),
            V(c * rr0 - tx, s * rr0 - ty, z + zz), V(c * rr0 + tx, s * rr0 + ty, z + zz), V(c * rr1 + tx * 0.7, s * rr1 + ty * 0.7, z + zz), V(c * rr1 - tx * 0.7, s * rr1 - ty * 0.7, z + zz),
        ]);
    }
}

// (Luau optional args: emissive 0, outline 1, shiny 0, unlit 0)
function col(b: Builder, hex: f64, emissive: f64 = 0, outline: f64 = 1, shiny: f64 = 0, unlit: f64 = 0): void {
    meshgen.color(b, hex);
    meshgen.aux(b, emissive, outline, unlit, shiny);
}

// Model builders -------------------------------------------------------------

// roundels (cobalt / cream / crimson): disc in the plane facing (nx, ny, nz)
function roundel(b: Builder, cx: f64, cy: f64, cz: f64, nx: f64, ny: f64, nz: f64, r: f64): void {
    let ax = 0.0, ay = 0.0, az = 1.0;
    if (Math.abs(nz) > 0.9) {
        ax = 1;
        ay = 0;
        az = 0;
    }
    let ux = ay * nz - az * ny, uy = az * nx - ax * nz, uz = ax * ny - ay * nx;
    let ul = Math.sqrt(ux * ux + uy * uy + uz * uz);
    ux = ux / ul;
    uy = uy / ul;
    uz = uz / ul;
    let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux;
    let rings: Array<Array<f64>> = [[0.0], [0.0, 1, BLUE], [0.0, 0.62, CREAM], [0.0, 0.3, RED]];
    for (let k = 1; k <= 3; k++) {
        let ring = rings[k];
        col(b, ring[2], 0, 0);
        let rr = r * ring[1];
        let lift = 0.004 * <f64>k;
        let pts: Array<Vector> = [V0];
        for (let i = 0; i <= 13; i++) {
            let a = <f64>i / 14 * TAU;
            let c = Math.cos(a) * rr, sn = Math.sin(a) * rr;
            pts.push(V(cx + ux * c + vx * sn + nx * lift, cy + uy * c + vy * sn + ny * lift, cz + uz * c + vz * sn + nz * lift));
        }
        polyN(b, pts, nx, ny, nz);
    }
}

function buildBiplane(): Mesh {
    let b = meshgen.create(9000);
    // fuselage
    lathe(b, [RG0,
        rg(-3.32, 0.0, CREAM),
        rg(-3.14, 0.22, CREAM),
        rg(-3.04, 0.27, BLUE),
        rg(-2.98, 0.64, BLUE),
        rg(-2.40, 0.70, RED),
        rg(-1.20, 0.68, RED),
        rg(0.30, 0.56, RED),
        rg(1.70, 0.36, RED),
        rg(2.90, 0.16, RED),
        rg(3.35, 0.0, RED),
    ], 14, 0, 0, 1, 1.1);
    // cockpit rim and pilot
    col(b, INK, 0, 0.6);
    meshgen.push(b, Mat4.fromTranslation(0, 0.72, 0.35) * Mat4.fromRotationX(<f32>(Math.PI / 2)));
    meshgen.torus(b, 0.42, 0.07, 14, 5);
    meshgen.pop(b);
    col(b, 0x4A3A30, 0, 1);
    meshgen.sphere(b, 0, 0.7, 0.45, 0.4, 0.18, 0.26, 10, 5); // shoulders
    col(b, LEATHER, 0, 1);
    meshgen.sphere(b, 0, 0.9, 0.38, 0.27, 0.29, 0.3, 10, 7);
    col(b, 0x9BD7F0, 0.25, 0.5, 0.8);
    meshgen.box(b, 0, 0.94, 0.12, 0.34, 0.1, 0.08); // goggles
    col(b, 0xF4EEDD, 0, 0.8);
    wing(b, -0.05, 0.78, 0.55, 0.75, 0.05, 0.18, 0.86, 1.1, 1.55, 0.03); // scarf tail
    col(b, 0xBFE6F5, 0.1, 0.6, 1);
    hexa(b, [V0, V(-0.3, 0.72, -0.35), V(0.3, 0.72, -0.35), V(0.3, 0.72, -0.25), V(-0.3, 0.72, -0.25), V(-0.26, 1.0, -0.2), V(0.26, 1.0, -0.2), V(0.26, 1.0, -0.12), V(-0.26, 1.0, -0.12)]);
    // upper wing (cream, red tips)
    col(b, CREAM);
    wing(b, -3.6, 1.34, -2.05, -0.8, 0.16, 3.6, 1.34, -2.05, -0.8, 0.16);
    col(b, RED);
    wing(b, 3.6, 1.34, -2.05, -0.8, 0.16, 4.35, 1.38, -1.92, -0.9, 0.13);
    wing(b, -3.6, 1.34, -2.05, -0.8, 0.16, -4.35, 1.38, -1.92, -0.9, 0.13);
    // lower wing
    col(b, CREAM);
    wing(b, -3.3, -0.46, -1.75, -0.6, 0.14, 3.3, -0.46, -1.75, -0.6, 0.14);
    col(b, RED);
    wing(b, 3.3, -0.46, -1.75, -0.6, 0.14, 3.95, -0.42, -1.65, -0.7, 0.12);
    wing(b, -3.3, -0.46, -1.75, -0.6, 0.14, -3.95, -0.42, -1.65, -0.7, 0.12);
    // roundels on top of the upper wing, under the lower wing and on the
    // fuselage flanks, so a close pass reads from any side
    for (let side = -1.0; side <= 1; side += 2) {
        roundel(b, side * 2.6, 1.422, -1.42, 0, 1, 0, 0.44);
        roundel(b, side * 2.35, -0.535, -1.18, 0, -1, 0, 0.4);
        roundel(b, side * 0.455, 0.05, 1.15, side, 0, 0, 0.28);
    }
    // rib tapes over the wing fabric (tops of both wings, under the lower
    // one) and the aileron hinge lines: close passes read as doped canvas
    // over a frame, not a slab
    col(b, 0xD2C096, 0, 0);
    for (let i = 1; i <= 6; i++) {
        let x = 0.62 + <f64>(i - 1) * 0.56;
        for (let side = -1.0; side <= 1; side += 2) {
            let xx = side * x;
            hexa(b, [V0,
                V(xx - 0.035, 1.42, -2.02), V(xx + 0.035, 1.42, -2.02), V(xx + 0.035, 1.42, -0.83), V(xx - 0.035, 1.42, -0.83),
                V(xx - 0.035, 1.445, -2.0), V(xx + 0.035, 1.445, -2.0), V(xx + 0.035, 1.445, -0.85), V(xx - 0.035, 1.445, -0.85),
            ]);
            if (x < 3.25) {
                hexa(b, [V0,
                    V(xx - 0.03, -0.39, -1.72), V(xx + 0.03, -0.39, -1.72), V(xx + 0.03, -0.39, -0.63), V(xx - 0.03, -0.39, -0.63),
                    V(xx - 0.03, -0.37, -1.7), V(xx + 0.03, -0.37, -1.7), V(xx + 0.03, -0.37, -0.65), V(xx - 0.03, -0.37, -0.65),
                ]);
                hexa(b, [V0,
                    V(xx - 0.03, -0.535, -1.72), V(xx + 0.03, -0.535, -1.72), V(xx + 0.03, -0.535, -0.63), V(xx - 0.03, -0.535, -0.63),
                    V(xx - 0.03, -0.555, -1.7), V(xx + 0.03, -0.555, -1.7), V(xx + 0.03, -0.555, -0.65), V(xx - 0.03, -0.555, -0.65),
                ]);
            }
        }
    }
    // leading-edge ply strip along the upper wing
    col(b, 0xE4D3A8, 0, 0);
    hexa(b, [V0,
        V(-3.6, 1.421, -2.05), V(3.6, 1.421, -2.05), V(3.6, 1.421, -1.86), V(-3.6, 1.421, -1.86),
        V(-3.6, 1.43, -2.05), V(3.6, 1.43, -2.05), V(3.6, 1.43, -1.86), V(-3.6, 1.43, -1.86),
    ]);
    col(b, INK, 0, 0);
    for (let side = -1.0; side <= 1; side += 2) {
        beam(b, V(side * 2.2, 1.43, -1.08), V(side * 3.55, 1.43, -1.08), 0.014);
        beam(b, V(side * 2.2, 1.43, -1.08), V(side * 2.2, 1.43, -0.82), 0.014);
    }
    // radial engine: cylinder heads through the cowl face, a brass cowl ring
    col(b, IRON, 0, 0.7, 0.35);
    for (let i = 0; i <= 6; i++) {
        let a = <f64>i / 7 * TAU + 0.2;
        let cx = Math.cos(a) * 0.45, cy = Math.sin(a) * 0.45;
        tube(b, V(cx, cy, -2.96), V(cx * 1.05, cy * 1.05, -3.16), [RG0,
            rg(0, 0.13, IRON), rg(0.3, 0.13, SLATE), rg(0.55, 0.1, IRON), rg(1, 0.08, IRON),
        ], 6, 0.7);
    }
    col(b, BRASS, 0, 0.6, 0.6);
    meshgen.push(b, Mat4.fromTranslation(0, 0, -2.99));
    meshgen.torus(b, 0.64, 0.055, 18, 5);
    meshgen.pop(b);
    // struts
    col(b, 0x3B2B22, 0, 0.5);
    for (let side = -1.0; side <= 1; side += 2) {
        beam(b, V(side * 2.7, -0.4, -1.6), V(side * 2.78, 1.28, -1.75), 0.075);
        beam(b, V(side * 2.7, -0.4, -0.78), V(side * 2.78, 1.28, -0.95), 0.075);
        beam(b, V(side * 0.3, 0.62, -1.75), V(side * 0.5, 1.28, -1.62), 0.045);
        beam(b, V(side * 0.3, 0.62, -0.95), V(side * 0.5, 1.28, -0.85), 0.045);
        // landing gear
        beam(b, V(side * 0.35, -0.55, -1.85), V(side * 0.78, -1.3, -1.7), 0.05);
        beam(b, V(side * 0.35, -0.55, -1.15), V(side * 0.78, -1.3, -1.7), 0.05);
    }
    beam(b, V(-0.8, -1.3, -1.7), V(0.8, -1.3, -1.7), 0.04);
    // flying and landing wires: an X between the cabane and each
    // interplane bay, the rigging that makes it read as a biplane up close
    col(b, INK, 0, 0.25);
    let wz: Array<f64> = [-1.68, -0.86];
    for (let side = -1.0; side <= 1; side += 2) {
        for (let k = 0; k < 2; k++) {
            let z = wz[k];
            beam(b, V(side * 0.45, -0.38, z), V(side * 2.74, 1.26, z - 0.08), 0.016);
            beam(b, V(side * 0.52, 1.26, z), V(side * 2.7, -0.38, z + 0.04), 0.016);
        }
    }
    for (let side = -1.0; side <= 1; side += 2) {
        tube(b, V(side * 0.72, -1.3, -1.7), V(side * 0.98, -1.3, -1.7), [RG0,
            rg(0, 0.0, INK),
            rg(0.0, 0.34, INK),
            rg(1.0, 0.34, INK),
            rg(1.0, 0.0, INK),
        ], 12, 1);
        col(b, CREAM, 0, 0);
        meshgen.sphere(b, side * 1.0, -1.3, -1.7, 0.03, 0.14, 0.14, 8, 4);
    }
    // tail
    col(b, CREAM);
    wing(b, -1.35, 0.12, 2.35, 3.15, 0.1, 1.35, 0.12, 2.35, 3.15, 0.1);
    col(b, RED);
    wing(b, 1.35, 0.12, 2.35, 3.15, 0.1, 1.8, 0.12, 2.6, 3.1, 0.08);
    wing(b, -1.35, 0.12, 2.35, 3.15, 0.1, -1.8, 0.12, 2.6, 3.1, 0.08);
    fin(b, 0, 0.25, 2.05, 3.35, 1.45, 2.85, 3.35, 0.1);
    col(b, CREAM, 0, 0);
    fin(b, 0, 0.75, 2.52, 3.36, 0.95, 2.62, 3.36, 0.115);
    // exhaust stubs
    col(b, DARK, 0, 0.6);
    for (let side = -1.0; side <= 1; side += 2) {
        beam(b, V(side * 0.62, -0.1, -2.5), V(side * 0.72, -0.28, -1.9), 0.06);
    }
    return gpu.uploadMesh(b);
}

// Two-blade propeller in the XY plane (spins around Z), radius 1.45.
function buildProp(): Mesh {
    let b = meshgen.create(600);
    col(b, DARK, 0, 0.8, 0.4);
    meshgen.sphere(b, 0, 0, 0, 0.16, 0.16, 0.12, 8, 5);
    for (let side = -1.0; side <= 1; side += 2) {
        col(b, WOOD, 0, 0.7);
        hexa(b, [V0,
            V(-0.13, side * 0.12, 0.03), V(0.12, side * 0.12, -0.03), V(0.08, side * 1.18, -0.05), V(-0.1, side * 1.18, 0.02),
            V(-0.13, side * 0.12, 0.08), V(0.12, side * 0.12, 0.02), V(0.08, side * 1.18, -0.01), V(-0.1, side * 1.18, 0.06),
        ]);
        col(b, CREAM, 0, 0.7);
        hexa(b, [V0,
            V(-0.1, side * 1.18, 0.02), V(0.08, side * 1.18, -0.05), V(0.06, side * 1.45, -0.05), V(-0.07, side * 1.45, 0.02),
            V(-0.1, side * 1.18, 0.06), V(0.08, side * 1.18, -0.01), V(0.06, side * 1.45, -0.01), V(-0.07, side * 1.45, 0.05),
        ]);
    }
    return gpu.uploadMesh(b);
}

function buildDrone(): Mesh {
    let b = meshgen.create(5000);
    lathe(b, [RG0,
        rg(-1.12, 0.0, DARK),
        rg(-1.12, 0.8, DARK),
        rg(-0.96, 0.94, RED),
        rg(-0.2, 1.02, RED),
        rg(0.8, 0.86, RED),
        rg(1.45, 0.58, GREY),
        rg(1.75, 0.44, DARK),
        rg(1.75, 0.0, DARK),
    ], 16, 0, 0, 1, 0.86);
    // glowing eye with a cartoon glint
    col(b, 0xFF3B2E, 1, 0.8, 0.6);
    meshgen.sphere(b, 0, 0, -1.08, 0.6, 0.6, 0.45, 14, 9);
    col(b, INK, 0, 0.5);
    meshgen.push(b, Mat4.fromTranslation(0, 0, -1.2));
    meshgen.torus(b, 0.64, 0.09, 18, 5);
    meshgen.pop(b);
    col(b, 0xFFFFFF, 1, 0, 0, 1);
    meshgen.sphere(b, 0.2, 0.2, -1.5, 0.12, 0.12, 0.08, 8, 5);
    // swept wings with dark trailing strip and tip fins
    col(b, RED);
    for (let side = -1.0; side <= 1; side += 2) {
        wing(b, side * 0.6, 0, -0.35, 0.85, 0.24, side * 3.3, 0.38, 0.9, 1.35, 0.1);
        col(b, RED_DK);
        wing(b, side * 0.6, 0.0, 0.85, 1.12, 0.2, side * 3.3, 0.38, 1.35, 1.52, 0.08);
        col(b, GREY);
        fin(b, side * 3.3, -0.35, 0.95, 1.55, 0.45, 1.2, 1.55, 0.09);
        col(b, RED_DK);
        // canted top fins
        hexa(b, [V0,
            V(side * 0.25, 0.7, 0.25), V(side * 0.25, 0.7, 1.35), V(side * 0.33, 0.7, 1.35), V(side * 0.33, 0.7, 0.25),
            V(side * 0.6, 1.35, 0.95), V(side * 0.6, 1.35, 1.45), V(side * 0.68, 1.35, 1.45), V(side * 0.68, 1.35, 0.95),
        ]);
        col(b, RED);
    }
    // belly pod and thruster glow
    col(b, GREY, 0, 1, 0, 0.3);
    meshgen.sphere(b, 0, -0.72, 0.25, 0.46, 0.3, 1.0, 12, 6);
    col(b, 0xFF9A3A, 1, 0);
    meshgen.sphere(b, 0, 0, 1.72, 0.3, 0.26, 0.12, 10, 5);
    return gpu.uploadMesh(b);
}

// Rival jet trooper: prone flying pose, head toward -Z, jetpack on the back (+Y).
// Hot pink armor so they pop against the violet world.
function buildTrooper(): Mesh {
    let b = meshgen.create(7000);
    const HOT: f64 = 0xFF5FB4;
    const BOOT: f64 = 0x3A1C46;
    // pitched up: head high, legs trailing down behind (reads as a flying figure)
    meshgen.push(b, Mat4.fromRotationX(0.6));
    // helmet + visor + gold crest
    col(b, HOT, 0, 1, 0.5);
    meshgen.sphere(b, 0, 0.06, -0.98, 0.28, 0.28, 0.3, 12, 8);
    col(b, 0x2A1838, 0.2, 0.6, 0.9);
    hexa(b, [V0, V(-0.2, -0.02, -1.2), V(0.2, -0.02, -1.2), V(0.2, 0.14, -1.2), V(-0.2, 0.14, -1.2), V(-0.17, -0.05, -1.29), V(0.17, -0.05, -1.29), V(0.17, 0.12, -1.27), V(-0.17, 0.12, -1.27)]);
    col(b, GOLD, 0.15, 0.8, 0.7);
    fin(b, 0, 0.3, -1.12, -0.78, 0.5, -0.95, -0.74, 0.07); // crest
    // torso
    lathe(b, [RG0,
        rg(-0.8, 0.0, HOT),
        rg(-0.74, 0.22, HOT),
        rg(-0.55, 0.33, HOT),
        rg(-0.1, 0.31, PINK),
        rg(0.02, 0.27, MAGENTA),
        rg(0.2, 0.2, MAGENTA),
        rg(0.24, 0.0, MAGENTA),
    ], 12, 0, 0, 1.05, 0.75);
    // belt
    col(b, GOLD, 0.15, 0.6, 0.7);
    meshgen.push(b, Mat4.fromTranslation(0, 0, -0.14));
    meshgen.torus(b, 0.3, 0.05, 14, 4);
    meshgen.pop(b);
    for (let side = -1.0; side <= 1; side += 2) {
        // legs
        tube(b, V(side * 0.13, -0.03, 0.1), V(side * 0.19, -0.12, 0.98), [RG0,
            rg(0.0, 0.12, MAGENTA),
            rg(0.5, 0.11, MAGENTA),
            rg(0.74, 0.11, BOOT),
            rg(1.0, 0.11, BOOT),
            rg(1.02, 0.0, BOOT),
        ], 8, 1);
        // arms swept back along the sides, gold cuffs
        tube(b, V(side * 0.3, 0.0, -0.62), V(side * 0.42, -0.12, 0.05), [RG0,
            rg(0.0, 0.1, HOT),
            rg(0.6, 0.09, HOT),
            rg(0.7, 0.1, GOLD),
            rg(0.8, 0.1, BOOT),
            rg(1.0, 0.08, BOOT),
            rg(1.05, 0.0, BOOT),
        ], 8, 1);
        // jetpack tanks with brass bands and dark nozzles
        tube(b, V(side * 0.15, 0.32, -0.64), V(side * 0.15, 0.32, 0.36), [RG0,
            rg(0.0, 0.0, STEEL),
            rg(0.04, 0.11, STEEL),
            rg(0.12, 0.14, STEEL),
            rg(0.3, 0.14, BRASS),
            rg(0.36, 0.14, STEEL),
            rg(0.8, 0.14, STEEL),
            rg(0.88, 0.11, DARK),
            rg(1.0, 0.1, DARK),
            rg(1.0, 0.0, DARK),
        ], 10, 1);
    }
    col(b, MAGENTA, 0, 0.8);
    meshgen.box(b, 0, 0.26, -0.15, 0.22, 0.16, 0.6);
    // swept rocket wings: hot pink with cream leading edge and dark trailing strip
    for (let side = -1.0; side <= 1; side += 2) {
        col(b, CREAM, 0, 1);
        wing(b, side * 0.24, 0.36, -0.5, -0.36, 0.07, side * 1.42, 0.5, -0.02, 0.1, 0.04);
        col(b, HOT);
        wing(b, side * 0.24, 0.36, -0.36, 0.14, 0.07, side * 1.42, 0.5, 0.1, 0.34, 0.04);
        col(b, BOOT);
        wing(b, side * 0.24, 0.36, 0.14, 0.24, 0.06, side * 1.42, 0.5, 0.34, 0.42, 0.035);
        col(b, GOLD, 0.1, 0.8, 0.6);
        fin(b, side * 1.42, 0.46, -0.02, 0.42, 0.72, 0.2, 0.46, 0.05);
    }
    meshgen.pop(b);
    return gpu.uploadMesh(b);
}

function buildMine(): Mesh {
    let b = meshgen.create(4000);
    col(b, IRON, 0, 1, 0.35);
    meshgen.sphere(b, 0, 0, 0, 1, 1, 1, 16, 10);
    col(b, 0xB5352E, 0.1, 0.7);
    meshgen.push(b, Mat4.fromRotationX(<f32>(Math.PI / 2)));
    meshgen.torus(b, 1.0, 0.1, 24, 5);
    meshgen.pop(b);
    // spikes on a fibonacci sphere
    let n = 16;
    for (let i = 0; i < n; i++) {
        let y = 1 - (<f64>i + 0.5) / <f64>n * 2;
        let rr = Math.sqrt(1 - y * y);
        let a = <f64>i * 2.39996;
        let d = V(Math.cos(a) * rr, y, Math.sin(a) * rr);
        if (Math.abs(y) < 0.97) {
            col(b, DARK, 0, 0.7, 0.2);
            cone(b, sc(d, 0.9), d, 0.16, 0.62, 6);
            col(b, BRASS, 0.1, 0.4, 0.5);
            meshgen.sphere(b, <f64>d.x * 1.52, <f64>d.y * 1.52, <f64>d.z * 1.52, 0.07, 0.07, 0.07, 5, 3);
        }
    }
    // lamp housing on top
    col(b, BRASS, 0, 0.8, 0.6);
    meshgen.cylinder(b, 0, 0.9, 0, 0.26, 0.2, 0.28, 10, true, true);
    col(b, 0xFF5A3A, 0.9, 0.4);
    meshgen.sphere(b, 0, 1.24, 0, 0.14, 0.12, 0.14, 8, 5);
    return gpu.uploadMesh(b);
}

// Gun nest: a tapered sea-stack pedestal topped by a concrete bunker ring,
// sandbags and Kessel's pennant. Top of the pad at y = 0, base at y = -16.
function buildTurretBase(): Mesh {
    let b = meshgen.create(5000);
    let r = mathx.rng(77);
    // faceted rock, wider at the waterline
    col(b, 0x66708A, 0, 1);
    meshgen.cylinder(b, 0, -16, 0, 4.6, 3.9, 7, 9, false, false);
    col(b, 0x727C95, 0, 1);
    meshgen.cylinder(b, 0, -9, 0, 3.9, 3.1, 6.5, 9, false, false);
    col(b, 0x8A92A6, 0, 1);
    meshgen.cylinder(b, 0, -2.5, 0, 3.1, 2.7, 1.3, 9, true, false);
    // boulders at the foot and a ledge lip
    col(b, 0x5C6479, 0, 1);
    for (let i = 0; i <= 5; i++) {
        let a = <f64>i * 1.1 + 0.3;
        let rr = 4.3 + mathx.rand(r) * 0.6;
        meshgen.rock(b, Math.cos(a) * rr, -14 + mathx.rand(r) * 0.6, Math.sin(a) * rr, 1.3, 1.1, 1.2, <f64>i * 7.1);
    }
    // concrete bunker ring with a hazard band
    col(b, 0xC9C2AE, 0, 1);
    meshgen.cylinder(b, 0, -1.25, 0, 2.55, 2.4, 1.05, 16, true, true);
    col(b, 0xE2B84E, 0.05, 1);
    meshgen.cylinder(b, 0, -0.95, 0, 2.58, 2.58, 0.3, 16, false, true);
    col(b, 0x2A2E3A, 0, 0.6);
    for (let i = 0; i <= 7; i++) {
        let a = <f64>i / 8 * TAU;
        meshgen.box(b, Math.cos(a) * 2.6, -0.8, Math.sin(a) * 2.6, 0.28, 0.3, 0.28);
    }
    // sandbags
    col(b, 0xB9A57A, 0, 1);
    for (let i = 0; i <= 11; i++) {
        let a = (<f64>i + 0.5) / 12 * TAU;
        meshgen.sphere(b, Math.cos(a) * 2.35, -0.05, Math.sin(a) * 2.35, 0.55, 0.3, 0.4, 7, 4);
    }
    // pennant pole + flag (red, cream stripe)
    col(b, 0x3B2B22, 0, 0.6);
    beam(b, V(1.9, -0.2, 1.4), V(1.9, 3.4, 1.4), 0.06);
    col(b, RED, 0, 0.8);
    hexa(b, [V0,
        V(1.9, 3.3, 1.4), V(1.9, 2.4, 1.4), V(1.92, 2.85, 2.9), V(1.92, 2.95, 2.9),
        V(1.95, 3.3, 1.4), V(1.95, 2.4, 1.4), V(1.97, 2.85, 2.9), V(1.97, 2.95, 2.9),
    ]);
    col(b, CREAM, 0, 0.8);
    hexa(b, [V0,
        V(1.89, 3.0, 1.6), V(1.89, 2.75, 1.6), V(1.9, 2.87, 2.4), V(1.9, 2.93, 2.4),
        V(1.98, 3.0, 1.6), V(1.98, 2.75, 1.6), V(1.99, 2.87, 2.4), V(1.99, 2.93, 2.4),
    ]);
    return gpu.uploadMesh(b);
}

// Armored dome (yaws). Origin at the base center.
function buildTurretDome(): Mesh {
    let b = meshgen.create(2500);
    // the lathe runs along +Z; stand it up so the dome bulges along +Y
    meshgen.push(b, Mat4.fromRotationX(<f32>(-Math.PI / 2)));
    lathe(b, [RG0,
        rg(0.0, 1.4, 0x3E4558),
        rg(0.18, 1.4, 0xC99A45),
        rg(0.3, 1.36, 0x505A6E),
        rg(0.62, 1.3, 0xB5352E),
        rg(0.9, 1.16, 0xB5352E),
        rg(1.02, 1.08, 0x505A6E),
        rg(1.3, 0.72, 0x505A6E),
        rg(1.45, 0.0, 0x505A6E),
    ], 16, 0, 0, 1, 1, 1);
    meshgen.pop(b);
    // periscope / sight on top
    col(b, 0x2A2E3A, 0, 0.8);
    meshgen.box(b, 0.45, 1.5, 0.2, 0.28, 0.3, 0.5);
    col(b, 0x9BD7F0, 0.4, 0.4, 0.8);
    meshgen.box(b, 0.45, 1.52, -0.06, 0.2, 0.12, 0.04);
    return gpu.uploadMesh(b);
}

// Twin guns (pitch), pivot at the origin, barrels toward -Z.
function buildTurretGun(): Mesh {
    let b = meshgen.create(2000);
    col(b, 0x3A4050, 0, 1, 0.3);
    meshgen.box(b, 0, 0, -0.2, 1.1, 0.55, 0.8);
    col(b, 0xFF4A3A, 1, 0);
    meshgen.sphere(b, 0, 0.12, -0.62, 0.12, 0.12, 0.05, 8, 4);
    for (let side = -1.0; side <= 1; side += 2) {
        tube(b, V(side * 0.34, -0.06, -0.3), V(side * 0.34, -0.06, -2.7), [RG0,
            rg(0.0, 0.17, DARK),
            rg(0.85, 0.14, DARK),
            rg(0.86, 0.2, INK),
            rg(1.0, 0.2, INK),
            rg(1.0, 0.0, INK),
        ], 8, 1);
    }
    return gpu.uploadMesh(b);
}

// Emblem: a crow in a cream disc, projected onto a lathe surface. u along z, v up.
function crowEmblem(b: Builder, side: f64, zc: f64, yc: f64, radiusAt: (z: f64) => f64, scale: f64): void {
    let proj = (u: f64, v: f64, lift: f64): Vector => {
        let z = zc + u * scale;
        let y = yc + v * scale;
        let R0 = radiusAt(z);
        let rr = R0 * R0 - y * y;
        let x = Math.sqrt(rr > 0.01 ? rr : 0.01) + lift;
        return V(side * x, y, z);
    };
    let shape = (pts2: Array<Vector>, hex: f64, lift: f64): void => {
        col(b, hex, 0, 0);
        // fan around the centroid, each triangle projected onto the surface
        // in pieces <= 0.7 m (flat normal per fan triangle): one flat fan
        // triangle is a chord that sagged up to 0.2 m under the canvas, so
        // the bag cut through the disc, its edge crawling frame to frame
        let n = pts2.length - 1;
        let cx = 0.0, cy = 0.0;
        for (let i = 1; i <= n; i++) {
            cx += <f64>pts2[i].x;
            cy += <f64>pts2[i].y;
        }
        cx /= <f64>n;
        cy /= <f64>n;
        let c = proj(cx, cy, lift);
        // one split count for the shape: shared spokes match (no cracks)
        let edge = 0.0;
        for (let i = 1; i <= n; i++) {
            let p = pts2[i], q = pts2[(i % n) + 1];
            let a = proj(<f64>p.x, <f64>p.y, lift), d = proj(<f64>q.x, <f64>q.y, lift);
            edge = Math.max(edge, Math.max(mathx.len(a - c), mathx.len(d - a)));
        }
        let ns = Math.max(1.0, Math.ceil(edge / 0.7));
        for (let i = 1; i <= n; i++) {
            let p = pts2[i], q = pts2[(i % n) + 1];
            let px = <f64>p.x, py = <f64>p.y, qx = <f64>q.x, qy = <f64>q.y;
            let a = proj(px, py, lift), d = proj(qx, qy, lift);
            let nv = mathx.norm(mathx.cross(a - c, d - c));
            if (<f64>nv.x * side < 0) nv = sc(nv, -1);
            let G = (gi: f64, gj: f64): Vector => {
                let s = gi / ns, t = gj / ns;
                return proj(cx + (px - cx) * s + (qx - cx) * t, cy + (py - cy) * s + (qy - cy) * t, lift);
            };
            for (let gi = 0.0; gi < ns; gi++) {
                for (let gj = 0.0; gj < ns - gi; gj++) {
                    triAuto(b, G(gi, gj), G(gi + 1, gj), G(gi, gj + 1), nv, nv, nv);
                    if (gi + gj < ns - 1) triAuto(b, G(gi + 1, gj), G(gi + 1, gj + 1), G(gi, gj + 1), nv, nv, nv);
                }
            }
        }
    };
    let disc: Array<Vector> = [V0];
    for (let i = 0; i <= 19; i++) {
        let a = <f64>i / 20 * TAU;
        disc.push(X(Math.cos(a), Math.sin(a)));
    }
    shape(disc, CREAM, 0.08);
    // crow (facing -z): body, head, beak, wings up, tail
    shape([V0, X(-0.45, -0.05), X(-0.15, -0.28), X(0.35, -0.2), X(0.55, -0.05), X(0.3, 0.1), X(-0.3, 0.12)], INK, 0.14);
    shape([V0, X(-0.72, 0.12), X(-0.62, 0.0), X(-0.45, -0.02), X(-0.38, 0.12), X(-0.5, 0.24), X(-0.64, 0.24)], INK, 0.14);
    shape([V0, X(-0.92, 0.08), X(-0.7, 0.18), X(-0.7, 0.04)], 0xE2B84E, 0.16);
    shape([V0, X(-0.2, 0.08), X(0.25, 0.1), X(0.62, 0.72), X(0.28, 0.62), X(-0.05, 0.45)], INK, 0.14);
    shape([V0, X(0.45, -0.12), X(0.85, -0.3), X(0.9, -0.05), X(0.55, 0.05)], INK, 0.14);
    shape([V0, X(-0.02, -0.2), X(0.2, -0.24), X(0.14, -0.62), X(0.04, -0.6)], INK, 0.14);
    shape([V0, X(-0.64, 0.14), X(-0.6, 0.1), X(-0.56, 0.14), X(-0.6, 0.18)], 0xFF3B2E, 0.18);
}

// STORMCROW sky galleon hull: gasbag, fins, gondola, struts, outriggers, emblems.
// Local units: meters, ~66 m long. Gondola hangs below at y = -13.5.
const GAS: Array<Ring> = [RG0,
    rg(-34, 0.0, RED),
    rg(-33.2, 3.2, RED),
    rg(-31.0, 5.8, BAG),
    rg(-26.0, 8.2, BAG),
    rg(-20.0, 9.2, RED),
    rg(-18.5, 9.35, BAG),
    rg(-6.0, 9.5, BAG),
    rg(6.0, 9.1, BAG),
    rg(12.0, 8.4, RED),
    rg(13.6, 8.2, BAG),
    rg(22.0, 5.8, BAG),
    rg(29.0, 3.0, BAG),
    rg(32.5, 1.2, RED),
    rg(33.4, 0.0, RED),
];

function gasRadius(z: f64): f64 {
    let n = GAS.length - 1;
    for (let i = 1; i <= n - 1; i++) {
        let a = GAS[i], c = GAS[i + 1];
        if (z >= a.z && z <= c.z) {
            let dz = c.z - a.z;
            let t = (z - a.z) / (dz > 1e-6 ? dz : 1e-6);
            return a.r + (c.r - a.r) * t;
        }
    }
    return 0;
}

// A band painted on the gasbag between angles a0..a1 (around the Z axis,
// 0 = right flank, pi/2 = top) from z0 to z1, lifted off the canvas: it
// follows the bag's taper like a gore (livery stripes, the ventral catwalk).
function bagBand(b: Builder, a0: f64, a1: f64, z0: f64, z1: f64, hex: f64, lift: f64): void {
    col(b, hex, 0, 0);
    let nc = Math.ceil((z1 - z0) / 1.1);
    let n = nc > 2 ? nc : 2.0;
    let P = (z: f64, a: f64): void => {
        let r = gasRadius(z) + lift;
        let c = Math.cos(a), sn = Math.sin(a);
        PT_P = V(c * r, sn * r, z);
        PT_N = V(c, sn, 0);
    };
    // cut at the profile's rings too: a step across one is a chord that
    // sags into the lift (at z -26 it met the canvas)
    let zs: Array<f64> = [];
    for (let i = 0.0; i <= n; i++) zs.push(z0 + (z1 - z0) * i / n);
    for (let k = 1; k < GAS.length; k++) {
        let e = GAS[k];
        if (e.z > z0 && e.z < z1) zs.push(e.z);
    }
    zs.sort((x: f64, y: f64): i32 => (x < y ? -1 : x > y ? 1 : 0));
    for (let i = 0; i < zs.length - 1; i++) {
        let za = zs[i], zb = zs[i + 1];
        if (gasRadius(za) > 2 && gasRadius(zb) > 2) {
            P(za, a0);
            let p00 = PT_P, n00 = PT_N;
            P(za, a1);
            let p01 = PT_P, n01 = PT_N;
            P(zb, a0);
            let p10 = PT_P, n10 = PT_N;
            P(zb, a1);
            let p11 = PT_P, n11 = PT_N;
            triAuto(b, p00, p10, p11, n00, n10, n11);
            triAuto(b, p00, p11, p01, n00, n11, n01);
        }
    }
}

@inline function finP(c: f64, s: f64, r0: f64, z: f64, t: f64): Vector {
    return V(c * r0 - s * t, s * r0 + c * t, z);
}

function buildCrowHull(): Mesh {
    let b = meshgen.create(30000);
    lathe(b, GAS, 26, 0, 0, 1, 1, 1, BAG2);
    // close-camera detail (kill cam): raised rib tapes round the canvas
    // (clear of the flank emblems and the red bands), a crimson cheat line
    // with a cream pinstripe down both flanks under the emblems, and the
    // ventral catwalk the gondola struts hang from
    col(b, BAG_RIB, 0, 1, 0.2);
    let ribs: Array<f64> = [-28.5, -24.5, -14.5, 3.5, 8, 17.5, 22.5, 27];
    for (let k = 0; k < ribs.length; k++) {
        let z = ribs[k];
        meshgen.push(b, Mat4.fromTranslation(0, 0, <f32>z));
        meshgen.torus(b, gasRadius(z) + 0.02, 0.15, 32, 4);
        meshgen.pop(b);
    }
    for (let side = -1.0; side <= 1; side += 2) {
        let ang = (a: f64): f64 => side > 0 ? a : Math.PI - a;
        bagBand(b, ang(-0.5), ang(-0.43), -30, 29.5, 0xB3262A, 0.07);
        bagBand(b, ang(-0.41), ang(-0.385), -29, 28.5, CREAM, 0.07);
    }
    bagBand(b, -Math.PI / 2 - 0.065, -Math.PI / 2 + 0.065, -24, 21, 0x6B4A2E, 0.1);
    // dorsal walkway ridge
    col(b, 0x363C4E);
    wing(b, -0.6, 9.45, -18, 8, 0.25, 0.6, 9.45, -18, 8, 0.25);
    // tail fins (cross)
    for (let k = 0; k <= 3; k++) {
        let a = <f64>k * Math.PI / 2;
        let c = Math.cos(a), s = Math.sin(a);
        col(b, RED_DK);
        hexa(b, [V0,
            finP(c, s, 4.0, 20, -0.25), finP(c, s, 4.0, 31, -0.25), finP(c, s, 12.5, 34.5, -0.2), finP(c, s, 12.0, 26, -0.2),
            finP(c, s, 4.0, 20, 0.25), finP(c, s, 4.0, 31, 0.25), finP(c, s, 12.5, 34.5, 0.2), finP(c, s, 12.0, 26, 0.2),
        ]);
        col(b, CREAM);
        hexa(b, [V0,
            finP(c, s, 12.0, 26, -0.22), finP(c, s, 12.5, 34.5, -0.22), finP(c, s, 13.4, 35, -0.18), finP(c, s, 13.0, 27.5, -0.18),
            finP(c, s, 12.0, 26, 0.22), finP(c, s, 12.5, 34.5, 0.22), finP(c, s, 13.4, 35, 0.18), finP(c, s, 13.0, 27.5, 0.18),
        ]);
    }
    // emblems on both flanks
    crowEmblem(b, 1, -4, 1.0, gasRadius, 4.2);
    crowEmblem(b, -1, -4, 1.0, gasRadius, 4.2);
    // gondola: wooden galleon hull
    lathe(b, [RG0,
        rg(-16.5, 0.0, BRASS),
        rg(-16.0, 0.8, BRASS),
        rg(-14.6, 1.25, WOOD),
        rg(-6.0, 1.35, WOOD),
        rg(6.0, 1.35, WOOD),
        rg(11.5, 1.15, WOOD),
        rg(13.8, 0.7, BRASS),
        rg(14.4, 0.0, BRASS),
    ], 16, 0, -13.5, 2.9, 2.1);
    // keel + deckhouse
    col(b, 0x5A3820, 0, 1);
    wing(b, -0.35, -16.0, -14, 12, 0.5, 0.35, -16.0, -14, 12, 0.5);
    col(b, 0x8A5A34, 0, 1);
    hexa(b, [V0,
        V(-1.9, -11.6, -9), V(1.9, -11.6, -9), V(1.9, -11.6, 6), V(-1.9, -11.6, 6),
        V(-1.6, -10.6, -8), V(1.6, -10.6, -8), V(1.6, -10.6, 5), V(-1.6, -10.6, 5),
    ]);
    // brass rails top and bottom
    col(b, BRASS, 0.05, 0.6, 0.6);
    wing(b, -2.7, -12.25, -12, 11, 0.12, 2.7, -12.25, -12, 11, 0.12);
    // lit windows (warm)
    for (let side = -1.0; side <= 1; side += 2) {
        for (let i = 0; i <= 8; i++) {
            let z = -9 + <f64>i * 2.1;
            col(b, 0xFFD27A, 1, 0.3, 0, 1);
            meshgen.box(b, side * 2.88, -13.3, z, 0.14, 0.55, 0.95);
        }
        // bridge glass
        col(b, 0x9FE0F5, 0.55, 0.5, 0.8);
        hexa(b, [V0,
            V(side * 0.3, -12.7, -13.4), V(side * 2.1, -12.7, -12.2), V(side * 2.1, -13.9, -12.3), V(side * 0.3, -13.9, -13.6),
            V(side * 0.3, -12.7, -13.1), V(side * 1.9, -12.7, -11.9), V(side * 1.9, -13.9, -12.0), V(side * 0.3, -13.9, -13.3),
        ]);
    }
    // struts gondola <-> gasbag
    col(b, 0x3B2B22, 0, 0.6);
    for (let side = -1.0; side <= 1; side += 2) {
        for (let i = 0; i <= 3; i++) {
            let z = -9 + <f64>i * 6;
            beam(b, V(side * 1.4, -11.8, z), V(side * 2.6, -8.8, z + 0.5), 0.12);
        }
    }
    // outriggers to the engine pods
    col(b, 0x3A4050, 0, 0.8);
    for (let side = -1.0; side <= 1; side += 2) {
        beam(b, V(side * 2.4, -13.2, -6), V(side * 12.5, -10.2, -6), 0.2);
        beam(b, V(side * 5.5, -6.8, -6), V(side * 12.3, -9.6, -6), 0.15);
        beam(b, V(side * 2.4, -13.0, 9), V(side * 15.5, -7.2, 9), 0.2);
        beam(b, V(side * 7.5, -4.2, 9), V(side * 15.2, -6.6, 9), 0.15);
    }
    // core housing ring (the cage the core hangs in)
    col(b, BRASS, 0.1, 1, 0.6);
    meshgen.push(b, Mat4.fromTranslation(0, -15.4, 2) * Mat4.fromRotationX(<f32>(Math.PI / 2)));
    meshgen.torus(b, 2.9, 0.28, 20, 6);
    meshgen.pop(b);
    // stern lantern
    col(b, 0xFF9A3A, 1, 0.4);
    meshgen.sphere(b, 0, -13.2, 13.2, 0.35, 0.35, 0.35, 8, 5);
    return gpu.uploadMesh(b);
}

// Engine pod (destructible), prop mounts at local (0, 0, -4.1).
function buildCrowPod(): Mesh {
    let b = meshgen.create(4000);
    lathe(b, [RG0,
        rg(-3.9, 0.0, DARK),
        rg(-3.8, 0.9, RED),
        rg(-3.4, 1.55, RED),
        rg(-2.6, 1.7, BRASS),
        rg(1.5, 1.6, BRASS),
        rg(2.8, 1.2, BRASS),
        rg(3.3, 0.9, DARK),
        rg(3.6, 0.7, DARK),
        rg(3.6, 0.0, 0xFF8A2A, 0.9),
    ], 16, 0, 0, 1, 1);
    // cooling fins
    col(b, 0x8A6A33, 0, 0.6);
    for (let i = 0; i <= 5; i++) {
        let a = <f64>i / 6 * TAU;
        let c = Math.cos(a), s = Math.sin(a);
        hexa(b, [V0,
            V(c * 1.55 - s * 0.06, s * 1.55 + c * 0.06, -1.8), V(c * 1.55 - s * 0.06, s * 1.55 + c * 0.06, 1.2), V(c * 2.0 - s * 0.05, s * 2.0 + c * 0.05, 0.9), V(c * 2.0 - s * 0.05, s * 2.0 + c * 0.05, -1.4),
            V(c * 1.55 + s * 0.06, s * 1.55 - c * 0.06, -1.8), V(c * 1.55 + s * 0.06, s * 1.55 - c * 0.06, 1.2), V(c * 2.0 + s * 0.05, s * 2.0 - c * 0.05, 0.9), V(c * 2.0 + s * 0.05, s * 2.0 - c * 0.05, -1.4),
        ]);
    }
    return gpu.uploadMesh(b);
}

// Pennant segment (double sided), 3 m long toward +Z, hangs from its top edge.
function bannerCard(b: Builder, z0: f64, z1: f64, h0: f64, h1: f64, y0: f64, hex: f64): void {
    col(b, hex, 0, 0.6);
    let pts: Array<Vector> = [V0, V(0, y0, z0), V(0, y0, z1), V(0, y0 - h1, z1), V(0, y0 - h0, z0)];
    polyN(b, pts, 1, 0, 0);
    polyN(b, pts, -1, 0, 0);
}

function buildBanner(): Mesh {
    let b = meshgen.create(400);
    bannerCard(b, 0, 3.05, 3.2, 2.6, 0, 0xB3262A);
    bannerCard(b, 0, 3.05, 0.4, 0.35, -1.3, GOLD);
    return gpu.uploadMesh(b);
}

@inline function shutterP(a: f64, p: f64, r0: f64): Vector {
    return V(Math.sin(p) * Math.sin(a) * r0, -Math.cos(p) * r0 + r0 * 0.1, Math.sin(p) * Math.cos(a) * r0 * -1);
}

// Armored shutter petal: one quarter of a shell around the core (hinge at the top).
function buildShutter(): Mesh {
    let b = meshgen.create(2000);
    let r0 = 3.2;
    for (let j = 0; j <= 5; j++) {
        for (let i = 0; i <= 3; i++) {
            let fi = <f64>i, fj = <f64>j;
            let a0 = (fi / 4) * (Math.PI / 2) - Math.PI / 4, a1 = ((fi + 1) / 4) * (Math.PI / 2) - Math.PI / 4;
            let p0 = (fj / 6) * (Math.PI * 0.52), p1 = ((fj + 1) / 6) * (Math.PI * 0.52);
            col(b, j == 5 ? BRASS : IRON, 0, 1, 0.3);
            let A = shutterP(a0, p0, r0), Bv = shutterP(a1, p0, r0), C = shutterP(a1, p1, r0), D = shutterP(a0, p1, r0);
            let nA = mathx.norm(A), nB = mathx.norm(Bv), nC = mathx.norm(C), nD = mathx.norm(D);
            triAuto(b, A, Bv, C, nA, nB, nC);
            triAuto(b, A, C, D, nA, nC, nD);
            // inner side (dark)
            col(b, INK, 0, 0);
            triAuto(b, sc(A, 0.97), sc(C, 0.97), sc(Bv, 0.97), -nA, -nC, -nB);
            triAuto(b, sc(A, 0.97), sc(D, 0.97), sc(C, 0.97), -nA, -nD, -nC);
        }
    }
    return gpu.uploadMesh(b);
}

// Glowing lift core: a furnace sphere with brass bands.
function buildCore(): Mesh {
    let b = meshgen.create(3000);
    ball(b, 0, 0, 0, 2.3, 18, 12, (x: f64, y: f64, z: f64): void => {
        let band = Math.abs(y) < 0.12 || Math.abs(x) < 0.1;
        if (band) {
            col(b, BRASS, 0.2, 1, 0.6);
        } else {
            col(b, 0xFF8A2A, 1, 1);
        }
    });
    col(b, 0xFFF0B0, 1, 0, 0, 1);
    meshgen.sphere(b, 0, 0, 0, 2.5, 0.5, 2.5, 12, 4);
    return gpu.uploadMesh(b);
}

// THE WATCHER: a clockwork eye. Eyeball looks down -Z.
function buildEyeBall(): Mesh {
    let b = meshgen.create(12000);
    frontBall(b, 0, 0, 0, 6, 36, 24, (fz: f64, x: f64, y: f64): void => {
        let ang = Math.acos(mathx.clamp(fz, -1, 1)) / RPD;
        if (ang < 11) {
            col(b, 0x0E0F1A, 0, 1);
        } else if (ang < 15) {
            col(b, 0xFF9AD0, 1, 1);
        } else if (ang < 30) {
            let swirl = Math.sin(Math.atan2(y, x) * 9 + ang * 0.3);
            col(b, swirl > 0 ? 0xE0409A : 0xB02E8A, 0.85, 1);
        } else if (ang < 34) {
            col(b, 0x2A1238, 0, 1);
        } else if (ang < 92) {
            let vein = Math.sin(Math.atan2(y, x) * 7) > 0.93 && ang > 45;
            col(b, vein ? 0xE58C9E : 0xF3EBDC, 0, 1, 0.3);
        } else {
            col(b, 0xB8883A, 0, 1, 0.5);
        }
    });
    // glint
    col(b, 0xFFFFFF, 1, 0, 0, 1);
    meshgen.sphere(b, 1.4, 1.5, -5.75, 0.55, 0.55, 0.2, 10, 5);
    // brass collar around the back half
    col(b, BRASS, 0.05, 1, 0.6);
    meshgen.push(b, Mat4.fromTranslation(0, 0, 0.6));
    meshgen.torus(b, 6.2, 0.55, 40, 8);
    meshgen.pop(b);
    // rivets / bolts
    col(b, 0x8A6A33, 0, 0.8);
    for (let i = 0; i <= 15; i++) {
        let a = <f64>i / 16 * TAU;
        meshgen.sphere(b, Math.cos(a) * 6.3, Math.sin(a) * 6.3, 0.0, 0.3, 0.3, 0.3, 6, 4);
    }
    // rear exhaust stacks
    col(b, IRON, 0, 1, 0.3);
    for (let i = 0; i <= 5; i++) {
        let a = <f64>i / 6 * TAU + 0.3;
        let d = V(Math.cos(a) * 0.7, Math.sin(a) * 0.7, 0.7);
        cone(b, sc(d, 5.2), mathx.norm(d), 0.9, 3.4, 6);
    }
    return gpu.uploadMesh(b);
}

function buildEyeRing(): Mesh {
    let b = meshgen.create(8000);
    meshgen.aux(b, 0.05, 1, 0, 0.6);
    gearRing(b, 9.5, 0.5, 0, 48, 6, 28, 0.9, BRASS, 0xD9B45A);
    // spokes
    col(b, 0x8A6A33, 0, 0.8, 0.4);
    for (let i = 0; i <= 3; i++) {
        let a = <f64>i / 4 * TAU + Math.PI / 4;
        beam(b, V(Math.cos(a) * 6.6, Math.sin(a) * 6.6, 0), V(Math.cos(a) * 9.3, Math.sin(a) * 9.3, 0), 0.22);
    }
    return gpu.uploadMesh(b);
}

// polar angle p from -Z; azimuth a around Z centred on +Y
@inline function petalP(a: f64, p: f64, r0: f64): Vector {
    return V(Math.sin(p) * Math.sin(a) * r0, Math.sin(p) * Math.cos(a) * r0, -Math.cos(p) * r0);
}

// Eyelid petal: a quarter shell over the front of the eye, hinged at its outer rim.
function buildEyePetal(): Mesh {
    let b = meshgen.create(3000);
    let r0 = 6.7;
    let rings = 6, segs = 6;
    let frings = <f64>rings, fsegs = <f64>segs;
    for (let j = 0; j < rings; j++) {
        for (let i = 0; i < segs; i++) {
            let fi = <f64>i, fj = <f64>j;
            let a0 = (fi / fsegs - 0.5) * (Math.PI / 2);
            let a1 = ((fi + 1) / fsegs - 0.5) * (Math.PI / 2);
            let p0 = (fj / frings) * (80 * RPD);
            let p1 = ((fj + 1) / frings) * (80 * RPD);
            let A = petalP(a0, p0, r0), Bv = petalP(a1, p0, r0), C = petalP(a1, p1, r0), D = petalP(a0, p1, r0);
            let nA = mathx.norm(A), nB = mathx.norm(Bv), nC = mathx.norm(C), nD = mathx.norm(D);
            col(b, j == rings - 1 ? BRASS : ((i + j) % 2 == 0 ? 0x3A3F52 : 0x333848), 0, 1, 0.35);
            triAuto(b, A, Bv, C, nA, nB, nC);
            triAuto(b, A, C, D, nA, nC, nD);
            col(b, INK, 0, 0);
            triAuto(b, sc(A, 0.98), sc(C, 0.98), sc(Bv, 0.98), -nA, -nC, -nB);
            triAuto(b, sc(A, 0.98), sc(D, 0.98), sc(C, 0.98), -nA, -nD, -nC);
        }
    }
    // brass spine rib
    col(b, BRASS, 0.05, 0.8, 0.6);
    for (let j = 0; j < rings; j++) {
        let p0 = (<f64>j / frings) * (80 * RPD);
        let p1 = ((<f64>j + 1) / frings) * (80 * RPD);
        beam(b, V(0, Math.sin(p0) * (r0 + 0.1), -Math.cos(p0) * (r0 + 0.1)), V(0, Math.sin(p1) * (r0 + 0.1), -Math.cos(p1) * (r0 + 0.1)), 0.2);
    }
    return gpu.uploadMesh(b);
}

// Lens emitter pod (destructible): brass can with a glowing cyan lens toward -Z.
function buildEyeLens(): Mesh {
    let b = meshgen.create(2000);
    lathe(b, [RG0,
        rg(-0.9, 0.0, 0x7FF3FF, 1),
        rg(-0.9, 0.75, BRASS),
        rg(-0.6, 0.95, BRASS),
        rg(0.6, 0.95, 0x8A6A33),
        rg(1.1, 0.6, IRON),
        rg(1.2, 0.0, IRON),
    ], 12, 0, 0, 1, 1);
    col(b, IRON, 0, 1, 0.3);
    cone(b, V(0, 0, 1.0), V(0, 0, 1), 0.4, 1.2, 6);
    return gpu.uploadMesh(b);
}

function buildDebris(): Mesh {
    let b = meshgen.create(400);
    col(b, 0xE6E8EE, 0, 1);
    meshgen.rock(b, 0, 0, 0, 0.5, 0.35, 0.45, 3.3, 6, 4);
    return gpu.uploadMesh(b);
}

function buildRocket(): Mesh {
    let b = meshgen.create(1200);
    lathe(b, [RG0,
        rg(-0.8, 0.0, RED),
        rg(-0.55, 0.14, RED),
        rg(-0.35, 0.17, CREAM),
        rg(0.45, 0.17, CREAM),
        rg(0.6, 0.12, DARK),
        rg(0.65, 0.0, DARK),
    ], 8, 0, 0, 1, 1);
    col(b, RED_DK, 0, 0.7);
    for (let k = 0; k <= 3; k++) {
        let a = <f64>k * Math.PI / 2;
        let c = Math.cos(a), s = Math.sin(a);
        hexa(b, [V0,
            V(c * 0.15 - s * 0.02, s * 0.15 + c * 0.02, 0.2), V(c * 0.15 - s * 0.02, s * 0.15 + c * 0.02, 0.6), V(c * 0.38 - s * 0.02, s * 0.38 + c * 0.02, 0.62), V(c * 0.38 - s * 0.02, s * 0.38 + c * 0.02, 0.45),
            V(c * 0.15 + s * 0.02, s * 0.15 - c * 0.02, 0.2), V(c * 0.15 + s * 0.02, s * 0.15 - c * 0.02, 0.6), V(c * 0.38 + s * 0.02, s * 0.38 - c * 0.02, 0.62), V(c * 0.38 + s * 0.02, s * 0.38 - c * 0.02, 0.45),
        ]);
    }
    return gpu.uploadMesh(b);
}

// Splash water: sea aqua at the waterline, white at the crest.
const SPLASH_BANDS: Array<f64> = [0.0, 0x9CD6E4, 0xC8ECF4, 0xEEF9FC, 0xEEF9FC, 0xEEF9FC];

// Splash crown: a thin wall of water around +Y (base radius 1 at y 0, up to
// 1 high) flaring out as it rises, its rim torn into 8 pointed petals (tips
// at mesh angles (k + 0.5) / 8 turns). Open underneath (it stands in the sea).
function buildSplashCrown(): Mesh {
    let b = meshgen.create(3600);
    const N = 48, ROWS = 5, P = 8;
    let fN = <f64>N, fROWS = <f64>ROWS, fP = <f64>P;
    let top: Array<f64> = []; // 0-based (as the Luau table)
    for (let j = 0; j <= N; j++) {
        let f = mod(<f64>j / fN * fP, 1);
        let tip = 1 - Math.abs(f * 2 - 1);
        let k = mod(Math.floor(<f64>j / fN * fP + 1e-6), fP);
        top.push(0.4 + 0.6 * (0.8 + 0.2 * Math.sin(k * 2.3 + 1.1)) * Math.pow(tip, 1.8));
    }
    let at = (i: i32, j: i32, inner: bool): void => {
        let a = <f64>j / fN * TAU;
        let c = Math.cos(a), s = Math.sin(a);
        let v = <f64>i / fROWS;
        let y = v * top[j];
        let ro = 1 + 0.5 * Math.pow(y, 1.5);
        let slope = 0.75 * Math.sqrt(y);
        let r = inner ? ro - (0.12 * (1 - v) + 0.02) : ro;
        let sg = inner ? -1.0 : 1.0;
        PT_P = V(c * r, y, s * r);
        PT_N = mathx.norm(V(c * sg, -slope * sg, s * sg));
    };
    for (let i = 0; i < ROWS; i++) {
        col(b, SPLASH_BANDS[i + 1], 0, 1);
        for (let j = 0; j < N; j++) {
            for (let side = 0; side <= 1; side++) {
                let inner = side == 1;
                at(i, j, inner);
                let p00 = PT_P, n00 = PT_N;
                at(i, j + 1, inner);
                let p01 = PT_P, n01 = PT_N;
                at(i + 1, j, inner);
                let p10 = PT_P, n10 = PT_N;
                at(i + 1, j + 1, inner);
                let p11 = PT_P, n11 = PT_N;
                triAuto(b, p00, p01, p11, n00, n01, n11);
                triAuto(b, p00, p11, p10, n00, n11, n10);
            }
        }
    }
    // rim between the two walls
    col(b, SPLASH_BANDS[ROWS], 0, 1);
    for (let j = 0; j < N; j++) {
        at(ROWS, j, false);
        let o0 = PT_P, n0 = PT_N;
        at(ROWS, j + 1, false);
        let o1 = PT_P, n1 = PT_N;
        at(ROWS, j, true);
        let i0 = PT_P;
        at(ROWS, j + 1, true);
        let i1 = PT_P;
        let u0 = mathx.norm(n0 + V(0, 2, 0)), u1 = mathx.norm(n1 + V(0, 2, 0));
        triAuto(b, o0, o1, i1, u0, u1, u1);
        triAuto(b, o0, i1, i0, u0, u1, u0);
    }
    return gpu.uploadMesh(b);
}

// Splash jet: a column climbing along +Y (0..1) to a round head.
function buildSplashJet(): Mesh {
    let b = meshgen.create(900);
    // { y, r, band }
    let prof: Array<Array<f64>> = [[0.0],
        [0.0, 0.0, 0.5, 1], [0.0, 0.12, 0.35, 2], [0.0, 0.35, 0.25, 3], [0.0, 0.7, 0.2, 3],
        [0.0, 0.86, 0.19, 3], [0.0, 0.95, 0.14, 3], [0.0, 0.99, 0.07, 3], [0.0, 1.0, 0.0, 3],
    ];
    const SEG = 12;
    let n = prof.length - 1;
    let at = (i: i32, j: i32): void => {
        let e = prof[i];
        let a = <f64>j / <f64>SEG * TAU;
        let c = Math.cos(a), s = Math.sin(a);
        let lo = prof[max(i - 1, 1)], hi = prof[min(i + 1, n)];
        let dy = hi[1] - lo[1], dr = hi[2] - lo[2];
        PT_P = V(c * e[2], e[1], s * e[2]);
        PT_N = mathx.norm(V(c * dy, -dr, s * dy));
    };
    for (let i = 1; i <= n - 1; i++) {
        col(b, SPLASH_BANDS[<i32>prof[i][3]], 0, 1);
        for (let j = 0; j < SEG; j++) {
            at(i, j);
            let p00 = PT_P, n00 = PT_N;
            at(i, j + 1);
            let p01 = PT_P, n01 = PT_N;
            at(i + 1, j);
            let p10 = PT_P, n10 = PT_N;
            at(i + 1, j + 1);
            let p11 = PT_P, n11 = PT_N;
            triAuto(b, p00, p01, p11, n00, n01, n11);
            triAuto(b, p00, p11, p10, n00, n11, n10);
        }
    }
    return gpu.uploadMesh(b);
}

function foamEdge(j: i32, inner: bool): Vector {
    let a = <f64>j / 64 * TAU;
    let w = Math.sin(a * 5 + 0.7) * 0.5 + Math.sin(a * 11 + 2.1) * 0.3 + Math.sin(a * 23 + 4.2) * 0.2;
    let r = inner ? 0.76 + 0.07 * w : 1 + 0.035 * w;
    return V(Math.cos(a) * r, 0, Math.sin(a) * r);
}

// Foam shockwave ring: a flat band of unlit foam lace lying on the water
// (radius 0.76..1 with ragged edges), the shoreline foam paint.
function buildFoamRing(): Mesh {
    let b = meshgen.create(800);
    col(b, 0xF2FAFD, 0, 0, 0.25, 1);
    const N = 64;
    let up = V(0, 1, 0);
    for (let j = 0; j < N; j++) {
        let i0 = foamEdge(j, true), i1 = foamEdge(j + 1, true), o0 = foamEdge(j, false), o1 = foamEdge(j + 1, false);
        triAuto(b, i0, o0, o1, up, up, up);
        triAuto(b, i0, o1, i1, up, up, up);
    }
    return gpu.uploadMesh(b);
}

// Splash crown, jet and foam ring batches (fx builds them on first use):
// SPLASH_CROWN, SPLASH_JET, SPLASH_RING.
export let SPLASH_CROWN: Batch? = null;
export let SPLASH_JET: Batch? = null;
export let SPLASH_RING: Batch? = null;
export function splashBatches(): void {
    SPLASH_CROWN = gpu.batch("fxSplashCrown", buildSplashCrown(), 32, true, true);
    SPLASH_JET = gpu.batch("fxSplashJet", buildSplashJet(), 16, true, true);
    SPLASH_RING = gpu.batch("fxFoamRing", buildFoamRing(), 16, false, false);
}

// Instancing -------------------------------------------------------------------

// A placed frame: position, orthonormal right/up/forward (forward = mesh -Z) and uniform scale.
export class Xf {
    px: f64 = 0;
    py: f64 = 0;
    pz: f64 = 0;
    rx: f64 = 1;
    ry: f64 = 0;
    rz: f64 = 0;
    ux: f64 = 0;
    uy: f64 = 1;
    uz: f64 = 0;
    fx: f64 = 0;
    fy: f64 = 0;
    fz: f64 = -1;
    s: f64 = 1;
}

function mk(name: string, mesh: Mesh, cap: i32, reflect: bool): Batch {
    return gpu.batch(name, mesh, cap, true, reflect);
}

export class Models {
    biplane: Batch;
    prop: Batch;
    drone: Batch;
    trooper: Batch;
    mine: Batch;
    turretBase: Batch;
    turretDome: Batch;
    turretGun: Batch;
    crowHull: Batch;
    crowPod: Batch;
    crowBanner: Batch;
    crowShutter: Batch;
    crowCore: Batch;
    eyeBall: Batch;
    eyeRing: Batch;
    eyePetal: Batch;
    eyeLens: Batch;
    debris: Batch;
    rocket: Batch;
    all: Array<Batch>; // 1-based

    // (build order as Luau: prop, dome, gun, then the table fields in order)
    constructor() {
        let prop = buildProp();
        let dome = buildTurretDome();
        let gun = buildTurretGun();
        this.biplane = mk("enemyBiplane", buildBiplane(), 24, true);
        this.prop = mk("enemyProp", prop, 64, true);
        this.drone = mk("enemyDrone", buildDrone(), 40, true);
        this.trooper = mk("enemyTrooper", buildTrooper(), 24, true);
        this.mine = mk("enemyMine", buildMine(), 64, true);
        this.turretBase = mk("enemyTurretBase", buildTurretBase(), 16, true);
        this.turretDome = mk("enemyTurretDome", dome, 24, true);
        this.turretGun = mk("enemyTurretGun", gun, 24, true);
        this.crowHull = mk("bossCrowHull", buildCrowHull(), 2, false);
        this.crowPod = mk("bossCrowPod", buildCrowPod(), 6, false);
        this.crowBanner = mk("bossCrowBanner", buildBanner(), 8, false);
        this.crowShutter = mk("bossCrowShutter", buildShutter(), 4, false);
        this.crowCore = mk("bossCrowCore", buildCore(), 2, false);
        this.eyeBall = mk("bossEyeBall", buildEyeBall(), 2, true);
        this.eyeRing = mk("bossEyeRing", buildEyeRing(), 4, true);
        this.eyePetal = mk("bossEyePetal", buildEyePetal(), 4, true);
        this.eyeLens = mk("bossEyeLens", buildEyeLens(), 8, true);
        this.debris = mk("fxDebris", buildDebris(), 160, true);
        this.rocket = mk("enemyRocket", buildRocket(), 24, true);
        let all = new Array<Batch>(1);
        all.push(this.biplane);
        all.push(this.prop);
        all.push(this.drone);
        all.push(this.trooper);
        all.push(this.mine);
        all.push(this.turretBase);
        all.push(this.turretDome);
        all.push(this.turretGun);
        all.push(this.crowHull);
        all.push(this.crowPod);
        all.push(this.crowBanner);
        all.push(this.crowShutter);
        all.push(this.crowCore);
        all.push(this.eyeBall);
        all.push(this.eyeRing);
        all.push(this.eyePetal);
        all.push(this.eyeLens);
        all.push(this.debris);
        all.push(this.rocket);
        this.all = all;
    }
}

export function build(): Models {
    return new Models();
}

export function reset(mo: Models): void {
    let all = mo.all;
    for (let i = 1; i < all.length; i++) gpu.reset(all[i]);
}

export function submit(mo: Models, r: R.Gfx): void {
    let all = mo.all;
    for (let i = 1; i < all.length; i++) R.addBatch(r, all[i]);
}

export function xf(): Xf {
    return new Xf();
}

// Frame from a forward direction, an up hint and a roll around forward.
export function aim(x: Xf, px: f64, py: f64, pz: f64, fx: f64, fy: f64, fz: f64, hx: f64, hy: f64, hz: f64, roll: f64, s: f64): void {
    let l = Math.sqrt(fx * fx + fy * fy + fz * fz);
    if (l < 1e-9) {
        fx = 0;
        fy = 0;
        fz = -1;
        l = 1;
    }
    fx = fx / l;
    fy = fy / l;
    fz = fz / l;
    // right = f x hint
    let rx = fy * hz - fz * hy, ry = fz * hx - fx * hz, rz = fx * hy - fy * hx;
    let rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
    if (rl < 1e-6) {
        rx = 1;
        ry = 0;
        rz = 0;
        rl = 1;
    }
    rx = rx / rl;
    ry = ry / rl;
    rz = rz / rl;
    // up = right x f
    let ux = ry * fz - rz * fy, uy = rz * fx - rx * fz, uz = rx * fy - ry * fx;
    let c = Math.cos(roll), sn = Math.sin(roll);
    x.px = px;
    x.py = py;
    x.pz = pz;
    x.rx = rx * c + ux * sn;
    x.ry = ry * c + uy * sn;
    x.rz = rz * c + uz * sn;
    x.ux = ux * c - rx * sn;
    x.uy = uy * c - ry * sn;
    x.uz = uz * c - rz * sn;
    x.fx = fx;
    x.fy = fy;
    x.fz = fz;
    x.s = s;
}

// World point of a local offset (mesh space: +X right, +Y up, -Z forward): POINT_X / Y / Z.
export let POINT_X: f64 = 0;
export let POINT_Y: f64 = 0;
export let POINT_Z: f64 = 0;
export function point(x: Xf, lx: f64, ly: f64, lz: f64): void {
    let s = x.s;
    POINT_X = x.px + (x.rx * lx + x.ux * ly - x.fx * lz) * s;
    POINT_Y = x.py + (x.ry * lx + x.uy * ly - x.fy * lz) * s;
    POINT_Z = x.pz + (x.rz * lx + x.uz * ly - x.fz * lz) * s;
}

// World direction of a local direction: DIR_X / Y / Z.
export let DIR_X: f64 = 0;
export let DIR_Y: f64 = 0;
export let DIR_Z: f64 = 0;
export function dir(x: Xf, lx: f64, ly: f64, lz: f64): void {
    DIR_X = x.rx * lx + x.ux * ly - x.fx * lz;
    DIR_Y = x.ry * lx + x.uy * ly - x.fy * lz;
    DIR_Z = x.rz * lx + x.uz * ly - x.fz * lz;
}

// Child frame: local offset, then yaw (around up), pitch (around right), roll (around forward), scale multiplier.
export function child(out: Xf, p: Xf, lx: f64, ly: f64, lz: f64, yaw: f64, pitch: f64, roll: f64, s: f64): void {
    let cy = Math.cos(yaw), sy = Math.sin(yaw);
    let cp = Math.cos(pitch), sp = Math.sin(pitch);
    let cr = Math.cos(roll), sr = Math.sin(roll);
    // local forward (mesh -Z) after yaw/pitch, in parent mesh axes
    let lfx = -sy * cp, lfy = sp, lfz = -cy * cp;
    let lrx = cy, lry = 0.0, lrz = -sy;
    let lux = lry * lfz - lrz * lfy, luy = lrz * lfx - lrx * lfz, luz = lrx * lfy - lry * lfx;
    let rrx = lrx * cr + lux * sr, rry = lry * cr + luy * sr, rrz = lrz * cr + luz * sr;
    let uux = lux * cr - lrx * sr, uuy = luy * cr - lry * sr, uuz = luz * cr - lrz * sr;
    // map parent-mesh vectors to world (mesh -Z = parent forward)
    point(p, lx, ly, lz);
    let px = POINT_X, py = POINT_Y, pz = POINT_Z;
    out.px = px;
    out.py = py;
    out.pz = pz;
    let ox = p.rx * rrx + p.ux * rry - p.fx * rrz, oy = p.ry * rrx + p.uy * rry - p.fy * rrz, oz = p.rz * rrx + p.uz * rry - p.fz * rrz;
    out.rx = ox;
    out.ry = oy;
    out.rz = oz;
    ox = p.rx * uux + p.ux * uuy - p.fx * uuz;
    oy = p.ry * uux + p.uy * uuy - p.fy * uuz;
    oz = p.rz * uux + p.uz * uuy - p.fz * uuz;
    out.ux = ox;
    out.uy = oy;
    out.uz = oz;
    // forward in mesh coords is -Z, so world forward = w(-(-lf))... lf is already the forward direction vector
    let wx = p.rx * lfx + p.ux * lfy - p.fx * lfz, wy = p.ry * lfx + p.uy * lfy - p.fy * lfz, wz = p.rz * lfx + p.uz * lfy - p.fz * lfz;
    out.fx = wx;
    out.fy = wy;
    out.fz = wz;
    out.s = p.s * s;
}

// Flight school targets (enemies.practice): tint r, g, b and a cream wash
// floor (the hit-flash channel), so the red hull reads crimson on cream. (1-based)
export const PRACTICE_TINT: Array<f64> = [0.0, 1.1, 0.85, 1.15, 0.4];

// (Luau optional args: emissive 0, dissolve 0, ink 1)
export function put(b: Batch, x: Xf, tr: f64, tg: f64, tb: f64, flash: f64, emissive: f64 = 0, dissolve: f64 = 0, ink: f64 = 1): bool {
    return gpu.addBasis(b, x.px, x.py, x.pz, x.rx, x.ry, x.rz, x.ux, x.uy, x.uz, x.fx, x.fy, x.fz, x.s, x.s, x.s, tr, tg, tb, flash, emissive, dissolve, ink);
}

// Non-uniform scaled instance (debris).
export function putScaled(b: Batch, x: Xf, sx: f64, sy: f64, sz: f64, tr: f64, tg: f64, tb: f64, flash: f64, emissive: f64 = 0): bool {
    return gpu.addBasis(b, x.px, x.py, x.pz, x.rx, x.ry, x.rz, x.ux, x.uy, x.uz, x.fx, x.fy, x.fz, sx, sy, sz, tr, tg, tb, flash, emissive, 0, 1);
}
