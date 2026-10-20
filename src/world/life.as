// Port of src/world/life.luau. Ambient life along the route, animated each
// frame as instanced batches: gull flocks wheeling over the coast and rock
// debris orbiting the two swirl portals. Built lazily on the first update; no
// per-frame allocation.
//
// Port: update returns the gulls batch and sets UPDATE_GULLS / UPDATE_DEBRIS
// (copy them right away). Per-rock lists are 1-based.
import * as mathx from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as gpu from "../lib/gpu";
import { Batch, Mesh } from "../lib/gpu";
import * as trackMod from "./track";
import * as lv from "./level";
import { Gate } from "./level";
import { lmax, lclamp } from "../lib/compat";

class Flock {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    s: f64 = 0;
    n: f64 = 0;
    radius: f64 = 0;
    speed: f64 = 0;
    phase: f64 = 0;
    scale: f64 = 0;
}

class Orbit {
    cx: f64 = 0;
    cy: f64 = 0;
    cz: f64 = 0;
    ax: f64 = 0;
    az: f64 = 0;
    s0: f64 = 0;
    s1: f64 = 0;
    // per rock: start angle, orbit radius, axial offset, angular speed, scale, tumble
    a0: Array<f64> = [0.0];
    d: Array<f64> = [0.0];
    v: Array<f64> = [0.0];
    w: Array<f64> = [0.0];
    sc: Array<f64> = [0.0];
    spin: Array<f64> = [0.0];
}

export class Life {
    gulls: Batch;
    debris: Batch;
    flocks: Array<Flock>; // 1-based
    orbits: Array<Orbit>; // 1-based
    constructor(gulls: Batch, debris: Batch, flocks: Array<Flock>, orbits: Array<Orbit>) {
        this.gulls = gulls;
        this.debris = debris;
        this.flocks = flocks;
        this.orbits = orbits;
    }
}

let state: Life? = null;
let density: f64 = 1; // graphics quality: share of each flock / debris ring drawn

// Graphics quality (scenery.setQuality): 1 draws every bird and rock.
export function setDensity(k: f64): void {
    density = lclamp(k, 0.1, 1);
}

function wing(b: Builder, side: f64): void {
    let inner = mathx.v3(0.12 * side, 0.02, -0.12);
    let innerB = mathx.v3(0.12 * side, 0.02, 0.18);
    let elbow = mathx.v3(0.75 * side, 0.22, -0.05);
    let elbowB = mathx.v3(0.75 * side, 0.22, 0.2);
    let tip = mathx.v3(1.45 * side, 0.05, 0.28);
    // underside first (faces down), then the white top
    if (side > 0) {
        meshgen.color(b, 0xA2AEC0);
        meshgen.flatQuad(b, inner, elbow, elbowB, innerB);
        meshgen.color(b, 0xFBFAF5);
        meshgen.flatQuad(b, innerB, elbowB, elbow, inner);
    } else {
        meshgen.color(b, 0xA2AEC0);
        meshgen.flatQuad(b, innerB, elbowB, elbow, inner);
        meshgen.color(b, 0xFBFAF5);
        meshgen.flatQuad(b, inner, elbow, elbowB, innerB);
    }
    meshgen.color(b, 0x76808F);
    meshgen.flatTri(b, elbow.x, elbow.y, elbow.z, tip.x, tip.y, tip.z, elbowB.x, elbowB.y, elbowB.z);
    meshgen.flatTri(b, elbowB.x, elbowB.y, elbowB.z, tip.x, tip.y, tip.z, elbow.x, elbow.y, elbow.z);
}

// A gull: white body and wings, grey undersides (they read against white
// clouds), grey tips. No ink at all: at 100-300 m a bird is 4-8 px and a
// hull or post's 2 px depth-edge ink swallows it (navy specks). The mesh
// uses the toon cumulus material (aux.z = 0.4): soft white / cool shade
// and the gbuffer "no ink" mark, so post draws no edges around it.
export function gullBuilder(): Builder {
    let b = meshgen.create(512);
    meshgen.aux(b, 0.05, 0, 0.4, 0);
    // body (nose toward -Z)
    meshgen.color(b, 0xFBFAF5);
    meshgen.sphere(b, 0, 0, 0, 0.16, 0.16, 0.55, 8, 5, false);
    meshgen.color(b, 0xE8B23A);
    meshgen.cylinder(b, 0, -0.02, -0.62, 0.05, 0.0, 0.18, 5, false, false);
    // wings: shallow gull "M", double sided
    wing(b, 1);
    wing(b, -1);
    return b;
}

export function rockBuilder(): Builder {
    let b = meshgen.create(512);
    meshgen.aux(b, 0, 1, 0, 0);
    meshgen.color(b, 0x6E7A96);
    meshgen.rock(b, 0, 0, 0, 1, 0.75, 0.9, 3.7, 7, 5);
    return b;
}

function gullMesh(): Mesh {
    return gpu.uploadMesh(gullBuilder());
}

function rockMesh(): Mesh {
    return gpu.uploadMesh(rockBuilder());
}

// gulls over the coast: s, lateral, height
const SPOTS: StaticArray<f64> = [
    60, 55, 34, 420, -70, 58, 560, -40, 62, 980, 80, 40, 1450, -90, 46,
    1700, 30, 44, 2200, 140, 36, 2650, -120, 42, 3050, 20, 70, 3650, -30, 80, 3950, 90, 60,
    -4100, 45, 26, // over the flight school lane
];

function build(): Life {
    let tr = lv.track;
    let flocks = new Array<Flock>(1);
    let r = mathx.rng(4242);
    let total = 0.0;
    for (let q = 0; q < SPOTS.length; q += 3) {
        let s = SPOTS[q], lat = SPOTS[q + 1], hy = SPOTS[q + 2];
        trackMod.frame(tr, s);
        let p = trackMod.FRAME_P, rt = trackMod.FRAME_R;
        let n = mathx.randInt(r, 4, 8);
        total += n;
        let f = new Flock();
        f.x = <f64>p.x + <f64>rt.x * lat;
        f.y = hy;
        f.z = <f64>p.z + <f64>rt.z * lat;
        f.s = s;
        f.n = n;
        f.radius = mathx.randRange(r, 14, 32);
        let sp = mathx.randRange(r, 0.25, 0.45);
        f.speed = sp * (mathx.rand(r) < 0.5 ? -1.0 : 1.0);
        f.phase = mathx.rand(r) * mathx.TAU;
        // far flocks fly bigger birds (a readable "M" at 150 m)
        f.scale = 1.8 + mathx.clamp((Math.abs(lat) - 40) / 110, 0, 1) * 1.3;
        flocks.push(f);
    }
    let orbits = new Array<Orbit>(1);
    let gates: Array<Gate> = [lv.portal, lv.eye];
    for (let gi = 0; gi < 2; gi++) {
        let i = gi + 1;
        let g = gates[gi];
        let c = lv.world(g.s, g.x, g.y);
        trackMod.frame(tr, g.s);
        let f = trackMod.FRAME_F;
        let ffx = <f64>f.x, ffz = <f64>f.z;
        let fl = Math.sqrt(ffx * ffx + ffz * ffz);
        let o = new Orbit();
        o.cx = <f64>c.x;
        o.cy = <f64>c.y;
        o.cz = <f64>c.z;
        o.ax = ffx / fl;
        o.az = ffz / fl;
        o.s0 = g.s - 2200;
        o.s1 = g.s + 60;
        let rr = mathx.rng(<f64>(700 + i));
        let n = i == 1 ? 36 : 48;
        let rMin = g.radius + 12, rMax = g.radius * 1.65;
        for (let k = 0; k < n; k++) {
            let d = mathx.randRange(rr, rMin, rMax);
            o.a0.push(mathx.rand(rr) * mathx.TAU);
            o.d.push(d);
            o.v.push(mathx.randRange(rr, -14, 14));
            o.w.push(mathx.randRange(rr, 0.03, 0.08) * (d < (rMin + rMax) * 0.5 ? 1.4 : 1));
            o.sc.push(mathx.randRange(rr, 0.8, 3.2));
            o.spin.push(mathx.randRange(rr, -0.6, 0.6));
        }
        orbits.push(o);
    }
    let nDebris = 0;
    for (let k = 1; k < orbits.length; k++) nDebris += orbits[k].a0.length - 1;
    return new Life(
        gpu.batch("lifeGulls", gullMesh(), <i32>total, false, true),
        gpu.batch("lifeDebris", rockMesh(), nDebris, true, true),
        flocks,
        orbits
    );
}

// The lazily built state (for tests and the renderer port).
export function getState(): Life {
    let st = state;
    if (st == null) {
        st = build();
        state = st;
    }
    return st;
}

// Fills the batches for the player at rail distance s and returns them
// (empty batches are skipped by R.addBatch).
// update -> gulls (also UPDATE_GULLS), UPDATE_DEBRIS
export let UPDATE_GULLS: Batch? = null;
export let UPDATE_DEBRIS: Batch? = null;
export function update(t: f64, s: f64): Batch {
    let L = getState();
    let gb = L.gulls, db = L.debris;
    gpu.reset(gb);
    gpu.reset(db);
    for (let q = 1; q < L.flocks.length; q++) {
        let f = L.flocks[q];
        if (f.s > s - 250 && f.s < s + 1500) {
            let n = density < 1 ? lmax(2, Math.floor(f.n * density + 0.5)) : f.n;
            let ni = <i32>n;
            for (let ii = 0; ii < ni; ii++) {
                let i = <f64>ii;
                let k = i / n;
                let a = f.phase + k * mathx.TAU + t * f.speed * (1 + k * 0.3);
                let rr = f.radius * (0.7 + 0.5 * Math.sin(k * 7.3 + f.phase));
                let x = f.x + Math.cos(a) * rr;
                let z = f.z + Math.sin(a) * rr;
                let y = f.y + Math.sin(t * 0.9 + k * 5.1) * 2.5 + k * 6;
                // heading along the circle's tangent
                let sg = f.speed > 0 ? 1.0 : -1.0;
                let tx = -Math.sin(a) * sg, tz = Math.cos(a) * sg;
                let yaw = Math.atan2(-tx, -tz);
                let roll = 0.4 * sg + Math.sin(t * 1.3 + k * 3) * 0.12;
                gpu.addYPR(gb, x, y, z, yaw, Math.sin(t * 0.8 + k) * 0.08, roll, f.scale);
            }
        }
    }
    for (let q = 1; q < L.orbits.length; q++) {
        let o = L.orbits[q];
        if (s > o.s0 && s < o.s1) {
            let rx = -o.az, rz = o.ax;
            let na = <f64>(o.a0.length - 1);
            let nr = <i32>(density < 1 ? Math.floor(na * density + 0.5) : na);
            for (let k = 1; k <= nr; k++) {
                let a0 = o.a0[k], d = o.d[k], v = o.v[k], sc = o.sc[k], spin = o.spin[k];
                let a = a0 + t * o.w[k];
                let ca = Math.cos(a), sa = Math.sin(a);
                let x = o.cx + rx * ca * d + o.ax * v;
                let y = o.cy + sa * d + Math.sin(t * 0.7 + a0 * 3) * 1.5;
                let z = o.cz + rz * ca * d + o.az * v;
                gpu.addYPR(db, x, y, z, a0 + t * spin, t * spin * 0.7, a0, sc);
            }
        }
    }
    UPDATE_GULLS = gb;
    UPDATE_DEBRIS = db;
    return gb;
}
