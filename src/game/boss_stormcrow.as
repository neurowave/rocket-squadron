// Port of src/game/boss_stormcrow.luau. STORMCROW: the sky galleon boss (storm reveal, engines, broadside, core, death / escape).
// Phase 1 ENGINES (four pods, flak), phase 2 CANNONS (turns broadside, orb
// volleys, swings to the other flank), phase 3 CORE (armor blown off, lift
// core exposed, drones and homing rockets), then a long fiery death. She
// rises out of a storm's shelf over the bay (fx.storm*) for the STORMCROW
// sting; the core kill cues the DOWNED sting and a kill cam on the falling
// hull (enemies.focus). If the player reaches `sEnd` first she escapes
// through the portal. A guard keeps her hull AIR m clear of rock
// (level.bossRoomS / solidAt) and, while the camera is down in the slot,
// whole in its view of the sky (level.sightFrom / sightAt). Every attack is
// telegraphed. The pilot's speed is capped for the fight (ctx.holdSpeed).
// Port: the guard memo lives in this module (one boss at a time; Luau keeps
// it on the boss), keyed by the boss object's identity. Internal
// multi-returns use module globals. murk()'s fx.stormShelfTop builds the
// storm meshes on first use: call fx.stormBuild() in a loading step.
import { Vector } from "rive/vector";
import { format, FormatArg } from "rive/format";
import { Ctx } from "./types";
import * as ai from "./ai_types";
import { Boss, World, Enemy, BossV } from "./ai_types";
import * as fx from "./fx";
import { Fx } from "./fx";
import * as models from "./models";
import { Models, Xf } from "./models";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import * as lv from "../world/level";
import { Sight } from "../world/level";
import * as sfxLib from "./sfx";
import { HUGE, lmin, lmax, lclamp, mod, lrandom } from "../lib/compat";

// (1-based rows)
const PODS: Array<Array<f64>> = [[0.0], [0.0, -12.5, -10.2, -6], [0.0, 12.5, -10.2, -6], [0.0, -15.5, -7.2, 9], [0.0, 15.5, -7.2, 9]];
const CANNONS: Array<Array<f64>> = [[0.0], [0.0, -2.75, -13.9, -6, -1], [0.0, -2.75, -13.9, 5, -1], [0.0, 2.75, -13.9, -6, 1], [0.0, 2.75, -13.9, 5, 1]];
const CORE_X: f64 = 0, CORE_Y: f64 = -17.8, CORE_Z: f64 = 2;
const ARMOR: Array<Array<f64>> = [[0.0], [0.0, -24, 7.6], [0.0, -12, 8.8], [0.0, 0, 8.9], [0.0, 12, 8.0], [0.0, 22, 5.6]];
const NAME = "STORMCROW";
const SCALE: f64 = 1.25;
// pilot cruise cap (m/s): reveal/engines/broadside, core, death dive
const HOLD: f64 = 40;
const HOLD_CORE: f64 = 34;
const HOLD_DEATH: f64 = 44;
// reveal beats (s): emerges by EMERGE, holds broadside (the sting from
// STING_AT), turns in from TURN, fights at REVEAL; pods live from PODS_LIVE
const REVEAL: f64 = 5.2;
const EMERGE: f64 = 2.3;
const STING_AT: f64 = 2.7;
const TURN: f64 = 3.5;
const PODS_LIVE: f64 = 3.9;
// the hull's visual centre (local)
const CENTER_Y: f64 = -4;
// her top fin's tip (local), and about how far the chase lens rides behind
// the pilot in a boss frame (m); the radius that frames all of her
const TOP_Y: f64 = 13.4;
const LENS_BACK: f64 = 14;
const FRAME_R: f64 = 36;
// fight framing (local y of the chase camera's focus, per phase), eased
// over ~1.5 s on a phase change
const FOCUS_Y: Array<f64> = [0.0, -6.5, -11.5, -15.2];
// fight heights (m over the rail at her station)
const FIGHT_Y: Array<f64> = [0.0, 22, 28, 33];
// core phase pose: CORE_S_WIDE m further off on a wide screen, swings less,
// stern low (nose up) so the top fin stays in the frame
const CORE_S: f64 = 106;
const CORE_S_WIDE: f64 = 14;
const CORE_YAW: f64 = 0.5;
const CORE_PITCH: f64 = 0.05;
// broadside: her pitch while she is end-on in a swap of sides
const SWAP_PITCH: f64 = 0.18;
// her height (m over the rail) while she holds broadside for the poster
const HOLD_Y: f64 = 25;
// OUT OF THE STORM (fx.storm*): hidden low inside the shelf HID_BACK m past
// its anchor, HID_X m right, HID_Y m up, three-quarter on (YAW_OUT); rears
// nose-high from T_REAR0 (PITCH_UP by T_REAR), heaves up from T_HEAVE,
// levels from T_LEVEL, LIFT m over the hold by T_PEAK, settles by T_SETTLE;
// handed over to the pilot-relative hold over LOCK0 .. LOCK1. Searchlights
// from BEAM0, a bolt at T_STRIKE, engines catch from SPIN0, broadside over
// BANK0 .. BANK1 heeled HEEL; the cell breaks up from T_BREAK, the shelf
// collapses at COLLAPSE_AT (the cell drifts off at DRIFT m/s).
// SLOW_RISE (debug, off): a slower, heavier heave on the same cues.
const SLOW_RISE: bool = false;
const STORM_X: f64 = -14;
const STORM_SMAX: f64 = 3975;
// (the anchor at least this far past her cue's rail s, else the sky reveal)
const STORM_MIN: f64 = 160;
const HID_BACK: f64 = 18;
const HID_X: f64 = 20;
const HID_Y: f64 = -7;
const YAW_OUT: f64 = 2.15;
const T_REAR0: f64 = 0.35;
const T_HEAVE: f64 = 0.7;
const T_REAR: f64 = 1.0;
const T_LEVEL: f64 = SLOW_RISE ? 1.4 : 1.05;
const T_PEAK: f64 = SLOW_RISE ? 2.5 : 1.65;
const T_SETTLE: f64 = SLOW_RISE ? 3.0 : 2.6;
const HEAVE_POW: f64 = 0.55;
const LIFT: f64 = 2.5;
const PITCH_UP: f64 = 0.55;
const LOCK0: f64 = 1.9;
const LOCK1: f64 = 2.6;
// once out she keeps at least NEAR_S x the rise's stand-off ahead (soft
// over NEAR_SOFT m, eased in over NEAR0 .. NEAR1)
const NEAR_S: f64 = 158;
const NEAR_SOFT: f64 = 6;
const NEAR0: f64 = 0.6;
const NEAR1: f64 = 1.0;
const BEAM0: f64 = 0.15;
const BEAM_LEN: f64 = 210;
const SPIN0: f64 = 1.05;
const T_STRIKE: f64 = 0.8;
const BANK0: f64 = 1.1;
const BANK1: f64 = 2.6;
const HEEL: f64 = -0.12;
const T_BREAK: f64 = 1.25;
const COLLAPSE_AT: f64 = 1.3;
const DRIFT: f64 = 8;
// coming out of the storm the slot's sight step eases in at this rate (1/s)
const SIGHT_EASE: f64 = 4;
// The still frame she rises into: the camera's focus FRAME_UP m over her
// peak's centre (FRAME_UP_TALL on a narrow screen); nearer than the hold it
// rides up toward her top fin by 1 / NEAR_K. If her top or her crest (CREST
// times, led by CEIL_LEAD s) rises over CEIL_V (CEIL_V_TALL) of the view,
// the point rises at CEIL_RATE (1/s) until clear (from CEIL_T0).
const FRAME_UP: f64 = 8.5;
const FRAME_UP_TALL: f64 = -6;
const NEAR_K: f64 = 3;
const CEIL_V: f64 = 0.3;
const CEIL_V_TALL: f64 = 0.17;
const CEIL_RATE: f64 = 24;
const CEIL_LEAD: f64 = 0.3;
const CEIL_T0: f64 = 0.85;
const CREST: Array<f64> = SLOW_RISE ? [0.0, 1.6, 1.75, 1.9] : [0.0, 1.3, 1.45, 1.6];
// PORTRAIT: weighted by the portrait share (1 - wide) she holds at
// PORT_HOLD x the hold's stand-off and heaves PORT_UP m higher
const PORT_HOLD: f64 = 0.6;
const PORT_UP: f64 = 18;
// her hull in the murk: this dark until she is up out of it
const MURK_TINT: f64 = 0.62;
// the sky reveal (a run that starts past the mouth): m over / right of the rail
const SKY_Y: f64 = 62;
const SKY_X: f64 = 6;
// pacing floor: a phase's last weak point holds out until its weak points
// have been up this long (s)
const FLOOR: Array<f64> = [0.0, 5, 5, 6];
// she comes back toward the pilot at most this share of her distance per s
const APPROACH: f64 = 0.8;
// ... and backs off by at most this share per second; room still wins
const RECEDE: f64 = 0.35;
// air (m) the clearance guard keeps between her hull and rock
const AIR: f64 = 3;
// telegraph lead (s) before cannon volleys, rocket salvos and stern bursts
const TELE: f64 = 0.7;
// with the core out it hangs on HANG m past sEnd; the final blast lands by
// sEnd + BLAST_AT
const HANG: f64 = 50;
const BLAST_AT: f64 = 130;
// death: seconds (at rate 1) to the final blast
const DEATH_BLAST: f64 = 3.6;
// seconds a blown armor shutter tumbles before it is gone
const PIECE_LIFE: f64 = 3.5;

// Tuning knob (1 = shipped balance).
const HP_MULT: f64 = 1;

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}

// Core service: cap the rail speed during the fight (NaN releases it).
function holdSpeed(ctx: Ctx, v: f64): void {
    ctx.holdSpeed(v);
}

function part(W: World, kind: string, hp: f64, radius: f64, score: f64, armored: bool): Enemy {
    let e = ai.enemy(kind, "part", hp >= 9999 ? hp : lmax(0.1, hp * HP_MULT), radius, score);
    e.part = true;
    e.armored = armored;
    e.lockable = !armored;
    e.rel = true;
    if (hp < 9999) W.list.push(e);
    return e;
}

// The storm she rises out of: brewed by the mission script ahead of her
// cue `cueS`, or with her when the run starts later.
export function brew(F: Fx, cueS: f64): void {
    fx.stormStart(F, cueS, STORM_X, STORM_SMAX);
}

export function spawn(W: World, ctx: Ctx, sEnd: f64): Boss {
    let B = new Boss();
    B.kind = "stormcrow";
    B.name = NAME;
    B.phase = 0;
    B.t = 0;
    B.phaseT = 0;
    B.s = 620;
    B.x = 0;
    B.y = 60;
    B.xf = models.xf();
    B.hpTotal = 0;
    let v = B.v;
    v.fireT = 2; v.flakT = 2.5; v.sternT = 3; v.rocketT = 3; v.droneT = 3; v.side = -1; v.deathT = 0; v.boomT = 0;
    v.burst = 0; v.burstT = 0; v.deathRate = 1;
    v.stung = 0; v.barT = -1; v.callout = 0; v.sAbs = -1e9; v.focusY = CENTER_Y; v.etaT = 0; v.phaseEta = HUGE;
    v.storm = 0; v.upT = -1; v.sp1 = 0; v.sp2 = 0; v.sp3 = 0; v.sp4 = 0; v.roar = 0;
    // (Luau nil: read as 0, crestV as "none yet")
    v.hvx = 0; v.hvy = 0; v.hvz = 0; v.sds = 0; v.sdx = 0; v.lift = 0; v.crestV = NaN; v.portUp = 0;
    v.bolt = 0; v.col = 0; v.brk = 0; v.hx = 0; v.hy = 0; v.hz = 0; v.hSet = 0;
    B.killed = false;
    B.escaped = false;
    B.done = false;
    B.sEnd = sEnd;
    B.yaw = 0;
    B.pitch = 0;
    B.roll = 0;
    for (let i = 1; i <= 4; i++) {
        let e = part(W, "crowPod", 5, 3.3 * SCALE, 400, false);
        e.hidden = true;
        B.parts.push(e);
    }
    for (let i = 1; i <= 4; i++) {
        let e = part(W, "crowCannon", 3, 2.8 * SCALE, 400, false);
        e.hidden = true;
        B.parts.push(e);
    }
    let core = part(W, "crowCore", 14, 3.7 * SCALE, 1500, true);
    core.hidden = true;
    B.parts.push(core);
    for (let i = 1; i <= 5; i++) {
        let a = part(W, "crowArmor", 9999, 8, 0, true);
        a.hidden = true;
        B.parts.push(a);
    }
    for (let i = 1; i <= 9; i++) B.hpTotal += B.parts[i].maxHp;
    ctx.stats.killsTotal += 1;
    holdSpeed(ctx, HOLD);
    // out of the storm, unless the run starts past the mouth (the sky reveal)
    let F = W.fx;
    brew(F, ctx.railS);
    if (fx.stormAnchorS(F, lmax(W.far, 0.1)) - ctx.railS > STORM_MIN) {
        fx.stormRipen(F);
        B.v.storm = 1;
    } else {
        fx.stormClear(F);
    }
    return B;
}

@inline function pod(B: Boss, i: i32): Enemy {
    return B.parts[i];
}
@inline function cannon(B: Boss, i: i32): Enemy {
    return B.parts[4 + i];
}
@inline function core(B: Boss): Enemy {
    return B.parts[9];
}

function health(B: Boss): f64 {
    let h = 0.0;
    for (let i = 1; i <= 9; i++) {
        let e = B.parts[i];
        if (e.alive) h += lmax(e.hp, 0);
    }
    return h / B.hpTotal;
}

// Seconds the phase's weak points may last at the rate they have gone down
// since they came up (v.etaT, not counting her turns): events bossComms
// starts a phase line only when it is over by then; HUGE until a quarter of
// their hp is gone.
function phaseEta(B: Boss): f64 {
    let i0 = 9, i1 = 9;
    if (B.phase <= 1) {
        i0 = 1;
        i1 = 4;
    } else if (B.phase == 2) {
        i0 = 5;
        i1 = 8;
    } else if (B.phase > 3) {
        return HUGE;
    }
    let hp = 0.0, max = 0.0;
    for (let i = i0; i <= i1; i++) {
        let e = B.parts[i];
        max += e.maxHp;
        if (e.alive) hp += lmax(e.hp, 0);
    }
    let done = 1 - hp / max;
    // (never under the pacing floor left)
    let v = B.v;
    let fl = v.upT >= 0 ? FLOOR[<i32>lmax(B.phase, 1)] - v.upT : 0.0;
    if (done < 0.25) return HUGE;
    // broadside: plus the turns still to come
    let turn = 0.0;
    if (B.phase == 2) {
        let target = v.side < 0 ? 1.3 : -1.3;
        turn = Math.log(lmax(Math.abs(B.yaw - target), 0.5) / 0.5) / 1.6;
        if (v.side < 0 && (cannon(B, 3).alive || cannon(B, 4).alive)) {
            turn += Math.log(2.6 / 0.5) / 1.6;
        }
    }
    return lmax(v.etaT * (1 - done) / done + turn, fl);
}

// The pacing floor: the last live weak point of the phase holds out until
// they have been up FLOOR s (eased down from where it stands, so a hit
// never heals it); the rest go down as they are hit.
function floors(B: Boss, dt: f64): void {
    let v = B.v;
    if (v.upT >= 0) v.upT += dt;
    let last: Enemy? = null;
    let left = 0;
    let ph = <i32>lmax(B.phase, 1);
    let i0 = ph == 1 ? 1 : ph == 2 ? 5 : 9;
    let i1 = ph == 1 ? 4 : ph == 2 ? 8 : 9;
    for (let i = 1; i <= 9; i++) {
        let e = B.parts[i];
        e.minHp = 0;
        if (i >= i0 && i <= i1 && e.alive) {
            left += 1;
            last = e;
        }
    }
    if (last != null && left == 1 && B.phase <= 3 && v.upT >= 0 && v.upT < FLOOR[ph]) {
        last.minHp = lmin(last.hp, last.maxHp * 0.9 * (1 - v.upT / FLOOR[ph]));
    }
}

function setPhase(B: Boss, W: World, ctx: Ctx, ph: f64): void {
    if (ai.LOG) console.log(format("CROW phase %d at s=%.0f t=%.1f", [N(ph), N(ctx.railS), N(B.t)]));
    B.phase = ph;
    B.phaseT = 0;
    if (ph >= 2) {
        B.v.etaT = 0;
        B.v.upT = 0;
    }
    if (ph >= 1 && ph <= 2) {
        holdSpeed(ctx, HOLD);
    } else if (ph == 3) {
        holdSpeed(ctx, HOLD_CORE);
    }
    if (ph == 1) {
        for (let i = 1; i <= 4; i++) pod(B, i).hidden = false;
        for (let i = 10; i < B.parts.length; i++) B.parts[i].hidden = false;
        core(B).hidden = false;
        ai.say(W, "hank", "Four engines on that gasbag. Pop 'em and she can't run!", 3.4, 3, "shout");
        ai.say(W, "tower", "Stay on her tail - ride the brakes if you overshoot.", 3.4, 1, "neutral");
    } else if (ph == 2) {
        for (let i = 1; i <= 4; i++) cannon(B, i).hidden = false;
        B.v.side = -1;
        B.v.fireT = 1.8;
        ai.banner(W, "BROADSIDE", "TAKE OUT THE CANNONS", "warning", 3, 2);
        ai.say(W, "baron", "Enough! Gunners, show him our good side!", 3, 3, "angry");
        ai.say(W, "vi", "She's turning! Cannons on the flank, hit 'em!", 3, 2, "shout");
    } else if (ph == 3) {
        let c = core(B);
        c.armored = false;
        c.lockable = true;
        B.v.rocketT = 3;
        B.v.droneT = 3;
        ai.banner(W, "CORE EXPOSED", "FIRE AT WILL", "warning", 3, 3);
        ctx.sfx("explode_big", 0.8);
        ctx.shake(0.8);
        // blow the shutters off
        let cx = c.x, cy = c.y, cz = c.z;
        for (let k = 0.0; k <= 3; k++) {
            let a = k * Math.PI / 2 + Math.PI / 4;
            models.dir(B.xf, Math.sin(a), -0.3, -Math.cos(a));
            let ox = models.DIR_X, oy = models.DIR_Y, oz = models.DIR_Z;
            // thrown off with her way on: they tumble down and fall behind her
            let v2 = B.v;
            let cvx = v2.hvx * 0.9, cvy = v2.hvy * 0.9, cvz = v2.hvz * 0.9;
            B.pieces.push([0.0, cx, cy, cz, cvx + ox * 14, cvy + 6 + oy * 6, cvz + oz * 14, a, (lrandom() - 0.5) * 8, PIECE_LIFE, k]);
            fx.explosion(W.fx, cx + ox * 3, cy + oy * 3, cz + oz * 3, 0.9, "pop");
        }
        ai.say(W, "tower", "Armor's off! Hit that glowing core, NOW!", 3, 3, "shout");
        ai.say(W, "baron", "My lift core! Launch everything!", 2.6, 2, "worried");
    }
}

// 1 on a landscape screen .. 0 at phone portrait (from World.far)
function wide(W: World): f64 {
    return mathx.saturate((1.3 - W.far) / 0.3);
}

// Guard caches (exact: every input is in the key, the maths is unchanged).
// world(): the inputs of the pose in B.xf (NaN: none yet) and its
// generation; the hull points in world space for pose generation pgen;
// roomNeed's result for (pose generation, sc, solids) with its QA / QL / QH
// (hull point offsets from her rail point: along, lateral, height) and their
// bounds; envEnd: where level.bossRoomS's table ends. (1-based arrays)
class Memo {
    ws: f64 = NaN;
    wx: f64 = NaN;
    wy: f64 = NaN;
    wyaw: f64 = NaN;
    wpitch: f64 = NaN;
    wroll: f64 = NaN;
    gen: f64 = 0;
    pgen: f64 = -1;
    px: Array<f64>;
    py: Array<f64>;
    pz: Array<f64>;
    sp: Array<f64>;
    rgen: f64 = -1;
    rsc: f64 = NaN;
    rsol: f64 = -1;
    need: f64 = 0;
    pos: Vector = Vector.xyz(0, 0, 0);
    qa: Array<f64>;
    ql: Array<f64>;
    qh: Array<f64>;
    qaLo: f64 = 0;
    qaHi: f64 = 0;
    qhLo: f64 = 0;
    qhHi: f64 = 0;
    qlLo: f64 = 0;
    qlHi: f64 = 0;
    envEnd: f64 = NaN;
    constructor(n: i32) {
        this.px = new Array<f64>(n + 1);
        this.py = new Array<f64>(n + 1);
        this.pz = new Array<f64>(n + 1);
        this.sp = new Array<f64>(n + 1);
        this.qa = new Array<f64>(n + 1);
        this.ql = new Array<f64>(n + 1);
        this.qh = new Array<f64>(n + 1);
    }
}

class MemoSlot {
    boss: Boss? = null;
    m: Memo? = null;
}
const MEMO = new MemoSlot();

function memo(B: Boss): Memo {
    let m = MEMO.m;
    if (m != null && MEMO.boss === B) return m;
    let fresh = new Memo(HULL_N);
    MEMO.boss = B;
    MEMO.m = fresh;
    return fresh;
}

// bit-equal (0 and -0 differ; NaN never matches)
@inline function same(a: f64, b: f64): bool {
    return a == b && (a != 0 || 1 / a == 1 / b);
}

function world(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let s = ctx.railS + ai.bossS(W, B);
    let mo = memo(B);
    if (same(s, mo.ws) && same(B.x, mo.wx) && same(B.y, mo.wy) && same(B.yaw, mo.wyaw) && same(B.pitch, mo.wpitch) && same(B.roll, mo.wroll)) {
        return;
    }
    mo.ws = s;
    mo.wx = B.x;
    mo.wy = B.y;
    mo.wyaw = B.yaw;
    mo.wpitch = B.pitch;
    mo.wroll = B.roll;
    mo.gen += 1;
    ctx.railFrame(s);
    let pos = ctx.rfPos, f = ctx.rfFwd, rt = ctx.rfRight;
    let rtx: f64 = rt.x, rtz: f64 = rt.z;
    let px = <f64>pos.x + rtx * B.x;
    let py = <f64>pos.y + B.y;
    let pz = <f64>pos.z + rtz * B.x;
    let cy = Math.cos(B.yaw), sy = Math.sin(B.yaw);
    let hx = <f64>f.x * cy - rtx * sy, hy = <f64>f.y * cy, hz = <f64>f.z * cy - rtz * sy;
    let cp = Math.cos(B.pitch), sp = Math.sin(B.pitch);
    hx = hx * cp;
    hy = hy * cp + sp;
    hz = hz * cp;
    models.aim(B.xf, px, py, pz, hx, hy, hz, 0, 1, 0, B.roll, SCALE);
}

// Clearance ------------------------------------------------------------------------------
// Points (mesh units, before SCALE) bounding her silhouette: the gasbag
// outline, the tail fins, the engine pods' propeller discs, the gondola and
// core keel, the pennant, and the gap under the gasbag (1-based).
const HX: Array<f64> = [0.0];
const HY: Array<f64> = [0.0];
const HZ: Array<f64> = [0.0];
function hullAdd(x: f64, y: f64, z: f64): void {
    HX.push(x);
    HY.push(y);
    HZ.push(z);
}
function buildHull(): i32 {
    let gas: Array<f64> = [-33.6, 1.6, -31, 5.8, -26, 8.2, -20, 9.2, -6, 9.5, 6, 9.1, 13.6, 8.2, 22, 5.8, 29, 3, 33.2, 1];
    for (let g = 0; g < 10; g++) {
        let g1 = gas[g * 2], g2 = gas[g * 2 + 1];
        for (let k = 0.0; k <= 7; k++) {
            let a = k * Math.PI / 4;
            hullAdd(Math.cos(a) * g2, Math.sin(a) * g2, g1);
        }
    }
    let fins: Array<f64> = [13.4, 27, 13.4, 34.9, 8.7, 29];
    for (let k = 0.0; k <= 3; k++) {
        let c = Math.cos(k * Math.PI / 2), sn = Math.sin(k * Math.PI / 2);
        for (let j = 0; j < 3; j++) hullAdd(c * fins[j * 2], sn * fins[j * 2], fins[j * 2 + 1]);
    }
    for (let i = 1; i <= 4; i++) {
        let p = PODS[i];
        for (let k = 0.0; k <= 3; k++) {
            let a = k * Math.PI / 2;
            hullAdd(p[1] + Math.cos(a) * 3.1, p[2] + Math.sin(a) * 3.1, p[3] - 4.1);
        }
        hullAdd(p[1], p[2], p[3] + 3.9);
    }
    let keel: Array<f64> = [0, -20.3, 2, 3.2, -15.4, 2, -3.2, -15.4, 2, 0, -16.4, -14, 0, -16.4, 12, 2.9, -13.5, -14, -2.9, -13.5, -14, 0, -13.2, 28, 4.5, -13.2, 26, -4.5, -13.2, 26];
    for (let j = 0; j < 10; j++) hullAdd(keel[j * 3], keel[j * 3 + 1], keel[j * 3 + 2]);
    let gap: Array<f64> = [2.4, -13.2, -6, 7.4, -11.7, -6, 9, -10.1, 9, 3.9, -13.5, -10, 3.9, -13.5, 0, 3.9, -13.5, 10, 6.5, -9, -14, 6.5, -9, 2, 6.5, -9, 16];
    for (let side = -1.0; side <= 1; side += 2) {
        for (let j = 0; j < 9; j++) hullAdd(side * gap[j * 3], gap[j * 3 + 1], gap[j * 3 + 2]);
    }
    return HX.length - 1;
}
const HULL_N: i32 = buildHull();

// the HULL points that can be her highest: the gasbag outline's upper ones
// (its first 80, 8 per station) and the 12 fin points after them (1-based)
function buildTops(): Array<i32> {
    let t: Array<i32> = [0];
    for (let i = 1; i <= HULL_N; i++) {
        if ((HY[i] > 0.5 && i <= 80) || (i > 80 && i <= 92)) t.push(i);
    }
    return t;
}
const TOPS: Array<i32> = buildTops();

// Out of the storm, before the hold: her offset from the rail (lateral,
// height), yaw, pitch and heel at t0 (qx: the storm's lateral x; tall: the
// portrait share), and the portrait lift in that height: RISE_*.
let RISE_X: f64 = 0, RISE_Y: f64 = 0, RISE_YAW: f64 = 0, RISE_PITCH: f64 = 0, RISE_HEEL: f64 = 0, RISE_UP: f64 = 0;
function rise(t0: f64, qx: f64, tall: f64): void {
    // (a heavy heave: she strains, surges, overshoots and wallows down)
    let hu = mathx.saturate((t0 - T_HEAVE) / (T_PEAK - T_HEAVE));
    if (SLOW_RISE) hu = Math.pow(hu, HEAVE_POW);
    let heave = hu * hu * hu * (hu * (hu * 6 - 15) + 10);
    let settle = mathx.smoothstep(T_PEAK, T_SETTLE, t0);
    let x = mathx.lerp(qx + HID_X, 1, mathx.smoothstep(1.0, EMERGE + 0.4, t0));
    let y = HID_Y + (HOLD_Y + LIFT - HID_Y) * heave - LIFT * settle;
    let up = 0.0;
    if (tall > 0) {
        up = tall * PORT_UP * heave;
        y += up;
    }
    let yaw = mathx.lerp(YAW_OUT, 1.45, mathx.smoothstep(BANK0, BANK1, t0));
    // she rears nose-high as she heaves (a heavy wallow on it), level by the hold
    let nose = mathx.smoothstep(T_REAR0, T_REAR, t0) * (1 - mathx.smoothstep(T_LEVEL, T_PEAK + 0.2, t0));
    let pitch = (PITCH_UP + 0.025 * Math.sin(t0 * 2.6)) * nose;
    let heel = HEEL * Math.sin(Math.PI * mathx.saturate((t0 - BANK0) / (BANK1 + 0.5 - BANK0)));
    RISE_X = x;
    RISE_Y = y;
    RISE_YAW = yaw;
    RISE_PITCH = pitch;
    RISE_HEEL = heel;
    RISE_UP = up;
}

// her hull points in world space for the pose in B.xf (once per pose)
function hullPoints(B: Boss, m: Memo): void {
    if (m.pgen == m.gen) return;
    m.pgen = m.gen;
    let X = m.px, Y = m.py, Z = m.pz;
    let xf = B.xf;
    for (let i = 1; i <= HULL_N; i++) {
        models.point(xf, HX[i], HY[i], HZ[i]);
        X[i] = models.POINT_X;
        Y[i] = models.POINT_Y;
        Z[i] = models.POINT_Z;
    }
}

// Room: her hull AIR m clear of rock. The CLIFF TURN walls and the exit
// stacks: pushed on along the rail to the least s where the pose clears
// them (level.bossRoomS is non-decreasing). Other registered rock: pushed
// aside. roomNeed: her rail s now (returned) and the least s at which this
// pose clears the walls and the exit stacks (RN_NEED; RN_POS her rail
// point); fills the memo's QA / QL / QH. A point at least 1 m past the end
// of bossRoomS's table is not looked up: the need is exact whenever it is
// over sc, at most sc otherwise.
let RN_NEED: f64 = 0;
let RN_POS: Vector = Vector.xyz(0, 0, 0);
function roomNeed(B: Boss, W: World, ctx: Ctx, dt: f64): f64 {
    world(B, W, ctx, dt);
    let m = memo(B);
    let far = lmax(W.far, 0.1);
    let sc = ctx.railS + B.s * far;
    let nsol = <f64>(lv.solids.length - 1);
    if (m.rgen == m.gen && same(m.rsc, sc) && m.rsol == nsol) {
        RN_NEED = m.need;
        RN_POS = m.pos;
        return sc;
    }
    ctx.railFrame(sc);
    let pos = ctx.rfPos, f = ctx.rfFwd, rt = ctx.rfRight;
    let ffx: f64 = f.x, ffz: f64 = f.z;
    let fl = lmax(Math.sqrt(ffx * ffx + ffz * ffz), 1e-6);
    let fx_ = ffx / fl, fz_ = ffz / fl;
    let rtx: f64 = rt.x, rtz: f64 = rt.z;
    let posx: f64 = pos.x, posy: f64 = pos.y, posz: f64 = pos.z;
    let need = -HUGE;
    let envEnd = m.envEnd;
    if (isNaN(envEnd)) {
        envEnd = lv.bossRoomS(1, HUGE, 1);
        if (!(envEnd > -HUGE && envEnd < HUGE)) envEnd = HUGE;
        m.envEnd = envEnd;
    }
    let lim = envEnd + 1;
    hullPoints(B, m);
    let X = m.px, Y = m.py, Z = m.pz;
    let QA = m.qa, QL = m.ql, QH = m.qh;
    let aLo = HUGE, aHi = -HUGE, hLo = HUGE, hHi = -HUGE, lLo = HUGE, lHi = -HUGE;
    for (let i = 1; i <= HULL_N; i++) {
        let wx = X[i], wy = Y[i], wz = Z[i];
        let dx = wx - posx, dz = wz - posz;
        let along = dx * fx_ + dz * fz_;
        let lat = dx * rtx + dz * rtz;
        let h = wy - posy;
        QA[i] = along;
        QL[i] = lat;
        QH[i] = h;
        if (!(sc + along > lim)) {
            need = lmax(need, lv.bossRoomS(lat < 0 ? -1 : 1, Math.abs(lat) + AIR, wy) - along);
        }
        if (along < aLo) aLo = along;
        if (along > aHi) aHi = along;
        if (lat < lLo) lLo = lat;
        if (lat > lHi) lHi = lat;
        if (h < hLo) hLo = h;
        if (h > hHi) hHi = h;
    }
    m.rgen = m.gen;
    m.rsc = sc;
    m.rsol = nsol;
    m.need = need;
    m.pos = pos;
    m.qaLo = aLo;
    m.qaHi = aHi;
    m.qhLo = hLo;
    m.qhHi = hHi;
    m.qlLo = lLo;
    m.qlHi = lHi;
    RN_NEED = need;
    RN_POS = pos;
    return sc;
}

function room(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let far = lmax(W.far, 0.1);
    let sc = roomNeed(B, W, ctx, dt);
    let need = RN_NEED;
    let pos = RN_POS;
    let m = memo(B);
    let target = lmax(sc, need);
    let py: f64 = pos.y;
    if (target > sc + 1e-3) py = ctx.railFrame(target).y;
    let pushR = 0.0, pushL = 0.0;
    // (no registered solid near the hull's box: no point can be pushed)
    if (lv.solidAtIn(target + m.qaLo, target + m.qaHi, m.qlLo, m.qlHi, m.qhLo + py, m.qhHi + py, AIR)) {
        let QA = m.qa, QL = m.ql, QH = m.qh;
        for (let i = 1; i <= HULL_N; i++) {
            let push = lv.solidAt(target + QA[i], QL[i], QH[i] + py, AIR);
            let dir = lv.SOLIDAT_DIR;
            if (push > 0) {
                if (dir > 0) {
                    pushR = lmax(pushR, push);
                } else {
                    pushL = lmax(pushL, push);
                }
            }
        }
    }
    let push = pushR - pushL;
    if (target > sc + 1e-3 || push != 0) {
        B.s = (target - ctx.railS) / far;
        B.x += push;
        world(B, W, ctx, dt);
    }
}

// Sight: while the camera is down in the CLIFF TURN slot, the air beyond
// shows only through the slot's narrowest stretch. Every lens that may be
// on screen (the core's camera, the chase camera's mirror, the sting's low
// reveal shot) must see her whole silhouette in that window, SIGHT_A (+
// SIGHT_M m) clear of the rock edges: she slides across to the window, and
// where it is too narrow she stands further off down the valley.
const SIGHT_A: f64 = 1 * Math.PI / 180;
const SIGHT_M: f64 = 1.5;
// the furthest she is staged (m of rail past the pilot)
const SIGHT_MAX: f64 = 1500;
// the widest she slides across for the window (m off the rail, plus a share
// of her distance)
const SIGHT_X: f64 = 30;
const SIGHT_XK: f64 = 0.18;
const SIGHTS: Array<Sight> = [lv.sightNew(), lv.sightNew(), lv.sightNew(), lv.sightNew()]; // 1-based
let sightN: i32 = 0;
let sightS: f64 = 0; // the nearest lens's rail s

function lens(ctx: Ctx, x: f64, y: f64, z: f64, s: f64, hLow: f64): void {
    if (s > lv.SIGHT_S1 - 60) return;
    sightN += 1;
    let pos = ctx.railFrame(s);
    lv.sightFrom(SIGHTS[sightN], x, y, z, s, lmin(y - <f64>pos.y, hLow) - 1);
    sightS = lmin(sightS, s);
}

function lenses(B: Boss, W: World, ctx: Ctx, hLow: f64): void {
    sightN = 0;
    sightS = HUGE;
    let p = ctx.player;
    let fX: f64 = p.fwd.x, fZ: f64 = p.fwd.z, rX: f64 = p.right.x, rZ: f64 = p.right.z;
    let pX: f64 = p.pos.x, pY: f64 = p.pos.y, pZ: f64 = p.pos.z;
    let fl = lmax(Math.sqrt(fX * fX + fZ * fZ), 1e-6);
    // the core's camera (the frame on screen, beats included)
    let ok = ai.lens(W, ctx);
    let ex = ai.LENS_2, ey = ai.LENS_3, ez = ai.LENS_4;
    if (ok) lens(ctx, ex, ey, ez, p.s + ((ex - pX) * fX + (ez - pZ) * fZ) / fl, hLow);
    // the chase camera's mirror, or a lens behind the pilot before either
    // has a frame
    let c = W.cam;
    if (c.on) {
        lens(ctx, c.eye.x, c.eye.y, c.eye.z, c.s, hLow);
    } else if (!ok) {
        lens(ctx, pX - fX * 10, pY + 3, pZ - fZ * 10, p.s - 10, hLow);
    }
    // the sting's low reveal shot beside the pilot, from just before it cuts in
    let v = B.v;
    if (B.phase == 0 && B.phaseT > STING_AT - 0.3 && v.stung == 0) {
        let side = p.x > 0 ? 1.0 : -1.0;
        lens(ctx, pX - fX * 9 + rX * 3.2 * side, lmax(0.9, pY - 1.4), pZ - fZ * 9 + rZ * 3.2 * side, p.s - 9, hLow);
    }
}

// One look at her pose from every lens: whether she shows whole (returned),
// the sideways step range LOOK_DLO .. LOOK_DHI (m) that keeps the points a
// span leaves in sight so, how wide she stands across the view (LOOK_EXT, m
// at her distance) and how many points a bridge span hides (LOOK_SHUT).
let LOOK_DLO: f64 = 0, LOOK_DHI: f64 = 0, LOOK_EXT: f64 = 0, LOOK_SHUT: f64 = 0;
function look(B: Boss, ctx: Ctx, far: f64): bool {
    let sc = ctx.railS + B.s * far;
    ctx.railFrame(sc);
    let pos = ctx.rfPos, f = ctx.rfFwd, rt = ctx.rfRight;
    let ffx: f64 = f.x, ffz: f64 = f.z;
    let fl = lmax(Math.sqrt(ffx * ffx + ffz * ffz), 1e-6);
    let fx_ = ffx / fl, fz_ = ffz / fl;
    let rtx: f64 = rt.x, rtz: f64 = rt.z;
    let posx: f64 = pos.x, posz: f64 = pos.z;
    let dlo = -HUGE, dhi = HUGE;
    let ext = 0.0;
    let shut = 0.0;
    models.point(B.xf, 0, CENTER_Y, 0);
    let cx = models.POINT_X, cz = models.POINT_Z;
    // (the hull's world points and rail s once per look, not per lens)
    let hm = memo(B);
    hullPoints(B, hm);
    let X = hm.px, Y = hm.py, Z = hm.pz;
    let SP = hm.sp;
    for (let i = 1; i <= HULL_N; i++) SP[i] = sc + (X[i] - posx) * fx_ + (Z[i] - posz) * fz_;
    for (let e = 1; e <= sightN; e++) {
        let S = SIGHTS[e];
        // a sideways step of hers turns her bearings by k / dist
        let k = lmax(rtx * S.rx + rtz * S.rz, 0.2);
        let aim = Math.atan2((cx - S.ex) * S.rx + (cz - S.ez) * S.rz, (cx - S.ex) * S.fx + (cz - S.ez) * S.fz);
        let bmin = HUGE, bmax = -HUGE;
        for (let i = 1; i <= HULL_N; i++) {
            let lo = lv.sightAt(S, SP[i], X[i], Y[i], Z[i], aim);
            let hi = lv.SIGHTAT_HI, beta = lv.SIGHTAT_BETA, dist = lv.SIGHTAT_DIST;
            if (lo > hi) {
                shut += 1;
            } else {
                let m = SIGHT_A + SIGHT_M / dist;
                dlo = lmax(dlo, (lo + m - beta) * dist / k);
                dhi = lmin(dhi, (hi - m - beta) * dist / k);
            }
            bmin = lmin(bmin, beta);
            bmax = lmax(bmax, beta);
        }
        ext = lmax(ext, (bmax - bmin) * lmax(sc - S.se, 1));
    }
    LOOK_DLO = dlo;
    LOOK_DHI = dhi;
    LOOK_EXT = ext;
    LOOK_SHUT = shut;
    return shut == 0 && dlo <= dhi;
}

// how badly a look misses (points a span hides first, then m of window short)
function miss(dlo: f64, dhi: f64, shut: f64): f64 {
    return shut * 1e4 + lclamp(dlo - dhi, 0, 1e4 - 1);
}

function xmax(B: Boss, ctx: Ctx, far: f64): f64 {
    return SIGHT_X + SIGHT_XK * lmax(0, ctx.railS + B.s * far - sightS);
}
function place(B: Boss, W: World, ctx: Ctx, dt: f64, far: f64, D: f64): void {
    B.s = (sightS + D - ctx.railS) / far;
    world(B, W, ctx, dt);
}

function sight(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let far = lmax(W.far, 0.1);
    world(B, W, ctx, dt);
    let low = HUGE;
    let QH = memo(B).qh;
    for (let i = 1; i <= HULL_N; i++) low = lmin(low, QH[i]);
    lenses(B, W, ctx, lmax(0, low));
    if (sightN == 0) return;
    // whole where she is: the least sideways step that keeps her so
    let ok = look(B, ctx, far);
    let dlo = LOOK_DLO, dhi = LOOK_DHI, ext = LOOK_EXT, shut = LOOK_SHUT;
    if (ok) {
        let sh = lclamp(0, dlo, dhi);
        if (Math.abs(sh) > 1e-3) {
            let xm = xmax(B, ctx, far);
            B.x = lclamp(B.x + sh, -xm, xm);
            world(B, W, ctx, dt);
        }
        return;
    }
    // too wide for the window here (or a bridge span in the way): centred on
    // it, she stands further off until she fits, then back in to the
    // nearest fit
    let D = lmax(ctx.railS + B.s * far - sightS, 20);
    let Dmax = ctx.railS + SIGHT_MAX - sightS;
    let lo = D;
    let hi = -1.0;
    let hx = B.x;
    // (if nothing fits, the least missing pose looked at)
    let bestD = D, bestX = B.x;
    let bestMiss = miss(dlo, dhi, shut);
    if (dlo > -HUGE && dhi < HUGE) bestX = B.x + (dlo + dhi) * 0.5;
    for (let it = 1; it <= 10; it++) {
        let win = dlo > -HUGE && dhi < HUGE;
        if (win) {
            let xm = xmax(B, ctx, far);
            B.x = lclamp(B.x + (dlo + dhi) * 0.5, -xm, xm);
        }
        let rho = 1.3;
        if (win && shut == 0 && ext > 1) {
            rho = lclamp(ext / lmax(ext - (dlo - dhi), ext * 0.4) * 1.01, 1.01, 1.6);
        }
        D = lmin(D * rho, Dmax);
        place(B, W, ctx, dt, far, D);
        ok = look(B, ctx, far);
        dlo = LOOK_DLO;
        dhi = LOOK_DHI;
        ext = LOOK_EXT;
        shut = LOOK_SHUT;
        if (ok) {
            hi = D;
            hx = B.x + lclamp(0, dlo, dhi);
            break;
        }
        let ms = miss(dlo, dhi, shut);
        if (ms < bestMiss) {
            bestMiss = ms;
            bestD = D;
            bestX = B.x;
            if (dlo > -HUGE && dhi < HUGE) bestX = B.x + (dlo + dhi) * 0.5;
        }
        lo = D;
        if (D >= Dmax) break;
    }
    if (hi < 0) {
        let xm = xmax(B, ctx, far);
        B.x = lclamp(bestX, -xm, xm);
        place(B, W, ctx, dt, far, bestD);
        return;
    }
    for (let it = 1; it <= 4; it++) {
        if (hi < lo * 1.02) break;
        let mid = (lo + hi) * 0.5;
        place(B, W, ctx, dt, far, mid);
        let ok2 = look(B, ctx, far);
        let a = LOOK_DLO, b = LOOK_DHI;
        if (ok2) {
            hi = mid;
            hx = B.x + lclamp(0, a, b);
        } else {
            lo = mid;
            if (a > -HUGE && b < HUGE) {
                let xm = xmax(B, ctx, far);
                B.x = lclamp(B.x + (a + b) * 0.5, -xm, xm);
            }
        }
    }
    let xm = xmax(B, ctx, far);
    B.x = lclamp(hx, -xm, xm);
    place(B, W, ctx, dt, far, hi);
}

// Held at `cap` (rail s) on the bearing the guard picked (the slot's
// window: the least step that keeps her whole, else its centre), slid back
// toward x1 (room's pose this frame, clear at any s beyond) as rock needs.
function recede(B: Boss, W: World, ctx: Ctx, dt: f64, cap: f64, x1: f64): void {
    let far = lmax(W.far, 0.1);
    let px = ctx.player.x;
    let d0 = lmax(B.s * far, 1);
    B.s = (cap - ctx.railS) / far;
    B.x = px + (B.x - px) * lmax(B.s * far, 1) / d0;
    world(B, W, ctx, dt);
    if (sightN > 0) {
        let ok = look(B, ctx, far);
        let dlo = LOOK_DLO, dhi = LOOK_DHI;
        if (dlo > -HUGE && dhi < HUGE) {
            let xm = SIGHT_X + SIGHT_XK * lmax(0, cap - sightS);
            B.x = lclamp(B.x + (ok ? lclamp(0, dlo, dhi) : (dlo + dhi) * 0.5), -xm, xm);
        }
    }
    let sc = roomNeed(B, W, ctx, dt);
    let need = RN_NEED;
    if (need > sc + 1e-3) {
        let xc = B.x;
        let a = 0.0, b = 1.0;
        for (let it = 1; it <= 7; it++) {
            let m = (a + b) * 0.5;
            B.x = x1 + (xc - x1) * m;
            let sc2 = roomNeed(B, W, ctx, dt);
            let need2 = RN_NEED;
            if (need2 > sc2 + 1e-3) {
                b = m;
            } else {
                a = m;
            }
        }
        B.x = x1 + (xc - x1) * a;
    }
    room(B, W, ctx, dt);
}

// Places her (world) clear of rock and whole in the camera's view (room,
// sight). Until she goes down or runs she closes on the pilot by at most
// APPROACH of her distance per second and backs off by at most RECEDE.
function guard(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    let far = lmax(W.far, 0.1);
    let v = B.v;
    let held = B.phase <= 3 && v.sAbs > -1e8;
    if (held) {
        let floor = ctx.railS + (v.sAbs - ctx.railS) * Math.exp(-APPROACH * dt);
        if (ctx.railS + B.s * far < floor) B.s = (floor - ctx.railS) / far;
    }
    room(B, W, ctx, dt);
    let s1 = ctx.railS + B.s * far, x1 = B.x;
    sight(B, W, ctx, dt);
    room(B, W, ctx, dt);
    if (B.phase == 0 && v.storm == 1) {
        // out of the storm: pinned to the world and to time until LOCK0, then
        // the slot's sight step eases in (damped); rock clearance always holds
        let ds = ctx.railS + B.s * far - s1, dx = B.x - x1;
        if (B.phaseT < LOCK0) {
            ds = 0;
            dx = 0;
        }
        let k = 1 - Math.exp(-SIGHT_EASE * dt);
        let sds = v.sds, sdx = v.sdx;
        sds += (ds - sds) * k;
        sdx += (dx - sdx) * k;
        v.sds = sds;
        v.sdx = sdx;
        B.s = (s1 + sds - ctx.railS) / far;
        B.x = x1 + sdx;
        room(B, W, ctx, dt);
    }
    // (not while the sting's reveal shot is due or up: a cut)
    let cut = B.phase == 0 && v.stung == 0 && B.phaseT > STING_AT - 0.3;
    if (held && !cut && !ctx.stingActive()) {
        let cap = lmax(s1, ctx.railS + (v.sAbs - ctx.railS) * Math.exp(RECEDE * dt));
        if (ctx.railS + B.s * far > cap + 1e-3) recede(B, W, ctx, dt, cap, x1);
    }
    v.sAbs = ctx.railS + B.s * far;
}

function placeParts(B: Boss): void {
    let x = B.xf;
    for (let i = 1; i <= 4; i++) {
        let e = pod(B, i);
        let p = PODS[i];
        models.point(x, p[1], p[2], p[3]);
        e.x = models.POINT_X;
        e.y = models.POINT_Y;
        e.z = models.POINT_Z;
    }
    for (let i = 1; i <= 4; i++) {
        let e = cannon(B, i);
        let p = CANNONS[i];
        models.point(x, p[1] + p[4] * 1.2, p[2], p[3]);
        e.x = models.POINT_X;
        e.y = models.POINT_Y;
        e.z = models.POINT_Z;
    }
    let c = core(B);
    models.point(x, CORE_X, CORE_Y, CORE_Z);
    c.x = models.POINT_X;
    c.y = models.POINT_Y;
    c.z = models.POINT_Z;
    for (let i = 1; i <= 5; i++) {
        let a = B.parts[9 + i];
        models.point(x, 0, 0, ARMOR[i][1]);
        a.x = models.POINT_X;
        a.y = models.POINT_Y;
        a.z = models.POINT_Z;
        a.radius = ARMOR[i][2] * SCALE;
    }
}

function flak(B: Boss, W: World, ctx: Ctx): void {
    models.point(B.xf, (lrandom() - 0.5) * 4, -15.2, 6);
    let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
    ai.aimAtPlayer(W, ctx, ox, oy, oz, 70, 7);
    let dx = ai.AIM_AT_PLAYER_1, dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
    let d = ai.distToPlayer(ctx, ox, oy, oz);
    let fuse = d / (70 + 40) + (lrandom() - 0.5) * 0.25;
    ai.bullet(W, 2, ox, oy, oz, dx * 70, dy * 70, dz * 70, 0.08, 4, 0.5, 0.2, 0.2, 0.2, fuse);
    fx.muzzle(W.fx, ox, oy, oz, dx, dy, dz, 1.4, 1, 0.6, 0.2);
    ctx.sfx("laser", 0.3);
}

function launchDrone(B: Boss, W: World, ctx: Ctx, side: f64): void {
    let e = ai.enemy("drone", "hover", 2, 3.3, 100);
    e.scale = 1.1;
    e.rel = true;
    e.s = ai.bossS(W, B) - 6;
    e.rx = B.x + side * 4;
    e.ry = B.y - 18;
    e.p1 = ai.bossS(W, B) - 30 - lrandom() * 12;
    e.p2 = B.x + side * (10 + lrandom() * 8);
    e.p3 = mathx.clamp(B.y - 16, 6, 22);
    e.p4 = 7;
    e.side = side;
    e.fireT = 1.4;
    W.list.push(e);
    ctx.stats.killsTotal += 1;
}

// Rail distance where the final blast must land (well before the portal mouth).
function blastLine(B: Boss): f64 {
    return B.sEnd + BLAST_AT;
}

// Death animation rate so the final blast lands by the blast line at the
// pilot's actual speed (a boost surges to the cap + 25).
function deathRate(B: Boss, ctx: Ctx, left: f64): f64 {
    let pl = ctx.player;
    let sp = lmax(lmax(pl.speed, pl.boosting ? HOLD_DEATH + 25 : HOLD_DEATH), 1);
    let room = (blastLine(B) - ctx.railS) / sp;
    if (room <= 0.05) return HUGE;
    return lmax(1, left / room);
}

// The still frame's focus point (FRAME_UP, CEIL_*): over her spot (rail
// point plus her lateral offset; returned), world y (STILL_Y).
const crestXf: Xf = models.xf();
let STILL_Y: f64 = 0;
function still(B: Boss, W: World, ctx: Ctx, dt: f64): Vector {
    let v = B.v;
    let far = lmax(W.far, 0.1);
    let tall = mathx.saturate((far - 1) / 0.3);
    let farR = fx.stormFar(far);
    ctx.railFrame(ctx.railS + B.s * far);
    let pos = ctx.rfPos, f = ctx.rfFwd, rt = ctx.rfRight;
    let spot = pos + rt * <f32>B.x;
    // (the hold's stand-off: on a narrow screen it comes in to PORT_HOLD's)
    let pk = mathx.lerp(1, PORT_HOLD, 1 - wide(W));
    let holdW = 165 * mathx.lerp(farR, far * pk, mathx.saturate((B.phaseT - NEAR1) / (LOCK1 - NEAR1)));
    let near = lmin(1, NEAR_K * (1 - (B.s * far + LENS_BACK) / (holdW + LENS_BACK)));
    let posy: f64 = pos.y;
    let base = posy + HOLD_Y + LIFT + mathx.lerp(FRAME_UP, FRAME_UP_TALL, tall) + mathx.lerp(CENTER_Y, TOP_Y, lmax(near, 0)) * SCALE;
    let lift = v.lift;
    if (B.phaseT > CEIL_T0) {
        // on the core's view: her own top, the top of her crest, and how far
        // down a meter up of the point moves her
        let vt = 1.0, vc = 1.0;
        for (let j = 1; j < TOPS.length; j++) {
            let i = TOPS[j];
            models.point(B.xf, HX[i], HY[i], HZ[i]);
            ai.screen(W, ctx, models.POINT_X, models.POINT_Y, models.POINT_Z);
            let sv = ai.SCREEN_2, d = ai.SCREEN_3;
            if (d > 0) vt = lmin(vt, sv);
        }
        let qx = W.fx.storm.x;
        let fX: f64 = f.x, fY: f64 = f.y, fZ: f64 = f.z, rX: f64 = rt.x, rZ: f64 = rt.z;
        let posx: f64 = pos.x, posz: f64 = pos.z;
        for (let c = 1; c <= 3; c++) {
            rise(CREST[c], qx, tall);
            let x = RISE_X, y = RISE_Y, yaw = RISE_YAW, pitch = RISE_PITCH, heel = RISE_HEEL;
            let cy = Math.cos(yaw), sy = Math.sin(yaw);
            let hx = fX * cy - rX * sy, hy = fY * cy, hz = fZ * cy - rZ * sy;
            let cp = Math.cos(pitch), sp = Math.sin(pitch);
            models.aim(crestXf, posx + rX * x, posy + y, posz + rZ * x, hx * cp, hy * cp + sp, hz * cp, 0, 1, 0, heel, SCALE);
            for (let j = 1; j < TOPS.length; j++) {
                let i = TOPS[j];
                models.point(crestXf, HX[i], HY[i], HZ[i]);
                ai.screen(W, ctx, models.POINT_X, models.POINT_Y, models.POINT_Z);
                let sv = ai.SCREEN_2, d = ai.SCREEN_3;
                if (d > 0) vc = lmin(vc, sv);
            }
        }
        // (the crest only drifts with the view: lead it; smoothed, the shake
        // jitters it)
        let cf0 = isNaN(v.crestV) ? vc : v.crestV;
        let cf = mathx.damp(cf0, vc, 10, dt);
        let lead = cf + lmin(0, cf - cf0) / lmax(dt, 1e-3) * CEIL_LEAD;
        v.crestV = cf;
        let need = mathx.lerp(CEIL_V, CEIL_V_TALL, tall) - lmin(vt, lead);
        if (need > 0) {
            let y0 = base + lift;
            let spx: f64 = spot.x, spz: f64 = spot.z;
            ai.screen(W, ctx, spx, y0, spz);
            let v0 = ai.SCREEN_2, d0 = ai.SCREEN_3;
            ai.screen(W, ctx, spx, y0 + 10, spz);
            let v1 = ai.SCREEN_2, d1 = ai.SCREEN_3;
            if (d0 > 0 && d1 > 0 && v0 - v1 > 1e-4) {
                lift = lmin(lift + need * 10 / (v0 - v1) * (1 - Math.exp(-CEIL_RATE * dt)), 30);
            }
        }
    }
    v.lift = lift;
    STILL_Y = base + lift;
    return spot;
}

// a thunder roll with her strikes (the 'thunder' sound, once it exists)
const THUNDER: bool = sfxLib.duration("thunder") > 0;
function thunder(ctx: Ctx, vol: f64): void {
    if (THUNDER) ctx.sfx("thunder", vol);
}

// torn cloud off her as she heaves up through the shelf: a small light wisp
// that pours down and thins fast (its own random stream, fx.quiet)
let murkSeed: f64 = 777;
function murkRand(): f64 {
    murkSeed = mod(murkSeed * 16807, 2147483647);
    return (murkSeed - 1) / 2147483646;
}
function murk(W: World, x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, size: f64, life: f64): void {
    fx.emit(W.fx, 0, x, y, z, vx, vy, vz, size, size * 0.8, 1.2,
        0.58, 0.58, 0.76, 0.6, 0.8, 0.8, 0.9, life, 0, 1.4, 5, 0);
}
// v.sp1 .. sp4 (Luau v[SPIN[i]])
function spinGet(v: BossV, i: i32): f64 {
    return i == 1 ? v.sp1 : i == 2 ? v.sp2 : i == 3 ? v.sp3 : v.sp4;
}
function spinAdd(v: BossV, i: i32, d: f64): void {
    if (i == 1) v.sp1 += d;
    else if (i == 2) v.sp2 += d;
    else if (i == 3) v.sp3 += d;
    else v.sp4 += d;
}

export function update(B: Boss, W: World, ctx: Ctx, dt: f64): void {
    B.t += dt;
    B.phaseT += dt;
    let v = B.v;
    let t = B.t;
    let ph = B.phase;
    // (broadside: the clock runs while she shows a flank, not as she comes about)
    if (ph != 2) v.etaT += dt;
    v.phaseEta = phaseEta(B);

    // escape when the portal comes up (with the core exposed it hangs on a little longer)
    let escapeS = ph == 3 ? B.sEnd + HANG : B.sEnd;
    if (!B.killed && !B.escaped && ctx.railS > escapeS) {
        B.escaped = true;
        B.phase = 5;
        B.phaseT = 0;
        for (let i = 1; i < B.parts.length; i++) B.parts[i].hidden = true;
        holdSpeed(ctx, NaN);
        // the bar goes at once so the escape slab gets the centre slot
        ctx.boss(false, NAME, lmax(health(B), 0.05));
        ai.say(W, "baron", "Ta-ta, rocket boy! The portal waits for no one!", 3, 4, "happy");
        ai.banner(W, "STORMCROW ESCAPED", "SHE RAN FOR THE PORTAL", "warning", 3);
        if (ai.LOG) console.log(format("CROW escaped at s=%.0f t=%.1f ph=%d", [N(ctx.railS), N(B.t), N(ph)]));
        ph = 5;
    }

    if (ph == 0) {
        let t0 = B.phaseT;
        let hold = mathx.saturate((t0 - EMERGE) / (TURN - EMERGE));
        let turn = mathx.easeInOutCubic(mathx.saturate((t0 - TURN) / (REVEAL - TURN)));
        let F = W.fx;
        if (v.storm == 1) {
            let Q = F.storm;
            // OUT OF THE STORM: low inside the shelf while lightning and her
            // searchlights stab out of the murk; she rears and heaves up out
            // of it, engines catching, sweeps broadside as the shelf
            // collapses and settles onto the hold for the sting, then turns
            // in and drops into the fight. Pinned to the world while hidden,
            // then paced NEAR_S ahead
            let far = lmax(W.far, 0.1);
            // (portrait: nearer and higher at the hold; PORT_*)
            let tall = 1 - wide(W);
            let pk = mathx.lerp(1, PORT_HOLD, tall);
            rise(t0, Q.x, tall);
            let rx = RISE_X, ry = RISE_Y, yawA = RISE_YAW, pitch = RISE_PITCH, heel = RISE_HEEL, up = RISE_UP;
            // (the camera's portrait offset: off with the poster card's cut)
            v.portUp = v.stung == 1 ? 0 : up * (1 - turn);
            // (rail m) pinned over her spot; the floor runs from the rise's
            // stand-off to the hold by LOCK1. A narrow screen keeps its
            // stand-off and height
            let closeIn = hold * (1 - tall);
            let holdS = (165 - 18 * closeIn) * pk;
            let relW = fx.stormAnchorS(F, far) + HID_BACK - ctx.railS;
            let nk = mathx.smoothstep(NEAR0, NEAR1, t0);
            let floor = mathx.lerp(NEAR_S * fx.stormFar(far), holdS * far, mathx.saturate((t0 - NEAR1) / (LOCK1 - NEAR1)));
            relW += nk * NEAR_SOFT * Math.log(1 + Math.exp((floor - relW) / NEAR_SOFT));
            let lock = mathx.smoothstep(LOCK0, LOCK1, t0);
            // (and eases out to the fight's station under the poster card)
            if (tall > 0) holdS = mathx.lerp(holdS, lmax(holdS, 104), mathx.smoothstep(STING_AT, TURN, t0));
            B.s = mathx.lerp(mathx.lerp(relW / far, holdS, lock), 104, turn);
            B.x = mathx.lerp(rx - 4 * hold, 0, turn);
            B.y = mathx.lerp(ry - 2 * closeIn, 22, turn);
            B.yaw = mathx.lerp(yawA, 0, mathx.smoothstep(TURN - 0.4, REVEAL, t0));
            B.pitch = pitch;
            B.roll = Math.sin(t * 0.5) * 0.04 + heel * (1 - turn);
            // a slow shake while she heaves
            if (t0 > T_HEAVE && t0 < T_PEAK) ctx.shake(0.07);
            // its shadow rolls up the slot over the pilot, gone as she is out
            fx.stormSweep(F, mathx.smoothstep(0, 0.9, t0) * (1 - mathx.smoothstep(COLLAPSE_AT, COLLAPSE_AT + 0.8, t0)));
            // lightning with the horn, and the bolt behind her as she clears
            let hx = HID_X;
            if (v.bolt == 0 && t0 >= 0.05) {
                v.bolt = 1;
                fx.stormStrike(F, true, true, hx - 34);
                ctx.shake(0.15);
                thunder(ctx, 0.7);
            }
            if (v.bolt == 1 && t0 >= T_STRIKE) {
                v.bolt = 2;
                fx.stormStrike(F, true, true, hx + 26);
                fx.stormStrike(F, false, true, hx - 20, true);
                ctx.shake(0.3);
                thunder(ctx, 0.9);
            }
            if (v.col == 0 && t0 >= COLLAPSE_AT) {
                v.col = 1;
                fx.stormCollapse(F);
                fx.stormRelease(F, DRIFT);
            }
            if (v.brk == 0 && t0 >= T_BREAK) {
                v.brk = 1;
                fx.stormBreakUp(F);
            }
        } else {
            // (a run that starts past the mouth) comes down out of open sky
            // ahead, drifting in from the right broadside; the guard holds her
            // further off down the valley until the mouth opens round her
            let e = mathx.easeOutCubic(mathx.saturate(t0 / EMERGE));
            B.s = mathx.lerp(mathx.lerp(300, 165, e) - 18 * hold, 104, turn);
            B.x = mathx.lerp(mathx.lerp(SKY_X, 1, e) - 4 * hold, 0, turn);
            B.y = mathx.lerp(HOLD_Y + (SKY_Y - HOLD_Y) * (1 - e) - 2 * hold, 22, turn);
            B.yaw = mathx.lerp(1.45, 0, mathx.smoothstep(TURN - 0.4, REVEAL, t0));
            B.roll = Math.sin(t * 0.5) * 0.04 + (1 - turn) * 0.06 - hold * (1 - turn) * 0.05;
        }
        // the STORMCROW poster, once the warning has left the slot
        if (v.stung == 0 && t0 >= STING_AT && (ctx.alertFree() || t0 > STING_AT + 1.2)) {
            v.stung = 1;
            v.portUp = 0;
            models.point(B.xf, 0, CENTER_Y, 0);
            let cx = models.POINT_X, cy = models.POINT_Y, cz = models.POINT_Z;
            ai.focus(W, ctx, cx, cy, cz, 0.75);
            let took = ai.sting(W, ctx, "boss_stormcrow", NAME, "BARON KESSEL'S SKY GALLEON", cx, cy, cz, FRAME_R);
            v.barT = t0 + (took ? 0.5 : 0);
        }
        // the phase-1 callout queues with the sting; the engines are fair game
        // once she swings in
        if (v.stung == 1 && v.callout != 1) {
            v.callout = 1;
            ai.banner(W, "ENGINES", "KNOCK OUT THE ENGINES", "warning", 3, 1);
        }
        if (pod(B, 1).hidden && t0 > PODS_LIVE) {
            for (let i = 1; i <= 4; i++) pod(B, i).hidden = false;
            v.etaT = 0;
            v.upT = 0;
        }
        if (B.phaseT > REVEAL) setPhase(B, W, ctx, 1);
    } else if (ph == 1) {
        B.s = mathx.damp(B.s, 104 + Math.sin(t * 0.4) * 6, 1.5, dt);
        B.x = mathx.damp(B.x, Math.sin(t * 0.3) * 15, 1.2, dt);
        B.y = mathx.damp(B.y, FIGHT_Y[1] + Math.sin(t * 0.6) * 2, 1.2, dt);
        // list toward lost engines
        let lean = 0.0;
        for (let i = 1; i <= 4; i++) {
            if (!pod(B, i).alive) lean += PODS[i][1] < 0 ? -0.05 : 0.05;
        }
        B.roll = mathx.damp(B.roll, lean + Math.sin(t * 0.5) * 0.04, 1, dt);
        B.yaw = mathx.damp(B.yaw, B.x / 17 * 0.42, 1.5, dt);
        v.flakT -= dt;
        if (v.flakT <= 0) {
            v.flakT = 1.25;
            flak(B, W, ctx);
        }
        v.sternT -= dt;
        if (v.sternT <= 0) {
            v.sternT = 2.8;
            v.burst = 5;
        }
        let alive = 0;
        for (let i = 1; i <= 4; i++) {
            if (pod(B, i).alive) alive += 1;
        }
        if (alive == 0 && B.phaseT > 0.5) setPhase(B, W, ctx, 2);
    } else if (ph == 2) {
        // present the flank that still has guns
        let leftAlive = cannon(B, 1).alive || cannon(B, 2).alive;
        let rightAlive = cannon(B, 3).alive || cannon(B, 4).alive;
        if (v.side < 0 && !leftAlive && rightAlive) {
            v.side = 1;
            v.fireT = lmax(v.fireT, 1.6);
            ai.say(W, "hank", "She's coming about! Other side, other side!", 2.6, 2, "worried");
        }
        let targetYaw = v.side < 0 ? 1.3 : -1.3;
        B.yaw = mathx.damp(B.yaw, targetYaw, 1.6, dt);
        // coming about she swings her stern past the camera: nose up, so the
        // top fin dips instead of running off the top of the frame
        B.pitch = mathx.damp(B.pitch, SWAP_PITCH * (1 - mathx.smoothstep(0.35, 1.0, Math.abs(B.yaw))), 4, dt);
        B.s = mathx.damp(B.s, 94, 1, dt);
        B.x = mathx.damp(B.x, -v.side * 6 + Math.sin(t * 0.35) * 5, 0.8, dt);
        B.y = mathx.damp(B.y, FIGHT_Y[2] + Math.sin(t * 0.7) * 2, 1, dt);
        B.roll = mathx.damp(B.roll, -v.side * 0.12 + Math.sin(t * 0.8) * 0.03, 1, dt);
        let facing = Math.abs(B.yaw - targetYaw) < 0.5;
        if (facing) v.etaT += dt;
        let was = v.fireT;
        if (facing || v.fireT > TELE) v.fireT -= dt;
        if (was > TELE && v.fireT <= TELE) {
            // gun ports glow: a volley is coming
            ctx.sfx("charge", 0.35);
        }
        if (v.fireT <= 0) {
            v.fireT = 2.3;
            for (let i = 1; i <= 4; i++) {
                let c = cannon(B, i);
                if (c.alive && CANNONS[i][4] == v.side) {
                    // volley: three orbs fanned around the player
                    for (let k = -1.0; k <= 1; k++) {
                        let ox = c.x, oy = c.y, oz = c.z;
                        ai.aimAtPlayer(W, ctx, ox, oy, oz, 30, 2);
                        let dx = ai.AIM_AT_PLAYER_1, dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
                        let rt = ctx.player.right;
                        dx += <f64>rt.x * k * 0.12;
                        dz += <f64>rt.z * k * 0.12;
                        ai.bullet(W, 1, ox, oy, oz, dx * 30, dy * 30, dz * 30, 0.1, 5, 0.9, 1, 0.45, 0.2, 0);
                    }
                    fx.muzzle(W.fx, c.x, c.y, c.z, 0, 0, 0, 3, 1, 0.6, 0.2);
                    fx.carry(W.fx, v.hvx, v.hvy, v.hvz);
                    fx.smoke(W.fx, c.x, c.y, c.z, 1.6, 0.4);
                    fx.carry(W.fx, 0, 0, 0);
                }
            }
            ctx.sfx("explode_small", 0.35);
        }
        v.sternT -= dt;
        if (v.sternT <= 0) {
            v.sternT = 3.4;
            v.burst = 4;
        }
        let any = leftAlive || rightAlive;
        if (!any && B.phaseT > 0.5) setPhase(B, W, ctx, 3);
    } else if (ph == 3) {
        // swings side to side, showing a three-quarter view of the burning hull
        B.yaw = mathx.damp(B.yaw, CORE_YAW * Math.sin(t * 0.32), 1.2, dt);
        B.pitch = mathx.damp(B.pitch, CORE_PITCH, 1, dt);
        // (she backs off to her core station quickly)
        let st = CORE_S + CORE_S_WIDE * wide(W) + Math.sin(t * 0.5) * 5;
        B.s = mathx.damp(B.s, st, B.s < st ? 1.8 : 1, dt);
        B.x = mathx.damp(B.x, Math.sin(t * 0.45) * 10, 1, dt);
        B.y = mathx.damp(B.y, FIGHT_Y[3] + Math.sin(t * 0.9) * 2, 1, dt);
        B.roll = mathx.damp(B.roll, Math.sin(t * 0.7) * 0.08, 1, dt);
        v.flakT -= dt;
        if (v.flakT <= 0) {
            v.flakT = 1.6;
            flak(B, W, ctx);
        }
        let was = v.rocketT;
        v.rocketT -= dt;
        if (was > TELE && v.rocketT <= TELE) ctx.sfx("lock", 0.4);
        if (v.rocketT <= 0) {
            v.rocketT = 3.2;
            for (let side = -1.0; side <= 1; side += 2) {
                models.point(B.xf, side * 2.6, -13, 11);
                let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
                ai.aimAtPlayer(W, ctx, ox, oy, oz, 40, 10);
                let dx = ai.AIM_AT_PLAYER_1, dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
                ai.bullet(W, 3, ox, oy, oz, dx * 42, dy * 42 - 4, dz * 42, 0.1, 5, 0.6, 1, 0.5, 0.2, 1.5);
                fx.muzzle(W.fx, ox, oy, oz, dx, dy, dz, 1.2, 1, 0.6, 0.2);
            }
            ctx.sfx("explode_small", 0.3);
        }
        v.droneT -= dt;
        if (v.droneT <= 0) {
            v.droneT = 6;
            launchDrone(B, W, ctx, -1);
            launchDrone(B, W, ctx, 1);
        }
    } else if (ph == 4) {
        // going down in flames (sped up so the final blast lands by the blast
        // line at the pilot's real speed)
        if (v.deathT < DEATH_BLAST) v.deathRate = deathRate(B, ctx, DEATH_BLAST - v.deathT);
        let dd = lmin(dt * v.deathRate, lmax(DEATH_BLAST - v.deathT, dt));
        v.deathT += dd;
        let rk = lmin(v.deathRate, 6);
        B.pitch = mathx.damp(B.pitch, -0.5, 0.6 * rk, dt);
        B.roll = mathx.damp(B.roll, 0.35, 0.5 * rk, dt);
        B.y -= dd * (3 + v.deathT * 4.5);
        B.s = mathx.damp(B.s, 135, 0.6, dt);
        v.boomT -= dd;
        if (v.boomT <= 0 && v.deathT < 3.4) {
            v.boomT = 0.16;
            let lz = (lrandom() - 0.5) * 56;
            let ly = (lrandom() - 0.5) * 12 - 2;
            let lx = (lrandom() - 0.5) * 12;
            models.point(B.xf, lx, ly, lz);
            let wx = models.POINT_X, wy = models.POINT_Y, wz = models.POINT_Z;
            fx.carry(W.fx, v.hvx * 0.85, v.hvy * 0.85, v.hvz * 0.85);
            fx.explosion(W.fx, wx, wy, wz, 1.3 + lrandom() * 0.6, "boom");
            fx.carry(W.fx, 0, 0, 0);
            ctx.sfx("explode_small", 0.6);
            ctx.shake(0.35);
        }
        if (v.deathT >= DEATH_BLAST && v.boomT > -10) {
            // the final blast: spectacle only (the kill was announced and
            // paid when the core went)
            v.boomT = -100;
            let wx = B.xf.px, wy = B.xf.py, wz = B.xf.pz;
            fx.explosion(W.fx, wx, wy, wz, 4, "huge");
            fx.explosion(W.fx, wx, wy - 14, wz, 2.5, "big");
            fx.confetti(W.fx, wx, wy - 6, wz, 3, 24);
            ctx.sfx("explode_big", 1);
            ctx.shake(1.6);
            holdSpeed(ctx, NaN);
            if (ai.LOG) console.log(format("CROW final blast at s=%.0f t=%.1f", [N(ctx.railS), N(B.t)]));
        }
        if (v.deathT > 4.2) B.done = true;
    } else if (ph == 5) {
        // escape: end-on through the middle of the portal, then climb away
        let u = B.phaseT;
        B.s += dt * (20 + u * 40);
        let g = lv.portal;
        if (ctx.railS + ai.bossS(W, B) < g.s + 30) {
            B.y = mathx.damp(B.y, g.y + 8, 1.2, dt);
            B.pitch = mathx.damp(B.pitch, 0.04, 1, dt);
        } else {
            B.y += dt * (6 + u * 8);
            B.pitch = mathx.damp(B.pitch, 0.18, 1, dt);
        }
        B.x = mathx.damp(B.x, g.x, 1.2, dt);
        B.yaw = mathx.damp(B.yaw, 0, 1.5, dt);
        B.roll = mathx.damp(B.roll, 0, 1, dt);
        if (u > 5) B.done = true;
    }

    floors(B, dt);
    guard(B, W, ctx, dt);
    placeParts(B);
    // her velocity (world m/s): smoke off her burning stubs and the armor
    // she sheds ride along with her (fx.carry)
    let hx0 = B.xf.px, hy0 = B.xf.py, hz0 = B.xf.pz;
    let hvx = 0.0, hvy = 0.0, hvz = 0.0;
    if (v.hSet > 0 && dt > 1e-4) {
        hvx = (hx0 - v.hx) / dt;
        hvy = (hy0 - v.hy) / dt;
        hvz = (hz0 - v.hz) / dt;
        if (hvx * hvx + hvy * hvy + hvz * hvz > 160 * 160) {
            hvx = 0;
            hvy = 0;
            hvz = 0;
        }
    }
    v.hx = hx0;
    v.hy = hy0;
    v.hz = hz0;
    v.hSet = 1;
    v.hvx = hvx;
    v.hvy = hvy;
    v.hvz = hvz;

    // engines: idling in the murk, they catch one after another as she rises
    // out (a cough of smoke and a flare each; the prop roar as the second and
    // the fourth catch); the props' turn (draw)
    let storming = ph == 0 && v.storm == 1;
    for (let i = 1; i <= 4; i++) {
        let rate = <f64>(18 + i);
        if (storming) {
            let on0 = SPIN0 + 0.2 * <f64>(i - 1);
            rate = mathx.lerp(1.1, rate, mathx.smoothstep(on0, on0 + 0.7, B.phaseT));
            if (B.phaseT >= on0 && v.roar < <f64>i) {
                v.roar = i;
                let e = pod(B, i);
                let p = PODS[i];
                models.point(B.xf, p[1], p[2], p[3] + 4.2);
                let qx = models.POINT_X, qy = models.POINT_Y, qz = models.POINT_Z;
                fx.quiet(true);
                fx.carry(W.fx, hvx * 0.6, hvy * 0.6, hvz * 0.6);
                for (let k = 1; k <= 4; k++) fx.smoke(W.fx, qx, qy, qz, 3.2, 0.95);
                fx.carry(W.fx, 0, 0, 0);
                fx.glow(W.fx, e.x, e.y, e.z, 9, 1, 0.6, 0.25, 0.3);
                fx.quiet(false);
                if (i == 2 || i == 4) {
                    ctx.sfx("flyby", i == 2 ? 1 : 0.8);
                    ctx.shake(i == 2 ? 0.45 : 0.3);
                }
            }
        }
        spinAdd(v, i, rate * dt);
    }
    // torn cloud pouring off her as she heaves up through the shelf
    if (storming && W.fx.storm.on && B.phaseT > T_REAR0 + 0.25 && B.phaseT < COLLAPSE_AT + 0.2) {
        fx.quiet(true);
        for (let k = 1; k <= 2; k++) {
            let i = 1 + <i32>Math.floor(murkRand() * <f64>HULL_N);
            models.point(B.xf, HX[i], HY[i], HZ[i]);
            let wx = models.POINT_X, wy = models.POINT_Y, wz = models.POINT_Z;
            fx.stormLocal(W.fx, wx, wy, wz, true);
            let lx = fx.STORM_LOCAL_X, ly = fx.STORM_LOCAL_Y, lz = fx.STORM_LOCAL_Z;
            // (where her hull is breaking out through the shelf's top)
            let top = fx.stormShelfTop(lx, lz);
            if (top > 0 && Math.abs(ly - top) < 3) {
                let size = 1.8 + murkRand() * 1.6;
                murk(W, wx, wy, wz, hvx * 0.3, hvy * 0.3 - 3, hvz * 0.3, size, 0.4 + murkRand() * 0.3);
            }
        }
        fx.quiet(false);
    }

    // stern gun bursts (phases 1-2)
    if (v.burst > 0 && (ph == 1 || ph == 2)) {
        v.burstT = v.burstT - dt;
        if (v.burstT <= 0) {
            v.burstT = 0.11;
            v.burst -= 1;
            models.point(B.xf, mod(v.burst, 2) * 0.8 - 0.4, -13.2, 13.6);
            let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
            if (ai.ahead(ctx, ox, oy, oz) > 20) ai.tracer(W, ctx, ox, oy, oz, 100, 3.5);
        }
    }

    // burning engine stubs + propeller wash: a short plume that rides with her
    fx.carry(W.fx, hvx, hvy, hvz);
    for (let i = 1; i <= 4; i++) {
        let e = pod(B, i);
        if (!e.alive && ph < 5) {
            if (lrandom() < 0.35) fx.fire(W.fx, e.x, e.y, e.z, 1.4);
            if (lrandom() < 0.22) fx.smoke(W.fx, e.x, e.y + 1, e.z, 1.3, 0.9);
        }
    }
    fx.carry(W.fx, 0, 0, 0);
    // lift core embers
    let c = core(B);
    if (c.alive && ph == 3 && lrandom() < 0.5) {
        let gx = c.x + (lrandom() - 0.5) * 5;
        let gy = c.y + (lrandom() - 0.5) * 5;
        let gz = c.z + (lrandom() - 0.5) * 5;
        fx.glow(W.fx, gx, gy, gz, 0.5, 1, 0.6, 0.2, 0.4);
    }
    // blown armor pieces
    let pcs = B.pieces;
    let j = 1;
    while (j <= pcs.length - 1) {
        let q = pcs[j];
        q[5] -= 22 * dt;
        q[1] += q[4] * dt;
        q[2] += q[5] * dt;
        q[3] += q[6] * dt;
        q[7] += q[8] * dt;
        q[9] -= dt;
        // a thin wisp off each piece, only as it tears away
        if (q[9] > PIECE_LIFE - 0.8 && lrandom() < 0.35) {
            fx.carry(W.fx, q[4] * 0.8, q[5] * 0.8, q[6] * 0.8);
            fx.wisp(W.fx, q[1], q[2], q[3], 0.45, 0.8);
            fx.carry(W.fx, 0, 0, 0);
        }
        if (q[9] <= 0) {
            let n = pcs.length - 1;
            pcs[j] = pcs[n];
            pcs.pop();
        } else {
            j += 1;
        }
    }

    // camera framing: strong during the reveal, gentle during the fight
    let fw = 0.0;
    if (ph == 0) {
        fw = 0.75 * mathx.smoothstep(0, 0.8, B.phaseT);
    } else if (ph >= 1 && ph <= 3) {
        fw = B.phaseT < 1.5 && ph == 2 ? 0.45 : 0.22;
    } else if (ph == 4) {
        fw = 0.6;
    }
    models.point(B.xf, 0, CENTER_Y, 0);
    let cx = models.POINT_X, cy = models.POINT_Y, cz = models.POINT_Z;
    if (ph >= 1 && ph <= 3) {
        v.focusY = mathx.damp(v.focusY, FOCUS_Y[<i32>ph], 1.5, dt);
    } else {
        v.focusY = CENTER_Y;
    }
    if (fw > 0) {
        models.point(B.xf, 0, v.focusY, 0);
        let qx = models.POINT_X, qy = models.POINT_Y, qz = models.POINT_Z;
        // (portrait: aimed as if she were not PORT_UP higher)
        if (ph == 0 && v.storm == 1) qy -= v.portUp;
        if (ph == 0 && v.storm == 1 && B.phaseT < LOCK1) {
            // out of the storm: the still frame (FRAME_UP) over her spot, her
            // own centre (less portUp) from LOCK0 as she settles
            let pos = still(B, W, ctx, dt);
            let sy = STILL_Y;
            let k = mathx.smoothstep(LOCK0, LOCK1, B.phaseT);
            qx = mathx.lerp(pos.x, qx, k);
            qy = mathx.lerp(sy, qy, k);
            qz = mathx.lerp(pos.z, qz, k);
        }
        ai.focus(W, ctx, qx, qy, qz, fw);
    }
    if (ph <= 4) {
        W.focusOn = true;
        W.focusX = cx;
        W.focusY = cy;
        W.focusZ = cz;
        W.focusR = FRAME_R;
    }

    if (ai.LOG && Math.floor(B.t * 2) != Math.floor((B.t - dt) * 2)) {
        ai.screen(W, ctx, cx, cy, cz);
        let cv = ai.SCREEN_2;
        console.log(format("CROW ph=%d pt=%.1f s=%.0f x=%.1f y=%.1f centre v=%.2f (ai.screen) pilot y=%.1f", [N(ph), N(B.phaseT), N(B.s), N(B.x), N(B.y), N(cv), N(ctx.player.y)]));
    }
    // HUD: the bar lands once the poster has had its moment
    if (ph >= 1 && ph <= 3) {
        let h = health(B);
        ctx.boss(true, NAME, h);
    } else if (ph == 0 && v.barT >= 0 && B.phaseT > v.barT) {
        ctx.boss(true, NAME, 1);
    }
}

export function partKilled(B: Boss, W: World, ctx: Ctx, e: Enemy): void {
    let F = W.fx;
    if (e.kind == "crowPod") {
        fx.explosion(F, e.x, e.y, e.z, 1.8, "big");
        ctx.sfx("explode_big", 0.8);
        ctx.shake(0.6);
        ctx.addScore(e.score, e.x, e.y, e.z, "ENGINE");
        let left = 0;
        for (let i = 1; i <= 4; i++) {
            if (pod(B, i).alive) left += 1;
        }
        if (left == 3) {
            ai.say(W, "vi", "One engine down! She is wobbling!", 2.4, 1, "happy");
        } else if (left == 1) {
            ai.say(W, "baron", "Stop that! Do you know what engines COST?", 2.6, 1, "angry");
        }
    } else if (e.kind == "crowCannon") {
        fx.explosion(F, e.x, e.y, e.z, 1.5, "big");
        ctx.sfx("explode_big", 0.7);
        ctx.shake(0.5);
        ctx.addScore(e.score, e.x, e.y, e.z, "CANNON");
    } else if (e.kind == "crowCore") {
        fx.explosion(F, e.x, e.y, e.z, 2.6, "huge");
        fx.confetti(F, e.x, e.y, e.z, 2.4, 18);
        ctx.sfx("explode_big", 1);
        ctx.shake(1.2);
        B.killed = true;
        B.phase = 4;
        B.phaseT = 0;
        B.v.boomT = 0;
        // the kill is announced now, not at the final blast: the DOWNED sting
        // (kill cam on her fall) or the slab; the bar goes at once; the bonus
        // is paid here
        models.point(B.xf, 0, CENTER_Y, 0);
        let cx = models.POINT_X, cy = models.POINT_Y, cz = models.POINT_Z;
        let paid = ai.pay(ctx, 5000, cx, cy, cz, "STORMCROW DOWN");
        ctx.stats.kills += 1;
        let sub = !isNaN(paid) ? format("+%d  //  OBJECTIVE COMPLETE", [N(paid)]) : "OBJECTIVE COMPLETE";
        ai.focus(W, ctx, cx, cy, cz, 0.6);
        if (!ai.sting(W, ctx, "down_stormcrow", NAME, sub, cx, cy, cz, FRAME_R)) {
            ctx.banner("STORMCROW DOWN", sub, "success");
        }
        ctx.boss(false, NAME, 0);
        holdSpeed(ctx, HOLD_DEATH);
        B.v.deathRate = deathRate(B, ctx, DEATH_BLAST);
        if (ai.LOG) console.log(format("CROW killed at s=%.0f t=%.1f", [N(ctx.railS), N(B.t)]));
        for (let i = 1; i < B.parts.length; i++) {
            let p = B.parts[i];
            p.alive = false;
            p.hidden = true;
        }
        // (HANK's cheer and the tower follow it: events)
        ai.say(W, "baron", "My beautiful ship! You will PAY for the paint!", 3, 3, "angry");
    }
}

// Drawing ---------------------------------------------------------------------------------

export function draw(B: Boss, W: World, mo: Models, r: R.Gfx, t: f64): void {
    let x = B.xf;
    // going down she scorches (warm, a shade darker) rather than going black
    let burn = B.phase == 4 ? 0.8 : 1.0;
    // out of the storm: dark in the murk until she is up out of it, lit by
    // the lightning
    let v = B.v;
    let lit = 0.0;
    let mk = 1.0, mkb = 1.0;
    let Q = W.fx.storm;
    if (B.phase == 0 && v.storm == 1 && Q.on) {
        lit = 0.45 * Q.flash * Q.flash;
        let out = mathx.smoothstep(0.75, 1.7, B.phaseT);
        mk = mathx.lerp(MURK_TINT, 1, out);
        mkb = mathx.lerp(lmin(MURK_TINT * 1.2, 1), 1, out);
    }
    models.put(mo.crowHull, x, burn * mk, burn * 0.88 * mk, burn * 0.84 * mkb, lit, 0, 0);
    let c = W.xf2;
    let c2 = W.xf3;
    // engine pods + propellers
    for (let i = 1; i <= 4; i++) {
        let e = pod(B, i);
        let p = PODS[i];
        models.child(c, x, p[1], p[2], p[3], 0, 0, 0, 1);
        let tint = e.alive ? 1.0 : 0.3;
        models.put(mo.crowPod, c, tint * mk, tint * 0.95 * mk, tint * 0.9 * mkb, lmax(e.flash, lit), 0, 0);
        let spin = e.alive ? spinGet(v, i) : 0.6 * <f64>i;
        models.child(c2, c, 0, 0, -4.1, 0, 0, spin, 2.1);
        models.put(mo.prop, c2, tint * mk, tint * mk, tint * mkb, e.flash, 0, 0);
        if (e.alive) {
            models.point(c, 0, 0, -4.2);
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 3.9, 0.92, 0.96, 1, 0.4, 2, 0.5, <f64>i * 0.1, 0);
            models.point(c, 0, 0, 3.8);
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 1.8, 1, 0.55, 0.2, 0.8, 1, 0.5, <f64>i * 0.1, 0);
        }
    }
    // cannons on the gondola flanks
    for (let i = 1; i <= 4; i++) {
        let e = cannon(B, i);
        let p = CANNONS[i];
        let side = p[4];
        models.dir(x, side, 0, 0);
        let ox = models.DIR_X, oy = models.DIR_Y, oz = models.DIR_Z;
        models.point(x, p[1], p[2], p[3]);
        models.aim(c, models.POINT_X, models.POINT_Y, models.POINT_Z, x.fx, x.fy, x.fz, ox, oy, oz, 0, 1.25);
        let tint = e.alive ? 1.0 : 0.3;
        models.put(mo.turretDome, c, tint, tint, tint, e.flash, 0, 0);
        if (e.alive) {
            let ctx = W.ctx;
            let ax = ox, ay = oy, az = oz;
            if (ctx != null) {
                let pp = ctx.player.pos;
                let tx = <f64>pp.x - e.x, ty = <f64>pp.y - e.y, tz = <f64>pp.z - e.z;
                let l = lmax(Math.sqrt(tx * tx + ty * ty + tz * tz), 0.01);
                ax = tx / l + ox * 0.7;
                ay = ty / l + oy * 0.7;
                az = tz / l + oz * 0.7;
            }
            models.aim(c2, e.x, e.y, e.z, ax, ay, az, ox, oy, oz, 0, 1.25);
            models.put(mo.turretGun, c2, 1, 1, 1, e.flash, 0, 0);
        }
    }
    // telegraphs: gun ports heat up before a volley, the stern gun flashes
    // before a burst, the rocket tubes blink before a salvo
    if (B.phase == 2 && v.fireT < TELE) {
        let k = mathx.saturate(1 - v.fireT / TELE);
        let flick = 0.85 + 0.15 * Math.sin(t * 50);
        for (let i = 1; i <= 4; i++) {
            let e = cannon(B, i);
            if (e.alive && CANNONS[i][4] == v.side) {
                R.particle(r, e.x, e.y, e.z, (1.4 + 3.2 * k) * flick, 1, 0.5 + 0.3 * k, 0.15 + 0.3 * k, 0.45 + 0.55 * k, 1, 0.5, <f64>i * 0.2, 0);
            }
        }
    }
    if ((B.phase == 1 || B.phase == 2) && v.sternT < 0.5) {
        let k = mathx.saturate(1 - v.sternT / 0.5);
        models.point(x, 0, -13.2, 13.6);
        R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 1 + 2.2 * k, 1, 0.75, 0.3, 0.5 + 0.5 * k, 1, 0.5, 0.7, 0);
    }
    if (B.phase == 3 && v.rocketT < TELE) {
        let blink = mod(t * 12, 1) < 0.5 ? 1.0 : 0.35;
        for (let side = -1.0; side <= 1; side += 2) {
            models.point(x, side * 2.6, -13, 11);
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 2.4 * blink, 1, 0.3, 0.2, blink, 1, 0.5, 0.4 + side * 0.1, 0);
        }
    }
    // lift core + shutters
    let core0 = core(B);
    models.child(c, x, CORE_X, CORE_Y, CORE_Z, t * 0.6, 0, 0, 1);
    let pulse = B.phase == 3 ? 0.35 + 0.3 * Math.sin(t * 9) : 0.1;
    if (B.phase <= 3) {
        models.put(mo.crowCore, c, 1, 1, 1, core0.flash, pulse, 0);
        if (B.phase == 3) R.particle(r, c.px, c.py, c.pz, 9 + 1.5 * Math.sin(t * 9), 1, 0.55, 0.2, 0.55, 1, 0.5, 0.3, 0);
    }
    if (B.phase < 3) {
        for (let k = 0.0; k <= 3; k++) {
            models.child(c2, x, CORE_X, CORE_Y, CORE_Z, k * Math.PI / 2, 0, 0, 1);
            models.put(mo.crowShutter, c2, 1, 1, 1, core0.flash * 0.5, 0, 0);
        }
    }
    let pcs = B.pieces;
    for (let j = 1; j < pcs.length; j++) {
        let q = pcs[j];
        models.aim(c2, q[1], q[2], q[3], Math.sin(q[7]), Math.cos(q[7] * 0.7), Math.cos(q[7]), 0, 1, 0, q[7], 1);
        models.put(mo.crowShutter, c2, 0.6, 0.55, 0.55, 0, 0, 0);
    }
    // out of the storm: two searchlights on her nose stab up out of the murk
    // (a stutter, then steady) and come down on the canyon mouth as she
    // breaks out (ribbons, depth tested); off as she turns in. Her bulk
    // shades the sea.
    if (B.phase == 0 && v.storm == 1) {
        let t0 = B.phaseT;
        let k = mathx.smoothstep(BEAM0, BEAM0 + 0.2, t0) * (1 - mathx.smoothstep(TURN - 0.3, TURN + 0.3, t0));
        if (t0 < BEAM0 + 0.5 && Math.sin(t0 * 60) < 0) k *= 0.25;
        if (k > 0.01) {
            for (let side = -1.0; side <= 1; side += 2) {
                models.point(x, side * 3.4, -3.5, -30.5);
                let lx = models.POINT_X, ly = models.POINT_Y, lz = models.POINT_Z;
                let sw = 0.5 + 0.5 * Math.sin(t0 * 1.4 + side * 1.6);
                // (the near beam keeps ahead of her bow)
                let yo = side > 0 ? 0.45 + 0.5 * sw : -0.12 - 0.3 * sw;
                // (elevation over the horizon, less her own pitch)
                let pd = B.pitch - mathx.lerp(0.3, -0.04, mathx.smoothstep(0.95, 1.9, t0)) + 0.06 * Math.sin(t0 * 0.9 + side);
                models.dir(x, Math.sin(yo) * Math.cos(pd), -Math.sin(pd), -Math.cos(yo) * Math.cos(pd));
                let dx = models.DIR_X, dy = models.DIR_Y, dz = models.DIR_Z;
                let L = BEAM_LEN;
                if (dy < -1e-3 && ly + dy * L < 0.4) L = (ly - 0.4) / -dy;
                let ex = lx + dx * L, ey = ly + dy * L, ez = lz + dz * L;
                let w1 = 30 * L / BEAM_LEN + 3;
                R.ribbon(r, lx, ly, lz, 2.4, 1, ex, ey, ez, w1, 0.4, 1, 0.96, 0.84, 0.95 * k, 0, 0, 0.25, NaN, NaN, NaN, NaN, NaN, NaN, side);
                R.ribbon(r, lx, ly, lz, 1.6, 1, ex, ey, ez, w1 * 0.35, 0.2, 1, 0.88, 0.62, 0.22 * k, 1, 0, 0.7, NaN, NaN, NaN, NaN, NaN, NaN, side + 5);
                R.particle(r, lx, ly, lz, 9, 1, 0.95, 0.8, k, 1, 0.5, 0.3 + side * 0.1, 0);
                if (L < BEAM_LEN - 1) R.particle(r, ex, 0.6, ez, w1 * 1.1, 1, 0.95, 0.8, 0.35 * k, 1, 0.5, 0.5 + side * 0.1, 0);
            }
        }
        R.shadow(r, x.px, x.pz, 46, 0.4 * mathx.smoothstep(1.0, 2.2, t0));
    }
    // Kessel's pennant streaming from the stern
    models.child(c, x, 0, -13.2, 13.4, 0, 0, 0, 1);
    for (let i = 0; i <= 4; i++) {
        models.put(mo.crowBanner, c, burn, burn, burn, 0, 0, 0);
        let fi = <f64>i;
        let wave = Math.sin(t * 3.2 - fi * 0.9) * 0.32;
        models.child(c2, c, 0, 0, 3.0, wave, Math.sin(t * 2.1 - fi) * 0.05, 0, 0.93);
        c.px = c2.px; c.py = c2.py; c.pz = c2.pz;
        c.rx = c2.rx; c.ry = c2.ry; c.rz = c2.rz;
        c.ux = c2.ux; c.uy = c2.uy; c.uz = c2.uz;
        c.fx = c2.fx; c.fy = c2.fy; c.fz = c2.fz;
        c.s = c2.s;
    }
    // glow of the gondola windows at dusk-ish distance
    models.point(x, 0, -13.2, 13.2);
    R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 1.6, 1, 0.6, 0.25, 0.8, 1, 0.5, 0.9, 0);
}
