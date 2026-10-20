// Port of src/world/level.luau. Mission 01 layout: the rail's control points,
// the eight route checkpoints shown on the HUD, set-piece anchors and ring
// chains. Distances are meters along the rail (s); rail coords (s, x, y) put
// a point at railPos(s) + right * x, height railPos.y + y.
// Owned by the world module; gameplay reads sections, rings, anchors,
// portal, eye and waterfalls.
//
// Port: sequences 1-based (slot 0 a dummy). Multi-returns: solidAt ->
// SOLIDAT_PUSH / SOLIDAT_DIR, sightAt -> SIGHTAT_LO / _HI / _BETA / _DIST.
// knots takes flat 0-based (s, value) pairs: knots([s0, v0, s1, v1, ...]).
// Arch.halfAt / inside are methods. canyonFace is set with setCanyonFace
// (an imported binding is read-only). arenas: Map by name.
import { Vector } from "rive/vector";
import * as trackMod from "./track";
import { Track } from "./track";
import * as mathx from "../lib/mathx";
import { HUGE, lmin, lmax, lclamp } from "../lib/compat";

export class Section {
    num: string;
    label: string;
    s0: f64;
    s1: f64;
    biome: f64; // 0 coast, 1 violet
    objective: string;
    constructor(num: string, label: string, s0: f64, s1: f64, biome: f64, objective: string) {
        this.num = num;
        this.label = label;
        this.s0 = s0;
        this.s1 = s1;
        this.biome = biome;
        this.objective = objective;
    }
}

// kind: "gold" | "silver" | "boost"
export class RingSpec {
    s: f64 = 0;
    x: f64 = 0;
    y: f64 = 0;
    kind: string = "gold";
}

// A ring gate in rail coords: center (s, x, y rail-relative), radius in meters.
export class Gate {
    s: f64;
    x: f64;
    y: f64;
    radius: f64;
    constructor(s: f64, x: f64, y: f64, radius: f64) {
        this.s = s;
        this.x = x;
        this.y = y;
        this.radius = radius;
    }
}

// Waterfall descriptor (world space): lip center, pool height, width and the
// horizontal direction the water falls away from its cliff.
export class Waterfall {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    bottom: f64 = 0;
    width: f64 = 0;
    ox: f64 = 0;
    oz: f64 = 0;
    s: f64 = 0;
}

export const points: Array<Vector> = [
    Vector.xyz(0, 0, 0), // (slot 0)
    // 01 lighthouse: out of the bay, hug the headland
    Vector.xyz(0, 0, 0),
    Vector.xyz(0, 0, -260),
    Vector.xyz(-30, 0, -560),
    Vector.xyz(5, 0, -880),
    // 02 sea arch: stacks slalom, then dead straight through the arch
    Vector.xyz(35, 0, -1150),
    Vector.xyz(5, 0, -1420),
    Vector.xyz(0, 0, -1600),
    Vector.xyz(0, 0, -1780),
    // 03 low pass: open water S-curve
    Vector.xyz(-35, 0, -2100),
    Vector.xyz(10, 0, -2420),
    Vector.xyz(40, 0, -2720),
    // 04 cliff turn: canyon hard right
    Vector.xyz(45, 0, -2960),
    Vector.xyz(90, 0, -3220),
    Vector.xyz(210, 0, -3400),
    Vector.xyz(400, 0, -3470),
    Vector.xyz(620, 0, -3470),
    // 05 sky portal: the climb
    Vector.xyz(860, 8, -3440),
    Vector.xyz(1100, 45, -3480),
    Vector.xyz(1350, 95, -3440),
    Vector.xyz(1600, 140, -3470),
    Vector.xyz(1850, 158, -3510),
    Vector.xyz(2080, 165, -3480), // the portal
    // 06 violet reach: the dive
    Vector.xyz(2320, 150, -3470),
    Vector.xyz(2560, 95, -3490),
    Vector.xyz(2800, 38, -3520),
    Vector.xyz(3050, 3, -3500),
    Vector.xyz(3330, 0, -3430),
    Vector.xyz(3600, 0, -3510),
    // 07 the falls: S-bend canyon
    Vector.xyz(3900, 0, -3570),
    Vector.xyz(4200, 0, -3510),
    Vector.xyz(4500, 0, -3460),
    Vector.xyz(4800, 0, -3490),
    // 08 the eye: final climb
    Vector.xyz(5100, 8, -3490),
    Vector.xyz(5400, 55, -3490),
    Vector.xyz(5620, 80, -3490),
];

export const track: Track = trackMod.build(points, 2);

// s of control point i (nearest resampled point)
function sAtPoint(i: i32): f64 {
    let p = points[i];
    let tr = track;
    let px = <f64>p.x, py = <f64>p.y, pz = <f64>p.z;
    let best = HUGE, bs = 0.0;
    for (let k = 1; k <= tr.n; k++) {
        let dx = tr.px[k] - px, dy = tr.py[k] - py, dz = tr.pz[k] - pz;
        let d = dx * dx + dy * dy + dz * dz;
        if (d < best) {
            best = d;
            bs = <f64>(k - 1) * tr.step;
        }
    }
    return bs;
}

const LEN: f64 = track.length;
const PORTAL_S: f64 = Math.floor(sAtPoint(22));

// The lighthouse: rail distance, lateral distance to the left of the rail,
// clifftop ground height (the promontory is flattened to it).
export class Lighthouse {
    s: f64 = 610;
    x: f64 = 104;
    ground: f64 = 22;
    scale: f64 = 1.3;
}
export const lighthouse: Lighthouse = new Lighthouse();

function lanternPos(): Vector {
    let L = lighthouse;
    trackMod.frame(track, L.s + 4);
    let p = trackMod.FRAME_P, rt = trackMod.FRAME_R;
    return mathx.v3(<f64>p.x - <f64>rt.x * L.x, L.ground + 27.8 * L.scale, <f64>p.z - <f64>rt.z * L.x);
}

const ARCH_S: f64 = 1690, ARCH_W: f64 = 36, ARCH_H: f64 = 26;
// arch rock (scenery builds it from these): half thickness along the rail,
// rock over the crown, leg width beside the opening
export const ARCH_DEPTH: f64 = 10;
export const ARCH_CROWN: f64 = 13;
export const ARCH_LEG: f64 = 14;

// arches.gate's smooth intrados, right half (crown to foot): th from pi/2
// to 0 in N = 32 steps, u = cos(th) w/2, y = h sin(th)^0.62, the feet drawn
// down to vertical sides near the water (same formula as arches.gate)
export const ARCH_DRIP: f64 = 1.7;
const ARCH_N: i32 = 32;
const archU: Array<f64> = [0.0];
const archY: Array<f64> = [0.0];
function buildArchProfile(): void {
    for (let k = ARCH_N / 2; k <= ARCH_N; k++) {
        let th = Math.PI * (1 - <f64>k / <f64>ARCH_N);
        let c = Math.cos(th), sn = Math.sin(th);
        let iy = ARCH_H * Math.pow(sn, 0.62);
        if (k == ARCH_N) {
            iy = -4;
        } else if (sn < 0.25) {
            iy = lmax(-4, iy - (0.25 - sn) * 16);
        }
        archU.push(c * ARCH_W * 0.5);
        archY.push(iy);
    }
}
buildArchProfile();

// half width of the smooth profile polygon at height y (0 above the crown)
function profileHalf(y: f64): f64 {
    if (y >= archY[1]) return 0;
    let n = archY.length - 1;
    for (let i = 1; i <= n - 1; i++) {
        let y0 = archY[i], y1 = archY[i + 1];
        if (y <= y0 && y >= y1) {
            let t = (y0 - y) / lmax(y0 - y1, 1e-6);
            return archU[i] + (archU[i + 1] - archU[i]) * t;
        }
    }
    return archU[archU.length - 1];
}

function archHalfAt(y: f64): f64 {
    if (y <= 0) return 0;
    // drips hang from the ceiling above 0.72 h: nothing lower than
    // 0.72 h - ARCH_DRIP
    let drop = ARCH_DRIP * mathx.smoothstep(ARCH_H * 0.72 - ARCH_DRIP - 1.5, ARCH_H * 0.72 - ARCH_DRIP, y);
    return lmax(0, profileHalf(y + drop) - 0.25);
}

// The SEA ARCH opening (rail coords) for gameplay (objective, THREADED
// sting, camera framing). The rock is `depth` m thick along the rail: the
// tunnel runs from mouth s0 to mouth s1 with the keystone at s. `halfAt(y)`
// is the clear half width of the opening at height y above the water,
// symmetric about x: the smooth profile arches.gate builds its colliders
// on (its broken rock edge only ever cuts outward), less 0.25 m, and under
// the crown less the ceiling drips (they hang up to ARCH_DRIP m): 0 at or
// below the water and from h - ARCH_DRIP up. `inside(x, y, r?)` tests a
// rail-relative point (a body of radius r) against it: nothing baked or
// colliding lies inside the window.
export class Arch {
    s: f64 = ARCH_S; // keystone (middle of the tunnel)
    x: f64 = 0; // opening center, rail x
    y: f64 = 0; // opening bottom, rail-relative (the water)
    w: f64 = ARCH_W; // full width at the springing
    h: f64 = ARCH_H; // height, water to crown
    s0: f64 = ARCH_S - ARCH_DEPTH; // front mouth
    s1: f64 = ARCH_S + ARCH_DEPTH; // back mouth (the exit)
    top: f64 = ARCH_H + ARCH_CROWN; // rock top above the water (the grass cap)
    halfAt(y: f64): f64 {
        return archHalfAt(y);
    }
    inside(x: f64, y: f64, r: f64 = 0): bool {
        return y > 0 && Math.abs(x) + r < archHalfAt(y + r);
    }
}

export class Anchors {
    lighthouseS: f64 = 0;
    archS: f64 = 0;
    archX: f64 = 0; // opening center, rail x
    archY: f64 = 0; // opening mid height, rail-relative
    archW: f64 = 0; // opening full width
    archH: f64 = 0; // opening height (water to crown)
    canyonS0: f64 = 0;
    canyonS1: f64 = 0;
    portalS: f64 = 0;
    fallsS: f64 = 0; // the falls curtain you fly through
    eyeS: f64 = 0;
    climbS0: f64 = 0; // start of the sky climb
    diveS1: f64 = 0; // end of the dive after the portal (back at sea level)
    // the arch opening as one record: x center, y bottom (rail-relative), w full width, h height
    arch: Arch = new Arch();
    lighthouse: Vector = Vector.xyz(0, 0, 0); // lantern world position (camera framing)
}

function makeAnchors(): Anchors {
    let a = new Anchors();
    a.lighthouseS = lighthouse.s;
    a.archS = ARCH_S;
    a.archX = 0;
    a.archY = ARCH_H * 0.5;
    a.archW = ARCH_W;
    a.archH = ARCH_H;
    a.canyonS0 = 2900;
    a.canyonS1 = 3860;
    a.portalS = PORTAL_S;
    a.fallsS = 7420;
    a.eyeS = Math.floor(LEN - 40);
    a.climbS0 = 3900;
    a.diveS1 = 6380;
    a.arch = new Arch();
    a.lighthouse = lanternPos();
    return a;
}
export const anchors: Anchors = makeAnchors();

// Checkpoints (HUD "ROUTE nn/08"), 1-based.
export const sections: Array<Section> = [
    new Section("", "", 0, 0, 0, ""), // (slot 0)
    new Section("01", "LIGHTHOUSE", 0, 900, 0, "CLEAR THE SKIES"),
    new Section("02", "SEA ARCH", 900, 1800, 0, "FLY THROUGH THE ARCH"),
    new Section("03", "LOW PASS", 1800, 2850, 0, "STAY UNDER 3 M"),
    new Section("04", "CLIFF TURN", 2850, 3900, 0, "THREAD THE CANYON"),
    new Section("05", "SKY PORTAL", 3900, PORTAL_S, 0, "DOWN THE STORMCROW"),
    new Section("06", "VIOLET REACH", PORTAL_S, 6600, 1, "DOWN THE JET TROOPERS"),
    new Section("07", "THE FALLS", 6600, 7700, 1, "SKIM THE FALLS"),
    new Section("08", "THE EYE", 7700, Math.ceil(LEN), 1, "ENTER THE EYE"),
];

// Portal between biomes (s where the violet palette takes over).
export const portalS: f64 = PORTAL_S;

// The two swirl portals (rail coords). The renderer draws the swirl inside
// `radius`; the scenery builds the rim just outside it.
export const portal: Gate = new Gate(PORTAL_S, 0, 14, 52);
export const eye: Gate = new Gate(anchors.eyeS, 0, 14, 90);

// Flight school lane out at sea, before the bay (rail s < 0 runs straight
// back along frame 0): launch hover s, the cut into the bay channel
// (handoff) and the drills' hard stop.
export class School {
    s: f64 = -4500;
    handoff: f64 = -340;
    stop: f64 = -900;
}
export const school: School = new School();

// World position of a rail coordinate.
export function world(s: f64, x: f64, y: f64): Vector {
    trackMod.frame(track, s);
    let p = trackMod.FRAME_P, rt = trackMod.FRAME_R;
    return mathx.v3(<f64>p.x + <f64>rt.x * x, <f64>p.y + y, <f64>p.z + <f64>rt.z * x);
}

// Waterfalls ---------------------------------------------------------------
// (s, side, lateral lip distance, lip height, width). Lips sit on the canyon
// wall tops of THE FALLS and on floating islands during the climb.
// Canyon walls (shared by the scenery and the waterfall lips). dist = the
// inner face's lateral distance at the waterline; the face leans back by
// 0.12 * height toward its top.
// Canyon wall foot, lateral meters from the rail. The walls pinch the
// flight box (|x| ~14 at flying height): holding a side means rock.
export function cliffTurnDist(s: f64, side: f64): f64 {
    let n = mathx.fbm2(s * 0.011, side * 3.7, 3) / 0.875;
    let q = (s - 3420) / 180;
    let pinch = Math.exp(-(q * q)) * 2.5;
    return 16 + (n - 0.5) * 4 - pinch;
}

export function fallsDist(s: f64, side: f64): f64 {
    let n = mathx.fbm2(s * 0.013, side * 4.1 + 7, 3) / 0.875;
    return 38 + (n - 0.5) * 6;
}

export type KnotFn = (s: f64) => f64;

// Smooth curve through (s, value) knots (cosine blend) plus fbm jitter
// (the scenery's profile curves). list: flat (s, value) pairs, 0-based.
export function knots(list: Array<f64>, amp: f64 = 0, freq: f64 = 0.02, seed: f64 = 0): KnotFn {
    let a = amp;
    let fq = freq;
    let sd = seed;
    let nk = list.length >> 1;
    return (s: f64): f64 => {
        let v: f64;
        let last = (nk - 1) * 2;
        if (s <= list[0]) {
            v = list[1];
        } else if (s >= list[last]) {
            v = list[last + 1];
        } else {
            v = list[last + 1];
            for (let i = 0; i < nk - 1; i++) {
                let p0 = list[i * 2], p1 = list[i * 2 + 1];
                let q0 = list[i * 2 + 2], q1 = list[i * 2 + 3];
                if (s < q0) {
                    let t = (s - p0) / (q0 - p0);
                    t = (1 - Math.cos(t * Math.PI)) * 0.5;
                    v = p1 + (q1 - p1) * t;
                    break;
                }
            }
        }
        if (a > 0) {
            v += (mathx.fbm2(s * fq + sd * 0.1, sd * 0.37, 3) / 0.875 - 0.5) * 2 * a;
        }
        return v;
    };
}

// CLIFF TURN wall foot from the canyon mouth through the climb (the canyon
// strips' waterline, lateral m from the rail): the slot (cliffTurnDist)
// flares out over CANYON_OPEN0 .. CANYON_OPEN1, from just past the
// Stormcrow's cue (3600) into the valley shore below the climb, so from the
// slot the sky beyond the mouth opens wide enough to show her whole at her
// reveal distance (see sightFrom). The scenery builds the strips on it;
// bossRoomS reads it.
export const CANYON_OPEN0: f64 = 3630;
export const CANYON_OPEN1: f64 = 3930;
const canyonFarL: KnotFn = knots([CANYON_OPEN0, 60, 3950, 170, 4500, 250, 5000, 320, 5700, 380], 24, 0.01, 31 - 1);
const canyonFarR: KnotFn = knots([CANYON_OPEN0, 60, 3950, 170, 4500, 250, 5000, 320, 5700, 380], 24, 0.01, 31 + 1);

export function canyonFoot(s: f64, side: f64): f64 {
    let c0 = anchors.canyonS0;
    let mouth = lmax(0, c0 + 10 - s) * 0.55;
    let t = mathx.smoothstep(CANYON_OPEN0, CANYON_OPEN1, s);
    let far = side < 0 ? canyonFarL(s) : canyonFarR(s);
    return (cliffTurnDist(s, side) + mouth) * (1 - t) + far * t;
}

// lat: wall foot distance (NaN: the canyon's)
class FallDef {
    s: f64;
    side: f64;
    h: f64;
    w: f64;
    falls: bool;
    lat: f64;
    constructor(s: f64, side: f64, h: f64, w: f64, falls: bool, lat: f64 = NaN) {
        this.s = s;
        this.side = side;
        this.h = h;
        this.w = w;
        this.falls = falls;
        this.lat = lat;
    }
}

function buildWaterfalls(): Array<Waterfall> {
    let defs: Array<FallDef> = [
        // CLIFF TURN: two ribbons down the canyon walls
        new FallDef(3200, -1, 64, 12, false),
        new FallDef(3640, 1, 72, 14, false),
        // a lip fall on the outside wall mid-turn
        new FallDef(3390, -1, 66, 16, false),
        // VIOLET REACH: a tall ribbon down the right lagoon wall (violet_reach.png)
        new FallDef(6040, 1, 120, 18, true, 118),
        // THE FALLS canyon
        new FallDef(6720, -1, 72, 12, true),
        new FallDef(6880, 1, 80, 16, true),
        new FallDef(7060, -1, 88, 22, true),
        new FallDef(7230, 1, 76, 14, true),
        new FallDef(7560, -1, 84, 18, true),
    ];
    let out = new Array<Waterfall>(1);
    for (let k = 0; k < defs.length; k++) {
        let f = defs[k];
        trackMod.frame(track, f.s);
        let p = trackMod.FRAME_P, rt = trackMod.FRAME_R;
        let d0 = !isNaN(f.lat) ? f.lat : (f.falls ? fallsDist(f.s, f.side) : cliffTurnDist(f.s, f.side));
        // lip tucked just inside the leaning face near its top
        let d = d0 + 0.12 * f.h + 1.5;
        let w = new Waterfall();
        w.x = <f64>p.x + <f64>rt.x * f.side * d;
        w.y = f.h - 1;
        w.z = <f64>p.z + <f64>rt.z * f.side * d;
        w.bottom = 0;
        w.width = f.w;
        w.ox = -<f64>rt.x * f.side;
        w.oz = -<f64>rt.z * f.side;
        w.s = f.s;
        out.push(w);
    }
    return out;
}
// 1-based; the scenery rewrites x / y / z of entries in place.
export const waterfalls: Array<Waterfall> = buildWaterfalls();

// Rings --------------------------------------------------------------------

// Skim ring centre height over the water: under the skim line (player.luau
// SKIM_ALT 3.2), so a pilot threading the middle counts as skimming (the
// 3.2 m ring dips its lower rim into the sea).
export const SKIM_RING_Y: f64 = 2.7;

// The fence's guide rings (rail s, x, y): level with its stacks, in their
// gaps. 1-based, each entry 1-based.
export const FENCE_RINGS: Array<Array<f64>> = [[0.0], [0.0, 760, -9, 6], [0.0, 810, 4.5, 7], [0.0, 870, 7, 6], [0.0, 935, 0, 7]];

// SEA ARCH slalom gates (rail s, ring x): level with the slalom stacks
// (scenery.sectionArch), centred in the gap between each one and its
// partner at the box edge. 1-based, each entry 1-based.
export const SLALOM_RINGS: Array<Array<f64>> = [[0.0], [0.0, 1010, -7], [0.0, 1090, 6.5], [0.0, 1170, -5.5], [0.0, 1250, 5.5], [0.0, 1330, -5.5], [0.0, 1410, 5.5]];

function addRing(out: Array<RingSpec>, s: f64, x: f64, y: f64, kind: string = "gold"): void {
    let r = new RingSpec();
    r.s = s;
    r.x = x;
    r.y = y;
    r.kind = kind;
    out.push(r);
}

function buildRings(): Array<RingSpec> {
    let R = new Array<RingSpec>(1);
    // 01: tutorial weave out of the bay
    for (let k = 0; k <= 5; k++) {
        let i = <f64>k;
        addRing(R, 250 + i * 45, Math.sin(i * 0.8) * 8, 6 + Math.cos(i * 0.6) * 2);
    }
    // 01: a climbing arc that salutes the lighthouse as it passes, then back down
    for (let k = 0; k <= 6; k++) {
        let i = <f64>k;
        let t = i / 6;
        addRing(R, 500 + i * 34, -6 - Math.sin(t * Math.PI) * 12, 8 + Math.sin(t * Math.PI) * 16);
    }
    // 01: through the fence after the lighthouse (scenery.sectionLighthouse):
    // one ring in each stack's gap, so no ring line runs through the fence
    for (let k = 1; k < FENCE_RINGS.length; k++) {
        let f = FENCE_RINGS[k];
        addRing(R, f[1], f[2], f[3]);
    }
    // 02: slalom gates: each ring level with its stack, in the gap between
    // the stack and its outer partner (scenery.sectionArch); the line from
    // one gate to the next crosses open water
    for (let k = 1; k < SLALOM_RINGS.length; k++) {
        let sx = SLALOM_RINGS[k];
        addRing(R, sx[1], sx[2], 5 + <f64>(k % 2) * 2);
    }
    // 02: through the arch
    addRing(R, 1640, 0, 9);
    addRing(R, 1690, 0, 11, "silver");
    addRing(R, 1740, 0, 9);
    // 03: skim chains just above the water (centres under the skim line,
    // SKIM_RING_Y: flying through the middle counts as skimming)
    for (let k = 0; k <= 7; k++) {
        let i = <f64>k;
        addRing(R, 1900 + i * 45, Math.sin(i * 0.7) * 12, SKIM_RING_Y);
    }
    for (let k = 0; k <= 7; k++) {
        let i = <f64>k;
        addRing(R, 2330 + i * 45, -Math.sin(i * 0.55) * 14, SKIM_RING_Y, k == 7 ? "silver" : "gold");
    }
    // 04: hug the inside of the canyon turn, ducking under the bridges; the
    // rings either side of the 3260 pillar lead through its left gap, the
    // one before them easing the swing over (the first sits at 3240, past
    // the pinch of the 3200 fall: player.boxX stops a pilot ~4.5 m left of
    // the rail at 3225 and its soft edge slows him there, so it stays within
    // reach of the line out of the pinch)
    // (the last one, 3675, is gone: 2.7 m outside player.boxX, no pilot
    // or bot ever took it, and it sat over the Stormcrow rising out of the
    // storm; enemies notes)
    for (let k = 0; k <= 8; k++) {
        let i = <f64>k;
        let s = k == 3 ? 3240.0 : 3000 + i * 75;
        let x = k == 2 ? 2.0 : k == 3 ? -4.0 : k == 4 ? -3.5 : 3 + Math.sin(i * 0.9) * 6;
        addRing(R, s, x, 7 + Math.cos(i * 0.7) * 4);
    }
    // 05: boost rings up the climb, then gold among the clouds
    for (let k = 0; k <= 5; k++) {
        let i = <f64>k;
        addRing(R, 3960 + i * 110, Math.cos(i * 1.1) * 7, 8 + i * 1.5, "boost");
    }
    for (let k = 0; k <= 8; k++) {
        let i = <f64>k;
        addRing(R, 4700 + i * 70, Math.sin(i * 0.9) * 14, 12 + Math.sin(i * 1.4) * 7);
    }
    addRing(R, PORTAL_S - 45, 0, 14, "silver");
    // 06: down the dive between the spires, then a weave at sea level
    for (let k = 0; k <= 8; k++) {
        let i = <f64>k;
        addRing(R, PORTAL_S + 90 + i * 100, Math.sin(i * 0.8) * 10, 10 + Math.cos(i * 0.5) * 4);
    }
    for (let k = 0; k <= 5; k++) {
        let i = <f64>k;
        addRing(R, 6420 + i * 40, Math.sin(i * 1.1) * 13, 4);
    }
    // 07: skim the pools under the falls, then the curtain
    for (let k = 0; k <= 11; k++) {
        let i = <f64>k;
        addRing(R, 6680 + i * 55, Math.sin(i * 0.6) * 11, SKIM_RING_Y, k == 11 ? "silver" : "gold");
    }
    addRing(R, 7390, 0, 6);
    addRing(R, 7420, 0, 6);
    addRing(R, 7450, 0, 6);
    // 08: last gauntlet, rising into the Eye
    for (let k = 0; k <= 11; k++) {
        let i = <f64>k;
        addRing(R, 7800 + i * 85, Math.sin(i * 0.75) * 12, 6 + i * 0.7, k == 11 ? "silver" : "gold");
    }
    return R;
}
// 1-based
export const rings: Array<RingSpec> = buildRings();

// 1-based section index
export function sectionAt(s: f64): i32 {
    let n = sections.length - 1;
    for (let i = 1; i <= n; i++) {
        if (s < sections[i].s1) return i;
    }
    return n;
}

// Boss clearance -------------------------------------------------------------
// Arenas: rail volumes a boss fight owns (s span, half width hw, heights
// y0..y1 m over the rail). The scenery keeps islands and stacks out of
// them (`arenaClearX`). The Stormcrow's runs from where the CLIFF TURN
// walls have opened past hw through the portal; before it, over the canyon
// mouth, `bossRoomS` describes the room (the walls and the exit stacks).
export class Arena {
    s0: f64;
    s1: f64;
    hw: f64;
    y0: f64;
    y1: f64;
    constructor(s0: f64, s1: f64, hw: f64, y0: f64, y1: f64) {
        this.s0 = s0;
        this.s1 = s1;
        this.hw = hw;
        this.y0 = y0;
        this.y1 = y1;
    }
}
// Registered rock (stacks, islands, the canyon pillars): an upright
// cylinder at rail s, lateral x, radius r, between world heights y0 and y1
// (wx, wz: its world centre).
export class Solid {
    s: f64 = 0;
    x: f64 = 0;
    r: f64 = 0;
    y0: f64 = 0;
    y1: f64 = 0;
    wx: f64 = 0;
    wz: f64 = 0;
}

function makeArenas(): Map<string, Arena> {
    let m = new Map<string, Arena>();
    m.set("stormcrow", new Arena(3880, PORTAL_S + 40, 60, -4, 52));
    return m;
}
export const arenas: Map<string, Arena> = makeArenas();
// The rendered canyon face stands at most CANYON_FACE_IN m in front of
// canyonFoot (facets, bulge, crags, ribs; the face between two strip
// columns never nearer than the nearer column) and leans back CANYON_LEAN
// m per m of height.
export const CANYON_FACE_IN: f64 = 5.5;
export const CANYON_LEAN: f64 = 0.12;
// 1-based
export const solids: Array<Solid> = new Array<Solid>(1);

// The envelope table: per side, the least lateral room from s to the end
// of the table (non-decreasing in s), canyon walls and registered solids.
const ENV_S0: f64 = anchors.canyonS0 - 80, ENV_S1: f64 = 4400, ENV_DS: f64 = 2;
class Env {
    l: Array<f64> = [0.0]; // side -1, 1-based
    r: Array<f64> = [0.0]; // side +1
}
let env: Env? = null;

export function addSolid(s: f64, x: f64, r: f64, y0: f64, y1: f64): void {
    let w = world(s, x, 0);
    let so = new Solid();
    so.s = s;
    so.x = x;
    so.r = r;
    so.y0 = y0;
    so.y1 = y1;
    so.wx = <f64>w.x;
    so.wz = <f64>w.z;
    solids.push(so);
    env = null;
}

function buildEnv(): Env {
    let n = <i32>Math.floor((ENV_S1 - ENV_S0) / ENV_DS) + 1;
    let out = new Env();
    for (let sd = -1; sd <= 1; sd += 2) {
        let side = <f64>sd;
        let foot = new Array<f64>(n + 7);
        for (let i = 1; i <= n + 6; i++) {
            foot[i] = canyonFoot(ENV_S0 + <f64>(i - 4) * ENV_DS, side);
        }
        let e = new Array<f64>(n + 1);
        for (let i = 1; i <= n; i++) {
            // column spacing 6 m: the nearer foot within +-6 m
            let m = HUGE;
            for (let j = i; j <= i + 6; j++) m = lmin(m, foot[j]);
            e[i] = m - CANYON_FACE_IN;
        }
        for (let k = 1; k < solids.length; k++) {
            let so = solids[k];
            if (so.x * side > 0) {
                let i0 = <i32>lmax(1, Math.floor((so.s - so.r - ENV_S0) / ENV_DS) + 1);
                let i1 = <i32>lmin(<f64>n, Math.ceil((so.s + so.r - ENV_S0) / ENV_DS) + 1);
                for (let i = i0; i <= i1; i++) {
                    e[i] = lmin(e[i], Math.abs(so.x) - so.r);
                }
            }
        }
        for (let i = n - 1; i >= 1; i--) e[i] = lmin(e[i], e[i + 1]);
        if (sd < 0) out.l = e;
        else out.r = e;
    }
    return out;
}

// The first rail s from which a point `lat` m to `side` of the rail, `y` m
// over the sea, stays clear of the canyon walls and the solids for good
// (-huge: clear from the canyon's start; beyond the table the arena holds).
export function bossRoomS(side: f64, lat: f64, y: f64): f64 {
    let tab = env;
    if (tab == null) {
        tab = buildEnv();
        env = tab;
    }
    let e = side < 0 ? tab.l : tab.r;
    let want = lat - CANYON_LEAN * lmax(0, y - 1);
    if (e[1] >= want) return -HUGE;
    let n = e.length - 1;
    if (e[n] < want) return ENV_S1;
    let lo = 1, hi = n;
    while (hi - lo > 1) {
        let mid = (lo + hi) >> 1;
        if (e[mid] >= want) hi = mid;
        else lo = mid;
    }
    let t = (want - e[lo]) / lmax(e[hi] - e[lo], 1e-6);
    return ENV_S0 + (<f64>(lo - 1) + lclamp(t, 0, 1)) * ENV_DS;
}

// How far a point (rail s, lateral lat, world height y) sits inside a
// registered solid grown by pad, as the lateral move that frees it (> 0
// inside) and its direction (+1 right, -1 left).
// solidAt -> push (also SOLIDAT_PUSH), SOLIDAT_DIR
export let SOLIDAT_PUSH: f64 = 0;
export let SOLIDAT_DIR: f64 = 0;
export function solidAt(s: f64, lat: f64, y: f64, pad: f64): f64 {
    let best = 0.0, dir = 0.0;
    for (let k = 1; k < solids.length; k++) {
        let so = solids[k];
        let ds = s - so.s;
        let r = so.r + pad;
        if (ds > -r && ds < r && y > so.y0 - pad && y < so.y1 + pad) {
            let reach = Math.sqrt(r * r - ds * ds);
            let dl = lat - so.x;
            let push = reach - Math.abs(dl);
            if (push > best) {
                best = push;
                dir = dl >= 0 ? 1 : -1;
            }
        }
    }
    SOLIDAT_PUSH = best;
    SOLIDAT_DIR = dir;
    return best;
}

// Whether solidAt can push any point with rail s in s0 .. s1, lateral lat
// in l0 .. l1 and world height y in y0 .. y1 (its tests on the box's ends;
// a push needs |lat - x| under the grown radius): false means solidAt
// returns 0 for every such point (a prefilter for a batch of points).
export function solidAtIn(s0: f64, s1: f64, l0: f64, l1: f64, y0: f64, y1: f64, pad: f64): bool {
    for (let k = 1; k < solids.length; k++) {
        let so = solids[k];
        let r = so.r + pad;
        if (s1 - so.s > -r && s0 - so.s < r && y1 > so.y0 - pad && y0 < so.y1 + pad && l1 - so.x > -r && l0 - so.x < r) {
            return true;
        }
    }
    return false;
}

// Lateral x for rock of radius r (plan radius, grown for spurs and shrubs)
// standing between world heights y0 and y1 at rail s: pushed out of any
// arena it would reach into (the scenery places islands with it).
export function arenaClearX(s: f64, x: f64, r: f64, y0: f64, y1: f64): f64 {
    let all = arenas.values();
    for (let k = 0; k < all.length; k++) {
        let a = all[k];
        if (s > a.s0 - r && s < a.s1 + r) {
            trackMod.frame(track, s);
            let py = <f64>trackMod.FRAME_P.y;
            if (y1 > py + a.y0 && y0 < py + a.y1 && Math.abs(x) - r < a.hw) {
                x = (x < 0 ? -1.0 : 1.0) * (a.hw + r);
            }
        }
    }
    return x;
}

// Sight lines out of the CLIFF TURN slot --------------------------------------
// From deep in the slot the air beyond shows only through its narrowest
// stretch. `sightFrom` fills a Sight for one lens: per rail column ahead,
// the canyon faces as bearings (radians, + right of the rail at the lens)
// folded into the narrowest window so far (lo[k] .. hi[k]: no canyon wall
// up to column k stands between those bearings). `sightAt` gives a point's
// bearing and the window in front of it, narrowed by the registered solids
// in the way and by the opening of a bridge span it passes (a span it runs
// into closes it). A boss keeps its whole silhouette inside the window, so
// rock never cuts into it on screen.
export class Ceiling {
    s: f64 = 0;
    half: f64 = 0; // half depth along the rail
    hw: f64 = 0; // opening half width at the springing
    h: f64 = 0; // opening crown over the sea
    top: f64 = 0; // rock top (world y), grass cap included
    x: f64 = 0; // world centre on the water, rail frame there
    z: f64 = 0;
    fx: f64 = 0;
    fz: f64 = 0;
    rx: f64 = 0;
    rz: f64 = 0;
}
// Rock spans over the rail (the canyon bridges, arches.gate): rail s, half
// depth along the rail, the opening (the smooth intrados the gate is built
// on: half width hw at the springing, crown h; the rock only ever breaks
// outward from it) and the rock's top. A sight line that runs through the
// span clear of rock is inside the opening or over the top all the way.
// 1-based
export const ceilings: Array<Ceiling> = new Array<Ceiling>(1);

export function addCeiling(s: f64, half: f64, hw: f64, h: f64, top: f64): void {
    trackMod.frame(track, s);
    let p = trackMod.FRAME_P, f = trackMod.FRAME_F, rt = trackMod.FRAME_R;
    let fx = <f64>f.x, fz = <f64>f.z;
    let fl = lmax(Math.sqrt(fx * fx + fz * fz), 1e-6);
    let c = new Ceiling();
    c.s = s;
    c.half = half;
    c.hw = hw;
    c.h = h;
    c.top = top;
    c.x = <f64>p.x;
    c.z = <f64>p.z;
    c.fx = fx / fl;
    c.fz = fz / fl;
    c.rx = <f64>rt.x;
    c.rz = <f64>rt.z;
    ceilings.push(c);
}

// Clear half width of a span's opening at world height y (the intrados,
// its ceiling drips off as for the arch; 0 at the water and over the crown).
function spanHalf(ce: Ceiling, y: f64): f64 {
    if (y <= 0.3) return 0;
    let drop = ARCH_DRIP * mathx.smoothstep(ce.h * 0.72 - ARCH_DRIP - 1.5, ce.h * 0.72 - ARCH_DRIP, y);
    let u = (y + drop) / ce.h;
    if (u >= 1) return 0;
    let sn = Math.pow(u, 1 / 0.62);
    return ce.hw * Math.sqrt(1 - sn * sn) - 0.25;
}

// margins a sight line keeps off a span's rock: under the intrados and over
// the top (m, plus m per m from the lens), and off its sides (m; the bearing
// margin is the boss's)
const SPAN_M: f64 = 1.5, SPAN_A: f64 = 0.018, SPAN_W: f64 = 0.5;

export class Sight {
    ex: f64 = 0;
    ey: f64 = 0;
    ez: f64 = 0;
    se: f64 = 0; // the lens's rail s
    fx: f64 = 0; // bearing frame: the rail's forward / right at the lens
    fz: f64 = 1;
    rx: f64 = 1;
    rz: f64 = 0;
    i0: i32 = 1; // first column in front of the lens
    lo: Array<f64> = [0.0]; // 1-based, set from i0 on
    hi: Array<f64> = [0.0];
    near: Array<Solid> = new Array<Solid>(1); // 1-based: solids ahead of the lens that can stand in the window
}

// Past SIGHT_S1 the valley is wide open: no wall narrows the view.
export const SIGHT_S1: f64 = 4300;
const SIGHT_DS: f64 = 4;
// The rendered CLIFF TURN faces once the scenery has planned its strips:
// the nearest face point (lateral m, any height) of the strip columns
// within 6 m of s. Without it the sight lines read canyonFoot less
// CANYON_FACE_IN, leaning back with height.
export type FaceFn = (s: f64, side: f64) => f64;
export let canyonFace: FaceFn? = null;
export function setCanyonFace(fn: FaceFn?): void {
    canyonFace = fn;
}

class Cols {
    n: i32 = 0;
    real: bool = false;
    px: Array<f64> = [0.0];
    pz: Array<f64> = [0.0];
    rx: Array<f64> = [0.0];
    rz: Array<f64> = [0.0];
    fl: Array<f64> = [0.0];
    fr: Array<f64> = [0.0];
}
let cols: Cols? = null;

function buildCols(): Cols {
    let n = <i32>Math.floor((SIGHT_S1 - ENV_S0) / SIGHT_DS) + 1;
    let cf = canyonFace;
    let c = new Cols();
    c.n = n;
    c.real = cf != null;
    c.px = new Array<f64>(n + 1);
    c.pz = new Array<f64>(n + 1);
    c.rx = new Array<f64>(n + 1);
    c.rz = new Array<f64>(n + 1);
    c.fl = new Array<f64>(n + 1);
    c.fr = new Array<f64>(n + 1);
    for (let i = 1; i <= n; i++) {
        let s = ENV_S0 + <f64>(i - 1) * SIGHT_DS;
        trackMod.frame(track, s);
        let p = trackMod.FRAME_P, rt = trackMod.FRAME_R;
        c.px[i] = <f64>p.x;
        c.pz[i] = <f64>p.z;
        c.rx[i] = <f64>rt.x;
        c.rz[i] = <f64>rt.z;
        if (cf != null) {
            c.fl[i] = cf(s, -1);
            c.fr[i] = cf(s, 1);
        } else {
            // the nearest foot within the strips' 6 m column spacing
            let ml = HUGE, mr = HUGE;
            for (let k = -3; k <= 3; k++) {
                ml = lmin(ml, canyonFoot(s + <f64>k * 2, -1));
                mr = lmin(mr, canyonFoot(s + <f64>k * 2, 1));
            }
            c.fl[i] = ml - CANYON_FACE_IN;
            c.fr[i] = mr - CANYON_FACE_IN;
        }
    }
    return c;
}

function getCols(): Cols {
    let c = cols;
    if (c == null) {
        c = buildCols();
        cols = c;
    }
    return c;
}

// Builds the sight columns now (the scenery calls it once its strips are
// planned, so a boss's first frame does not pay for it).
export function sightPrep(): void {
    cols = buildCols();
}

export function sightNew(): Sight {
    return new Sight();
}

// Fills S for a lens at world (ex, ey, ez), rail s se; h: the lowest
// height (m over the sea) the sight lines pass the walls at (the faces
// lean back above it).
export function sightFrom(S: Sight, ex: f64, ey: f64, ez: f64, se: f64, h: f64): void {
    let c = getCols();
    trackMod.frame(track, se);
    let f = trackMod.FRAME_F, rt = trackMod.FRAME_R;
    let ffx = <f64>f.x, ffz = <f64>f.z;
    let fl = lmax(Math.sqrt(ffx * ffx + ffz * ffz), 1e-6);
    let fx = ffx / fl, fz = ffz / fl, rx = <f64>rt.x, rz = <f64>rt.z;
    S.ex = ex;
    S.ey = ey;
    S.ez = ez;
    S.se = se;
    S.fx = fx;
    S.fz = fz;
    S.rx = rx;
    S.rz = rz;
    let i0 = <i32>lmax(1, Math.floor((se - ENV_S0) / SIGHT_DS) + 2);
    S.i0 = i0;
    let lean = c.real ? 0 : CANYON_LEAN * lmax(0, h);
    let lo = -Math.PI * 0.5, hi = Math.PI * 0.5;
    let L = S.lo, H = S.hi;
    while (L.length <= c.n) L.push(0);
    while (H.length <= c.n) H.push(0);
    for (let i = i0; i <= c.n; i++) {
        let cx = c.px[i] - ex, cz = c.pz[i] - ez;
        let crx = c.rx[i], crz = c.rz[i];
        // (a lens outside the faces' conservative line is not in rock: the
        // face there stands at least 1 m beyond it)
        let el = -(cx * crx + cz * crz);
        let dl = lmax(c.fl[i] + lean, -el + 1);
        let dr = lmax(c.fr[i] + lean, el + 1);
        let lx = cx - crx * dl, lz = cz - crz * dl;
        let a = lx * fx + lz * fz;
        if (a > 2) lo = lmax(lo, Math.atan2(lx * rx + lz * rz, a));
        let qx = cx + crx * dr, qz = cz + crz * dr;
        a = qx * fx + qz * fz;
        if (a > 2) hi = lmin(hi, Math.atan2(qx * rx + qz * rz, a));
        L[i] = lo;
        H[i] = hi;
    }
    // solids that can stand in the window (as open at their own column)
    let near = S.near;
    near.length = 1;
    for (let q = 1; q < solids.length; q++) {
        let so = solids[q];
        if (so.s > se) {
            let ox = so.wx - ex, oz = so.wz - ez;
            let oa = ox * fx + oz * fz;
            // (a solid the lens is passing stands at the edge of the view)
            if (oa > so.r + 1) {
                let od = Math.sqrt(ox * ox + oz * oz);
                let ob = Math.atan2(ox * rx + oz * rz, oa);
                let half = Math.asin(lmin(1, so.r / od));
                let k = lmin(<f64>c.n, Math.floor((so.s - so.r - ENV_S0) / SIGHT_DS));
                let wl = -Math.PI * 0.5, wh = Math.PI * 0.5;
                if (k >= <f64>i0) {
                    wl = L[<i32>k];
                    wh = H[<i32>k];
                }
                if (ob + half > wl - 0.05 && ob - half < wh + 0.05) near.push(so);
            }
        }
    }
}

// For a point at rail s and world (x, y, z) seen from S's lens: the open
// window's bearings in front of it (lo, hi; lo > hi when rock hides it
// whatever its bearing), its bearing and its horizontal distance. A solid
// in the way closes the window on the side of it away from `aim` (the
// bearing of the body the point belongs to; default (NaN) the point's own),
// so every point of one body keeps to the same side of it.
// sightAt -> lo (also SIGHTAT_LO), SIGHTAT_HI, SIGHTAT_BETA, SIGHTAT_DIST
export let SIGHTAT_LO: f64 = 0;
export let SIGHTAT_HI: f64 = 0;
export let SIGHTAT_BETA: f64 = 0;
export let SIGHTAT_DIST: f64 = 0;

@inline function sightRet(lo: f64, hi: f64, beta: f64, dist: f64): f64 {
    SIGHTAT_LO = lo;
    SIGHTAT_HI = hi;
    SIGHTAT_BETA = beta;
    SIGHTAT_DIST = dist;
    return lo;
}

export function sightAt(S: Sight, s: f64, x: f64, y: f64, z: f64, aim: f64 = NaN): f64 {
    let c = getCols();
    let vx = x - S.ex, vz = z - S.ez;
    let a = vx * S.fx + vz * S.fz;
    let beta = Math.atan2(vx * S.rx + vz * S.rz, a);
    let dist = lmax(Math.sqrt(vx * vx + vz * vz), 1);
    let k = lmin(<f64>c.n, Math.floor((s - ENV_S0) / SIGHT_DS));
    let lo = -Math.PI * 0.5, hi = Math.PI * 0.5;
    if (k >= <f64>S.i0) {
        lo = S.lo[<i32>k];
        hi = S.hi[<i32>k];
    }
    let side = isNaN(aim) ? beta : aim;
    let near = S.near;
    for (let q = 1; q < near.length; q++) {
        let so = near[q];
        if (so.s < s - so.r) {
            let ox = so.wx - S.ex, oz = so.wz - S.ez;
            let od = Math.sqrt(ox * ox + oz * oz);
            if (od < dist) {
                // (the sight line keeps SPAN_M + SPAN_A m over or under it)
                let yl = S.ey + (y - S.ey) * od / dist;
                let mv = SPAN_M + SPAN_A * od;
                if (yl > so.y0 - mv && yl < so.y1 + mv) {
                    let ob = Math.atan2(ox * S.rx + oz * S.rz, ox * S.fx + oz * S.fz);
                    let half = Math.asin(lmin(1, so.r / od));
                    if (ob < side) lo = lmax(lo, ob + half);
                    else hi = lmin(hi, ob - half);
                }
            }
        }
    }
    for (let q = 1; q < ceilings.length; q++) {
        let ce = ceilings[q];
        // the stretch of the sight line inside the span's depth
        let aE = (S.ex - ce.x) * ce.fx + (S.ez - ce.z) * ce.fz;
        let aP = (x - ce.x) * ce.fx + (z - ce.z) * ce.fz;
        if (lmax(aE, aP) > -ce.half && lmin(aE, aP) < ce.half) {
            let da = aP - aE;
            let u0 = 0.0, u1 = 1.0;
            if (Math.abs(da) > 1e-6) {
                let ua = (-ce.half - aE) / da, ub = (ce.half - aE) / da;
                u0 = lmax(0, lmin(ua, ub));
                u1 = lmin(1, lmax(ua, ub));
            }
            // over the top all the way, or through the opening: at both
            // faces (the opening is convex) inside it, as bearings from the
            // lens (a face at the lens itself bounds nothing)
            let qy0 = S.ey + (y - S.ey) * u0, qy1 = S.ey + (y - S.ey) * u1;
            let mv0 = SPAN_M + SPAN_A * dist * u0, mv1 = SPAN_M + SPAN_A * dist * u1;
            if (qy0 - mv0 < ce.top || qy1 - mv1 < ce.top) {
                for (let face = 0; face <= 1; face++) {
                    let u = face == 0 ? u0 : u1;
                    let qy = face == 0 ? qy0 : qy1;
                    let mv = face == 0 ? mv0 : mv1;
                    let w = spanHalf(ce, qy + mv) - SPAN_W;
                    if (w <= 0 || qy < mv) return sightRet(1, -1, beta, dist);
                    if (u > 0.02) {
                        let af = aE + da * u;
                        let cx = ce.x + ce.fx * af - S.ex, cz = ce.z + ce.fz * af - S.ez;
                        let lx = cx - ce.rx * w, lz = cz - ce.rz * w;
                        let rx = cx + ce.rx * w, rz = cz + ce.rz * w;
                        let bl = Math.atan2(lx * S.rx + lz * S.rz, lx * S.fx + lz * S.fz);
                        let br = Math.atan2(rx * S.rx + rz * S.rz, rx * S.fx + rz * S.fz);
                        lo = lmax(lo, lmin(bl, br));
                        hi = lmin(hi, lmax(bl, br));
                    }
                }
            }
        }
    }
    return sightRet(lo, hi, beta, dist);
}
