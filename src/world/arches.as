// Port of src/world/arches.luau: natural arches (a thick rock wall with an
// opening punched through it, the opening facing the rail): fractured faces,
// a tunnel with a wave-cut notch, a grass cap, boulders and foam at the feet,
// box colliders along the band.
//
// Port rules as terrain.as. gateSteps' closures share one GateBaker (the
// Luau setup runs in its constructor); GateBaker.step(i) is step i (1-based);
// gateSteps returns the steps as a 0-BASED array of closures.
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import { Rng, rand, randRange, hash, noise2, smoothstep, TAU } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as coll from "./collide";
import { Collider } from "./collide";
import { Look, COAST } from "./terrain";
import { lmin, lmax, lclamp, mod, opt } from "../lib/compat";

export class GateSpec {
    x: f64 = 0; // opening center on the water (world)
    z: f64 = 0;
    rx: f64 = 1; // across the opening (horizontal unit)
    rz: f64 = 0;
    halfW: f64 = 1; // opening half width at the springing
    height: f64 = 1; // opening height at the crown (intrados)
    crown: f64 = 1; // rock above the crown
    leg: f64 = 1; // leg width beside the opening
    flare: f64 = NaN; // extra leg width at the waterline
    depth: f64 = 1; // half thickness along the view
    seed: f64 = 0;
    look: Look = COAST;
    base: f64 = NaN; // feet bottom (default -4)
    ink: f64 = NaN;
    square: f64 = NaN; // outer outline squareness (2 round .. 6 boxy)
    rough: f64 = NaN; // outline jitter (m)
    foam: bool = true; // Luau: foam ~= false
    grassTop: bool = true; // Luau: grassTop ~= false
    facet: f64 = NaN; // fracture facet amplitude (m, default 1.5)
    drips: bool = true; // Luau: drips ~= false
}

// Piecewise-linear fracture value over an integer lattice line: irregular
// breakpoints carry hashed values in [0, 1]; between them the value runs straight.
function isBreakP(k: f64, salt: f64, seed: f64, period: f64, p: f64): bool {
    return mod(k, period) == 0 || hash(k * 0.917 + salt * 13.1, seed * 0.023) < p;
}

function isBreak(k: f64, salt: f64, seed: f64): bool {
    return isBreakP(k, salt, seed, 3, 0.45);
}

function breakVal(k: f64, salt: f64, seed: f64): f64 {
    return hash(k * 1.731 + salt * 5.3, seed * 0.031);
}

function facetLineP(k: f64, salt: f64, seed: f64, period: f64, p: f64): f64 {
    if (isBreakP(k, salt, seed, period, p)) return breakVal(k, salt, seed);
    let kp = k - 1, kn = k + 1;
    while (!isBreakP(kp, salt, seed, period, p)) kp -= 1;
    while (!isBreakP(kn, salt, seed, period, p)) kn += 1;
    let t = (k - kp) / (kn - kp);
    return breakVal(kp, salt, seed) * (1 - t) + breakVal(kn, salt, seed) * t;
}

// Coarse facets for the big faces: a few broad planes, tilted per ring block.
function faceFacet(k: f64, q: f64, seed: f64): f64 {
    let a = facetLineP(k, Math.floor(q / 4) + 20, seed, 5, 0.22);
    let b2 = facetLineP(q, Math.floor(k / 5) + 70, seed + 3, 4, 0.3);
    return a * 0.7 + b2 * 0.3;
}

// 2D fracture field on the (k, m) lattice.
function facet2(k: f64, m: f64, seed: f64): f64 {
    let a = facetLineP(k, Math.floor(m / 4) + 1, seed, 4, 0.2);
    let b = facetLineP(m, Math.floor(k / 5) + 50, seed + 7, 4, 0.2);
    return a * 0.62 + b * 0.38;
}

export type GateStep = (b: Builder, cols: Array<Collider>?) => void;
export const GATE_STEPS: i32 = 9;

const N: i32 = 32;
const MD: i32 = 8; // tunnel slices along the view
const RAD: StaticArray<f64> = [0, 0, 0.1, 0.22, 0.36, 0.52, 0.68, 0.82, 0.93, 1]; // 1-based
const NR: i32 = 9;

// The arch in bake steps of a millisecond or two each: step(1..GATE_STEPS)
// in order on one builder, nothing emitted in between.
export class GateBaker {
    sp: GateSpec;
    b: Builder? = null;
    cols: Array<Collider>? = null;
    r: Rng;
    look: Look;
    seed: f64;
    base: f64;
    fx: f64;
    fz: f64;
    hw: f64;
    H: f64;
    outW: f64;
    flare: f64;
    topY: f64;
    sq: f64;
    rough: f64;
    famp: f64;
    cy0: f64;
    // 2D profile: intrados I(k) and outer O(k), kk = 1..N+1, left foot -> right foot
    Iu: Array<f64> = [0.0];
    Iy: Array<f64> = [0.0];
    Ou: Array<f64> = [0.0];
    Oy: Array<f64> = [0.0];
    // the smooth profile before the jitter (the colliders follow it)
    AIu: Array<f64> = [0.0];
    AIy: Array<f64> = [0.0];
    AOu: Array<f64> = [0.0];
    AOy: Array<f64> = [0.0];
    dF: Array<f64> = [0.0];
    dB: Array<f64> = [0.0];
    bandH: f64;
    tones: Array<f64> = [0.0];
    tfs: Array<f64> = [0.0];
    // the tunnel lattice [kk][m + 1]
    TX: Array<Array<f64>> = [[0.0]];
    TY: Array<Array<f64>> = [[0.0]];
    TZ: Array<Array<f64>> = [[0.0]];
    TU: Array<Array<f64>> = [[0.0]];
    col0: u32 = 0;
    aux0: u32 = 0;
    v0: i32 = 0;
    i0: i32 = 0;
    grassTop: bool;
    capAt: f64;
    wetR: f64;
    wetG: f64;
    wetB: f64;
    drips: bool;
    // W / faceP / strata / inward / capP outputs
    WX: f64 = 0;
    WY: f64 = 0;
    WZ: f64 = 0;
    CR_: f64 = 0;
    CG_: f64 = 0;
    CB_: f64 = 0;

    constructor(sp: GateSpec) {
        this.sp = sp;
        this.r = mathx.rng(sp.seed);
        let look = sp.look;
        this.look = look;
        let seed = sp.seed;
        this.seed = seed;
        let base = opt(sp.base, -4);
        this.base = base;
        this.fx = -sp.rz; // along the view
        this.fz = sp.rx;
        let hw = sp.halfW, H = sp.height;
        this.hw = hw;
        this.H = H;
        let outW = hw + sp.leg;
        this.outW = outW;
        let flare = opt(sp.flare, sp.leg * 0.5);
        this.flare = flare;
        let topY = H + sp.crown;
        this.topY = topY;
        let sq = opt(sp.square, 3.2);
        this.sq = sq;
        let rough = opt(sp.rough, 1.2);
        this.rough = rough;
        this.famp = opt(sp.facet, 1.5);
        let cy0 = H * 0.42; // the opening's center
        this.cy0 = cy0;
        let Iu = this.Iu, Iy = this.Iy, Ou = this.Ou, Oy = this.Oy;
        for (let k = 0; k <= N; k++) {
            let kf = <f64>k;
            let t = kf / <f64>N;
            let th = Math.PI * (1 - t);
            let c = Math.cos(th), s = Math.sin(th);
            // intrados: tall rounded opening (vertical sides near the water)
            let iu = c * hw;
            let iy = H * Math.pow(s, 0.62);
            if (k == 0 || k == N) {
                iy = base;
            } else if (s < 0.25) {
                iy = lmax(base, iy - (0.25 - s) * 16);
            }
            // outer: boxy superellipse, feet flared into the sea
            let ac = Math.abs(c), asn = Math.abs(s);
            let sk = Math.pow(Math.pow(ac, sq) + Math.pow(asn, sq), -1 / sq);
            let ou = c * sk * (outW + flare * Math.pow(1 - s, 2));
            let oy = lmin(topY, topY * asn * sk * 1.02);
            if (k == 0 || k == N) oy = base;
            let j = (hash(kf * 1.7, seed * 0.01) - 0.5) * rough * 2;
            // broken rock around the opening: the jitter cuts into the rock only
            let j2 = (hash(kf * 2.9, seed * 0.02) - 0.2) * rough;
            let j3 = (hash(kf * 0.61 + 4.1, seed * 0.07) - 0.2) * rough * 2.2 * (k % 3 == 0 ? 1.6 : 0.7);
            this.AIu.push(iu);
            this.AIy.push(iy);
            this.AOu.push(ou);
            this.AOy.push(oy);
            let inside = k > 0 && k < N;
            Iu.push(iu + (inside ? c * lmax(0, j2 * 0.6 + j3) : 0.0));
            Iy.push(iy + (inside ? s * lmax(0, j2 * 0.5 + j3 * 0.8) : 0.0));
            Ou.push(ou + c * j * 0.8);
            Oy.push(oy + (inside ? s * j : 0.0));
        }
        // per-point depth jitter (front/back facets)
        for (let k = 0; k <= N; k++) {
            this.dF.push(sp.depth * (1 + (hash(<f64>k * 0.77, seed * 0.3) - 0.5) * 0.18));
            this.dB.push(sp.depth * (1 + (hash(<f64>k * 0.53, seed * 0.7) - 0.5) * 0.18));
        }

        // strata: bands alternate lighter / darker (with the odd accent band)
        let tr = mathx.rng(seed * 3 + 1);
        this.bandH = lmax(3.2, topY / 8);
        let dark = rand(tr) < 0.5;
        let nRock = <f64>(look.rock.length - 1);
        for (let i = 1; i <= 40; i++) {
            if (i == 1 || rand(tr) > 0.3) dark = !dark;
            this.tones.push(look.rock[<i32>mathx.randInt(tr, 1, nRock)]);
            this.tfs.push(dark ? randRange(tr, 0.78, 0.86) : randRange(tr, 0.97, 1.04));
        }

        // the tunnel lattice: intrados points displaced into the rock by the
        // fracture field; a wave-cut notch at the water
        let famp = this.famp, dF = this.dF, dB = this.dB;
        for (let kk = 1; kk <= N + 1; kk++) {
            let k = <f64>(kk - 1);
            let rowX: Array<f64> = [0.0], rowY: Array<f64> = [0.0], rowZ: Array<f64> = [0.0], rowU: Array<f64> = [0.0];
            let u0 = Iu[kk], y0 = Iy[kk];
            let du = u0, dy = y0 - cy0;
            if (y0 < 1.5) {
                du = u0 >= 0 ? 1.0 : -1.0;
                dy = 0;
            }
            let dl = Math.sqrt(du * du + dy * dy);
            du = du / dl;
            dy = dy / dl;
            for (let m = 0; m <= MD; m++) {
                let mf = <f64>m;
                let t = mf / <f64>MD;
                let v = -dF[kk] + (dF[kk] + dB[kk]) * t;
                let d = famp * lmax(0, facet2(k, mf, seed) * 1.1 - 0.1);
                if (y0 < 1.3) {
                    // wave-cut notch: the tide gnaws a dark groove
                    d = famp * 0.35 + 0.9 + 0.3 * hash(k * 0.37 + mf, seed * 0.11);
                } else if (y0 < 3) {
                    d = d * 0.6 + 0.35;
                }
                // the mouths stay near the profile (their edge is the face's)
                if (m == 0 || m == MD) d *= 0.55;
                let u = u0 + du * d, y = y0 + dy * d;
                this.W(u, y, v);
                rowX.push(this.WX);
                rowY.push(this.WY);
                rowZ.push(this.WZ);
                rowU.push(u);
            }
            this.TX.push(rowX);
            this.TY.push(rowY);
            this.TZ.push(rowZ);
            this.TU.push(rowU);
        }

        this.grassTop = sp.grassTop;
        this.capAt = H + sp.crown * 0.5;
        mathx.rgb(look.wet);
        this.wetR = mathx.RGB_R;
        this.wetG = mathx.RGB_G;
        this.wetB = mathx.RGB_B;
        this.drips = sp.drips;
    }

    // -> WX, WY, WZ
    W(u: f64, y: f64, v: f64): void {
        let sp = this.sp;
        this.WX = sp.x + sp.rx * u + this.fx * v;
        this.WY = y;
        this.WZ = sp.z + sp.rz * u + this.fz * v;
    }

    // -> CR_, CG_, CB_ (Luau mulHex of the band)
    strata(y: f64, u: f64, v: f64): void {
        let bandH = this.bandH;
        let yw = y + (noise2(u * 0.05 + this.seed * 0.01, v * 0.05) - 0.5) * bandH * 0.6;
        let i = <i32>lclamp(Math.floor((yw + 4) / bandH) + 1, 1, <f64>(this.tones.length - 1));
        mathx.rgb(this.tones[i]);
        let f = this.tfs[i];
        this.CR_ = mathx.RGB_R * f;
        this.CG_ = mathx.RGB_G * f;
        this.CB_ = mathx.RGB_B * f;
    }

    // face lattice ring point (q: 1..NR, fractions from the opening out) -> WX, WY, WZ
    faceP(kk: i32, q: i32, face: f64): void {
        if (q == 1) {
            let m = face < 0 ? 1 : MD + 1;
            this.WX = this.TX[kk][m];
            this.WY = this.TY[kk][m];
            this.WZ = this.TZ[kk][m];
            return;
        }
        let a = RAD[q];
        let dd = face < 0 ? this.dF[kk] : this.dB[kk];
        let Iu = this.Iu, Iy = this.Iy;
        let u = Iu[kk] + (this.Ou[kk] - Iu[kk]) * a;
        let y = Iy[kk] + (this.Oy[kk] - Iy[kk]) * a;
        let out = 0.0;
        if (q < NR) {
            // fracture facets standing out of / sinking into the face
            out = this.famp * 1.3 * (faceFacet(<f64>kk + face * 40, <f64>q, this.seed + 11) - 0.4);
            if (y < 1.2) out = -0.7; // notch
        }
        this.W(u, y, face * (dd + out));
    }

    // front and back faces (two bake steps each: kk ranges)
    faces(face: f64, kA: i32, kB: i32): void {
        let b = this.b!, sp = this.sp, look = this.look;
        let Oy = this.Oy, capAt = this.capAt;
        for (let kk = kA; kk <= kB; kk++) {
            for (let q = 1; q <= NR - 1; q++) {
                this.faceP(kk, q, face);
                let ax = this.WX, ay = this.WY, az = this.WZ;
                this.faceP(kk + 1, q, face);
                let bx = this.WX, by = this.WY, bz = this.WZ;
                this.faceP(kk + 1, q + 1, face);
                let cx = this.WX, cy = this.WY, cz = this.WZ;
                this.faceP(kk, q + 1, face);
                let dx = this.WX, dy = this.WY, dz = this.WZ;
                let my = (ay + by + cy + dy) * 0.25;
                let mu = ((ax - sp.x) * sp.rx + (az - sp.z) * sp.rz + (cx - sp.x) * sp.rx + (cz - sp.z) * sp.rz) * 0.5;
                let onTop = Oy[kk] > capAt && Oy[kk + 1] > capAt;
                if (q == NR - 1 && onTop && this.grassTop) {
                    meshgen.color(b, look.drape);
                } else if (my < 1.2) {
                    meshgen.color(b, look.wet);
                } else {
                    this.strata(my, mu, face * 5);
                    let cr = this.CR_, cg = this.CG_, cb = this.CB_;
                    let f = 0.97 + (faceFacet(<f64>kk + face * 40 + 7, <f64>q, this.seed + 29) - 0.5) * 0.08;
                    if (my < 3.2) {
                        // tidal band: darker, wet
                        let wt = 0.45 * (1 - smoothstep(1.2, 3.2, my));
                        cr = cr + (this.wetR - cr) * wt;
                        cg = cg + (this.wetG - cg) * wt;
                        cb = cb + (this.wetB - cb) * wt;
                    }
                    meshgen.colorf(b, cr * f, cg * f, cb * f);
                }
                meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, this.fx * face, 0, this.fz * face);
            }
        }
    }

    // i: 1..GATE_STEPS
    step(i: i32, bb: Builder, cc: Array<Collider>?): void {
        this.b = bb;
        this.cols = cc;
        let halfN = N / 2;
        if (i == 1) {
            this.col0 = bb.col;
            this.aux0 = bb.aux;
            this.v0 = bb.vcount;
            this.i0 = bb.icount;
            meshgen.aux(bb, 0, 1, 0, 0);
            this.faces(-1, 1, halfN);
        } else if (i == 2) {
            meshgen.aux(bb, 0, 1, 0, 0);
            this.faces(-1, halfN + 1, N);
        } else if (i == 3) {
            meshgen.aux(bb, 0, 1, 0, 0);
            this.faces(1, 1, halfN);
        } else if (i == 4) {
            meshgen.aux(bb, 0, 1, 0, 0);
            this.faces(1, halfN + 1, N);
        } else if (i == 5) {
            this.tunnel();
        } else if (i == 6) {
            this.skin();
        } else if (i == 7) {
            meshgen.inkShell(bb, this.v0, this.i0, opt(this.sp.ink, 1));
        } else if (i == 8) {
            this.decor();
        } else if (i == 9) {
            this.feet();
        }
    }

    // step2: the tunnel (intrados): shade deepens toward the middle and the ceiling
    tunnel(): void {
        let b = this.b!, sp = this.sp, H = this.H, cy0 = this.cy0, seed = this.seed;
        let TX = this.TX, TY = this.TY, TZ = this.TZ, TU = this.TU;
        meshgen.aux(b, 0, 1, 0, 0);
        for (let kk = 1; kk <= N; kk++) {
            for (let m = 1; m <= MD; m++) {
                let ax = TX[kk][m], ay = TY[kk][m], az = TZ[kk][m];
                let bx = TX[kk + 1][m], by = TY[kk + 1][m], bz = TZ[kk + 1][m];
                let cx = TX[kk + 1][m + 1], cy = TY[kk + 1][m + 1], cz = TZ[kk + 1][m + 1];
                let dx = TX[kk][m + 1], dy = TY[kk][m + 1], dz = TZ[kk][m + 1];
                let my = (ay + by + cy + dy) * 0.25;
                let mu = (TU[kk][m] + TU[kk + 1][m + 1]) * 0.5;
                let tm = (<f64>m - 0.5) / <f64>MD;
                let ao = (1 - 0.36 * Math.pow(Math.sin(Math.PI * tm), 0.7)) * (1 - 0.2 * smoothstep(H * 0.4, H, my));
                let cr: f64, cg: f64, cb: f64;
                if (my < 1.2) {
                    cr = this.wetR;
                    cg = this.wetG;
                    cb = this.wetB;
                } else {
                    this.strata(my, mu, tm * 20);
                    cr = this.CR_;
                    cg = this.CG_;
                    cb = this.CB_;
                    if (my < 3.4) {
                        let wt = 0.55 * (1 - smoothstep(1.2, 3.4, my));
                        cr = cr + (this.wetR - cr) * wt;
                        cg = cg + (this.wetG - cg) * wt;
                        cb = cb + (this.wetB - cb) * wt;
                    }
                }
                let f = ao * (0.94 + 0.12 * hash(<f64>kk * 0.53 + <f64>m * 0.71, seed * 0.13));
                meshgen.colorf(b, cr * f, cg * f, cb * f);
                // facing the opening's center
                let hu = -mu, hy = cy0 - my;
                meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, sp.rx * hu, hy, sp.rz * hu);
            }
        }
    }

    // cap row point (j: 0..CR across the thickness) -> WX, WY, WZ
    capP(kk: i32, j: i32, capH: f64): void {
        let t = <f64>j / 5;
        let v = -this.dF[kk] + (this.dF[kk] + this.dB[kk]) * t;
        let bump = capH * Math.pow(Math.sin(Math.PI * t), 0.7) * (0.75 + 0.5 * hash(<f64>kk * 0.41, this.seed * 0.17));
        this.W(this.Ou[kk], this.Oy[kk] + bump, v);
    }

    // step2b: the outer skin (legs, the grass cap) and the hanging drips
    skin(): void {
        let b = this.b!, sp = this.sp, look = this.look, seed = this.seed, r = this.r;
        let Ou = this.Ou, Oy = this.Oy, dF = this.dF, dB = this.dB, capAt = this.capAt, H = this.H;
        let grassTop = this.grassTop;
        for (let kk = 1; kk <= N; kk++) {
            let ou = (Ou[kk] + Ou[kk + 1]) * 0.5;
            let oy = (Oy[kk] + Oy[kk + 1]) * 0.5;
            let up = Oy[kk] > capAt && Oy[kk + 1] > capAt;
            if (!(up && grassTop)) {
                this.W(Ou[kk], Oy[kk], -dF[kk]);
                let ex = this.WX, ey = this.WY, ez = this.WZ;
                this.W(Ou[kk + 1], Oy[kk + 1], -dF[kk + 1]);
                let gx = this.WX, gy = this.WY, gz = this.WZ;
                this.W(Ou[kk + 1], Oy[kk + 1], dB[kk + 1]);
                let hx2 = this.WX, hy2 = this.WY, hz2 = this.WZ;
                this.W(Ou[kk], Oy[kk], dB[kk]);
                let ix = this.WX, iy = this.WY, iz = this.WZ;
                if (up) {
                    meshgen.color(b, look.back);
                } else {
                    this.strata(oy, ou, 0);
                    meshgen.colorf(b, this.CR_, this.CG_, this.CB_);
                }
                meshgen.quadFlat(b, ex, ey, ez, gx, gy, gz, hx2, hy2, hz2, ix, iy, iz, sp.rx * ou, up ? 4 : oy - H * 0.3, sp.rz * ou);
            }
        }
        if (grassTop) {
            // cap rows across the thickness: a low rounded mound, smooth normals
            let CR = 5;
            let capH = lmin(2.2, sp.depth * 0.22);
            let gph = seed * 0.37;
            let ids = new Array<Array<i32>?>(N + 2);
            for (let kk = 1; kk <= N + 1; kk++) {
                if (Oy[kk] > capAt) {
                    let row: Array<i32> = [0];
                    for (let j = 0; j <= CR; j++) {
                        this.capP(kk, j, capH);
                        let x = this.WX, y = this.WY, z = this.WZ;
                        let kp = max(kk - 1, 1);
                        let kn = min(kk + 1, N + 1);
                        this.capP(kp, j, capH);
                        let ax = this.WX, ay = this.WY, az = this.WZ;
                        this.capP(kn, j, capH);
                        let bx = this.WX, by = this.WY, bz = this.WZ;
                        this.capP(kk, max(j - 1, 0), capH);
                        let cx = this.WX, cy = this.WY, cz = this.WZ;
                        this.capP(kk, min(j + 1, CR), capH);
                        let dx = this.WX, dy = this.WY, dz = this.WZ;
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
                        if (j == 0 || j == CR) {
                            meshgen.color(b, look.drape);
                        } else {
                            let g = noise2(x * 0.05 + gph, z * 0.05);
                            let g2 = noise2(x * 0.13 - gph, z * 0.13);
                            meshgen.color(b, g > 0.6 ? look.grass[2] : g2 > 0.7 ? look.grass[look.grass.length - 1] : look.grass[1]);
                        }
                        row.push(meshgen.vertex(b, x, y, z, nx / l, ny / l, nz / l));
                    }
                    ids[kk] = row;
                }
            }
            for (let kk = 1; kk <= N; kk++) {
                let ra = ids[kk], rb = ids[kk + 1];
                if (ra != null && rb != null) {
                    for (let j = 1; j <= CR; j++) {
                        let a = ra[j], bq = rb[j], c = rb[j + 1], d = ra[j + 1];
                        // wind so the cap faces up
                        this.capP(kk, j - 1, capH);
                        let ax = this.WX, az = this.WZ;
                        this.capP(kk + 1, j - 1, capH);
                        let bx = this.WX, bz = this.WZ;
                        this.capP(kk, j, capH);
                        let cx = this.WX, cz = this.WZ;
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
            }
            // gorse and outcrops on the cap
            for (let kk = 2; kk <= N - 1; kk++) {
                let kf = <f64>kk;
                if (Oy[kk] > capAt + 1 && hash(kf * 0.83, seed * 0.29) < 0.4) {
                    let j = 1 + <i32>Math.floor(hash(kf * 1.9, seed) * <f64>(CR - 1));
                    this.capP(kk, j, capH);
                    let x = this.WX, y = this.WY, z = this.WZ;
                    let sz = randRange(r, 1, 2.4);
                    if (hash(kf * 3.1, seed * 0.5) < 0.3) {
                        meshgen.color(b, look.boulder[<i32>mathx.randInt(r, 1, <f64>(look.boulder.length - 1))]);
                        meshgen.rock(b, x, y - sz * 0.3, z, sz, sz * 0.6, sz * 0.9, rand(r) * 100, 6, 4);
                    } else {
                        meshgen.color(b, look.shrub);
                        meshgen.rock(b, x, y - sz * 0.15, z, sz * 1.2, sz * 0.55, sz, rand(r) * 100, 6, 3);
                    }
                }
            }
        }

        // hanging drips under the crown (little rock icicles), inked with the rock
        if (this.drips) {
            let Iy = this.Iy, TX = this.TX, TY = this.TY, TZ = this.TZ;
            let fx = this.fx, fz = this.fz;
            for (let kk = 2; kk <= N - 1; kk++) {
                if (Iy[kk] > H * 0.72) {
                    let kf = <f64>kk;
                    for (let m = 2; m <= MD - 2; m++) {
                        let mf = <f64>m;
                        if (hash(kf * 0.67 + mf * 1.9, seed * 0.43) < 0.16) {
                            let x = TX[kk][m + 1], y = TY[kk][m + 1], z = TZ[kk][m + 1];
                            let ln = 0.5 + 1.1 * hash(kf + mf * 3.3, seed * 0.9);
                            let rad = 0.18 + 0.2 * hash(kf * 2.3 + mf, seed * 0.2);
                            let tx = x + fx * 0.15, tz = z + fz * 0.15;
                            mixHex(look.rock[1], look.wet, 0.3);
                            meshgen.colorf(b, MIX_R * 0.95, MIX_G * 0.97, MIX_B);
                            let ph = hash(kf, mf) * TAU;
                            for (let i = 0; i <= 3; i++) {
                                let a0 = ph + <f64>i / 4 * TAU;
                                let a1 = ph + <f64>(i + 1) / 4 * TAU;
                                let p0x = x + (sp.rx * Math.cos(a0) + fx * Math.sin(a0)) * rad;
                                let p0z = z + (sp.rz * Math.cos(a0) + fz * Math.sin(a0)) * rad;
                                let p1x = x + (sp.rx * Math.cos(a1) + fx * Math.sin(a1)) * rad;
                                let p1z = z + (sp.rz * Math.cos(a1) + fz * Math.sin(a1)) * rad;
                                let mx = (p0x + p1x) * 0.5 - x, mz = (p0z + p1z) * 0.5 - z;
                                meshgen.flatTriFacing(b, p0x, y + 0.3, p0z, p1x, y + 0.3, p1z, tx, y - ln, tz, mx, 0.2, mz);
                            }
                        }
                    }
                }
            }
        }
    }

    // a tunnel point pushed toward the opening's center by amt -> WX, WY, WZ
    inward(kk: i32, m: i32, amt: f64): void {
        let sp = this.sp;
        let x = this.TX[kk][m], y = this.TY[kk][m], z = this.TZ[kk][m];
        let u = this.TU[kk][m];
        let hu = -u, hy = this.cy0 - y;
        let hl = Math.sqrt(hu * hu + hy * hy);
        this.WX = x + sp.rx * hu / hl * amt;
        this.WY = y + hy / hl * amt;
        this.WZ = z + sp.rz * hu / hl * amt;
    }

    // step4: decorations without ink
    decor(): void {
        let b = this.b!, sp = this.sp, look = this.look, seed = this.seed;
        let fx = this.fx, fz = this.fz, H = this.H, cy0 = this.cy0;
        let Iu = this.Iu, Iy = this.Iy, Ou = this.Ou, Oy = this.Oy, TU = this.TU, capAt = this.capAt;
        meshgen.aux(b, 0, 0, 0, 0);
        // crevices: dark strips down the faces along fracture lines
        meshgen.color(b, look.crack);
        for (let face = -1.0; face <= 1; face += 2) {
            for (let kk = 2; kk <= N; kk++) {
                let k = <f64>(kk - 1);
                if (isBreak(k, 3 + face, seed + 11) && hash(k * 0.77 + face * 3, seed * 0.41) < 0.75) {
                    let q1 = 2 + <i32>Math.floor(hash(k * 1.3 + face, seed * 0.6) * 2);
                    let q2 = <i32>lmin(<f64>(NR - 1), <f64>q1 + 2 + Math.floor(hash(k * 2.7 + face, seed * 0.8) * <f64>(NR - q1 - 1)));
                    let w0 = 0.2 + 0.2 * hash(k * 0.3 + face, seed);
                    let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                    for (let q = q1; q <= q2; q++) {
                        this.faceP(kk, q, face);
                        let x = this.WX, y = this.WY, z = this.WZ;
                        // across: along the ring
                        this.faceP(kk + 1, q, face);
                        let ex = this.WX - x, ey = this.WY - y, ez = this.WZ - z;
                        let el = Math.sqrt(ex * ex + ey * ey + ez * ez);
                        ex = ex / el;
                        ey = ey / el;
                        ez = ez / el;
                        let jit = (hash(k * 3.1 + <f64>q, seed) - 0.5) * 0.8;
                        x = x + ex * jit + fx * face * 0.14;
                        y = y + ey * jit;
                        z = z + ez * jit + fz * face * 0.14;
                        let t = <f64>(q - q1) / lmax(<f64>(q2 - q1), 1);
                        let wj = w0 * (0.35 + 0.65 * Math.pow(Math.sin(Math.PI * t), 0.5));
                        if (q > q1) {
                            meshgen.quadFlat(b, px - ex * pw, py - ey * pw, pz - ez * pw, px + ex * pw, py + ey * pw, pz + ez * pw, x + ex * wj, y + ey * wj, z + ez * wj, x - ex * wj, y - ey * wj, z - ez * wj, fx * face, 0, fz * face);
                        }
                        px = x;
                        py = y;
                        pz = z;
                        pw = wj;
                    }
                }
            }
        }
        // tunnel crevices: along the view at fracture breaks (k), and around
        // the tunnel at depth breaks (m) over part of the profile
        for (let kk = 2; kk <= N; kk++) {
            let k = <f64>(kk - 1);
            if (isBreak(k, 1, seed) && Iy[kk] > 2 && hash(k * 0.53, seed * 0.19) < 0.7) {
                let w0 = 0.18 + 0.16 * hash(k, seed * 0.7);
                let m1 = <i32>Math.floor(hash(k * 1.7, seed) * 3);
                let m2 = MD - <i32>Math.floor(hash(k * 2.3, seed) * 3);
                // across: along the profile
                let tu = Iu[kk + 1] - Iu[kk - 1];
                let ty = Iy[kk + 1] - Iy[kk - 1];
                let tl = Math.sqrt(tu * tu + ty * ty);
                tu = tu / tl;
                ty = ty / tl;
                let ex = sp.rx * tu, ey = ty, ez = sp.rz * tu;
                let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                for (let m = m1; m <= m2; m++) {
                    this.inward(kk, m + 1, 0.12);
                    let x = this.WX, y = this.WY, z = this.WZ;
                    let t = <f64>(m - m1) / lmax(<f64>(m2 - m1), 1);
                    let wj = w0 * (0.3 + 0.7 * Math.pow(Math.sin(Math.PI * t), 0.5));
                    if (m > m1) {
                        let hu = -TU[kk][m + 1], hy = cy0 - y;
                        meshgen.quadFlat(b, px - ex * pw, py - ey * pw, pz - ez * pw, px + ex * pw, py + ey * pw, pz + ez * pw, x + ex * wj, y + ey * wj, z + ez * wj, x - ex * wj, y - ey * wj, z - ez * wj, sp.rx * hu, hy, sp.rz * hu);
                    }
                    px = x;
                    py = y;
                    pz = z;
                    pw = wj;
                }
            }
        }
        for (let m = 1; m <= MD - 1; m++) {
            let mf = <f64>m;
            if (isBreak(mf, 60, seed + 7) && hash(mf * 0.91, seed * 0.37) < 0.8) {
                let side = hash(mf * 1.3, seed) < 0.5 ? -1 : 1;
                // from the tidal band up a leg, sometimes over the crown
                let kLow = side < 0 ? 2 : N;
                let span = 6 + <i32>Math.floor(hash(mf * 2.1, seed * 0.3) * 10);
                let kEnd = <i32>lclamp(<f64>(kLow - side * span), 2, <f64>N);
                let w0 = 0.16 + 0.14 * hash(mf * 0.7, seed * 0.9);
                let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                let n = 0;
                let kk = kLow;
                while (true) {
                    if (Iy[kk] > 1.5) {
                        this.inward(kk, m + 1, 0.12);
                        let x = this.WX, y = this.WY, z = this.WZ;
                        let jit = (hash(<f64>kk * 1.1 + mf, seed * 0.77) - 0.5) * 0.5;
                        x = x + fx * jit;
                        z = z + fz * jit;
                        let wj = w0 * (0.4 + 0.6 * hash(<f64>kk + mf * 7, seed));
                        if (n > 0) {
                            let hu = -TU[kk][m + 1], hy = cy0 - y;
                            meshgen.quadFlat(b, px - fx * pw, py, pz - fz * pw, px + fx * pw, py, pz + fz * pw, x + fx * wj, y, z + fz * wj, x - fx * wj, y, z - fz * wj, sp.rx * hu, hy, sp.rz * hu);
                        }
                        px = x;
                        py = y;
                        pz = z;
                        pw = wj;
                        n += 1;
                    }
                    if (kk == kEnd) break;
                    kk -= side;
                }
            }
        }
        if (this.drips) {
            // wet streaks: water weeping from the crown down the tunnel walls
            mixHex(look.rock[1], look.wet, 0.7);
            meshgen.colorf(b, MIX_R * 0.9, MIX_G * 0.95, MIX_B * 1.05);
            for (let m = 1; m <= MD - 1; m++) {
                let mf = <f64>m;
                for (let side = -1; side <= 1; side += 2) {
                    let sf = <f64>side;
                    if (hash(mf * 1.7 + sf, seed * 0.51) < 0.45) {
                        let kTop = <i32>Math.floor(<f64>N * 0.5 + sf * <f64>N * (0.12 + 0.12 * hash(mf + sf, seed * 0.3)));
                        let kLow = side < 0 ? 1 : N + 1;
                        let w0 = 0.2 + 0.35 * hash(mf * 3.3 + sf, seed * 0.2);
                        let mo = (hash(mf * 5.1 + sf, seed) - 0.5) * 0.7;
                        let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                        let n = 0;
                        let kk = kTop;
                        while (true) {
                            if (Iy[kk] > 1.2) {
                                this.inward(kk, m + 1, 0.08);
                                let x = this.WX, y = this.WY, z = this.WZ;
                                x = x + fx * mo;
                                z = z + fz * mo;
                                let t = <f64>n / 8;
                                let wj = w0 * (1 - 0.6 * lmin(t, 1)) * (0.7 + 0.3 * hash(<f64>kk * 0.9 + mf, seed));
                                if (n > 0) {
                                    let hu = -TU[kk][m + 1], hy = cy0 - y;
                                    meshgen.quadFlat(b, px - fx * pw, py, pz - fz * pw, px + fx * pw, py, pz + fz * pw, x + fx * wj, y, z + fz * wj, x - fx * wj, y, z - fz * wj, sp.rx * hu, hy, sp.rz * hu);
                                }
                                px = x;
                                py = y;
                                pz = z;
                                pw = wj;
                                n += 1;
                            }
                            if (kk == kLow) break;
                            kk += side;
                        }
                    }
                }
            }
        }
        // grass tongues over the faces' top edge, and long moss drapes hanging
        // down the lintel into the opening
        if (this.grassTop) {
            for (let face = -1.0; face <= 1; face += 2) {
                let dd = face < 0 ? this.dF : this.dB;
                for (let kk = 1; kk <= N; kk++) {
                    let kf = <f64>kk;
                    let onTop = Oy[kk] > capAt && Oy[kk + 1] > capAt;
                    if (onTop && hash(kf * 1.3 + face, seed * 0.2) < 0.75) {
                        let drop = 1 + 3.5 * hash(kf * 2.1 + face, seed * 0.3);
                        let off = face * 0.18;
                        this.W(Ou[kk], Oy[kk] - 0.2, face * dd[kk] + off);
                        let ax = this.WX, ay = this.WY, az = this.WZ;
                        this.W(Ou[kk + 1], Oy[kk + 1] - 0.2, face * dd[kk + 1] + off);
                        let bx = this.WX, by = this.WY, bz = this.WZ;
                        this.W(Ou[kk + 1] * 0.97, Oy[kk + 1] - drop * 0.6, face * dd[kk + 1] + off);
                        let cx = this.WX, cy = this.WY, cz = this.WZ;
                        this.W(Ou[kk] * 0.97, Oy[kk] - drop, face * dd[kk] + off);
                        let dx = this.WX, dy = this.WY, dz = this.WZ;
                        meshgen.color(b, hash(kf, seed) > 0.5 ? look.drape : look.grass[1]);
                        meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, fx * face, 0.3, fz * face);
                    }
                }
                // moss drapes: a few broad tongues from the top down part of the
                // lintel, ragged tips
                let ex = sp.rx, ez = sp.rz;
                for (let kk = 3; kk <= N - 2; kk++) {
                    let k = <f64>(kk - 1);
                    if (Iy[kk] > H * 0.7 && hash(k * 2.9 + face * 5, seed * 0.61) < 0.16) {
                        let w = 0.9 + 1.2 * hash(k * 1.1 + face, seed * 0.4);
                        let reach = 0.3 + 0.35 * hash(k * 0.7 + face, seed * 0.8); // fraction of the lintel
                        meshgen.color(b, hash(k * 4.1, seed) > 0.5 ? look.drape : look.ledge);
                        let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                        let qStop = <i32>lmax(2, Math.floor(<f64>NR - <f64>(NR - 1) * reach));
                        for (let q = NR; q >= qStop; q--) {
                            this.faceP(kk, q, face);
                            let x = this.WX, y = this.WY, z = this.WZ;
                            x = x + fx * face * 0.22;
                            z = z + fz * face * 0.22;
                            let wj = w * (1.05 - 0.25 * <f64>(NR - q) / <f64>(NR - qStop + 1)) * (0.85 + 0.3 * hash(<f64>q * 1.7 + k, seed * 0.3));
                            if (q < NR) {
                                meshgen.quadFlat(b, px - ex * pw, py, pz - ez * pw, px + ex * pw, py, pz + ez * pw, x + ex * wj, y, z + ez * wj, x - ex * wj, y, z - ez * wj, fx * face, 0.2, fz * face);
                            }
                            px = x;
                            py = y;
                            pz = z;
                            pw = wj;
                        }
                        // ragged end: two or three tips
                        let nt = 2 + <i32>Math.floor(hash(k * 5.3, seed) * 2);
                        for (let i = 0; i <= nt - 1; i++) {
                            let a0 = -pw + 2 * pw * <f64>i / <f64>nt;
                            let a1 = -pw + 2 * pw * <f64>(i + 1) / <f64>nt;
                            let tl = 0.8 + 1.6 * hash(k * 1.9 + <f64>i, seed * 0.7);
                            let tm = (a0 + a1) * 0.5;
                            meshgen.flatTriFacing(b, px + ex * a0, py, pz + ez * a0, px + ex * a1, py, pz + ez * a1, px + ex * tm + fx * face * 0.05, py - tl, pz + ez * tm + fz * face * 0.05, fx * face, 0.2, fz * face);
                        }
                    }
                }
            }
        }
    }

    // stroke over the 1-based scratch lists (P: x, z pairs; widths; outward n)
    stroke(P: Array<f64>, widths: Array<f64>, nx: Array<f64>, nz: Array<f64>): void {
        let b = this.b!;
        let n = widths.length - 1;
        for (let i = 1; i <= n - 1; i++) {
            let ax = P[i * 2 - 1], az = P[i * 2];
            let bx = P[i * 2 + 1], bz = P[i * 2 + 2];
            let wa = widths[i], wb = widths[i + 1];
            meshgen.quadFlat(b, ax, 0.07, az, bx, 0.07, bz, bx + nx[i + 1] * wb, 0.07, bz + nz[i + 1] * wb, ax + nx[i] * wa, 0.07, az + nz[i] * wa, 0, 1, 0);
        }
    }

    // step5: boulders, foam and colliders
    feet(): void {
        let b = this.b!, sp = this.sp, look = this.look, seed = this.seed, r = this.r;
        let fx = this.fx, fz = this.fz, hw = this.hw, H = this.H, base = this.base, cy0 = this.cy0;
        let outW = this.outW, flare = this.flare;
        let Iy = this.Iy, TU = this.TU, dF = this.dF, dB = this.dB;
        // boulders around the feet (against the legs, clear of the opening)
        meshgen.aux(b, 0, 1, 0, 0);
        let vb0 = b.vcount, ib0 = b.icount;
        let nB = <f64>(look.boulder.length - 1);
        for (let side = -1.0; side <= 1; side += 2) {
            for (let i = 0; i < 6; i++) {
                let u = side * (hw + 0.6 + (sp.leg + flare) * randRange(r, 0.1, 1.05));
                let v = randRange(r, -1.3, 1.3) * sp.depth;
                let sz = randRange(r, 1, 3.4);
                this.W(u, sz * randRange(r, -0.3, 0.15), v);
                let x = this.WX, y = this.WY, z = this.WZ;
                meshgen.color(b, look.boulder[<i32>mathx.randInt(r, 1, nB)]);
                meshgen.rock(b, x, y, z, sz, sz * 0.7, sz * 0.9, rand(r) * 100, 6, 4);
            }
        }
        meshgen.inkShell(b, vb0, ib0, opt(sp.ink, 1));
        // foam: broken lace hugging each leg, an outer broken band, and lace
        // along the tunnel walls at the waterline
        if (sp.foam) {
            meshgen.aux(b, 0, 0, 1, 0.25);
            meshgen.color(b, look.foam);
            let P: Array<f64> = [0.0], Wd: Array<f64> = [0.0], NX: Array<f64> = [0.0], NZ: Array<f64> = [0.0];
            for (let side = -1.0; side <= 1; side += 2) {
                let u0 = side * hw;
                let u1 = side * (outW + flare);
                let cu = (u0 + u1) * 0.5, du = Math.abs(u1 - u0) * 0.5 + 0.2;
                let dv = sp.depth + 0.2;
                let nseg = 22.0;
                let i = 0.0;
                while (i < nseg) {
                    let ln = 1 + Math.floor(hash(i * 1.3 + side, seed * 0.7) * 2.5);
                    if (hash(i * 0.71 + side * 3, seed * 0.9) < 0.78) {
                        P = [0.0];
                        Wd = [0.0];
                        NX = [0.0];
                        NZ = [0.0];
                        let wmax = 0.8 + 2 * hash(i * 2.9 + side, seed);
                        let steps = <i32>(ln * 3);
                        for (let j = 0; j <= steps; j++) {
                            let jf = <f64>j;
                            let a = (i + jf / 3) / nseg * TAU;
                            let ca = Math.cos(a), sa = Math.sin(a);
                            // rounded-box footprint (superellipse)
                            let eu = (ca >= 0 ? 1.0 : -1.0) * Math.pow(Math.abs(ca), 0.55);
                            let ev = (sa >= 0 ? 1.0 : -1.0) * Math.pow(Math.abs(sa), 0.55);
                            let jit = (hash(i * 7.1 + jf, seed * 0.33) - 0.5) * 0.5;
                            this.W(cu + eu * (du + jit), 0, ev * (dv + jit));
                            let x = this.WX, z = this.WZ;
                            let nxu = eu, nxv = ev;
                            let nl = Math.sqrt(nxu * nxu + nxv * nxv);
                            let ox = sp.rx * nxu / nl + fx * nxv / nl, oz = sp.rz * nxu / nl + fz * nxv / nl;
                            P.push(x - ox * 0.3);
                            P.push(z - oz * 0.3);
                            let t = jf / <f64>steps;
                            Wd.push(wmax * Math.pow(Math.sin(Math.PI * t), 0.7) + 0.3);
                            NX.push(ox);
                            NZ.push(oz);
                        }
                        this.stroke(P, Wd, NX, NZ);
                        // an outer dash
                        if (hash(i * 3.7 + side, seed * 0.21) < 0.45) {
                            let o = wmax + 1 + 1.5 * hash(i, seed * 0.12);
                            for (let j = 1; j < Wd.length; j++) {
                                P[j * 2 - 1] += NX[j] * o;
                                P[j * 2] += NZ[j] * o;
                                Wd[j] = (Wd[j] - 0.3) * 0.35 + 0.08;
                            }
                            this.stroke(P, Wd, NX, NZ);
                        }
                    }
                    i += ln;
                }
            }
            // lace along the tunnel walls
            for (let side = -1; side <= 1; side += 2) {
                let sf = <f64>side;
                // the profile point just above the water on this side
                let kk = side < 0 ? 1 : N + 1;
                let guard = 0;
                while (Iy[kk] < 0.3 && guard < N) {
                    kk -= side;
                    guard += 1;
                }
                let m = 0.0;
                let mdf = <f64>MD;
                while (m < mdf) {
                    let ln = 1 + Math.floor(hash(m * 1.9 + sf, seed * 0.5) * 2);
                    if (hash(m * 0.37 + sf * 5, seed * 0.66) < 0.8) {
                        P = [0.0];
                        Wd = [0.0];
                        NX = [0.0];
                        NZ = [0.0];
                        let wmax = 0.6 + 1.4 * hash(m * 2.2 + sf, seed * 0.4);
                        let steps = <i32>(ln * 3);
                        for (let j = 0; j <= steps; j++) {
                            let jf = <f64>j;
                            let mm = lmin(m + jf / 3, mdf);
                            let m0 = Math.floor(mm);
                            let ft = mm - m0;
                            let m1 = lmin(m0 + 1, mdf);
                            let u = TU[kk][<i32>m0 + 1] * (1 - ft) + TU[kk][<i32>m1 + 1] * ft;
                            let v = -dF[kk] + (dF[kk] + dB[kk]) * (mm / mdf);
                            let jit = (hash(m * 5.3 + jf, seed * 0.29) - 0.5) * 0.4;
                            this.W(u - sf * (0.2 + jit), 0, v);
                            P.push(this.WX);
                            P.push(this.WZ);
                            let t = jf / <f64>steps;
                            Wd.push(wmax * Math.pow(Math.sin(Math.PI * t), 0.7) + 0.2);
                            NX.push(-sp.rx * sf);
                            NZ.push(-sp.rz * sf);
                        }
                        this.stroke(P, Wd, NX, NZ);
                    }
                    m += ln;
                }
            }
        }
        meshgen.setPaint(b, this.col0, this.aux0);
        // colliders: one tall box per leg up to the springing, then boxes along
        // the band over the crown
        let cols = this.cols;
        if (cols != null) {
            let spring = H * 0.55;
            let w = Vector.xyz(<f32>fx, 0, <f32>fz);
            let up = Vector.xyz(0, 1, 0);
            for (let side = -1.0; side <= 1; side += 2) {
                let u0 = side * hw, u1 = side * (outW + flare * 0.35);
                let cu = (u0 + u1) * 0.5;
                this.W(cu, 0, 0);
                let cx = this.WX, cz = this.WZ;
                let cy = (base + spring) * 0.5;
                cols.push(coll.box(cx, cy, cz, Vector.xyz(<f32>sp.rx, 0, <f32>sp.rz), up, w, Math.abs(u1 - u0) * 0.5, (spring - base) * 0.5, sp.depth * 0.95));
            }
            // the intrados band: boxes whose inner face is the chord of the
            // smooth intrados pushed out by the chord's sag
            let AIu = this.AIu, AIy = this.AIy, AOu = this.AOu, AOy = this.AOy;
            let k = 1;
            while (k <= N) {
                let k2 = min(k + 2, N + 1);
                let au = AIu[k], ay = AIy[k], bu = AIu[k2], by = AIy[k2];
                if (ay >= 1.5 || by >= 1.5) {
                    let tu = bu - au, ty = by - ay;
                    let tl = Math.sqrt(tu * tu + ty * ty);
                    if (tl > 1e-3) {
                        tu = tu / tl;
                        ty = ty / tl;
                        // normal into the rock (away from the opening's center)
                        let nu = ty, ny = -tu;
                        if (((au + bu) * 0.5) * nu + ((ay + by) * 0.5 - cy0) * ny < 0) {
                            nu = -nu;
                            ny = -ny;
                        }
                        let km = min(k + 1, N + 1);
                        let sag = lmax(0, (AIu[km] - au) * nu + (AIy[km] - ay) * ny);
                        let t0 = (AOu[k] - au) * nu + (AOy[k] - ay) * ny;
                        let t1 = (AOu[k2] - au) * nu + (AOy[k2] - ay) * ny;
                        let th = lmax(2, lmin(t0, t1) * 0.95 - sag);
                        let cu = (au + bu) * 0.5 + nu * (sag + th * 0.5);
                        let cy = (ay + by) * 0.5 + ny * (sag + th * 0.5);
                        this.W(cu, cy, 0);
                        let wx = this.WX, wz = this.WZ;
                        let u = Vector.xyz(<f32>(sp.rx * tu), <f32>ty, <f32>(sp.rz * tu));
                        let v = Vector.xyz(<f32>(sp.rx * nu), <f32>ny, <f32>(sp.rz * nu));
                        cols.push(coll.box(wx, cy, wz, u, v, w, tl * 0.5 + 0.4, th * 0.5, sp.depth * 0.95));
                    }
                }
                k = k2;
            }
        }
    }
}

// mixHex -> MIX_R, MIX_G, MIX_B
let MIX_R: f64 = 0;
let MIX_G: f64 = 0;
let MIX_B: f64 = 0;
function mixHex(a: f64, b: f64, t: f64): void {
    mathx.rgb(a);
    let ar = mathx.RGB_R, ag = mathx.RGB_G, ab = mathx.RGB_B;
    mathx.rgb(b);
    let br = mathx.RGB_R, bg = mathx.RGB_G, bb = mathx.RGB_B;
    MIX_R = ar + (br - ar) * t;
    MIX_G = ag + (bg - ag) * t;
    MIX_B = ab + (bb - ab) * t;
}

// The arch's bake steps: a 0-BASED array of GATE_STEPS closures sharing one
// GateBaker (the setup runs here, as in Luau).
export function gateSteps(sp: GateSpec): Array<GateStep> {
    let gb = new GateBaker(sp);
    let out: Array<GateStep> = [];
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(1, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(2, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(3, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(4, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(5, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(6, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(7, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(8, b, cols); });
    out.push((b: Builder, cols: Array<Collider>?): void => { gb.step(9, b, cols); });
    return out;
}

// The whole arch at once. Returns its top height.
export function gate(b: Builder, sp: GateSpec, cols: Array<Collider>?): f64 {
    let gb = new GateBaker(sp);
    for (let i = 1; i <= GATE_STEPS; i++) gb.step(i, b, cols);
    return sp.height + sp.crown;
}
