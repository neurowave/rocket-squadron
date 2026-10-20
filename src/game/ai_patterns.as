// Port of src/game/ai_patterns.luau. Enemy behaviors, their wrecks and how each kind is drawn.
// Choreographed flight paths (rail-relative waypoint splines), hovering
// drones, kamikaze dives, racing jet troopers, sea mines and cliff turrets.
// OWNER: enemies & events agent.
//
// Rail-relative paths: keys are {t, s, x, y} where s is meters ahead of the
// player, x lateral, y height above the rail base. Planes face along their
// *relative* velocity (plus a forward bias) so a U-turn reads as a U-turn on
// screen even though the whole formation keeps pace with the player.
//
// Port: PATHS is a Map of 1-based key lists (rows 1-based {t, s, x, y}).
// sample -> SAMPLE_1..3. Module state (the lens, the kill ripple) is global
// as in Luau.
import { Vector } from "rive/vector";
import { Ctx } from "./types";
import * as ai from "./ai_types";
import { Enemy, World } from "./ai_types";
import * as fx from "./fx";
import * as models from "./models";
import { Models } from "./models";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import * as gpu from "../lib/gpu";
import { Batch } from "../lib/gpu";
import * as level from "../world/level";
import { HUGE, lmin, lmax, mod, lrandom } from "../lib/compat";

// Paths -----------------------------------------------------------------------

function makePaths(): Map<string, Array<Array<f64>>> {
    let m = new Map<string, Array<Array<f64>>>();
    // squadron zooms past the camera, U-turns ahead and comes back strafing
    m.set("overtake", [[0.0],
        [0.0, 0.0, -34, -3, 13],
        [0.0, 0.8, 8, 0, 11],
        [0.0, 1.7, 44, 3, 10],
        [0.0, 2.6, 66, 8, 11],
        [0.0, 3.4, 74, 16, 13],
        [0.0, 4.2, 66, 22, 14],
        [0.0, 5.0, 50, 17, 12],
        [0.0, 5.9, 32, 8, 10],
        [0.0, 6.8, 8, 0, 8],
        [0.0, 7.6, -24, -8, 8],
        [0.0, 8.4, -64, -16, 9],
    ]);
    // head-on strafing run from far ahead
    m.set("headon", [[0.0],
        [0.0, 0.0, 260, 4, 14],
        [0.0, 2.0, 150, 3, 12],
        [0.0, 3.3, 75, 2, 9],
        [0.0, 4.1, 32, 0, 7],
        [0.0, 4.7, 4, 7, 9],
        [0.0, 5.5, -34, 18, 14],
        [0.0, 6.3, -70, 26, 18],
    ]);
    // vertical loop in front of the player
    m.set("loop", [[0.0],
        [0.0, 0.0, 170, 0, 8],
        [0.0, 1.4, 110, 0, 8],
        [0.0, 2.2, 88, 0, 12],
        [0.0, 2.8, 84, 0, 20],
        [0.0, 3.3, 92, 0, 27],
        [0.0, 3.8, 104, 0, 24],
        [0.0, 4.2, 104, 0, 15],
        [0.0, 4.7, 92, 0, 9],
        [0.0, 5.5, 62, 2, 8],
        [0.0, 6.3, 24, 6, 9],
        [0.0, 7.1, -16, 12, 11],
        [0.0, 7.9, -60, 18, 14],
    ]);
    // lateral sweep across the rail ahead
    m.set("sweep", [[0.0],
        [0.0, 0.0, 125, -85, 20],
        [0.0, 1.6, 104, -44, 14],
        [0.0, 3.0, 88, -4, 11],
        [0.0, 4.4, 78, 36, 13],
        [0.0, 5.8, 74, 80, 18],
        [0.0, 7.0, 80, 120, 24],
    ]);
    // steep dive toward the water and zoom climb past the player
    m.set("dive", [[0.0],
        [0.0, 0.0, 170, 0, 48],
        [0.0, 1.4, 110, 0, 30],
        [0.0, 2.4, 66, 0, 9],
        [0.0, 3.0, 46, 0, 4],
        [0.0, 3.7, 28, 0, 8],
        [0.0, 4.5, 8, 0, 18],
        [0.0, 5.3, -30, 0, 32],
    ]);
    // overtake from behind that settles ahead of the player, then breaks
    // away in a steep climb (out the top of the view, over any coast ahead).
    // It comes over the top, 21 m+ above the water as it passes him: clear
    // of a pilot skimming the LOW PASS under 3 m and of one hopping the fangs
    // under it (2060, 2140: tops ~15 m); it only settles low 30 m+ ahead.
    // (It starts 30 m back: the V's last rank, 14 m further, stays inside
    // the -45 m cull for rail-relative craft.)
    m.set("escort", [[0.0],
        [0.0, 0.0, -30, 0, 25],
        [0.0, 0.8, -12, 0, 23],
        [0.0, 1.8, 14, 2, 20],
        [0.0, 2.8, 34, 4, 13],
        [0.0, 4.2, 54, 6, 7],
        [0.0, 5.4, 60, -2, 6],
        [0.0, 6.6, 66, -10, 9],
        [0.0, 7.6, 100, -24, 22],
        [0.0, 8.4, 150, -34, 42],
        [0.0, 9.4, 200, -34, 84],
    ]);
    // a column snaking down into the canyon slot: drops in over the far
    // rim, weaves S-turns ahead (|x| <= ~8), then climbs out over the pilot
    m.set("snake", [[0.0],
        [0.0, 0.0, 160, 0, 40],
        [0.0, 1.2, 118, 5, 25],
        [0.0, 2.3, 94, -6, 15],
        [0.0, 3.4, 82, 7, 10],
        [0.0, 4.5, 76, -7, 10],
        [0.0, 5.6, 72, 6, 13],
        [0.0, 6.6, 56, -3, 17],
        [0.0, 7.5, 26, 0, 24],
        [0.0, 8.4, -16, 0, 32],
        [0.0, 9.2, -60, 0, 40],
    ]);
    return m;
}

export const PATHS: Map<string, Array<Array<f64>>> = makePaths();

// Catmull-Rom sample of a time-keyed path -> SAMPLE_1..3 (s, x, y).
export let SAMPLE_1: f64 = 0;
export let SAMPLE_2: f64 = 0;
export let SAMPLE_3: f64 = 0;
@inline function cr(a: f64, b: f64, c: f64, d: f64, u: f64, u2: f64, u3: f64): f64 {
    return 0.5 * ((2 * b) + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (-a + 3 * b - 3 * c + d) * u3);
}
export function sample(path: Array<Array<f64>>, t: f64): f64 {
    let n = path.length - 1;
    if (t <= path[1][1]) {
        let k = path[1];
        SAMPLE_1 = k[2];
        SAMPLE_2 = k[3];
        SAMPLE_3 = k[4];
        return SAMPLE_1;
    }
    if (t >= path[n][1]) {
        // extrapolate along the last segment
        let a = path[n - 1], b = path[n];
        let u = (t - b[1]) / lmax(b[1] - a[1], 1e-3);
        SAMPLE_1 = b[2] + (b[2] - a[2]) * u;
        SAMPLE_2 = b[3] + (b[3] - a[3]) * u;
        SAMPLE_3 = b[4] + (b[4] - a[4]) * u;
        return SAMPLE_1;
    }
    let i = 1;
    while (i < n - 1 && path[i + 1][1] < t) {
        i += 1;
    }
    let p0 = path[i - 1 > 1 ? i - 1 : 1];
    let p1 = path[i];
    let p2 = path[i + 1];
    let p3 = path[i + 2 < n ? i + 2 : n];
    let u = (t - p1[1]) / lmax(p2[1] - p1[1], 1e-4);
    let u2 = u * u, u3 = u * u * u;
    SAMPLE_1 = cr(p0[2], p1[2], p2[2], p3[2], u, u2, u3);
    SAMPLE_2 = cr(p0[3], p1[3], p2[3], p3[3], u, u2, u3);
    SAMPLE_3 = cr(p0[4], p1[4], p2[4], p3[4], u, u2, u3);
    return SAMPLE_1;
}

// Rock hop ------------------------------------------------------------------------

// Rocks standing near the rail, {s, x, radius, top}: mirrors the stacks,
// fangs, pillars, skerries and the wreck placed in scenery (sectionLighthouse
// / Arch / LowPass / Canyon / Climb, the violet lagoon, the falls pool; slalom
// radii at their 7 m maximum). Sorted by s. (1-based)
const ROCKS: Array<Array<f64>> = [[0.0],
    [0.0, 250, 64, 10, 34], [0.0, 250, -34, 3.2, 2.2], [0.0, 300, 86, 6, 22], [0.0, 360, -84, 8, 26], [0.0, 470, 36, 3.6, 2.4],
    [0.0, 610, 46, 4.5, 3.2], [0.0, 760, 4, 6, 22], [0.0, 790, -66, 11, 38], [0.0, 810, 18, 7, 24], [0.0, 840, -88, 7, 26],
    [0.0, 870, -5, 6.5, 23], [0.0, 935, -14, 7, 23], [0.0, 972, 10, 5.6, 21],
    // 02 SEA ARCH: slalom + the gate stacks at the box edge
    [0.0, 1010, 6, 7, 23], [0.0, 1010, -19, 7, 36], [0.0, 1090, -6.5, 7, 22], [0.0, 1090, 19, 7, 30], [0.0, 1170, 6, 7, 24],
    [0.0, 1170, -19, 7, 36], [0.0, 1250, -6, 7, 21], [0.0, 1250, 19, 7, 30], [0.0, 1330, 6.5, 7, 24], [0.0, 1330, -19, 7, 36],
    [0.0, 1410, -6, 7, 22], [0.0, 1410, 19, 7, 30], [0.0, 1520, 26, 3.4, 2.4], [0.0, 1560, -40, 8, 30], [0.0, 1600, 44, 9, 34],
    [0.0, 1780, -30, 3, 2],
    // 03 LOW PASS: skim rocks, fangs, stacks, the wreck
    [0.0, 1900, -17, 3.4, 1.8], [0.0, 1950, 74, 10, 30], [0.0, 1985, 20, 3.8, 2.4], [0.0, 2060, -15, 4.2, 14], [0.0, 2100, -8, 2.8, 1.3],
    [0.0, 2140, 14, 4.2, 13], [0.0, 2150, -96, 12, 40], [0.0, 2210, 16, 3.2, 2], [0.0, 2220, 9.5, 4.2, 14], [0.0, 2250, -21, 4.4, 15],
    [0.0, 2300, -12, 4.2, 15], [0.0, 2320, -20, 4, 2.6], [0.0, 2380, 88, 8, 26], [0.0, 2385, 15, 4.2, 14], [0.0, 2466, 52, 2.4, 1.2],
    [0.0, 2470, 7, 2.6, 1.2], [0.0, 2480, 44, 13, 21], [0.0, 2498, 36, 3, 1.6], [0.0, 2520, 10, 4.2, 15], [0.0, 2580, -14, 3.6, 2],
    [0.0, 2585, -21, 4.5, 16], [0.0, 2610, 21, 4.4, 14], [0.0, 2620, -72, 10, 34], [0.0, 2665, -15, 4.3, 15], [0.0, 2690, 18, 3, 1.8],
    [0.0, 2740, 16, 4.2, 14], [0.0, 2790, -5, 2.4, 1.1], [0.0, 2815, -9, 4.2, 15],
    // 04 CLIFF TURN pillars (none past 3580), 05 the stacks flanking the
    // canyon mouth out in the bay
    [0.0, 3060, -9, 3.4, 28], [0.0, 3260, 3, 3.6, 30], [0.0, 3380, 9, 3.4, 30], [0.0, 3580, -3, 3.4, 26],
    [0.0, 3960, -130, 10, 38], [0.0, 4040, 80, 11, 44],
    // 06 the lagoon where the dive levels out (vrock)
    [0.0, 6390, -18, 4.5, 6], [0.0, 6440, -42, 7, 14], [0.0, 6450, 21, 5, 9], [0.0, 6520, -9, 3.2, 4], [0.0, 6560, 46, 8, 18],
    [0.0, 6575, 15, 4, 5.5],
    // 07 THE FALLS pool rocks
    [0.0, 6760, 22, 3.5, 5], [0.0, 6990, -21, 4, 6], [0.0, 7180, 23, 3, 4], [0.0, 7520, -22, 3.6, 5],
];
// a flyer lined up with a rock (within 3 m of its radius laterally, fading
// out by 8 m) climbs over it from HOP_REACH m before it
const HOP_REACH: f64 = 34;
const HOP_CLEAR: f64 = 5;

// CLIFF TURN rock bridges spanning the slot (scenery sectionCanyon: {s,
// underside height, crown}; the last one stands at 3560, flown under before
// the Stormcrow's cue): a flyer at the span's height stays BRIDGE_CLEAR m
// under it within BRIDGE_REACH m of its s. (1-based)
const BRIDGES: Array<Array<f64>> = [[0.0], [0.0, 3130, 50, 9], [0.0, 3470, 24, 8], [0.0, 3560, 44, 10]];
const BRIDGE_REACH: f64 = 14;
const BRIDGE_CLEAR: f64 = 3;

// The height a flyer at (sAbs, y) may have under a bridge span (y when none
// is near, or it flies clear over the top).
function underSpan(sAbs: f64, y: f64): f64 {
    for (let i = 1; i < BRIDGES.length; i++) {
        let b = BRIDGES[i];
        let ds = Math.abs(sAbs - b[1]);
        if (ds < BRIDGE_REACH && y < b[2] + b[3] + 6) {
            let cap = b[2] - BRIDGE_CLEAR + mathx.smoothstep(BRIDGE_REACH * 0.6, BRIDGE_REACH, ds) * 30;
            y = lmin(y, cap);
        }
    }
    return y;
}

// Extra height that keeps a flyer at (sAbs, x) with planned height y at
// least HOP_CLEAR over any rock it would pass within radius + 3 m.
function hop(sAbs: f64, x: f64, y: f64): f64 {
    let need = 0.0;
    for (let i = 1; i < ROCKS.length; i++) {
        let r = ROCKS[i];
        if (r[1] > sAbs + HOP_REACH + 13) {
            break; // sorted by s; no rock is wider than 13 m
        }
        let ds = Math.abs(sAbs - r[1]) - r[3];
        if (ds < HOP_REACH) {
            let lift = r[4] + HOP_CLEAR - y;
            if (lift > need) {
                let dx = Math.abs(x - r[2]) - r[3];
                if (dx < 8) {
                    need = lmax(need, lift * mathx.smoothstep(8, 3, dx) * mathx.smoothstep(HOP_REACH, 2, ds));
                }
            }
        }
    }
    return need;
}

// Canyon walls (scenery sectionCanyon / THE FALLS strips): the room a flyer
// has from the rail. The cliff canyon's inner face funnels in from 80 m
// before it and leans back 0.12 * height; THE FALLS walls are studded with
// boulders (radius 13-23) that stand up to ~16 m proud of the face.
const CANYON0: f64 = level.anchors.canyonS0, CANYON1: f64 = level.anchors.canyonS1;
const FALLS0: f64 = 6620, FALLS1: f64 = 7680;

function wallRoom(sAbs: f64, side: f64, y: f64): f64 {
    if (sAbs >= CANYON0 - 80 && sAbs <= CANYON1 + 40) {
        return level.cliffTurnDist(sAbs, side) + lmax(0, CANYON0 + 10 - sAbs) * 0.55 + 0.12 * y - 5;
    } else if (sAbs >= FALLS0 && sAbs <= FALLS1) {
        return level.fallsDist(sAbs, side) - 20;
    }
    return HUGE;
}

// Lens guard: the camera's lens (world, the fx record's eye, a frame behind;
// set by update). A flyer passing it keeps LENS_R m off it, pushed out
// sideways, from LENS_B0..B1 m behind the lens (ramping in) to LENS_F0..F1
// m in front (ramping out; the pilot rides ~10-16 m in front of it, so
// anything near him is untouched). Overtakes and escorts start behind the
// camera and used to fly through it.
let lensX: f64 = 0, lensY: f64 = 0, lensZ: f64 = 0;
const LENS_R: f64 = 7;
const LENS_B0: f64 = -7, LENS_B1: f64 = -1.5;
const LENS_F0: f64 = 7, LENS_F1: f64 = 12;
// a live craft whose hull comes within LENS_FADE1 m of the lens fades
// toward the sky behind it (gone by LENS_FADE0), like a wreck melts; one
// already past the pilot fades from LENS_BEHIND1 m (gone by LENS_BEHIND0)
const LENS_FADE0: f64 = 2.5, LENS_FADE1: f64 = 7.5;
const LENS_BEHIND0: f64 = 6, LENS_BEHIND1: f64 = 16;

// A kamikaze dive that misses closes on the pilot at ~120 m/s. Looked
// PASS_LOOK s ahead, a dive that is passing him wide of PASS_WIDE0..1 m has
// missed: it melts into the sky in the frames before it draws level (0..1),
// and stops taking locks. One on target (inside PASS_WIDE0) stays solid.
const PASS_LOOK: f64 = 0.05;
const PASS_WIDE0: f64 = 2.5, PASS_WIDE1: f64 = 4.5;

export function passing(e: Enemy, ctx: Ctx): f64 {
    if (e.ai != "kamikaze" || !e.world || e.dying > 0) {
        return 0;
    }
    let pl = ctx.player;
    let f = pl.fwd, p = pl.pos;
    let fx0 = <f64>f.x, fy0 = <f64>f.y, fz0 = <f64>f.z;
    let closing = e.wvx * fx0 + e.wvy * fy0 + e.wvz * fz0 - pl.speed;
    let dx = e.x - <f64>p.x, dy = e.y - <f64>p.y, dz = e.z - <f64>p.z;
    let al = dx * fx0 + dy * fy0 + dz * fz0;
    let past = mathx.smoothstep(1.5, -1.5, al + lmin(closing, 0) * PASS_LOOK);
    if (past <= 0) {
        return 0;
    }
    dx = dx - fx0 * al;
    dy = dy - fy0 * al;
    dz = dz - fz0 * al;
    return past * mathx.smoothstep(PASS_WIDE0, PASS_WIDE1, Math.sqrt(dx * dx + dy * dy + dz * dz));
}

function lensGuard(e: Enemy, pos: Vector, f: Vector, rt: Vector, ry: f64): void {
    let lx = lensX - <f64>pos.x, lz = lensZ - <f64>pos.z;
    let fx0 = <f64>f.x, fz0 = <f64>f.z;
    let fl = lmax(Math.sqrt(fx0 * fx0 + fz0 * fz0), 1e-6);
    // the craft's station ahead of the lens (m along the rail)
    let along = -(lx * fx0 + lz * fz0) / fl;
    if (along <= LENS_B0 || along >= LENS_F1) {
        return;
    }
    let need = LENS_R * mathx.smoothstep(LENS_B0, LENS_B1, along) * (1 - mathx.smoothstep(LENS_F0, LENS_F1, along));
    let dy = ry - (lensY - <f64>pos.y);
    if (need <= 0 || Math.abs(dy) >= need) {
        return;
    }
    let want = Math.sqrt(need * need - dy * dy);
    let lat0 = lx * <f64>rt.x + lz * <f64>rt.z;
    let dx = e.rx - lat0;
    if (Math.abs(dx) < want) {
        let side = Math.abs(dx) > 0.05 ? (dx > 0 ? 1.0 : -1.0) : (e.side < 0 ? -1.0 : 1.0);
        e.rx = lat0 + side * want;
    }
}

// Shared kinematics ---------------------------------------------------------------

// Places the enemy from rail coords, estimates rail-relative velocity and
// acceleration, and leaves the rail frame at its position in KF / KR / KU.
// Flyers keep off the canyon walls and hop over the rocks near the rail
// (`Enemy.lift`).
let KF: Vector = Vector.xyz(0, 0, -1);
let KR: Vector = Vector.xyz(1, 0, 0);
let KU: Vector = Vector.xyz(0, 1, 0);
function kinematics(e: Enemy, ctx: Ctx, dt: f64): void {
    let sAbs = e.rel ? ctx.railS + e.s : e.s;
    let pos = ctx.railFrame(sAbs);
    let f = ctx.rfFwd, rt = ctx.rfRight, up = ctx.rfUp;
    let a = e.ai;
    let flyer = a == "path" || a == "hover" || a == "kamikaze" || a == "racer";
    if (flyer) {
        // inside a canyon a flyer slides along the wall instead of into it
        let side = e.rx >= 0 ? 1.0 : -1.0;
        let room = wallRoom(sAbs, side, e.ry);
        if (Math.abs(e.rx) > room) {
            e.rx = side * lmax(room, 0);
        }
    }
    e.lift = flyer ? hop(sAbs, e.rx, e.ry) : 0;
    let ry = e.ry + e.lift;
    if (flyer && sAbs > BRIDGES[1][1] - BRIDGE_REACH && sAbs < BRIDGES[BRIDGES.length - 1][1] + BRIDGE_REACH) {
        let capped = underSpan(sAbs, ry);
        e.lift += capped - ry;
        ry = capped;
    }
    if (flyer && !e.practice) {
        lensGuard(e, pos, f, rt, ry);
    }
    e.x = <f64>pos.x + <f64>rt.x * e.rx;
    e.y = <f64>pos.y + ry;
    e.z = <f64>pos.z + <f64>rt.z * e.rx;
    if (e.t <= dt * 1.5 || dt <= 0) {
        e.ps = e.s;
        e.px = e.rx;
        e.py = ry;
        e.lx = e.x;
        e.ly = e.y;
        e.lz = e.z;
    }
    let ivd = 1 / lmax(dt, 1e-4);
    let nvs = (e.s - e.ps) * ivd, nvx = (e.rx - e.px) * ivd, nvy = (ry - e.py) * ivd;
    let k = 1 - Math.exp(-12 * dt);
    let ovs = e.vs, ovx = e.vx, ovy = e.vy;
    e.vs += (nvs - e.vs) * k;
    e.vx += (nvx - e.vx) * k;
    e.vy += (nvy - e.vy) * k;
    let ka = 1 - Math.exp(-6 * dt);
    e.as += ((e.vs - ovs) * ivd - e.as) * ka;
    e.ax += ((e.vx - ovx) * ivd - e.ax) * ka;
    e.ay += ((e.vy - ovy) * ivd - e.ay) * ka;
    e.ps = e.s;
    e.px = e.rx;
    e.py = ry;
    // world velocity (for wrecks)
    let kw = 1 - Math.exp(-10 * dt);
    e.wvx += ((e.x - e.lx) * ivd - e.wvx) * kw;
    e.wvy += ((e.y - e.ly) * ivd - e.wvy) * kw;
    e.wvz += ((e.z - e.lz) * ivd - e.wvz) * kw;
    e.lx = e.x;
    e.ly = e.y;
    e.lz = e.z;
    KF = f;
    KR = rt;
    KU = up;
}

// Smoothly turn the pose toward heading h and up hint u.
function orient(e: Enemy, dt: f64, hx: f64, hy: f64, hz: f64, ux: f64, uy: f64, uz: f64, rate: f64, roll: f64): void {
    let l = Math.sqrt(hx * hx + hy * hy + hz * hz);
    if (l > 1e-5) {
        hx = hx / l;
        hy = hy / l;
        hz = hz / l;
        let k = 1 - Math.exp(-rate * dt);
        e.hx += (hx - e.hx) * k;
        e.hy += (hy - e.hy) * k;
        e.hz += (hz - e.hz) * k;
    }
    let lu = Math.sqrt(ux * ux + uy * uy + uz * uz);
    if (lu > 1e-5) {
        let k = 1 - Math.exp(-rate * 0.8 * dt);
        e.upx += (ux / lu - e.upx) * k;
        e.upy += (uy / lu - e.upy) * k;
        e.upz += (uz / lu - e.upz) * k;
    }
    models.aim(e.xf, e.x, e.y, e.z, e.hx, e.hy, e.hz, e.upx, e.upy, e.upz, roll, e.scale);
}

// Plane pose: heading = relative velocity + forward bias, up = lift (gravity + turn accel).
function planePose(e: Enemy, dt: f64, f: Vector, rt: Vector, up: Vector, bias: f64, roll: f64): void {
    let hs = e.vs + bias, hx = e.vx, hy = e.vy;
    let fx0 = <f64>f.x, fy0 = <f64>f.y, fz0 = <f64>f.z;
    let rx = <f64>rt.x, ry = <f64>rt.y, rz = <f64>rt.z;
    let ux = <f64>up.x, uy = <f64>up.y, uz = <f64>up.z;
    let wx = fx0 * hs + rx * hx + ux * hy;
    let wy = fy0 * hs + ry * hx + uy * hy;
    let wz = fz0 * hs + rz * hx + uz * hy;
    let g = 11.0;
    let ax = (fx0 * e.as + rx * e.ax + ux * e.ay) * 0.9;
    let ay = (fy0 * e.as + ry * e.ax + uy * e.ay) * 0.9 + g;
    let az = (fz0 * e.as + rz * e.ax + uz * e.ay) * 0.9;
    orient(e, dt, wx, wy, wz, ax, ay, az, 7, roll);
}

// Enemy fire helpers ------------------------------------------------------------------

// facingPlayer -> FACE_DOT, FACE_D
let FACE_DOT: f64 = 0;
let FACE_D: f64 = 0;
function facingPlayer(e: Enemy, ctx: Ctx): f64 {
    let p = ctx.player.pos;
    let dx = <f64>p.x - e.x, dy = <f64>p.y - e.y, dz = <f64>p.z - e.z;
    let d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 0.01);
    FACE_DOT = (dx * e.xf.fx + dy * e.xf.fy + dz * e.xf.fz) / d;
    FACE_D = d;
    return FACE_DOT;
}

// Charge-up before a shot: 0 until TELE_LEAD seconds before the gun is ready, then ramps to 1.
const TELE_LEAD: f64 = 0.45;
function telegraph(fireT: f64): f64 {
    return mathx.saturate(1 - fireT / TELE_LEAD);
}

// Behaviors -----------------------------------------------------------------------------

function updatePath(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let path = e.path;
    if (path == null) {
        return;
    }
    let s = sample(path, e.t), x = SAMPLE_2, y = SAMPLE_3;
    e.s = s + e.p1;
    e.rx = e.side * x * e.sx + e.p2;
    e.ry = lmax(y + e.p3, e.duck ? -8.0 : 2.5);
    kinematics(e, ctx, dt);
    let f = KF, rt = KR, up = KU;
    if (e.duck && e.y < 0.3) {
        // ducked under (retire): gone with a splash, no kill
        fx.splash(W.fx, e.x, e.z, 0.9, true);
        e.dead = true;
        return;
    }
    let bias = 16.0;
    // barrel roll flourish on the U-turn for biplanes
    planePose(e, dt, f, rt, up, bias, e.roll);
    // fire when lined up
    e.fireT -= dt;
    let dot = facingPlayer(e, ctx), d = FACE_D;
    let ahead = ai.ahead(ctx, e.x, e.y, e.z);
    let lined = e.t > 0.6 && ahead > 22 && d < 170 && dot > 0.72;
    e.tele = lined ? telegraph(e.fireT) : 0;
    if (lined) {
        if (e.fireT <= 0) {
            e.shots += 1;
            if (e.kind == "biplane") {
                e.burst = 4;
                e.fireT = e.p4;
            } else {
                // every other volley is a leading fan of three
                models.point(e.xf, 0, 0, -1.8);
                let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
                if (mod(e.shots, 2) == 0) {
                    ai.orbFan(W, ctx, ox, oy, oz, 38, 3, 3.2, 1, 0.3, 0.35);
                } else {
                    ai.orb(W, ctx, ox, oy, oz, 38, 3, 1, 0.3, 0.35);
                }
                ctx.sfx("enemy_fire", 0.4);
                e.fireT = e.p4;
            }
        }
    }
    if (e.burst > 0 && e.fireT < e.p4 - 0.1 * (5 - e.burst)) {
        e.burst -= 1;
        let side = mod(e.burst, 2) == 0 ? 1.0 : -1.0;
        models.point(e.xf, side * 0.5, 0.75, -2.6);
        let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
        // the burst opens with a leading pair (dead on, then a bracket on
        // the gun's side); the rest spray
        if (e.burst == 3) {
            ai.tracer(W, ctx, ox, oy, oz, 95, 0, 0);
            ctx.sfx("enemy_fire", 0.35);
        } else if (e.burst == 2) {
            ai.tracer(W, ctx, ox, oy, oz, 95, 0, side * 2.2);
        } else {
            ai.tracer(W, ctx, ox, oy, oz, 95, 2.4);
        }
    }
    // wingtip vapor while overtaking fast or pulling hard
    let pull = Math.abs(e.ax) + Math.abs(e.ay);
    if ((e.vs > 20 || pull > 26) && e.t > 0.05) {
        if (e.trail == 0) {
            e.trail = ai.trailGet(W, 0, 0.55, 0.28 * e.scale, 1, 1, 1, 0.8, 1.2);
            e.trail2 = ai.trailGet(W, 0, 0.55, 0.28 * e.scale, 1, 1, 1, 0.8, 1.2);
        }
    } else if (e.trail > 0 && e.vs < 12 && pull < 18) {
        ai.trailRelease(W, e.trail);
        ai.trailRelease(W, e.trail2);
        e.trail = 0;
        e.trail2 = 0;
    }
    if (e.trail > 0) {
        let span = e.kind == "biplane" ? 4.3 : 3.3;
        let ty = e.kind == "biplane" ? 1.38 : 0.38;
        models.point(e.xf, -span, ty, -1.4);
        ai.trailPush(W, e.trail, models.POINT_X, models.POINT_Y, models.POINT_Z);
        models.point(e.xf, span, ty, -1.4);
        ai.trailPush(W, e.trail2, models.POINT_X, models.POINT_Y, models.POINT_Z);
    }
    // whoosh as the squadron overtakes the camera
    if (!e.passed && e.rel && e.s > -12 && e.vs > 15) {
        e.passed = true;
        let g = e.group;
        if (g == null || g.flyby != ctx.t) {
            ctx.sfx("flyby", 0.9);
            if (g != null) {
                g.flyby = ctx.t;
            }
        }
    }
    // behind the camera, or out wide past the edge of the view (a sweep's
    // far end would run on into whatever coast lies out there)
    if (e.rel && (e.s < -45 || (e.t > 1 && Math.abs(e.rx) > 100))) {
        e.dead = true;
    }
}

// Clears the stage for a boss entrance (she comes down out of the sky
// ahead): a drone still out ahead ducks, diving for the sea just ahead of
// it and slipping under with a splash (~0.8 s, down and away from her);
// anything else still on its run, or already over the pilot, pulls up and
// away back over the camera (2.4 s). No more shots; one not launched yet
// never shows.
export function retire(e: Enemy): void {
    if (e.ai != "path" || !e.alive || e.dying > 0 || !e.rel || e.practice || e.p4 >= 99) {
        return; // (p4 99: already on its way out)
    }
    if (e.t < 0) {
        e.dead = true;
        return;
    }
    let s0 = e.s, x0 = e.rx, y0 = e.ry;
    let out = x0 >= 0 ? 1.0 : -1.0;
    if (e.kind == "drone" && s0 > 16) {
        e.duck = true;
        e.path = [[0.0],
            [0.0, 0, s0, x0, y0],
            [0.0, 0.3, s0 - 5, x0 + out * 1.5, y0 * 0.6],
            [0.0, 0.75, s0 - 10, x0 + out * 3, -2],
            [0.0, 1.1, s0 - 13, x0 + out * 4, -8],
        ];
    } else {
        e.path = [[0.0],
            [0.0, 0, s0, x0, y0],
            [0.0, 0.7, s0 - 14, x0 + out * 3, y0 + 8],
            [0.0, 1.5, s0 * 0.4 - 20, x0 + out * 7, y0 + 22],
            [0.0, 2.4, -70, x0 + out * 10, y0 + 38],
        ];
    }
    e.t = 0;
    e.p1 = 0;
    e.p2 = 0;
    e.p3 = 0;
    e.side = 1;
    e.sx = 1;
    e.fireT = 99;
    e.p4 = 99;
    e.burst = 0;
    e.tele = 0;
}

// Hover drone: rises (optionally out of the sea), weaves ahead facing the player, fires orbs, leaves.
function updateHover(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let t = e.t;
    let ph = e.seed * 6.28;
    let tx = e.p2 + Math.sin(t * 1.25 + ph) * 7;
    let ty = e.p3 + Math.sin(t * 2.1 + ph * 1.7) * 2.2;
    let ts = e.p1 + Math.sin(t * 0.7 + ph) * 6;
    if (t > e.p4) {
        let u = t - e.p4;
        ts += u * u * 18;
        ty += u * u * 6;
        tx += e.side * u * u * 8;
    }
    let k = 1 - Math.exp(-2.2 * dt);
    e.s += (ts - e.s) * k;
    e.rx += (tx - e.rx) * k;
    e.ry += (ty - e.ry) * k;
    let wasUnder = e.y < 0.2;
    kinematics(e, ctx, dt);
    let rt = KR;
    if (wasUnder && e.y >= 0.2 && e.t > 0.05) {
        fx.splash(W.fx, e.x, e.z, 1.1, true);
        ctx.sfx("explode_small", 0.25);
    }
    // face the player, bank with lateral motion
    let p = ctx.player.pos;
    let hx = <f64>p.x - e.x, hy = (<f64>p.y - e.y) * 0.5, hz = <f64>p.z - e.z;
    let bankUpX = <f64>rt.x * -e.vx * 0.9;
    let bankUpZ = <f64>rt.z * -e.vx * 0.9;
    orient(e, dt, hx, hy, hz, bankUpX, 12, bankUpZ, 5, 0);
    e.fireT -= dt;
    let ahead = ai.ahead(ctx, e.x, e.y, e.z);
    let armed = e.t > 1.2 && e.t < e.p4 && ahead > 20;
    e.tele = armed ? telegraph(e.fireT) : 0;
    if (e.fireT <= 0 && armed) {
        e.fireT = 1.6 + lrandom() * 1.2;
        e.shots += 1;
        models.point(e.xf, 0, 0, -1.7);
        let ox = models.POINT_X, oy = models.POINT_Y, oz = models.POINT_Z;
        // every third volley leads him with a fan
        if (mod(e.shots, 3) == 2) {
            ai.orbFan(W, ctx, ox, oy, oz, 36, 3, 3.2, 1, 0.28, 0.32);
        } else {
            ai.orb(W, ctx, ox, oy, oz, 36, 2.5, 1, 0.28, 0.32);
        }
        ctx.sfx("enemy_fire", 0.35);
    }
    if (e.s > 400 || (e.rel && e.s < -45)) {
        e.dead = true;
    }
}

// Kamikaze: climbs ahead, blinks, then dives at the player in world space.
function updateKamikaze(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    if (!e.world) {
        // approach phase on the rail
        let k = 1 - Math.exp(-2 * dt);
        e.s += (e.p1 - e.s) * k;
        e.ry += (e.p3 - e.ry) * k;
        kinematics(e, ctx, dt);
        let p = ctx.player.pos;
        orient(e, dt, <f64>p.x - e.x, <f64>p.y - e.y, <f64>p.z - e.z, 0, 1, 0, 4, Math.sin(e.t * 9) * 0.2);
        if (e.t > e.p4) {
            e.world = true;
            e.p2 = 0; // seconds since launch
            let dx = ai.aimAtPlayer(W, ctx, e.x, e.y, e.z, 60, 0), dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
            e.wvx = dx * 30;
            e.wvy = dy * 30;
            e.wvz = dz * 30;
            ctx.sfx("lock", 0.5);
        }
        return;
    }
    // homing dive: committed once close, self-destructs if it never connects
    e.p2 += dt;
    let sp = lmin(90, Math.sqrt(e.wvx * e.wvx + e.wvy * e.wvy + e.wvz * e.wvz) + 70 * dt);
    let dx = ai.aimAtPlayer(W, ctx, e.x, e.y, e.z, sp, 0), dy = ai.AIM_AT_PLAYER_2, dz = ai.AIM_AT_PLAYER_3;
    let ahead = ai.ahead(ctx, e.x, e.y, e.z);
    let turn = ahead > 25 && e.p2 < 2.2 ? 2.6 : 0.0;
    if (e.p2 > 3.2) {
        e.alive = false;
        e.dead = true;
        fx.explosion(W.fx, e.x, e.y, e.z, 0.8, "pop");
        return;
    }
    let cx = e.wvx / sp, cy = e.wvy / sp, cz = e.wvz / sp;
    let k = 1 - Math.exp(-turn * dt);
    cx += (dx - cx) * k;
    cy += (dy - cy) * k;
    cz += (dz - cz) * k;
    let l = lmax(Math.sqrt(cx * cx + cy * cy + cz * cz), 1e-4);
    e.wvx = cx / l * sp;
    e.wvy = cy / l * sp;
    e.wvz = cz / l * sp;
    if (ahead < 1.5) {
        // missed him: it pulls up and out, away from the camera behind him,
        // instead of flying on through the lens
        let fw = ctx.player.fwd;
        let fx0 = <f64>fw.x, fy0 = <f64>fw.y, fz0 = <f64>fw.z;
        let ox = e.x - lensX, oy = e.y - lensY, oz = e.z - lensZ;
        let al = ox * fx0 + oy * fy0 + oz * fz0;
        ox = ox - fx0 * al;
        oy = oy - fy0 * al;
        oz = oz - fz0 * al;
        let ol = Math.sqrt(ox * ox + oy * oy + oz * oz);
        if (ol < 0.05) {
            ox = 0;
            oy = 1;
            oz = 0;
            ol = 1;
        }
        let acc = 110 * dt;
        e.wvx += ox / ol * acc;
        e.wvy += (oy / ol + 0.5) * acc;
        e.wvz += oz / ol * acc;
    }
    e.x += e.wvx * dt;
    e.y += e.wvy * dt;
    e.z += e.wvz * dt;
    e.spin += dt * 14;
    orient(e, dt, e.wvx, e.wvy, e.wvz, 0, 1, 0, 10, e.spin);
    if (e.trail == 0) {
        e.trail = ai.trailGet(W, 1, 0.22, 1.1 * e.scale, 1, 0.45, 0.12, 1, 1.0);
        e.trail2 = ai.trailGet(W, 2, 0.8, 0.9 * e.scale, 0.36, 0.42, 0.8, 1, 1.6);
    }
    models.point(e.xf, 0, 0, 1.9);
    let bx = models.POINT_X, by = models.POINT_Y, bz = models.POINT_Z;
    ai.trailPush(W, e.trail, bx, by, bz);
    ai.trailPush(W, e.trail2, bx, by, bz);
    if (e.y < 0.3) {
        // missed into the sea
        e.alive = false;
        e.dead = true;
        fx.explosion(W.fx, e.x, 0.5, e.z, 1, "water");
        fx.explosion(W.fx, e.x, 1, e.z, 0.8, "pop");
    }
    if (ahead < -30) {
        e.dead = true;
    }
}

// racer entry: lateral room (m) off the pilot while it comes up from
// behind, held until it is RACER_WIDE_S0 m ahead of him, gone by S1
const RACER_WIDE: f64 = 26;
const RACER_WIDE_Y: f64 = 1.5; // m over the pilot's height while it is out wide
const RACER_WIDE_S0: f64 = 10, RACER_WIDE_S1: f64 = 42;

// the side a racer comes up on (its station's side; the middle one by its seed)
function racerOut(e: Enemy): f64 {
    return e.p2 > 0.5 ? 1.0 : e.p2 < -0.5 ? -1.0 : e.seed > 0.5 ? 1.0 : -1.0;
}

// Where an overtaking racer starts (enemies.troopers): out wide of the
// pilot, at his height (the middle of the view's side edge, between the
// HUD's corner panels).
export function racerStart(e: Enemy, ctx: Ctx): void {
    e.rx = ctx.player.x + racerOut(e) * RACER_WIDE;
    e.ry = lmax(2.5, ctx.player.y + RACER_WIDE_Y);
}

// Jet trooper: overtakes from behind, races ahead weaving, dodges when targeted, fires backward.
function updateRacer(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let t = e.t;
    let ph = e.seed * 6.28;
    let entry = mathx.easeOutCubic(t / 2.2);
    let ts = mathx.lerp(-26, e.p1, entry) + Math.sin(t * 0.6 + ph) * 5;
    let tx = e.p2 + Math.sin(t * 0.95 + ph) * 8 + e.p4;
    let ty = e.p3 + Math.sin(t * 1.4 + ph * 1.3) * 2.8;
    // the overtake comes up out wide of the pilot at his height, past the
    // edge of the view, and slides in to its station once it is well ahead;
    // a warp-in starts ahead and is untouched
    let wideK = 1 - mathx.smoothstep(RACER_WIDE_S0, RACER_WIDE_S1, e.s);
    if (wideK > 0) {
        tx = mathx.lerp(tx, ctx.player.x + racerOut(e) * RACER_WIDE, wideK);
        ty = mathx.lerp(ty, ctx.player.y + RACER_WIDE_Y, wideK);
    }
    if (t > 11) {
        let u = t - 11;
        ts += u * u * 16;
        ty += u * u * 4;
    }
    // dodge when the player lines up while firing
    e.dodgeT -= dt;
    let pl = ctx.player;
    if (W.playerFiring && e.dodgeT <= 0 && t > 1.5 && Math.abs(pl.x - e.rx) < 5.5 && Math.abs(pl.y - e.ry) < 6) {
        e.dodgeT = 2.2 + lrandom();
        let dir = e.rx > pl.x ? 1.0 : -1.0;
        if (Math.abs(e.p2 + dir * 10) > 22) {
            dir = -dir;
        }
        e.p4 += dir * 10;
        e.rollT = 0.5;
        e.side = dir;
    }
    // the dodge offset relaxes back over time
    e.p4 *= Math.exp(-0.25 * dt);
    let k = 1 - Math.exp(-3 * dt);
    e.s += (ts - e.s) * k;
    e.rx += (tx - e.rx) * (1 - Math.exp(-5 * dt));
    e.ry += (ty - e.ry) * k;
    e.ry = lmax(e.ry, 2.2);
    kinematics(e, ctx, dt);
    let f = KF, rt = KR, up = KU;
    let roll = 0.0;
    if (e.rollT > 0) {
        e.rollT = lmax(0, e.rollT - dt);
        roll = -e.side * mathx.easeInOutCubic(1 - e.rollT / 0.5) * mathx.TAU;
    }
    let hs = 24 + e.vs;
    let hx = <f64>f.x * hs + <f64>rt.x * e.vx, hy = <f64>f.y * hs + <f64>up.y * e.vy * 0.5, hz = <f64>f.z * hs + <f64>rt.z * e.vx;
    orient(e, dt, hx, hy, hz, <f64>rt.x * -e.ax * 0.5, 14, <f64>rt.z * -e.ax * 0.5, 6, roll);
    // twin pink jet flames
    if (e.trail == 0) {
        e.trail = ai.trailGet(W, 1, 0.16, 0.34 * e.scale, 1, 0.3, 0.75, 1, 0.8);
        e.trail2 = ai.trailGet(W, 1, 0.16, 0.34 * e.scale, 1, 0.3, 0.75, 1, 0.8);
    }
    models.point(e.xf, -0.15, 0.0, 0.56);
    ai.trailPush(W, e.trail, models.POINT_X, models.POINT_Y, models.POINT_Z);
    models.point(e.xf, 0.15, 0.0, 0.56);
    ai.trailPush(W, e.trail2, models.POINT_X, models.POINT_Y, models.POINT_Z);
    // fire back at the player
    e.fireT -= dt;
    e.tele = t > 2.4 && t < 11 ? telegraph(e.fireT) : 0;
    if (e.fireT <= 0 && t > 2.4 && t < 11) {
        e.fireT = 1.7 + lrandom() * 1.1;
        models.point(e.xf, 0, 0.1, -0.6);
        ai.orb(W, ctx, models.POINT_X, models.POINT_Y, models.POINT_Z, 26, 3.5, 1, 0.35, 0.8);
        ctx.sfx("enemy_fire", 0.35);
    }
    if (e.s > 420) {
        e.dead = true;
    }
}

// Sea mine: bobs, blinks, detonates by proximity.
function updateMine(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    e.ry = e.p3 + Math.sin(e.t * 1.7 + e.seed * 6) * (e.p3 < 2 ? 0.18 : 0.6);
    kinematics(e, ctx, dt);
    e.spin += dt * 0.35;
    models.aim(e.xf, e.x, e.y, e.z, Math.sin(e.spin), 0, -Math.cos(e.spin), 0, 1, 0, Math.sin(e.t * 1.3) * 0.12, e.scale);
    // chain reaction fuse (set by a neighbor's blast)
    if (e.p4 > 0) {
        e.p4 -= dt;
        e.flash = 1;
        if (e.p4 <= 0) {
            e.hp = 0;
        }
    }
    let d = ai.distToPlayer(ctx, e.x, e.y, e.z);
    let ph = mod(e.t * 1.6 + e.seed, 1);
    if (d < 70 && ph < e.burst) {
        ctx.sfx("beep", 0.25 * (1 - d / 70));
    }
    e.burst = ph;
    if (d < 3.6) {
        ctx.hurtPlayer(0.2, e.x, e.y, e.z);
        e.hp = 0;
    }
    if (e.rel == false && e.s < ctx.railS - 60) {
        e.dead = true;
    }
}

// Cliff turret: tracks the player, fires tracer bursts.
const TURRET_DMG: f64 = 0.1;
function updateTurret(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    if (e.t <= dt * 1.5) {
        kinematics(e, ctx, dt);
        ctx.railFrame(e.s);
        let f = ctx.rfFwd;
        e.yaw = Math.atan2(-<f64>f.x, -<f64>f.z) + Math.PI;
    }
    let p = ctx.player.pos;
    let dx = <f64>p.x - e.x, dy = <f64>p.y - (e.y + 1.2 * e.scale), dz = <f64>p.z - e.z;
    let hd = Math.sqrt(dx * dx + dz * dz);
    let tyaw = Math.atan2(-dx, -dz);
    let tpitch = Math.atan2(dy, hd);
    e.yaw = mathx.dampAngle(e.yaw, tyaw, 3.5, dt);
    e.pitch = mathx.damp(e.pitch, mathx.clamp(tpitch, -0.3, 1.1), 3.5, dt);
    let ahead = ai.ahead(ctx, e.x, e.y, e.z);
    e.fireT -= dt;
    e.tele = ahead > 30 && ahead < 240 && e.burst <= 0 ? telegraph(e.fireT) : 0;
    if (ahead > 30 && ahead < 240 && e.fireT <= 0) {
        e.fireT = e.p4;
        e.burst = 3;
        e.shots += 1;
    }
    if (e.burst > 0 && e.fireT < e.p4 - 0.1 * (4 - e.burst)) {
        e.burst -= 1;
        let side = mod(e.burst, 2) == 0 ? 1.0 : -1.0;
        // muzzle in world: dome at y + 1.05*scale, barrels 2.7 forward
        let cy = Math.cos(e.yaw), sy = Math.sin(e.yaw);
        let cp = Math.cos(e.pitch), sp = Math.sin(e.pitch);
        let fx0 = -sy * cp, fy0 = sp, fz0 = -cy * cp;
        let rx0 = cy, rz0 = -sy;
        let s = e.scale;
        let ox = e.x + (fx0 * 2.7 + rx0 * side * 0.34) * s;
        let oy = e.y + (1.05 + fy0 * 2.7) * s;
        let oz = e.z + (fz0 * 2.7 + rz0 * side * 0.34) * s;
        // heavier rounds than the planes'; every other burst opens with a
        // leading shot (hold a straight line in the canyon and it lands)
        if (e.burst == 2 && mod(e.shots, 2) == 1) {
            ai.tracer(W, ctx, ox, oy, oz, 110, 0, 0, TURRET_DMG);
        } else {
            ai.tracer(W, ctx, ox, oy, oz, 110, 3, NaN, TURRET_DMG);
        }
        ctx.sfx("enemy_fire", 0.4);
    }
    if (e.s < ctx.railS - 60) {
        e.dead = true;
    }
}

// Showroom pose (debug): holds a rail-relative spot and turns slowly (p1 = yaw rate).
function updatePose(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    kinematics(e, ctx, dt);
    let f = KF, rt = KR, up = KU;
    let a = e.t * e.p1 + e.p2;
    let c = Math.cos(a), s = Math.sin(a);
    let hx = -<f64>f.x * c + <f64>rt.x * s, hy = 0.0, hz = -<f64>f.z * c + <f64>rt.z * s;
    models.aim(e.xf, e.x, e.y, e.z, hx, hy, hz, <f64>up.x, <f64>up.y, <f64>up.z, 0, e.scale);
    e.hx = hx;
    e.hy = hy;
    e.hz = hz;
}

// Flight school target (enemies.practice): holds its rail-relative spot
// (p1 ahead, p2 across, p3 up; bobs by e.bob), rising out of the sea first
// while p4 > 0; faces the pilot. A lobber (lobEvery > 0) glows for
// the 0.45 s telegraph, then spits a slow intercept orb (lead 0) marked
// practice, homing back on it once deflected.
const PRACTICE_ORB: Array<f64> = [0.0, 1, 0.5, 0.3];
function updatePractice(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let ty = e.p3 + Math.sin(e.t * 1.9 + e.seed * 6.28) * e.bob;
    if (e.p4 > 0) {
        // rising (p4 = 1 until it arrives)
        e.ry += (ty - e.ry) * (1 - Math.exp(-2.6 * dt));
        if (Math.abs(ty - e.ry) < 0.3) {
            e.p4 = 0;
        }
    } else {
        e.ry = ty;
    }
    e.s = e.p1;
    e.rx = e.p2;
    let wasUnder = e.y < 0.2;
    kinematics(e, ctx, dt);
    let rt = KR;
    if (wasUnder && e.y >= 0.2 && e.t > 0.05) {
        fx.splash(W.fx, e.x, e.z, 1.1);
        ctx.sfx("explode_small", 0.25);
    }
    let p = ctx.player.pos;
    orient(e, dt, <f64>p.x - e.x, (<f64>p.y - e.y) * 0.5, <f64>p.z - e.z, <f64>rt.x * -e.vx * 0.9, 12, <f64>rt.z * -e.vx * 0.9, 5, 0);
    if (e.lobEvery <= 0) {
        e.tele = 0;
        return;
    }
    e.fireT -= dt;
    let armed = e.y > 1 && ai.ahead(ctx, e.x, e.y, e.z) > 20;
    e.tele = armed ? telegraph(e.fireT) : 0;
    if (armed && e.fireT <= 0) {
        e.fireT = e.lobEvery;
        e.shots += 1;
        models.point(e.xf, 0, 0, -1.7);
        let c = PRACTICE_ORB;
        let b = ai.orb(W, ctx, models.POINT_X, models.POINT_Y, models.POINT_Z, e.lobSpeed, 0, c[1], c[2], c[3], 0);
        if (b != null) {
            b.practice = true;
            b.src = e;
        }
        ctx.sfx("enemy_fire", 0.35);
    }
}

export function update(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let F = W.fx;
    lensX = F.camX;
    lensY = F.camY;
    lensZ = F.camZ;
    let a = e.ai;
    if (a == "practice") {
        updatePractice(e, W, ctx, dt);
    } else if (a == "pose") {
        updatePose(e, W, ctx, dt);
    } else if (a == "path") {
        updatePath(e, W, ctx, dt);
    } else if (a == "hover") {
        updateHover(e, W, ctx, dt);
    } else if (a == "kamikaze") {
        updateKamikaze(e, W, ctx, dt);
    } else if (a == "racer") {
        updateRacer(e, W, ctx, dt);
    } else if (a == "mine") {
        updateMine(e, W, ctx, dt);
    } else if (a == "turret") {
        updateTurret(e, W, ctx, dt);
    }
}

// Wrecks ---------------------------------------------------------------------------------

// Kills landing together (a squadron downed in one burst, a mine chain)
// go up as a ripple, not a wall: each kill within RIPPLE_GAP s of the last
// waits RIPPLE_STEP s more (up to RIPPLE_MAX steps) and goes up a little
// smaller (RIPPLE_SHRINK a step, to RIPPLE_MIN).
const RIPPLE_GAP: f64 = 0.1, RIPPLE_STEP: f64 = 0.07, RIPPLE_MAX: f64 = 4;
const RIPPLE_SHRINK: f64 = 0.15, RIPPLE_MIN: f64 = 0.5;
let rippleT: f64 = -HUGE, rippleN: f64 = 0;

// ripple -> RIPPLE_WAIT, RIPPLE_SC
let RIPPLE_WAIT: f64 = 0;
let RIPPLE_SC: f64 = 1;
function ripple(W: World): f64 {
    let gap = W.time - rippleT;
    rippleN = gap >= 0 && gap < RIPPLE_GAP ? lmin(rippleN + 1, RIPPLE_MAX) : 0;
    rippleT = W.time;
    RIPPLE_WAIT = rippleN * RIPPLE_STEP;
    RIPPLE_SC = lmax(RIPPLE_MIN, 1 - rippleN * RIPPLE_SHRINK);
    return RIPPLE_WAIT;
}

// A wreck closes on the pilot at most WRECK_CLOSE m/s along the rail: the
// hit knocks it on ahead, and its fireball rides with it (fx.carry) instead
// of standing in the air for the pilot to fly into. A mine's fireball rides
// on ahead the same way (its splash stays on the water).
const WRECK_CLOSE: f64 = 18;
// seconds a wreck falls before it blows up in the air (if it has not hit the sea)
const WRECK_LIFE: f64 = 3;

// Called when a regular enemy is destroyed: fx now, then a falling wreck.
export function kill(e: Enemy, W: World, ctx: Ctx): void {
    let F = W.fx;
    let k = e.kind;
    let near = ai.distToPlayer(ctx, e.x, e.y, e.z);
    if (near < 40) {
        ctx.shake(0.5 * (1 - near / 40));
    }
    let wait = ripple(W), sc = RIPPLE_SC;
    fx.delay(F, wait);
    let pl = ctx.player;
    let f = pl.fwd;
    let fx0 = <f64>f.x, fy0 = <f64>f.y, fz0 = <f64>f.z;
    if (k == "mine") {
        let add = lmax(0, pl.speed - WRECK_CLOSE);
        fx.carry(F, fx0 * add, 0, fz0 * add);
        fx.explosion(F, e.x, e.y, e.z, 1.15 * sc, "mine");
        fx.carry(F, 0, 0, 0);
        fx.delay(F, 0);
        ctx.sfx("explode_small", 0.8);
        e.dead = true;
        // chain reaction
        let list = W.list;
        for (let i = 1; i < list.length; i++) {
            let o = list[i];
            if (o != e && o.alive && o.kind == "mine" && o.p4 <= 0) {
                let dx = o.x - e.x, dy = o.y - e.y, dz = o.z - e.z;
                if (dx * dx + dy * dy + dz * dz < 16 * 16) {
                    o.p4 = 0.14 + lrandom() * 0.1;
                }
            }
        }
        return;
    }
    if (k == "turret") {
        fx.explosion(F, e.x, e.y + 1.2 * e.scale, e.z, 1.5 * sc, "big");
        let rvx = (lrandom() - 0.5) * 8;
        let rvz = (lrandom() - 0.5) * 8;
        fx.debris(F, e.x, e.y + 1.5, e.z, rvx, 16, rvz, 1.8, 0.3, 0.33, 0.4, true);
        fx.delay(F, 0);
        ctx.sfx("explode_big", 0.8);
        e.dying = 60;
        e.char = 1;
        return;
    }
    let close = pl.speed - (e.wvx * fx0 + e.wvy * fy0 + e.wvz * fz0);
    if (close > WRECK_CLOSE) {
        let add = close - WRECK_CLOSE;
        e.wvx += fx0 * add;
        e.wvz += fz0 * add;
    }
    e.wvy = lmax(e.wvy, 0) + 2;
    fx.carry(F, e.wvx, e.wvy, e.wvz);
    fx.explosion(F, e.x, e.y, e.z, (k == "trooper" ? 0.8 : 1.1) * sc, "small");
    fx.carry(F, 0, 0, 0);
    fx.delay(F, 0);
    ctx.sfx("explode_small", 0.8);
    // white silhouette for a beat, then the charred wreck
    e.flash = 1.4;
    // falling burning wreck
    ai.trailRelease(W, e.trail);
    ai.trailRelease(W, e.trail2);
    e.trail = 0;
    e.trail2 = 0;
    e.dying = WRECK_LIFE;
    e.world = true;
    e.char = 0.85;
    let sgn = lrandom() < 0.5 ? -1.0 : 1.0;
    e.spin = sgn * (4 + lrandom() * 4);
}

// Near field: a wreck coming at the lens drops out of the frame (down and
// out to its side of the sight line through the pilot) before it can cross
// him or the gauges: WRECK_STEER m/s^2 down and 0.6 of it outward, from
// WRECK_NEAR1 m ahead of the lens (full by WRECK_NEAR0), while it is still
// within WRECK_CONE0..1 of the sight line (rise over run; the bottom edge
// is ~0.45 under him).
const WRECK_NEAR0: f64 = 30, WRECK_NEAR1: f64 = 50;
const WRECK_STEER: f64 = 60;
const WRECK_CONE0: f64 = 0.5, WRECK_CONE1: f64 = 0.8;

function wreckSteer(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    let F = W.fx;
    let p = ctx.player.pos;
    let ax = <f64>p.x - F.camX, ay = <f64>p.y - F.camY, az = <f64>p.z - F.camZ;
    let al = Math.sqrt(ax * ax + ay * ay + az * az);
    if (al < 1) {
        return;
    }
    ax = ax / al;
    ay = ay / al;
    az = az / al;
    let vx = e.x - F.camX, vy = e.y - F.camY, vz = e.z - F.camZ;
    let along = vx * ax + vy * ay + vz * az;
    if (along <= 1 || along >= WRECK_NEAR1) {
        return;
    }
    let ox = vx - ax * along, oy = vy - ay * along, oz = vz - az * along;
    let od = Math.sqrt(ox * ox + oy * oy + oz * oz);
    let k = (1 - mathx.smoothstep(WRECK_CONE0, WRECK_CONE1, od / along)) * (1 - mathx.smoothstep(WRECK_NEAR0, WRECK_NEAR1, along));
    if (k <= 0) {
        return;
    }
    // its side of the sight line (dead on it: its own side)
    let rl = lmax(Math.sqrt(ax * ax + az * az), 1e-3);
    let rx = -az / rl, rz = ax / rl;
    let lat = ox * rx + oz * rz;
    let side = Math.abs(lat) > 0.5 ? (lat > 0 ? 1.0 : -1.0) : (e.seed < 0.5 ? -1.0 : 1.0);
    let a = WRECK_STEER * k * dt;
    e.wvx += rx * side * 0.6 * a;
    e.wvy -= a;
    e.wvz += rz * side * 0.6 * a;
}

// The gauge band (BOOST, SKIM, HEAT, NOVA / LOCK) from screen y WRECK_BAND
// (portrait WRECK_BAND_P) down: a wreck veils out from WRECK_BAND_RAMP above
// it (wreckVeil), gone WRECK_BAND_GAP above it, judged by its lowest point
// (a radius under it) now or WRECK_LEAD s on at its speed past the lens.
// Its flames stop, and its chain pop only sounds, once that point is due in
// the ramp within WRECK_FX_LEAD s (they ride on with it that long).
const WRECK_BAND: f64 = 0.72, WRECK_BAND_P: f64 = 0.58;
const WRECK_BAND_GAP: f64 = 0.01, WRECK_BAND_RAMP: f64 = 0.08;
const WRECK_LEAD: f64 = 0.067, WRECK_FX_LEAD: f64 = 0.4;

// lowest screen y (0 top .. 1 bottom) of a sphere at (x, y, z), radius rad;
// -1 behind the lens
function lowEdge(W: World, ctx: Ctx, x: f64, y: f64, z: f64, rad: f64): f64 {
    ai.screen(W, ctx, x, y, z);
    let v = ai.SCREEN_2, d = ai.SCREEN_3;
    ai.screen(W, ctx, x, y - rad, z);
    let v2 = ai.SCREEN_2, d2 = ai.SCREEN_3;
    if (d <= 0.5 || d2 <= 0.5) {
        return -1;
    }
    return lmax(v, v2);
}

// how far into the band's ramp a wreck is (0..1), now or `lead` s on
function inBand(e: Enemy, W: World, ctx: Ctx, lead: f64): f64 {
    let band = W.cam.aspect < 1 ? WRECK_BAND_P : WRECK_BAND;
    let lx = (e.wvx - W.playerVx) * lead, ly = (e.wvy - W.playerVy) * lead, lz = (e.wvz - W.playerVz) * lead;
    let low = lmax(lowEdge(W, ctx, e.x, e.y, e.z, e.radius), lowEdge(W, ctx, e.x + lx, e.y + ly, e.z + lz, e.radius));
    return mathx.smoothstep(band - WRECK_BAND_GAP - WRECK_BAND_RAMP, band - WRECK_BAND_GAP, low);
}

// Wreck physics (dead set when finished).
export function updateWreck(e: Enemy, W: World, ctx: Ctx, dt: f64): void {
    e.dying -= dt;
    if (e.kind == "turret") {
        // smoldering stump
        e.smokeT -= dt;
        if (e.smokeT <= 0 && e.dying > 50) {
            e.smokeT = 0.12;
            fx.smoke(W.fx, e.x, e.y + 0.8, e.z, 1.2, 0.8);
        }
        if (e.s < ctx.railS - 60) {
            e.dead = true;
        }
        return;
    }
    e.wvx *= Math.exp(-0.5 * dt);
    e.wvz *= Math.exp(-0.5 * dt);
    e.wvy -= 22 * dt;
    wreckSteer(e, W, ctx, dt);
    e.x += e.wvx * dt;
    e.y += e.wvy * dt;
    e.z += e.wvz * dt;
    e.roll += e.spin * dt;
    let l = lmax(Math.sqrt(e.wvx * e.wvx + e.wvy * e.wvy + e.wvz * e.wvz), 1e-3);
    orient(e, dt, e.wvx / l, e.wvy / l, e.wvz / l, 0, 1, 0, 3, e.roll);
    if (e.trail == 0) {
        ai.trailRelease(W, e.trail2);
        e.trail2 = 0;
        e.trail = ai.trailGet(W, 2, 0.9, 0.6 * e.scale, 0.42, 0.48, 0.84, 1, 1.4);
    }
    ai.trailPush(W, e.trail, e.x, e.y, e.z);
    // flames lick the wreck and it sheds sparks as it falls; the ribbon
    // trail carries the ink smoke (carried along with it: puffs left at rest
    // by a wreck the pilot is closing on stream back at the lens)
    e.smokeT -= dt;
    let F = W.fx;
    fx.carry(F, e.wvx, e.wvy, e.wvz);
    let band = inBand(e, W, ctx, WRECK_FX_LEAD) > 0;
    if (e.smokeT <= 0 && !band) {
        e.smokeT = 0.07;
        fx.fire(F, e.x, e.y, e.z, 0.9 * e.scale);
        if (lrandom() < 0.3) {
            fx.sparks(F, e.x, e.y, e.z, 3, 1, 0.78, 0.3);
        }
    }
    // SQUADRON DOWN: the squadron's wrecks go up one after another
    if (e.chain > 0) {
        e.chain -= dt;
        if (e.chain <= 0) {
            // (one on its way into the gauge band only sounds)
            if (!band) {
                fx.explosion(F, e.x, e.y, e.z, 0.9, "pop");
                fx.confetti(F, e.x, e.y, e.z, 1, 8);
            }
            fx.carry(F, 0, 0, 0);
            ctx.sfx("explode_small", 0.55);
            e.dead = true;
            return;
        }
    }
    fx.carry(F, 0, 0, 0);
    if (e.y < 0.2) {
        fx.explosion(W.fx, e.x, 0.3, e.z, 1.2, "water");
        fx.explosion(W.fx, e.x, 1, e.z, 0.7, "pop");
        fx.waterRing(W.fx, e.x, e.z, 1.1);
        ctx.sfx("explode_small", 0.4);
        e.dead = true;
    } else if (e.dying <= 0) {
        fx.explosion(W.fx, e.x, e.y, e.z, 0.9, "small");
        e.dead = true;
    }
}

// Drawing ------------------------------------------------------------------------------

// Wrecks veil toward the sky behind them (gpu sky fade):
// - one falling behind the pilot on screen (from 2 m in front of his depth
//   on) by up to WRECK_VEIL while it overlaps him (measured at his depth:
//   its hull, 0.7 of its radius, within 0.5 m of his sight line; gone by
//   2.5 m), so a downed squadron's broken planes never stand as dark
//   frames round him;
// - any wreck whose hull comes within WRECK_FADE1 m of the lens (gone by
//   WRECK_FADE0), once it has tumbled for WRECK_SHOW0..1 s (a close kill
//   still shows its charred wreck): it melts away as it drops out of the
//   frame instead of crossing the gauges.
const WRECK_VEIL: f64 = 0.55;
const WRECK_FADE0: f64 = 14, WRECK_FADE1: f64 = 40;
const WRECK_SHOW0: f64 = 0.3, WRECK_SHOW1: f64 = 0.6;
// - any wreck nearing the gauge band (see WRECK_BAND), once 0.1-0.2 s into
//   its fall (the lens rule above waits, and misses a wreck carried in
//   close and low).

function wreckVeil(e: Enemy, W: World): f64 {
    let F = W.fx;
    let vx = e.x - F.camX, vy = e.y - F.camY, vz = e.z - F.camZ;
    let gap = Math.sqrt(vx * vx + vy * vy + vz * vz) - e.radius;
    let age = WRECK_LIFE - e.dying;
    let near = (1 - mathx.smoothstep(WRECK_FADE0, WRECK_FADE1, gap)) * mathx.smoothstep(WRECK_SHOW0, WRECK_SHOW1, age);
    let ctx = W.ctx;
    if (ctx == null) {
        return near;
    }
    near = lmax(near, inBand(e, W, ctx, WRECK_LEAD) * mathx.smoothstep(0.1, 0.2, age));
    let p = ctx.player.pos;
    let ax = <f64>p.x - F.camX, ay = <f64>p.y - F.camY, az = <f64>p.z - F.camZ;
    let hd = Math.sqrt(ax * ax + ay * ay + az * az);
    if (hd < 1) {
        return near;
    }
    ax = ax / hd;
    ay = ay / hd;
    az = az / hd;
    let along = vx * ax + vy * ay + vz * az;
    if (along < hd - 2) {
        return near;
    }
    let ox = vx - ax * along, oy = vy - ay * along, oz = vz - az * along;
    let edge = (Math.sqrt(ox * ox + oy * oy + oz * oz) - 0.7 * e.radius) / along * hd;
    return lmax(near, WRECK_VEIL * (1 - mathx.smoothstep(0.5, 2.5, edge)));
}

// The instance just put into b fades toward the sky behind it (near 0..1).
function fadeLast(b: Batch, near: f64): void {
    if (near > 0.01 && b.n > 0) {
        gpu.setSkyFade(b, b.n, near);
    }
}

export function draw(e: Enemy, W: World, mo: Models, r: Gfx, t: f64): void {
    let k = e.kind;
    let x = e.xf;
    let tint = 1 - e.char * 0.72;
    let tr = tint, tg = tint * 0.95, tb = tint * 0.92;
    let flash = lmin(e.flash, 1);
    if (e.practice) {
        // flight school targets: cream / crimson print stock
        let pt = models.PRACTICE_TINT;
        tr = pt[1];
        tg = pt[2];
        tb = pt[3];
        flash = lmax(flash, pt[4]);
    }
    let dis = e.warp;
    // a live craft at the lens fades toward the sky behind it (gpu sky fade)
    let near = 0.0;
    if (e.dying <= 0 && !e.practice && k != "turret" && k != "mine") {
        let F = W.fx;
        let dx = e.x - F.camX, dy = e.y - F.camY, dz = e.z - F.camZ;
        let gap = Math.sqrt(dx * dx + dy * dy + dz * dz) - e.radius;
        if (gap < LENS_BEHIND1) {
            near = 1 - mathx.smoothstep(LENS_FADE0, LENS_FADE1, gap);
            let ctx = W.ctx;
            if (ctx != null) {
                let past = mathx.smoothstep(0, -3, ai.ahead(ctx, e.x, e.y, e.z));
                near = lmax(near, past * (1 - mathx.smoothstep(LENS_BEHIND0, LENS_BEHIND1, gap)));
            }
        }
        let ctx = W.ctx;
        if (ctx != null && k == "kamikaze") {
            near = lmax(near, passing(e, ctx));
        }
    }
    if (e.dying > 0 && k != "turret") {
        // a wreck falling past the lens melts away (toon.wgsl: any dissolve
        // also melts what nears the camera, gone by 5 m)
        let F = W.fx;
        let dx = e.x - F.camX, dy = e.y - F.camY, dz = e.z - F.camZ;
        if (dx * dx + dy * dy + dz * dz < 16 * 16) {
            dis = lmax(dis, 0.001);
        }
        near = wreckVeil(e, W);
        if (near >= 0.995) {
            // fully veiled: nothing (its depth prepass left ink specks)
            return;
        }
    }
    if (k == "biplane") {
        models.put(mo.biplane, x, tr, tg, tb, flash, 0, dis);
        fadeLast(mo.biplane, near);
        let c = W.xf2;
        let spin = e.dying > 0 ? t * 6 : t * 38 + e.seed * 10;
        models.child(c, x, 0, 0, -3.36, 0, 0, spin, 1);
        models.put(mo.prop, c, tr, tg, tb, flash, 0, dis);
        fadeLast(mo.prop, near);
        if (e.dying <= 0 && near < 0.5) {
            models.point(x, 0, 0, -3.42);
            ai.propDisc(W, r, models.POINT_X, models.POINT_Y, models.POINT_Z, x.fx, x.fy, x.fz, 1.5 * e.scale, 1, e.seed);
            if (e.tele > 0) {
                // twin guns heat up before a burst
                for (let side = -1.0; side <= 1; side += 2) {
                    models.point(x, side * 0.5, 0.75, -2.7);
                    R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, (0.25 + 0.55 * e.tele) * e.scale, 1, 0.1, 0.4, 0.5 + 0.5 * e.tele, 1, 0.5, e.seed + side, 0);
                }
            }
        }
    } else if (k == "drone" || k == "kamikaze") {
        let em = 0.0;
        if (k == "kamikaze" && e.world) {
            em = 0.35 + 0.35 * Math.sin(t * 30);
        }
        models.put(mo.drone, x, tr, tg, tb, flash, em, dis);
        fadeLast(mo.drone, near);
        if (e.dying <= 0 && near < 0.5) {
            models.point(x, 0, 0, -1.55);
            let px = models.POINT_X, py = models.POINT_Y, pz = models.POINT_Z;
            let pulse = 0.8 + 0.2 * Math.sin(t * 8 + e.seed * 6);
            // the eye swells and whitens before it spits an orb
            let tl = e.tele;
            if (e.practice) {
                // a cream bullseye eye on the practice targets
                R.particle(r, px, py, pz, 1.5 * e.scale * (pulse + tl * 0.7), 1, 0.9 + tl * 0.1, 0.72 + tl * 0.28, 0.85 + tl * 0.15, 1, 0.5, e.seed, 0);
            } else {
                R.particle(r, px, py, pz, 1.5 * e.scale * (pulse + tl * 0.7), 1, 0.25 + tl * 0.55, 0.15 + tl * 0.45, 0.85 + tl * 0.15, 1, 0.5, e.seed, 0);
            }
            models.point(x, 0, 0, 1.85);
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 0.9 * e.scale, 1, 0.6, 0.25, 0.8, 1, 0.5, e.seed, 0);
        }
    } else if (k == "trooper") {
        models.put(mo.trooper, x, tr, tg, tb, flash, 0, dis);
        fadeLast(mo.trooper, near);
        if (e.dying <= 0 && near < 0.5) {
            // hot pink nozzle glow (the ribbon trails carry the flame)
            let pulse = 0.85 + 0.15 * Math.sin(t * 40 + e.seed * 9);
            for (let side = -1.0; side <= 1; side += 2) {
                models.point(x, side * 0.15, 0.0, 0.58);
                R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 0.5 * e.scale * pulse, 1, 0.35, 0.8, 0.95, 1, 0.5, e.seed + side, 0);
            }
            if (e.tele > 0) {
                models.point(x, 0, 0.1, -0.6);
                R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, (0.2 + 0.35 * e.tele) * e.scale, 1, 0.6, 0.9, 0.5 + 0.5 * e.tele, 1, 0.5, e.seed, 0);
            }
        }
    } else if (k == "mine") {
        models.put(mo.mine, x, 1, 1, 1, flash, 0, dis);
        let blink = mod(t * 1.6 + e.seed, 1) < 0.22 || e.p4 > 0;
        if (blink) {
            models.point(x, 0, 1.3, 0);
            R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 1.6 * e.scale, 1, 0.25, 0.15, 1, 1, 0.5, e.seed, 0);
        }
    } else if (k == "turret") {
        let base = W.xf2;
        models.aim(base, e.x, e.y, e.z, Math.sin(e.seed * 6), 0, Math.cos(e.seed * 6), 0, 1, 0, 0, 1);
        let wsc = e.scale * 0.72;
        models.putScaled(mo.turretBase, base, wsc, e.p3, wsc, 1, 1, 1, 0);
        if (e.dying <= 0) {
            let dome = W.xf3;
            models.aim(dome, e.x, e.y, e.z, -Math.sin(e.yaw), 0, -Math.cos(e.yaw), 0, 1, 0, 0, e.scale);
            models.put(mo.turretDome, dome, 1, 1, 1, flash, 0, 0);
            let gun = W.xf2;
            models.child(gun, dome, 0, 1.05, 0, 0, e.pitch, 0, 1);
            models.put(mo.turretGun, gun, 1, 1, 1, flash, e.tele * 0.5, 0);
            if (e.tele > 0) {
                models.point(gun, 0, 0, -2.7);
                R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, (0.4 + 0.9 * e.tele) * e.scale, 1, 0.1, 0.4, 0.5 + 0.5 * e.tele, 1, 0.5, e.seed, 0);
            }
        }
    }
}
