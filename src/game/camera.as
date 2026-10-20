// Port of src/game/camera.luau. Camera rig: title attract orbit, briefing swoop, launch, rubber-band chase
// cam with lag and roll, boss framing, crash/outro holds, results drift.
// Also owns the visor sway springs and screen shake.
//
// Port notes: the game's probe closures (Luau rig.solid / rig.rockNear) are
// one RigWorld (rig.world, null = none): solid() returns hit and leaves the
// push-out normal / depth in its nx / ny / nz / d. Multi-returns: project ->
// PROJECT_1..3, zone -> ZONE_1..3, numeralBox -> NUMERALBOX_1..4. rig.near
// is a 1-based f64 seq (slot 0 dummy). reframe's `place` closures are a rule
// picked by PL_KIND (params PL_*). Vectors are f32 like Luau's; the math
// between them stays f64 (components cast to f64 before arithmetic).
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import * as track from "../world/track";
import * as level from "../world/level";
import * as R from "../render/renderer";
import * as playerMod from "./player";
import { Player } from "./player";
import { HUGE, lmin, lmax, lclamp, mod } from "../lib/compat";

const RAD: f64 = Math.PI / 180;
@inline function rad(d: f64): f64 {
    return d * RAD;
}

// near plane (m); THE FALLS move it up past the curtain (fallsNear)
const NEAR: f64 = 0.3;
const ZERO: Vector = Vector.xyz(0, 0, 0);

// The scenery probes the game hands the rig (Luau rig.solid / rig.rockNear).
// solid: scenery probe (world point, radius) -> hit; the push-out normal and
// depth in nx / ny / nz / d. rockNear: `solid`'s probes until rockNear(false)
// mostly lie in the xz box: while the scenery still bakes it answers them from
// one near list (the same answers). Returns whether it took the list.
export abstract class RigWorld {
    nx: f64 = 0;
    ny: f64 = 0;
    nz: f64 = 0;
    d: f64 = 0;
    abstract solid(x: f64, y: f64, z: f64, r: f64): bool;
    abstract rockNear(on: bool, minx: f64, minz: f64, maxx: f64, maxz: f64): bool;
}

export class Rig {
    cam: R.Camera = new R.Camera();
    mode: string = "title"; // 'title' | 'briefing' | 'launch' | 'go' | 'chase' | 'hold' | 'results'
    modeT: f64 = 0;
    s: f64 = 0; // chase: rail distance of the eye
    sv: f64 = 0; // chase: eye speed along the rail
    x: f64 = 0;
    y: f64 = 4;
    eye: Vector = Vector.xyz(6, 3, 12);
    look: Vector = Vector.xyz(0, 6, -40);
    fov: f64 = rad(56);
    roll: f64 = 0;
    shake: f64 = 0;
    focusW: f64 = 0;
    focusP: Vector = Vector.xyz(0, 0, 0);
    twist: f64 = 0; // extra roll (portal dive), radians
    fovKick: f64 = 0; // extra fov (radians), decays
    push: f64 = 0; // extra chase distance (m), decays
    visorYaw: f64 = 0;
    visorPitch: f64 = 0;
    visorVy: f64 = 0;
    visorVp: f64 = 0;
    lighthouse: Vector = Vector.xyz(0, 0, 0);
    drift: Vector = Vector.xyz(0, 0, 0); // hold mode: eye velocity, decays
    cut: f64 = 0; // title attract: 0..1 dip to black at shot cuts
    aspect: f64 = 16.0 / 9; // viewport width / height
    holdEye: Vector = Vector.xyz(0, 3, 10); // 'go': where the eye waited while the pilot blasted off
    holdLook: Vector = Vector.xyz(0, 3, -20);
    exitLook: Vector = Vector.xyz(0, 0, 0); // 'hold': optional point the gaze settles on (eye portal)
    exitW: f64 = 0;
    // set-piece beats over the base mode (stings): 'reveal' | 'kill' | 'arch'
    beat: string = "";
    beatT: f64 = 0; // real seconds (the game may be in bullet time)
    beatDur: f64 = 0;
    beatR: f64 = 30; // kill cam: orbit radius
    beatH: f64 = 6; // kill cam: eye height over the target
    beatSide: f64 = 1; // reveal: -1 / +1 side of the pilot
    beatS0: f64 = 0; // arch: rail distance of the pilot when the shot began
    beatTag: string = ""; // reveal: the sting kind ('boss_stormcrow' | 'boss_watcher')
    bossLift: f64 = 0; // boss fights: meters the chase eye rises so the boss rides above the hero
    // scenery probes (Luau solid / rockNear), set by the game; keeps the lens out of rocks
    world: RigWorld? = null;
    // chase lens clearance: eased push-out off the rock (world offset), the
    // raw eye last frame (a jump drops the push)
    clr: Vector = Vector.xyz(0, 0, 0);
    clrPrev: Vector = Vector.xyz(0, 0, 0);
    title: Vector = Vector.xyz(0, 0, 0); // title: where the attract frames
    // death cam ('hold' after a crash, deathHold): the heading frame at the
    // crash, the picked eye slot (DEATH_EYES index, 0 = none yet), re-pick clock
    death: bool = false;
    deathF: Vector = Vector.xyz(0, 0, -1);
    deathR: Vector = Vector.xyz(1, 0, 0);
    deathPick: i32 = 0;
    deathT: f64 = 0;
    // occluders the death cam keeps out of its sight line (enemies, wrecks):
    // x, y, z, radius per entry, `nearN` entries; written by the game (1-based)
    near: Array<f64> = [0.0];
    nearN: i32 = 0;
    // death cam: the eye rides the fall at deathOff from him, his last point
    // and velocity, forced re-pick cooldown
    deathOff: Vector = Vector.xyz(0, 0, 0);
    deathA: Vector = Vector.xyz(0, 0, 0);
    deathV: Vector = Vector.xyz(0, 0, 0);
    deathCd: f64 = 0;
    // chase: the view direction last frame and the mode it was drawn in
    lookDir: Vector = Vector.xyz(0, 0, -1);
    lookMode: string = "";
    lookOm: Vector = Vector.xyz(0, 0, 0); // chase: the view's turn rate last frame (rad / s about this world axis)
    // THE FALLS: the curtain would hide him this frame (set by curtainPull,
    // before update) / did so in the frame last drawn (rockEntry, the draw)
    fallsPull: bool = false;
    fallsLive: bool = false;
    // chase: his rail x / y and their rates last frame (thrOn: valid), the
    // world offset the eye took this frame when a push-out threw him and the
    // rail move it carries into the next frame (see THROW_J)
    thrX: f64 = 0;
    thrY: f64 = 0;
    thrVx: f64 = 0;
    thrVy: f64 = 0;
    thrOn: bool = false;
    thrW: Vector = Vector.xyz(0, 0, 0);
    thrMx: f64 = 0;
    thrMy: f64 = 0;
    faceK: f64 = 0;
    faceOff: Vector = Vector.xyz(0, 0, 0);
    faceSide: f64 = 0; // chase, portrait: the eye's lead toward the way round (rail m, eased)
    lensW: f64 = 0; // chase, portrait: the wide lens's weight (eased; < 0: snap to it next frame)
    lensX: f64 = 0; // chase, portrait: its extra width near rock (eased)
    lean: f64 = 0; // chase, portrait: the more open side ahead near rock (-1 left .. 1 right, eased)
    govA: f64 = 1; // chase, portrait: the hero-size governor's back-off allowance
    govX: f64 = 1; // chase, portrait: its near-rock width allowance (cap on lensX, eased)
    lxUp: f64 = 9; // s since lensX last grew
    lxCut: f64 = 9; // s since the governor last cut lensX
    goT: f64 = 1e9; // s since GO (the portrait lens eases in from GO over GO_LENS_T)
    lensV: f64 = 0; // chase, portrait: the speed the lens goes off at for the next stretch (0: not going)
}

// (Luau reads level.anchors.lighthouse when present: always, in this level)
function lighthousePos(): Vector {
    return level.anchors.lighthouse;
}

export function create(): Rig {
    let c = new Rig();
    let cam = c.cam;
    cam.eye = Vector.xyz(0, 8, 12);
    cam.target = Vector.xyz(0, 6, 0);
    cam.up = Vector.xyz(0, 1, 0);
    cam.fov = rad(60);
    cam.near = NEAR;
    cam.far = 6000;
    c.lighthouse = lighthousePos();
    return c;
}

export function setMode(c: Rig, mode: string): void {
    if (c.mode != mode) {
        c.death = false;
        c.thrOn = false;
        c.thrMx = 0;
        c.thrMy = 0;
        c.mode = mode;
        c.modeT = 0;
        // remember where we were: some modes ease in from here
        c.holdEye = c.eye;
        c.holdLook = c.look;
    }
}

// Launch countdown: two shots, cut on the 1 (a camera beat). Keys: seconds,
// yaw around the pilot, distance (x the fit distance), eye height (m) and
// where his figure sits in its slot (0 low .. 1 high).
class LaunchKey {
    t: f64;
    ang: f64;
    rad: f64;
    h: f64;
    lu: f64;
    constructor(t: f64, ang: f64, rd: f64, h: f64, lu: f64) {
        this.t = t;
        this.ang = ang;
        this.rad = rd;
        this.h = h;
        this.lu = lu;
    }
}
const SHOT_A: Array<LaunchKey> = [
    new LaunchKey(0, 0, 0, 0, 0),
    new LaunchKey(0.0, rad(30), 1.1, 2.4, 0.6),
    new LaunchKey(1.0, rad(22), 1.04, 1.8, 0.5),
    new LaunchKey(2.0, rad(15), 1.0, 1.3, 0.45),
];
const SHOT_B: Array<LaunchKey> = [
    new LaunchKey(0, 0, 0, 0, 0),
    new LaunchKey(2.0, rad(24), 1.0, 0.9, 0.45),
    new LaunchKey(3.0, rad(9), 1.05, 0.6, 0.4),
];
const LAUNCH_CUT: f64 = 2.0;

// returns ang; LK_RAD, LK_H, LK_LU
let LK_RAD: f64 = 0, LK_H: f64 = 0, LK_LU: f64 = 0;
function launchKey(keys: Array<LaunchKey>, t: f64): f64 {
    let n = keys.length - 1;
    if (t <= keys[1].t) {
        let k = keys[1];
        LK_RAD = k.rad;
        LK_H = k.h;
        LK_LU = k.lu;
        return k.ang;
    }
    for (let i = 1; i <= n - 1; i++) {
        let a = keys[i], b = keys[i + 1];
        if (t < b.t) {
            let u = mathx.easeInOutCubic((t - a.t) / (b.t - a.t));
            LK_RAD = mathx.lerp(a.rad, b.rad, u);
            LK_H = mathx.lerp(a.h, b.h, u);
            LK_LU = mathx.lerp(a.lu, b.lu, u);
            return mathx.lerp(a.ang, b.ang, u);
        }
    }
    let k = keys[n];
    LK_RAD = k.rad;
    LK_H = k.h;
    LK_LU = k.lu;
    return k.ang;
}

// Snap the chase rig behind the player (debug starts, restarts).
export function snapChase(c: Rig, p: Player): void {
    // (s < 0: the school lane out at sea; the bay start keeps its old floor)
    c.s = p.s >= 0 ? lmax(0, p.s - 10) : p.s - 10;
    c.sv = p.speed;
    c.x = p.x * 0.7;
    c.y = p.y * 0.72 + 4.8;
    track.frame(level.track, c.s);
    let tp = track.FRAME_P, f = track.FRAME_F, rt = track.FRAME_R, up = track.FRAME_U;
    c.eye = mathx.v3(<f64>tp.x + <f64>rt.x * c.x + <f64>up.x * c.y, <f64>tp.y + <f64>up.y * c.y, <f64>tp.z + <f64>rt.z * c.x + <f64>up.z * c.y);
    c.look = p.pos + f * 24;
    c.lookMode = "";
    c.thrOn = false;
    c.faceK = 0;
    c.faceOff = ZERO;
    c.faceSide = 0;
    c.lensW = -1;
    c.lensX = 0;
    c.lean = 0;
    c.govA = 1;
    c.govX = 1;
    c.goT = 1e9;
    c.lxUp = 9;
    c.lxCut = 9;
    c.lensV = 0;
    setMode(c, "chase");
}

// Freeze the chase: the eye keeps a fraction of the pilot's momentum and
// coasts to a stop while it watches (crash, mission complete).
export function hold(c: Rig, p: Player, carry: f64): void {
    c.eye = c.cam.eye;
    c.drift = p.fwd * <f32>(p.speed * carry);
    c.exitW = 0;
    setMode(c, "hold");
}

// The crash: a clear three-quarter shot from behind and above the fall
// (see deathUpdate), instead of coasting on with the chase lens.
export function deathHold(c: Rig, p: Player): void {
    hold(c, p, 0.7);
    c.death = true;
    let hf = Vector.xyz(p.fwd.x, 0, p.fwd.z);
    let l = mathx.len(hf);
    c.deathF = l > 1e-3 ? hf * <f32>(1 / l) : Vector.xyz(0, 0, -1);
    c.deathR = Vector.xyz(-c.deathF.z, 0, c.deathF.x);
    c.deathPick = 0;
    c.deathT = 0;
    c.deathA = mathx.v3(<f64>p.pos.x, lmax(0.5, <f64>p.pos.y), <f64>p.pos.z);
    c.deathV = p.fwd * <f32>p.speed;
    c.deathCd = 0;
}

// While holding, ease the gaze toward a point (e.g. the portal the pilot dives into).
export function holdGaze(c: Rig, x: f64, y: f64, z: f64, w: f64): void {
    c.exitLook = mathx.v3(x, y, z);
    c.exitW = mathx.saturate(w);
}

// Blast-off: the eye waits a beat where it is while the pilot rockets away,
// then swings into the chase and reels him back in.
export function go(c: Rig, p: Player): void {
    c.holdEye = c.eye;
    c.holdLook = c.look;
    // chase state starts right behind with no speed, so it lags the surge
    c.s = p.s >= 0 ? lmax(0, p.s - 6) : p.s - 6;
    c.sv = 0;
    c.x = p.x;
    c.y = lmax(2.2, p.y + 0.8);
    c.thrOn = false;
    c.goT = 0;
    c.govA = 1;
    c.govX = 1;
    c.faceK = 0;
    c.lxUp = 9;
    c.lxCut = 9;
    c.lensV = 0;
    setMode(c, "go");
}

export function addShake(c: Rig, amount: f64): void {
    c.shake = lmax(c.shake, amount);
}

export function focus(c: Rig, x: f64, y: f64, z: f64, w: f64): void {
    c.focusP = mathx.v3(x, y, z);
    c.focusW = lmax(c.focusW, mathx.saturate(w));
}

// Set-piece beat over the chase (stings): 'reveal' (low shot past the pilot
// up at the boss in focus), 'kill' (KILL CAM: hard cut to an orbit around the
// focus point, hard cut back with an fov punch), 'arch' (low fly-through).
// dur: real seconds. The same beat again only extends it. tag: null = ''.
export function beat(c: Rig, kind: string, dur: f64, p: Player, tag: string? = null): void {
    if (c.beat == kind) {
        c.beatDur = lmax(c.beatDur, c.beatT + dur);
        return;
    }
    c.beat = kind;
    c.beatT = 0;
    c.beatDur = dur;
    c.beatSide = p.x > 0 ? 1 : -1;
    c.beatS0 = p.s;
    c.beatTag = tag != null ? tag : "";
    if (kind == "kill") {
        // the arc sits on the pilot's side of the hull, far enough to hold
        // the whole airship / eye, and sweeps across its rear three-quarter
        let F = c.focusP;
        let e = c.cam.eye;
        let dx = <f64>e.x - <f64>F.x, dz = <f64>e.z - <f64>F.z;
        let d = lmax(1, Math.sqrt(dx * dx + dz * dz));
        c.beatR = mathx.clamp(d * 0.75, 60, 95);
        c.beatH = mathx.clamp((<f64>e.y - <f64>F.y) * 0.3 + 16, 12, 22);
        c.beatSide = (<f64>e.x - <f64>F.x) * <f64>p.right.x + (<f64>e.z - <f64>F.z) * <f64>p.right.z > 0 ? 1 : -1;
    }
}

// Advance the beat clock (real seconds).
export function beatTick(c: Rig, rdt: f64): void {
    if (c.beat == "") return;
    c.beatT += rdt;
    if (c.beatT >= c.beatDur) {
        if (c.beat == "kill") {
            // snap back to the chase with a punch
            c.fovKick = lmax(c.fovKick, rad(14));
            c.shake = lmax(c.shake, 0.6);
        }
        c.beat = "";
    }
}

// End a beat: hard (now) or soft (eases out over ~0.6 s).
export function beatEnd(c: Rig, hard: bool): void {
    if (hard) {
        c.beat = "";
    } else if (c.beat != "") {
        c.beatDur = lmin(c.beatDur, c.beatT + 0.6);
    }
}

function railPoint(s: f64, x: f64, y: f64): Vector {
    track.frame(level.track, s);
    let tp = track.FRAME_P, rt = track.FRAME_R, up = track.FRAME_U;
    return mathx.v3(<f64>tp.x + <f64>rt.x * x + <f64>up.x * y, <f64>tp.y + <f64>up.y * y, <f64>tp.z + <f64>rt.z * x + <f64>up.z * y);
}

// Portrait keeps at least this much horizontal view (bosses, flanks).
const MIN_HFOV: f64 = rad(75);
const MAX_VFOV: f64 = rad(110);

// The vertical fov actually used: narrow (portrait) viewports widen it to keep
// a minimum horizontal field of view.
export function effFov(fov: f64, aspect: f64): f64 {
    let vNeed = 2 * Math.atan(Math.tan(MIN_HFOV * 0.5) / lmax(aspect, 0.3));
    return lmax(fov, lmin(vNeed, MAX_VFOV));
}

// PORTRAIT LENS (chase only; aspect < 1, none in a boss fight, a beat, the
// launch / GO cards, the death cam or the outro): the chase keeps at least
// LENS_HFOV across (vertical up to LENS_VCAP), LENS_HFOV_X near rock
// (c.lensX), weighted by c.lensW.
const LENS_HFOV: f64 = rad(86), LENS_HFOV_X: f64 = rad(92);
const LENS_VCAP: f64 = rad(128), LENS_VCAP_X: f64 = rad(134);
// (eased: in / out per s; near rock in / out)
const LENS_IN: f64 = 1.2, LENS_OUT: f64 = 3, LENS_X_IN: f64 = 0.8, LENS_X_OUT: f64 = 0.25;
// the most the lens changes the drawn fov (rad / s) while it eases in / out
// or widens near rock; going out it is off LENS_OFF_BY m past a stretch's end
// at any speed
const LENS_RATE: f64 = rad(4.5), LENS_OFF_BY: f64 = 45;
// after GO the lens eases in over GO_LENS_T s from GO (accelerating over
// the first and braking over the last GO_LENS_A of it, steady between)
const GO_LENS_T: f64 = 2.5, GO_LENS_A: f64 = 0.25;
// HERO-SIZE GOVERNOR (portrait lens): gives up first the face back-off, then
// the near-rock width, so his drawn height (GOV_HERO_H m) stays at GOV_FLOOR
// of the screen height or more. The allowances ease down at GOV_DOWN / s (the
// width at GOV_X_DOWN / s) and back at GOV_UP / s; the width comes back only
// with him GOV_X_BAND over the floor, and is not cut within GOV_X_HOLD s of
// widening (nor widens within it of a cut).
const GOV_HERO_H: f64 = 2.69, GOV_FLOOR: f64 = 0.082, GOV_X_BAND: f64 = 0.06, GOV_X_HOLD: f64 = 1;
const GOV_DOWN: f64 = 8, GOV_X_DOWN: f64 = 3, GOV_UP: f64 = 1.5;
// before a touch faceBack's side lead takes the more open side ahead: blocked
// points at his height LEAN_DS m on, LEAN_DX m either side of him; c.lean =
// (left - right) / all, eased at LEAN_K / s, x LEAN_SIDE (capped at 1)
const LEAN_K: f64 = 1.5, LEAN_SIDE: f64 = 2;
const LEAN_DS: Array<f64> = [0.0, 12, 24];
const LEAN_DX: Array<f64> = [0.0, 5, 10, 15];

// The vertical fov of the lens at weight w, near-rock width x.
function lensFovAt(aspect: f64, fov: f64, w: f64, x: f64): f64 {
    let v = effFov(fov, aspect);
    if (w <= 0) return v;
    let h = MIN_HFOV + (LENS_HFOV - MIN_HFOV + (LENS_HFOV_X - LENS_HFOV) * x) * w;
    let need = 2 * Math.atan(Math.tan(h * 0.5) / lmax(aspect, 0.3));
    return lmax(v, lmin(need, MAX_VFOV + (LENS_VCAP - MAX_VFOV + (LENS_VCAP_X - LENS_VCAP) * x) * w));
}

// The lens weight (0..1) that draws at vertical fov F, near-rock width x
// (lensFovAt inverted).
function lensWAt(aspect: f64, fov: f64, F: f64, x: f64): f64 {
    if (F <= effFov(fov, aspect)) return 0;
    let h = 2 * Math.atan(Math.tan(F * 0.5) * lmax(aspect, 0.3));
    let wN = (h - MIN_HFOV) / (LENS_HFOV - MIN_HFOV + (LENS_HFOV_X - LENS_HFOV) * x);
    let wC = (F - MAX_VFOV) / (LENS_VCAP - MAX_VFOV + (LENS_VCAP_X - LENS_VCAP) * x);
    return mathx.saturate(lmax(wN, wC));
}

// The vertical fov the chase draws with (effFov widened by the lens).
function lensFov(c: Rig, fov: f64): f64 {
    return lensFovAt(c.aspect, fov, c.lensW, c.lensX);
}

// The hero's drawn height as a share of the screen height (the painted
// figure, GOV_HERO_H, on his camera-facing sprite at P) for the final camera.
export function heroH(c: Rig, P: Vector): f64 {
    let cam = c.cam;
    let z = mathx.dot(P - cam.eye, mathx.norm(cam.target - cam.eye));
    if (z < 0.5) return 1;
    return GOV_HERO_H / (2 * z * Math.tan(cam.fov * 0.5));
}

// An ease 0..1 over x in 0..1: accelerating over the first a of it,
// braking over the last a, steady between (the GO ease).
function rampEase(x: f64, a: f64): f64 {
    x = mathx.saturate(x);
    let vm = 1 / (1 - a);
    if (x < a) {
        return vm * x * x / (2 * a);
    } else if (x > 1 - a) {
        return 1 - vm * (1 - x) * (1 - x) / (2 * a);
    }
    return vm * (x - a * 0.5);
}

// HERO SAFE ZONE (DIRECTION #16) in NDC (x right, y up): landscape x 0.30-0.70,
// y 0.42-0.72 of the screen; portrait x 0.25-0.75, y 0.34-0.58. Returns the
// half width (ZONE_1) and the low / high y (ZONE_2 / ZONE_3); near-square
// viewports blend the two.
export let ZONE_1: f64 = 0;
export let ZONE_2: f64 = 0;
export let ZONE_3: f64 = 0;
export function zone(aspect: f64): f64 {
    let k = mathx.saturate((1.15 - aspect) / 0.35);
    ZONE_1 = mathx.lerp(0.4, 0.5, k);
    ZONE_2 = mathx.lerp(-0.44, -0.16, k);
    ZONE_3 = mathx.lerp(0.16, 0.32, k);
    return ZONE_1;
}

const Y: Vector = Vector.xyz(0, 1, 0);

// View basis of an eye looking at a point, rolled like the final camera:
// VB_F, VB_RT, VB_UP.
let VB_F: Vector = ZERO, VB_RT: Vector = ZERO, VB_UP: Vector = ZERO;
function viewBasis(eye: Vector, look: Vector, roll: f64): void {
    let f = mathx.norm(look - eye);
    let rt = mathx.norm(mathx.cross(f, Y));
    let up = mathx.cross(rt, f);
    if (roll != 0) {
        up = mathx.rotateAxis(up, f, roll);
        rt = mathx.cross(f, up);
    }
    VB_F = f;
    VB_RT = rt;
    VB_UP = up;
}

// Screen position (NDC, y up) and depth of P for that view: returns x;
// NDC_Y, NDC_Z.
let NDC_Y: f64 = 0, NDC_Z: f64 = 0;
function ndcOf(eye: Vector, f: Vector, rt: Vector, up: Vector, th: f64, aspect: f64, P: Vector): f64 {
    let d = P - eye;
    let z = mathx.dot(d, f);
    if (z < 0.3) {
        NDC_Y = 0;
        NDC_Z = z;
        return 0;
    }
    NDC_Y = mathx.dot(d, up) / (z * th);
    NDC_Z = z;
    return mathx.dot(d, rt) / (z * th * aspect);
}

// Soft limit: identity inside [lo + m, hi - m], easing asymptotically to lo / hi.
function soft(v: f64, lo: f64, hi: f64, m: f64): f64 {
    if (lo > hi) return (lo + hi) * 0.5;
    m = lmin(m, (hi - lo) * 0.5);
    if (m <= 1e-4) return mathx.clamp(v, lo, hi);
    if (v > hi - m) {
        return hi - m + m * Math.tanh((v - (hi - m)) / m);
    } else if (v < lo + m) {
        return lo + m - m * Math.tanh((lo + m - v) / m);
    }
    return v;
}

// reframe's `place` (Luau closures place(nx, ny, hw, hh) -> tx, ty): the rule
// PL_KIND with params PL_A..PL_D, PL_M; result PL_TX, PL_TY.
const PL_ZONE: i32 = 0; // soft zone (A hx, B y0, C y1, M margin scale)
const PL_RIDE: i32 = 1; // nx, A
const PL_FIT: i32 = 2; // soft(nx, -A, A, 0.1), ny
const PL_SLOT: i32 = 3; // soft slot (A x0, B x1, C y0, D y1)
const PL_AT: i32 = 4; // A, B
let PL_KIND: i32 = 0;
let PL_A: f64 = 0, PL_B: f64 = 0, PL_C: f64 = 0, PL_D: f64 = 0, PL_M: f64 = 0;
let PL_TX: f64 = 0, PL_TY: f64 = 0;
function place(nx: f64, ny: f64, hw: f64, hh: f64): void {
    if (PL_KIND == PL_ZONE) {
        PL_TX = soft(nx, -PL_A + hw, PL_A - hw, 0.12 * PL_M);
        PL_TY = soft(ny, PL_B + hh, PL_C - hh, 0.1 * PL_M);
    } else if (PL_KIND == PL_RIDE) {
        PL_TX = nx;
        PL_TY = PL_A;
    } else if (PL_KIND == PL_FIT) {
        PL_TX = soft(nx, -PL_A, PL_A, 0.1);
        PL_TY = ny;
    } else if (PL_KIND == PL_SLOT) {
        PL_TX = soft(nx, PL_A + HERO_W * hw, PL_B - HERO_W * hw, 0.04);
        PL_TY = soft(ny, PL_C + HERO_DN * hh, PL_D - HERO_UP * hh, 0.04);
    } else {
        PL_TX = PL_A;
        PL_TY = PL_B;
    }
}

// Turn the view (move the look point) so P lands where `place` (PL_*) wants
// it on screen. Two passes converge well enough for the small angles involved.
function reframe(eye: Vector, look: Vector, P: Vector, extent: f64, roll: f64, fov: f64, aspect: f64): Vector {
    let th = Math.tan(fov * 0.5);
    for (let pass = 0; pass < 2; pass++) {
        viewBasis(eye, look, roll);
        let f = VB_F, rt = VB_RT, up = VB_UP;
        let nx = ndcOf(eye, f, rt, up, th, aspect, P);
        let ny = NDC_Y, z = NDC_Z;
        if (z < 0.5) return look;
        let hh = extent / (z * th);
        place(nx, ny, hh / aspect, hh);
        let tx = PL_TX, ty = PL_TY;
        if (Math.abs(tx - nx) < 1e-4 && Math.abs(ty - ny) < 1e-4) return look;
        let D = mathx.len(look - eye);
        look = look + rt * <f32>((nx - tx) * th * aspect * D) + up * <f32>((ny - ty) * th * D);
    }
    return look;
}

// Keep P (with its half extent in meters) inside the hero safe zone.
const HERO_EXTENT: f64 = 1.05;
// boss fights: where the boss focus rides on screen (NDC y, under the HUD's
// boss stack)
const BOSS_Y: f64 = 0.2;
// boss fights: the highest the horizon may ride (NDC y) when a dive leaves
// the eye above him (it caps the eye's height over him)
const HORIZON_Y: f64 = 0.4;
// boss fights: meters the eye may lag above the height the framing wants
const EYE_LAG: f64 = 1.0;
function clampToZone(c: Rig, P: Vector, look: Vector, hard: bool = false): Vector {
    zone(c.aspect);
    PL_KIND = PL_ZONE;
    PL_A = ZONE_1;
    PL_B = ZONE_2;
    PL_C = ZONE_3;
    PL_M = hard ? 0 : 1;
    return reframe(c.eye, look, P, HERO_EXTENT, c.roll + c.twist, lensFov(c, c.fov), c.aspect);
}

// Chase: the most the view turns per second; only the zone's hard edge turns
// it faster (by at most HARD_OM: hardEdge).
const TURN_MAX: f64 = rad(240);
// ... and its turn rate changes by at most TURN_ACC a second, bar that hard
// edge. The rate is kept in rad / s (c.lookOm) and brakes to a stop at the
// target (no overshoot for the hard edge to snap back).
const TURN_ACC: f64 = rad(7200);

// Chase turn cap: the view direction this frame toward unit target T
// (TR_HELD: it stopped short). The rate c.lookOm changes by at most TURN_ACC
// dt, stays under TURN_MAX and under what still stops at T (sqrt(2 TURN_ACC
// angle)); a flip is not capped. c.lookOm itself is set from the turn
// actually drawn (update).
let TR_HELD: bool = false;
function turnRate(c: Rig, T: Vector, dt: f64): Vector {
    let a = c.lookDir;
    let ax = mathx.cross(a, T);
    let sl = mathx.len(ax);
    let ang = Math.atan2(sl, mathx.dot(a, T));
    if (ang >= 3) {
        TR_HELD = false;
        return T;
    }
    // (only the part of last frame's rate that turns this direction)
    let om = c.lookOm;
    om = om - a * <f32>mathx.dot(om, a);
    let want = ZERO;
    let full = true;
    if (sl > 1e-9) {
        let r = ang / dt;
        let rb = lmin(TURN_MAX, Math.sqrt(2 * TURN_ACC * ang));
        if (r > rb) {
            r = rb;
            full = false;
        }
        want = ax * <f32>(r / sl);
    }
    let dv = want - om;
    let dl = mathx.len(dv);
    let lim = TURN_ACC * dt;
    if (dl > lim) {
        om = om + dv * <f32>(lim / dl);
        full = false;
    } else {
        om = want;
    }
    let ol = mathx.len(om);
    if (ol > TURN_MAX) {
        om = om * <f32>(TURN_MAX / ol);
        ol = TURN_MAX;
        full = false;
    }
    if (full) {
        TR_HELD = false;
        return T;
    }
    TR_HELD = true;
    if (ol < 1e-9) return a;
    return mathx.norm(mathx.rotateAxis(a, om / <f32>ol, ol * dt));
}

// Chase: a scrape's push-out throws him up to ~5.8 m across, or up, in one
// frame. The eye (and the gaze, a pure slide) takes only the part that would
// jump him more than THROW_J (NDC; THROW_JIN back toward the zone's middle)
// across the screen or past the zone's hard edge, less what the turn cap
// still allows, up to THROW_MAX m, and carries THROW_KEEP of it into the next
// frame (never past the follow's target). A throw is his move past what last
// frame's rates carry him (< THROW_DEAD m).
const THROW_MAX: f64 = 2.2, THROW_DEAD: f64 = 0.3;
const THROW_J: f64 = 0.4, THROW_JIN: f64 = 0.55, THROW_KEEP: f64 = 0.5;
// Chase: the most the eye travels per second; only the hard margin moves it
// further
const STEP_V: f64 = 150;

// Look target that puts P at screen offset (ox, oy) (NDC, y up) from an eye.
function frameAt(eye: Vector, P: Vector, ox: f64, oy: f64, aspect: f64, fov0: f64): Vector {
    let fov = effFov(fov0, aspect);
    let d = P - eye;
    let dist = lmax(0.1, mathx.len(d));
    let f = d / <f32>dist;
    let rt = mathx.norm(mathx.cross(f, Vector.xyz(0, 1, 0)));
    let up = mathx.cross(rt, f);
    let th = Math.tan(fov * 0.5);
    return P - rt * <f32>(ox * th * aspect * dist) - up * <f32>(oy * th * dist);
}

// Lens clearance: the chase lens keeps CHASE_CLEAR m from any collider (>= ~2.6
// m off box rock at CHASE_HARD) and its sight line to him LINE_CLEAR m (bar
// the LINE_SKIP m next to him): pushed out along the collider normal, the line
// by swinging the eye about him, eased so it never pops; CHASE_HARD holds at
// once. Portrait (aspect <= 0.8, blended up to 1.3) keeps the lens further off
// (_P). The death cam scores with LENS_*.
const LENS_CLEAR: f64 = 4.2, LENS_HARD: f64 = 3.4, LINE_CLEAR: f64 = 4;
const CHASE_CLEAR: f64 = 5.2, CHASE_HARD: f64 = 4.4, LINE_SKIP: f64 = 4;
const CHASE_CLEAR_P: f64 = 6.6, CHASE_HARD_P: f64 = 5.8;
// the most the clearance swings the lens across its line to him (as a turn
// of his bearing, rad / s), and how far ahead (s of the pose's own travel, at
// most CLR_REACH of the way to him) the push-out is also found from
const CLR_OM: f64 = rad(150), CLR_LEAD: f64 = 0.25, CLR_REACH: f64 = 0.8;
// the most the clearance backs the lens off along its line to him (m); past
// it the push goes across, toward the flight box's middle
const CLR_BACK: f64 = 6;
// how far the rendered rock may reach past a collider (rockEntry): box
// faces, ~1.8 m (p90) + 0.6
export const ROCK_JUT: f64 = 2.4;

// The chase lens margins for this aspect: returns clear; CM_HARD.
let CM_HARD: f64 = 0;
function chaseMargins(c: Rig): f64 {
    let tall = mathx.saturate((1.3 - c.aspect) / 0.5);
    CM_HARD = mathx.lerp(CHASE_HARD, CHASE_HARD_P, tall);
    return mathx.lerp(CHASE_CLEAR, CHASE_CLEAR_P, tall);
}

// Offset that moves E to r m clear of every collider (a few push-outs).
function pushOut(c: Rig, E: Vector, r: f64): Vector {
    let w = c.world;
    let off = ZERO;
    if (w != null) {
        for (let i = 0; i < 4; i++) {
            let q = E + off;
            if (!w.solid(<f64>q.x, <f64>q.y, <f64>q.z, r)) break;
            off = off + mathx.v3(w.nx, w.ny, w.nz) * <f32>(w.d + 0.03);
        }
    }
    return off;
}

// Swing that clears the sight line from P to the eye E (samples from
// LINE_SKIP m off him out to the lens): a hit at fraction k of the way moves
// the eye depth / k along its normal, across the line.
function lineOut(c: Rig, P: Vector, E: Vector): Vector {
    let w = c.world;
    let d = E - P;
    let len = mathx.len(d);
    if (w == null || len < LINE_SKIP + 0.5) return ZERO;
    let dir = d * <f32>(1 / len);
    let best = ZERO, bestL = 0.0;
    let k0 = LINE_SKIP / len;
    for (let i = 0; i <= 4; i++) {
        let k = k0 + (1 - k0) * <f64>i / 5;
        let q = P + d * <f32>k;
        if (w.solid(<f64>q.x, <f64>q.y, <f64>q.z, LINE_CLEAR)) {
            let dep = w.d;
            let n = mathx.v3(w.nx, w.ny, w.nz);
            // (only the part across the line moves it off the rock)
            n = n - dir * <f32>mathx.dot(n, dir);
            let nl = mathx.len(n);
            if (nl > 0.2) {
                let m = lmin(6, (dep + 0.05) / (k * nl));
                if (m > bestL) {
                    best = n * <f32>(m / nl);
                    bestL = m;
                }
            }
        }
    }
    return best;
}

// The chase eye E kept clear of rock, and its view of him at P (see
// CHASE_CLEAR). hasLast / last: Luau's optional `last` eye.
function clearEye(c: Rig, E: Vector, P: Vector, dt: f64, hasLast: bool, last: Vector): Vector {
    // (the pose's own travel, without faceBack's back-off; with the portrait
    // lens only, like the back-off cap and the slide in game time below)
    let tallC = c.lensW > 0;
    let E0 = tallC ? E - c.faceOff : E;
    let prev = c.clrPrev;
    c.clrPrev = E0;
    let w = c.world;
    if (w == null || dt <= 0) return E;
    if (mathx.len(E0 - prev) > 12) {
        // a jump (restart, debug start): no stale push, no turn or step cap
        c.clr = ZERO;
        c.lookMode = "";
        hasLast = false;
    }
    // (stateful: the push is found from where the lens is, not from the
    // chase pose, which may lie deep in the rock he passes)
    let clear = chaseMargins(c);
    let hard = CM_HARD;
    let off0 = c.clr;
    let off = mathx.vdamp(off0, ZERO, 2.5, dt);
    let out = E + off;
    // (no line swing while a push-out has him inside the rock)
    let want = w.solid(<f64>P.x, <f64>P.y, <f64>P.z, 0.1) ? ZERO : lineOut(c, P, out);
    want = want + pushOut(c, out + want, clear);
    let L0 = P - (E + off0);
    let l0 = mathx.len(L0);
    let u = l0 > 1 ? L0 / <f32>l0 : ZERO;
    if (hasLast && l0 > 1) {
        // (the swing also found where the lens is going, CLR_LEAD s on but no
        // further than CLR_REACH of the way to him; only its part across the
        // line)
        let lead = (E0 - prev) * <f32>(CLR_LEAD / dt);
        let la = mathx.dot(lead, u);
        if (la > l0 * CLR_REACH) lead = lead - u * <f32>(la - l0 * CLR_REACH);
        let wA = pushOut(c, out + lead, clear);
        wA = wA - u * <f32>mathx.dot(wA, u);
        let wa = mathx.dot(want, u);
        let wP = want - u * <f32>wa;
        if (mathx.dot(wA, wA) > mathx.dot(wP, wP)) want = wA + u * <f32>wa;
    }
    off = off + want * <f32>(1 - Math.exp(-16 * dt));
    // (along the pose's own line to him: the lens may already sit off to
    // the side, where its line to him runs across the rail)
    let LE = P - E;
    let le = mathx.len(LE);
    let uE = le > 1 ? LE / <f32>le : ZERO;
    let back = -mathx.dot(off, uE);
    if (tallC && le > 1 && back > CLR_BACK) {
        track.frame(level.track, c.s);
        let trt = track.FRAME_R;
        let side = trt - uE * <f32>mathx.dot(trt, uE);
        let sl = mathx.len(side);
        off = off + uE * <f32>(back - CLR_BACK);
        if (sl > 0.1) {
            // (the way it already swings, else toward the box's middle)
            let ox = mathx.dot(off, side) / sl;
            let sg = Math.abs(ox) > 0.5 ? mathx.sign(ox) : c.x > 0 ? -1.0 : 1.0;
            off = off + side * <f32>(sg * (back - CLR_BACK) / sl);
        }
    }
    if (hasLast && l0 > 1) {
        // (across his line the offset turns the view: capped at CLR_OM of
        // bearing; toward / away from him it is free)
        let d = off - off0;
        let along = u * <f32>mathx.dot(d, u);
        let perp = d - along;
        let pl = mathx.len(perp);
        let lim = l0 * Math.tan(CLR_OM * dt);
        if (pl > lim) off = off0 + along + perp * <f32>(lim / pl);
    }
    out = E + off;
    if (hasLast) {
        let mv = out - last;
        let l = mathx.len(mv);
        if (l > STEP_V * dt) out = last + mv * <f32>(STEP_V * dt / l);
    }
    out = out + pushOut(c, out, hard);
    c.clr = out - E;
    return out;
}

// THE FALLS: the curtain (a sheet poured from the bridge at fallsS, at flying
// height ~17.9 m before it) spans the gate. While it stands between the lens
// and him, the near plane moves up to just past it (never into him, nor into
// the sea at the bottom of the view). While his own sprite is in the sheet
// (curtainPull) he is drawn in front of it and the near plane stays.
const FALLS_BACK: f64 = 17.9, FALLS_HALF: f64 = 1.0, FALLS_MAX: f64 = 12;
const FALLS_FACE: f64 = FALLS_HALF + 0.5;
// (the hero sprite's half size: from this far short of the near face it may
// dip into the sheet)
const HERO_HALF: f64 = 1.7;
// (Luau fallsQ is nil without anchors.fallsS: this level always has it)
let fallsQ: Vector = ZERO, fallsN: Vector = ZERO;
function fallsInit(): bool {
    track.frame(level.track, level.anchors.fallsS);
    let tp = track.FRAME_P, f = track.FRAME_F;
    fallsN = mathx.norm(Vector.xyz(f.x, 0, f.z));
    fallsQ = tp - fallsN * <f32>FALLS_BACK;
    return true;
}
const FALLS_ON: bool = fallsInit();

// Distance from E along its line to P where it meets the sheet's near face,
// or HUGE (E past it, or P short of it).
function fallsEntry(E: Vector, P: Vector): f64 {
    if (!FALLS_ON) return HUGE;
    let Q = fallsQ;
    let dE = mathx.dot(E - Q, fallsN), dP = mathx.dot(P - Q, fallsN);
    if (dE >= -FALLS_FACE || dP <= -FALLS_FACE) return HUGE;
    return mathx.len(P - E) * (-FALLS_FACE - dE) / (dP - dE);
}

// Distance from the lens E along its sight line to P where the line first
// comes within `jut` m of a collider (rock drawn there may hide him), or HUGE.
// In the frames THE FALLS curtain would hide him (curtainPull) also where the
// line meets the sheet.
export function rockEntry(c: Rig, E: Vector, P: Vector, jut: f64): f64 {
    let fe = c.fallsLive ? fallsEntry(E, P) : HUGE;
    let w = c.world;
    let d = P - E;
    let len = mathx.len(d);
    if (w == null || len < 0.5) return fe;
    let n = Math.ceil(len / 0.5);
    // (a probe every 0.5 m: one near list for the segment while the scenery
    // bakes, rockNear)
    let on = w.rockNear(true, lmin(<f64>E.x, <f64>P.x) - jut - 0.1, lmin(<f64>E.z, <f64>P.z) - jut - 0.1, lmax(<f64>E.x, <f64>P.x) + jut + 0.1, lmax(<f64>E.z, <f64>P.z) + jut + 0.1);
    let hitI = -1.0;
    for (let i = 0.0; i <= n; i++) {
        let q = E + d * <f32>(i / n);
        if (w.solid(<f64>q.x, <f64>q.y, <f64>q.z, jut)) {
            hitI = i;
            break;
        }
    }
    if (on) w.rockNear(false, 0, 0, 0, 0);
    if (hitI >= 0) return lmin(fe, len * lmax(0, hitI - 1) / n);
    return fe;
}

// Chase: past the turn cap only the zone's hard edge turns the view, by at
// most HARD_OM more (rad / s); the rest is an eye slide (the gaze by the same
// offset: no turn), up to HARD_SLIDE m / s (game time), carried in the
// clearance offset (c.clr). Only what a slide cannot do (into rock) turns.
const HARD_OM: f64 = rad(120), HARD_SLIDE: f64 = 72;
// (landscape keeps its per-frame slide, m)
const HARD_SLIDE_L: f64 = 1.2;

// The look after the turn cap held it at unit dir (d m off): the hard edge.
function hardEdge(c: Rig, P: Vector, dir: Vector, d: f64, dt: f64): void {
    let hardL = clampToZone(c, P, c.look, true);
    let hd = mathx.norm(hardL - c.eye);
    let ang = Math.acos(lclamp(mathx.dot(dir, hd), -1, 1));
    let cap = HARD_OM * dt;
    if (ang <= cap || ang >= 3) {
        c.look = hardL;
        return;
    }
    let ax = mathx.cross(dir, hd);
    let dir2 = mathx.rotateAxis(dir, mathx.norm(ax), cap);
    let look = c.eye + dir2 * <f32>d;
    let th = Math.tan(lensFov(c, c.fov) * 0.5);
    viewBasis(c.eye, look, c.roll + c.twist);
    let f = VB_F, rt = VB_RT, up = VB_UP;
    let nx = ndcOf(c.eye, f, rt, up, th, c.aspect, P);
    let ny = NDC_Y, z = NDC_Z;
    if (z < 1) {
        c.look = hardL;
        return;
    }
    let hx = zone(c.aspect), y0 = ZONE_2, y1 = ZONE_3;
    let hh = HERO_EXTENT / (z * th);
    let hw = hh / c.aspect;
    let ex = nx - mathx.clamp(nx, -hx + hw, hx - hw);
    let ey = ny - mathx.clamp(ny, y0 + hh, lmax(y0 + hh, y1 - hh));
    let sl = rt * <f32>(ex * z * th * c.aspect) + up * <f32>(ey * z * th);
    let l = mathx.len(sl);
    let slMax = c.lensW > 0 ? HARD_SLIDE * dt : HARD_SLIDE_L;
    if (l > slMax) sl = sl * <f32>(slMax / l);
    let e1 = c.eye + sl;
    chaseMargins(c);
    let hard = CM_HARD;
    let w = c.world;
    if (w != null && w.solid(<f64>e1.x, <f64>e1.y, <f64>e1.z, hard)) {
        c.look = hardL;
        return;
    }
    c.eye = e1;
    c.clr = c.clr + sl;
    c.look = clampToZone(c, P, look + sl, true);
}

// A throw (tx, ty rail m) this frame: the eye (and the gaze, c.thrW) takes
// its share (see THROW_J), judged from the view as it stands this frame.
// Returns the eye.
function throwWindow(c: Rig, p: Player, eye: Vector, look: Vector, tx: f64, ty: f64, boss: f64, dt: f64): Vector {
    let E = eye + c.clr;
    let L = mathx.vdamp(c.look, look, 10 + 8 * boss, dt);
    let th = Math.tan(lensFov(c, c.fov) * 0.5);
    viewBasis(E, L, c.roll + c.twist);
    let f = VB_F, rt = VB_RT, up = VB_UP;
    let nx = ndcOf(E, f, rt, up, th, c.aspect, p.pos);
    let ny = NDC_Y, z = NDC_Z;
    if (z < 1) return eye;
    track.frame(level.track, p.s);
    let prt = track.FRAME_R, pup = track.FRAME_U;
    let nx0 = ndcOf(E, f, rt, up, th, c.aspect, p.pos - prt * <f32>tx - pup * <f32>ty);
    let ny0 = NDC_Y;
    let hx = zone(c.aspect), y0 = ZONE_2, y1 = ZONE_3;
    let hh = HERO_EXTENT / (z * th);
    let hw = hh / c.aspect;
    // (a throw back toward the zone's middle is mostly his)
    let jx = Math.abs(nx) > Math.abs(nx0) ? THROW_J : THROW_JIN;
    let jy = Math.abs(ny - (y0 + y1) * 0.5) > Math.abs(ny0 - (y0 + y1) * 0.5) ? THROW_J : THROW_JIN;
    let ex = nx - mathx.clamp(nx, lmin(lmax(-hx + hw, nx0 - jx), nx0), lmax(lmin(hx - hw, nx0 + jx), nx0));
    let ey = ny - mathx.clamp(ny, lmin(lmax(y0 + hh, ny0 - jy), ny0), lmax(lmin(y1 - hh, ny0 + jy), ny0));
    if (ex == 0 && ey == 0) return eye;
    // (first what the turn cap still allows this frame)
    if (c.lookMode == "chase") {
        let rot = TURN_MAX * dt - Math.acos(lclamp(mathx.dot(mathx.norm(L - E), c.lookDir), -1, 1));
        let tx0 = th * c.aspect, ty0 = th;
        let ax = Math.atan(nx * tx0) - Math.atan((nx - ex) * tx0);
        let ay = Math.atan(ny * ty0) - Math.atan((ny - ey) * ty0);
        let a = Math.sqrt(ax * ax + ay * ay);
        if (a <= rot) {
            return eye;
        } else if (rot > 0) {
            ex *= 1 - rot / a;
            ey *= 1 - rot / a;
        }
    }
    let d = rt * <f32>(ex * z * th * c.aspect) + up * <f32>(ey * z * th);
    let l = mathx.len(d);
    if (l > THROW_MAX) d = d * <f32>(THROW_MAX / l);
    track.frame(level.track, c.s);
    let trt = track.FRAME_R, tup = track.FRAME_U;
    let rx = mathx.dot(d, trt), ry = mathx.dot(d, tup);
    c.x += rx;
    c.y += ry;
    c.thrMx = rx * THROW_KEEP;
    c.thrMy = ry * THROW_KEEP;
    let e1 = railPoint(c.s, c.x, c.y) + c.faceOff;
    c.thrW = c.thrW + (e1 - eye);
    return e1;
}

// Chase, held at a face / rock filling the view near him: the eye backs off
// along its line to him (FACE_BACK m, portrait FACE_BACK_P) and rises FACE_UP
// m (eased in at FACE_IN / s, out at FACE_OUT / s; not out while he is held),
// none in a boss fight. Not held, it backs off by how much of the view meets
// rock near the lens: from FACE_FILL0 to FACE_FILL1 of 3 x 3 rays (NDC +-0.6,
// probed FACE_STEPS m out, collider + FACE_JUT), looked at while he grazes or
// the lens is pushed off.
const FACE_BACK: f64 = 1.5, FACE_BACK_P: f64 = 3.5, FACE_UP: f64 = 1.75;
// (with the portrait lens, x c.lensW: the face back-off ahead of the touch)
const FACE_BACK_L: f64 = 5.5;
const FACE_IN: f64 = 10, FACE_OUT: f64 = 2;
// (the eye's own speed sheds toward his rail progress at FACE_SV x (1 -
// railK) / s more: held, it stops within ~1 m)
const FACE_SV: f64 = 45;
const FACE_FILL0: f64 = 0.3, FACE_FILL1: f64 = 0.55, FACE_JUT: f64 = 0.8;
const FACE_STEPS: Array<f64> = [0.0, 4, 7, 10];
const FACE_NDC: Array<f64> = [0.0, -0.6, 0, 0.6];
// portrait: a head-on touch FACE_AHEAD s or less ahead on his line (probed
// every FACE_DT s) backs it off already
const FACE_AHEAD: f64 = 0.42, FACE_DT: f64 = 0.07;
// (eased in at FACE_IN_A / s)
const FACE_IN_A: f64 = 6;
// portrait, held: the eye also leads him FACE_SIDE m toward the way round
// (p.hitSide; x faceK), eased at FACE_SIDE_K / s
const FACE_SIDE: f64 = 4, FACE_SIDE_K: f64 = 5;

// Share of the last frame's view (3 x 3 rays) that meets rock within 10 m.
function viewFill(c: Rig): f64 {
    let w = c.world;
    if (w == null) return 0;
    let cam = c.cam;
    let E = cam.eye;
    let f = mathx.norm(cam.target - E);
    let rt = mathx.norm(mathx.cross(f, cam.up));
    let up = mathx.cross(rt, f);
    let th = Math.tan(cam.fov * 0.5);
    let n = 0.0;
    for (let iv = 1; iv <= 3; iv++) {
        let v = FACE_NDC[iv];
        for (let iu = 1; iu <= 3; iu++) {
            let u = FACE_NDC[iu];
            let d = mathx.norm(f + rt * <f32>(u * th * c.aspect) + up * <f32>(v * th));
            for (let ik = 1; ik <= 3; ik++) {
                let q = E + d * <f32>FACE_STEPS[ik];
                if (q.y > 0 && w.solid(<f64>q.x, <f64>q.y, <f64>q.z, FACE_JUT)) {
                    n += 1;
                    break;
                }
            }
        }
    }
    return n / 9;
}

// True when his line (carried on at this frame's rates) touches rock within
// FACE_AHEAD s.
function faceAhead(c: Rig, p: Player): bool {
    let w = c.world;
    if (w == null || !p.alive) return false;
    let v = p.speed * p.railK;
    let t = FACE_DT;
    while (t <= FACE_AHEAD + 1e-6) {
        let q = railPoint(lmin(p.s + v * t, level.track.length - 1), p.x + p.vx * t, p.y + p.vy * t);
        if (q.y > 0 && w.solid(<f64>q.x, <f64>q.y, <f64>q.z, playerMod.RADIUS + 0.2)) return true;
        t += FACE_DT;
    }
    return false;
}

// governor's closures (zth / backMax / widthMax) read these
let G_ASPECT: f64 = 0, G_FOV: f64 = 0, G_W: f64 = 0, G_OY: f64 = 0;
let G_D: Vector = ZERO, G_OFF: Vector = ZERO;
function zth(a: f64, x: f64): f64 {
    let th = Math.tan(lensFovAt(G_ASPECT, G_FOV, G_W, x) * 0.5);
    return mathx.len(G_D - G_OFF * <f32>a) * th / Math.sqrt(1 + G_OY * G_OY * th * th);
}
// the most back-off (x off) with the hero at the floor at width x
function backMax(x: f64, zMax: f64): f64 {
    if (zth(0, x) >= zMax) return 0;
    if (zth(1, x) <= zMax) return 1;
    let lo = 0.0, hi = 1.0;
    for (let i = 0; i < 10; i++) {
        let m = (lo + hi) * 0.5;
        if (zth(m, x) > zMax) hi = m;
        else lo = m;
    }
    return lo;
}
// the most near-rock width with no back-off and the hero at depth zM
function widthMax(zM: f64): f64 {
    if (zth(0, 1) <= zM) return 1;
    if (zth(0, 0) >= zM) return 0;
    let lo = 0.0, hi = 1.0;
    for (let i = 0; i < 10; i++) {
        let m = (lo + hi) * 0.5;
        if (zth(0, m) > zM) hi = m;
        else lo = m;
    }
    return lo;
}

// The hero-size governor (portrait lens; see GOV_FLOOR): eases c.govA and
// c.govX toward what keeps his drawn height at GOV_FLOOR of the screen
// height. E: the pose eye with the clearance push, P: him, off: the full
// back-off, fov: the chase fov, oy: his ride height on screen (NDC y).
function governor(c: Rig, E: Vector, P: Vector, off: Vector, fov: f64, oy: f64, dt: f64): void {
    // (depth along the view: he rides oy off its middle; across it, ignored)
    let zMax = GOV_HERO_H / (2 * GOV_FLOOR);
    G_ASPECT = c.aspect;
    G_FOV = fov;
    G_W = c.lensW;
    G_OY = oy;
    G_D = P - E;
    G_OFF = off;
    let aMax = backMax(lmin(c.lensX, c.govX), zMax);
    c.govA = mathx.damp(c.govA, aMax, aMax < c.govA ? GOV_DOWN : GOV_UP, dt);
    // (the width: cut to the floor, back to GOV_X_BAND over it)
    let xMax = widthMax(zMax);
    if (xMax < c.govX) {
        c.govX = mathx.damp(c.govX, xMax, GOV_X_DOWN, dt);
    } else {
        let xUp = widthMax(zMax / (1 + GOV_X_BAND));
        if (xUp > c.govX) c.govX = mathx.damp(c.govX, xUp, GOV_UP, dt);
    }
}

// The eye's back-off offset this frame (eye: the chase pose eye; fov: the
// chase fov, oy: his ride height on screen, for the governor).
function faceBack(c: Rig, p: Player, eye: Vector, boss: f64, dt: f64, fov: f64, oy: f64): Vector {
    if (c.mode != "chase" || c.lookMode != "chase") {
        c.faceK = 0;
        return ZERO;
    }
    let tall = mathx.saturate((1.3 - c.aspect) / 0.5);
    let want = p.hold ? 1.0 : 0.0;
    let rateIn = FACE_IN;
    if (want < 1 && c.lensW > 0 && boss < 1 && faceAhead(c, p)) {
        want = c.lensW;
        rateIn = FACE_IN_A;
    }
    if (want < 1 && (p.grazing || c.faceK > 0.01 || mathx.dot(c.clr, c.clr) > 0.01)) {
        want = lmax(want, mathx.saturate((viewFill(c) - FACE_FILL0) / (FACE_FILL1 - FACE_FILL0)));
    }
    want *= 1 - boss;
    if (p.hold) want = lmax(want, c.faceK);
    c.faceK = mathx.damp(c.faceK, want, want > c.faceK ? rateIn : FACE_OUT, dt);
    // (portrait only: a landscape lens easing out after a turn has none)
    if (c.lensW > 0 && c.aspect < 1) {
        let d = p.pos - eye;
        let h = mathx.norm(Vector.xyz(d.x, 0, d.z));
        let off = Y * <f32>FACE_UP - h * <f32>mathx.lerp(FACE_BACK, mathx.lerp(FACE_BACK_P, FACE_BACK_L, c.lensW), tall);
        governor(c, eye + c.clr, p.pos, off, fov, oy, dt);
        // (the cut weighted by the lens: gone with it, e.g. into a fight)
        let a = c.faceK - (c.faceK - lmin(c.faceK, c.govA)) * c.lensW;
        if (a < 1e-3) return ZERO;
        return off * <f32>a;
    }
    if (c.aspect >= 1) {
        // (fresh at a turn back to portrait)
        c.govA = 1;
        c.govX = 1;
    }
    if (c.faceK < 1e-3) return ZERO;
    let d = p.pos - eye;
    let h = mathx.norm(Vector.xyz(d.x, 0, d.z));
    return (Y * <f32>FACE_UP - h * <f32>mathx.lerp(FACE_BACK, mathx.lerp(FACE_BACK_P, FACE_BACK_L, c.lensW), tall)) * <f32>c.faceK;
}

// The carried part of a take (m, rail) toward the follow's gap (none past it).
function carry(m: f64, gap: f64): f64 {
    if (m * gap <= 0) return 0;
    return m > 0 ? lmin(m, gap * 0.6) : lmax(m, gap * 0.6);
}

// The portrait lens off ahead of the boss fights (rail s): the Stormcrow
// (3600 on, then the sky portal's focus up to the portal) and from before
// THE FALLS curtain to the end (the Watcher): linear ramps, eased (LENS_OUT)
// and rate-limited (LENS_RATE). 1-based, each entry 1-based.
const LENS_OFF: Array<Array<f64>> = [
    [0.0],
    [0.0, 3320, 3540, level.portalS + 100, level.portalS + 320],
    [0.0, 7120, 7340, 1e9, 1e9 + 1],
];

// The lens weights this chase frame (before chasePose; c.faceK from the frame
// before).
function lensTick(c: Rig, p: Player, dt: f64): void {
    let boss = mathx.saturate(c.focusW * 6.5);
    let want = mathx.saturate((1 - c.aspect) / 0.25) * (1 - boss);
    // (sOff: where the lens is off in the next stretch, at any speed)
    let sOff = -1.0;
    for (let i = 1; i < LENS_OFF.length; i++) {
        let g = LENS_OFF[i];
        want *= 1 - mathx.saturate((p.s - g[1]) / (g[2] - g[1])) * (1 - mathx.saturate((p.s - g[3]) / (g[4] - g[3])));
        if (sOff < 0 && p.s < g[3]) sOff = g[2] + LENS_OFF_BY;
    }
    if (p.s >= sOff) c.lensV = 0;
    // (tl: s to sOff at the speed he heads for, a boost's at once, and at
    // least the speed it started going at)
    let tl = (sOff - p.s) / lmax(lmax(lmax(p.speed, p.targetSpeed), c.lensV), 1);
    // (eOff: the most lens (fov over effFov) LENS_RATE takes off by sOff, its
    // ease (1 / LENS_OUT s) inside)
    let base = effFov(c.fov, c.aspect);
    let eOff = HUGE;
    if (want > 0 && c.aspect < 1) {
        eOff = LENS_RATE * (tl - 1 / LENS_OUT);
        let wOff = lensWAt(c.aspect, c.fov, base + eOff, c.lensX);
        if (wOff < want) {
            want = wOff;
            c.lensV = lmax(lmax(c.lensV, p.speed), p.targetSpeed);
        }
    }
    // (once going for a stretch none comes back before it)
    let cap = c.lensV > 0 && c.lensW >= 0 ? c.lensW : 1.0;
    // (fW: the fov the weight moved this frame; the width gets the rest of LENS_RATE)
    let fW = 0.0;
    if (c.lensW < 0 || boss > 0) {
        // (a debug start / restart settles at once; a boss fight never draws
        // with it)
        c.lensW = want;
    } else if (c.goT < GO_LENS_T) {
        c.lensW = lmin(want * rampEase(c.goT / GO_LENS_T, GO_LENS_A), cap);
    } else {
        want = lmin(want, cap);
        let w0 = c.lensW;
        let w = mathx.damp(w0, want, want > w0 ? LENS_IN : LENS_OUT, dt);
        // (eased out it never reaches 0 by itself)
        if (want <= 0 && w < 1e-3) w = 0;
        // (landscape after a turn: eased only; back in portrait it comes in
        // at LENS_RATE)
        if (w != w0 && c.aspect < 1) {
            let f0 = lensFovAt(c.aspect, c.fov, w0, c.lensX);
            let dv = Math.abs(lensFovAt(c.aspect, c.fov, w, c.lensX) - f0);
            let lim = LENS_RATE * dt;
            let need = 0.0;
            if (want < w0) {
                // (the rest at the rate that ends at sOff in tl)
                need = (f0 - base) * dt / lmax(lmax(tl, dt), 1e-3);
                lim = lmax(lim, need);
            }
            if (dv > lim) {
                w = w0 + (w - w0) * (lim / dv);
            } else if (dv < need) {
                // (no eased tail past it: on at the rate, down to want)
                let dw = f0 - lensFovAt(c.aspect, c.fov, want, c.lensX);
                w = dw <= need ? want : w0 + (want - w0) * (need / dw);
            }
            fW = Math.abs(lensFovAt(c.aspect, c.fov, w, c.lensX) - f0);
        }
        c.lensW = w;
    }
    let x = c.lensW > 0 ? c.faceK : 0.0;
    let x0 = c.lensX;
    let x1 = mathx.damp(x0, x, x > x0 ? LENS_X_IN : LENS_X_OUT, dt);
    c.lxUp += dt;
    c.lxCut += dt;
    if (c.lensW > 0 && c.aspect < 1) {
        // (the governor's cap, held GOV_X_HOLD s after a widening, through
        // the same fov limit; no widening once going off for a stretch or
        // once the full width could cross eOff)
        if (x1 > x0 && (c.lxCut < GOV_X_HOLD || c.lensV > 0 || lensFovAt(c.aspect, c.fov, c.lensW, 1) - base > eOff)) x1 = x0;
        if (x1 > c.govX) {
            if (x0 <= c.govX) {
                x1 = c.govX;
            } else if (c.lxUp < GOV_X_HOLD) {
                x1 = lmin(x1, x0);
            } else {
                x1 = c.govX;
                c.lxCut = 0;
            }
        }
        let dv = Math.abs(lensFovAt(c.aspect, c.fov, c.lensW, x1) - lensFovAt(c.aspect, c.fov, c.lensW, x0));
        let lim = lmax(0, LENS_RATE * dt - fW);
        if (dv > lim) x1 = x0 + (x1 - x0) * (lim / dv);
    }
    // (a widening: faster than 0.1 / s, not the damp's creep)
    if (x1 > x0 + 0.1 * dt) c.lxUp = 0;
    c.lensX = x1;
    let lean = 0.0;
    let w = c.world;
    if (w != null && c.lensW > 0 && c.faceK > 0.01) {
        let nL = 0.0, nR = 0.0;
        let bx = playerMod.BOX_X - 1.2;
        for (let i = 1; i < LEAN_DS.length; i++) {
            let sq = lmin(p.s + LEAN_DS[i], level.track.length - 1);
            for (let j = 1; j < LEAN_DX.length; j++) {
                let dx = LEAN_DX[j];
                let xl = lmax(-bx, p.x - dx), xr = lmin(bx, p.x + dx);
                let q = railPoint(sq, xl, p.y);
                if (xl > p.x - dx + 0.5 || w.solid(<f64>q.x, <f64>q.y, <f64>q.z, 1.5)) nL += 1;
                q = railPoint(sq, xr, p.y);
                if (xr < p.x + dx - 0.5 || w.solid(<f64>q.x, <f64>q.y, <f64>q.z, 1.5)) nR += 1;
            }
        }
        // (blocked counts: rock or past the box edge)
        lean = (nL - nR) / <f64>((LEAN_DS.length - 1) * (LEAN_DX.length - 1)) * c.lensW;
    }
    c.lean = mathx.damp(c.lean, lean, LEAN_K, dt);
}

// chasePose's boss separation (Luau closure sepAt)
function sepAt(ex: f64, pl: f64, pf: f64, fl: f64, ff: f64): f64 {
    return Math.atan2(pl - ex, pf) - Math.atan2(fl - ex, ff);
}

// Rubber-band follow in rail space: the eye has its own speed that chases the
// pilot's, so boosts pull away and settle back. Updates the rail-space state
// and returns the eye; CP_LOOK, CP_FOV, CP_ROLL.
let CP_LOOK: Vector = ZERO, CP_FOV: f64 = 0, CP_ROLL: f64 = 0;
function chasePose(c: Rig, p: Player, dt: f64): Vector {
    // portrait: the wide vertical fov already shows the lanes either side, so
    // the eye comes in close (~2/3 of the distance)
    let tall = mathx.saturate((1.3 - c.aspect) / 0.75);
    let near = mathx.lerp(1, 0.68, tall);
    let boss = mathx.saturate(c.focusW * 6.5);
    // boost sells speed with fov, lines and streaks, not distance
    let dist = (mathx.clamp(10 + (p.speed - playerMod.CRUISE) * 0.02, 9.5, 10.8) + c.push * 0.6 + c.focusW * 6) * near;
    let targetS = p.s - dist;
    let err = targetS - c.s;
    // (an eye too close matches his speed and falls back at once; only his
    // brake (outside a fight) still closes it in)
    let close = (p.braking ? boss : 1.0) * mathx.saturate(-err / 2);
    // (held at a rock face he met head-on he barely moves along the rail)
    c.sv = mathx.damp(c.sv, p.speed * p.railK, 2.6 + 9 * close + FACE_SV * (1 - p.railK), dt);
    let pull = 2.4 + lmax(0, err - 2) * 0.35 + 4 * close;
    c.s += c.sv * dt + err * (1 - Math.exp(-pull * dt));
    // after blast-off the eye may trail behind; that slack runs out over a
    // second of chase
    let slack = c.mode == "go" ? 6.0 : c.mode == "chase" ? lmax(0, 6 - c.modeT * 6) : 0.0;
    c.s = mathx.clamp(c.s, p.s - dist - 1.5 * near - slack, p.s - 5 * near);
    let fov = rad(60) + (p.speed - playerMod.CRUISE) * rad(0.16) + p.boostKick * rad(6);
    let fovE = lensFov(c, fov);
    let th = Math.tan(fovE * 0.5);
    let hx = zone(c.aspect), y0 = ZONE_2, y1 = ZONE_3;
    // (before the touch the way round is not known yet: the portrait lens's
    // open side ahead, c.lean, stands in for it)
    let side = p.hitSide != 0 ? p.hitSide : c.lensW > 0 ? mathx.clamp(c.lean * LEAN_SIDE, -1, 1) : 0.0;
    c.faceSide = mathx.damp(c.faceSide, side * FACE_SIDE * c.faceK * c.lensW * (1 - boss), FACE_SIDE_K, dt);
    let exWant = p.x * 0.8 + c.faceSide;
    if (boss > 0) {
        // boss fights: when the pilot and the boss are too far apart across
        // the view for both to fit, the eye slides outboard of him and looks
        // in past his shoulder
        track.frame(level.track, c.s);
        let tp = track.FRAME_P, tf = track.FRAME_F, tr = track.FRAME_R;
        let dP = p.pos - tp, dF = c.focusP - tp;
        let pf = lmax(2, mathx.dot(dP, tf)), pl = mathx.dot(dP, tr);
        let ff = lmax(pf + 5, mathx.dot(dF, tf)), fl = mathx.dot(dF, tr);
        let thx = th * c.aspect;
        let limB = mathx.lerp(0.6, 0.25, tall) - 0.04;
        let limH = lmax(0.05, hx - HERO_EXTENT / (pf * thx) - 0.04);
        let sepMax = Math.atan(limB * thx) + Math.atan(limH * thx);
        let s0 = sepAt(exWant, pl, pf, fl, ff);
        if (Math.abs(s0) > sepMax) {
            // (the separation falls as the eye moves right)
            let target = s0 > 0 ? sepMax : -sepMax;
            let lo = exWant - 9, hi = exWant + 9;
            for (let i = 0; i < 14; i++) {
                let m = (lo + hi) * 0.5;
                if (sepAt(m, pl, pf, fl, ff) > target) lo = m;
                else hi = m;
            }
            exWant = mathx.lerp(exWant, (lo + hi) * 0.5, boss);
        }
    }
    let tx = 0.0, ty = 0.0;
    if (c.thrOn && dt > 0) {
        let dx = p.x - c.thrX - c.thrVx * dt, dy = p.y - c.thrY - c.thrVy * dt;
        tx = dx - mathx.clamp(dx, -THROW_DEAD, THROW_DEAD);
        ty = dy - mathx.clamp(dy, -THROW_DEAD, THROW_DEAD);
    } else {
        c.thrMx = 0;
        c.thrMy = 0;
    }
    c.thrX = p.x;
    c.thrY = p.y;
    c.thrVx = p.vx;
    c.thrVy = p.vy;
    c.thrOn = true;
    c.thrW = ZERO;
    let mx = c.thrMx, my = c.thrMy;
    c.thrMx = Math.abs(mx) > 0.02 ? mx * THROW_KEEP : 0;
    c.thrMy = Math.abs(my) > 0.02 ? my * THROW_KEEP : 0;
    if (mx != 0) {
        let e0 = railPoint(c.s, c.x, c.y);
        c.x += carry(mx, exWant - c.x);
        c.thrW = railPoint(c.s, c.x, c.y) - e0;
    }
    // (with a lead on his side-slip in a fight)
    let xRate = mathx.lerp(7.5, 12, boss);
    c.x = mathx.damp(c.x, exWant + p.vx * 0.8 / xRate * boss, xRate, dt);
    // low over the water the view tips down continuously with altitude so the
    // painted underside twin slides in under him: full tip at 3 m, none from ~10 m
    let skimK = 1 - mathx.smoothstep(3, 10, p.y);
    // ride height on screen: the pilot sits in the lower part of the safe zone
    let oy = mathx.lerp(y0, y1, mathx.lerp(0.28, 0.66, skimK));
    let off = p.y * 0.72 + 4.8 - skimK * 2.6 + c.focusW * 2 - p.y;
    let cyBase = p.y + lmax(off, 1.5 * boss) * near;
    let solvedY = HUGE; // boss fights: the eye height the framing wants this frame
    let ex = c.x, ez = 0.0;
    {
        let e0 = railPoint(c.s, c.x, 0);
        ex = <f64>e0.x;
        ez = <f64>e0.z;
    }
    if (boss > 0) {
        // boss fights: the pilot rides low in the safe zone and the eye height
        // is solved so the boss focus lands at NDC y ~ +0.24 (under the boss
        // bar)
        let P = p.pos, F = c.focusP;
        let px = <f64>P.x - ex, pz = <f64>P.z - ez, fx = <f64>F.x - ex, fz = <f64>F.z - ez;
        let dh = lmax(3, Math.sqrt(px * px + pz * pz));
        let db = lmax(dh + 5, Math.sqrt(fx * fx + fz * fz));
        let hh = HERO_EXTENT / (dh * th);
        let yH = y0 + hh + 0.03;
        oy = mathx.lerp(oy, yH, boss);
        let sep = Math.atan(BOSS_Y * th) - Math.atan(yH * th);
        let lo = lmax(1.3, <f64>P.y - 8), hi = <f64>P.y + 10;
        if (lo < hi) {
            for (let i = 0; i < 14; i++) {
                let e = (lo + hi) * 0.5;
                if (Math.atan((<f64>F.y - e) / db) - Math.atan((<f64>P.y - e) / dh) > sep) hi = e;
                else lo = e;
            }
        }
        track.frame(level.track, c.s);
        let tp = track.FRAME_P, tu = track.FRAME_U;
        let want = ((lo + hi) * 0.5 - <f64>tp.y) / lmax(<f64>tu.y, 0.5);
        solvedY = want;
        c.bossLift = mathx.damp(c.bossLift, (want - cyBase) * boss, 6, dt);
    } else {
        c.bossLift = mathx.damp(c.bossLift, 0, 1.5, dt);
    }
    // (a boss fight follows his height tightly, with a lead on his climb /
    // dive rate)
    let yRate = mathx.lerp(5, 12, boss);
    let yWant = lmax(1.3, cyBase + c.bossLift + p.vy / yRate * boss);
    if (my != 0) {
        let e0 = railPoint(c.s, c.x, c.y);
        c.y += carry(my, yWant - c.y);
        c.thrW = c.thrW + (railPoint(c.s, c.x, c.y) - e0);
    }
    c.y = mathx.damp(c.y, yWant, yRate, dt);
    if (boss > 0) {
        // a fast dive must never leave the eye high above him: it follows
        // him down at once past EYE_LAG over the height the framing wants,
        // and never sits so high that the horizon rides above HORIZON_Y
        let P = p.pos;
        let e0 = railPoint(c.s, c.x, 0);
        let px = <f64>P.x - <f64>e0.x, pz = <f64>P.z - <f64>e0.z;
        let dh = lmax(3, Math.sqrt(px * px + pz * pz));
        let capA = Math.atan(HORIZON_Y * th) + Math.atan(lmax(0, -oy) * th);
        let cap = lmin(p.y + dh * Math.tan(capA), solvedY + EYE_LAG);
        if (c.y > cap) c.y = mathx.lerp(c.y, cap, boss);
    }
    let eye = railPoint(c.s, c.x, c.y);
    c.faceOff = faceBack(c, p, eye, boss, dt, fov, oy);
    eye = eye + c.faceOff;
    let f = p.fwd, rt = p.right, up = p.up;
    let look = p.pos + f * 24 + up * 0.6 + rt * <f32>(p.vx * 0.04);
    if (c.focusW > 0.001) look = mathx.vlerp(look, c.focusP, c.focusW * (0.45 + tall * 0.25));
    PL_KIND = PL_RIDE;
    PL_A = oy;
    look = reframe(eye, look, p.pos, 0, 0, fovE, c.aspect);
    if (boss > 0) {
        // what the eye could not fix yet: pitch the rest, as far as the
        // pilot's room in the zone allows
        viewBasis(eye, look, 0);
        let vf = VB_F, vr = VB_RT, vu = VB_UP;
        ndcOf(eye, vf, vr, vu, th, c.aspect, p.pos);
        let hy0 = NDC_Y, hz0 = NDC_Z;
        ndcOf(eye, vf, vr, vu, th, c.aspect, c.focusP);
        let by0 = NDC_Y, bz0 = NDC_Z;
        if (hz0 > 1 && bz0 > 1) {
            let hh = HERO_EXTENT / (hz0 * th);
            let want = mathx.clamp(by0, BOSS_Y - 0.05, BOSS_Y + 0.05);
            let dy = mathx.clamp(by0 - want, hy0 - (y1 - hh), hy0 - (y0 + hh * 0.85));
            if (Math.abs(dy) > 1e-3) {
                let D = mathx.len(look - eye);
                look = look + vu * <f32>(dy * boss * th * D);
            }
        }
    }
    if (boss > 0 && tall > 0) {
        // narrow screens: turn toward the boss so it stays in frame (the zone
        // clamp still has the last word on the pilot)
        let lim = mathx.lerp(0.6, 0.25, tall);
        PL_KIND = PL_FIT;
        PL_A = lim;
        let fit = reframe(eye, look, c.focusP, 0, 0, fovE, c.aspect);
        look = mathx.vlerp(look, fit, boss * tall);
    }
    if (tx != 0 || ty != 0) {
        let w0 = c.thrW;
        eye = throwWindow(c, p, eye, look, tx, ty, boss, dt);
        look = look + (c.thrW - w0);
    }
    CP_LOOK = look;
    CP_FOV = fov;
    CP_ROLL = p.railBank * 0.45 + p.bank * 0.2;
    return eye;
}

// Countdown numeral card (a 1200 x 900 artboard laid over the view with fit
// contain). The numerals and their glass plates stay inside this box of it;
// the launch framing keeps the hero out of it.
const CARD_W: f64 = 1200, CARD_H: f64 = 900;
const NUM_X0: f64 = 465, NUM_X1: f64 = 735, NUM_Y0: f64 = 250, NUM_Y1: f64 = 670;
// GO! is wider than the digits
const GO_X0: f64 = 395, GO_X1: f64 = 805;

// Portrait (aspect < 1) boxes the card into this band of the screen height,
// above the hero safe zone.
const BAND_Y0: f64 = 0.035, BAND_Y1: f64 = 0.34;

// The numeral box in NDC (x right, y up): returns left; NUMERALBOX_1..4 =
// left, right, top, bottom. go: the wider GO! glyphs.
export let NUMERALBOX_1: f64 = 0;
export let NUMERALBOX_2: f64 = 0;
export let NUMERALBOX_3: f64 = 0;
export let NUMERALBOX_4: f64 = 0;
export function numeralBox(aspect: f64, go: bool = false): f64 {
    let nx0 = go ? GO_X0 : NUM_X0, nx1 = go ? GO_X1 : NUM_X1;
    if (aspect < 1) {
        // fit contain into the band (units: screen heights)
        let bh = BAND_Y1 - BAND_Y0;
        let k = lmin(aspect / CARD_W, bh / CARD_H);
        let left = (aspect - CARD_W * k) * 0.5;
        let top = BAND_Y0 + (bh - CARD_H * k) * 0.5;
        NUMERALBOX_1 = (left + nx0 * k) / aspect * 2 - 1;
        NUMERALBOX_2 = (left + nx1 * k) / aspect * 2 - 1;
        NUMERALBOX_3 = 1 - 2 * (top + NUM_Y0 * k);
        NUMERALBOX_4 = 1 - 2 * (top + NUM_Y1 * k);
    } else if (aspect >= CARD_W / CARD_H) {
        let kx = 2 / (CARD_H * aspect);
        NUMERALBOX_1 = (nx0 - CARD_W * 0.5) * kx;
        NUMERALBOX_2 = (nx1 - CARD_W * 0.5) * kx;
        NUMERALBOX_3 = 1 - 2 * NUM_Y0 / CARD_H;
        NUMERALBOX_4 = 1 - 2 * NUM_Y1 / CARD_H;
    } else {
        let ky = 2 * aspect / CARD_W;
        NUMERALBOX_1 = 2 * nx0 / CARD_W - 1;
        NUMERALBOX_2 = 2 * nx1 / CARD_W - 1;
        NUMERALBOX_3 = (CARD_H * 0.5 - NUM_Y0) * ky;
        NUMERALBOX_4 = (CARD_H * 0.5 - NUM_Y1) * ky;
    }
    return NUMERALBOX_1;
}

// The painted launch pose around p.pos (m): half width (fists out), reach
// above (helmet) and below (boots + flames).
const HERO_W: f64 = 1.25, HERO_UP: f64 = 1.25, HERO_DN: f64 = 1.2;
const SLOT_GAP: f64 = 0.025;

// Which side of the numerals the pilot takes in shot A (returned) / B
// (LS_B): -1 left, +1 right, 0 under them (portrait). Up to 16:10 he keeps
// to the right (the route list owns the left).
let LS_B: f64 = 0;
function launchSides(aspect: f64): f64 {
    if (aspect < 1) {
        LS_B = 0;
        return 0;
    } else if (aspect >= 1.7) {
        LS_B = 1;
        return -1;
    }
    LS_B = 1;
    return 1;
}

// The slot his whole figure fits in during the countdown (NDC, y up): beside
// the numerals inside the hero safe zone, or the safe zone itself under the
// numeral band in portrait. Returns x0; SL_X1, SL_Y0, SL_Y1.
let SL_X1: f64 = 0, SL_Y0: f64 = 0, SL_Y1: f64 = 0;
function launchSlot(aspect: f64, side: f64, go: bool = false): f64 {
    let hx = zone(aspect), zy0 = ZONE_2, zy1 = ZONE_3;
    let nx0 = numeralBox(aspect, go), nx1 = NUMERALBOX_2, nyB = NUMERALBOX_4;
    SL_Y0 = zy0;
    SL_Y1 = zy1;
    if (side == 0) {
        SL_X1 = hx;
        SL_Y1 = lmin(zy1, nyB - SLOT_GAP);
        return -hx;
    }
    if (side > 0) {
        // 16:9 and wider: the strip runs a little past the zone; toward 4:3
        // he keeps inside the zone (smaller) rather than drift out
        let ext = aspect < 1.15 ? 0.12 : 0.02 + 0.1 * mathx.saturate((aspect - 1.4) / 0.3);
        SL_X1 = hx + ext;
        return nx1 + SLOT_GAP;
    }
    SL_X1 = nx0 - SLOT_GAP;
    return -(hx + 0.02);
}

// How far the eye must be for his figure to fit a slot.
function fitDist(aspect: f64, fov: f64, x0: f64, x1: f64, y0: f64, y1: f64): f64 {
    let th = Math.tan(effFov(fov, aspect) * 0.5);
    let zx = 2 * HERO_W / (lmax(0.05, x1 - x0) * 0.9 * th * aspect);
    let zy = (HERO_UP + HERO_DN) / (lmax(0.05, y1 - y0) * 0.9 * th);
    // portrait's wide vertical fov: come closer so he is not a speck
    return lmax(lmax(aspect < 1 ? 6.5 : 8.5, zx), zy);
}

function launchFov(t: f64): f64 {
    return rad(54 - mathx.saturate(t / 3) * 6);
}

// Launch pad framing at countdown time t: returns the eye; LP_LOOK, LP_YAW
// and the slot LP_X0, LP_X1, LP_Y0, LP_Y1.
let LP_LOOK: Vector = ZERO, LP_YAW: f64 = 0, LP_X0: f64 = 0, LP_X1: f64 = 0, LP_Y0: f64 = 0, LP_Y1: f64 = 0;
function launchPose(c: Rig, p: Player, t: f64): Vector {
    let f = p.fwd, rt = p.right;
    let shotB = t >= LAUNCH_CUT;
    let ang = launchKey(shotB ? SHOT_B : SHOT_A, t);
    let rd = LK_RAD, h = LK_H, lu = LK_LU;
    let sA = launchSides(c.aspect), sB = LS_B;
    let side = shotB ? sB : sA;
    let fovK = launchFov(t);
    let x0 = launchSlot(c.aspect, side), x1 = SL_X1, y0 = SL_Y0, y1 = SL_Y1;
    let dist = fitDist(c.aspect, fovK, x0, x1, y0, y1) * rd;
    // the eye on his right turns him toward the right of the frame
    let yaw = side == 0 ? (shotB ? -ang : ang) : -side * ang;
    let eye = p.pos - f * <f32>(Math.cos(yaw) * dist) + rt * <f32>(Math.sin(yaw) * dist) + mathx.v3(0, h, 0);
    let th = Math.tan(effFov(fovK, c.aspect) * 0.5);
    let hw = HERO_W / (dist * th * c.aspect);
    let up = HERO_UP / (dist * th), dn = HERO_DN / (dist * th);
    let ox = (x0 + x1) * 0.5;
    if (side == 0) {
        // a little off centre, facing into the open side
        ox = mathx.clamp(shotB ? 0.1 : -0.1, x0 + hw, x1 - hw);
    }
    let oy = mathx.lerp(y0 + dn, y1 - up, lu);
    LP_LOOK = frameAt(eye, p.pos, ox, oy, c.aspect, fovK);
    LP_YAW = yaw;
    LP_X0 = x0;
    LP_X1 = x1;
    LP_Y0 = y0;
    LP_Y1 = y1;
    return eye;
}

// Keep his figure inside the countdown slot (soft edges).
function clampToSlot(c: Rig, P: Vector, look: Vector, x0: f64, x1: f64, y0: f64, y1: f64): Vector {
    // (the lens: eased in from GO)
    PL_KIND = PL_SLOT;
    PL_A = x0;
    PL_B = x1;
    PL_C = y0;
    PL_D = y1;
    return reframe(c.eye, look, P, 1, c.roll + c.twist, lensFov(c, c.fov), c.aspect);
}

// Start the launch countdown framed on the pad at once (restart / retry,
// where easing in from the old camera would swoop across the map).
export function snapLaunch(c: Rig, p: Player): void {
    setMode(c, "launch");
    let eye = launchPose(c, p, 0);
    let look = LP_LOOK;
    c.holdEye = eye;
    c.holdLook = look;
    c.eye = eye;
    c.look = look;
}

// World -> screen (0..1, y down) and depth from the rig's camera as last
// updated: exact in headless runs too, where the renderer's matrix lags.
// Returns u; PROJECT_1..3 = u, v, depth (-1, -1, -1 behind the eye).
export let PROJECT_1: f64 = 0;
export let PROJECT_2: f64 = 0;
export let PROJECT_3: f64 = 0;
export function project(c: Rig, P: Vector): f64 {
    let cam = c.cam;
    let f = mathx.norm(cam.target - cam.eye);
    let rt = mathx.norm(mathx.cross(f, cam.up));
    let up = mathx.cross(rt, f);
    let d = P - cam.eye;
    let z = mathx.dot(d, f);
    if (z <= 0.0001) {
        PROJECT_1 = -1;
        PROJECT_2 = -1;
        PROJECT_3 = -1;
        return -1;
    }
    let th = Math.tan(cam.fov * 0.5);
    PROJECT_1 = mathx.dot(d, rt) / (z * th * c.aspect) * 0.5 + 0.5;
    PROJECT_2 = 0.5 - mathx.dot(d, up) / (z * th) * 0.5;
    PROJECT_3 = z;
    return PROJECT_1;
}

// Briefing end framing per aspect: where the pilot sits (NDC) and how far the
// eye ends up. Returns x; BF_Y, BF_D.
// 4:3: the band under the chart: lower and further off, so the helmet clears it
const BRIEF_43X: f64 = 0.44, BRIEF_43Y: f64 = -0.56, BRIEF_43D: f64 = 12.5;
let BF_Y: f64 = 0, BF_D: f64 = 0;
function briefFrame(aspect: f64): f64 {
    if (aspect >= 1.33) {
        let k = mathx.saturate((aspect - 1.33) / 0.4);
        BF_Y = mathx.lerp(BRIEF_43Y, -0.3, k);
        BF_D = mathx.lerp(BRIEF_43D, 9, k);
        return mathx.lerp(BRIEF_43X, 0.04, k);
    }
    let k = mathx.saturate((aspect - 0.6) / 0.73);
    BF_Y = mathx.lerp(-0.02, BRIEF_43Y, k);
    BF_D = mathx.lerp(14, BRIEF_43D, k);
    return mathx.lerp(0, BRIEF_43X, k);
}

// Boss reveal: where the hull's focus point sits on screen during the poster
// hold, in the card units of the boss poster (StingCard 1920 x 1080 /
// StingCardP 1080 x 1920, fit contain). Landscape: left of the badge.
// Portrait: the Stormcrow rides above-left of the badge disc (REVEAL_P 9:16,
// REVEAL_PN phones); the Watcher's ring keeps the spot beside the badge.
const REVEAL_L_X: f64 = 780, REVEAL_L_Y: f64 = 310;
const REVEAL_P_X: f64 = 305, REVEAL_P_Y: f64 = 360;
const REVEAL_PN_X: f64 = 314, REVEAL_PN_Y: f64 = 345;
// (3:4 and squarer: the card is pillarboxed; blended in from 9:16)
const REVEAL_PQ_X: f64 = 265, REVEAL_PQ_Y: f64 = 320;
const REVEAL_PW_X: f64 = 225, REVEAL_PW_Y: f64 = 410;
// Stormcrow poster: where the pilot sits (card units, his middle) and how far
// the eye stays behind him (m, before the hold's 3 m push in). Portrait also
// rolls the view (REVEAL_ROLL_P, rad) and widens it to REVEAL_HFOV_P.
const PILOT_L_X: f64 = 410, PILOT_L_Y: f64 = 350;
const PILOT_P_X: f64 = 180, PILOT_P_Y: f64 = 680;
const PILOT_DL: f64 = 18, PILOT_DP: f64 = 18;
const REVEAL_ROLL_P: f64 = 0.12;
const REVEAL_HFOV_P: f64 = rad(86);
// A point in poster card units -> NDC (y up): returns x; CN_Y.
let CN_Y: f64 = 0;
function cardNdc(aspect: f64, ax: f64, ay: f64): f64 {
    let tall = aspect < 1;
    let W = tall ? 1080.0 : 1920.0, H = tall ? 1920.0 : 1080.0;
    let s = lmin(aspect / W, 1 / H);
    let u = ((aspect - W * s) * 0.5 + ax * s) / aspect;
    let v = (1 - H * s) * 0.5 + ay * s;
    CN_Y = 1 - v * 2;
    return u * 2 - 1;
}
// aimAt's closures: dir(yw, pt) and at(yw, pt) (-> ndcOf's NDC_Y, NDC_Z)
function aimDir(yw: f64, pt: f64): Vector {
    return mathx.v3(Math.sin(yw) * Math.cos(pt), Math.sin(pt), -Math.cos(yw) * Math.cos(pt));
}
function aimAtNdc(eye: Vector, P: Vector, roll: f64, th: f64, aspect: f64, yw: f64, pt: f64): f64 {
    viewBasis(eye, eye + aimDir(yw, pt), roll);
    return ndcOf(eye, VB_F, VB_RT, VB_UP, th, aspect, P);
}
// Turn the view from eye so P lands at NDC (tx, ty) under roll: Newton on
// the view's yaw / pitch (reframe's linear step overshoots ~45 deg off axis).
function aimAt(eye: Vector, look: Vector, P: Vector, roll: f64, th: f64, aspect: f64, tx: f64, ty: f64): Vector {
    let D = mathx.len(look - eye);
    let f0 = (look - eye) * <f32>(1 / lmax(D, 1e-6));
    let yaw = Math.atan2(<f64>f0.x, -<f64>f0.z), pitch = Math.asin(mathx.clamp(<f64>f0.y, -1, 1));
    for (let i = 0; i < 5; i++) {
        let nx = aimAtNdc(eye, P, roll, th, aspect, yaw, pitch);
        let ny = NDC_Y, z = NDC_Z;
        let ex = nx - tx, ey = ny - ty;
        if (z < 0.5 || Math.abs(ex) + Math.abs(ey) < 1e-4) break;
        let ax = aimAtNdc(eye, P, roll, th, aspect, yaw + 1e-3, pitch);
        let ay = NDC_Y;
        let bx = aimAtNdc(eye, P, roll, th, aspect, yaw, pitch + 1e-3);
        let by = NDC_Y;
        let j11 = (ax - nx) * 1e3, j21 = (ay - ny) * 1e3, j12 = (bx - nx) * 1e3, j22 = (by - ny) * 1e3;
        let det = j11 * j22 - j12 * j21;
        if (Math.abs(det) < 1e-6) break;
        yaw -= (j22 * ex - j12 * ey) / det;
        pitch = mathx.clamp(pitch - (j11 * ey - j21 * ex) / det, -1.45, 1.45);
    }
    return eye + aimDir(yaw, pitch) * <f32>D;
}
function squarer(aspect: f64): f64 {
    return mathx.saturate((aspect - 0.5625) / 0.1875);
}
// returns x; CN_Y
function revealNdc(aspect: f64, tag: string): f64 {
    if (aspect >= 1) {
        return cardNdc(aspect, REVEAL_L_X, REVEAL_L_Y);
    } else if (tag == "boss_watcher") {
        return cardNdc(aspect, REVEAL_PW_X, REVEAL_PW_Y);
    }
    let k = mathx.saturate((aspect - 0.46) / 0.1);
    let q = squarer(aspect);
    let x = mathx.lerp(mathx.lerp(REVEAL_PN_X, REVEAL_P_X, k), REVEAL_PQ_X, q);
    return cardNdc(aspect, x, mathx.lerp(mathx.lerp(REVEAL_PN_Y, REVEAL_P_Y, k), REVEAL_PQ_Y, q));
}

// The beat's shot: returns the eye; BP_LOOK, BP_FOV, BP_ROLL and how much of
// it shows, BP_W (0..1).
let BP_LOOK: Vector = ZERO, BP_FOV: f64 = 0, BP_ROLL: f64 = 0, BP_W: f64 = 0;
function beatPose(c: Rig, p: Player): Vector {
    let t = c.beatT, dur = lmax(c.beatDur, 0.01);
    let u = mathx.saturate(t / dur);
    let Yv = Vector.xyz(0, 1, 0);
    if (c.beat == "kill") {
        // KILL CAM: hard cut, orbit the falling hull (its focus point) in
        // bullet time, following it down
        let F = c.focusP;
        let sw = mathx.easeInOutCubic(u);
        let f = p.fwd, rt = p.right;
        let along = -c.beatR * mathx.lerp(1.1, 0.82, sw);
        let lat = c.beatSide * mathx.lerp(1, -0.8, sw) * c.beatR * 0.3;
        let hy = c.beatH + 3 * u;
        let eye = F + f * <f32>along + rt * <f32>lat + Yv * <f32>hy;
        // keep the lens out of canyon walls: slide in toward the hull's line
        // and up
        let w = c.world;
        if (w != null) {
            for (let i = 0; i < 3; i++) {
                if (!w.solid(<f64>eye.x, <f64>eye.y, <f64>eye.z, 1.5)) break;
                lat *= 0.5;
                hy += 8;
                eye = F + f * <f32>along + rt * <f32>lat + Yv * <f32>hy;
            }
        }
        if (eye.y < 3) eye = Vector.xyz(eye.x, 3, eye.z);
        BP_LOOK = F - Yv * <f32>(2 * u);
        BP_FOV = rad(52 - 6 * u);
        BP_ROLL = c.beatSide * (0.06 - 0.12 * u);
        BP_W = 1;
        return eye;
    } else if (c.beat == "reveal") {
        // low behind and beside the pilot, looking up past him at the boss
        let w = mathx.easeOutCubic(mathx.saturate(t / 0.35)) * (1 - mathx.smoothstep(dur - 0.55, dur, t));
        let f = p.fwd, rt = p.right;
        let eye = p.pos - f * <f32>(10.5 - 3 * u) + rt * <f32>(3.2 * c.beatSide) - Yv * 1.4;
        if (eye.y < 0.9) eye = Vector.xyz(eye.x, 0.9, eye.z);
        // the hull lands in the poster's image band (the Watcher: the lens
        // stays where the guard models it, only the aim moves)
        let tall = c.aspect < 1;
        let crow = c.beatTag == "boss_stormcrow";
        let fov = rad(62 - 8 * u), roll = -0.06 * c.beatSide;
        if (crow && tall) {
            let q = squarer(c.aspect);
            roll = mathx.lerp(REVEAL_ROLL_P, roll, q);
            fov = lmax(fov, 2 * Math.atan(Math.tan(mathx.lerp(REVEAL_HFOV_P, MIN_HFOV, q) * 0.5) / c.aspect));
        }
        let ox = revealNdc(c.aspect, c.beatTag), oy = CN_Y;
        let fe = effFov(fov, c.aspect);
        let look = mathx.vlerp(p.pos + Yv * 1.2, c.focusP, 0.78);
        if (crow) {
            // the pilot on his spot: the eye moves round him
            let px = tall ? cardNdc(c.aspect, PILOT_P_X, PILOT_P_Y) : cardNdc(c.aspect, PILOT_L_X, PILOT_L_Y);
            let py = CN_Y;
            let D = (tall ? PILOT_DP : PILOT_DL) - 3 * u;
            let th = Math.tan(fe * 0.5);
            look = aimAt(eye, look, c.focusP, roll, th, c.aspect, ox, oy);
            for (let i = 0; i < 3; i++) {
                viewBasis(eye, look, roll);
                let vf = VB_F, vr = VB_RT, vu = VB_UP;
                let d = mathx.norm(vf + vr * <f32>(px * th * c.aspect) + vu * <f32>(py * th));
                eye = p.pos - d * <f32>D;
                if (eye.y < 0.9) eye = Vector.xyz(eye.x, 0.9, eye.z);
                look = aimAt(eye, look, c.focusP, roll, th, c.aspect, ox, oy);
            }
        } else {
            PL_KIND = PL_AT;
            PL_A = ox;
            PL_B = oy;
            look = reframe(eye, look, c.focusP, 0, roll, fe, c.aspect);
            look = reframe(eye, look, c.focusP, 0, roll, fe, c.aspect);
        }
        BP_LOOK = look;
        BP_FOV = fov;
        BP_ROLL = roll;
        BP_W = w;
        return eye;
    } else if (c.beat == "arch") {
        // the lens drops to skim the water behind him and trails at half his
        // pace: he pulls ahead and threads the arch framed whole around him
        let w = mathx.easeOutCubic(mathx.saturate(t / 0.35)) * (1 - mathx.smoothstep(dur - 0.6, dur, t));
        let es = c.beatS0 - 8 + (p.s - c.beatS0) * 0.75;
        let eye = railPoint(es, p.x * 0.7, 1.0);
        BP_LOOK = p.pos + p.fwd * 10 + Yv * 3.5;
        BP_FOV = rad(66);
        BP_ROLL = 0.035 * c.beatSide;
        BP_W = w;
        return eye;
    }
    BP_LOOK = c.look;
    BP_FOV = c.fov;
    BP_ROLL = c.roll;
    BP_W = 0;
    return c.eye;
}

// Death cam slots around the crash (heading frame at the crash): lateral m
// (+ right), back m, up m, in order of preference (1-based). Three-quarter
// views off the side first: a lens straight behind him ends up on the smoke
// streak from the crash point.
const DEATH_EYES: Array<Array<f64>> = [
    [0.0],
    [0.0, 9, 13, 8],
    [0.0, -9, 13, 8],
    [0.0, 13, 8, 8],
    [0.0, -13, 8, 8],
    [0.0, 7, 18, 11],
    [0.0, -7, 18, 11],
    [0.0, 0, 23, 13],
    [0.0, 0, 30, 19],
    // (last resort: high over the fall, looking down past the rock)
    [0.0, 8, 10, 22],
    [0.0, -8, 10, 22],
    [0.0, 0, 16, 28],
];

function segDist2(px: f64, py: f64, pz: f64, a: Vector, b: Vector): f64 {
    let ax = <f64>a.x, ay = <f64>a.y, az = <f64>a.z;
    let dx = <f64>b.x - ax, dy = <f64>b.y - ay, dz = <f64>b.z - az;
    let l2 = dx * dx + dy * dy + dz * dz;
    let k = l2 > 1e-6 ? mathx.clamp(((px - ax) * dx + (py - ay) * dy + (pz - az) * dz) / l2, 0, 1) : 0.0;
    let qx = ax + dx * k - px, qy = ay + dy * k - py, qz = az + dz * k - pz;
    return qx * qx + qy * qy + qz * qz;
}

// Near-field probes of a death cam view (offsets across the view, ~20 deg
// out, at 3 / 6 / 10 m): rock there fills a big part of the frame even when
// the sight line itself is clear. 1-based.
const NEAR_A: Array<f64> = [0.0, -0.36, 0, 0.36, -0.36, 0.36, -0.36, 0, 0.36];
const NEAR_B: Array<f64> = [0.0, -0.3, -0.3, -0.3, 0, 0, 0.3, 0.3, 0.3];
const NEAR_D: Array<f64> = [0.0, 3, 6, 10];

// The death cam's sight line from E to A is blocked: probes bar its last
// 3 m (he may lie in the rock he hit), wider more than 8 m from him.
function deathLineBlocked(c: Rig, E: Vector, A: Vector): bool {
    let w = c.world;
    if (w == null) return false;
    let d = A - E;
    let len = mathx.len(d);
    let stop = lmax(0, 1 - 3 / lmax(len, 1e-3));
    for (let i = 1; i <= 6; i++) {
        let k = stop * <f64>i / 6;
        let q = E + d * <f32>k;
        if (w.solid(<f64>q.x, <f64>q.y, <f64>q.z, (1 - k) * len > 8 ? 2.5 : 1.5)) return true;
    }
    return false;
}

// Cost of a death cam eye E looking at A (lower is better, >= 1000 blocked):
// the lens LENS_CLEAR m off the rock and the sight line clear of it, little
// rock in the near field of the view, the listed occluders >= 4 m off the
// line / lens.
function deathCost(c: Rig, E: Vector, A: Vector): f64 {
    let cost = 0.0;
    let w = c.world;
    if (w != null) {
        if (w.solid(<f64>E.x, <f64>E.y, <f64>E.z, LENS_CLEAR) || deathLineBlocked(c, E, A)) return 1000;
        let d = A - E;
        let len = mathx.len(d);
        let f = d * <f32>(1 / lmax(len, 1e-3));
        let rt = mathx.norm(mathx.cross(f, Vector.xyz(0, 1, 0)));
        let up = mathx.cross(rt, f);
        for (let j = 1; j < NEAR_A.length; j++) {
            let dir = f + rt * <f32>NEAR_A[j] + up * <f32>NEAR_B[j];
            for (let i = 1; i < NEAR_D.length; i++) {
                let dd = NEAR_D[i];
                if (dd < len - 3) {
                    let q = E + dir * <f32>dd;
                    if (w.solid(<f64>q.x, <f64>q.y, <f64>q.z, 1.5)) {
                        cost += 5;
                        break;
                    }
                }
            }
        }
    }
    let nr = c.near;
    for (let i = 0; i < c.nearN; i++) {
        let o = i * 4;
        let ox = nr[o + 1], oy = nr[o + 2], oz = nr[o + 3], rr = nr[o + 4];
        let dl = Math.sqrt(segDist2(ox, oy, oz, E, A)) - rr;
        let dx = ox - <f64>E.x, dy = oy - <f64>E.y, dz = oz - <f64>E.z;
        let de = Math.sqrt(dx * dx + dy * dy + dz * dz) - rr;
        let m = lmin(dl, de - 2);
        if (m < 4) cost += (4 - m) * 3;
    }
    return cost;
}

// A death cam slot's offset from him (heading frame at the crash).
function slotOff(c: Rig, i: i32): Vector {
    let e = DEATH_EYES[i];
    return c.deathR * <f32>e[1] - c.deathF * <f32>e[2] + mathx.v3(0, e[3], 0);
}

// The death cam eye at offset o from him (never under 3 m over the water).
function deathAt(A: Vector, o: Vector): Vector {
    let E = A + o;
    if (E.y < 3) E = Vector.xyz(E.x, 3, E.z);
    return E;
}

// The clearest slot: scored where it is now and where his fall takes it
// 0.35 s on; after the cut a move costs more: only a clearly better slot
// takes over.
function deathA2(c: Rig, A: Vector): Vector {
    let la = 0.35;
    let A2 = A + c.deathV * <f32>la;
    return mathx.v3(<f64>A2.x, lmax(0.5, <f64>A2.y - 13 * la * la), <f64>A2.z);
}
function deathPickSlot(c: Rig, A: Vector, first: bool): i32 {
    let A2 = deathA2(c, A);
    let moveK = first ? 0.05 : 0.15;
    let best = 1, bestC = HUGE;
    for (let i = 1; i < DEATH_EYES.length; i++) {
        let o = slotOff(c, i);
        let E = deathAt(A, o);
        let cst = deathCost(c, E, A);
        if (cst < 1000) cst += deathCost(c, deathAt(A2, o), A2) * 0.6;
        cst += <f64>i * 0.4 + mathx.len(E - c.eye) * moveK;
        if (i == c.deathPick) cst -= 6;
        if (cst < bestC) {
            best = i;
            bestC = cst;
        }
    }
    return best;
}

// The death cam lens at E is in or hugging rock, or rock hides him.
function deathBlocked(c: Rig, E: Vector, A: Vector): bool {
    let w = c.world;
    if (w == null) return false;
    return w.solid(<f64>E.x, <f64>E.y, <f64>E.z, LENS_HARD) || deathLineBlocked(c, E, A);
}

// The glide from offset o0 to o1 stays clear (else the move is a cut).
function deathGlideClear(c: Rig, A: Vector, o0: Vector, o1: Vector): bool {
    for (let k = 1; k <= 6; k++) {
        if (deathBlocked(c, deathAt(A, mathx.vlerp(o0, o1, <f64>k / 6)), A)) return false;
    }
    return true;
}

// A slot pick's probes lie within DEATH_REACH m (xz) of A or its look-ahead:
// while the scenery bakes one near list serves them (rockNear).
const DEATH_REACH: f64 = 36;
function deathNear(c: Rig, A: Vector): bool {
    let w = c.world;
    if (w == null) return false;
    let A2 = deathA2(c, A);
    let r = DEATH_REACH;
    return w.rockNear(true, lmin(<f64>A.x, <f64>A2.x) - r, lmin(<f64>A.z, <f64>A2.z) - r, lmax(<f64>A.x, <f64>A2.x) + r, lmax(<f64>A.z, <f64>A2.z) + r);
}

// The death cam this frame: the eye rides his fall at the picked slot's
// offset. Slots are re-scored every 0.25 s; a new one is reached by a short
// glide when the way there is clear, else by a cut, and a lens that runs
// into rock (or loses him behind it) cuts to the clearest slot at once.
function deathUpdate(c: Rig, A: Vector, dt: f64): void {
    if (dt > 0) c.deathV = mathx.vdamp(c.deathV, (A - c.deathA) * <f32>(1 / dt), 12, dt);
    c.deathA = A;
    c.deathT -= dt;
    c.deathCd -= dt;
    let first = c.deathPick == 0;
    let cut = first;
    let nearOn = false;
    if (first || c.deathT <= 0) {
        nearOn = deathNear(c, A);
        c.deathT = 0.25;
        let pick = deathPickSlot(c, A, first);
        if (!first && pick != c.deathPick && !deathGlideClear(c, A, c.deathOff, slotOff(c, pick))) cut = true;
        c.deathPick = pick;
    }
    let off = slotOff(c, c.deathPick);
    if (!cut) {
        off = mathx.vdamp(c.deathOff, off, 5, dt);
        if (c.deathCd <= 0 && deathBlocked(c, deathAt(A, off), A)) {
            if (!nearOn) nearOn = deathNear(c, A);
            c.deathPick = deathPickSlot(c, A, false);
            c.deathT = 0.25;
            c.deathCd = 0.3;
            off = slotOff(c, c.deathPick);
            cut = true;
        }
    }
    if (nearOn) c.world!.rockNear(false, 0, 0, 0, 0);
    c.deathOff = off;
    c.eye = deathAt(A, off);
    if (cut) c.look = A + Vector.xyz(0, 0.6, 0);
}

// THE FALLS near plane (see FALLS_BACK): just past the curtain while it
// stands between the lens and him, else NEAR (also when that would need
// `margin` m more than the cap).
function fallsNear(E: Vector, fwd: Vector, rt: Vector, up: Vector, fov: f64, aspect: f64, P: Vector, margin: f64): f64 {
    if (!FALLS_ON) return NEAR;
    let Q = fallsQ;
    let n = fallsN;
    let dE = mathx.dot(E - Q, n), dP = mathx.dot(P - Q, n);
    if (dE >= FALLS_HALF || dP <= FALLS_HALF + 0.5) return NEAR;
    let zP = mathx.dot(P - E, fwd);
    let th = Math.tan(fov * 0.5);
    // (the sea stays: stop short of where the view's bottom corners meet it)
    let cap = lmin(FALLS_MAX, zP - 0.8);
    let Rs = new Array<Vector>(5);
    for (let i = 1; i <= 4; i++) {
        let r = fwd + rt * <f32>(i % 2 == 0 ? th * aspect : -th * aspect) + up * <f32>(i <= 2 ? -th : th);
        Rs[i] = r;
        if (i <= 2 && r.y < -1e-3) cap = lmin(cap, 0.9 * <f64>E.y / -<f64>r.y);
    }
    // depth of the curtain's far side on the ray to him, then at the view's
    // corners (clips the whole sheet when it can)
    let need = (FALLS_HALF - dE) / (dP - dE) * zP + 0.3;
    if (need + margin > cap) return NEAR;
    for (let i = 1; i <= 4; i++) {
        let nr = mathx.dot(n, Rs[i]);
        if (nr > 1e-3) need = lmax(need, (FALLS_HALF - dE) / nr + 0.3);
    }
    return lmax(NEAR, lmin(need, cap));
}

// The hero pull to draw with this frame (the game, before update): `pull`
// (his scrape's), or 1 while THE FALLS curtain would hide him (fallsNear,
// judged from the view last drawn with a 0.3 m margin). The pull lets go at
// once (to `pull` while he scrapes). No pull while a beat runs.
export function curtainPull(c: Rig, p: Player, pull: f64): f64 {
    let hide = false;
    let mode = c.mode;
    if (FALLS_ON && p.alive && c.beat == "" && (mode == "chase" || mode == "go" || mode == "hold")) {
        let Q = fallsQ;
        let cam = c.cam;
        let E = cam.eye, P = p.pos;
        let dE = mathx.dot(E - Q, fallsN), dP = mathx.dot(P - Q, fallsN);
        if (dE < -FALLS_FACE && dP > -FALLS_FACE - HERO_HALF) {
            let fwd = mathx.norm(cam.target - E);
            let rt = mathx.norm(mathx.cross(fwd, cam.up));
            hide = fallsNear(E, fwd, rt, mathx.cross(rt, fwd), cam.fov, c.aspect, P, 0.3) <= NEAR;
        }
    }
    let was = c.fallsLive;
    c.fallsPull = hide;
    if (hide) {
        return 1;
    } else if (was) {
        return p.grazing ? pull : 0;
    }
    return pull;
}

function updateRig(c: Rig, p: Player, t: f64, dt: f64): void {
    c.modeT += dt;
    if (c.goT < GO_LENS_T) c.goT += dt;
    c.cut = 0;
    let mode = c.mode;
    let fovT = rad(60);
    let rollT = 0.0;
    let rate = 6.0;
    let slotX0 = 0.0, slotX1 = 0.0, slotY0 = 0.0, slotY1 = 0.0;
    let modeT0 = c.modeT; // (a mode switch below resets modeT)

    if (mode == "title") {
        // attract: three slow shots with dip-to-black cuts. The lens stands
        // well back so the wingmen fly small through the print window
        const SHOT: f64 = 9;
        let st = mod(c.modeT, SHOT * 3);
        let shot = Math.floor(st / SHOT);
        let u = mod(st, SHOT) / SHOT;
        let e = mathx.smoothstep(0, 1, u);
        let P = p.pos, F = p.fwd, Rt = p.right;
        let Yt = Vector.xyz(0, 1, 0);
        // landscape: the (hidden) lead sits at x ~0.62 with the echelon
        // trailing left into the open strip; portrait: the band between
        // masthead and menu
        let wide = mathx.saturate((c.aspect - 1) / 0.6);
        let ox = mathx.lerp(0.18, 0.24, wide);
        let oy = mathx.lerp(-0.02, 0.1, wide);
        let fovS = rad(shot == 2 ? 56 : 50);
        let eye: Vector;
        if (shot == 0) {
            // low behind, a slow push in over the water
            eye = P - F * <f32>(26 - 4 * e) - Rt * 3 + Yt * <f32>(2.2 + 0.6 * e);
            rollT = -0.03;
        } else if (shot == 1) {
            // low behind on the right, skimming the waves, drifting across
            eye = P - F * <f32>(22 - 3 * e) + Rt * <f32>(6 - 3 * e) + Yt * <f32>(1.4 + 0.5 * e);
            rollT = 0.025;
        } else {
            // crane: rise high behind, looking down the coast past the squadron
            eye = P - F * <f32>(30 + 5 * e) + Yt * <f32>(8 + 5 * e) - Rt * <f32>(2 + 2 * e);
            rollT = 0.04 - 0.08 * e;
        }
        let look = frameAt(eye, P + Yt * 0.3, ox, oy, c.aspect, fovS);
        c.eye = eye;
        c.look = look;
        c.roll = rollT;
        // dip to black around each cut
        let tc = mod(st, SHOT);
        c.cut = 1 - lmin(mathx.smoothstep(0, 0.6, tc), 1 - mathx.smoothstep(SHOT - 0.6, SHOT, tc));
        if (c.modeT < SHOT) c.cut = lmax(0, c.cut - (1 - mathx.smoothstep(0, 0.6, c.modeT)));
        fovT = rad(shot == 2 ? 60 : 52);
        c.fov = fovT;
        rate = 50;
    } else if (mode == "briefing") {
        // swoop: from high in front of the pilot, around the left side, down
        // to over the shoulder looking up the route; then idles until launch
        let f = p.fwd, rt = p.right;
        let k = mathx.easeInOutCubic(c.modeT / 3.6);
        let bx = briefFrame(c.aspect), by = BF_Y, brad = BF_D;
        let idle = mathx.smoothstep(3.6, 6, c.modeT);
        let th = mathx.lerp(rad(105), rad(12), k) + idle * Math.sin((c.modeT - 3.6) * 0.35) * 0.1;
        let rd = mathx.lerp(22, brad, k);
        let h = mathx.lerp(10, 1.2 + (brad - 7.2) * 0.12, mathx.smoothstep(0, 1, k)) + idle * Math.sin((c.modeT - 3.6) * 0.5) * 0.25;
        let back = -Math.cos(th) * rd;
        let side = Math.sin(th) * rd;
        let eye = p.pos + f * <f32>back + rt * <f32>side + mathx.v3(0, h, 0);
        let ahead = p.pos + f * 34 - rt * 2.5 + Vector.xyz(0, 2.4, 0);
        let look = mathx.vlerp(p.pos + Vector.xyz(0, 0.6, 0), ahead, mathx.smoothstep(0.55, 1, k));
        let fovB = rad(mathx.lerp(46, 56, k));
        let lookEnd = frameAt(eye, p.pos, bx, by, c.aspect, fovB);
        look = mathx.vlerp(look, lookEnd, mathx.smoothstep(0.35, 1, k));
        if (c.modeT < dt * 1.5) {
            c.eye = eye;
            c.look = look;
        }
        c.eye = mathx.vdamp(c.eye, eye, 6, dt);
        c.look = mathx.vdamp(c.look, look, 6, dt);
        fovT = fovB;
        rollT = mathx.lerp(-0.12, 0.03, k);
        rate = 4;
    } else if (mode == "launch") {
        // countdown: two shots while the pack spools up, cut on the 1; eases
        // in from wherever the briefing left the eye
        let eye = launchPose(c, p, c.modeT);
        let look = LP_LOOK, yaw = LP_YAW;
        slotX0 = LP_X0;
        slotX1 = LP_X1;
        slotY0 = LP_Y0;
        slotY1 = LP_Y1;
        let w = mathx.easeOutCubic(mathx.saturate(c.modeT / 0.45));
        c.eye = mathx.vlerp(c.holdEye, eye, w);
        c.look = mathx.vlerp(c.holdLook, look, w);
        let bt = mod(c.modeT, 1);
        let punch = c.modeT < 3 ? Math.exp(-bt * 8) * 0.8 : 0.0;
        fovT = launchFov(c.modeT) + rad(punch * 2.5);
        rollT = -Math.sin(yaw) * 0.1;
        rate = 4;
        if (c.modeT >= LAUNCH_CUT && c.modeT - dt < LAUNCH_CUT) {
            // the cut lands whole: no roll or fov easing across it
            c.roll = rollT;
            c.fov = fovT;
        }
    } else if (mode == "go") {
        // a blink of a hold, then the eye rides the blast-off into the chase
        // pose (the portrait lens eases in from here, GO_LENS_T)
        lensTick(c, p, dt);
        let eyeC = chasePose(c, p, dt);
        let lookC = CP_LOOK, fovC = CP_FOV, rollC = CP_ROLL;
        let k = mathx.saturate((c.modeT - 0.08) / 0.6);
        let e = mathx.easeInOutCubic(k);
        let watch = p.pos + p.fwd * 14 + Vector.xyz(0, 0.8, 0);
        let lookHold = mathx.vlerp(c.holdLook, watch, mathx.smoothstep(0, 0.2, c.modeT));
        // the waiting eye is dragged along behind him so the gap never opens
        let hold = c.holdEye + p.fwd * <f32>lmax(0, mathx.dot(p.pos - c.holdEye, p.fwd) - 9);
        c.eye = mathx.vlerp(hold, eyeC, e);
        c.look = mathx.vlerp(lookHold, lookC, e);
        fovT = mathx.lerp(rad(50), fovC, e);
        rollT = rollC * e;
        rate = 8;
        if (c.modeT >= 1.0) setMode(c, "chase");
    } else if (mode == "chase") {
        lensTick(c, p, dt);
        let eye = chasePose(c, p, dt);
        let look = CP_LOOK, fovC = CP_FOV, rollC = CP_ROLL;
        c.eye = clearEye(c, eye, p.pos, dt, c.lookMode == "chase", c.eye);
        // (a framed boss is held tighter: a lagging gaze drifts it off frame)
        c.look = mathx.vdamp(c.look + c.thrW, look, 10 + 8 * mathx.saturate(c.focusW * 6.5), dt);
        fovT = fovC;
        rollT = rollC;
    } else if (mode == "hold") {
        // eye coasts to a stop, watching the pilot (crash, outro fly-away);
        // after a crash it eases to the death cam's clear slot instead
        if (c.death) {
            // a hard cut on the crash (under its flash)
            deathUpdate(c, mathx.v3(<f64>p.pos.x, lmax(0.5, <f64>p.pos.y), <f64>p.pos.z), dt);
        } else {
            c.drift = mathx.vdamp(c.drift, Vector.xyz(0, 0, 0), 1.1, dt);
            c.eye = c.eye + c.drift * <f32>dt + mathx.v3(0, dt * 0.6, 0);
        }
        let look = mathx.v3(<f64>p.pos.x, lmax(0.5, <f64>p.pos.y) + 0.6, <f64>p.pos.z);
        if (c.exitW > 0) look = mathx.vlerp(look, c.exitLook, c.exitW);
        // (the death cam rides with him: its gaze stays on him)
        c.look = c.death ? look : mathx.vdamp(c.look, look, 4, dt);
        fovT = rad(52);
        rollT = 0;
    } else if (mode == "results") {
        // the report's backdrop: rise to a high vista back along the route
        // looking down the course where he flew, drifting slowly
        let k = mathx.easeInOutCubic(mathx.saturate(c.modeT / 2.4));
        let E = level.eye;
        let top: Vector;
        let target: Vector;
        if (p.s > E.s - 700) {
            // mission complete: high over the water well back from the Eye,
            // looking at it over the last spires
            let sb = lmax(0, E.s - 680 - c.modeT * 3);
            top = railPoint(sb, 50, 190);
            target = railPoint(E.s, E.x, E.y + 10);
        } else {
            let back = 240 + c.modeT * 2;
            let sb = lmax(0, lmin(p.s, level.track.length - 1) - back);
            top = railPoint(sb, 0, 120);
            track.frame(level.track, sb);
            let tf = track.FRAME_F;
            let hf = mathx.norm(Vector.xyz(tf.x, 0, tf.z));
            // a gentle look down the route with the horizon in the top third
            target = top + hf * 400 + Vector.xyz(0, -80, 0);
        }
        c.eye = mathx.vlerp(c.holdEye, top, k);
        let look = mathx.vlerp(c.holdLook, target, k);
        c.look = mathx.vdamp(c.look, look, 3, dt);
        fovT = rad(55);
    }

    if (mode != "chase" && mode != "go") {
        if (mode == "hold" && !c.death && c.lensW > 1e-3) {
            c.lensW = mathx.damp(c.lensW, 0, LENS_OUT, dt);
        } else {
            c.lensW = 0;
        }
        c.lensX = 0;
        c.lean = 0;
        c.faceSide = 0;
    }
    c.fovKick = mathx.damp(c.fovKick, 0, 3, dt);
    c.push = mathx.damp(c.push, 0, 2.5, dt);
    c.focusW = lmax(0, c.focusW - dt * 1.5);
    c.fov = mathx.damp(c.fov, fovT + c.fovKick, 4, dt);
    c.roll = mathx.damp(c.roll, rollT, rate, dt);
    c.twist = mathx.damp(c.twist, 0, 1.2, dt);

    // the hero never leaves the safe zone while flying or on the launch pad
    if (mode == "launch") {
        c.look = clampToSlot(c, p.pos, c.look, slotX0, slotX1, slotY0, slotY1);
    } else if (mode == "go") {
        // GO! zooms through the lens for ~0.5 s: he keeps the last shot's slot
        // beside it, then eases into the safe zone without a jump
        launchSides(c.aspect);
        let sB = LS_B;
        let x0 = launchSlot(c.aspect, sB, true), x1 = SL_X1, y0 = SL_Y0, y1 = SL_Y1;
        let inSlot = clampToSlot(c, p.pos, c.look, x0, x1, y0, y1);
        c.look = mathx.vlerp(inSlot, clampToZone(c, p.pos, c.look), mathx.smoothstep(0.35, 1.0, modeT0));
    } else if (mode == "chase") {
        c.look = clampToZone(c, p.pos, c.look);
        if (c.lookMode == "chase") {
            let v = c.look - c.eye;
            let d = mathx.len(v);
            if (d > 1e-3 && dt > 1e-5) {
                let dir = turnRate(c, v / <f32>d, dt);
                if (TR_HELD) {
                    c.look = c.eye + dir * <f32>d;
                    hardEdge(c, p.pos, dir, d, dt);
                }
            }
        }
    }

    // the held lens never sits inside a rock: pull it in toward the pilot
    // in front of whatever stands between them (the chase keeps its own
    // clearance: clearEye)
    let w = c.world;
    if (w != null && mode == "hold" && !c.death) {
        let d = c.eye - p.pos;
        let n = 6;
        for (let i = 1; i <= n; i++) {
            let k = <f64>i / <f64>n;
            let q = p.pos + d * <f32>k;
            if (w.solid(<f64>q.x, <f64>q.y, <f64>q.z, 0.7)) {
                c.eye = p.pos + d * <f32>lmax(0.25, (<f64>i - 1.2) / <f64>n);
                break;
            }
        }
        c.eye = c.eye + pushOut(c, c.eye, CHASE_HARD);
    }

    // never dip the lens into the sea
    if (c.eye.y < 0.55) c.eye = Vector.xyz(c.eye.x, 0.55, c.eye.z);
    let nd = mathx.norm(c.look - c.eye);
    if (mode == "chase" && c.lookMode == "chase") {
        // the rate carried into the next frame: the turn drawn (incl. the
        // hard edge's, up to TURN_MAX); a flip carries none
        if (dt > 1e-5) {
            let ax = mathx.cross(c.lookDir, nd);
            let sl = mathx.len(ax);
            let ang = Math.atan2(sl, mathx.dot(c.lookDir, nd));
            c.lookOm = ang >= 3 || sl < 1e-9 ? ZERO : ax * <f32>(lmin(ang / dt, TURN_MAX) / sl);
        }
    } else {
        c.lookOm = ZERO;
    }
    c.lookDir = nd;
    c.lookMode = mode;

    // set-piece beat on top of the base shot
    let eyeF = c.eye, lookF = c.look, fovF = c.fov, rollF = c.roll + c.twist;
    // (the portrait lens's extra width, gone as a beat takes over)
    let lensV = c.lensW > 0 ? lensFov(c, c.fov) - effFov(c.fov, c.aspect) : 0.0;
    if (c.beat != "") {
        let be = beatPose(c, p);
        let bl = BP_LOOK, bfov = BP_FOV, broll = BP_ROLL, bw = BP_W;
        lensV *= 1 - bw;
        if (bw > 0) {
            eyeF = mathx.vlerp(eyeF, be, bw);
            lookF = mathx.vlerp(lookF, bl, bw);
            fovF = mathx.lerp(fovF, bfov, bw);
            rollF = mathx.lerp(rollF, broll, bw);
        }
        if (eyeF.y < 0.55) eyeF = Vector.xyz(eyeF.x, 0.55, eyeF.z);
    }

    // basis + shake (trauma^2)
    let cam = c.cam;
    let fwd = mathx.norm(lookF - eyeF);
    let rtv = mathx.norm(mathx.cross(fwd, Vector.xyz(0, 1, 0)));
    let upv = mathx.cross(rtv, fwd);
    upv = mathx.rotateAxis(upv, fwd, rollF);
    let sh = c.shake;
    c.shake = lmax(0, sh - dt * 2.2);
    let amp = sh * sh * 0.5;
    // (a jolt never shoves the lens into the rock it is kept off: near rock
    // the shake is mostly roll)
    let ampT = amp;
    if (amp > 0.02 && w != null && (mode == "chase" || mode == "hold" || mode == "go") && ((c.lensW > 0 && p.grazing && c.beat == "") || w.solid(<f64>eyeF.x, <f64>eyeF.y, <f64>eyeF.z, chaseMargins(c) + 0.3))) {
        // (the portrait lens backs off from the rock he scrapes: the scrape's
        // shake is mostly roll there too)
        ampT *= 0.25;
    }
    let jx = (mathx.noise2(t * 24, 1.3) - 0.5) * ampT;
    let jy = (mathx.noise2(t * 22, 7.1) - 0.5) * ampT;
    let jr = (mathx.noise2(t * 19, 3.7) - 0.5) * amp * 0.08;
    cam.eye = eyeF + rtv * <f32>jx + upv * <f32>jy;
    cam.target = lookF + rtv * <f32>jx + upv * <f32>jy;
    cam.up = mathx.rotateAxis(upv, fwd, jr);
    // keep a minimum horizontal field of view on narrow (portrait) viewports
    cam.fov = effFov(fovF, c.aspect) + lensV;
    cam.near = NEAR;
    if (c.beat == "" && (mode == "chase" || mode == "go" || mode == "hold") && !c.fallsPull) {
        cam.near = fallsNear(cam.eye, fwd, mathx.cross(fwd, upv), upv, cam.fov, c.aspect, p.pos, 0);
    }
    // (curtainPull's verdict holds for this frame's draw only)
    c.fallsLive = c.fallsPull;
    c.fallsPull = false;

    // visor sway: springs against the pilot's angular motion
    let yawRate = p.vx / playerMod.MAX_VX;
    let pitchRate = p.vy / playerMod.MAX_VY;
    let k = 55.0, d = 8.0;
    c.visorVy += (-(yawRate * 0.045) - c.visorYaw) * k * dt - c.visorVy * d * dt;
    c.visorVp += ((pitchRate * 0.03) - c.visorPitch) * k * dt - c.visorVp * d * dt;
    c.visorYaw += c.visorVy * dt;
    c.visorPitch += c.visorVp * dt;
}

// The chase frame's probes (lens clearance, face back-off, lean) lie round
// him and the lens: within FRAME_REACH m (xz) of either, one near list
// serves them while the scenery still bakes (rockNear).
const FRAME_REACH: f64 = 30;
export function update(c: Rig, p: Player, t: f64, dt: f64): void {
    let w = c.world;
    let on = false;
    if (w != null && c.mode == "chase" && !c.death) {
        let e = c.eye, P = p.pos;
        let r = FRAME_REACH;
        on = w.rockNear(true, lmin(<f64>e.x, <f64>P.x) - r, lmin(<f64>e.z, <f64>P.z) - r, lmax(<f64>e.x, <f64>P.x) + r, lmax(<f64>e.z, <f64>P.z) + r);
    }
    updateRig(c, p, t, dt);
    if (on) w!.rockNear(false, 0, 0, 0, 0);
}
