// Port of src/game/weapons.luau. Guns: twin bolts, hold-to-charge lock-on, homing novas, heat; the Reticle view model.
//
// Guns: twin laser bolts (tap), hold-to-charge lock-on (up to 4 targets in a
// cone ahead, LockOn artboard brackets), homing "nova" shots on release, heat
// and overheat. Also drives the Reticle view model (charge / lock / hot).
//
// Port: lists 1-based (slot 0 a dummy); volleyHit 0-based (volley % 64).
// gunL / gunR: Box_Vector? (null = derive from the flight frame; setGuns
// sets both). Multi-returns: sights -> SIGHTS_1 (near) / _2 (far) / _3 /
// _4 (sizes). attachLockOn takes the LockOn artboard input
// (Artboard<LockOn>, LockOn below).
import { Vector } from "rive/vector";
import { Box_Vector } from "rive/box";
import { Artboard } from "rive/artboard";
import { ViewModel } from "rive/data";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import { Ctx } from "./types";
import * as enemies from "./enemies";
import { World, Enemy } from "./ai_types";
import * as fx from "./fx";
import { Fx } from "./fx";
import * as playerMod from "./player";
import { Player } from "./player";
import * as vmx from "./vm";
import { Bag } from "./vm";
import * as gpu from "../lib/gpu";
import { Batch } from "../lib/gpu";
import * as meshgen from "../lib/meshgen";
import { lmin, lmax, mod, imod, lstr } from "../lib/compat";

// The LockOn view model (Data.LockOn): the lock-on bracket artboard binds it.
export class LockOn extends ViewModel {
    constructor(handle: u32) {
        super(handle);
    }
}

export const BOLT_SPEED: f64 = 250;
export const BOLT_LIFE: f64 = 1.3;
export const FIRE_GAP: f64 = 0.075;
export const HOLD_TO_CHARGE: f64 = 0.26;
export const CHARGE_TIME: f64 = 0.85;
export const LOCK_CONE: f64 = Math.cos(20 * (Math.PI / 180));
export const LOCK_RANGE: f64 = 520;
export const MAX_LOCKS: f64 = 4;
export const NOVA_SPEED: f64 = 170;
export const BOLT_HEAT: f64 = 2.4;
export const NOVA_HEAT: f64 = 10;

// bolt colors (lime plasma with a white-hot core)
const GR: f64 = 0.55, GG: f64 = 1.0, GB: f64 = 0.32;
const CR: f64 = 0.93, CG: f64 = 1.0, CB: f64 = 0.78;
// bolt halo: deeper, saturated lime so it reads against white foam and sky
const HR: f64 = 0.4, HG: f64 = 1.0, HB: f64 = 0.1;

export class Bolt {
    active: bool = false;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    dx: f64 = 0; // unit direction
    dy: f64 = 0;
    dz: f64 = -1;
    life: f64 = 0;
    age: f64 = 0;
    volley: f64 = 0;
}

export class Nova {
    active: bool = false;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    life: f64 = 0;
    age: f64 = 0;
    target: Enemy? = null;
    homing: bool = false;
    tx: Array<f64> = [0.0, 0, 0, 0, 0, 0, 0, 0, 0]; // trail ring buffer (1-based, 8)
    ty: Array<f64> = [0.0, 0, 0, 0, 0, 0, 0, 0, 0];
    tz: Array<f64> = [0.0, 0, 0, 0, 0, 0, 0, 0, 0];
    ti: i32 = 1;
}

export class Lock {
    e: Enemy? = null;
    progress: f64 = 0;
    locked: bool = false;
    fade: f64 = 0; // 1 while held, fades out after release/loss
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    dist: f64 = 0;
    art: Artboard<LockOn>? = null;
    bag: Bag? = null;
    sprite: R.Sprite? = null;
    over: f64 = 0; // 0..1 eased: its brackets over the hero (they dim there)
}

export class Flare {
    active: bool = false;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    size: f64 = 1;
    grow: f64 = 0;
    age: f64 = 0;
    life: f64 = 1;
    r: f64 = 1;
    g: f64 = 1;
    b: f64 = 1;
    kind: f64 = 2;
}

export class Weapons {
    bolts: Array<Bolt> = new Array<Bolt>(1);
    novas: Array<Nova> = new Array<Nova>(1);
    locks: Array<Lock> = new Array<Lock>(1);
    flares: Array<Flare> = new Array<Flare>(1);
    fireT: f64 = 0;
    holdT: f64 = 0;
    wasDown: bool = false;
    charging: bool = false;
    charge: f64 = 0;
    lockT: f64 = 0;
    lockCount: f64 = 0;
    muzzle: f64 = 0;
    hot: bool = false;
    hotAmt: f64 = 0;
    aim: Vector = Vector.xyz(0, 0, -1);
    // per-frame events for the caller (HUD pulses, pilot anim)
    firedVolley: bool = false;
    firedNova: bool = false;
    newLock: bool = false;
    reticleBag: Bag? = null;
    volley: f64 = 0; // volley serial (hit ratio counts volleys, not bolts)
    volleyHit: Array<bool> = new Array<bool>(64); // 0-based: volley % 64
    boltBatch: Batch? = null;
    novaBatch: Batch? = null;
    // wrist blaster muzzles in world space (set each frame by the caller from
    // the pilot sprite's hands; null = derive from the flight frame)
    gunL: Box_Vector? = null;
    gunR: Box_Vector? = null;
    // sights kept off the hero (sightsUpdate): world lifts of the near / far
    // reticle, the near one's opacity
    liftN: Vector = Vector.xyz(0, 0, 0);
    liftF: Vector = Vector.xyz(0, 0, 0);
    sightLift: f64 = 0;
    nearOp: f64 = 1;
}

export function create(): Weapons {
    let W = new Weapons();
    for (let i = 1; i <= 64; i++) W.bolts.push(new Bolt());
    for (let i = 1; i <= 8; i++) W.novas.push(new Nova());
    for (let i = 1; i <= <i32>MAX_LOCKS; i++) W.locks.push(new Lock());
    for (let i = 1; i <= 24; i++) W.flares.push(new Flare());
    return W;
}

// Where the bolts leave the pilot (the sprite's wrist blasters).
export function setGuns(W: Weapons, l: Vector, r: Vector): void {
    W.gunL = new Box_Vector(l);
    W.gunR = new Box_Vector(r);
}

// GPU meshes for the bolts (glowing capsules) and nova cores. Call once the
// renderer exists.
export function buildMeshes(W: Weapons): void {
    let nb = meshgen.create(256);
    meshgen.colorf(nb, 0.85, 1, 0.7);
    meshgen.aux(nb, 0.9, 0, 1, 0);
    meshgen.sphere(nb, 0, 0, 0, 1, 1, 1, 12, 8, false);
    W.novaBatch = gpu.batch("novas", gpu.uploadMesh(nb), 8, false, true);
}

// (Artboard<LockOn> as the renderer's untyped Artboard: the same class
// under another view model type, which no cast converts)
unsafe function asLockOnVm(vm: ViewModel): LockOn {
    return changetype<LockOn>(vm);
}
unsafe function asArtboard(a: Artboard<LockOn>): Artboard {
    return changetype<Artboard>(a);
}

// LockOn artboards: one instance + sprite per slot (each needs its own canvas).
export function attachLockOn(W: Weapons, r: R.Gfx, input: Artboard<LockOn>): void {
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        // (the same object, typed: a second wrapper of the handle would own it
        // too, and its collection released the view model under the bag)
        let vm = ViewModel.create("LockOn");
        let art = input.instance(asLockOnVm(vm));
        l.art = art;
        l.bag = vmx.bag(vm);
        l.sprite = R.createSprite(r, "lockon" + lstr(i), asArtboard(art), 320, 320, 1, false, true);
    }
}

export function reset(W: Weapons): void {
    for (let i = 1; i < W.bolts.length; i++) W.bolts[i].active = false;
    for (let i = 1; i < W.novas.length; i++) W.novas[i].active = false;
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        l.e = null;
        l.progress = 0;
        l.locked = false;
        l.fade = 0;
        l.over = 0;
    }
    W.liftN = Vector.xyz(0, 0, 0);
    W.liftF = Vector.xyz(0, 0, 0);
    W.sightLift = 0;
    W.nearOp = 1;
    for (let i = 1; i < W.flares.length; i++) W.flares[i].active = false;
    W.fireT = 0;
    W.holdT = 0;
    W.charging = false;
    W.charge = 0;
    W.lockCount = 0;
    W.wasDown = false;
}

export function flare(W: Weapons, x: f64, y: f64, z: f64, size: f64, grow: f64, life: f64, r: f64, g: f64, b: f64, kind: f64): void {
    let best: Flare? = null;
    for (let i = 1; i < W.flares.length; i++) {
        let f = W.flares[i];
        if (!f.active) {
            best = f;
            break;
        }
    }
    if (best == null) {
        return;
    }
    let f = best;
    f.active = true;
    f.x = x;
    f.y = y;
    f.z = z;
    f.size = size;
    f.grow = grow;
    f.age = 0;
    f.life = life;
    f.r = r;
    f.g = g;
    f.b = b;
    f.kind = kind;
}

// Direction the guns point: rail forward nudged by the stick (the nose leads
// the motion), so the reticles and bolts track where the pilot is heading.
export function aimDir(p: Player): Vector {
    let f = p.fwd, rt = p.right, up = p.up;
    let ax = p.vx / playerMod.MAX_VX * 0.2 + p.sx * 0.05;
    let ay = p.vy / playerMod.MAX_VY * 0.16 + p.pitch * 0.12 + 0.03;
    return mathx.norm(f + rt * <f32>ax + up * <f32>ay);
}

function spawnBolt(W: Weapons, x: f64, y: f64, z: f64, dx: f64, dy: f64, dz: f64, base: f64): void {
    for (let i = 1; i < W.bolts.length; i++) {
        let b = W.bolts[i];
        if (!b.active) {
            b.active = true;
            b.volley = W.volley;
            b.x = x;
            b.y = y;
            b.z = z;
            let sp = BOLT_SPEED + base;
            b.vx = dx * sp;
            b.vy = dy * sp;
            b.vz = dz * sp;
            b.dx = dx;
            b.dy = dy;
            b.dz = dz;
            b.life = BOLT_LIFE;
            b.age = 0;
            return;
        }
    }
}

// the gun at `side` (-1 left), else the flight frame's
function gunAt(W: Weapons, p: Player, side: f64): Vector {
    let g = side < 0 ? W.gunL : W.gunR;
    if (g != null) return g.value;
    return p.pos + p.right * <f32>(0.62 * side) + p.up * <f32>0.15;
}

function volley(W: Weapons, p: Player, ctx: Ctx, F: Fx): void {
    let aim = W.aim;
    W.volley += 1;
    W.volleyHit[<i32>mod(W.volley, 64)] = false;
    // converge on a point 140 m down the aim line
    let cx = <f64>p.pos.x + <f64>aim.x * 140, cy = <f64>p.pos.y + <f64>aim.y * 140, cz = <f64>p.pos.z + <f64>aim.z * 140;
    let pv = p.fwd * <f32>p.speed + p.right * <f32>p.vx + p.up * <f32>p.vy;
    for (let side = -1.0; side <= 1; side += 2) {
        let o = gunAt(W, p, side);
        o = o + p.fwd * <f32>(0.6 + p.speed / 60); // hands were sampled last frame
        let dx = cx - <f64>o.x, dy = cy - <f64>o.y, dz = cz - <f64>o.z;
        let l = Math.sqrt(dx * dx + dy * dy + dz * dz);
        spawnBolt(W, o.x, o.y, o.z, dx / l, dy / l, dz / l, p.speed);
        // muzzle flash (star + streak), carried along with the pilot
        let n0 = F.parts.length - 1;
        fx.muzzle(F, o.x, o.y, o.z, dx / l, dy / l, dz / l, 0.55, GR, GG, GB);
        for (let i = n0 + 1; i < F.parts.length; i++) {
            let q = F.parts[i];
            q.vx += pv.x;
            q.vy += pv.y;
            q.vz += pv.z;
            q.drag = 0;
        }
    }
    ctx.stats.shotsFired += 1;
    W.muzzle = 1;
    W.firedVolley = true;
    playerMod.addHeat(p, BOLT_HEAT);
    ctx.sfx("laser", 0.45);
}

// (Luau's launch closure; returns whether a nova went)
function launch(W: Weapons, p: Player, aim: Vector, launched: i32, target: Enemy?, spread: f64): bool {
    for (let i = 1; i < W.novas.length; i++) {
        let n = W.novas[i];
        if (!n.active) {
            n.active = true;
            let g = launched % 2 == 0 ? W.gunR : W.gunL;
            let o = (g != null ? g.value : p.pos + p.up * <f32>0.3) + p.fwd * <f32>(1.2 + p.speed / 60);
            n.x = o.x;
            n.y = o.y;
            n.z = o.z;
            // fan out a little so multiple novas curve in separately
            let side = p.right * <f32>(spread * 0.35) + p.up * <f32>(Math.abs(spread) * 0.12);
            let v = mathx.norm(aim + side) * <f32>(NOVA_SPEED * 0.75 + p.speed);
            n.vx = v.x;
            n.vy = v.y;
            n.vz = v.z;
            n.life = target != null ? 2.6 : 1.25;
            n.age = 0;
            n.target = target;
            n.homing = target != null;
            for (let k = 1; k <= 8; k++) {
                n.tx[k] = o.x;
                n.ty[k] = o.y;
                n.tz[k] = o.z;
            }
            n.ti = 1;
            return true;
        }
    }
    return false;
}

function fireNovas(W: Weapons, p: Player, ctx: Ctx): void {
    let aim = W.aim;
    let launched = 0;
    let count = 0.0;
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        if (l.e != null && l.locked) {
            count += 1;
        }
    }
    if (count == 0) {
        if (launch(W, p, aim, launched, null, 0)) launched += 1;
    } else {
        let k = 0.0;
        for (let i = 1; i < W.locks.length; i++) {
            let l = W.locks[i];
            let e = l.e;
            if (e != null && l.locked) {
                if (launch(W, p, aim, launched, e, (k - (count - 1) / 2) * 1.0)) launched += 1;
                k += 1;
            }
        }
    }
    if (launched > 0) {
        ctx.stats.shotsFired += launched;
        W.firedNova = true;
        W.muzzle = 1.4;
        playerMod.addHeat(p, NOVA_HEAT);
        ctx.sfx("nova", 0.8);
        let o = p.pos + p.fwd * <f32>1.5;
        flare(W, o.x, o.y, o.z, 0.6, 4.5, 0.22, GR, GG, GB, 2);
        ctx.shake(0.35);
    }
    // release the brackets (they fade out while the shots fly)
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        l.locked = false;
        l.progress = 0;
    }
}

// Candidate lock target: alive, lockable, not already held, inside the cone.
function findTarget(W: Weapons, p: Player, E: World): Enemy? {
    let best: Enemy? = null;
    let bestScore = -1.0;
    let aim = W.aim;
    let px = <f64>p.pos.x, py = <f64>p.pos.y, pz = <f64>p.pos.z;
    for (let j = 1; j < E.list.length; j++) {
        let e = E.list[j];
        if (e.alive && e.lockable && !e.hidden && e.dying <= 0) {
            let held = false;
            for (let i = 1; i < W.locks.length; i++) {
                if (W.locks[i].e == e) {
                    held = true;
                    break;
                }
            }
            if (!held) {
                let dx = e.x - px, dy = e.y - py, dz = e.z - pz;
                let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
                if (d > 12 && d < LOCK_RANGE) {
                    let c = (dx * <f64>aim.x + dy * <f64>aim.y + dz * <f64>aim.z) / d;
                    if (c > LOCK_CONE) {
                        let score = c - d / LOCK_RANGE * 0.05;
                        if (score > bestScore) {
                            best = e;
                            bestScore = score;
                        }
                    }
                }
            }
        }
    }
    return best;
}

function splash(W: Weapons, E: World, ctx: Ctx, x: f64, y: f64, z: f64, radius: f64, dmg: f64): void {
    for (let i = 1; i < E.list.length; i++) {
        let e = E.list[i];
        if (e.alive) {
            let dx = e.x - x, dy = e.y - y, dz = e.z - z;
            let rr = radius + e.radius;
            if (dx * dx + dy * dy + dz * dz < rr * rr) {
                enemies.damage(E, ctx, e, dmg);
            }
        }
    }
}

function novaBurst(W: Weapons, F: Fx, ctx: Ctx, x: f64, y: f64, z: f64): void {
    flare(W, x, y, z, 1.5, 24, 0.4, GR, GG, GB, 2);
    flare(W, x, y, z, 2.6, 7, 0.25, CR, CG, CB, 1);
    fx.sparks(F, x, y, z, 16, GR, GG, GB);
    ctx.shake(0.4);
}

// controls: fire held state this frame. Returns nothing; read the event flags.
export function update(W: Weapons, p: Player, fireDown: bool, dt: f64, ctx: Ctx, E: World?, F: Fx): void {
    W.firedVolley = false;
    W.firedNova = false;
    W.newLock = false;
    W.aim = aimDir(p);
    W.fireT = lmax(0, W.fireT - dt);
    W.muzzle = lmax(0, W.muzzle - dt * 9);
    let canFire = p.overheat <= 0 && p.alive && p.controls;
    let down = fireDown && canFire;
    let pressed = down && !W.wasDown;

    if (pressed && W.fireT <= 0) {
        volley(W, p, ctx, F);
        W.fireT = FIRE_GAP;
    }
    if (down) {
        W.holdT += dt;
        if (W.holdT > HOLD_TO_CHARGE) {
            W.charging = true;
            W.charge = lmin(1, W.charge + dt / CHARGE_TIME);
        }
    } else {
        if (W.charging && W.wasDown) {
            // released: launch
            if (W.charge >= 0.3 || W.lockCount > 0) {
                fireNovas(W, p, ctx);
            } else if (canFire && W.fireT <= 0) {
                volley(W, p, ctx, F);
                W.fireT = FIRE_GAP;
            }
        }
        W.charging = false;
        W.holdT = 0;
        W.charge = lmax(0, W.charge - dt * 4);
    }
    if (!canFire) {
        W.charging = false;
        W.holdT = 0;
    }
    W.wasDown = down;

    // lock acquisition while charged
    let count = 0.0;
    let px = <f64>p.pos.x, py = <f64>p.pos.y, pz = <f64>p.pos.z;
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        let e = l.e;
        if (e != null) {
            let dx = e.x - px, dy = e.y - py, dz = e.z - pz;
            let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
            let ahead = (dx * <f64>p.fwd.x + dy * <f64>p.fwd.y + dz * <f64>p.fwd.z) > 5;
            if (!e.alive || e.dying > 0 || !ahead || d > LOCK_RANGE * 1.25) {
                l.e = null;
                l.locked = false;
            } else {
                l.x = e.x;
                l.y = e.y;
                l.z = e.z;
                l.dist = d;
                if (W.charging) {
                    l.progress = lmin(1, l.progress + dt / 0.22);
                    l.fade = lmin(1, l.fade + dt * 8);
                    if (l.progress >= 1 && !l.locked) {
                        l.locked = true;
                        W.newLock = true;
                        ctx.sfx("lock", 0.7);
                        let n = 0.0;
                        for (let k = 1; k < W.locks.length; k++) {
                            if (W.locks[k].locked) {
                                n += 1;
                            }
                        }
                        if (n == MAX_LOCKS) {
                            ctx.sfx("lock_full", 0.8);
                        }
                    }
                    if (l.locked) {
                        count += 1;
                    }
                } else {
                    // after release the bracket rides its nova's target briefly
                    l.fade = lmax(0, l.fade - dt * 3);
                    if (l.fade <= 0) {
                        l.e = null;
                    }
                }
            }
        } else {
            l.fade = lmax(0, l.fade - dt * 5);
        }
    }
    W.lockCount = count;
    if (W.charging && W.charge > 0.25 && E != null) {
        W.lockT -= dt;
        if (W.lockT <= 0) {
            let slot: Lock? = null;
            for (let i = 1; i < W.locks.length; i++) {
                let l = W.locks[i];
                if (l.e == null) {
                    slot = l;
                    break;
                }
            }
            if (slot != null) {
                let e = findTarget(W, p, E);
                if (e != null) {
                    slot.e = e;
                    slot.progress = 0;
                    slot.locked = false;
                    slot.fade = 0;
                    slot.x = e.x;
                    slot.y = e.y;
                    slot.z = e.z;
                    W.lockT = 0.14;
                }
            }
        }
    } else {
        W.lockT = 0;
    }

    // hot: an enemy sits under the reticle line
    let hot = false;
    if (E != null) {
        let aim = W.aim;
        let ax = <f64>aim.x, ay = <f64>aim.y, az = <f64>aim.z;
        for (let i = 1; i < E.list.length; i++) {
            let e = E.list[i];
            if (e.alive && !e.hidden && e.dying <= 0) {
                let dx = e.x - px, dy = e.y - py, dz = e.z - pz;
                let along = dx * ax + dy * ay + dz * az;
                if (along > 8 && along < 480) {
                    let px2 = dx - ax * along;
                    let py2 = dy - ay * along;
                    let pz2 = dz - az * along;
                    let off2 = px2 * px2 + py2 * py2 + pz2 * pz2;
                    let rr = e.radius + 1.5 + along * 0.02;
                    if (off2 < rr * rr) {
                        hot = true;
                        break;
                    }
                }
            }
        }
    }
    W.hot = hot;
    W.hotAmt = mathx.damp(W.hotAmt, hot ? 1 : 0, 12, dt);

    // bolts
    for (let i = 1; i < W.bolts.length; i++) {
        let b = W.bolts[i];
        if (b.active) {
            b.age += dt;
            let nx = b.x + b.vx * dt, ny = b.y + b.vy * dt, nz = b.z + b.vz * dt;
            let hit = false;
            if (E != null) {
                let e = enemies.raycast(E, b.x, b.y, b.z, nx, ny, nz, 0.45);
                if (e != null) {
                    hit = true;
                    let vk = <i32>mod(b.volley, 64);
                    if (!W.volleyHit[vk]) {
                        W.volleyHit[vk] = true;
                        ctx.stats.shotsHit += 1;
                    }
                    fx.sparks(F, nx, ny, nz, 7, CR, CG, CB);
                    flare(W, nx, ny, nz, 0.6, 7, 0.16, GR, GG, GB, 1);
                    enemies.damage(E, ctx, e, 1);
                }
            }
            if (!hit && ny < 0 && b.y >= 0) {
                // plink into the sea
                let k = b.y / lmax(1e-4, b.y - ny);
                let wx = b.x + (nx - b.x) * k, wz = b.z + (nz - b.z) * k;
                fx.spray(F, wx, 0, wz, 1);
                fx.spray(F, wx, 0, wz, 1);
                flare(W, wx, 0.05, wz, 0.4, 3, 0.35, 0.95, 1, 1, 2);
                hit = true;
            }
            b.x = nx;
            b.y = ny;
            b.z = nz;
            b.life -= dt;
            if (hit || b.life <= 0) {
                b.active = false;
            }
        }
    }

    // novas
    for (let i = 1; i < W.novas.length; i++) {
        let n = W.novas[i];
        if (n.active) {
            n.age += dt;
            let tgt = n.target;
            if (tgt != null && !tgt.alive) {
                n.target = null;
                tgt = null;
            }
            if (tgt != null) {
                let dx = tgt.x - n.x, dy = tgt.y - n.y, dz = tgt.z - n.z;
                let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
                let sp = NOVA_SPEED + p.speed + n.age * 60;
                let turn = 1 - Math.exp(-(4 + n.age * 10) * dt);
                n.vx += (dx / d * sp - n.vx) * turn;
                n.vy += (dy / d * sp - n.vy) * turn;
                n.vz += (dz / d * sp - n.vz) * turn;
            }
            let nx = n.x + n.vx * dt, ny = n.y + n.vy * dt, nz = n.z + n.vz * dt;
            let boom = false;
            if (E != null) {
                let e = enemies.raycast(E, n.x, n.y, n.z, nx, ny, nz, 1.2);
                if (e != null) {
                    boom = true;
                    ctx.stats.shotsHit += 1;
                    enemies.damage(E, ctx, e, 6);
                }
            }
            n.x = nx;
            n.y = ny;
            n.z = nz;
            n.ti = (n.ti % 8) + 1;
            n.tx[n.ti] = nx;
            n.ty[n.ti] = ny;
            n.tz[n.ti] = nz;
            n.life -= dt;
            if (boom || n.life <= 0 || ny < 0.2) {
                n.active = false;
                if (E != null) {
                    splash(W, E, ctx, nx, ny, nz, n.homing ? 6 : 14, 3);
                }
                novaBurst(W, F, ctx, nx, lmax(0.3, ny), nz);
                ctx.sfx("explode_small", 0.7);
            }
        }
    }

    // flares
    for (let i = 1; i < W.flares.length; i++) {
        let f = W.flares[i];
        if (f.active) {
            f.age += dt;
            f.size += f.grow * dt;
            if (f.age >= f.life) {
                f.active = false;
            }
        }
    }
}

// Reticle view model + lock-on brackets.
export function sync(W: Weapons, rb: Bag?): void {
    if (rb != null) {
        vmx.num(rb, "charge", Math.floor(W.charge * 100 + 0.5) / 100);
        vmx.num(rb, "lock", W.lockCount / MAX_LOCKS);
        vmx.bool(rb, "hot", W.hot);
    }
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        let b = l.bag;
        if (b != null && (l.e != null || l.fade > 0)) {
            vmx.num(b, "progress", Math.floor(l.progress * 50 + 0.5) / 50);
            vmx.bool(b, "locked", l.locked);
        }
    }
}

export function advanceArt(W: Weapons, dt: f64): void {
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        let a = l.art;
        if (a != null && (l.e != null || l.fade > 0)) {
            a.advance(dt);
        }
    }
}

// Twin reticles along the aim line: near / far points and their sizes as a
// fraction of the view height (near ~15%, far ~10%; game draws them).
export const SIGHT_NEAR: f64 = 30;
export const SIGHT_FAR: f64 = 64;
let RAW_N: Vector = Vector.xyz(0, 0, 0);
let RAW_F: Vector = Vector.xyz(0, 0, 0);
let RAW_KN: f64 = 0;
let RAW_KF: f64 = 0;
function sightsRaw(W: Weapons, p: Player): void {
    let hot = W.hotAmt;
    RAW_N = p.pos + W.aim * <f32>SIGHT_NEAR;
    RAW_F = p.pos + W.aim * <f32>SIGHT_FAR;
    RAW_KN = 0.15 * (1 + hot * 0.1);
    RAW_KF = 0.10 * (1 + W.charge * 0.18 + hot * 0.08);
}

export let SIGHTS_1: Vector = Vector.xyz(0, 0, 0);
export let SIGHTS_2: Vector = Vector.xyz(0, 0, 0);
export let SIGHTS_3: f64 = 0;
export let SIGHTS_4: f64 = 0;

// The same, kept off the hero (sightsUpdate's lift): near, far, their sizes
// -> SIGHTS_1 / _2 / _3 / _4; returns the near point.
export function sights(W: Weapons, p: Player): Vector {
    sightsRaw(W, p);
    SIGHTS_1 = RAW_N + W.liftN;
    SIGHTS_2 = RAW_F + W.liftF;
    SIGHTS_3 = RAW_KN;
    SIGHTS_4 = RAW_KF;
    return SIGHTS_1;
}

// Sights off the hero (DIRECTION #16, QA M5): a low eye (fights, portrait)
// puts the aim line's vanishing point on his helmet, and the twin reticles
// (amber when hot) sat on it. The pair lifts up the screen until the far
// reticle (all of it: ring and ticks) clears his painted figure (at most
// SIGHT_LIFT of the view height, ~1-2 deg: inside the hot cone;
// SIGHT_LIFT_TALL in portrait), and the near one ghosts out where it would
// still cover him. Lock brackets stay on their target and only dim over him
// (to 55%).
const HERO_HALF: f64 = 1.25; // the painted figure: helmet top, fist to fist (m)
const BRACKET: f64 = 0.275; // Reticle bracket box (+ stroke), of its sprite size
const OUTER: f64 = 0.475; // Reticle tick notches (radius 121 of 256, + stroke): its drawn extent
const LOCK_BOX: f64 = 0.25; // LockOn bracket box
const SIGHT_GAP: f64 = 0.006;
const SIGHT_LIFT: f64 = 0.035;
const SIGHT_LIFT_TALL: f64 = 0.045;
const SIGHT_TOP: f64 = 0.30; // a lift stops here: the phone comms plate docks above the reticle (to ~0.29)

// share of a box (half extents hu, hv) inside the hero's box, ramped over
// the first `ramp` of its half extent so an edge graze does not toggle
function overHero(u: f64, v: f64, hu: f64, hv: f64, cu: f64, top: f64, bot: f64, hw: f64, ramp: f64): f64 {
    let ou = lmin(u + hu, cu + hw) - lmax(u - hu, cu - hw);
    let ov = lmin(v + hv, bot) - lmax(v - hv, top);
    if (ou <= 0 || ov <= 0) {
        return 0;
    }
    return mathx.saturate(ou / (hu * ramp)) * mathx.saturate(ov / (hv * ramp));
}

// how far (view heights) a ring at (u, v), radius r + SIGHT_GAP, dips below the
// top of the hero's box (half width m); -1 when it misses the box
function ringReach(u: f64, v: f64, r: f64, cu: f64, top: f64, bot: f64, m: f64, aspect: f64): f64 {
    let rr = r + SIGHT_GAP;
    let dx = lmax(0, Math.abs(u - cu) * aspect - m);
    if (dx >= rr || v - rr >= bot) {
        return -1;
    }
    return v + Math.sqrt(rr * rr - dx * dx) - top;
}

// (sightsUpdate's screen closure: -> SC_U / SC_V / SC_Z)
let SC_U: f64 = 0;
let SC_V: f64 = 0;
let SC_Z: f64 = 0;
function screen(P: Vector, eye: Vector, fw: Vector, rt: Vector, up: Vector, th: f64, aspect: f64): void {
    let d = P - eye;
    let z = lmax(mathx.dot(d, fw), 0.5);
    SC_U = mathx.dot(d, rt) / (z * th * aspect) * 0.5 + 0.5;
    SC_V = 0.5 - mathx.dot(d, up) / (z * th) * 0.5;
    SC_Z = z;
}

// Once a frame after the camera: eye, its forward / right / up, tan(fovY / 2).
export function sightsUpdate(W: Weapons, p: Player, eye: Vector, fw: Vector, rt: Vector, up: Vector, th: f64, aspect: f64, dt: f64): void {
    screen(p.pos, eye, fw, rt, up, th, aspect);
    let cu = SC_U, cv = SC_V, cz = SC_Z;
    let m = HERO_HALF / (cz * 2 * th);
    let top = cv - m, bot = cv + m, hw = m / aspect;
    sightsRaw(W, p);
    let near = RAW_N, far = RAW_F, kn = RAW_KN, kf = RAW_KF;
    screen(far, eye, fw, rt, up, th, aspect);
    let fu = SC_U, fv = SC_V, fz = SC_Z;
    screen(near, eye, fw, rt, up, th, aspect);
    let nu = SC_U, nv = SC_V, nz = SC_Z;
    let fs = kf * mathx.dist(far, eye) / fz;
    let ns = kn * mathx.dist(near, eye) / nz;
    let want = 0.0, k = 0.0;
    if (mathx.dot(p.pos - eye, fw) > 0.5) {
        want = mathx.clamp(ringReach(fu, fv, fs * OUTER, cu, top, bot, m, aspect), 0, aspect < 1 ? SIGHT_LIFT_TALL : SIGHT_LIFT);
        want = lmin(want, lmax(0, fv - fs * BRACKET - SIGHT_TOP));
        // the near reticle still on him after the lift (fully gone 0.012 in)
        k = mathx.saturate(ringReach(nu, nv - want, ns * OUTER, cu, top, bot, m, aspect) / 0.018);
    }
    W.sightLift = mathx.damp(W.sightLift, want, 10, dt);
    W.nearOp = mathx.damp(W.nearOp, 1 - k, 10, dt);
    W.liftF = up * <f32>(W.sightLift * fz * 2 * th);
    W.liftN = up * <f32>(W.sightLift * nz * 2 * th);
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        let o = 0.0;
        if ((l.e != null || l.fade > 0) && mathx.dot(Vector.xyz(<f32>l.x, <f32>l.y, <f32>l.z) - eye, fw) > 0.5) {
            screen(Vector.xyz(<f32>l.x, <f32>l.y, <f32>l.z), eye, fw, rt, up, th, aspect);
            let lu = SC_U, lv = SC_V, lz = SC_Z;
            let h = lmax(4, (l.dist + 11) * 2 * th * 0.11) / (lz * 2 * th) * LOCK_BOX;
            o = overHero(lu, lv, h / aspect, h, cu, top, bot, hw, 1);
        }
        l.over = mathx.damp(l.over, o, 10, dt);
    }
}

// viewK: 2 * tan(fovY / 2) of the camera (sizes the lock brackets on screen); NaN: 1.15.
export function draw(W: Weapons, r: R.Gfx, p: Player, t: f64, viewK: f64 = NaN): void {
    // bolts: perspective-correct laser ribbons (white-hot core, lime flame)
    // with a glowing head; ribbons and particles reflect in the sea too
    for (let i = 1; i < W.bolts.length; i++) {
        let b = W.bolts[i];
        if (b.active) {
            // a 20+ m streak: wide saturated lime halo (the exhaust shader at
            // mid age: thin core, colored flame) around a thin white-hot line
            let len = lmin(22, 3 + b.age * 140);
            let tx = b.x - b.dx * len, ty = b.y - b.dy * len, tz = b.z - b.dz * len;
            R.ribbon(r, b.x, b.y, b.z, 1.3, 1, tx, ty, tz, 0.5, 0.85, HR, HG, HB, 1.7, 1, 0.45, 0.62);
            R.ribbon(r, b.x, b.y, b.z, 0.3, 1, tx, ty, tz, 0.1, 0.6, CR, CG, CB, 0.8, 1, 0.1, 0.5);
            R.particle(r, b.x, b.y, b.z, 1.4, HR, HG, HB, 0.75, 1, 0, 0, 0);
        }
    }
    // muzzle glow + charge energy gathering at both wrist blasters
    let pulse = 0.85 + 0.15 * Math.sin(t * 30);
    let ring = mod(t * 3, 1);
    for (let side = -1.0; side <= 1; side += 2) {
        let o = gunAt(W, p, side);
        // a hair toward the camera: the hero sprite writes depth where opaque
        o = o - p.fwd * <f32>0.3;
        if (W.muzzle > 0) {
            R.particle(r, o.x, o.y, o.z, 0.9 * W.muzzle, GR, GG, GB, lmin(1, W.muzzle), 1, 0, 0, 0);
        }
        if (W.charge > 0.02) {
            R.particle(r, o.x, o.y, o.z, (0.3 + W.charge * 0.9) * pulse, GR, GG, GB, 0.5 + W.charge * 0.5, 1, 0, 0, 0);
            R.particle(r, o.x, o.y, o.z, 0.18 + W.charge * 0.25, CR, CG, CB, 1, 3, 0, 0, 0);
            if (W.charge >= 1) {
                R.particle(r, o.x, o.y, o.z, 0.8 + ring * 1.2, GR, GG, GB, 1 - ring, 2, 0, 0, 0);
            }
        }
    }
    // novas: orb + ring + fading trail
    let nb = W.novaBatch;
    if (nb != null) {
        gpu.reset(nb);
    }
    for (let i = 1; i < W.novas.length; i++) {
        let n = W.novas[i];
        if (n.active) {
            if (nb != null) {
                let s = 0.62 + Math.sin(n.age * 50) * 0.08;
                gpu.addYPR(nb, n.x, n.y, n.z, n.age * 7, n.age * 5, 0, s, 1, 1, 1, 0, 0.5);
            }
            R.particle(r, n.x, n.y, n.z, 2.2, GR, GG, GB, 0.9, 1, 0, 0, 0);
            R.particle(r, n.x, n.y, n.z, 1.1 + Math.sin(n.age * 40) * 0.2, GR, GG, GB, 0.8, 2, 0, 0, n.age * 6);
            let steps = <i32>lmin(7, Math.floor(n.age * 60));
            let i0 = n.ti;
            for (let k = 1; k <= steps; k++) {
                let i1 = imod(i0 - 2, 8) + 1;
                let u0 = <f64>(k - 1) / 8, u1 = <f64>k / 8;
                R.ribbon(r, n.tx[i0], n.ty[i0], n.tz[i0], 1.1 * (1 - u0) + 0.2, 1, n.tx[i1], n.ty[i1], n.tz[i1], 1.1 * (1 - u1) + 0.2, 1, GR, GG, GB, 1, 3, u0, u1);
                i0 = i1;
            }
        }
    }
    if (nb != null) {
        R.addBatch(r, nb);
    }
    for (let i = 1; i < W.flares.length; i++) {
        let f = W.flares[i];
        if (f.active) {
            let k = f.age / f.life;
            R.particle(r, f.x, f.y, f.z, f.size, f.r, f.g, f.b, (1 - k) * (1 - k), f.kind, k, 0, 0);
        }
    }
    // lock-on brackets over their targets at a steady screen size (~11% of
    // the view height; the camera sits ~11 m behind the pilot)
    let vk = isNaN(viewK) ? 1.15 : viewK;
    for (let i = 1; i < W.locks.length; i++) {
        let l = W.locks[i];
        let s = l.sprite;
        if (s != null && (l.e != null || l.fade > 0) && l.fade > 0.01) {
            let size = lmax(4, (l.dist + 11) * vk * 0.11);
            let spin = (1 - l.progress) * 1.6;
            R.spriteAdd(s, l.x, l.y, l.z, spin, size, size, 0.5, l.fade * (1 - 0.45 * l.over));
        }
    }
}
