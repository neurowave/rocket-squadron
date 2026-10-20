// Port of src/game/player.luau. Flight model: steering inside the rail box
// with response curves and soft edges, bank/pitch, barrel roll, boost/brake,
// heat, skim multiplier and scenery collisions. Pure simulation; feedback
// (sound, HUD, shake) is done by the caller from the returned events.
//
// Port: `new` -> create. Player extends types.Player (ctx.player holds it).
// Multi-returns: update -> UPDATE_1 (Hit) / UPDATE_2 (rolled), boxX ->
// BOX_X_1 / BOX_X_2 (lo, hi). scenery.collide always exists in the game: the
// Luau `cf` checks are always true and its cylinder fallback (collide) is
// not ported. Collider lists are 1-based (coll.query).
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import { HUGE, lmin, lmax, lsort } from "../lib/compat";
import * as track from "../world/track";
import * as level from "../world/level";
import * as scenery from "../world/scenery";
import { Chunk } from "../world/scenery";
import * as coll from "../world/collide";
import { Collider } from "../world/collide";
import * as types from "./types";

// Tunables -------------------------------------------------------------------
export const CRUISE: f64 = 55;
export const BOOST: f64 = 95;
export const BRAKE: f64 = 28;
export const BOX_X: f64 = 24;
export const BOX_Y0: f64 = 1.1;
export const BOX_Y1: f64 = 30;
export const MAX_VX: f64 = 30;
export const MAX_VY: f64 = 22;
export const EDGE: f64 = 6; // soft edge band (m)
export const RADIUS: f64 = 1.2;
export const ROLL_TIME: f64 = 0.5;
export const SKIM_ALT: f64 = 3.2;

export class Controls {
    sx: f64 = 0;
    sy: f64 = 0;
    fire: bool = false;
    boost: bool = false;
    brake: bool = false;
    rollL: bool = false;
    rollR: bool = false;
    bomb: bool = false;
}

// (types.Player's fields: s x y vx vy speed bank pitch roll pos fwd right up
// shield invuln rolling boosting braking alive aim; the constructor sets the
// Luau defaults that differ)
export class Player extends types.Player {
    targetSpeed: f64 = CRUISE;
    rollDir: f64 = 0;
    rollT: f64 = 0;
    rollCd: f64 = 0;
    boost: f64 = 100; // 0..100
    boostDelay: f64 = 0;
    heat: f64 = 0; // 0..100
    heatDelay: f64 = 0;
    overheat: f64 = 0; // seconds left locked out
    hurtCd: f64 = 0; // scenery damage cooldown
    flash: f64 = 0; // white hit flash 0..1
    boostKick: f64 = 0; // 1 at boost start, decays (FOV / camera punch)
    skim: f64 = 1; // multiplier 1..4
    skimT: f64 = 0;
    lowT: f64 = 0; // seconds under the skim altitude (this run)
    thrust: f64 = 0.5; // visual thruster output 0..1
    controls: bool = true; // player input accepted
    frozen: bool = false; // hold s (title/briefing/launch countdown)
    wallHits: f64 = 0;
    railPos: Vector = Vector.xyz(0, 0, 0);
    railBank: f64 = 0;
    overWater: bool = true;
    sx: f64 = 0; // smoothed steering (for anticipation)
    sy: f64 = 0;
    // one-frame events (set by update, read by the caller)
    evOverheat: bool = false;
    evBoost: bool = false;
    evSplash: bool = false;
    wetT: f64 = 10; // seconds since the pilot last touched the water
    speedCap: f64 = 0; // > 0: cruise speed cap (boss fights), boost surges to cap + 25
    // close calls: skimming past scenery without touching it
    grazing: bool = false;
    grazeT: f64 = 0;
    grazeHit: bool = false;
    grazeCd: f64 = 0;
    evNearMiss: bool = false;
    nearX: f64 = 0; // where the closest scenery was (for the popup)
    nearY: f64 = 0;
    nearZ: f64 = 0;
    // scenery contact (see player.luau): the way round a head-on rock, seconds
    // since the last touch, held at a face and for how long, the rail share
    hitSide: f64 = 0;
    hitT: f64 = 10;
    hold: bool = false;
    holdT: f64 = 0;
    railK: f64 = 1;
    // the lane planner's lane and settle, the stick lockout, glance / flip
    laneX: f64 = 0;
    laneT: f64 = 0;
    lockT: f64 = 0;
    lockSide: f64 = 0;
    glance: bool = false;
    flipped: bool = false;
    // the stall guard (WEDGE)
    nLat: f64 = 0;
    nFwd: f64 = 0;
    nUp: f64 = 0;
    pushLat: f64 = 0;
    holdX: f64 = 0;
    holdXT: f64 = 0;
    stS: f64 = 0;
    stallT: f64 = 0;
    flips: f64 = 0;
    esc: f64 = 0;
    escX: f64 = 0;
    escY: f64 = 0;
    escS: f64 = HUGE;
    escDiag: bool = false;
    ghost: bool = false;
    escSt: f64 = 0;
    sideV: f64 = 0;
    lockY: f64 = 0;
    roomSd: f64 = 0;
    roomT: f64 = 0;
    roomOk: bool = false;
    lastOk: bool = false;
    tumble: bool = false; // the crash tumble has begun (its first touch picks the face's lean)

    constructor() {
        super();
        this.y = 6;
        this.speed = CRUISE;
        this.pos = Vector.xyz(0, 6, 0);
    }
}

export function create(): Player {
    return new Player();
}

export function newControls(): Controls {
    return new Controls();
}

export function clearControls(c: Controls): void {
    c.sx = 0;
    c.sy = 0;
    c.fire = false;
    c.boost = false;
    c.brake = false;
    c.rollL = false;
    c.rollR = false;
    c.bomb = false;
}

export function addHeat(p: Player, amount: f64): void {
    p.heat = lmin(100, p.heat + amount);
    p.heatDelay = 0.35;
    if (p.heat >= 100 && p.overheat <= 0) {
        p.overheat = 2.5;
        p.evOverheat = true;
    }
}

// Recompute the world frame from rail coordinates.
export function place(p: Player): void {
    track.frame(level.track, p.s);
    let tp = track.FRAME_P, rt = track.FRAME_R;
    p.fwd = track.FRAME_F;
    p.right = rt;
    p.up = track.FRAME_U;
    p.railPos = tp;
    p.railBank = track.FRAME_BANK;
    p.pos = mathx.v3(<f64>tp.x + <f64>rt.x * p.x, <f64>tp.y + p.y, <f64>tp.z + <f64>rt.z * p.x);
    p.overWater = <f64>tp.y < 1;
}

// Soft wall: scales velocity heading into the edge, springs back past it
// (free: no scaling, only the spring). Returns the velocity (pos is unchanged).
function softAxis(pos: f64, vel: f64, lo: f64, hi: f64, band: f64, dt: f64, free: bool): f64 {
    if (free) {
        // (the spring below still holds the box)
    } else if (vel > 0 && pos > hi - band) {
        let k = mathx.saturate((hi - pos) / band);
        vel *= Math.pow(k, 0.6);
    } else if (vel < 0 && pos < lo + band) {
        let k = mathx.saturate((pos - lo) / band);
        vel *= Math.pow(k, 0.6);
    }
    if (pos > hi) {
        vel -= (pos - hi) * 40 * dt;
    } else if (pos < lo) {
        vel += (lo - pos) * 40 * dt;
    }
    return vel;
}

export class Hit {
    hit: bool = false;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    head: bool = false;
}

export const HEAD_V: f64 = 30; // m/s sideways a head-on hit sends him round the rock,
export const HEAD_ACC: f64 = 300; // gaining this per second held (a wide face)
export const HEAD_V_MAX: f64 = 45; // up to a barrel roll's sidestep pace
export const HEAD_SPEED: f64 = 28; // speed he sheds toward while held at a face
export const HOLD_K: f64 = 0.12; // share of his speed still moving him along the rail there
export const OFF_RATE: f64 = 12; // how fast the sidestep gives way to the stick once he is round
export const OFF_V: f64 = 15; // m/s sideways a falling body glances off rock
export const HOLD_MAX: f64 = 0.5; // s a rock just ahead (not touched) may hold him in a contact
export const BACK_OFF: f64 = 0.5; // m a push-out may take him back along the rail in a frame
export const GLANCE_LAT: f64 = 0.6; // a head-on touch whose normal leans this far across the rail (a corner clip)
export const GLANCE_O: f64 = 3; // glances off, not held, when the near side is clear within this (m)
export const GLANCE_V: f64 = 18; // m/s sideways a glance sends him
export const TIE: f64 = 2; // m: the nearer side's first clear line wins unless the other's is within this
export const SLIDE_W: f64 = 1; // near-tie cost per metre of held slide to a side's first clear line
export const LEAN: f64 = 3; // cost of going round against the way the face leans
export const LEAN_HARD: f64 = 0.75; // a face leaning this far across the rail takes a near-tie its way
export const LANE_RUN: f64 = 300; // m of clear lane ahead the planner looks for
export const LANE_T: f64 = 1.5; // s the hands-off settle may steer him into the lane after a slide
export const LOCK_MAX: f64 = 0.5; // s at most the stick is kept from steering him back into the rock
export const BUMP_V: f64 = 6; // m/s a side face touched during a contact bounces him off it
export const STALL_W: f64 = 0.05; // s a held slide making less than STALL_K of its way sideways is blocked
export const STALL_K: f64 = 0.35;
export const STALL_RATE: f64 = 0.1; // share of cruise his net rail progress must beat in a contact (else he is stalled)
export const STALL_T: f64 = 0.25; // s stalled (and not sliding round freely) before the stall guard plans a way out
export const LAST_T: f64 = 0.28; // s stalled (bar a held slide still making way round): the last resort moves him out
export const LAST_T2: f64 = 0.45; // s stalled, whatever else happens: the last resort
export const LAST_NEAR: f64 = 3; // m: a held slide past LAST_T goes on when the nearest spot is this close ahead of it
export const HOLD_FACE_MAX: f64 = 0.4; // s a contact may hold him at faces in all
export const ESC_T: f64 = 0.5; // s an escape runs before it is planned again (the last resort comes first)
export const ESC_V: f64 = 45; // m/s toward the way out while escaping (HEAD_V_MAX)
export const ESC_K: f64 = 0.12; // share of his speed moving him along the rail until he is out (HOLD_K)
export const MOVE_STEP: f64 = 0.95; // m a frame at most the last resort moves him (no teleport)
export const OUT_UP: f64 = 1.3; // way-out cost per metre climbed (per metre across or down: 1)
export const OUT_PREF: f64 = 4; // way-out cost a stick held that way saves (m)
export const OUT_PATH: f64 = 8; // way-out cost of a spot whose straight way there is not clear (m)
export const OUT_SLIDE: f64 = 6; // m: a first slide longer than this (or none) looks for a way over / under first
export const BOX_JUT: f64 = 2; // m a box collider's drawn rock may jut past it (the planner's lanes keep off)
const STALL_STEP: f64 = STALL_RATE * CRUISE * STALL_T; // m of net rail progress that is not a stall
const CONTACT_GAP: f64 = 0.25; // seconds untouched that end a contact
const SIDES: StaticArray<f64> = [-1, 1];
const AHEAD: StaticArray<f64> = [1.5, 4];
const LANE_STEP: f64 = 1.5; // m between the lines the planner probes
const LANE_EDGE: f64 = 1.5; // m short of the box edge a lane may lie
const LANE_PROBE: f64 = 5; // m between the probes along a lane
const LANE_N: i32 = 12; // lanes scored per side
const LANE_SHIFT: f64 = 0.15; // cost per metre of settle past the first clear line

// scenery.collide (the Luau CollideFn): hit, then HIT_NX / NY / NZ / D
@inline function cf(chunks: Array<Chunk>, x: f64, y: f64, z: f64, r: f64): bool {
    return scenery.collide(chunks, x, y, z, r);
}

// The planner's probes ask only the colliders near the corridor ahead: every
// collider of the chunks over [s - 10, s + LANE_RUN + 10] whose bounds come
// within the box (+ 4 m) of the rail somewhere along it (25 m pieces) at his
// height (+- 4 m). A course chunk there not baked yet is baked first. Box
// colliders apart (their drawn rock juts past them by up to ~BOX_JUT).
let corridor: Array<Collider> = new Array<Collider>(1);
let corridorBox: Array<Collider> = new Array<Collider>(1);
let corridorOn = false;
let segs: Array<f64> = [0.0];
function buildCorridor(p: Player, chunks: Array<Chunk>): void {
    corridor.length = 1;
    corridorBox.length = 1;
    corridorOn = false;
    let s0 = p.s - 10, s1 = lmin(p.s + LANE_RUN + 10, level.track.length - 1);
    let n = <i32>Math.ceil((s1 - s0) / 25);
    segs.length = 1;
    let w = BOX_X + 4;
    for (let i = 0; i < n; i++) {
        let x0 = HUGE, z0 = HUGE, x1 = -HUGE, z1 = -HUGE;
        for (let e = 0; e < 2; e++) {
            let ss = e == 0 ? s0 + <f64>i * 25 : lmin(s0 + <f64>(i + 1) * 25, s1);
            track.frame(level.track, ss);
            let tp = track.FRAME_P, rt = track.FRAME_R;
            for (let q = 0; q < 2; q++) {
                let o = q == 0 ? -w : w;
                let x = <f64>tp.x + <f64>rt.x * o, z = <f64>tp.z + <f64>rt.z * o;
                x0 = lmin(x0, x);
                z0 = lmin(z0, z);
                x1 = lmax(x1, x);
                z1 = lmax(z1, z);
            }
        }
        segs.push(x0 - 4);
        segs.push(z0 - 4);
        segs.push(x1 + 4);
        segs.push(z1 + 4);
    }
    let ylo = <f64>p.pos.y - 4, yhi = <f64>p.pos.y + 4;
    let ns = segs.length - 1;
    for (let ci = 1; ci < chunks.length; ci++) {
        let ch = chunks[ci];
        if (!ch.ready && ch.gs1 >= s0 && ch.gs0 <= s1 && ch.gs1 - ch.gs0 <= 400) {
            track.frame(level.track, mathx.clamp((lmax(ch.gs0, s0) + lmin(ch.gs1, s1)) * 0.5, 0, level.track.length - 1));
            let tp = track.FRAME_P;
            cf(chunks, tp.x, <f64>tp.y + p.y, tp.z, 0.1);
        }
        if (ch.ready && ch.gs1 >= s0 && ch.gs0 <= s1) {
            let cl = ch.colliders;
            for (let j = 1; j < cl.length; j++) {
                let c = cl[j];
                coll.extent(c);
                let E = coll.EXT;
                let cx0 = E[0], cy0 = E[1], cz0 = E[2], cx1 = E[3], cy1 = E[4], cz1 = E[5];
                if (cy1 >= ylo && cy0 <= yhi) {
                    for (let i = 1; i <= ns; i += 4) {
                        if (cx1 >= segs[i] && cx0 <= segs[i + 2] && cz1 >= segs[i + 1] && cz0 <= segs[i + 3]) {
                            if (c.kind == 1) corridorBox.push(c);
                            else corridor.push(c);
                            break;
                        }
                    }
                }
            }
        }
    }
    corridorOn = true;
}

// (jut: a box collider counts BOX_JUT bigger)
function probe(chunks: Array<Chunk>, x: f64, y: f64, z: f64, r: f64, jut: bool): bool {
    if (corridorOn) {
        return coll.query(corridor, x, y, z, r) || coll.query(corridorBox, x, y, z, jut ? r + BOX_JUT : r);
    }
    return cf(chunks, x, y, z, r);
}

// Is the line o m across the rail from him clear of rock 1.5 and 4 m ahead?
function lineClear(p: Player, chunks: Array<Chunk>, o: f64, jut: bool = false): bool {
    let rt = p.right, f = p.fwd, P = p.pos;
    for (let i = 0; i < 2; i++) {
        let a = AHEAD[i];
        if (probe(chunks, <f64>P.x + <f64>rt.x * o + <f64>f.x * a, P.y, <f64>P.z + <f64>rt.z * o + <f64>f.z * a, RADIUS + 0.3, jut)) {
            return false;
        }
    }
    return true;
}

// Metres the lane at rail x stays clear ahead of him (at his height, a probe
// every LANE_PROBE m with 1 m to spare), up to LANE_RUN.
function laneRun(p: Player, chunks: Array<Chunk>, x: f64): f64 {
    let len = level.track.length - 1;
    for (let d = LANE_PROBE; d <= LANE_RUN; d += LANE_PROBE) {
        if (p.s + d >= len) {
            break;
        }
        track.frame(level.track, p.s + d);
        let tp = track.FRAME_P, rt = track.FRAME_R;
        if (probe(chunks, <f64>tp.x + <f64>rt.x * x, <f64>tp.y + p.y, <f64>tp.z + <f64>rt.z * x, RADIUS + 1, true)) {
            return d;
        }
    }
    return LANE_RUN;
}

// The lanes one way (sd) from his line (from: offset of the first line
// tried): the first line clear 1.5 and 4 m ahead short of the soft edge
// band's middle, then every other line past it (LANE_N in all) while the
// lines stay clear, out to LANE_EDGE short of the box edge. Hands off (runs)
// each lane is scored by the move to it past that first line and how soon
// rock closes it ahead; a lane whose move alone costs more than the best so
// far ends the search. Returns the first clear line's offset (HUGE: none);
// LANES_BO the best lane's offset, LANES_C its score.
let LANES_BO: f64 = 0;
let LANES_C: f64 = 0;
function lanes(p: Player, chunks: Array<Chunk>, sd: f64, from: i32, runs: bool): f64 {
    boxX(p.s);
    let lo = BOX_X_1, hi = BOX_X_2;
    let first = HUGE, best = HUGE, bo = 0.0;
    let j: i32 = 0;
    for (let k = from; k <= 40; k++) {
        let o = <f64>k * LANE_STEP;
        let x = p.x + sd * o;
        if (first == HUGE) {
            if (x < lo + EDGE * 0.5 || x > hi - EDGE * 0.5) {
                break;
            }
            if (k == 0 || lineClear(p, chunks, sd * o)) {
                first = o;
                bo = o;
                if (!runs) {
                    break;
                }
                best = 0.1 * (LANE_RUN - laneRun(p, chunks, x));
            }
        } else {
            let shift = LANE_SHIFT * (o - first);
            j += 1;
            if (j >= 2 * LANE_N || shift >= best || x < lo + LANE_EDGE || x > hi - LANE_EDGE || !lineClear(p, chunks, sd * o, true)) {
                break;
            }
            if (j % 2 == 0) {
                let c = shift + 0.1 * (LANE_RUN - laneRun(p, chunks, x));
                if (c < best) {
                    best = c;
                    bo = o;
                }
            }
        }
    }
    LANES_BO = bo;
    LANES_C = first == HUGE ? HUGE : runs ? best : 0;
    return first;
}

// The lane planner: the way round a rock met head-on and the lane past it
// (see player.luau). Returns the side; PLAN_O the lane's offset, PLAN_O1 the
// slide's metres to that side's first clear line (HUGE: none).
let PLAN_O: f64 = 0;
let PLAN_O1: f64 = 0;
function planSides(p: Player, chunks: Array<Chunk>, lat: f64): f64 {
    let st = p.sx > 0.3 ? 1.0 : p.sx < -0.3 ? -1.0 : 0.0;
    // [-1] / [1] of the Luau tables: index 0 / 1
    let firstL = HUGE, firstR = HUGE, costL = HUGE, costR = HUGE, laneL = 0.0, laneR = 0.0;
    for (let i = 0; i < 2; i++) {
        let sd = SIDES[i];
        let o1 = lanes(p, chunks, sd, 1, st == 0);
        let o = LANES_BO, c = LANES_C;
        let cost = SLIDE_W * o1 + c + (Math.abs(lat) > 0.3 && sd != mathx.sign(lat) ? LEAN : 0);
        if (sd < 0) {
            firstL = o1;
            laneL = o;
            costL = cost;
        } else {
            firstR = o1;
            laneR = o;
            costR = cost;
        }
    }
    if (firstL == HUGE && firstR == HUGE) {
        boxX(p.s);
        let lo = BOX_X_1, hi = BOX_X_2;
        PLAN_O = 0;
        PLAN_O1 = HUGE;
        return p.x - lo < hi - p.x ? 1.0 : -1.0;
    }
    let sd: f64;
    let sl = mathx.sign(lat);
    if (firstR - firstL > TIE) {
        sd = -1;
    } else if (firstL - firstR > TIE) {
        sd = 1;
    } else if (Math.abs(lat) >= LEAN_HARD && (sl < 0 ? firstL : firstR) < HUGE) {
        // a face leaning this hard pushes a slide against it straight back
        sd = sl;
    } else if (st != 0) {
        sd = st;
    } else {
        sd = costL < costR ? -1.0 : costR < costL ? 1.0 : Math.abs(lat) > 0.05 ? sl : p.x > 0 ? -1.0 : 1.0;
    }
    PLAN_O = sd < 0 ? laneL : laneR;
    PLAN_O1 = sd < 0 ? firstL : firstR;
    return sd;
}

function plan(p: Player, chunks: Array<Chunk>, lat: f64): f64 {
    buildCorridor(p, chunks);
    let sd = planSides(p, chunks, lat);
    corridorOn = false;
    return sd;
}

// Where the hands-off settle takes him when the slide let him go and its lane
// was not planned hands off: the lanes from his own line on, either way.
function settleLane(p: Player, chunks: Array<Chunk>): f64 {
    let best = HUGE, bx = p.x;
    buildCorridor(p, chunks);
    for (let i = 0; i < 2; i++) {
        let sd = SIDES[i];
        let o1 = lanes(p, chunks, sd, 0, true);
        let o = LANES_BO, c = LANES_C;
        if (o1 < HUGE && c < best) {
            best = c;
            bx = p.x + sd * o;
        }
    }
    corridorOn = false;
    return bx;
}

// Is the way toward the rock he slid round (side sd) clear: 1 m that way
// 1.5 m ahead, 2 m that way 2.5 and 4 m ahead and 3 m that way 4, 7 and 11
// m ahead?
const LOCK_PROBES: StaticArray<f64> = [1, 1.5, 2, 2.5, 2, 4, 3, 4, 3, 7, 3, 11];
function lockClear(p: Player, chunks: Array<Chunk>, sd: f64): bool {
    let rt = p.right, f = p.fwd, P = p.pos;
    for (let i = 0; i < 12; i += 2) {
        let o = sd * LOCK_PROBES[i], a = LOCK_PROBES[i + 1];
        if (cf(chunks, <f64>P.x + <f64>rt.x * o + <f64>f.x * a, P.y, <f64>P.z + <f64>rt.z * o + <f64>f.z * a, RADIUS + 0.3)) {
            return false;
        }
    }
    return true;
}

// Is his own line clear 1.5 and 4 m ahead (his radius + 0.1: what lets a hold
// go)?
function aheadClear(p: Player, chunks: Array<Chunk>): bool {
    let P = p.pos, f = p.fwd;
    for (let i = 0; i < 2; i++) {
        let a = AHEAD[i];
        if (cf(chunks, <f64>P.x + <f64>f.x * a, P.y, <f64>P.z + <f64>f.z * a, RADIUS + 0.1)) {
            return false;
        }
    }
    return true;
}

// Is the way up (sd 1) / down (-1) clear of the rock he climbed / dived away
// from: 2.5 m that way 1.5, 4 and 7 m ahead?
const LOCK_Y_AHEAD: StaticArray<f64> = [1.5, 4, 7];
function lockClearY(p: Player, chunks: Array<Chunk>, sd: f64): bool {
    let f = p.fwd, P = p.pos;
    for (let i = 0; i < 3; i++) {
        let a = LOCK_Y_AHEAD[i];
        if (cf(chunks, <f64>P.x + <f64>f.x * a, <f64>P.y + sd * 2.5, <f64>P.z + <f64>f.z * a, RADIUS + 0.3)) {
            return false;
        }
    }
    return true;
}

// a contact was already live when this frame's collide began
let contactLive = false;
// the first head-on touch this frame: the slide's metres to the first clear
// line (HUGE: none; -1: no first touch)
let slideTo: f64 = -1;

// The way out of a stall (see player.luau): the cheapest spot round him at
// his s, across the rail and up or down, that is clear, with his line from it
// clear 1.5 ... 9 m ahead.
const OUT_AHEAD: StaticArray<f64> = [1.5, 3, 4.5, 6, 7.5, 9];
const OUT_Y0: f64 = 2; // the lowest spot (m over the water)
class Out {
    dx: f64 = 0;
    dy: f64 = 0;
    c: f64 = 0;
    constructor(dx: f64, dy: f64) {
        this.dx = dx;
        this.dy = dy;
    }
}
function buildOuts(): Array<Out> {
    let dxs: Array<f64> = [0, 0.75, -0.75];
    for (let k = 1; k <= 9; k++) {
        dxs.push(<f64>k * 1.5);
        dxs.push(-<f64>k * 1.5);
    }
    let far: StaticArray<f64> = [16.5, 19.5, 24, 30, 36, 42, 48];
    for (let i = 0; i < far.length; i++) {
        dxs.push(far[i]);
        dxs.push(-far[i]);
    }
    let outs = new Array<Out>(1);
    for (let i = 0; i < dxs.length; i++) {
        for (let k = -12; k <= 12; k++) {
            outs.push(new Out(dxs[i], <f64>k * 2.5));
        }
    }
    return outs;
}
const OUTS: Array<Out> = buildOuts(); // 1-based
// the colliders round him (his s - 2 .. + 12, the box's width + 4 m, any
// height); a course chunk there not baked yet is baked first
let near: Array<Collider> = new Array<Collider>(1);
let outC: Array<Out> = new Array<Out>(1);
function buildNear(p: Player, chunks: Array<Chunk>): void {
    near.length = 1;
    let s0 = p.s - 2, s1 = lmin(p.s + 12, level.track.length - 1);
    for (let ci = 1; ci < chunks.length; ci++) {
        let ch = chunks[ci];
        if (!ch.ready && ch.gs1 >= s0 && ch.gs0 <= s1 && ch.gs1 - ch.gs0 <= 400) {
            track.frame(level.track, mathx.clamp((lmax(ch.gs0, s0) + lmin(ch.gs1, s1)) * 0.5, 0, level.track.length - 1));
            let tp = track.FRAME_P;
            cf(chunks, tp.x, <f64>tp.y + p.y, tp.z, 0.1);
        }
    }
    let x0 = HUGE, z0 = HUGE, x1 = -HUGE, z1 = -HUGE;
    boxX(p.s);
    let lo = BOX_X_1, hi = BOX_X_2;
    for (let e = 0; e < 2; e++) {
        let ss = e == 0 ? p.s - 2 : p.s + 12;
        track.frame(level.track, mathx.clamp(ss, 0, level.track.length - 1));
        let tp = track.FRAME_P, rt = track.FRAME_R;
        for (let q = 0; q < 2; q++) {
            let o = q == 0 ? lo - 4 : hi + 4;
            let x = <f64>tp.x + <f64>rt.x * o, z = <f64>tp.z + <f64>rt.z * o;
            x0 = lmin(x0, x);
            x1 = lmax(x1, x);
            z0 = lmin(z0, z);
            z1 = lmax(z1, z);
        }
    }
    for (let ci = 1; ci < chunks.length; ci++) {
        let ch = chunks[ci];
        let bb = ch.bounds;
        if (ch.ready && bb.maxx >= x0 && bb.minx <= x1 && bb.maxz >= z0 && bb.minz <= z1) {
            let cl = ch.colliders;
            for (let j = 1; j < cl.length; j++) {
                let c = cl[j];
                coll.extent(c);
                let E = coll.EXT;
                if (E[3] >= x0 && E[0] <= x1 && E[5] >= z0 && E[2] <= z1) {
                    near.push(c);
                }
            }
        }
    }
}

const OUT_BACKS: StaticArray<f64> = [1.5, 3, 4.5];
// (is the straight way from rail offset (b0 back, dx0, dy0) to (b1, dx1, dy1)
// clear: a thinner probe every metre?)
function wayClear(P: Vector, rt: Vector, f: Vector, b0: f64, dx0: f64, dy0: f64, b1: f64, dx1: f64, dy1: f64): bool {
    let ex = dx1 - dx0, ey = dy1 - dy0, eb = b1 - b0;
    let n = Math.ceil(Math.sqrt(ex * ex + ey * ey + eb * eb));
    for (let i = 1.0; i <= n - 1; i++) {
        let t = i / n;
        let dx = dx0 + ex * t, dy = dy0 + ey * t, b = b0 + eb * t;
        if (coll.query(near, <f64>P.x + <f64>rt.x * dx - <f64>f.x * b, <f64>P.y + dy, <f64>P.z + <f64>rt.z * dx - <f64>f.z * b, RADIUS * 0.75)) {
            return false;
        }
    }
    return true;
}
// (is the spot b back, dx across, dy up clear, with his line from it?)
function spotClear(P: Vector, rt: Vector, f: Vector, b: f64, dx: f64, dy: f64): bool {
    let wx = <f64>P.x + <f64>rt.x * dx - <f64>f.x * b, wy = <f64>P.y + dy, wz = <f64>P.z + <f64>rt.z * dx - <f64>f.z * b;
    if (coll.query(near, wx, wy, wz, RADIUS + 0.2)) {
        return false;
    }
    for (let i = 0; i < 6; i++) {
        let a = OUT_AHEAD[i];
        if (coll.query(near, wx + <f64>f.x * a, wy, wz + <f64>f.z * a, RADIUS + 0.3)) {
            return false;
        }
    }
    return true;
}

// backs: a spot whose straight way is not clear may be reached by first
// backing along his track (OUT_BACKS m, 1.5 cost a metre), then across;
// clear: only a way clear of rock (the last resort). Returns found;
// OUT_DX / OUT_DY / OUT_B (offsets across / up and back), OUT_DIAG.
let OUT_DX: f64 = 0;
let OUT_DY: f64 = 0;
let OUT_B: f64 = 0;
let OUT_DIAG = false;
function outRet(ok: bool, dx: f64, dy: f64, b: f64, diag: bool): bool {
    OUT_DX = dx;
    OUT_DY = dy;
    OUT_B = b;
    OUT_DIAG = diag;
    return ok;
}
function findOut(p: Player, chunks: Array<Chunk>, stx: f64, sty: f64, awayX: f64, only: bool, backs: bool, clear: bool = false): bool {
    buildNear(p, chunks);
    boxX(p.s);
    let lo = BOX_X_1, hi = BOX_X_2;
    let P = p.pos, rt = p.right, f = p.fwd;
    outC.length = 1;
    for (let i = 1; i < OUTS.length; i++) {
        let o = OUTS[i];
        let dx = o.dx, dy = o.dy;
        let x = p.x + dx, y = p.y + dy;
        // (above the ceiling, ridden up a rock's slope: only spots under it)
        if ((dx == 0 || (x >= lo - 1.5 && x <= hi + 1.5)) && ((dy == 0 && y <= BOX_Y1 + 0.5) || (y >= OUT_Y0 && y <= BOX_Y1 - 1.5)) && (awayX == 0 || (dx * awayX > 0 && dy == 0))) {
            let c = Math.abs(dx) + Math.abs(dy) * (dy > 0 ? OUT_UP : 1);
            if (dx * stx > 0) {
                c -= OUT_PREF;
            }
            if (dy * sty > 0) {
                c -= OUT_PREF;
            }
            if (x < lo + EDGE * 0.5 || x > hi - EDGE * 0.5) {
                c += x < lo || x > hi ? 9.0 : 6.0;
            }
            if (dx * p.hitSide < 0) {
                // (a tie goes the way he slides)
                c += 0.05;
            }
            o.c = c;
            outC.push(o);
        }
    }
    lsortOut();
    // fb: the cheapest spot whose straight way is not clear (OUT_PATH more);
    // bk: the cheapest reached by backing first
    let fb: Out? = null;
    let fbC = HUGE;
    let bk: Out? = null;
    let bkB = 0.0, bkC = HUGE, bkD = false;
    for (let i = 1; i < outC.length; i++) {
        let o = outC[i];
        let c = o.c;
        if (c > bkC || (c > fbC && (!clear || c > fbC + 12))) {
            break;
        }
        let dx = o.dx, dy = o.dy;
        let ok = spotClear(P, rt, f, 0, dx, dy);
        if (ok && wayClear(P, rt, f, 0, 0, 0, 0, dx, dy)) {
            return outRet(true, dx, dy, 0, false);
        }
        if (ok && fb == null) {
            fb = o;
            fbC = c + OUT_PATH;
        }
        if (backs) {
            for (let q = 0; q < 3; q++) {
                let b = OUT_BACKS[q];
                let cb = c + 1.5 * b;
                if (cb >= bkC) {
                    break;
                }
                if (spotClear(P, rt, f, b, dx, dy)) {
                    // (straight there, backing and across at once, else back
                    // first then across)
                    let diag = wayClear(P, rt, f, 0, 0, 0, b, dx, dy);
                    if (diag || (wayClear(P, rt, f, 0, 0, 0, b, 0, 0) && wayClear(P, rt, f, b, 0, 0, b, dx, dy))) {
                        bk = o;
                        bkB = b;
                        bkC = cb;
                        bkD = diag;
                        break;
                    }
                }
            }
        }
    }
    if (bk != null && (bkC <= fbC || clear)) {
        return outRet(true, bk.dx, bk.dy, bkB, bkD);
    }
    if (fb != null) {
        return outRet(true, fb.dx, fb.dy, 0, false);
    }
    if (awayX != 0 && !only) {
        return findOut(p, chunks, stx, sty, 0, false, backs, clear);
    }
    return outRet(false, 0, 0, 0, false);
}
function lsortOut(): void {
    lsort<Out>(outC, outC.length - 1, (a: Out, b: Out): bool => a.c < b.c);
}

// Is there room to go round that way (sd): a way out that way short of the
// box's hard limit? (asked again at most every ROOM_T s for one side)
const ROOM_T: f64 = 0.1;
function roomTo(p: Player, chunks: Array<Chunk>, sd: f64): bool {
    if (p.roomSd != sd || p.roomT <= 0) {
        p.roomSd = sd;
        p.roomT = ROOM_T;
        p.roomOk = findOut(p, chunks, 0, 0, sd, true, false);
    }
    return p.roomOk;
}

// The stall guard acts: an escape toward a way out (ESC_T, no hold), or
// (last) the last resort's ghost move to the nearest clear spot (see
// player.luau).
function beginEscape(p: Player, dx: f64, dy: f64, b: f64, stx: f64, last: bool, diag: bool): void {
    let sd = dx > 0 ? 1.0 : dx < 0 ? -1.0 : 0.0;
    if (sd != 0 && sd != p.hitSide) {
        p.flipped = true;
    }
    if (sd != 0) {
        p.hitSide = sd;
    }
    // (escS: where backing along his track ends; none: huge)
    p.escX = p.x + dx;
    p.escY = p.y + dy;
    p.escS = b > 0 ? p.s - b : HUGE;
    p.escDiag = diag;
    p.esc = ESC_T;
    p.ghost = last;
    p.escSt = stx;
    if (last) {
        // (the last resort's move lasts what its way needs, a few frames more
        // at most)
        p.esc = (Math.sqrt(dx * dx + dy * dy) / MOVE_STEP + b / (0.9 * BACK_OFF) + 8) / 60;
    }
    // (once he is out the stick may not climb / dive straight back at it)
    p.lockY = dy > 0 ? -1.0 : dy < 0 ? 1.0 : 0.0;
    p.flips += 1;
    p.hold = false;
    // (the settle re-plans its lane from where the escape lets him go)
    p.laneT = -2;
}

@inline function stickSide(v: f64): f64 {
    return v > 0.3 ? 1.0 : v < -0.3 ? -1.0 : 0.0;
}

function startEscape(p: Player, chunks: Array<Chunk>, sx: f64, sy: f64, awayX: f64, last: bool): void {
    let stx = stickSide(sx), sty = stickSide(sy);
    // (the last resort: the nearest spot, whatever the stick says)
    let ok = findOut(p, chunks, last ? 0.0 : stx, last ? 0.0 : sty, last ? 0.0 : awayX, false, true, last);
    let dx = OUT_DX, dy = OUT_DY, b = OUT_B, diag = OUT_DIAG;
    if (!ok) {
        // (no clear spot anywhere round him: toward the box's middle)
        boxX(p.s);
        let lo = BOX_X_1, hi = BOX_X_2;
        dx = p.x - lo < hi - p.x ? 6.0 : -6.0;
        dy = 0;
        b = 0;
    } else if (dx == 0 && dy == 0 && b == 0) {
        // (where he is, his line is clear: not stalled)
        p.stS = p.s;
        p.stallT = 0;
        return;
    }
    beginEscape(p, dx, dy, b, stx, last, diag);
}

function endContact(p: Player): void {
    p.hitSide = 0;
    p.holdT = 0;
    p.glance = false;
    p.nLat = 0;
    p.pushLat = 0;
    p.stallT = 0;
    p.flips = 0;
    p.stS = p.s;
    p.sideV = 0;
    p.lastOk = false;
}

// Resolve a push-out (world normal n, depth d) in rail space: pop over the
// top, bounce off a side, or (head-on) stop at the face and slide round the
// rock the way the lane planner picks; a corner clip with the near side clear
// close by glances off it. Returns true when the push was exact (the caller
// re-probes). (Luau's cf is never nil here: the cylinder fallback is not
// ported.)
function resolve(p: Player, nx: f64, ny: f64, nz: f64, depth: f64, out: Hit, sMin: f64, chunks: Array<Chunk>): bool {
    let rt = p.right, f = p.fwd;
    let lat = nx * <f64>rt.x + nz * <f64>rt.z; // normal across the rail
    let fwdN = nx * <f64>f.x + nz * <f64>f.z; // normal along the rail (< 0 = head-on)
    let head = fwdN < -0.55;
    if (!out.hit) {
        out.hit = true;
        out.head = head;
        out.x = <f64>p.pos.x - nx * RADIUS;
        out.y = <f64>p.pos.y - ny * RADIUS;
        out.z = <f64>p.pos.z - nz * RADIUS;
    }
    p.hitT = 0;
    p.nLat = lat;
    p.nFwd = fwdN;
    p.nUp = ny;
    // (escaping: the way round is not planned again at each touch)
    let live = p.hold || p.holdT > 0 || p.glance || p.esc > 0;
    if (contactLive) {
        // one crash: touches until he is clear of it do not hurt again
        p.hurtCd = lmax(p.hurtCd, CONTACT_GAP + 0.05);
    }
    let push = lmin(depth + 0.25, 4);
    if (ny > 0.6) {
        // landed on a top: hop up
        p.y += push * ny;
        p.vy = lmax(p.vy, 9);
    } else if (ny < -0.6) {
        // ceiling (arch band, bridge): shove down
        p.y -= push * -ny;
        p.vy = lmin(p.vy, -9);
    } else if (head || live) {
        if (head && !live && (p.alive || p.hitSide == 0)) {
            // the first head-on touch of a contact: a corner clip glances off
            // the side the face leans to when a line that way is clear within
            // GLANCE_O, else the planner picks the way round and the lane.
            // laneT -1: the lane was planned hands off; -2: not.
            p.glance = false;
            p.flipped = false;
            p.laneT = -2;
            p.lockY = 0;
            let sl = lat != 0 ? mathx.sign(lat) : 1.0;
            let sd = sl, o = 0.0;
            if (p.alive) {
                if (Math.abs(lat) >= GLANCE_LAT) {
                    boxX(p.s);
                    let lo = BOX_X_1, hi = BOX_X_2;
                    for (let k = 1; k <= 4; k++) {
                        let x = p.x + sl * <f64>k * 0.75;
                        if (x < lo - 1 || x > hi + 1 || <f64>k * 0.75 > GLANCE_O) {
                            break;
                        }
                        if (lineClear(p, chunks, sl * <f64>k * 0.75)) {
                            p.glance = true;
                            break;
                        }
                    }
                }
                if (!p.glance) {
                    sd = plan(p, chunks, lat);
                    o = PLAN_O;
                    let o1 = PLAN_O1;
                    if (Math.abs(p.sx) <= 0.3) {
                        p.laneT = -1;
                    }
                    // (a long slide, or none: update looks for a way over /
                    // under the rock first)
                    slideTo = o1;
                }
            }
            p.hitSide = sd;
            p.laneX = p.x + sd * o;
        }
        let e = depth + 0.05;
        p.pushLat += lat * e;
        p.x += lat * e;
        p.y += ny * e;
        p.s = lmax(sMin, p.s + fwdN * e);
        let sd = p.hitSide;
        if (p.glance && !p.hold && p.holdT <= 0) {
            if (head && (Math.abs(lat) < GLANCE_LAT * 0.75 || mathx.sign(lat) != sd)) {
                // square into the rock after all: held, the same way round
                p.glance = false;
            } else if (head || mathx.sign(lat) == sd) {
                // a corner clip: he slides off along the face at the speed he
                // has along it (across the rail at least GLANCE_V), and the
                // rail takes only what that leaves along it (railK)
                out.head = false;
                let hn = lmax(Math.sqrt(lat * lat + fwdN * fwdN), 1e-3);
                let tl = Math.abs(fwdN) / hn, tf = Math.abs(lat) / hn;
                let vt = lmax(0, p.vx * sd * tl + p.speed * p.railK * tf);
                p.vx = sd * lmax(lmax(GLANCE_V, vt * tl), p.vx * sd > 0 ? Math.abs(p.vx) : 0);
                p.railK = lmin(p.railK, vt * tf / lmax(p.speed, 1));
                return true;
            }
        }
        if (head && p.esc <= 0) {
            let v = lmin(HEAD_V_MAX, HEAD_V + HEAD_ACC * p.holdT);
            p.vx = sd * lmax(v, p.vx * sd > 0 ? Math.abs(p.vx) : 0);
            p.hold = true;
        } else if (head) {
            // escaping (update): no hold, the escape keeps its slide
        } else if (Math.abs(lat) > 0.3 && p.esc <= 0) {
            // a side face: a small bounce off it
            let away = mathx.sign(lat);
            if (p.vx * away < BUMP_V) {
                p.vx = away * lmax(BUMP_V, Math.abs(p.vx) * 0.3);
            }
        }
        return true;
    } else {
        let l = Math.sqrt(lat * lat + fwdN * fwdN);
        let side = Math.abs(lat) > 0.12 ? mathx.sign(lat) : p.x > 0 ? -1.0 : 1.0;
        p.x += side * push * lmax(0.4, Math.abs(lat) / lmax(l, 1e-3));
        p.vx = side * lmax(15, Math.abs(p.vx) * 0.6);
        p.y += ny * push;
        p.hitSide = side;
        p.pushLat += side * push;
    }
    return false;
}

// Scenery collision (scenery.collide, exact shapes). (sA, xA, yA): where he
// was before this frame's move: a move that ends with his centre in the rock
// is first walked back to where he met it.
function collide(p: Player, chunks: Array<Chunk>, out: Hit, sA: f64, xA: f64, yA: f64): void {
    out.hit = false;
    contactLive = p.holdT > 0 || p.glance;
    slideTo = -1;
    let R = RADIUS;
    let hit = cf(chunks, p.pos.x, p.pos.y, p.pos.z, R);
    let nx = scenery.HIT_NX, ny = scenery.HIT_NY, nz = scenery.HIT_NZ, depth = scenery.HIT_D;
    if (hit && depth > R) {
        let nxB = nx, nyB = ny, nzB = nz;
        let sB = p.s, xB = p.x, yB = p.y;
        let a = 0.0, b = 1.0;
        for (let it = 0; it < 6; it++) {
            let m = (a + b) * 0.5;
            p.s = mathx.lerp(sA, sB, m);
            p.x = mathx.lerp(xA, xB, m);
            p.y = mathx.lerp(yA, yB, m);
            place(p);
            let h2 = cf(chunks, p.pos.x, p.pos.y, p.pos.z, R);
            let d2 = scenery.HIT_D;
            if (h2 && d2 > R * 0.5) {
                b = m;
            } else {
                a = m;
            }
        }
        p.s = mathx.lerp(sA, sB, a);
        p.x = mathx.lerp(xA, xB, a);
        p.y = mathx.lerp(yA, yB, a);
        place(p);
        hit = cf(chunks, p.pos.x, p.pos.y, p.pos.z, R);
        nx = scenery.HIT_NX;
        ny = scenery.HIT_NY;
        nz = scenery.HIT_NZ;
        depth = scenery.HIT_D;
        if (!hit && a <= 0) {
            // walked all the way back (no part of the move is clear): a
            // contact all the same, a shallow push along the deep probe's
            // normal
            hit = true;
            nx = nxB;
            ny = nyB;
            nz = nzB;
            depth = 0.05;
        }
    }
    for (let it = 0; it < 3; it++) {
        if (!hit) {
            break;
        }
        let exact = resolve(p, nx, ny, nz, depth, out, sA - BACK_OFF, chunks);
        place(p);
        if (!exact) {
            break;
        }
        hit = cf(chunks, p.pos.x, p.pos.y, p.pos.z, R);
        nx = scenery.HIT_NX;
        ny = scenery.HIT_NY;
        nz = scenery.HIT_NZ;
        depth = scenery.HIT_D;
    }
}

const hitOut: Hit = new Hit();

export const GRAZE: f64 = 3; // meters of clearance that still count as a close call

// Close calls: a wider probe around the pilot. Leaving a graze that lasted a
// moment without touching anything raises evNearMiss.
function graze(p: Player, chunks: Array<Chunk>, touched: bool, dt: f64): void {
    p.grazeCd = lmax(0, p.grazeCd - dt);
    let nearHit = cf(chunks, p.pos.x, p.pos.y, p.pos.z, RADIUS + GRAZE);
    let nx = scenery.HIT_NX, ny = scenery.HIT_NY, nz = scenery.HIT_NZ, depth = scenery.HIT_D;
    // the sea floor / water tops do not count, only walls, stacks, arches, bridges
    if (nearHit && ny > 0.7) {
        nearHit = false;
    }
    if (nearHit) {
        let d = RADIUS + GRAZE - depth;
        p.nearX = <f64>p.pos.x - nx * d;
        p.nearY = <f64>p.pos.y - ny * d;
        p.nearZ = <f64>p.pos.z - nz * d;
        if (!p.grazing) {
            p.grazing = true;
            p.grazeT = 0;
            p.grazeHit = false;
        }
        p.grazeT += dt;
        p.grazeHit = p.grazeHit || touched;
    } else if (p.grazing) {
        p.grazing = false;
        if (!p.grazeHit && p.grazeT > 0.06 && p.grazeCd <= 0) {
            p.evNearMiss = true;
            p.grazeCd = 1.2;
        }
    }
}

// Lateral limits of the rail box at s: +-BOX_X, pinched inside the CLIFF TURN
// canyon to its walls (less a margin), eased in / out over 80 m at the canyon
// ends; past a waterfall ribbon that side pinches further.
const CANYON_MARGIN: f64 = 6.8;
const FALL_MARGIN: f64 = 4.5;
class CanyonFall {
    s: f64 = 0;
    side: f64 = 0;
    hw: f64 = 0;
}
let canyonFalls: Array<CanyonFall>? = null; // 1-based

function fallsIn(s0: f64, s1: f64): Array<CanyonFall> {
    let cached = canyonFalls;
    if (cached != null) {
        return cached;
    }
    let l = new Array<CanyonFall>(1);
    let wf = level.waterfalls;
    for (let i = 1; i < wf.length; i++) {
        let f = wf[i];
        if (f.s >= s0 - 80 && f.s <= s1 + 80) {
            track.frame(level.track, f.s);
            let tp = track.FRAME_P, rt = track.FRAME_R;
            let lat = (f.x - <f64>tp.x) * <f64>rt.x + (f.z - <f64>tp.z) * <f64>rt.z;
            let cfl = new CanyonFall();
            cfl.s = f.s;
            cfl.side = lat >= 0 ? 1.0 : -1.0;
            cfl.hw = f.width * 0.5;
            l.push(cfl);
        }
    }
    canyonFalls = l;
    return l;
}

// boxX(s) -> lo (also BOX_X_1), hi (BOX_X_2)
export let BOX_X_1: f64 = -BOX_X;
export let BOX_X_2: f64 = BOX_X;
export function boxX(s: f64): f64 {
    let A = level.anchors;
    let s0 = A.canyonS0, s1 = A.canyonS1;
    if (s1 <= s0 || s < s0 - 80 || s > s1 + 80) {
        BOX_X_1 = -BOX_X;
        BOX_X_2 = BOX_X;
        return BOX_X_1;
    }
    let mL = CANYON_MARGIN, mR = CANYON_MARGIN;
    let fl = fallsIn(s0, s1);
    for (let i = 1; i < fl.length; i++) {
        let f = fl[i];
        let k = 1 - mathx.smoothstep(12, 45, Math.abs(s - f.s) - f.hw);
        if (f.side < 0) {
            mL += FALL_MARGIN * k;
        } else {
            mR += FALL_MARGIN * k;
        }
    }
    let k = mathx.smoothstep(s0 - 80, s0 + 40, s) * (1 - mathx.smoothstep(s1 - 40, s1 + 80, s));
    let lo = mathx.lerp(-BOX_X, -lmin(BOX_X, level.cliffTurnDist(s, -1) - mL), k);
    let hi = mathx.lerp(BOX_X, lmin(BOX_X, level.cliffTurnDist(s, 1) - mR), k);
    BOX_X_1 = lo;
    BOX_X_2 = hi;
    return lo;
}

// Advance the pilot. Returns the collision record (shared object, valid until
// the next call; also UPDATE_1) and whether a barrel roll started this frame
// (UPDATE_2).
export let UPDATE_1: Hit = hitOut;
export let UPDATE_2: bool = false;
export function update(p: Player, c: Controls, dt: f64, chunks: Array<Chunk>): Hit {
    p.evOverheat = false;
    p.evBoost = false;
    p.evSplash = false;
    p.evNearMiss = false;
    let sA = p.s, xA = p.x, yA = p.y;
    let controls = p.controls && p.alive;
    let sx = 0.0, sy = 0.0;
    if (controls) {
        sx = c.sx;
        sy = c.sy;
    }
    p.sx = mathx.damp(p.sx, sx, 10, dt);
    p.sy = mathx.damp(p.sy, sy, 10, dt);

    // lateral / vertical: accelerate toward the stick target, quicker to push
    // than to coast, with a small overshoot-free response
    let tx = sx * MAX_VX, ty = sy * MAX_VY;
    // a stick held away from the rock is never cancelled: held at a face it
    // becomes the way round at once; escaping, the way out is found again
    // that way. Away = the side the rock has been pushing him to (the recent
    // push-outs' sideways sum), else the last normal's.
    let live = p.alive && !p.frozen;
    p.roomT -= dt;
    let openS = Math.abs(p.pushLat) > 0.05 ? mathx.sign(p.pushLat) : Math.abs(p.nLat) > 0.2 ? mathx.sign(p.nLat) : 0.0;
    let stA = stickSide(sx);
    // (not while the face he last touched pushes straight against the stick)
    let away = stA != 0 && stA == openS && stA * p.nLat > -0.5 && (p.hitT <= CONTACT_GAP || p.esc > 0);
    if (away && p.hitSide != stA && !roomTo(p, chunks, stA)) {
        // (nor where no way out lies that way short of the box's hard limit)
        away = false;
    }
    if (away && live && !p.ghost) {
        if (p.esc > 0 && stA != p.escSt && (p.escX - p.x) * stA <= 0) {
            // escaping the other way: the way out is found again, this way
            startEscape(p, chunks, sx, sy, stA, false);
        } else if (p.hold && p.hitSide != stA) {
            // (the blocked-slide test below measures the new slide afresh)
            p.hitSide = stA;
            p.flipped = true;
            p.holdX = p.x;
            p.holdXT = p.holdT;
        }
    }
    // held at a face, and just round it, the stick does not steer him back
    // into the rock he is sliding round (until the line that way is clear,
    // LOCK_MAX at most)
    if (p.hold && tx * p.hitSide < 0) {
        tx = 0;
    } else if (p.lockT > 0) {
        p.lockT = lmax(0, p.lockT - dt);
        if (tx * p.lockSide > 0) {
            if (!lockClear(p, chunks, p.lockSide)) {
                tx = 0;
            } else {
                p.lockT = 0;
            }
        }
        // (out from under / off the top of a rock: not straight back at it)
        if (ty * p.lockY > 0) {
            if (!lockClearY(p, chunks, p.lockY)) {
                ty = 0;
            } else {
                p.lockY = 0;
            }
        }
    }
    let rx = Math.abs(tx) > Math.abs(p.vx) || tx * p.vx < 0 ? 7.5 : 4.2;
    let ry = Math.abs(ty) > Math.abs(p.vy) || ty * p.vy < 0 ? 7.5 : 4.2;
    p.vx += (tx - p.vx) * (1 - Math.exp(-rx * dt));
    p.vy += (ty - p.vy) * (1 - Math.exp(-ry * dt));

    // barrel roll
    p.rollCd = lmax(0, p.rollCd - dt);
    let rolled = false;
    if (controls && p.rollT <= 0 && p.rollCd <= 0) {
        if (c.rollL) {
            p.rollDir = 1;
            p.rollT = ROLL_TIME;
            rolled = true;
        } else if (c.rollR) {
            p.rollDir = -1;
            p.rollT = ROLL_TIME;
            rolled = true;
        }
        if (rolled) {
            // sidestep impulse in the roll direction
            p.vx += -p.rollDir * 16;
        }
    }
    if (p.rollT > 0) {
        p.rollT = lmax(0, p.rollT - dt);
        let k = 1 - p.rollT / ROLL_TIME;
        // fast in, eased out
        let e = 1 - Math.pow(1 - k, 2.6);
        p.roll = p.rollDir * e * mathx.TAU;
        if (p.rollT <= 0) {
            p.roll = 0;
            p.rollCd = 0.12;
        }
    } else {
        p.roll = 0;
    }

    // escaping (the stall guard): for the way out, at ESC_V; the last
    // resort's move at MOVE_STEP a frame at most (no teleport)
    let moving = (p.esc > 0 || p.ghost) && live && dt > 0;
    let backV = 0.0;
    if (moving && p.s > p.escS + 0.05) {
        // (backing along his track, <= 0.9 BACK_OFF a frame)
        let rb = p.s - p.escS;
        let ex = p.escDiag ? p.escX - p.x : 0.0, ey = p.escDiag ? p.escY - p.y : 0.0;
        let L = Math.sqrt(ex * ex + ey * ey);
        let k = lmin(lmin(1, 0.9 * BACK_OFF / rb), L > 1e-3 ? (p.ghost ? MOVE_STEP : ESC_V * dt) / L : 1);
        p.vx = ex * k / dt;
        p.vy = ey * k / dt;
        backV = -rb * k / dt - p.speed * p.railK;
        if (k >= 1) {
            p.escS = HUGE;
        }
    } else if (moving) {
        let ex = p.escX - p.x, ey = p.escY - p.y;
        let L = Math.sqrt(ex * ex + ey * ey);
        if (L > 1e-3) {
            let v = lmin(L / dt, p.ghost ? MOVE_STEP / dt : ESC_V);
            let dx = ex / L, dy = ey / L, df = 0.0;
            let dn = dx * p.nLat + dy * p.nUp;
            if (!p.ghost && p.hitT <= 0 && dn < -0.2) {
                dx = dx - dn * p.nLat;
                dy = dy - dn * p.nUp;
                df = -dn * p.nFwd;
                let tl = Math.sqrt(dx * dx + dy * dy + df * df);
                if (tl > 0.1 && df <= 0) {
                    dx = dx / tl;
                    dy = dy / tl;
                    df = df / tl;
                    v = ESC_V;
                } else {
                    dx = ex / L;
                    dy = ey / L;
                    df = 0;
                }
            }
            p.vx = dx * v;
            p.vy = dy * v;
            backV = lmax(df * v, -BACK_OFF / dt);
        } else {
            p.vx = 0;
            p.vy = 0;
        }
    }
    boxX(p.s);
    let bx0 = BOX_X_1, bx1 = BOX_X_2;
    let settling = p.laneT > 0 && p.laneX >= bx0 + LANE_EDGE && p.laneX <= bx1 - LANE_EDGE;
    let x = p.x, y = p.y;
    let vx = softAxis(p.x, p.vx, bx0, bx1, EDGE, dt, p.hold || moving || settling);
    let vy = softAxis(p.y, p.vy, BOX_Y0, BOX_Y1, 3, dt, moving);
    p.vx = vx;
    p.vy = vy;
    p.x = mathx.clamp(x + p.vx * dt, bx0 - 2, bx1 + 2);
    p.y = mathx.clamp(y + p.vy * dt, BOX_Y0 - 0.3, BOX_Y1 + 2);
    p.wetT += dt;
    if (p.y < BOX_Y0) {
        p.y = mathx.damp(p.y, BOX_Y0, 12, dt);
        if (p.vy < -4 && p.wetT > 0.4) {
            p.evSplash = true;
        }
        if (p.vy < 0) {
            p.vy *= 0.5;
        }
        p.wetT = 0;
    }

    // boost / brake / heat
    let wasBoosting = p.boosting;
    let canBoost = p.overheat <= 0 && p.boost > (wasBoosting ? 0.5 : 8);
    p.boosting = controls && c.boost && canBoost;
    p.braking = controls && !p.boosting && c.brake;
    if (p.boosting && !wasBoosting) {
        p.boostKick = 1;
        p.evBoost = true;
    }
    p.boostKick = lmax(0, p.boostKick - dt * 1.6);
    let target = CRUISE;
    if (p.boosting) {
        target = BOOST;
        p.boost = lmax(0, p.boost - 30 * dt);
        p.boostDelay = 0.6;
        addHeat(p, 16 * dt);
    } else if (p.braking) {
        target = BRAKE;
        p.boost = lmax(0, p.boost - 6 * dt);
        p.boostDelay = 0.6;
    } else {
        p.boostDelay = lmax(0, p.boostDelay - dt);
        if (p.boostDelay <= 0) {
            p.boost = lmin(100, p.boost + 11 * dt);
        }
    }
    if (p.speedCap > 0) {
        target = lmin(target, p.boosting ? p.speedCap + 25 : p.speedCap);
    }
    if (p.frozen) {
        target = 0;
    }
    p.targetSpeed = target;
    let srate = target > p.speed ? (p.boosting ? 3.2 : 1.6) : 2.4;
    p.speed = mathx.damp(p.speed, target, srate, dt);
    p.heatDelay = lmax(0, p.heatDelay - dt);
    if (p.heatDelay <= 0) {
        let cool = p.overheat > 0 ? 34.0 : 22.0;
        p.heat = lmax(0, p.heat - cool * dt);
    }
    p.overheat = lmax(0, p.overheat - dt);
    p.invuln = lmax(0, p.invuln - dt);
    p.hurtCd = lmax(0, p.hurtCd - dt);
    p.flash = lmax(0, p.flash - dt * 4);

    // thrust (visual): hover idles low, cruise mid, boost full
    let th: f64 = p.boosting ? 1.0 : p.braking ? 0.25 : 0.55;
    if (p.frozen) {
        th = 0.3;
    }
    p.thrust = mathx.damp(p.thrust, th, 6, dt);

    // bank / pitch: follow velocity plus stick anticipation
    let bankT = -(p.vx / MAX_VX) * 0.7 - p.sx * 0.22;
    p.bank = mathx.damp(p.bank, bankT, 9, dt);
    p.pitch = mathx.damp(p.pitch, (p.vy / MAX_VY) * 0.45 + p.sy * 0.1, 8, dt);

    // advance along the rail (held at a face: barely)
    if (!p.frozen) {
        p.s = lmin(p.s + (p.speed * p.railK + backV) * dt, level.track.length - 1);
    }
    let wasHeld = p.hold;
    p.hold = false;
    place(p);

    // skim multiplier: low over water builds it
    let alt = <f64>p.pos.y;
    if (alt < SKIM_ALT && p.overWater && p.alive && !p.frozen) {
        p.skimT = lmin(p.skimT + dt, 4 * 1.2);
        p.lowT += dt;
    } else {
        p.skimT = lmax(0, p.skimT - dt * 3);
    }
    p.skim = p.skimT > 0.5 ? lmin(4, 2 + Math.floor((p.skimT - 0.5) / 1.3)) : 1.0;

    let hit = hitOut;
    hit.hit = false;
    p.hitT += dt;
    if (p.hitT > CONTACT_GAP && p.esc <= 0 && !p.ghost) {
        endContact(p);
    }
    if (live) {
        p.esc = lmax(0, p.esc - dt);
        if (!p.ghost) {
            collide(p, chunks, hit, sA, xA, yA);
        }
        // (the last resort's move passing rock is no close call)
        graze(p, chunks, hit.hit || p.ghost, dt);
        if (slideTo >= 0) {
            // a first head-on touch whose slide round is long, or has no clear
            // line short of the soft edge band: over or under it when that is
            // nearer (an escape), else, with no line, the held slide goes the
            // way out findOut found
            let o1 = slideTo;
            slideTo = -1;
            if (p.esc <= 0 && o1 > OUT_SLIDE) {
                let stx = stickSide(sx), sty = stickSide(sy);
                let ok = findOut(p, chunks, stx, sty, 0, false, true);
                let dx = OUT_DX, dy = OUT_DY, b = OUT_B, diag = OUT_DIAG;
                if (ok && b > 0 && o1 > 2 * OUT_SLIDE) {
                    // (a long way round whose straight way runs into the
                    // rock: backing off it at once beats a slide pressed
                    // along it)
                    beginEscape(p, dx, dy, b, stx, false, diag);
                } else if (ok && dy != 0 && (o1 == HUGE || Math.abs(dx) + Math.abs(dy) * (dy > 0 ? OUT_UP : 1) + 1.5 < o1)) {
                    beginEscape(p, dx, dy, 0, stx, false, false);
                } else if (ok && dx != 0 && o1 == HUGE) {
                    p.hitSide = dx > 0 ? 1.0 : -1.0;
                    p.laneX = p.x + dx;
                    p.vx = p.hitSide * Math.abs(p.vx);
                    p.laneT = -2;
                }
            }
        }
        if (wasHeld && !p.hold && p.holdT < HOLD_MAX && !aheadClear(p, chunks)) {
            // off the face but still in front of it: held until his line is
            // clear 1.5 and 4 m ahead
            p.hold = true;
            p.hitT = 0;
        }
    }
    // stall guard: rock never holds him still (see player.luau). The stall
    // measure is his net rail progress in a contact (or escaping).
    if (live && dt > 0) {
        if (p.hitT <= CONTACT_GAP || p.esc > 0 || p.ghost) {
            p.pushLat *= Math.exp(-dt / 0.3);
            p.sideV = mathx.damp(p.sideV, (p.x - xA) * p.hitSide / dt, 10, dt);
            p.stallT += dt;
            if (p.s - p.stS >= STALL_STEP || (!hit.hit && !p.hold && p.esc <= 0 && !p.ghost && p.stallT >= STALL_T && aheadClear(p, chunks))) {
                // (or untouched and not held, his line clear 1.5 and 4 m
                // ahead: free, his way along the rail coming back)
                p.stS = p.s;
                p.stallT = 0;
                p.lastOk = false;
            }
        } else {
            p.stS = p.s;
            p.stallT = 0;
            p.lastOk = false;
        }
        if (p.hold && p.esc <= 0 && !p.ghost) {
            // pressed against a face his way into it is gone at once and he
            // slides round it
            if (p.holdT <= 0) {
                p.holdX = p.x;
                p.holdXT = 0;
            } else if (p.laneT > 0 && !wasHeld) {
                // (held again after a lapse of the hold: the settle is
                // planned when the slide really lets him go)
                p.laneT = -2;
            }
            p.holdT += dt;
            if (p.holdT - p.holdXT >= STALL_W) {
                // the slide is blocked (wedged, or a face leaning against it
                // pushes him back as fast): the way out at once
                let moved = (p.x - p.holdX) * p.hitSide, win = p.holdT - p.holdXT;
                let blocked = moved < STALL_K * HEAD_V * win;
                p.holdX = p.x;
                p.holdXT = p.holdT;
                if (blocked) {
                    let stx = stickSide(sx), sty = stickSide(sy);
                    let ok = findOut(p, chunks, stx, sty, away ? stA : 0, false, true);
                    let dx = OUT_DX, dy = OUT_DY, b = OUT_B, diag = OUT_DIAG;
                    if (!ok) {
                        startEscape(p, chunks, sx, sy, 0, false);
                    } else if (dy == 0 && dx * p.hitSide > 0 && moved >= 0.03 * HEAD_V * win) {
                        // (the way out lies the way he slides and he is
                        // getting there: the slow slide goes on)
                    } else if (dx != 0 || dy != 0 || b != 0) {
                        beginEscape(p, dx, dy, b, stx, false, diag);
                    }
                }
            }
        }
        if (!p.ghost && (p.hitT <= CONTACT_GAP || p.esc > 0)) {
            // (a held slide still making way round, its side never turned:
            // the hold-at-face feel of a long face, up to LAST_T2)
            let free = p.hold && p.sideV >= 0.25 * HEAD_V && !p.flipped;
            if (p.stallT >= LAST_T2 || (p.stallT >= LAST_T && !free)) {
                startEscape(p, chunks, sx, sy, 0, true);
            } else if (p.stallT >= LAST_T && !p.lastOk) {
                // (that slide: let go on only when the nearest spot is just
                // ahead of it, LAST_NEAR; else the last resort now)
                p.lastOk = true;
                let ok = findOut(p, chunks, 0, 0, 0, false, true, true);
                let dx = OUT_DX, dy = OUT_DY, b = OUT_B, diag = OUT_DIAG;
                if (ok && !(dy == 0 && b == 0 && dx * p.hitSide >= 0 && Math.abs(dx) <= LAST_NEAR)) {
                    beginEscape(p, dx, dy, b, 0, true, diag);
                }
            } else if (p.esc <= 0 && !free && (p.stallT >= STALL_T || (p.hold && p.holdT >= HOLD_FACE_MAX))) {
                startEscape(p, chunks, sx, sy, away ? stA : 0, false);
            }
        }
        if (p.esc > 0 || p.ghost) {
            // out: the last resort at its spot, an escape untouched with his
            // line clear 1.5 and 4 m ahead; his climb / dive stops there and
            // his speed comes back
            let out: bool;
            if (p.ghost) {
                out = (Math.abs(p.escX - p.x) < 0.05 && Math.abs(p.escY - p.y) < 0.05 && p.escS > 1e9) || p.esc <= 0;
            } else {
                out = !hit.hit && lineClear(p, chunks, 0);
            }
            if (out) {
                if (p.ghost) {
                    // (moved out whole: his speed along the rail comes back now)
                    p.railK = lmax(p.railK, 0.35);
                    p.vx *= 0.3;
                }
                p.esc = 0;
                p.ghost = false;
                p.lastOk = false;
                p.vy = 0;
                p.speed = lmax(p.speed, HEAD_SPEED);
                p.stS = p.s;
                p.stallT = 0;
            } else if (!p.ghost && p.esc < ESC_T - 0.05 && Math.abs(p.escX - p.x) < 0.1 && Math.abs(p.escY - p.y) < 0.1 && p.escS > 1e9) {
                // (there, and not out: the way out is found again from here)
                startEscape(p, chunks, sx, sy, away ? stA : 0, false);
            }
        }
    }
    if ((p.esc > 0 || p.ghost) && live) {
        // escaping: no hold, and his way along the rail stays low until he
        // is out
        p.hold = false;
        p.railK = lmin(p.railK, ESC_K);
        p.speed = mathx.damp(p.speed, lmin(p.speed, HEAD_SPEED), 14, dt);
    } else if (p.hold) {
        p.railK = HOLD_K;
        p.speed = mathx.damp(p.speed, lmin(p.speed, HEAD_SPEED), 14, dt);
        let v = lmin(HEAD_V_MAX, HEAD_V + HEAD_ACC * p.holdT);
        p.vx = p.hitSide * lmax(v, p.vx * p.hitSide > 0 ? Math.abs(p.vx) : 0);
    } else {
        p.railK = mathx.damp(p.railK, 1, 6, dt);
        if (live && p.laneT < 0 && (p.holdT > 0 || p.glance || p.flips > 0)) {
            // let go round the rock: the stick is kept off it for a moment,
            // and hands off he settles into the lane past it
            p.lockT = LOCK_MAX;
            p.lockSide = -p.hitSide;
            if (tx * p.lockSide > 0) {
                tx = 0;
            }
            if (Math.abs(sx) < 0.2 && (p.laneT < -1.5 || p.flipped)) {
                p.laneX = settleLane(p, chunks);
            }
            p.laneT = LANE_T;
        }
        if (p.laneT > 0 && Math.abs(sx) >= 0.2) {
            // any stick input ends the settle
            p.laneT = 0;
        }
        if (!live) {
            // (frozen under a card: no settle, no slide)
        } else if (p.laneT > 0) {
            p.laneT = lmax(0, p.laneT - dt);
            if ((p.laneX - p.x) * p.lockSide > 0) {
                // (never back toward the rock: he stays on the line he has)
                p.laneX = p.x;
            }
            if (!hit.hit) {
                p.vx = mathx.damp(p.vx, mathx.clamp((p.laneX - p.x) * 5, -MAX_VX, MAX_VX), 8, dt);
            }
        } else if (p.holdT > 0 || p.glance || p.flips > 0) {
            // round the face (or let go by an escape): the sidestep gives way
            // to the stick so he does not sail on across the lanes
            p.vx = mathx.damp(p.vx, tx, OFF_RATE, dt);
        }
    }
    UPDATE_1 = hit;
    UPDATE_2 = rolled;
    return hit;
}

// Crash tumble after the shield is gone: falls, spins, hits the sea. chunks:
// the scenery (optional): he glances off rock instead of falling through the
// stack he hit.
export function updateDead(p: Player, dt: f64, chunks: Array<Chunk>? = null): bool {
    let sA = p.s, xA = p.x, yA = p.y;
    if (p.hitT < 1) {
        // just off rock: a falling body glances off, no sidestep round it,
        // and the shove fades
        p.vx = mathx.damp(mathx.clamp(p.vx, -OFF_V, OFF_V), 0, 3, dt);
    }
    p.speed = mathx.damp(p.speed, 22, 1.2, dt);
    p.railK = 1;
    p.s = lmin(p.s + p.speed * dt, level.track.length - 1);
    p.vy -= 26 * dt;
    p.y += p.vy * dt;
    p.x += p.vx * dt;
    p.roll += dt * 9;
    p.bank = mathx.damp(p.bank, 0.9, 3, dt);
    // the fatal hit's white flash fades as in flight (update no longer runs)
    p.flash = lmax(0, p.flash - dt * 4);
    place(p);
    if (!p.tumble) {
        // a falling body glances off the way the face it meets leans
        p.tumble = true;
        endContact(p);
        // (no escape / last resort carries into the fall)
        p.esc = 0;
        p.ghost = false;
    }
    if (chunks != null) {
        let hit = hitOut;
        p.hitT += dt;
        if (p.hitT > CONTACT_GAP) {
            endContact(p);
        }
        p.hold = false;
        collide(p, chunks, hit, sA, xA, yA);
        if (hit.hit) {
            p.speed = lmin(p.speed, 12);
            p.vx = mathx.clamp(p.vx, -OFF_V, OFF_V);
        }
    }
    return <f64>p.pos.y <= 0.3;
}
