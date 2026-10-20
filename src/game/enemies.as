// Port of src/game/enemies.luau. Enemies, their bullets and the bosses (the facade the core and the mission script call).
// The core loop calls: create, update, draw, raycast, damage. The mission
// script (events) spawns through the helpers below.
// Port: Luau's object-keyed SEEN set is the Enemy.seen flag (object keys
// lose entries after the per-frame GC). squadron opts -> SquadOpts,
// practice opts -> PracticeOpts (+ PracticeLob); spawn's unused params
// table is dropped. Multi-return: focus -> FOCUS_1 .. FOCUS_5.
import { Vector } from "rive/vector";
import { format, FormatArg } from "rive/format";
import { clock } from "rive/os";
import { Ctx } from "./types";
import * as R from "../render/renderer";
import * as fx from "./fx";
import { Fx } from "./fx";
import * as models from "./models";
import * as ai from "./ai_types";
import { Enemy, World, Group, Bullet } from "./ai_types";
import * as mathx from "../lib/mathx";
import * as patterns from "./ai_patterns";
import * as crow from "./boss_stormcrow";
import * as eye from "./boss_eye";
import * as sfxLib from "./sfx";
import { HUGE, lmin, lmax, lclamp, lrandom, mod } from "../lib/compat";

// boss part hit / ricochet counters for the ai.LOG telemetry
export const DBG: Map<string, f64> = new Map<string, f64>();

// hostile fire: hot crimson-magenta in dark plum ink (tracers)
const HOT_R: f64 = 1, HOT_G: f64 = 0.1, HOT_B: f64 = 0.4;
const INK_R: f64 = 0.16, INK_G: f64 = 0.02, INK_B: f64 = 0.1;

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}

export function create(effects: Fx): World {
    let mo = models.build();
    effects.debrisBatch = mo.debris;
    models.splashBatches();
    effects.crownBatch = models.SPLASH_CROWN;
    effects.jetBatch = models.SPLASH_JET;
    effects.ringBatch = models.SPLASH_RING;
    // (the World's defaults are Luau's table: empty lists, far 1, fresh trails and cam)
    return new World(effects, mo);
}

// Clears enemies, bullets, boss and debris (run restarts).
export function clear(E: World): void {
    DBG.clear();
    let list = E.list;
    for (let i = 1; i < list.length; i++) list[i].seen = false;
    list.length = 1;
    E.bullets.length = 1;
    E.fx.debris.length = 1;
    E.comms.length = 1;
    E.alerts.length = 1;
    ai.trailsClear(E);
    E.boss = null;
    E.cam.on = false;
}

// Spawning ------------------------------------------------------------------------------

// hp, radius, score, scale (1-based)
function stats(kind: string): Array<f64> {
    if (kind == "biplane") return [0.0, 3, 5.0, 150, 1.25];
    if (kind == "kamikaze") return [0.0, 1, 3.1, 120, 1.15];
    if (kind == "trooper") return [0.0, 4, 3.8, 200, 2.9];
    if (kind == "mine") return [0.0, 1, 3.0, 50, 1.9];
    if (kind == "turret") return [0.0, 6, 2.8, 250, 1.2];
    return [0.0, 2, 3.9, 100, 1.35]; // drone (and any other kind)
}

function make(E: World, ctx: Ctx, kind: string, behavior: string, countKill: bool): Enemy {
    let st = stats(kind);
    let model = kind == "kamikaze" ? "kamikaze" : kind;
    let e = ai.enemy(model, behavior, st[1], st[2], st[3]);
    e.scale = st[4];
    E.list.push(e);
    if (countKill) ctx.stats.killsTotal += 1;
    return e;
}

export function group(name: string, bonus: f64): Group {
    let g = new Group();
    g.alive = 0;
    g.total = 0;
    g.bonus = bonus;
    g.name = name;
    g.escaped = 0;
    g.flyby = -1;
    return g;
}

// squadron opts (Luau { [string]: number }?): NaN = unset
export class SquadOpts {
    x: f64 = NaN; // offsets
    y: f64 = NaN;
    fire: f64 = NaN; // burst gap s
    bonus: f64 = NaN;
    gap: f64 = NaN; // lateral spacing of the formation, m
    sx: f64 = NaN; // path lateral scale (0.15 keeps a head-on pass inside the canyon slot)
}

@inline function opt(v: f64, d: f64): f64 {
    return isNaN(v) ? d : v;
}

// Squadron on a named path (see ai_patterns.PATHS).
// formation: 'v' | 'line' | 'column' | 'wall'; mirror alternates sides.
export function squadron(E: World, ctx: Ctx, kind: string, pathName: string, n: f64, formation: string, side: f64, opts: SquadOpts? = null): Group {
    let path = patterns.PATHS.has(pathName) ? patterns.PATHS.get(pathName) : patterns.PATHS.get("overtake");
    let o: SquadOpts = opts != null ? opts : new SquadOpts();
    let g = group(pathName, opt(o.bonus, n * 100));
    let x0 = opt(o.x, 0), y0 = opt(o.y, 0);
    for (let i = 1.0; i <= n; i++) {
        let e = make(E, ctx, kind, "path", true);
        e.path = path;
        e.side = side;
        e.sx = opt(o.sx, 1);
        let k = i - 1;
        let wing = mod(k, 2) == 1 ? 1.0 : -1.0;
        let rank = Math.floor((k + 1) / 2);
        if (formation == "v") {
            e.p1 = -rank * 7;
            e.p2 = wing * rank * opt(o.gap, 7) + x0;
            e.p3 = rank * 1.5 + y0;
            e.t = -rank * 0.12;
        } else if (formation == "line") {
            e.p1 = 0;
            e.p2 = (k - (n - 1) / 2) * opt(o.gap, 9) + x0;
            e.p3 = y0;
            e.t = -k * 0.05;
        } else if (formation == "wall") {
            e.p1 = 0;
            e.p2 = (mod(k, 3) - 1) * opt(o.gap, 10) + x0;
            e.p3 = Math.floor(k / 3) * 7 + y0;
            e.t = 0;
        } else { // column / trail
            e.p1 = 0;
            e.p2 = x0;
            e.p3 = y0;
            e.t = -k * 0.45;
        }
        e.p4 = opt(o.fire, 2.0);
        e.fireT = 0.8 + lrandom() * 1.2;
        e.group = g;
        e.hidden = e.t < 0;
        g.total += 1;
        g.alive += 1;
    }
    return g;
}

// Hover drones that rise ahead (from the sea when `fromSea`), weave and fire.
export function hoverDrones(E: World, ctx: Ctx, n: f64, rs: f64, spread: f64, y: f64, stay: f64, fromSea: bool): Group {
    let g = group("drones", n * 80);
    for (let i = 1.0; i <= n; i++) {
        let e = make(E, ctx, "drone", "hover", true);
        let u = n > 1 ? (i - 1) / (n - 1) - 0.5 : 0.0;
        e.p1 = rs + Math.abs(u) * 14;
        e.p2 = u * spread;
        e.p3 = y + mod(i, 2) * 3;
        e.p4 = stay + i * 0.3;
        e.s = rs + 40;
        e.rx = e.p2 * 1.4;
        e.ry = fromSea ? -4 : 34;
        e.side = u < 0 ? -1 : 1;
        e.fireT = 1 + i * 0.4;
        e.group = g;
        g.total += 1;
        g.alive += 1;
    }
    return g;
}

export function kamikaze(E: World, ctx: Ctx, x: f64, delay: f64): void {
    let e = make(E, ctx, "kamikaze", "kamikaze", true);
    e.s = 230;
    e.rx = x;
    e.ry = 40;
    e.p1 = 150;
    e.p3 = 26;
    e.p4 = 1.2 + delay;
    e.t = 0;
}

// Jet troopers racing ahead; `warp` fades them in with a sparkle (violet reach).
export function troopers(E: World, ctx: Ctx, n: f64, rs: f64, spread: f64, y: f64, warp: bool): Group {
    let g = group("troopers", n * 150);
    for (let i = 1.0; i <= n; i++) {
        let e = make(E, ctx, "trooper", "racer", true);
        let u = n > 1 ? (i - 1) / (n - 1) - 0.5 : 0.0;
        e.p1 = rs + mod(i, 2) * 12;
        e.p2 = u * spread;
        e.p3 = y + mod(i, 3) * 2;
        e.s = -26;
        e.rx = e.p2;
        e.ry = e.p3 + 6;
        e.t = -(i - 1) * 0.35;
        e.hidden = e.t < 0;
        e.fireT = 2.5 + i * 0.5;
        e.group = g;
        if (warp) {
            e.warp = 1;
            e.s = e.p1;
            e.t = 1.6 - (i - 1) * 0.25;
            e.hidden = false;
        } else {
            // an overtake comes up out wide of the pilot, past the view's edge
            patterns.racerStart(e, ctx);
        }
        g.total += 1;
        g.alive += 1;
    }
    return g;
}

// Floating mine (absolute rail position). y ~0.8 floats on the sea.
export function mine(E: World, ctx: Ctx, s: f64, x: f64, y: f64): void {
    let e = make(E, ctx, "mine", "mine", true);
    e.rel = false;
    e.s = s;
    e.rx = x;
    e.p3 = y;
    e.ry = y;
    e.lockable = true;
}

// A cluster of mines around (s, x): `n` mines within `radius`.
export function mineField(E: World, ctx: Ctx, s: f64, x: f64, n: f64, radius: f64, airborne: bool): void {
    for (let i = 1.0; i <= n; i++) {
        let a = i * 2.39996 + s * 0.01;
        let rr = radius * Math.sqrt(i / n);
        let y = airborne && mod(i, 2) == 0 ? 4 + mod(i, 3) * 3 : 0.75;
        mine(E, ctx, s + Math.sin(a) * rr * 1.6, x + Math.cos(a) * rr, y);
    }
}

// Turret on a rock pedestal whose top sits at height y (absolute rail position).
// fireEvery: NaN = 1.9
export function turret(E: World, ctx: Ctx, s: f64, x: f64, y: f64, fireEvery: f64 = NaN): void {
    let e = make(E, ctx, "turret", "turret", true);
    e.rel = false;
    e.s = s;
    e.rx = x;
    e.ry = y;
    // the rock pedestal stretches to reach the ledge height; the gun stays big
    e.p3 = lclamp(y / 14, 0.6, 1.6);
    e.scale = 2.1;
    e.radius = 2.6 * e.scale;
    e.p4 = opt(fireEvery, 1.9);
    e.fireT = 0.5 + lrandom();
}

// Showroom (debug): a model held at a rail-relative spot, turning at `rate` rad/s.
export function pose(E: World, ctx: Ctx, kind: string, s: f64, x: f64, y: f64, rate: f64, yaw0: f64): void {
    let e = make(E, ctx, kind, "pose", false);
    e.s = s;
    e.rx = x;
    e.ry = y;
    e.p1 = rate;
    e.p2 = yaw0;
    e.lockable = false;
}

// Flight school target: rides `relS` m ahead of the pilot at (x, y) like
// pose; no score, no kill count, no body collision; lockable while alive and
// above the sea. opts: rise (comes up out of the sea), bob (m, NaN = 0.5),
// hp (NaN = the kind's), lob: a lobber (0.45 s telegraph, then a practice
// intercept orb).
export class PracticeLob {
    first: f64 = 0;
    every: f64 = 0;
    speed: f64 = 0;
}
export class PracticeOpts {
    rise: bool = false; // (Luau `if o.rise`)
    bob: f64 = NaN;
    hp: f64 = NaN;
    lob: PracticeLob? = null;
}

export function practice(E: World, ctx: Ctx, kind: string, relS: f64, x: f64, y: f64, opts: PracticeOpts? = null): Enemy {
    let o: PracticeOpts = opts != null ? opts : new PracticeOpts();
    let e = make(E, ctx, kind, "practice", false);
    e.practice = true;
    e.score = 0;
    e.p1 = relS;
    e.p2 = x;
    e.p3 = y;
    e.s = relS;
    e.rx = x;
    e.ry = y;
    e.bob = opt(o.bob, 0.5);
    if (o.rise) {
        e.ry = -4;
        e.p4 = 1;
    }
    if (!isNaN(o.hp)) {
        e.hp = o.hp;
        e.maxHp = o.hp;
    }
    let lob = o.lob;
    if (lob != null) {
        e.fireT = lob.first;
        e.lobEvery = lmax(lob.every, 0.5);
        e.lobSpeed = lob.speed;
    }
    return e;
}

// Generic entry kept for the core API: kind at rail coords (absolute s).
export function spawn(E: World, ctx: Ctx, kind: string, s: f64, x: f64, y: f64): void {
    if (kind == "mine") {
        mine(E, ctx, s, x, y);
    } else if (kind == "turret") {
        turret(E, ctx, s, x, y, NaN);
    } else if (kind == "kamikaze") {
        kamikaze(E, ctx, x, 0);
    } else if (kind == "trooper") {
        troopers(E, ctx, 1, lmax(30, s - ctx.railS), 0, y, false);
    } else {
        let e = make(E, ctx, kind == "biplane" ? "biplane" : "drone", "hover", true);
        e.s = lmax(40, s - ctx.railS);
        e.rx = x;
        e.ry = y;
        e.p1 = e.s;
        e.p2 = x;
        e.p3 = y;
        e.p4 = 8;
    }
}

// Bosses ------------------------------------------------------------------------------------

// Clears the stage for a boss entrance: whatever is still on a run ducks into
// the sea or peels away over the camera (ai_patterns.retire).
export function clearStage(E: World): void {
    let list = E.list;
    for (let i = 1; i < list.length; i++) patterns.retire(list[i]);
}

export function bossStart(E: World, ctx: Ctx, kind: string, sEnd: f64): void {
    if (E.boss != null) return;
    if (kind == "stormcrow") {
        // (again, for a run that starts past the script's own call)
        clearStage(E);
        E.boss = crow.spawn(E, ctx, sEnd);
    } else if (kind == "eye") {
        E.boss = eye.spawn(E, ctx, sEnd);
    }
}

export function bossActive(E: World): bool {
    return E.boss != null;
}

// Live framing of the boss for the core's reveal framing and kill cam: on
// (returned, FOCUS_1), then its visual centre (world, FOCUS_2..4) and a
// radius (m, FOCUS_5) that holds all of it; off when no boss is up.
export let FOCUS_1: bool = false;
export let FOCUS_2: f64 = 0;
export let FOCUS_3: f64 = 0;
export let FOCUS_4: f64 = 0;
export let FOCUS_5: f64 = 0;
export function focus(E: World): bool {
    FOCUS_1 = E.focusOn;
    FOCUS_2 = E.focusX;
    FOCUS_3 = E.focusY;
    FOCUS_4 = E.focusZ;
    FOCUS_5 = E.focusR;
    return FOCUS_1;
}

// Returns 'none' | 'active' | 'killed' | 'escaped' for the last boss of a kind.
export function bossResult(E: World, kind: string): string {
    let b = E.boss;
    if (b != null && b.kind == kind) {
        if (b.killed) return "killed";
        if (b.escaped) return "escaped";
        return "active";
    }
    return "none";
}

// Damage -------------------------------------------------------------------------------------

function groupKill(E: World, ctx: Ctx, e: Enemy): void {
    let g = e.group;
    if (g == null) return;
    g.alive -= 1;
    if (g.alive <= 0 && g.escaped == 0 && g.total >= 3) {
        ctx.addScore(g.bonus, e.x, e.y + 3, e.z, "SQUADRON DOWN");
        ctx.sfx("checkpoint", 0.6);
        // a brass flash where the last one went, then the squadron's falling
        // wrecks go up one after another
        let F = E.fx;
        fx.ring(F, e.x, e.y, e.z, 2.5, 34, 0.97, 0.74, 0.2, 0.5);
        fx.glow(F, e.x, e.y, e.z, 5, 1, 0.8, 0.3, 0.18);
        let k = 0.0;
        let list = E.list;
        for (let i = 1; i < list.length; i++) {
            let o = list[i];
            if (o.group === g && o !== e && o.dying > 0 && !o.dead && o.chain <= 0 && o.kind != "turret") {
                k += 1;
                o.chain = 0.3 + k * 0.08;
            }
        }
    }
}

// Practice pop: confetti, POP!, a pop sound; no score, kills or wreck.
const POP_SFX: bool = sfxLib.duration("pop") > 0;
function practicePop(E: World, ctx: Ctx, e: Enemy, tell: bool): void {
    e.alive = false;
    e.lockable = false;
    e.dead = true;
    ai.trailRelease(E, e.trail);
    ai.trailRelease(E, e.trail2);
    e.trail = 0;
    e.trail2 = 0;
    let F = E.fx;
    fx.explosion(F, e.x, e.y, e.z, 1.2, "pop");
    fx.confetti(F, e.x, e.y, e.z, 1.2, 8);
    ctx.popup("POP!", "bonus", e.x, e.y + 2, e.z);
    if (POP_SFX) {
        ctx.sfx("pop", 0.8);
    } else {
        ctx.sfx("explode_small", 0.5);
    }
    if (tell && ctx.practiceOn) ctx.onPractice(e.kind, e.x, e.y, e.z);
}

function dbgAdd(key: string, d: f64): void {
    DBG.set(key, (DBG.has(key) ? DBG.get(key) : 0) + d);
}

// Apply damage; returns true if it destroyed the enemy.
export function damage(E: World, ctx: Ctx, e: Enemy, amount: f64): bool {
    if (!e.alive || e.dying > 0 || e.hidden) return false;
    if (e.armored) {
        fx.ricochet(E.fx, e.x, e.y, e.z);
        if (ai.LOG && e.part) dbgAdd("ric_" + e.kind, 1);
        return false;
    }
    if (ai.LOG && e.part) dbgAdd("hit_" + e.kind, amount);
    e.hp -= amount;
    e.flash = 1;
    if (e.minHp > 0 && e.hp < e.minHp) {
        // boss pacing floor: it shrugs the rest off
        e.hp = e.minHp;
        fx.ricochet(E.fx, e.x, e.y, e.z);
    }
    if (e.hp > 0) {
        ctx.sfx("hit", 0.35);
        return false;
    }
    if (e.practice) {
        practicePop(E, ctx, e, true);
        return true;
    }
    e.alive = false;
    e.lockable = false;
    let b = E.boss;
    if (e.part) {
        if (b != null) {
            if (b.kind == "stormcrow") {
                crow.partKilled(b, E, ctx, e);
            } else {
                eye.partKilled(b, E, ctx, e);
            }
        }
        return true;
    }
    ctx.addScore(e.score, e.x, e.y, e.z, null);
    ctx.stats.kills += 1;
    groupKill(E, ctx, e);
    patterns.kill(e, E, ctx);
    return true;
}

// Flight school cleanup: every practice target goes (pop: with a confetti
// pop each, not reported to ctx.onPractice; false: silently) and practice
// orbs in the air vanish.
export function clearPractice(E: World, ctx: Ctx, pop: bool): void {
    let list = E.list;
    for (let i = 1; i < list.length; i++) {
        let e = list[i];
        if (e.practice && !e.dead) {
            if (pop && e.alive && !e.hidden && e.y > -1) {
                practicePop(E, ctx, e, false);
            } else {
                e.alive = false;
                e.lockable = false;
                e.dead = true;
            }
        }
    }
    let bl = E.bullets;
    for (let i = 1; i < bl.length; i++) {
        let b = bl[i];
        if (b.practice) {
            b.life = 0;
            b.src = null;
        }
    }
}

// Player shot query: nearest target whose sphere the segment a->b crosses.
export function raycast(E: World, ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, radius: f64): Enemy? {
    let dx = bx - ax, dy = by - ay, dz = bz - az;
    let l2 = dx * dx + dy * dy + dz * dz;
    let best: Enemy? = null;
    let bestT = HUGE;
    let list = E.list;
    for (let i = 1; i < list.length; i++) {
        let e = list[i];
        if (e.alive && !e.hidden && e.dying <= 0) {
            // quick reject
            let mx = e.x - ax, my = e.y - ay, mz = e.z - az;
            let t = 0.0;
            if (l2 > 0) t = lclamp((mx * dx + my * dy + mz * dz) / l2, 0, 1);
            let cx = ax + dx * t - e.x, cy = ay + dy * t - e.y, cz = az + dz * t - e.z;
            let rr = e.radius + radius;
            if (cx * cx + cy * cy + cz * cz < rr * rr && t < bestT) {
                bestT = t;
                best = e;
            }
        }
    }
    // boss armor shells (not in the target list) block and ricochet shots
    let B = E.boss;
    if (B != null) {
        let parts = B.parts;
        for (let i = 1; i < parts.length; i++) {
            let e = parts[i];
            if (e.armored && e.maxHp >= 9999 && e.alive && !e.hidden) {
                let mx = e.x - ax, my = e.y - ay, mz = e.z - az;
                let t = 0.0;
                if (l2 > 0) t = lclamp((mx * dx + my * dy + mz * dz) / l2, 0, 1);
                let cx = ax + dx * t - e.x, cy = ay + dy * t - e.y, cz = az + dz * t - e.z;
                let rr = e.radius + radius;
                if (cx * cx + cy * cy + cz * cz < rr * rr && t < bestT) {
                    bestT = t;
                    best = e;
                }
            }
        }
    }
    return best;
}

// Update ---------------------------------------------------------------------------------------

function segHitsSphere(ax: f64, ay: f64, az: f64, bx: f64, by: f64, bz: f64, cx: f64, cy: f64, cz: f64, r: f64): bool {
    let dx = bx - ax, dy = by - ay, dz = bz - az;
    let l2 = dx * dx + dy * dy + dz * dz;
    let t = 0.0;
    if (l2 > 0) t = lclamp(((cx - ax) * dx + (cy - ay) * dy + (cz - az) * dz) / l2, 0, 1);
    let qx = ax + dx * t - cx, qy = ay + dy * t - cy, qz = az + dz * t - cz;
    return qx * qx + qy * qy + qz * qz < r * r;
}

// A shot lands on the pilot: practice orbs go to ctx.practiceHit (never
// shield; nothing without it), the rest to ctx.hurtPlayer.
const PRACTICE_RETURN: f64 = 220; // m/s, a deflected practice orb on its way home
function hitPlayer(ctx: Ctx, b: Bullet, amount: f64): void {
    if (b.practice) {
        if (ctx.practiceOn) ctx.practiceHit(amount, b.x, b.y, b.z);
        return;
    }
    ctx.hurtPlayer(amount, b.x, b.y, b.z);
}

// A hit point moved off the pilot's figure, as the core's offHero does: at
// least 1.8 m from him across the view from the lens (E.fx cam, set in
// update), 1.5 m past him: hit sparks never bloom over him. OH_X / Y / Z.
const UP: Vector = Vector.xyz(0, 1, 0);
let OH_X: f64 = 0, OH_Y: f64 = 0, OH_Z: f64 = 0;
function offHero(E: World, ctx: Ctx, x: f64, y: f64, z: f64): void {
    let P = ctx.player.pos;
    let F = E.fx;
    let f = mathx.norm(P - Vector.xyz(<f32>F.camX, <f32>F.camY, <f32>F.camZ));
    let R0 = mathx.norm(mathx.cross(f, UP));
    let U0 = mathx.cross(R0, f);
    let d = Vector.xyz(<f32>x, <f32>y, <f32>z) - P;
    let u = mathx.dot(d, R0), v = mathx.dot(d, U0);
    let l = Math.sqrt(u * u + v * v);
    if (l < 0.3) {
        u = 0;
        v = 1;
        l = 1;
    }
    let k = lmax(l, 1.8) / l;
    let q = P + R0 * <f32>(u * k) + U0 * <f32>(v * k) + f * <f32>1.5;
    OH_X = q.x;
    OH_Y = q.y;
    OH_Z = q.z;
}

function updateBullets(E: World, ctx: Ctx, dt: f64): void {
    let bl = E.bullets;
    let p = ctx.player.pos;
    let px: f64 = p.x, py: f64 = p.y, pz: f64 = p.z;
    let rolling = ctx.player.rolling;
    let F = E.fx;
    let i = 1;
    while (i <= bl.length - 1) {
        let b = bl[i];
        b.age += dt;
        b.life -= dt;
        let ox = b.x, oy = b.y, oz = b.z;
        if (b.kind == 3 && !b.deflected) {
            // homing rocket
            let dx = px - b.x, dy = py - b.y, dz = pz - b.z;
            let d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.01);
            let sp = Math.sqrt(b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
            let k = 1 - Math.exp(-b.fuse * dt);
            if (ai.ahead(ctx, b.x, b.y, b.z) > 8) {
                b.vx += (dx / d * sp - b.vx) * k;
                b.vy += (dy / d * sp - b.vy) * k;
                b.vz += (dz / d * sp - b.vz) * k;
            }
            // a pencil line of light ink
            if (lrandom() < 0.8) fx.wisp(F, b.x, b.y, b.z, 0.3, 0.75);
        }
        let src = b.src;
        if (b.deflected && src != null) {
            // a returned practice orb homes back on its lobber
            if (src.alive && !src.dead) {
                let dx = src.x - b.x, dy = src.y - b.y, dz = src.z - b.z;
                let d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.01);
                let k = 1 - Math.exp(-14 * dt);
                b.vx += (dx / d * PRACTICE_RETURN - b.vx) * k;
                b.vy += (dy / d * PRACTICE_RETURN - b.vy) * k;
                b.vz += (dz / d * PRACTICE_RETURN - b.vz) * k;
            } else {
                b.src = null;
            }
        }
        b.x += b.vx * dt;
        b.y += b.vy * dt;
        b.z += b.vz * dt;
        let remove = b.life <= 0;
        if (b.kind == 2 && !b.deflected) {
            b.fuse -= dt;
            if (b.fuse <= 0) {
                fx.explosion(F, b.x, b.y, b.z, 1.4, "air");
                ctx.sfx("explode_small", 0.3);
                let dx = px - b.x, dy = py - b.y, dz = pz - b.z;
                if (dx * dx + dy * dy + dz * dz < 5.5 * 5.5 && !rolling) hitPlayer(ctx, b, b.dmg);
                remove = true;
            }
        }
        if (!remove && !b.deflected) {
            let dx = px - b.x, dy = py - b.y, dz = pz - b.z;
            let d2 = dx * dx + dy * dy + dz * dz;
            if (rolling && d2 < 3.4 * 3.4) {
                // barrel roll deflection: send it back where it came from
                b.deflected = true;
                let sp = Math.sqrt(b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
                let f = ctx.player.fwd;
                let out = lmax(sp, 90);
                b.vx = <f64>f.x * out + (lrandom() - 0.5) * 12;
                b.vy = <f64>f.y * out + (lrandom() - 0.3) * 8;
                b.vz = <f64>f.z * out + (lrandom() - 0.5) * 12;
                b.r = 0.55;
                b.g = 0.95;
                b.b = 1;
                b.life = 1.6;
                b.dmg = 2;
                if (b.src != null) b.life = 3;
                ctx.deflect(b.x, b.y, b.z);
            } else if (segHitsSphere(ox, oy, oz, b.x, b.y, b.z, px, py, pz, 0.95 + b.size * 0.5)) {
                hitPlayer(ctx, b, b.dmg);
                offHero(E, ctx, b.x, b.y, b.z);
                fx.sparks(F, OH_X, OH_Y, OH_Z, 8, 1, 0.3, 0.55);
                remove = true;
            }
        } else if (!remove && b.deflected) {
            let e = raycast(E, ox, oy, oz, b.x, b.y, b.z, 0.6);
            if (e != null) {
                fx.sparks(F, b.x, b.y, b.z, 8, 0.6, 0.95, 1);
                damage(E, ctx, e, b.dmg);
                remove = true;
            }
        }
        if (!remove && b.age > 0.3 && ai.ahead(ctx, b.x, b.y, b.z) < -14) remove = true;
        if (!remove && b.y < 0) {
            if (b.kind == 1 || b.kind == 3) fx.explosion(F, b.x, 0.2, b.z, 0.35, "water");
            remove = true;
        }
        if (remove) {
            let n = bl.length - 1;
            bl[i] = bl[n];
            bl.pop();
            E.freeBullets.push(b);
        } else {
            i += 1;
        }
    }
}

export function update(E: World, ctx: Ctx, dt: f64): void {
    E.ctx = ctx;
    E.dt = dt;
    E.time = ctx.t;
    let pl = ctx.player;
    let fX: f64 = pl.fwd.x, fY: f64 = pl.fwd.y, fZ: f64 = pl.fwd.z;
    // player world velocity (for lead) and firing edge
    E.playerVx = fX * pl.speed + <f64>pl.right.x * pl.vx;
    E.playerVy = fY * pl.speed + pl.vy;
    E.playerVz = fZ * pl.speed + <f64>pl.right.z * pl.vx;
    let shots = ctx.stats.shotsFired;
    E.playerFiring = shots != E.lastShots;
    E.lastShots = shots;
    // lens for checks during the simulation: the core's rig as last updated
    // (a frame behind; kill cams included), else a chase-camera estimate (the
    // draw pass replaces it with this frame's eye)
    let F = E.fx;
    let p = pl.pos;
    let px: f64 = p.x, py: f64 = p.y, pz: f64 = p.z;
    if (ai.lens(E, ctx)) {
        F.camX = ai.LENS_2;
        F.camY = ai.LENS_3;
        F.camZ = ai.LENS_4;
    } else {
        F.camX = px - fX * 10.5;
        F.camY = py + 2.6;
        F.camZ = pz - fZ * 10.5;
    }

    let list = E.list;
    let i = 1;
    while (i <= list.length - 1) {
        let e = list[i];
        if (e.ai != "part") {
            e.t += dt;
            if (e.t < 0) {
                e.hidden = true;
            } else {
                e.hidden = false;
                if (e.dying > 0) {
                    patterns.updateWreck(e, E, ctx, dt);
                } else if (e.alive) {
                    patterns.update(e, E, ctx, dt);
                }
            }
            if (e.warp > 0) {
                e.warp = lmax(0, e.warp - dt * 1.4);
                if (e.warp > 0.9) fx.warp(E.fx, e.x, e.y, e.z, 0.7, 1, 0.45, 0.85);
            }
        }
        e.flash = lmax(0, e.flash - dt * 6);
        e.lockable = e.alive && !e.hidden && !e.armored && e.dying <= 0 && (!e.practice || e.y > 0.5)
            && patterns.passing(e, ctx) < 0.3;
        // damage smoke
        if (e.alive && !e.hidden && e.hp <= e.maxHp * 0.5 && e.maxHp > 1 && !e.part) {
            e.smokeT -= dt;
            if (e.smokeT <= 0) {
                e.smokeT = 0.07;
                // carried along (a craft pacing the pilot left its smoke
                // streaming back at the lens)
                fx.carry(E.fx, e.wvx, e.wvy, e.wvz);
                fx.smoke(E.fx, e.x, e.y, e.z, 0.8 * e.scale, 0.7);
                fx.carry(E.fx, 0, 0, 0);
            }
        }
        // enemy death by chain reaction / proximity detonation
        if (e.alive && e.hp <= 0) damage(E, ctx, e, 0.001);
        // body collision with the player: only a craft he has had clear ahead
        // of him
        if (e.alive && !e.hidden && !e.part && e.dying <= 0 && e.kind != "mine" && !e.practice) {
            let dx = px - e.x, dy = py - e.y, dz = pz - e.z;
            let rr = e.radius * 0.55 + 0.9;
            let d2 = dx * dx + dy * dy + dz * dz;
            if (!e.seen && d2 > rr * rr && ai.ahead(ctx, e.x, e.y, e.z) > 3) e.seen = true;
            if (e.seen && d2 < rr * rr) {
                ctx.hurtPlayer(e.kind == "kamikaze" ? 0.18 : 0.12, e.x, e.y, e.z);
                damage(E, ctx, e, 99);
            }
        }
        // far away cleanup
        if (!e.dead && !e.part) {
            let dx = e.x - px, dz = e.z - pz;
            if (dx * dx + dz * dz > 900 * 900 && e.t > 3) e.dead = true;
        }
        if (e.dead) {
            let g = e.group;
            if (e.alive && g != null) {
                g.escaped += 1;
                g.alive -= 1;
            }
            // its ribbons fade out on their own; the slots go back to the pool
            ai.trailRelease(E, e.trail);
            ai.trailRelease(E, e.trail2);
            e.trail = 0;
            e.trail2 = 0;
            e.seen = false;
            let n = list.length - 1;
            list[i] = list[n];
            list.pop();
        } else {
            i += 1;
        }
    }

    E.stingT = lmax(0, E.stingT - dt);
    E.focusOn = false;
    let b = E.boss;
    if (b != null) {
        if (b.kind == "stormcrow") {
            crow.update(b, E, ctx, dt);
        } else {
            eye.update(b, E, ctx, dt);
        }
        if (b.done) {
            // drop remaining parts
            let j = 1;
            while (j <= list.length - 1) {
                if (list[j].part) {
                    list[j] = list[list.length - 1];
                    list.pop();
                } else {
                    j += 1;
                }
            }
            E.boss = null;
        }
    }
    // the chase-camera mirror runs while a boss is up (after its ctx.focus,
    // as the core's camera runs after us)
    if (E.boss != null) {
        ai.camTick(E, ctx, dt);
    } else {
        E.cam.on = false;
    }

    updateBullets(E, ctx, dt);
}

// The core stops simulating once the finale (outro) starts. A boss still on
// the field then is finished off at once: final blast if it was dying, the
// bar cleared, nothing left frozen.
function bossFinish(E: World, ctx: Ctx): void {
    let b = E.boss;
    if (b == null) return;
    if (b.killed) {
        // (the kill was counted, paid and announced when it happened)
        if (b.v.boomT > -10) fx.explosion(E.fx, b.xf.px, b.xf.py, b.xf.pz, 4, "huge");
    } else if (!b.escaped) {
        ctx.boss(false, b.name, 0.05);
    }
    ctx.holdSpeed(NaN);
    let list = E.list;
    let j = 1;
    while (j <= list.length - 1) {
        if (list[j].part) {
            list[j] = list[list.length - 1];
            list.pop();
        } else {
            j += 1;
        }
    }
    E.boss = null;
    if (ai.LOG) console.log(format("BOSS %s finished by the finale at s=%.0f", [FormatArg.string(b.kind), N(ctx.railS)]));
}

// Draw -------------------------------------------------------------------------------------------

function drawBullets(E: World, r: R.Gfx, t: f64): void {
    let mo = E.models;
    let F = E.fx;
    let ex = F.camX, ey = F.camY, ez = F.camZ;
    let bl = E.bullets;
    for (let i = 1; i < bl.length; i++) {
        let b = bl[i];
        let k = b.kind;
        // keep shots that graze the lens from filling the screen
        let dx = b.x - ex, dy = b.y - ey, dz = b.z - ez;
        let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
        let lim = d * 0.035;
        let fade = mathx.saturate((d - 3) / 6);
        if (fade > 0) {
            if (k == 0 && !b.deflected) {
                // hostile tracer: a hot crimson-magenta slug in a dark ink rim
                // over a dim magenta halo; a size floor keeps distant fire
                // readable
                let s = lmax(lmin(b.size * 0.72, lim * 0.5), d * 0.005);
                R.particle(r, b.x, b.y, b.z, s * 2.3, HOT_R, HOT_G, HOT_B, 0.4 * fade, 1, 0.3, 0.1, 0);
                R.particle(r, b.x, b.y, b.z, s, INK_R, INK_G, INK_B, fade, 3, 0.3, 0.2, 0, b.vx, b.vy, b.vz, 0.75);
                R.particle(r, b.x, b.y, b.z, s * 0.62, HOT_R, HOT_G, HOT_B, fade, 3, 0.3, 0.2, 0, b.vx, b.vy, b.vz, 1.15);
            } else if (k == 0) {
                // (rolled back at them: ours now, a cyan bolt)
                let s1 = lmax(lmin(b.size * 1.5, lim), d * 0.008);
                R.particle(r, b.x, b.y, b.z, s1, b.r, b.g, b.b, fade, 1, 0.3, 0.1, 0, b.vx, b.vy, b.vz, 0.55);
                R.particle(r, b.x, b.y, b.z, lmin(b.size * 0.55, lim * 0.4), 1, 0.95, 0.75, fade, 3, 0.3, 0.2, 0, b.vx, b.vy, b.vz, 0.5);
            } else if (k == 1) {
                // hostile orb: a dark ink-red shell with a hot centre in a warm halo
                let pulse = 1 + 0.18 * Math.sin(b.age * 22);
                let s1 = lmax(lmin(b.size * 2.1 * pulse, lim * 1.4), d * 0.011);
                R.particle(r, b.x, b.y, b.z, s1, b.r, b.g * 0.6, b.b * 0.6, 0.6 * fade, 1, 0.3, 0.3, 0);
                R.particle(r, b.x, b.y, b.z, s1 * 0.46, b.r * 0.5, b.g * 0.1, b.b * 0.25, fade, 3, 0.3, 0.4, 0);
                R.particle(r, b.x, b.y, b.z, s1 * 0.62, 0.86, 0.14, 0.38, 0.45 * fade, 2, 0.5, 0.5, b.age * 4);
            } else if (k == 2) {
                R.particle(r, b.x, b.y, b.z, lmin(0.32, lim), 0.16, 0.15, 0.2, fade, 3, 0.3, 0.6, 0);
                R.particle(r, b.x, b.y, b.z, lmin(0.9, lim * 2), 1, 0.5, 0.2, 0.7 * fade, 1, 0.3, 0.7, 0);
            } else if (mo != null) {
                let x = E.xf3;
                models.aim(x, b.x, b.y, b.z, b.vx, b.vy, b.vz, 0, 1, 0, b.age * 8, 1.3);
                models.put(mo.rocket, x, 1, 1, 1, 0, 0, 0);
                models.point(x, 0, 0, 0.8);
                R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, lmin(0.9, lim * 2), 1, 0.6, 0.2, fade, 1, 0.3, 0.8, 0);
            }
        }
    }
}

export function draw(E: World, r: R.Gfx): void {
    let mo = E.models;
    if (mo == null) return;
    models.reset(mo);
    let t = clock();
    let ctx = E.ctx;
    if (ctx != null) t = ctx.t;
    ai.eye(E, r);
    let ex = ai.EYE_1, ey = ai.EYE_2, ez = ai.EYE_3;
    // kill cam on a falling boss (its down_* sting): fx thin out in front of
    // it (fx.Fx.shotNear)
    let bk = E.boss;
    if (ctx != null && bk != null && bk.killed && E.focusOn && ctx.stingActive()) {
        let dx = E.focusX - ex, dy = E.focusY - ey, dz = E.focusZ - ez;
        let side = Math.sqrt(dx * dx + dy * dy + dz * dz) - E.focusR;
        if (side > 20) E.fx.shotNear = side;
    }
    // portrait: bosses stand off further so their width fits the screen
    let aspect = r.ptW / lmax(r.ptH, 1);
    E.far = 1 + 0.3 * mathx.saturate((1 - aspect) / 0.45);
    E.cam.aspect = aspect;
    let list = E.list;
    for (let i = 1; i < list.length; i++) {
        let e = list[i];
        if (!e.hidden && !e.part && e.y > -3) {
            let dx = e.x - ex, dy = e.y - ey, dz = e.z - ez;
            if (dx * dx + dy * dy + dz * dz < 1100 * 1100) patterns.draw(e, E, mo, r, t);
        }
    }
    if (ctx != null && E.boss != null && ctx.state == "outro") bossFinish(E, ctx);
    let b = E.boss;
    if (b != null) {
        if (b.kind == "stormcrow") {
            crow.draw(b, E, mo, r, t);
        } else {
            eye.draw(b, E, mo, r, t);
        }
    }
    drawBullets(E, r, t);
    ai.trailsDraw(E, r);
    let all = mo.all;
    for (let i = 1; i < all.length; i++) {
        let bt = all[i];
        if (bt !== mo.debris) R.addBatch(r, bt);
    }
}
