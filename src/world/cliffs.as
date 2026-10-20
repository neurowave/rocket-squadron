// Port of src/world/cliffs.luau (the recipes the game bakes: headland,
// skerry, island, lump / towerSteps, rockArchSteps, ridge; and, with no
// caller in the game, groundAt, blocks, blockArch and wall at the end).
//
// Port rules: Luau sequences stay 1-based (slot 0 a dummy); optional spec
// numbers are NaN ("nil") with the default taken by a ternary where the
// default has side effects (RNG draws); closures that carry state become
// classes (HeightFn, HeadCap, TowerBaker, ArchBaker); multi-returns go
// through module globals. wall's `rail` returns a RailPt (Luau's two
// returns).
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import { Rng, rand, randRange, smoothstep, saturate, TAU } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as coll from "./collide";
import { Collider, TopFn } from "./collide";
import { HUGE, lmin, lmax, lclamp, mod, imod, opt } from "../lib/compat";

function seq(a: Array<f64>): Array<f64> {
    let out: Array<f64> = [0.0];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

export class Look {
    strata: Array<f64>; // 1-based
    weights: Array<f64>;
    wet: f64;
    crack: f64;
    grass: Array<f64>;
    drape: f64;
    shrub: f64;
    lichen: f64;
    boulder: f64;
    foam: f64;
    constructor(strata: Array<f64>, weights: Array<f64>, wet: f64, crack: f64, grass: Array<f64>, drape: f64, shrub: f64, lichen: f64, boulder: f64, foam: f64) {
        this.strata = seq(strata);
        this.weights = seq(weights);
        this.wet = wet;
        this.crack = crack;
        this.grass = seq(grass);
        this.drape = drape;
        this.shrub = shrub;
        this.lichen = lichen;
        this.boulder = boulder;
        this.foam = foam;
    }
}

export const COAST = new Look([0x5A7792, 0x4F6B86, 0x445F79, 0x66819C], [0.34, 0.32, 0.2, 0.14], 0x2F3D4E, 0x28354A,
    [0x9C8628, 0x857526, 0xA89232, 0x927E27], 0x8E7D2A, 0x7A7A32, 0x7E8A6E, 0x4B5E72, 0xF4FAFF);
export const COAST_WARM = new Look([0x6A849E, 0x5C7690, 0x4E6882, 0x7A8C9C], [0.36, 0.32, 0.22, 0.1], 0x2F3D4E, 0x28354A,
    [0x9C8628, 0x857526, 0xA89232, 0x927E27], 0x8E7D2A, 0x7A7A32, 0x8A906A, 0x506478, 0xF4FAFF);
export const COAST_BARE = new Look([0x6C8599, 0x61798E, 0x566E84, 0x7D92A4], [0.3, 0.34, 0.26, 0.1], 0x3E4B5A, 0x3A4655,
    [0x98A4AC, 0x8E9AA3, 0xA3AEB5, 0x8A96A0], 0x84909A, 0x7A8660, 0xA09A68, 0x4E5B68, 0xF4FAFF);
export const COAST_FAR = new Look([0x7F98AE, 0x7690A8, 0x86A0B5, 0x7A93AA], [0.3, 0.3, 0.2, 0.2], 0x5E7890, 0x6A8298,
    [0xA99E58, 0x9E955A, 0xB3A762, 0xA49A58], 0x9D945A, 0x8C8C5E, 0x8E9A8E, 0x6E88A0, 0xF4FAFF);
export const VIOLET = new Look([0x9058C8, 0x7E4CBC, 0x6A40AA, 0x9C64D2], [0.34, 0.34, 0.2, 0.12], 0x33206E, 0x2E1C6A,
    [0xC6F5FC, 0xA9EAF8, 0xE6FCFF, 0xB4EEF9], 0xA4E6F6, 0x8ED8F0, 0x9C7FE2, 0x5A3CA2, 0xF0FEFF);
export const VIOLET_FAR = new Look([0x7E6CCB, 0x7564C2, 0x8574D2, 0x7A68C8], [0.3, 0.3, 0.2, 0.2], 0x5C4CAE, 0x5C4CAE,
    [0xB6E4F6, 0xA6DCF2, 0xC6ECF8, 0xAEE0F4], 0xA0D6EE, 0x9CC8EA, 0x8878D4, 0x6A5ABA, 0xF0FEFF);

function pickTone(r: Rng, look: Look): f64 {
    let x = rand(r);
    let acc = 0.0;
    let w = look.weights;
    for (let i = 1; i < w.length; i++) {
        acc += w[i];
        if (x <= acc) return look.strata[i];
    }
    return look.strata[1];
}

// Strata: a tone per row, thick bands (1-based).
function strataRows(r: Rng, look: Look, n: i32): Array<f64> {
    let out: Array<f64> = [0.0];
    let cur = pickTone(r, look);
    for (let i = 1; i <= n; i++) {
        if (i > 1 && rand(r) > 0.42) {
            let nxt = pickTone(r, look);
            let guard = 0;
            while (nxt == cur && guard < 4) {
                nxt = pickTone(r, look);
                guard += 1;
            }
            cur = nxt;
        }
        out[i] = cur;
    }
    return out;
}

@inline function quad(
    b: Builder,
    ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64,
    dx: f64, dy: f64, dz: f64,
    hx: f64, hy: f64, hz: f64
): void {
    meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, hx, hy, hz);
}

// Thin dark crack zig-zagging down a face along a column of points (rows j0..j1).
function crackStrip(b: Builder, r: Rng, xs: Array<f64>, ys: Array<f64>, zs: Array<f64>, j0: i32, j1: i32, hx: f64, hz: f64, width: f64, hex: f64): void {
    if (j1 <= j0) return;
    meshgen.color(b, hex);
    let tx = -hz, tz = hx;
    let off: Array<f64> = [];
    let wd: Array<f64> = [];
    for (let j = j0; j <= j1; j++) {
        let t = <f64>(j - j0) / <f64>(j1 - j0);
        off[j] = randRange(r, -0.5, 0.5) * width * 1.6;
        wd[j] = width * (0.25 + 0.75 * Math.pow(Math.sin(Math.PI * t), 0.6));
    }
    for (let j = j0; j < j1; j++) {
        let ax = xs[j] + tx * off[j] + hx * 0.12, ay = ys[j], az = zs[j] + tz * off[j] + hz * 0.12;
        let bx = xs[j + 1] + tx * off[j + 1] + hx * 0.12, by = ys[j + 1], bz = zs[j + 1] + tz * off[j + 1] + hz * 0.12;
        let wa = wd[j], wb = wd[j + 1];
        quad(b, ax - tx * wa, ay, az - tz * wa, ax + tx * wa, ay, az + tz * wa, bx + tx * wb, by, bz + tz * wb, bx - tx * wb, by, bz - tz * wb, hx, 0, hz);
    }
}

// Broken foam lace on the water around a closed ring of waterline points.
export function foamRing(b: Builder, r: Rng, xs: Array<f64>, zs: Array<f64>, cx: f64, cz: f64, width: f64, hex: f64): void {
    let col = b.col, aux = b.aux;
    meshgen.color(b, hex);
    meshgen.aux(b, 0, 0, 1, 0.25);
    meshgen.laceRing(b, r, xs, zs, cx, cz, width, 0.12, lmin(0.8, width * 0.6));
    meshgen.setPaint(b, col, aux);
}

// Collider for a meshgen.rock (same points: its meridians as shell columns).
export function rockShell(cx: f64, cy: f64, cz: f64, rx: f64, ry: f64, rz: f64, seed: f64, sg: i32 = 9, rg: i32 = 6): Collider {
    let P: Array<f64> = [0.0];
    for (let i = 0; i < sg; i++) {
        let th = <f64>i / <f64>sg * TAU;
        let prev = -HUGE;
        for (let j = rg; j >= 0; j--) {
            let ph = <f64>j / <f64>rg * Math.PI;
            let x = Math.sin(ph) * Math.cos(th);
            let y = Math.cos(ph);
            let z = Math.sin(ph) * Math.sin(th);
            let n = 0.78 + 0.44 * mathx.hash3(x * 3.1 + seed, y * 2.7 - seed, z * 1.9 + seed * 0.37);
            if (j == 0 || j == rg) n = 0.9;
            prev = lmax(prev, cy + y * ry * n);
            P.push(prev);
            P.push(cx + x * rx * n);
            P.push(cz + z * rz * n);
        }
    }
    return coll.shell(sg, rg + 1, P, false, null);
}

// Faceted boulder (its colliders into `cols` when given). capHex NaN = none.
export function boulder(b: Builder, r: Rng, x: f64, y: f64, z: f64, s: f64, hex: f64, capHex: f64, cols: Array<Collider>?): void {
    meshgen.color(b, hex);
    let ry = s * randRange(r, 0.55, 0.85);
    let rz = s * randRange(r, 0.75, 1.1);
    let sd = rand(r) * 100;
    meshgen.rock(b, x, y, z, s, ry, rz, sd, 7, 5);
    if (cols != null) cols.push(rockShell(x, y, z, s, ry, rz, sd, 7, 5));
    if (!isNaN(capHex) && s > 1.6) {
        meshgen.color(b, capHex);
        let sd2 = rand(r) * 100;
        meshgen.rock(b, x, y + s * 0.5, z, s * 0.72, s * 0.24, s * 0.72, sd2, 7, 3);
        if (cols != null) cols.push(rockShell(x, y + s * 0.5, z, s * 0.72, s * 0.24, s * 0.72, sd2, 7, 3));
    }
}

// Headland ---------------------------------------------------------------------

export class HeadSpec {
    x: f64 = 0;
    z: f64 = 0;
    yaw: f64 = 0;
    rx: f64 = 1;
    rz: f64 = 1;
    h: f64 = 1;
    seed: f64 = 0;
    look: Look = COAST;
    front: f64 = NaN;
    rise: f64 = NaN;
    tip: f64 = NaN;
    skew: f64 = NaN;
    hills: f64 = NaN;
    dome: f64 = NaN;
    cols: f64 = NaN;
    rough: f64 = NaN;
    taper: f64 = NaN;
    lip: f64 = NaN;
    drape: f64 = NaN;
    spurs: f64 = NaN;
    crack: f64 = NaN;
    boulders: f64 = NaN;
    tufts: f64 = NaN;
    foam: bool = true; // Luau: foam ~= false
    ink: f64 = NaN;
    base: f64 = NaN;
    collide: bool = true; // Luau: collide ~= false
    leanX: f64 = NaN;
    leanZ: f64 = NaN;
    rowH: f64 = NaN;
    fracture: f64 = NaN;
    square: f64 = NaN;
    bulge: f64 = NaN;
    under: f64 = NaN;
    tier: f64 = NaN;
    detail: f64 = NaN;
    rim: Array<f64>? = null; // filled with the lip ring (x, y, z per column), 1-based
}

// Top surface height of a headland in its local frame (lx along, lz across).
export class HeightFn {
    base: f64;
    rx: f64;
    rz: f64;
    front: f64;
    rise: f64;
    tip: f64;
    skew: f64;
    hills: f64;
    dome: f64;
    h: f64;
    ph1: f64;
    ph2: f64;
    hf: f64;

    constructor(sp: HeadSpec) {
        let r = mathx.rng(sp.seed * 3 + 11);
        this.base = opt(sp.base, -4);
        this.rx = sp.rx;
        this.rz = sp.rz;
        this.front = opt(sp.front, 0);
        this.rise = opt(sp.rise, 0);
        this.tip = opt(sp.tip, 0);
        this.skew = opt(sp.skew, 0);
        this.hills = opt(sp.hills, 0);
        this.dome = opt(sp.dome, 0);
        this.h = sp.h;
        this.ph1 = rand(r) * 40;
        this.ph2 = rand(r) * 40;
        this.hf = 1 / lmax(14, lmin(sp.rx, sp.rz) * 0.9);
    }

    at(lx: f64, lz: f64): f64 {
        let u = lx / this.rx, v = lz / this.rz;
        let au = lmin(Math.abs(u), 1.25);
        let y = this.h * (1 - this.tip * smoothstep(0.15, 1.15, au) + this.skew * mathx.clamp(u, -1, 1));
        if (this.front != 0) {
            let inland = -v * this.front;
            y += this.rise * Math.pow(saturate((inland + 1) * 0.5), 1.25);
        }
        y += this.dome * (1 - lmin(1, u * u + v * v));
        if (this.hills > 0) {
            y += this.hills * (mathx.fbm2(lx * this.hf + this.ph1, lz * this.hf + this.ph2, 3) / 0.875 - 0.5) * 2;
        }
        return lmax(y, this.base + 1.5);
    }
}

export function heightFn(sp: HeadSpec): HeightFn {
    return new HeightFn(sp);
}

// The collider cap of a headland (Luau capAt).
class HeadCap extends TopFn {
    H: HeightFn;
    sx: f64;
    sz: f64;
    leanX: f64;
    leanZ: f64;
    cyw: f64;
    syw: f64;
    constructor(H: HeightFn, sx: f64, sz: f64, leanX: f64, leanZ: f64, cyw: f64, syw: f64) {
        super();
        this.H = H;
        this.sx = sx;
        this.sz = sz;
        this.leanX = leanX;
        this.leanZ = leanZ;
        this.cyw = cyw;
        this.syw = syw;
    }
    override at(wx: f64, wz: f64): f64 {
        let dx = wx - this.sx - this.leanX, dz = wz - this.sz - this.leanZ;
        return this.H.at(dx * this.cyw + dz * this.syw, -dx * this.syw + dz * this.cyw);
    }
}

// toWorld(ax, az, lean)
@inline function twX(sx: f64, ax: f64, az: f64, cyw: f64, syw: f64, leanX: f64, lean: f64): f64 {
    return sx + ax * cyw - az * syw + leanX * lean;
}
@inline function twZ(sz: f64, ax: f64, az: f64, cyw: f64, syw: f64, leanZ: f64, lean: f64): f64 {
    return sz + ax * syw + az * cyw + leanZ * lean;
}

const RING_F: StaticArray<f64> = [0, 1, 0.8, 0.58, 0.36, 0.15]; // 1-based

// Returns the highest point of the top.
export function headland(b: Builder, sp: HeadSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let look = sp.look;
    let base = opt(sp.base, -4);
    let rooted = base < 0.5;
    let rx = sp.rx, rz = sp.rz;
    let cyw = Math.cos(sp.yaw), syw = Math.sin(sp.yaw);
    let rough = opt(sp.rough, 0.2);
    let taper = opt(sp.taper, 0.08);
    let lip = opt(sp.lip, 0.03);
    let leanX = opt(sp.leanX, 0), leanZ = opt(sp.leanZ, 0);
    let ph1 = rand(r) * 40;
    let ph2 = rand(r) * 40;
    let H = new HeightFn(sp);
    let sx = sp.x, sz0 = sp.z;

    // outline
    let per = Math.PI * (3 * (rx + rz) - Math.sqrt((3 * rx + rz) * (rx + 3 * rz)));
    let n = <i32>(isNaN(sp.cols) ? lclamp(Math.floor(per / 7.5), 9, 44) : sp.cols);
    let nF = <f64>n;
    let lx: Array<f64> = [0.0], lz: Array<f64> = [0.0];
    let spurP = opt(sp.spurs, 0.12);
    let sq = opt(sp.square, 2);
    for (let i = 0; i < n; i++) {
        let a = -(<f64>i + (rand(r) - 0.5) * 0.5) / nF * TAU;
        let ca = Math.cos(a), sa = Math.sin(a);
        let nn = mathx.fbm2(ca * 1.3 + ph1, sa * 1.3 + ph2, 3) / 0.875;
        let k = 1 + rough * (nn - 0.5) * 2.4 + (rand(r) - 0.5) * rough * 0.4;
        if (sq > 2.05) k *= Math.pow(Math.pow(Math.abs(ca), sq) + Math.pow(Math.abs(sa), sq), -1 / sq);
        if (rand(r) < spurP) k *= randRange(r, 1.06, 1.16);
        lx.push(ca * rx * k);
        lz.push(sa * rz * k);
    }
    // fracture: per-column in/out, cracks
    let colJ: Array<f64> = [0.0];
    let colJ2: Array<f64> = [0.0];
    let tierT = opt(sp.tier, 0.5);
    let crack: Array<f64> = [0.0];
    let crackTop: Array<f64> = [0.0];
    let crackP = opt(sp.crack, 0.2);
    let szj = lclamp(lmin(rx, rz) / 22, 0.25, 1.6);
    let fr = opt(sp.fracture, 1);
    let seed = sp.seed;
    for (let i = 1; i <= n; i++) {
        let fi = <f64>i;
        let rad = lmax(Math.sqrt(lx[i] * lx[i] + lz[i] * lz[i]), 1);
        let jag = (i % 2 == 0 ? 1.0 : -1.0) * 0.7 + (mathx.hash(fi * 1.37, seed * 0.013) - 0.5) * 3.2;
        jag += (mathx.noise2(fi * 0.45, seed * 0.07) - 0.5) * 6;
        if (mathx.hash(fi * 0.61, seed * 0.029) > 0.84) jag += 3.5;
        colJ[i] = jag * szj * fr / rad;
        let jag2 = (mathx.hash(fi * 2.71 + 3.3, seed * 0.019) - 0.5) * 3.6 + (mathx.noise2(fi * 0.5 + 9, seed * 0.05) - 0.5) * 5 - 1.2;
        colJ2[i] = jag2 * szj * fr / rad;
        crack[i] = rand(r) < crackP ? randRange(r, 0.04, 0.09) : 0.0;
        crackTop[i] = randRange(r, 0.55, 1.0);
    }

    // rows
    let sTop = 1 - taper;
    let T: Array<f64> = [0.0];
    let dd: Array<f64> = [0.0];
    let avgT = 0.0;
    let drape = opt(sp.drape, 2.6);
    for (let i = 1; i <= n; i++) {
        T[i] = H.at(lx[i] * sTop, lz[i] * sTop);
        avgT += T[i];
        let deep = i % 2 == 0 ? randRange(r, 0.65, 1.25) : randRange(r, 0.15, 0.5);
        dd[i] = lmin(drape * deep, (T[i] - base) * 0.3);
    }
    avgT /= nF;
    let rowH = isNaN(sp.rowH) ? lmax(3.2, (avgT - base) / 7) : sp.rowH;
    let nIntF = lclamp(Math.floor((avgT - base) / rowH + 0.5), 2, 8);
    let nInt = <i32>nIntF;
    let rowJit: Array<f64> = [0.0];
    for (let q = 1; q < nInt; q++) rowJit[q] = randRange(r, -0.22, 0.22) / nIntF;
    let tones = strataRows(r, look, nInt + 1);
    let ntones = tones.length - 1;
    let wl = rooted ? 0.9 : base + lmin(1.2, (avgT - base) * 0.15);
    let det = opt(sp.detail, 0);
    let rowOff: Array<f64> = [];
    let stepQ: Array<bool> = [];
    let jKind: Array<i32> = [0];
    let jRow: Array<i32> = [0];
    let tideH = 0.0;
    if (det > 0) {
        let amp = lclamp(lmin(rx, rz) * 0.07, 0.25, 0.7) * det;
        rowOff[0] = 0;
        for (let q = 1; q < nInt; q++) {
            rowOff[q] = (mathx.hash(<f64>q * 1.93 + 0.5, seed * 0.021) - 0.45) * 2 * amp;
            stepQ[q] = Math.abs(rowOff[q] - rowOff[q - 1]) > amp * 0.3;
        }
        tideH = lmin(1.6, (avgT - wl) / nIntF * 0.45);
    }
    let bulge = opt(sp.bulge, 0);
    // per column rows: world x, y, z
    let W: Array<Array<f64>> = new Array<Array<f64>>(1);
    let Y: Array<Array<f64>> = new Array<Array<f64>>(1);
    let Z: Array<Array<f64>> = new Array<Array<f64>>(1);
    let rowsN = 0;
    for (let i = 1; i <= n; i++) {
        let fi = <f64>i;
        let ys: Array<f64> = [0.0];
        let scs: Array<f64> = [0.0];
        let offs: Array<f64> = [0.0];
        let Ti = T[i];
        let top1 = Ti - dd[i];
        ys.push(base);
        scs.push(rooted ? 1.06 : 0.92);
        ys.push(wl + (mathx.hash(fi * 0.7, seed) - 0.5) * 0.3);
        scs.push(rooted ? 0.985 : 1);
        if (det > 0) {
            offs[1] = 0;
            offs[2] = 0;
            jKind[1] = 0; jKind[2] = 0; jRow[1] = 0; jRow[2] = 0;
            let rad = lmax(Math.sqrt(lx[i] * lx[i] + lz[i] * lz[i]), 1);
            let b1 = wl + (top1 - wl) * (1 / nIntF + rowJit[1]);
            ys.push(lmin(ys[2] + tideH, (ys[2] + b1) * 0.5));
            scs.push(1);
            offs[3] = 0;
            jKind[3] = 1;
            jRow[3] = 0;
            for (let q = 1; q < nInt; q++) {
                let t = <f64>q / nIntF + rowJit[q];
                let y = wl + (top1 - wl) * t + (mathx.noise2(fi * 0.55 + <f64>q * 3.1, seed * 0.07) - 0.5) * 0.8 * det;
                let hv = mathx.hash3(fi * 0.91, <f64>q * 1.7, seed * 0.03);
                let vary = hv < 0.18 ? 0.0 : 0.35 + 1.1 * hv;
                if (stepQ[q]) {
                    let e = 0.14;
                    ys.push(y - e);
                    scs.push(1);
                    offs.push(rowOff[q - 1] * vary / rad);
                    jKind[ys.length - 1] = 2;
                    jRow[ys.length - 1] = q;
                    ys.push(y + e);
                    scs.push(1);
                    offs.push(rowOff[q] * vary / rad);
                    jKind[ys.length - 1] = 3;
                    jRow[ys.length - 1] = q;
                } else {
                    ys.push(y);
                    scs.push(1);
                    offs.push((rowOff[q - 1] + rowOff[q]) * 0.5 * vary / rad);
                    jKind[ys.length - 1] = 0;
                    jRow[ys.length - 1] = q;
                }
            }
            offs.push(rowOff[nInt - 1] * 0.5 / rad);
            offs.push(0);
        } else {
            for (let q = 1; q < nInt; q++) {
                let t = <f64>q / nIntF + rowJit[q];
                ys.push(wl + (top1 - wl) * t);
                scs.push(1);
            }
        }
        ys.push(lmax(top1, wl + 0.2));
        scs.push(1 + lip * 0.6);
        ys.push(Ti);
        scs.push(1 + lip);
        let ny = ys.length - 1;
        rowsN = ny;
        if (det > 0) {
            jKind[rowsN - 1] = 0;
            jRow[rowsN - 1] = nInt;
            jKind[rowsN] = 0;
            jRow[rowsN] = nInt;
        }
        let wx: Array<f64> = [0.0], wy: Array<f64> = [0.0], wz: Array<f64> = [0.0];
        for (let j = 1; j <= ny; j++) {
            let y = ys[j];
            let t = saturate((y - base) / lmax(Ti - base, 1));
            let k = scs[j] * (1 - taper * Math.pow(t, 1.3)) * (1 + bulge * Math.sin(Math.PI * t));
            let mid = j > 2 && j < ny - 1;
            if (mid) {
                k += (t > tierT ? colJ2[i] : colJ[i]) + (mathx.hash3(fi * 1.37, <f64>j * 2.11, seed * 0.013) - 0.5) * 0.004;
                if (crack[i] > 0 && t < crackTop[i]) k -= crack[i] * 0.25;
            } else if (j >= ny - 1) {
                k += (tierT < 1 ? colJ2[i] : colJ[i]) * 0.6;
            }
            if (det > 0) k += offs[j];
            let ax = lx[i] * k, az = lz[i] * k, lean = Math.pow(t, 1.5);
            wx[j] = twX(sx, ax, az, cyw, syw, leanX, lean);
            wy[j] = y;
            wz[j] = twZ(sz0, ax, az, cyw, syw, leanZ, lean);
        }
        W[i] = wx;
        Y[i] = wy;
        Z[i] = wz;
    }
    let ccx = twX(sx, 0, 0, cyw, syw, leanX, 0), ccz = twZ(sz0, 0, 0, cyw, syw, leanZ, 0);
    let rimOut = sp.rim;
    if (rimOut != null) {
        for (let i = 1; i <= n; i++) {
            rimOut.push(W[i][rowsN]);
            rimOut.push(Y[i][rowsN]);
            rimOut.push(Z[i][rowsN]);
        }
    }
    // detail: every face cell creases down its middle
    let MX: Array<Array<f64>> = new Array<Array<f64>>(1);
    let MY: Array<Array<f64>> = new Array<Array<f64>>(1);
    let MZ: Array<Array<f64>> = new Array<Array<f64>>(1);
    let creased = det >= 0.9;
    if (creased) {
        let cAmp = lclamp(lmin(rx, rz) * 0.1, 0.3, 0.9) * det;
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let cr = (mathx.hash(<f64>i * 2.3 + 0.7, seed * 0.017) - 0.62) * 2 * cAmp;
            let mx: Array<f64> = [0.0], my: Array<f64> = [0.0], mz: Array<f64> = [0.0];
            for (let j = 1; j <= rowsN; j++) {
                let ax = W[i][j], az = Z[i][j];
                let bx = W[i2][j], bz = Z[i2][j];
                let cx = (ax + bx) * 0.5, cz = (az + bz) * 0.5;
                let ex = bx - ax, ez = bz - az;
                let l = lmax(Math.sqrt(ex * ex + ez * ez), 1e-3);
                let ux = ez / l, uz = -ex / l;
                if (ux * (cx - ccx) + uz * (cz - ccz) < 0) {
                    ux = -ux;
                    uz = -uz;
                }
                let fade = j == rowsN ? 0.0 : (j == rowsN - 1 ? 0.4 : 1.0);
                let c = cr * (0.75 + 0.5 * mathx.hash3(<f64>i * 1.1, <f64>j * 0.7, seed * 0.01)) * fade;
                mx[j] = cx + ux * c;
                my[j] = (Y[i][j] + Y[i2][j]) * 0.5;
                mz[j] = cz + uz * c;
            }
            MX[i] = mx;
            MY[i] = my;
            MZ[i] = mz;
        }
    }

    let v0 = b.vcount, i0 = b.icount;
    let col0 = b.col, aux0 = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    // walls
    if (det > 0) {
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let A = W[i], B = W[i2];
            let AY = Y[i], BY = Y[i2];
            let AZ = Z[i], BZ = Z[i2];
            let hx = (A[2] + B[2]) * 0.5 - ccx, hz = (AZ[2] + BZ[2]) * 0.5 - ccz;
            for (let j = 1; j < rowsN; j++) {
                let kj = jKind[j];
                let hy = 0.0;
                let cr: f64, cg: f64, cb: f64;
                if (j == 1) {
                    mathx.rgb(rooted ? look.wet : look.strata[3]);
                    cr = mathx.RGB_R; cg = mathx.RGB_G; cb = mathx.RGB_B;
                } else if (j == rowsN - 1) {
                    mathx.rgb(look.drape);
                    cr = mathx.RGB_R; cg = mathx.RGB_G; cb = mathx.RGB_B;
                    hy = 0.35;
                } else if (kj == 0 && jKind[j + 1] == 1) {
                    mathx.rgb(look.wet);
                    let wr = mathx.RGB_R, wg = mathx.RGB_G, wb = mathx.RGB_B;
                    mathx.rgb(tones[2]);
                    let tr_ = mathx.RGB_R, tg = mathx.RGB_G, tb = mathx.RGB_B;
                    cr = wr + (tr_ - wr) * 0.45;
                    cg = wg + (tg - wg) * 0.45;
                    cb = wb + (tb - wb) * 0.45;
                } else if (kj == 2) {
                    let q = jRow[j];
                    if (rowOff[q] > rowOff[q - 1]) {
                        mathx.rgb(look.crack);
                        let wr = mathx.RGB_R, wg = mathx.RGB_G, wb = mathx.RGB_B;
                        mathx.rgb(tones[min(q + 2, ntones)]);
                        let tr_ = mathx.RGB_R, tg = mathx.RGB_G, tb = mathx.RGB_B;
                        cr = wr + (tr_ - wr) * 0.35;
                        cg = wg + (tg - wg) * 0.35;
                        cb = wb + (tb - wb) * 0.35;
                        hy = -0.5;
                    } else {
                        let moss = mathx.hash(<f64>i * 1.3, <f64>q * 2.9 + seed * 0.01) < 0.1;
                        mathx.rgb(moss ? look.drape : look.lichen);
                        let wr = mathx.RGB_R, wg = mathx.RGB_G, wb = mathx.RGB_B;
                        mathx.rgb(tones[min(q + 2, ntones)]);
                        let tr_ = mathx.RGB_R, tg = mathx.RGB_G, tb = mathx.RGB_B;
                        let mk = moss ? 0.85 : 0.4;
                        cr = tr_ + (wr - tr_) * mk;
                        cg = tg + (wg - tg) * mk;
                        cb = tb + (wb - tb) * mk;
                        hy = 0.5;
                    }
                } else {
                    let q = jRow[j];
                    mathx.rgb(tones[min(q + 2, ntones)]);
                    cr = mathx.RGB_R; cg = mathx.RGB_G; cb = mathx.RGB_B;
                    let bk = 1 + (mathx.hash(<f64>q * 2.17 + 0.3, seed * 0.019) - 0.5) * 0.14;
                    cr = cr * bk;
                    cg = cg * bk;
                    cb = cb * bk;
                    let hc = mathx.hash3(<f64>i * 0.83, <f64>q * 1.9, seed * 0.011);
                    if (q + 1 < nInt && stepQ[q + 1] && rowOff[q + 1] > rowOff[q] && hc < 0.4) {
                        cr = cr * 0.84;
                        cg = cg * 0.85;
                        cb = cb * 0.88;
                    } else if (<f64>q > nIntF * 0.45 && hc > 0.9) {
                        mathx.rgb(look.lichen);
                        cr = mathx.RGB_R; cg = mathx.RGB_G; cb = mathx.RGB_B;
                    }
                }
                meshgen.colorf(b, cr, cg, cb);
                if (creased) {
                    let Mx = MX[i], My = MY[i], Mz = MZ[i];
                    quad(b, A[j], AY[j], AZ[j], Mx[j], My[j], Mz[j], Mx[j + 1], My[j + 1], Mz[j + 1], A[j + 1], AY[j + 1], AZ[j + 1], hx, hy, hz);
                    quad(b, Mx[j], My[j], Mz[j], B[j], BY[j], BZ[j], B[j + 1], BY[j + 1], BZ[j + 1], Mx[j + 1], My[j + 1], Mz[j + 1], hx, hy, hz);
                } else {
                    quad(b, A[j], AY[j], AZ[j], B[j], BY[j], BZ[j], B[j + 1], BY[j + 1], BZ[j + 1], A[j + 1], AY[j + 1], AZ[j + 1], hx, hy, hz);
                }
            }
        }
    } else {
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let A = W[i], B = W[i2];
            let AY = Y[i], BY = Y[i2];
            let AZ = Z[i], BZ = Z[i2];
            let hx = (A[2] + B[2]) * 0.5 - ccx, hz = (AZ[2] + BZ[2]) * 0.5 - ccz;
            for (let j = 1; j < rowsN; j++) {
                let tone: f64;
                if (j == 1) {
                    tone = rooted ? look.wet : look.strata[3];
                } else if (j == rowsN - 1) {
                    tone = look.drape;
                } else {
                    tone = tones[min(j, ntones)];
                    if (rand(r) < 0.012) tone = look.lichen;
                }
                meshgen.color(b, tone);
                let hy = j == rowsN - 1 ? 0.35 : 0.0;
                quad(b, A[j], AY[j], AZ[j], B[j], BY[j], BZ[j], B[j + 1], BY[j + 1], BZ[j + 1], A[j + 1], AY[j + 1], AZ[j + 1], hx, hy, hz);
            }
        }
    }
    // underside for floating masses
    if (!rooted) {
        meshgen.color(b, opt(sp.under, look.wet));
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            meshgen.flatTriFacing(b, W[i][1], base, Z[i][1], W[i2][1], base, Z[i2][1], ccx, base, ccz, 0, -1, 0);
        }
    }
    // cap: smooth rolling grass (indexed rings from the lip inward)
    let capIds: Array<Array<i32>> = new Array<Array<i32>>(1);
    let e = 0.8;
    let topMax = -HUGE;
    let grass = look.grass;
    let ng = <f64>(grass.length - 1);
    for (let k = 1; k <= 5; k++) {
        let f = RING_F[k];
        let ids: Array<i32> = [0];
        for (let i = 1; i <= n; i++) {
            let kk = (sTop + lip) * f;
            let axl = lx[i] * kk, azl = lz[i] * kk;
            let y: f64;
            let dhx = (H.at(axl + e, azl) - H.at(axl - e, azl)) / (2 * e);
            let dhz = (H.at(axl, azl + e) - H.at(axl, azl - e)) / (2 * e);
            let nx = -dhx, ny = 1.0, nz = -dhz;
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
            nx = nx / l;
            ny = ny / l;
            nz = nz / l;
            if (k == 1) {
                y = Y[i][rowsN];
                let wx = W[i][rowsN], wz = Z[i][rowsN];
                meshgen.color(b, look.drape);
                ids[i] = meshgen.vertex(b, wx, y, wz, (nx * cyw - nz * syw), ny, (nx * syw + nz * cyw));
            } else {
                y = H.at(axl, azl);
                // capVertex
                let wnx = nx * cyw - nz * syw, wnz = nx * syw + nz * cyw;
                let wx = twX(sx, axl, azl, cyw, syw, leanX, 1), wz = twZ(sz0, axl, azl, cyw, syw, leanZ, 1);
                let g = mathx.noise2(wx * 0.035 + ph1, wz * 0.035 + ph2);
                let gi = <i32>lclamp(Math.floor(g * ng) + 1, 1, ng);
                meshgen.color(b, grass[gi]);
                if (y > topMax) topMax = y;
                ids[i] = meshgen.vertex(b, wx, y, wz, wnx, ny, wnz);
            }
        }
        capIds[k] = ids;
    }
    let center: i32;
    {
        let axl = 0.0, azl = 0.0;
        let y = H.at(0, 0);
        let dhx = (H.at(axl + e, azl) - H.at(axl - e, azl)) / (2 * e);
        let dhz = (H.at(axl, azl + e) - H.at(axl, azl - e)) / (2 * e);
        let nx = -dhx, ny = 1.0, nz = -dhz;
        let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
        nx = nx / l;
        ny = ny / l;
        nz = nz / l;
        let wnx = nx * cyw - nz * syw, wnz = nx * syw + nz * cyw;
        let wx = twX(sx, axl, azl, cyw, syw, leanX, 1), wz = twZ(sz0, axl, azl, cyw, syw, leanZ, 1);
        let g = mathx.noise2(wx * 0.035 + ph1, wz * 0.035 + ph2);
        let gi = <i32>lclamp(Math.floor(g * ng) + 1, 1, ng);
        meshgen.color(b, grass[gi]);
        if (y > topMax) topMax = y;
        center = meshgen.vertex(b, wx, y, wz, wnx, ny, wnz);
    }
    for (let k = 1; k <= 4; k++) {
        let A = capIds[k], B = capIds[k + 1];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            meshgen.tri(b, A[i], B[i2], B[i]);
            meshgen.tri(b, A[i], A[i2], B[i2]);
        }
    }
    let L = capIds[5];
    for (let i = 1; i <= n; i++) {
        let i2 = (i % n) + 1;
        meshgen.tri(b, L[i], L[i2], center);
    }
    // shrubs on the top
    let collides = cols != null && sp.collide;
    let rcols: Array<Collider>? = collides ? [] : null;
    let nt = isNaN(sp.tufts) ? Math.floor(lmin(rx, rz) * 0.25) : sp.tufts;
    for (let t = 1; <f64>t <= nt; t++) {
        let i = <i32>mathx.randInt(r, 1, nF);
        let f = randRange(r, 0.15, 0.78);
        let axl = lx[i] * f * sTop, azl = lz[i] * f * sTop;
        let wx = twX(sx, axl, azl, cyw, syw, leanX, 1), wz = twZ(sz0, axl, azl, cyw, syw, leanZ, 1);
        let s = randRange(r, 1.1, 2.6);
        meshgen.color(b, look.shrub);
        let sy = H.at(axl, azl) - s * 0.25;
        let srz = s * randRange(r, 0.8, 1.2);
        let sd = rand(r) * 100;
        meshgen.rock(b, wx, sy, wz, s, s * 0.6, srz, sd, 6, 4);
        if (rcols != null) rcols.push(rockShell(wx, sy, wz, s, s * 0.6, srz, sd, 6, 4));
    }
    // boulders at the waterline
    if (rooted) {
        let nb = isNaN(sp.boulders) ? Math.floor((rx + rz) / 10) : sp.boulders;
        for (let t = 1; <f64>t <= nb; t++) {
            let i = <i32>mathx.randInt(r, 1, nF);
            let ox = W[i][2] - ccx, oz = Z[i][2] - ccz;
            let l = lmax(Math.sqrt(ox * ox + oz * oz), 1e-3);
            let s = lclamp(lmin(rx, rz) * randRange(r, 0.05, 0.13), 0.8, 5);
            let d = l + s * randRange(r, 0.1, 0.9);
            let bx = ccx + ox / l * d;
            let by = s * randRange(r, -0.1, 0.25);
            let bz = ccz + oz / l * d;
            boulder(b, r, bx, by, bz, s, rand(r) < 0.6 ? look.wet : look.boulder, NaN, rcols);
        }
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    // cracks
    meshgen.aux(b, 0, 0, 0, 0);
    for (let i = 1; i <= n; i++) {
        if (crack[i] > 0) {
            let hx = W[i][2] - ccx, hz = Z[i][2] - ccz;
            let l = lmax(Math.sqrt(hx * hx + hz * hz), 1e-3);
            let jTop = 3;
            for (let j = 3; j <= rowsN - 2; j++) {
                if ((Y[i][j] - base) / lmax(T[i] - base, 1) < crackTop[i]) jTop = j;
            }
            crackStrip(b, r, W[i], Y[i], Z[i], 2, jTop, hx / l, hz / l, lclamp(lmin(rx, rz) * 0.012, 0.25, 0.6), look.crack);
        }
    }
    // foam collar at the waterline
    if (rooted && sp.foam) {
        let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
        for (let i = 1; i <= n; i++) {
            fx[i] = W[i][2];
            fz[i] = Z[i][2];
        }
        foamRing(b, r, fx, fz, ccx, ccz, lclamp((rx + rz) * 0.03, 0.9, 3), look.foam);
    }
    meshgen.setPaint(b, col0, aux0);

    // colliders
    if (collides) {
        let P: Array<f64> = [0.0];
        let nc = 0;
        for (let i = 1; i <= n; i++) {
            for (let pass = 0; pass < 2; pass++) {
                if (pass == 1 && !creased) break;
                let xs = pass == 0 ? W[i] : MX[i];
                let ys = pass == 0 ? Y[i] : MY[i];
                let zs = pass == 0 ? Z[i] : MZ[i];
                let prev = -HUGE;
                for (let j = 1; j <= rowsN; j++) {
                    prev = lmax(ys[j], prev);
                    P.push(prev);
                    P.push(xs[j]);
                    P.push(zs[j]);
                }
                nc += 1;
            }
        }
        let cap = new HeadCap(H, sp.x, sp.z, leanX, leanZ, cyw, syw);
        let sh = coll.shell(nc, rowsN, P, rooted, cap);
        let bx = 0.0, bz = 0.0, bn = 0.0;
        let np = P.length - 1;
        for (let q = 1; q <= np; q += 3) {
            if ((P[q] > 0.5 && P[q] < 34) || !rooted) {
                bx += P[q + 1];
                bz += P[q + 2];
                bn += 1;
            }
        }
        if (bn > 0) {
            bx = bx / bn;
            bz = bz / bn;
            let mean = 0.0, far = 0.0;
            for (let q = 1; q <= np; q += 3) {
                if ((P[q] > 0.5 && P[q] < 34) || !rooted) {
                    let d = Math.sqrt(Math.pow(P[q + 1] - bx, 2) + Math.pow(P[q + 2] - bz, 2));
                    mean += d / bn;
                    far = lmax(far, d);
                }
            }
            coll.body(sh, bx, bz, mean + (far - mean) * 0.75, sh.y0, sh.y1);
        }
        let rc = rcols!;
        for (let q = 0; q < rc.length; q++) coll.attach(sh, rc[q]);
        cols!.push(sh);
    }
    return topMax;
}

// Skerry: a cluster of wave-washed faceted rocks with a foam collar.
export function skerry(b: Builder, x: f64, z: f64, rad: f64, h: f64, seed: f64, look: Look, cols: Array<Collider>?): void {
    let r = mathx.rng(seed);
    let col0 = b.col, aux0 = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    let v0 = b.vcount, i0 = b.icount;
    let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
    let shell: Collider? = null;
    let nRock = <i32>mathx.randInt(r, 3, 5);
    for (let q = 1; q <= nRock; q++) {
        let main = q == 1;
        let a = rand(r) * TAU;
        let d = main ? 0.0 : rad * randRange(r, 0.55, 1.05);
        let s = main ? rad : rad * randRange(r, 0.3, 0.6);
        let hh = main ? h : h * randRange(r, 0.3, 0.7);
        let cx = x + Math.cos(a) * d, cz = z + Math.sin(a) * d;
        let ry = lmax(hh, s * 0.45);
        meshgen.color(b, main ? look.strata[2] : look.boulder);
        let rz = s * randRange(r, 0.75, 1);
        let sd1 = rand(r) * 100;
        meshgen.rock(b, cx, hh - ry, cz, s, ry, rz, sd1, 9, 6);
        meshgen.color(b, look.grass[1]);
        let sd2 = rand(r) * 100;
        meshgen.rock(b, cx + s * 0.05, hh - ry * 0.18, cz, s * 0.62, ry * 0.3, s * 0.55, sd2, 7, 3);
        meshgen.color(b, look.wet);
        let sd3 = rand(r) * 100;
        meshgen.rock(b, cx, 0.1, cz, s * 1.06, 0.8, s * 1.02, sd3, 9, 3);
        if (cols != null) {
            let sh = rockShell(cx, hh - ry, cz, s, ry, rz, sd1, 9, 6);
            let root: Collider;
            if (shell == null) {
                root = sh;
                shell = sh;
                coll.body(sh, x, z, rad * 0.9, -6, h);
            } else {
                root = shell;
                coll.attach(root, sh);
            }
            coll.attach(root, rockShell(cx + s * 0.05, hh - ry * 0.18, cz, s * 0.62, ry * 0.3, s * 0.55, sd2, 7, 3));
            coll.attach(root, rockShell(cx, 0.1, cz, s * 1.06, 0.8, s * 1.02, sd3, 9, 3));
        }
        for (let k = 0; k <= 7; k++) {
            let aa = -<f64>k / 8 * TAU;
            fx.push(cx + Math.cos(aa) * s * 1.02);
            fz.push(cz + Math.sin(aa) * s * 1.02);
        }
    }
    meshgen.inkShell(b, v0, i0, 1);
    let mx: Array<f64> = [0.0], mz: Array<f64> = [0.0];
    for (let k = 1; k <= 8; k++) {
        mx[k] = fx[k];
        mz[k] = fz[k];
    }
    foamRing(b, r, mx, mz, x, z, lclamp(rad * 0.25, 0.8, 2.2), look.foam);
    meshgen.setPaint(b, col0, aux0);
    if (cols != null && shell != null) cols.push(shell);
}

// Rounded rock masses (violet) ---------------------------------------------------

export class LumpSpec {
    x: f64 = 0;
    z: f64 = 0;
    y0: f64 = 0;
    y1: f64 = 1;
    rx: f64 = 1;
    rz: f64 = 1;
    yaw: f64 = 0;
    seed: f64 = 0;
    look: Look = VIOLET;
    peak: f64 = NaN;
    leanX: f64 = NaN;
    leanZ: f64 = NaN;
    n: f64 = NaN;
    square: f64 = NaN;
    frost: f64 = NaN;
    tone: f64 = NaN;
    cracks: f64 = NaN;
    far: bool = false;
    joint: f64 = NaN;
}

const LUMP_V: StaticArray<f64> = [0, 0, 0.08, 0.3, 0.6, 0.85, 0.95, 1]; // 1-based
const LUMP_S: StaticArray<f64> = [0, 0.84, 0.97, 1.02, 1.0, 0.98, 0.9, 0.7];
const LUMP_NR: i32 = 7;

const lumpX: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpY: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpZ: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpNX: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpNY: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpNZ: Array<Array<f64>> = new Array<Array<f64>>(1);
const lumpRing: Array<i32> = [0];

function ensureRows(): void {
    if (lumpX.length > 1) return;
    for (let j = 1; j <= LUMP_NR; j++) {
        lumpX.push([0.0]);
        lumpY.push([0.0]);
        lumpZ.push([0.0]);
        lumpNX.push([0.0]);
        lumpNY.push([0.0]);
        lumpNZ.push([0.0]);
    }
}

// One rounded block. Returns the top height (dome included).
export function lump(b: Builder, sp: LumpSpec, cols: Array<Collider>?): f64 {
    ensureRows();
    let r = mathx.rng(sp.seed);
    let look = sp.look;
    let n = <i32>(isNaN(sp.n) ? (sp.far ? 10.0 : 16.0) : sp.n);
    let nF = <f64>n;
    let nr = LUMP_NR;
    let sq = isNaN(sp.square) ? randRange(r, 2.3, 3.1) : sp.square;
    let peak = opt(sp.peak, 0);
    let lxo = opt(sp.leanX, 0), lzo = opt(sp.leanZ, 0);
    let cyw = Math.cos(sp.yaw), syw = Math.sin(sp.yaw);
    let H = sp.y1 - sp.y0;
    let ph1 = rand(r) * 40;
    let ph2 = rand(r) * 40;
    let amp = sp.far ? 0.1 : 0.14;
    let seed = sp.seed;
    let px: Array<f64> = [0.0], pz: Array<f64> = [0.0];
    for (let i = 1; i <= n; i++) {
        let a = (<f64>(i - 1) + (rand(r) - 0.5) * 0.35) / nF * TAU;
        let ca = Math.cos(a), sa = Math.sin(a);
        let k = Math.pow(Math.pow(Math.abs(ca), sq) + Math.pow(Math.abs(sa), sq), -1 / sq);
        let lmp = 1 + amp * (mathx.fbm2(ca * 1.2 + ph1, sa * 1.2 + ph2, 2) / 0.75 - 0.5) * 2;
        if (mathx.hash(<f64>i * 1.37, seed * 0.011) < 0.22) lmp *= 0.93;
        px[i] = ca * sp.rx * k * lmp;
        pz[i] = sa * sp.rz * k * lmp;
    }
    for (let j = 1; j <= nr; j++) {
        let v = LUMP_V[j];
        let sc = LUMP_S[j];
        if (j == 1 && !isNaN(sp.joint)) sc = sp.joint;
        if (peak > 0) sc *= 1 - peak * 0.62 * Math.pow(v, 1.5);
        let y = sp.y0 + H * v;
        let ox = lxo * v, oz = lzo * v;
        let rowX = lumpX[j], rowY = lumpY[j], rowZ = lumpZ[j];
        for (let i = 1; i <= n; i++) {
            let jit = 1 + (mathx.hash3(<f64>i * 1.91, <f64>j * 2.37, seed * 0.013) - 0.5) * 0.09;
            let ax = px[i] * sc * jit, az = pz[i] * sc * jit;
            rowX[i] = sp.x + ax * cyw - az * syw + ox;
            rowY[i] = y + (j > 1 && j < nr ? (mathx.hash3(<f64>i * 0.71, <f64>j * 1.3, seed) - 0.5) * H * 0.04 : 0.0);
            rowZ[i] = sp.z + ax * syw + az * cyw + oz;
        }
    }
    let dome = lmin(sp.rx, sp.rz) * (0.1 + 0.08 * rand(r)) + H * 0.22 * peak;
    let topX = sp.x + lxo, topY = sp.y1 + dome, topZ = sp.z + lzo;
    if (cols != null) {
        let P: Array<f64> = [0.0];
        for (let i = 1; i <= n; i++) {
            let prev = -HUGE;
            for (let j = 1; j <= nr; j++) {
                prev = lmax(prev, lumpY[j][i]);
                P.push(prev);
                P.push(lumpX[j][i]);
                P.push(lumpZ[j][i]);
            }
            P.push(lmax(prev, topY));
            P.push(topX);
            P.push(topZ);
        }
        cols.push(coll.shell(n, nr + 1, P, sp.y0 < -1, null));
    }
    let tone = isNaN(sp.tone) ? look.strata[<i32>mathx.randInt(r, 1, <f64>(look.strata.length - 1))] : sp.tone;
    let frost = opt(sp.frost, 1);
    let col0 = b.col, aux0 = b.aux;
    let NX = lumpNX, NY = lumpNY, NZ = lumpNZ;
    for (let j = 1; j <= nr; j++) {
        let ja = max(j - 1, 1), jb = min(j + 1, nr);
        let rx0 = NX[j], ry0 = NY[j], rz0 = NZ[j];
        let LXj = lumpX[j], LYj = lumpY[j], LZj = lumpZ[j];
        for (let i = 1; i <= n; i++) {
            let ia = imod(i - 2, n) + 1, ib = (i % n) + 1;
            let ux = LXj[ib] - LXj[ia], uy = LYj[ib] - LYj[ia], uz = LZj[ib] - LZj[ia];
            let vx = lumpX[jb][i] - lumpX[ja][i], vy = lumpY[jb][i] - lumpY[ja][i], vz = lumpZ[jb][i] - lumpZ[ja][i];
            if (j == nr) {
                vx = topX - lumpX[ja][i];
                vy = topY - lumpY[ja][i];
                vz = topZ - lumpZ[ja][i];
            }
            let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
            let ox = LXj[i] - sp.x - lxo * LUMP_V[j], oz = LZj[i] - sp.z - lzo * LUMP_V[j];
            if (nx * ox + nz * oz < 0) {
                nx = -nx;
                ny = -ny;
                nz = -nz;
            }
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
            if (l < 1e-9) {
                nx = 0;
                ny = 1;
                nz = 0;
                l = 1;
            }
            rx0[i] = nx / l;
            ry0[i] = ny / l;
            rz0[i] = nz / l;
        }
    }
    let grass = look.grass;
    let ng = <f64>(grass.length - 1);
    let colShift = Math.floor(mathx.hash(seed, 3.3) * 3);
    for (let j = 1; j < nr; j++) {
        let A = lumpX[j], AY = lumpY[j], AZ = lumpZ[j];
        let B = lumpX[j + 1], BY = lumpY[j + 1], BZ = lumpZ[j + 1];
        let NA = NX[j], NAY = NY[j], NAZ = NZ[j];
        let NB = NX[j + 1], NBY = NY[j + 1], NBZ = NZ[j + 1];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let nyAvg = (NAY[i] + NAY[i2] + NBY[i] + NBY[i2]) * 0.25;
            let fh = mathx.hash3(<f64>i * 0.53, <f64>j * 1.7, seed * 0.021);
            if (nyAvg > 0.6 - 0.12 * frost && frost > 0) {
                meshgen.color(b, grass[<i32>lclamp(Math.floor(fh * ng) + 1, 1, ng)]);
            } else if (nyAvg > 0.28 && frost > 0 && fh < 0.55 * frost) {
                meshgen.color(b, look.drape);
            } else if (j == 1 && sp.y0 < 0.5) {
                meshgen.color(b, look.wet);
            } else {
                let colK = mod(Math.floor((<f64>i + colShift) / 3), 2) == 0 ? 1.0 : 0.93;
                mathx.rgb(tone);
                let f = colK * (0.97 + 0.06 * fh);
                meshgen.colorf(b, mathx.RGB_R * f, mathx.RGB_G * f, mathx.RGB_B * f);
            }
            let i0v = meshgen.vertex(b, A[i], AY[i], AZ[i], NA[i], NAY[i], NAZ[i]);
            let i1v = meshgen.vertex(b, A[i2], AY[i2], AZ[i2], NA[i2], NAY[i2], NAZ[i2]);
            let i2v = meshgen.vertex(b, B[i2], BY[i2], BZ[i2], NB[i2], NBY[i2], NBZ[i2]);
            let i3v = meshgen.vertex(b, B[i], BY[i], BZ[i], NB[i], NBY[i], NBZ[i]);
            let ux = B[i2] - A[i], uy = BY[i2] - AY[i], uz = BZ[i2] - AZ[i];
            let vx = B[i] - A[i2], vy = BY[i] - AY[i2], vz = BZ[i] - AZ[i2];
            let fx = uy * vz - uz * vy, fy = uz * vx - ux * vz, fz = ux * vy - uy * vx;
            if (fx * (NA[i] + NB[i2]) + fy * (NAY[i] + NBY[i2]) + fz * (NAZ[i] + NBZ[i2]) >= 0) {
                meshgen.tri(b, i0v, i1v, i2v);
                meshgen.tri(b, i0v, i2v, i3v);
            } else {
                meshgen.tri(b, i0v, i2v, i1v);
                meshgen.tri(b, i0v, i3v, i2v);
            }
        }
    }
    // top cap (frost), smooth: a dome over the last ring
    let T = lumpX[nr], TY = lumpY[nr], TZ = lumpZ[nr];
    let NT = NX[nr], NTY = NY[nr], NTZ = NZ[nr];
    if (frost > 0) {
        meshgen.color(b, grass[1]);
    } else {
        meshgen.color(b, tone);
    }
    let ci = meshgen.vertex(b, topX, topY, topZ, 0, 1, 0);
    let ring = lumpRing;
    for (let i = 1; i <= n; i++) {
        let g = mathx.hash(<f64>i * 0.77, seed * 0.3);
        if (frost > 0) meshgen.color(b, grass[<i32>lclamp(Math.floor(g * ng) + 1, 1, ng)]);
        let ux = NT[i] * 0.5, uy = NTY[i] * 0.5 + 0.5, uz = NTZ[i] * 0.5;
        let l = Math.sqrt(ux * ux + uy * uy + uz * uz);
        ring[i] = meshgen.vertex(b, T[i], TY[i], TZ[i], ux / l, uy / l, uz / l);
    }
    for (let i = 1; i <= n; i++) {
        let i2 = (i % n) + 1;
        let ax = T[i] - topX, az = TZ[i] - topZ;
        let bx = T[i2] - topX, bz = TZ[i2] - topZ;
        if (ax * bz - az * bx <= 0) {
            meshgen.tri(b, ci, ring[i], ring[i2]);
        } else {
            meshgen.tri(b, ci, ring[i2], ring[i]);
        }
    }
    meshgen.setPaint(b, col0, aux0);
    return topY;
}

export class TowerSpec {
    x: f64 = 0;
    z: f64 = 0;
    yaw: f64 = 0;
    h: f64 = 1;
    rx: f64 = 1;
    rz: f64 = 1;
    seed: f64 = 0;
    look: Look = VIOLET;
    segs: f64 = NaN;
    peak: f64 = NaN;
    shrink: f64 = NaN;
    lean: f64 = NaN;
    base: f64 = NaN;
    far: bool = false;
    ink: f64 = NaN;
    foam: bool = true; // Luau: foam ~= false
    boulders: f64 = NaN;
    frost: f64 = NaN;
    n: f64 = NaN;
    cracks: f64 = NaN;
}

class Seg {
    x: f64 = 0;
    z: f64 = 0;
    y0: f64 = 0;
    y1: f64 = 0;
    rx: f64 = 0;
    rz: f64 = 0;
    yaw: f64 = 0;
    seed: f64 = 0;
    peak: f64 = 0;
    tone: f64 = 0;
    lx: f64 = 0;
    lz: f64 = 0;
}

function nSegOf(sp: TowerSpec): i32 {
    let base = opt(sp.base, -4);
    return <i32>(isNaN(sp.segs) ? lclamp(Math.floor((sp.h - base) / lmax(sp.rx, sp.rz) * 0.5 + 0.5), 1, 5) : sp.segs);
}

export function towerStepCount(sp: TowerSpec): i32 {
    return nSegOf(sp) + 1;
}

// Bake steps of a tower (Luau towerSteps' closures): step(1..nSeg) lays one
// block segment each, step(nSeg + 1) the boulders, ink, cracks, foam and
// colliders. `top` is the top height once baked.
export class TowerBaker {
    sp: TowerSpec;
    r: Rng;
    look: Look;
    base: f64;
    nSeg: i32;
    shrink: f64;
    lean: f64;
    weights: Array<f64> = [0.0];
    tot: f64 = 0;
    v0: i32 = 0;
    i0: i32 = 0;
    col0: u32 = 0;
    aux0: u32 = 0;
    y: f64;
    cx: f64;
    cz: f64;
    rx: f64;
    rz: f64;
    yaw: f64;
    span: f64;
    top: f64;
    segs: Array<Seg> = new Array<Seg>(1);
    shells: Array<Collider> = [];
    bcols: Array<Collider> = [];
    toneI: f64;

    constructor(sp: TowerSpec) {
        this.sp = sp;
        let r = mathx.rng(sp.seed);
        this.r = r;
        this.look = sp.look;
        this.base = opt(sp.base, -4);
        this.nSeg = nSegOf(sp);
        this.shrink = opt(sp.shrink, 0.84);
        this.lean = opt(sp.lean, 0.2);
        for (let i = 1; i <= this.nSeg; i++) {
            this.weights[i] = randRange(r, 0.75, 1.3) * (1 + <f64>(i - 1) * 0.06);
            this.tot += this.weights[i];
        }
        this.y = this.base;
        this.cx = sp.x;
        this.cz = sp.z;
        this.rx = sp.rx;
        this.rz = sp.rz;
        this.yaw = sp.yaw;
        this.span = sp.h - this.base;
        this.top = this.base;
        this.toneI = mathx.randInt(r, 1, <f64>(this.look.strata.length - 1));
    }

    get count(): i32 {
        return this.nSeg + 1;
    }

    segment(b: Builder, i: i32): void {
        let sp = this.sp, r = this.r, look = this.look;
        let ns = <f64>(look.strata.length - 1);
        let bh = this.span * this.weights[i] / this.tot;
        let y0 = i == 1 ? this.y : this.y - lmin(bh * 0.3, lmin(this.rx, this.rz) * 0.22);
        let y1 = this.y + bh;
        let last = i == this.nSeg;
        let lxo = randRange(r, -this.lean, this.lean) * this.rx * 0.6;
        let lzo = randRange(r, -this.lean, this.lean) * this.rz * 0.6;
        this.toneI = mod(this.toneI + mathx.randInt(r, 1, ns - 1) - 1, ns) + 1;
        let sg = new Seg();
        sg.x = this.cx;
        sg.z = this.cz;
        sg.y0 = y0;
        sg.y1 = y1;
        sg.rx = this.rx;
        sg.rz = this.rz;
        sg.yaw = this.yaw;
        sg.seed = sp.seed + <f64>i * 131;
        sg.peak = last ? opt(sp.peak, 0) : opt(sp.peak, 0) * 0.25;
        sg.tone = look.strata[<i32>this.toneI];
        sg.lx = lxo;
        sg.lz = lzo;
        this.segs.push(sg);
        let ls = new LumpSpec();
        ls.x = sg.x;
        ls.z = sg.z;
        ls.y0 = sg.y0;
        ls.y1 = sg.y1;
        ls.rx = sg.rx;
        ls.rz = sg.rz;
        ls.yaw = sg.yaw;
        ls.seed = sg.seed;
        ls.look = look;
        ls.peak = sg.peak;
        ls.leanX = lxo;
        ls.leanZ = lzo;
        ls.n = sp.n;
        ls.frost = sp.frost;
        ls.tone = sg.tone;
        ls.far = sp.far;
        ls.joint = i > 1 ? 0.96 : NaN;
        this.top = lump(b, ls, sp.far ? null : this.shells);
        this.y = y1;
        this.cx += lxo;
        this.cz += lzo;
        let k = this.shrink * randRange(r, 0.86, 1.1);
        this.rx *= k;
        this.rz *= k * randRange(r, 0.94, 1.06);
        this.yaw += randRange(r, -0.35, 0.35);
    }

    finish(b: Builder, cols: Array<Collider>?): void {
        let sp = this.sp, r = this.r, look = this.look;
        let base = this.base;
        if (!sp.far && base < 0.5) {
            let nb = isNaN(sp.boulders) ? Math.floor((sp.rx + sp.rz) / 9) : sp.boulders;
            for (let t = 1; <f64>t <= nb; t++) {
                let a = rand(r) * TAU;
                let d = lmax(sp.rx, sp.rz) * randRange(r, 0.95, 1.25);
                let s = lclamp(lmin(sp.rx, sp.rz) * randRange(r, 0.08, 0.18), 1, 5);
                let bx = sp.x + Math.cos(a) * d;
                let by = s * randRange(r, -0.3, 0.15);
                let bz = sp.z + Math.sin(a) * d;
                boulder(b, r, bx, by, bz, s, rand(r) < 0.5 ? look.wet : look.boulder, look.grass[1], cols != null ? this.bcols : null);
            }
        }
        meshgen.inkShell(b, this.v0, this.i0, opt(sp.ink, 1));
        meshgen.aux(b, 0, 0, 0, 0);
        let segs = this.segs;
        let nsegs = segs.length - 1;
        if (!sp.far) {
            let crP = opt(sp.cracks, 0.8);
            for (let si = 1; si <= nsegs; si++) {
                let sg = segs[si];
                if (rand(r) < crP) {
                    let nc = mathx.randInt(r, 1, 2);
                    for (let c = 1; <f64>c <= nc; c++) {
                        let a = rand(r) * TAU;
                        let ca = Math.cos(a), sa = Math.sin(a);
                        let xs: Array<f64> = [0.0], ys: Array<f64> = [0.0], zs: Array<f64> = [0.0];
                        let rows = 5;
                        for (let j = 1; j <= rows; j++) {
                            let v = 0.12 + 0.72 * <f64>(j - 1) / <f64>(rows - 1);
                            let sc = v < 0.3 ? 1.0 : (v < 0.8 ? 1.02 : 0.97);
                            let ax = ca * sg.rx * sc, az = sa * sg.rz * sc;
                            let cc = Math.cos(sg.yaw), ss = Math.sin(sg.yaw);
                            xs[j] = sg.x + ax * cc - az * ss + sg.lx * v;
                            ys[j] = sg.y0 + (sg.y1 - sg.y0) * v;
                            zs[j] = sg.z + ax * ss + az * cc + sg.lz * v;
                        }
                        let hx = xs[3] - sg.x, hz = zs[3] - sg.z;
                        let hl = lmax(Math.sqrt(hx * hx + hz * hz), 1e-3);
                        for (let j = 1; j <= rows; j++) {
                            xs[j] += hx / hl * lmin(sg.rx, sg.rz) * 0.1;
                            zs[j] += hz / hl * lmin(sg.rx, sg.rz) * 0.1;
                        }
                        crackStrip(b, r, xs, ys, zs, 1, rows, hx / hl, hz / hl, lclamp(lmin(sg.rx, sg.rz) * 0.035, 0.3, 0.9), look.crack);
                    }
                }
            }
        }
        if (base < 0.5 && sp.foam && !sp.far) {
            let s1 = segs[1];
            let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
            let nF = 12;
            let c = Math.cos(s1.yaw), s = Math.sin(s1.yaw);
            for (let i = 1; i <= nF; i++) {
                let a = -<f64>(i - 1) / <f64>nF * TAU;
                let ca = Math.cos(a), sa = Math.sin(a);
                let k = Math.pow(Math.pow(Math.abs(ca), 2.6) + Math.pow(Math.abs(sa), 2.6), -1 / 2.6);
                let ax = ca * s1.rx * k * 0.98, az = sa * s1.rz * k * 0.98;
                fx[i] = s1.x + ax * c - az * s;
                fz[i] = s1.z + ax * s + az * c;
            }
            foamRing(b, r, fx, fz, s1.x, s1.z, lclamp((sp.rx + sp.rz) * 0.04, 1, 3), look.foam);
        }
        meshgen.setPaint(b, this.col0, this.aux0);
        if (cols != null) {
            let shells = this.shells;
            for (let q = 0; q < shells.length; q++) {
                let i = q + 1;
                let sh = shells[q];
                let sg = segs[i];
                let rad = lmin(sg.rx, sg.rz) * 0.9;
                let y0 = i == 1 ? lmin(sg.y0, -6) : sg.y0;
                let y1 = sg.y1 + (i == nsegs ? lmin(sg.rx, sg.rz) * 0.1 : 0.0);
                let rr = sg.peak > 0.5 || lmax(sg.rx, sg.rz) / lmin(sg.rx, sg.rz) >= 1.4 ? rad : (sg.rx + sg.rz) * 0.45;
                coll.body(sh, sg.x + sg.lx * 0.5, sg.z + sg.lz * 0.5, rr, y0, y1);
                if (i == 1) {
                    let bc = this.bcols;
                    for (let k = 0; k < bc.length; k++) coll.attach(sh, bc[k]);
                }
                cols.push(sh);
            }
        }
    }

    // i: 1..count
    step(i: i32, b: Builder, cols: Array<Collider>?): void {
        if (i <= this.nSeg) {
            if (i == 1) {
                this.v0 = b.vcount;
                this.i0 = b.icount;
                this.col0 = b.col;
                this.aux0 = b.aux;
            }
            meshgen.aux(b, 0, 1, 0, 0);
            this.segment(b, i);
        } else {
            this.finish(b, cols);
        }
    }
}

export function tower(b: Builder, sp: TowerSpec, cols: Array<Collider>?): f64 {
    let tb = new TowerBaker(sp);
    for (let i = 1; i <= tb.count; i++) tb.step(i, b, cols);
    return tb.top;
}

export class RockArchSpec {
    x: f64 = 0;
    z: f64 = 0;
    rx: f64 = 1;
    rz: f64 = 0;
    halfW: f64 = 1;
    height: f64 = 1;
    leg: f64 = 1;
    depth: f64 = 1;
    lintel: f64 = 1;
    seed: f64 = 0;
    look: Look = VIOLET;
    legTop: f64 = NaN;
}

// The rock arch in bake steps (each leg's tower steps, then the bridge).
export class ArchBaker {
    sp: RockArchSpec;
    r: Rng;
    yaw: f64;
    legH: f64;
    legs: Array<TowerSpec> = [];
    legSteps: Array<i32> = [];
    bakers: Array<TowerBaker?> = [null, null];
    total: i32 = 0;

    constructor(sp: RockArchSpec) {
        this.sp = sp;
        let r = mathx.rng(sp.seed);
        this.r = r;
        this.yaw = Math.atan2(sp.rz, sp.rx);
        this.legH = isNaN(sp.legTop) ? sp.height + sp.lintel * 0.4 : sp.legTop;
        for (let side = -1; side <= 1; side += 2) {
            let off = (sp.halfW + sp.leg * 0.85) * <f64>side;
            let t = new TowerSpec();
            t.x = sp.x + sp.rx * off;
            t.z = sp.z + sp.rz * off;
            t.yaw = this.yaw + randRange(r, -0.1, 0.1);
            t.h = this.legH + randRange(r, -2, 5);
            t.rx = sp.leg * 1.05;
            t.rz = sp.depth;
            t.seed = sp.seed + <f64>side * 7 + 7;
            t.look = sp.look;
            t.segs = mathx.randInt(r, 2, 4);
            t.shrink = 0.93;
            t.lean = 0.05;
            this.legs.push(t);
            let ns = towerStepCount(t);
            this.legSteps.push(ns);
            this.total += ns;
        }
        this.total += 1;
    }

    // i: 1..total
    step(i: i32, b: Builder, cols: Array<Collider>?): void {
        let k = i;
        for (let li = 0; li < 2; li++) {
            let ns = this.legSteps[li];
            if (k <= ns) {
                if (k == 1) this.bakers[li] = new TowerBaker(this.legs[li]);
                let tb = this.bakers[li];
                if (tb != null) tb.step(k, b, cols);
                return;
            }
            k -= ns;
        }
        this.bridge(b, cols);
    }

    bridge(b: Builder, cols: Array<Collider>?): void {
        let sp = this.sp, r = this.r;
        let v0 = b.vcount, i0 = b.icount;
        let col0 = b.col, aux0 = b.aux;
        meshgen.aux(b, 0, 1, 0, 0);
        let span = sp.halfW + sp.leg * 0.6;
        let nL = <i32>lclamp(Math.floor(span * 2 / (sp.lintel * 0.9)) + 1, 4, 9);
        let th = sp.lintel;
        for (let k = 0; k < nL; k++) {
            let t = <f64>k / <f64>(nL - 1);
            let a = Math.PI * (1 - t);
            let u = Math.cos(a) * span;
            let lift = Math.pow(Math.sin(a), 0.35);
            let yc = sp.height - th * 0.2 + (th * 0.5) * lift + (this.legH - sp.height) * (1 - lift) * 0.6;
            let rxl = span / <f64>(nL - 1) * randRange(r, 0.85, 1.1) + th * 0.25;
            let x = sp.x + sp.rx * u, z = sp.z + sp.rz * u;
            let ls = new LumpSpec();
            ls.x = x;
            ls.z = z;
            ls.y0 = yc - th * randRange(r, 0.45, 0.6);
            ls.y1 = yc + th * randRange(r, 0.4, 0.62);
            ls.rx = rxl;
            ls.rz = sp.depth * randRange(r, 0.82, 0.98);
            ls.yaw = this.yaw + randRange(r, -0.12, 0.12);
            ls.seed = sp.seed + 300 + <f64>k * 17;
            ls.look = sp.look;
            lump(b, ls, null);
        }
        meshgen.inkShell(b, v0, i0, 1);
        meshgen.setPaint(b, col0, aux0);
        if (cols != null) {
            cols.push(coll.box(sp.x, sp.height + th * 0.45, sp.z, Vector.xyz(<f32>sp.rx, 0, <f32>sp.rz), Vector.xyz(0, 1, 0), Vector.xyz(<f32>-sp.rz, 0, <f32>sp.rx), span, th * 0.55, sp.depth * 0.85));
        }
    }
}

export function rockArch(b: Builder, sp: RockArchSpec, cols: Array<Collider>?): void {
    let ab = new ArchBaker(sp);
    for (let i = 1; i <= ab.total; i++) ab.step(i, b, cols);
}

// Floating island ------------------------------------------------------------------

export class IslandSpec {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    r: f64 = 1;
    depth: f64 = 1;
    seed: f64 = 0;
    look: Look = COAST;
    ink: f64 = NaN;
}

const LEVELS: StaticArray<f64> = [0, 0, 0.14, 0.3, 0.48, 0.66, 0.84, 1]; // 1-based
const SCALES: StaticArray<f64> = [0, 1.02, 0.9, 0.74, 0.55, 0.36, 0.17, 0];
const NLEV: i32 = 7;

export let ISLAND_RIM: Array<f64> = [0.0];

// Returns the top height (the grass lip ring goes to ISLAND_RIM).
export function island(b: Builder, sp: IslandSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let look = sp.look;
    let wallH = sp.r * randRange(r, 0.28, 0.4);
    let yaw = rand(r) * TAU;
    let rz = sp.r * randRange(r, 0.7, 0.95);
    let rim: Array<f64> = [0.0];
    let hs = new HeadSpec();
    hs.x = sp.x;
    hs.z = sp.z;
    hs.yaw = yaw;
    hs.rx = sp.r;
    hs.rz = rz;
    hs.h = sp.y;
    hs.base = sp.y - wallH;
    hs.seed = sp.seed;
    hs.look = look;
    hs.dome = sp.r * randRange(r, 0.12, 0.26);
    hs.hills = sp.r * 0.05;
    hs.tip = randRange(r, 0, 0.25);
    hs.skew = randRange(r, -0.12, 0.12);
    hs.rough = 0.25;
    hs.taper = -0.07;
    hs.lip = 0.05;
    hs.drape = lmin(3, wallH * 0.45);
    hs.spurs = 0.2;
    hs.crack = 0.2;
    hs.boulders = 0;
    hs.tufts = Math.floor(sp.r * 0.2);
    hs.foam = false;
    hs.ink = sp.ink;
    hs.rowH = wallH / 2;
    hs.under = look.strata[3];
    hs.rim = rim;
    let top = headland(b, hs, cols);
    // hanging root
    let n = <i32>lclamp(Math.floor(sp.r * 0.8) + 8, 9, 20);
    let nF = <f64>n;
    let tones = strataRows(r, look, NLEV);
    let ph = rand(r) * 10;
    let cyw = Math.cos(yaw), syw = Math.sin(yaw);
    let tipX = sp.x + randRange(r, -0.2, 0.2) * sp.r;
    let tipZ = sp.z + randRange(r, -0.2, 0.2) * sp.r;
    let RX: Array<Array<f64>> = new Array<Array<f64>>(1);
    let RY: Array<Array<f64>> = new Array<Array<f64>>(1);
    let RZ: Array<Array<f64>> = new Array<Array<f64>>(1);
    let y0 = sp.y - wallH + 0.6;
    for (let li = 1; li <= NLEV; li++) {
        let lvl = LEVELS[li];
        let xs: Array<f64> = [0.0], ys: Array<f64> = [0.0], zs: Array<f64> = [0.0];
        let yy = y0 - sp.depth * lvl;
        let cx = sp.x + (tipX - sp.x) * lvl;
        let cz = sp.z + (tipZ - sp.z) * lvl;
        for (let i = 0; i < n; i++) {
            let a = -(<f64>i / nF) * TAU;
            let ca = Math.cos(a), sa = Math.sin(a);
            let k = SCALES[li] * (0.78 + 0.44 * mathx.noise2(ca * 1.7 + ph + lvl * 3, sa * 1.7));
            let lx = ca * sp.r * 0.95 * k, lz = sa * rz * 0.95 * k;
            xs.push(cx + lx * cyw - lz * syw);
            ys.push(yy + (li > 1 && li < NLEV ? randRange(r, -1.5, 1.5) * sp.depth / 30 : 0.0));
            zs.push(cz + lx * syw + lz * cyw);
        }
        RX.push(xs);
        RY.push(ys);
        RZ.push(zs);
    }
    let v0 = b.vcount, i0 = b.icount;
    let col0 = b.col, aux0 = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    for (let li = 1; li < NLEV; li++) {
        meshgen.color(b, tones[li]);
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let hx = (RX[li][i] + RX[li][i2]) * 0.5 - sp.x;
            let hz = (RZ[li][i] + RZ[li][i2]) * 0.5 - sp.z;
            if (li == NLEV - 1) {
                meshgen.flatTriFacing(b, RX[li][i], RY[li][i], RZ[li][i], RX[li][i2], RY[li][i2], RZ[li][i2], RX[li + 1][1], RY[li + 1][1], RZ[li + 1][1], hx, -0.6, hz);
            } else {
                quad(b, RX[li][i], RY[li][i], RZ[li][i], RX[li][i2], RY[li][i2], RZ[li][i2], RX[li + 1][i2], RY[li + 1][i2], RZ[li + 1][i2], RX[li + 1][i], RY[li + 1][i], RZ[li + 1][i], hx, -0.4, hz);
            }
        }
    }
    // stalactites under the rim
    let hung: Array<Collider> = [];
    let ns = mathx.randInt(r, 2, 5);
    for (let t = 1; <f64>t <= ns; t++) {
        let i = <i32>mathx.randInt(r, 1, nF);
        let li = <i32>mathx.randInt(r, 2, 3);
        let px = RX[li][i], py = RY[li][i], pz = RZ[li][i];
        let mx = (px + sp.x) * 0.5, mz = (pz + sp.z) * 0.5;
        let rr = sp.r * randRange(r, 0.1, 0.2);
        meshgen.color(b, tones[li + 1]);
        let sx = (px + mx) * 0.5, sz = (pz + mz) * 0.5;
        let sy = py - sp.depth * randRange(r, 0.3, 0.55);
        let sh = sp.depth * randRange(r, 0.3, 0.55) + 1;
        meshgen.cylinder(b, sx, sy, sz, 0, rr, sh, 6, false, false);
        if (cols != null) {
            let P: Array<f64> = [0.0];
            for (let k = 0; k <= 5; k++) {
                let a = <f64>k / 6 * TAU;
                P.push(sy);
                P.push(sx);
                P.push(sz);
                P.push(sy + sh);
                P.push(sx + Math.cos(a) * rr);
                P.push(sz + Math.sin(a) * rr);
            }
            hung.push(coll.shell(6, 2, P, false, null));
        }
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    meshgen.setPaint(b, col0, aux0);
    if (cols != null) {
        let P: Array<f64> = [0.0];
        for (let i = 1; i <= n; i++) {
            let prev = -HUGE;
            for (let li = NLEV; li >= 1; li--) {
                prev = lmax(RY[li][i], prev);
                P.push(prev);
                P.push(RX[li][i]);
                P.push(RZ[li][i]);
            }
        }
        let slab = cols[cols.length - 1];
        coll.attach(slab, coll.shell(n, NLEV, P, false, null));
        for (let k = 0; k < hung.length; k++) coll.attach(slab, hung[k]);
        coll.body(slab, sp.x, sp.z, sp.r * 0.82, sp.y - wallH - sp.depth * 0.45, top - 0.5);
    }
    ISLAND_RIM = rim;
    return top;
}

// Distant mountain ridge -------------------------------------------------------------

export class RidgeSpec {
    x: f64 = 0;
    z: f64 = 0;
    yaw: f64 = 0;
    len: f64 = 1;
    h: f64 = 1;
    peaks: f64 = NaN;
    seed: f64 = 0;
    tones: Array<f64> = [0.0, 0, 0, 0]; // 1-based: crest, mid, base
    ink: f64 = NaN;
}

class Crest {
    np: i32 = 0;
    pu: Array<f64> = [0.0];
    ph: Array<f64> = [0.0];
    pw: Array<f64> = [0.0];
    Hm: f64 = 0;
    seed: f64 = 0;
    at(u: f64): f64 {
        let hgt = this.Hm * 0.28 * (1 - u * u);
        for (let i = 1; i <= this.np; i++) {
            let d = Math.abs(u - this.pu[i]) / this.pw[i];
            if (d < 1) hgt = lmax(hgt, this.ph[i] * Math.pow(1 - d, 1.25));
        }
        hgt *= 0.92 + 0.16 * mathx.noise2(u * 9 + this.seed * 0.1, 3.3);
        return hgt * smoothstep(1, 0.8, Math.abs(u));
    }
}

export function ridge(b: Builder, sp: RidgeSpec): void {
    let r = mathx.rng(sp.seed);
    let col0 = b.col, aux0 = b.aux;
    meshgen.aux(b, 0, opt(sp.ink, 0.3), 0, 0);
    let ca = Math.cos(sp.yaw), sa = Math.sin(sp.yaw);
    let L = sp.len, Hm = sp.h;
    let npF = isNaN(sp.peaks) ? mathx.randInt(r, 2, 4) : sp.peaks;
    let np = <i32>npF;
    let cr = new Crest();
    cr.np = np;
    cr.Hm = Hm;
    cr.seed = sp.seed;
    let mid = <i32>Math.ceil(npF / 2);
    for (let i = 1; i <= np; i++) {
        let t = (<f64>i - 0.5) / npF * 2 - 1;
        cr.pu[i] = t * 0.7 + randRange(r, -0.12, 0.12);
        cr.ph[i] = Hm * (i == mid ? 1.0 : randRange(r, 0.55, 0.85));
        cr.pw[i] = randRange(r, 0.28, 0.45);
    }
    let W = Hm * 1.15;
    let NU = 36, NV = 10;
    let P: Array<f64> = [0.0];
    for (let i = 0; i <= NU; i++) {
        let u = <f64>i / <f64>NU * 2 - 1;
        let hc = cr.at(u);
        let vc = (mathx.noise2(u * 2.3, sp.seed * 0.3) - 0.5) * 0.3;
        for (let j = 0; j <= NV; j++) {
            let v = <f64>j / <f64>NV * 2 - 1;
            let dv = Math.abs(v - vc) / (1 + Math.abs(vc));
            let y = hc * Math.pow(1 - dv, 1.12);
            y += (mathx.noise2(u * 7 + v * 2, v * 5 + sp.seed * 0.7) - 0.5) * hc * 0.12 * (1 - dv) * dv * 4;
            if (j == 0 || j == NV) y = -6;
            let lu = u * L, lv = v * W;
            P.push(sp.x + lu * ca - lv * sa);
            P.push(y);
            P.push(sp.z + lu * sa + lv * ca);
        }
    }
    let tc = sp.tones[1], tm = sp.tones[2], tb = sp.tones[3];
    let first = b.vcount;
    for (let i = 0; i <= NU; i++) {
        for (let j = 0; j <= NV; j++) {
            let o = (i * (NV + 1) + j) * 3;
            let x = P[o + 1], y = P[o + 2], z = P[o + 3];
            let a = (max(i - 1, 0) * (NV + 1) + j) * 3;
            let c = (min(i + 1, NU) * (NV + 1) + j) * 3;
            let d = (i * (NV + 1) + max(j - 1, 0)) * 3;
            let e = (i * (NV + 1) + min(j + 1, NV)) * 3;
            let ux = P[c + 1] - P[a + 1], uy = P[c + 2] - P[a + 2], uz = P[c + 3] - P[a + 3];
            let vx = P[e + 1] - P[d + 1], vy = P[e + 2] - P[d + 2], vz = P[e + 3] - P[d + 3];
            let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
            if (ny < 0) {
                nx = -nx;
                ny = -ny;
                nz = -nz;
            }
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz) + 1e-9;
            let k = lclamp(y / lmax(Hm, 1), 0, 1);
            let hx = k > 0.55 ? tc : (k > 0.18 ? tm : tb);
            meshgen.color(b, hx);
            meshgen.vertex(b, x, y, z, nx / l, ny / l, nz / l);
        }
    }
    for (let i = 0; i < NU; i++) {
        for (let j = 0; j < NV; j++) {
            let a = first + i * (NV + 1) + j;
            let c = a + NV + 1;
            let oa = (i * (NV + 1) + j) * 3, ob = ((i + 1) * (NV + 1) + j) * 3, oc = (i * (NV + 1) + j + 1) * 3;
            let ax = P[oa + 1], az = P[oa + 3];
            let bx = P[ob + 1], bz = P[ob + 3];
            let cx = P[oc + 1], cz = P[oc + 3];
            let ny = (bz - az) * (cx - ax) - (bx - ax) * (cz - az);
            if (ny >= 0) {
                meshgen.tri(b, a, c, c + 1);
                meshgen.tri(b, a, c + 1, a + 1);
            } else {
                meshgen.tri(b, a, c + 1, c);
                meshgen.tri(b, a, a + 1, c + 1);
            }
        }
    }
    meshgen.setPaint(b, col0, aux0);
}

// Ground height of a headland's top at world (wx, wz) (ignores the lean).
export function groundAt(sp: HeadSpec, wx: f64, wz: f64): f64 {
    let c = Math.cos(sp.yaw), s = Math.sin(sp.yaw);
    let dx = wx - sp.x, dz = wz - sp.z;
    return new HeightFn(sp).at(dx * c + dz * s, -dx * s + dz * c);
}

// Violet block stacks ----------------------------------------------------------------

export class BlocksSpec {
    x: f64 = 0;
    z: f64 = 0;
    w: f64 = 1; // half width (local x)
    d: f64 = 1; // half depth (local z)
    h: f64 = 1; // top height
    yaw: f64 = 0;
    seed: f64 = 0;
    look: Look = VIOLET;
    blocks: f64 = NaN;
    shrink: f64 = NaN; // per block footprint shrink
    lean: f64 = NaN; // per block offset (fraction)
    base: f64 = NaN;
    ink: f64 = NaN;
    foam: bool = true; // Luau nil reaches headland's foam ~= false
    square: f64 = NaN;
    far: bool = false; // cheap silhouette: fewer columns, no boulders / shrubs / cracks
}

// Stack of rounded stone blocks with frosted tops. Returns the top height.
export function blocks(b: Builder, sp: BlocksSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let nb = <i32>(isNaN(sp.blocks) ? mathx.randInt(r, 2, 4) : sp.blocks);
    let shrink = opt(sp.shrink, 0.86);
    let lean = opt(sp.lean, 0.14);
    let y = opt(sp.base, -4);
    let w = sp.w, d = sp.d;
    let cx = sp.x, cz = sp.z;
    let yaw = sp.yaw;
    let weights: Array<f64> = [0.0];
    let tot = 0.0;
    for (let i = 1; i <= nb; i++) {
        weights.push(randRange(r, 0.6, 1.4) * (1 - <f64>(i - 1) * 0.08));
        tot += weights[i];
    }
    let span = sp.h - y;
    let top = y;
    for (let i = 1; i <= nb; i++) {
        let bh = span * weights[i] / tot;
        let y1 = y + bh;
        let hs = new HeadSpec();
        hs.x = cx;
        hs.z = cz;
        hs.yaw = yaw;
        hs.rx = w;
        hs.rz = d;
        hs.h = y1;
        hs.base = i == 1 ? y : y - 1;
        hs.seed = sp.seed + <f64>i * 97;
        hs.look = sp.look;
        // (draw order of the Luau table constructor)
        hs.dome = lmin(w, d) * randRange(r, 0.04, 0.1);
        hs.hills = 0;
        hs.square = isNaN(sp.square) ? randRange(r, 3.2, 5) : sp.square;
        hs.bulge = randRange(r, 0.02, 0.07);
        hs.rough = 0.07;
        hs.taper = randRange(r, 0.0, 0.07);
        hs.lip = 0.045;
        hs.drape = lmin(randRange(r, 2, 4), bh * 0.3);
        hs.spurs = 0.04;
        hs.crack = sp.far ? 0 : 0.4;
        hs.fracture = 0.55;
        hs.cols = sp.far ? 14 : NaN;
        hs.boulders = i == 1 && !sp.far ? Math.floor((w + d) / 14) : 0;
        hs.tufts = i == nb && !sp.far ? Math.floor(lmin(w, d) * 0.12) : 0;
        hs.ink = sp.ink;
        hs.foam = i == 1 ? sp.foam : false;
        hs.collide = false;
        hs.rowH = lmax(4, bh / 3);
        hs.under = sp.look.strata[3];
        hs.tier = 1;
        top = headland(b, hs, null);
        y = y1;
        w *= shrink * randRange(r, 0.88, 1.1);
        d *= shrink * randRange(r, 0.88, 1.1);
        let ox = randRange(r, -lean, lean) * sp.w;
        let oz = randRange(r, -lean, lean) * sp.d;
        cx += ox * Math.cos(yaw) - oz * Math.sin(yaw);
        cz += ox * Math.sin(yaw) + oz * Math.cos(yaw);
        yaw += randRange(r, -0.2, 0.2);
    }
    if (cols != null) {
        let lo = lmin(sp.w, sp.d);
        if (lmax(sp.w, sp.d) / lo < 1.4) {
            cols.push(coll.cylinder(sp.x, sp.z, (sp.w + sp.d) * 0.45, -6, top));
        } else {
            cols.push(coll.yawBox(sp.x, (top - 6) * 0.5, sp.z, sp.yaw, sp.w * 0.88, (top + 6) * 0.5, sp.d * 0.88));
        }
    }
    return top;
}

// Block arch: two stacks joined by a frosted lintel. (x, z): opening center
// on the water; (rx, rz): unit across the opening.
export class BlockArchSpec {
    x: f64 = 0;
    z: f64 = 0;
    rx: f64 = 1;
    rz: f64 = 0;
    halfW: f64 = 1;
    height: f64 = 1; // underside of the lintel
    leg: f64 = 1; // leg half width
    depth: f64 = 1; // half depth (along the view)
    lintel: f64 = 1; // lintel thickness
    seed: f64 = 0;
    look: Look = VIOLET;
    legTop: f64 = NaN;
}

export function blockArch(b: Builder, sp: BlockArchSpec, cols: Array<Collider>?): void {
    let r = mathx.rng(sp.seed);
    let yaw = Math.atan2(sp.rz, sp.rx);
    let top = sp.height + sp.lintel;
    for (let sd = -1; sd <= 1; sd += 2) {
        let side = <f64>sd;
        let off = (sp.halfW + sp.leg) * side;
        let bs = new BlocksSpec();
        bs.x = sp.x + sp.rx * off;
        bs.z = sp.z + sp.rz * off;
        bs.w = sp.leg;
        bs.d = sp.depth;
        bs.h = (isNaN(sp.legTop) ? top + sp.lintel * 0.5 : sp.legTop) + randRange(r, -2, 6);
        bs.yaw = yaw + randRange(r, -0.06, 0.06);
        bs.seed = sp.seed + side * 7 + 7;
        bs.look = sp.look;
        bs.blocks = mathx.randInt(r, 2, 4);
        bs.shrink = 0.95;
        bs.lean = 0.05;
        bs.foam = true;
        blocks(b, bs, cols);
    }
    let L = sp.halfW + sp.leg * 1.5;
    let hs = new HeadSpec();
    hs.x = sp.x;
    hs.z = sp.z;
    hs.yaw = yaw;
    hs.rx = L;
    hs.rz = sp.depth * 0.92;
    hs.h = top;
    hs.base = sp.height;
    hs.seed = sp.seed + 3;
    hs.look = sp.look;
    hs.dome = sp.lintel * 0.12;
    hs.square = 4.5;
    hs.bulge = 0.03;
    hs.rough = 0.05;
    hs.taper = 0;
    hs.lip = 0.03;
    hs.drape = lmin(3.5, sp.lintel * 0.35);
    hs.spurs = 0.03;
    hs.crack = 0.35;
    hs.fracture = 0.5;
    hs.boulders = 0;
    hs.tufts = 2;
    hs.foam = false;
    hs.collide = false;
    hs.rowH = sp.lintel / 2.5;
    hs.under = sp.look.strata[3];
    headland(b, hs, null);
    if (cols != null) {
        cols.push(coll.box(sp.x, sp.height + sp.lintel * 0.5, sp.z, mathx.v3(sp.rx, 0, sp.rz), Vector.xyz(0, 1, 0), mathx.v3(-sp.rz, 0, sp.rx), L * 0.95, sp.lintel * 0.5, sp.depth * 0.85));
    }
}

// Cliff wall along the rail -------------------------------------------------------

// What WallSpec.rail returns: rail position and right (horizontal unit).
export class RailPt {
    p: Vector = Vector.xyz(0, 0, 0);
    rt: Vector = Vector.xyz(1, 0, 0);
}

export type WallFn = (s: f64) => f64;
export type RailFn = (s: f64) => RailPt;

export class WallSpec {
    s0: f64 = 0; // this piece
    s1: f64 = 0;
    gs0: f64 = 0; // whole wall (end caps, end taper)
    gs1: f64 = 0;
    side: f64 = 1; // +1 right of the rail, -1 left
    dist: WallFn; // inner face lateral distance at the waterline
    height: WallFn; // cliff edge height
    depth: f64 = 0; // how far the top runs inland
    step: f64 = 1;
    seed: f64 = 0;
    look: Look = COAST;
    rail: RailFn; // position, right (horizontal unit) (Luau's two returns)
    rise: f64 = NaN; // the top climbs this much toward the back
    hills: f64 = NaN;
    lean: f64 = NaN; // face lean back (fraction of height)
    drape: f64 = NaN;
    buttress: f64 = NaN; // rib protrusion (m)
    ink: f64 = NaN;
    foam: bool = true; // Luau: foam ~= false
    rowH: f64 = NaN;
    taperEnds: f64 = NaN; // columns over which the ends taper down
    crenel: f64 = NaN; // jagged top edge amplitude (m)
    constructor(dist: WallFn, height: WallFn, rail: RailFn) {
        this.dist = dist;
        this.height = height;
        this.rail = rail;
    }
}

class WCol {
    x: Array<f64> = [0.0]; // 1-based
    y: Array<f64> = [0.0];
    z: Array<f64> = [0.0];
    cx: Array<f64> = [0.0];
    cy: Array<f64> = [0.0];
    cz: Array<f64> = [0.0];
    ox: f64 = 0;
    oz: f64 = 0;
    h: f64 = 0;
    crack: bool = false;
}

const WALL_CAP_F: StaticArray<f64> = [0, 0.035, 0.12, 0.3, 0.6, 1]; // 1-based
const WALL_NCAP: i32 = 5;

// wall's P(q, m): the grass top grid point (lip row m = 1, then cap rows)
let WP_X: f64 = 0, WP_Y: f64 = 0, WP_Z: f64 = 0;
function wallP(data: Array<WCol>, nr: i32, q: i32, m: i32): void {
    let c = data[q];
    if (m == 1) {
        WP_X = c.x[nr];
        WP_Y = c.y[nr];
        WP_Z = c.z[nr];
        return;
    }
    WP_X = c.cx[m - 1];
    WP_Y = c.cy[m - 1];
    WP_Z = c.cz[m - 1];
}

// end cap (only at the whole wall's ends)
function wallCap(b: Builder, look: Look, nr: i32, c: WCol, fx: f64, fz: f64): void {
    let px: Array<f64> = [0.0], py: Array<f64> = [0.0], pz: Array<f64> = [0.0];
    for (let j = 1; j <= nr; j++) {
        px.push(c.x[j]);
        py.push(c.y[j]);
        pz.push(c.z[j]);
    }
    let l = c.cx.length - 1;
    for (let m = 1; m <= l; m++) {
        px.push(c.cx[m]);
        py.push(c.cy[m]);
        pz.push(c.cz[m]);
    }
    px.push(c.cx[l] + c.ox * 8);
    py.push(-4);
    pz.push(c.cz[l] + c.oz * 8);
    let np = px.length - 1;
    let mx = 0.0, my = 0.0, mz = 0.0;
    for (let i = 1; i <= np; i++) {
        mx += px[i];
        my += py[i];
        mz += pz[i];
    }
    mx /= <f64>np;
    my /= <f64>np;
    mz /= <f64>np;
    meshgen.color(b, look.strata[2]);
    for (let i = 1; i <= np; i++) {
        let i2 = (i % np) + 1;
        meshgen.flatTriFacing(b, px[i], py[i], pz[i], px[i2], py[i2], pz[i2], mx, my, mz, fx, 0, fz);
    }
}

// foam: the face's waterline point (x, z) of a column
let WY0_X: f64 = 0, WY0_Z: f64 = 0;
function wallAtY0(cc: WCol): void {
    let f = saturate(4 / (cc.y[2] + 4));
    WY0_X = cc.x[1] + (cc.x[2] - cc.x[1]) * f;
    WY0_Z = cc.z[1] + (cc.z[2] - cc.z[1]) * f;
}

// colliders: innermost lateral point of the face rows (ribs, ledges)
let WIN_X: f64 = 0, WIN_Z: f64 = 0;
function wallInnerXZ(cc: WCol): void {
    let bx = cc.x[2], bz = cc.z[2];
    let best = HUGE;
    let ny = cc.y.length - 1;
    for (let j = 2; j <= ny - 1; j++) {
        if (cc.y[j] < 34) {
            let d = (cc.x[j] - cc.x[1]) * cc.ox + (cc.z[j] - cc.z[1]) * cc.oz;
            if (d < best) {
                best = d;
                bx = cc.x[1] + cc.ox * d;
                bz = cc.z[1] + cc.oz * d;
            }
        }
    }
    WIN_X = bx;
    WIN_Z = bz;
}

export function wall(b: Builder, sp: WallSpec, cols: Array<Collider>?): void {
    let side = sp.side;
    let look = sp.look;
    let step = sp.step;
    let k0 = lmax(Math.floor(sp.s0 / step), Math.floor(sp.gs0 / step));
    let k1 = lmin(Math.ceil(sp.s1 / step), Math.ceil(sp.gs1 / step));
    let gk0 = Math.floor(sp.gs0 / step), gk1 = Math.ceil(sp.gs1 / step);
    if (k1 <= k0) return;
    let seed = sp.seed;
    let r = mathx.rng(seed + k0 * 13);
    let rg = mathx.rng(seed); // shared across pieces: strata + ledges line up
    let leanF = opt(sp.lean, 0.12);
    let drape = opt(sp.drape, 2.8);
    let rise = opt(sp.rise, 10);
    let hills = opt(sp.hills, 4);
    let butt = opt(sp.buttress, 5);
    let ends = opt(sp.taperEnds, 3);
    let crenel = opt(sp.crenel, 3);
    // rows are shared by the whole wall so strata continue across pieces
    let nInt = 7;
    let tones = strataRows(rg, look, nInt + 3);
    let ntones = tones.length - 1;
    let ledge: Array<f64> = [0.0];
    let rowJit: Array<f64> = [0.0];
    for (let q = 1; q <= nInt; q++) {
        ledge.push(randRange(rg, -0.9, 0.9));
        rowJit.push(randRange(rg, -0.25, 0.25) / <f64>nInt);
    }
    let data = new Array<WCol>(1);
    for (let k = k0; k <= k1; k += 1) {
        let s = k * step;
        let rp = sp.rail(s);
        let p = rp.p, rt = rp.rt;
        let ox = <f64>rt.x * side, oz = <f64>rt.z * side; // outward (away from the rail)
        let e = lmin(lmin((k - gk0) / ends, (gk1 - k) / ends), 1);
        let h = sp.height(s) * (0.3 + 0.7 * smoothstep(0, 1, e));
        h += (mathx.hash(k * 1.91, seed * 0.07) - 0.5) * crenel * e;
        let d0 = sp.dist(s);
        let crack = mathx.hash(k * 0.731, seed * 0.1) < 0.2;
        let even = mod(k, 2) == 0;
        let ridge = (mathx.noise2(k * 0.55, seed * 0.37) - 0.5) * 6 + (even ? 1 : -1) + (mathx.hash(k * 2.7, seed * 0.37) - 0.5) * 2.2;
        let bt = lmax(0, mathx.noise2(k * 0.16 + 3.3, seed * 0.21) - 0.52) / 0.48;
        let rib = -butt * smoothstep(0, 0.6, bt); // toward the rail
        let c = new WCol();
        c.ox = ox;
        c.oz = oz;
        c.h = h;
        c.crack = crack;
        let dd = drape * (even ? randRange(r, 0.7, 1.3) : randRange(r, 0.15, 0.5));
        dd = lmin(dd, h * 0.3);
        let top1 = h - dd;
        let ys: Array<f64> = [0.0, -4, 0.9 + (mathx.hash(k * 0.7, seed) - 0.5) * 0.3];
        for (let q = 1; q <= nInt - 1; q++) {
            ys.push(0.9 + (top1 - 0.9) * (<f64>q / <f64>nInt + rowJit[q]));
        }
        ys.push(lmax(top1, 1.2));
        ys.push(h);
        let nr = ys.length - 1;
        for (let j = 1; j <= nr; j++) {
            let y = ys[j];
            let t = saturate((y + 4) / lmax(h + 4, 1));
            let lat = d0 + t * h * leanF;
            if (j == 2) {
                lat += 1.1; // wave-cut notch
            }
            if (j > 2 && j < nr - 1) {
                lat += ridge + ledge[min(j - 2, nInt)] + rib * (1 - t * 0.6);
                if (crack) lat += 0.8;
            } else if (j >= nr - 1) {
                lat += ridge * 0.6 + rib * 0.4 - (j == nr ? 1.1 : 0.7); // grass overhang
            } else {
                lat += rib * 0.8;
            }
            c.x.push(<f64>p.x + ox * lat);
            c.y.push(y);
            c.z.push(<f64>p.z + oz * lat);
        }
        // cap rows inland
        let dTop = d0 + h * leanF + ridge * 0.6 + rib * 0.4 - 1.1;
        for (let m = 1; m <= WALL_NCAP; m++) {
            let f = WALL_CAP_F[m];
            let lat = dTop + 1.2 + sp.depth * f;
            let y = h + 0.8 + rise * smoothstep(0, 1, f) + hills * (mathx.fbm2(s * 0.011 + seed * 0.1, f * 2.5, 3) / 0.875 - 0.5) * 2 * Math.sqrt(f);
            if (m == 1) y = h + 0.5;
            c.cx.push(<f64>p.x + ox * lat);
            c.cy.push(y);
            c.cz.push(<f64>p.z + oz * lat);
        }
        data.push(c);
    }
    let nCol = data.length - 1;
    let nr = data[1].y.length - 1;
    let v0 = b.vcount, i0 = b.icount;
    let col0 = b.col, aux0 = b.aux;
    meshgen.aux(b, 0, 1, 0, 0);
    // inner face
    for (let q = 1; q <= nCol - 1; q++) {
        let a = data[q], c = data[q + 1];
        let hx = -(a.ox + c.ox) * 0.5, hz = -(a.oz + c.oz) * 0.5;
        for (let j = 1; j <= nr - 1; j++) {
            let tone: f64;
            if (j == 1) tone = look.wet;
            else if (j == nr - 1) tone = look.drape;
            else tone = tones[min(j, ntones)];
            meshgen.color(b, tone);
            quad(b, a.x[j], a.y[j], a.z[j], c.x[j], c.y[j], c.z[j], c.x[j + 1], c.y[j + 1], c.z[j + 1], a.x[j + 1], a.y[j + 1], a.z[j + 1], hx, j == nr - 1 ? 0.4 : 0, hz);
        }
    }
    // grass top: smooth, indexed (lip row + cap rows)
    let grid: Array<Array<i32>> = [[0]];
    let nm = WALL_NCAP + 1;
    let ngrass = look.grass.length - 1;
    for (let q = 1; q <= nCol; q++) {
        let ids: Array<i32> = [0];
        for (let m = 1; m <= nm; m++) {
            wallP(data, nr, q, m);
            let x = WP_X, y = WP_Y, z = WP_Z;
            let qa = max(q - 1, 1), qb = min(q + 1, nCol);
            let ma = max(m - 1, 1), mb = min(m + 1, nm);
            wallP(data, nr, qa, m);
            let ax = WP_X, ay = WP_Y, az = WP_Z;
            wallP(data, nr, qb, m);
            let bx = WP_X, by = WP_Y, bz = WP_Z;
            wallP(data, nr, q, ma);
            let cx = WP_X, cy = WP_Y, cz = WP_Z;
            wallP(data, nr, q, mb);
            let dx = WP_X, dy = WP_Y, dz = WP_Z;
            let ux = bx - ax, uy = by - ay, uz = bz - az;
            let vx = dx - cx, vy = dy - cy, vz = dz - cz;
            let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
            if (ny < 0) {
                nx = -nx;
                ny = -ny;
                nz = -nz;
            }
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
            if (l < 1e-9) {
                nx = 0;
                ny = 1;
                nz = 0;
                l = 1;
            }
            if (m == 1) {
                meshgen.color(b, look.drape);
            } else {
                let g = mathx.noise2(x * 0.03 + seed * 0.01, z * 0.03);
                meshgen.color(b, look.grass[<i32>lclamp(Math.floor(g * <f64>ngrass) + 1, 1, <f64>ngrass)]);
            }
            ids.push(meshgen.vertex(b, x, y, z, nx / l, ny / l, nz / l));
        }
        grid.push(ids);
    }
    for (let q = 1; q <= nCol - 1; q++) {
        for (let m = 1; m <= nm - 1; m++) {
            let a = grid[q][m], bq = grid[q + 1][m], c = grid[q + 1][m + 1], d = grid[q][m + 1];
            // facing up: pick the winding from the first triangle's normal
            wallP(data, nr, q, m);
            let ax = WP_X, az = WP_Z;
            wallP(data, nr, q + 1, m);
            let bx = WP_X, bz = WP_Z;
            wallP(data, nr, q + 1, m + 1);
            let cx = WP_X, cz = WP_Z;
            let ny = (bz - az) * (cx - ax) - (bx - ax) * (cz - az);
            if (ny >= 0) {
                meshgen.tri(b, a, bq, c);
                meshgen.tri(b, a, c, d);
            } else {
                meshgen.tri(b, a, c, bq);
                meshgen.tri(b, a, d, c);
            }
        }
    }
    // back face down to the sea
    meshgen.color(b, look.strata[2]);
    for (let q = 1; q <= nCol - 1; q++) {
        let a = data[q], c = data[q + 1];
        let la = a.cx.length - 1, lc = c.cx.length - 1;
        let bax = a.cx[la] + a.ox * 8, baz = a.cz[la] + a.oz * 8;
        let bcx = c.cx[lc] + c.ox * 8, bcz = c.cz[lc] + c.oz * 8;
        quad(b, a.cx[la], a.cy[la], a.cz[la], c.cx[lc], c.cy[lc], c.cz[lc], bcx, -4, bcz, bax, -4, baz, a.ox, 0.2, a.oz);
    }
    // end caps (only at the whole wall's ends)
    if (k0 == gk0) {
        let c = data[1];
        wallCap(b, look, nr, c, -c.oz * side, c.ox * side);
    }
    if (k1 == gk1) {
        let c = data[nCol];
        wallCap(b, look, nr, c, c.oz * side, -c.ox * side);
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    // cracks
    meshgen.aux(b, 0, 0, 0, 0);
    for (let q = 1; q <= nCol; q++) {
        let c = data[q];
        if (c.crack) {
            let jt = <i32>mathx.randInt(r, 4, <f64>(nr - 2));
            crackStrip(b, r, c.x, c.y, c.z, 2, jt, -c.ox, -c.oz, 0.55, look.crack);
        }
    }
    // waterline foam along the inner face
    if (sp.foam) {
        meshgen.aux(b, 0, 0, 1, 0.25);
        meshgen.color(b, look.foam);
        for (let q = 1; q <= nCol - 1; q++) {
            if (rand(r) < 0.88) {
                let a = data[q], c = data[q + 1];
                wallAtY0(a);
                let ax = WY0_X, az = WY0_Z;
                wallAtY0(c);
                let cx = WY0_X, cz = WY0_Z;
                let wa = randRange(r, 0.8, 2.8), wc = randRange(r, 0.8, 2.8);
                quad(b, ax + a.ox * 0.6, 0.07, az + a.oz * 0.6, cx + c.ox * 0.6, 0.07, cz + c.oz * 0.6, cx - c.ox * wc, 0.07, cz - c.oz * wc, ax - a.ox * wa, 0.07, az - a.oz * wa, 0, 1, 0);
            }
        }
    }
    meshgen.setPaint(b, col0, aux0);
    // colliders: one box per ~2 columns, inner face at the waterline
    if (cols != null) {
        let q = 1;
        while (q < nCol) {
            let q2 = min(q + 2, nCol);
            let a = data[q], c = data[q2];
            wallInnerXZ(a);
            let ax = WIN_X, az = WIN_Z;
            wallInnerXZ(c);
            let cx = WIN_X, cz = WIN_Z;
            let ux = cx - ax, uz = cz - az;
            let ul = Math.sqrt(ux * ux + uz * uz);
            if (ul > 1e-3) {
                ux = ux / ul;
                uz = uz / ul;
                let hgt = lmin(a.h, c.h);
                let wxv = (a.ox + c.ox) * 0.5, wzv = (a.oz + c.oz) * 0.5;
                let wl = Math.sqrt(wxv * wxv + wzv * wzv);
                wxv = wxv / wl;
                wzv = wzv / wl;
                let half = sp.depth * 0.5;
                let mx = (ax + cx) * 0.5 + wxv * (half + 0.3), mz = (az + cz) * 0.5 + wzv * (half + 0.3);
                cols.push(coll.box(mx, (hgt - 6) * 0.5, mz, mathx.v3(ux, 0, uz), Vector.xyz(0, 1, 0), mathx.v3(wxv, 0, wzv), ul * 0.5 + 1, (hgt + 6) * 0.5, half));
            }
            q = q2;
        }
    }
}
