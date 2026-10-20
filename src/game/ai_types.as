// Port of src/game/ai_types.luau. Shared enemy state, bullets and helpers for behaviors and bosses.
// Used by the behaviors (ai_patterns), the bosses (boss_*) and the enemies facade.
// OWNER: enemies & events agent.
//
// Port: lists are 1-based (slot 0 a hole); Enemy.path / Boss.pieces rows are
// 1-based f64 arrays. Optional numbers: NaN = nil. Boss.v (Luau {[string]:
// number}) is BossV: every key either boss uses, 0 = nil except phaseEta /
// crestV (NaN = nil). Multi-returns: aimAtPlayer -> AIM_AT_PLAYER_1..3,
// intercept -> INTERCEPT_1..3, screen -> SCREEN_1..3, camProject ->
// CAM_PROJECT_1..3, lens -> LENS_1 (bool), LENS_2..4, eye -> EYE_1..3.
// Ctx always has project / sting / holdSpeed (types.as): the Luau existence
// guards are gone (screen = ctx.project, sting always takes).
import { Vector } from "rive/vector";
import { Ctx } from "./types";
import * as fx from "./fx";
import { Fx } from "./fx";
import * as models from "./models";
import { Xf, Models } from "./models";
import * as R from "../render/renderer";
import { Trail, Gfx } from "../render/renderer";
import * as mathx from "../lib/mathx";
import * as camera from "./camera";
import * as playerMod from "./player";
import { HUGE, lmin, lmax, lclamp, lrandom } from "../lib/compat";

// Debug: print the mission timeline (cues, alerts, comms, boss phases) and a
// once-a-second telemetry line to the console. Keep false in shipped builds.
// (Port: the prints behind it are not ported.)
export const LOG: bool = false;

@inline function rad(d: f64): f64 {
    return d * (Math.PI / 180.0);
}

// A squadron: kills of every member pay a bonus. (defaults: enemies.group)
export class Group {
    alive: f64 = 0;
    total: f64 = 0;
    bonus: f64 = 0;
    name: string = "";
    escaped: f64 = 0;
    flyby: f64 = -1;
}

export class Enemy {
    kind: string = ""; // model: biplane | drone | kamikaze | trooper | mine | turret | part kinds
    ai: string = ""; // behavior key (ai_patterns) or 'part' for boss pieces
    x: f64 = 0; // world position
    y: f64 = -1000;
    z: f64 = 0;
    radius: f64 = 0;
    hp: f64 = 0;
    maxHp: f64 = 0;
    alive: bool = true;
    lockable: bool = true;
    armored: bool = false; // shots ricochet (boss armor)
    part: bool = false; // boss piece: no kill credit, no body collision
    score: f64 = 0;
    t: f64 = 0; // age in seconds (negative = not launched yet)
    // rail placement: s is relative to the player when rel, else absolute
    rel: bool = true;
    s: f64 = 0;
    rx: f64 = 0;
    ry: f64 = 0;
    // motion (rail-relative velocity / acceleration estimates) and pose
    ps: f64 = 0;
    px: f64 = 0;
    py: f64 = 0;
    vs: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    as: f64 = 0;
    ax: f64 = 0;
    ay: f64 = 0;
    hx: f64 = 0; // smoothed world heading
    hy: f64 = 0;
    hz: f64 = -1;
    upx: f64 = 0; // smoothed world up
    upy: f64 = 1;
    upz: f64 = 0;
    xf: Xf = models.xf();
    scale: f64 = 1;
    yaw: f64 = 0;
    pitch: f64 = 0;
    roll: f64 = 0;
    // behavior params; path keys {t, s, x, y} (1-based rows, 1-based list)
    path: Array<Array<f64>>? = null;
    p1: f64 = 0;
    p2: f64 = 0;
    p3: f64 = 0;
    p4: f64 = 0;
    side: f64 = 1;
    fireT: f64 = 1;
    burst: f64 = 0;
    flash: f64 = 0;
    spin: f64 = 0;
    seed: f64 = 0;
    group: Group? = null;
    dying: f64 = 0; // > 0: falling wreck, seconds left
    dead: bool = false; // remove on the next update
    warp: f64 = 0; // dissolve 1 -> 0 while warping in
    char: f64 = 0; // 0 clean .. 1 charred
    smokeT: f64 = 0;
    hidden: bool = false;
    world: bool = false; // position integrated in world space (kamikaze, wrecks)
    wvx: f64 = 0; // world velocity estimate
    wvy: f64 = 0;
    wvz: f64 = 0;
    lx: f64 = 0; // last world position
    ly: f64 = 0;
    lz: f64 = 0;
    dodgeT: f64 = 0;
    rollT: f64 = 0;
    trail: f64 = 0; // trail slot (0 = none), see trailGet
    trail2: f64 = 0;
    passed: bool = false; // flew past the camera (flyby cue done)
    minHp: f64 = 0; // damage can't take hp below this (boss pacing floor; 0 = off)
    tele: f64 = 0; // attack telegraph 0..1 (drawn as a charge glow before a shot)
    sx: f64 = 1; // path lateral scale (a squadron squeezed into the canyon slot)
    shots: f64 = 0; // volleys fired (alternates aimed shots and leading fans)
    lift: f64 = 0; // extra height (m) over the rail plan to clear a rock (ai_patterns hop)
    chain: f64 = 0; // falling wreck: seconds until a chained blast finishes it (0 = none; SQUADRON DOWN)
    duck: bool = false; // path drone ducking into the sea to clear a boss entrance (ai_patterns.retire)
    // flight school (enemies.practice): no score, no kill count, pops with confetti
    practice: bool = false;
    bob: f64 = 0; // practice: vertical bob (m)
    lobEvery: f64 = 0; // practice lobber: seconds between orbs (0 = no gun)
    lobSpeed: f64 = 0; // practice lobber: orb speed (m/s)
    // port: enemies' SEEN set (Luau keys a table by the enemy) as a flag
    seen: bool = false;
}

export class Bullet {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    life: f64 = 0;
    kind: f64 = 0; // 0 tracer, 1 orb, 2 flak shell, 3 rocket
    dmg: f64 = 0;
    deflected: bool = false;
    size: f64 = 0;
    r: f64 = 0;
    g: f64 = 0;
    b: f64 = 0;
    fuse: f64 = 0; // flak: seconds to burst; rocket: homing strength
    age: f64 = 0;
    trail: f64 = 0;
    practice: bool = false; // flight school orb: a hit is ctx.practiceHit, never shield
    src: Enemy? = null; // practice: the lobber a deflected orb homes back on
}

// Pooled ribbon trail (smoke, exhaust, vapor) owned by an enemy or a bullet.
export class TrailSlot {
    tr: Trail;
    used: bool = false;
    lastT: f64 = -100;
    gap: bool = false;
    constructor(tr: Trail) {
        this.tr = tr;
    }
}

// Boss.v: per-boss numbers (Luau {[string]: number}), every key either boss
// uses. 0 stands for nil (Luau reads them `or 0`) except phaseEta and crestV
// (NaN = nil). Each boss's spawn sets its own starting values.
export class BossV {
    // both
    fireT: f64 = 0;
    droneT: f64 = 0;
    deathT: f64 = 0;
    boomT: f64 = 0;
    deathRate: f64 = 0;
    stung: f64 = 0;
    barT: f64 = 0;
    callout: f64 = 0;
    // the eye
    open: f64 = 0;
    ringA: f64 = 0;
    ringB: f64 = 0;
    lensIdx: f64 = 0;
    beamT: f64 = 0;
    beamState: f64 = 0;
    bdx: f64 = 0;
    bdy: f64 = 0;
    bdz: f64 = 0;
    spiralT: f64 = 0;
    rage: f64 = 0;
    volleyT: f64 = 0;
    stillT: f64 = 0;
    iris: f64 = 0;
    irisT: f64 = 0;
    beamN: f64 = 0;
    breach: f64 = 0;
    beamY: f64 = 0;
    beamSgn: f64 = 0;
    beamDur: f64 = 0;
    beamDone: f64 = 0;
    stareT: f64 = 0;
    beamRolled: f64 = 0;
    cracked: f64 = 0;
    onT: f64 = 0;
    inView: f64 = 0;
    leaving: f64 = 0;
    stripRoll: f64 = 0;
    // the stormcrow
    flakT: f64 = 0;
    sternT: f64 = 0;
    rocketT: f64 = 0;
    side: f64 = 0;
    burst: f64 = 0;
    burstT: f64 = 0;
    sAbs: f64 = 0;
    focusY: f64 = 0;
    etaT: f64 = 0;
    phaseEta: f64 = NaN; // NaN = nil (the eye has none)
    storm: f64 = 0;
    upT: f64 = 0;
    sp1: f64 = 0;
    sp2: f64 = 0;
    sp3: f64 = 0;
    sp4: f64 = 0;
    roar: f64 = 0;
    bolt: f64 = 0;
    portUp: f64 = 0;
    hvx: f64 = 0;
    hvy: f64 = 0;
    hvz: f64 = 0;
    sdx: f64 = 0;
    sds: f64 = 0;
    lift: f64 = 0;
    hx: f64 = 0;
    hy: f64 = 0;
    hz: f64 = 0;
    hSet: f64 = 0;
    crestV: f64 = NaN; // NaN = nil
    col: f64 = 0;
    brk: f64 = 0;
}

// Boss state shared by both bosses (per-boss numbers live in `v`).
export class Boss {
    kind: string = ""; // 'stormcrow' | 'eye'
    name: string = "";
    phase: f64 = 0;
    t: f64 = 0;
    phaseT: f64 = 0;
    s: f64 = 0; // rail distance ahead of the player
    x: f64 = 0;
    y: f64 = 0;
    xf: Xf = models.xf();
    parts: Array<Enemy> = new Array<Enemy>(1); // 1-based
    hpTotal: f64 = 0;
    v: BossV = new BossV();
    killed: bool = false;
    escaped: bool = false;
    done: bool = false;
    sEnd: f64 = 0; // absolute s where it gives up (escapes)
    pieces: Array<Array<f64>> = [[0.0]]; // free-flying bits (blown armor): x,y,z,vx,vy,vz,a,spin,life (1-based rows)
    yaw: f64 = 0;
    pitch: f64 = 0;
    roll: f64 = 0;
}

// A boss's comms line, handed to the core's channel by the mission script.
// mood: the portrait expression ('neutral' | 'happy' | 'worried' | 'shout' | 'angry').
// boss / phase: the fight and phase it was said in (phase -1: a kill or
// escape reaction, tied to no phase); the script drops it once that phase
// is over.
export class Comm {
    who: string = "";
    speaker: string = "";
    text: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    mood: string = "neutral";
    boss: string = "";
    phase: f64 = -1;
}

// A centre-of-visor alert (banner or warning) the mission script plays when
// the HUD's single alert slot is free. kind 'banner' | 'warning'; style is the
// banner kind ('checkpoint' | 'warning' | 'info' | 'success'). A boss phase
// callout names its boss and phase (`phase` >= 0): it is dropped unshown once
// that boss is gone or past that phase.
export class Alert {
    kind: string = "";
    text: string = "";
    sub: string = "";
    style: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    boss: string = "";
    phase: f64 = -1;
}

// Mirror of the core's chase camera (camTick): rail distance and speed of
// the eye, its lateral and height offsets, the boss lift, our focus point
// and weight, the damped look point and fov, the eye, the screen aspect.
export class Cam {
    on: bool = false;
    s: f64 = 0;
    sv: f64 = 0;
    x: f64 = 0;
    y: f64 = 0;
    lift: f64 = 0;
    fw: f64 = 0;
    fx: f64 = 0;
    fy: f64 = 0;
    fz: f64 = 0;
    look: Vector = Vector.xyz(0, 0, 1);
    fov: f64 = rad(60);
    eye: Vector = Vector.xyz(0, 0, 0);
    aspect: f64 = 16.0 / 9.0;
}

// The enemies record (enemies.luau Enemies = World). Field defaults are
// enemies.new's; trails = newTrails() (40 lrandom draws, in the slot order),
// built after `models` as Luau's table constructor.
export class World {
    list: Array<Enemy> = new Array<Enemy>(1); // 1-based
    bullets: Array<Bullet> = new Array<Bullet>(1); // 1-based
    freeBullets: Array<Bullet> = new Array<Bullet>(1); // 1-based
    fx: Fx;
    models: Models? = null;
    boss: Boss? = null;
    xf: Xf = models.xf(); // scratch frames
    xf2: Xf = models.xf();
    xf3: Xf = models.xf();
    lastShots: f64 = 0;
    playerFiring: bool = false;
    playerVx: f64 = 0;
    playerVy: f64 = 0;
    playerVz: f64 = 0;
    killsQueued: f64 = 0;
    ctx: Ctx? = null;
    dt: f64 = 0;
    comms: Array<Comm> = new Array<Comm>(1); // 1-based
    alerts: Array<Alert> = new Array<Alert>(1); // 1-based
    far: f64 = 1; // boss stand-off multiplier (> 1 on narrow portrait screens, see enemies.draw)
    trails: Array<TrailSlot>; // 1-based
    time: f64 = 0; // game time (trail clock)
    // set-piece stings (DIRECTION #21): game seconds our alerts still hold
    // after a sting we fired
    stingT: f64 = 0;
    // live boss framing for the core's reveal / kill cam (enemies.focus)
    focusOn: bool = false;
    focusX: f64 = 0;
    focusY: f64 = 0;
    focusZ: f64 = 0;
    focusR: f64 = 0;
    cam: Cam = newCam(); // chase-camera mirror (screen guards without ctx.project)
    constructor(effects: Fx, mo: Models?) {
        this.fx = effects;
        this.models = mo;
        this.trails = newTrails();
    }
}

export function enemy(kind: string, ai: string, hp: f64, radius: f64, score: f64): Enemy {
    let e = new Enemy();
    e.kind = kind;
    e.ai = ai;
    e.radius = radius;
    e.hp = hp;
    e.maxHp = hp;
    e.score = score;
    e.seed = lrandom();
    return e;
}

// Spawns a bullet from (x,y,z) with world velocity (vx,vy,vz); null when
// the pool is full (220).
export function bullet(W: World, kind: f64, x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, dmg: f64, life: f64, size: f64, r: f64, g: f64, b: f64, fuse: f64): Bullet? {
    if (W.bullets.length - 1 >= 220) {
        return null;
    }
    let n = W.freeBullets.length - 1;
    let bl: Bullet;
    if (n > 0) {
        bl = W.freeBullets[n];
        W.freeBullets.length = n;
    } else {
        bl = new Bullet();
    }
    bl.x = x;
    bl.y = y;
    bl.z = z;
    bl.vx = vx;
    bl.vy = vy;
    bl.vz = vz;
    bl.kind = kind;
    bl.dmg = dmg;
    bl.life = life;
    bl.size = size;
    bl.r = r;
    bl.g = g;
    bl.b = b;
    bl.fuse = fuse;
    bl.deflected = false;
    bl.age = 0;
    bl.trail = 0;
    bl.practice = false;
    bl.src = null;
    W.bullets.push(bl);
    return bl;
}

// Trails -------------------------------------------------------------------------

export const TRAIL_SLOTS: f64 = 40;

export function newTrails(): Array<TrailSlot> {
    let t = new Array<TrailSlot>(1);
    for (let i = 1; i <= <i32>TRAIL_SLOTS; i++) {
        t.push(new TrailSlot(R.newTrail(40, 2, 1, 1, 1, 1, 1, 1, 1.5)));
    }
    return t;
}

// Claims a free trail slot (0 when the pool is exhausted).
// kind: 0 vapor, 1 exhaust (additive), 2 toon smoke, 3 energy.
export function trailGet(W: World, kind: f64, life: f64, width: f64, r: f64, g: f64, b: f64, a: f64, minDist: f64): f64 {
    let now = W.time;
    let ts = W.trails;
    for (let i = 1; i < ts.length; i++) {
        let sl = ts[i];
        if (!sl.used && now - sl.lastT > sl.tr.life + 0.05) {
            let tr = sl.tr;
            R.trailClear(tr);
            tr.kind = kind;
            tr.life = life;
            tr.width = width;
            tr.minDist = minDist;
            tr.cr = r;
            tr.cg = g;
            tr.cb = b;
            tr.ca = a;
            sl.used = true;
            sl.lastT = now;
            sl.gap = false;
            return <f64>i;
        }
    }
    return 0;
}

// Points near the lens are skipped (a ribbon passing the camera would fill
// the screen); feeding restarts with a fresh ribbon once clear again.
// width: NaN = nil.
export function trailPush(W: World, i: f64, x: f64, y: f64, z: f64, width: f64 = NaN): void {
    if (i <= 0) {
        return;
    }
    let sl = W.trails[<i32>i];
    let F = W.fx;
    let dx = x - F.camX, dy = y - F.camY, dz = z - F.camZ;
    sl.lastT = W.time;
    if (dx * dx + dy * dy + dz * dz < 16 * 16) {
        sl.gap = true;
        return;
    }
    if (sl.gap) {
        sl.gap = false;
        R.trailClear(sl.tr);
    }
    R.trailPush(sl.tr, x, y, z, W.time, width);
}

// Stops feeding a trail; it keeps drawing until its points expire.
export function trailRelease(W: World, i: f64): void {
    if (i > 0) {
        W.trails[<i32>i].used = false;
    }
}

// An ink-smoke ribbon (kind 2: a falling wreck's column, a kamikaze's
// plume) stays in the world while the pilot flies on into it: it thins out
// as its nearest live point comes within SMOKE_NEAR1 m of the lens (gone
// by SMOKE_NEAR0), so it never stands as a cobalt column across the view.
const SMOKE_NEAR0: f64 = 14, SMOKE_NEAR1: f64 = 46;

export function trailsDraw(W: World, r: Gfx): void {
    let now = W.time;
    let F = W.fx;
    let ex = F.camX, ey = F.camY, ez = F.camZ;
    let ts0 = W.trails;
    for (let i = 1; i < ts0.length; i++) {
        let sl = ts0[i];
        let tr = sl.tr;
        if (sl.used || now - sl.lastT < tr.life) {
            let al = 1.0;
            if (tr.kind == 2) {
                let best = HUGE;
                let xs = tr.xs, ys = tr.ys, zs = tr.zs, ts = tr.ts;
                for (let k = 1; k <= tr.n; k++) {
                    if (now - ts[k] < tr.life) {
                        let dx = xs[k] - ex, dy = ys[k] - ey, dz = zs[k] - ez;
                        let d2 = dx * dx + dy * dy + dz * dz;
                        if (d2 < best) {
                            best = d2;
                        }
                    }
                }
                let k = lclamp((Math.sqrt(best) - SMOKE_NEAR0) / (SMOKE_NEAR1 - SMOKE_NEAR0), 0, 1);
                al = k * k * (3 - 2 * k);
            }
            if (al > 0.01) {
                R.trail(r, tr, now, al);
            }
        }
    }
}

export function trailsClear(W: World): void {
    let ts = W.trails;
    for (let i = 1; i < ts.length; i++) {
        let sl = ts[i];
        sl.used = false;
        sl.lastT = -100;
        sl.gap = false;
        R.trailClear(sl.tr);
    }
}

// Spinning propeller disc as a translucent ellipse (mesh blades spin inside).
// (nx, ny, nz) = the disc normal (the prop axis).
export function propDisc(W: World, r: Gfx, cx: f64, cy: f64, cz: f64, nx: f64, ny: f64, nz: f64, radius: f64, alpha: f64, seed: f64): void {
    let F = W.fx;
    let vx = F.camX - cx, vy = F.camY - cy, vz = F.camZ - cz;
    let vl = Math.sqrt(vx * vx + vy * vy + vz * vz);
    if (vl < 1e-3) {
        return;
    }
    vx = vx / vl;
    vy = vy / vl;
    vz = vz / vl;
    let c = Math.abs(nx * vx + ny * vy + nz * vz);
    let ax = ny * vz - nz * vy, ay = nz * vx - nx * vz, az = nx * vy - ny * vx;
    let al = Math.sqrt(ax * ax + ay * ay + az * az);
    let minor = lmax(c, 0.14);
    let stretch = al > 1e-3 ? (1 / minor - 1) * 20 : 0.0;
    if (al > 1e-3) {
        ax = ax / al;
        ay = ay / al;
        az = az / al;
    }
    let sz = radius * minor;
    if (stretch > 0.05) {
        R.particle(r, cx, cy, cz, sz, 0.9, 0.95, 1, alpha * 0.26, 3, 0.9, seed, 0, ax, ay, az, stretch);
        R.particle(r, cx, cy, cz, sz * 1.1, 0.55, 0.82, 1, alpha * 0.5, 2, 0.55, seed, 0, ax, ay, az, stretch);
    } else {
        R.particle(r, cx, cy, cz, sz, 0.9, 0.95, 1, alpha * 0.26, 3, 0.9, seed, 0);
        R.particle(r, cx, cy, cz, sz * 1.1, 0.55, 0.82, 1, alpha * 0.5, 2, 0.55, seed, 0);
    }
}

// Aim direction from (x,y,z) at the player with lead and a little scatter.
export let AIM_AT_PLAYER_1: f64 = 0;
export let AIM_AT_PLAYER_2: f64 = 0;
export let AIM_AT_PLAYER_3: f64 = 0;
export function aimAtPlayer(W: World, ctx: Ctx, x: f64, y: f64, z: f64, speed: f64, scatter: f64): f64 {
    let p = ctx.player.pos;
    let px = <f64>p.x, py = <f64>p.y, pz = <f64>p.z;
    let dx = px - x, dy = py - y, dz = pz - z;
    let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
    // closing speed estimate (player flies toward bullets coming from ahead)
    let t = d / lmax(speed + 30, 10);
    let tx = px + W.playerVx * t + (lrandom() - 0.5) * scatter;
    let ty = py + W.playerVy * t + (lrandom() - 0.5) * scatter;
    let tz = pz + W.playerVz * t + (lrandom() - 0.5) * scatter;
    dx = tx - x;
    dy = ty - y;
    dz = tz - z;
    d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.001);
    AIM_AT_PLAYER_1 = dx / d;
    AIM_AT_PLAYER_2 = dy / d;
    AIM_AT_PLAYER_3 = dz / d;
    return AIM_AT_PLAYER_1;
}

// Time for a shot at `speed` from D (target - muzzle) to meet a target
// moving at V: |D + V t| = speed * t. -1 when it never catches up.
function meetTime(dx: f64, dy: f64, dz: f64, vx: f64, vy: f64, vz: f64, speed: f64): f64 {
    let a = vx * vx + vy * vy + vz * vz - speed * speed;
    let b = 2 * (dx * vx + dy * vy + dz * vz);
    let c = dx * dx + dy * dy + dz * dz;
    if (Math.abs(a) < 1e-4) {
        return b < 0 ? -c / b : -1.0;
    }
    let disc = b * b - 4 * a * c;
    if (disc < 0) {
        return -1;
    }
    let sq = Math.sqrt(disc);
    let t1 = (-b - sq) / (2 * a), t2 = (-b + sq) / (2 * a);
    if (t1 > 0 && (t2 <= 0 || t1 < t2)) {
        return t1;
    }
    return t2 > 0 ? t2 : -1.0;
}

// Leading shot: the intercept with a pilot who keeps flying the rail the way
// he is now (speed, lateral and vertical drift; the rail's curve included),
// aimed `off` meters to his right (0 = dead on; a fan brackets him).
// Holding a line gets you hit; turning, climbing or rolling does not.
export let INTERCEPT_1: f64 = 0;
export let INTERCEPT_2: f64 = 0;
export let INTERCEPT_3: f64 = 0;
export function intercept(W: World, ctx: Ctx, x: f64, y: f64, z: f64, speed: f64, off: f64): f64 {
    let pl = ctx.player;
    let p = pl.pos, rt = pl.right;
    let px = <f64>p.x + <f64>rt.x * off, py = <f64>p.y + <f64>rt.y * off, pz = <f64>p.z + <f64>rt.z * off;
    let dx = px - x, dy = py - y, dz = pz - z;
    let t = meetTime(dx, dy, dz, W.playerVx, W.playerVy, W.playerVz, speed);
    if (t <= 0 || t > 3.5) {
        // no intercept in reach (a slow orb chasing him): plain aim
        aimAtPlayer(W, ctx, x, y, z, speed, 0);
        INTERCEPT_1 = AIM_AT_PLAYER_1;
        INTERCEPT_2 = AIM_AT_PLAYER_2;
        INTERCEPT_3 = AIM_AT_PLAYER_3;
        return INTERCEPT_1;
    }
    // follow the rail: where he will be, as an average velocity, twice
    let q = ctx.toWorld(pl.s + pl.speed * t, pl.x + off + pl.vx * t, pl.y + pl.vy * t);
    for (let k = 1; k <= 2; k++) {
        let t2 = meetTime(dx, dy, dz, (<f64>q.x - px) / t, (<f64>q.y - py) / t, (<f64>q.z - pz) / t, speed);
        if (t2 <= 0 || t2 > 3.5) {
            break;
        }
        t = t2;
        q = ctx.toWorld(pl.s + pl.speed * t, pl.x + off + pl.vx * t, pl.y + pl.vy * t);
    }
    dx = <f64>q.x - x;
    dy = <f64>q.y - y;
    dz = <f64>q.z - z;
    let d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.001);
    INTERCEPT_1 = dx / d;
    INTERCEPT_2 = dy / d;
    INTERCEPT_3 = dz / d;
    return INTERCEPT_1;
}

// Standard shots. `lead` (optional, NaN = nil) fires a leading shot `lead` m
// to the pilot's right instead of the scattered one; `dmg` (NaN = nil)
// overrides the damage.
export function tracer(W: World, ctx: Ctx, x: f64, y: f64, z: f64, speed: f64, scatter: f64, lead: f64 = NaN, dmg: f64 = NaN): void {
    let dx: f64, dy: f64, dz: f64;
    if (!isNaN(lead)) {
        intercept(W, ctx, x, y, z, speed, lead);
        dx = INTERCEPT_1;
        dy = INTERCEPT_2;
        dz = INTERCEPT_3;
    } else {
        aimAtPlayer(W, ctx, x, y, z, speed, scatter);
        dx = AIM_AT_PLAYER_1;
        dy = AIM_AT_PLAYER_2;
        dz = AIM_AT_PLAYER_3;
    }
    bullet(W, 0, x, y, z, dx * speed, dy * speed, dz * speed, isNaN(dmg) ? 0.07 : dmg, 2.2, 0.5, 1, 0.1, 0.4, 0);
    fx.muzzle(W.fx, x, y, z, dx, dy, dz, 0.9, 1, 0.1, 0.4);
}

// lead: NaN = nil
export function orb(W: World, ctx: Ctx, x: f64, y: f64, z: f64, speed: f64, scatter: f64, r: f64, g: f64, b: f64, lead: f64 = NaN): Bullet? {
    let dx: f64, dy: f64, dz: f64;
    if (!isNaN(lead)) {
        intercept(W, ctx, x, y, z, speed, lead);
        dx = INTERCEPT_1;
        dy = INTERCEPT_2;
        dz = INTERCEPT_3;
    } else {
        aimAtPlayer(W, ctx, x, y, z, speed, scatter);
        dx = AIM_AT_PLAYER_1;
        dy = AIM_AT_PLAYER_2;
        dz = AIM_AT_PLAYER_3;
    }
    let bl = bullet(W, 1, x, y, z, dx * speed, dy * speed, dz * speed, 0.09, 4, 0.95, r, g, b, 0);
    fx.muzzle(W.fx, x, y, z, dx, dy, dz, 1.3, r, g, b);
    return bl;
}

// A leading fan of `n` orbs: the middle one dead on the intercept, the others
// `gap` m apart across his line (a sidestep alone does not clear it).
export function orbFan(W: World, ctx: Ctx, x: f64, y: f64, z: f64, speed: f64, n: f64, gap: f64, r: f64, g: f64, b: f64): void {
    for (let i = 1.0; i <= n; i++) {
        orb(W, ctx, x, y, z, speed, 0, r, g, b, (i - (n + 1) / 2) * gap);
    }
}

function speakerOf(who: string): string {
    if (who == "tower") return "LIGHTHOUSE";
    if (who == "vi") return "VI";
    if (who == "hank") return "HANK";
    if (who == "baron") return "BARON KESSEL";
    return who.toUpperCase();
}

// Queue a comm line for the core's channel. The mission script holds it
// until the channel is free and drops it once its boss phase is over (the
// first line of a phase cuts in within 2.5 s: events.luau bossComms).
// `now`: tied to no phase, it goes out at once (like a kill reaction).
// seconds / prio: NaN = nil (3.2 / 1); mood: null = 'neutral'.
export function say(W: World, who: string, text: string, seconds: f64 = NaN, prio: f64 = NaN, mood: string? = null, now: bool = false): void {
    let b = W.boss;
    let live = b != null && !b.killed && !b.escaped && !now;
    let c = new Comm();
    c.who = who;
    c.speaker = speakerOf(who);
    c.text = text;
    c.seconds = isNaN(seconds) ? 3.2 : seconds;
    c.prio = isNaN(prio) ? 1 : prio;
    c.mood = mood != null ? mood : "neutral";
    c.boss = b != null ? b.kind : "";
    c.phase = b != null && live ? b.phase : -1;
    W.comms.push(c);
}

// Queue a banner for the HUD's alert slot (played by the mission script
// when the slot is free, so bosses never stack slabs on each other). `phase`
// ties a callout to a boss phase (dropped if the fight has moved past it).
// prio / phase: NaN = nil.
export function banner(W: World, text: string, sub: string, style: string, prio: f64 = NaN, phase: f64 = NaN): void {
    let b = W.boss;
    let a = new Alert();
    a.kind = "banner";
    a.text = text;
    a.sub = sub;
    a.style = style;
    a.seconds = 0;
    a.prio = isNaN(prio) ? 2 : prio;
    a.boss = b != null ? b.kind : "";
    a.phase = b != null && !isNaN(phase) ? phase : -1;
    W.alerts.push(a);
}

// Optional core services ------------------------------------------------------------

// Seconds of game time our alerts hold after a sting (the card itself runs
// 1.2-2.5 s under the core's bullet time).
export const STING_HOLD: f64 = 1.1;

// DIRECTION #21 set-piece sting (core: Game.sting / stingTitle / stingSub +
// stingFire, bullet time, centre alerts held, the camera framing the boss at
// (x, y, z) within `radius` m; the live position stays readable through
// enemies.focus). Port: ctx.sting always exists (Luau: false without it, the
// caller falls back to a banner); x, y, z, radius are not passed on (the
// core's sting takes 3 args).
export function sting(W: World, ctx: Ctx, kind: string, title: string, sub: string, x: f64, y: f64, z: f64, radius: f64): bool {
    ctx.sting(kind, title, sub);
    W.stingT = STING_HOLD;
    return true;
}

// Pays a boss bonus; returns the points actually credited when the core's
// addScore reports them (skim and combo multiply the base), else NaN (nil).
export function pay(ctx: Ctx, points: f64, x: f64, y: f64, z: f64, label: string): f64 {
    return ctx.addScore(points, x, y, z, label);
}

// Chase-camera mirror ---------------------------------------------------------------
// The bosses keep their weak points under the HUD's boss stack by where the
// core's chase camera puts them on screen. With ctx.project (camera.project
// on the rig) that is exact; without it this mirror replays camera.luau
// chasePose + the chase branch of camera.update from what the ctx shows (the
// pilot's rail state, our own ctx.focus calls, same dt): the rubber-band
// eye, its lateral and height damps (a diving pilot leaves the eye above him
// looking down), the boss lift fed back from the focus point's screen
// height, the pilot placed low in the safe zone, the look damp, the zone
// clamp and the fov. Roll, shake, boost kick and the rock probe are left out
// (measured against camera.project in a boss fight: v within ~0.03).

export function newCam(): Cam {
    return new Cam();
}

const UPY: Vector = Vector.xyz(0, 1, 0);
const HERO_EXTENT: f64 = 1.05; // camera.luau

// viewBasis -> VB_F / VB_R / VB_U
let VB_F: Vector = Vector.xyz(0, 0, -1);
let VB_R: Vector = Vector.xyz(1, 0, 0);
let VB_U: Vector = Vector.xyz(0, 1, 0);
function viewBasis(eye: Vector, look: Vector): void {
    let f = mathx.norm(look - eye);
    let rt = mathx.norm(mathx.cross(f, UPY));
    VB_F = f;
    VB_R = rt;
    VB_U = mathx.cross(rt, f);
}

// ndcOf -> NDC_X / NDC_Y / NDC_Z
let NDC_X: f64 = 0;
let NDC_Y: f64 = 0;
let NDC_Z: f64 = 0;
function ndcOf(eye: Vector, f: Vector, rt: Vector, up: Vector, th: f64, aspect: f64, P: Vector): void {
    let d = P - eye;
    let z = mathx.dot(d, f);
    if (z < 0.3) {
        NDC_X = 0;
        NDC_Y = 0;
        NDC_Z = z;
        return;
    }
    NDC_X = mathx.dot(d, rt) / (z * th * aspect);
    NDC_Y = mathx.dot(d, up) / (z * th);
    NDC_Z = z;
}

function soft(v: f64, lo: f64, hi: f64, m: f64): f64 {
    if (lo > hi) {
        return (lo + hi) * 0.5;
    }
    m = lmin(m, (hi - lo) * 0.5);
    if (m <= 1e-4) {
        return mathx.clamp(v, lo, hi);
    }
    if (v > hi - m) {
        return hi - m + m * Math.tanh((v - (hi - m)) / m);
    } else if (v < lo + m) {
        return lo + m - m * Math.tanh((lo + m - v) / m);
    }
    return v;
}

// Turn the look point so P lands where `place` wants it. Port: Luau's place
// closures as modes: 0 (nx, a); 1 (soft(nx, -a, a, 0.1), ny); 2 the zone
// clamp (soft(nx, -a + hw, a - hw, 0.12), soft(ny, b + hh, c - hh, 0.1)).
function reframe(eye: Vector, look: Vector, P: Vector, extent: f64, fov: f64, aspect: f64, mode: i32, a: f64, b: f64, c: f64): Vector {
    let th = Math.tan(fov * 0.5);
    for (let it = 1; it <= 2; it++) {
        viewBasis(eye, look);
        let f = VB_F, rt = VB_R, up = VB_U;
        ndcOf(eye, f, rt, up, th, aspect, P);
        let nx = NDC_X, ny = NDC_Y, z = NDC_Z;
        if (z < 0.5) {
            return look;
        }
        let hh = extent / (z * th);
        let hw = hh / aspect;
        let tx: f64, ty: f64;
        if (mode == 0) {
            tx = nx;
            ty = a;
        } else if (mode == 1) {
            tx = soft(nx, -a, a, 0.1);
            ty = ny;
        } else {
            tx = soft(nx, -a + hw, a - hw, 0.12);
            ty = soft(ny, b + hh, c - hh, 0.1);
        }
        if (Math.abs(tx - nx) < 1e-4 && Math.abs(ty - ny) < 1e-4) {
            return look;
        }
        let D = mathx.len(look - eye);
        look = look + rt * <f32>((nx - tx) * th * aspect * D) + up * <f32>((ny - ty) * th * D);
    }
    return look;
}

// ctx.focus, also fed to the mirror. Bosses frame themselves through this.
export function focus(W: World, ctx: Ctx, x: f64, y: f64, z: f64, w: f64): void {
    ctx.focus(x, y, z, w);
    let c = W.cam;
    c.fx = x;
    c.fy = y;
    c.fz = z;
    c.fw = lmax(c.fw, mathx.saturate(w));
}

// One frame of the mirror (enemies.update calls it after the boss, as the
// core updates its camera after the enemies). Starts on a boss's first frame.
export function camTick(W: World, ctx: Ctx, dt: f64): void {
    let c = W.cam;
    let p = ctx.player;
    let tall = mathx.saturate((1.3 - c.aspect) / 0.75);
    let near = mathx.lerp(1, 0.68, tall);
    let boss = mathx.saturate(c.fw * 5);
    let dist = (mathx.clamp(10 + (p.speed - playerMod.CRUISE) * 0.02, 9.5, 10.8) + c.fw * 6) * near;
    let skimK = 1 - mathx.smoothstep(3, 10, p.y);
    let fovT = rad(60) + (p.speed - playerMod.CRUISE) * rad(0.16);
    if (!c.on) {
        c.on = true;
        c.s = p.s - dist;
        c.sv = p.speed;
        c.x = p.x * 0.8;
        c.y = lmax(1.3, p.y + lmax(p.y * -0.28 + 4.8 - skimK * 2.6 + c.fw * 2, 1.5 * boss) * near);
        c.lift = 0;
        c.look = p.pos + p.fwd * <f32>24;
        c.fov = fovT;
    }
    // chasePose
    c.sv = mathx.damp(c.sv, p.speed, 2.6, dt);
    let err = (p.s - dist) - c.s;
    let pull = 2.4 + lmax(0, err - 2) * 0.35;
    c.s += c.sv * dt + err * (1 - Math.exp(-pull * dt));
    c.s = mathx.clamp(c.s, p.s - dist - 1.5 * near, p.s - 5 * near);
    c.x = mathx.damp(c.x, p.x * 0.8, 7.5, dt);
    if (boss <= 0) {
        c.lift = mathx.damp(c.lift, 0, 1.5, dt);
    }
    let off = p.y * 0.72 + 4.8 - skimK * 2.6 + c.fw * 2 - p.y;
    let cy = p.y + lmax(off, 1.5 * boss) * near + c.lift;
    c.y = mathx.damp(c.y, lmax(1.3, cy), 5, dt);
    let tp = ctx.railFrame(c.s);
    let rt = ctx.rfRight, up = ctx.rfUp;
    let eye = Vector.xyz(<f32>(<f64>tp.x + <f64>rt.x * c.x + <f64>up.x * c.y), <f32>(<f64>tp.y + <f64>up.y * c.y), <f32>(<f64>tp.z + <f64>rt.z * c.x + <f64>up.z * c.y));
    let P = p.pos;
    let look = P + p.fwd * <f32>24 + p.up * <f32>0.6 + p.right * <f32>(p.vx * 0.04);
    let focusP = Vector.xyz(<f32>c.fx, <f32>c.fy, <f32>c.fz);
    if (c.fw > 0.001) {
        look = mathx.vlerp(look, focusP, c.fw * (0.45 + tall * 0.25));
    }
    let hx = camera.zone(c.aspect), y0 = camera.ZONE_2, y1 = camera.ZONE_3;
    let oy = mathx.lerp(y0, y1, mathx.lerp(mathx.lerp(0.28, 0.66, skimK), 0.16, boss));
    let fovE = camera.effFov(fovT, c.aspect);
    look = reframe(eye, look, P, 0, fovE, c.aspect, 0, oy, 0, 0);
    if (boss > 0) {
        let th = Math.tan(fovE * 0.5);
        viewBasis(eye, look);
        ndcOf(eye, VB_F, VB_R, VB_U, th, c.aspect, focusP);
        let by = NDC_Y, bz = NDC_Z;
        if (bz > 1) {
            c.lift = mathx.clamp(c.lift + (0.24 - by) * 6 * boss * dt, 0, 6);
        }
        if (tall > 0) {
            let lim = mathx.lerp(0.6, 0.25, tall);
            let fit = reframe(eye, look, focusP, 0, fovE, c.aspect, 1, lim, 0, 0);
            look = mathx.vlerp(look, fit, boss * tall);
        }
    }
    // camera.update, chase branch
    c.look = mathx.vdamp(c.look, look, 10, dt);
    c.fw = lmax(0, c.fw - dt * 1.5);
    c.fov = mathx.damp(c.fov, fovT, 4, dt);
    c.look = reframe(eye, c.look, P, HERO_EXTENT, camera.effFov(c.fov, c.aspect), c.aspect, 2, hx, y0, y1);
    if (<f64>eye.y < 0.55) {
        eye = Vector.xyz(eye.x, <f32>0.55, eye.z);
    }
    c.eye = eye;
}

// Screen position of a world point, (u, v) 0..1 with v down, and depth:
// ctx.project (camera.project on the rig; the port's Ctx always has it).
export let SCREEN_1: f64 = 0;
export let SCREEN_2: f64 = 0;
export let SCREEN_3: f64 = 0;
export function screen(W: World, ctx: Ctx, x: f64, y: f64, z: f64): f64 {
    ctx.project(x, y, z);
    SCREEN_1 = ctx.pjU;
    SCREEN_2 = ctx.pjV;
    SCREEN_3 = ctx.pjD;
    return SCREEN_1;
}

// The mirror's projection alone (debug: compare with ctx.project).
export let CAM_PROJECT_1: f64 = 0;
export let CAM_PROJECT_2: f64 = 0;
export let CAM_PROJECT_3: f64 = 0;
export function camProject(W: World, x: f64, y: f64, z: f64): f64 {
    let c = W.cam;
    if (!c.on) {
        CAM_PROJECT_1 = -1;
        CAM_PROJECT_2 = -1;
        CAM_PROJECT_3 = -1;
        return -1;
    }
    viewBasis(c.eye, c.look);
    let f = VB_F, rt = VB_R, up = VB_U;
    let d = Vector.xyz(<f32>x, <f32>y, <f32>z) - c.eye;
    let zz = mathx.dot(d, f);
    if (zz <= 1e-4) {
        CAM_PROJECT_1 = -1;
        CAM_PROJECT_2 = -1;
        CAM_PROJECT_3 = -1;
        return -1;
    }
    let th = Math.tan(camera.effFov(c.fov, c.aspect) * 0.5);
    CAM_PROJECT_1 = mathx.dot(d, rt) / (zz * th * c.aspect) * 0.5 + 0.5;
    CAM_PROJECT_2 = 0.5 - mathx.dot(d, up) / (zz * th) * 0.5;
    CAM_PROJECT_3 = zz;
    return CAM_PROJECT_1;
}

// Rail distance ahead of the pilot a boss actually sits at (its choreography
// works in B.s; narrow screens push it back so it still fits the width).
export function bossS(W: World, B: Boss): f64 {
    return B.s * W.far;
}

// Distance from a world point to the player.
export function distToPlayer(ctx: Ctx, x: f64, y: f64, z: f64): f64 {
    let p = ctx.player.pos;
    let dx = <f64>p.x - x, dy = <f64>p.y - y, dz = <f64>p.z - z;
    return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

// Is the point in front of the player (along the rail forward) by at least `ahead` meters?
export function ahead(ctx: Ctx, x: f64, y: f64, z: f64): f64 {
    let p = ctx.player.pos;
    let f = ctx.player.fwd;
    return (x - <f64>p.x) * <f64>f.x + (y - <f64>p.y) * <f64>f.y + (z - <f64>p.z) * <f64>f.z;
}

// The lens of the core's rig as last updated (beats included), solved from
// ctx.project: camera.project is linear per view axis once scaled by depth,
// so 4 probes around a point in front of the lens give the view basis and the
// eye. false when no probe point is in front.
const PROBE_H: f64 = 8;

// solveEye -> SE_X / SE_Y / SE_Z (valid when it returns true)
let SE_X: f64 = 0;
let SE_Y: f64 = 0;
let SE_Z: f64 = 0;
function solveEye(ctx: Ctx, px: f64, py: f64, pz: f64): bool {
    let u0 = ctx.project(px, py, pz), v0 = ctx.pjV, z0 = ctx.pjD;
    let u1 = ctx.project(px + PROBE_H, py, pz), v1 = ctx.pjV, z1 = ctx.pjD;
    let u2 = ctx.project(px, py + PROBE_H, pz), v2 = ctx.pjV, z2 = ctx.pjD;
    let u3 = ctx.project(px, py, pz + PROBE_H), v3 = ctx.pjV, z3 = ctx.pjD;
    SE_X = 0;
    SE_Y = 0;
    SE_Z = 0;
    if (z0 < 2 || z1 < 2 || z2 < 2 || z3 < 2) {
        return false;
    }
    // view coordinates: depth, right / (tan * aspect), up / tan
    let a0 = (u0 - 0.5) * 2 * z0, b0 = (0.5 - v0) * 2 * z0;
    let k = 1 / PROBE_H;
    let fx0 = (z1 - z0) * k, fy0 = (z2 - z0) * k, fz0 = (z3 - z0) * k;
    let rx = ((u1 - 0.5) * 2 * z1 - a0) * k, ry = ((u2 - 0.5) * 2 * z2 - a0) * k, rz = ((u3 - 0.5) * 2 * z3 - a0) * k;
    let ux = ((0.5 - v1) * 2 * z1 - b0) * k, uy = ((0.5 - v2) * 2 * z2 - b0) * k, uz = ((0.5 - v3) * 2 * z3 - b0) * k;
    let ff = fx0 * fx0 + fy0 * fy0 + fz0 * fz0;
    let rr = rx * rx + ry * ry + rz * rz;
    let uu = ux * ux + uy * uy + uz * uz;
    if (ff < 0.5 || rr < 1e-6 || uu < 1e-6) {
        return false;
    }
    // P - eye = f z0 / |f|^2 + R a0 / |R|^2 + U b0 / |U|^2 (orthogonal basis)
    let kf = z0 / ff, kr = a0 / rr, ku = b0 / uu;
    SE_X = px - fx0 * kf - rx * kr - ux * ku;
    SE_Y = py - fy0 * kf - ry * kr - uy * ku;
    SE_Z = pz - fz0 * kf - rz * kr - uz * ku;
    return true;
}

// The core's lens this frame: solved from ctx.project around a point ahead
// of the pilot, the boss in focus or the pilot himself (the first one in
// front of the lens).
export let LENS_1: bool = false;
export let LENS_2: f64 = 0;
export let LENS_3: f64 = 0;
export let LENS_4: f64 = 0;
export function lens(W: World, ctx: Ctx): bool {
    let p = ctx.player.pos;
    let f = ctx.player.fwd;
    let px = <f64>p.x, py = <f64>p.y, pz = <f64>p.z;
    let ok = solveEye(ctx, px + <f64>f.x * 60, py + <f64>f.y * 60, pz + <f64>f.z * 60);
    if (!ok && W.focusOn) {
        ok = solveEye(ctx, W.focusX, W.focusY, W.focusZ);
    }
    if (!ok) {
        ok = solveEye(ctx, px, py, pz);
    }
    LENS_1 = ok;
    LENS_2 = SE_X;
    LENS_3 = SE_Y;
    LENS_4 = SE_Z;
    return ok;
}

// Camera eye for size clamps and culling: the core's lens (lens, exact
// through kill cams, reveal / arch shots and the death cam, headless too).
// Else r.camEye, or a chase-camera estimate when r.camEye is not near the
// pilot. Also stores it on the fx record (fx.draw runs right after
// enemies.draw).
export let EYE_1: f64 = 0;
export let EYE_2: f64 = 0;
export let EYE_3: f64 = 0;
export function eye(W: World, r: Gfx): f64 {
    let e = r.camEye;
    let ex = <f64>e.x, ey = <f64>e.y, ez = <f64>e.z;
    let ctx = W.ctx;
    if (ctx != null) {
        if (lens(W, ctx)) {
            ex = LENS_2;
            ey = LENS_3;
            ez = LENS_4;
        } else {
            let p = ctx.player.pos;
            let dx = ex - <f64>p.x, dy = ey - <f64>p.y, dz = ez - <f64>p.z;
            if (dx * dx + dy * dy + dz * dz > 60 * 60) {
                let f = ctx.player.fwd;
                ex = <f64>p.x - <f64>f.x * 9;
                ey = <f64>p.y + 2.4;
                ez = <f64>p.z - <f64>f.z * 9;
            }
        }
    }
    let F = W.fx;
    F.camX = ex;
    F.camY = ey;
    F.camZ = ez;
    F.camSet = true;
    EYE_1 = ex;
    EYE_2 = ey;
    EYE_3 = ez;
    return ex;
}

// Rail coordinates -> world, writing the enemy's position.
export function place(e: Enemy, ctx: Ctx): void {
    let s = e.rel ? ctx.railS + e.s : e.s;
    let w = ctx.toWorld(s, e.rx, e.ry);
    e.x = <f64>w.x;
    e.y = <f64>w.y;
    e.z = <f64>w.z;
}
