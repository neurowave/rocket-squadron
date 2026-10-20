// Port of src/world/ambient.luau. Per-frame ambient effects keyed to the
// player's rail distance: spray and churning pools at every waterfall, the
// lighthouse lantern with its sweeping beam, and sparkles crawling over the
// two portal rims. Particles and foam discs only; no allocation per frame.
//
// Port: falls and the rims are 1-based (slot 0 a hole); lensFade's optional
// band ends are NaN (nil).
import * as track from "./track";
import * as levelMod from "./level";
import { Gate } from "./level";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import { lmin, lmax, lclamp, opt } from "../lib/compat";

// A waterfall for the effects: lip (x, y, z), pool height, width, outward
// unit (ox, oz), how far the sheet arcs out, and its rail distance.
export class Fall {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    bottom: f64 = 0;
    width: f64 = 0;
    ox: f64 = 0;
    oz: f64 = 0;
    arc: f64 = 0;
    s: f64 = 0;
}

// 1-based
export const falls: Array<Fall> = new Array<Fall>(1);

// Graphics quality (scenery.setQuality): share of the mist puffs, streaks,
// churn blobs and rim sparkles drawn (1: all).
export let density: f64 = 1;
export function setDensity(k: f64): void {
    density = k < 0.1 ? 0.1 : k > 1 ? 1 : k;
}
function thin(n: f64, least: f64): f64 {
    return density < 1 ? lmax(least, Math.floor(n * density + 0.5)) : n;
}

// Registered by scenery.build for every waterfall it bakes.
export function addFall(f: Fall): void {
    falls.push(f);
}

class Rim {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    rx: f64 = 0;
    rz: f64 = 0;
    radius: f64 = 0;
    s: f64 = 0;
    r: f64 = 0;
    g: f64 = 0;
    b: f64 = 0;
}
let rims: Array<Rim>? = null;

function buildRims(): Array<Rim> {
    let out = new Array<Rim>(1);
    let lv: Array<Gate> = [levelMod.portal, levelMod.eye];
    for (let k = 0; k < 2; k++) {
        let g = lv[k];
        let one = k == 0;
        let c = levelMod.world(g.s, g.x, g.y);
        track.frame(levelMod.track, g.s);
        let f = track.FRAME_F;
        let fl = Math.sqrt(<f64>f.x * <f64>f.x + <f64>f.z * <f64>f.z);
        let fx = <f64>f.x / fl, fz = <f64>f.z / fl;
        let m = new Rim();
        m.x = c.x;
        m.y = c.y;
        m.z = c.z;
        m.rx = -fz;
        m.rz = fx;
        m.radius = g.radius + (one ? 4.5 : 5);
        m.s = g.s;
        m.r = one ? 1 : 0.75;
        m.g = one ? 0.9 : 0.95;
        m.b = one ? 0.6 : 1;
        out.push(m);
    }
    return out;
}

@inline function frac(x: f64): f64 {
    return x - Math.floor(x);
}

// Mist near the lens is gone (a puff at arm's length reads as a white ball
// swallowing the frame; a half-faded one over the white sheet keeps only its
// grey ink rim, a soap bubble): 0 inside `d0` m, 1 past `d1` (default
// 16..36), squared so the band where a big puff is half there stays short.
let ex: f64 = 0, ey: f64 = 0, ez: f64 = 0;
function lensFade(x: f64, y: f64, z: f64, d0: f64 = NaN, d1: f64 = NaN): f64 {
    let dx = x - ex, dy = y - ey, dz = z - ez;
    let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
    let a = opt(d0, 16);
    let u = lclamp((d - a) / (opt(d1, 36) - a), 0, 1);
    let k = u * u * (3 - 2 * u);
    return k * k;
}

export function update(r: Gfx, t: f64, s: f64): void {
    // waterfalls: billowing mist off the pool (clusters of soft, translucent
    // puffs at staggered ages that swell, drift out and thin as they rise),
    // mist streaks sliding down the lower face, a churning foam disc
    let nFoam = 0;
    // the renderer learns the eye in frame, after this; a headless capture
    // draws one frame, so fall back to a chase-camera guess when the last
    // eye is nowhere near the rail
    let eye = r.camEye;
    ex = eye.x;
    ey = eye.y;
    ez = eye.z;
    let rp = levelMod.world(s, 0, 0);
    let qx = ex - <f64>rp.x, qy = ey - <f64>rp.y, qz = ez - <f64>rp.z;
    if (qx * qx + qy * qy + qz * qz > 80 * 80) {
        let ge = levelMod.world(s - 9, 0, 4);
        ex = ge.x;
        ey = ge.y;
        ez = ge.z;
    }
    for (let fi = 1; fi < falls.length; fi++) {
        let f = falls[fi];
        let i = <f64>fi;
        let d = f.s - s;
        if (!(d > -120 && d < 950)) continue;
        let near = d < 450;
        let out = f.arc + 1.5;
        let px = f.x + f.ox * out, pz = f.z + f.oz * out;
        let tx = -f.oz, tz = f.ox;
        let drop = f.y - f.bottom;
        let rise = lclamp(drop * 0.14, 3.5, 11);
        let sz0 = lclamp(f.width * 0.07, 1.3, 3.2);
        let nc = thin(lclamp(Math.floor(f.width / 6), 2, 11), 2);
        let np = thin(near ? 7 : 3, 2);
        for (let c = 1.0; c <= nc; c++) {
            let hc = frac(c * 0.618 + i * 0.37);
            let hc2 = frac(c * 0.3819 + i * 0.73);
            let uc = (((c - 0.5) / nc) - 0.5) * f.width * 0.95 + (hc - 0.5) * f.width / nc * 0.6;
            let rate = 0.2 + 0.14 * hc2;
            let lift = 0.5 + 0.8 * hc; // clusters reach different heights
            for (let j = 1.0; j <= np; j++) {
                let hj = frac(j * 0.7548 + c * 0.131 + i * 0.29);
                let age = frac(t * rate + (j - 1) / np + hc);
                let grow = 0.55 + 1.35 * age;
                let u = uc + (hj - 0.5) * sz0 * 1.6 + (hj - 0.5) * age * 3;
                let o = age * (1.5 + 3.5 * hc2) + hj * 0.8;
                let x = px + tx * u + f.ox * o;
                let z = pz + tz * u + f.oz * o;
                let y = f.bottom + 0.3 + Math.pow(age, 0.8) * rise * lift + hj * sz0 * 0.4;
                let size = sz0 * grow * (0.8 + 0.45 * hj);
                // quick fade in, long thinning as it climbs
                let a = 0.48 * lmin(1, age * 8) * Math.pow(1 - age, 1.2) * lensFade(x, y, z);
                if (a > 0.01) {
                    R.particle(r, x, y, z, size, 0.9, 0.97, 1, a, 5, 0.15 * age, c * 13 + j + i * 7, hj * 6 + age);
                }
            }
        }
        if (near && drop > 12) {
            // mist streaks sliding down the lower face with the water
            let ns = thin(lclamp(Math.floor(f.width / 4), 3, 16), 2);
            for (let k = 1.0; k <= ns; k++) {
                let h1 = frac(k * 0.618 + i * 0.53);
                let h2 = frac(k * 0.4142 + i * 0.17);
                let age = frac(t * (0.45 + 0.3 * h2) + h1);
                let u = (h1 - 0.5) * f.width * 0.9;
                let y = f.bottom + drop * (0.12 + 0.3 * h2) - age * drop * 0.14;
                let o = f.arc + 1.1;
                let x = f.x + f.ox * o + tx * u;
                let z = f.z + f.oz * o + tz * u;
                // streaks read at a distance; up close one is a white egg
                let a = 0.55 * Math.sin(age * Math.PI) * lensFade(x, y, z, 18, 60);
                R.particle(r, x, y, z, 1 + 0.7 * h2, 0.95, 0.99, 1, a, 5, 0.1, k + i * 11, 0, 0, -12, 0, 4);
            }
        }
        if (near) {
            // churning white band along the waterline (blobs drawn out
            // sideways along the face)
            let nb = thin(lclamp(Math.floor(f.width / 5), 2, 12), 2);
            for (let k = 1.0; k <= nb; k++) {
                let h1 = frac(k * 0.7071 + i * 0.29);
                let age = frac(t * (0.5 + 0.4 * h1) + h1 * 3.1);
                let u = ((k - 0.5) / nb - 0.5) * f.width * 0.95 + (h1 - 0.5) * 2;
                let x = px + tx * u + f.ox * (h1 - 0.3) * 1.5;
                let z = pz + tz * u + f.oz * (h1 - 0.3) * 1.5;
                let sw = age < 0.5 ? 1.0 : -1.0;
                let yb = 0.25 + 0.3 * Math.sin(age * Math.PI);
                // (Luau ^ 0.5 is sqrt)
                R.particle(r, x, yb, z, sz0 * (0.8 + 0.5 * h1), 0.96, 0.99, 1, 0.8 * Math.sqrt(Math.sin(age * Math.PI)) * lensFade(x, yb, z), 5, 0.1, k + i * 17, 0, tx * 10 * sw, 0, tz * 10 * sw, 2.5);
            }
        }
        if (nFoam < 2 && d > -60 && d < 600) {
            R.foam(r, px, pz, lmin(f.width * 0.7 + 3, 16), 0.85);
            nFoam += 1;
        }
    }

    // the SEA ARCH weeps: drops fall from the crown at both mouths and
    // ring the water below (read as you thread it)
    let arch = levelMod.anchors.arch;
    if (Math.abs(arch.s - s) < 260) {
        let hw = arch.w * 0.5;
        for (let k = 1; k <= 14; k++) {
            let i = <f64>k;
            let h1 = frac(i * 0.6180339 + 0.13);
            let h2 = frac(i * 0.4142136 + 0.71);
            let age = frac(t * (0.42 + 0.12 * h2) + h1);
            let u = (h1 - 0.5) * hw * 1.1;
            let sn = (u / hw) * (u / hw);
            let top = arch.h * Math.pow(1 - sn, 0.62 / 2) - 1.2;
            let ms = k % 2 == 0 ? arch.s0 + 1.5 + h2 * 3 : arch.s1 - 1.5 - h2 * 3;
            // falling for 80% of the cycle, then a ring on the water
            let fa = lmin(age / 0.8, 1);
            let y = top * (1 - fa * fa);
            let wp = levelMod.world(ms, arch.x + u, arch.y + lmax(y, 0));
            let a = 0.85 * lmin(1, age * 10) * lensFade(wp.x, wp.y, wp.z, 6, 14);
            if (age < 0.8) {
                if (a > 0.02) {
                    R.particle(r, wp.x, wp.y, wp.z, 0.14, 0.86, 0.96, 1, a, 3, age, i, 0, 0, -2 * top * fa, 0, 3);
                }
            } else {
                let ring = (age - 0.8) / 0.2;
                R.particle(r, wp.x, 0.08, wp.z, 0.5 + 1.6 * ring, 0.9, 0.98, 1, 0.75 * (1 - ring) * lensFade(wp.x, 0, wp.z, 6, 14), 2, ring, i, 0);
            }
        }
    }

    // the lighthouse: a warm lantern that flashes as its lamp turns (no
    // beam geometry: by day a beam only read as a floating capsule)
    let L = levelMod.lighthouse;
    if (s < L.s + 250) {
        let lp = levelMod.anchors.lighthouse;
        let turn = lmax(0, Math.cos(t * 1.4));
        let flash = Math.pow(turn, 10);
        let glow = 2.2 + 3.2 * flash;
        R.particle(r, lp.x, lp.y, lp.z, glow * L.scale, 1, 0.8, 0.42, 0.55 + 0.4 * flash, 1, 0, 1, 0);
    }

    // sparkles crawling around the portal rims
    let rl = rims;
    if (rl == null) {
        rl = buildRims();
        rims = rl;
    }
    for (let jj = 1; jj < rl.length; jj++) {
        let g = rl[jj];
        let j = <f64>jj;
        let d = g.s - s;
        if (!(d > -60 && d < 1100)) continue;
        let n = thin(d < 500 ? 28 : 14, 6);
        for (let k = 1.0; k <= n; k++) {
            let ph = frac(k * 0.754 + j * 0.31);
            let age = frac(t * 0.6 + ph);
            let ang = (k / n) * Math.PI * 2 + t * (jj == 1 ? 0.25 : -0.18);
            let ca = Math.cos(ang), sa = Math.sin(ang);
            let rr = g.radius + Math.sin(k * 3.7) * 2.5;
            let x = g.x + g.rx * ca * rr;
            let y = g.y + sa * rr;
            let z = g.z + g.rz * ca * rr;
            let tw = Math.sin(age * Math.PI);
            R.particle(r, x, y, z, (2.2 + 1.4 * tw) * (g.radius / 55), g.r, g.g, g.b, tw, 4, age, k, age * 3);
        }
    }
}
