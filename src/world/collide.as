// Port of src/world/collide.luau: scenery colliders (vertical cylinders,
// oriented boxes, spheres, rock shells) and the penetration query.
// Multi-returns go through module globals: extent -> EXT[0..5], test ->
// T_D / T_NX / T_NY / T_NZ, span -> SPAN_LO / SPAN_HI, query -> Q_*.
// `top` (a Luau function field) is a TopFn subclass; shell points P are a
// Float32Array (Luau packs them into a buffer as f32 too).
import { Vector } from "rive/vector";
import { HUGE, lmin, lmax, lclamp } from "../lib/compat";

export abstract class TopFn {
    abstract at(x: f64, z: f64): f64;
}

export class Collider {
    kind: i32 = 0;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    r: f64 = 0;
    y0: f64 = 0;
    y1: f64 = 0;
    ux: f64 = 1;
    uy: f64 = 0;
    uz: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 1;
    vz: f64 = 0;
    wx: f64 = 0;
    wy: f64 = 0;
    wz: f64 = 1;
    hx: f64 = 0;
    hy: f64 = 0;
    hz: f64 = 0;
    // kind 3
    n: i32 = 0;
    m: i32 = 0;
    P: Float32Array? = null;
    rooted: bool = false;
    top: TopFn? = null;
    bx: f64 = 0;
    bz: f64 = 0;
    br: f64 = 0;
    b0: f64 = 0;
    b1: f64 = 0;
    sub: Array<Collider>? = null; // 0-based
}

export class Bounds {
    minx: f64 = HUGE;
    miny: f64 = HUGE;
    minz: f64 = HUGE;
    maxx: f64 = -HUGE;
    maxy: f64 = -HUGE;
    maxz: f64 = -HUGE;
}

function blank(kind: i32): Collider {
    let c = new Collider();
    c.kind = kind;
    return c;
}

export function cylinder(x: f64, z: f64, r: f64, y0: f64, y1: f64): Collider {
    let c = blank(0);
    c.x = x;
    c.z = z;
    c.r = r;
    c.y0 = y0;
    c.y1 = y1;
    c.y = (y0 + y1) * 0.5;
    return c;
}

export function sphere(x: f64, y: f64, z: f64, r: f64): Collider {
    let c = blank(2);
    c.x = x;
    c.y = y;
    c.z = z;
    c.r = r;
    c.y0 = y - r;
    c.y1 = y + r;
    return c;
}

export function box(x: f64, y: f64, z: f64, u: Vector, v: Vector, w: Vector, hx: f64, hy: f64, hz: f64): Collider {
    let c = blank(1);
    c.x = x;
    c.y = y;
    c.z = z;
    c.ux = u.x; c.uy = u.y; c.uz = u.z;
    c.vx = v.x; c.vy = v.y; c.vz = v.z;
    c.wx = w.x; c.wy = w.y; c.wz = w.z;
    c.hx = hx;
    c.hy = hy;
    c.hz = hz;
    let ey = Math.abs(<f64>u.y) * hx + Math.abs(<f64>v.y) * hy + Math.abs(<f64>w.y) * hz;
    c.y0 = y - ey;
    c.y1 = y + ey;
    c.r = lmin(lmin(hx, hy), hz);
    return c;
}

export function yawBox(x: f64, y: f64, z: f64, yaw: f64, hx: f64, hy: f64, hz: f64): Collider {
    let c = Math.cos(yaw), s = Math.sin(yaw);
    return box(x, y, z, Vector.xyz(<f32>c, 0, <f32>s), Vector.xyz(0, 1, 0), Vector.xyz(<f32>-s, 0, <f32>c), hx, hy, hz);
}

const TOPF: StaticArray<f64> = [0, 0.4, 0.7];

// Rock shell: n columns of m points (y, x, z), P 1-based (slot 0 unused).
export function shell(n: i32, m: i32, P: Array<f64>, rooted: bool, top: TopFn?): Collider {
    let c = blank(3);
    let cx = 0.0, cz = 0.0, k = 0.0;
    let y0 = HUGE, y1 = -HUGE;
    for (let i = 1; i <= n * m; i++) {
        let o = (i - 1) * 3;
        let py = P[o + 1];
        y0 = lmin(y0, py);
        y1 = lmax(y1, py);
        cx += P[o + 2];
        cz += P[o + 3];
        k += 1;
    }
    cx = cx / k;
    cz = cz / k;
    let r = 0.0;
    for (let i = 1; i <= n * m; i++) {
        let o = (i - 1) * 3;
        let dx = P[o + 2] - cx, dz = P[o + 3] - cz;
        r = lmax(r, Math.sqrt(dx * dx + dz * dz));
    }
    if (top != null) {
        for (let i = 1; i <= n; i++) {
            let o = ((i - 1) * m + m - 1) * 3;
            let tx = P[o + 2], tz = P[o + 3];
            for (let q = 0; q < 3; q++) {
                let f = TOPF[q];
                let h = top.at(tx + (cx - tx) * f, tz + (cz - tz) * f);
                y1 = lmax(y1, h);
            }
        }
    }
    c.x = cx;
    c.z = cz;
    c.r = r;
    c.y0 = rooted ? lmin(y0, -6) : y0;
    c.y1 = y1;
    c.y = (c.y0 + c.y1) * 0.5;
    let pk = new Float32Array(n * m * 3);
    for (let i = 1; i <= n * m * 3; i++) pk[i - 1] = <f32>P[i];
    c.n = n;
    c.m = m;
    c.P = pk;
    c.rooted = rooted;
    c.top = top;
    c.bx = cx;
    c.bz = cz;
    c.br = r;
    c.b0 = c.y0;
    c.b1 = y1;
    return c;
}

export function body(c: Collider, x: f64, z: f64, r: f64, y0: f64, y1: f64): void {
    c.x = x;
    c.z = z;
    c.r = r;
    c.y0 = y0;
    c.y1 = y1;
    c.y = (y0 + y1) * 0.5;
}

export function attach(c: Collider, s: Collider): void {
    let sub = c.sub;
    if (sub == null) {
        sub = [];
        c.sub = sub;
    }
    sub.push(s);
    let dx = s.bx - c.bx, dz = s.bz - c.bz;
    c.br = lmax(c.br, Math.sqrt(dx * dx + dz * dz) + s.br);
    c.b0 = lmin(c.b0, s.b0);
    c.b1 = lmax(c.b1, s.b1);
}

export const EXT = new StaticArray<f64>(6);

// Conservative world bounds of one collider into EXT.
export function extent(c: Collider): void {
    let e = EXT;
    if (c.kind == 3) {
        e[0] = c.bx - c.br; e[1] = c.b0; e[2] = c.bz - c.br;
        e[3] = c.bx + c.br; e[4] = c.b1; e[5] = c.bz + c.br;
        return;
    } else if (c.kind == 0) {
        e[0] = c.x - c.r; e[1] = c.y0; e[2] = c.z - c.r;
        e[3] = c.x + c.r; e[4] = c.y1; e[5] = c.z + c.r;
        return;
    } else if (c.kind == 2) {
        e[0] = c.x - c.r; e[1] = c.y - c.r; e[2] = c.z - c.r;
        e[3] = c.x + c.r; e[4] = c.y + c.r; e[5] = c.z + c.r;
        return;
    }
    let ex = Math.abs(c.ux) * c.hx + Math.abs(c.vx) * c.hy + Math.abs(c.wx) * c.hz;
    let ey = Math.abs(c.uy) * c.hx + Math.abs(c.vy) * c.hy + Math.abs(c.wy) * c.hz;
    let ez = Math.abs(c.uz) * c.hx + Math.abs(c.vz) * c.hy + Math.abs(c.wz) * c.hz;
    e[0] = c.x - ex; e[1] = c.y - ey; e[2] = c.z - ez;
    e[3] = c.x + ex; e[4] = c.y + ey; e[5] = c.z + ez;
}

// list: 1-based (slot 0 unused)
export function bounds(list: Array<Collider>): Bounds {
    let b = new Bounds();
    let e = EXT;
    for (let i = 1; i < list.length; i++) {
        extent(list[i]);
        b.minx = lmin(b.minx, e[0]);
        b.miny = lmin(b.miny, e[1]);
        b.minz = lmin(b.minz, e[2]);
        b.maxx = lmax(b.maxx, e[3]);
        b.maxy = lmax(b.maxy, e[4]);
        b.maxz = lmax(b.maxz, e[5]);
    }
    return b;
}

// Shell cut scratch (1-based).
const SX: Array<f64> = [0.0];
const SZ: Array<f64> = [0.0];
const SB: Array<f64> = [0.0];
const ST: Array<f64> = [0.0];

function cut(c: Collider, y: f64): void {
    let n = c.n, m = c.m;
    let P = c.P!;
    let span = (m - 1) * 3;
    for (let i = 1; i <= n; i++) {
        let o = (i - 1) * m * 3;
        let yb = <f64>P[o], yt = <f64>P[o + span];
        SB[i] = yb;
        ST[i] = yt;
        if (y <= yb) {
            SX[i] = <f64>P[o + 1];
            SZ[i] = <f64>P[o + 2];
        } else if (y >= yt) {
            SX[i] = <f64>P[o + span + 1];
            SZ[i] = <f64>P[o + span + 2];
        } else {
            let q = o;
            while (<f64>P[q + 3] < y) q += 3;
            let ya = <f64>P[q], yb2 = <f64>P[q + 3];
            let t = yb2 > ya ? (y - ya) / (yb2 - ya) : 1.0;
            let xa = <f64>P[q + 1], za = <f64>P[q + 2];
            SX[i] = xa + (<f64>P[q + 4] - xa) * t;
            SZ[i] = za + (<f64>P[q + 5] - za) * t;
        }
    }
}

export let SPAN_LO: f64 = 0;
export let SPAN_HI: f64 = 0;

function reach(c: Collider, ox: f64, oz: f64, dx: f64, dz: f64, ya: f64, yb: f64): void {
    let lo = HUGE, hi = -HUGE;
    let n = c.n, m = c.m;
    let P = c.P!;
    if (ya > c.b1 || !(c.rooted || yb >= <f64>P[0])) {
        SPAN_LO = lo;
        SPAN_HI = hi;
        return;
    }
    for (let k = 1; k <= 2; k++) {
        cut(c, k == 1 ? ya : yb);
        for (let i = 1; i <= n; i++) {
            let l = (SX[i] - ox) * dx + (SZ[i] - oz) * dz;
            lo = lmin(lo, l);
            hi = lmax(hi, l);
        }
    }
    for (let q = 0; q <= (n * m - 1) * 3; q += 3) {
        let py = <f64>P[q];
        if (py > ya && py < yb) {
            let l = (<f64>P[q + 1] - ox) * dx + (<f64>P[q + 2] - oz) * dz;
            lo = lmin(lo, l);
            hi = lmax(hi, l);
        }
    }
    SPAN_LO = lo;
    SPAN_HI = hi;
}

export function span(c: Collider, ox: f64, oz: f64, dx: f64, dz: f64, ya: f64, yb: f64): void {
    reach(c, ox, oz, dx, dz, ya, yb);
    let lo = SPAN_LO, hi = SPAN_HI;
    let sub = c.sub;
    if (sub != null) {
        for (let i = 0; i < sub.length; i++) {
            reach(sub[i], ox, oz, dx, dz, ya, yb);
            lo = lmin(lo, SPAN_LO);
            hi = lmax(hi, SPAN_HI);
        }
    }
    SPAN_LO = lo;
    SPAN_HI = hi;
}

export let T_D: f64 = 0;
export let T_NX: f64 = 0;
export let T_NY: f64 = 0;
export let T_NZ: f64 = 0;

@inline function ret(d: f64, nx: f64, ny: f64, nz: f64): void {
    T_D = d;
    T_NX = nx;
    T_NY = ny;
    T_NZ = nz;
}

function testShell(c: Collider, x: f64, y: f64, z: f64, radius: f64): void {
    let n = c.n;
    cut(c, y);
    let inside = false;
    let best = HUGE, bqx = 0.0, bqz = 0.0, bt = 0.0;
    let bi = 1;
    let j = n;
    for (let i = 1; i <= n; i++) {
        let ax = SX[j], az = SZ[j], bx = SX[i], bz = SZ[i];
        if ((az > z) != (bz > z) && x < ax + (bx - ax) * (z - az) / (bz - az)) inside = !inside;
        let ex = bx - ax, ez = bz - az;
        let l2 = ex * ex + ez * ez;
        let t = l2 > 1e-12 ? lclamp(((x - ax) * ex + (z - az) * ez) / l2, 0, 1) : 0.0;
        let qx = ax + ex * t, qz = az + ez * t;
        let d2 = (x - qx) * (x - qx) + (z - qz) * (z - qz);
        if (d2 < best) {
            best = d2;
            bqx = qx;
            bqz = qz;
            bt = t;
            bi = i;
        }
        j = i;
    }
    let dist = Math.sqrt(best);
    let ia = bi == 1 ? n : bi - 1;
    let lip = ST[ia] + (ST[bi] - ST[ia]) * bt;
    let foot = c.rooted ? -HUGE : SB[ia] + (SB[bi] - SB[ia]) * bt;
    let hx: f64, hz: f64;
    if (dist > 1e-6) {
        hx = (x - bqx) / dist;
        hz = (z - bqz) / dist;
        if (inside) {
            hx = -hx;
            hz = -hz;
        }
    } else {
        let ex = SX[bi] - SX[ia], ez = SZ[bi] - SZ[ia];
        let l = lmax(Math.sqrt(ex * ex + ez * ez), 1e-9);
        hx = ez / l;
        hz = -ex / l;
        if (hx * (x - c.x) + hz * (z - c.z) < 0) {
            hx = -hx;
            hz = -hz;
        }
    }
    if (inside) {
        let tf = c.top;
        let cap = tf != null ? lmax(tf.at(x, z), lip) : lip;
        let up = cap + radius - y;
        if (up <= 0) { ret(0, 0, 0, 0); return; }
        let down = c.rooted ? HUGE : y - (foot - radius);
        if (down <= 0) { ret(0, 0, 0, 0); return; }
        if (y > cap) { ret(up, 0, 1, 0); return; }
        else if (y < foot) { ret(down, 0, -1, 0); return; }
        let side = dist + radius;
        if (up < side && up <= down) { ret(up, 0, 1, 0); return; }
        else if (down < side) { ret(down, 0, -1, 0); return; }
        ret(side, hx, 0, hz);
        return;
    }
    let dy = y > lip ? y - lip : (y < foot ? y - foot : 0.0);
    let d = Math.sqrt(dist * dist + dy * dy);
    if (d >= radius) { ret(0, 0, 0, 0); return; }
    if (d < 1e-6) { ret(radius, hx, 0, hz); return; }
    ret(radius - d, hx * dist / d, dy / d, hz * dist / d);
}

// Penetration of a sphere (x, y, z, radius) into one collider: T_D (> 0 when
// overlapping) and the push-out normal T_NX / T_NY / T_NZ.
export function test(c: Collider, x: f64, y: f64, z: f64, radius: f64): void {
    if (c.kind == 3) {
        if (y < c.b0 - radius || y > c.b1 + radius) { ret(0, 0, 0, 0); return; }
        let dx = x - c.bx, dz = z - c.bz;
        let rr = c.br + radius;
        if (dx * dx + dz * dz >= rr * rr) { ret(0, 0, 0, 0); return; }
        testShell(c, x, y, z, radius);
        let d = T_D, nx = T_NX, ny = T_NY, nz = T_NZ;
        let sub = c.sub;
        if (sub != null) {
            for (let i = 0; i < sub.length; i++) {
                test(sub[i], x, y, z, radius);
                if (T_D > d) {
                    d = T_D;
                    nx = T_NX;
                    ny = T_NY;
                    nz = T_NZ;
                }
            }
        }
        ret(d, nx, ny, nz);
        return;
    } else if (c.kind == 0) {
        if (y < c.y0 - radius || y > c.y1 + radius) { ret(0, 0, 0, 0); return; }
        let dx = x - c.x, dz = z - c.z;
        let d = Math.sqrt(dx * dx + dz * dz);
        let rr = c.r + radius;
        if (d >= rr) { ret(0, 0, 0, 0); return; }
        let side = rr - d;
        let top = c.y1 + radius - y;
        let bottom = y - (c.y0 - radius);
        if (c.y0 < -1) bottom = HUGE;
        if (top < side && top <= bottom) { ret(top, 0, 1, 0); return; }
        else if (bottom < side) { ret(bottom, 0, -1, 0); return; }
        if (d < 1e-6) { ret(side, 1, 0, 0); return; }
        ret(side, dx / d, 0, dz / d);
        return;
    } else if (c.kind == 2) {
        let dx = x - c.x, dy = y - c.y, dz = z - c.z;
        let d2 = dx * dx + dy * dy + dz * dz;
        let rr = c.r + radius;
        if (d2 >= rr * rr) { ret(0, 0, 0, 0); return; }
        let d = Math.sqrt(d2);
        if (d < 1e-6) { ret(rr, 0, 1, 0); return; }
        ret(rr - d, dx / d, dy / d, dz / d);
        return;
    }
    // oriented box
    let px = x - c.x, py = y - c.y, pz = z - c.z;
    let lu = px * c.ux + py * c.uy + pz * c.uz;
    let lv = px * c.vx + py * c.vy + pz * c.vz;
    let lw = px * c.wx + py * c.wy + pz * c.wz;
    let cu = lclamp(lu, -c.hx, c.hx);
    let cv = lclamp(lv, -c.hy, c.hy);
    let cw = lclamp(lw, -c.hz, c.hz);
    let du = lu - cu, dv = lv - cv, dw = lw - cw;
    let d2 = du * du + dv * dv + dw * dw;
    if (d2 > 1e-12) {
        if (d2 >= radius * radius) { ret(0, 0, 0, 0); return; }
        let d = Math.sqrt(d2);
        let nu = du / d, nv = dv / d, nw = dw / d;
        ret(radius - d, nu * c.ux + nv * c.vx + nw * c.wx, nu * c.uy + nv * c.vy + nw * c.wy, nu * c.uz + nv * c.vz + nw * c.wz);
        return;
    }
    let pu = c.hx - Math.abs(lu);
    let pv = c.hy - Math.abs(lv);
    let pw = c.hz - Math.abs(lw);
    if (pu <= pv && pu <= pw) {
        let sg = lu >= 0 ? 1.0 : -1.0;
        ret(pu + radius, c.ux * sg, c.uy * sg, c.uz * sg);
        return;
    } else if (pv <= pw) {
        let sg = lv >= 0 ? 1.0 : -1.0;
        ret(pv + radius, c.vx * sg, c.vy * sg, c.vz * sg);
        return;
    }
    let sg = lw >= 0 ? 1.0 : -1.0;
    ret(pw + radius, c.wx * sg, c.wy * sg, c.wz * sg);
}

export let Q_HIT: bool = false;
export let Q_NX: f64 = 0;
export let Q_NY: f64 = 0;
export let Q_NZ: f64 = 0;
export let Q_DEPTH: f64 = 0;

// Deepest contact against a 1-based list.
export function query(list: Array<Collider>, x: f64, y: f64, z: f64, radius: f64): bool {
    let best = 0.0, bx = 0.0, by = 0.0, bz = 0.0;
    for (let i = 1; i < list.length; i++) {
        test(list[i], x, y, z, radius);
        if (T_D > best) {
            best = T_D;
            bx = T_NX;
            by = T_NY;
            bz = T_NZ;
        }
    }
    Q_HIT = best > 0;
    Q_NX = bx;
    Q_NY = by;
    Q_NZ = bz;
    Q_DEPTH = best;
    return Q_HIT;
}
