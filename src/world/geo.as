// Port of src/world/geo.luau: procedural geology for the toon renderer (sea
// cliffs and mesas, canyon walls, natural arches, crystal block stacks,
// floating islands, toon cumulus, waterfalls and waterline foam), emitted in
// world space into a meshgen.Builder.
//
// Port rules: Luau sequences stay 1-based (slot 0 a dummy); optional spec
// numbers are NaN ("nil"), defaults with side effects taken by a ternary;
// optional bools default to the value the Luau test treats nil as; closures
// that carry state become classes (Fall); multi-returns go through module
// globals. mass / stack / blockArch / wall / arch / island have no caller in
// the game (ported anyway).
import { Vector } from "rive/vector";
import { clock } from "rive/os";
import { format, FormatArg } from "rive/format";
import * as mathx from "../lib/mathx";
import { Rng, rand, randRange, saturate, TAU } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as coll from "./collide";
import { Collider } from "./collide";
import { HUGE, lmin, lmax, lclamp, mod, opt, sinL, cosL } from "../lib/compat";

function seq(a: Array<f64>): Array<f64> {
    let out: Array<f64> = [0.0];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

@inline function V(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

export class Style {
    rock: Array<f64>; // strata tones, cycled by band (1-based)
    wet: f64; // waterline band
    crack: f64; // vertical cracks
    cap: Array<f64>; // top tones (grass / frost) (1-based)
    drape: f64; // cap spilling over the edge
    lichen: f64; // occasional patch on the walls
    constructor(rock: Array<f64>, wet: f64, crack: f64, cap: Array<f64>, drape: f64, lichen: f64) {
        this.rock = seq(rock);
        this.wet = wet;
        this.crack = crack;
        this.cap = seq(cap);
        this.drape = drape;
        this.lichen = lichen;
    }
}

export const COAST = new Style([0x7884A0, 0x6E7A96, 0x808CA7, 0x73809B], 0x4B5268, 0x535C78,
    [0xAA9F40, 0x9B943A, 0xB5AA4A, 0x8F8A36], 0xA2983C, 0x8F9A6A);

export const VIOLET = new Style([0x7A52C9, 0x6A45B6, 0x8660D6, 0x7049BD], 0x4A2F8E, 0x4E3498,
    [0xBFF3FB, 0x9FE6F6, 0xE8FCFF, 0xAEEBF8], 0xA6E9F7, 0x9A7BE0);

// Waterfall vertex tag for the renderer: aux.z = 1 (unlit), aux.w = 0.5, and
// color alpha carries the flow coordinate (0 at the lip -> 1 at the pool).
export const WATERFALL_SHINY: f64 = 0.5;

@inline function paint(b: Builder, hex: f64): void {
    meshgen.color(b, hex);
}

// Flat quad whose facets face along the hint (hx, hy, hz).
export function quadH(
    b: Builder,
    ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64,
    dx: f64, dy: f64, dz: f64,
    hx: f64, hy: f64, hz: f64
): void {
    meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, hx, hy, hz);
}

function pickTone(r: Rng, t: Array<f64>, i: f64): f64 {
    let n = <f64>(t.length - 1);
    if (rand(r) < 0.06) {
        return t[<i32>mathx.randInt(r, 1, n)];
    }
    return t[<i32>mod(i - 1, n) + 1];
}

// Foam -----------------------------------------------------------------------

// Broken foam lace on the water around a closed ring of points (xs, zs
// around center cx, cz; 1-based): meshgen.laceRing's tapered strokes. Emitted
// unlit, no ink. gaps / foamHex: NaN = default.
export function foamRing(b: Builder, r: Rng, xs: Array<f64>, zs: Array<f64>, cx: f64, cz: f64, width: f64, gaps: f64 = NaN, foamHex: f64 = NaN): void {
    let col = b.col, aux = b.aux;
    paint(b, opt(foamHex, 0xF4FAFF));
    meshgen.aux(b, 0, 0, 1, 0);
    meshgen.laceRing(b, r, xs, zs, cx, cz, width, opt(gaps, 0.12), lmin(0.6, width * 0.5));
    meshgen.setPaint(b, col, aux);
}

// Boulders -------------------------------------------------------------------

export function boulder(b: Builder, r: Rng, x: f64, y: f64, z: f64, s: f64, hex: f64): void {
    paint(b, hex);
    meshgen.rock(b, x, y, z, s, s * randRange(r, 0.55, 0.85), s * randRange(r, 0.75, 1.1), rand(r) * 100, 7, 5);
}

// Rock mass (sea cliff, mesa, stack, crystal block) --------------------------

export class MassSpec {
    x: f64 = 0;
    z: f64 = 0;
    rx: f64 = 0;
    rz: f64 = 0;
    yaw: f64 = 0;
    h: f64 = 0;
    seed: f64 = 0;
    style: Style = COAST;
    base: f64 = NaN; // bottom y (default -4, i.e. rooted in the sea)
    cols: f64 = NaN;
    rough: f64 = NaN;
    taper: f64 = NaN;
    lip: f64 = NaN;
    dome: f64 = NaN;
    drape: f64 = NaN;
    ink: f64 = NaN;
    foam: bool = true; // Luau `foam ~= false`
    boulders: f64 = NaN;
    outline: Array<Vector>? = null; // custom local outline (x, y = local x, z), 1-based
    crack: f64 = NaN; // fraction of columns cracked
    collide: bool = true; // Luau `collide ~= false`
    band: f64 = NaN; // strata band thickness (m)
    capTones: Array<f64>? = null; // 1-based
    leanX: f64 = NaN; // top offset relative to the base (world meters)
    leanZ: f64 = NaN;
}

// mass's toWorld (local -> world, with the current ring's lean)
let TW_X: f64 = 0, TW_Z: f64 = 0;
@inline function toWorld(sp: MassSpec, cyw: f64, syw: f64, leanX: f64, leanZ: f64, lean: f64, ax: f64, az: f64): void {
    TW_X = sp.x + ax * cyw - az * syw + leanX * lean;
    TW_Z = sp.z + ax * syw + az * cyw + leanZ * lean;
}

// Returns the dome-top height.
export function mass(b: Builder, sp: MassSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let st = sp.style;
    let base = opt(sp.base, -4);
    let h = sp.h;
    let rx = sp.rx, rz = sp.rz;
    let cyw = cosL(sp.yaw), syw = sinL(sp.yaw);
    let rough = opt(sp.rough, 0.22);
    let taper = opt(sp.taper, 0.1);
    let lip = opt(sp.lip, 0.035);
    let dome = isNaN(sp.dome) ? lmin(rx, rz) * 0.12 : sp.dome;
    let drape = lmin(opt(sp.drape, 3.2), (h - base) * 0.3);
    let rooted = base < 0.5;
    let ct = sp.capTones;
    let capTones = ct != null ? ct : st.cap;

    // outline (local)
    let lx: Array<f64> = [0.0], lz: Array<f64> = [0.0];
    let custom = sp.outline;
    if (custom != null) {
        for (let i = 1; i < custom.length; i++) {
            let p = custom[i];
            lx.push(<f64>p.x);
            lz.push(<f64>p.y);
        }
    } else {
        let nf = isNaN(sp.cols) ? lclamp(Math.floor((rx + rz) * 0.3) + 10, 10, 34) : sp.cols;
        let ph = rand(r) * 50;
        for (let i = 0.0; i <= nf - 1; i++) {
            let a = -(i + (rand(r) - 0.5) * 0.55) / nf * TAU;
            let ca = Math.cos(a), sa = Math.sin(a);
            let nn = mathx.fbm2(ca * 1.25 + ph, sa * 1.25 + ph * 0.61, 3) / 0.875;
            let k = 1 + rough * (nn - 0.5) * 2.4 + (rand(r) - 0.5) * rough * 0.35;
            lx.push(ca * rx * k);
            lz.push(sa * rz * k);
        }
    }
    let n = lx.length - 1;

    // crack columns
    let crack: Array<f64> = [0.0];
    let crackP = opt(sp.crack, 0.2);
    for (let i = 1; i <= n; i++) {
        crack.push(rand(r) < crackP ? randRange(r, 0.05, 0.11) : 0.0);
    }

    // ring heights and scales
    let ys: Array<f64> = [0.0], sc: Array<f64> = [0.0], cm: Array<f64> = [0.0];
    let bandH = isNaN(sp.band) ? lmax(2.4, (h - base) * 0.14) : sp.band;
    if (rooted) {
        ys.push(base); sc.push(1.07); cm.push(0);
        ys.push(0.8); sc.push(1.045); cm.push(0.3);
    } else {
        ys.push(base); sc.push(1); cm.push(0);
    }
    let topWall = h - drape - 0.3;
    let y = ys[ys.length - 1];
    while (y < topWall - 0.8) {
        y = lmin(topWall, y + bandH * randRange(r, 0.6, 1.4));
        let t = saturate((y - base) / lmax(h - base, 1));
        let s = 1 - taper * Math.pow(t, 1.3) + randRange(r, -0.016, 0.022);
        ys.push(y); sc.push(s); cm.push(1);
    }
    if (ys[ys.length - 1] < topWall - 0.05) {
        let t = saturate((topWall - base) / lmax(h - base, 1));
        ys.push(topWall); sc.push(1 - taper * Math.pow(t, 1.3)); cm.push(1);
    }
    let nWall = ys.length - 1;
    let sTop = sc[nWall];

    // world positions of the wall rings
    let wx: Array<Array<f64>> = [[0.0]], wy: Array<Array<f64>> = [[0.0]], wz: Array<Array<f64>> = [[0.0]];
    let leanX = opt(sp.leanX, 0), leanZ = opt(sp.leanZ, 0);
    let lean = 0.0; // current ring's fraction of the lean (set per ring)
    // vertical ridges: per-column offsets shared by every ring, plus a little per-ring wobble
    let colJ: Array<f64> = [0.0];
    for (let i = 1; i <= n; i++) {
        colJ.push((mathx.hash(<f64>i * 1.37, sp.seed * 0.013) - 0.5) * 0.15);
    }
    for (let j = 1; j <= nWall; j++) {
        let rxw: Array<f64> = [0.0], ryw: Array<f64> = [0.0], rzw: Array<f64> = [0.0];
        lean = Math.pow(saturate((ys[j] - base) / lmax(h - base, 1)), 1.5);
        for (let i = 1; i <= n; i++) {
            let jit = colJ[i] * cm[j] + (mathx.hash3(<f64>i * 1.37, <f64>j * 2.11, sp.seed * 0.013) - 0.5) * 0.022;
            let k = sc[j] + jit - crack[i] * cm[j];
            toWorld(sp, cyw, syw, leanX, leanZ, lean, lx[i] * k, lz[i] * k);
            rxw.push(TW_X);
            ryw.push(ys[j] + (j > 1 && j < nWall ? randRange(r, -0.2, 0.2) : 0.0));
            rzw.push(TW_Z);
        }
        wx.push(rxw);
        wy.push(ryw);
        wz.push(rzw);
    }
    // drape ring (jagged lower edge of the cap spilling over) and lip
    lean = 1;
    let dx: Array<f64> = [0.0], dyy: Array<f64> = [0.0], dz: Array<f64> = [0.0];
    let lpx: Array<f64> = [0.0], lpy: Array<f64> = [0.0], lpz: Array<f64> = [0.0];
    for (let i = 1; i <= n; i++) {
        let deep = i % 2 == 0 ? randRange(r, 0.55, 1) : randRange(r, 0.15, 0.5);
        let k = sTop + lip * 0.5;
        toWorld(sp, cyw, syw, leanX, leanZ, lean, lx[i] * k, lz[i] * k);
        dx.push(TW_X); dyy.push(h - drape * deep); dz.push(TW_Z);
        let k2 = sTop + lip;
        toWorld(sp, cyw, syw, leanX, leanZ, lean, lx[i] * k2, lz[i] * k2);
        lpx.push(TW_X); lpy.push(h + randRange(r, -0.2, 0.25)); lpz.push(TW_Z);
    }
    // cap rings
    let c1x: Array<f64> = [0.0], c1y: Array<f64> = [0.0], c1z: Array<f64> = [0.0];
    let c2x: Array<f64> = [0.0], c2y: Array<f64> = [0.0], c2z: Array<f64> = [0.0];
    for (let i = 1; i <= n; i++) {
        let k1 = (sTop + lip) * 0.78;
        toWorld(sp, cyw, syw, leanX, leanZ, lean, lx[i] * k1, lz[i] * k1);
        c1x.push(TW_X); c1y.push(h + dome * randRange(r, 0.42, 0.62)); c1z.push(TW_Z);
        let k2 = (sTop + lip) * 0.42;
        toWorld(sp, cyw, syw, leanX, leanZ, lean, lx[i] * k2, lz[i] * k2);
        c2x.push(TW_X); c2y.push(h + dome * randRange(r, 0.82, 0.95)); c2z.push(TW_Z);
    }
    toWorld(sp, cyw, syw, leanX, leanZ, lean, 0, 0);
    let ccx = TW_X, ccz = TW_Z;
    let ccy = h + dome;

    let v0 = b.vcount, i0 = b.icount;
    // walls
    let bandOff = mathx.randInt(r, 0, 3);
    for (let j = 1; j <= nWall - 1; j++) {
        let ax = wx[j], ay = wy[j], az = wz[j], bx = wx[j + 1], by = wy[j + 1], bz = wz[j + 1];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let hx = (ax[i] + ax[i2]) * 0.5 - ccx, hz = (az[i] + az[i2]) * 0.5 - ccz;
            let tone: f64;
            if (rooted && j == 1) {
                tone = st.wet;
            } else if ((crack[i] > 0 || crack[i2] > 0) && cm[j] > 0.5) {
                tone = st.crack;
            } else {
                tone = pickTone(r, st.rock, <f64>j + bandOff);
            }
            paint(b, tone);
            quadH(b, ax[i], ay[i], az[i], ax[i2], ay[i2], az[i2], bx[i2], by[i2], bz[i2], bx[i], by[i], bz[i], hx, 0, hz);
        }
    }
    // top wall ring -> drape ring (rock), drape ring -> lip (cap spill)
    let jt = nWall;
    {
        let ax = wx[jt], ay = wy[jt], az = wz[jt];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let hx = (ax[i] + ax[i2]) * 0.5 - ccx, hz = (az[i] + az[i2]) * 0.5 - ccz;
            paint(b, pickTone(r, st.rock, <f64>jt + bandOff));
            quadH(b, ax[i], ay[i], az[i], ax[i2], ay[i2], az[i2], dx[i2], dyy[i2], dz[i2], dx[i], dyy[i], dz[i], hx, 0, hz);
            paint(b, st.drape);
            quadH(b, dx[i], dyy[i], dz[i], dx[i2], dyy[i2], dz[i2], lpx[i2], lpy[i2], lpz[i2], lpx[i], lpy[i], lpz[i], hx, 0.3, hz);
        }
    }
    // cap
    let toneSeed = rand(r) * 10;
    let nct = <f64>(capTones.length - 1);
    for (let i = 1; i <= n; i++) {
        let i2 = (i % n) + 1;
        let ci = Math.floor(mathx.noise2(<f64>i * 0.45 + toneSeed, 0.5) * nct) + 1;
        paint(b, capTones[<i32>lclamp(ci, 1, nct)]);
        quadH(b, lpx[i], lpy[i], lpz[i], lpx[i2], lpy[i2], lpz[i2], c1x[i2], c1y[i2], c1z[i2], c1x[i], c1y[i], c1z[i], 0, 1, 0);
        let cj = Math.floor(mathx.noise2(<f64>i * 0.45 + toneSeed, 3.5) * nct) + 1;
        paint(b, capTones[<i32>lclamp(cj, 1, nct)]);
        quadH(b, c1x[i], c1y[i], c1z[i], c1x[i2], c1y[i2], c1z[i2], c2x[i2], c2y[i2], c2z[i2], c2x[i], c2y[i], c2z[i], 0, 1, 0);
        meshgen.flatTriFacing(b, c2x[i], c2y[i], c2z[i], c2x[i2], c2y[i2], c2z[i2], ccx, ccy, ccz, 0, 1, 0);
    }
    // underside for floating masses
    if (!rooted) {
        paint(b, st.wet);
        let byy = base;
        let w1x = wx[1], w1z = wz[1];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            meshgen.flatTriFacing(b, w1x[i], byy, w1z[i], w1x[i2], byy, w1z[i2], ccx, byy, ccz, 0, -1, 0);
        }
    }
    // boulders at the waterline
    let nb = !isNaN(sp.boulders) ? sp.boulders : (rooted ? Math.floor((rx + rz) / 9) : 0.0);
    if (rooted && nb > 0) {
        let wl = 2;
        for (let q = 1.0; q <= nb; q++) {
            let i = <i32>mathx.randInt(r, 1, <f64>n);
            let ox = wx[wl][i] - ccx, oz = wz[wl][i] - ccz;
            let l = Math.sqrt(ox * ox + oz * oz);
            let s = lclamp(lmin(rx, rz) * randRange(r, 0.05, 0.13), 0.8, 5.5);
            let d = l + s * randRange(r, 0.1, 0.9);
            boulder(b, r, ccx + ox / l * d, s * randRange(r, 0.0, 0.3), ccz + oz / l * d, s, rand(r) < 0.6 ? st.wet : st.rock[2]);
        }
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));

    // foam at the waterline
    if (rooted && sp.foam) {
        let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
        for (let i = 1; i <= n; i++) {
            fx.push(wx[2][i]);
            fz.push(wz[2][i]);
        }
        foamRing(b, r, fx, fz, ccx, ccz, lclamp((rx + rz) * 0.035, 0.9, 3.2));
    }

    // colliders
    if (cols != null && sp.collide) {
        let y0 = rooted ? -6.0 : base;
        let y1 = h + dome * 0.5;
        let long = lmax(rx, rz), short = lmin(rx, rz);
        let cr = short * (1 - taper * 0.35) * (1 - rough * 0.4);
        if (long / short < 1.35) {
            cols.push(coll.cylinder(ccx, ccz, (rx + rz) * 0.5 * (1 - taper * 0.35) * (1 - rough * 0.4), y0, y1));
        } else {
            // chain of cylinders along the long axis
            let ax = rx >= rz ? cyw : -syw, az = rx >= rz ? syw : cyw;
            let span = long - short;
            let k = Math.ceil(span / (short * 0.8)) + 1;
            for (let q = 0.0; q <= k - 1; q++) {
                let t = k > 1 ? (q / (k - 1)) * 2 - 1 : 0.0;
                let ell = Math.sqrt(lmax(0.2, 1 - Math.pow(t * span / long, 2)));
                cols.push(coll.cylinder(ccx + ax * t * span, ccz + az * t * span, cr * ell, y0, y1));
            }
        }
    }
    return ccy;
}

// Chamfered-rectangle outline for crystal blocks (local x, z in Vector.xy), 1-based.
export function blockOutline(r: Rng, hx: f64, hz: f64, chamfer: f64): Array<Vector> {
    let cm = lmin(hx, hz) * 0.6;
    let c1 = lmin(chamfer * randRange(r, 0.4, 1.5), cm);
    let c2 = lmin(chamfer * randRange(r, 0.4, 1.5), cm);
    let c3 = lmin(chamfer * randRange(r, 0.4, 1.5), cm);
    let c4 = lmin(chamfer * randRange(r, 0.4, 1.5), cm);
    // raw points, x then z (the Luau table constructor's draw order)
    let raw: Array<f64> = [];
    raw.push(hx); raw.push(hz - c1);
    raw.push(hx - c1); raw.push(hz);
    raw.push(randRange(r, -0.3, 0.3) * hx); raw.push(hz * (1 + randRange(r, -0.07, 0.07) * 1.6));
    raw.push(-hx + c2); raw.push(hz);
    raw.push(-hx); raw.push(hz - c2);
    raw.push(-hx * (1 + randRange(r, -0.07, 0.07) * 1.6)); raw.push(randRange(r, -0.3, 0.3) * hz);
    raw.push(-hx); raw.push(-hz + c3);
    raw.push(-hx + c3); raw.push(-hz);
    raw.push(randRange(r, -0.3, 0.3) * hx); raw.push(-hz * (1 + randRange(r, -0.07, 0.07) * 1.6));
    raw.push(hx - c4); raw.push(-hz);
    raw.push(hx); raw.push(-hz + c4);
    raw.push(hx * (1 + randRange(r, -0.07, 0.07) * 1.6)); raw.push(randRange(r, -0.3, 0.3) * hz);
    let pts: Array<Vector> = [];
    for (let k = 0; k < 12; k++) {
        let px = raw[k * 2] * (1 + randRange(r, -0.07, 0.07));
        let pz = raw[k * 2 + 1] * (1 + randRange(r, -0.07, 0.07));
        pts.push(Vector.xy(<f32>px, <f32>pz));
    }
    // decreasing angle order
    let out: Array<Vector> = [Vector.xy(0, 0)];
    for (let i = 11; i >= 0; i--) out.push(pts[i]);
    return out;
}

// Stack of crystal blocks (violet biome): each step keeps a frosted ledge.
export class StackSpec {
    x: f64 = 0;
    z: f64 = 0;
    w: f64 = 0; // half width (local x)
    d: f64 = 0; // half depth (local z)
    h: f64 = 0; // total height
    yaw: f64 = 0;
    seed: f64 = 0;
    style: Style = VIOLET;
    blocks: f64 = NaN;
    shrink: f64 = NaN; // per block footprint shrink
    lean: f64 = NaN; // per block offset (fraction)
    ink: f64 = NaN;
    foam: bool = true; // passed to the first block's mass (Luau nil -> `~= false`)
    base: f64 = NaN;
}

export function stack(b: Builder, sp: StackSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let nb = isNaN(sp.blocks) ? mathx.randInt(r, 2, 4) : sp.blocks;
    let shrink = opt(sp.shrink, 0.88);
    let lean = opt(sp.lean, 0.2);
    let y = opt(sp.base, -4);
    let w = sp.w, d = sp.d;
    let cx = sp.x, cz = sp.z;
    let yaw = sp.yaw;
    let top = y;
    // heights per block: bottom tallest
    let weights: Array<f64> = [0.0];
    let tot = 0.0;
    for (let i = 1.0; i <= nb; i++) {
        let wt = randRange(r, 0.55, 1.5) * (1 - (i - 1) * 0.1);
        weights.push(wt);
        tot += wt;
    }
    let span = sp.h - y;
    for (let i = 1; <f64>i <= nb; i++) {
        let bh = span * weights[i] / tot;
        let y1 = y + bh;
        let ms = new MassSpec();
        ms.x = cx;
        ms.z = cz;
        ms.rx = w;
        ms.rz = d;
        ms.yaw = yaw;
        ms.h = y1;
        ms.base = i == 1 ? y : y - 0.6;
        ms.seed = sp.seed + <f64>i * 97;
        ms.style = sp.style;
        let chamfer = lmin(w, d) * randRange(r, 0.2, 0.45);
        ms.outline = blockOutline(r, w, d, chamfer);
        ms.rough = 0;
        ms.taper = randRange(r, 0.02, 0.1);
        ms.lip = 0.02;
        ms.dome = lmin(w, d) * 0.08;
        ms.drape = lmin(3.2, bh * 0.25);
        ms.band = lmax(3, bh * 0.3);
        ms.crack = 0.15;
        ms.ink = sp.ink;
        ms.foam = i == 1 ? sp.foam : false;
        ms.boulders = i == 1 ? NaN : 0;
        ms.collide = false;
        top = mass(b, ms, null);
        y = y1;
        // next block: usually smaller, shifted, twisted (sometimes overhanging)
        w *= shrink * randRange(r, 0.86, 1.12);
        d *= shrink * randRange(r, 0.86, 1.12);
        let ox = randRange(r, -lean, lean) * sp.w, oz = randRange(r, -lean, lean) * sp.d;
        cx += ox * cosL(yaw) - oz * sinL(yaw);
        cz += ox * sinL(yaw) + oz * cosL(yaw);
        yaw += randRange(r, -0.25, 0.25);
    }
    if (cols != null) {
        let rl = lmax(sp.w, sp.d);
        if (rl / lmin(sp.w, sp.d) < 1.4) {
            cols.push(coll.cylinder(sp.x, sp.z, (sp.w + sp.d) * 0.45, -6, top));
        } else {
            cols.push(coll.yawBox(sp.x, (top - 6) * 0.5, sp.z, sp.yaw, sp.w * 0.88, (top + 6) * 0.5, sp.d * 0.88));
        }
    }
    return top;
}

// Block arch (violet): two crystal stacks joined by a frosted lintel.
// (x, z) is the opening center on the water; (rx, rz) runs across the opening.
export class BlockArchSpec {
    x: f64 = 0;
    z: f64 = 0;
    rx: f64 = 0;
    rz: f64 = 0;
    halfW: f64 = 0; // opening half width
    height: f64 = 0; // underside of the lintel
    leg: f64 = 0; // leg half width
    depth: f64 = 0; // half depth (along the view)
    lintel: f64 = 0; // lintel thickness
    seed: f64 = 0;
    style: Style = VIOLET;
    legTop: f64 = NaN; // legs rise above the lintel (default: lintel top + a bit)
}

export function blockArch(b: Builder, sp: BlockArchSpec, cols: Array<Collider>?): void {
    let r = mathx.rng(sp.seed);
    let yaw = Math.atan2(sp.rz, sp.rx);
    let top = sp.height + sp.lintel;
    for (let side = -1.0; side <= 1; side += 2) {
        let off = (sp.halfW + sp.leg) * side;
        let ss = new StackSpec();
        ss.x = sp.x + sp.rx * off;
        ss.z = sp.z + sp.rz * off;
        ss.w = sp.leg;
        ss.d = sp.depth;
        ss.h = (isNaN(sp.legTop) ? top + sp.lintel * 0.6 : sp.legTop) + randRange(r, -2, 6);
        ss.yaw = yaw + randRange(r, -0.08, 0.08);
        ss.seed = sp.seed + side * 7 + 7;
        ss.style = sp.style;
        ss.blocks = mathx.randInt(r, 2, 4);
        ss.shrink = 0.96;
        ss.lean = 0.06;
        ss.foam = true;
        stack(b, ss, cols);
    }
    // lintel: a slab with a frosted top, slightly sagging in the middle
    let L = sp.halfW + sp.leg * 1.6;
    let outline = blockOutline(r, L, sp.depth * 0.92, sp.depth * 0.4);
    let ms = new MassSpec();
    ms.x = sp.x;
    ms.z = sp.z;
    ms.rx = 1;
    ms.rz = 1;
    ms.yaw = yaw;
    ms.h = top;
    ms.base = sp.height;
    ms.seed = sp.seed + 3;
    ms.style = sp.style;
    ms.outline = outline;
    ms.rough = 0;
    ms.taper = 0;
    ms.lip = 0.015;
    ms.dome = sp.lintel * 0.25;
    ms.drape = lmin(3, sp.lintel * 0.4);
    ms.band = sp.lintel * 0.5;
    ms.crack = 0.25;
    ms.foam = false;
    ms.boulders = 0;
    ms.collide = false;
    mass(b, ms, null);
    if (cols != null) {
        cols.push(coll.box(sp.x, sp.height + sp.lintel * 0.5, sp.z, V(sp.rx, 0, sp.rz), V(0, 1, 0), V(-sp.rz, 0, sp.rx), L * 0.95, sp.lintel * 0.5, sp.depth * 0.85));
    }
}

// Canyon wall following the rail --------------------------------------------

// The rail sample a WallSpec.rail returns (Luau's two returns).
export class WallRail {
    p: Vector; // position
    right: Vector; // right (horizontal unit)
    constructor(p: Vector, right: Vector) {
        this.p = p;
        this.right = right;
    }
}

export class WallSpec {
    s0: f64 = 0; // this piece
    s1: f64 = 0;
    gs0: f64 = 0; // whole wall (for end caps and height envelope)
    gs1: f64 = 0;
    side: f64 = 1; // +1 right, -1 left
    dist: (s: f64) => f64 = (s: f64): f64 => 0; // inner face lateral distance
    height: (s: f64) => f64 = (s: f64): f64 => 0;
    depth: f64 = 0;
    step: f64 = 1;
    seed: f64 = 0;
    style: Style = COAST;
    ink: f64 = NaN;
    rail: (s: f64) => WallRail = (s: f64): WallRail => new WallRail(Vector.xyz(0, 0, 0), Vector.xyz(1, 0, 0));
}

class WallCol {
    ix: Array<f64> = [0.0];
    iy: Array<f64> = [0.0];
    iz: Array<f64> = [0.0];
    tx: Array<f64> = [0.0];
    ty: Array<f64> = [0.0];
    tz: Array<f64> = [0.0];
    rx: f64 = 0;
    rz: f64 = 0;
    h: f64 = 0;
    crack: bool = false;
}

// end cap: polygon of the inner face bottom->top, top strip, outer bottom
function wallCap(b: Builder, st: Style, rows: i32, c: WallCol, fx: f64, fz: f64): void {
    let px: Array<f64> = [0.0], py: Array<f64> = [0.0], pz: Array<f64> = [0.0];
    for (let j = 1; j <= rows + 1; j++) {
        px.push(c.ix[j]);
        py.push(c.iy[j]);
        pz.push(c.iz[j]);
    }
    for (let m = 1; m <= 4; m++) {
        px.push(c.tx[m]);
        py.push(c.ty[m]);
        pz.push(c.tz[m]);
    }
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
    paint(b, st.rock[1]);
    for (let i = 1; i <= np; i++) {
        let i2 = (i % np) + 1;
        meshgen.flatTriFacing(b, px[i], py[i], pz[i], px[i2], py[i2], pz[i2], mx, my, mz, fx, 0, fz);
    }
}

export function wall(b: Builder, sp: WallSpec, cols: Array<Collider>?): void {
    let side = sp.side;
    let rows = 7;
    let st = sp.style;
    let k0 = Math.floor(sp.s0 / sp.step);
    let k1 = Math.ceil(sp.s1 / sp.step);
    let gk0 = Math.floor(sp.gs0 / sp.step);
    let gk1 = Math.ceil(sp.gs1 / sp.step);
    k0 = lmax(k0, gk0);
    k1 = lmin(k1, gk1);
    if (k1 <= k0) return;
    let seed = sp.seed;
    // per column samples
    let colsData: Array<WallCol> = [new WallCol()];
    for (let k = k0; k <= k1; k++) {
        let s = k * sp.step;
        let rl = sp.rail(s);
        let p = rl.p, rt = rl.right;
        let px = <f64>p.x, pz = <f64>p.z;
        let rxv = <f64>rt.x * side, rzv = <f64>rt.z * side;
        let h = sp.height(s);
        // taper the ends down
        let e = lmin(lmin((k - gk0) / 3, (gk1 - k) / 3), 1);
        h = h * (0.35 + 0.65 * e);
        let d0 = sp.dist(s);
        let crack = mathx.hash(k * 0.731, seed) < 0.22;
        let c = new WallCol();
        c.rx = rxv;
        c.rz = rzv;
        c.h = h;
        c.crack = crack;
        let ridge = (mathx.noise2(k * 0.9, seed * 0.37) - 0.5) * 7 + (mathx.hash(k * 2.7, seed * 0.37) - 0.5) * 2.5;
        for (let j = 0; j <= rows; j++) {
            let jf = <f64>j;
            let t = jf / <f64>rows;
            let y = -4 + (h + 4) * t;
            let mid = j > 0 && j < rows;
            if (mid) {
                y += (mathx.hash(k * 1.3, jf * 7.1 + seed) - 0.5) * 0.8;
            }
            let ledge = (mathx.hash(jf * 3.3, seed * 0.11) - 0.5) * 2.6;
            let lean = t * h * 0.12 + ridge * (mid ? 1 : 0.6) + (mid ? ledge : 0.0) + (mathx.hash(k * 2.7 + jf, seed * 0.37) - 0.5) * 0.6 + (crack && mid ? 3 : 0.0);
            if (j == rows) {
                lean -= 0.8; // lip overhang
            }
            let d = d0 + lean;
            c.ix.push(px + rxv * d);
            c.iy.push(y);
            c.iz.push(pz + rzv * d);
        }
        // top strip: lip, mid (dome), outer lip; then the outer face bottom
        let dm = d0 + sp.depth * 0.5;
        let dOut = d0 + sp.depth;
        let ym = h + 3 + mathx.hash(k * 0.37, seed) * 4;
        c.tx.push(px + rxv * (d0 + h * 0.12 + 3));
        c.ty.push(h + 1.2);
        c.tz.push(pz + rzv * (d0 + h * 0.12 + 3));
        c.tx.push(px + rxv * dm);
        c.ty.push(ym);
        c.tz.push(pz + rzv * dm);
        c.tx.push(px + rxv * dOut);
        c.ty.push(h * 0.8);
        c.tz.push(pz + rzv * dOut);
        c.tx.push(px + rxv * (dOut + 4));
        c.ty.push(-4);
        c.tz.push(pz + rzv * (dOut + 4));
        colsData.push(c);
    }
    let nCol = colsData.length - 1;
    let r = mathx.rng(seed + k0 * 13);
    let v0 = b.vcount, i0 = b.icount;
    let bandOff = mod(seed, 4);
    let ncap = <f64>(st.cap.length - 1);
    for (let q = 1; q <= nCol - 1; q++) {
        let a = colsData[q], c = colsData[q + 1];
        let hx = -(a.rx + c.rx) * 0.5, hz = -(a.rz + c.rz) * 0.5; // inner face looks at the rail
        for (let j = 1; j <= rows; j++) {
            let tone: f64;
            if (j == 1) {
                tone = st.wet;
            } else if ((a.crack || c.crack) && j < rows) {
                tone = st.crack;
            } else {
                tone = pickTone(r, st.rock, <f64>j + bandOff);
            }
            if (j == rows) {
                // jagged drape spill on the top row
                tone = rand(r) < 0.55 ? st.drape : pickTone(r, st.rock, <f64>j + bandOff);
            }
            paint(b, tone);
            quadH(b, a.ix[j], a.iy[j], a.iz[j], c.ix[j], c.iy[j], c.iz[j], c.ix[j + 1], c.iy[j + 1], c.iz[j + 1], a.ix[j + 1], a.iy[j + 1], a.iz[j + 1], hx, 0, hz);
        }
        // lip -> top strip
        let L = rows + 1;
        paint(b, st.drape);
        quadH(b, a.ix[L], a.iy[L], a.iz[L], c.ix[L], c.iy[L], c.iz[L], c.tx[1], c.ty[1], c.tz[1], a.tx[1], a.ty[1], a.tz[1], hx * 0.3, 1, hz * 0.3);
        for (let m = 1; m <= 2; m++) {
            paint(b, st.cap[<i32>mod(<f64>(q + m), ncap) + 1]);
            quadH(b, a.tx[m], a.ty[m], a.tz[m], c.tx[m], c.ty[m], c.tz[m], c.tx[m + 1], c.ty[m + 1], c.tz[m + 1], a.tx[m + 1], a.ty[m + 1], a.tz[m + 1], 0, 1, 0);
        }
        paint(b, st.rock[2]);
        quadH(b, a.tx[3], a.ty[3], a.tz[3], c.tx[3], c.ty[3], c.tz[3], c.tx[4], c.ty[4], c.tz[4], a.tx[4], a.ty[4], a.tz[4], -hx, 0, -hz);
    }
    // end caps (only at the whole wall's ends)
    // rail right = (rx, rz) * side; forward = (right.z, -right.x)
    if (k0 == gk0) {
        let c = colsData[1];
        wallCap(b, st, rows, c, -c.rz * side, c.rx * side); // faces back along the rail
    }
    if (k1 == gk1) {
        let c = colsData[nCol];
        wallCap(b, st, rows, c, c.rz * side, -c.rx * side);
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    // waterline foam along the inner face
    let fcol = b.col, faux = b.aux;
    meshgen.aux(b, 0, 0, 1, 0);
    paint(b, 0xF4FAFF);
    for (let q = 1; q <= nCol - 1; q++) {
        if (rand(r) < 0.85) {
            let a = colsData[q], c = colsData[q + 1];
            let fa = saturate(4 / (a.iy[2] + 4));
            let ax = a.ix[1] + (a.ix[2] - a.ix[1]) * fa, az = a.iz[1] + (a.iz[2] - a.iz[1]) * fa;
            let fc = saturate(4 / (c.iy[2] + 4));
            let cx = c.ix[1] + (c.ix[2] - c.ix[1]) * fc, cz = c.iz[1] + (c.iz[2] - c.iz[1]) * fc;
            let wa = randRange(r, 0.8, 2.6), wc = randRange(r, 0.8, 2.6);
            quadH(b, ax + a.rx * 0.5, 0.07, az + a.rz * 0.5, cx + c.rx * 0.5, 0.07, cz + c.rz * 0.5, cx - c.rx * wc, 0.07, cz - c.rz * wc, ax - a.rx * wa, 0.07, az - a.rz * wa, 0, 1, 0);
        }
    }
    meshgen.setPaint(b, fcol, faux);
    // colliders: one box per ~2 columns
    if (cols != null) {
        let q = 1;
        while (q < nCol) {
            let q2 = q + 2 < nCol ? q + 2 : nCol;
            let a = colsData[q], c = colsData[q2];
            // inner face bottom points (row 2 ~ waterline)
            let ax = a.ix[2], az = a.iz[2];
            let cx = c.ix[2], cz = c.iz[2];
            let ux = cx - ax, uz = cz - az;
            let ul = Math.sqrt(ux * ux + uz * uz);
            if (ul > 1e-3) {
                ux = ux / ul;
                uz = uz / ul;
                let hgt = lmin(a.h, c.h);
                let wxv = (a.rx + c.rx) * 0.5, wzv = (a.rz + c.rz) * 0.5;
                let half = sp.depth * 0.5;
                let mx = (ax + cx) * 0.5 + wxv * (half + 0.8), mz = (az + cz) * 0.5 + wzv * (half + 0.8);
                cols.push(coll.box(mx, (hgt - 6) * 0.5, mz, V(ux, 0, uz), V(0, 1, 0), V(wxv, 0, wzv), ul * 0.5 + 1, (hgt + 6) * 0.5, half));
            }
            q = q2;
        }
    }
}

// Natural arch sweeping across the rail ---------------------------------------

export class ArchSpec {
    x: f64 = 0; // center on the water (world)
    z: f64 = 0;
    rx: f64 = 0; // across-rail unit (right)
    rz: f64 = 0;
    fx: f64 = 0; // along-rail unit (forward)
    fz: f64 = 0;
    halfW: f64 = 0; // opening half width
    height: f64 = 0; // opening height (intrados crown)
    thick: f64 = 0; // crown thickness
    depth: f64 = 0; // half depth along the rail
    seed: f64 = 0;
    style: Style = COAST;
    ink: f64 = NaN;
    feet: f64 = NaN; // foot thickening
}

class ArchRing {
    x: Array<f64> = [0.0];
    y: Array<f64> = [0.0];
    z: Array<f64> = [0.0];
    cx: f64 = 0;
    cy: f64 = 0;
    cz: f64 = 0;
}

export function arch(b: Builder, sp: ArchSpec, cols: Array<Collider>?): void {
    let r = mathx.rng(sp.seed);
    let st = sp.style;
    let N = 30; // path samples
    let M_ = 12; // cross-section points
    let feet = opt(sp.feet, 2.2);
    let rings: Array<ArchRing> = [new ArchRing()];
    // path: foot below water -> superellipse crown -> other foot
    let pathX: Array<f64> = [0.0], pathY: Array<f64> = [0.0], nX: Array<f64> = [0.0], nY: Array<f64> = [0.0], thick: Array<f64> = [0.0];
    for (let k = 0; k <= N; k++) {
        let t = <f64>k / <f64>N;
        let th = Math.PI * (1 - t); // left (-W) to right (+W)
        let cx = Math.cos(th);
        let sy = Math.sin(th);
        let px = cx * sp.halfW;
        let py = sp.height * Math.pow(sy, 0.6);
        // extend the feet under the water
        let foot = Math.pow(1 - sy, 2);
        py = py - foot * 6;
        pathX.push(px);
        pathY.push(py);
        // outward normal of the intrados (away from the opening)
        let nx = cx / sp.halfW, ny = sy / lmax(sp.height, 1);
        let nl = Math.sqrt(nx * nx + ny * ny);
        nX.push(nx / nl);
        nY.push(ny / nl);
        thick.push(sp.thick * (1 + feet * foot) * (0.85 + 0.3 * mathx.noise2(<f64>k * 0.4, sp.seed * 0.01)));
    }
    for (let k = 1; k <= N + 1; k++) {
        let kf = <f64>k;
        let ring = new ArchRing();
        let T = thick[k];
        let D = sp.depth * (1 + 0.7 * (1 - Math.sin(Math.PI * (kf - 1) / <f64>N)));
        let nx = nX[k], ny = nY[k];
        // cross-section: u along normal (0..T), v along the rail (-D..D)
        let cu = T * 0.5, cv = 0.0;
        for (let m = 0; m < M_; m++) {
            let mf = <f64>m;
            let a = mf / <f64>M_ * TAU;
            let nu = 1 + (mathx.noise2(mf * 1.7 + sp.seed * 0.01, kf * 0.35) - 0.5) * 0.35;
            let nv = 1 + (mathx.noise2(mf * 2.3 + 5, kf * 0.3 + sp.seed * 0.01) - 0.5) * 0.3;
            let u = T * 0.5 + Math.cos(a) * T * 0.5 * nu;
            let v = Math.sin(a) * D * nv;
            // blocky: square it up a little
            let sq = 0.35;
            u = T * 0.5 + (u - T * 0.5) * (1 + sq * (1 - Math.abs(Math.cos(a * 2))));
            let ax = pathX[k] + nx * u;
            let ay = pathY[k] + ny * u;
            let wx = sp.x + sp.rx * ax + sp.fx * v;
            let wz = sp.z + sp.rz * ax + sp.fz * v;
            ring.x.push(wx);
            ring.y.push(ay);
            ring.z.push(wz);
        }
        let ax = pathX[k] + nx * cu;
        ring.cx = sp.x + sp.rx * ax + sp.fx * cv;
        ring.cy = pathY[k] + ny * cu;
        ring.cz = sp.z + sp.rz * ax + sp.fz * cv;
        rings.push(ring);
    }
    let v0 = b.vcount, i0 = b.icount;
    let ncap = <f64>(st.cap.length - 1);
    for (let k = 1; k <= N; k++) {
        let A = rings[k], B = rings[k + 1];
        for (let m = 1; m <= M_; m++) {
            let m2 = (m % M_) + 1;
            let mx = (A.x[m] + A.x[m2] + B.x[m] + B.x[m2]) * 0.25;
            let my = (A.y[m] + A.y[m2] + B.y[m] + B.y[m2]) * 0.25;
            let mz = (A.z[m] + A.z[m2] + B.z[m] + B.z[m2]) * 0.25;
            let hx = mx - (A.cx + B.cx) * 0.5, hy = my - (A.cy + B.cy) * 0.5, hz = mz - (A.cz + B.cz) * 0.5;
            let hl = Math.sqrt(hx * hx + hy * hy + hz * hz);
            let up = hl > 0 ? hy / hl : 0.0;
            let tone: f64;
            if (up > 0.6 && my > sp.height * 0.5) {
                tone = st.cap[<i32>mod(<f64>(k + m), ncap) + 1];
            } else if (up > 0.45 && my > sp.height * 0.5 && rand(r) < 0.6) {
                tone = st.drape;
            } else if (my < 1.2) {
                tone = st.wet;
            } else {
                let band = Math.floor((my + 40) / 5.5);
                tone = pickTone(r, st.rock, band);
            }
            paint(b, tone);
            quadH(b, A.x[m], A.y[m], A.z[m], A.x[m2], A.y[m2], A.z[m2], B.x[m2], B.y[m2], B.z[m2], B.x[m], B.y[m], B.z[m], hx, hy, hz);
        }
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    // foam at both feet
    for (let f = 0; f < 2; f++) {
        let R = rings[f == 0 ? 1 : N + 1];
        let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
        let cx = 0.0, cz = 0.0;
        for (let m = 1; m <= M_; m++) {
            // project the ring to the waterline
            fx.push(R.x[m]);
            fz.push(R.z[m]);
            cx += R.x[m];
            cz += R.z[m];
        }
        foamRing(b, r, fx, fz, cx / <f64>M_, cz / <f64>M_, 2.2);
    }
    if (cols != null) {
        // boxes along the path
        let k = 1;
        while (k <= N) {
            let k2 = k + 2 < N + 1 ? k + 2 : N + 1;
            let ax = pathX[k] + nX[k] * thick[k] * 0.5, ay = pathY[k] + nY[k] * thick[k] * 0.5;
            let bx = pathX[k2] + nX[k2] * thick[k2] * 0.5, by = pathY[k2] + nY[k2] * thick[k2] * 0.5;
            let tx = bx - ax, ty = by - ay;
            let tl = Math.sqrt(tx * tx + ty * ty);
            if (tl > 1e-3) {
                tx = tx / tl;
                ty = ty / tl;
                let mx = (ax + bx) * 0.5, my = (ay + by) * 0.5;
                let T = (thick[k] + thick[k2]) * 0.5;
                let wx = sp.x + sp.rx * mx;
                let wz = sp.z + sp.rz * mx;
                let u = V(sp.rx * tx, ty, sp.rz * tx);
                let w = V(sp.fx, 0, sp.fz);
                let v = mathx.norm(mathx.cross(w, u));
                cols.push(coll.box(wx, my, wz, u, v, w, tl * 0.5 + 1, T * 0.42, sp.depth * 0.9));
            }
            k = k2;
        }
    }
}

// Floating island ---------------------------------------------------------------

export class IslandSpec {
    x: f64 = 0;
    y: f64 = 0; // top rim height
    z: f64 = 0;
    r: f64 = 0;
    depth: f64 = 0; // how far the rocky root hangs
    seed: f64 = 0;
    style: Style = COAST;
    ink: f64 = NaN;
    wall: f64 = NaN; // short cliff wall under the rim
}

class IslandRing {
    x: Array<f64> = [0.0];
    y: Array<f64> = [0.0];
    z: Array<f64> = [0.0];
}

export function island(b: Builder, sp: IslandSpec, cols: Array<Collider>?): f64 {
    let r = mathx.rng(sp.seed);
    let st = sp.style;
    let wallH = isNaN(sp.wall) ? sp.r * 0.35 : sp.wall;
    let ms = new MassSpec();
    ms.x = sp.x;
    ms.z = sp.z;
    ms.rx = sp.r;
    ms.rz = sp.r * randRange(r, 0.7, 1);
    ms.yaw = rand(r) * TAU;
    ms.h = sp.y;
    ms.base = sp.y - wallH;
    ms.seed = sp.seed;
    ms.style = st;
    ms.rough = 0.26;
    ms.taper = -0.05;
    ms.dome = sp.r * 0.18;
    ms.drape = lmin(2.8, wallH * 0.4);
    ms.ink = sp.ink;
    ms.foam = false;
    ms.boulders = 0;
    ms.collide = false;
    ms.cols = lclamp(Math.floor(sp.r * 0.6) + 9, 9, 22);
    let top = mass(b, ms, null);
    // hanging root: inverted jagged cone
    let n = <i32>lclamp(Math.floor(sp.r * 0.5) + 7, 7, 16);
    let nf = <f64>n;
    let ph = rand(r) * 10;
    let levels: Array<f64> = [0.0, 0, 0.3, 0.58, 0.82, 1];
    let scales: Array<f64> = [0.0, 1.1, 0.8, 0.52, 0.22, 0];
    let nLev = levels.length - 1;
    let rings: Array<IslandRing> = [new IslandRing()];
    let tipX = sp.x + randRange(r, -0.15, 0.15) * sp.r, tipZ = sp.z + randRange(r, -0.15, 0.15) * sp.r;
    for (let li = 1; li <= nLev; li++) {
        let lv = levels[li];
        let ring = new IslandRing();
        let yy = sp.y - wallH - sp.depth * lv + (li == 1 ? 1.2 : 0.0);
        let cx = sp.x + (tipX - sp.x) * lv;
        let cz = sp.z + (tipZ - sp.z) * lv;
        for (let i = 0; i < n; i++) {
            let a = -(<f64>i / nf) * TAU;
            let k = scales[li] * sp.r * (0.8 + 0.4 * mathx.noise2(Math.cos(a) * 1.6 + ph + lv * 2, Math.sin(a) * 1.6));
            ring.x.push(cx + Math.cos(a) * k);
            ring.y.push(yy + (li > 1 && li < nLev ? randRange(r, -1.2, 1.2) : 0.0));
            ring.z.push(cz + Math.sin(a) * k);
        }
        rings.push(ring);
    }
    let v0 = b.vcount, i0 = b.icount;
    let nR = rings.length - 1;
    for (let li = 1; li <= nR - 1; li++) {
        let A = rings[li], B = rings[li + 1];
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            let hx = (A.x[i] + A.x[i2]) * 0.5 - sp.x;
            let hz = (A.z[i] + A.z[i2]) * 0.5 - sp.z;
            paint(b, li == 1 ? st.rock[1] : pickTone(r, st.rock, <f64>(li + 1)));
            if (li == nR - 1) {
                meshgen.flatTriFacing(b, A.x[i], A.y[i], A.z[i], A.x[i2], A.y[i2], A.z[i2], B.x[1], B.y[1], B.z[1], hx, -0.6, hz);
            } else {
                quadH(b, A.x[i], A.y[i], A.z[i], A.x[i2], A.y[i2], A.z[i2], B.x[i2], B.y[i2], B.z[i2], B.x[i], B.y[i], B.z[i], hx, -0.5, hz);
            }
        }
    }
    meshgen.inkShell(b, v0, i0, opt(sp.ink, 1));
    if (cols != null) {
        cols.push(coll.cylinder(sp.x, sp.z, sp.r * 0.82, sp.y - wallH - sp.depth * 0.45, top - 0.5));
    }
    return top;
}

// Toon cumulus: a cluster of smooth puffs sharing a flat base. -----------------

// Smooth ellipsoid whose vertices below `base` are pressed flat onto it.
function puff(b: Builder, cx: f64, cy: f64, cz: f64, rx: f64, ry: f64, rz: f64, base: f64): void {
    let seg = 14, rings = 9;
    let first = b.vcount;
    for (let j = 0; j <= rings; j++) {
        let ph = <f64>j / <f64>rings * Math.PI;
        for (let i = 0; i <= seg; i++) {
            let th = <f64>i / <f64>seg * TAU;
            let x = Math.sin(ph) * Math.cos(th);
            let y = Math.cos(ph);
            let z = Math.sin(ph) * Math.sin(th);
            let py = cy + y * ry;
            let nx = x / rx, ny = y / ry, nz = z / rz;
            if (py < base) {
                py = base;
                nx = nx * 0.35;
                ny = -1;
                nz = nz * 0.35;
            }
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
            meshgen.vertex(b, cx + x * rx, py, cz + z * rz, nx / l, ny / l, nz / l);
        }
    }
    for (let j = 0; j < rings; j++) {
        for (let i = 0; i < seg; i++) {
            let a = first + j * (seg + 1) + i;
            let c = a + seg + 1;
            meshgen.tri(b, a, a + 1, c + 1);
            meshgen.tri(b, a, c + 1, c);
        }
    }
}

export class CloudSpec {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    sx: f64 = 0;
    sy: f64 = 0;
    sz: f64 = 0;
    puffs: f64 = 0;
    seed: f64 = 0;
    tint: f64 = NaN;
    ink: f64 = NaN;
}

// Low churn of puffs sharing a flat base (waterfall splash).
export function puffCluster(b: Builder, sp: CloudSpec): void {
    let r = mathx.rng(sp.seed);
    let col = b.col, aux = b.aux;
    paint(b, opt(sp.tint, 0xFFFFFF));
    meshgen.aux(b, 0.04, opt(sp.ink, 0.75), 0, 0);
    let base = sp.y - sp.sy * 0.12;
    let n = lmax(sp.puffs, 3);
    let nBase = Math.ceil(n * 0.5);
    let nMid = Math.ceil(n * 0.85);
    let spreadT: Array<f64> = [0.0, 1, 0.55, 0.25];
    let sizeT: Array<f64> = [0.0, 0.32, 0.3, 0.27];
    let liftT: Array<f64> = [0.0, 0.2, 0.62, 1.0];
    for (let i = 1.0; i <= n; i++) {
        let tier = i <= nBase ? 1 : i <= nMid ? 2 : 3;
        let a = rand(r) * TAU;
        let d = Math.sqrt(rand(r)) * spreadT[tier];
        let px = sp.x + Math.cos(a) * d * sp.sx;
        let pz = sp.z + Math.sin(a) * d * sp.sz;
        let rad = lmax(sp.sx, sp.sz) * sizeT[tier] * randRange(r, 0.8, 1.2);
        let py = base + liftT[tier] * sp.sy * randRange(r, 0.85, 1.15);
        puff(b, px, py, pz, rad, rad * randRange(r, 0.8, 0.95), rad * randRange(r, 0.85, 1.05), base);
    }
    meshgen.setPaint(b, col, aux);
}

// Toon cumulus: ONE welded surface per cloud, the union of squashed lobes
// seen from a center near its base (a star-shaped hull), so there are no
// seams or inner ink rims between billows. A wide base row cut flat by the
// condensation plane, a dome of medium lobes piled into towers and a crown,
// and small billows crowding their tops. Normals are the surface's own,
// averaged, then leaned toward the cloud's overall ellipsoid so the cel band
// sweeps across the whole mass (lit crown, cool shaded belly) instead of
// ringing every lobe.
// Lobes live in flat arrays (center rel. to the hull center, 1/radius^2,
// view cone, 1-based), rays test only the lobes whose cone they fall in.
let LX: Array<f64> = [0.0], LY: Array<f64> = [0.0], LZ: Array<f64> = [0.0];
let IAX: Array<f64> = [0.0], IAY: Array<f64> = [0.0], IAZ: Array<f64> = [0.0];
let LC: Array<f64> = [0.0], CX: Array<f64> = [0.0], CY: Array<f64> = [0.0], CZ: Array<f64> = [0.0], CA: Array<f64> = [0.0];
const C_SEG = 56, C_RINGS = 28;
// hull rays (1-based: x, y, z per grid point at (j * SEG + i) * 3 + 1)
const SCRATCH_P = new StaticArray<f64>((C_RINGS + 1) * C_SEG * 3 + 1);

// Luau's M.CLOUD_TIMING flag: set through cloudTiming (a library has no
// log here, so the timing lines go to `log`).
let CLOUD_TIMING: bool = false;
let CLOUD_LOG: ((s: string) => void)? = null;
export function cloudTiming(on: bool, log: ((s: string) => void)?): void {
    CLOUD_TIMING = on;
    CLOUD_LOG = log;
}

// A cumulus hull sampled around its center (built by cloudPlan, emitted by
// cloudEmit: two bake steps of ~1-2 ms each instead of one long one).
export class CloudHull {
    P: Array<f64> = [0.0]; // x, y, z per grid point, relative to (ox, oy, oz) (1-based)
    seg: i32 = 0;
    rings: i32 = 0;
    ox: f64 = 0;
    oy: f64 = 0;
    oz: f64 = 0;
    baseRel: f64 = 0;
    ex: f64 = 0;
    ey: f64 = 0;
    ez: f64 = 0;
    hh: f64 = 0;
    tint: f64 = 0;
    ink: f64 = 0;
}

// Cloud plan state between its bake steps (lobes live in the module scratch
// arrays: one cloud is planned at a time).
export class CloudPlanState {
    sp: CloudSpec;
    s: f64 = 0;
    hh: f64 = 0;
    nL: i32 = 0;
    seg: i32 = 0;
    rings: i32 = 0;
    ox: f64 = 0;
    oy: f64 = 0;
    oz: f64 = 0;
    baseRel: f64 = 0;
    ex: f64 = 0;
    ey: f64 = 0;
    ez: f64 = 0;
    ph: Array<f64> = [0.0]; // 1-based
    ar: Array<f64> = [0.0]; // 1-based
    t0: f64 = 0;
    constructor(sp: CloudSpec) {
        this.sp = sp;
    }
}
let CAND: Array<i32> = [0];

// Hull rays of latitude rings j0..j1 (into SCRATCH_P).
function sampleRings(st: CloudPlanState, j0: i32, j1: i32): void {
    let P = SCRATCH_P;
    let cand = CAND;
    let seg = st.seg;
    let segf = <f64>seg;
    for (let j = j0; j <= j1; j++) {
        let ph = <f64>j / <f64>st.rings * Math.PI;
        let sy0 = Math.sin(ph), cy0 = Math.cos(ph);
        let nCand = 0;
        for (let L = 1; L <= st.nL; L++) {
            if (Math.abs(st.ph[L] - ph) <= st.ar[L]) {
                nCand += 1;
                if (nCand < cand.length) cand[nCand] = L;
                else cand.push(L);
            }
        }
        for (let i = 0; i < seg; i++) {
            let th = <f64>i / segf * TAU;
            let dx = sy0 * Math.cos(th), dy = cy0, dz = sy0 * Math.sin(th);
            let tb = dy < -1e-4 ? st.baseRel / dy : HUGE;
            let best = 0.0;
            let dx2 = dx * dx, dy2 = dy * dy, dz2 = dz * dz;
            for (let ci = 1; ci <= nCand; ci++) {
                let L = cand[ci];
                let ca = CA[L];
                if (ca < -1 || dx * CX[L] + dy * CY[L] + dz * CZ[L] > ca) {
                    let ix = IAX[L], iy = IAY[L], iz = IAZ[L];
                    let A = dx2 * ix + dy2 * iy + dz2 * iz;
                    let B = -(LX[L] * dx * ix + LY[L] * dy * iy + LZ[L] * dz * iz);
                    let disc = B * B - A * LC[L];
                    if (disc > 0) {
                        let t = (-B + Math.sqrt(disc)) / A;
                        if (t > best) {
                            best = t;
                            if (best >= tb) break;
                        }
                    }
                }
            }
            if (best <= 0) best = st.s * 0.3;
            if (best > tb) best = tb; // the flat condensation base
            let o = (j * seg + i) * 3;
            P[o + 1] = dx * best;
            P[o + 2] = dy * best;
            P[o + 3] = dz * best;
        }
    }
}

// More hull rays between the plan's steps: rings j0..j1 (scenery splits
// the sampling into several bake steps; same result in any split).
export function cloudRings(st: CloudPlanState, j0: i32, j1: i32): void {
    sampleRings(st, j0, j1);
}

// cloudPlanA's lobe / big closures: their upvalues
let L_N: i32 = 0;
let L_CYW: f64 = 0, L_SYW: f64 = 0, L_OY: f64 = 0;
let BIGS: Array<f64> = [0.0];

function lobe(lx: f64, ly: f64, lz: f64, rad: f64, sqy: f64, sqz: f64): void {
    // lx along the cloud's long axis, lz across; world = rotated by yaw
    let x = lx * L_CYW - lz * L_SYW;
    let z = lx * L_SYW + lz * L_CYW;
    let y = ly - L_OY;
    let ax = rad, ay = rad * sqy, az = rad * sqz;
    L_N += 1;
    let n = L_N;
    if (n >= LX.length) {
        LX.push(0); LY.push(0); LZ.push(0); IAX.push(0); IAY.push(0); IAZ.push(0);
        LC.push(0); CX.push(0); CY.push(0); CZ.push(0); CA.push(0);
    }
    LX[n] = x;
    LY[n] = y;
    LZ[n] = z;
    IAX[n] = 1 / (ax * ax);
    IAY[n] = 1 / (ay * ay);
    IAZ[n] = 1 / (az * az);
    LC[n] = x * x * IAX[n] + y * y * IAY[n] + z * z * IAZ[n] - 1;
    let dist = Math.sqrt(x * x + y * y + z * z);
    let mr = lmax(lmax(ax, ay), az);
    if (dist > mr * 1.001) {
        let sn = mr / dist;
        CA[n] = Math.sqrt(1 - sn * sn);
        CX[n] = x / dist;
        CY[n] = y / dist;
        CZ[n] = z / dist;
    } else {
        CA[n] = -2;
        CX[n] = 0;
        CY[n] = 0;
        CZ[n] = 0;
    }
}

function big(lx: f64, ly: f64, lz: f64, rad: f64, sqy: f64, sqz: f64): void {
    lobe(lx, ly, lz, rad, sqy, sqz);
    BIGS.push(lx);
    BIGS.push(ly);
    BIGS.push(lz);
    BIGS.push(rad);
}

// Cumulus plan, step 1: the lobes, then the upper half of the hull rays
// (rings 0..`upTo`, default (-1) the upper half).
export function cloudPlanA(sp: CloudSpec, upTo: i32 = -1): CloudPlanState {
    let t0c = clock();
    let r = mathx.rng(sp.seed);
    let S = lmax(sp.sx, sp.sz * 0.8);
    let Hh = sp.sy;
    let D = sp.sz;
    let base = sp.y - sp.sy * 0.12;
    // the hull's center: low in the cloud (every lobe must be seen from it)
    let ox = sp.x, oy = base + Hh * 0.36, oz = sp.z;
    let yaw = rand(r) * TAU;
    L_CYW = Math.cos(yaw);
    L_SYW = Math.sin(yaw);
    L_OY = oy;
    L_N = 0;
    BIGS = [0.0];
    // a core body around the center (no ray escapes between the lobes)
    lobe(0, oy, 0, S * 0.32, Hh * 0.3 / (S * 0.32), D * 0.35 / (S * 0.32));
    // base row: squashed lobes along the long axis, cut flat by the base
    let nb = 5 + Math.floor(rand(r) * 3);
    for (let i = 1.0; i <= nb; i++) {
        let t = (i - 0.5) / nb * 2 - 1;
        let rad = S * randRange(r, 0.22, 0.32) * (1 - 0.25 * Math.abs(t));
        let lx = t * S * 0.72 + randRange(r, -0.06, 0.06) * S;
        let lz = randRange(r, -0.4, 0.4) * D;
        let ly = base + rad * randRange(r, 0.25, 0.45);
        let sqy = randRange(r, 0.75, 0.9);
        big(lx, ly, lz, rad, sqy, randRange(r, 0.8, 1));
    }
    let nBase0 = (BIGS.length - 1) / 4;
    // the dome: medium lobes piled higher toward a leading tower
    let lead = randRange(r, -0.3, 0.3) * S;
    let nm = 10 + Math.floor(rand(r) * 5);
    for (let q = 1.0; q <= nm; q++) {
        let h = rand(r);
        let spread = (1 - h * 0.6) * 0.74;
        let lx = lead * h + randRange(r, -1, 1) * S * spread;
        let lz = randRange(r, -0.35, 0.35) * D * (1 - h * 0.5);
        let rad = S * randRange(r, 0.14, 0.24) * (1 - h * 0.2);
        let sqy = randRange(r, 0.8, 0.95);
        big(lx, base + Hh * (0.3 + 0.62 * h), lz, rad, sqy, randRange(r, 0.85, 1));
    }
    // crown
    let nc = 1 + Math.floor(rand(r) * 2);
    for (let q = 1.0; q <= nc; q++) {
        let rad = S * randRange(r, 0.14, 0.2);
        let lx = lead + randRange(r, -0.15, 0.15) * S;
        let ly = base + Hh * randRange(r, 0.9, 1.04);
        let lz = randRange(r, -0.12, 0.12) * D;
        big(lx, ly, lz, rad, randRange(r, 0.85, 1), 1);
    }
    // billows on the upper halves of the big lobes
    let nBig = (BIGS.length - 1) / 4;
    let bigs = BIGS;
    for (let i = nBase0 + 1; i <= nBig; i++) {
        let bx = bigs[i * 4 - 3], by = bigs[i * 4 - 2], bz = bigs[i * 4 - 1], br = bigs[i * 4];
        let k = Math.floor(rand(r) * 3.2);
        for (let q = 1.0; q <= k; q++) {
            let a = rand(r) * TAU;
            let up = randRange(r, 0.3, 0.95);
            let hz = Math.sqrt(1 - up * up);
            let dx = Math.cos(a) * hz, dy = up, dz = Math.sin(a) * hz * 0.7;
            let rad = br * randRange(r, 0.36, 0.55);
            let d = br * randRange(r, 0.7, 0.88);
            lobe(bx + dx * d, by + dy * d * 0.8, bz + dz * d, rad, randRange(r, 0.8, 0.95), 1);
        }
    }
    let nL = L_N;
    // overall extents (for the leaned normal)
    let ex = S * 1.1, ey = Hh * 0.72, ez = D * 0.9;
    // sample the hull on a lat-long grid around the center
    let baseRel = base - oy;
    // each lobe's polar angle and angular radius (rings only test the lobes
    // whose view cone reaches their latitude)
    let st = new CloudPlanState(sp);
    let PH = st.ph, AR = st.ar;
    for (let L = 1; L <= nL; L++) {
        if (CA[L] < -1) {
            PH.push(0);
            AR.push(10);
        } else {
            PH.push(Math.acos(lclamp(CY[L], -1, 1)));
            AR.push(Math.acos(lclamp(CA[L], -1, 1)) + 0.01);
        }
    }
    st.s = S;
    st.hh = Hh;
    st.nL = nL;
    st.seg = C_SEG;
    st.rings = C_RINGS;
    st.ox = ox;
    st.oy = oy;
    st.oz = oz;
    st.baseRel = baseRel;
    st.ex = ex;
    st.ey = ey;
    st.ez = ez;
    st.t0 = clock() - t0c;
    sampleRings(st, 0, upTo >= 0 ? upTo : C_RINGS / 2);
    st.t0 = clock() - t0c;
    return st;
}

// Cumulus plan, step 2: the lower rays (from ring `from`, default (-1) the
// lower half) and one smoothing pass.
export function cloudPlanB(st: CloudPlanState, from: i32 = -1): CloudHull {
    let t1 = clock();
    let P = SCRATCH_P;
    let SEG = st.seg, RINGS = st.rings, baseRel = st.baseRel;
    sampleRings(st, from >= 0 ? from : RINGS / 2 + 1, RINGS);
    let n = (RINGS + 1) * SEG * 3;
    // soften the lat-long facets and the creases between lobes (one pass,
    // off the flat base): rounder billows, no angular ink inside
    let Q = new Array<f64>(n + 1);
    for (let j = 1; j <= RINGS - 1; j++) {
        for (let i = 0; i < SEG; i++) {
            let o = (j * SEG + i) * 3;
            if (P[o + 2] > baseRel + 0.01) {
                let a = (j * SEG + (i + SEG - 1) % SEG) * 3;
                let c = (j * SEG + (i + 1) % SEG) * 3;
                let d = ((j - 1) * SEG + i) * 3;
                let e = ((j + 1) * SEG + i) * 3;
                let r0 = Math.sqrt(Math.pow(P[o + 1], 2) + Math.pow(P[o + 2], 2) + Math.pow(P[o + 3], 2));
                let ra = Math.sqrt(Math.pow(P[a + 1], 2) + Math.pow(P[a + 2], 2) + Math.pow(P[a + 3], 2));
                let rc = Math.sqrt(Math.pow(P[c + 1], 2) + Math.pow(P[c + 2], 2) + Math.pow(P[c + 3], 2));
                let rd = Math.sqrt(Math.pow(P[d + 1], 2) + Math.pow(P[d + 2], 2) + Math.pow(P[d + 3], 2));
                let re = Math.sqrt(Math.pow(P[e + 1], 2) + Math.pow(P[e + 2], 2) + Math.pow(P[e + 3], 2));
                let rs = r0 * 0.5 + (ra + rc + rd + re) * 0.125;
                let k = rs / lmax(r0, 1e-6);
                Q[o + 1] = P[o + 1] * k;
                Q[o + 2] = P[o + 2] * k;
                Q[o + 3] = P[o + 3] * k;
                // stay on or above the base
                if (Q[o + 2] < baseRel) {
                    let kk = baseRel / P[o + 2];
                    Q[o + 1] = P[o + 1] * kk;
                    Q[o + 2] = baseRel;
                    Q[o + 3] = P[o + 3] * kk;
                }
            } else {
                Q[o + 1] = P[o + 1];
                Q[o + 2] = P[o + 2];
                Q[o + 3] = P[o + 3];
            }
        }
    }
    for (let i = 0; i < SEG; i++) {
        let o0 = i * 3;
        let o1 = (RINGS * SEG + i) * 3;
        Q[o0 + 1] = P[o0 + 1];
        Q[o0 + 2] = P[o0 + 2];
        Q[o0 + 3] = P[o0 + 3];
        Q[o1 + 1] = P[o1 + 1];
        Q[o1 + 2] = P[o1 + 2];
        Q[o1 + 3] = P[o1 + 3];
    }
    let sp = st.sp;
    if (CLOUD_TIMING) {
        let lg = CLOUD_LOG;
        if (lg != null) lg(format("cloud plan %d lobes %d ms %.2f + %.2f", [FormatArg.number(sp.seed), FormatArg.number(<f64>st.nL), FormatArg.number(st.t0 * 1000), FormatArg.number((clock() - t1) * 1000)]));
    }
    let h = new CloudHull();
    h.P = Q;
    h.seg = SEG;
    h.rings = RINGS;
    h.ox = st.ox;
    h.oy = st.oy;
    h.oz = st.oz;
    h.baseRel = baseRel;
    h.ex = st.ex;
    h.ey = st.ey;
    h.ez = st.ez;
    h.hh = st.hh;
    h.tint = opt(sp.tint, 0xFFFFFF);
    h.ink = opt(sp.ink, 0.75);
    return h;
}

export function cloudPlan(sp: CloudSpec): CloudHull {
    return cloudPlanB(cloudPlanA(sp));
}

export function cloudEmit(b: Builder, h: CloudHull): void {
    let t0c = clock();
    let col = b.col, aux = b.aux;
    paint(b, h.tint);
    meshgen.aux(b, 0.04, h.ink, 0, 0);
    let P = h.P, SEG = h.seg, RINGS = h.rings;
    let ox = h.ox, oy = h.oy, oz = h.oz, baseRel = h.baseRel;
    let ex = h.ex, ey = h.ey, ez = h.ez, Hh = h.hh;
    let first = b.vcount;
    for (let j = 0; j <= RINGS; j++) {
        for (let i = 0; i < SEG; i++) {
            let o = (j * SEG + i % SEG) * 3;
            let x = P[o + 1], y = P[o + 2], z = P[o + 3];
            // surface normal from the neighbours (central differences)
            let nx: f64, ny: f64, nz: f64;
            if (j == 0) {
                nx = 0; ny = 1; nz = 0;
            } else if (j == RINGS) {
                nx = 0; ny = -1; nz = 0;
            } else {
                let a = (j * SEG + (i - 1 + SEG) % SEG) * 3, c = (j * SEG + (i + 1) % SEG) * 3;
                let d = ((j - 1) * SEG + i % SEG) * 3, e = ((j + 1) * SEG + i % SEG) * 3;
                let ux = P[c + 1] - P[a + 1], uy = P[c + 2] - P[a + 2], uz = P[c + 3] - P[a + 3];
                let vx = P[e + 1] - P[d + 1], vy = P[e + 2] - P[d + 2], vz = P[e + 3] - P[d + 3];
                nx = vy * uz - vz * uy;
                ny = vz * ux - vx * uz;
                nz = vx * uy - vy * ux;
                // outward (away from the center)
                if (nx * x + ny * y + nz * z < 0) {
                    nx = -nx;
                    ny = -ny;
                    nz = -nz;
                }
                let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
                if (l < 1e-9) {
                    nx = x;
                    ny = y;
                    nz = z;
                    l = Math.sqrt(nx * nx + ny * ny + nz * nz) + 1e-9;
                }
                nx = nx / l;
                ny = ny / l;
                nz = nz / l;
            }
            if (y <= baseRel + 0.01) {
                nx = nx * 0.3;
                ny = -1;
                nz = nz * 0.3;
            } else {
                // lean toward the whole cloud's ellipsoid
                let gx = x / (ex * ex), gy = (y + Hh * 0.1) / (ey * ey), gz = z / (ez * ez);
                let gl = Math.sqrt(gx * gx + gy * gy + gz * gz) + 1e-9;
                nx = nx * 0.62 + gx / gl * 0.38;
                ny = ny * 0.62 + gy / gl * 0.38;
                nz = nz * 0.62 + gz / gl * 0.38;
            }
            let l = Math.sqrt(nx * nx + ny * ny + nz * nz) + 1e-9;
            meshgen.vertex(b, ox + x, oy + y, oz + z, nx / l, ny / l, nz / l);
        }
    }
    for (let j = 0; j < RINGS; j++) {
        for (let i = 0; i < SEG; i++) {
            let a = first + j * SEG + i;
            let c = first + j * SEG + (i + 1) % SEG;
            let d = a + SEG;
            let e = c + SEG;
            meshgen.tri(b, a, c, e);
            meshgen.tri(b, a, e, d);
        }
    }
    meshgen.setPaint(b, col, aux);
    if (CLOUD_TIMING) {
        let lg = CLOUD_LOG;
        if (lg != null) lg(format("cloud emit ms %.2f", [FormatArg.number((clock() - t0c) * 1000)]));
    }
}

export function cloud(b: Builder, sp: CloudSpec): void {
    cloudEmit(b, cloudPlan(sp));
}

// Waterfall ribbon --------------------------------------------------------------

export class FallSpec {
    x: f64 = 0; // lip center
    y: f64 = 0; // lip height
    z: f64 = 0;
    bottom: f64 = 0; // pool height (usually 0)
    width: f64 = 0;
    ox: f64 = 0; // outward unit (horizontal, away from the cliff)
    oz: f64 = 0;
    seed: f64 = 0;
    colors: Array<f64> = [0.0]; // streak tones (light first), 1-based
    foam: f64 = 0;
    arc: f64 = NaN; // how far the water arcs out before dropping
    splash: bool = true; // mist puffs at the pool (Luau `splash ~= false`)
    outAt: ((t: f64) => f64)? = null; // outward offset at drop fraction t (replaces the arc)
    // tall free falls (floating islands): the sheet fans out by `spread`
    // (x width at the pool), its streaks give out into spray over the last
    // `ragged` of the drop, white water churns at the lip, and the pool
    // throws up a plume `plume` x the usual churn
    spread: f64 = NaN;
    ragged: f64 = NaN;
    lipFoam: bool = false; // Luau `if lipFoam`
    rim: Array<f64>? = null; // the lip hugs this outline (x, y, z per point, a closed ring, 1-based) instead of running straight
    plume: f64 = NaN;
}

// waterfall's pt / sheet closures (their upvalues), results in X / Y / Z
class Fall {
    sp: FallSpec;
    tx: f64;
    tz: f64;
    rows: f64 = 12;
    nc: f64;
    arc: f64;
    H: f64;
    hasRim: bool = false;
    rimO: Array<f64> = [0.0];
    rimY: Array<f64> = [0.0];
    X: f64 = 0;
    Y: f64 = 0;
    Z: f64 = 0;

    constructor(sp: FallSpec) {
        this.sp = sp;
        this.tx = -sp.oz;
        this.tz = sp.ox;
        this.nc = lclamp(Math.floor(sp.width / 1.6), 4, 14);
        this.arc = isNaN(sp.arc) ? lmin(6, sp.width * 0.4) : sp.arc;
        this.H = sp.y - sp.bottom;
    }

    pt(i: f64, j: f64): void {
        let sp = this.sp;
        let t = j / this.rows;
        let u = (i / this.nc - 0.5);
        let sk = sp.spread;
        let spread = !isNaN(sk) ? 1 + sk * Math.pow(t, 1.5) : 1 + t * 0.35;
        let oa = sp.outAt;
        let out = oa != null ? oa(t) : this.arc * (1 - Math.pow(1 - lmin(t * 3, 1), 2)) + t * 1.5;
        let wob = (mathx.hash(i * 3.1, j * 1.7 + sp.seed) - 0.5) * 0.6;
        let x = sp.x + this.tx * u * sp.width * spread + sp.ox * (out + wob);
        let z = sp.z + this.tz * u * sp.width * spread + sp.oz * (out + wob);
        let y = sp.y - this.H * Math.pow(t, 1.15);
        if (this.hasRim && t < 0.25) {
            let k = 1 - mathx.smoothstep(0, 0.25, t);
            let q = <i32>lclamp(Math.floor(i + 0.5), 0, this.nc) + 1;
            x += sp.ox * this.rimO[q] * k;
            z += sp.oz * this.rimO[q] * k;
            y += this.rimY[q] * k;
        }
        this.X = x;
        this.Y = y;
        this.Z = z;
    }

    sheet(fi: f64, fj: f64, off: f64): void {
        let sp = this.sp;
        let i0 = lmin(Math.floor(fi), this.nc - 1), j0 = Math.floor(fj);
        let u = fi - i0, v = fj - j0;
        this.pt(i0, j0);
        let ax = this.X, ay = this.Y, az = this.Z;
        this.pt(i0 + 1, j0);
        let bx2 = this.X, by2 = this.Y, bz2 = this.Z;
        this.pt(i0, j0 + 1);
        let cx = this.X, cy = this.Y, cz = this.Z;
        this.pt(i0 + 1, j0 + 1);
        let dx = this.X, dy = this.Y, dz = this.Z;
        let w00 = (1 - u) * (1 - v), w10 = u * (1 - v), w01 = (1 - u) * v, w11 = u * v;
        this.X = ax * w00 + bx2 * w10 + cx * w01 + dx * w11 + sp.ox * off;
        this.Y = ay * w00 + by2 * w10 + cy * w01 + dy * w11;
        this.Z = az * w00 + bz2 * w10 + cz * w01 + dz * w11 + sp.oz * off;
    }
}

export function waterfall(b: Builder, sp: FallSpec): void {
    let r = mathx.rng(sp.seed);
    let col = b.col, aux = b.aux;
    let F = new Fall(sp);
    let tx = F.tx, tz = F.tz; // across the fall
    let rows = 12;
    let rowsF = <f64>rows;
    let nc = F.nc;
    let H = F.H;
    // lip on a rim: per column, how far the rim stands out / up from the
    // straight lip line (eased away over the first quarter of the drop)
    let rim = sp.rim;
    if (rim != null) {
        F.hasRim = true;
        let np = (rim.length - 1) / 3;
        for (let i = 0.0; i <= nc; i++) {
            let a = (i / nc - 0.5) * sp.width;
            let best = -HUGE, by = 0.0;
            for (let q = 0; q < np; q++) {
                let o1 = q * 3, o2 = ((q + 1) % np) * 3;
                let ax = rim[o1 + 1] - sp.x, az = rim[o1 + 3] - sp.z;
                let bx = rim[o2 + 1] - sp.x, bz = rim[o2 + 3] - sp.z;
                let la = ax * tx + az * tz, lb = bx * tx + bz * tz;
                if ((la <= a) != (lb <= a)) {
                    let f = (a - la) / (lb - la);
                    let d = (ax + (bx - ax) * f) * sp.ox + (az + (bz - az) * f) * sp.oz;
                    if (d > best) {
                        best = d;
                        by = rim[o1 + 2] + (rim[o2 + 2] - rim[o1 + 2]) * f - sp.y;
                    }
                }
            }
            F.rimO.push(best > -HUGE ? best : 0.0);
            F.rimY.push(by);
        }
    }
    let rowsAlpha: Array<f64> = [0.0];
    for (let j = 0; j <= rows; j++) {
        rowsAlpha.push(<f64>j / rowsF);
    }
    let ncol = <f64>(sp.colors.length - 1);
    // front and back layers (double sided), streak colors per column
    for (let layer = 0; layer <= 1; layer++) {
        let sgn = layer == 0 ? 1.0 : -1.0;
        let off = layer == 0 ? 0.25 : -0.25;
        for (let i = 0.0; i <= nc - 1; i++) {
            let tone = sp.colors[<i32>mod(i, ncol) + 1];
            if (rand(r) < 0.3) {
                tone = sp.colors[<i32>mathx.randInt(r, 1, ncol)];
            }
            mathx.rgb(tone);
            let cr = mathx.RGB_R, cg = mathx.RGB_G, cb = mathx.RGB_B;
            // (ragged: this streak gives out into spray short of the pool)
            let rg = sp.ragged;
            let jEnd = !isNaN(rg) ? rowsF - Math.floor(mathx.hash(i * 1.7 + 0.3, sp.seed * 0.13) * rg * rowsF + 0.5) : rowsF;
            for (let j = 0.0; j <= jEnd - 1; j++) {
                F.pt(i, j);
                let ax = F.X, ay = F.Y, az = F.Z;
                F.pt(i + 1, j);
                let bx = F.X, by = F.Y, bz = F.Z;
                F.pt(i + 1, j + 1);
                let cx = F.X, cy = F.Y, cz = F.Z;
                F.pt(i, j + 1);
                let dx = F.X, dy = F.Y, dz = F.Z;
                ax += sp.ox * off;
                bx += sp.ox * off;
                cx += sp.ox * off;
                dx += sp.ox * off;
                az += sp.oz * off;
                bz += sp.oz * off;
                cz += sp.oz * off;
                dz += sp.oz * off;
                // white lip on the first row
                let lr = cr, lg = cg, lb = cb;
                if (j == 0 && !sp.lipFoam) {
                    lr = 0.97;
                    lg = 1;
                    lb = 1;
                }
                meshgen.aux(b, 0.04, 0, 1, WATERFALL_SHINY);
                // (lipFoam: no flat white first row from the shader's lip
                // band, the foam tongues below are the lip)
                let ra = rowsAlpha[<i32>j + 1];
                meshgen.colorf(b, lr, lg, lb, sp.lipFoam ? lmax(ra, 0.12) : ra);
                meshgen.flatTriFacing(b, ax, ay, az, bx, by, bz, cx, cy, cz, sp.ox * sgn, 0, sp.oz * sgn);
                meshgen.flatTriFacing(b, ax, ay, az, cx, cy, cz, dx, dy, dz, sp.ox * sgn, 0, sp.oz * sgn);
            }
        }
    }
    // splash: foam pool + puffs
    F.pt(nc / 2, rowsF);
    let bx = F.X, bz = F.Z;
    let fx: Array<f64> = [0.0], fz: Array<f64> = [0.0];
    // pool: an ellipse stretched across the fall, hugging its base
    let pw = sp.width * 0.62, pd = lmin(sp.width * 0.4, 7);
    for (let i = 0; i <= 17; i++) {
        let a = -<f64>i / 18 * TAU;
        let ca = Math.cos(a), sa = Math.sin(a);
        let k = randRange(r, 0.85, 1.15);
        fx.push(bx + (tx * ca * pw + sp.ox * sa * pd) * k);
        fz.push(bz + (tz * ca * pw + sp.oz * sa * pd) * k);
    }
    foamRing(b, r, fx, fz, bx, bz, lmin(sp.width * 0.18, 3), 0.05, sp.foam);
    if (sp.splash) {
        // a low churn hugging the base (tall puffs reaching toward the rail
        // read as snowballs when the camera passes at arm's length)
        let pk = opt(sp.plume, 1);
        let pz = lmin(sp.width * 0.3, 4.5) * pk;
        let cs = new CloudSpec();
        cs.x = bx + sp.ox * pz * 0.3;
        cs.y = sp.bottom + 0.3;
        cs.z = bz + sp.oz * pz * 0.3;
        cs.sx = sp.width * 0.62 * Math.sqrt(pk);
        cs.sy = lmin(sp.width * 0.34, 6) * pk;
        cs.sz = pz;
        cs.puffs = pk > 1 ? 11 : 7;
        cs.seed = sp.seed + 3;
        cs.tint = sp.foam;
        cs.ink = 0.35;
        puffCluster(b, cs);
    }
    if (sp.lipFoam) {
        // white water breaking over the lip: ragged tongues of foam down
        // the sheet (uneven band, pointed ends), a bead of churn along the rim
        // tongue length in rows (a few metres whatever the drop)
        let lipRows = lclamp(sp.width * 0.4, 2.5, 6) / lmax(H * Math.pow(1 / rowsF, 1.15), 1e-3);
        let nt = nc * 2;
        mathx.rgb(sp.foam);
        let fr = mathx.RGB_R, fg = mathx.RGB_G, fb = mathx.RGB_B;
        meshgen.aux(b, 0.04, 0, 1, WATERFALL_SHINY);
        for (let layer = 0; layer <= 1; layer++) {
            let sgn = layer == 0 ? 1.0 : -1.0;
            let off = sgn * 0.36;
            for (let k = 0.0; k <= nt - 1; k++) {
                let h0 = mathx.hash(k * 2.3 + 0.7, sp.seed * 0.31);
                let h1 = mathx.hash(k * 2.3 + 3.0, sp.seed * 0.31);
                let hm = mathx.hash(k * 5.1 + 1.9, sp.seed * 0.17);
                let ua = k / nt * nc, ub = (k + 1) / nt * nc;
                let um = ua + (ub - ua) * (0.25 + 0.5 * hm);
                // shoulders (shared with the neighbours), then the point
                let da = lipRows * (0.18 + 0.32 * h0), db = lipRows * (0.18 + 0.32 * h1);
                let dm = lipRows * (mod(k, 3) == 1 ? 0.9 + 0.5 * hm : 0.5 + 0.4 * hm);
                F.sheet(ua, 0, off);
                let ax = F.X, ay = F.Y, az = F.Z;
                F.sheet(ub, 0, off);
                let bx2 = F.X, by2 = F.Y, bz2 = F.Z;
                F.sheet(ub, db, off);
                let cx = F.X, cy = F.Y, cz = F.Z;
                F.sheet(ua, da, off);
                let dx = F.X, dy = F.Y, dz = F.Z;
                F.sheet(um, dm, off);
                let ex = F.X, ey = F.Y, ez = F.Z;
                if (mod(k, 4) == 2) {
                    meshgen.colorf(b, fr * 0.9, fg * 0.96, fb, 0);
                } else {
                    meshgen.colorf(b, fr, fg, fb, 0);
                }
                meshgen.flatTriFacing(b, ax, ay, az, bx2, by2, bz2, cx, cy, cz, sp.ox * sgn, 0, sp.oz * sgn);
                meshgen.flatTriFacing(b, ax, ay, az, cx, cy, cz, dx, dy, dz, sp.ox * sgn, 0, sp.oz * sgn);
                meshgen.flatTriFacing(b, dx, dy, dz, cx, cy, cz, ex, ey, ez, sp.ox * sgn, 0, sp.oz * sgn);
            }
        }
        // the bead: small puffs of uneven size along the lip line, sunk
        // into it (they sit on the rim, the sheet starts under them)
        paint(b, sp.foam);
        meshgen.aux(b, 0.04, 0.35, 0, 0);
        let nb = lclamp(Math.floor(sp.width / 1.2), 7, 13);
        let pr = lclamp(sp.width * 0.085, 0.7, 1.4);
        for (let k = 0.0; k <= nb - 1; k++) {
            let h = mathx.hash(k * 3.7 + 0.2, sp.seed * 0.23);
            let h2 = mathx.hash(k * 1.3 + 5.2, sp.seed * 0.41);
            F.sheet((k + 0.1 + 0.8 * h2) / nb * nc, 0, 0.15);
            let lx = F.X, ly = F.Y, lz = F.Z;
            let rad = pr * (0.5 + 0.85 * h);
            puff(b, lx, ly - rad * 0.3, lz, rad * (1 + 0.5 * h2), rad * 0.85, rad, ly - rad * 3);
        }
    }
    meshgen.setPaint(b, col, aux);
}
