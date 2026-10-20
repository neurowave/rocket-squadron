// Port of src/game/boss_eye.luau. THE WATCHER: the clockwork eye guarding THE EYE portal.
// Rise: the pool boils, then it breaches. Phase 1 LENSES: armored lids closed,
// six lens pods orbit on the gear ring and fire in turn, then glow together
// and fire one aimed volley. Phase 2 IRIS: the lids open, the eye tracks the
// player, fires orb rings and a telegraphed sweeping beam, stares, then blinks
// (armored) and opens again; at half health it rages. The pupil only takes
// damage with the lids open and holds out at least IRIS_MIN seconds, so the
// beam always shows at least twice. Barrel rolls shrug off the beam. The
// lids only open once the pupil is in frame under the HUD's boss stack
// (ai.screen: ctx.project).
// DIRECTION #21: THE WATCHER sting plays once it has risen (after the
// warning), the DOWNED sting and kill cam when the pupil goes. The camera
// frames it by the ctx.focus point (the core's chase camera rides that point
// in the upper frame, under the HUD's boss stack): the pupil in the iris.
// OWNER: enemies & events agent.
//
// Port: the ai.LOG prints are not ported. ctx.holdSpeed / sting always exist
// (types.Ctx), so the DOWNED sting always takes (no banner fallback).
import { format, FormatArg } from "rive/format";
import { Ctx } from "./types";
import * as ai from "./ai_types";
import { Boss, BossV, World, Enemy } from "./ai_types";
import * as fx from "./fx";
import * as models from "./models";
import { Models } from "./models";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import { HUGE, lmin, lmax, mod, lrandom } from "../lib/compat";

const NAME = "THE WATCHER";
const LENSES: i32 = 6;
const RING_R: f64 = 8.2;
const SCALE: f64 = 2.1;
// Hover height (m over the pilot's rail base): in the lenses it stands back
// (LENS_S) so the tall lens ring fits the frame, the ring clear of the water;
// in the iris it closes in, the pupil just over the pilot's line of fire, its
// gear ring cutting the pool. The camera focus (see the end of update) sits
// LENS_FOCUS m over the centre in the lenses (the ring rides lower in frame)
// and on the pupil in the iris.
const HOVER_Y: f64 = 18.5;
const LENS_S: f64 = 118;
const LENS_FOCUS: f64 = 9;
const IRIS_ABOVE: f64 = 3;
// screen height (v, 0 top) the pupil must stay under: the HUD boss stack
// (shield tab, name bar, phase chip) ends ~0.26 of a landscape screen
const IRIS_TOP_V: f64 = 0.32;
// the lids open only once the pupil has been under IRIS_TOP_V this long (a
// pilot diving out of the lenses leaves the chase eye above him, looking
// down: the pupil rides over the top of the frame for ~1 s); they give up
// waiting after IRIS_WAIT s (the first opening) / IRIS_WAIT2 (after a blink)
const IRIS_SETTLE: f64 = 0.2;
// the guard's sink: m/s, and how far under the pilot's height it may go
const SINK: f64 = 16;
const SINK_UNDER: f64 = 1;
const IRIS_WAIT: f64 = 3.0;
const IRIS_WAIT2: f64 = 1.2;

// Tuning knob (1 = shipped balance).
const HP_MULT: f64 = 1;
// pilot cruise cap (m/s): lenses, iris, death
const HOLD: f64 = 36;
const HOLD_IRIS: f64 = 30;
const HOLD_DEATH: f64 = 40;
// rise: seconds the pool boils, then seconds it takes to rise; the sting
// plays STING_AT into it (once the warning has cleared the alert slot)
const BOIL: f64 = 2.0;
const RISE: f64 = 3.0;
const STING_AT: f64 = 4.1;
// radius (m) that frames all of it (gear ring included)
const FRAME_R: f64 = 24;
// lenses: seconds between the synchronized volleys, and their telegraph
const VOLLEY_GAP: f64 = 3.4;
const LENS_TELE: f64 = 0.8;
// iris: minimum length (s), beam telegraph and sweep, stare after it, blink
const IRIS_MIN: f64 = 12;
const BEAM_TELE: f64 = 1.2;
const FIRST_BEAM: f64 = 2.8;
const BEAM_FIRE: f64 = 1.8;
const STARE: f64 = 0.9;
const BLINK: f64 = 1.4;
const CORE_HP: f64 = 40;
// death: seconds (at rate 1) to the final blast; the retreat after an escape
const DEATH_BLAST: f64 = 3.2;
const RETREAT: f64 = 2.2;
// the Baron calls the retreat this long (s at the pilot's speed) before it
// gives up, so the wingmen's closing call is over before the finale
const CALL_LEAD: f64 = 3.6;

function part(W: World, kind: string, hp: f64, radius: f64, score: f64, armored: bool): Enemy {
    let e = ai.enemy(kind, "part", hp >= 9999 ? hp : lmax(0.1, hp * HP_MULT), radius, score);
    e.part = true;
    e.armored = armored;
    e.lockable = !armored;
    e.hidden = true;
    if (hp < 9999) {
        W.list.push(e);
    }
    return e;
}

function newV(): BossV {
    let v = new BossV();
    v.open = 0;
    v.ringA = 0;
    v.ringB = 0;
    v.fireT = 2.5;
    v.lensIdx = 0;
    v.beamT = 5;
    v.beamState = 0;
    v.bdx = 0;
    v.bdy = 0;
    v.bdz = -1;
    v.spiralT = 3;
    v.droneT = 6;
    v.deathT = 0;
    v.boomT = 0;
    v.rage = 0;
    v.volleyT = 3;
    v.stillT = 0;
    v.iris = 0;
    v.irisT = 0;
    v.beamN = 0;
    v.breach = 0;
    v.deathRate = 1;
    v.beamY = 6;
    v.beamSgn = 1;
    v.beamDur = 1;
    v.beamDone = 0;
    v.stareT = 0;
    v.beamRolled = 0;
    v.callout = 0;
    v.stung = 0;
    v.barT = -1;
    v.cracked = 0;
    v.onT = 0;
    v.inView = 0;
    v.leaving = 0;
    v.stripRoll = 0;
    return v;
}

export function spawn(W: World, ctx: Ctx, sEnd: f64): Boss {
    let B = new Boss();
    B.kind = "eye";
    B.name = NAME;
    B.phase = 0;
    B.t = 0;
    B.phaseT = 0;
    B.s = 420;
    B.x = 0;
    B.y = -30;
    B.hpTotal = 0;
    B.v = newV();
    B.sEnd = sEnd;
    for (let i = 1; i <= LENSES; i++) {
        B.parts.push(part(W, "eyeLens", 3, 2.0 * SCALE, 300, false));
    }
    B.parts.push(part(W, "eyeCore", CORE_HP, 3.8 * SCALE, 3000, true));
    B.parts.push(part(W, "eyeArmor", 9999, 6.2 * SCALE, 0, true));
    for (let i = 1; i <= LENSES + 1; i++) {
        B.hpTotal += B.parts[i].maxHp;
    }
    ctx.stats.killsTotal += 1;
    ctx.holdSpeed(HOLD);
    return B;
}

@inline function lens(B: Boss, i: i32): Enemy {
    return B.parts[i];
}
@inline function core(B: Boss): Enemy {
    return B.parts[LENSES + 1];
}
@inline function armor(B: Boss): Enemy {
    return B.parts[LENSES + 2];
}

function health(B: Boss): f64 {
    let h = 0.0;
    for (let i = 1; i <= LENSES + 1; i++) {
        let e = B.parts[i];
        if (e.alive) {
            h += lmax(e.hp, 0);
        }
    }
    return h / B.hpTotal;
}

function orbRing(B: Boss, W: World, ctx: Ctx, n: f64, speed: f64, twist: f64): void {
    let x = B.xf;
    models.point(x, 0, 0, -7);
    let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
    let dx = ai.aimAtPlayer(W, ctx, ox, oy, oz, speed, 0), dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
    let rt = ctx.player.right;
    let rx = <f64>rt.x, rz = <f64>rt.z;
    for (let k = 0.0; k <= n - 1; k++) {
        let a = k / n * mathx.TAU + twist;
        let cx = Math.cos(a) * 0.22, cy = Math.sin(a) * 0.22;
        let vx = dx + rx * cx;
        let vy = dy + cy;
        let vz = dz + rz * cx;
        let l = Math.sqrt(vx * vx + vy * vy + vz * vz);
        ai.bullet(W, 1, ox, oy, oz, vx / l * speed, vy / l * speed, vz / l * speed, 0.09, 5, 0.8, 1, 0.3, 0.75, 0);
    }
    fx.ring(W.fx, ox, oy, oz, 3, 30, 1, 0.5, 0.85, 0.35);
}

// v: NaN releases the cap (Luau nil)
function holdSpeed(ctx: Ctx, v: f64): void {
    ctx.holdSpeed(v);
}

function setPhase(B: Boss, W: World, ctx: Ctx, ph: f64): void {
    B.phase = ph;
    B.phaseT = 0;
    if (ph == 1) {
        holdSpeed(ctx, HOLD);
    } else if (ph == 2) {
        holdSpeed(ctx, HOLD_IRIS);
    }
    let v = B.v;
    if (ph == 1) {
        for (let i = 1; i <= LENSES; i++) {
            lens(B, i).hidden = false;
        }
        core(B).hidden = false;
        armor(B).hidden = false;
        v.fireT = 1.2;
        v.volleyT = 2.6;
        ai.say(W, "vi", "That thing is LOOKING at us. Pop the lenses on the ring!", 3.2, 3, "worried");
    } else if (ph == 2) {
        // the lids crack open; the pupil only takes damage while they are open
        // (the pupil call and its lines go out as the lids crack: update)
        v.iris = 0;
        v.irisT = 0;
        v.beamState = 0;
        v.beamN = 0;
        v.cracked = 0;
        v.onT = 0;
        v.inView = 0;
    }
}

// The job on the strip under the bar (Hud.bossPhase): HIT THE PUPIL as the
// lids first open and again as each sweep ends, ROLL! as each beam charges
// (startBeam).
function irisCall(W: World): void {
    ai.banner(W, "HIT THE PUPIL", "WHEN THE LIDS OPEN", "warning", 3, 2);
}

// The lids crack for the first time: the pupil call and the tower's ROLL
// (the Baron's taunt waits for the first sweep's end: it held the radio
// through that sweep).
function crack(B: Boss, W: World, ctx: Ctx): void {
    B.v.cracked = 1;
    irisCall(W);
    ctx.sfx("warning", 0.8);
    ai.say(W, "tower", "It's opening up! Hit the pupil - and ROLL through that beam!", 3.4, 3, "shout");
}

function world(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let pos = ctx.railFrame(ctx.railS + ai.bossS(W, B));
    let f = ctx.rfFwd, rt = ctx.rfRight;
    let px = <f64>pos.x + <f64>rt.x * B.x;
    // height mostly off the pilot's rail base: on the final climb the rail
    // ahead rises ~15 m, which would lift the pupil under the boss bar
    let base = ctx.railFrame(ctx.railS);
    let py = mathx.lerp(<f64>pos.y, <f64>base.y, 0.8) + B.y;
    let pz = <f64>pos.z + <f64>rt.z * B.x;
    // look at the player (smoothed); before the fight it stares down the rail
    let tx = -<f64>f.x, ty = -<f64>f.y, tz = -<f64>f.z;
    if (B.phase >= 1 && B.phase <= 2) {
        let p = ctx.player.pos;
        let dx = <f64>p.x - px, dy = <f64>p.y - py, dz = <f64>p.z - pz;
        let l = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.01);
        let w = B.phase == 2 ? 1 : 0.45;
        tx = mathx.lerp(tx, dx / l, w);
        ty = mathx.lerp(ty, dy / l, w);
        tz = mathx.lerp(tz, dz / l, w);
    } else if (B.phase == 3) {
        tx = -<f64>f.x * 0.4;
        ty = -0.9;
        tz = -<f64>f.z * 0.4;
    }
    let k = 1 - Math.exp(-(B.phase == 2 ? 3.0 : 1.5) * dt);
    let x = B.xf;
    let hx = x.fx + (tx - x.fx) * k;
    let hy = x.fy + (ty - x.fy) * k;
    let hz = x.fz + (tz - x.fz) * k;
    models.aim(x, px, py, pz, hx, hy, hz, 0, 1, 0, B.roll, SCALE);
}

function placeParts(B: Boss): void {
    let x = B.xf;
    let v = B.v;
    for (let i = 1; i <= LENSES; i++) {
        let e = lens(B, i);
        let a = <f64>(i - 1) / <f64>LENSES * mathx.TAU + v.ringA;
        models.point(x, Math.cos(a) * RING_R, Math.sin(a) * RING_R, -0.6);
        e.x = models.POINT_X;
        e.y = models.POINT_Y;
        e.z = models.POINT_Z;
    }
    let c = core(B);
    models.point(x, 0, 0, -5.2);
    c.x = models.POINT_X;
    c.y = models.POINT_Y;
    c.z = models.POINT_Z;
    let ar = armor(B);
    models.point(x, 0, 0, 0);
    ar.x = models.POINT_X;
    ar.y = models.POINT_Y;
    ar.z = models.POINT_Z;
}

// Hover height for the phase (it follows the pilot's height).
function hoverY(ctx: Ctx, ph: f64): f64 {
    let py = ctx.player.y;
    if (ph == 2) {
        return mathx.clamp(py + IRIS_ABOVE, 6, 24);
    }
    // (a climbing pilot sees the tall ring slide down the frame)
    return mathx.clamp(HOVER_Y + (py - 8) * 0.15, 17.5, 22);
}

// Spray where the gear ring cuts the pool (the iris hovers low).
function ringSpray(B: Boss, W: World): void {
    let x = B.xf;
    let sc = x.s;
    if (x.uy < 0.5 || sc <= 0) {
        return;
    }
    let r = 9.9;
    let ly = -x.py / (sc * x.uy);
    if (Math.abs(ly) >= r * 0.97) {
        return;
    }
    let lx = Math.sqrt(r * r - ly * ly);
    for (let side = -1.0; side <= 1; side += 2) {
        if (lrandom() < 0.2) {
            models.point(x, side * lx, ly, 0);
            let wx = models.POINT_X, wz = models.POINT_Z;
            let sx = wx + (lrandom() - 0.5) * 2;
            let sz = wz + (lrandom() - 0.5) * 2;
            fx.splash(W.fx, sx, sz, 0.7 + lrandom() * 0.7);
        }
    }
}

// Rail distance by which the final blast must have happened: 90 m past the
// escape line (sEnd = EYE_S - 300), so WATCHER DESTROYED plays before the
// finale starts at EYE_S - 70.
function blastLine(B: Boss): f64 {
    return B.sEnd + 90;
}

// Death animation rate so the final blast lands by the blast line at the
// pilot's actual speed (a boost surges to the cap + 25).
function deathRate(B: Boss, ctx: Ctx, left: f64): f64 {
    let pl = ctx.player;
    let sp = lmax(lmax(pl.speed, pl.boosting ? HOLD_DEATH + 25 : HOLD_DEATH), 1);
    let room = (blastLine(B) - ctx.railS) / sp;
    if (room <= 0.05) {
        return HUGE;
    }
    return lmax(1, left / room);
}

// The telegraphed sweeping beam: 0 idle -> 1 telegraph -> 2 firing. It sweeps
// a horizontal line across the whole flight box at the height the pilot was
// flying when it started charging (dotted guide on screen), so it reads as a
// ray crossing the screen and can be dodged by changing height or rolling.
// Enraged, it sweeps back again and drifts toward the pilot's height.
const SWEEP_X: f64 = 34;

function beamAim(B: Boss, ctx: Ctx, u: f64): void {
    let v = B.v;
    let x = mathx.lerp(-v.beamSgn * SWEEP_X, v.beamSgn * SWEEP_X, u);
    let tp = ctx.toWorld(ctx.railS + 2, x, v.beamY);
    models.point(B.xf, 0, 0, -6.2);
    v.bdx = <f64>tp.x - models.POINT_X;
    v.bdy = <f64>tp.y - models.POINT_Y;
    v.bdz = <f64>tp.z - models.POINT_Z;
}

// Sweep progress 0..1 (and back to 0 on an enraged return pass).
function sweepU(B: Boss): f64 {
    let v = B.v;
    let k = mathx.saturate(1 - v.beamT / v.beamDur);
    if (v.rage > 0) {
        let w = k < 0.5 ? k * 2 : (1 - k) * 2;
        return mathx.easeInOutCubic(w);
    }
    return mathx.easeInOutCubic(k);
}

function beam(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let v = B.v;
    if (v.beamState == 1) {
        v.beamT -= dt;
        beamAim(B, ctx, 0);
        if (v.beamT <= 0) {
            v.beamState = 2;
            v.beamDur = v.rage > 0 ? BEAM_FIRE * 1.7 : BEAM_FIRE;
            v.beamT = v.beamDur;
            ctx.sfx("nova", 0.8);
            ctx.shake(0.4);
        }
        return;
    }
    if (v.beamState != 2) {
        return;
    }
    v.beamT -= dt;
    if (v.rage > 0) {
        v.beamY = mathx.damp(v.beamY, ctx.player.y, 0.7, dt);
    }
    beamAim(B, ctx, sweepU(B));
    // hit test: distance from the player to the beam ray
    models.point(B.xf, 0, 0, -6.2);
    let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
    let l = lmax(Math.sqrt(v.bdx * v.bdx + v.bdy * v.bdy + v.bdz * v.bdz), 1e-4);
    let bx = v.bdx / l, by = v.bdy / l, bz = v.bdz / l;
    let p = ctx.player.pos;
    let pxx = <f64>p.x, pyy = <f64>p.y, pzz = <f64>p.z;
    let qx = pxx - ox, qy = pyy - oy, qz = pzz - oz;
    let along = qx * bx + qy * by + qz * bz;
    if (along > 0) {
        let cx = qx - bx * along, cy = qy - by * along, cz = qz - bz * along;
        if (cx * cx + cy * cy + cz * cz < 2.6 * 2.6) {
            // a roll shrugs the ray off: one deflect per pass, not per frame
            // (unrolled contact is paced by the core's hit invulnerability)
            if (!ctx.player.rolling) {
                ctx.hurtPlayer(0.12, pxx, pyy, pzz);
            } else if (v.beamRolled == 0) {
                v.beamRolled = 1;
                ctx.hurtPlayer(0.12, pxx, pyy, pzz);
            }
        }
    }
    if (v.beamT <= 0) {
        v.beamState = 0;
    }
}

function startBeam(B: Boss, W: World, ctx: Ctx, rageK: f64): void {
    let v = B.v;
    v.beamState = 1;
    v.beamT = BEAM_TELE / Math.sqrt(rageK);
    v.beamRolled = 0;
    v.beamN += 1;
    v.beamSgn = mod(v.beamN, 2) == 0 ? -1.0 : 1.0;
    v.beamY = mathx.clamp(ctx.player.y, 2.5, 24);
    beamAim(B, ctx, 0);
    ctx.sfx("charge", 0.8);
    // the ROLL prompt pops on the strip for the charge and most of the sweep
    v.stripRoll = 1;
    ai.banner(W, "ROLL!", "THROUGH THE BEAM", "warning", 3, 2);
}

export function update(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    B.t += dt;
    B.phaseT += dt;
    let v = B.v;
    let t = B.t;
    let ph = B.phase;

    if (!B.killed && !B.escaped && v.leaving == 0 && ctx.railS > B.sEnd - CALL_LEAD * lmax(ctx.player.speed, HOLD_IRIS)) {
        // last chance: the fight goes on to sEnd; its waiting phase lines
        // drop (events bossComms)
        v.leaving = 1;
        ai.say(W, "baron", "Retreat, my pet! The Eye will have him yet!", 2.8, 4, "angry", true);
    }
    if (!B.killed && !B.escaped && ctx.railS > B.sEnd) {
        // it gives up: lids shut, it pulls back into the Eye and the bar goes
        // (the wingmen's closing call goes out now)
        B.escaped = true;
        B.phase = 5;
        B.phaseT = 0;
        ph = 5;
        v.beamState = 0;
        let ps = B.parts;
        for (let i = 1; i < ps.length; i++) {
            ps[i].hidden = true;
        }
        holdSpeed(ctx, NaN);
        // the bar goes at once so the escape slab gets the centre slot
        ctx.boss(false, NAME, lmax(health(B), 0.05));
        ai.banner(W, "THE WATCHER ESCAPED", "FOLLOW IT INTO THE EYE", "warning", 3);
    }

    let rageK = 1 + v.rage * 0.6;
    v.ringA += dt * (0.22 + v.rage * 0.4 + (v.iris == 2 ? 1.2 : 0));
    v.ringB += dt * (0.6 + v.rage * 0.6 + (v.iris == 2 ? 2.4 : 0));

    if (ph == 0) {
        // the pool boils, then it breaches and rises, dripping
        let u = mathx.saturate((B.phaseT - BOIL) / RISE);
        let e = mathx.easeOutCubic(u);
        B.s = mathx.lerp(240, LENS_S, e);
        B.y = mathx.lerp(-24, hoverY(ctx, 1), mathx.easeInOutCubic(u));
        B.roll = Math.sin(t * 0.8) * 0.05;
        let pos = ctx.railFrame(ctx.railS + ai.bossS(W, B));
        let rt = ctx.rfRight;
        let ex = <f64>pos.x + <f64>rt.x * B.x, ez = <f64>pos.z + <f64>rt.z * B.x;
        if (B.phaseT < BOIL + 0.4) {
            // boiling water where it will surface
            if (lrandom() < 0.35) {
                let a = lrandom() * mathx.TAU;
                let rr = lrandom() * 16;
                fx.splash(W.fx, ex + Math.cos(a) * rr, ez + Math.sin(a) * rr, 0.7 + lrandom() * 0.6);
            }
            if (lrandom() < 0.08) {
                fx.ring(W.fx, ex, 0.3, ez, 4, 30, 0.9, 0.97, 1, 0.7);
                ctx.shake(0.15);
            }
        } else if (v.breach == 0) {
            v.breach = 1;
            fx.splash(W.fx, ex, ez, 3.2);
            fx.waterRing(W.fx, ex, ez, 3);
            fx.ring(W.fx, ex, 0.4, ez, 6, 60, 1, 1, 1, 0.8);
            ctx.sfx("explode_big", 0.6);
            ctx.shake(0.6);
        }
        if (B.y > -10 && B.y < 8 && lrandom() < 0.3) {
            let a = lrandom() * mathx.TAU;
            fx.splash(W.fx, ex + Math.cos(a) * 12, ez + Math.sin(a) * 12, 1.6);
        }
        // THE WATCHER poster once it towers over the pool (after the
        // warning); the phase-1 callout queues behind it (the mission
        // script holds alerts through a sting; dropped if the lenses are
        // gone by then)
        if (v.stung == 0 && B.phaseT >= STING_AT && (ctx.alertFree() || B.phaseT > STING_AT + 1.2)) {
            v.stung = 1;
            ai.focus(W, ctx, B.xf.px, B.xf.py, B.xf.pz, 0.7);
            let took = ai.sting(W, ctx, "boss_watcher", NAME, "KESSEL'S CLOCKWORK SENTINEL", B.xf.px, B.xf.py, B.xf.pz, FRAME_R);
            v.barT = B.phaseT + (took ? 0.5 : 0);
            ai.banner(W, "LENSES", "SHOOT THE LENSES", "warning", 3, 1);
        }
        if (B.phaseT > BOIL + RISE && v.stung == 1) {
            setPhase(B, W, ctx, 1);
        }
    } else if (ph == 1) {
        B.s = mathx.damp(B.s, LENS_S + Math.sin(t * 0.5) * 5, 1.5, dt);
        B.x = mathx.damp(B.x, Math.sin(t * 0.4) * 6, 1, dt);
        B.y = mathx.damp(B.y, hoverY(ctx, 1) + Math.sin(t * 0.8) * 2, 1, dt);
        // lenses take turns...
        v.fireT -= dt;
        if (v.fireT <= 0 && v.volleyT > LENS_TELE) {
            v.fireT = 0.7;
            for (let k = 1; k <= LENSES; k++) {
                v.lensIdx = mod(v.lensIdx, <f64>LENSES) + 1;
                let e = lens(B, <i32>v.lensIdx);
                if (e.alive) {
                    ai.orb(W, ctx, e.x, e.y, e.z, 34, 4, 0.45, 0.95, 1);
                    ctx.sfx("laser", 0.25);
                    break;
                }
            }
        }
        // ...then glow together and fire one aimed volley (a pilot who sits
        // still in the middle gets it square)
        let pl = ctx.player;
        let still = Math.abs(pl.vx) < 3 && Math.abs(pl.vy) < 2.5;
        v.stillT = still ? v.stillT + dt : 0;
        let was = v.volleyT;
        v.volleyT -= dt;
        if (was > LENS_TELE && v.volleyT <= LENS_TELE) {
            ctx.sfx("charge", 0.5);
        }
        if (v.volleyT <= 0) {
            v.volleyT = VOLLEY_GAP;
            let scatter = v.stillT > 1.2 ? 0 : 1.2;
            for (let i = 1; i <= LENSES; i++) {
                let e = lens(B, i);
                if (e.alive) {
                    ai.orb(W, ctx, e.x, e.y, e.z, 44, scatter, 0.45, 0.95, 1);
                }
            }
            ctx.sfx("laser", 0.5);
        }
        v.droneT -= dt;
        if (v.droneT <= 0) {
            v.droneT = 7;
            for (let side = -1.0; side <= 1; side += 2) {
                let d = ai.enemy("kamikaze", "kamikaze", 1, 2.8, 120);
                d.s = ai.bossS(W, B) + 10;
                d.rx = B.x + side * 14;
                d.ry = B.y + 12;
                d.p1 = ai.bossS(W, B) - 20;
                d.p3 = B.y + 6;
                d.p4 = 1.2 + (side + 1) * 0.3;
                W.list.push(d);
                ctx.stats.killsTotal += 1;
            }
        }
        let alive = 0;
        for (let i = 1; i <= LENSES; i++) {
            if (lens(B, i).alive) {
                alive += 1;
            }
        }
        if (alive == 0 && B.phaseT > 0.5) {
            setPhase(B, W, ctx, 2);
        }
    } else if (ph == 2) {
        B.s = mathx.damp(B.s, 78 + Math.sin(t * 0.6) * 5, 1.2, dt);
        B.x = mathx.damp(B.x, Math.sin(t * 0.5) * 7, 0.8, dt);
        // it tracks the pilot's height closely (a pilot who dives away from
        // the beam must not leave the pupil stranded at the top of the frame)
        let py = ctx.player.y;
        B.y = mathx.clamp(mathx.damp(B.y, hoverY(ctx, 2) + Math.sin(t * 0.9) * 1.5, 1.6, dt), py - 1, py + IRIS_ABOVE + 4);
        // guard: a diving pilot leaves the chase camera above him looking
        // down, which lifts the pupil under the HUD's boss stack; it sinks
        // at once then (screen height from ctx.project: ai.screen)
        let c0 = core(B);
        ai.screen(W, ctx, c0.x, c0.y, c0.z);
        let pv = ai.SCREEN_2, pd = ai.SCREEN_3;
        let high = pd > 0 && pv < IRIS_TOP_V;
        if (high) {
            B.y = lmax(lmax(B.y - dt * SINK, py - SINK_UNDER), 4);
        }
        if (B.xf.py < 30) {
            ringSpray(B, W);
        }
        let c = core(B);
        if (c.hp < c.maxHp * 0.5 && v.rage == 0) {
            v.rage = 1;
            ai.say(W, "hank", "It's mad now! Keep rolling, kid!", 2.4, 2, "worried");
            ctx.sfx("warning", 0.6);
        }
        // lids: 0 opening -> 1 open (orb rings, the beam) -> 2 blink (armored)
        v.irisT += dt;
        if (v.cracked == 1) {
            v.onT += dt;
        }
        if (v.iris == 0) {
            // they wait, shut, until the pupil is in frame (under the boss
            // stack); the first time, the pupil call goes out as they crack
            v.inView = high ? 0 : v.inView + dt;
            let go = v.inView >= IRIS_SETTLE || v.irisT > (v.cracked == 0 ? IRIS_WAIT : IRIS_WAIT2);
            if (go && v.cracked == 0) {
                crack(B, W, ctx);
            }
            v.open = mathx.damp(v.open, go ? 1 : 0.06, go ? 3 : 7, dt);
            if (v.open > 0.6) {
                v.iris = 1;
                v.irisT = 0;
                v.beamDone = 0;
                v.stareT = 0;
                v.spiralT = 0.8;
                // the first window waits out the IRIS slab so the beam is seen
                v.beamT = v.beamN == 0 ? FIRST_BEAM : 1.5;
            }
        } else if (v.iris == 1) {
            v.open = mathx.damp(v.open, 1, 3, dt);
            // orb rings
            v.spiralT -= dt;
            if (v.spiralT <= 0 && v.beamState == 0) {
                v.spiralT = 2.6 / rageK;
                orbRing(B, W, ctx, 8 + Math.floor(v.rage * 4), 30, t);
                ctx.sfx("laser", 0.35);
            }
            // one beam per open window; none its escape would cut off (the
            // retreat called, or not over by sEnd: its ROLL! popped, then the
            // escape dropped the beam)
            if (v.beamState == 0 && v.beamDone == 0) {
                v.beamT -= dt;
                let need = BEAM_TELE / Math.sqrt(rageK) + (v.rage > 0 ? BEAM_FIRE * 1.7 : BEAM_FIRE);
                let room = (B.sEnd - ctx.railS) / lmax(ctx.player.speed, HOLD_IRIS);
                if (v.beamT <= 0 && v.leaving == 0 && room > need) {
                    startBeam(B, W, ctx, rageK);
                    v.beamDone = 1;
                }
            }
            beam(B, W, ctx, dt);
            // after the beam the eye stares a moment, then blinks
            if (v.beamDone == 1 && v.beamState == 0) {
                if (v.stripRoll == 1) {
                    // the sweep is over: the strip goes back to the pupil
                    // (else ROLL! stays docked through the stare and blink)
                    v.stripRoll = 0;
                    irisCall(W);
                    if (v.beamN == 1) {
                        // the Baron's taunt fits between the first sweep and
                        // the next charge (~4 s) only on a free radio
                        let left = ctx.commState(), waiting = ctx.csWait;
                        if (left <= 0.05 && waiting == 0) {
                            ai.say(W, "baron", "Behold the Eye! Blink and you miss your own funeral!", 3, 1, "happy");
                        }
                    }
                }
                v.stareT += dt;
                if (v.stareT > STARE) {
                    v.iris = 2;
                    v.irisT = 0;
                    ctx.sfx("ui_move", 0.6);
                }
            }
        } else {
            v.open = mathx.damp(v.open, 0.06, 7, dt);
            // enraged, it spits a ring even with its lids shut
            if (v.rage > 0 && v.irisT > 0.35 && v.irisT - dt <= 0.35) {
                orbRing(B, W, ctx, 10, 26, t * 1.7);
            }
            if (lrandom() < 0.3) {
                let ax = (lrandom() - 0.5) * 10;
                let ay = (lrandom() - 0.5) * 10;
                models.point(B.xf, ax, ay, 1);
                fx.smoke(W.fx, models.POINT_X, models.POINT_Y, models.POINT_Z, 1.4, 0.1);
            }
            if (v.irisT > BLINK / rageK) {
                v.iris = 0;
                v.irisT = 0;
            }
        }
        // the pupil is armored whenever the lids are not open
        let vulnerable = v.iris != 2 && v.open > 0.55;
        if (c.armored == vulnerable) {
            c.armored = !vulnerable;
        }
        // pacing floor: the iris holds out for IRIS_MIN seconds (from the
        // lids' first crack) whatever you throw
        c.minHp = v.onT < IRIS_MIN ? c.maxHp * 0.9 * (1 - v.onT / IRIS_MIN) : 0;
    } else if (ph == 3) {
        // dying: shudders, sinks, detonates (sped up so the blast lands by
        // the blast line at the pilot's real speed)
        if (v.deathT < DEATH_BLAST) {
            v.deathRate = deathRate(B, ctx, DEATH_BLAST - v.deathT);
        }
        let dd = lmin(dt * v.deathRate, lmax(DEATH_BLAST - v.deathT, dt));
        v.deathT += dd;
        // it reels back as it sinks, so the blast is not on top of the pilot
        B.s = mathx.damp(B.s, 118, 0.9, dt);
        v.open = mathx.damp(v.open, 1.3, 2, dt);
        B.roll += dd * (0.5 + v.deathT);
        B.y -= dd * (1 + v.deathT * v.deathT * 2.5);
        v.boomT -= dd;
        if (v.boomT <= 0 && v.deathT < 3) {
            v.boomT = 0.14;
            let a = lrandom() * mathx.TAU;
            let rr = 5 + lrandom() * 6;
            let lz = (lrandom() - 0.5) * 6;
            models.point(B.xf, Math.cos(a) * rr, Math.sin(a) * rr, lz);
            fx.explosion(W.fx, models.POINT_X, models.POINT_Y, models.POINT_Z, 1.4 + lrandom(), "boom");
            ctx.sfx("explode_small", 0.6);
            ctx.shake(0.35);
        }
        if (v.deathT >= DEATH_BLAST && v.boomT > -10) {
            v.boomT = -100;
            let wx = B.xf.px, wy = B.xf.py, wz = B.xf.pz;
            fx.explosion(W.fx, wx, wy, wz, 5, "huge");
            if (wy < 8) {
                fx.splash(W.fx, wx, wz, 3);
            }
            fx.confetti(W.fx, wx, wy, wz, 3, 24);
            if (wy < 12) {
                fx.waterRing(W.fx, wx, wz, 4);
            }
            ctx.sfx("explode_big", 1);
            ctx.shake(1.8);
            holdSpeed(ctx, NaN);
        }
        if (v.deathT > 3.9) {
            B.done = true;
        }
    } else if (ph == 5) {
        // retreat: lids shut, it sinks and pulls away toward the Eye, gone in
        // RETREAT seconds
        let u = B.phaseT;
        v.open = mathx.damp(v.open, 0, 5, dt);
        B.y -= dt * (3 + u * 10);
        B.s += dt * (25 + u * 80);
        B.roll += dt * 0.6;
        if (lrandom() < 0.5) {
            let ax = (lrandom() - 0.5) * 12;
            let ay = (lrandom() - 0.5) * 12;
            models.point(B.xf, ax, ay, 2);
            fx.smoke(W.fx, models.POINT_X, models.POINT_Y, models.POINT_Z, 2, 0.3);
        }
        // (gone well before the finale at sEnd + 230 even for a boosting pilot)
        if (u > RETREAT || ctx.railS > B.sEnd + 150) {
            B.done = true;
        }
    }

    world(B, W, ctx, dt);
    placeParts(B);

    let fw = ph == 0 ? 0.7 * mathx.smoothstep(BOIL - 0.8, BOIL + 0.6, B.phaseT) : ph == 3 ? 0.6 : ph <= 2 ? 0.2 : 0.0;
    if (fw > 0) {
        let fx0 = B.xf.px, fy0 = B.xf.py, fz0 = B.xf.pz;
        if (ph == 1) {
            fy0 += LENS_FOCUS;
        } else if (ph == 2) {
            let c0 = core(B);
            fx0 = c0.x;
            fy0 = c0.y;
            fz0 = c0.z;
        }
        ai.focus(W, ctx, fx0, fy0, fz0, fw);
    }
    if (ph <= 3 && (ph > 0 || B.phaseT > BOIL)) {
        W.focusOn = true;
        W.focusX = B.xf.px;
        W.focusY = B.xf.py;
        W.focusZ = B.xf.pz;
        W.focusR = FRAME_R;
    }
    if (ph >= 1 && ph <= 2) {
        ctx.boss(true, NAME, health(B));
    } else if (ph == 0 && v.barT >= 0 && B.phaseT > v.barT) {
        ctx.boss(true, NAME, 1);
    }
}

export function partKilled(B: Boss, W: World, ctx: Ctx, e: Enemy): void {
    let F = W.fx;
    if (e.kind == "eyeLens") {
        fx.explosion(F, e.x, e.y, e.z, 1.3, "big");
        fx.ring(F, e.x, e.y, e.z, 2, 26, 0.5, 0.95, 1, 0.4);
        ctx.sfx("explode_big", 0.7);
        ctx.shake(0.4);
        ctx.addScore(e.score, e.x, e.y, e.z, "LENS");
        let left = 0;
        for (let i = 1; i <= LENSES; i++) {
            if (lens(B, i).alive) {
                left += 1;
            }
        }
        if (left == 3) {
            ai.say(W, "hank", "Half blind already! Keep poking!", 2.4, 1, "happy");
        }
    } else if (e.kind == "eyeCore") {
        fx.explosion(F, e.x, e.y, e.z, 3, "huge");
        fx.confetti(F, e.x, e.y, e.z, 2.4, 18);
        ctx.sfx("explode_big", 1);
        ctx.shake(1.4);
        B.killed = true;
        B.phase = 3;
        B.phaseT = 0;
        B.v.boomT = 0;
        B.v.beamState = 0;
        // the kill is announced and paid now (the DOWNED sting and kill cam
        // on its fall, or the slab); the bar and the phase chip go at once
        let paid = ai.pay(ctx, 8000, B.xf.px, B.xf.py, B.xf.pz, "WATCHER DESTROYED");
        ctx.stats.kills += 1;
        let sub = !isNaN(paid) ? format("+%d  //  THE EYE IS OPEN", [FormatArg.number(paid)]) : "THE EYE IS OPEN";
        ai.focus(W, ctx, B.xf.px, B.xf.py, B.xf.pz, 0.6);
        if (!ai.sting(W, ctx, "down_watcher", NAME, sub, B.xf.px, B.xf.py, B.xf.pz, FRAME_R)) {
            ctx.banner("WATCHER DESTROYED", sub, "success");
        }
        ctx.boss(false, NAME, 0);
        holdSpeed(ctx, HOLD_DEATH);
        B.v.deathRate = deathRate(B, ctx, DEATH_BLAST);
        let ps = B.parts;
        for (let i = 1; i < ps.length; i++) {
            ps[i].alive = false;
            ps[i].hidden = true;
        }
        ai.say(W, "baron", "No, no, NO! Do you know how long it took to wind that thing?", 3.2, 3, "angry");
    }
}

// Drawing ---------------------------------------------------------------------------------------

// beam segment (Luau: a local closure over r and the fx eye)
function seg(r: Gfx, W: World, px: f64, py: f64, pz: f64, bx: f64, by: f64, bz: f64, size: f64, cr: f64, cg: f64, cb: f64, a: f64, stretch: f64): void {
    let F = W.fx;
    let dx = px - F.camX, dy = py - F.camY, dz = pz - F.camZ;
    let cd = Math.sqrt(dx * dx + dy * dy + dz * dz);
    let sz = lmin(size, cd * 0.05);
    let fade = mathx.saturate((cd - 6) / 10);
    if (fade > 0.01) {
        R.particle(r, px, py, pz, sz, cr, cg, cb, a * fade, 1, 0.5, 0.3, 0, bx * 60, by * 60, bz * 60, stretch);
    }
}

export function draw(B: Boss, W: World, mo: Models, r: Gfx, t: f64): void {
    let x = B.xf;
    let v = B.v;
    let c = W.xf2;
    let c2 = W.xf3;
    let cr = core(B);
    let dying = B.phase == 3;
    let tint = dying ? 0.6 : 1.0;
    let irisGlow = B.phase == 2 ? 0.25 + 0.2 * Math.sin(t * 7) + v.rage * 0.2 : 0.0;
    models.put(mo.eyeBall, x, tint, tint, tint, cr.flash, irisGlow, 0);
    // gear rings
    models.child(c, x, 0, 0, 0.4, 0, 0, v.ringA, 1);
    models.put(mo.eyeRing, c, tint, tint, tint, 0, 0, 0);
    models.child(c, x, 0, 0, 2.2, 0, 0, -v.ringB * 0.7, 0.8);
    models.put(mo.eyeRing, c, tint * 0.9, tint * 0.88, tint * 0.85, 0, 0, 0);
    // the third ring is a gyroscope hoop: its plane tilted ~52-64 deg off
    // the eye's face and the tilt axis precessing round it, so it sweeps
    // round the pupil as an ellipse
    let c3 = W.xf;
    models.child(c3, x, 0, 0, 0, 0, 0, v.ringA * 0.6 + 0.8, 1);
    models.child(c2, c3, 0, 0, 0, 1.0 + 0.1 * Math.sin(v.ringB * 0.35), 0, 0, 1);
    models.child(c, c2, 0, 0, 0, 0, 0, v.ringB, 1.18);
    models.put(mo.eyeRing, c, tint, tint, tint, 0, 0, 0);
    // lids
    let open = v.open * 1.3;
    for (let k = 0; k <= 3; k++) {
        models.child(c2, x, 0, 0, 0, 0, 0, <f64>k * Math.PI / 2 + Math.PI / 4, 1);
        models.child(c, c2, 0, 0, 0, 0, open, 0, 1);
        models.put(mo.eyePetal, c, tint, tint, tint, B.phase == 1 ? cr.flash * 0.6 : 0, 0, 0);
    }
    // lens pods on the ring (they swell and flare white before a volley)
    let tele = B.phase == 1 && v.volleyT < LENS_TELE ? mathx.saturate(1 - v.volleyT / LENS_TELE) : 0.0;
    for (let i = 1; i <= LENSES; i++) {
        let e = lens(B, i);
        if (e.alive && B.phase >= 1 && B.phase <= 2) {
            let fi = <f64>i;
            models.aim(c, e.x, e.y, e.z, x.fx, x.fy, x.fz, x.ux, x.uy, x.uz, 0, 1.2 * SCALE);
            models.put(mo.eyeLens, c, 1, 1, 1, e.flash, 0.2 + 0.2 * Math.sin(t * 6 + fi) + tele * 0.6, 0);
            models.point(c, 0, 0, -1.2);
            let gs = 1.5 * SCALE * (1 + tele * (0.9 + 0.25 * Math.sin(t * 45)));
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, gs, 0.35 + tele * 0.6, 0.9 + tele * 0.1, 1, 0.55 + 0.25 * Math.sin(t * 6 + fi) + tele * 0.4, 1, 0.5, fi * 0.13, 0);
        }
    }
    // pupil glow
    if (B.phase >= 1 && B.phase <= 2) {
        models.point(x, 0, 0, -6.3);
        let g = 0.5 + 0.3 * Math.sin(t * 5);
        if (B.phase == 2) {
            g += 0.3 * mathx.saturate(v.open);
        }
        R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 3.4 * g * SCALE, 1, 0.3, 0.7, 0.7, 1, 0.5, 0.2, 0);
    }
    // beam: stretched glow segments so it reads as one continuous ray
    if (B.phase == 2 && v.beamState > 0) {
        models.point(x, 0, 0, -6.4);
        let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
        let l = lmax(Math.sqrt(v.bdx * v.bdx + v.bdy * v.bdy + v.bdz * v.bdz), 1e-4);
        let bx = v.bdx / l, by = v.bdy / l, bz = v.bdz / l;
        if (v.beamState == 1) {
            // thin flickering dashed sight line to where the sweep starts...
            let a = 0.5 + 0.35 * Math.sin(t * 40);
            let n = Math.floor(l / 3) + 8;
            for (let i = 1.0; i <= n; i += 2) {
                let d = i * 3;
                seg(r, W, ox + bx * d, oy + by * d, oz + bz * d, bx, by, bz, 0.16, 1, 0.45, 0.75, a, 0.8);
            }
            // ...and a dashed guide along the whole sweep, 70% of the way to the
            // pilot, drawing itself across in the sweep direction
            let ctx = W.ctx;
            if (ctx != null) {
                let k = mathx.saturate(1 - v.beamT / BEAM_TELE);
                ctx.railFrame(ctx.railS + 2);
                let rt = ctx.rfRight;
                let rx = <f64>rt.x, rz = <f64>rt.z;
                let dashes = 24;
                for (let j = 0; j <= dashes; j++) {
                    let fj = <f64>j;
                    let u = fj / <f64>dashes;
                    if (u <= k * 1.25) {
                        let xx = mathx.lerp(-v.beamSgn * SWEEP_X, v.beamSgn * SWEEP_X, u);
                        let tp = ctx.toWorld(ctx.railS + 2, xx, v.beamY);
                        let gx = ox + (<f64>tp.x - ox) * 0.7, gy = oy + (<f64>tp.y - oy) * 0.7, gz = oz + (<f64>tp.z - oz) * 0.7;
                        let a2 = (0.5 + 0.4 * k) * (0.75 + 0.25 * Math.sin(t * 30 + fj));
                        R.particle(r, gx, gy, gz, 0.28, 1, 0.45, 0.8, a2, 1, 0.5, fj * 0.05, 0, rx * 30, 0, rz * 30, 1.2);
                    }
                }
            }
            R.particle(r, ox, oy, oz, (2.4 + 2.2 * mathx.saturate(1 - v.beamT / BEAM_TELE)) * SCALE, 1, 0.4, 0.8, 1, 1, 0.5, 0.1, 0);
        } else {
            // (to its aim plane, 2 m ahead of him: run on to the lens it
            // glared over his figure at every hit, QA PT1-9)
            let n = Math.floor(l / 4);
            for (let i = 0.0; i <= n; i++) {
                let d = i * 4;
                let w = 2.0 + 0.35 * Math.sin(t * 50 + i);
                let px = ox + bx * d, py = oy + by * d, pz = oz + bz * d;
                seg(r, W, px, py, pz, bx, by, bz, w, 1, 0.3, 0.72, 0.85, 1.3);
                seg(r, W, px, py, pz, bx, by, bz, w * 0.4, 1, 0.95, 1, 1, 1.3);
            }
            R.particle(r, ox, oy, oz, 4.2 * SCALE, 1, 0.5, 0.85, 1, 1, 0.5, 0.1, 0);
        }
    }
}
