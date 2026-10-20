// Port of src/game/core_rings.luau. Rings: gold (+boost, +5% shield), silver
// (+25% shield), boost (refill and a speed kick). Pass-through detection on
// the ring plane, chains, and the collect effect (flare, expanding ring,
// sparkles).
//
// Port: `new` -> create. Lists are 1-based (slot 0 a hole). Optional numbers
// are NaN (nil). The ring basis is spun in f32 as Luau's Vector math.
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import * as gpu from "../lib/gpu";
import { Batch } from "../lib/gpu";
import * as meshgen from "../lib/meshgen";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import * as track from "../world/track";
import * as level from "../world/level";
import { lmax, opt } from "../lib/compat";

export const RADIUS: f64 = 3.2;
export const CATCH: f64 = 3.35;

export class Ring {
    s: f64 = 0;
    x: f64 = 0;
    y: f64 = 0;
    kind: string = "gold";
    taken: bool = false;
    missed: bool = false;
    pos: Vector = Vector.xyz(0, 0, 0);
    fwd: Vector = Vector.xyz(0, 0, -1);
    rt: Vector = Vector.xyz(1, 0, 0);
    up: Vector = Vector.xyz(0, 1, 0);
    flash: f64 = 0;
    seed: f64 = 0;
    tag: f64 = 0; // 0 the mission's; flight school sets tag their drill set
}

export class Rings {
    list: Array<Ring> = new Array<Ring>(1); // 1-based
    gold: Batch? = null;
    silver: Batch? = null;
    boost: Batch? = null;
    spin: f64 = 0;
    // events for this frame
    collected: Array<Ring> = new Array<Ring>(1); // 1-based
    missedCount: f64 = 0;
    px: f64 = 0; // the pilot's rail x, y at the last update (draw: rings he is missing); NaN = nil
    py: f64 = 0;
}

function torus(hex: f64, emissive: f64, cap: i32, name: string): Batch {
    let b = meshgen.create(2048);
    meshgen.color(b, hex);
    meshgen.aux(b, emissive, 1, 0, 1);
    meshgen.torus(b, RADIUS, 0.42, 36, 10);
    return gpu.batch(name, gpu.uploadMesh(b), cap, true, true);
}

// A ring at rail (s, x, y) (any s: the school lane extrapolates, s < 0).
// tag: NaN = nil (0).
export class Spec {
    s: f64;
    x: f64;
    y: f64;
    kind: string;
    tag: f64;
    constructor(s: f64 = 0, x: f64 = 0, y: f64 = 0, kind: string = "gold", tag: f64 = NaN) {
        this.s = s;
        this.x = x;
        this.y = y;
        this.kind = kind;
        this.tag = tag;
    }
}

function build(s: f64, x: f64, y: f64, kind: string, tag: f64, seed: f64): Ring {
    track.frame(level.track, s);
    let p = track.FRAME_P, f = track.FRAME_F, rt = track.FRAME_R;
    let hf = mathx.norm(Vector.xyz(f.x, f.y, f.z));
    let r = new Ring();
    r.s = s;
    r.x = x;
    r.y = y;
    r.kind = kind;
    r.pos = mathx.v3(<f64>p.x + <f64>rt.x * x, <f64>p.y + y, <f64>p.z + <f64>rt.z * x);
    r.fwd = hf;
    r.rt = rt;
    r.up = mathx.cross(rt, hf);
    r.seed = seed;
    r.tag = tag;
    return r;
}

// The mission's rings (level.rings) with their batches.
export function create(): Rings {
    let Rg = new Rings();
    Rg.gold = torus(0xF2B632, 0.12, 64, "ringsGold");
    Rg.silver = torus(0xDDE8F2, 0.15, 32, "ringsSilver");
    Rg.boost = torus(0x4FD8FF, 0.45, 32, "ringsBoost");
    let l = level.rings;
    for (let i = 1; i < l.length; i++) {
        let sp = l[i];
        Rg.list.push(build(sp.s, sp.x, sp.y, sp.kind, 0, <f64>i * 1.37));
    }
    return Rg;
}

// A ring set from any Spec list (1-based; the flight school's practice
// rings). share: draw with that set's batches (one of the two draws a frame).
export function fromSpecs(specs: Array<Spec>, share: Rings? = null): Rings {
    let Rg = new Rings();
    if (share != null) {
        Rg.gold = share.gold;
        Rg.silver = share.silver;
        Rg.boost = share.boost;
    }
    append(Rg, specs);
    return Rg;
}

// specs: 1-based
export function append(Rg: Rings, specs: Array<Spec>): void {
    let l = Rg.list;
    for (let i = 1; i < specs.length; i++) {
        let sp = specs[i];
        l.push(build(sp.s, sp.x, sp.y, sp.kind, opt(sp.tag, 0), <f64>l.length * 1.37 + sp.s * 0.01));
    }
}

// Drop rings: tag (NaN = nil) drops that tag's untaken rings; always drops
// taken rings whose flash is over and missed rings more than 40 m behind ps.
export function prune(Rg: Rings, ps: f64, tag: f64 = NaN): void {
    let l = Rg.list;
    for (let i = l.length - 1; i >= 1; i--) {
        let r = l[i];
        if ((r.taken && r.flash <= 0) || (r.missed && r.s < ps - 40) || (!isNaN(tag) && r.tag == tag && !r.taken)) {
            l.splice(i, 1);
        }
    }
}

export function reset(Rg: Rings): void {
    let l = Rg.list;
    for (let i = 1; i < l.length; i++) {
        let r = l[i];
        r.taken = false;
        r.missed = false;
        r.flash = 0;
    }
}

// Detect rings crossed between s0 and s1 (player rail coords x, y).
export function update(Rg: Rings, s0: f64, s1: f64, x: f64, y: f64, dt: f64): void {
    Rg.spin += dt;
    Rg.px = x;
    Rg.py = y;
    Rg.collected.length = 1;
    Rg.missedCount = 0;
    let l = Rg.list;
    for (let i = 1; i < l.length; i++) {
        let r = l[i];
        if (r.flash > 0) {
            r.flash = lmax(0, r.flash - dt * 3.2);
        }
        if (!r.taken && !r.missed && r.s > s0 && r.s <= s1) {
            let dx = r.x - x, dy = r.y - y;
            if (dx * dx + dy * dy < CATCH * CATCH) {
                r.taken = true;
                r.flash = 1;
                Rg.collected.push(r);
            } else {
                r.missed = true;
                Rg.missedCount += 1;
            }
        }
    }
}

// Luau nil eye (Vector is a value class): x NaN
export const NO_EYE: Vector = Vector.xyz(NaN, NaN, NaN);

// eye: the camera (a taken ring never sweeps through the lens); NO_EYE = nil.
export function draw(Rg: Rings, r: Gfx, ps: f64, t: f64, eye: Vector = NO_EYE): void {
    let hasEye = !isNaN(<f64>eye.x);
    let bg = Rg.gold, bs = Rg.silver, bb = Rg.boost;
    if (bg == null || bs == null || bb == null) return;
    gpu.reset(bg);
    gpu.reset(bs);
    gpu.reset(bb);
    let l = Rg.list;
    for (let i = 1; i < l.length; i++) {
        let ring = l[i];
        if (!(ring.s > ps - 30 && ring.s < ps + 1300)) continue;
        if (ring.taken && ring.flash <= 0) continue;
        let boost = ring.kind == "boost";
        let b = ring.kind == "silver" ? bs : boost ? bb : bg;
        let scale = 1.0;
        let op = 0.0;
        let flash = 0.0;
        let pulse = 0.0;
        let px = <f64>ring.pos.x, py = <f64>ring.pos.y, pz = <f64>ring.pos.z;
        if (ring.taken) {
            // a taken ring is flung ahead of the pilot, shrinking as it
            // dissolves: it never comes back through the lens
            let k = 1 - ring.flash;
            let ahead = lmax(0, ps - ring.s) + 4 + mathx.easeOutCubic(k) * 22;
            let f = ring.fwd;
            px = px + <f64>f.x * ahead;
            py = py + <f64>f.y * ahead;
            pz = pz + <f64>f.z * ahead;
            scale = 1 - mathx.easeOutCubic(k) * 0.45;
            op = Math.sqrt(k);
            flash = ring.flash * 0.3;
            if (hasEye) {
                let dx = px - <f64>eye.x, dy = py - <f64>eye.y, dz = pz - <f64>eye.z;
                let lim = RADIUS * scale + 8;
                if (dx * dx + dy * dy + dz * dz < lim * lim) continue;
            }
        } else {
            // a ring he is missing shrinks away over his last 6 m to it and
            // 2 m past, so it is gone before the lens (~10 m behind him) can
            // sweep through it
            let d = ring.s - ps;
            let gone = 0.0;
            if (hasEye && d < 6) {
                let qx = opt(Rg.px, ring.x), qy = opt(Rg.py, ring.y);
                let mx = ring.x - qx, my = ring.y - qy;
                if (d < 0 || mx * mx + my * my > (CATCH + 0.6) * (CATCH + 0.6)) {
                    gone = mathx.saturate((6 - d) / 8);
                }
                let dx = px - <f64>eye.x, dy = py - <f64>eye.y, dz = pz - <f64>eye.z;
                if (gone >= 1 || (d < 0 && dx * dx + dy * dy + dz * dz < (RADIUS + 8) * (RADIUS + 8))) continue;
            }
            // slow bob and a heartbeat glint as it nears
            pulse = mathx.saturate(1 - d / 160) * (0.5 + 0.5 * Math.sin(t * 9 + ring.seed));
            scale = (1 + pulse * 0.04) * (1 - gone);
            flash = pulse * 0.25;
        }
        let a = Rg.spin * (boost ? 1.4 : 0.35) + ring.seed;
        let c = <f32>Math.cos(a), s = <f32>Math.sin(a);
        let rt = ring.rt, up = ring.up, f = ring.fwd;
        // rt * c + up * s, up * c - rt * s (f32 per op, as Luau's Vector)
        let rxx: f32 = rt.x * c + up.x * s, rxy: f32 = rt.y * c + up.y * s, rxz: f32 = rt.z * c + up.z * s;
        let uxx: f32 = up.x * c - rt.x * s, uxy: f32 = up.y * c - rt.y * s, uxz: f32 = up.z * c - rt.z * s;
        let bob = ring.taken ? 0.0 : Math.sin(t * 1.6 + ring.seed) * 0.25;
        gpu.addBasis(b, px, py + bob, pz, rxx, rxy, rxz, uxx, uxy, uxz, f.x, f.y, f.z, scale, scale, scale, 1, 1, 1, flash, boost ? 0.6 : 0, op);
    }
    R.addBatch(r, bg);
    R.addBatch(r, bs);
    R.addBatch(r, bb);
}
