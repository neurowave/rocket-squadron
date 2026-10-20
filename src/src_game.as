// Port of src/game.luau. CLOUDBREAKER: the scripted layout that runs the whole game.
// Owns the frame loop and the app state machine, and wires input, the
// simulation modules and the renderer together. Rive artboards (HUD, pilot,
// wingmen, reticle, lock-on, popups) arrive as script inputs, are instanced
// here with their own view models, and are rendered to textures by the renderer.
// See DESIGN.md for the view model contract and module map.
//
// App states: title -> briefing -> launch -> playing <-> paused
//             playing -> dying -> gameover | playing -> outro -> results
//             launch -> training (flight school) -> playing (the cut)
//
// Port: the Luau local functions taking `self` are Game methods; module
// locals are module globals. types.Ctx is GameCtx (buildCtx's closures), the
// camera rig's solid / rockNear GameWorld, the wingmen keeper GameKeeper,
// hud.bossPoint's projector GameProjector, the school's env GameEnv. Local
// multi-returns land in Game fields (commTyped -> ctShows, offHero -> ohX..,
// bossHullRect -> hrU0.., archWindow -> AW_*). The setup Luau does in init
// runs in loading steps on the first advance(s) (watchdog: R.create, the
// scenery plan, the storm meshes, the start chunks: Luau's START_SYNC); the
// advances it spans are replayed once it is done, so frames line up with
// Luau's. --define=TRK=1: the mission oracle's TRK lines; DBG0 / DBG1: per
// frame comms / alert / enemy / lock dumps over those TRK frames.
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Vector } from "rive/vector";
import { Artboard, NodeData } from "rive/artboard";
import { ViewModel } from "rive/data";
import { Mat2D } from "rive/mat2d";
import { PointerEvent, KeyboardEvent, GamepadEvent } from "rive/events";
import { format, FormatArg } from "rive/format";
import { Pattern } from "rive/pattern";
import { clock } from "rive/os";
import { ownersCount } from "rive/handles";
import { HUGE, mod, lmin, lmax, lclamp, lstr, lsub, lfind, lrandom, lrandomseed, opt } from "./lib/compat";
import * as mathx from "./lib/mathx";
import * as R from "./render/renderer";
import * as palette from "./world/palette";
import { Palette } from "./world/palette";
import * as track from "./world/track";
import * as level from "./world/level";
import * as scenery from "./world/scenery";
import { Chunk } from "./world/scenery";
import * as input from "./game/input";
import * as vmx from "./game/vm";
import { Bag } from "./game/vm";
import * as types from "./game/types";
import * as enemies from "./game/enemies";
import * as ai from "./game/ai_types";
import * as events from "./game/events";
import * as fx from "./game/fx";
import * as sfx from "./game/sfx";
import * as playerMod from "./game/player";
import * as camera from "./game/camera";
import * as weapons from "./game/weapons";
import * as wingmen from "./game/wingmen";
import * as popups from "./game/popups";
import * as scoring from "./game/scoring";
import * as rings from "./game/core_rings";
import * as autopilot from "./game/core_autopilot";
import * as hud from "./game/core_hud";
import * as wake from "./game/core_wake";
import * as cmode from "./game/core_mode";
import * as cquality from "./game/core_quality";
import * as training from "./game/core_training";
import * as pages from "./game/core_pages";
import { CommLine, CoreAlert } from "./game/core_pages";
import * as cprint from "./game/core_print";
import { PrintVals } from "./game/core_print";
import * as hudlive from "./game/core_hudlive";
import { REPLAY_N, REPLAY_HEX } from "./game/replay_track";

// mission oracle: --define=TRK=1 logs a TRK line every 30 frames
declare const TRK: i32;
// (debug) every CENSUS frames: owned host handles, heap pages, collection sizes
declare const CENSUS: i32;
// (debug) log advance / draw calls over PERF ms
declare const PERF: i32;
// (debug) per-frame DBG lines for TRK frames DBG0..DBG1
declare const DBG0: i32;
declare const DBG1: i32;
// oracle: --define=REPLAY=1 replaces autopilot.drive by the recorded controls in game/replay_track.as
declare const REPLAY: i32;
let replayK: i32 = 0;
// oracle: --define=APR=1 logs autopilot.drive's controls per call (the Luau recording's APR lines)
declare const APR: i32;
let aprK: i32 = 0;
// oracle: --define=FRAMECLOCK=1 runs the sound clock on game frames, not the audio device (its cooldowns gate
// math.random draws: on wall time the shared stream depends on how fast frames run)
declare const FRAMECLOCK: i32;
class FrameClock extends sfx.TimeFn {
    t: f64 = 0;
    time(): f64 {
        return this.t;
    }
}
let frameClock = new FrameClock();

function hexAt(s: string, i: i32, n: i32): u64 {
    let v: u64 = 0;
    for (let k = 0; k < n; k++) {
        let c = s.charCodeAt(i + k);
        v = (v << 4) | <u64>(c <= 57 ? c - 48 : c - 87);
    }
    return v;
}

// (the recording's controls for this drive call, and drive's one draw when the shield dropped)
function replayDrive(ap: autopilot.Pilot, p: playerMod.Player, c: playerMod.Controls): void {
    let k = replayK++;
    if (k >= REPLAY_N) {
        c.sx = 0;
        c.sy = 0;
        c.fire = false;
        c.boost = false;
        c.rollL = false;
        c.rollR = false;
    } else {
        let o = k * 33;
        let v = <i32>hexAt(REPLAY_HEX, o + 32, 1);
        c.sx = reinterpret<f64>(hexAt(REPLAY_HEX, o, 16));
        c.sy = reinterpret<f64>(hexAt(REPLAY_HEX, o + 16, 16));
        c.fire = (v & 1) != 0;
        c.boost = (v & 2) != 0;
        c.rollL = (v & 4) != 0;
        c.rollR = (v & 8) != 0;
    }
    if (p.shield < ap.lastShield - 0.01) lrandom();
    ap.lastShield = p.shield;
}

// View models the artboard inputs bind (scene/main.rml: Hud, Pilot, Reticle;
// LockOn and Popup are weapons.LockOn and popups.Popup).
export class Hud extends ViewModel {
    constructor(handle: u32) {
        super(handle);
    }
}
export class Pilot extends ViewModel {
    constructor(handle: u32) {
        super(handle);
    }
}
export class Reticle extends ViewModel {
    constructor(handle: u32) {
        super(handle);
    }
}

// (ViewModel.create returns the base class and the renderer / attach calls
// take plain Artboards: the typed views of the same objects)
unsafe function asHud(vm: ViewModel): Hud {
    return changetype<Hud>(vm);
}
unsafe function asPilot(vm: ViewModel): Pilot {
    return changetype<Pilot>(vm);
}
unsafe function asReticle(vm: ViewModel): Reticle {
    return changetype<Reticle>(vm);
}
unsafe function plainHud(a: Artboard<Hud>): Artboard {
    return changetype<Artboard>(a);
}
unsafe function plainPilot(a: Artboard<Pilot>): Artboard {
    return changetype<Artboard>(a);
}
unsafe function plainReticle(a: Artboard<Reticle>): Artboard {
    return changetype<Artboard>(a);
}
unsafe function worldT(n: NodeData): Mat2D {
    return n.worldTransform();
}

function FN(v: f64): FormatArg {
    return FormatArg.number(v);
}
function FS(v: string): FormatArg {
    return FormatArg.string(v);
}

// 1-based list helpers (table.insert(t, i, x) / table.remove(t, i))
function ins<T>(a: Array<T>, i: i32, x: T): void {
    a.push(x);
    for (let k = a.length - 1; k > i; k--) a[k] = a[k - 1];
    a[i] = x;
}
function rem<T>(a: Array<T>, i: i32): void {
    a.splice(i, 1);
}

// A script line the radio holds for a quieter spot (QA PT1-4): pushed at
// rail s, or as its pair (a warning) shows.
class Later {
    s: f64 = 0;
    pair: string? = null;
    who: string = "";
    speaker: string = "";
    text: string = "";
    seconds: f64 = 0;
    mood: string? = null;
    prio: f64 = 0;
}

// RETRY from here (QA PT1-6): the run as it stood when he crossed a
// checkpoint (section edge).
class Checkpoint {
    idx: i32 = 0; // section
    s: f64 = 0;
    label: string = ""; // '02 SEA ARCH'
    shield: f64 = 0;
    boost: f64 = 0;
    bombs: f64 = 0;
    sc: scoring.Snap;
    kills: f64 = 0;
    killsTotal: f64 = 0;
    shotsFired: f64 = 0;
    shotsHit: f64 = 0;
    archDone: bool = false;
    stings: Map<string, bool> = new Map<string, bool>();
    down: Map<i32, bool> = new Map<i32, bool>();
    constructor(sc: scoring.Snap) {
        this.sc = sc;
    }
}

// A wingman's formation call waiting out a boss fight.
class HeldLine {
    line: wingmen.Line;
    age: f64 = 0;
    constructor(line: wingmen.Line) {
        this.line = line;
    }
}

class Memo {
    cp: Checkpoint? = null; // the last checkpoint passed this attempt (Game.cpLabel)
    retryCp: bool = false; // the retry under way picks up at cp
    retried: bool = false; // a retry since the title: the opening lines heard are skipped
    heard: Map<string, bool> = new Map<string, bool>(); // lines played since the mission started from the title
    later: Array<Later> = new Array<Later>(1); // script lines held for their spot (scriptLine), 1-based
    rockHit: bool = false; // the first rock hit of the run had its line
    cause: string = ""; // what hit him last (Game.failCause)
    rt: f64 = 0; // real seconds (the radio and slab rows)
    slab: string = ""; // the headline in the alert slot (alertShow)
    annN: Map<i32, f64> = new Map<i32, f64>(); // per section: times named running (card / slab / route / radio)
    annT: Map<i32, f64> = new Map<i32, f64>(); // per section: real s it was named last
    give: bool = false; // a line started under a slab: it gives way (alertPump)
    clrT: f64 = 0; // a slab given way to a line: Hud.downed holds the slot idle this long
    holdT: f64 = 0; // ...and the next slab (not a warning) waits for that line's letters
    goT: f64 = 0; // s the visor stays down past a checkpoint count's GO (pages.GO_HOLD)
}

class StingDue {
    kind: string = "";
    title: string = "";
    sub: string = "";
    t: f64 = 0;
}

const BOMBS: f64 = 2; // BOMB charges per run
const BOMB_CD: f64 = 12; // seconds between bombs
const BOMB_REACH: f64 = 170; // meters
const BRIEF_ATTRACT: f64 = 14; // seconds the briefing waits before it launches by itself
const NO_RINGS: Array<rings.Ring> = new Array<rings.Ring>(1);
const SCHOOL_CRUISE: f64 = 45; // ctx.holdSpeed in the school: cruise 45, boost 70, brake 28
const LOG_TRAIN: bool = false; // debug: the flight school director's log (t, s, lesson, phase, cause)
// (port) wall ms of loading steps started in one advance (each step stays
// well under the 200 ms watchdog in the dev build)
const LOAD_MS: f64 = 90;
// a scenery plan this slow (ms; ~28 published, ~165 in the dev preview) bakes the whole
// course while loading
const SLOW_PLAN_MS: f64 = 80;
let seeded: bool = false; // debugSeed applied (once per session)

// The pilot is flying the rail: the mission, or the flight school.
function flying(st: string): bool {
    return st == "playing" || st == "training";
}

// Points on the 3.4 m hero sprite (x right, y up from its center) where the
// jets leave the pack, the flames end and the wrist blasters sit. The painted
// (raster) hero dives flat; the vector rig stands upright.
class Anchors {
    nozX: f64;
    nozY: f64;
    tipY: f64;
    handX: f64;
    handY: f64;
    constructor(nozX: f64, nozY: f64, tipY: f64, handX: f64, handY: f64) {
        this.nozX = nozX;
        this.nozY = nozY;
        this.tipY = tipY;
        this.handX = handX;
        this.handY = handY;
    }
}
const ANCHORS_RASTER: Anchors = new Anchors(0.25, 0.06, -0.42, 1.12, 0.16);
const ANCHORS_VECTOR: Anchors = new Anchors(0.17, -0.13, -0.72, 0.69, -0.08);

// The painted hero changes pose (Solo in the Pilot artboard), so its flame tips
// and wrist muzzles are read from named nodes every frame (FlameTipL/R,
// RasterMuzzleL/R; see docs/notes/characters.md).
class HeroNodes {
    tipL: NodeData;
    tipR: NodeData;
    muzL: NodeData;
    muzR: NodeData;
    w: f64;
    h: f64;
    constructor(tipL: NodeData, tipR: NodeData, muzL: NodeData, muzR: NodeData, w: f64, h: f64) {
        this.tipL = tipL;
        this.tipR = tipR;
        this.muzL = muzL;
        this.muzR = muzR;
        this.w = w;
        this.h = h;
    }
}
const HERO_M: f64 = 3.4; // hero sprite size (m)

function readHeroNodes(art: Artboard<Pilot>): HeroNodes? {
    let a = art.node("FlameTipL"), b = art.node("FlameTipR"), c = art.node("RasterMuzzleL"), d = art.node("RasterMuzzleR");
    if (a != null && b != null && c != null && d != null) {
        return new HeroNodes(a, b, c, d, art.width, art.height);
    }
    return null;
}

// Hero texture follows the render height so the painted art is never magnified.
function heroTexSize(r: R.Gfx): f64 {
    return r.rh > 1100 ? 1024 : 768;
}

function sceneState(st: string): string {
    if (st == "dying" || st == "outro" || st == "training" || st == "relaunch") {
        return "playing";
    } else if (st == "retry") {
        return "results";
    }
    return st;
}

function menuCount(st: string): f64 {
    if (st == "title") {
        return 5;
    } else if (st == "paused") {
        return 5;
    } else if (st == "results") {
        return 2;
    } else if (st == "gameover") {
        // RETRY (from the last checkpoint) | RESTART MISSION | TITLE
        return 3;
    }
    return 0;
}

// Rock between the lens E and a point P (colliders probed every ~4 m along
// the line, 2 m clear of both ends): a flyer behind a canyon wall.
const WING_SEEN_FAR: f64 = 160; // m: past this a wingman is a speck, no panel fades for him
// (while the scenery still bakes a plain probe checks every pending chunk:
// a long line's probes then share one near list, the same answers)
const sightNear: scenery.Near = scenery.newNear();
const SIGHT_NEAR_N: f64 = 8;

function portalLine(text: string): bool {
    return lfind(text.toLowerCase(), "portal") != 0;
}

// A line about the sea arch ahead ('Arch dead ahead...'): it has to be over
// before he gets there (QA M14: the warning was still typing inside the arch).
function archLine(text: string): bool {
    let t = text.toLowerCase();
    return Pattern.find(t, "%f[%a]arch%f[%A]") != null || lfind(t, "mines ahead") != 0;
}

// The lens drops to the water for the arch fly-through ~0.55 s out (archLow).
const ARCH_SHOT: f64 = 0.55;

let followWait: f64 = 0; // seconds the free channel has waited for a boss's follow-up line (commPump, QA HUD2-6)
const FOLLOW_WAIT: f64 = 0.6;

// How long a line stays up: long enough to be typed at a readable pace.
function commDur(seconds: f64, text: string): f64 {
    return lmax(lmax(seconds, 1.8 + <f64>text.length * 0.042), pages.readNeed(text));
}

// Outro push into the Eye (QA CD-1): the eye stops OUTRO_STOP m short of its
// plane, the gaze runs on OUTRO_LOOK m down its axis once he is in, the
// white-out runs over enteredT OUTRO_WHITE0..1 (s) as the lens nears the
// swirl's white centre, and results follow at OUTRO_END. The dive post stays
// under OUTRO_DIVE: past 0.6 its toon tunnel grew out of the white as a
// second disc.
const OUTRO_STOP: f64 = 12;
const OUTRO_LOOK: f64 = 300;
const OUTRO_WHITE0: f64 = 1.1;
const OUTRO_WHITE1: f64 = 1.65;
const OUTRO_END: f64 = 1.85;
const OUTRO_DIVE: f64 = 0.58;

const LOG_COMMS: bool = false; // debug: print the channel (PUSH / PLAY / OUT / CUT / CLOSE / drops) with frame, s, real time
let logF: f64 = 0; // frame, real seconds (LOG_COMMS)
let logT: f64 = 0;
let logSting: bool = false;
let trkF: f64 = 0; // (TRK) advance frames
let perfFrame: f64 = 0; // (PERF) ms of the last R.frame

function CLline(l: CommLine): string {
    return format('%s p%d%s "%s"', [FS(l.speaker), FN(l.prio), FS(l.wing ? "w" : l.yield ? "y" : ""), FS(l.text)]);
}

// a wingman's line stays up by its length (at least 2.6 s; it held 4.2 s)
const WING_SECONDS: f64 = 2.6;

// The mission script's spoken cues by rail distance (events.luau `say` cues:
// keep in step). The wingmen's chatter keeps clear of them: a wingman's line
// only starts when it is over before the next one (QA M14: scripted beats
// start on their cue; join / peel calls and reactions wait or drop). 1-based.
const BEATS: Array<f64> = [
    0.0,
    25, 1240, pages.MINES_S, level.anchors.archS + 4, 1900, 2400, 2870, 3120, 3370, 3600,
    level.portalS + 60, level.portalS + 320, level.portalS + 570, 6620,
    level.anchors.fallsS - 330, 7240,
];
// the finale (the visor goes with the dive into the Eye): he comes in flat out
const FINALE_S: f64 = level.eye.s - 70;

// a line this close to typed out finishes before another takes over
const FINISH: f64 = 0.6;
// a typed-out line gives way to a scripted beat that has waited BEAT_WAIT,
// once it has been up whole for CUT_TAIL
const CUT_TAIL: f64 = 0.4;
const BEAT_WAIT: f64 = 0.5;

// Luau string.find(text, '[%.!?]+%s', i): the 1-based end of the match (the
// whitespace), 0 = nil
function sentEnd(text: string, i: i32): i32 {
    let m = Pattern.find(text, "[%.!?]+%s", i - 1);
    return m == null ? 0 : m.end;
}

// What a wingman can say in `room` s before the next scripted beat: the
// whole line, else its leading sentences ('Back with you!'), nil when not
// even the first is over by then (the beat may wait BEAT_WAIT for it). A
// shot reaction (`tail`) says its last sentence instead ('Roll it off!'),
// which may hold the beat REACT_LATE more (the beats leave no gap that
// long in the Low Pass: it never played).
function wingOver(t: string): f64 {
    return pages.typeOut(t, commDur(WING_SECONDS, t)) + CUT_TAIL - BEAT_WAIT;
}

function wingFit(text: string, room: f64, tail: bool): string? {
    const REACT_LATE: f64 = 0.5;
    if (wingOver(text) <= room) {
        return text;
    }
    if (tail) {
        let m = Pattern.find(text, "[%.!?]%s+([^%.!?]+[%.!?]+)$");
        if (m == null) return null;
        let last = m.group(1);
        return wingOver(last) <= room + REACT_LATE ? last : null;
    }
    let best: string? = null;
    let i = 1;
    while (true) {
        let b = sentEnd(text, i);
        if (b == 0) {
            break;
        }
        let head = lsub(text, 1, b - 1);
        if (wingOver(head) > room) {
            break;
        }
        best = head;
        i = b + 1;
    }
    return best;
}

const LOG_STING: bool = false; // debug: print every sting as it fires
const LOG_STATS: bool = false; // debug: print the renderer's budget stats once a second
// meters the hero is drawn nearer the lens while he scrapes rock (more when
// the sight line meets rock sooner: camera.rockEntry)
const HERO_PULL: f64 = 4;
const LOG_CAM: bool = false; // debug: boss framing every 10 frames

// A boss hull's box in its model frame (mesh units, before its scale; x, y,
// z pairs, 1-based), boss_stormcrow.luau HULL's bounds: the STORMCROW's
// gasbag (z -33.6..33.2, r 9.5), tail fins (13.4 out, to z 34.9), outer
// engine pods' propeller discs (x +-15.5 +- 3.1), gondola keel (y -20.3);
// the pennant (from y -13.2, z 13.4, ~13 long) swings inside it. Others:
// the boss framing sphere (enemies.focus).
function hullBoxes(): Map<string, Array<f64>> {
    let m = new Map<string, Array<f64>>();
    m.set("stormcrow", [0.0, -18.6, 18.6, -20.3, 13.4, -33.6, 34.9]);
    return m;
}
const HULL_BOX: Map<string, Array<f64>> = hullBoxes();

// Set-piece stings (DIRECTION #21): real seconds of bullet time per kind
// (the screens card runs 1.2-2.5 s).
function stingHolds(): Map<string, f64> {
    let m = new Map<string, f64>();
    m.set("boss_stormcrow", 2.3);
    m.set("boss_watcher", 2.3);
    m.set("down_stormcrow", 2.5);
    m.set("down_watcher", 2.5);
    m.set("chapter_violet", 2.0);
    m.set("arch_threaded", 1.5);
    m.set("mission_complete", 2.6);
    m.set("training_complete", 2.5); // the certificate: real time, no bullet time, no beat
    return m;
}
const STING_HOLD: Map<string, f64> = stingHolds();
const STING_SCALE: f64 = 0.3; // bullet time
// Banners a sting already says (dropped once it played, when the UI has stings).
function stingDups(): Map<string, string> {
    let m = new Map<string, string>();
    m.set("STORMCROW DOWN", "down_stormcrow");
    m.set("WATCHER DESTROYED", "down_watcher");
    m.set("MISSION COMPLETE", "mission_complete");
    return m;
}
const STING_DUP: Map<string, string> = stingDups();

let camLogN: f64 = 0;

// The section an objective slab is about (its sub starts with the label); 0 = nil.
function objSection(sub: string): i32 {
    let secs = level.sections;
    for (let i = 1; i < secs.length; i++) {
        if (lfind(sub, secs[i].label) == 1) {
            return i;
        }
    }
    return 0;
}

// A checkpoint / objective result slab up when a boss takes the field
// gives way to her WARNING once its sub is out (the banner types it by
// frame 72; it stays up until the WARNING, 0.3 s later), SLAB_READ, or
// SLAB_BOSS after she came up: the WARNING (2.6 s) ends before her
// poster's last call (boss_stormcrow STING_AT + 1.2 = 3.9 s).
const SLAB_READ: f64 = 1.25;
const SLAB_BOSS: f64 = 0.9;
// A result slab due this close before a boss cue is not shown (she would
// cut it before its sub is read; the route tab says it): her WARNING and
// poster keep their beats.
const SLAB_SOON: f64 = 1.45;

// s, x0, x1, y0, y1 in rail coords (archWindow)
let AW_S: f64 = 0;
let AW_X0: f64 = 0;
let AW_X1: f64 = 0;
let AW_Y0: f64 = 0;
let AW_Y1: f64 = 0;
function archWindow(): f64 {
    // (level.anchors.arch is always there in the port: x center, y bottom,
    // w full width, h height)
    let a = level.anchors.arch;
    let hw = a.w, hh = a.h, cx = a.x, cy = a.y;
    AW_S = a.s;
    AW_X0 = cx - hw / 2;
    AW_X1 = cx + hw / 2;
    AW_Y0 = cy;
    AW_Y1 = cy + hh;
    return AW_S;
}

// Attract reel (DIRECTION #21): after ~25 s idle on the title, the autopilot
// flies a highlights reel with jump cuts; any input (or the end) returns to
// the title. Game.attract (optional) is true meanwhile (screens: the print
// lower-third). Clip s = rail distance it starts from; dur = real seconds.
class Clip {
    kind: string;
    s: f64;
    dur: f64;
    constructor(kind: string, s: f64, dur: f64) {
        this.kind = kind;
        this.s = s;
        this.dur = dur;
    }
}
const REEL_IDLE: f64 = 25;
const REEL: Array<Clip> = [
    new Clip("", 0, 0), // (slot 0)
    new Clip("launch", 0, 4.6),
    new Clip("arch", 1490, 6.2),
    new Clip("crow", 3585, 10.5),
    new Clip("portal", level.portalS - 165, 5.8),
    new Clip("watcher", 7440, 7),
    new Clip("finale", level.eye.s - 230, 9),
];
// the STORMCROW clip's fight cut short: its core goes after the reveal poster
const REEL_CROW_KILL: f64 = 6.2;

export class Game extends Layout {
    // artboard inputs (see scene/main.rml)
    @input hud: Artboard<Hud>? = null;
    @input pilot: Artboard<Pilot>? = null;
    @input reticle: Artboard<Reticle>? = null;
    @input lockon: Artboard<weapons.LockOn>? = null;
    @input popup: Artboard<popups.Popup>? = null;

    ctx: Context? = null;
    r: R.Gfx? = null;
    size: Vector = Vector.xy(0, 0);
    scale: f64 = 1;
    t: f64 = 0;
    dt: f64 = 0;
    // (port) loading steps done (init's work, see load)
    loadStep: i32 = 0;
    loaded: bool = false;
    lateDt: Array<f64> = []; // advances spent loading (replayed once loaded)
    drew: bool = false; // a draw since the last advance

    // view models
    gameVm: Bag? = null;
    hudVm: Bag? = null;
    pilotVm: Bag? = null;
    reticleVm: Bag? = null;
    hudArt: Artboard<Hud>? = null;
    pilotArt: Artboard<Pilot>? = null;
    reticleArt: Artboard<Reticle>? = null;
    pilotSprite: R.Sprite? = null;
    reticleSprite: R.Sprite? = null;
    hudCache: hud.Cache = hud.newCache();

    // app state
    state: string = "title";
    stateT: f64 = 0;
    menuIndex: f64 = 0;
    titlePanel: f64 = 0;
    countdown: f64 = 3;
    autopilotOn: bool = false;

    inp: input.Input = input.create();
    ctrl: playerMod.Controls = playerMod.newControls();
    auto: autopilot.Pilot = autopilot.create();
    player: playerMod.Player = playerMod.create();
    rig: camera.Rig = camera.create();

    chunks: Array<Chunk> = new Array<Chunk>(1);
    // (the real set is made in load, once the renderer exists: rings.create uploads meshes)
    rings: rings.Rings = new rings.Rings();
    weapons: weapons.Weapons = weapons.create();
    wing: wingmen.Wingmen = wingmen.create();
    pops: popups.Popups = popups.create();
    wake: wake.Wake = wake.create();
    sc: scoring.Scoring = scoring.create();
    pal: Palette = palette.coast;
    portalT: f64 = -1; // seconds since the portal dive (-1 before)
    archDone: bool = false;

    fx: fx.Fx = fx.create();
    enemies: ai.World? = null;
    events: events.Events = events.create();
    sfx: sfx.Sfx? = null;
    ctx2: GameCtx? = null;
    tp: types.Player = Game.newTp();
    commT: f64 = 0;
    warnT: f64 = 0;
    commQueue: Array<CommLine> = new Array<CommLine>(1); // 1-based
    commAge: f64 = 0; // seconds the current line has played
    commPrio: f64 = 0; // priority of the current line
    alerts: Array<CoreAlert> = new Array<CoreAlert>(1); // 1-based
    alertT: f64 = 0; // seconds the current alert still owns the slot
    alertAge: f64 = 0;
    alertPrio: f64 = 0;
    alertCut: bool = false; // the slab showing is a checkpoint / objective result raised before a boss took the field: her arrival cuts it
    alertBossT: f64 = 0; // seconds a boss has been on the field under an alertCut slab
    stats: types.Stats = new types.Stats();
    music: string = "";
    bossActive: bool = false;
    prevS: f64 = 0;
    lastShield: f64 = 1;
    hitStop: f64 = 0;
    heroPull: f64 = 0; // 0..1 while he scrapes rock: drawn nearer the lens (see HERO_PULL)
    splashed: bool = false;
    puffT: f64 = 0;
    sprayT: f64 = 0;
    musicOn: bool = true;
    soundOn: bool = true;
    launchT: f64 = -1; // seconds since blast-off (-1 before)
    launchX: f64 = 0; // takeoff point on the water (foam burst)
    launchZ: f64 = 0;
    porPos: Vector = Vector.xyz(0, 0, 0); // sky portal disc (world), facing porFwd
    porFwd: Vector = Vector.xyz(0, 0, -1);
    eyePos: Vector = Vector.xyz(0, 0, 0); // the Eye (final portal)
    eyeFwd: Vector = Vector.xyz(0, 0, -1);
    entered: bool = false; // outro: the pilot has dived into the Eye
    enteredT: f64 = 0;
    trails: Array<R.Trail> = new Array<R.Trail>(1); // exhaust L, exhaust R, vapor L, vapor R (1-based)
    smoke: R.Trail? = null; // crash: toon smoke ribbon behind the falling pilot
    camR: Vector = Vector.xyz(1, 0, 0); // camera basis (sprite-space anchors: nozzles, hands)
    camU: Vector = Vector.xyz(0, 1, 0);
    anchors: Anchors = ANCHORS_VECTOR; // sprite-space points on the hero art (meters, sprite center origin)
    trailPos: Vector = Vector.xyz(0, 0, 0); // last position the trails were fed from
    exVis: Array<f64> = [0.0, 1, 1]; // how much of each exhaust ribbon shows (wingmen.ribbonVis, eased), 1-based
    reflArt: Artboard<Pilot>? = null; // painted underside twin for the water
    reflVm: Bag? = null;
    reflSprite: R.Sprite? = null;
    heroNodes: HeroNodes? = null; // painted hero: flame tips + wrist muzzles, read from the artboard
    keeper: GameKeeper? = null; // keeps the wingmen inside the hero safe zone on screen
    anc: Array<f64> = [0.0, 0, 0, 0, 0, 0, 0, 0, 0]; // this frame's tipL x,y, tipR x,y, muzzleL x,y, muzzleR x,y (sprite meters), 1-based
    pausedFrom: string = "playing"; // the state RESUME returns to ('playing' or 'launch')
    pausedT: f64 = 0; // its stateT (the countdown picks up where it stopped)
    commText: string = ""; // the line on the comms channel now
    commLine: CommLine? = null; // the queued line it came from (a wingman's may be stepped on)
    commOut: f64 = 0; // seconds into the line by which the HUD types it out (its schedule)
    commOutAge: f64 = -1; // seconds into the line at which it was typed out (-1: not yet)
    commCutAt: f64 = -1; // letters out at which the line on air is replaced (-1: no takeover pending)
    commOn: bool = false; // the HUD's comms window is open
    commHold: f64 = 0; // real seconds the channel waits for a boss's reveal poster
    commBoss: bool = false; // a boss was up last frame (commHold starts as one comes up)
    quitArmed: bool = false; // pause: QUIT pressed once, the next press quits
    quitT: f64 = 0;
    // set-piece stings (DIRECTION #21)
    sting: string = ""; // kind holding the screen ('' = none)
    stingT: f64 = 0; // real seconds since it fired
    stingHold: f64 = 0; // real seconds of bullet time
    stingPlayed: Map<string, bool> = new Map<string, bool>(); // once per run
    stingExt: bool = false; // the bosses fire their own stings (core fallbacks stand down)
    stingDue: StingDue? = null; // core fallback waiting to fire
    stingLast: string = ""; // the last kind that fired
    stingAfter: f64 = 0; // real seconds after its hold in which the objective result it said is dropped
    stingBeat: string = ""; // the camera beat the sting owns ('' once over): the sting lasts through it
    stingDown: Map<i32, bool> = new Map<i32, bool>(); // sections whose boss a down_* card downed (its objective slab is dropped)
    timeScale: f64 = 1; // game time / real time (bullet time)
    archLow: bool = false; // the arch fly-through shot is running
    // attract reel (DIRECTION #21): autopilot highlights after ~25 s idle on the title
    reel: i32 = 0; // clip index (0 = not running)
    reelT: f64 = 0; // real seconds into the clip
    idleT: f64 = 0; // real seconds without input on the title
    idleSig: f64 = NaN; // title pointer / menu signature (activity = it changed)
    pointerPoke: bool = false; // a pointer went down since the last frame (attract reel: any tap returns)
    bossName: string = ""; // the boss now on the HUD
    bossDying: bool = false; // a downed boss falls: Hud.bossActive stays up (bossHealth 0) through its death dive
    bossDyingT: f64 = 0;
    bossPick: ai.Enemy? = null; // the weak point Hud.bossU / bossV track (sticky)
    wingHeld: Array<HeldLine> = new Array<HeldLine>(1); // wingmen join / peel calls held through a boss fight (1-based)
    // per wingman: in sight from the lens (not behind rock), re-tested in turns;
    // 1-based, -1 = nil, 0 / 1
    wingSeen: Array<i32> = [0, 1, 1];
    wingSeenN: f64 = 0;
    bombs: f64 = 0; // BOMB charges left
    bombCd: f64 = 0; // seconds until the next BOMB can go
    bombT: f64 = -1; // seconds since the last BOMB (shock ring)
    bombPos: Vector = Vector.xyz(0, 0, 0);
    retryT: f64 = -1; // RETRY: seconds until the world resets under the roller (-1 none)
    retryBrief: bool = false;
    // control mode (DIRECTION #25; core_mode.luau) and the HOW TO FLY card
    controlMode: string = "keyboard"; // the setting: 'keyboard' | 'gamepad' | 'touch'
    modeRec: cmode.Mode = cmode.create(); // its evidence, lock and VM writes
    qualityRec: cquality.Quality = cquality.create(); // graphics quality (DIRECTION #27; core_quality.luau)
    cardIndex: f64 = 1; // HOW TO FLY footer focus: 0 FLIGHT SCHOOL, 1 BACK
    schoolRequested: bool = false; // FLIGHT SCHOOL chosen: the next restart(false) trains
    // flight school (core_training.luau; docs/design/training.md)
    school: training.School = training.create();
    schoolArmed: bool = false; // the next briefing launch runs the school (Game.trainArmed)
    schoolEnvRec: GameEnv? = null;
    rolledNow: bool = false; // a barrel roll started this frame
    cardKind: f64 = -1; // the UI has the training_complete card: -1 unknown, 0 no, 1 yes
    memo: Memo = new Memo(); // checkpoints, retries, what hit him, the radio's memory (QA PT1)

    // (port) local multi-returns
    ctShows: bool = false; // commTyped's second value
    ohX: f64 = 0; // offHero
    ohY: f64 = 0;
    ohZ: f64 = 0;
    hrU0: f64 = -1; // bossHullRect
    hrV0: f64 = -1;
    hrU1: f64 = -1;
    hrV1: f64 = -1;
    pv: PrintVals = new PrintVals(); // (core_print.feed reads)

    static newTp(): types.Player {
        let t = new types.Player();
        t.y = 6;
        t.pos = Vector.xyz(0, 6, 0);
        return t;
    }

    // this frame's anchors (sprite meters, x right / y up from the sprite center)
    readAnchors(): void {
        let an = this.anchors, o = this.anc;
        o[1] = -an.nozX;
        o[2] = an.tipY;
        o[3] = an.nozX;
        o[4] = an.tipY;
        o[5] = -an.handX;
        o[6] = an.handY;
        o[7] = an.handX;
        o[8] = an.handY;
        let hn = this.heroNodes;
        if (hn != null) {
            let k = HERO_M / hn.w;
            let cx = hn.w * 0.5, cy = hn.h * 0.5;
            for (let i = 1; i <= 4; i++) {
                let n = i == 1 ? hn.tipL : i == 2 ? hn.tipR : i == 3 ? hn.muzL : hn.muzR;
                let wt = worldT(n);
                o[i * 2 - 1] = (<f64>wt.tx - cx) * k;
                o[i * 2] = (cy - <f64>wt.ty) * k;
            }
        }
    }

    // Billboard roll: the painted poses already lean into the bank, so the raster
    // hero only adds a small residual on top of the barrel roll.
    heroRoll(p: playerMod.Player): f64 {
        if (this.heroNodes != null) {
            return p.bank * 0.12 + p.roll;
        }
        return p.bank * 0.5 + p.roll;
    }

    // Helpers -------------------------------------------------------------------------

    sfxPlay(name: string, vol: f64 = NaN): void {
        let sx = this.sfx;
        if (sx != null) {
            sfx.play(sx, name, vol);
        }
    }

    // Music and ambience follow the app state through sfx.scene (called every
    // frame); this only remembers the last request for debugging.
    setMusic(name: string): void {
        this.music = name;
    }

    setMenu(i: f64): void {
        this.menuIndex = i;
        let g = this.gameVm;
        if (g != null) {
            vmx.num(g, "menuIndex", i);
        }
    }

    setState(st: string): void {
        this.state = st;
        this.stateT = 0;
        let g = this.gameVm;
        if (g != null) {
            let screen = st;
            if (st == "launch" || st == "dying" || st == "outro" || st == "retry" || st == "training" || st == "relaunch") {
                screen = "playing";
            }
            vmx.setEnum(g, "screen", screen);
            vmx.optSetBool(g, "quitArmed", false);
            // the victory dive flies itself: the touch controls leave as it starts (QA L4)
            vmx.optSetBool(g, "outro", st == "outro");
        }
        this.quitArmed = false;
        if (menuCount(st) > 0) {
            this.setMenu(0);
        }
        // a downed pilot: the HUD's alert slot clears (QA FAIL-N1)
        let h = this.hudVm;
        if (h != null) {
            vmx.optSetBool(h, "downed", st == "dying");
        }
        let c = this.ctx2;
        if (c != null) {
            c.state = st;
        }
    }

    sightBlocked(E: Vector, P: Vector): bool {
        let d = P - E;
        let len = mathx.len(d);
        if (len < 5) {
            return false;
        }
        let n = Math.ceil((len - 4) / 4);
        if (n >= SIGHT_NEAR_N && !scenery.ready()) {
            let m = 0.7;
            scenery.near(sightNear, this.chunks, lmin(<f64>E.x, <f64>P.x) - m, lmin(<f64>E.z, <f64>P.z) - m, lmax(<f64>E.x, <f64>P.x) + m, lmax(<f64>E.z, <f64>P.z) + m);
            for (let k = 0.0; k <= n; k++) {
                let q = E + d * <f32>((2 + (len - 4) * k / n) / len);
                if (scenery.nearCollide(sightNear, q.x, q.y, q.z, 0.6)) {
                    return true;
                }
            }
            return false;
        }
        for (let k = 0.0; k <= n; k++) {
            let q = E + d * <f32>((2 + (len - 4) * k / n) / len);
            if (scenery.collide(this.chunks, q.x, q.y, q.z, 0.6)) {
                return true;
            }
        }
        return false;
    }

    hudOn(): bool {
        let st = this.state;
        if (st == "outro") {
            // keep the visor up for the MISSION COMPLETE banner as he dives in;
            // the sting card says it instead, so the visor goes as he enters
            // and never comes back over the swirl (QA L9)
            let g = this.gameVm;
            if (this.entered && g != null && vmx.hasTrigger(g, "stingFire")) {
                return false;
            }
            return !this.entered || this.enteredT < 1.1;
        }
        return st == "launch" || flying(st) || st == "paused" || st == "dying" || st == "relaunch";
    }

    // Copy the pilot into the shared (enemies-facing) record, in place.
    syncTypesPlayer(): void {
        let p = this.player, t = this.tp;
        t.s = p.s;
        t.x = p.x;
        t.y = p.y;
        t.vx = p.vx;
        t.vy = p.vy;
        t.speed = p.speed;
        t.bank = p.bank;
        t.pitch = p.pitch;
        t.roll = p.roll;
        t.pos = p.pos;
        t.fwd = p.fwd;
        t.right = p.right;
        t.up = p.up;
        t.shield = p.shield;
        t.invuln = p.invuln;
        t.rolling = p.rollT > 0;
        t.boosting = p.boosting;
        t.braking = p.braking;
        t.alive = p.alive;
        t.aim = this.weapons.aim;
    }

    // Fire a Pilot trigger on the hero and its reflection twin.
    pilotTrigger(name: string): void {
        let pv = this.pilotVm;
        if (pv != null) {
            vmx.fire(pv, name);
        }
        let rv = this.reflVm;
        if (rv != null) {
            vmx.fire(rv, name);
        }
    }

    // Seconds until the pilot reaches the sky portal (math.huge once through).
    toPortal(): f64 {
        let p = this.player;
        if (this.portalT >= 0 || p.s >= level.portalS) {
            return HUGE;
        }
        return (level.portalS - p.s) / lmax(p.speed, 10);
    }

    // Seconds until the pilot reaches the sea arch (math.huge once past it).
    toArch(): f64 {
        let p = this.player;
        let s = level.anchors.archS;
        if (p.s >= s) {
            return HUGE;
        }
        return (s - p.s) / lmax(p.speed, 10);
    }

    // The same flat out while he boosts (or runs above cruise): a line is
    // paced for it (QA M14: a warning paced at cruise still typed in the arch
    // shot once he boosted). At cruise his speed now: assumed whenever he could
    // boost, the mines call was cut to its first sentence for every pilot (QA
    // PT1-4 r2); one he boosts into closes at the arch shot (commPump).
    toArchBoost(): f64 {
        let p = this.player;
        let live = this.toArch();
        if (live == HUGE || p.overheat > 0 || p.boost <= 8 || !(p.boosting || p.speed > playerMod.CRUISE + 5)) {
            return live;
        }
        let B = playerMod.BOOST;
        // (the speed eases up at 3.2 / s: the lag behind a flat-out run)
        let lag = lmax(0, B - p.speed) / 3.2;
        return lmin(live, (level.anchors.archS - p.s + lag) / B);
    }

    // Seconds a line about a moment ahead has before it: the arch fly-through
    // shot (if he boosts from now), the portal dive (he speeds up into it);
    // negative once the moment has passed, math.huge for any other line.
    momentLeft(text: string): f64 {
        if (archLine(text)) {
            let ta = this.toArchBoost();
            return ta == HUGE ? -1 : ta - ARCH_SHOT;
        }
        if (pages.watcherLine(text)) {
            // (its letters out before her warning at the boss cue, at his speed
            // (fitLine reads the whole air: its TYPE_TAIL may run past; without
            // it every pilot lost 'it wants YOU.'); a boost after it starts:
            // the warning waits for the letters, events)
            let p = this.player;
            let ws = pages.BOSS_CUES[2];
            return p.s >= ws ? -1 : (ws - p.s) / lmax(p.speed, playerMod.CRUISE) - 0.15 + pages.TYPE_TAIL;
        }
        if (portalLine(text)) {
            // (as if he runs at the portal flat out)
            let p = this.player;
            if (this.portalT >= 0 || p.s >= level.portalS) {
                return -1;
            }
            return (level.portalS - p.s) / lmax(p.speed, playerMod.BOOST) - 0.3;
        }
        return HUGE;
    }

    // Seconds before he enters the Eye, as if flat out (the outro takes him to
    // 118 m/s over its last 70 m: 0.15 s margin): its MISSION COMPLETE card
    // closes the channel, so every line is typed out by then (VI's 'Last one
    // through buys the milkshakes!' started 1.35 s before it and stopped at
    // 'buys th'). math.huge far from it or off the run.
    eyeLeft(): f64 {
        let st = this.state;
        let p = this.player;
        if (!(st == "playing" || st == "outro") || p.s < level.eye.s - 1500) {
            return HUGE;
        }
        if (this.entered) {
            return -1;
        }
        return (level.eye.s - p.s) / lmax(p.speed, playerMod.BOOST) - 0.15;
    }

    // Seconds a line has before its moment: the arch / portal ahead for a line
    // about it, the Eye or the reel's next cut for any line; while the tower's
    // portal call still waits in events' follow queue (behind the kill cheer),
    // any other line leaves it its read (r3, the cheer cut it to 'Portal's
    // open!'; r5, the Stormcrow falls ~320 m later: the Baron's kill line goes
    // when not even its first sentence leaves that room).
    lineLeft(text: string): f64 {
        let p = this.player;
        let pf = this.portalT < 0 ? pages.portalRoom(this.events.follow, text, p.s, p.speed) : HUGE;
        return lmin(lmin(lmin(this.momentLeft(text), this.eyeLeft()), this.reelLeft()), pf);
    }

    // A line is moot once not even its first sentence can be read before its
    // moment (the arch / portal it is about, the Eye).
    commStale(text: string): bool {
        let left = this.lineLeft(text);
        return left != HUGE && pages.fitLine(text, left) == null;
    }

    CL(kind: string, msg: string): void {
        console.log(format("CL f=%d s=%.0f rt=%.2f v=%.0f %s %s", [FN(logF), FN(this.player.s), FN(logT), FN(this.player.speed), FS(kind), FS(msg)]));
    }

    // The Watcher's beam charges or sweeps.
    beamOn(): bool {
        let E = this.enemies;
        let B = E != null ? E.boss : null;
        if (B == null || B.kind != "eye" || B.killed || B.escaped) return false;
        return B.v.beamState > 0;
    }

    // In a hazard stretch, or under the Watcher's beam: no flavor on the radio.
    hazardAt(): bool {
        return pages.hazard(this.player.s) || this.beamOn();
    }

    heardIt(text: string): bool {
        return this.memo.heard.has(text) && this.memo.heard.get(text);
    }

    commPush(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64, maxAge: f64, wing: bool = false): CommLine? {
        if (this.commStale(text)) {
            if (LOG_COMMS) {
                this.CL("REJ-stale", format('%s p%d "%s"', [FS(speaker), FN(prio), FS(text)]));
            }
            return null;
        }
        if ((this.memo.retried && this.heardIt(text) && pages.opening(text)) || (prio <= 1 && this.hazardAt())) {
            if (LOG_COMMS) {
                this.CL(prio <= 1 ? "REJ-hazard" : "REJ-heard", format('%s p%d "%s"', [FS(speaker), FN(prio), FS(text)]));
            }
            return null;
        }
        let q = this.commQueue;
        for (let k = 1; k < q.length; k++) {
            if (q[k].text == text) {
                return null;
            }
        }
        if (q.length - 1 >= 6) {
            // full: the newcomer replaces the weakest waiting line, or is dropped
            let worst = 1;
            for (let i = 2; i < q.length; i++) {
                if (q[i].prio < q[worst].prio) {
                    worst = i;
                }
            }
            if (q[worst].prio >= prio) {
                if (LOG_COMMS) {
                    this.CL("REJ-full", format('%s p%d "%s"', [FS(speaker), FN(prio), FS(text)]));
                }
                return null;
            }
            if (LOG_COMMS) {
                this.CL("QDROP-bumped", CLline(q[worst]));
            }
            rem(q, worst);
        }
        let l = new CommLine();
        l.who = who;
        l.speaker = speaker;
        l.text = text;
        l.seconds = seconds;
        l.mood = mood;
        l.prio = prio;
        l.age = 0;
        l.maxAge = maxAge;
        l.wing = wing;
        l.boss = null;
        l.phase = 0;
        l.rock = false;
        l.react = false;
        l.yield = wing;
        if (text == pages.KESSEL_LINE) {
            // (the Baron's hello yields like a wingman's call: whole when it is
            // over before the Low Pass call's beat, else 'Baron Kessel here.',
            // QA PT2-1; boosting out of the arch it held that call)
            l.yield = true;
        }
        q.push(l);
        if (LOG_COMMS) {
            this.CL("PUSH", format('%s p%d%s "%s" sec=%.1f maxAge=%.1f', [FS(speaker), FN(prio), FS(wing ? "w" : ""), FS(text), FN(seconds), FN(maxAge)]));
        }
        return l;
    }

    // A mission script line (events, bosses): recut, held for its spot or its
    // pair, or dropped (pages.radio), then queued; said in a boss fight it
    // carries the phase.
    scriptLine(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64): void {
        let r = pages.radio(text);
        if (r != null) {
            if (r.drop) {
                if (LOG_COMMS) {
                    this.CL("REJ-radio", text);
                }
                return;
            }
            let rt = r.text;
            if (rt != null) text = rt;
            seconds = opt(r.seconds, seconds);
            prio = opt(r.prio, prio);
            let s = opt(r.s, 0);
            if (this.player.s < s || r.hold) {
                let lt = new Later();
                lt.s = s;
                lt.pair = r.hold ? r.pair : null;
                lt.who = who;
                lt.speaker = speaker;
                lt.text = text;
                lt.seconds = seconds;
                lt.mood = mood;
                lt.prio = prio;
                this.memo.later.push(lt);
                return;
            }
        }
        let l = this.commPush(who, speaker, text, seconds, mood, prio, prio >= 3 ? 10 : prio >= 2 ? 6 : 3);
        let E = this.enemies;
        let B = E != null ? E.boss : null;
        if (l != null && B != null && B.phase >= 1 && !B.killed && !B.escaped) {
            l.boss = B;
            l.phase = B.phase;
        }
    }

    // Held script lines go out at their spot, or as their pair shows.
    laterPump(): void {
        let q = this.memo.later;
        for (let i = q.length - 1; i >= 1; i--) {
            let l = q[i];
            let pr = l.pair;
            let due = pr != null ? this.memo.slab == pr && this.alertT > 0 : this.player.s >= l.s;
            if (due) {
                rem(q, i);
                this.commPush(l.who, l.speaker, l.text, l.seconds, l.mood, l.prio, l.prio >= 3 ? 10 : l.prio >= 2 ? 6 : 3);
            }
        }
    }

    // Section names running (QA PT1: card, slab, route tab and radio said one
    // 3-4 times running): at most twice. Counted per section (another named
    // between does not reset it: r2, THE FALLS 3x in 3.4 s around VIOLET
    // REACH's result): the route tab at the edge, a slab, a card, a line on
    // air, each within 8 real s of its last; past two a checkpoint slab is
    // dropped (the route tab says it), a line opening on it drops that
    // sentence, an objective result says the objective in its own words
    // (pages.resultSub; r2's bare '+1000' read as nothing, r3's 3.5 s window
    // named THE FALLS a third time 4 s after the falls call).
    annCount(i: i32): f64 {
        if (i == 0) {
            return 0;
        }
        let m = this.memo;
        if (m.annT.has(i) && m.rt - m.annT.get(i) < 8) {
            return (m.annN.has(i) ? m.annN.get(i) : 0) + 1;
        }
        return 1;
    }

    annSay(i: i32): void {
        if (i > 0) {
            let m = this.memo;
            m.annN.set(i, this.annCount(i));
            m.annT.set(i, m.rt);
        }
    }

    annLine(text: string): string {
        let i = <i32>pages.secNamed(text);
        if (i > 0 && this.annCount(i) > 2) {
            let b = sentEnd(text, 1);
            if (b != 0 && <i32>pages.secNamed(lsub(text, 1, b)) == i) {
                text = lsub(text, b + 1);
                i = <i32>pages.secNamed(text);
            }
        }
        this.annSay(i);
        return text;
    }

    // The channel is taken: a line on air (not about to end) or a line of
    // prio 2+ waiting (not the rock line: it lets a formation call go first,
    // QA PT2-1). A formation join / peel waits for it (wingmen W.hold).
    commBusy(): bool {
        if (this.commT > 0.35) {
            return true;
        }
        let q = this.commQueue;
        for (let k = 1; k < q.length; k++) {
            let l = q[k];
            if (l.prio >= 2 && !l.rock) {
                return true;
            }
        }
        return false;
    }

    // Seconds before a waiting line about the arch / the portal ahead can no
    // longer be read whole before its moment; math.huge for the rest.
    commSlack(l: CommLine): f64 {
        let left = this.momentLeft(l.text);
        return left == HUGE ? HUGE : left - pages.readNeed(l.text);
    }

    // A centre slab or warning is up: no line starts under it (QA PT1-4). A
    // call (prio 2-3, the wingmen's too) waits until the slab has been read
    // (pages.slabMin), then the slab gives way (alertPump); flavor and the
    // Baron wait it out, any line a warning. Urgent lines, the school, a line
    // about the arch / portal ahead with no time to wait and a slab's pair in
    // its first PAIR_WIN (pages.paired) go at once. (r2 let calls start 1.25
    // s into a slab: 8 a run over one.)
    slabWait(l: CommLine): bool {
        if (this.alertT <= 0 || l.prio >= 4 || this.school.active) {
            return false;
        }
        if (this.alertAge < pages.pairWin(l.text) && pages.paired(l.text, this.memo.slab, this.sc.sectionIdx)) {
            return false;
        }
        // (a call whose threat waits for it reads no slab out: a sustained boost's
        // LOW PASS result held HANK's drone call past the dive's fallback, QA RP-4)
        if (this.warnT <= 0 && events.leadWaiting(this.events, l.text)) {
            return false;
        }
        // (the Baron's taunt before the Watcher reads a slab out, then says what
        // fits before her warning: going at once it typed under a late THE
        // FALLS result, QA RP-2)
        let watcher = pages.watcherLine(l.text);
        let whole = (l.prio <= 1 || l.who == "baron" || this.warnT > 0) && !watcher;
        let wait = whole ? this.alertT : pages.slabMin(this.alertPrio) - this.alertAge;
        return wait > 0 && (watcher || this.commSlack(l) > wait);
    }

    // Seconds before the next warning goes up (events' cues: pages.WARN_CUES,
    // the boss cues) at `v` m/s; 0 while one waits for the slot (events' queue
    // or the core's), math.huge in the school.
    warnIn(v: f64): f64 {
        return this.school.active ? HUGE : pages.warnIn(this.alerts, this.events.alerts, this.player.s, v);
    }

    // Seconds until the next scripted beat at his speed now (fast: if he
    // speeds up, at 1.25x and 70 m/s at least).
    beatIn(fast: bool = false): f64 {
        let p = this.player;
        let v = fast ? lmax(p.speed * 1.25, 70) : lmax(p.speed, 10);
        let best = HUGE;
        if (this.school.active) {
            // (the flight school runs its own script)
            return best;
        }
        for (let i = 1; i < BEATS.length; i++) {
            let s = BEATS[i];
            if (s > p.s) {
                best = lmin(best, (s - p.s) / v);
            }
        }
        // (a wingman's line keeps clear of the warnings too, typed out by one
        // within its wait for letters (alertPump), none while one waits for the
        // slot: r3, BOGEYS ON YOUR SIX! went up over HANK's intro; r4, over VI's
        // last letters at 390x844, 0.48 s into her intro at 480x360, 44 m late
        // behind RING CHAIN)
        if (!fast) {
            best = lmin(best, this.warnIn(v) + pages.WARN_SLACK);
        }
        if (FINALE_S > p.s) {
            best = lmin(best, (FINALE_S - p.s) / lmax(p.speed, playerMod.BOOST));
        }
        return best;
    }

    // A formation join is due but not even its call's first sentence would be
    // over before the next scripted beat: the pair holds off and swoops in as
    // its call plays (QA SEGA-N2: VI rejoined at 1861 m, 0.6 s before the low
    // pass call, and her 'Back with you!' played 6.8 s later).
    joinUnfit(): bool {
        let W = this.wing;
        if (W.window != 0) {
            return false;
        }
        let s = this.player.s;
        let wins = wingmen.WINDOWS;
        for (let i = 1; i < wins.length; i++) {
            let win = wins[i];
            if (s >= win.s0 && s < win.s1) {
                if (win.join.length < 2) return false;
                let l = win.join[1];
                return wingFit(l.text, this.beatIn(), false) == null;
            }
        }
        return false;
    }

    // The whole sting: the card's hold (bullet time) and the camera beat it owns
    // (the kill cam runs 0.15 s past the hold, the reveal / arch shots 0.35-0.4 s).
    stingLive(): bool {
        if (this.sting != "") {
            return true;
        }
        return this.stingBeat != "" && this.rig.beat == this.stingBeat;
    }

    // The boss on screen while she is revealed (hrU0, hrV0, hrU1, hrV1; y down;
    // hrU0 < 0: none): from her spawn until her bar lands, and through her
    // reveal poster and its camera beat. From this frame's rig; the popups
    // keep off her.
    hullNone(): void {
        this.hrU0 = -1;
        this.hrV0 = -1;
        this.hrU1 = -1;
        this.hrV1 = -1;
    }

    bossHullRect(): void {
        let E = this.enemies;
        let B = E != null ? E.boss : null;
        if (E == null || B == null || this.bossDying) {
            this.hullNone();
            return;
        }
        let poster = this.stingLive() && (this.sting.startsWith("boss_") || this.stingBeat == "reveal");
        if (this.bossActive && !poster) {
            this.hullNone();
            return;
        }
        let rig = this.rig;
        if (!HULL_BOX.has(B.kind)) {
            let on = enemies.focus(E);
            let cx = enemies.FOCUS_2, cy = enemies.FOCUS_3, cz = enemies.FOCUS_4, cr = enemies.FOCUS_5;
            if (!on) {
                this.hullNone();
                return;
            }
            let u = camera.project(rig, Vector.xyz(<f32>cx, <f32>cy, <f32>cz));
            let v = camera.PROJECT_2, w = camera.PROJECT_3;
            if (w <= cr) {
                this.hullNone();
                return;
            }
            let hv = cr / (w * Math.tan(rig.cam.fov * 0.5)) * 0.5;
            let hu = hv / lmax(rig.aspect, 0.1);
            this.hrU0 = u - hu;
            this.hrV0 = v - hv;
            this.hrU1 = u + hu;
            this.hrV1 = v + hv;
            return;
        }
        let box = HULL_BOX.get(B.kind);
        let x = B.xf;
        let s = x.s;
        let u0 = HUGE, v0 = HUGE, u1 = -HUGE, v1 = -HUGE;
        for (let i = 0; i <= 7; i++) {
            let lx = box[1 + i % 2], ly = box[3 + (i / 2) % 2], lz = box[5 + i / 4];
            let P = Vector.xyz(<f32>(x.px + (x.rx * lx + x.ux * ly - x.fx * lz) * s), <f32>(x.py + (x.ry * lx + x.uy * ly - x.fy * lz) * s), <f32>(x.pz + (x.rz * lx + x.uz * ly - x.fz * lz) * s));
            let u = camera.project(rig, P);
            let v = camera.PROJECT_2, w = camera.PROJECT_3;
            if (w <= 0.5) {
                this.hullNone();
                return;
            }
            u0 = lmin(u0, u);
            v0 = lmin(v0, v);
            u1 = lmax(u1, u);
            v1 = lmax(v1, v);
        }
        this.hrU0 = u0;
        this.hrV0 = v0;
        this.hrU1 = u1;
        this.hrV1 = v1;
    }

    // Letters of the line on air the HUD has fully typed (its typer's
    // Hud.commDone, read only; the schedule when the HUD has none), and whether
    // anything of it shows (a letter fading in counts: ctShows).
    commTyped(): f64 {
        let n = <f64>this.commText.length;
        let h = this.hudVm;
        // (commDone: the whole line; commTyped counts within a page on phones)
        let v = NaN;
        if (h != null) {
            v = vmx.optNum(h, "commDone");
            if (isNaN(v)) v = vmx.optNum(h, "commTyped");
        }
        if (isNaN(v) || this.commAge < 0.04) {
            // (the typer has not seen a line that only just went out)
            let out = this.commOut;
            if (this.commAge >= out) {
                this.ctShows = n > 0;
                return n;
            }
            let k = (this.commAge - pages.TYPE_LEAD) / lmax(out - pages.TYPE_LEAD, 0.01) * n;
            this.ctShows = k > 0;
            return lclamp(Math.floor(k), 0, n);
        }
        this.ctShows = v > 0;
        return v >= n ? n : lmax(0, Math.floor(v));
    }

    commLogEnd(kind: string): void {
        let n = <f64>this.commText.length;
        let k = this.commTyped();
        this.CL(kind, format('"%s" age=%.2f left=%.2f typed %d/%d %s', [FS(this.commText), FN(this.commAge), FN(lmax(0, this.commT)), FN(k), FN(n),
            FS(k >= n ? "ALL" : '"' + lsub(this.commText, 1, <i32>k) + '"')]));
    }

    commPlay(l: CommLine): void {
        if (LOG_COMMS && this.commT > 0) {
            this.commLogEnd("OVER");
        }
        // (a slab up gives way: alertPump)
        if (this.alertT > 0) {
            this.memo.give = true;
        }
        this.sfxPlay("comm", 0.7);
        // (a threat cued with this line comes with it: events.leadThreat)
        events.lineOn(this.events, l.text);
        this.memo.heard.set(l.text, true);
        if (l.text == pages.KESSEL_LINE) {
            pages.dropFlavor(this.commQueue);
        }
        // a line about the arch / the portal ahead, any line near the Eye: all
        // of it when it can be read before the moment, else its leading
        // sentences (commStale drops it when not even the first fits)
        let text = this.annLine(l.text);
        let left = this.lineLeft(text);
        if (left != HUGE) {
            let ft = pages.fitLine(text, left);
            if (ft != null) text = ft;
        }
        let room = this.beatIn();
        if (l.yield) {
            // a wingman says what is over before the next scripted beat; the
            // tower's rock line, before the next hazard call (a beat cuts in)
            let p = this.player;
            // (a hazard call does not wait BEAT_WAIT for it; at cruise at least:
            // slowed by the hit it reached the kamikaze call, r1)
            let wf = wingFit(text, l.rock ? pages.hazardIn(p.s, lmax(p.speed, playerMod.CRUISE)) - BEAT_WAIT : room, l.react);
            if (wf != null) text = wf;
        }
        // (clear of a hazard stretch / a warning ahead: pages.recut)
        let v = lmax(this.player.speed, 10);
        let wcap = HUGE;
        text = pages.recut(l, text, this.player.s, v, this.warnIn(v));
        wcap = pages.RECUT_2;
        // long lines stay up long enough to read; the typer paces the line to
        // end before the channel closes. With the next scripted beat due
        // sooner (even if he speeds up) the line is paced for it (READ_CPS at
        // most)
        let air = commDur(l.seconds, text);
        // (the Baron's hello as a scripted line: boosting out of the arch, it
        // held the Low Pass call and VI's join went stale, QA PT2-1)
        air = lmax(pages.readNeed(text), lmin(lmin(lmin(air, left), wcap), l.yield && l.text != pages.KESSEL_LINE ? room : this.beatIn(true)));
        this.commT = air;
        this.commOut = pages.typeOut(text, air);
        R.hudFlush(this.r); // 2.1: the typer schedules the line with exactly this frame's step, as before
        let h = this.hudVm;
        if (h != null) {
            vmx.setEnum(h, "commWho", l.who);
            let md = l.mood;
            vmx.optEnumOrString(h, "commMood", md != null ? md : pages.mood(l.who, text));
            vmx.optSetNum(h, "commSeconds", Math.floor(air * 100 + 0.5) / 100);
            vmx.str(h, "commSpeaker", l.speaker);
            vmx.str(h, "commText", text);
            vmx.bool(h, "commActive", true);
        }
        this.commText = text;
        this.commLine = l;
        this.commAge = 0;
        this.commPrio = l.prio;
        this.commOutAge = -1;
        this.commCutAt = -1;
        if (LOG_COMMS) {
            this.CL("PLAY", format('%s p%d%s "%s" waited=%.2f air=%.2f pace=%.2f n=%d pages=%d', [FS(l.speaker), FN(l.prio), FS(l.wing ? "w" : l.yield ? "y" : ""), FS(text), FN(l.age), FN(air), FN(air), FN(<f64>text.length), FN(pages.turns(text, pages.cols, pages.rows) + 1)]));
        }
    }

    // The channel closes (the HUD's window slides out).
    commClose(): void {
        if (LOG_COMMS && this.commOn) {
            this.commLogEnd("CLOSE");
        }
        this.commOn = false;
        this.commT = 0;
        this.commPrio = 0;
        R.hudFlush(this.r); // 2.1: the typer sees the old line end, then the close, as before
        let h = this.hudVm;
        if (h != null) {
            vmx.bool(h, "commActive", false);
        }
    }

    // A line is typing on the channel, or one of prio 3+ waits to: the
    // autopilot's killing blow waits for it (its DOWNED card closes the channel).
    commTyping(): bool {
        if (this.commT > 0 && this.commTyped() < <f64>this.commText.length) {
            return true;
        }
        let q = this.commQueue;
        for (let k = 1; k < q.length; k++) {
            if (q[k].prio >= 3) {
                return true;
            }
        }
        return false;
    }

    // Deliver queued lines: the next one when the channel is free. A line on
    // air is never left half typed: a line that takes over (an urgent one, a
    // scripted beat over a wingman's line or over a lower priority, a line
    // about the arch / portal that would go stale) waits for it to finish when
    // it is nearly typed out (FINISH), else the text stops on a whole word (the
    // end of the sentence when near) and is replaced there; one that has not
    // typed a letter yet is pulled (a wingman's call waits again).
    commPump(dt: f64): void {
        let q = this.commQueue;
        let hv = this.hudVm;
        pages.setPlate(hv != null ? opt(vmx.optNum(hv, "commCols"), 0) : 0, hv != null ? opt(vmx.optNum(hv, "commRows"), 1) : 1);
        let frozen = this.stingLive();
        if (LOG_COMMS && frozen != logSting) {
            logSting = frozen;
            this.CL(frozen ? "STING-on" : "STING-off", this.stingLast);
        }
        let n = <f64>this.commText.length;
        let typed = this.commT > 0 ? this.commTyped() : n;
        if (this.commT > 0 && this.commOutAge < 0 && typed >= n) {
            this.commOutAge = this.commAge;
            if (LOG_COMMS) {
                this.CL("OUT", format('"%s" age=%.2f left=%.2f cps=%.1f', [FS(this.commText), FN(this.commAge), FN(this.commT), FN(n / lmax(this.commAge - pages.TYPE_LEAD, 0.01))]));
            }
        }
        // a boss has just come up: its reveal poster is a moment away, so the
        // next line waits for it (the Stormcrow's welcome was tucked under the
        // poster 2 s in); the line on air plays on
        let E = this.enemies;
        let boss = E != null && enemies.bossActive(E);
        let g = this.gameVm;
        if (boss && !this.commBoss && !frozen && g != null && vmx.hasTrigger(g, "stingFire")
            && !this.played(this.player.s < level.portalS ? "boss_stormcrow" : "boss_watcher")) {
            this.commHold = 4;
            if (LOG_COMMS) {
                this.CL("HOLD-on", "");
            }
        }
        this.commBoss = boss;
        if (this.commHold > 0) {
            this.commHold = frozen ? 0 : this.commHold - dt;
            if (!frozen) {
                if (this.commT > 0) {
                    this.commT -= dt;
                    this.commAge += dt;
                }
                if (this.commT <= 0 && this.commOn) {
                    this.commClose();
                }
                return;
            }
        }
        // a set-piece sting holds the screen and the HUD tucks its panels: the
        // channel waits it out. A scripted line it caught half typed plays again
        // right after it if nothing else wants the channel (not after a kill)
        if (frozen) {
            if (this.commT > 0) {
                let on = this.commLine;
                let kill = this.stingLast.startsWith("down_") || this.stingLast == "mission_complete";
                if (on != null && (!on.yield || on.rock) && on.prio >= 2 && !kill && this.commTyped() < <f64>this.commText.length) {
                    on.age = 0;
                    on.maxAge = 1.5;
                    ins(q, 1, on);
                    if (LOG_COMMS) {
                        this.CL("STING-requeue", CLline(on));
                    }
                }
            }
            if (this.commOn) {
                this.commClose();
            }
            return;
        }
        let i = 1;
        while (i < q.length) {
            let l = q[i];
            l.age += dt;
            let b = l.boss;
            // (its fight phase is over; flavor in a hazard stretch)
            let over = b != null && (b.killed || b.escaped || b.phase > l.phase || E == null || E.boss != b);
            let hz = l.prio <= 1 && this.hazardAt();
            let moot = pages.lineMoot(l, this.player.s);
            if (l.age > l.maxAge || this.commStale(l.text) || over || hz || moot) {
                if (LOG_COMMS) {
                    this.CL(over ? "QDROP-phase" : hz ? "QDROP-hazard" : l.age > l.maxAge ? "QDROP-age" : moot ? "QDROP-moot" : "QDROP-stale", CLline(l) + format(" waited=%.2f", [FN(l.age)]));
                }
                if (l.rock) {
                    // (unsaid: the next rock hit says it, this one too)
                    this.memo.rockHit = false;
                    this.memo.heard.delete(l.text);
                }
                rem(q, i);
            } else {
                i += 1;
            }
        }
        this.commT -= dt;
        this.commAge += dt;
        if (this.commT > 0 && this.portalT >= 0 && this.portalT < 1 && portalLine(this.commText)) {
            // through the portal: its line is over
            this.commT = 0;
        }
        // a line about the arch / portal ahead closes before it at his speed now
        // (a boost brings it closer): the arch line as the arch shot cuts in, or
        // once it is typed out if that is later
        if (this.commT > 0 && archLine(this.commText)) {
            let ta = this.toArch();
            this.commT = lmin(lmin(this.commT, ta - 0.3), lmax(ta - ARCH_SHOT, this.commOut - this.commAge + 0.15));
        } else if (this.commT > 0 && portalLine(this.commText) && this.portalT < 0) {
            this.commT = lmin(this.commT, this.toPortal() - 0.1);
        }
        // the Watcher's beam charges or sweeps: a flavor / Baron line on air
        // ends once typed out, none starts (the roll call has the box, QA PT1-4)
        // (and the first of two joining wingmen hands over once read: pages.lineEnd)
        let quiet = this.beamOn();
        this.commT = pages.lineEnd(this.commLine, this.commT, this.commAge, this.commOutAge >= 0 ? this.commOutAge : this.commOut, this.commText, <f64>(this.wing.pend.length - 1), quiet, CUT_TAIL);
        let st = this.state;
        let live = flying(st) || st == "launch" || st == "outro" || st == "dying";
        if (live && q.length > 1) {
            // the highest priority; at the same one the mission script's line
            // goes before a wingman's (join / peel / reactions yield to the
            // scripted beats), else the oldest. A wingman's line is only in the
            // running when it is over before the next scripted beat
            let room = this.beatIn();
            // a line that yields (a wingman's, the tower's rock line) never goes
            // ahead of a scripted call waiting (QA PT2-5: the first-rock line at
            // 1325-1413 m took the channel and the mines call expired behind it)
            let scripted = false;
            for (let k = 1; k < q.length; k++) {
                let w = q[k];
                if (!w.yield && w.prio >= 2 && !(quiet && w.who == "baron")) {
                    scripted = true;
                    break;
                }
            }
            let best = 0;
            for (let k = 1; k < q.length; k++) {
                let a = q[k];
                let ok = !a.yield;
                if (!ok && !scripted && !(a.rock && pages.formationWaiting(q))) {
                    let pl = this.player;
                    ok = wingFit(a.text, a.rock ? pages.hazardIn(pl.s, lmax(pl.speed, playerMod.CRUISE)) - BEAT_WAIT : room, a.react) != null;
                }
                if (ok && !(quiet && (a.prio <= 1 || a.who == "baron"))) {
                    // (of two urgent lines the later one: it would cut in anyway)
                    if (best == 0) {
                        best = k;
                    } else {
                        let b = q[best];
                        if (a.prio > b.prio || (a.prio == b.prio && ((b.yield && !a.yield) || a.prio >= 4))) {
                            best = k;
                        }
                    }
                }
            }
            // a line paired with the slab now up goes out with it, ahead of a
            // call that has to wait the slab out (boosting, BOGEYS ON YOUR SIX!
            // went up at 2420: HANK's drone call waited it out and VI's rejoin
            // behind it went moot, QA RP-1)
            if (this.alertT > 0 && (best == 0 || q[best].prio < 4)) {
                let pk = <i32>pages.pairedIn(q, this.memo.slab, this.sc.sectionIdx, this.alertAge);
                if (pk > 0) {
                    best = pk;
                }
            }
            let l: CommLine? = best > 0 ? q[best] : null;
            if (l != null && l.prio >= 4) {
                // an urgent line supersedes the urgent ones still waiting
                for (let k = best - 1; k >= 1; k--) {
                    if (q[k].prio >= 4) {
                        if (LOG_COMMS) {
                            this.CL("QDROP-superseded", CLline(q[k]));
                        }
                        rem(q, k);
                        best -= 1;
                    }
                }
            }
            // a boss's follow-up line (events' queue, handed over once the channel is free) of a higher priority goes
            // first: the free channel waits up to FOLLOW_WAIT for it instead of opening for a lower line it would
            // take over a few frames in (QA HUD2-6: HANK's 'Yeehaw! Look at her burn!' showed 3 frames, no text)
            let fq = this.events.follow;
            if (l != null && this.commT <= 0 && fq.length > 1 && fq[1].prio > l.prio && this.events.held.length - 1 == 0
                && followWait < FOLLOW_WAIT) {
                followWait += dt;
                if (this.commOn) {
                    this.commClose();
                }
                return;
            }
            if (l != null && this.commT <= 0 && this.slabWait(l)) {
                if (this.commOn) {
                    this.commClose();
                }
                return;
            }
            if (l != null && this.commT <= 0) {
                followWait = 0;
                rem(q, best);
                this.commPlay(l);
                this.commOn = true;
                return;
            }
            let on = this.commLine;
            if (l != null && on != null) {
                let beat = !l.yield && l.prio >= 2;
                let swap = false, again = false;
                if (typed >= n && l.prio >= 5) {
                    swap = true;
                } else if (typed >= n) {
                    // typed out: once read it gives way to a beat that has waited
                    if (((beat && l.age >= BEAT_WAIT) || l.prio >= 4) && !this.slabWait(l)) {
                        let outAge = this.commOutAge >= 0 ? this.commOutAge : this.commAge;
                        this.commT = lmin(this.commT, outAge + CUT_TAIL - this.commAge);
                        swap = this.commT <= 0;
                    }
                } else {
                    let take = l.prio >= 4 || (beat && (on.yield || l.prio > this.commPrio));
                    // a line about the arch / portal ahead that would go stale
                    // before the line on air ends (QA M14: the tower's mine
                    // warning waited out the kamikaze call and was dropped)
                    if (!take && l.prio >= this.commPrio && this.commSlack(l) < this.commT + 0.3) {
                        take = true;
                    }
                    if (take && this.slabWait(l)) {
                        take = false;
                    }
                    // (the Baron's Watcher taunt lets the line on air type out
                    // while its first sentence still fits after it: a late result
                    // held VI's curtain line and he cut it to 'Through the
                    // curtain!', QA RP-2 r3; events wants hers out first)
                    if (take && pages.watcherLine(l.text)
                        && pages.fitLine(l.text, this.momentLeft(l.text) - lmax(0, this.commOut - this.commAge) - CUT_TAIL) != null) {
                        take = false;
                    }
                    if (take) {
                        this.commTyped();
                        let shows = this.ctShows;
                        if (!shows) {
                            // nothing of it shown yet (not a letter fading in): pulled
                            swap = true;
                            again = on.yield && on.prio >= 2 && l.prio < 5;
                        } else if (this.commCutAt >= 0 || l.prio >= 5 || (n - typed) / pages.TYPE_CPS > FINISH) {
                            if (this.commCutAt < 0) {
                                // (a scripted line of the same priority is let
                                // to the end of its sentence, up to 2.5 s on, the
                                // rock line to its end for any beat but a hazard
                                // call: r2 cut 'Roll and bounce' 1.1 s from its
                                // end; not in the school: the voice follows the
                                // ticket)
                                let same = !on.yield && l.prio <= this.commPrio && !this.school.active;
                                let rockEnd = on.rock && !pages.hazardLine(l.text);
                                let reach = l.prio >= 5 ? 0.0 : same || rockEnd ? 2.5 : 1.0;
                                this.commCutAt = pages.cutPoint(this.commText, typed, reach * pages.TYPE_CPS, rockEnd);
                            }
                            swap = typed >= this.commCutAt;
                        }
                    }
                }
                if (swap) {
                    rem(q, best);
                    if (again) {
                        ins(q, 1, on);
                        if (LOG_COMMS) {
                            this.CL("STEP-requeue", CLline(on));
                        }
                    }
                    this.commPlay(l);
                    this.commOn = true;
                    return;
                }
            }
        }
        if (this.commT <= 0 && this.commOn) {
            this.commClose();
        }
    }

    played(kind: string): bool {
        return this.stingPlayed.has(kind) && this.stingPlayed.get(kind);
    }

    downed(i: i32): bool {
        return this.stingDown.has(i) && this.stingDown.get(i);
    }

    stingUi(): bool {
        let g = this.gameVm;
        return g != null && vmx.hasTrigger(g, "stingFire");
    }

    // Hud.stingActive follows the whole sting (change-only write).
    stingSync(): void {
        let live = this.stingLive();
        if (!live) {
            this.stingBeat = "";
        }
        let h = this.hudVm;
        if (h != null) {
            vmx.optSetBool(h, "stingActive", live);
        }
    }

    logCam(bu: f64, bv: f64): void {
        camLogN += 1;
        if (mod(camLogN, 10) != 0) {
            return;
        }
        let rig = this.rig, p = this.player;
        camera.project(rig, rig.focusP);
        let fv = camera.PROJECT_2;
        let hz = p.pos + p.fwd * 3000;
        camera.project(rig, Vector.xyz(hz.x, 0, hz.z));
        let hv = camera.PROJECT_2;
        camera.project(rig, p.pos);
        let pv = camera.PROJECT_2;
        console.log(format("[cam %5.0f m %6.2f s] y %.1f vy %5.1f eye%+.1f fw %.2f | focus v %.2f horizon v %.2f pilot v %.2f | boss uv %.2f %.2f | sting %s beat %s dying %s bossActive %s", [
            FN(p.s), FN(this.t), FN(p.pos.y), FN(p.vy), FN(<f64>rig.cam.eye.y - <f64>p.pos.y), FN(rig.focusW), FN(fv), FN(hv), FN(pv), FN(bu), FN(bv),
            FS(this.stingLive() ? "true" : "false"), FS(rig.beat), FS(this.bossDying ? "true" : "false"), FS(this.bossActive ? "true" : "false")]));
    }

    stingFire(kind: string, title: string, sub: string): void {
        if (!STING_HOLD.has(kind) || this.played(kind) || this.sting != "") {
            return;
        }
        let hold = STING_HOLD.get(kind);
        let st = this.state;
        if (!flying(st) && st != "outro" && st != "launch") {
            return;
        }
        if (LOG_STING) {
            console.log(format("[sting %5.0f m %6.2f s] %s: %s / %s", [FN(this.player.s), FN(this.t), FS(kind), FS(title), FS(sub)]));
        }
        this.stingPlayed.set(kind, true);
        this.annSay(<i32>pages.secNamed(title + " " + sub));
        this.sting = kind;
        this.stingLast = kind;
        this.stingAfter = 0;
        this.stingT = 0;
        this.stingHold = hold;
        let g = this.gameVm;
        if (g != null) {
            vmx.optEnumOrString(g, "sting", kind);
            vmx.optSetStr(g, "stingTitle", title);
            vmx.optSetStr(g, "stingSub", sub);
            if (vmx.hasTrigger(g, "stingFire")) {
                vmx.fire(g, "stingFire");
            }
            // an objective result the card says, already queued: dropped
            if (kind == "arch_threaded" || kind.startsWith("down_")) {
                let q = this.alerts;
                for (let i = q.length - 1; i >= 1; i--) {
                    if (!q[i].warn && q[i].text == "OBJECTIVE COMPLETE") {
                        rem(q, i);
                    }
                }
            }
        }
        let h = this.hudVm;
        if (h != null) {
            vmx.optSetBool(h, "stingActive", true);
            // the slab on the visor gets out of the card's way
            if (this.alertT > 0 && this.warnT <= 0) {
                this.alertT = 0;
            }
        }
        let pre = lsub(kind, 1, 5);
        if (pre == "down_") {
            // its section's objective result (and a pending DOWN THE <boss>
            // objective) is the card's to say
            this.stingDown.set(level.sectionAt(this.player.s), true);
            let objs = this.sc.objectives;
            for (let i = 1; i < objs.length; i++) {
                let o = objs[i];
                if (o.kind == "boss" && o.result == "") {
                    this.stingDown.set(i, true);
                }
            }
        }
        let r = this.r;
        // the slam: the frame re-prints as misregistered halftone plates (render's
        // print flash, ~0.5 s real under bullet time)
        if (r != null) {
            R.printFlash(r, pre == "down_" ? 1 : 0.85, 0.16);
        }
        this.stingBeat = "";
        if (pre == "down_") {
            // KILL CAM: a white frame, a beat of hit-stop, then the orbit
            camera.beat(this.rig, "kill", hold + 0.15, this.player);
            this.stingBeat = "kill";
            if (r != null) {
                r.post.flash = 0.55;
                r.post.flashR = 1;
                r.post.flashG = 0.97;
                r.post.flashB = 0.9;
            }
            camera.addShake(this.rig, 1.2);
        } else if (pre == "boss_") {
            camera.beat(this.rig, "reveal", hold + 0.35, this.player, kind);
            this.stingBeat = "reveal";
        } else if (kind == "arch_threaded") {
            camera.beat(this.rig, "arch", hold + 0.4, this.player);
            this.stingBeat = "arch";
        }
        let sx = this.sfx;
        if (sx != null) {
            let nm = "sting_" + kind;
            if (sfx.has(sx, nm)) {
                sfx.stinger(sx, nm);
            } else if (sfx.has(sx, "sting")) {
                sfx.stinger(sx, "sting");
            }
        }
    }

    // Hold, ease game time (fast into bullet time, slower out) and end the sting;
    // core fallbacks (bosses that do not fire their own) wait on their moment.
    stingUpdate(rdt: f64): void {
        let due = this.stingDue;
        if (due != null) {
            due.t -= rdt;
            if (this.stingExt || this.played(due.kind)) {
                this.stingDue = null;
            } else if (due.t <= 0 && this.sting == "") {
                this.stingDue = null;
                this.stingFire(due.kind, due.title, due.sub);
            }
        }
        let target = 1.0;
        this.stingAfter = lmax(0, this.stingAfter - rdt);
        if (this.sting != "") {
            this.stingT += rdt;
            let t = this.stingT;
            if (t >= this.stingHold) {
                this.sting = "";
                this.stingAfter = 4;
                let g = this.gameVm;
                if (g != null) {
                    vmx.optEnumOrString(g, "sting", "none");
                }
                // (Hud.stingActive holds through the beat it owns: stingSync)
            } else if (this.sting.startsWith("down_") && t < 0.3) {
                // hit-stop on the kill frame
                target = 0.04;
            } else if (this.sting != "training_complete") {
                target = STING_SCALE;
            }
        }
        // the deflect drill's coach: a slow beat as the orb closes
        if (this.school.slow) {
            target = lmin(target, training.SLOW);
        }
        let st = this.state;
        if (!flying(st) && st != "outro" && st != "launch") {
            target = 1;
        }
        this.timeScale = mathx.damp(this.timeScale, target, target < this.timeScale ? 16 : 3.2, rdt);
        if (target >= 1 && this.timeScale > 0.985) {
            this.timeScale = 1;
        }
    }

    stingReset(keep: bool): void {
        // keep: the live sting (kind, clock, its played flag) rides through (the cut)
        let kind = keep ? this.sting : "";
        this.stingPlayed.clear();
        if (kind != "") {
            this.stingPlayed.set(kind, true);
        }
        this.stingDown.clear();
        this.stingDue = null;
        this.stingLast = "";
        this.stingAfter = 0;
        this.timeScale = 1;
        this.archLow = false;
        if (this.sting != "" && kind == "") {
            this.sting = "";
            let g = this.gameVm;
            if (g != null) {
                vmx.optEnumOrString(g, "sting", "none");
            }
        }
        camera.beatEnd(this.rig, true);
        this.stingBeat = "";
        this.stingSync();
    }

    // Boss stings when the bosses do not fire their own (core fallback).
    stingSchedule(kind: string, title: string, sub: string, delay: f64): void {
        let due = this.stingDue;
        if (this.stingExt || this.played(kind) || (due != null && due.kind == kind)) {
            return;
        }
        let d = new StingDue();
        d.kind = kind;
        d.title = title;
        d.sub = sub;
        d.t = delay;
        this.stingDue = d;
    }

    alertPush(warn: bool, text: string, sub: string, kind: string, seconds: f64): void {
        // a sting card already said it
        if (!warn && STING_DUP.has(text) && this.played(STING_DUP.get(text)) && this.stingUi()) {
            return;
        }
        let objective = lsub(text, 1, 9) == "OBJECTIVE";
        if (!warn && objective) {
            // the THREADED / DOWNED card already said the objective was won (its
            // +1000 still pops in the world and ticks the route tab)
            if (text == "OBJECTIVE COMPLETE" && this.stingUi() && (this.sting != "" || this.stingAfter > 0)) {
                let k = this.stingLast;
                if (k == "arch_threaded" || k.startsWith("down_")) {
                    return;
                }
            }
            // the boss's own objective, once its DOWNED card said it
            let sec = objSection(sub);
            if (sec != 0 && this.downed(sec) && this.stingUi()) {
                return;
            }
            // any other result while a boss is framed: the route tab ticks it
            // off, no slab over the fight
            if (this.bossActive) {
                return;
            }
        }
        let prio = 1.0, maxAge = 3.5;
        if (warn) {
            prio = 4;
            maxAge = 2.5;
        } else if (text == "MISSION COMPLETE") {
            prio = 5;
            maxAge = 10;
        } else if (kind == "success" || kind == "warning") {
            prio = 3;
            maxAge = 5;
        } else if (kind == "checkpoint") {
            prio = 2;
            maxAge = 5;
        }
        // never a checkpoint slab over a framed boss: the route tab still pings
        // from routeIndex
        if (!warn && kind == "checkpoint" && this.bossActive) {
            return;
        }
        // boss phase callouts go to the compact line under the boss bar when the
        // HUD has one, so the slab never covers the boss. Only real callouts
        // ('phase' kind, or a 'warning'-kind banner that is not an objective
        // result; objective results never go there).
        let h = this.hudVm;
        let phase = kind == "phase" || (kind == "warning" && !objective);
        if (kind == "phase") {
            kind = "warning";
            prio = 3;
            maxAge = 5;
        }
        if (!warn && phase && this.bossActive && h != null && vmx.hasStr(h, "bossPhase")) {
            vmx.optSetStr(h, "bossPhase", sub != "" ? text + "  //  " + sub : text);
            if (vmx.hasTrigger(h, "bossPhaseFire")) {
                vmx.fire(h, "bossPhaseFire");
            }
            this.sfxPlay("warning", 0.5);
            return;
        }
        let a = new CoreAlert();
        a.warn = warn;
        a.text = text;
        a.sub = sub;
        a.kind = kind;
        a.seconds = seconds;
        a.prio = prio;
        a.age = 0;
        a.maxAge = maxAge;
        this.alerts.push(a);
    }

    alertShow(a: CoreAlert): void {
        let h = this.hudVm;
        if (a.warn) {
            if (h != null) {
                vmx.str(h, "warningText", a.text);
                vmx.bool(h, "warningActive", true);
            }
            this.warnT = a.seconds;
            this.alertT = a.seconds;
            this.sfxPlay("warning", 0.8);
        } else {
            if (h != null) {
                vmx.str(h, "bannerText", a.text);
                vmx.str(h, "bannerSub", a.sub);
                vmx.setEnum(h, "bannerKind", a.kind);
                vmx.fire(h, "bannerFire");
                vmx.bool(h, "warningActive", false);
            }
            this.warnT = 0;
            // in combat the slab gets out of the way sooner
            this.alertT = this.bossActive ? 2.2 : 3.4;
        }
        this.alertAge = 0;
        this.alertBossT = 0;
        this.alertPrio = a.prio;
        this.memo.slab = a.text;
        // (only before a boss is on the field: one raised in a death dive keeps its time)
        let E = this.enemies;
        this.alertCut = !a.warn && (a.kind == "checkpoint" || lsub(a.text, 1, 9) == "OBJECTIVE")
            && !(E != null && enemies.bossActive(E));
    }

    // Seconds until the next boss cue at his speed now (math.huge: none ahead).
    bossIn(): f64 {
        let p = this.player;
        let cues = pages.BOSS_CUES;
        for (let i = 1; i < cues.length; i++) {
            let s = cues[i];
            if (s > p.s) {
                return (s - p.s) / lmax(p.speed, 10);
            }
        }
        return HUGE;
    }

    alertPump(dt: f64): void {
        let q = this.alerts;
        // a line started under a slab (a call once it is read, one with no time
        // to wait, an urgent one: commPlay): a slab whose sub is out goes
        // (Hud.downed takes the slot to idle; a warning stays), the slot held
        // SLAB_CLR
        let m = this.memo, h = this.hudVm;
        // (a read slab gives way to a warning waiting for the slot too: r4,
        // RING CHAIN held BOGEYS ON YOUR SIX! 44 m at 480x360)
        if (this.alertT > pages.SLAB_CLR && this.alertAge >= pages.slabMin(this.alertPrio) && pages.warnWaits(this.events.alerts)) {
            m.give = true;
        }
        if (m.give) {
            m.give = false;
            if (this.alertT > 0 && this.warnT <= 0 && this.alertAge >= 1.25) {
                this.alertT = pages.SLAB_CLR;
                m.clrT = pages.SLAB_CLR;
                // (the next slab waits for that line's letters: 04 CLIFF TURN
                // slammed in 0.2 s into the gun nests call; the rock line's too:
                // without, 02 SEA ARCH went up on its first letter and pulled it,
                // and it came back as 'Watch the stacks!' only, QA PT2)
                m.holdT = this.commOut - this.commAge;
                if (h != null) {
                    vmx.optSetBool(h, "downed", true);
                }
            }
        } else if (m.clrT > 0) {
            m.clrT -= dt;
            if (m.clrT <= 0 && h != null && this.state != "dying") {
                vmx.optSetBool(h, "downed", false);
            }
        }
        if (this.state == "dying") {
            q.length = 1; // (a downed pilot gets no banner: the death block clears the slot, QA FAIL-N1)
        }
        let soon = this.bossIn() < SLAB_SOON;
        // a boss on the field before her fight HUD (the Stormcrow's storm
        // entrance): her WARNING is waiting in events' queue for this slot
        // (QA PT2: hands-off 2700, 04 CLIFF TURN FAILED went up at 3633 and the
        // WARNING after her reveal poster)
        let E0 = this.enemies;
        let B0 = E0 != null ? E0.boss : null;
        let entering = B0 != null && !B0.killed && !B0.escaped && !this.bossActive && !this.bossDying;
        let i = 1;
        while (i < q.length) {
            let a = q[i];
            a.age += dt;
            // a fight starts (or its boss is coming in): info, SKY PORTAL,
            // checkpoint slabs and objective results still waiting go (the
            // route tab says them); SKY PORTAL (it waits for the tower's call)
            // once through it. A checkpoint / result still waiting SLAB_SOON
            // before a boss cue goes too (r4: CLIFF TURN FAILED waited for
            // 'Climb, Corsair!' past her cue, held her WARNING after her poster)
            let result = !a.warn && (a.kind == "checkpoint" || lsub(a.text, 1, 9) == "OBJECTIVE");
            let moot = ((this.bossActive || entering) && (a.prio <= 1 || a.text == "SKY PORTAL" || result))
                || (a.text == "SKY PORTAL" && this.portalT >= 0) || (soon && result);
            if (a.age > a.maxAge || moot) {
                rem(q, i);
            } else {
                i += 1;
            }
        }
        this.alertT -= dt;
        this.alertAge += dt;
        m.holdT -= dt;
        // a boss takes the field: a checkpoint / objective result slab raised
        // just before her cue gets out of the way for her WARNING, which the
        // reveal poster waits on (hands-off, 04 CLIFF TURN FAILED held the slot
        // 3.4 s: the poster went first, the warning after)
        let E = this.enemies;
        if (this.alertCut && this.alertT > 0 && E != null && enemies.bossActive(E)) {
            this.alertBossT += dt;
            if (this.alertAge >= SLAB_READ || this.alertBossT >= SLAB_BOSS) {
                this.alertT = 0;
                this.alertCut = false;
            }
        }
        if (q.length - 1 == 0) {
            return;
        }
        let best = 1;
        for (let k = 2; k < q.length; k++) {
            if (q[k].prio > q[best].prio) {
                best = k;
            }
        }
        let a = q[best];
        // never two headlines at once: only the mission end takes over a slot.
        // A slab never goes up over a line still typing (r3: 03 LOW PASS over
        // 'Ha! Threaded', 1.2 s of letters left): it waits for the letters (to
        // the end of its own age at most), unless that line is its pair; nor
        // ahead of its pair still to come (SKY PORTAL waits for the tower's
        // call: they go up together, r3's slab held the kill cheer and cut it)
        let cut = a.prio >= 5 && a.prio > this.alertPrio;
        let on = this.commLine;
        let typed = this.commTyped();
        let shows = this.ctShows;
        let pr: string? = on != null ? pages.pair(on.text) : null;
        let paired = on != null && pr != null && pr == a.text;
        // (nor for the rock line's: r1 held 02 SEA ARCH until it expired, QA PT2)
        let typing = this.commT > 0 && typed < <f64>this.commText.length && !paired && !(on != null && on.rock);
        let due = !a.warn && pages.pairDue(this.events.follow, this.commQueue, a.text, this.commT > 0.05);
        // (a warning waits for letters out within WARN_HOLD: r4, BOGEYS ON YOUR
        // SIX! over VI's last letters at 390x844, boosting)
        let wait = a.warn ? a.age < pages.WARN_HOLD && this.commOut - this.commAge < pages.WARN_HOLD - a.age : a.age < a.maxAge - 0.1;
        if (!cut && (due || (typing && wait))) {
            if (due) {
                // (held for its pair: it keeps its place, not its age)
                a.age = lmin(a.age, a.maxAge - 0.5);
            }
            return;
        }
        if ((this.alertT <= 0 && (m.holdT <= 0 || a.warn)) || cut) {
            rem(q, best);
            // (hands-off, 04 CLIFF TURN FAILED went up 0.45 s before her cue)
            if (!a.warn && (a.kind == "checkpoint" || lsub(a.text, 1, 9) == "OBJECTIVE") && this.bossIn() < SLAB_SOON) {
                return;
            }
            // a checkpoint whose section call has been on air a while: the call
            // said it (hands-off 2700: 04 CLIFF TURN behind LOW PASS FAILED)
            if (a.kind == "checkpoint" && paired && this.commAge > pages.PAIR_WIN) {
                return;
            }
            if (!a.warn) {
                // a section said twice in a row already: no third checkpoint
                // slab (the route tab says it), a result in the objective's words
                let sec = <i32>pages.secNamed(a.text + " " + a.sub);
                if (this.annCount(sec) > 2) {
                    if (a.kind == "checkpoint") {
                        return;
                    } else if (lsub(a.text, 1, 9) == "OBJECTIVE") {
                        a.sub = pages.resultSub(sec, a.sub);
                        sec = <i32>pages.secNamed(a.sub);
                    }
                }
                this.annSay(sec);
            }
            this.alertShow(a);
            // a line that has not shown a letter yet waits for it (r3: BOGEYS
            // ON YOUR SIX! 2 frames into HANK's intro)
            if (on != null && this.commT > 0 && !shows && on.prio < 4 && this.slabWait(on)) {
                on.age = 0;
                ins(this.commQueue, 1, on);
                this.commClose();
                if (LOG_COMMS) {
                    this.CL("SLAB-requeue", CLline(on));
                }
            }
        }
    }

    // A downed boss keeps its HUD stack (bar at 0) until the hull is gone: the
    // final blast is over and the boss has left the field (8 s at most).
    bossDyingUpdate(dt: f64): void {
        if (!this.bossDying) {
            return;
        }
        let st = this.state;
        if (st == "paused") {
            return;
        }
        this.bossDyingT += dt;
        let E = this.enemies;
        let gone = E == null || !enemies.bossActive(E);
        if (gone || this.bossDyingT > 8 || !(st == "playing" || st == "outro" || st == "dying")) {
            this.bossDying = false;
            let h = this.hudVm;
            if (h != null) {
                vmx.bool(h, "bossActive", this.bossActive);
            }
        }
    }

    // A checkpoint (QA PT1-6): the run as it stands at a section edge, for
    // RETRY (Game.cpLabel). Not mid-fight, nor inside a boss cue's window (how
    // far past BOSS_CUES events.luau still fires them: keep in step), where a
    // retry would bring the boss back.
    checkpoint(): void {
        const BOSS_WIN: StaticArray<f64> = [0.0, 900, 700];
        let i = <i32>this.sc.sectionIdx;
        let secs = level.sections;
        let E = this.enemies;
        if (i < 1 || i >= secs.length || i < 2 || this.state != "playing" || this.reel > 0 || !this.player.alive
            || this.bossActive || this.bossDying || (E != null && enemies.bossActive(E))) {
            return;
        }
        let sec = secs[i];
        let cues = pages.BOSS_CUES;
        for (let k = 1; k < cues.length; k++) {
            let bs = cues[k];
            if (sec.s0 >= bs && sec.s0 < bs + BOSS_WIN[k]) {
                return;
            }
        }
        let p = this.player, st = this.stats;
        let cp = new Checkpoint(scoring.snapshot(this.sc));
        cp.idx = i;
        cp.s = sec.s0 + 2;
        cp.label = sec.num + " " + sec.label;
        cp.shield = p.shield; // (logs only: a checkpoint retry restores a full shield)
        cp.boost = p.boost;
        cp.bombs = this.bombs;
        cp.kills = st.kills;
        cp.killsTotal = st.killsTotal;
        cp.shotsFired = st.shotsFired;
        cp.shotsHit = st.shotsHit;
        cp.archDone = this.archDone;
        let ks = this.stingPlayed.keys();
        for (let k = 0; k < ks.length; k++) cp.stings.set(ks[k], this.stingPlayed.get(ks[k]));
        let kd = this.stingDown.keys();
        for (let k = 0; k < kd.length; k++) cp.down.set(kd[k], this.stingDown.get(kd[k]));
        this.memo.cp = cp;
        let g = this.gameVm;
        if (g != null) {
            vmx.optSetStr(g, "cpLabel", cp.label);
        }
    }

    // A hit point moved off his figure (at least 1.8 m from his centre across
    // the view, on its side; above him from dead centre) and 1.5 m past him
    // (his figure stays on top of what still reaches it): sparks, flares and
    // their glow never bloom over the pilot (QA PT1: a beam hit hid him; r3,
    // the deflect flare's ring still crossed him). Sets ohX / ohY / ohZ.
    offHero(x: f64, y: f64, z: f64): void {
        let P = this.player.pos;
        let R0 = this.camR, U0 = this.camU;
        let d = Vector.xyz(<f32>x, <f32>y, <f32>z) - P;
        let u = mathx.dot(d, R0), v = mathx.dot(d, U0);
        let l = Math.sqrt(u * u + v * v);
        if (l < 0.3) {
            u = 0;
            v = 1;
            l = 1;
        }
        let k = lmax(l, 1.8) / l;
        let q = P + R0 * <f32>(u * k) + U0 * <f32>(v * k) + mathx.cross(U0, R0) * <f32>1.5;
        this.ohX = q.x;
        this.ohY = q.y;
        this.ohZ = q.z;
    }

    // A rock hit's own feel (QA PT1-5: it costs 0.2 against a shot's 0.07): a
    // crunch, grey chips and grit thrown off the face along with him.
    rockFeel(x: f64, y: f64, z: f64, amount: f64): void {
        let F = this.fx, p = this.player;
        let v = p.fwd * <f32>(p.speed * 0.85);
        let n = amount > 0.15 ? 7 : 4;
        for (let i = 1; i <= n; i++) {
            let a = lrandom() * mathx.TAU;
            let sp = 4 + lrandom() * 6;
            let tone = 0.42 + lrandom() * 0.16;
            fx.debris(F, x, y, z, <f64>v.x + Math.cos(a) * sp, <f64>v.y + 2 + lrandom() * 4, <f64>v.z + Math.sin(a) * sp, 0.3, tone, tone * 0.94, tone * 0.88, false);
        }
        fx.carry(F, v.x, v.y, v.z);
        fx.smoke(F, x, y, z, 1.1, 0);
        fx.carry(F, 0, 0, 0);
        this.sfxPlay("explode_small", 0.55);
    }

    hurt(amount: f64, x: f64, y: f64, z: f64, fromScenery: bool, cause: string): void {
        let p = this.player;
        if (!p.alive || this.state != "playing") {
            return;
        }
        if (!fromScenery && p.invuln > 0) {
            return;
        }
        // nothing lands while a sting holds the screen or the camera is away
        if (this.sting != "" || this.rig.beat != "") {
            return;
        }
        p.shield = lmax(0, p.shield - amount);
        // float residue (five 0.2 hits leave 5.6e-17): what the HUD shows as
        // empty (it rounds to 0.01) is empty, and the next check downs him
        if (p.shield < 0.005) {
            p.shield = 0;
        }
        // the attract reel and the autopilot (QA) never go down
        if (this.reel > 0 || this.autopilotOn) {
            p.shield = lmax(p.shield, 0.05);
        }
        this.memo.cause = cause;
        p.invuln = fromScenery ? 0.5 : 1.0;
        p.flash = 1;
        // (a rock lands harder than a shot)
        this.hitStop = fromScenery ? 0.09 : 0.05;
        camera.addShake(this.rig, fromScenery ? (amount > 0.15 ? 2 : 1.5) : amount > 0.15 ? 1.5 : 1.1);
        this.offHero(x, y, z);
        let hx = this.ohX, hy = this.ohY, hz = this.ohZ;
        fx.sparks(this.fx, hx, hy, hz, 12, 1, 0.55, 0.25);
        this.sfxPlay("damage", 0.9);
        if (fromScenery) {
            this.rockFeel(hx, hy, hz, amount);
        }
        let h = this.hudVm;
        if (h != null) {
            vmx.fire(h, "damage");
        }
        this.pilotTrigger("hit");
        let r = this.r;
        if (r != null) {
            r.post.damage = 1;
            r.visor.glitch = lmax(r.visor.glitch, fromScenery ? 1 : 0.8);
        }
        // say what hit him (QA PT1-5): the first rock of a run gets the tower's
        // line at once (a slab read first), unless heard since the title (r2:
        // every retry at the stacks heard it again); 'roll it off' is for shots
        // (and none on the final approach: MISSION COMPLETE is coming)
        if (fromScenery) {
            let RL = scoring.ROCK_LINES;
            let rl = RL.has(cause) ? RL.get(cause) : RL.get("ROCKS");
            if (!this.memo.rockHit && !this.heardIt(rl)) {
                this.memo.rockHit = true;
                // (9 s: it may wait out a call or two in the Low Pass and the
                // canyon; in the stack field the stretch's end, 1500, drops it
                // first: pages.rockUntil)
                let l = this.commPush("tower", "LIGHTHOUSE", rl, 2.6, "worried", 3, 9);
                if (l != null) {
                    // it yields to the scripted calls like a wingman's line (QA
                    // PT2-5): it never goes ahead of one waiting, starts only
                    // when it is over before the next hazard call ('Watch the
                    // stacks!' when short of room: pages.hazardIn), and a beat
                    // due takes over from it at a word
                    l.yield = true;
                    l.rock = true;
                }
            }
        } else if (p.s < level.eye.s - 450) {
            // (a useful call: it outranks flavor, drops after 2 s)
            let say = this.wing.say;
            let n0 = say.length - 1;
            wingmen.react(this.wing, "hit");
            for (let i = n0 + 1; i < say.length; i++) {
                say[i].prio = 2;
                say[i].call = "react";
            }
        }
    }

    // BOMB charges on the HUD pip and Game.bombs (the touch BOMB pip)
    syncBombs(): void {
        let hb = this.hudVm, gb = this.gameVm;
        if (hb != null) {
            vmx.optSetNum(hb, "bombs", this.bombs);
        }
        if (gb != null) {
            vmx.optSetNum(gb, "bombs", this.bombs);
        }
    }

    // keepS: the rail distance the pilot waits at (NaN: the bay, 0). keepSting
    // (RunOpts.keepSting): keeps only the live sting (the cut).
    resetRun(keepS: f64 = NaN, keepSting: bool = false): void {
        let s0 = opt(keepS, 0);
        this.player = playerMod.create();
        // (a pull left over from a scrape must not draw the new pilot off his spot)
        this.heroPull = 0;
        this.player.s = s0;
        this.player.y = 2.8; // hover low over the bay: spray and a clear reflection
        this.player.frozen = true;
        playerMod.place(this.player);
        let trs = this.trails;
        for (let i = 1; i < trs.length; i++) {
            R.trailClear(trs[i]);
        }
        let sm = this.smoke;
        if (sm != null) {
            R.trailClear(sm);
        }
        this.launchT = -1;
        this.entered = false;
        this.enteredT = 0;
        this.stats.kills = 0;
        this.stats.killsTotal = 0;
        this.stats.shotsFired = 0;
        this.stats.shotsHit = 0;
        scoring.reset(this.sc, this.stats);
        rings.reset(this.rings);
        weapons.reset(this.weapons);
        wingmen.reset(this.wing);
        popups.clear(this.pops);
        wake.clear(this.wake);
        this.fx.parts.length = 1;
        if (LOG_COMMS && this.commOn) {
            this.commLogEnd("RESET");
        }
        this.commQueue.length = 1;
        this.memo.later.length = 1;
        this.alerts.length = 1;
        this.memo.rockHit = false;
        this.memo.cause = "";
        this.memo.annN.clear();
        this.memo.annT.clear();
        this.memo.give = false;
        this.memo.clrT = 0;
        this.memo.holdT = 0;
        this.memo.goT = 0;
        this.commAge = 0;
        this.commPrio = 0;
        this.commText = "";
        this.commLine = null;
        this.commOut = 0;
        this.commOutAge = -1;
        this.commCutAt = -1;
        this.commOn = false;
        this.commHold = 0;
        this.commBoss = false;
        this.alertT = 0;
        this.alertAge = 0;
        this.alertPrio = 0;
        this.alertCut = false;
        this.alertBossT = 0;
        let E = this.enemies;
        if (E != null) {
            enemies.clear(E);
        }
        events.reset(this.events);
        this.portalT = -1;
        this.archDone = false;
        this.stingReset(keepSting);
        this.bossName = "";
        this.bombs = BOMBS;
        this.bombCd = 0;
        this.bombT = -1;
        this.syncBombs();
        this.hudCache.clear();
        this.pal = palette.coast;
        this.commT = 0;
        this.warnT = 0;
        this.bossActive = false;
        this.bossDying = false;
        this.bossDyingT = 0;
        this.bossPick = null;
        this.wingHeld.length = 1;
        this.prevS = s0;
        this.lastShield = 1;
        this.countdown = 3;
        R.hudFlush(this.r);
        let h = this.hudVm;
        if (h != null) {
            vmx.bool(h, "commActive", false);
            vmx.bool(h, "warningActive", false);
            vmx.bool(h, "bossActive", false);
            vmx.num(h, "bossHealth", 1);
            vmx.optSetStr(h, "bossPhase", "");
            vmx.optSetNum(h, "bossU", -1);
            vmx.optSetNum(h, "bossV", -1);
            hud.syncHud(h, this.hudCache, this.player, this.sc, this.weapons, false);
        }
        let g = this.gameVm;
        if (g != null) {
            vmx.num(g, "countdown", 3);
            // the results / game over sheets count up from zero next time
            vmx.bool(g, "newBest", false);
            vmx.str(g, "timeText", this.sc.timeText);
            vmx.num(g, "score", 0);
            vmx.str(g, "scoreText", "0000000");
            vmx.num(g, "rings", 0);
            vmx.num(g, "ringsTotal", this.sc.ringsTotal);
            vmx.num(g, "kills", 0);
            vmx.num(g, "killsTotal", 0);
            vmx.num(g, "hitRatio", 0);
            vmx.str(g, "rank", "");
            vmx.optSetStr(g, "downedAt", "");
            vmx.optSetStr(g, "failCause", "");
            vmx.optSetStr(g, "failTip", "");
            vmx.optSetNum(g, "failProgress", -1);
            vmx.optSetNum(g, "objectives", 0);
            vmx.optSetNum(g, "objectivesTotal", 0);
        }
        let r = this.r;
        if (r != null) {
            r.post.portal = 0;
            r.post.fade = 0;
            r.post.flash = 0;
            r.post.damage = 0;
        }
        let c = this.ctx2;
        if (c != null) {
            this.syncTypesPlayer();
            c.railS = s0;
        }
        input.releaseAll(this.inp);
        // the flight school: nothing survives a reset (the cut finishes it itself)
        if (!keepSting) {
            training.reset(this.school, this.schoolEnv());
        }
        this.school.rings.list.length = 1;
        this.schoolArmed = false;
        if (g != null) {
            vmx.optSetBool(g, "trainArmed", false);
        }
    }

    // Lifecycle -------------------------------------------------------------------------

    override init(context: Context): bool {
        this.ctx = context;
        training.setLOG(LOG_TRAIN);
        // (the view model and the artboard inputs may bind later: load waits
        // for them; the heavy setup runs in steps over the first advances)
        this.bindGame();
        return true;
    }

    // Luau init's first half: the Game view model (once bound).
    bindGame(): void {
        let context = this.ctx;
        if (context == null || this.gameVm != null) return;
        let g = context.viewModel();
        if (g != null) {
            let gb = vmx.bag(g);
            this.gameVm = gb;
            training.prime(gb);
            this.setState(this.state);
            vmx.num(gb, "menuIndex", this.menuIndex);
            vmx.optSetBool(gb, "musicOn", this.musicOn);
            vmx.optSetBool(gb, "soundOn", this.soundOn);
        }
    }

    // Luau init's second half, one step an advance (each well under the
    // watchdog in the dev build). True once done.
    load(): bool {
        let context = this.ctx;
        if (context == null) return false;
        this.bindGame();
        if (this.gameVm == null) {
            // the runtime binds the view model after init: build the renderer
            // and the instances only then
            return false;
        }
        let step = this.loadStep;
        this.loadStep += 1;
        if (step == 0) {
            this.loadArt(context);
        } else if (step == 1) {
            this.loadRig(context);
        } else if (step == 2) {
            // plan only: the start chunks bake in pump (watchdog)
            scenery.knobs.START_SYNC = false;
            this.chunks = scenery.build();
        } else if (step == 3) {
            // the storm meshes (fx builds them on first use: here, apart)
            fx.stormBuild();
        } else if (step == 4) {
            // Luau's START_SYNC: the near start chunks (title attract, launch)
            // baked before the game runs, here in pump slices
            // (a slow build, the unoptimized dev preview: the whole course, so
            // no chunk is baked on the spot later in one call over the 200 ms
            // watchdog; behaviour-neutral: probes answer the same either way)
            let all = scenery.stats.planMs > SLOW_PLAN_MS;
            if (all ? !scenery.ready() : !this.startBaked()) {
                scenery.pump(0, 6);
                this.loadStep = 4;
            }
        } else {
            this.rings = rings.create();
            this.school.rings = rings.fromSpecs(new Array<rings.Spec>(1), this.rings);
            this.resetRun();
            this.loaded = true;
            context.log("game: loaded");
            // (Luau: resize follows init; a size that came in while loading)
            let r = this.r;
            if (r != null && this.size.y > 0) {
                R.hudFlush(r);
                R.resize(r, this.size.x, this.size.y, this.scale);
            }
            return true;
        }
        return false;
    }

    startBaked(): bool {
        let ch = this.chunks;
        for (let i = 1; i < ch.length; i++) {
            let c = ch[i];
            if (!c.ready && c.gs0 < scenery.knobs.URGENT_AHEAD && c.gs1 > -200 && c.name.indexOf("far") < 0) return false;
        }
        return true;
    }

    loadArt(context: Context): void {
        let r = R.create(context);
        this.r = r;
        let hudIn = this.hud, pilotIn = this.pilot, reticleIn = this.reticle;
        // artboard instances with their own view models
        if (hudIn != null) {
            let hvm = ViewModel.create("Hud");
            let hudArt = hudIn.instance(asHud(hvm));
            this.hudArt = hudArt;
            this.hudVm = vmx.bag(hvm);
            R.setHud(r, plainHud(hudArt));
        }
        if (pilotIn != null) {
            let pvm = ViewModel.create("Pilot");
            let pbag = vmx.bag(pvm);
            // the hero wears the painted poses (skin = hero, the default; the
            // wingmen wear theirs, see wingmen.attach)
            if (pvm.getBoolean("raster") != null) {
                vmx.optSetBool(pbag, "raster", true);
                this.anchors = ANCHORS_RASTER;
            }
            let pilotArt = pilotIn.instance(asPilot(pvm));
            this.pilotArt = pilotArt;
            this.pilotVm = pbag;
            if (this.anchors == ANCHORS_RASTER) {
                this.heroNodes = readHeroNodes(pilotArt);
            }
            // The water mirrors a twin hero posed from below (Pilot.reflection):
            // the renderer draws reflection-only sprites.
            let tvm = ViewModel.create("Pilot");
            let tb = vmx.bag(tvm);
            vmx.optSetBool(tb, "raster", true);
            vmx.optSetBool(tb, "reflection", true);
            let twin = pilotIn.instance(asPilot(tvm));
            this.reflArt = twin;
            this.reflVm = tb;
            this.reflSprite = R.createReflectionSprite(r, "pilotRefl", plainPilot(twin), 512, 512, 1);
            this.pilotSprite = R.createSprite(r, "pilot", plainPilot(pilotArt), 768, 768, 4, false, false);
        }
        // opaque hero texels write depth + a gbuffer mark (ink, glows behind him stop at his silhouette)
        let ps0 = this.pilotSprite;
        if (ps0 != null) {
            R.setSpriteSolid(ps0, true);
        }
        if (reticleIn != null) {
            let rvm = ViewModel.create("Reticle");
            let reticleArt = reticleIn.instance(asReticle(rvm));
            this.reticleArt = reticleArt;
            this.reticleVm = vmx.bag(rvm);
            this.reticleSprite = R.createSprite(r, "reticle", plainReticle(reticleArt), 384, 384, 2, false, true);
        }
    }

    loadRig(context: Context): void {
        let r = this.r!;
        let pilotIn = this.pilot;
        if (pilotIn != null) {
            wingmen.attach(this.wing, r, plainPilot(pilotIn));
        }
        let rig = this.rig;
        // the chase lens stays out of rocks (camera occlusion probe)
        // (while the scenery bakes a plain probe checks every pending chunk: a
        // burst of probes in one box, e.g. the death cam's slot scoring, is
        // answered from one near list then, with the same answers)
        rig.world = new GameWorld(this);
        let kp = new GameKeeper(rig);
        // from the camera rig, not the renderer's last drawn matrix
        kp.halfW = camera.zone(this.rig.aspect);
        this.keeper = kp;
        let wl = this.wing.list;
        for (let i = 1; i < wl.length; i++) {
            let ws = wl[i].sprite;
            if (ws != null) {
                R.setSpriteSolid(ws, true);
            }
        }
        let lockIn = this.lockon;
        if (lockIn != null) {
            weapons.attachLockOn(this.weapons, r, lockIn);
        }
        weapons.buildMeshes(this.weapons);
        wake.build(this.wake);
        let popIn = this.popup;
        if (popIn != null) {
            popups.attach(this.pops, r, popIn);
        }

        // the two swirl portals are static: frame them once
        let por = level.portal, eyeG = level.eye;
        track.frame(level.track, por.s);
        let pf = track.FRAME_F;
        this.porPos = level.world(por.s, por.x, por.y);
        this.porFwd = pf;
        track.frame(level.track, eyeG.s);
        let ef = track.FRAME_F;
        this.eyePos = level.world(eyeG.s, eyeG.x, eyeG.y);
        this.eyeFwd = ef;
        // jet exhaust ribbons and wingtip vapor
        let trs = new Array<R.Trail>(1);
        trs.push(R.newTrail(20, 1, 0.12, 0.5, 1, 0.66, 0.3, 0.95, 0.7));
        trs.push(R.newTrail(20, 1, 0.12, 0.5, 1, 0.66, 0.3, 0.95, 0.7));
        trs.push(R.newTrail(36, 0, 0.5, 0.2, 1, 1, 1, 0.8, 0.9));
        trs.push(R.newTrail(36, 0, 0.5, 0.2, 1, 1, 1, 0.8, 0.9));
        this.trails = trs;
        // the crash streak: a wide, pale grey-lavender haze, soft-edged and
        // see-through (vapor kind: the inked toon kind read as an opaque, hard
        // pipe, QA M8), as wide as the puffs it carries so the two read as one
        // plume
        this.smoke = R.newTrail(48, 0, 2.2, 3.2, 0.62, 0.61, 0.7, 0.8, 1.2);

        this.sfx = sfx.create(context);
        if (isDefined(FRAMECLOCK)) this.sfx.timeFn = frameClock;
        this.enemies = enemies.create(this.fx);
        this.ctx2 = new GameCtx(this);
    }

    override resize(width: f64, height: f64, scale: f64): void {
        let size = Vector.xy(<f32>width, <f32>height);
        this.size = size;
        this.scale = scale;
        cmode.window(this.modeRec, size, scale);
        if (size.y > 0) {
            this.rig.aspect = <f64>size.x / <f64>size.y;
            let kp = this.keeper;
            if (kp != null) {
                kp.halfW = camera.zone(this.rig.aspect);
            }
        }
        let r = this.r;
        if (r != null) {
            R.hudFlush(r);
            R.resize(r, size.x, size.y, scale);
        }
    }

    // Simulation -------------------------------------------------------------------------

    // BOMB (B / pad Y): a shock nova that clears the sky ahead. Two per run, a
    // long cooldown: small fry in reach go at once, boss parts take a knock,
    // bullets in the air are wiped. White / crimson / brass shock rings + a print
    // flash.
    bomb(): void {
        let p = this.player;
        let E = this.enemies, c = this.ctx2;
        if (this.bombs <= 0 || this.bombCd > 0 || !p.alive || !p.controls || !flying(this.state)) {
            return;
        }
        this.bombs -= 1;
        this.bombCd = BOMB_CD;
        this.bombT = 0;
        // the nova bursts ahead of him (never a bloom over the hero)
        let pos = p.pos + p.fwd * <f32>26;
        this.bombPos = pos;
        if (E != null && c != null) {
            let list = E.list;
            for (let i = 1; i < list.length; i++) {
                let e = list[i];
                if (e.alive && !e.hidden && e.dying <= 0) {
                    let dx = e.x - <f64>pos.x, dy = e.y - <f64>pos.y, dz = e.z - <f64>pos.z;
                    let along = dx * <f64>p.fwd.x + dy * <f64>p.fwd.y + dz * <f64>p.fwd.z;
                    if (along > -30 && along < BOMB_REACH && dx * dx + dy * dy + dz * dz < BOMB_REACH * BOMB_REACH) {
                        enemies.damage(E, c, e, e.part ? 3 : 999);
                    }
                }
            }
            let bl = E.bullets;
            for (let i = 1; i < bl.length; i++) {
                let b = bl[i];
                let dx = b.x - <f64>pos.x, dy = b.y - <f64>pos.y, dz = b.z - <f64>pos.z;
                if (dx * dx + dy * dy + dz * dz < BOMB_REACH * BOMB_REACH) {
                    b.life = 0;
                }
            }
        }
        let W = this.weapons;
        weapons.flare(W, pos.x, pos.y, pos.z, 3, 58, 1.0, 1, 1, 1, 2);
        weapons.flare(W, pos.x, pos.y, pos.z, 2, 38, 0.85, 0.85, 0.14, 0.37, 2);
        weapons.flare(W, pos.x, pos.y, pos.z, 2.5, 16, 0.3, 0.95, 0.72, 0.2, 1);
        weapons.flare(W, pos.x, 0.3, pos.z, 3, 48, 1.1, 0.95, 1, 1, 2);
        fx.sparks(this.fx, pos.x, pos.y, pos.z, 40, 1, 0.85, 0.4);
        camera.addShake(this.rig, 1.1);
        this.rig.fovKick = lmax(this.rig.fovKick, rad(12));
        let r = this.r;
        if (r != null) {
            // a print flash: the frame re-prints as halftone plates on cream
            R.printFlash(r, 0.8, 0.3);
            r.post.flash = 0.25;
            r.post.flashR = 0.95;
            r.post.flashG = 0.92;
            r.post.flashB = 0.84;
            r.visor.glitch = lmax(r.visor.glitch, 0.5);
        }
        this.sfxPlay("explode_big", 1);
        this.sfxPlay("nova", 0.9);
        this.syncBombs();
        let h = this.hudVm;
        if (h != null) {
            if (vmx.hasTrigger(h, "bombFire")) {
                vmx.fire(h, "bombFire");
            }
        }
    }

    readControls(): void {
        let c = this.ctrl;
        let inp = this.inp;
        let S = this.school;
        if (this.autopilotOn) {
            let E = this.enemies;
            // (the flight school: its practice rings)
            let list = S.active ? S.rings.list : this.rings.list;
            if (isDefined(REPLAY)) {
                // (the call's arguments as the real one: commTyping updates the channel's typed state)
                this.commTyping();
                replayDrive(this.auto, this.player, c);
            }
            else {
                let rng = this.player.shield < this.auto.lastShield - 0.01;
                autopilot.drive(this.auto, this.player, c, list, E, this.chunks, this.weapons.hot, this.weapons.lockCount, this.t, this.dt, this.commTyping());
                if (isDefined(APR)) {
                    aprK++;
                    let bits = (c.fire ? 1 : 0) + (c.boost ? 2 : 0) + (c.rollL ? 4 : 0) + (c.rollR ? 8 : 0);
                    console.log(format("APR %d %.17g %.17g %d %d", [FormatArg.number(aprK), FormatArg.number(c.sx), FormatArg.number(c.sy), FormatArg.number(bits), FormatArg.number(rng ? 1 : 0)]));
                }
            }
            if (S.active) {
                autopilot.school(this.auto, c, S.lesson, S.timing);
            }
            // the pilot can still take over any axis
            let sx = input.steer(inp);
            let sy = input.STEER_2;
            if (sx != 0) c.sx = sx;
            if (sy != 0) c.sy = sy;
            c.fire = c.fire || input.down(inp, "fire");
            c.boost = c.boost || input.down(inp, "boost");
            c.brake = input.down(inp, "brake");
            c.rollL = c.rollL || input.pressed(inp, "rollL");
            c.rollR = c.rollR || input.pressed(inp, "rollR");
            c.bomb = input.pressed(inp, "bomb");
        } else {
            c.sx = input.steer(inp);
            c.sy = input.STEER_2;
            c.fire = input.down(inp, "fire");
            c.boost = input.down(inp, "boost");
            c.brake = input.down(inp, "brake");
            c.rollL = input.pressed(inp, "rollL");
            c.rollR = input.pressed(inp, "rollR");
            c.bomb = input.pressed(inp, "bomb");
        }
        // the flight school's demo: the flight computer takes the stick
        if (S.active) {
            training.inject(S, c);
        }
        if (c.bomb) {
            this.bomb();
        }
    }

    simulate(dt: f64, weaponsOn: bool): void {
        let p = this.player;
        let c = this.ctx2;
        let E = this.enemies;
        this.bombCd = lmax(0, this.bombCd - dt);
        if (this.bombT >= 0) {
            this.bombT += dt;
        }
        this.readControls();
        let S = this.school;
        let school = S.active;
        let s0 = p.s;
        let hit = playerMod.update(p, this.ctrl, dt, this.chunks);
        let rolled = playerMod.UPDATE_2;
        this.rolledNow = rolled;
        if (rolled) {
            this.sfxPlay("roll", 0.7);
            this.pilotTrigger("roll");
            wingmen.echoRoll(this.wing, p.rollDir);
            // a whoosh of air around the roll, 2 m past him (his figure stays on
            // top of its ring), none while a hit's burst is up: the two boxed
            // him in at the Watcher's beam (QA PT1-9 r3)
            if (p.flash <= 0) {
                let wq = p.pos + mathx.cross(this.camU, this.camR) * <f32>2;
                weapons.flare(this.weapons, wq.x, wq.y, wq.z, 1.8, 7, 0.28, 0.9, 0.97, 1, 2);
            }
        }
        if (p.evBoost) {
            this.sfxPlay("boost_start", 0.8);
            camera.addShake(this.rig, 0.45);
        }
        if (p.boosting) {
            // the pack rattles the lens while it burns
            camera.addShake(this.rig, 0.26);
        }
        if (p.evOverheat) {
            this.sfxPlay("overheat", 0.9);
            let rr = this.r;
            if (rr != null) {
                rr.visor.glitch = lmax(rr.visor.glitch, 0.4);
            }
        }
        if (p.evSplash) {
            this.sfxPlay("splash", 0.8);
            for (let i = 1; i <= 14; i++) {
                let ox = (lrandom() - 0.5) * 2;
                let oz = (lrandom() - 0.5) * 2;
                fx.spray(this.fx, <f64>p.pos.x + ox, 0, <f64>p.pos.z + oz, 1);
            }
            camera.addShake(this.rig, 0.25);
        }
        if (hit.hit && p.hurtCd <= 0) {
            if (LOG_STING) {
                console.log(format("[wall %5.0f m x %.1f y %.1f]", [FN(p.s), FN(p.x), FN(p.y)]));
            }
            p.hurtCd = 0.6;
            p.wallHits += 1;
            scoring.wallHit(this.sc);
            // (where the contact is, across the rail: a canyon pillar or the wall)
            let rp = p.railPos, rt = p.right;
            let lat = (hit.x - <f64>rp.x) * <f64>rt.x + (hit.z - <f64>rp.z) * <f64>rt.z;
            this.hurt(hit.head ? 0.2 : 0.1, hit.x, hit.y, hit.z, true, scoring.rockCause(p.s, lat, hit.y));
            this.offHero(hit.x, hit.y, hit.z);
            fx.sparks(this.fx, this.ohX, this.ohY, this.ohZ, 16, 1, 0.85, 0.5);
        } else if (hit.hit) {
            fx.sparks(this.fx, hit.x, hit.y, hit.z, 3, 1, 0.85, 0.5);
        }
        if (p.evNearMiss && weaponsOn) {
            // threaded past the rock without a scratch
            let pts = scoring.closeCall(this.sc, p);
            let ax = p.pos + p.fwd * <f32>15 + p.up * <f32>2.6;
            let v = p.fwd * <f32>p.speed;
            popups.spawn(this.pops, "CLOSE CALL +" + lstr(pts), "bonus", ax.x, ax.y, ax.z, 0.95, v.x, v.y, v.z);
            weapons.flare(this.weapons, p.nearX, p.nearY, p.nearZ, 0.8, 16, 0.3, 0.7, 0.95, 1, 2);
            this.sfxPlay("flyby", 0.45);
        }

        // rings (the flight school: its practice rings instead)
        if (school) {
            training.ringsStep(S, this.schoolEnv(), s0, dt);
        } else {
            rings.update(this.rings, s0, p.s, p.x, p.y, dt);
        }
        let got = school ? NO_RINGS : this.rings.collected;
        for (let gi = 1; gi < got.length; gi++) {
            let ring = got[gi];
            let pts = scoring.ring(this.sc, p, ring.kind);
            if (ring.kind == "silver") {
                p.shield = lmin(1, p.shield + 0.25);
                this.sfxPlay("ring_silver", 0.9);
            } else if (ring.kind == "boost") {
                p.boost = lmin(100, p.boost + 50);
                // a boss fight's speed hold caps the surge like a boost (cap + 25)
                let surge = p.speedCap > 0 ? lmin(playerMod.BOOST, p.speedCap + 25) : playerMod.BOOST;
                p.speed = lmax(p.speed, surge);
                p.boostKick = 1;
                this.rig.fovKick = rad(6);
                this.sfxPlay("boost_start", 0.8);
                this.sfxPlay("ring", 0.9);
            } else {
                p.boost = lmin(100, p.boost + 25);
                p.shield = lmin(1, p.shield + 0.05);
                this.sfxPlay("ring", 0.9);
            }
            // the collect burst rides ahead of the pilot (the lens passes the ring
            // plane a moment later: nothing blooms over the hero)
            let rp = ring.pos + ring.fwd * <f32>12;
            let col = ring.kind == "silver" ? 0.9 : ring.kind == "boost" ? 0.4 : 1.0;
            weapons.flare(this.weapons, rp.x, rp.y, rp.z, 3.4, 14, 0.4, col, ring.kind == "boost" ? 0.9 : 0.85, ring.kind == "gold" ? 0.35 : 1, 2);
            fx.sparks(this.fx, rp.x, rp.y, rp.z, 10, 1, 0.9, 0.45);
            let chain = this.sc.ringChain;
            let ax = p.pos + p.fwd * <f32>16 + p.up * <f32>2.4;
            let v = p.fwd * <f32>p.speed;
            popups.spawn(this.pops, chain >= 2 ? format("RING x%d  +%d", [FN(chain), FN(pts)]) : "+" + lstr(pts), "ring", ax.x, ax.y, ax.z, 0.9, v.x, v.y, v.z);
            let h = this.hudVm;
            if (h != null) {
                vmx.fire(h, "ringPulse");
            }
            if (chain == 6) {
                wingmen.react(this.wing, "ring");
            }
        }
        if (!school && this.rings.missedCount > 0) {
            scoring.ringMissed(this.sc);
        }

        // sea arch objective
        if (!this.archDone) {
            archWindow();
            let as = AW_S, x0 = AW_X0, x1 = AW_X1, y0 = AW_Y0, y1 = AW_Y1;
            // lined up on the window ~0.55 s out: the lens drops to the water for
            // the fly-through (the THREADED sting holds it in bullet time)
            if (!this.archLow && weaponsOn && p.s < as && p.s > as - p.speed * 0.55
                && p.x > x0 + 1.5 && p.x < x1 - 1.5 && p.y > y0 + 1 && p.y < y1 - 2) {
                this.archLow = true;
                camera.beat(this.rig, "arch", 1.2, p);
            }
            if (s0 < as && p.s >= as) {
                this.archDone = true;
                let ok = p.x > x0 && p.x < x1 && p.y > y0 && p.y < y1;
                scoring.archPassed(this.sc, ok, c!);
                if (ok) {
                    let pts = scoring.add(this.sc, p, 500);
                    let v = p.fwd * <f32>p.speed;
                    popups.spawn(this.pops, "ARCH +" + lstr(pts), "bonus", <f64>p.pos.x + <f64>p.fwd.x * 18, <f64>p.pos.y + 4, <f64>p.pos.z + <f64>p.fwd.z * 18, 1.2, v.x, v.y, v.z);
                    this.stingFire("arch_threaded", "THREADED!", "SEA ARCH  //  +" + lstr(pts));
                } else if (this.archLow) {
                    camera.beatEnd(this.rig, false);
                }
            }
        }

        // world: events + enemies
        this.syncTypesPlayer();
        if (c != null && E != null) {
            c.t = this.t;
            c.dt = dt;
            c.railS = p.s;
            if (!school) {
                events.update(this.events, E, c);
            }
            enemies.update(E, c, dt);
            // a shot grazing a wingman: he flinches (painted hit pose), sparks fly
            if (this.wing.positions.length - 1 > 0) {
                let bl = E.bullets;
                for (let i = 1; i < bl.length; i++) {
                    let b = bl[i];
                    if (!b.deflected && wingmen.flinch(this.wing, b.x, b.y, b.z, 1.4)) {
                        fx.sparks(this.fx, b.x, b.y, b.z, 8, 1, 0.8, 0.45);
                    }
                }
            }
        }
        if (weaponsOn && c != null) {
            weapons.update(this.weapons, p, this.ctrl.fire, dt, c, E, this.fx);
        } else {
            weapons.update(this.weapons, p, false, dt, c!, E, this.fx);
        }
        if (this.weapons.newLock) {
            let h = this.hudVm;
            if (h != null) {
                vmx.fire(h, "lockPulse");
            }
        }
        if (this.weapons.firedNova) {
            camera.addShake(this.rig, 0.35);
            this.rig.push = 1.2;
        }

        // scoring (kills -> combo, sections, objectives; never in the school)
        if (c != null && !school) {
            let sec0 = this.sc.sectionIdx;
            let bonus = scoring.update(this.sc, p, c, dt);
            if (this.sc.sectionIdx != sec0) {
                // a section edge: the route tab says its name; a checkpoint
                this.annSay(<i32>this.sc.sectionIdx);
                this.checkpoint();
            }
            if (this.sc.killPulse) {
                let h = this.hudVm;
                if (h != null) {
                    vmx.fire(h, "killPulse");
                }
                // every kill lands with a little kick
                camera.addShake(this.rig, 0.22);
                if (this.sc.combo == 5) {
                    wingmen.react(this.wing, "combo");
                }
            }
            if (bonus > 0) {
                let f = p.fwd;
                let v = f * <f32>p.speed;
                popups.spawn(this.pops, format("CHAIN x%d  +%d", [FN(this.sc.lastChain), FN(bonus)]), "bonus", <f64>p.pos.x + <f64>f.x * 20, <f64>p.pos.y + 5, <f64>p.pos.z + <f64>f.z * 20, 1.3, v.x, v.y, v.z);
                this.sfxPlay("checkpoint", 0.5);
            }
        }

        // spray kicked up off the V arms while skimming (the wake module lays the foam)
        let alt = <f64>p.pos.y;
        if (p.overWater && alt < 3.6 && p.alive) {
            let k = mathx.saturate((3.6 - alt) / 2.5);
            this.sprayT -= dt * (0.4 + k * 1.6);
            if (this.sprayT <= 0) {
                this.sprayT = 0.05;
                let side = lrandom() < 0.5 ? -1.0 : 1.0;
                let off = 0.6 + lrandom() * 1.2;
                fx.spray(this.fx, <f64>p.pos.x - <f64>p.fwd.x * 2.2 + <f64>p.right.x * side * off, 0, <f64>p.pos.z - <f64>p.fwd.z * 2.2 + <f64>p.right.z * side * off, 0.5 + 0.5 * k);
            }
        }
        this.prevS = p.s;
    }

    // Portal dive: swirl as it nears, flash + palette shift + visor glitch through.
    updatePortal(dt: f64): void {
        let r = this.r;
        let p = this.player;
        if (r == null) {
            return;
        }
        let ps = level.portalS;
        let pp = r.post;
        if (this.portalT < 0) {
            // approach: a gentle swirl grows around the portal mouth
            let a = mathx.smoothstep(ps - 520, ps, p.s);
            if (a > 0) {
                track.frame(level.track, ps);
                let tp = track.FRAME_P, rt = track.FRAME_R, up = track.FRAME_U;
                let oy = p.y;
                let cx = <f64>tp.x + <f64>up.x * oy + <f64>rt.x * p.x * 0.5, cy = <f64>tp.y + <f64>up.y * oy, cz = <f64>tp.z + <f64>up.z * oy + <f64>rt.z * p.x * 0.5;
                let u = camera.project(this.rig, Vector.xyz(<f32>cx, <f32>cy, <f32>cz));
                let v = camera.PROJECT_2, w = camera.PROJECT_3;
                if (w > 0) {
                    pp.portalX = mathx.damp(pp.portalX, mathx.clamp(u, 0.2, 0.8), 6, dt);
                    pp.portalY = mathx.damp(pp.portalY, mathx.clamp(v, 0.2, 0.8), 6, dt);
                }
                pp.portal = a * a * 0.24;
                pp.portalR = 0.03 + a * a * 0.1;
                // the camera eases back and lifts to frame the swirl
                let po = this.porPos;
                camera.focus(this.rig, po.x, po.y, po.z, mathx.smoothstep(0.2, 0.8, a) * 0.3);
                if (lrandom() < a * a * 0.06) {
                    r.visor.glitch = lmax(r.visor.glitch, 0.45);
                }
                camera.addShake(this.rig, a * a * 0.3);
                this.rig.fovKick = lmax(this.rig.fovKick, a * a * rad(8));
            } else {
                pp.portal = 0;
            }
            if (p.s >= ps) {
                // the dive: white-violet flash, visor glitch, fov punch, palette shift
                this.portalT = 0;
                pp.flash = 1;
                pp.flashR = 0.92;
                pp.flashG = 0.86;
                pp.flashB = 1;
                pp.portal = 0.5;
                pp.portalX = 0.5;
                pp.portalY = 0.48;
                pp.portalR = 0.14;
                r.visor.glitch = 1;
                this.rig.twist = 0.35;
                this.rig.fovKick = rad(24);
                camera.addShake(this.rig, 1.3);
                this.sfxPlay("portal", 1);
                this.setMusic("music_violet");
                this.stingFire("chapter_violet", "VIOLET REACH", "CHAPTER 2");
            }
        } else {
            this.portalT += dt;
            let k = mathx.saturate(this.portalT / 2);
            this.pal = k >= 1 ? palette.violet : palette.lerp(palette.coast, palette.violet, mathx.smoothstep(0, 1, k));
            pp.portal = lmax(0, pp.portal - dt * 0.4);
            pp.portalR = lmax(0.02, pp.portalR - dt * 0.06);
            if (this.portalT < 1.2) {
                r.visor.glitch = lmax(r.visor.glitch, 0.6 * (1 - this.portalT / 1.2));
            }
        }
    }

    menuStep(strict: bool = false): f64 {
        let inp = this.inp;
        let n = menuCount(this.state);
        let g = this.gameVm;
        if (g != null) {
            // the UI may move the highlight on hover
            let live = vmx.readNumLive(g, "menuIndex");
            if (!isNaN(live) && live != this.menuIndex && live >= 0 && live < n) {
                this.menuIndex = Math.floor(live);
            }
        }
        // the game over buttons sit in a row in landscape (RETRY | TITLE, Main's
        // landscape group: width >= height); every other menu is a column
        let horiz = this.state == "gameover" && this.rig.aspect >= 1;
        let d = input.nav(inp, horiz);
        if (d != 0 && n > 0) {
            this.setMenu(mod(this.menuIndex + d, n));
            this.sfxPlay("ui_move", 0.6);
        }
        let act = -1.0;
        if (input.pressed(inp, strict ? "accept" : "confirm")) {
            act = this.menuIndex;
        }
        if (g != null && vmx.takeBool(g, "menuPressed")) {
            act = this.menuIndex;
        }
        return act;
    }

    // Control mode from a menu: -1 previous, 1 next (keyboard -> gamepad -> touch).
    modeStep(d: f64): void {
        let m = this.modeRec;
        cmode.step(m, d);
        this.controlMode = m.mode;
        cmode.write(m, this.gameVm);
        this.sfxPlay("ui_move", 0.6);
    }

    // A CONTROLS row (title, pause): left / right step the mode.
    controlsRow(): void {
        let inp = this.inp;
        if (input.pressed(inp, "left")) {
            this.modeStep(-1);
        } else if (input.pressed(inp, "right")) {
            this.modeStep(1);
        }
    }

    // Graphics quality from a menu: -1 previous, 1 next (auto -> low -> medium -> high).
    qualityStep(d: f64): void {
        cquality.step(this.qualityRec, d);
        cquality.write(this.qualityRec, this.gameVm);
        this.sfxPlay("ui_move", 0.6);
    }

    // A QUALITY row (title, pause): left / right step the setting.
    qualityRow(): void {
        let inp = this.inp;
        if (input.pressed(inp, "left")) {
            this.qualityStep(-1);
        } else if (input.pressed(inp, "right")) {
            this.qualityStep(1);
        }
    }

    // The HOW TO FLY card (titlePanel 1): left / right mode, up / down the
    // footer (cardIndex 0 FLIGHT SCHOOL, 1 BACK), confirm acts, back closes.
    // Returns 0 FLIGHT SCHOOL, 1 close, -1 nothing.
    cardStep(): f64 {
        let inp = this.inp, g = this.gameVm;
        if (g != null) {
            // the UI may move the focus on hover
            let live = vmx.readNumLive(g, "cardIndex");
            if (!isNaN(live) && (live == 0 || live == 1)) {
                this.cardIndex = live;
            }
        }
        this.controlsRow();
        let d = input.nav(inp);
        if (d != 0) {
            this.cardIndex = mod(this.cardIndex + d, 2);
            this.sfxPlay("ui_move", 0.6);
        }
        if (g != null) {
            vmx.num(g, "cardIndex", this.cardIndex);
        }
        let act = -1.0;
        if (input.pressed(inp, "confirm") || (g != null && vmx.takeBool(g, "menuPressed"))) {
            act = this.cardIndex;
        }
        if (g != null && vmx.optTakeBool(g, "trainPressed")) {
            act = 0;
        }
        if (input.pressed(inp, "back") || (g != null && vmx.optTakeBool(g, "backPressed"))) {
            act = 1;
        }
        return act;
    }

    // school: the countdown fires from the flight school lane (the pilot waits
    // at level.school.s); false = the bay launch.
    startLaunch(school: bool): void {
        this.setState("launch");
        let p = this.player;
        p.frozen = true;
        p.speed = 0;
        p.controls = true;
        camera.setMode(this.rig, "launch");
        let h = this.hudVm;
        if (h != null) {
            vmx.fire(h, "boot");
        }
        this.countdown = 3;
        let g = this.gameVm;
        if (g != null) {
            vmx.num(g, "countdown", 3);
        }
        this.setMusic("music_level");
        this.schoolArmed = false;
        if (g != null) {
            vmx.optSetBool(g, "trainArmed", false);
        }
        if (school) {
            // holdSpeed(45): cruise 45, boost 70, brake 28
            p.speedCap = SCHOOL_CRUISE;
            let S = this.school;
            training.begin(S, this.schoolEnv(), 1);
            training.launch(S);
        }
    }

    // The checkpoint goes (a run from the launch pad, the title).
    cpClear(): void {
        this.memo.cp = null;
        this.memo.retryCp = false;
        let g = this.gameVm;
        if (g != null) {
            vmx.optSetStr(g, "cpLabel", "");
        }
    }

    goToTitle(): void {
        this.cpClear();
        this.memo.retried = false;
        this.resetRun();
        this.setState("title");
        camera.setMode(this.rig, "title");
        this.titlePanel = 0;
        this.setMusic("music_title");
    }

    // Who trains (training.md 3.6): restart(false) arms the school when FLIGHT
    // SCHOOL was chosen, debugTraining is on, or on a first START of the session
    // (not trained, no autopilot, no debugNoTraining). restart(true) (RESTART,
    // RETRY) never arms. Armed, the briefing waits out at sea.
    restart(skipBriefing: bool): void {
        this.cpClear();
        // a retry (RESTART, RETRY from the pad) skips the opening lines heard;
        // START from the title is a new mission
        this.memo.retried = skipBriefing;
        if (!skipBriefing) {
            this.memo.heard.clear();
        }
        if (skipBriefing) {
            this.resetRun();
            this.startLaunch(false);
            camera.snapLaunch(this.rig, this.player);
        } else {
            let g = this.gameVm;
            let dbgOn = g != null && vmx.optBool(g, "debugTraining");
            let dbgOff = g != null && vmx.optBool(g, "debugNoTraining");
            let armed = this.schoolRequested || dbgOn || (!training.trained() && !this.autopilotOn && !dbgOff);
            this.schoolRequested = false;
            this.resetRun(armed ? level.school.s : NaN);
            this.schoolArmed = armed;
            if (g != null) {
                vmx.optSetBool(g, "trainArmed", armed);
            }
            this.setState("briefing");
            camera.setMode(this.rig, "briefing");
        }
    }

    // Pause row 1: RESTART; SKIP TRAINING while the school runs (resume + skip,
    // queued to GO + 0.45 s from the countdown). Once its certificate is up the
    // school is over: the row reads RESTART (screens) and restarts (QA FS-2: in
    // the certificate's first 0.35 s it offered SKIP TRAINING, which only resumed).
    pauseRow1(): void {
        let S = this.school;
        if (S.active && S.carded) {
            training.markTrained();
            this.restart(true);
            return;
        }
        if (S.active) {
            let back = this.pausedFrom;
            this.setState(back);
            this.stateT = this.pausedT;
            input.releaseAll(this.inp);
            training.skipNow(S, this.schoolEnv());
            return;
        }
        this.restart(true);
    }

    // RETRY from the last checkpoint (QA PT1-6): the run as it stood there
    // (score, chain, rings, kills, objectives, bombs, cards played), a full
    // shield (QA PT2-6), then a short countdown (0.7 s a beat) over the held
    // course, under its own plates (CHECKPOINT / FROM <cpLabel>, screens), and
    // he flies on. Every retry caps the rank at A (scoring).

    // The lane at s with the longest clear run ahead (a stack can stand on the rail).
    cpLane(s: f64): f64 {
        const LANES: StaticArray<f64> = [0, -6, 6, -12, 12];
        let best = 0.0, bestRun = -1.0;
        for (let li = 0; li < LANES.length; li++) {
            let x = LANES[li];
            let run = 0.0;
            for (let k = 0; k <= 8; k++) {
                let P = level.world(s + <f64>k * 10, x, 6);
                if (scenery.collide(this.chunks, P.x, P.y, P.z, 2.5)) {
                    break;
                }
                run += 1;
            }
            if (run > bestRun) {
                best = x;
                bestRun = run;
            }
            if (run == 9) {
                break;
            }
        }
        return best;
    }

    cpRestore(): void {
        let cp = this.memo.cp;
        if (cp == null) {
            return;
        }
        this.resetRun(cp.s);
        let p = this.player;
        p.s = cp.s;
        p.x = this.cpLane(cp.s);
        p.y = 6;
        p.speed = 0;
        p.frozen = true;
        p.controls = true;
        // (a full shield: the retry puts him back before the stretch that
        // downed him, QA PT2-6; r1's 0.75 floor left G2 at 0.01 in it again)
        p.shield = 1;
        p.boost = cp.boost;
        playerMod.place(p);
        let st = this.stats;
        st.kills = cp.kills;
        st.killsTotal = cp.killsTotal;
        st.shotsFired = cp.shotsFired;
        st.shotsHit = cp.shotsHit;
        scoring.restore(this.sc, cp.sc, st);
        this.archDone = cp.archDone;
        let ks = cp.stings.keys();
        for (let k = 0; k < ks.length; k++) this.stingPlayed.set(ks[k], cp.stings.get(ks[k]));
        let kd = cp.down.keys();
        for (let k = 0; k < kd.length; k++) this.stingDown.set(kd[k], cp.down.get(kd[k]));
        this.bombs = cp.bombs;
        this.syncBombs();
        let violet = p.s > level.portalS;
        if (violet) {
            this.portalT = 5;
            this.pal = palette.violet;
        }
        this.setState("relaunch");
        // landscape: the launch's shot B, him right of the numerals (the side
        // GO keeps him; the chase put him behind them, r2), cut in whole (its
        // LAUNCH_CUT 2.0); portrait: the chase (he sits under the band)
        let rig = this.rig;
        if (rig.aspect >= 1) {
            camera.snapLaunch(rig, p);
            rig.modeT = 1.999;
        } else {
            camera.snapChase(rig, p);
        }
        this.trailPos = p.pos;
        this.countdown = 3;
        let g = this.gameVm;
        if (g != null) {
            vmx.num(g, "countdown", 3);
            vmx.num(g, "score", this.sc.score);
        }
        // (no HUD boot: it runs 4 s, GO at 3, so after the 2.1 s count the
        // boost read ~0% and the labels were still scrambling at GO, r2; the
        // visor stays down under the count, postFx, and the booted panels come
        // back with it at GO)
        this.setMusic(violet ? "music_violet" : "music_level");
    }

    // Where the hero, the wingmen and the boss are on screen, and what the
    // popups keep clear of.
    screenWrites(h: Bag, g: Bag?, p: playerMod.Player): void {
        // where the hero and the wingmen are on screen (0..1, y down; -1 when
        // not shown), so the HUD can fade a panel they fly behind. Projected
        // from this frame's camera rig (exact headless too).
        let shown = this.hudOn() && p.alive;
        let u = camera.project(this.rig, p.pos);
        let v = camera.PROJECT_2, w = camera.PROJECT_3;
        let ok = shown && w > 0;
        let pu = ok ? Math.floor(u * 100 + 0.5) / 100 : -1;
        let pv0 = ok ? Math.floor(v * 100 + 0.5) / 100 : -1;
        vmx.optSetNum(h, "pilotU", pu);
        vmx.optSetNum(h, "pilotV", pv0);
        if (g != null) {
            // the same for Main's overlays (countdown numerals can dodge him)
            vmx.optSetNum(g, "heroU", pu);
            vmx.optSetNum(g, "heroV", pv0);
        }
        // (only a wingman the player can see: on screen, not a speck, not
        // behind rock; QA M10: after a peel into the canyon walls the route
        // tab and score stayed faded with only rock behind them)
        this.wingSeenN += 1;
        let wl = this.wing.list;
        let seen = this.wingSeen;
        while (seen.length < wl.length) seen.push(-1);
        for (let i = 1; i < wl.length; i++) {
            let wg = wl[i];
            let wu = -1.0, wv = -1.0;
            if (shown && wg.phase != "away") {
                let a = camera.project(this.rig, wg.pos);
                let b = camera.PROJECT_2, cw = camera.PROJECT_3;
                if (cw > 0 && cw < WING_SEEN_FAR && a > -0.05 && a < 1.05 && b > -0.05 && b < 1.05) {
                    if (mod(this.wingSeenN + <f64>i, 4) == 0 || seen[i] < 0) {
                        seen[i] = this.sightBlocked(this.rig.cam.eye, wg.pos) ? 0 : 1;
                    }
                    if (seen[i] == 1) {
                        wu = Math.floor(a * 100 + 0.5) / 100;
                        wv = Math.floor(b * 100 + 0.5) / 100;
                    }
                }
            }
            vmx.optSetNum(h, "wing" + i.toString() + "U", wu);
            vmx.optSetNum(h, "wing" + i.toString() + "V", wv);
        }
        // the touch overlay is up (touch mode, either orientation): the HUD
        // keeps its gauges and score clear of it
        let touchMode = this.controlMode == "touch";
        vmx.optSetBool(h, "touchUi", touchMode);
        // the attract reel's print lower third owns the bottom of the
        // screen: the HUD tucks its gauge band under it (QA M6)
        vmx.optSetBool(h, "attract", this.reel > 0);
        // the window size in points: the HUD's type floors scale from it
        if (g != null) {
            vmx.optSetNum(h, "viewW", opt(vmx.optNum(g, "viewW"), 0));
            vmx.optSetNum(h, "viewH", opt(vmx.optNum(g, "viewH"), 0));
        }
        // what the world popups keep clear of: the gauges' touch layout, the
        // alert slot (fight place, or showing), the route list while it is
        // unfolded, the hero (and below, the boss weak point; the hero safe
        // zone is popups' own)
        let PL = this.pops.layout;
        PL.touch = touchMode;
        PL.school = this.school.active;
        PL.fight = this.bossActive || this.bossDying || opt(vmx.optNum(h, "fightK"), 0) > 0.5;
        PL.alert = this.alertT > 0;
        PL.route = opt(vmx.optNum(h, "routeK"), 0);
        // the HUD's portrait yield and legibility growth (its panels move)
        PL.yieldK = opt(vmx.optNum(h, "alertK"), 0);
        PL.bannerK = opt(vmx.optNum(h, "bannerK"), 1);
        PL.fightK = opt(vmx.optNum(h, "fightK"), 0);
        PL.hudPx = opt(vmx.optNum(h, "hudPx"), 1);
        PL.legScoreDy = opt(vmx.optNum(h, "legScoreDy"), 0);
        PL.legBoxH = opt(vmx.optNum(h, "legBoxH"), 190);
        PL.legBoxW = opt(vmx.optNum(h, "legBoxW"), 452);
        PL.legRoute = opt(vmx.optNum(h, "legRoute"), 1);
        PL.commCols = opt(vmx.optNum(h, "commCols"), 0);
        PL.chainK = opt(vmx.optNum(h, "combo"), 0) >= 2 ? opt(vmx.optNum(h, "commK"), 0) : 0;
        // the hero's box (1.7 m around him: the painted figure, helmet to
        // boots and fist to fist, in every pose)
        PL.heroU = -1;
        if (ok) {
            let ext = 1.7 / (w * Math.tan(this.rig.cam.fov * 0.5)) * 0.5;
            PL.heroU = u;
            PL.heroV = v;
            PL.heroHu = ext / this.rig.aspect;
            PL.heroHv = ext;
        }
        // the boss weak point on screen (the boss stack dodges it); -1 when
        // none is exposed or it is off screen
        let bu = -1.0, bv = -1.0;
        let E = this.enemies;
        if (shown && E != null && E.boss != null) {
            let a = hud.bossPoint(E, new GameProjector(this.rig), this.bossPick);
            let b = hud.BOSS_POINT_2;
            let pick = hud.BOSS_POINT_3;
            this.bossPick = pick;
            if (pick != null) {
                bu = Math.floor(a * 100 + 0.5) / 100;
                bv = Math.floor(b * 100 + 0.5) / 100;
            }
        } else {
            this.bossPick = null;
        }
        vmx.optSetNum(h, "bossU", bu);
        vmx.optSetNum(h, "bossV", bv);
        // the popups keep off the weak point too, and off her whole hull
        // while she is revealed (a RING x6 chip sat on her bow)
        PL.bossU = bu;
        PL.bossV = bv;
        if (shown) {
            this.bossHullRect();
        } else {
            this.hullNone();
        }
        PL.hullU0 = this.hrU0;
        PL.hullV0 = this.hrV0;
        PL.hullU1 = this.hrU1;
        PL.hullV1 = this.hrV1;
        if (LOG_CAM && this.state == "playing" && (this.rig.focusW > 0.01 || this.bossDying || this.stingLive())) {
            this.logCam(bu, bv);
        }
    }

    // Renderer params: visor boot, post fx.
    postFx(r: R.Gfx, p: playerMod.Player, dt: f64, rdt: f64): void {
        let v = r.visor;
        // (down: the visor goes at the splash, VI's cry typed out first; a
        // checkpoint count: it comes back with GO, see cpRestore)
        let count = this.state == "relaunch" || (this.state == "paused" && this.pausedFrom == "relaunch") || this.memo.goT > 0;
        if (this.memo.goT > 0) {
            // (paused under it: the pause card has the visor up)
            this.memo.goT = this.state == "paused" ? 0 : lmax(0, this.memo.goT - dt);
        }
        let on = this.hudOn() && !(this.state == "dying" && ((this.splashed && !this.commOn) || this.stateT > 1.2)) && !count;
        if (this.state == "dying" && !this.splashed) {
            v.glitch = lmax(v.glitch, 0.35 + 0.4 * lrandom());
        }
        let menu = this.state == "title" || this.state == "briefing" || this.state == "results" || this.state == "gameover" || this.state == "retry";
        if (on) {
            let bootT = this.state == "launch" ? this.stateT / 1.4 : 1;
            v.boot = mathx.saturate(bootT);
            v.opacity = mathx.damp(v.opacity, 1, 6, dt);
        } else if (menu) {
            // menus are print, never flight instruments
            v.opacity = 0;
            v.boot = 0;
        } else if (this.state == "outro" && this.entered) {
            // into the Eye: gone under the card (real time: bullet time
            // holds), and nothing left once it has rolled off
            v.opacity = this.sting == "" ? 0 : mathx.damp(v.opacity, 0, 10, rdt);
            if (v.opacity < 0.02) {
                v.boot = 0;
            }
        } else {
            v.opacity = mathx.damp(v.opacity, 0, 5, dt);
            if (v.opacity < 0.02) {
                v.boot = 0;
            }
        }
        // narrow screens: the same sway angle moves the HUD much further in
        // screen space, so scale it down in portrait to keep the edges on screen
        let swayAsp = this.size.y > 0 ? mathx.clamp(<f64>this.size.x / <f64>this.size.y, 0.3, 1) : 1;
        v.yaw = this.rig.visorYaw * swayAsp * Math.sqrt(swayAsp);
        v.pitch = this.rig.visorPitch;
        v.roll = -p.bank * 0.04;
        v.push = mathx.damp(v.push, p.boosting ? 0.02 : 0, 6, dt);
        v.glitch = lmax(0, v.glitch - dt * 2.5);
        let pp = r.post;
        let fast = flying(this.state) || this.state == "launch" || this.state == "outro";
        let lines = 0.0;
        if (fast) {
            lines = lmax(lmax(p.boostKick, p.boosting ? 0.85 : 0), mathx.saturate((p.speed - 70) / 30));
            if (this.portalT >= 0 && this.portalT < 1.5) {
                lines = lmax(lines, 1 - this.portalT / 1.5);
            }
        }
        pp.speedLines = mathx.damp(pp.speedLines, lines, 6, dt);
        let fu = camera.project(this.rig, p.pos + p.fwd * <f32>200);
        let fv = camera.PROJECT_2, fw = camera.PROJECT_3;
        if (fw > 0) {
            pp.focusX = mathx.damp(pp.focusX, mathx.clamp(fu, 0.2, 0.8), 6, dt);
            pp.focusY = mathx.damp(pp.focusY, mathx.clamp(fv, 0.2, 0.8), 6, dt);
        }
        pp.chroma = 0.35 + pp.speedLines * 1.4 + v.glitch * 1.5;
        let cine = this.state == "title" || this.state == "briefing" || this.state == "results" || this.state == "gameover" || this.state == "retry";
        // cinematic bars only where there is width to spare
        let wideK = mathx.saturate((this.rig.aspect - 0.9) / 0.5);
        pp.letterbox = mathx.damp(pp.letterbox, cine ? wideK : 0, 3, dt);
        pp.vignette = this.state == "paused" ? 0.9 : 0.35 + pp.speedLines * 0.15;
        pp.damage = lmax(0, pp.damage - dt * 2);
        // bullet-time grade while a sting holds (cobalt / cream duotone,
        // halftone vignette; the hero safe zone stays clean)
        let slowT = this.sting == "" || this.sting == "training_complete" ? 0.0 : this.sting.startsWith("down_") ? 0.8 : 1.0;
        pp.slow = mathx.damp(pp.slow, slowT, 8, rdt);
        pp.flash = lmax(0, pp.flash - dt * 2.4);
        if (this.state != "playing" && this.state != "outro") {
            pp.portal = mathx.damp(pp.portal, 0, 3, dt);
        }
        r.boost = p.boosting ? 1 : p.boostKick;
        // game over: desaturate and dim
        let gray = this.state == "gameover" || this.state == "dying" ? 0.55 : this.state == "paused" ? 0.35 : 0;
        pp.fade = mathx.damp(pp.fade, gray * 0.5, 2, dt);
        if (this.state == "title") {
            pp.fade = lmax(pp.fade, this.rig.cut);
        }
        pp.fadeR = 0.02;
        pp.fadeG = 0.03;
        pp.fadeB = 0.07;
        if (LOG_STATS && Math.floor(this.t) != Math.floor(this.t - dt)) {
            console.log(R.statsText(r));
        }
        let pal = this.pal;
        pp.saturation = pal.saturation * (1 - gray * 0.6);
        pp.contrast = pal.contrast;
        pp.warmth = pal.warmth;
        pp.exposure = pal.exposure;
    }

    // The checkpoint countdown (state relaunch): 3-2-1 0.7 s each, then GO.
    relaunchUpdate(dt: f64): void {
        let p = this.player, g = this.gameVm, inp = this.inp, rig = this.rig;
        // (rock at or before the launch shot's lens: the chase instead)
        let E = rig.eye;
        if (rig.mode == "launch" && (scenery.collide(this.chunks, E.x, E.y, E.z, 1) || this.sightBlocked(E, p.pos))) {
            camera.snapChase(rig, p);
        }
        playerMod.clearControls(this.ctrl);
        playerMod.update(p, this.ctrl, dt, this.chunks);
        let cd = lmax(0, 3 - Math.floor(this.stateT / 0.7));
        if (cd != this.countdown) {
            this.countdown = cd;
            if (g != null) {
                vmx.num(g, "countdown", cd);
            }
        }
        if (input.pressed(inp, "pause")) {
            this.pausedFrom = "relaunch";
            this.pausedT = this.stateT;
            this.setState("paused");
            input.releaseAll(inp);
        } else if (cd == 0) {
            // GO: he flies on from the checkpoint (the visor stays down while
            // the count's plates and GO! clear: they sat on the objective strip,
            // in portrait the GO! ring on the timer, QA PT2-6)
            this.memo.goT = pages.GO_HOLD;
            this.setState("playing");
            p.frozen = false;
            p.speed = playerMod.CRUISE * 0.7;
            p.boostKick = 1;
            if (rig.mode == "launch") {
                camera.go(rig, p);
            }
            rig.fovKick = rad(7);
            camera.addShake(rig, 0.6);
            this.sfxPlay("boost_start", 1);
            // (the odometer's eased columns hung on the retry's drop under the
            // down visor, 009 for 0 until the next points, r3: a fresh target
            // as the panels come back, the exact score next frame)
            let h = this.hudVm;
            if (h != null) {
                vmx.num(h, "score", this.sc.score + 0.5);
            }
        }
    }

    // Results / game over rows. Game over: 0 RETRY (from the last checkpoint,
    // else the launch pad), 1 RESTART MISSION (the pad), 2 TITLE; results: 0
    // RETRY (the pad), 1 TITLE. The world resets once the roller covers the
    // report (state retry).
    reportAct(act: f64, back: bool): void {
        let st = this.state;
        let over = st == "gameover";
        if (act == 0 || (over && act == 1)) {
            this.memo.retryCp = over && act == 0 && this.memo.cp != null;
            let g0 = this.gameVm;
            if (g0 != null && !this.memo.retryCp) {
                // (the count from the pad reads LAUNCH SEQUENCE from its first
                // frame: cpLabel switches it to its checkpoint plates)
                vmx.optSetStr(g0, "cpLabel", "");
            }
            this.setState("retry");
            this.countdown = 3;
            let g = this.gameVm;
            if (g != null) {
                vmx.num(g, "countdown", 3);
            }
        } else if (act == menuCount(st) - 1 || back) {
            this.goToTitle();
        }
    }

    retryGo(): void {
        if (this.memo.retryCp && this.memo.cp != null) {
            this.memo.retried = true;
            this.cpRestore();
        } else {
            this.restart(true);
        }
    }

    endRun(completed: bool): void {
        scoring.finish(this.sc, this.player, this.stats, completed, this.ctx2);
        let g = this.gameVm;
        if (g != null) {
            hud.syncResults(g, this.sc, this.stats, this.player);
        }
    }

    // The downed pilot (state dying): tumble trailing smoke, splash into the
    // sea, then game over.
    dyingStep(p: playerMod.Player, dt: f64): void {
        if (!this.splashed) {
            let hitWater = playerMod.updateDead(p, dt, this.chunks);
            let nearRock = scenery.collide(this.chunks, p.pos.x, p.pos.y, p.pos.z, playerMod.RADIUS + playerMod.GRAZE);
            this.heroPull = mathx.damp(this.heroPull, nearRock ? 1 : 0, nearRock ? 20 : 4, dt);
            p.thrust = 0;
            // soft smoke, no blast rings (QA M8: a fireball in a flash ring
            // every 0.07 s read as beads on a skewer, then even cobalt puffs
            // as a string of beads): pale grey-lavender puffs of mixed sizes
            // at an uneven beat, drifting up and apart, part-eroded (alpha
            // < 1 wears the cel shape into wisps), swelling so the column
            // merges into one plume over the wide ribbon; now and then a
            // small lick of fire at the pack
            this.puffT -= dt;
            if (this.puffT <= 0) {
                this.puffT = 0.06 + lrandom() * 0.1;
                let k = mathx.saturate(this.stateT / 1.2);
                // (never thinned by the quality tier: ~10 puffs / s, and a
                // gap in the column reads as beads again)
                let F = this.fx;
                let dens = F.density;
                F.density = 1;
                let np = lrandom() < 0.35 ? 2 : 1;
                for (let i = 1; i <= np; i++) {
                    let big = lrandom();
                    let sz = (0.5 + 1.3 * big * big) * (0.8 + 0.5 * k);
                    let jx = (lrandom() - 0.5) * 1.8;
                    let jy = (lrandom() - 0.5) * 1.8;
                    let jz = (lrandom() - 0.5) * 1.8;
                    // grey (spread < 0.12: the shader's soft 2.1x swell), never
                    // all channels over 0.85 (that shades as foam)
                    let tone = 0.58 + lrandom() * 0.14;
                    let tone2 = lmin(0.8, tone + 0.12);
                    // (arguments in Luau's order: left to right)
                    let vx = (lrandom() - 0.5) * 2.4;
                    let vy = 1.2 + lrandom() * 1.8;
                    let vz = (lrandom() - 0.5) * 2.4;
                    let sz1 = sz * (1.1 + lrandom() * 0.8);
                    let ca = 0.55 + lrandom() * 0.4;
                    let life = 1.1 + lrandom() * 0.9;
                    fx.emit(this.fx, 0, <f64>p.pos.x + jx, <f64>p.pos.y + jy, <f64>p.pos.z + jz,
                        vx, vy, vz,
                        sz, sz1, 0.7,
                        tone * 0.97, tone * 0.95, tone * 1.07, ca,
                        tone2 * 0.98, tone2 * 0.97, tone2 * 1.05,
                        life, 0, 1.2, -0.6, 0);
                }
                if (lrandom() < 0.3) {
                    let jx = (lrandom() - 0.5) * 0.6;
                    let jy = (lrandom() - 0.5) * 0.6;
                    let jz = (lrandom() - 0.5) * 0.6;
                    fx.fire(this.fx, <f64>p.pos.x + jx, <f64>p.pos.y + jy, <f64>p.pos.z + jz, 0.45 - 0.2 * k);
                }
                F.density = dens;
            }
            let sm = this.smoke;
            if (sm != null) {
                R.trailPush(sm, p.pos.x, p.pos.y, p.pos.z, this.t, 3.2 + this.stateT * 2.4);
            }
            if (hitWater) {
                this.splashed = true;
                this.stateT = 0;
                fx.explosion(this.fx, p.pos.x, 0.3, p.pos.z, 1.2, "water");
                for (let i = 1; i <= 40; i++) {
                    let ox = (lrandom() - 0.5) * 4;
                    let oz = (lrandom() - 0.5) * 4;
                    fx.spray(this.fx, <f64>p.pos.x + ox, 0, <f64>p.pos.z + oz, 1);
                }
                // a short white burst over the crown (a camera-facing ring at the waterline was cut in half by the
                // water and read as a horseshoe over the crown, QA FAIL-N2)
                weapons.flare(this.weapons, p.pos.x, 1.6, p.pos.z, 2.5, 9, 0.35, 0.95, 1, 1, 1);
                this.sfxPlay("splash", 1);
                this.sfxPlay("explode_small", 0.8);
                camera.addShake(this.rig, 0.8);
            }
        }
        weapons.update(this.weapons, p, false, dt, this.ctx2!, this.enemies, this.fx);
        // (the splash crown and spray have settled by ~0.9 s: no long hold
        // on empty water)
        if ((this.splashed && this.stateT > 0.95) || this.stateT > 4) {
            this.endRun(false);
            this.setState("gameover");
            camera.setMode(this.rig, "results");
            this.setMusic("");
        }
    }

    // The death cam keeps enemies and wrecks off its sight line and lens, and
    // anything moving that still comes near the lens fades out.
    nearFade(p: playerMod.Player): void {
        let rig = this.rig;
        let n = 0;
        let E = this.enemies;
        if (this.state == "dying" && E != null) {
            let nr = rig.near;
            let list = E.list;
            for (let i = 1; i < list.length; i++) {
                let e = list[i];
                if (!e.dead && !e.hidden) {
                    let dx = e.x - <f64>p.pos.x, dy = e.y - <f64>p.pos.y, dz = e.z - <f64>p.pos.z;
                    if (dx * dx + dy * dy + dz * dz < 90 * 90) {
                        let o = n * 4;
                        while (nr.length < o + 5) nr.push(0);
                        nr[o + 1] = e.x;
                        nr[o + 2] = e.y;
                        nr[o + 3] = e.z;
                        nr[o + 4] = e.radius * 1.5 + 1;
                        n += 1;
                    }
                }
            }
        }
        rig.nearN = n;
        let rv = this.r;
        if (rv != null) {
            rv.nearFade = this.state == "dying" ? 8 : 0;
        }
    }

    bootDone(): bool {
        return this.state != "launch" || this.stateT > 1.0;
    }

    // Fly from rail distance s at once (debug starts, attract reel clips, the
    // school cut; s < 0 flies the lane out at sea).
    startAt(s: f64, boot: bool, keepSting: bool = false): void {
        this.resetRun(s, keepSting);
        let p = this.player;
        p.s = s;
        p.y = 6;
        scoring.startAt(this.sc, p.s);
        p.frozen = false;
        p.speed = playerMod.CRUISE;
        playerMod.place(p);
        this.countdown = 0;
        let g = this.gameVm;
        if (g != null) {
            vmx.num(g, "countdown", 0);
        }
        this.setState("playing");
        camera.snapChase(this.rig, p);
        if (p.s > level.portalS) {
            this.portalT = 5;
            this.pal = palette.violet;
        }
        let h = this.hudVm;
        if (h != null && boot) {
            vmx.fire(h, "boot");
        }
        this.setMusic(p.s > level.portalS ? "music_violet" : "music_level");
    }

    // The Main card has the certificate (StingKind training_complete).
    cardUi(): bool {
        if (this.cardKind < 0) {
            this.cardKind = 0;
            let g = this.gameVm;
            let e = g != null && this.stingUi() ? g.vm.getEnum("sting") : null;
            if (e != null) {
                let vals = e.values();
                for (let i = 0; i < vals.length; i++) {
                    let v = Pattern.gsub(vals[i], " ", "_").text.toLowerCase();
                    if (v == "training_complete") {
                        this.cardKind = 1;
                    }
                }
            }
        }
        return this.cardKind == 1;
    }

    // The certificate (training.md 3.5 step 1): the pilot freezes, practice goes.
    schoolCard(title: string, sub: string): void {
        this.stingFire("training_complete", title, sub);
        let p = this.player;
        p.frozen = true;
        p.controls = false;
        let E = this.enemies, c = this.ctx2;
        if (E != null && c != null) {
            enemies.clearPractice(E, c, false);
        }
        let r = this.r;
        if (r != null && !this.cardUi()) {
            // no card: a white flash + visor glitch cover the cut
            r.post.flash = 1;
            r.post.flashR = 1;
            r.post.flashG = 0.98;
            r.post.flashB = 0.94;
            r.visor.glitch = 1;
        }
    }

    // THE CUT (training.md 3.5 step 2), under the opaque card: a fresh run in the
    // bay channel at s -340; only the live sting rides through.
    schoolCut(): void {
        training.markTrained();
        this.startAt(level.school.handoff, false, true);
        let p = this.player;
        p.x = 0;
        p.y = 7;
        p.speed = playerMod.CRUISE;
        playerMod.place(p);
        camera.snapChase(this.rig, p);
        p.controls = false;
        this.trailPos = p.pos;
        training.finish(this.school, this.schoolEnv());
        let r = this.r;
        if (r != null && !this.cardUi()) {
            r.post.flash = 1;
            r.post.flashR = 1;
            r.post.flashG = 0.98;
            r.post.flashB = 0.94;
            r.visor.glitch = 1;
        }
    }

    // debugSkipIntro + debugTraining: the school at once, flying at
    // level.school.s + 60 on drill debugTrainStep (no title, briefing, countdown).
    schoolDebug(step: f64): void {
        this.startAt(level.school.s + 60, true);
        let p = this.player;
        p.speedCap = SCHOOL_CRUISE;
        p.speed = SCHOOL_CRUISE;
        this.setState("training");
        let S = this.school;
        training.begin(S, this.schoolEnv(), lclamp(Math.floor(step), 1, <f64>(training.LESSONS.length - 1)));
        training.go(S);
    }

    // The director's view of the game (refreshed on every call).
    schoolEnv(): GameEnv {
        let env: GameEnv;
        let e0 = this.schoolEnvRec;
        if (e0 != null) {
            env = e0;
        } else {
            env = new GameEnv(this);
            this.schoolEnvRec = env;
        }
        let g = this.gameVm;
        env.p = this.player;
        env.W = this.weapons;
        env.E = this.enemies;
        env.c = this.ctx2;
        env.F = this.fx;
        env.pops = this.pops;
        env.inp = this.inp;
        env.g = g;
        env.h = this.hudVm;
        env.mode = this.controlMode;
        env.portrait = this.rig.aspect < 1;
        env.bot = this.autopilotOn && g != null && vmx.optBool(g, "debugTraining");
        env.state = this.state;
        env.rolled = this.rolledNow;
        env.deflects = this.sc.deflects;
        env.bombs = this.bombs;
        env.sting = this.sting;
        env.stingT = this.stingT;
        return env;
    }

    // Seconds before the attract reel cuts away; math.huge off it. (comms: a
    // line on the reel is said by the next cut or the kill card, else its
    // leading sentences, else nothing: every clip cut one off mid-word,
    // 'Welcom', QA sweep 2 HUD2-1)
    reelLeft(): f64 {
        if (this.reel < 1 || this.reel >= REEL.length) {
            return HUGE;
        }
        let clip = REEL[this.reel];
        let cut = clip.kind == "crow" && this.reelT < REEL_CROW_KILL ? REEL_CROW_KILL : clip.dur;
        return cut - this.reelT;
    }

    reelClip(i: i32): void {
        let clip = REEL[i];
        let g = this.gameVm;
        if (clip.kind == "launch") {
            this.resetRun();
            this.startLaunch(false);
            camera.snapLaunch(this.rig, this.player);
            // from the 2: the last beats of the countdown and the blast-off
            this.stateT = 1.02;
            this.rig.modeT = 1.02;
        } else {
            this.startAt(clip.s, i == 1);
            let p = this.player;
            if (clip.kind == "arch") {
                // lined up on the window: the autopilot threads it
                archWindow();
                p.x = (AW_X0 + AW_X1) * 0.5;
                p.y = lmin(AW_Y1 - 6, AW_Y0 + 7);
                playerMod.place(p);
                camera.snapChase(this.rig, p);
            }
        }
        this.reel = i;
        this.reelT = 0;
        if (g != null) {
            vmx.optSetBool(g, "attract", true);
        }
        // jump cut: one white frame
        let r = this.r;
        if (r != null) {
            r.post.flash = 0.55;
            r.post.flashR = 1;
            r.post.flashG = 0.97;
            r.post.flashB = 0.9;
        }
    }

    reelExit(): void {
        this.reel = 0;
        this.reelT = 0;
        this.idleT = 0;
        let g = this.gameVm;
        if (g != null) {
            vmx.optSetBool(g, "attract", false);
        }
        this.resetRun();
        this.setState("title");
        camera.setMode(this.rig, "title");
        this.titlePanel = 0;
        this.setMusic("music_title");
    }

    // Per-frame reel bookkeeping (real seconds): scripted beats, cuts, the end.
    reelUpdate(rdt: f64): void {
        if (this.reel < 1 || this.reel >= REEL.length) {
            this.reelExit();
            return;
        }
        let clip = REEL[this.reel];
        let t0 = this.reelT;
        this.reelT += rdt;
        let t = this.reelT;
        if (clip.kind == "crow" || clip.kind == "watcher") {
            // the fight cut short: the weak point goes after the reveal poster
            let killAt = clip.kind == "crow" ? REEL_CROW_KILL : 99;
            let E = this.enemies, c = this.ctx2;
            if (t0 < killAt && t >= killAt && E != null && c != null && this.sting == "") {
                let list = E.list;
                for (let i = 1; i < list.length; i++) {
                    let e = list[i];
                    if (e.part && e.alive && (e.kind == "crowCore" || e.kind == "eyeCore")) {
                        e.hidden = false;
                        e.armored = false;
                        e.minHp = 0;
                        enemies.damage(E, c, e, e.hp + 999);
                        break;
                    }
                }
            }
        }
        if (t >= clip.dur && this.sting == "") {
            if (this.reel < REEL.length - 1) {
                this.reelClip(this.reel + 1);
            } else {
                this.reelExit();
            }
        }
    }

    // The finale (state outro): the pilot lines up on the Eye and rockets in;
    // the wingmen follow him through, then the swirl swallows the view.
    outroStep(p: playerMod.Player, dt: f64): void {
        let inp = this.inp;
        p.controls = false;
        p.thrust = 1;
        p.boosting = true;
        p.speed = mathx.damp(p.speed, 118, 1.6, dt);
        p.s += p.speed * dt;
        let eyeG = level.eye;
        let k = mathx.saturate(this.stateT / 1.1);
        p.x = mathx.damp(p.x, eyeG.x, 1 + 3 * k, dt);
        p.y = mathx.damp(p.y, eyeG.y, 1 + 3 * k, dt);
        p.bank = mathx.damp(p.bank, 0, 3, dt);
        p.pitch = mathx.damp(p.pitch, 0.3, 3, dt);
        track.frame(level.track, lmin(p.s, level.track.length - 1));
        let tp = track.FRAME_P, f = track.FRAME_F, rt = track.FRAME_R, up = track.FRAME_U;
        let over = lmax(0, p.s - (level.track.length - 1));
        p.pos = Vector.xyz(<f32>(<f64>tp.x + <f64>rt.x * p.x + <f64>f.x * over), <f32>(<f64>tp.y + p.y + <f64>f.y * over), <f32>(<f64>tp.z + <f64>rt.z * p.x + <f64>f.z * over));
        p.fwd = f;
        p.right = rt;
        p.up = up;
        let ep = this.eyePos, ef = this.eyeFwd;
        // the gaze settles on the Eye, then (in) on down its axis: the eye
        // never looks back at it (QA CD-1)
        let gz = ep + ef * <f32>(OUTRO_LOOK * mathx.smoothstep(0, 0.9, this.entered ? this.enteredT : 0));
        camera.holdGaze(this.rig, gz.x, gz.y, gz.z, mathx.smoothstep(0.2, 1.6, this.stateT) * 0.85);
        wingmen.update(this.wing, p, this.t, dt, true);
        // anything still on the field keeps flying, firing and falling (no new
        // spawns: events stay off), and bolts / novas in flight land
        this.syncTypesPlayer();
        let oc = this.ctx2, oE = this.enemies;
        if (oc != null && oE != null) {
            oc.t = this.t;
            oc.dt = dt;
            oc.railS = p.s;
            enemies.update(oE, oc, dt);
        }
        weapons.update(this.weapons, p, false, dt, oc!, oE, this.fx);
        let r = this.r;
        if (!this.entered && p.s >= eyeG.s) {
            this.entered = true;
            this.enteredT = 0;
            this.sfxPlay("portal", 1);
            camera.addShake(this.rig, 0.9);
            this.rig.fovKick = rad(10);
            weapons.flare(this.weapons, p.pos.x, p.pos.y, p.pos.z, 4, 60, 0.8, 0.95, 0.8, 1, 2);
            weapons.flare(this.weapons, p.pos.x, p.pos.y, p.pos.z, 6, 20, 0.5, 1, 0.9, 1, 1);
            if (r != null) {
                r.post.flash = 0.55;
                r.post.flashR = 0.95;
                r.post.flashG = 0.85;
                r.post.flashB = 1;
                r.visor.glitch = 1;
            }
            // the last checkpoint ticks off under MISSION COMPLETE
            scoring.completeFinal(this.sc);
            this.stingFire("mission_complete", "MISSION COMPLETE", "MISSION 01  //  COASTAL RUN");
            let c = this.ctx2;
            if (c != null) {
                c.banner("MISSION COMPLETE", "MISSION 01  //  COASTAL RUN", "success");
            }
        }
        if (this.entered) {
            this.enteredT += dt;
            // the camera follows him in: the swirl rushes up, then white-out
            let et = this.enteredT;
            // the push eases to a stop OUTRO_STOP m short of the Eye's plane:
            // the white-out lands inside the swirl (it used to fly through,
            // turn round and show the portal from behind, QA CD-1)
            let gap = -OUTRO_STOP - mathx.dot(this.rig.eye - ep, ef);
            let v = lmin(mathx.lerp(12, 70, mathx.smoothstep(0.1, 1.5, et)), lmax(0, gap) * 5);
            this.rig.drift = ef * <f32>v;
            this.rig.fovKick = lmax(this.rig.fovKick, rad(14) * mathx.smoothstep(0.3, 1.8, et));
            if (r != null) {
                r.post.portal = lmin(mathx.smoothstep(0.3, 1.8, et) * 0.9, OUTRO_DIVE);
                let wht = mathx.smoothstep(OUTRO_WHITE0, OUTRO_WHITE1, et);
                if (wht > 0) {
                    r.post.flash = lmax(r.post.flash, wht);
                    r.post.flashR = 1;
                    r.post.flashG = 0.97;
                    r.post.flashB = 1;
                }
            }
        }
        // (Space is fire: only Enter / pad skip the outro, and not at once)
        if ((this.entered && this.enteredT > OUTRO_END) || (input.pressed(inp, "accept") && this.stateT > 2.5 && this.sting == "")) {
            if (this.reel > 0) {
                this.reelExit();
            } else {
                this.endRun(true);
                this.setState("results");
                camera.setMode(this.rig, "results");
                this.setMusic("music_title");
            }
        }
    }

    // core_print.feed's reads of the Game view model (vm.optNum: NaN = nil)
    printVals(): PrintVals? {
        let g = this.gameVm;
        if (g == null) return null;
        let v = this.pv;
        v.printRootK = vmx.optNum(g, "printRootK");
        v.printRedK = vmx.optNum(g, "printRedK");
        v.printBlueK = vmx.optNum(g, "printBlueK");
        v.printRollX = vmx.optNum(g, "printRollX");
        v.viewW = vmx.optNum(g, "viewW");
        v.viewH = vmx.optNum(g, "viewH");
        v.stingPrintK = vmx.optNum(g, "stingPrintK");
        v.stingCrimK = vmx.optNum(g, "stingCrimK");
        v.stingDenseK = vmx.optNum(g, "stingDenseK");
        v.stingBlueK = vmx.optNum(g, "stingBlueK");
        v.stingRollX = vmx.optNum(g, "stingRollX");
        v.stingPrintKP = vmx.optNum(g, "stingPrintKP");
        v.stingCrimKP = vmx.optNum(g, "stingCrimKP");
        v.stingDenseKP = vmx.optNum(g, "stingDenseKP");
        v.stingBlueKP = vmx.optNum(g, "stingBlueKP");
        v.stingRollXP = vmx.optNum(g, "stingRollXP");
        return v;
    }

    override advance(seconds: f64): bool {
        let t0 = clock();
        if (!this.loaded) {
            // (port) init's setup in steps (watchdog): as many as fit in
            // LOAD_MS this call. The advances it spans are replayed once it is
            // done (LOAD_MS of them a call), so the game's frames line up with
            // Luau's (init there).
            while (!this.loaded) {
                if (this.gameVm == null && this.ctx != null) this.bindGame();
                if (this.gameVm == null) return true; // (not bound yet)
                this.load();
                if (this.loaded) break;
                if ((clock() - t0) * 1000 > LOAD_MS) {
                    this.lateDt.push(seconds);
                    return true;
                }
            }
        }
        let late = this.lateDt;
        if (late.length > 0) {
            late.push(seconds);
            let k = 0;
            while (k < late.length && (k == 0 || (clock() - t0) * 1000 < LOAD_MS)) {
                this.tick(late[k]);
                k++;
            }
            late.splice(0, k);
            return true;
        }
        let more = this.tick(seconds);
        // (no draw since the last advance, headless runs: the bake the draw
        // tops up runs here, so a capture's single draw finds the chunks in
        // view baked; gameplay reads the same answers either way)
        if (!this.drew) scenery.pump(this.player.s, 6);
        this.drew = false;
        if (isDefined(PERF) && (clock() - t0) * 1000 > <f64>PERF) console.log(format("PERF advance %.1f ms st=%s s=%.0f", [FN((clock() - t0) * 1000), FS(this.state), FN(this.player.s)]));
        return more;
    }

    // Luau's advance.
    tick(seconds: f64): bool {
        // real seconds (UI, comms, audio) vs game seconds (bullet time in stings)
        let rdt = lmin(seconds, 1.0 / 20);
        if (isDefined(FRAMECLOCK)) frameClock.t += rdt;
        if (LOG_COMMS) {
            logF += 1;
            logT += rdt;
        }
        // paused: the sting hold, its bullet time and the camera beat wait for
        // the resume (the menus run in real time)
        let frozen = this.state == "paused";
        this.stingUpdate(frozen ? 0 : rdt);
        camera.beatTick(this.rig, frozen ? 0 : rdt);
        let dt = rdt * (frozen ? 1 : this.timeScale);
        this.dt = dt;
        this.t += dt;
        this.memo.rt += rdt;
        this.stateT += dt;
        let inp = this.inp;
        input.tick(inp, rdt);
        let g = this.gameVm;
        let st = this.state;
        let p = this.player;
        if (g != null && !seeded) {
            // QA: --data=debugSeed=<n> makes gameplay randomness repeatable (the
            // --data values land after init: seeded on the first advance)
            seeded = true;
            let seed = opt(vmx.optNum(g, "debugSeed"), 0);
            if (seed != 0) {
                lrandomseed(seed);
            }
        }
        if (g != null) {
            this.autopilotOn = vmx.readBool(g, "autopilot") || this.reel > 0;
            // touch controls (optional Game view model properties; see docs/notes/core.md)
            let tx = vmx.optNum(g, "touchX");
            if (!isNaN(tx)) {
                inp.tx = mathx.clamp(tx, -1, 1);
                inp.ty = mathx.clamp(opt(vmx.optNum(g, "touchY"), 0), -1, 1);
                input.touchButton(inp, "fire", vmx.optBool(g, "touchFire"));
                input.touchButton(inp, "boost", vmx.optBool(g, "touchBoost"));
                input.touchButton(inp, "brake", vmx.optBool(g, "touchBrake"));
                input.touchEdge(inp, "roll", vmx.optBool(g, "touchRoll"), inp.tx < -0.2 ? "rollL" : "rollR");
                input.touchButton(inp, "pause", vmx.optBool(g, "touchPause"));
                input.touchButton(inp, "bomb", vmx.optBool(g, "touchBomb"));
            }
            input.keysLost(inp, g, seconds);
        }
        // control mode: modePick, the provisional mode, controlMode + touchMode
        cmode.update(this.modeRec, g, rdt);
        this.controlMode = this.modeRec.mode;
        // graphics quality: qualityPick, the AUTO probe, quality + qualityNow, the tiers
        cquality.update(this.qualityRec, g, rdt, flying(this.state), this.r, this.fx, seconds);
        if (g != null) {
            if (vmx.optTakeBool(g, "musicToggle")) {
                inp.edge.add("muteMusic");
            }
            if (vmx.optTakeBool(g, "soundToggle")) {
                inp.edge.add("muteAll");
            }
        }
        // the attract reel: any key, pad button, tap or menu press returns to the title
        let tapped = this.pointerPoke;
        this.pointerPoke = false;
        if (this.reel > 0) {
            let poke = inp.anyKey || inp.tx != 0 || inp.ty != 0 || tapped;
            if (g != null) {
                // (taken, so the press does not also start the mission)
                let a = vmx.takeBool(g, "startPressed");
                let b = vmx.takeBool(g, "menuPressed");
                let c = vmx.optTakeBool(g, "backPressed");
                poke = poke || a || b || c || vmx.optBool(g, "touchFire") || vmx.optBool(g, "touchPause");
            }
            if (poke) {
                this.reelExit();
                input.releaseAll(inp);
                input.endFrame(inp);
                return true;
            }
            this.reelUpdate(rdt);
            st = this.state;
            p = this.player;
        }
        // M toggles music, N toggles every sound
        if (input.pressed(inp, "muteMusic") || input.pressed(inp, "muteAll")) {
            let sx0 = this.sfx;
            if (input.pressed(inp, "muteMusic")) {
                this.musicOn = !this.musicOn;
            } else {
                this.soundOn = !this.soundOn;
            }
            if (sx0 != null) {
                sfx.setVolume(sx0, "music", this.musicOn ? 0.62 : 0);
                sfx.setVolume(sx0, null, this.soundOn ? 1 : 0);
            }
            if (g != null) {
                vmx.optSetBool(g, "musicOn", this.musicOn);
                vmx.optSetBool(g, "soundOn", this.soundOn);
            }
        }

        // hit-stop: a couple of frozen frames on heavy hits
        let simDt = dt;
        if (this.hitStop > 0) {
            this.hitStop -= dt;
            simDt = dt * 0.15;
        }

        if (st == "title" && g != null && vmx.readBool(g, "debugSkipIntro")) {
            // debug: --data=debugSkipIntro=true --data=debugStart=<meters>
            cmode.lock(this.modeRec);
            this.controlMode = this.modeRec.mode;
            cmode.write(this.modeRec, this.gameVm);
            if (vmx.optBool(g, "debugTraining")) {
                this.schoolDebug(opt(vmx.optNum(g, "debugTrainStep"), 1));
            } else {
                this.startAt(opt(vmx.readNum(g, "debugStart"), 0), true);
            }
            vmx.bool(g, "debugSkipIntro", false);
            st = this.state;
            p = this.player;
        } else if (st == "title" && g != null && opt(vmx.readNum(g, "debugStart"), 0) < 0) {
            // debug: --data=debugStart=-<clip> runs the attract reel from that clip
            let i = <i32>lclamp(Math.floor(-opt(vmx.readNum(g, "debugStart"), 0)), 1, <f64>(REEL.length - 1));
            vmx.num(g, "debugStart", 0);
            this.reelClip(i);
            st = this.state;
            p = this.player;
        }

        if (st == "title") {
            // attract: the pilot cruises out of the bay, weaving low over the
            // water; the loop restarts under the camera's dip to black
            playerMod.clearControls(this.ctrl);
            playerMod.update(p, this.ctrl, dt, this.chunks);
            let ct = mod(this.rig.modeT, 27);
            let wx = Math.sin(this.t * 0.33) * 5 + Math.sin(this.t * 0.71) * 1.5;
            let vx = Math.cos(this.t * 0.33) * 0.33 * 5 + Math.cos(this.t * 0.71) * 0.71 * 1.5;
            p.s = 20 + ct * 30;
            p.x = wx;
            p.vx = vx;
            p.y = 2.6 + Math.sin(this.t * 0.52) * 0.5;
            p.speed = 30;
            p.bank = mathx.damp(p.bank, -vx * 0.12, 4, dt);
            p.thrust = 0.6;
            playerMod.place(p);
            // bake the course in the background, independent of draw
            scenery.pump(p.s, 3);
            if (this.stateT < 0.1) {
                this.setMusic("music_title");
            }
            // rows: 0 START MISSION, 1 HOW TO FLY, 2 CONTROLS, 3 QUALITY, 4 CREDITS
            let card = -1.0;
            let act = -1.0;
            if (this.titlePanel == 1) {
                card = this.cardStep();
            } else {
                act = this.menuStep();
            }
            if (g != null && vmx.takeBool(g, "startPressed")) {
                act = 0;
                this.titlePanel = 0;
            }
            // QA: the autopilot starts the mission on its own
            if (this.autopilotOn && this.stateT > 2.5 && this.titlePanel == 0) {
                act = 0;
            }
            if (this.titlePanel == 1) {
                if (card == 0) {
                    // FLIGHT SCHOOL: the START MISSION path, asking for the school
                    this.titlePanel = 0;
                    this.schoolRequested = true;
                    cmode.lock(this.modeRec);
                    this.controlMode = this.modeRec.mode;
                    cmode.write(this.modeRec, this.gameVm);
                    this.sfxPlay("ui_select", 0.8);
                    this.restart(false);
                } else if (card == 1) {
                    this.titlePanel = 0;
                    this.sfxPlay("ui_back", 0.8);
                }
            } else if (this.titlePanel != 0) {
                if (act >= 0 || input.pressed(inp, "back") || (g != null && vmx.optTakeBool(g, "backPressed"))) {
                    this.titlePanel = 0;
                    act = -1;
                    this.sfxPlay("ui_back", 0.8);
                }
            } else if (act == 0) {
                // the device that pressed START locks the control mode
                cmode.lock(this.modeRec);
                this.controlMode = this.modeRec.mode;
                cmode.write(this.modeRec, this.gameVm);
                this.restart(false);
            } else if (act == 1) {
                this.titlePanel = 1;
                this.cardIndex = 1;
                if (g != null) {
                    vmx.num(g, "cardIndex", 1);
                }
                this.sfxPlay("ui_select", 0.8);
            } else if (act == 2) {
                this.modeStep(1);
            } else if (act == 3) {
                this.qualityStep(1);
            } else if (act == 4) {
                this.titlePanel = 2;
                this.sfxPlay("ui_select", 0.8);
            } else if (this.menuIndex == 2) {
                this.controlsRow();
            } else if (this.menuIndex == 3) {
                this.qualityRow();
            }
            if (g != null) {
                vmx.num(g, "titlePanel", this.titlePanel);
            }
            // idle on the title (no key, pad, touch, pointer or menu activity):
            // the attract reel takes over after REEL_IDLE seconds
            let busy = inp.anyKey || act >= 0 || this.titlePanel != 0 || inp.tx != 0 || inp.ty != 0 || tapped;
            if (g != null) {
                let lx = opt(vmx.optNum(g, "lookX"), 0), ly = opt(vmx.optNum(g, "lookY"), 0);
                let mi = opt(vmx.readNumLive(g, "menuIndex"), 0);
                let sig = lx * 1.37 + ly * 7.1 + mi * 1000;
                if (this.idleSig != sig) {
                    if (!isNaN(this.idleSig)) {
                        busy = true;
                    }
                    this.idleSig = sig;
                }
            }
            if (busy) {
                this.idleT = 0;
            } else {
                this.idleT += rdt;
            }
            if (this.state == "title" && this.idleT > REEL_IDLE && !this.autopilotOn) {
                this.idleT = 0;
                this.reelClip(1);
            }
        } else if (st == "briefing") {
            playerMod.clearControls(this.ctrl);
            playerMod.update(p, this.ctrl, dt, this.chunks);
            // keep baking the course near the launch pad while the dossier reads
            scenery.pump(0, 3);
            // the dossier holds until the pilot confirms (or the attract timeout);
            // back returns to the title
            let go = input.pressed(inp, "confirm") || (g != null && vmx.takeBool(g, "startPressed"));
            let back = input.pressed(inp, "back") || (g != null && vmx.optTakeBool(g, "backPressed"));
            if (g != null) {
                vmx.optSetNum(g, "autoLaunch", Math.floor(mathx.saturate(this.stateT / BRIEF_ATTRACT) * 100) / 100);
            }
            if (back && this.stateT > 0.3) {
                this.sfxPlay("ui_back", 0.8);
                this.goToTitle();
            } else if ((go && this.stateT > 0.5) || this.stateT > BRIEF_ATTRACT || (this.autopilotOn && this.stateT > 4.2)) {
                this.sfxPlay("ui_select", 0.8);
                this.startLaunch(this.schoolArmed);
            }
        } else if (st == "launch") {
            // countdown while the rocket pack spools up, then blast off
            let cd = lmax(0, 3 - Math.floor(this.stateT));
            if (cd != this.countdown) {
                this.countdown = cd;
                if (g != null) {
                    vmx.num(g, "countdown", cd);
                }
                if (cd == 0) {
                    // GO
                    this.sfxPlay("boost_start", 1);
                    p.frozen = false;
                    p.speed = 24;
                    p.boostKick = 1;
                    camera.go(this.rig, p);
                    this.rig.fovKick = rad(9);
                    this.launchT = 0;
                    this.launchX = p.pos.x;
                    this.launchZ = p.pos.z;
                    p.vy = 4.2; // a low hop: he cruises ~3.8 m over the bay, his twin in the water
                    // shockwave rings on the water and a hot core at the pack
                    weapons.flare(this.weapons, p.pos.x, 0.25, p.pos.z, 2.5, 46, 0.75, 0.95, 1, 1, 2);
                    weapons.flare(this.weapons, p.pos.x, 0.25, p.pos.z, 1.5, 26, 0.55, 1, 0.85, 0.6, 2);
                    weapons.flare(this.weapons, <f64>p.pos.x - <f64>p.fwd.x, <f64>p.pos.y - 0.6, <f64>p.pos.z - <f64>p.fwd.z, 3, 10, 0.35, 1, 0.75, 0.4, 1);
                    camera.addShake(this.rig, 1.0);
                    let r = this.r;
                    if (r != null) {
                        r.post.flash = 0.35;
                        r.post.flashR = 1;
                        r.post.flashG = 0.92;
                        r.post.flashB = 0.75;
                    }
                    for (let i = 1; i <= 30; i++) {
                        let ox = (lrandom() - 0.5) * 3;
                        let oz = (lrandom() - 0.5) * 3;
                        fx.spray(this.fx, <f64>p.pos.x + ox, 0, <f64>p.pos.z + oz, 1);
                    }
                    fx.sparks(this.fx, <f64>p.pos.x - <f64>p.fwd.x, <f64>p.pos.y - 0.6, <f64>p.pos.z - <f64>p.fwd.z, 18, 1, 0.65, 0.25);
                    training.go(this.school);
                }
            }
            if (cd == 0) {
                // launch surge: boost speed without spending the meter (the
                // school's speed hold caps it like a boost: ~70, settling to 45)
                let surge = p.speedCap > 0 ? lmin(playerMod.BOOST, p.speedCap + 25) : playerMod.BOOST;
                p.speed = mathx.damp(p.speed, surge, 2.2, dt);
            }
            this.simulate(dt, cd == 0);
            if (cd > 0) {
                p.thrust = mathx.lerp(0.3, 0.9, this.stateT / 3);
                camera.addShake(this.rig, 0.1 + this.stateT * 0.12);
                let n = Math.floor(this.stateT * 1.2 + lrandom());
                for (let i = 1.0; i <= n; i++) {
                    let a = lrandom() * mathx.TAU;
                    let rr = 0.8 + lrandom() * (1 + this.stateT);
                    fx.spray(this.fx, <f64>p.pos.x + Math.cos(a) * rr, 0, <f64>p.pos.z + Math.sin(a) * rr, 1);
                }
            }
            if (input.pressed(inp, "pause")) {
                // the countdown pauses too (the touch PAUSE button is up from the 2)
                this.pausedFrom = "launch";
                this.pausedT = this.stateT;
                this.setState("paused");
                input.releaseAll(inp);
            } else {
                if (this.stateT > 3.9) {
                    this.setState(this.school.active ? "training" : "playing");
                }
                // the school: skip (queued to GO + 0.45 s), the tower line, drill 1
                if (this.school.active) {
                    training.update(this.school, this.schoolEnv(), rdt);
                    p = this.player;
                }
            }
        } else if (st == "relaunch") {
            this.relaunchUpdate(dt);
        } else if (st == "training") {
            // the flight school (core_training.luau): no events, scoring or death
            this.simulate(simDt, true);
            this.heroPull = mathx.damp(this.heroPull, p.grazing ? 1 : 0, p.grazing ? 20 : 4, simDt);
            if (input.pressed(inp, "pause")) {
                this.pausedFrom = "training";
                this.pausedT = this.stateT;
                this.setState("paused");
                input.releaseAll(inp);
            } else {
                training.update(this.school, this.schoolEnv(), rdt);
                // (the cut starts a fresh run: a new pilot)
                p = this.player;
            }
        } else if (st == "playing") {
            this.simulate(simDt, true);
            this.updatePortal(simDt);
            // (and drawn in front of THE FALLS curtain while it would hide him)
            this.heroPull = camera.curtainPull(this.rig, p, mathx.damp(this.heroPull, p.grazing ? 1 : 0, p.grazing ? 20 : 4, simDt));
            if (p.shield <= 0 && p.alive) {
                p.alive = false;
                this.splashed = false;
                this.puffT = 0;
                p.vy = 2;
                p.vx = p.vx * 0.3;
                this.setState("dying");
                camera.deathHold(this.rig, p);
                // MISSION FAILED names the checkpoint he went down in ('02 SEA ARCH')
                let si = level.sectionAt(p.s);
                let secs = level.sections;
                if (g != null && si >= 1 && si < secs.length) {
                    let sec = secs[si];
                    vmx.optSetStr(g, "downedAt", sec.num + " " + sec.label);
                }
                // ... and what downed him, one tip, how far he got, where RETRY
                // picks up (QA PT1-5 / 6)
                if (g != null) {
                    let cp = this.memo.cp;
                    vmx.optSetStr(g, "failCause", this.memo.cause);
                    let tips = scoring.TIPS;
                    vmx.optSetStr(g, "failTip", tips.has(this.memo.cause) ? tips.get(this.memo.cause) : "");
                    vmx.optSetNum(g, "failProgress", Math.floor(mathx.saturate(p.s / level.eye.s) * 100 + 0.5) / 100);
                    vmx.optSetStr(g, "cpLabel", cp != null ? cp.label : "");
                }
                // a blast without the debris shower: a tumbling chunk trails ink
                // puffs, a column of beads down the rock (QA M8); its flat
                // flakes stay
                let F = this.fx;
                let nd = F.debris.length - 1;
                fx.explosion(F, p.pos.x, p.pos.y, p.pos.z, 1.2, "boom");
                for (let i = F.debris.length - 1; i >= nd + 1; i--) {
                    if (!F.debris[i].flat) {
                        rem(F.debris, i);
                    }
                }
                this.sfxPlay("explode_big", 1);
                camera.addShake(this.rig, 1.6);
                let r = this.r;
                if (r != null) {
                    r.post.flash = 0.6;
                    r.post.flashR = 1;
                    r.post.flashG = 0.7;
                    r.post.flashB = 0.4;
                }
                // the channel is VI's cry (prio 5: over the line on air at its
                // next whole word; nothing else plays to a downed pilot). One
                // word: the visor goes 1.2 s in (it was 'CORSAIR! Corsair, pull
                // up!', never typed past 'CORSAI' before the HUD went)
                this.commQueue.length = 1;
                this.commPush("vi", "VI", "CORSAIR!", 1.2, "shout", 5, 1);
                // the alert slot is the death's too: nothing queued shows over the death cam (alertPump drops what a
                // checkpoint crossed in the dive raises; QA FAIL-N1: ENTER THE EYE / FULL THROTTLE under SHIELD
                // CRITICAL)
                this.alerts.length = 1;
            } else if (p.s >= level.eye.s - 70) {
                // final approach: the camera lets go and watches the pilot dive into the Eye
                this.setState("outro");
                camera.hold(this.rig, p, 0.6);
                this.entered = false;
                this.enteredT = 0;
                // the victory dive: no flavor chatter (damage calls) under it
                let q = this.commQueue;
                for (let i = q.length - 1; i >= 1; i--) {
                    if (q[i].prio <= 1) {
                        rem(q, i);
                    }
                }
                // (one on air goes once it is typed out, not half way)
                if (this.commPrio <= 1 && this.commT > 0) {
                    this.commT = lmin(this.commT, lmax(0.1, this.commOut - this.commAge + CUT_TAIL));
                }
            } else if (input.pressed(inp, "pause")) {
                this.pausedFrom = "playing";
                this.pausedT = this.stateT;
                this.setState("paused");
                input.releaseAll(inp);
            }
        } else if (st == "paused") {
            let act = this.menuStep();
            if (g != null && vmx.takeBool(g, "resumePressed")) {
                act = 0;
            }
            if (input.pressed(inp, "pause") || input.pressed(inp, "back")) {
                act = 0;
            }
            // rows: 0 RESUME, 1 RESTART (pauseRow1), 2 CONTROLS, 3 QUALITY, 4 QUIT
            if (act == 2) {
                this.modeStep(1);
                act = -1;
            } else if (act == 3) {
                this.qualityStep(1);
                act = -1;
            } else if (act < 0 && this.menuIndex == 2) {
                this.controlsRow();
            } else if (act < 0 && this.menuIndex == 3) {
                this.qualityRow();
            }
            // QUIT asks twice when the pause card can show it (Game.quitArmed):
            // the first press arms it, moving off QUIT or 4 s disarm it
            if (this.quitArmed && (this.menuIndex != 4 || this.stateT - this.quitT > 4 || act == 0 || act == 1)) {
                this.quitArmed = false;
            }
            if (act == 4 && g != null && vmx.hasBool(g, "quitArmed") && !this.quitArmed) {
                this.quitArmed = true;
                this.quitT = this.stateT;
                this.sfxPlay("ui_select", 0.8);
                act = -1;
            }
            if (g != null) {
                vmx.optSetBool(g, "quitArmed", this.quitArmed);
            }
            if (act == 0) {
                let back = this.pausedFrom;
                this.setState(back);
                if (back == "launch" || back == "training" || back == "relaunch") {
                    this.stateT = this.pausedT;
                }
                input.releaseAll(inp);
            } else if (act == 1) {
                this.pauseRow1();
            } else if (act == 4) {
                this.goToTitle();
            }
        } else if (st == "dying") {
            this.dyingStep(p, dt);
        } else if (st == "outro") {
            this.outroStep(p, dt);
        } else if (st == "results" || st == "gameover") {
            // the report is read first: no key acts for 1.2 s, and Space (fire)
            // never confirms here (mashing fire must not skip the tally)
            let act = this.menuStep(true);
            if (g != null && vmx.takeBool(g, "startPressed")) {
                act = 0;
            }
            let back = input.pressed(inp, "back") || (g != null && vmx.optTakeBool(g, "backPressed"));
            if (this.stateT < 1.2) {
                act = -1;
                back = false;
            }
            this.reportAct(act, back);
        } else if (st == "retry") {
            if (this.stateT >= 0.17) {
                this.retryGo();
            }
        }

        this.bossDyingUpdate(dt);

        // after the cut: controls come back as the certificate ends
        let S = this.school;
        if (S.tail && this.state != "paused") {
            if (this.sting != "training_complete") {
                training.tailEnd(S, this.schoolEnv());
                this.player.controls = true;
            } else {
                this.player.controls = false;
            }
        }

        // wingmen fly with the pilot while flying
        // (not in the school: wingmen are voice only there)
        let wingFly = this.state == "playing" || (this.state == "launch" && this.countdown == 0 && !this.school.active);
        let attract = this.state == "title";
        if (this.state != "outro" && this.state != "paused") {
            this.wing.titleForm = attract;
            this.wing.fight = this.bossActive || this.rig.focusW > 0.1;
            // a join / peel lands with its call: it waits for the channel (not in
            // a fight: their calls are held there anyway)
            this.wing.hold = wingFly && !this.bossActive && !this.bossDying && (this.commBusy() || this.joinUnfit());
            wingmen.update(this.wing, this.player, this.t, dt, wingFly || attract, wingFly ? this.keeper : null);
        }
        if (attract) {
            // the squadron flies the attract loop together, quietly
            this.wing.say.length = 1;
        } else if (this.wing.joined) {
            this.sfxPlay("flyby", 0.8);
        }
        // a boss fight keeps the wingmen off the channel: their flavor reactions
        // drop, their formation calls (join / peel) wait until the fight and the
        // boss's death dive are over (the kill chatter goes first)
        let held = this.wingHeld;
        let say = this.wing.say;
        for (let si = 1; si < say.length; si++) {
            let l = say[si];
            let pr = opt(l.prio, 2);
            let call = l.call;
            let isReact = call != null && call == "react";
            if (isReact && (this.bossActive || this.bossDying)) {
                // (a shot reaction is only worth saying at once)
                continue;
            } else if (this.bossActive || (this.bossDying && held.length - 1 > 0)) {
                if (pr >= 2) {
                    held.push(new HeldLine(l));
                } else if (!this.bossActive) {
                    // (a reaction to the kill goes out at once)
                    this.commPush(l.who, l.speaker, l.text, WING_SECONDS, null, pr, 4, true);
                }
            } else {
                // (a shot reaction is a prio 2 wingman's line, its last sentence
                // when short of room: a beat waits ~0.7 s for it at most, r2:
                // HANK's drone call waited 2.5 s; QA PT1-5: at prio 1, whole,
                // it was queued 42x, played 0x)
                if (call != null && call == "peel") {
                    pages.dropJoins(this.commQueue, l.who);
                }
                let cl = this.commPush(l.who, l.speaker, l.text, WING_SECONDS, null, pr, wingAge(l), true);
                if (cl != null) {
                    cl.react = isReact;
                }
            }
        }
        this.wing.say.length = 1;
        if (held.length - 1 > 0) {
            if (!this.bossActive && !this.bossDying) {
                for (let hi = 1; hi < held.length; hi++) {
                    let l = held[hi].line;
                    this.commPush(l.who, l.speaker, l.text, WING_SECONDS, null, opt(l.prio, 2), 10, true);
                }
                held.length = 1;
            } else if (this.state != "paused") {
                for (let hi = held.length - 1; hi >= 1; hi--) {
                    held[hi].age += rdt;
                    if (held[hi].age > 40) {
                        rem(held, hi);
                    }
                }
            }
        }

        // comms + center alerts: one channel each, delivered when free
        if (this.state != "paused") {
            if (this.state == "dying" && this.commOn) {
                // the channel goes with the visor: 1.2 s in, or at the splash
                // once VI's cry is out
                let cried = this.commPrio >= 5 && this.commOutAge >= 0 && this.commAge > this.commOutAge + 0.3;
                if (this.stateT > 1.2 || (this.splashed && cried)) {
                    this.commQueue.length = 1;
                    this.commClose();
                }
            }
            if (this.state == "playing") {
                this.laterPump();
            }
            // (the slot first: a line due on a banner's frame waits for it like
            // any other, QA PT1-4 r2)
            if ((this.state == "playing" || this.state == "launch" || this.state == "outro" || this.state == "dying") && !this.stingLive()) {
                this.alertPump(rdt);
            }
            this.commPump(rdt);
            this.warnT -= rdt;
            if (this.warnT <= 0) {
                let h = this.hudVm;
                if (h != null) {
                    vmx.bool(h, "warningActive", false);
                }
            }
        }

        // renderer params: visor boot, post fx
        let r = this.r;
        p = this.player;
        if (r != null) {
            this.postFx(r, p, dt, rdt);
        }

        fx.update(this.fx, simDt);
        popups.update(this.pops, dt);
        {
            let skimming = p.alive && p.overWater && !p.frozen && (flying(this.state) || this.state == "launch" || this.state == "outro");
            wake.update(this.wake, simDt, p.pos.x, p.pos.z, p.pos.y, p.fwd.x, p.fwd.z, skimming);
        }
        this.nearFade(p);
        if (this.state != "paused") {
            // (the lens holds with the hit-stop: it used to run on into the rock
            // he was stuck against)
            camera.update(this.rig, p, this.t, simDt);
            let cam = this.rig.cam;
            let cf = mathx.norm(cam.target - cam.eye);
            let cr = mathx.norm(mathx.cross(cf, cam.up));
            this.camR = cr;
            this.camU = mathx.cross(cr, cf);
            weapons.sightsUpdate(this.weapons, p, cam.eye, cf, cr, this.camU, Math.tan(cam.fov * 0.5), this.rig.aspect, dt);
            // exhaust + vapor ribbons anchored to the sprite's nozzles and hands
            let tr = this.trails;
            let nt = tr.length - 1;
            // a jump (attract loop, restart, debug start) must not draw a streak across the map
            if (mathx.dist2(p.pos, this.trailPos) > 40 * 40) {
                for (let i = 1; i < tr.length; i++) {
                    R.trailClear(tr[i]);
                }
            }
            this.trailPos = p.pos;
            if (nt == 4 && this.heroNodes != null) {
                // painted flames carry the look: the ribbons are a short heat
                // shimmer at cruise, a longer streak only while boosting
                let life = p.boosting || p.boostKick > 0.3 ? 0.065 : 0.045;
                tr[1].life = life;
                tr[2].life = life;
            }
            if (nt == 4) {
                // wingtip vapor: short wisps off the fists (about 4 m of ribbon at
                // any speed), never a beam streaming back past the lens
                let vl = mathx.clamp(4 / lmax(p.speed, 1), 0.04, 0.1);
                tr[3].life = vl;
                tr[4].life = vl;
            }
            if (nt == 4 && p.alive) {
                let roll = this.heroRoll(p);
                let c0 = Math.cos(roll), s0 = Math.sin(roll);
                let R0 = this.camR, U0 = this.camU;
                let o = this.anc;
                let thin = this.heroNodes != null ? 0.6 : 1.0;
                let gunL = this.weapons.aim, gunR = this.weapons.aim;
                for (let side = -1; side <= 1; side += 2) {
                    let j = side < 0 ? 1 : 3;
                    let ox = o[j], oy = o[j + 1];
                    let q = p.pos + R0 * <f32>(ox * c0 - oy * s0) + U0 * <f32>(ox * s0 + oy * c0) - p.fwd * <f32>0.3;
                    R.trailPush(tr[side < 0 ? 1 : 2], q.x, q.y, q.z, this.t, (0.22 + p.thrust * 0.3) * thin);
                    let hx = o[j + 4], hy = o[j + 5];
                    let h = p.pos + R0 * <f32>(hx * c0 - hy * s0) + U0 * <f32>(hx * s0 + hy * c0);
                    R.trailPush(tr[side < 0 ? 3 : 4], h.x, h.y, h.z, this.t);
                    if (side < 0) {
                        gunL = h;
                    } else {
                        gunR = h;
                    }
                }
                weapons.setGuns(this.weapons, gunL, gunR);
                // the ribbons never run up across his own body (a low eye in a
                // boss fight puts him above the vanishing point)
                let ce = this.rig.cam.eye;
                let vf = mathx.cross(U0, R0);
                for (let i = 1; i <= 2; i++) {
                    let vis = wingmen.ribbonVis(tr[i], ce, vf, R0, U0, roll, <f64>(i * 2 - 3));
                    this.exVis[i] = mathx.damp(this.exVis[i], vis, 14, dt);
                }
            }
        }
        if (this.state != "paused") {
            wingmen.pushTrails(this.wing, this.camR, this.camU, this.t, this.rig.cam.eye, dt);
        }
        if (this.launchT >= 0) {
            this.launchT += dt;
        }
        let sx = this.sfx;
        if (sx != null) {
            let biome = this.portalT >= 0 || p.s > level.portalS ? "violet" : "coast";
            sfx.scene(sx, sceneState(this.state), biome, this.bossActive);
            let airborne = flying(this.state) || this.state == "launch" || this.state == "outro" || (this.state == "dying" && !this.splashed);
            if (airborne) {
                let sp01 = mathx.saturate((p.speed - playerMod.BRAKE) / (playerMod.BOOST - playerMod.BRAKE));
                sfx.flight(sx, p.thrust, p.boosting, sp01, p.pos.y);
            }
            sfx.charge(sx, this.weapons.charging && flying(this.state));
            // radio static bed + music dip follow the comms window exactly
            sfx.comm(sx, this.commT > 0);
            if (this.state == "launch" || this.state == "relaunch") {
                sfx.countdown(sx, this.countdown);
            }
            sfx.update(sx, rdt);
        }

        // view models
        let h = this.hudVm;
        if (h != null) {
            hud.syncHud(h, this.hudCache, p, this.sc, this.weapons, this.hudOn() && this.bootDone(), this.school.active);
        }
        let pv = this.pilotVm;
        let volleys = this.weapons.muzzle > 0.2;
        if (pv != null) {
            // firing = volleys, and the whole charge hold (the painted hero raises
            // his fists while the nova charges, so the glows ride the fire pose's
            // wrist anchors)
            let charging = this.weapons.charging && flying(this.state);
            hud.syncPilot(pv, p, volleys || charging);
            vmx.optSetBool(pv, "charging", charging);
        }
        let tv = this.reflVm;
        if (tv != null) {
            // same bank (not negated): the reflection pass mirrors vertically only
            hud.syncPilot(tv, p, volleys);
        }
        if (h != null) {
            this.screenWrites(h, g, p);
        }
        this.stingSync();
        weapons.sync(this.weapons, this.reticleVm);
        if (g != null && (this.state == "playing" || this.state == "paused" || this.state == "relaunch")) {
            vmx.str(g, "timeText", this.sc.timeText);
            vmx.num(g, "score", this.sc.score);
        }

        // script-owned artboards (only the ones on screen)
        let ha = this.hudArt;
        let rv = this.r;
        let hon = this.hudOn();
        if (ha != null && (hon || (rv != null && rv.visor.opacity > 0.01))) {
            if (rv != null) {
                // 2.1: only on the frames it is drawn, unless the core reads it
                let live = hudlive.live(this.hudVm, rdt, hon && rv.visor.opacity > 0.01,
                    (this.commOn || this.commT > 0) && this.commOutAge < 0, this.rig.aspect < 1,
                    this.bossActive || this.bossDying, this.alertT > 0 || this.alerts.length - 1 > 0);
                R.hudAdvance(rv, rdt, live, this.t);
            } else {
                ha.advance(rdt);
            }
        }
        let shown = this.state != "title" && this.state != "results" && this.state != "gameover" && this.state != "retry";
        let pa = this.pilotArt;
        if (pa != null && shown) {
            pa.advance(dt);
        }
        let ta = this.reflArt;
        if (ta != null && shown && p.pos.y < 18) {
            // the underside twin only shows while low over the water
            ta.advance(dt);
        }
        this.readAnchors();
        let ra = this.reticleArt;
        if (ra != null) {
            ra.advance(rdt);
        }
        weapons.advanceArt(this.weapons, dt);
        if (isDefined(TRK)) {
            trkF += 1;
            if (mod(trkF, 30) == 0 && this.state != "title" && this.state != "briefing") {
                let pp = this.player;
                console.log(format("TRK f=%d st=%s t=%.17g s=%.17g x=%.17g y=%.17g sp=%.17g sh=%.17g sc=%d k=%d", [
                    FN(trkF), FS(this.state), FN(this.t), FN(pp.s), FN(pp.x), FN(pp.y), FN(pp.speed), FN(pp.shield), FN(this.sc.score), FN(this.stats.kills)]));
            }
        }
        if (isDefined(DBG0) && trkF >= <f64>DBG0 && trkF <= <f64>DBG1) {
            let E = this.enemies;
            let hp = 0.0, n = 0.0, nb = 0.0;
            if (E != null) {
                for (let i = 1; i < E.list.length; i++) {
                    let e = E.list[i];
                    if (e.alive) {
                        hp += e.hp;
                        n += 1;
                    }
                }
                nb = <f64>(E.bullets.length - 1);
            }
            let W = this.weapons, c = this.ctrl;
            let qs = "", as = "";
            for (let i = 1; i < this.commQueue.length; i++) {
                let l = this.commQueue[i];
                qs += (i > 1 ? ";" : "") + format("%s|%d|%.17g", [FS(l.text), FN(l.prio), FN(l.age)]);
            }
            for (let i = 1; i < this.alerts.length; i++) {
                let a = this.alerts[i];
                as += (i > 1 ? ";" : "") + format("%s|%d|%.17g", [FS(a.text), FN(a.prio), FN(a.age)]);
            }
            console.log(format("DBC f=%d aT=%.17g aA=%.17g wT=%.17g cT=%.17g cA=%.17g on=%s slab=%s txt=%s Q=[%s] A=[%s]", [FN(trkF), FN(this.alertT), FN(this.alertAge), FN(this.warnT), FN(this.commT), FN(this.commAge), FS(this.commOn ? "true" : "false"), FS(this.memo.slab), FS(this.commText), FS(qs), FS(as)]));
            if (E != null) {
                let ps = "";
                for (let i = 1; i < E.list.length; i++) {
                    let e = E.list[i];
                    ps += (i > 1 ? " " : "") + format("%s:%.17g,%.17g,%.17g,%s,%s", [FS(e.kind), FN(e.x), FN(e.y), FN(e.z), FS(e.alive ? "true" : "false"), FS(e.lockable ? "true" : "false")]);
                }
                console.log("DBE f=" + lstr(trkF) + " " + ps);
                let ls = "";
                for (let i = 1; i < W.locks.length; i++) {
                    let l = W.locks[i];
                    ls += (i > 1 ? " " : "") + format("%.17g/%s/%s", [FN(l.progress), FS(l.locked ? "true" : "false"), FS(l.e != null ? "true" : "false")]);
                }
                console.log("DBL f=" + lstr(trkF) + " lt=" + format("%.17g", [FN(W.lockT)]) + " ch=" + format("%.17g", [FN(W.charge)]) + " " + ls);
            }
            console.log(format("DBG f=%d sf=%d shh=%d k=%d lc=%d ch=%s vol=%d n=%d hp=%.17g nb=%d sx=%.17g sy=%.17g fi=%s x=%.17g y=%.17g ax=%.17g", [FN(trkF), FN(this.stats.shotsFired), FN(this.stats.shotsHit), FN(this.stats.kills), FN(W.lockCount), FS(W.charging ? "true" : "false"), FN(W.volley), FN(n), FN(hp), FN(nb), FN(c.sx), FN(c.sy), FS(c.fire ? "true" : "false"), FN(this.player.x), FN(this.player.y), FN(<f64>W.aim.x)]));
        }
        if (isDefined(CENSUS) && mod(trkF, <f64>CENSUS) == 0) this.census();
        input.endFrame(inp);
        return true;
    }

    census(): void {
        let E = this.enemies, F = this.fx, Ev = this.events, W = this.weapons, wg = this.wing, r = this.r;
        let bags = 0;
        let bl: Array<Bag?> = [this.gameVm, this.hudVm, this.pilotVm, this.reticleVm, this.reflVm];
        for (let i = 0; i < bl.length; i++) {
            let b = bl[i];
            if (b != null) bags += b.nums.size + b.strs.size + b.bools.size + b.enums.size + b.trigs.size + b.cols.size + b.missing.size + b.lastN.size + b.lastS.size + b.lastB.size;
        }
        let ps = this.pops.list;
        for (let i = 1; i < ps.length; i++) {
            let b = ps[i].bag;
            if (b != null) bags += b.nums.size + b.strs.size + b.bools.size + b.enums.size + b.trigs.size + b.lastN.size + b.lastS.size + b.lastB.size;
        }
        let sx = this.sfx;
        let line = format("CEN f=%d own=%d pages=%d bags=%d fx=%d/%d/%d/%d/%d/%d", [FN(trkF), FN(<f64>ownersCount()), FN(<f64>memory.size()), FN(<f64>bags),
            FN(<f64>F.parts.length), FN(<f64>F.free.length), FN(<f64>F.debris.length), FN(<f64>F.spots.length), FN(<f64>F.crowns.length), FN(<f64>F.rings.length)]);
        if (E != null) line += format(" E=%d/%d/%d/%d/%d/%d", [FN(<f64>E.list.length), FN(<f64>E.bullets.length), FN(<f64>E.freeBullets.length), FN(<f64>E.trails.length), FN(<f64>E.comms.length), FN(<f64>E.alerts.length)]);
        line += format(" ev=%d/%d/%d/%d/%d/%d/%d/%d/%d", [FN(<f64>Ev.fired.size), FN(<f64>Ev.timers.length), FN(<f64>Ev.alerts.length), FN(<f64>Ev.resolved.size), FN(<f64>Ev.core.length), FN(<f64>Ev.said.size), FN(<f64>Ev.held.length), FN(<f64>Ev.follow.length), FN(<f64>Ev.leads.length)]);
        line += format(" W=%d/%d/%d/%d wg=%d/%d/%d/%d", [FN(<f64>W.bolts.length), FN(<f64>W.novas.length), FN(<f64>W.locks.length), FN(<f64>W.flares.length), FN(<f64>wg.list.length), FN(<f64>wg.positions.length), FN(<f64>wg.say.length), FN(<f64>wg.pend.length)]);
        if (sx != null) line += format(" sfx=%d/%d/%d/%d/%d/%d/%d", [FN(<f64>sx.sources.size), FN(<f64>sx.missing.size), FN(<f64>sx.loops.size), FN(<f64>sx.voices.length), FN(<f64>sx.last.size), FN(<f64>sx.lastPick.size), FN(<f64>sx.ducks.size)]);
        if (r != null) line += format(" R=%d/%d/%d", [FN(<f64>r.batches.length), FN(<f64>r.sprites.length), FN(<f64>r.atlases.length)]);
        line += format(" pops=%d/%d game=%d/%d/%d/%d/%d/%d/%d", [FN(<f64>ps.length), FN(<f64>this.pops.foes.length), FN(<f64>this.commQueue.length), FN(<f64>this.alerts.length), FN(<f64>this.memo.heard.size), FN(<f64>this.memo.later.length), FN(<f64>this.memo.annN.size), FN(<f64>this.wingHeld.length), FN(<f64>this.rig.near.length)]);
        line += format(" rings=%d/%d school=%d", [FN(<f64>this.rings.list.length), FN(<f64>this.rings.collected.length), FN(<f64>this.school.rings.list.length)]);
        console.log(line);
    }

    // Rendering -------------------------------------------------------------------------

    override draw(renderer: Renderer): void {
        this.drew = true;
        let dt0 = clock();
        this.drawGame(renderer);
        if (isDefined(PERF) && (clock() - dt0) * 1000 > <f64>PERF) console.log(format("PERF draw %.1f ms (frame %.1f) st=%s", [FN((clock() - dt0) * 1000), FN(perfFrame), FS(this.state)]));
    }

    drawGame(renderer: Renderer): void {
        let r = this.r;
        if (r == null || !this.loaded) {
            return;
        }
        let p = this.player;
        let st = this.state;

        // scenery chunks around the player (far silhouettes live after the grid)
        let ps0 = p.s;
        let chunks = this.chunks;
        for (let i = 1; i < chunks.length; i++) {
            let c = chunks[i];
            if (scenery.isVisible(c, ps0)) {
                R.addBatch(r, c.batch);
            }
        }

        // swirl portals (the nearer is queued first: it drives the post lens)
        if (this.portalT < 0) {
            let d = level.portal.s - ps0;
            if (d < 2800 && d > -20) {
                let open = 0.5 + 0.5 * mathx.smoothstep(1500, 300, d);
                let pp = this.porPos, pf = this.porFwd;
                R.portal(r, pp.x, pp.y, pp.z, level.portal.radius, pf.x, pf.y, pf.z, this.t, open, 1);
            }
        } else if (!(st == "outro" && this.entered && this.enteredT > 2.4)) {
            let d = level.eye.s - ps0;
            if (d < 3400 && st != "results" && st != "gameover" && st != "retry") {
                let open = 0.45 + 0.55 * mathx.smoothstep(1800, 400, d);
                let ep = this.eyePos, ef = this.eyeFwd;
                R.portal(r, ep.x, ep.y, ep.z, level.eye.radius, ef.x, ef.y, ef.z, this.t * 0.8, open, -1, 1.25, 0.7, 1.35);
            }
        }

        // takeoff: the pack's blast churns the bay
        let lt = this.launchT;
        if (lt >= 0 && lt < 2.4) {
            R.foam(r, this.launchX, this.launchZ, 3 + lt * 9, 1 - lt / 2.4);
        } else if (st == "launch" && p.frozen) {
            R.foam(r, p.pos.x, p.pos.z, 1.5 + p.thrust * 2.5, 0.25 + p.thrust * 0.6);
        }

        scenery.drawDynamic(r, this.t, p.s);
        if (st != "title") {
            // (one ring set a frame: they share the batches)
            rings.draw(this.school.active ? this.school.rings : this.rings, r, p.s, this.t, this.rig.cam.eye);
        }
        wake.draw(this.wake, r);

        // the pilot (bank + barrel roll; flicker while invulnerable after a hit).
        // The title's key art is the hero on that screen (DIRECTION #17): no 3D
        // hero, twin, shadow or exhaust there; he shows from the briefing swoop on.
        let ps = this.pilotSprite;
        // (START: the title's key art floods and leaves first, never two Corsairs at once)
        let showPilot = st != "title" && st != "gameover" && st != "results" && st != "retry" && !(st == "outro" && this.entered)
            && !(st == "briefing" && this.stateT < 0.9);
        if (ps != null && showPilot && !(st == "dying" && this.splashed)) {
            let op = 1.0;
            // (not for the hit's first 0.15 s, p.flash 1 -> 0.4: at 0.45 under
            // the beam's glare he vanished on the hit frame, QA PT1-9)
            if (p.invuln > 0 && p.rollT <= 0 && flying(st) && p.flash < 0.4) {
                // (portrait chase: drawn small the faint frames blended into the
                // water; below 12% of the screen height they rise, to 0.75 at 8%)
                let rig = this.rig;
                let lo = rig.aspect < 1 && rig.mode == "chase" && rig.beat == "" && rig.focusW <= 0 ? mathx.lerp(0.75, 0.45, mathx.saturate((camera.heroH(rig, p.pos) - 0.08) / 0.04)) : 0.45;
                op = mod(this.t * 20, 2) < 1 ? lo : 1;
            }
            let bob = p.frozen ? Math.sin(this.t * 2.2) * 0.18 : 0;
            // barrel roll afterimages trail behind along the sidestep
            if (p.rollT > 0) {
                for (let k = 2; k >= 1; k--) {
                    let kf = <f64>k;
                    let lag = kf * 0.035;
                    let gx = <f64>p.pos.x - <f64>p.right.x * p.vx * lag - <f64>p.fwd.x * kf * 1.2;
                    let gz = <f64>p.pos.z - <f64>p.right.z * p.vx * lag - <f64>p.fwd.z * kf * 1.2;
                    let groll = this.heroRoll(p) - p.rollDir * kf * 0.55;
                    R.spriteAdd(ps, gx, <f64>p.pos.y - p.vy * lag, gz, groll, 3.4, 3.4, 0.5, 0.32 / kf, 0.7, 0.95, 1, 0.6);
                }
            }
            if (this.heroNodes != null) {
                // texture follows the (debounced) render size; a no-op unless it changed
                let px = heroTexSize(r);
                R.setSpriteSize(r, ps, px, px);
            }
            let roll = this.heroRoll(p);
            // a red kick on the painted hero when hit; barely any white (a white
            // flash plus bloom hid him, QA PT1)
            let hr = this.heroNodes != null ? 1 - p.flash * 0.45 : 1;
            let hx = <f64>p.pos.x, hy = <f64>p.pos.y + bob, hz = <f64>p.pos.z, hs = 3.4;
            let pull = flying(st) || st == "dying" ? this.heroPull : 0;
            if (pull > 0.001) {
                // scraping rock (the rendered rock juts past its collider): drawn
                // HERO_PULL m nearer the lens at the same screen size, so the
                // skin of rock he is in never hides him
                let e = this.rig.cam.eye;
                let dx = hx - <f64>e.x, dy = hy - <f64>e.y, dz = hz - <f64>e.z;
                let d = lmax(Math.sqrt(dx * dx + dy * dy + dz * dz), 1e-3);
                // (seen past a stack's flank the rock in front is thicker:
                // in front of where the sight line meets it)
                let want = lmax(HERO_PULL, d - camera.rockEntry(this.rig, e, Vector.xyz(<f32>hx, <f32>hy, <f32>hz), camera.ROCK_JUT) + 0.6);
                let f = lmax(0.2, 1 - want * pull / d);
                hx = <f64>e.x + dx * f;
                hy = <f64>e.y + dy * f;
                hz = <f64>e.z + dz * f;
                hs = 3.4 * f;
            }
            R.spriteAdd(ps, hx, hy, hz, roll, hs, hs, 0.5, op, 1, hr, hr, p.flash * 0.12);
            let rsp = this.reflSprite;
            if (rsp != null) {
                // the underside twin, mirrored in the water pass; fades with altitude
                let ro = op * (1 - mathx.smoothstep(5, 18, p.pos.y));
                if (ro > 0.01) {
                    R.spriteAdd(rsp, p.pos.x, <f64>p.pos.y + bob, p.pos.z, roll, 3.4, 3.4, 0.5, ro, 1, 1, 1, p.flash * 0.12);
                }
                // the hero sprite no longer reflects, so it no longer gets the auto contact shadow
                let k = 1 - mathx.smoothstep(0.5, 14.0, p.pos.y);
                R.shadow(r, p.pos.x, p.pos.z, 3.4 * (0.26 + 0.1 * (1 - k)), k * 0.8 * op);
            }
            if (p.alive) {
                R.wake(r, p.pos.x, p.pos.y, p.pos.z);
            }
        }
        wingmen.draw(this.wing, st == "outro" ? level.eye.s + 1 : HUGE, r, this.t);

        // the crash leaves a smoke streak down to the sea
        let sm = this.smoke;
        if (sm != null && (st == "dying" || st == "gameover")) {
            R.trail(r, sm, this.t, 1);
        }

        // exhaust ribbons and wingtip vapor (rolls, boosts, hard turns)
        let trs = this.trails;
        if (showPilot && p.alive && !p.frozen && trs.length - 1 == 4) {
            let ex = 0.55 + 0.45 * p.thrust;
            // painted flames are the hot core: the ribbons fade in past the flame tips
            let fadeIn = this.heroNodes != null ? 2.2 : NaN;
            if (this.heroNodes != null) {
                ex *= 0.5;
            }
            R.trail(r, trs[1], this.t, ex * this.exVis[1], fadeIn);
            R.trail(r, trs[2], this.t, ex * this.exVis[2], fadeIn);
            // rolls and hard turns only: the painted boost flames carry the boost
            let vap = lmax(p.rollT > 0 ? 0.8 : 0, mathx.saturate((Math.abs(p.vx) - 18) / 14) * 0.5);
            if (vap > 0.02) {
                R.trail(r, trs[3], this.t, vap);
                R.trail(r, trs[4], this.t, vap);
            }
        }

        // twin reticles ahead along the aim line
        let rs = this.reticleSprite;
        let W = this.weapons;
        let clean = this.rig.beat == ""; // set-piece shots carry no gun sights or score chips
        if (rs != null && clean && (flying(st) || (st == "launch" && this.countdown == 0 && this.stateT > 3.4)) && p.alive) {
            // constant screen size: near ~15% of the view height, far ~10%;
            // kept off the hero (weapons.sightsUpdate)
            let cam = this.rig.cam;
            let k = 2 * Math.tan(cam.fov * 0.5);
            let near = weapons.sights(W, p);
            let far = weapons.SIGHTS_2, kn = weapons.SIGHTS_3, kf = weapons.SIGHTS_4;
            let hot = W.hotAmt;
            let sn = mathx.dist(near, cam.eye) * k * kn;
            let sf = mathx.dist(far, cam.eye) * k * kf;
            let tg = 1 - hot * 0.3, tb = 1 - hot * 0.55;
            R.spriteAdd(rs, far.x, far.y, far.z, this.t * 1.5 * W.charge, sf, sf, 0.5, 0.8, 1, tg, tb);
            if (W.nearOp > 0.02) {
                R.spriteAdd(rs, near.x, near.y, near.z, 0, sn, sn, 0.5, 0.95 * W.nearOp, 1, tg, tb);
            }
        }

        let E = this.enemies;
        if (E != null) {
            enemies.draw(E, r);
        }
        fx.draw(this.fx, r);
        weapons.draw(W, r, p, this.t, 2 * Math.tan(this.rig.cam.fov * 0.5));
        if (clean) {
            // (the live enemies: the chips keep off them too)
            if (E != null) {
                popups.feed(this.pops, E.list, this.rig.cam);
            }
            popups.draw(this.pops, this.rig.cam, this.rig.aspect);
        }

        // rocket exhaust: two flame jets out of the sprite's nozzles, streaming
        // down the pilot's body line and back along the flight
        if (p.alive && showPilot && !(st == "dying" && this.splashed)) {
            let roll = this.heroRoll(p);
            let c0 = Math.cos(roll), s0 = Math.sin(roll);
            let R0 = this.camR, U0 = this.camU;
            let down = -(R0 * <f32>(-s0) + U0 * <f32>c0); // sprite-space down, rolled
            let th = p.thrust;
            let back = p.frozen ? 0.2 : 1.6;
            let o = this.anc;
            if (this.heroNodes != null) {
                // painted hero: the painted flames are the hot core; a few small
                // embers leave the flame tips back and a little outward (never up
                // the legs), reaching at most ~0.4 sprite heights
                let reach = p.frozen ? 0.35 : 0.9;
                for (let side = -1; side <= 1; side += 2) {
                    let sd = <f64>side;
                    let j = side < 0 ? 1 : 3;
                    let ox = o[j], oy = o[j + 1];
                    let out = R0 * <f32>(c0 * sd) + U0 * <f32>(s0 * sd);
                    let base = p.pos + R0 * <f32>(ox * c0 - oy * s0) + U0 * <f32>(ox * s0 + oy * c0) - p.fwd * <f32>0.25;
                    for (let i = 0; i <= 3; i++) {
                        let k = mod(this.t * (5 + th * 5) + <f64>i / 4, 1);
                        let q = base + down * <f32>(k * 0.22) + out * <f32>(k * 0.3) - p.fwd * <f32>(k * reach * (1 + th * 0.5));
                        let sz = (0.12 * (1 - k) + 0.04) * (0.7 + th * 0.5);
                        let a = lmin(1, k * 5) * (1 - k) * (0.14 + th * 0.2);
                        R.particle(r, q.x, q.y, q.z, sz, 1, 0.55 + (1 - k) * 0.25, 0.18 + (1 - k) * 0.2, a, 1, k, <f64>i, 0);
                    }
                }
            } else {
                let reach = 0.9 + th * 2.2;
                let an = this.anchors;
                for (let side = -1; side <= 1; side += 2) {
                    let ox = an.nozX * <f64>side, oy = an.nozY - 0.15;
                    let base = p.pos + R0 * <f32>(ox * c0 - oy * s0) + U0 * <f32>(ox * s0 + oy * c0);
                    for (let i = 0; i <= 5; i++) {
                        let k = mod(this.t * (6 + th * 6) + <f64>i / 6, 1);
                        let q = base + down * <f32>(k * reach) - p.fwd * <f32>(k * back * (1 + th));
                        let sz = (0.36 * (1 - k) + 0.07) * (0.6 + th * 0.8);
                        R.particle(r, q.x, q.y, q.z, sz, 1, 0.55 + (1 - k) * 0.35, 0.18 + (1 - k) * 0.3, (1 - k) * (0.45 + th * 0.5), 1, k, <f64>i, 0);
                    }
                }
            }
        }

        cprint.feed(r, this.printVals()); // JOB 26: the screens' print plates, as Rive draws them this frame
        let ft0 = clock();
        R.frame(r, renderer, this.rig.cam, this.pal, this.t);
        perfFrame = (clock() - ft0) * 1000;
    }

    // Input -------------------------------------------------------------------------------

    // Any press anywhere (never claimed: the UI under it still gets it). Only
    // the attract reel and the title idle clock read it.
    override pointerDown(e: PointerEvent): void {
        this.pointerPoke = true;
        cmode.pointerDown(this.modeRec, e);
    }

    // control mode evidence only (hover vs touch; core_mode.luau)
    override pointerMove(e: PointerEvent): void {
        cmode.pointerMove(this.modeRec, e);
    }

    override pointerUp(e: PointerEvent): void {
        cmode.pointerUp(this.modeRec, e);
    }

    override pointerExit(e: PointerEvent): void {
        cmode.pointerUp(this.modeRec, e);
    }

    // (Luau's handler returns nothing: the event keeps bubbling)
    override keyboardEvent(e: KeyboardEvent): bool {
        if (e.phase == "down") {
            cmode.key(this.modeRec);
        }
        input.key(this.inp, e.key, e.phase);
        return false;
    }

    override gamepadEvent(e: GamepadEvent): bool {
        cmode.pad(this.modeRec, e);
        input.gamepad(this.inp, e);
        return false;
    }

    // control mode evidence only: a pad is there (core_mode.luau)
    override gamepadConnected(e: GamepadEvent): void {
        cmode.padConnect(this.modeRec);
    }
}

// math.rad (x * (pi / 180), Luau's rounding)
function rad(x: f64): f64 {
    return x * (Math.PI / 180.0);
}

// How long a wingman's line may wait for the channel: a reaction 2 s (a
// stale one took the channel just as a scripted beat came due), a peel call
// 2.5 s (the pair waits for a free channel to break off, so it plays at once
// unless that wait ran out: then it must not push the next scripted beat far
// back), a join call 10 s. QA M14.
function wingAge(l: wingmen.Line): f64 {
    // (a shot reaction: only worth saying at once)
    let call = l.call;
    if (opt(l.prio, 2) <= 1 || (call != null && call == "react")) {
        return 2;
    }
    return call != null && call == "peel" ? 2.5 : 10;
}

// types.Ctx: the services the core loop hands the enemies, events and
// effects modules (Luau buildCtx's closures).
export class GameCtx extends types.Ctx {
    g: Game;

    constructor(g: Game) {
        super();
        this.g = g;
        this.player = g.tp;
        this.stats = g.stats;
        this.state = g.state;
        this.wingmen = g.wing.positions;
        this.practiceOn = true;
    }

    addScore(points: f64, x: f64, y: f64, z: f64, label: string?): f64 {
        let g = this.g;
        if (g.state != "playing" && g.state != "dying") {
            return NaN;
        }
        let pts = scoring.add(g.sc, g.player, points);
        if (label != null) {
            popups.spawn(g.pops, label + " +" + lstr(pts), "bonus", x, y + 2, z);
        } else {
            popups.kill(g.pops, pts, g.sc.combo + 1, x, y + 2, z);
        }
        // the points credited (the DOWNED card's sub prints them)
        return pts;
    }

    hurtPlayer(amount: f64, x: f64, y: f64, z: f64): void {
        let g = this.g;
        let p = g.player;
        if (p.rollT > 0 && amount <= 0.15) {
            this.deflect(x, y, z);
            return;
        }
        g.hurt(amount, x, y, z, false, scoring.hitCause(g.enemies, g.player.pos, HULL_BOX, x, y, z));
    }

    comm(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64): void {
        // (a flavor line is only worth saying at once)
        this.g.scriptLine(who, speaker, text, seconds, mood, opt(prio, 2));
    }

    // (events observes the slabs, the boss flag and the down_* cards it hooked:
    // Luau's pass-through wrappers on this ctx)
    banner(text: string, sub: string, kind: string): void {
        events.onBanner(this.g.events, this, text, sub, kind);
        this.g.alertPush(false, text, sub, kind, 0);
    }

    warning(text: string, seconds: f64): void {
        events.onWarning(this.g.events, this, text, seconds);
        this.g.alertPush(true, text, "", "warning", seconds);
    }

    boss(active: bool, name: string, health: f64): void {
        let g = this.g;
        events.onBoss(g.events, this, active);
        let h = g.hudVm;
        // the kill (the bar leaves the fight): the HUD keeps the stack up
        // with the bar at 0 through the death dive (its DESTROYED stamp),
        // released once the hull is gone (bossDyingUpdate)
        let downed = !active && health <= 0.001 && (g.bossActive || g.bossDying);
        if (downed && !g.bossDying) {
            g.bossDying = true;
            g.bossDyingT = 0;
        }
        if (h != null) {
            vmx.bool(h, "bossActive", active || g.bossDying);
            vmx.str(h, "bossName", name);
            vmx.num(h, "bossHealth", Math.floor(mathx.saturate(health) * 200 + 0.5) / 200);
            vmx.optSetStr(h, "bossTag", lfind(name, "STORM") != 0 ? "HOSTILE // CLASS-A AIRSHIP" : "HOSTILE // SENTINEL EYE");
            if (!active || health <= 0.001) {
                // a downed boss has no phase instruction left
                vmx.optSetStr(h, "bossPhase", "");
            }
        }
        if (active) {
            g.bossDying = false;
        }
        let crow = lfind(name, "STORM") != 0;
        if (active && !g.bossActive) {
            g.setMusic("music_boss");
            g.bossName = name;

            // core fallback: the reveal poster, unless the bosses fire their own
            if (crow) {
                g.stingSchedule("boss_stormcrow", "STORMCROW", "BARON KESSEL'S SKY GALLEON", 0.5);
            } else {
                g.stingSchedule("boss_watcher", "THE WATCHER", "SENTINEL OF THE EYE", 0.5);
            }
        }
        if (active && health <= 0.001) {
            // the core kill: DOWNED stamp + kill cam (core fallback)
            if (crow) {
                g.stingSchedule("down_stormcrow", "STORMCROW", "DOWNED", 0.2);
            } else {
                g.stingSchedule("down_watcher", "THE WATCHER", "DESTROYED", 0.2);
            }
        }
        if (!active && g.bossActive) {
            g.setMusic(g.portalT >= 0 ? "music_violet" : "music_level");
            if (health <= 0.001) {
                wingmen.react(g.wing, "combo");
            }
        }
        g.bossActive = active;
        scoring.boss(g.sc, active, health);
    }

    shake(amount: f64): void {
        camera.addShake(this.g.rig, amount);
    }

    sfx(name: string, volume: f64): void {
        this.g.sfxPlay(name, volume);
    }

    railFrame(sv: f64): Vector {
        track.frame(level.track, sv);
        this.rfPos = track.FRAME_P;
        this.rfFwd = track.FRAME_F;
        this.rfRight = track.FRAME_R;
        this.rfUp = track.FRAME_U;
        return this.rfPos;
    }

    toWorld(sv: f64, x: f64, y: f64): Vector {
        track.frame(level.track, sv);
        let p = track.FRAME_P, rt = track.FRAME_R;
        return Vector.xyz(<f32>(<f64>p.x + <f64>rt.x * x), <f32>(<f64>p.y + y), <f32>(<f64>p.z + <f64>rt.z * x));
    }

    focus(x: f64, y: f64, z: f64, weight: f64): void {
        camera.focus(this.g.rig, x, y, z, weight);
    }

    popup(text: string, kind: string, x: f64, y: f64, z: f64): void {
        popups.spawn(this.g.pops, text, kind, x, y, z);
    }

    deflect(x: f64, y: f64, z: f64): void {
        let g = this.g;
        g.offHero(x, y, z);
        let hx = g.ohX, hy = g.ohY, hz = g.ohZ;
        fx.sparks(g.fx, hx, hy, hz, 10, 0.75, 0.95, 1);
        // (its ring ends half r4's size, which boxed him in for 0.1 s
        // after a beam hit)
        weapons.flare(g.weapons, hx, hy, hz, 0.6, 5, 0.22, 0.75, 0.95, 1, 2);
        g.sfxPlay("hit", 0.6);
        g.sc.deflects += 1;
        if (g.school.active) {
            // the deflect drill: no score (its ticket stamps RETURNED!)
            return;
        }
        g.sc.score += 50;
        // RETURNED! (the school's word for it, QA PT1), every deflect: a
        // burst merges into one chip ('RETURNED! x3  +150'). It rides
        // along ahead of him on the bullet's side (a chip left at the
        // bullet point fell behind the lens in ~0.25 s)
        let p = g.player;
        let side = mathx.clamp((x - <f64>p.pos.x) * <f64>p.right.x + (y - <f64>p.pos.y) * <f64>p.right.y + (z - <f64>p.pos.z) * <f64>p.right.z, -2.5, 2.5);
        let a = p.pos + p.fwd * <f32>14 + p.up * <f32>2.2 + p.right * <f32>side;
        let v = p.fwd * <f32>p.speed;
        popups.spawn(g.pops, "RETURNED! +50", "bonus", a.x, a.y, a.z, 1.2, v.x, v.y, v.z);
    }

    holdSpeed(v: f64): void {
        this.g.player.speedCap = !isNaN(v) && v > 0 ? v : 0;
    }

    alertFree(): bool {
        let g = this.g;
        return g.alertT <= 0 && g.alerts.length - 1 == 0 && !g.stingLive();
    }

    commState(): f64 {
        let g = this.g;
        let waiting = 0.0;
        let q = g.commQueue;
        for (let i = 1; i < q.length; i++) {
            waiting = lmax(waiting, q[i].prio);
        }
        // (a sting holds the channel: taken until it is over)
        let left = g.stingLive() ? lmax(g.commT, 1) : g.commT;
        this.csLeft = left;
        this.csAge = g.commAge;
        this.csPrio = g.commT > 0 ? g.commPrio : 0;
        this.csWait = waiting;
        return left;
    }

    sting(kind: string, title: string, sub: string): void {
        let g = this.g;
        events.onSting(g.events, this, kind);
        // the bosses fire their own reveal / kill stings: core fallbacks stand down
        if (kind.startsWith("boss_") || kind.startsWith("down_")) {
            g.stingExt = true;
            g.stingDue = null;
        }
        g.stingFire(kind, title, sub);
    }

    stingActive(): bool {
        return this.g.stingLive();
    }

    project(x: f64, y: f64, z: f64): f64 {
        let u = camera.project(this.g.rig, Vector.xyz(<f32>x, <f32>y, <f32>z));
        this.pjU = u;
        this.pjV = camera.PROJECT_2;
        this.pjD = camera.PROJECT_3;
        return u;
    }

    onPractice(kind: string, x: f64, y: f64, z: f64): void {
        training.onPop(this.g.school, this.g.weapons, x, y, z);
    }

    // a practice orb landed: spark, light shake, a chip; never shield
    practiceHit(amount: f64, x: f64, y: f64, z: f64): void {
        let g = this.g;
        let p = g.player;
        if (LOG_TRAIN) {
            console.log(format("[train] practice hit %.2f at %.0f m (shield %.3f)", [FN(amount), FN(p.s), FN(p.shield)]));
        }
        fx.sparks(g.fx, x, y, z, 10, 1, 0.6, 0.3);
        camera.addShake(g.rig, 0.45);
        g.sfxPlay("hit", 0.5);
        p.flash = lmax(p.flash, 0.4);
        let a = p.pos + p.fwd * <f32>14 + p.up * <f32>2.4;
        let v = p.fwd * <f32>p.speed;
        popups.spawn(g.pops, "HIT!", "bonus", a.x, a.y, a.z, 0.85, v.x, v.y, v.z);
        let r = g.r;
        if (r != null) {
            r.visor.glitch = lmax(r.visor.glitch, 0.3);
        }
    }
}

// The camera rig's scenery probe (rig.solid / rig.rockNear): while the
// scenery still bakes, a burst of probes in one box is answered from one
// near list (scenery.near), with the same answers.
export class GameWorld extends camera.RigWorld {
    g: Game;
    nearL: scenery.Near = scenery.newNear();
    nearOn: bool = false;

    constructor(g: Game) {
        super();
        this.g = g;
    }

    solid(x: f64, y: f64, z: f64, rad: f64): bool {
        let hit = this.nearOn ? scenery.nearCollide(this.nearL, x, y, z, rad) : scenery.collide(this.g.chunks, x, y, z, rad);
        this.nx = scenery.HIT_NX;
        this.ny = scenery.HIT_NY;
        this.nz = scenery.HIT_NZ;
        this.d = scenery.HIT_D;
        return hit;
    }

    rockNear(on: bool, minx: f64, minz: f64, maxx: f64, maxz: f64): bool {
        this.nearOn = on && !scenery.ready();
        if (this.nearOn) {
            scenery.near(this.nearL, this.g.chunks, minx, minz, maxx, maxz);
        }
        return this.nearOn;
    }
}

// Keeps the wingmen inside the hero safe zone on screen (from the camera
// rig, not the renderer's last drawn matrix).
export class GameKeeper extends wingmen.Keeper {
    rig: camera.Rig;

    constructor(rig: camera.Rig) {
        super();
        this.rig = rig;
    }

    project(x: f64, y: f64, z: f64): f64 {
        let u = camera.project(this.rig, Vector.xyz(<f32>x, <f32>y, <f32>z));
        this.pjU = u;
        this.pjV = camera.PROJECT_2;
        this.pjD = camera.PROJECT_3;
        return u;
    }
}

// hud.bossPoint's projector (this frame's rig).
export class GameProjector extends hud.Projector {
    rig: camera.Rig;

    constructor(rig: camera.Rig) {
        super();
        this.rig = rig;
    }

    project(x: f64, y: f64, z: f64): f64 {
        let u = camera.project(this.rig, Vector.xyz(<f32>x, <f32>y, <f32>z));
        this.pjV = camera.PROJECT_2;
        this.pjD = camera.PROJECT_3;
        return u;
    }
}

// The flight school director's view of the game (schoolEnv refreshes the
// fields on every call; the Luau closures are the methods).
export class GameEnv extends training.Env {
    game: Game;

    constructor(game: Game) {
        super(game.player, game.weapons, game.fx, game.pops, game.inp);
        this.game = game;
    }

    sfx(name: string, vol: f64): void {
        this.game.sfxPlay(name, vol);
    }

    comm(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64): void {
        this.game.commPush(who, speaker, text, seconds, mood, prio, 10);
    }

    armBomb(): void {
        let g = this.game;
        g.bombs = lmax(g.bombs, 1);
        g.bombCd = 0;
        g.syncBombs();
    }

    card(title: string, sub: string): void {
        this.game.schoolCard(title, sub);
    }

    cut(): void {
        this.game.schoolCut();
    }
}
