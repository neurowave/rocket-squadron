// Port of src/game/core_training.luau. Flight school director (docs/design/training.md 3-4, 7). Owns the lesson
// plan, LAND / GAP / fresh-press rules, hint / demo / auto, the governor, hard stops, skip, the idle nudge,
// practice set-ups and rings, the per-drill success tests and the school's VM writes. The core (game.as) owns the
// app states, the sting (the certificate) and the cut; it calls:
//   begin (startLaunch(true) / debug start), go (GO), update (every unpaused launch / training frame), inject
//   (readControls: demos), ringsStep (simulate), onPop / skipNow (ctx.onPractice, pause SKIP TRAINING), finish
//   (the cut), reset (resetRun), prime (init: the certificate rows).
//
// Port: `new` -> create. Env is an abstract class (the core implements sfx / comm / armBomb / card / cut and
// refreshes the fields each frame). Lists are 1-based (slot 0 a hole): plan, rows, stacks, stackQ, LESSONS.
// orbs ({[Bullet]: Orb}) is a list of records holding their bullet (no object-keyed Map).
import { format, FormatArg } from "rive/format";
import { clock } from "rive/os";
import * as mathx from "../lib/mathx";
import * as level from "../world/level";
import * as vmx from "./vm";
import { Bag } from "./vm";
import * as input from "./input";
import { Input } from "./input";
import { Player, Controls } from "./player";
import * as weapons from "./weapons";
import { Weapons, Bolt } from "./weapons";
import * as enemies from "./enemies";
import { PracticeOpts, PracticeLob } from "./enemies";
import { Enemy, World, Bullet } from "./ai_types";
import * as fx from "./fx";
import { Fx } from "./fx";
import * as popups from "./popups";
import { Popups } from "./popups";
import * as pages from "./core_pages";
import * as rings from "./core_rings";
import { Rings, Spec } from "./core_rings";
import { Ctx } from "./types";
import * as scenery from "../world/scenery";
import { Chunk } from "../world/scenery";
import * as cliffs from "../world/cliffs";
import { HeadSpec } from "../world/cliffs";
import * as coll from "../world/collide";
import { Collider, Bounds } from "../world/collide";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as gpu from "../lib/gpu";
import { HUGE, lmin, lmax, lclamp } from "../lib/compat";

export let LOG: bool = false; // LOG_TRAIN: t, s, lesson, phase, cause on every change
// (an imported binding cannot be assigned: the core sets LOG here)
export function setLOG(on: bool): void {
    LOG = on;
}

const GAP: f64 = 0.7; // result -> next ticket (the ticket's exit is 38 f)
const LAND: f64 = 0.25; // tests count from show + LAND
const SKIP_FILL: f64 = 0.6; // seconds of hold
const SKIP_DECAY: f64 = 3;
const SKIP_LATE: f64 = 0.45; // a skip in the countdown fires at GO + this
const SKIP_CARD: f64 = 0.35; // skip -> the card
const HARD_T: f64 = 64; // GO + this: hard stop
const BUDGET: f64 = 60; // the governor's ceiling from GO
const CUT_AT: f64 = 0.35; // card (unpaused sting) seconds -> the cut
const NUDGE_T: f64 = 3;
const BOT_DEMO: f64 = 0.5; // bot mode: demos at LAND + this count as passes
const COACH_ETA: f64 = 0.55; // deflect coach: the slow beat starts this far out
const COACH_REAL: f64 = 0.6;
export const HEAT_CAP: f64 = 85;
export const SLOW: f64 = 0.35; // deflect coach time scale (game stingUpdate)
const CHIP: f64 = 0.25; // a scrape: one shield pip
const CHIP_FLOOR: f64 = 0.5; // (never SHIELD CRITICAL in the school)
const CHIP_HOLD: f64 = 1.4; // s the pip stays out
const CHIP_FILL: f64 = 0.6; // s it takes to refill
const LINE_WAIT: f64 = 3; // s the card may wait for the last drill's line
const LINE_TAIL: f64 = 0.05; // s of its hold the card may cover (its read hold plays)
const VOICE_HOLD: f64 = 1.2; // s the next ticket may wait for this one's line to type out and be read (its own plays with it)
const READ_TAIL: f64 = 0.4; // s a typed-out line holds before a waiting ticket line takes over (game CUT_TAIL)
const DRONE_BACK: f64 = 0.6; // s: a lobber shot down (before it lobbed: 11 s of nothing) is replaced
const DRONE_MAX: f64 = 3;

// Drill 01's slalom (s from the ticket's show, x, radius, height, seed): sea stacks rise in the lane, each face ~1 m
// past the middle at pilot height (its reach there: 4.55 / 3.44 / 3.14 m from x), so the line between two gap rings
// swings round the rock. A gap ring sits GAP_C from its stack's face as built, at the ring's height, as the
// mission's sea-arch gates sit. (1-based rows of 1-based fields)
const SLALOM: Array<Array<f64>> = [[0.0], [0.0, 175, 3.55, 4.6, 24, 7101], [0.0, 245, -2.45, 5, 27, 7103], [0.0, 315, 2.15, 4.4, 22, 7107]];
// RINGS_A: s, x, y0 +, stack (0: x as given, in open water; i: the gap ring level with stack i)
const RINGS_A: Array<Array<f64>> = [[0.0], [0.0, 125, 0, 3, 0], [0.0, 175, 0, 0, 1], [0.0, 245, 0, 2, 2], [0.0, 315, 0, 1, 3], [0.0, 365, 0, -1, 0]];
const GAP_C: f64 = 5.6; // m from the face to a gap ring's centre (its rim 2.4 m clear)
const PAST: f64 = 6; // m past the last stack: the drill passes there (a learner who had his 3 rings by stack 2 still dodges 3)
// A ring counts once he has steered this drill (past STIR, from the show); one he was carried into (within SHOVE_T
// of rock, or on the line the hands-off settle left him on: p.laneT) only if he steered across the lane in the last
// SIDE_T. A scrape shoves him into its gap ring and the settle takes him on (hands off was carried through three)
const SHOVE_T: f64 = 0.6;
const SIDE_T: f64 = 1.0;
const STIR: f64 = 0.05;
// Set B (set A can no longer finish the drill): s0 + ds i from the pilot (after set A's last live ring), x B_X either
// side of his coast line, toward the middle first (they arrive inside the drill). It waits until he is B_CLEAR s off
// rock (a hold's sidestep has eased out): a scrape's shove carried a hands-off pilot through B1 and B3
const B_S0: f64 = 50;
const B_DS: f64 = 40;
const B_X: f64 = 5;
const B_CLEAR: f64 = 0.3;
const COAST: f64 = 4.2; // 1 / s: his sideways speed eases out at this with the stick centred (player)
const LANE_X: f64 = 18;
const GROW: f64 = 0.8; // s a stack takes to rise (and to sink)
const SINK_AHEAD: f64 = 40; // m: at drill end the stacks further ahead sink; nearer ones stay until passed

// Section 4.1 / 4.3. hint / demo / auto: seconds from LAND (-1 none); hold: the demo's input time. focus:
// Hud.trainFocus.
export class Lesson {
    key: string;
    label: string;
    hint: f64;
    demo: f64;
    hold: f64;
    auto: f64;
    focus: string;
    who: string;
    mood: string;
    line: string;
    constructor(key: string, label: string, hint: f64, demo: f64, hold: f64, auto: f64, focus: string, who: string, mood: string, line: string) {
        this.key = key;
        this.label = label;
        this.hint = hint;
        this.demo = demo;
        this.hold = hold;
        this.auto = auto;
        this.focus = focus;
        this.who = who;
        this.mood = mood;
        this.line = line;
    }
}

// 1-based
export const LESSONS: Array<Lesson> = [
    new Lesson("", "", 0, 0, 0, 0, "", "", "", ""),
    new Lesson("rings", "RINGS", 6.0, -1, 0, 12.0, "shield", "tower", "neutral", "Rocks hurt! Thread the rings between them."),
    new Lesson("boost", "BOOST", 2.5, 4.5, 1.0, 6.0, "boost", "tower", "happy", "Open her up. Hold boost!"),
    new Lesson("brake", "BRAKE", 2.5, 4.5, 1.0, 6.0, "speed", "tower", "neutral", "Bleed it off. Hold brake!"),
    new Lesson("roll", "BARREL ROLL", 3.0, 4.5, 0, 6.0, "none", "vi", "happy", "Snap roll! Give me two!"),
    new Lesson("deflect", "DEFLECT", -1, -1, 0, 11.0, "shield", "hank", "happy", "Drone's lobbing slow ones. Roll into it, send it back!"),
    new Lesson("fire", "FIRE", 3.0, 5.0, 0.1, 6.5, "weapons", "tower", "neutral", "Three targets. Line up the reticle, quick taps."),
    new Lesson("charge", "LOCK-ON", 4.0, 7.0, 1.3, 9.0, "weapons", "hank", "happy", "Hold fire to charge a nova. Paint two, let go!"),
    new Lesson("bomb", "BOMB", 2.5, 4.0, 0, 5.0, "none", "tower", "shout", "Drop a bomb! You get two."),
];

function speakerOf(who: string): string {
    if (who == "tower") return "LIGHTHOUSE";
    if (who == "vi") return "VI";
    if (who == "hank") return "HANK";
    return who;
}
function nudgeOf(mode: string): string {
    if (mode == "gamepad") return "Still with me? Hold BACK to skip ahead.";
    if (mode == "touch") return "Still with me? Hold SKIP to skip ahead.";
    return "Still with me? Hold ENTER to skip ahead.";
}
const LAUNCH_LINE: string = "Flight school, Corsair. Quick check before the real thing.";
// (portrait: the hello waits for ticket 01 and gives way to its warning, which must land before the first stack)
const LAUNCH_RINGS_P: string = "Rocks hurt, Corsair! Thread the rings between them.";
const SKIM_LINE: string = "Low and fast! Skimming doubles your score.";

// Session only (like scoring's sessionBest): the school ran to its cut.
let trainedFlag: bool = false;
export function trained(): bool {
    return trainedFlag;
}
export function markTrained(): void {
    trainedFlag = true;
}

// What the director reads and calls each frame (the core refreshes it).
export abstract class Env {
    p: Player;
    W: Weapons;
    E: World? = null;
    c: Ctx? = null;
    F: Fx;
    pops: Popups;
    inp: Input;
    g: Bag? = null;
    h: Bag? = null;
    mode: string = "keyboard"; // control mode
    portrait: bool = false; // Main's portrait group (aspect < 1)
    bot: bool = false; // debugTraining + autopilot
    state: string = "";
    rolled: bool = false; // a barrel roll started this frame
    deflects: f64 = 0; // sc.deflects
    bombs: f64 = 0;
    sting: string = "";
    stingT: f64 = 0;
    constructor(p: Player, W: Weapons, F: Fx, pops: Popups, inp: Input) {
        this.p = p;
        this.W = W;
        this.F = F;
        this.pops = pops;
        this.inp = inp;
    }
    // vol: NaN = nil
    abstract sfx(name: string, vol: f64): void;
    // mood: null = nil
    abstract comm(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64): void;
    abstract armBomb(): void; // bombs = max(bombs, 1), bombCd = 0, syncBombs
    abstract card(title: string, sub: string): void; // the certificate sting
    abstract cut(): void; // the handoff (calls finish)
}

// Luau Orb, keyed by its bullet
class Orb {
    b: Bullet;
    d0: f64 = 0;
    age: f64 = 0;
    seen: f64 = 0;
    now: bool = false;
    constructor(b: Bullet) {
        this.b = b;
    }
}
// s, x: rail place; t: s since it rose (or sank: sink); the chunk rides in scenery's list while it lives
class Stack {
    s: f64 = 0;
    x: f64 = 0;
    t: f64 = 0;
    sink: bool = false;
    chunk: Chunk;
    constructor(s: f64, x: f64, chunk: Chunk) {
        this.s = s;
        this.x = x;
        this.chunk = chunk;
    }
}

export class School {
    active: bool = false; // startLaunch(true) .. the cut
    plan: Array<f64> = [0.0]; // LESSONS index per row (all 8 in every mode), 1-based
    rows: Array<string> = [""]; // TrainRowState per row, 1-based
    idx: f64 = 0; // row on the ticket (0 before drill 1)
    lesson: string = "none"; // its key ('none' before drill 1)
    phase: string = "none";
    goT: f64 = -1; // real s since GO (-1 before)
    launchT: f64 = -1; // real s since startLaunch (-1 none)
    towerSaid: bool = false;
    age: f64 = 0; // updates since begin (the launch press never skips)
    frame: f64 = 0;
    t: f64 = 0; // real s since show
    lt: f64 = -1; // real s since LAND (-1 before)
    hintAt: f64 = 0;
    demoAt: f64 = 0;
    autoAt: f64 = 0;
    autoBase: f64 = 0; // autoAt at show (the governor's)
    waitTo: f64 = 0; // drill 01: no auto before this while its rings ahead can still finish it
    hinted: bool = false;
    result: string = ""; // '' | 'pass' | 'auto'
    gapT: f64 = -1; // s until the next ticket (-1 none)
    postT: f64 = -1; // deflect: s the drone waits for its returned orb (-1 none)
    popT: f64 = -1; // deflect: pop the drone at 0 (-1 none)
    n: f64 = 0;
    need: f64 = 0;
    acc: f64 = 0;
    fresh: bool = false;
    misses: f64 = 0;
    orbsDone: f64 = 0;
    setB: bool = false;
    set: f64 = 0; // ring tag of the drill's set
    setA: f64 = 0; // drill 01: set A's tag (its rings count on after set B)
    tagN: f64 = 0;
    deflects0: f64 = 0;
    bombs0: f64 = 0;
    prevLocks: f64 = 0;
    peakLocks: f64 = 0; // the most locks held while charging this drill (the bot's demo nova passes on them)
    wasCharging: bool = false;
    pops: f64 = 0;
    respawns: f64 = 0;
    droneT: f64 = -1; // deflect: s until a shot-down lobber is replaced (-1 none)
    demo: f64 = 0; // real s left of the demo (0 none)
    demoAge: f64 = 0;
    demoEdge: bool = false; // one-shot input pending (roll, bomb)
    demoRoll: bool = false; // inject rolled this frame
    demoRan: bool = false;
    demoV0: f64 = -1; // W.volley before the demo (-1 none): its volleys are (v0, v1]
    demoV1: f64 = -1;
    refill: f64 = 0; // fire: targets the demo popped, to replace
    skipK: f64 = 0;
    skipFresh: bool = false;
    skipQueued: bool = false;
    skipped: bool = false;
    cardT: f64 = -1; // s until the card (-1 none)
    carded: bool = false;
    cardAge: f64 = 0;
    cutDone: bool = false;
    tail: bool = false; // after the cut, until the card ends (controls off)
    nudgeT: f64 = 0;
    nudged: bool = false;
    anyInput: bool = false; // the player touched anything since drill 1
    skimTipped: bool = false;
    slow: bool = false; // deflect coach: game time eases to SLOW
    nowT: f64 = 0;
    coach: bool = false;
    orbs: Array<Orb> = new Array<Orb>(1); // 1-based
    timing: f64 = 0;
    drone: Enemy? = null;
    mode: string = "";
    press: bool = false;
    sx: f64 = 0;
    sy: f64 = 0;
    progress: f64 = 0;
    tally: string = "";
    rings: Rings = rings.fromSpecs(new Array<Spec>(1), null);
    bot: bool = false;
    certDirty: bool = false;
    firstRow: f64 = 1; // the drill the school opens on (debugTrainStep)
    anchor: f64 = 0; // drill 01: p.s at its show (the slalom and set A hang off it)
    stacks: Array<Stack> = new Array<Stack>(1); // drill 01's sea stacks (rising, standing, sinking), 1-based
    stackQ: Array<Array<f64>> = new Array<Array<f64>>(1); // SLALOM rows still to build (one a frame), 1-based
    walls: f64 = 0; // p.wallHits seen (a new one is a scrape)
    chipT: f64 = 0; // s until the chipped pip is back (0 none)
    chipLow: f64 = 1; // the shield the scrape left
    chipTo: f64 = 1; // the shield it refills to
    lineT: f64 = 0; // s the card has waited for the last line
    flown: bool = false; // drill 01: he has steered since its show
    sideT: f64 = HUGE; // drill 01: s since he last steered across the lane (HUGE: not yet)
    settled: bool = false; // drill 01: the hands-off settle moved him, and he has not steered across since
    said: string = ""; // the ticket's line ('' none: the nudge took over)
    saidT: f64 = 0; // s since it was queued
    holdT: f64 = 0; // s the next ticket has waited for it
}

export function create(): School {
    return new School();
}

// begin: every field of a fresh school (Luau: `for k, v in M.new() do S[k] = v end`; its nil fields are not
// copied: drone keeps its value)
function copyFresh(S: School, f: School): void {
    S.active = f.active; S.plan = f.plan; S.rows = f.rows; S.idx = f.idx; S.lesson = f.lesson; S.phase = f.phase;
    S.goT = f.goT; S.launchT = f.launchT; S.towerSaid = f.towerSaid; S.age = f.age; S.frame = f.frame;
    S.t = f.t; S.lt = f.lt; S.hintAt = f.hintAt; S.demoAt = f.demoAt; S.autoAt = f.autoAt; S.autoBase = f.autoBase;
    S.waitTo = f.waitTo; S.hinted = f.hinted; S.result = f.result;
    S.gapT = f.gapT; S.postT = f.postT; S.popT = f.popT; S.n = f.n; S.need = f.need; S.acc = f.acc; S.fresh = f.fresh;
    S.misses = f.misses; S.orbsDone = f.orbsDone;
    S.setB = f.setB; S.set = f.set; S.setA = f.setA; S.tagN = f.tagN; S.deflects0 = f.deflects0; S.bombs0 = f.bombs0;
    S.prevLocks = f.prevLocks; S.peakLocks = f.peakLocks; S.wasCharging = f.wasCharging;
    S.pops = f.pops; S.respawns = f.respawns; S.droneT = f.droneT; S.demo = f.demo; S.demoAge = f.demoAge;
    S.demoEdge = f.demoEdge; S.demoRoll = f.demoRoll; S.demoRan = f.demoRan;
    S.demoV0 = f.demoV0; S.demoV1 = f.demoV1; S.refill = f.refill;
    S.skipK = f.skipK; S.skipFresh = f.skipFresh; S.skipQueued = f.skipQueued; S.skipped = f.skipped;
    S.cardT = f.cardT; S.carded = f.carded; S.cardAge = f.cardAge; S.cutDone = f.cutDone; S.tail = f.tail;
    S.nudgeT = f.nudgeT; S.nudged = f.nudged; S.anyInput = f.anyInput; S.skimTipped = f.skimTipped;
    S.slow = f.slow; S.nowT = f.nowT; S.coach = f.coach; S.orbs = f.orbs; S.timing = f.timing;
    S.mode = f.mode; S.press = f.press; S.sx = f.sx; S.sy = f.sy; S.progress = f.progress; S.tally = f.tally;
    S.rings = f.rings; S.bot = f.bot; S.certDirty = f.certDirty; S.firstRow = f.firstRow;
    S.anchor = f.anchor; S.stacks = f.stacks; S.stackQ = f.stackQ; S.walls = f.walls; S.chipT = f.chipT;
    S.chipLow = f.chipLow; S.chipTo = f.chipTo; S.lineT = f.lineT;
    S.said = f.said; S.saidT = f.saidT; S.holdT = f.holdT; S.flown = f.flown; S.sideT = f.sideT; S.settled = f.settled;
}

function N(v: f64): FormatArg {
    return FormatArg.number(v);
}
function T(v: string): FormatArg {
    return FormatArg.string(v);
}

function log(S: School, env: Env, cause: string): void {
    if (LOG) {
        console.log(format("[train %6.2f s %7.1f m] %-8s %-5s %s", [N(S.goT), N(env.p.s), T(S.lesson), T(S.phase), T(cause)]));
    }
}

function setPhase(S: School, env: Env, ph: string, cause: string): void {
    if (S.phase != ph) {
        S.phase = ph;
        log(S, env, cause);
    }
}

// S.plan[S.idx] (Luau nil past the plan)
function lessonOf(S: School): Lesson? {
    let i = S.idx;
    if (i >= 1 && i < <f64>S.plan.length && i == Math.floor(i)) return LESSONS[<i32>S.plan[<i32>i]];
    return null;
}

// VM ------------------------------------------------------------------------------

function q(v: f64, step: f64): f64 {
    return Math.floor(v / step + 0.5) * step;
}

const certLabels: Array<string> = [""]; // the plan's row labels (rebuilt when certDirty), 1-based

function writeVm(S: School, env: Env): void {
    let g = env.g;
    if (g != null) {
        vmx.optSetBool(g, "trainActive", S.active);
        vmx.optEnumOrString(g, "trainLesson", S.lesson);
        vmx.optEnumOrString(g, "trainPhase", S.phase);
        vmx.optSetNum(g, "trainIndex", S.idx);
        vmx.optSetNum(g, "trainTotal", <f64>(S.plan.length - 1));
        vmx.optSetNum(g, "trainProgress", q(mathx.saturate(S.progress), 0.02));
        vmx.optSetStr(g, "trainTally", S.tally);
        vmx.optSetBool(g, "trainPress", S.press);
        vmx.optSetNum(g, "trainSX", q(S.sx, 0.05));
        vmx.optSetNum(g, "trainSY", q(S.sy, 0.05));
        vmx.optSetBool(g, "trainDemo", S.demo > 0);
        vmx.optSetNum(g, "trainTiming", q(S.timing, 0.02));
        vmx.optSetNum(g, "trainSkipK", q(S.skipK, 0.02));
        vmx.optSetBool(g, "trainNudge", S.nudgeT > 0);
        vmx.optSetBool(g, "trainSkipped", S.skipped);
        if (S.certDirty) {
            certLabels.length = 1;
            for (let i = 1; i < S.plan.length; i++) certLabels.push(LESSONS[<i32>S.plan[i]].label);
        }
        vmx.syncTrainCert(g, certLabels, S.rows, S.certDirty);
        S.certDirty = false;
    }
    let h = env.h;
    if (h != null) {
        vmx.optSetBool(h, "trainActive", S.active);
        let L = lessonOf(S);
        vmx.optEnumOrString(h, "trainFocus", S.active && L != null && S.result == "" && S.cardT < 0 && !S.carded ? L.focus : "none");
    }
}

// Drill 01's sea stacks -----------------------------------------------------------
// The mission's sea-stack rock (cliffs.headland, scenery's recipe) in a chunk of its own that rides at the end of
// scenery's chunk list while it lives: the core draws it and the pilot hits it (scenery.collide) like the
// mission's. It rises out of the sea (the instance's up axis 0 -> 1) and sinks the same way, its collider gone
// first.

let stackB: Builder? = null;
const NO_BOUNDS: Bounds = coll.bounds(new Array<Collider>(1));

// (scenery's cached list: the one the core draws and collides with)
function chunkList(): Array<Chunk> {
    return scenery.build();
}

function buildStack(S: School, env: Env, row: Array<f64>): void {
    let s = S.anchor + row[1], x = row[2], rad = row[3], h = row[4], seed = row[5];
    let wp = level.world(s, x, 0);
    let la = mathx.hash(seed, 1.7) * mathx.TAU;
    let lm = rad * (0.2 + 0.35 * mathx.hash(seed, 2.9));
    let spec = new HeadSpec();
    spec.x = <f64>wp.x;
    spec.z = <f64>wp.z;
    spec.yaw = seed * 0.91;
    spec.rx = rad;
    spec.rz = rad * (0.7 + 0.25 * mathx.hash(seed, 4.1));
    spec.h = h;
    spec.seed = seed;
    spec.look = cliffs.COAST_WARM;
    spec.leanX = Math.cos(la) * lm;
    spec.leanZ = Math.sin(la) * lm;
    spec.cols = 16;
    spec.rough = 0.3;
    spec.taper = 0.24;
    spec.bulge = -0.06;
    spec.lip = 0.08;
    spec.dome = rad * 0.3;
    spec.tip = 0.2;
    spec.skew = (mathx.hash(seed, 6.1) - 0.5) * 0.3;
    spec.drape = lmin(3, h * 0.12);
    spec.crack = 0.4;
    spec.spurs = 0.3;
    spec.fracture = 1.5;
    spec.tier = 0.35 + 0.3 * mathx.hash(seed, 7.7);
    spec.boulders = 6;
    spec.tufts = 2;
    spec.rowH = lmax(2.6, h / 9);
    spec.detail = 1;
    let b0 = stackB;
    let b = b0 != null ? b0 : meshgen.create(16384);
    stackB = b;
    meshgen.reset(b);
    let cols = new Array<Collider>(1);
    let t0 = clock();
    cliffs.headland(b, spec, cols);
    let batch = gpu.batch("school_stack", gpu.uploadMesh(b), 1, true, true);
    gpu.addIdentity(batch);
    batch.df[5] = <f32>0.02; // (byte 20; flat on the sea: stacksStep raises it)
    let ch = new Chunk(batch, cols, coll.bounds(cols));
    ch.s0 = -1e9;
    ch.s1 = 1e9;
    ch.gs0 = s;
    ch.gs1 = s;
    ch.verts = b.vcount;
    ch.name = "school_stack";
    ch.ready = true;
    ch.readyT = -HUGE;
    let list = chunkList();
    list.push(ch);
    S.stacks.push(new Stack(s, x, ch));
    fx.splash(env.F, <f64>wp.x, <f64>wp.z, 1.6);
    fx.waterRing(env.F, <f64>wp.x, <f64>wp.z, 2.4);
    if (LOG) {
        log(S, env, format("stack at %.0f m x %.1f (%d verts, %.1f ms; %d chunks)", [N(s), N(x), N(<f64>b.vcount), N((clock() - t0) * 1000), N(<f64>(list.length - 1))]));
    }
}

function dropStack(st: Stack): void {
    let list = chunkList();
    let i = list.indexOf(st.chunk);
    if (i >= 1) list.splice(i, 1);
}

// Stack `i`'s rock across the lane between heights ya and yb (rail x: lo, hi; lo > hi before it is built).
// returns lo; REACH_HI = hi
let REACH_HI: f64 = 0;
function stackReach(S: School, i: i32, ya: f64, yb: f64): f64 {
    let s = S.anchor + SLALOM[i][1];
    let lo = HUGE, hi = -HUGE;
    let sts = S.stacks;
    for (let j = 1; j < sts.length; j++) {
        let st = sts[j];
        if (Math.abs(st.s - s) < 0.5 && !st.sink) {
            let o = level.world(s, 0, 0);
            let rt = level.world(s, 1, 0) - o;
            let cs = st.chunk.colliders;
            for (let k = 1; k < cs.length; k++) {
                let c = cs[k];
                if (c.kind == 3) {
                    coll.span(c, <f64>o.x, <f64>o.z, <f64>rt.x, <f64>rt.z, ya, yb);
                    lo = lmin(lo, coll.SPAN_LO);
                    hi = lmax(hi, coll.SPAN_HI);
                }
            }
        }
    }
    REACH_HI = hi;
    return lo;
}

// Rail s past the last stack: drill 01 passes from here on.
function slalomEnd(S: School): f64 {
    return S.anchor + SLALOM[SLALOM.length - 1][1] + PAST;
}

// Stacks further than SINK_AHEAD sink at once (all: `all`); the rest stand until passed.
function sinkStacks(S: School, env: Env, all: bool): void {
    S.stackQ.length = 1;
    let sts = S.stacks;
    for (let i = 1; i < sts.length; i++) {
        let st = sts[i];
        if (!st.sink && (all || st.s > env.p.s + SINK_AHEAD)) {
            st.sink = true;
            st.t = 0;
            st.chunk.colliders = new Array<Collider>(1);
            st.chunk.bounds = NO_BOUNDS;
            let wp = level.world(st.s, st.x, 0);
            fx.splash(env.F, <f64>wp.x, <f64>wp.z, 1.2);
        }
    }
}

function clearStacks(S: School): void {
    let sts = S.stacks;
    for (let i = 1; i < sts.length; i++) dropStack(sts[i]);
    sts.length = 1;
    S.stackQ.length = 1;
}

// Every unpaused frame: build one queued stack; rise / sink; passed ones go.
function stacksStep(S: School, env: Env, rdt: f64): void {
    if (S.stackQ.length > 1) {
        let row = S.stackQ[1];
        S.stackQ.splice(1, 1);
        buildStack(S, env, row);
        if (S.stackQ.length == 1) stackB = null; // (the scratch goes with the last one)
    }
    let sts = S.stacks;
    for (let i = sts.length - 1; i >= 1; i--) {
        let st = sts[i];
        st.t += rdt;
        let u = mathx.saturate(st.t / GROW);
        let k = st.sink ? 1 - u * u : 1 - Math.pow(1 - u, 3);
        st.chunk.batch.df[5] = <f32>lmax(0.02, k);
        if ((st.sink && u >= 1) || st.s < env.p.s - 30) {
            dropStack(st);
            sts.splice(i, 1);
        }
    }
}

// Practice set-ups ------------------------------------------------------------------

function clearDrill(S: School, env: Env, pop: bool): void {
    let E = env.E, c = env.c;
    if (E != null && c != null) enemies.clearPractice(E, c, pop);
    S.drone = null;
    S.orbs.length = 1;
    rings.prune(S.rings, env.p.s, S.set);
    if (S.setA > 0 && S.setA != S.set) rings.prune(S.rings, env.p.s, S.setA);
    sinkStacks(S, env, false);
    S.slow = false;
    S.timing = 0;
}

function spawnRingSet(S: School, env: Env, b: bool): void {
    let p = env.p;
    let y0 = mathx.clamp(p.y, 5, 9);
    S.tagN += 1;
    S.set = S.tagN;
    let specs = new Array<Spec>(1);
    if (b) {
        let s0 = p.s + B_S0;
        let l = S.rings.list;
        for (let i = 1; i < l.length; i++) {
            let r = l[i];
            if (r.tag == S.setA && !r.taken && !r.missed) s0 = lmax(s0, r.s + B_DS);
        }
        // (where he coasts to with the stick centred: hands off never threads one)
        let line = p.x + p.vx / COAST;
        let side = line > 0 ? -B_X : B_X;
        for (let i = 0; i <= 3; i++) {
            let d = i % 2 == 0 ? side : -side;
            let x = mathx.clamp(Math.abs(line + d) > LANE_X ? line - d : line + d, -LANE_X, LANE_X);
            specs.push(new Spec(s0 + B_DS * <f64>i, x, mathx.clamp(y0 + <f64>(i % 3), 3, 20), "gold", S.set));
        }
        // the count carries on (the tally never drops): 2 more at most
        S.need = S.n + lmin(2, S.need - S.n);
    } else {
        // (the slalom: one in open water, then one in each stack's gap, GAP_C off its face at the ring's height)
        for (let j = 1; j < RINGS_A.length; j++) {
            let o = RINGS_A[j];
            let y = mathx.clamp(y0 + o[3], 3, 20);
            let x = o[2], i = <i32>o[4];
            if (i > 0) {
                let row = SLALOM[i];
                let lo = stackReach(S, i, y - 2, y + 2);
                let hi = REACH_HI;
                if (lo > hi) {
                    lo = row[2] - row[3];
                    hi = row[2] + row[3];
                }
                let face = row[2] > 0 ? lo : hi;
                x = row[2] > 0 ? face - GAP_C : face + GAP_C;
            }
            specs.push(new Spec(S.anchor + o[1], x, y, "gold", S.set));
        }
        S.need = 3;
        S.n = 0;
        S.setA = S.set;
    }
    rings.append(S.rings, specs);
}

function practice(env: Env, relS: f64, x: f64, y: f64, opts: PracticeOpts?): Enemy? {
    let E = env.E, c = env.c;
    if (E != null && c != null) return enemies.practice(E, c, "drone", relS, x, y, opts);
    return null;
}

const CHARGE_AT: StaticArray<f64> = [-11, 4, -4, -3, 4, 3, 11, -4];

function spawnCharge(env: Env): void {
    let y0 = mathx.clamp(env.p.y, 8, 20);
    for (let i = 0; i < CHARGE_AT.length; i += 2) {
        practice(env, 150, CHARGE_AT[i], lmax(4, y0 + CHARGE_AT[i + 1]), null);
    }
}

function lobber(env: Env, rise: bool): Enemy? {
    let o = new PracticeOpts();
    o.rise = rise;
    let lob = new PracticeLob();
    lob.first = 1.0;
    lob.every = 2.0;
    lob.speed = 26;
    o.lob = lob;
    return practice(env, 120, 0, mathx.clamp(env.p.y + 1, 4, 20), o);
}

function hpOpts(hp: f64): PracticeOpts {
    let o = new PracticeOpts();
    o.hp = hp;
    return o;
}

const FIRE_X: StaticArray<f64> = [-9, 0, 9];
const BOMB_Y: StaticArray<f64> = [6, 11, 8, 14, 7, 12];

function setUp(S: School, env: Env, L: Lesson): void {
    let p = env.p;
    if (L.key == "rings") {
        spawnRingSet(S, env, false);
    } else if (L.key == "boost") {
        p.boost = lmax(p.boost, 70);
        p.heat = 0;
        p.overheat = 0;
    } else if (L.key == "brake") {
        // the silver trio is the drill's own set: it clears at drill end (4.1)
        S.tagN += 1;
        S.set = S.tagN;
        let trio = new Array<Spec>(1);
        trio.push(new Spec(p.s + 170, -6, mathx.clamp(p.y, 3, 20), "silver", S.set));
        trio.push(new Spec(p.s + 195, 6, mathx.clamp(p.y + 2, 3, 20), "silver", S.set));
        trio.push(new Spec(p.s + 220, -6, mathx.clamp(p.y, 3, 20), "silver", S.set));
        rings.append(S.rings, trio);
    } else if (L.key == "deflect") {
        S.drone = lobber(env, false);
        S.deflects0 = env.deflects;
    } else if (L.key == "fire") {
        let y = mathx.clamp(p.y, 5, 20);
        for (let i = 0; i < FIRE_X.length; i++) practice(env, 110, FIRE_X[i], y, hpOpts(2));
    } else if (L.key == "charge") {
        spawnCharge(env);
    } else if (L.key == "bomb") {
        for (let i = 0; i <= 5; i++) {
            let o = new PracticeOpts();
            o.rise = true;
            practice(env, 100 + <f64>i * 8, -18 + <f64>i * 7.2, BOMB_Y[i], o);
        }
        env.armBomb();
        S.bombs0 = lmax(env.bombs, 1);
    }
}

// Flow ------------------------------------------------------------------------------

function show(S: School, env: Env, row: f64): void {
    S.idx = row;
    let L = lessonOf(S);
    if (L == null) return;
    S.lesson = L.key;
    S.rows[<i32>row] = "current";
    if (L.key == "rings") {
        // the slalom rises as the ticket lands (a stack a frame); set A hangs off the same s
        S.anchor = env.p.s;
        clearStacks(S);
        for (let i = 1; i < SLALOM.length; i++) S.stackQ.push(SLALOM[i]);
    }
    S.t = 0;
    S.lt = -1;
    S.result = "";
    S.hinted = false;
    S.gapT = -1;
    S.n = 0; S.need = 0; S.acc = 0; S.fresh = false; S.misses = 0; S.orbsDone = 0;
    S.setB = false; S.setA = 0; S.waitTo = 0; S.flown = false; S.sideT = HUGE; S.settled = false;
    S.pops = 0; S.respawns = 0; S.droneT = -1;
    S.demo = 0; S.demoAge = 0; S.demoEdge = false; S.demoRan = false;
    S.demoV0 = -1; S.demoV1 = -1; S.refill = 0;
    S.coach = false; S.slow = false; S.nowT = 0;
    S.wasCharging = false;
    S.peakLocks = 0;
    S.progress = 0;
    S.tally = "";
    S.press = false; // (read for the new lesson from the next frame)
    S.orbs.length = 1;
    // governor: T' = max(3.5, T x budget / remaining T); hint and demo scale with it
    let nplan = <f64>(S.plan.length - 1);
    let rem = 0.0;
    for (let j = <i32>row; j < S.plan.length; j++) rem += LESSONS[<i32>S.plan[j]].auto;
    let budget = BUDGET - lmax(0, S.goT) - (nplan - row + 1) * (GAP + LAND);
    let k = lmin(1, lmax(3.5, L.auto * budget / lmax(rem, 1)) / L.auto);
    S.hintAt = L.hint >= 0 ? L.hint * k : HUGE;
    S.demoAt = L.demo >= 0 ? L.demo * k : HUGE;
    S.autoAt = L.auto * k;
    S.autoBase = S.autoAt;
    if (S.bot && L.demo >= 0) S.demoAt = BOT_DEMO;
    setPhase(S, env, "show", LOG ? format("ticket %d (k %.2f)", [N(row), N(k)]) : "");
    env.sfx("ticket", 0.8);
    // (right after the nudge line the ticket's line waits for it: prio 3)
    let line = L.line;
    if (S.launchT >= 0 && !S.towerSaid) {
        // portrait: the launch hello waited for the countdown to clear (its comms slot sits on the dial); on
        // ticket 01 the rock warning opens
        S.towerSaid = true;
        line = L.key == "rings" ? LAUNCH_RINGS_P : LAUNCH_LINE + " " + line;
        log(S, env, "launch line with ticket 01 (portrait)");
    }
    // (the last line has no 3.2 s floor: the card waits for it)
    env.comm(L.who, speakerOf(L.who), line, row == nplan ? 0 : 3.2, L.mood, S.nudgeT > 0 ? 3 : 4);
    S.said = line;
    S.saidT = 0;
    S.holdT = 0;
}

function result(S: School, env: Env, how: string, cause: string): void {
    if (S.result != "") return;
    S.result = how;
    S.rows[<i32>S.idx] = how == "pass" ? "done" : "assisted";
    setPhase(S, env, how, cause);
    env.sfx("stamp", 0.9);
    S.demo = 0;
    S.demoEdge = false;
    S.slow = false;
    S.gapT = GAP;
    S.progress = how == "pass" ? 1 : S.progress;
    let L = lessonOf(S);
    // a pass reads as one on the tally under its stamp: the bot's demo passes left '0 / 2', '0 / 3', '0 / 4' (QA FS-5)
    if (how == "pass" && L != null) {
        if (L.key == "roll") {
            S.tally = "2 / 2";
        } else if (L.key == "fire") {
            S.tally = "3 / 3";
        } else if (L.key == "charge") {
            S.tally = "2 / 2";
        }
    }
    let d = S.drone;
    if (L != null && L.key == "deflect" && how == "pass" && d != null) {
        // the returned orb pops its lobber (the director does 0.3 s after a miss); no orb after RETURNED!
        d.lobEvery = 0;
        S.postT = 1.5;
    } else {
        clearDrill(S, env, true);
    }
    // idle nudge (once): drills 1 and 2 both auto with no input at all
    if (!S.nudged && S.idx == 2 && S.rows[1] == "assisted" && S.rows[2] == "assisted" && !S.anyInput) {
        S.nudged = true;
        S.nudgeT = NUDGE_T;
        env.comm("tower", "LIGHTHOUSE", nudgeOf(env.mode), 3.5, "neutral", 4);
        S.said = "";
        log(S, env, "nudge");
    }
}

function doneCount(S: School): f64 {
    let n = 0.0;
    for (let i = 1; i < S.rows.length; i++) {
        if (S.rows[i] == "done") n += 1;
    }
    return n;
}

function fireCard(S: School, env: Env): void {
    S.cardT = -1;
    S.carded = true;
    S.cardAge = 0;
    let nplan = <f64>(S.plan.length - 1);
    S.idx = nplan + 1;
    // (training.md 4.4) graduated only on at least half the drills passed by hand: a mostly assisted (hands-off)
    // school is CLEARED TO FLY with its honest count and the ink stamp (QA FS-3: 0 / 8 DRILLS graduated)
    let done = doneCount(S);
    let cleared = S.skipped || done * 2 < nplan;
    let title = cleared ? "CLEARED TO FLY" : "TRAINING COMPLETE";
    let sub = S.skipped ? "TRAINING SKIPPED" : format("%d / %d DRILLS", [N(done), N(nplan)]);
    S.demo = 0;
    S.slow = false;
    S.timing = 0;
    log(S, env, "card: " + title + " / " + sub);
    env.card(title, sub);
}

// rows never reached go 'skipped' (the current one too when `current`)
function skipRest(S: School, current: bool): void {
    let rows = S.rows;
    for (let i = 1; i < rows.length; i++) {
        let r = rows[i];
        if (r == "pending" || (current && r == "current")) rows[i] = "skipped";
    }
}

function doSkip(S: School, env: Env, cause: string): void {
    if (S.skipped || S.carded) return;
    if (S.idx >= <f64>(S.plan.length - 1) && S.result != "") {
        // every drill has its result: nothing is left to skip (the card, as earned, without the last line's wait)
        S.lineT = LINE_WAIT;
        S.skipK = 0;
        log(S, env, cause + ": every drill done");
        return;
    }
    S.skipped = true;
    S.skipQueued = false;
    S.skipK = 1;
    skipRest(S, true);
    setPhase(S, env, "skip", cause);
    clearDrill(S, env, true);
    S.demo = 0;
    S.demoEdge = false;
    S.result = "skip";
    S.gapT = -1;
    S.postT = -1;
    S.popT = -1;
    S.cardT = SKIP_CARD;
}

// Pause > SKIP TRAINING (instant; from the countdown queued to GO + 0.45 s).
export function skipNow(S: School, env: Env): void {
    if (!S.active || S.skipped || S.carded) return;
    if (S.goT < SKIP_LATE) {
        S.skipQueued = true;
        S.skipK = 1;
        log(S, env, "skip queued (pause)");
    } else {
        doSkip(S, env, "skip (pause)");
    }
}

function hardStop(S: School, env: Env, cause: string): void {
    if (S.idx >= 1 && S.result == "") result(S, env, "auto", cause);
    skipRest(S, false);
    S.cardT = lmax(0.05, S.gapT);
    S.gapT = -1;
    log(S, env, cause);
}

// The SKIP tab's hold (UI-written): a press that outlived the tab (the skip moved it off) never lets go.
function clearSkipHeld(env: Env): void {
    let g = env.g;
    if (g != null) vmx.optSetBoolLive(g, "trainSkipHeld", false);
}

// API -------------------------------------------------------------------------------

// init: the certificate's rows exist from the first frame (vm.syncTrainCert).
export function prime(g: Bag): void {
    certLabels.length = 1;
    for (let i = 1; i < LESSONS.length; i++) certLabels.push(LESSONS[i].label);
    vmx.syncTrainCert(g, certLabels, [""], true);
}

// The school starts (startLaunch(true), or a debug start on drill `step`).
export function begin(S: School, env: Env, step: f64): void {
    clearStacks(S);
    let keep = S.rings;
    copyFresh(S, new School());
    S.rings = keep;
    S.rings.list.length = 1;
    S.active = true;
    let n = LESSONS.length - 1;
    for (let i = 1; i <= n; i++) {
        S.plan.push(<f64>i);
        S.rows.push(<f64>i < step ? "skipped" : "pending");
    }
    S.idx = 0;
    S.mode = env.mode;
    S.bot = env.bot;
    S.certDirty = true;
    S.firstRow = lclamp(step, 1, <f64>n);
    S.walls = env.p.wallHits;
    if (LOG) log(S, env, format("begin (%s%s, drill %d)", [T(env.mode), T(env.bot ? ", bot" : ""), N(step)]));
    writeVm(S, env);
    clearSkipHeld(env);
}

// GO: the drill clock starts (the countdown blast, or a debug start at once).
export function go(S: School): void {
    if (S.active && S.goT < 0) S.goT = 0;
}

// startLaunch(true): the tower line at +0.6 s.
export function launch(S: School): void {
    S.launchT = 0;
}

// The active bolt that just hit (x, y, z): the nearest to it along its step.
function hitter(W: Weapons, x: f64, y: f64, z: f64): Bolt? {
    let best: Bolt? = null;
    let bestD = 64.0; // (8 m)^2
    let bs = W.bolts;
    for (let i = 1; i < bs.length; i++) {
        let b = bs[i];
        if (b.active) {
            let dx = b.vx * 0.05, dy = b.vy * 0.05, dz = b.vz * 0.05;
            let mx = x - b.x, my = y - b.y, mz = z - b.z;
            let l2 = dx * dx + dy * dy + dz * dz;
            let t = l2 > 0 ? lclamp((mx * dx + my * dy + mz * dz) / l2, 0, 1) : 0.0;
            let cx = mx - dx * t, cy = my - dy * t, cz = mz - dz * t;
            let d = cx * cx + cy * cy + cz * cz;
            if (d < bestD) {
                best = b;
                bestD = d;
            }
        }
    }
    return best;
}

// ctx.onPractice: a practice target popped at (x, y, z). A pop by the demo's own bolts never counts (3.2, bot mode
// aside): the pilot gets a new target.
export function onPop(S: School, W: Weapons, x: f64, y: f64, z: f64): void {
    if (!S.active) return;
    if (!S.bot && S.demoV0 >= 0) {
        let b = hitter(W, x, y, z);
        if (b != null && b.volley > S.demoV0 && (b.volley <= S.demoV1 || S.demo > 0)) {
            S.refill += 1;
            return;
        }
    }
    S.pops += 1;
}

// readControls: the flight computer's demo (never counts, except in bot mode).
export function inject(S: School, c: Controls): void {
    S.demoRoll = false;
    if (!S.active || S.demo <= 0) return;
    let L = lessonOf(S);
    if (L == null) return;
    let k = L.key, a = S.demoAge;
    if (k == "boost") {
        c.boost = a < L.hold;
        c.brake = false;
    } else if (k == "brake") {
        c.brake = a < L.hold;
        c.boost = false;
    } else if (k == "roll") {
        if (S.demoEdge) {
            c.rollR = true;
            S.demoRoll = true;
            S.demoEdge = false;
        }
    } else if (k == "fire") {
        c.fire = a < L.hold;
    } else if (k == "charge") {
        c.fire = a < L.hold;
    } else if (k == "bomb") {
        if (S.demoEdge) {
            c.bomb = true;
            S.demoEdge = false;
        }
    }
}

// simulate: practice rings (update, collect effects; no scoring, no chain).
export function ringsStep(S: School, env: Env, s0: f64, dt: f64): void {
    let Rg = S.rings;
    let p = env.p;
    rings.update(Rg, s0, p.s, p.x, p.y, dt);
    let col = Rg.collected;
    for (let i = 1; i < col.length; i++) {
        let ring = col[i];
        let text = "RING";
        if (ring.kind == "silver") {
            p.shield = lmin(1, p.shield + 0.25);
            env.sfx("ring_silver", 0.9);
            text = "SILVER!";
        } else {
            p.boost = lmin(100, p.boost + 25);
            env.sfx("ring", 0.9);
            if (S.lesson == "rings" && (ring.tag == S.set || ring.tag == S.setA) && S.result == ""
                && (S.bot || (S.flown && ((p.hitT >= SHOVE_T && !S.settled) || S.sideT <= SIDE_T)))) {
                S.n += 1;
                // (a ring past the need, before the last stack: a plain RING)
                text = S.n <= S.need ? format("RING %d/%d", [N(S.n), N(S.need)]) : text;
            }
        }
        let rp = ring.pos + ring.fwd * <f32>12;
        weapons.flare(env.W, <f64>rp.x, <f64>rp.y, <f64>rp.z, 3.4, 14, 0.4, ring.kind == "silver" ? 0.9 : 1.0, 0.85, ring.kind == "gold" ? 0.35 : 1, 2);
        fx.sparks(env.F, <f64>rp.x, <f64>rp.y, <f64>rp.z, 10, 1, 0.9, 0.45);
        let ax = p.pos + p.fwd * <f32>16 + p.up * <f32>2.4;
        let v = p.fwd * <f32>p.speed;
        popups.spawn(env.pops, text, "ring", <f64>ax.x, <f64>ax.y, <f64>ax.z, 0.9, <f64>v.x, <f64>v.y, <f64>v.z);
        let h = env.h;
        if (h != null) vmx.fire(h, "ringPulse");
    }
    if (Rg.missedCount > 0 && S.lesson == "rings" && S.result == "") S.misses += Rg.missedCount;
    rings.prune(Rg, p.s);
}

// Deflect: track the live practice orbs (misses, the approach ring, the coach).
function orbStep(S: School, env: Env, rdt: f64): void {
    let E = env.E;
    let p = env.p;
    let ppx = <f64>p.pos.x, ppy = <f64>p.pos.y, ppz = <f64>p.pos.z;
    S.frame += 1;
    let near: Bullet? = null;
    let nearD = HUGE;
    let nearRec: Orb? = null;
    let orbs = S.orbs;
    if (E != null) {
        let bs = E.bullets;
        for (let i = 1; i < bs.length; i++) {
            let b = bs[i];
            if (b.practice && !b.deflected && b.life > 0) {
                let dx = b.x - ppx, dy = b.y - ppy, dz = b.z - ppz;
                let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
                let ri = 0;
                for (let j = 1; j < orbs.length; j++) {
                    if (orbs[j].b == b) {
                        ri = j;
                        break;
                    }
                }
                let rec: Orb? = ri > 0 ? orbs[ri] : null;
                if (rec == null || b.age < rec.age) {
                    let nr = new Orb(b);
                    nr.d0 = lmax(d, 1);
                    nr.age = b.age;
                    nr.seen = S.frame;
                    if (ri > 0) orbs[ri] = nr;
                    else orbs.push(nr);
                    rec = nr;
                }
                let r = rec!;
                r.age = b.age;
                r.seen = S.frame;
                if (d < nearD) {
                    near = b;
                    nearD = d;
                    nearRec = r;
                }
            }
        }
    }
    for (let j = orbs.length - 1; j >= 1; j--) {
        let rec = orbs[j];
        if (rec.seen != S.frame) {
            orbs.splice(j, 1);
            if (!rec.b.deflected) {
                S.misses += 1;
                S.orbsDone += 1;
                if (LOG) log(S, env, format("orb missed (%d)", [N(S.misses)]));
                if (S.misses >= 2) S.coach = true;
            }
        }
    }
    S.timing = 0;
    if (near != null && nearRec != null) {
        S.timing = mathx.saturate(1 - nearD / nearRec.d0);
        // coach: a slow beat as the orb closes (from the 2nd miss)
        let pfx = <f64>p.fwd.x, pfy = <f64>p.fwd.y, pfz = <f64>p.fwd.z;
        let vx = near.vx - pfx * p.speed, vy = near.vy - pfy * p.speed, vz = near.vz - pfz * p.speed;
        let toP = -((near.x - ppx) * vx + (near.y - ppy) * vy + (near.z - ppz) * vz) / lmax(nearD, 0.01);
        let eta = nearD / lmax(toP, 1);
        if (S.coach && !nearRec.now && eta <= COACH_ETA && S.result == "") {
            nearRec.now = true;
            S.slow = true;
            S.nowT = COACH_REAL;
            setPhase(S, env, "now", LOG ? format("coach (eta %.2f)", [N(eta)]) : "");
        }
    }
    if (S.nowT > 0) {
        S.nowT -= rdt;
        if (S.nowT <= 0) {
            S.slow = false;
            if (S.phase == "now") setPhase(S, env, "hint", "coach over");
        }
    }
}

function hint(S: School, env: Env, cause: string): void {
    if (!S.hinted && S.result == "") {
        S.hinted = true;
        if (S.phase != "now") setPhase(S, env, "hint", cause);
    }
}

// Drill 01's rings still ahead (set A's and set B's): returns the count; AHEAD_LAST = the last one's s.
let AHEAD_LAST: f64 = 0;
function ringsAhead(S: School): f64 {
    let left = 0.0, last = -HUGE;
    let l = S.rings.list;
    for (let i = 1; i < l.length; i++) {
        let r = l[i];
        if ((r.tag == S.set || r.tag == S.setA) && !r.taken && !r.missed) {
            left += 1;
            last = lmax(last, r.s);
        }
    }
    AHEAD_LAST = last;
    return left;
}

// The drill's own test (after LAND).
function test(S: School, env: Env, L: Lesson, rdt: f64): void {
    let p = env.p, inp = env.inp, W = env.W;
    let k = L.key;
    let demoing = S.demo > 0;
    if (k == "rings") {
        let left = ringsAhead(S), last = AHEAD_LAST;
        if (S.n < S.need && !S.setB && (left == 0 || (S.n > 0 && S.n + left < S.need)) && p.hitT >= B_CLEAR) {
            // set A ran out short, or (a ring in: the need stays 3) can no longer finish the drill: set B, once
            S.setB = true;
            spawnRingSet(S, env, true);
            left = ringsAhead(S);
            last = AHEAD_LAST;
            if (LOG) log(S, env, format("ring set B (%d / %d)", [N(S.n), N(S.need)]));
        }
        if (S.n >= S.need && S.need > 0) {
            // his rings are in: no auto before he is past the last stack (T at most)
            S.waitTo = S.lt + (slalomEnd(S) - p.s) / lmax(p.speed, 20) + 0.3;
        } else if (S.setB && left > 0 && S.n + left >= S.need) {
            // no auto while the rings ahead can still finish it (the drill's own T at most)
            S.waitTo = S.lt + (last - p.s) / lmax(p.speed, 20) + 0.3;
        } else if (S.setB && S.waitTo > S.lt + 0.3) {
            // they no longer can: a beat, then MOVING ON
            S.waitTo = S.lt + 0.3;
        }
        S.autoAt = lmax(S.autoBase, lmin(L.auto, S.waitTo));
        if (S.misses >= 2) hint(S, env, "two misses");
        S.progress = S.need > 0 ? lmin(S.n, S.need) / S.need : 0;
        S.tally = format("%d / %d", [N(lmin(S.n, S.need)), N(lmax(S.need, 1))]);
        // (the rings in and past the last stack: a learner with 3 by stack 2 still dodges 3)
        if (S.need > 0 && S.n >= S.need && p.s >= slalomEnd(S)) result(S, env, "pass", "rings");
    } else if (k == "boost" || k == "brake") {
        let real = input.down(inp, k);
        if (input.pressed(inp, k) && !demoing) S.fresh = true;
        let on = k == "boost" ? p.boosting : p.braking;
        if (S.fresh && real && on && !demoing) S.acc += rdt;
        let need = k == "boost" ? 0.8 : 0.6;
        S.progress = S.acc / need;
        if (S.acc >= need) result(S, env, "pass", k + " held");
    } else if (k == "roll") {
        if (env.rolled && !S.demoRoll) {
            S.n += 1;
            let a = p.pos + p.fwd * <f32>14 + p.up * <f32>2.2;
            let v = p.fwd * <f32>p.speed;
            popups.spawn(env.pops, "ROLL!", "bonus", <f64>a.x, <f64>a.y, <f64>a.z, 0.9, <f64>v.x, <f64>v.y, <f64>v.z);
        }
        S.progress = S.n / 2;
        S.tally = format("%d / 2", [N(S.n)]);
        if (S.n >= 2) result(S, env, "pass", "two rolls");
    } else if (k == "deflect") {
        orbStep(S, env, rdt);
        if (S.misses >= 1) hint(S, env, "first miss");
        let d = S.drone;
        if (S.droneT < 0 && d != null && !d.alive && S.respawns < DRONE_MAX) {
            // shot down (a tap of fire, a bomb): WAIT FOR IT, and a new one rises
            S.droneT = DRONE_BACK;
            hint(S, env, "drone down");
        } else if (S.droneT >= 0) {
            S.droneT -= rdt;
            if (S.droneT < 0) {
                S.respawns += 1;
                S.drone = lobber(env, true);
                if (LOG) log(S, env, format("lobber %d", [N(S.respawns + 1)]));
            }
        }
        S.progress = S.timing;
        if (env.deflects > S.deflects0) {
            result(S, env, "pass", "returned");
        } else if (S.orbsDone >= 4) {
            result(S, env, "auto", "four orbs");
        }
    } else if (k == "fire") {
        if (S.refill > 0 && S.result == "") {
            // the demo popped one: a new target in the free lane nearest him
            S.refill -= 1;
            let E = env.E;
            let best = 0.0, bestD = HUGE;
            for (let j = 0; j < FIRE_X.length; j++) {
                let x = FIRE_X[j];
                let taken = false;
                if (E != null) {
                    let l = E.list;
                    for (let i = 1; i < l.length; i++) {
                        let e = l[i];
                        if (e.practice && e.alive && Math.abs(e.p2 - x) < 1) taken = true;
                    }
                }
                if (!taken && Math.abs(x - p.x) < bestD) {
                    best = x;
                    bestD = Math.abs(x - p.x);
                }
            }
            practice(env, 110, best, mathx.clamp(p.y, 5, 20), hpOpts(2));
        }
        S.progress = S.pops / 3;
        S.tally = format("%d / 3", [N(lmin(S.pops, 3))]);
        if (S.pops >= 3) result(S, env, "pass", "three pops");
    } else if (k == "charge") {
        if (W.firedNova && !demoing) {
            if (S.prevLocks >= 2) {
                result(S, env, "pass", LOG ? format("nova on %d locks", [N(S.prevLocks)]) : "");
            } else {
                hint(S, env, "early release");
            }
        } else if (S.wasCharging && !W.charging && !demoing && S.prevLocks < 2) {
            hint(S, env, "early release");
        }
        // (a pass keeps its full fuse and its full count; the demo's locks are the ghost's, not the pilot's: the
        // tally keeps his own count through it, QA FS-5. It counts to the drill's 2: LOCKED! over '3 / 4' read
        // unfinished, playtest 1)
        if (W.charging) S.peakLocks = lmax(S.peakLocks, W.lockCount);
        if (S.result == "") {
            S.progress = W.charging ? W.charge : 0;
            S.tally = format("%d / 2", [N(demoing ? 0 : lmin(W.lockCount, 2))]);
        } else if (S.result == "pass") {
            S.tally = "2 / 2";
        }
        // targets tapped away: a fresh set (twice at most)
        let E = env.E;
        if (E != null && S.result == "" && S.respawns < 2) {
            let alive = 0.0;
            let l = E.list;
            for (let i = 1; i < l.length; i++) {
                let e = l[i];
                if (e.practice && e.alive) alive += 1;
            }
            if (alive < 2) {
                S.respawns += 1;
                spawnCharge(env);
            }
        }
    } else if (k == "bomb") {
        if (env.bombs < S.bombs0) {
            if (demoing) {
                // the demo spent it: the pilot gets his own
                env.armBomb();
            } else {
                result(S, env, "pass", "bomb");
            }
            S.bombs0 = lmax(env.bombs, 1);
        }
        if (S.result == "") S.progress = 0;
    }
    S.prevLocks = W.lockCount;
    S.wasCharging = W.charging;
}

// The taught input, any device (live keycap).
function pressTruth(S: School, env: Env, L: Lesson?): bool {
    if (L == null) return false;
    let inp = env.inp, k = L.key;
    let demo = S.demo > 0 && S.demoAge < lmax(L.hold, 0.12);
    if (k == "rings") {
        return Math.sqrt(S.sx * S.sx + S.sy * S.sy) > 0.3;
    } else if (k == "roll" || k == "deflect") {
        return input.down(inp, "rollL") || input.down(inp, "rollR") || (inp.touch.has("roll") && inp.touch.get("roll")) || env.p.rollT > 0;
    } else if (k == "charge") {
        return input.down(inp, "fire") || demo;
    }
    return input.down(inp, k) || demo;
}

function skipStep(S: School, env: Env, rdt: f64): void {
    let inp = env.inp;
    // a fresh down edge after the school started (the launch press never counts)
    if (S.age > 0 && input.pressed(inp, "skip")) S.skipFresh = true;
    let held = input.down(inp, "skip");
    if (!held) S.skipFresh = false;
    let g = env.g;
    let ptr = g != null && vmx.optBool(g, "trainSkipHeld");
    let on = (held && S.skipFresh) || ptr;
    if (S.skipped || S.skipQueued || S.carded || S.cardT >= 0) return;
    if (on) {
        S.skipK = lmin(1, S.skipK + rdt / SKIP_FILL);
    } else {
        S.skipK = lmax(0, S.skipK - rdt * SKIP_DECAY);
    }
    if (S.skipK >= 1) {
        if (S.goT < SKIP_LATE) {
            S.skipQueued = true;
            log(S, env, "skip queued");
        } else {
            doSkip(S, env, ptr ? "skip (SKIP tab)" : "skip (hold)");
        }
    }
}

// A scrape (the core counts p.wallHits; hurt() keeps out of the school): one pip out (never under CHIP_FLOOR), the
// damage beat (no popup: the bonus chip read as a reward), and it refills after CHIP_HOLD.
function chipStep(S: School, env: Env, rdt: f64): void {
    let p = env.p;
    if (p.wallHits > S.walls) {
        if (S.chipT <= 0) S.chipTo = p.shield;
        S.chipLow = lmax(lmin(p.shield, CHIP_FLOOR), p.shield - CHIP);
        p.shield = S.chipLow;
        S.chipT = CHIP_HOLD + CHIP_FILL;
        p.flash = 1;
        let c = env.c;
        if (c != null) c.shake(1.1);
        env.sfx("damage", 0.9);
        let h = env.h;
        if (h != null) vmx.fire(h, "damage");
        if (S.lesson == "rings" && S.result == "") hint(S, env, "scrape");
        if (LOG) log(S, env, format("scrape (shield %.2f)", [N(p.shield)]));
    }
    S.walls = p.wallHits;
    if (S.chipT > 0) {
        S.chipT = lmax(0, S.chipT - rdt);
        if (S.chipT < CHIP_FILL) {
            let u = mathx.smoothstep(0, 1, 1 - S.chipT / CHIP_FILL);
            p.shield = lmax(p.shield, S.chipLow + (S.chipTo - S.chipLow) * u);
            if (S.chipT <= 0) env.sfx("ring_silver", 0.5);
        }
    }
}

// The line on air is a ticket's (prio 3+) and not yet typed out and read (the last drill's plays whole).
function lineOn(env: Env): bool {
    let c = env.c;
    if (c == null) return false;
    let left = c.commState();
    let prio = c.csPrio;
    return left > LINE_TAIL && prio >= 3;
}

// The ticket's line is on air, not yet typed out and read (a fast pass: the next line cut it, or waited behind it).
function talking(S: School, env: Env): bool {
    let c = env.c;
    if (c == null || S.said == "") return false;
    let left = c.commState();
    let age = c.csAge, prio = c.csPrio;
    // (an older line on air: the ticket's is still queued)
    if (left <= 0 || prio < 3 || age > S.saidT + 0.05) return false;
    return age < pages.typeOut(S.said, age + left) + READ_TAIL;
}

// Every unpaused launch / training frame (real seconds).
export function update(S: School, env: Env, rdt: f64): void {
    if (!S.active) return;
    let p = env.p;
    // no close calls in the school (no score: a threaded stack popped CLOSE CALL +150)
    p.grazeCd = lmax(p.grazeCd, 0.25);
    if (S.launchT >= 0) {
        S.launchT += rdt;
        // (portrait: deferred to ticket 01, off the countdown)
        if (!S.towerSaid && S.launchT >= 0.6 && !env.portrait) {
            S.towerSaid = true;
            env.comm("tower", "LIGHTHOUSE", LAUNCH_LINE, 3.2, "happy", 3);
        }
    }
    if (S.goT >= 0) S.goT += rdt;
    S.saidT += rdt;
    if (env.mode != S.mode) {
        // the plan is the same 8 drills in every mode: only the prompts change
        log(S, env, "re-plan: " + S.mode + " -> " + env.mode);
        S.mode = env.mode;
    }
    // player input seen (idle nudge)
    let sx = input.steer(env.inp);
    let sy = input.STEER_2;
    S.sx = sx;
    S.sy = sy;
    if (S.lesson == "rings") {
        let across = Math.abs(sx) > STIR;
        S.flown = S.flown || across || Math.abs(sy) > STIR;
        S.sideT = across ? 0 : S.sideT + rdt;
        S.settled = (S.settled || p.laneT > 0) && !across;
    }
    if (!S.anyInput && S.goT >= 0 && (Math.abs(sx) > 0.3 || Math.abs(sy) > 0.3 || env.inp.anyKey)) S.anyInput = true;
    if (S.nudgeT > 0) S.nudgeT = lmax(0, S.nudgeT - rdt);
    skipStep(S, env, rdt);
    stacksStep(S, env, rdt);
    chipStep(S, env, rdt);
    let L = lessonOf(S);
    // (7.1: the taught input is held now, through the stamp and the gap too)
    S.press = pressTruth(S, env, L);

    if (S.carded) {
        // the certificate holds: the cut at 0.35 s of unpaused card time
        S.cardAge += rdt;
        let t = env.sting == "training_complete" ? env.stingT : S.cardAge;
        if (!S.cutDone && t >= CUT_AT) {
            S.cutDone = true;
            log(S, env, "cut");
            env.cut();
            return;
        }
        writeVm(S, env);
        S.age += 1;
        return;
    }
    if (S.cardT >= 0) {
        S.cardT -= rdt;
        if (S.cardT <= 0) fireCard(S, env);
        writeVm(S, env);
        S.age += 1;
        return;
    }
    if (S.goT < 0) {
        writeVm(S, env);
        S.age += 1;
        return;
    }
    if (S.skipQueued && S.goT >= SKIP_LATE) {
        doSkip(S, env, "skip (queued)");
        writeVm(S, env);
        S.age += 1;
        return;
    }
    if (!S.skipped && (S.goT >= HARD_T || p.s > level.school.stop)) {
        hardStop(S, env, S.goT >= HARD_T ? "hard stop (time)" : "hard stop (lane end)");
        writeVm(S, env);
        S.age += 1;
        return;
    }
    // heat never locks out in the school
    p.heat = lmin(p.heat, HEAT_CAP);
    p.overheat = 0;
    // skim tip (once)
    if (!S.skimTipped && p.skim >= 2) {
        S.skimTipped = true;
        let a = p.pos + p.fwd * <f32>15 + p.up * <f32>2.6;
        let v = p.fwd * <f32>p.speed;
        popups.spawn(env.pops, "SKIM x2", "bonus", <f64>a.x, <f64>a.y, <f64>a.z, 0.95, <f64>v.x, <f64>v.y, <f64>v.z);
        env.comm("vi", "VI", SKIM_LINE, 3, "happy", 2);
    }

    if (S.idx == 0) {
        if (env.state == "training") show(S, env, S.firstRow);
    } else if (S.result == "" && L != null) {
        S.t += rdt;
        if (S.lt < 0 && S.t >= LAND) {
            S.lt = 0;
            setUp(S, env, L);
            log(S, env, "land");
        } else if (S.lt >= 0) {
            S.lt += rdt;
            // demo (injected in readControls)
            if (S.demo > 0) {
                S.demoV1 = env.W.volley; // (this frame's injected volley included)
                S.demoAge += rdt;
                S.demo -= rdt;
                if (S.demo <= 0) {
                    S.demo = 0;
                    if (S.bot && S.result == "") {
                        test(S, env, L, rdt);
                        result(S, env, "pass", "demo (bot)");
                    }
                }
            } else if (!S.demoRan && S.lt >= S.demoAt) {
                S.demoRan = true;
                S.demo = lmax(L.hold, 0.3) + 0.25;
                S.demoAge = 0;
                S.demoEdge = true;
                S.demoV0 = env.W.volley;
                S.demoV1 = env.W.volley;
                hint(S, env, "demo");
                if (LOG) log(S, env, format("demo (%.1f s)", [N(S.demo)]));
            }
            if (S.result == "") test(S, env, L, rdt);
            // (drill 01: the timed hint waits until he is through the slalom; two misses or a scrape hint at once)
            if (S.result == "" && S.lt >= S.hintAt && (L.key != "rings" || env.p.s >= slalomEnd(S))) hint(S, env, "hint time");
            if (S.result == "" && S.lt >= S.autoAt) result(S, env, "auto", "auto time");
        }
    } else {
        // result shown: the deflect drone waits for its returned orb
        if (S.postT >= 0) {
            S.postT -= rdt;
            let E = env.E;
            let d = S.drone;
            let orb = false;
            if (E != null && d != null && d.alive) {
                let bs = E.bullets;
                for (let i = 1; i < bs.length; i++) {
                    let b = bs[i];
                    if (b.deflected && b.src == d) orb = true;
                }
            }
            if (d == null || !d.alive) {
                S.postT = -1;
                clearDrill(S, env, true);
            } else if (!orb || S.postT <= 0) {
                S.postT = -1;
                S.popT = 0.3;
            }
        }
        if (S.popT >= 0) {
            S.popT -= rdt;
            if (S.popT <= 0) {
                S.popT = -1;
                clearDrill(S, env, true);
            }
        }
        if (S.gapT >= 0) {
            // an expired gap holds at 0 while the drone waits (postT / popT)
            S.gapT = lmax(0, S.gapT - rdt);
            if (S.gapT <= 0 && S.postT < 0 && S.popT < 0) {
                let nplan = <f64>(S.plan.length - 1);
                if (S.idx < nplan && talking(S, env) && S.holdT < VOICE_HOLD) {
                    // the next ticket waits for this one's line to type out and be read: its own plays as it lands
                    S.holdT += rdt;
                } else if (S.idx < nplan) {
                    if (S.holdT > 0 && LOG) log(S, env, format("ticket held for the line (%.2f s)", [N(S.holdT)]));
                    S.gapT = -1;
                    show(S, env, S.idx + 1);
                } else if (lineOn(env) && S.lineT < LINE_WAIT) {
                    // the last drill's line plays whole first ('You get two.' was cut by the card)
                    S.lineT += rdt;
                } else {
                    S.gapT = -1;
                    if (LOG) log(S, env, format("card after the line (%.2f s)", [N(S.lineT)]));
                    fireCard(S, env);
                }
            }
        }
    }
    writeVm(S, env);
    S.age += 1;
}

// The cut: the school is over (trained is set by the core).
export function finish(S: School, env: Env): void {
    S.active = false;
    S.tail = true;
    S.lesson = "none";
    S.phase = "none";
    S.idx = 0;
    S.demo = 0; S.slow = false; S.timing = 0; S.skipK = 0; S.nudgeT = 0; S.progress = 0;
    S.press = false; S.sx = 0; S.sy = 0; S.tally = "";
    S.rings.list.length = 1;
    S.orbs.length = 1;
    S.drone = null;
    clearStacks(S);
    S.chipT = 0;
    // trainCert and trainSkipped hold for the card
    let g = env.g;
    if (g != null) {
        vmx.optSetBool(g, "trainActive", false);
        vmx.optEnumOrString(g, "trainLesson", "none");
        vmx.optEnumOrString(g, "trainPhase", "none");
        vmx.optSetNum(g, "trainIndex", 0);
        vmx.optSetNum(g, "trainProgress", 0);
        vmx.optSetStr(g, "trainTally", "");
        vmx.optSetBool(g, "trainPress", false);
        vmx.optSetNum(g, "trainSX", 0);
        vmx.optSetNum(g, "trainSY", 0);
        vmx.optSetBool(g, "trainDemo", false);
        vmx.optSetNum(g, "trainTiming", 0);
        vmx.optSetNum(g, "trainSkipK", 0);
        vmx.optSetBool(g, "trainNudge", false);
    }
    clearSkipHeld(env);
    let h = env.h;
    if (h != null) {
        vmx.optSetBool(h, "trainActive", false);
        vmx.optEnumOrString(h, "trainFocus", "none");
    }
}

// The card is over after the cut: the tail ends (trainSkipped clears).
export function tailEnd(S: School, env: Env): void {
    S.tail = false;
    S.skipped = false;
    let g = env.g;
    if (g != null) vmx.optSetBool(g, "trainSkipped", false);
}

// resetRun: nothing of the school survives (title, restarts, reel, debug starts).
export function reset(S: School, env: Env): void {
    let was = S.active || S.tail;
    finish(S, env);
    S.tail = false;
    if (was) tailEnd(S, env);
}
