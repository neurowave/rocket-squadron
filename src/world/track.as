// Port of src/world/track.luau: the rail, a Catmull-Rom spline through
// control points, resampled by arc length. Everything along the level
// (scenery, spawns, route checkpoints) is addressed by distance `s` in meters.
//
// Frame at s: pos (rail center, y = rail base altitude), fwd (unit, may pitch
// on climbs), right (horizontal unit), up (unit, perpendicular to fwd/right),
// bank (suggested roll from curvature, radians).
//
// Port: sequences 1-based (slot 0 a dummy); `frame` returns through
// FRAME_P / FRAME_F / FRAME_R / FRAME_U / FRAME_BANK (copy them right away).
// Vectors are f32 like Luau's; the math between them stays f64.
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import { lmax } from "../lib/compat";

export class Track {
    step: f64 = 2;
    length: f64 = 0;
    n: i32 = 0;
    px: Array<f64> = [0.0];
    py: Array<f64> = [0.0];
    pz: Array<f64> = [0.0];
    fx: Array<f64> = [0.0];
    fy: Array<f64> = [0.0];
    fz: Array<f64> = [0.0];
    bank: Array<f64> = [0.0];
}

@inline function cr(p0: f64, p1: f64, p2: f64, p3: f64, t: f64): f64 {
    let t2 = t * t, t3 = t * t * t;
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

// Luau mathx.cross: f64 products, one f32 rounding (mathx.as cross rounds
// each product to f32).
function cross(a: Vector, b: Vector): Vector {
    let ax = <f64>a.x, ay = <f64>a.y, az = <f64>a.z;
    let bx = <f64>b.x, by = <f64>b.y, bz = <f64>b.z;
    return mathx.v3(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx);
}

// points: control points (1-based); step: resample spacing in meters.
export function build(points: Array<Vector>, step: f64 = 2): Track {
    let st = step;
    let n = points.length - 1;
    // dense sampling
    let dx: Array<f64> = [0.0], dy: Array<f64> = [0.0], dz: Array<f64> = [0.0], ds: Array<f64> = [0.0];
    let total = 0.0;
    let lx = <f64>points[1].x, ly = <f64>points[1].y, lz = <f64>points[1].z;
    let sub = 48;
    for (let i = 1; i <= n - 1; i++) {
        let p0 = points[max(i - 1, 1)];
        let p1 = points[i];
        let p2 = points[i + 1];
        let p3 = points[min(i + 2, n)];
        for (let k = 0; k < sub; k++) {
            let t = <f64>k / <f64>sub;
            let x = cr(p0.x, p1.x, p2.x, p3.x, t);
            let y = cr(p0.y, p1.y, p2.y, p3.y, t);
            let z = cr(p0.z, p1.z, p2.z, p3.z, t);
            total += Math.sqrt((x - lx) * (x - lx) + (y - ly) * (y - ly) + (z - lz) * (z - lz));
            dx.push(x);
            dy.push(y);
            dz.push(z);
            ds.push(total);
            lx = x;
            ly = y;
            lz = z;
        }
    }
    let last = points[n];
    let qx = <f64>last.x, qy = <f64>last.y, qz = <f64>last.z;
    total += Math.sqrt((qx - lx) * (qx - lx) + (qy - ly) * (qy - ly) + (qz - lz) * (qz - lz));
    dx.push(qx);
    dy.push(qy);
    dz.push(qz);
    ds.push(total);

    // resample uniformly
    let tr = new Track();
    tr.step = st;
    tr.length = total;
    let nds = ds.length - 1;
    let j = 1;
    let count = <i32>Math.floor(total / st) + 1;
    for (let i = 0; i < count; i++) {
        let s = <f64>i * st;
        while (j < nds - 1 && ds[j + 1] < s) j += 1;
        let s0 = ds[j], s1 = ds[j + 1];
        let t = s1 > s0 ? mathx.saturate((s - s0) / (s1 - s0)) : 0.0;
        tr.px.push(dx[j] + (dx[j + 1] - dx[j]) * t);
        // never let the spline's overshoot dip the rail under the sea
        tr.py.push(lmax(0, dy[j] + (dy[j + 1] - dy[j]) * t));
        tr.pz.push(dz[j] + (dz[j + 1] - dz[j]) * t);
    }
    let tn = tr.px.length - 1;
    tr.n = tn;
    // tangents
    for (let i = 1; i <= tn; i++) {
        let a = max(i - 1, 1);
        let b = min(i + 1, tn);
        let vx = tr.px[b] - tr.px[a], vy = tr.py[b] - tr.py[a], vz = tr.pz[b] - tr.pz[a];
        let l = Math.sqrt(vx * vx + vy * vy + vz * vz);
        if (l < 1e-6) {
            vx = 0;
            vy = 0;
            vz = -1;
            l = 1;
        }
        tr.fx.push(vx / l);
        tr.fy.push(vy / l);
        tr.fz.push(vz / l);
    }
    // bank from horizontal curvature, smoothed
    let raw: Array<f64> = [0.0];
    for (let i = 1; i <= tn; i++) {
        let a = max(i - 8, 1);
        let b = min(i + 8, tn);
        let ha = Math.atan2(tr.fx[a], -tr.fz[a]);
        let hb = Math.atan2(tr.fx[b], -tr.fz[b]);
        let turn = mathx.wrapAngle(hb - ha) / lmax(<f64>(b - a) * st, 1);
        raw.push(mathx.clamp(-turn * 48, -0.45, 0.45));
    }
    for (let i = 1; i <= tn; i++) {
        let acc = 0.0, c = 0.0;
        for (let k = max(i - 10, 1); k <= min(i + 10, tn); k++) {
            acc += raw[k];
            c += 1;
        }
        tr.bank.push(acc / c);
    }
    return tr;
}

let IDX_I: i32 = 1;
let IDX_T: f64 = 0;
@inline function idx(tr: Track, s: f64): void {
    let f = mathx.clamp(s / tr.step, 0, <f64>tr.n - 1.0001);
    let i = Math.floor(f);
    IDX_I = <i32>i + 1;
    IDX_T = f - i;
}

// Before the start (s < 0) the rail runs straight back along frame 0: p0 +
// f0 * s, frame 0's axes, bank 0 (the flight school lane out at sea).
let BEH_P: Vector = Vector.xyz(0, 0, 0);
let BEH_F: Vector = Vector.xyz(0, 0, -1);
function behind(tr: Track, s: f64): void {
    let f = mathx.norm(mathx.v3(tr.fx[1], tr.fy[1], tr.fz[1]));
    BEH_P = mathx.v3(tr.px[1] + <f64>f.x * s, tr.py[1] + <f64>f.y * s, tr.pz[1] + <f64>f.z * s);
    BEH_F = f;
}

export function pos(tr: Track, s: f64): Vector {
    if (s < 0) {
        behind(tr, s);
        return BEH_P;
    }
    idx(tr, s);
    let i = IDX_I, t = IDX_T;
    return mathx.v3(
        tr.px[i] + (tr.px[i + 1] - tr.px[i]) * t,
        tr.py[i] + (tr.py[i + 1] - tr.py[i]) * t,
        tr.pz[i] + (tr.pz[i + 1] - tr.pz[i]) * t
    );
}

// frame(tr, s) -> pos, fwd, right, up, bank
export let FRAME_P: Vector = Vector.xyz(0, 0, 0);
export let FRAME_F: Vector = Vector.xyz(0, 0, -1);
export let FRAME_R: Vector = Vector.xyz(1, 0, 0);
export let FRAME_U: Vector = Vector.xyz(0, 1, 0);
export let FRAME_BANK: f64 = 0;

export function frame(tr: Track, s: f64): void {
    if (s < 0) {
        behind(tr, s);
        let f = BEH_F;
        let r = mathx.norm(mathx.v3(-<f64>f.z, 0, <f64>f.x));
        FRAME_P = BEH_P;
        FRAME_F = f;
        FRAME_R = r;
        FRAME_U = cross(r, f);
        FRAME_BANK = 0;
        return;
    }
    idx(tr, s);
    let i = IDX_I, t = IDX_T;
    let p = mathx.v3(
        tr.px[i] + (tr.px[i + 1] - tr.px[i]) * t,
        tr.py[i] + (tr.py[i + 1] - tr.py[i]) * t,
        tr.pz[i] + (tr.pz[i + 1] - tr.pz[i]) * t
    );
    let f = mathx.norm(mathx.v3(
        tr.fx[i] + (tr.fx[i + 1] - tr.fx[i]) * t,
        tr.fy[i] + (tr.fy[i + 1] - tr.fy[i]) * t,
        tr.fz[i] + (tr.fz[i + 1] - tr.fz[i]) * t
    ));
    let r = mathx.norm(mathx.v3(-<f64>f.z, 0, <f64>f.x));
    FRAME_P = p;
    FRAME_F = f;
    FRAME_R = r;
    FRAME_U = cross(r, f);
    FRAME_BANK = tr.bank[i] + (tr.bank[i + 1] - tr.bank[i]) * t;
}

// World point from rail coordinates: distance s, lateral x (right), height y (absolute world y).
export function toWorld(tr: Track, s: f64, x: f64, y: f64): Vector {
    frame(tr, s);
    let p = FRAME_P, r = FRAME_R;
    return mathx.v3(<f64>p.x + <f64>r.x * x, y, <f64>p.z + <f64>r.z * x);
}
