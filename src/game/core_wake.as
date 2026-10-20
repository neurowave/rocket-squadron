// Port of src/game/core_wake.luau. Water wake: when a flyer skims the sea it
// leaves a V of foam on the surface (two arms spreading outward), a churned
// center streak, and fading foam blobs behind. Flat foam meshes on the water
// (toon pipeline, unlit, no ink) that break up with the instance dissolve as
// they age.
//
// Port: `new` -> create. segs is 1-based (slot 0 a hole); head is 1-based.
import * as mathx from "../lib/mathx";
import * as gpu from "../lib/gpu";
import { Batch } from "../lib/gpu";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import { lmax, lrandom } from "../lib/compat";

export const MAX_ALT: f64 = 5.0; // no wake above this altitude
export const LIFE: f64 = 1.9;
export const EMIT: f64 = 0.045; // seconds between segments
export const CAP: i32 = 72;

export class Seg {
    active: bool = false;
    x: f64 = 0;
    z: f64 = 0;
    fx: f64 = 0; // horizontal forward at emission
    fz: f64 = -1;
    age: f64 = 0;
    life: f64 = 1;
    strength: f64 = 0; // 0..1 (how low the flyer was)
    seed: f64 = 0;
}

export class Wake {
    segs: Array<Seg> = new Array<Seg>(1); // 1-based
    head: i32 = 1;
    emitT: f64 = 0;
    arm: Batch? = null;
    streak: Batch? = null;
}

// flat ellipse facing +Y, long axis along -Z (the mesh nose)
function ellipse(b: Builder, seg: i32): void {
    let c = meshgen.vertex(b, 0, 0, 0, 0, 1, 0);
    let prev = -1;
    for (let i = 0; i <= seg; i++) {
        let a = -<f64>i / <f64>seg * mathx.TAU;
        let wob = 1 + 0.12 * Math.sin(<f64>i * 2.7);
        let v = meshgen.vertex(b, Math.cos(a) * 0.5 * wob, 0, Math.sin(a) * 0.5 * wob, 0, 1, 0);
        if (i > 0 && prev >= 0) meshgen.tri(b, c, prev, v);
        prev = v;
    }
}

export function create(): Wake {
    let W = new Wake();
    for (let i = 0; i < CAP; i++) W.segs.push(new Seg());
    return W;
}

export function build(W: Wake): void {
    let b = meshgen.create(64);
    meshgen.color(b, 0xF4FAFF);
    meshgen.aux(b, 0.15, 0, 1, 0);
    ellipse(b, 14);
    W.arm = gpu.batch("wakeArms", gpu.uploadMesh(b), CAP * 2, false, false);
    let sb = meshgen.create(64);
    meshgen.color(sb, 0xE6F6FF);
    meshgen.aux(sb, 0.1, 0, 1, 0);
    ellipse(sb, 14);
    W.streak = gpu.batch("wakeStreak", gpu.uploadMesh(sb), CAP, false, false);
}

export function clear(W: Wake): void {
    let l = W.segs;
    for (let i = 1; i < l.length; i++) l[i].active = false;
}

// x, z: flyer world position; alt: height above the sea; fwd: flight direction.
export function update(W: Wake, dt: f64, x: f64, z: f64, alt: f64, fx: f64, fz: f64, emit: bool): void {
    let l = W.segs;
    for (let i = 1; i < l.length; i++) {
        let s = l[i];
        if (s.active) {
            s.age += dt;
            if (s.age >= s.life) s.active = false;
        }
    }
    if (!emit || alt > MAX_ALT) {
        W.emitT = 0;
        return;
    }
    W.emitT -= dt;
    if (W.emitT > 0) return;
    W.emitT = EMIT;
    let s = l[W.head];
    W.head = (W.head % CAP) + 1;
    let n = Math.sqrt(fx * fx + fz * fz);
    s.active = true;
    s.x = x;
    s.z = z;
    s.fx = n > 1e-4 ? fx / n : 0;
    s.fz = n > 1e-4 ? fz / n : -1;
    s.age = 0;
    s.strength = mathx.saturate((MAX_ALT - alt) / (MAX_ALT - 1.1));
    s.life = LIFE * (0.55 + 0.45 * s.strength);
    s.seed = lrandom();
}

export function draw(W: Wake, r: Gfx): void {
    let ab = W.arm, sb = W.streak;
    if (ab == null || sb == null) return;
    gpu.reset(ab);
    gpu.reset(sb);
    let l = W.segs;
    for (let i = 1; i < l.length; i++) {
        let s = l[i];
        if (!s.active) continue;
        let k = s.age / s.life;
        let st = s.strength;
        let fx = s.fx, fz = s.fz;
        let rx = -fz, rz = fx; // horizontal right
        let y = 0.07;
        // center streak: churned water right under the path
        let sw = (0.5 + k * 1.3) * (0.5 + 0.5 * st);
        let sl = 2.6 + k * 2;
        // fades in behind the flyer so his reflection stays readable right under him
        let dis = mathx.saturate(lmax(0.3 + k * 0.85 + (1 - st) * 0.25, 1 - s.age / 0.12));
        gpu.addBasis(sb, s.x, y, s.z, rx, 0, rz, 0, 1, 0, fx, 0, fz, sw, 1, sl, 1, 1, 1, 0, 0.1, dis);
        // V arms: spread outward and back
        let spread = 0.8 + s.age * (6 + st * 5);
        for (let side = -1.0; side <= 1; side += 2) {
            let ax = rx * side * 0.55 - fx * 0.84;
            let az = rz * side * 0.55 - fz * 0.84;
            let al = Math.sqrt(ax * ax + az * az);
            ax = ax / al;
            az = az / al;
            let px = s.x + rx * side * spread;
            let pz = s.z + rz * side * spread;
            let w = (0.32 + k * 0.55) * (0.6 + 0.4 * st);
            let len = (2.8 + k * 3) * (0.6 + 0.4 * st);
            let d2 = mathx.saturate(lmax(k * k * 1.1 + (1 - st) * 0.3 + 0.05, 1 - s.age / 0.1));
            // basis: x = width (perpendicular to arm), z = along the arm
            gpu.addBasis(ab, px, y + 0.01, pz, -az, 0, ax, 0, 1, 0, ax, 0, az, w, 1, len, 1, 1, 1, 0, 0.2, d2);
        }
    }
    R.addBatch(r, sb);
    R.addBatch(r, ab);
}
