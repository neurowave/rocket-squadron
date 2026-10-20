// Port of src/world/props.luau: hand-shaped set-piece props (the lighthouse
// and keeper's cottage, a pier, a wreck, buoys, the sky portal ring and the
// Eye, the flight school barge). World-space, baked into scenery chunks.
// Colliders are appended to the given list.
//
// portalRingSteps returns its bake steps as a 0-based array (closures
// capture by value here: their shared state lives in a PortalRing).
import { Vector } from "rive/vector";
import { Mat4 } from "rive/mat4";
import * as mathx from "../lib/mathx";
import { Rng, rand, randRange, TAU, v3 } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as coll from "./collide";
import { Collider } from "./collide";
import * as geo from "./geo";
import { Style } from "./geo";
import { lmin, lmax, mod, cosL, sinL } from "../lib/compat";

// local frame helper: origin + yaw (local +x -> (cos, sin), local +z -> (-sin, cos))
function frame(x: f64, y: f64, z: f64, yaw: f64): Mat4 {
    return Mat4.fromTranslation(<f32>x, <f32>y, <f32>z) * Mat4.fromRotationY(<f32>(-yaw));
}

// Lighthouse ------------------------------------------------------------------

// x, y, z: ground point on the clifftop. Returns the lantern world position.
export function lighthouse(b: Builder, x: f64, y: f64, z: f64, cols: Array<Collider>?): Vector {
    let col = b.col, aux = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    // plinth
    meshgen.color(b, 0x9A97A0);
    meshgen.cylinder(b, x, y - 1.5, z, 4.6, 4.3, 2.6, 10, true, false);
    // banded tower
    let h = y + 1.1;
    let bands = 6;
    let bandH = 4.1;
    let r0 = 3.35, r1 = 2.25;
    for (let i = 0; i < bands; i++) {
        meshgen.color(b, i % 2 == 0 ? 0xF6F1E6 : 0xD8342C);
        let ra = r0 + (r1 - r0) * (<f64>i / <f64>bands);
        let rb = r0 + (r1 - r0) * (<f64>(i + 1) / <f64>bands);
        meshgen.cylinder(b, x, h, z, ra, rb, bandH, 20, false, true);
        h += bandH;
    }
    // windows (dark slits) on the rail-facing sides
    meshgen.color(b, 0x2A2F3E);
    meshgen.aux(b, 0, 0, 0, 0);
    for (let k = 0; k <= 3; k++) {
        let a = <f64>k * TAU / 4 + 0.4;
        let yy = y + 5 + <f64>k * 5.4;
        let rr = r0 + (r1 - r0) * ((yy - y) / (<f64>bands * bandH)) + 0.04;
        meshgen.push(b, frame(x + Math.cos(a) * rr, yy, z + Math.sin(a) * rr, a));
        meshgen.box(b, 0, 0, 0, 0.12, 1.3, 0.7);
        meshgen.pop(b);
    }
    meshgen.aux(b, 0, 1, 0, 0);
    // gallery deck + railing
    meshgen.color(b, 0x262A36);
    meshgen.cylinder(b, x, h, z, 3.3, 3.3, 0.45, 18, true, false);
    for (let k = 0; k <= 15; k++) {
        let a = <f64>k / 16 * TAU;
        meshgen.box(b, x + Math.cos(a) * 3.1, h + 0.95, z + Math.sin(a) * 3.1, 0.12, 1.0, 0.12);
    }
    meshgen.cylinder(b, x, h + 1.4, z, 3.15, 3.15, 0.14, 18, false, true);
    // lantern room (glowing)
    meshgen.color(b, 0x262A36);
    meshgen.cylinder(b, x, h + 0.45, z, 1.95, 1.95, 0.35, 12, false, false);
    meshgen.color(b, 0xFFE38A);
    meshgen.aux(b, 1, 0.35, 1, 0);
    meshgen.cylinder(b, x, h + 0.8, z, 1.75, 1.75, 2.5, 12, false, true);
    let lantern = v3(x, h + 2.05, z);
    // mullions
    meshgen.aux(b, 0, 0.5, 0, 0);
    meshgen.color(b, 0x262A36);
    for (let k = 0; k <= 5; k++) {
        let a = <f64>k / 6 * TAU;
        meshgen.box(b, x + Math.cos(a) * 1.8, h + 2.05, z + Math.sin(a) * 1.8, 0.16, 2.5, 0.16);
    }
    // red dome + finial
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.color(b, 0xD8342C);
    meshgen.cylinder(b, x, h + 3.3, z, 2.25, 1.6, 0.6, 16, false, true);
    meshgen.cylinder(b, x, h + 3.9, z, 1.6, 0.15, 1.8, 16, false, true);
    meshgen.color(b, 0x262A36);
    meshgen.sphere(b, x, h + 5.9, z, 0.35, 0.35, 0.35, 8, 6, false);
    meshgen.cylinder(b, x, h + 5.9, z, 0.06, 0.06, 1.4, 5, false, false);
    meshgen.setPaint(b, col, aux);
    if (cols != null) {
        cols.push(coll.cylinder(x, z, 3.6, y - 2, h + 6));
    }
    return lantern;
}

// Keeper's cottage: whitewashed walls, gabled roof (red by default), chimney.
// roofHex / wallHex / scale: NaN = default.
export function cottage(b: Builder, x: f64, y: f64, z: f64, yaw: f64, roofHex: f64 = NaN, wallHex: f64 = NaN, scale: f64 = NaN): void {
    let col = b.col, aux = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    let sc = isNaN(scale) ? 1.0 : scale;
    let wall = isNaN(wallHex) ? 0xF1ECDF : wallHex;
    meshgen.push(b, frame(x, y, z, yaw) * Mat4.fromUniformScale(<f32>sc));
    meshgen.color(b, wall);
    meshgen.box(b, 0, 1.6, 0, 8, 4.2, 5);
    // gable roof as two slabs
    meshgen.color(b, isNaN(roofHex) ? 0xC23A30 : roofHex);
    let rh = 2.6, ov = 0.5;
    meshgen.flatQuad(b, v3(-4 - ov, 3.7, 2.5 + ov), v3(4 + ov, 3.7, 2.5 + ov), v3(4 + ov, 3.7 + rh, 0), v3(-4 - ov, 3.7 + rh, 0));
    meshgen.flatQuad(b, v3(4 + ov, 3.7, -2.5 - ov), v3(-4 - ov, 3.7, -2.5 - ov), v3(-4 - ov, 3.7 + rh, 0), v3(4 + ov, 3.7 + rh, 0));
    meshgen.flatQuad(b, v3(-4 - ov, 3.7, -2.5 - ov), v3(4 + ov, 3.7, -2.5 - ov), v3(4 + ov, 3.7, 2.5 + ov), v3(-4 - ov, 3.7, 2.5 + ov));
    // gable ends
    meshgen.color(b, wall);
    meshgen.flatTri(b, 4, 3.7, 2.5, 4, 3.7, -2.5, 4, 3.7 + rh - 0.1, 0);
    meshgen.flatTri(b, -4, 3.7, -2.5, -4, 3.7, 2.5, -4, 3.7 + rh - 0.1, 0);
    // chimney
    meshgen.color(b, 0x8E8A92);
    meshgen.box(b, 2.4, 5.6, -0.9, 0.9, 2.6, 0.9);
    // door + windows
    meshgen.aux(b, 0, 0, 0, 0);
    meshgen.color(b, 0x2F5C7A);
    meshgen.box(b, 0, 1.0, 2.52, 1.1, 2.0, 0.1);
    meshgen.color(b, 0x283044);
    meshgen.box(b, -2.4, 2.1, 2.52, 1.2, 1.0, 0.1);
    meshgen.box(b, 2.4, 2.1, 2.52, 1.2, 1.0, 0.1);
    meshgen.box(b, -2.4, 2.1, -2.52, 1.2, 1.0, 0.1);
    meshgen.pop(b);
    meshgen.setPaint(b, col, aux);
}

// Wooden pier running from (x, z) along yaw for len meters, deck at y.
export function pier(b: Builder, x: f64, z: f64, yaw: f64, len: f64, y: f64): void {
    let col = b.col, aux = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.push(b, frame(x, 0, z, yaw));
    meshgen.color(b, 0x9A6A42);
    meshgen.box(b, len * 0.5, y, 0, len, 0.35, 3.2);
    // planks seams (darker strips)
    meshgen.aux(b, 0, 0, 0, 0);
    meshgen.color(b, 0x7B5233);
    let nk = Math.floor(len / 1.6);
    for (let k = 0.0; k <= nk; k++) {
        meshgen.box(b, k * 1.6 + 0.3, y + 0.18, 0, 0.1, 0.04, 3.2);
    }
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.color(b, 0x6B4A30);
    let k = 0.0;
    while (k <= len) {
        meshgen.box(b, k, y * 0.5 - 1, 1.5, 0.35, y + 2, 0.35);
        meshgen.box(b, k, y * 0.5 - 1, -1.5, 0.35, y + 2, 0.35);
        k += 4;
    }
    // bollards and a lamp post at the end
    meshgen.color(b, 0x2B2F3A);
    meshgen.cylinder(b, len - 0.6, y + 0.15, 1.2, 0.2, 0.2, 0.6, 6, true, true);
    meshgen.cylinder(b, len - 0.6, y + 0.15, -1.2, 0.2, 0.2, 0.6, 6, true, true);
    meshgen.box(b, len - 0.4, y + 2, -1.35, 0.14, 3.6, 0.14);
    meshgen.color(b, 0xFFE38A);
    meshgen.aux(b, 0.9, 0.3, 1, 0);
    meshgen.box(b, len - 0.4, y + 3.9, -1.35, 0.5, 0.6, 0.5);
    meshgen.pop(b);
    // little moored boat
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.push(b, frame(x, 0, z, yaw));
    meshgen.push(b, Mat4.fromTranslation(<f32>(len * 0.7), 0.25, 3.2));
    meshgen.color(b, 0xE9E2D2);
    meshgen.box(b, 0, 0.3, 0, 5, 0.9, 1.9);
    meshgen.color(b, 0x2F6FA0);
    meshgen.box(b, 0, -0.1, 0, 5.1, 0.35, 2.0);
    meshgen.color(b, 0xC23A30);
    meshgen.box(b, -0.6, 1.1, 0, 1.6, 0.9, 1.4);
    meshgen.pop(b);
    meshgen.pop(b);
    meshgen.setPaint(b, col, aux);
}

// wreck's sec(t): half width and sheer (deck) height
let SEC_W: f64 = 0, SEC_H: f64 = 0;
function wreckSec(W: f64, D: f64, t: f64): void {
    let u = t / 0.5;
    SEC_W = W * lmax(0.02, 1 - Math.pow(lmax(0, u), 2.2)) * (u < -0.8 ? 0.85 : 1.0);
    SEC_H = D * (1 + 0.18 * u * u);
}

// An old wooden ketch run aground: hull listing and down by the bow, one
// mast snapped, a tattered sail. (x, z) on the water, yaw along the keel.
export function wreck(b: Builder, x: f64, z: f64, yaw: f64, len: f64, cols: Array<Collider>?): void {
    let col = b.col, aux = b.aux;
    let L = len, W = len * 0.17, D = len * 0.2;
    let v0 = b.vcount, i0 = b.icount;
    meshgen.aux(b, 0, 1, 0, 0);
    let lean = Mat4.fromRotationX(0.42) * Mat4.fromRotationZ(-0.14);
    meshgen.push(b, frame(x, -D * 0.45, z, yaw) * lean);
    // sections along the keel: half width and sheer (deck) height
    let xs: Array<f64> = [0.0, -0.5, -0.32, -0.1, 0.12, 0.32, 0.46, 0.5];
    // profile: (lateral, height) factors, 1-based
    let pu: Array<f64> = [0.0, -1, -0.9, 0, 0.9, 1];
    let pv: Array<f64> = [0.0, 1, 0.35, 0, 0.35, 1];
    let nxs = xs.length - 1, np = pu.length - 1;
    for (let i = 1; i <= nxs - 1; i++) {
        let xa = xs[i] * L, xb = xs[i + 1] * L;
        wreckSec(W, D, xs[i]);
        let wa = SEC_W, ha = SEC_H;
        wreckSec(W, D, xs[i + 1]);
        let wb = SEC_W, hb = SEC_H;
        for (let j = 1; j <= np - 1; j++) {
            meshgen.color(b, j == 1 || j == 4 ? 0x7A5236 : 0x8A5E3E);
            meshgen.flatQuad(b, v3(xa, pv[j] * ha, pu[j] * wa), v3(xb, pv[j] * hb, pu[j] * wb), v3(xb, pv[j + 1] * hb, pu[j + 1] * wb), v3(xa, pv[j + 1] * ha, pu[j + 1] * wa));
        }
        // faded red stripe under the rail
        meshgen.color(b, 0x8E3328);
        meshgen.flatQuad(b, v3(xa, ha * 0.86, -wa * 1.01), v3(xb, hb * 0.86, -wb * 1.01), v3(xb, hb * 0.98, -wb * 1.01), v3(xa, ha * 0.98, -wa * 1.01));
        meshgen.flatQuad(b, v3(xa, ha * 0.98, wa * 1.01), v3(xb, hb * 0.98, wb * 1.01), v3(xb, hb * 0.86, wb * 1.01), v3(xa, ha * 0.86, wa * 1.01));
        // deck planks
        meshgen.color(b, 0xA07A50);
        meshgen.flatQuad(b, v3(xa, ha * 0.94, wa * 0.95), v3(xb, hb * 0.94, wb * 0.95), v3(xb, hb * 0.94, -wb * 0.95), v3(xa, ha * 0.94, -wa * 0.95));
    }
    // transom
    wreckSec(W, D, -0.5);
    let ws = SEC_W, hs = SEC_H;
    meshgen.color(b, 0x7A5236);
    meshgen.flatQuad(b, v3(-0.5 * L, 0, 0), v3(-0.5 * L, hs * 0.35, -ws * 0.9), v3(-0.5 * L, hs, -ws), v3(-0.5 * L, hs, ws));
    meshgen.flatTri(b, -0.5 * L, 0, 0, -0.5 * L, hs, ws, -0.5 * L, hs * 0.35, ws * 0.9);
    // masts: the main one standing, the fore one snapped
    meshgen.color(b, 0x4E3624);
    meshgen.cylinder(b, -0.05 * L, D * 0.9, 0, 0.32, 0.22, L * 0.62, 7, true, true);
    meshgen.cylinder(b, 0.26 * L, D * 0.9, 0, 0.28, 0.24, L * 0.22, 7, true, true);
    meshgen.box(b, -0.05 * L, D * 0.9 + L * 0.45, 0, 0.3, 0.3, W * 3.2);
    meshgen.pop(b);
    meshgen.inkShell(b, v0, i0, 1);
    // a tattered sail hanging off the yard (double sided, no ink)
    meshgen.push(b, frame(x, -D * 0.45, z, yaw) * lean);
    meshgen.aux(b, 0, 0, 0, 0);
    meshgen.color(b, 0xE8DCC0);
    let top = D * 0.9 + L * 0.44;
    let n = 6;
    for (let k = 0; k < n; k++) {
        let kf = <f64>k;
        let za = (kf / <f64>n - 0.5) * W * 2.8;
        let zb = ((kf + 1) / <f64>n - 0.5) * W * 2.8;
        let da = L * (0.18 + 0.12 * Math.sin(kf * 2.1));
        let db = L * (0.18 + 0.12 * Math.sin((kf + 1) * 2.1));
        let xo = -0.05 * L + 0.2;
        meshgen.flatQuad(b, v3(xo, top, za), v3(xo, top, zb), v3(xo + 0.8, top - db, zb), v3(xo + 0.6, top - da, za));
        meshgen.flatQuad(b, v3(xo + 0.6, top - da, za), v3(xo + 0.8, top - db, zb), v3(xo, top, zb), v3(xo, top, za));
    }
    meshgen.pop(b);
    // foam lapping around the hull
    meshgen.aux(b, 0, 0, 1, 0.25);
    meshgen.color(b, 0xF4FAFF);
    let cyw = cosL(yaw), syw = sinL(yaw);
    for (let k = 0; k <= 13; k++) {
        let a0 = <f64>k / 14 * TAU, a1 = <f64>(k + 1) / 14 * TAU;
        // ring(a, rr): the hull's waterline ellipse, world
        let lxa = Math.cos(a0) * L * 0.55, lza = Math.sin(a0) * W * 1.7;
        let lxb = Math.cos(a1) * L * 0.55, lzb = Math.sin(a1) * W * 1.7;
        let ax = x + lxa * cyw - lza * syw, az = z + lxa * syw + lza * cyw;
        let bx = x + lxb * cyw - lzb * syw, bz = z + lxb * syw + lzb * cyw;
        let lxc = Math.cos(a1) * L * 0.55 * 1.18, lzc = Math.sin(a1) * W * 1.7 * 1.18;
        let lxd = Math.cos(a0) * L * 0.55 * 1.18, lzd = Math.sin(a0) * W * 1.7 * 1.18;
        let cx = x + lxc * cyw - lzc * syw, cz = z + lxc * syw + lzc * cyw;
        let dx = x + lxd * cyw - lzd * syw, dz = z + lxd * syw + lzd * cyw;
        if (k % 3 != 1) {
            meshgen.flatQuad(b, v3(ax, 0.07, az), v3(dx, 0.07, dz), v3(cx, 0.07, cz), v3(bx, 0.07, bz));
        }
    }
    meshgen.setPaint(b, col, aux);
    if (cols != null) {
        cols.push(coll.yawBox(x, D * 0.3, z, yaw, L * 0.5, D * 0.9, W * 1.1));
        cols.push(coll.cylinder(x - cyw * 0.05 * L, z - syw * 0.05 * L, 1.2, -2, D + L * 0.6));
    }
}

// Navigation buoy bobbing at the waterline (static).
export function buoy(b: Builder, x: f64, z: f64, red: bool): void {
    let col = b.col, aux = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.color(b, red ? 0xD8342C : 0x2F8F5A);
    meshgen.cylinder(b, x, -0.4, z, 0.9, 1.1, 1.3, 10, true, true);
    meshgen.color(b, 0xF6F1E6);
    meshgen.cylinder(b, x, 0.9, z, 0.7, 0.5, 0.5, 10, false, true);
    meshgen.color(b, red ? 0xD8342C : 0x2F8F5A);
    meshgen.cylinder(b, x, 1.4, z, 0.5, 0.05, 1.3, 10, true, true);
    meshgen.color(b, 0xFFE38A);
    meshgen.aux(b, 0.9, 0.3, 1, 0);
    meshgen.sphere(b, x, 2.8, z, 0.22, 0.22, 0.22, 6, 4, false);
    meshgen.setPaint(b, col, aux);
}

// Sky portal: cream/gold rim with clamps, surrounded by floating rocks. ------

export class RingSpec {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    fx: f64 = 0; // ring axis (rail forward, horizontal unit)
    fz: f64 = 0;
    radius: f64 = 0;
    rim: f64 = 0; // rim radial thickness
    depth: f64 = 0; // rim depth along the axis
    seed: f64 = 0;
    rimColors: Array<f64> = [0.0]; // outer, inner face, clamp, clamp dark (1-based)
    rocks: f64 = 0;
    rockStyle: Style = geo.COAST;
    shards: bool = false; // Luau `if shards`
}

export type BakeStep = (b: Builder, cols: Array<Collider>?) => void;

// The ring's bake state (the Luau closures' shared upvalues).
export class PortalRing {
    sp: RingSpec;
    r: Rng;
    col: u32 = 0;
    aux: u32 = 0;
    rx: f64;
    rz: f64;
    seg: i32 = 64;
    R: f64;
    T: f64;
    D: f64;
    csU: Array<f64> = [0.0]; // cross-section u (radial outward from R), 1-based
    csV: Array<f64> = [0.0]; // cross-section v (along the axis)
    rv0: i32 = 0;
    ri0: i32 = 0;
    third: f64;
    PX: f64 = 0;
    PY: f64 = 0;
    PZ: f64 = 0;

    constructor(sp: RingSpec) {
        this.sp = sp;
        this.r = mathx.rng(sp.seed);
        this.rx = -sp.fz; // ring plane horizontal axis (right)
        this.rz = sp.fx;
        this.R = sp.radius;
        let T = sp.rim;
        let D = sp.depth * 0.5;
        this.T = T;
        this.D = D;
        // cross-section, rounded rectangle
        let u: Array<f64> = [0, 0, T * 0.2, T * 0.58, T * 0.82, T, T, T * 0.82, T * 0.58, T * 0.2];
        let v: Array<f64> = [-D * 0.7, D * 0.7, D, D, D, D * 0.6, -D * 0.6, -D, -D, -D];
        for (let i = 0; i < u.length; i++) {
            this.csU.push(u[i]);
            this.csV.push(v[i]);
        }
        this.third = Math.ceil(sp.rocks / 3);
    }

    P(a: f64, u: f64, v: f64): void {
        let sp = this.sp;
        let ca = Math.cos(a), sa = Math.sin(a);
        let rr = this.R + u;
        this.PX = sp.x + this.rx * ca * rr + sp.fx * v;
        this.PY = sp.y + sa * rr;
        this.PZ = sp.z + this.rz * ca * rr + sp.fz * v;
    }

    rimPart(b: Builder, kA: i32, kB: i32): void {
        let sp = this.sp;
        let T = this.T, rx = this.rx, rz = this.rz;
        let cs = this.csU.length - 1;
        let segf = <f64>this.seg;
        for (let k = kA; k < kB; k++) {
            let a0 = <f64>k / segf * TAU, a1 = <f64>(k + 1) / segf * TAU;
            for (let m = 1; m <= cs; m++) {
                let m2 = (m % cs) + 1;
                let ua = this.csU[m], va = this.csV[m];
                let ub = this.csU[m2], vb = this.csV[m2];
                // facing: outward from the cross-section center
                let cu = T * 0.5, cv = 0.0;
                let hu = (ua + ub) * 0.5 - cu, hv = (va + vb) * 0.5 - cv;
                let am = (a0 + a1) * 0.5;
                let hx = rx * Math.cos(am) * hu + sp.fx * hv;
                let hy = Math.sin(am) * hu;
                let hz = rz * Math.cos(am) * hu + sp.fz * hv;
                let inner = m == 1;
                let front = Math.abs(hv) > Math.abs(hu) * 0.8;
                let outerBand = lmin(ua, ub) >= T * 0.55;
                if (inner) {
                    meshgen.color(b, sp.rimColors[2]);
                    meshgen.aux(b, 0.12, 1, 0, 0.5);
                } else if (front && !outerBand) {
                    meshgen.color(b, sp.rimColors[2]);
                    meshgen.aux(b, 0.0, 1, 0, 0.5);
                } else {
                    meshgen.color(b, sp.rimColors[1]);
                    meshgen.aux(b, 0.0, 1, 0, 0.7);
                }
                this.P(a0, ua, va);
                let ax = this.PX, ay = this.PY, az = this.PZ;
                this.P(a0, ub, vb);
                let bx = this.PX, by = this.PY, bz = this.PZ;
                this.P(a1, ub, vb);
                let cx = this.PX, cy = this.PY, cz = this.PZ;
                this.P(a1, ua, va);
                let dx = this.PX, dy = this.PY, dz = this.PZ;
                geo.quadH(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, hx, hy, hz);
            }
        }
    }

    rimA(b: Builder, cols: Array<Collider>?): void {
        this.col = b.col;
        this.aux = b.aux;
        this.rv0 = b.vcount;
        this.ri0 = b.icount;
        this.rimPart(b, 0, this.seg / 2);
    }

    rimB(b: Builder, cols: Array<Collider>?): void {
        let sp = this.sp;
        let T = this.T, D = this.D, R = this.R;
        this.rimPart(b, this.seg / 2, this.seg);
        // clamps: chunky blocks straddling the rim
        let nClamp = 8;
        for (let k = 0; k < nClamp; k++) {
            let a = (<f64>k + 0.5) / <f64>nClamp * TAU;
            let ca = Math.cos(a), sa = Math.sin(a);
            let cxw = sp.x + this.rx * ca * (R + T * 0.5);
            let cyw = sp.y + sa * (R + T * 0.5);
            let czw = sp.z + this.rz * ca * (R + T * 0.5);
            // basis: radial, tangent, axis
            let radial = v3(this.rx * ca, sa, this.rz * ca);
            let axis = v3(sp.fx, 0, sp.fz);
            let tangent = mathx.cross(radial, axis);
            let m = Mat4.values(
                tangent.x, tangent.y, tangent.z, 0,
                radial.x, radial.y, radial.z, 0,
                axis.x, axis.y, axis.z, 0,
                <f32>cxw, <f32>cyw, <f32>czw, 1
            );
            meshgen.push(b, m);
            meshgen.aux(b, 0, 1, 0, 0.4);
            meshgen.color(b, sp.rimColors[3]);
            meshgen.box(b, 0, 0, 0, T * 1.5, T * 1.6, D * 2.7);
            meshgen.color(b, sp.rimColors[4]);
            meshgen.box(b, 0, T * 0.5, 0, T * 1.1, T * 0.9, D * 2.9);
            meshgen.pop(b);
        }
        meshgen.inkShell(b, this.rv0, this.ri0, 1);
    }

    // floating rocks kA..kB in a loose disc around the rim
    rocks(b: Builder, cols: Array<Collider>?, kA: f64, kB: f64): void {
        let sp = this.sp;
        let r = this.r;
        let T = this.T, D = this.D, R = this.R;
        let st = sp.rockStyle;
        let nr = <f64>(st.rock.length - 1);
        meshgen.aux(b, 0, 1, 0, 0);
        let k1 = lmin(kB, sp.rocks);
        for (let k = kA; k <= k1; k++) {
            let a = rand(r) * TAU;
            let d = R + T + randRange(r, 3, R * 0.45);
            let s = randRange(r, 1.2, 4.2) * (R / 55);
            let v = randRange(r, -D * 3, D * 3);
            let ca = Math.cos(a), sa = Math.sin(a);
            let px = sp.x + this.rx * ca * d + sp.fx * v;
            let py = sp.y + sa * d;
            let pz = sp.z + this.rz * ca * d + sp.fz * v;
            let vv0 = b.vcount, ii0 = b.icount;
            meshgen.color(b, st.rock[<i32>mod(k, nr) + 1]);
            meshgen.rock(b, px, py, pz, s, s * randRange(r, 0.6, 0.9), s * randRange(r, 0.7, 1.1), rand(r) * 100, 7, 5);
            if (rand(r) < 0.5) {
                meshgen.color(b, st.cap[1]);
                meshgen.rock(b, px, py + s * 0.55, pz, s * 0.8, s * 0.25, s * 0.8, rand(r) * 100, 7, 4);
            }
            meshgen.inkShell(b, vv0, ii0, 1);
            if (cols != null) {
                cols.push(coll.sphere(px, py, pz, s * 0.8));
            }
        }
    }

    shards(b: Builder, cols: Array<Collider>?): void {
        let sp = this.sp;
        let r = this.r;
        let T = this.T, D = this.D, R = this.R;
        let st = sp.rockStyle;
        // crystal shards radiating outward (the Eye)
        if (sp.shards) {
            let nS = 28;
            for (let k = 0; k < nS; k++) {
                let a = (<f64>k + randRange(r, -0.25, 0.25)) / <f64>nS * TAU;
                let ca = Math.cos(a), sa = Math.sin(a);
                let len = R * randRange(r, 0.28, 0.6);
                let wid = R * randRange(r, 0.05, 0.09);
                let baseR = R + T * 0.7;
                let radial = v3(this.rx * ca, sa, this.rz * ca);
                let axis = v3(sp.fx, 0, sp.fz);
                let tangent = mathx.cross(radial, axis);
                let rdx = <f64>radial.x, rdy = <f64>radial.y, rdz = <f64>radial.z;
                let bx = sp.x + rdx * baseR;
                let by = sp.y + rdy * baseR;
                let bz = sp.z + rdz * baseR;
                let tipx = bx + rdx * len, tipy = by + rdy * len, tipz = bz + rdz * len;
                let tw = randRange(r, -0.3, 0.3);
                let tv = tangent * <f32>Math.cos(tw) + axis * <f32>Math.sin(tw);
                let av = mathx.cross(radial, tv);
                let corners: Array<Vector> = [Vector.xyz(0, 0, 0)];
                for (let q = 0; q <= 3; q++) {
                    let qa = <f64>q / 4 * TAU + 0.4;
                    let o = tv * <f32>(Math.cos(qa) * wid) + av * <f32>(Math.sin(qa) * wid * 0.7);
                    corners.push(v3(bx + <f64>o.x, by + <f64>o.y, bz + <f64>o.z));
                }
                let vv0 = b.vcount, ii0 = b.icount;
                meshgen.aux(b, 0.12, 1, 0, 0.7);
                for (let q = 1; q <= 4; q++) {
                    let c1 = corners[q];
                    let c2 = corners[(q % 4) + 1];
                    let mid = (c1 + c2) * <f32>0.5;
                    let hx = <f64>mid.x - bx, hy = <f64>mid.y - by, hz = <f64>mid.z - bz;
                    meshgen.color(b, q % 2 == 0 ? st.rock[1] : st.cap[1]);
                    meshgen.flatTriFacing(b, c1.x, c1.y, c1.z, c2.x, c2.y, c2.z, tipx, tipy, tipz, hx, hy, hz);
                }
                meshgen.color(b, st.rock[2]);
                let k1 = corners[1], k2 = corners[2], k3 = corners[3], k4 = corners[4];
                meshgen.flatTriFacing(b, k1.x, k1.y, k1.z, k2.x, k2.y, k2.z, k3.x, k3.y, k3.z, -rdx, -rdy, -rdz);
                meshgen.flatTriFacing(b, k1.x, k1.y, k1.z, k3.x, k3.y, k3.z, k4.x, k4.y, k4.z, -rdx, -rdy, -rdz);
                meshgen.inkShell(b, vv0, ii0, 1);
            }
        }
        // rim colliders: boxes around the circle
        if (cols != null) {
            let n = 24;
            for (let k = 0; k < n; k++) {
                let a = (<f64>k + 0.5) / <f64>n * TAU;
                let ca = Math.cos(a), sa = Math.sin(a);
                let radial = v3(this.rx * ca, sa, this.rz * ca);
                let axis = v3(sp.fx, 0, sp.fz);
                let tangent = mathx.cross(radial, axis);
                let c = v3(sp.x, sp.y, sp.z) + radial * <f32>(R + T * 0.5);
                cols.push(coll.box(c.x, c.y, c.z, tangent, radial, axis, (R + T) * Math.PI / <f64>n + 0.5, T * 0.5, D));
            }
        }
        meshgen.setPaint(b, this.col, this.aux);
    }
}

// The ring in six bake steps (rim halves + clamps, rocks in thirds, shards +
// colliders): call them in order on one builder, nothing emitted in
// between. 0-based (steps[0] .. steps[PORTAL_RING_STEPS - 1]).
export function portalRingSteps(sp: RingSpec): Array<BakeStep> {
    let pr = new PortalRing(sp);
    let third = pr.third;
    let out: Array<BakeStep> = [];
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.rimA(b, cols);
    });
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.rimB(b, cols);
    });
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.rocks(b, cols, 1, third);
    });
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.rocks(b, cols, third + 1, third * 2);
    });
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.rocks(b, cols, third * 2 + 1, pr.sp.rocks);
    });
    out.push((b: Builder, cols: Array<Collider>?): void => {
        pr.shards(b, cols);
    });
    return out;
}
export const PORTAL_RING_STEPS: i32 = 6;

export function portalRing(b: Builder, sp: RingSpec, cols: Array<Collider>?): void {
    let steps = portalRingSteps(sp);
    for (let i = 0; i < steps.length; i++) {
        steps[i](b, cols);
    }
}

// Flight school barge (the launch hover out at sea): a navy pontoon with a
// cream boot stripe and crimson sheer, a crimson gunwale round a cream deck
// (deck 0.75 m), a cream / crimson rail on three sides (open at the bow,
// top BARGE_TOP), a crimson / cream roundel with a launch chevron, bollards,
// life rings, fenders, lamps and foam lace. The windsock mast on the bow
// corner (starboard) is the only thing over BARGE_TOP: the launch and
// briefing cameras sit off the stern, so it stays clear of the lens. yaw:
// local +x (the bow) -> (cos, sin). No collider: the pilot hovers over it.
export const BARGE_DECK: f64 = 0.75;
export const BARGE_TOP: f64 = 1.2;

// schoolBarge's disc: a top-only fan
function disc(b: Builder, r: f64, y: f64, seg: i32): void {
    for (let k = 0; k < seg; k++) {
        let a0 = <f64>k / <f64>seg * TAU, a1 = <f64>(k + 1) / <f64>seg * TAU;
        meshgen.flatTriFacing(b, 0, y, 0, Math.cos(a0) * r, y, Math.sin(a0) * r, Math.cos(a1) * r, y, Math.sin(a1) * r, 0, 1, 0);
    }
}

export function schoolBarge(b: Builder, x: f64, z: f64, yaw: f64): void {
    let col = b.col, aux = b.aux;
    let L = 14.0, W = 10.0;
    let hl = L * 0.5, hw = W * 0.5;
    let DECK = BARGE_DECK, TOP = BARGE_TOP;
    let CRIMSON = 0xD8342C, CREAM = 0xF6F1E6, NAVY = 0x2B3550, INK = 0x1E2436;
    let HT = 0.5; // pontoon top
    let GT = 0.9; // gunwale top
    meshgen.push(b, frame(x, 0, z, yaw));
    let v0 = b.vcount, i0 = b.icount;
    meshgen.aux(b, 0, 1, 0, 0);
    // pontoon (drawn to the bow and stern in a shallow wedge)
    meshgen.color(b, NAVY);
    meshgen.box(b, 0, (HT - 1.0) * 0.5, 0, L - 1.2, HT + 1.0, W);
    for (let q = 0; q < 2; q++) {
        let e = q == 0 ? 1.0 : -1.0;
        let xa = e * (hl - 0.6), xb = e * (hl + 0.3);
        meshgen.flatQuad(b, v3(xa, HT, hw * e), v3(xb, HT, (hw - 0.6) * e), v3(xb, HT, -(hw - 0.6) * e), v3(xa, HT, -hw * e));
        meshgen.flatQuad(b, v3(xa, -1.0, hw * e), v3(xa, -1.0, -hw * e), v3(xb, HT, -(hw - 0.6) * e), v3(xb, HT, (hw - 0.6) * e));
        meshgen.flatTri(b, xa, HT, hw * e, xa, -1.0, hw * e, xb, HT, (hw - 0.6) * e);
        meshgen.flatTri(b, xa, HT, -hw * e, xb, HT, -(hw - 0.6) * e, xa, -1.0, -hw * e);
    }
    // trim: cream boot stripe, crimson sheer band
    meshgen.color(b, CREAM);
    meshgen.box(b, 0, 0.1, 0, L - 1.18, 0.16, W + 0.04);
    meshgen.color(b, CRIMSON);
    meshgen.box(b, 0, HT - 0.07, 0, L - 1.18, 0.14, W + 0.04);
    // deck and gunwale
    meshgen.color(b, CREAM);
    meshgen.box(b, 0, (HT + DECK) * 0.5, 0, L - 1.4, DECK - HT, W - 0.6);
    meshgen.color(b, CRIMSON);
    let gh = GT - HT + 0.05, gy = (GT + HT - 0.05) * 0.5;
    meshgen.box(b, 0, gy, hw - 0.2, L - 1.2, gh, 0.4);
    meshgen.box(b, 0, gy, -(hw - 0.2), L - 1.2, gh, 0.4);
    meshgen.box(b, hl - 0.8, gy, 0, 0.4, gh, W - 0.8);
    meshgen.box(b, -(hl - 0.8), gy, 0, 0.4, gh, W - 0.8);
    meshgen.pop(b);
    meshgen.inkShell(b, v0, i0, 1);
    meshgen.push(b, frame(x, 0, z, yaw));
    // rail: cream stanchions, crimson top rail (sides and stern; the bow open)
    let RH = 0.07;
    let rx0 = -(hl - 0.8), rx1 = hl - 1.6;
    meshgen.color(b, CREAM);
    for (let k = 0; k <= 7; k++) {
        let px = rx0 + (rx1 - rx0) * <f64>k / 7;
        meshgen.box(b, px, (GT + TOP) * 0.5, hw - 0.2, 0.08, TOP - GT, 0.08);
        meshgen.box(b, px, (GT + TOP) * 0.5, -(hw - 0.2), 0.08, TOP - GT, 0.08);
    }
    for (let k = 1; k <= 4; k++) {
        let pz = -(hw - 0.2) + (W - 0.4) * <f64>k / 5;
        meshgen.box(b, rx0, (GT + TOP) * 0.5, pz, 0.08, TOP - GT, 0.08);
    }
    meshgen.color(b, CRIMSON);
    meshgen.box(b, (rx0 + rx1) * 0.5, TOP - RH * 0.5, hw - 0.2, rx1 - rx0 + 0.1, RH, 0.1);
    meshgen.box(b, (rx0 + rx1) * 0.5, TOP - RH * 0.5, -(hw - 0.2), rx1 - rx0 + 0.1, RH, 0.1);
    meshgen.box(b, rx0, TOP - RH * 0.5, 0, 0.1, RH, W - 0.3);
    // roundel, launch chevron and deck dashes (paint on the deck)
    // (top-only fans stacked a few mm apart: paint, no side walls)
    meshgen.color(b, CRIMSON);
    disc(b, 3.4, DECK + 0.01, 36);
    meshgen.color(b, CREAM);
    disc(b, 2.6, DECK + 0.02, 36);
    meshgen.color(b, NAVY);
    disc(b, 2.15, DECK + 0.03, 32);
    meshgen.color(b, CREAM);
    disc(b, 1.95, DECK + 0.04, 32);
    meshgen.color(b, CRIMSON);
    disc(b, 1.2, DECK + 0.05, 24);
    meshgen.aux(b, 0, 0, 0, 0);
    for (let q = 0; q <= 3; q++) {
        let a = <f64>q * Math.PI * 0.5;
        meshgen.box(b, Math.cos(a) * 3.85, DECK + 0.01, Math.sin(a) * 3.85, q % 2 == 0 ? 0.9 : 0.3, 0.03, q % 2 == 0 ? 0.3 : 0.9);
    }
    // launch chevron pointing at the bow
    let cyv = DECK + 0.02;
    for (let q = 0; q < 2; q++) {
        let e = q == 0 ? 1.0 : -1.0;
        let ax = 5.7, az = 0.0, bx2 = 4.3, bz2 = e * 1.3;
        let cx2 = 3.8, cz2 = e * 1.3, dx2 = 5.2, dz2 = 0.0;
        meshgen.flatTriFacing(b, ax, cyv, az, bx2, cyv, bz2, cx2, cyv, cz2, 0, 1, 0);
        meshgen.flatTriFacing(b, ax, cyv, az, cx2, cyv, cz2, dx2, cyv, dz2, 0, 1, 0);
    }
    meshgen.color(b, NAVY);
    for (let k = -2; k <= 2; k++) {
        meshgen.box(b, <f64>k * 2.2, DECK + 0.01, hw - 1.1, 1.1, 0.03, 0.35);
        meshgen.box(b, <f64>k * 2.2, DECK + 0.01, -(hw - 1.1), 1.1, 0.03, 0.35);
    }
    // bollards (navy posts, cream caps)
    meshgen.aux(b, 0, 1, 0, 0);
    let bq: Array<f64> = [1, -1, -1, -1, -1, 1];
    for (let q = 0; q < 3; q++) {
        let bx = bq[q * 2] * (hl - 1.7), bz = bq[q * 2 + 1] * (hw - 1.0);
        meshgen.color(b, NAVY);
        meshgen.cylinder(b, bx, DECK, bz, 0.2, 0.17, 0.26, 8, false, true);
        meshgen.color(b, CREAM);
        meshgen.cylinder(b, bx, DECK + 0.26, bz, 0.27, 0.24, 0.08, 8, true, true);
    }
    // life rings on the hull sides, black fenders between them
    let ringX: Array<f64> = [-3.6, 3.0];
    let fendX: Array<f64> = [-5.4, -0.3, 5.0];
    for (let q = 0; q < 2; q++) {
        let e = q == 0 ? 1.0 : -1.0;
        for (let p = 0; p < 2; p++) {
            let px = ringX[p];
            meshgen.color(b, px > 0 ? CRIMSON : CREAM);
            meshgen.push(b, Mat4.fromTranslation(<f32>px, 0.05, <f32>(e * (hw + 0.13))));
            meshgen.torus(b, 0.42, 0.11, 12, 5);
            meshgen.pop(b);
        }
        meshgen.color(b, INK);
        for (let p = 0; p < 3; p++) {
            meshgen.cylinder(b, fendX[p], -0.45, e * (hw + 0.2), 0.24, 0.24, 0.7, 8, true, true);
        }
    }
    // lamps along the bow, two at the stern
    meshgen.color(b, 0xFFE38A);
    meshgen.aux(b, 0.9, 0.3, 1, 0);
    for (let k = -1; k <= 1; k++) {
        meshgen.box(b, hl - 0.85, GT + 0.07, <f64>k * 2.6, 0.3, 0.14, 0.3);
    }
    meshgen.color(b, 0xFF7A5C);
    for (let q = 0; q < 2; q++) {
        let e = q == 0 ? 1.0 : -1.0;
        meshgen.box(b, -(hl - 0.8), GT + 0.07, e * 2.2, 0.3, 0.14, 0.3);
    }
    // windsock on the bow corner, streaming outboard (seen side on)
    meshgen.aux(b, 0, 1, 0, 0);
    let mx = hl - 0.8, mz = hw - 0.2; // on the gunwale corner
    meshgen.color(b, NAVY);
    meshgen.cylinder(b, mx, GT, mz, 0.24, 0.22, 0.12, 8, true, true);
    // tall enough that the sock flies over the pilot's head in every launch shot
    let MH = 5.6;
    for (let k = 0; k <= 5; k++) {
        let kf = <f64>k;
        meshgen.color(b, k % 2 == 0 ? CREAM : CRIMSON);
        meshgen.cylinder(b, mx, GT + 0.12 + kf * (MH / 6), mz, 0.1 - kf * 0.006, 0.094 - kf * 0.006, MH / 6, 8, k == 5, true);
    }
    meshgen.color(b, NAVY);
    meshgen.sphere(b, mx, GT + 0.12 + MH + 0.05, mz, 0.1, 0.1, 0.1, 6, 4, false);
    let rad100 = 100 * (Math.PI / 180);
    meshgen.push(b, frame(mx, GT + MH - 0.15, mz, rad100) * Mat4.fromRotationZ(<f32>(-rad100)));
    meshgen.color(b, NAVY);
    meshgen.push(b, Mat4.fromTranslation(0, 0.12, 0) * Mat4.fromRotationX(<f32>(Math.PI * 0.5)));
    meshgen.torus(b, 0.46, 0.035, 14, 4);
    meshgen.pop(b);
    let n = 5;
    for (let k = 0; k < n; k++) {
        let kf = <f64>k;
        let ra = 0.46 - 0.05 * kf;
        meshgen.color(b, k % 2 == 0 ? CRIMSON : CREAM);
        meshgen.cylinder(b, 0, 0.12 + kf * 0.5, 0, ra, ra - 0.05, 0.5, 12, k == n - 1, true);
    }
    meshgen.pop(b);
    meshgen.pop(b);
    // foam lace round the hull
    let xs: Array<f64> = [0.0], zs: Array<f64> = [0.0];
    let cy = cosL(yaw), sy = sinL(yaw);
    for (let k = 0; k <= 31; k++) {
        let a = <f64>k / 32 * TAU;
        let ca = Math.cos(a), sa = Math.sin(a);
        // rounded rectangle (superellipse) just outside the hull
        let lx = (hl + 0.4) * mathx.sign(ca) * Math.pow(Math.abs(ca), 0.35);
        let lz = (hw + 0.2) * mathx.sign(sa) * Math.pow(Math.abs(sa), 0.35);
        xs.push(x + lx * cy - lz * sy);
        zs.push(z + lx * sy + lz * cy);
    }
    meshgen.color(b, 0xF4FAFF);
    meshgen.aux(b, 0, 0, 1, 0.25);
    meshgen.laceRing(b, mathx.rng(4513), xs, zs, x, z, 1.1, 0.1, 0.4);
    meshgen.setPaint(b, col, aux);
}
