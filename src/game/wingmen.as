// Port of src/game/wingmen.luau. Wingmen VI and HANK: formation flight, rock plans, chatter, sprites.
// Wingmen VI and HANK: Pilot artboard instances in their painted skins
// (DIRECTION #22: `skin` vi / hank on the raster rig, each its own sprite)
// that join the formation early in the mission and for set pieces, now and
// then echo a barrel roll, peel away, and chat. Each flies as his own pilot
// (see STYLE and fly): he keeps the lead where he last settled on him and
// holds his slot through the lead's small moves, answers big ones late in
// his own way (VI quick and light, a hop as she crosses; HANK late and
// heavy), weaves, changes height and slot on his own clock, boosts / brakes
// late, looks round, rolls away from passing shots, keeps to his side of
// the lead (VI left, HANK right), clear of the lead, the alert band and
// the comms card on air on screen, and off the rocks.
// Treated like the painted hero: billboard roll `roll + bank * 0.12` (the
// poses carry the lean), exhaust ribbons from the painted flame tips
// (FlameTipL/R), an underside twin (`reflection = true`) in the water while
// low.
//
// Port: `new` -> create. Lists are 1-based (slot 0 a hole): W.list, W.positions,
// W.say, W.pend, WINDOWS (and their join / peel), style tables, trails, exVis,
// anc. Keeper is an abstract class the core implements (project sets pjU / pjV
// / pjD). Private multi-returns go through module globals (<FN>_1..n).
// Luau's EXT cache (keyed by collider) is gone: collide.extent is recomputed
// (same values; object-keyed maps lose entries after the per-frame GC).
import { Vector } from "rive/vector";
import { Artboard, NodeData } from "rive/artboard";
import { ViewModel } from "rive/data";
import * as mathx from "../lib/mathx";
import { HUGE, lmin, lmax, lclamp, mod, getOr, lrandom } from "../lib/compat";
import * as track from "../world/track";
import * as level from "../world/level";
import * as scenery from "../world/scenery";
import * as collide from "../world/collide";
import { Collider } from "../world/collide";
import * as R from "../render/renderer";
import * as vmx from "./vm";
import * as playerMod from "./player";
import { Player } from "./player";
import * as popups from "./popups";

// prio (optional, NaN = nil): comms priority on the core's channel (1 flavor,
// 2 default). call: 'join' / 'peel' for the formation windows' calls (the
// core lets a peel call wait only while they are still peeling)
export class Line {
    who: string;
    speaker: string;
    text: string;
    prio: f64;
    call: string?;
    constructor(who: string, speaker: string, text: string, prio: f64 = NaN, call: string? = null) {
        this.who = who;
        this.speaker = speaker;
        this.text = text;
        this.prio = prio;
        this.call = call;
    }
}

// How a wingman flies: delay / vdelay / thrDelay = s before he sees the
// lead's sideways / vertical moves / throttle, reflex = s before he sees the
// lead coming at him; tau = s he smooths what he sees over; settle = s the
// lead must sit off where he keeps him before he eases back on; his answer
// to a big move is a path of his own (qx / qy) to where he sees the lead
// plus lead / leadY s of the lead's (late) rate, taking mBase s + 1 s per
// mSpd m (x urgK when the lead comes at him or the frame runs out; never
// quicker than aacc m/s^2 / avmax m/s allow), re-planned at most every
// mHold s; catchK = how much quicker past the frame's comfort zone (x his
// catch); hop = m up (down: < 0) he arcs crossing fast;
// w, z, acc, vmax = his spring onto the slot; sw, sz = throttle rate and
// depth gain; bankRate, bankV, bankAcc = how fast he leans, the sideways m/s
// of a full lean and how much his own sideways acceleration adds; weave = x
// amp, Hz, amp, Hz, y amp, Hz, amp, Hz, depth amp, Hz (his own drift in the
// slot); slots = outward x / y / depth offsets he moves between, every slotT
// s (min, max), slotV = how fast (1/s); heights = his own height in the slot
// (min, max m), a new one every heightT s, heightV = how fast (1/s); slotP =
// portrait slot (x, y, depth); scr = where his slot sits on screen (share of
// the room beside the lead's figure across, landscape, portrait; how high,
// a share of the room over it, 1 his box clear over its top, landscape,
// portrait: the slot's metres follow the lens, slowly), fightY = height in
// a fight; lookT = s between looks round (min, max), lookLen s, lookP the
// most pose pitch of one (a look up / down); flourT = VI's flourish (roll
// or wing rock) interval; evadeR / evadeCd = a shot this near makes him roll
// away, at most this often; echo = s after the lead's roll when he echoes
// it, echoW = his share of the echoes (x0.5: the one who echoed last again);
// clrV = m/s he makes room off the lead's figure. Arrays 1-based.
export class Style {
    delay: f64 = 0;
    vdelay: f64 = 0;
    thrDelay: f64 = 0;
    reflex: f64 = 0;
    tau: f64 = 0;
    settle: f64 = 0;
    lead: f64 = 0;
    leadY: f64 = 0;
    mBase: f64 = 0;
    mSpd: f64 = 0;
    mHold: f64 = 0;
    urgK: f64 = 0;
    aacc: f64 = 0;
    avmax: f64 = 0;
    catchK: f64 = 0;
    hop: f64 = 0;
    w: f64 = 0;
    z: f64 = 0;
    acc: f64 = 0;
    vmax: f64 = 0;
    sw: f64 = 0;
    sz: f64 = 0;
    bankRate: f64 = 0;
    bankV: f64 = 0;
    bankAcc: f64 = 0;
    weave: Array<f64> = [0.0];
    slots: Array<Array<f64>> = [[0.0]];
    slotT: Array<f64> = [0.0];
    slotV: f64 = 0;
    heights: Array<f64> = [0.0];
    heightT: Array<f64> = [0.0];
    heightV: f64 = 0;
    slotP: Array<f64> = [0.0];
    scr: Array<f64> = [0.0];
    fightY: f64 = 0;
    lookT: Array<f64> = [0.0];
    lookLen: f64 = 0;
    lookP: f64 = 0;
    flourT: Array<f64>? = null;
    evadeR: f64 = 0;
    evadeCd: f64 = 0;
    echo: f64 = 0;
    echoW: f64 = 0;
    clrV: f64 = 0;
}

// VI: quick, light, playful (sees a move in ~0.2 s, answers it briskly
// and a little ahead of it, with a hop, quick weaves, changes height and
// slot often, looks round a lot, the odd flourish roll / wing rock). HANK:
// heavy and steady (sees it in ~0.7 s, answers late and slowly, sinking
// into it, wide lazy arcs, boosts last, rarely looks round, rolls from fire
// only when it is close).
function styleVi(): Style {
    let s = new Style();
    s.delay = 0.22;
    s.vdelay = 0.22;
    s.thrDelay = 0.22;
    s.reflex = 0.16;
    s.tau = 0.12;
    s.settle = 1.1;
    s.lead = 0.35;
    s.leadY = 0.2;
    s.mBase = 0.28;
    s.mSpd = 30;
    s.mHold = 0.35;
    s.urgK = 0.6;
    s.aacc = 46;
    s.avmax = 28;
    s.catchK = 1.5;
    s.hop = 1.2;
    s.w = 4.2;
    s.z = 0.85;
    s.acc = 120;
    s.vmax = 40;
    s.sw = 5.5;
    s.sz = 2.2;
    s.bankRate = 6;
    s.bankV = 22;
    s.bankAcc = 0.0015;
    s.weave = [0.0, 1.6, 0.19, 0.9, 0.47, 0.5, 0.23, 0.25, 0.61, 1.2, 0.13];
    s.slots = [[0.0], [0.0, 0, 0, 0], [0.0, 2.0, 0.6, -2], [0.0, -1.5, -0.5, 2], [0.0, 0.8, 1.0, 3]];
    s.slotT = [0.0, 3.5, 7];
    s.slotV = 0.9;
    s.heights = [0.0, -0.6, 1.4];
    s.heightT = [0.0, 3, 6];
    s.heightV = 0.9;
    s.slotP = [0.0, -7, 3.5, 21];
    s.scr = [0.0, 0.58, 0.55, 1.15, 1.25];
    s.fightY = 1.0;
    s.lookT = [0.0, 2.2, 4.5];
    s.lookLen = 0.7;
    s.lookP = 0.35;
    s.flourT = [0.0, 8, 15];
    s.evadeR = 6;
    s.evadeCd = 2.6;
    s.echo = 0.28;
    s.echoW = 0.55;
    s.clrV = 24;
    return s;
}

function styleHank(): Style {
    let s = new Style();
    s.delay = 0.7;
    s.vdelay = 0.55;
    s.thrDelay = 0.45;
    s.reflex = 0.3;
    s.tau = 0.25;
    s.settle = 1.8;
    s.lead = 0.12;
    s.leadY = 0.1;
    s.mBase = 0.9;
    s.mSpd = 15;
    s.mHold = 0.6;
    s.urgK = 0.85;
    s.aacc = 26;
    s.avmax = 19;
    s.catchK = 1;
    s.hop = -0.7;
    s.w = 3.0;
    s.z = 0.95;
    s.acc = 90;
    s.vmax = 34;
    s.sw = 4.5;
    s.sz = 2.2;
    s.bankRate = 3.4;
    s.bankV = 30;
    s.bankAcc = 0.002;
    s.weave = [0.0, 3.0, 0.07, 0.8, 0.19, 0.8, 0.06, 0.3, 0.17, 1.5, 0.06];
    s.slots = [[0.0], [0.0, 0, 0, 0], [0.0, 2.5, 0.4, -2], [0.0, -1.2, -0.6, 2], [0.0, 1.2, 0.9, 3]];
    s.slotT = [0.0, 8, 13];
    s.slotV = 0.6;
    s.heights = [0.0, -0.8, 0.8];
    s.heightT = [0.0, 6, 11];
    s.heightV = 0.6;
    s.slotP = [0.0, 7.5, 2.5, 24];
    s.scr = [0.0, 0.5, 0.5, 1.05, 1.2];
    s.fightY = -0.4;
    s.lookT = [0.0, 5, 9];
    s.lookLen = 1.0;
    s.lookP = 0.2;
    s.flourT = null;
    s.evadeR = 4.5;
    s.evadeCd = 5.5;
    s.echo = 0.55;
    s.echoW = 0.45;
    s.clrV = 18;
    return s;
}

const STYLE_VI: Style = styleVi();
const STYLE_HANK: Style = styleHank();

function styleOf(who: string): Style {
    return who == "vi" ? STYLE_VI : STYLE_HANK;
}

// The painted flame tips (artboard units), read every frame like the hero's.
export class Tips {
    l: NodeData;
    r: NodeData;
    w: f64;
    h: f64;
    constructor(l: NodeData, r: NodeData, w: f64, h: f64) {
        this.l = l;
        this.r = r;
        this.w = w;
        this.h = h;
    }
}

// Formation windows (rail meters) with the banter for joining and leaving.
// wait (optional, additive; NaN = nil): m past s1 the peel may wait for the
// channel. join / peel 1-based.
export class Window {
    s0: f64;
    s1: f64;
    join: Array<Line>;
    peel: Array<Line>;
    wait: f64;
    constructor(s0: f64, s1: f64, join: Array<Line>, peel: Array<Line>, wait: f64 = NaN) {
        this.s0 = s0;
        this.s1 = s1;
        this.join = join;
        this.peel = peel;
        this.wait = wait;
    }
}

function lines1(): Array<Line> {
    return new Array<Line>(1);
}

function joinLine(who: string, speaker: string, text: string, call: string): Line {
    return new Line(who, speaker, text, NaN, call);
}

// Window 1 is packed (the tower's hello from 25 m, both intros, the arch
// warning, the kamikazes from 1240 m, the mines call at 1375 m; the Baron
// now speaks past the arch, core_pages KESSEL_S): short intros, and the pair
// breaks off at 780 m without a call (QA M14: 'Splitting off to cover the
// arch!' had no room left on the channel; with a call the peel would wait
// for it). The join and a peel with a call wait for the comms channel
// (W.hold): the pair swoops in / breaks off as their call plays, not seconds
// before it. A wingman whose own join call comes second swoops in when the
// channel frees again (W.pend). The core only lets a call out when it is
// over before the next scripted beat (game.luau BEATS: its leading sentences
// when only those fit, else it waits or is dropped unsaid).
function makeWindows(): Array<Window> {
    let ws = new Array<Window>(1);
    let j1 = lines1();
    j1.push(joinLine("vi", "VI", "Vi on your left wing!", "join"));
    j1.push(joinLine("hank", "HANK", "Hank on the right. Mind my eyebrows, kid!", "join"));
    ws.push(new Window(70, 780, j1, lines1()));
    let j2 = lines1();
    j2.push(joinLine("vi", "VI", "Back with you! Hug the water, it keeps us under their guns.", "join"));
    let p2 = lines1();
    p2.push(joinLine("vi", "VI", "Bandits up high. I've got them, go go go!", "peel"));
    // (the canyon walls start at 2820)
    ws.push(new Window(1860, 2650, j2, p2, 100));
    let j3 = lines1();
    j3.push(joinLine("hank", "HANK", "That portal's pulling us in. All together now, nobody blinks!", "join"));
    // (Hank's 'purple', the Baron's troopers and VI's tip on them take
    // the channel first: from 5620 her call opened 0.2 s before the
    // Baron's cue and never played)
    let p3 = lines1();
    p3.push(joinLine("vi", "VI", "Fanning out. Stay sharp!", "peel"));
    ws.push(new Window(4940, 6100, j3, p3, 150));
    let j4 = lines1();
    j4.push(joinLine("hank", "HANK", "Last stretch. Right behind you, Corsair. Bring us home!", "join"));
    ws.push(new Window(7700, 99999, j4, lines1()));
    return ws;
}

export const WINDOWS: Array<Window> = makeWindows();

// jacket, scarf, helmet (fallback when the named Pilot instance is missing)
function looksOf(who: string): Array<f64> {
    return who == "vi" ? [0.0, 0xB5245F, 0xFF9ECB, 0xCFC7EA] : [0.0, 0x6B7733, 0xFF8A24, 0xAEB8C4];
}
function instanceOf(who: string): string {
    return who == "vi" ? "Vi" : "Hank";
}
// seconds a join may wait for the comms channel (the tower's hello, a
// scripted line on air; 8: window 2's waits out the low pass call, 6.7 s,
// QA SEGA-N2)
const JOIN_WAIT: f64 = 8;

// His own answer to a big move on one axis: a quintic from where he keeps
// the lead (place, rate, acceleration) to `to`, at rest, over T s (T 0:
// holding). A path of his own: never the lead's rate or its shape.
export class Plan {
    c0: f64 = 0;
    c1: f64 = 0;
    c2: f64 = 0;
    c3: f64 = 0;
    c4: f64 = 0;
    c5: f64 = 0;
    T: f64 = 0;
    t: f64 = 0;
    to: f64 = 0;
}

export class Wing {
    name: string = "";
    who: string = "";
    slotX: f64 = 0;
    slotY: f64 = 0;
    slotS: f64 = 0;
    size: f64 = 0;
    phase: string = "away"; // 'away' | 'join' | 'form' | 'peel'
    phaseT: f64 = 0;
    s: f64 = 0;
    x: f64 = 0;
    y: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    fromS: f64 = 0;
    fromX: f64 = 0;
    fromY: f64 = 0;
    bank: f64 = 0;
    pitch: f64 = 0;
    roll: f64 = 0;
    rollT: f64 = 0;
    rollDir: f64 = 0;
    rollDelay: f64 = -1;
    thrust: f64 = 0.6;
    peelDir: f64 = 1;
    pos: Vector = Vector.xyz(0, 0, 0);
    art: Artboard? = null;
    bag: vmx.Bag? = null;
    sprite: R.Sprite? = null;
    seed: f64 = 0;
    trails: Array<R.Trail> = new Array<R.Trail>(1); // jet exhaust ribbons (left, right), 1-based
    exVis: Array<f64> = [0.0, 1, 1]; // how much of each ribbon shows (ribbonVis, eased)
    painted: bool = false; // raster skin: hero-style roll, flame tips read from the art
    tips: Tips? = null; // FlameTipL/R on the painted art
    // this frame's flame tips (sprite meters, x right / y up): lx, ly, rx, ry
    // (vector-rig nozzles on a 3.4 m sprite until the painted tips are read)
    anc: Array<f64> = [0.0, -0.17, -0.72, 0.17, -0.72];
    twin: Artboard? = null; // underside twin, drawn in the water pass only
    twinBag: vmx.Bag? = null;
    twinSprite: R.Sprite? = null;
    flinchT: f64 = 0; // cooldown of the near-miss flinch (Pilot.hit)
    artDt: f64 = 0; // time since the art / its twin last advanced (half rate, see update)
    twinDt: f64 = 0;
    // triggers held for the art / its twin's next advance (a Pilot trigger
    // fired on a frame its artboard does not advance is lost); 1-based
    pend: Array<string> = [""];
    twinPend: Array<string> = [""];
    // his own flying (formation; see STYLE and fly)
    style: Style;
    rng: f64 = 0; // cosmetic draws (own generator: math.random stays gameplay's)
    ax: f64 = 0; // his rail accelerations (bank / pitch anticipation)
    ay: f64 = 0;
    rs: f64 = 0; // depth: m ahead of the lead
    sv: f64 = 0; // his own speed along the rail
    gap: f64 = 0; // m he is off his depth in the slot, as he notices it (late)
    slotK: f64 = 1; // current slot variant (style.slots)
    slotT: f64 = 0; // s to the next slot change
    sxM: f64 = 0; // his slot off where he keeps the lead (m, across / up): STYLE scr
    huS: f64 = 0.5; // where the lead's figure sits on screen (slowly)
    hvS: f64 = 0.55;
    luS: f64 = 0.5; // where the lead's line lands at his depth (slowly)
    lvS: f64 = 0.5;
    layT: f64 = 0; // > 0: the layout above is under way
    roomIn: f64 = 6; // m the lead may come at him on screen before his room runs out
    syM: f64 = 0; // at the lens's scale, eased
    oX: f64 = 0; // the slot variant he is easing into (outward / up / ahead)
    oY: f64 = 0;
    oS: f64 = 0;
    hOff: f64 = 0; // his own height in the slot, its goal, s to the next one
    hGoal: f64 = 0;
    hT: f64 = 0;
    own: f64 = 1; // 0..1: how much of his own drift the frame leaves room for
    depthK: f64 = 1; // his slot's depth, x (a bend: nearer, so he stays beside the lead)
    fk: f64 = 0; // 0..1: the fight slot (eased)
    avX: f64 = 0; // rock avoidance (rail m, eased back to 0)
    avY: f64 = 0;
    avT: f64 = 0;
    avGX: f64 = 0; // where the rock avoidance is taking his slot (offsets)
    avGY: f64 = 0;
    wayX: f64 = 0; // the way round rock he took (rail x / y), kept while clear
    wayY: f64 = 0;
    way: f64 = 0; // 0 none held, 1 a way held, 2 past the frame's edge (rock first)
    wayTx: f64 = 0; // his target before the way, last frame (the way stays put on the rail)
    wayTy: f64 = 0;
    planT: f64 = 0; // s to looking his ways round rock over again
    gW: f64 = 0; // the rock guard's way last frame (GUARD_X / Y; 0 none)
    near: Array<Collider> = new Array<Collider>(1); // rock near his way (gather): what his probes test; 1-based
    fx: f64 = 0; // the lead as he sees him: `delay` s ago, smoothed
    fy: f64 = 0;
    fvx: f64 = 0;
    fvy: f64 = 0;
    kx: f64 = 0; // where he keeps the lead (formats on), its rate and
    ky: f64 = 0; // acceleration: held through the lead's small moves, moved
    kvx: f64 = 0; // only along his own answers (qx / qy)
    kvy: f64 = 0;
    kax: f64 = 0;
    kay: f64 = 0;
    qx: Plan = new Plan();
    qy: Plan = new Plan();
    modeX: f64 = 0; // 0 holding, 1 answering a move, 2 easing back on (settle)
    modeY: f64 = 0;
    inX: bool = false; // answering the lead coming at him (his reflex)
    offX: f64 = 0; // s the lead has sat off where he keeps him
    offY: f64 = 0;
    clrX: f64 = 0; // room off the lead's figure on screen (out / up), its
    clrY: f64 = 0; // goal and the s it is held
    clrGX: f64 = 0;
    clrGY: f64 = 0;
    clrT: f64 = 0;
    boosting: bool = false; // his own throttle (the lead's, late)
    braking: bool = false;
    glance: f64 = 0; // pose bank offset: a look over the shoulder / wing rock
    glanceP: f64 = 0; // pose pitch of the look (up / down)
    lookP: f64 = 0; // this look's pitch
    glanceT: f64 = 0; // s left of the current look
    glanceDir: f64 = 1;
    glanceLen: f64 = 0;
    wag: bool = false; // the look is a wing rock (VI)
    lookT: f64 = 0; // s to the next look
    flourT: f64 = 0; // s to VI's next flourish
    evadeT: f64 = 0; // cooldown of the roll away from a passing shot
    rollCd: f64 = 0; // s before he may roll on his own again
    peelK: f64 = 1; // peel: share of the outward break (eases to 0 at rock)
    peelW: f64 = 1; // peel: his way round rock instead (PEEL_X / PEEL_Y)
    peelGo: f64 = 0; // peel: s taken off it (in rock: gone sooner)
    catch: f64 = 0; // 0..1: his slot off the frame's comfort zone: he answers quicker
    emX: f64 = 0; // 0..1: he himself past it: on with the lens's drift (eased)
    emY: f64 = 0;
    rtx: f64 = 1; // rail right at him (world x / z)
    rtz: f64 = 0;
    // the lens's drift of his slot on screen (u / v per s, held still) and
    // where it was last frame (screen, rail)
    driftU: f64 = 0;
    driftV: f64 = 0;
    scrU: f64 = -1;
    scrV: f64 = 0;
    scrX: f64 = 0;
    scrY: f64 = 0;
    // his own box off the lead's figure on screen last frame, and how fast
    // the lead / lens close it (u / v per s, his own move left out)
    figU: f64 = 0;
    figV: f64 = 0;
    figEU: f64 = 0;
    figEV: f64 = 0;
    figOk: bool = false;
    figAx: bool = true; // kept off the lead's figure across (else up / down)
    // where he was on screen last frame and the lens's drift of him there
    edU: f64 = 0;
    edV: f64 = 0;
    edEU: f64 = 0;
    edEV: f64 = 0;
    constructor(st: Style) {
        this.style = st;
    }
}

export class PendJoin {
    who: string;
    line: Line;
    constructor(who: string, line: Line) {
        this.who = who;
        this.line = line;
    }
}

// The lead's last HIST frames: time, rail x / y, their rates, speed along
// the rail, boost / brake (1 / 0). Ring slots 1..HIST.
const HIST: i32 = 96;
export class Hist {
    t: Array<f64> = zeros(HIST + 1);
    x: Array<f64> = zeros(HIST + 1);
    y: Array<f64> = zeros(HIST + 1);
    vx: Array<f64> = zeros(HIST + 1);
    vy: Array<f64> = zeros(HIST + 1);
    v: Array<f64> = zeros(HIST + 1);
    bo: Array<f64> = zeros(HIST + 1);
    br: Array<f64> = zeros(HIST + 1);
    n: i32 = 0;
    head: i32 = 0;
}

function zeros(n: i32): Array<f64> {
    let a = new Array<f64>(n);
    a.fill(0);
    return a;
}

export class Wingmen {
    list: Array<Wing> = new Array<Wing>(1); // 1-based
    window: i32 = 0; // index of the active window, 0 = none
    positions: Array<Vector> = [Vector.xyz(0, 0, 0)]; // 1-based (slot 0 dummy), cleared in place
    say: Array<Line> = new Array<Line>(1); // lines to deliver (drained by the caller), 1-based
    reactT: f64 = 8;
    joined: bool = false; // one-frame event: the pair just swooped in
    titleForm: bool = false; // title attract: echelon on the (hidden) lead's left
    fight: bool = false; // a boss is framed: keep out of the hero-to-boss line
    tick: f64 = 0; // frame counter (the art advances at half rate, staggered)
    // set by the caller each frame: the comms channel is busy, so a join /
    // peel waits (up to JOIN_WAIT s / the window's `wait` m) to land with its call
    hold: bool = false;
    holdT: f64 = 0; // seconds the pending join has waited
    // wingmen still to swoop in with their own join call, in call order (1-based)
    pend: Array<PendJoin> = new Array<PendJoin>(1);
    pendT: f64 = 0; // seconds the first of them has waited
    edgeT: f64 = HUGE; // seconds to the active window's end (reactions keep clear of the peel call)
    hist: Hist = new Hist(); // the lead's recent flight (what a wingman saw a beat ago)
    lastS: f64 = 0; // the lead's rail s last frame
    dsH: f64 = 0; // his move along the rail this frame
    rng: f64 = 977; // cosmetic draws (who echoes a roll)
    echoSkip: f64 = 2; // the lead's rolls to the next echo
    echoLast: f64 = 0; // who echoed last (1 VI, 2 HANK, 0 none yet)
    // the lead's figure on screen this frame (see figure): ok, centre, its
    // box off the centre (left, right, up, down), the sprite's u / v per
    // metre there and its depth
    figOk: bool = false;
    fU: f64 = 0.5;
    fV: f64 = 0.55;
    fL: f64 = 0;
    fR: f64 = 0;
    fT: f64 = 0;
    fB: f64 = 0;
    fKu: f64 = 0;
    fKv: f64 = 0;
    fZ: f64 = 1;
    // the comms card on screen (popups.comms: where the HUD draws it; across,
    // its foot) and how much it bars them while a line is on air (0..1, eased)
    cardK: f64 = 0;
    cardT: f64 = 0; // s it stays up past the line on air
    cU0: f64 = 0;
    cU1: f64 = 0;
    cV1: f64 = 0;
}

function histPush(h: Hist, t: f64, p: Player): void {
    if (h.n > 0 && t <= h.t[h.head]) {
        // (no time passed: refresh the newest sample)
        if (t < h.t[h.head]) {
            h.n = 0;
        } else {
            h.n -= 1;
            h.head = h.head == 1 ? HIST : h.head - 1;
        }
    }
    let i = h.head % HIST + 1;
    h.head = i;
    h.n = min(h.n + 1, HIST);
    h.t[i] = t;
    h.x[i] = p.x;
    h.y[i] = p.y;
    h.vx[i] = p.vx;
    h.vy[i] = p.vy;
    h.v[i] = p.speed * p.railK;
    h.bo[i] = p.boosting ? 1 : 0;
    h.br[i] = p.braking ? 1 : 0;
}

// The lead as seen `d` s ago (between samples; the oldest one when the
// record is shorter): x, y, vx, vy, speed, boosting, braking -> HIST_AT_1..7.
let HIST_AT_1: f64 = 0;
let HIST_AT_2: f64 = 0;
let HIST_AT_3: f64 = 0;
let HIST_AT_4: f64 = 0;
let HIST_AT_5: f64 = 0;
let HIST_AT_6: bool = false;
let HIST_AT_7: bool = false;

function histAt(h: Hist, t: f64, d: f64): f64 {
    let i = h.head;
    let tq = t - d;
    for (let c = 1; c <= h.n - 1; c++) {
        let j = i == 1 ? HIST : i - 1;
        let t0 = h.t[j];
        if (t0 <= tq) {
            let t1 = h.t[i];
            let k = t1 > t0 ? (tq - t0) / (t1 - t0) : 1.0;
            let x = h.x, y = h.y, vx = h.vx, vy = h.vy, v = h.v;
            let n = k < 0.5 ? j : i;
            HIST_AT_1 = x[j] + (x[i] - x[j]) * k;
            HIST_AT_2 = y[j] + (y[i] - y[j]) * k;
            HIST_AT_3 = vx[j] + (vx[i] - vx[j]) * k;
            HIST_AT_4 = vy[j] + (vy[i] - vy[j]) * k;
            HIST_AT_5 = v[j] + (v[i] - v[j]) * k;
            HIST_AT_6 = h.bo[n] > 0;
            HIST_AT_7 = h.br[n] > 0;
            return HIST_AT_1;
        }
        i = j;
    }
    HIST_AT_1 = h.x[i];
    HIST_AT_2 = h.y[i];
    HIST_AT_3 = h.vx[i];
    HIST_AT_4 = h.vy[i];
    HIST_AT_5 = h.v[i];
    HIST_AT_6 = h.bo[i] > 0;
    HIST_AT_7 = h.br[i] > 0;
    return HIST_AT_1;
}

function planStart(q: Plan, p: f64, v: f64, a: f64, to: f64, T: f64): void {
    let D = to - p;
    let T2 = T * T;
    let T3 = T2 * T;
    q.c0 = p;
    q.c1 = v;
    q.c2 = a * 0.5;
    q.c3 = (20 * D - 12 * v * T - 3 * a * T2) / (2 * T3);
    q.c4 = (-30 * D + 16 * v * T + 3 * a * T2) / (2 * T3 * T);
    q.c5 = (12 * D - 6 * v * T - a * T2) / (2 * T3 * T2);
    q.T = T;
    q.t = 0;
    q.to = to;
}

// Place, rate, acceleration t s into the plan -> PLAN_AT_1..3.
let PLAN_AT_1: f64 = 0;
let PLAN_AT_2: f64 = 0;
let PLAN_AT_3: f64 = 0;

function planAt(q: Plan, t: f64): f64 {
    let c1 = q.c1, c2 = q.c2, c3 = q.c3, c4 = q.c4, c5 = q.c5;
    PLAN_AT_1 = q.c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * c5))));
    PLAN_AT_2 = c1 + t * (2 * c2 + t * (3 * c3 + t * (4 * c4 + t * 5 * c5)));
    PLAN_AT_3 = 2 * c2 + t * (6 * c3 + t * (12 * c4 + t * 20 * c5));
    return PLAN_AT_1;
}

function rnd(w: Wing): f64 {
    // Park-Miller (exact in doubles)
    w.rng = mod(w.rng * 16807, 2147483647);
    return w.rng / 2147483647;
}

function rndIn(w: Wing, r: Array<f64>): f64 {
    return r[1] + (r[2] - r[1]) * rnd(w);
}

function newWing(name: string, who: string, slotX: f64, slotY: f64, slotS: f64, size: f64, seed: f64): Wing {
    let st = styleOf(who);
    let w = new Wing(st);
    w.name = name;
    w.who = who;
    w.slotX = slotX;
    w.slotY = slotY;
    w.slotS = slotS;
    w.size = size;
    w.peelDir = slotX < 0 ? -1 : 1;
    w.seed = seed;
    w.rng = Math.floor(seed * 7919) + 11;
    w.rs = slotS;
    w.sv = playerMod.CRUISE;
    w.slotT = st.slotT[1];
    w.sxM = slotX;
    w.syM = slotY;
    w.hT = st.heightT[1];
    w.glanceLen = st.lookLen;
    w.lookT = st.lookT[1];
    let ft = st.flourT;
    w.flourT = ft != null ? ft[1] : HUGE;
    return w;
}

export function create(): Wingmen {
    let W = new Wingmen();
    // (landscape slots: wide, a few metres above the lead and well
    // ahead, so the lead's sideways moves pass under them on screen and
    // they stay below the alert band; portrait: STYLE slotP)
    W.list.push(newWing("VI", "vi", -9, 4.3, 13, 3.2, 1.7));
    W.list.push(newWing("HANK", "hank", 9.5, 4.0, 20, 3.9, 4.1));
    return W;
}

// A Pilot view model in the wingman's painted skin (DIRECTION #22). The named
// instances carry raster + skin; they are written again so a plain instance
// (instance missing) still wears the skin. False on a file without skins.
function wearSkin(vm: ViewModel, b: vmx.Bag, who: string): bool {
    if (vm.getBoolean("raster") == null || vm.getEnum("skin") == null) {
        return false;
    }
    vmx.optSetBool(b, "raster", true);
    vmx.setEnum(b, "skin", who);
    return true;
}

function readTips(art: Artboard): Tips? {
    let a = art.node("FlameTipL"), c = art.node("FlameTipR");
    if (a != null && c != null && art.width > 0) {
        return new Tips(a, c, art.width, art.height);
    }
    return null;
}

// input: the Pilot artboard (game: self.pilot).
export function attach(W: Wingmen, r: R.Gfx, input: Artboard): void {
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        let vm = ViewModel.create("Pilot", instanceOf(w.who));
        let b = vmx.bag(vm);
        w.bag = b;
        w.painted = wearSkin(vm, b, w.who);
        if (!w.painted) {
            // vector rig: the named instances carry the designed palettes;
            // recolor a plain instance (a fresh one holds black)
            let look = looksOf(w.who);
            let jacket = vm.getColor("jacket");
            if (jacket == null || (jacket.value & 0xFFFFFF) == 0) {
                vmx.color(b, "jacket", look[1]);
                vmx.color(b, "scarf", look[2]);
                vmx.color(b, "helmet", look[3]);
            }
        }
        let art = input.instance(vm);
        w.art = art;
        if (w.painted) {
            w.tips = readTips(art);
            if (w.tips != null) {
                // the painted cruise tips (sprite meters) until the first read
                let k = w.size / 3.4;
                w.anc = [0.0, -0.25 * k, -0.42 * k, 0.25 * k, -0.42 * k];
            }
        }
        // the painted wingman's water reflection is his underside twin (like
        // the hero's); the sprite itself then stays out of the mirror
        let twinned = false;
        if (w.painted) {
            let tvm = ViewModel.create("Pilot", instanceOf(w.who));
            let tb = vmx.bag(tvm);
            wearSkin(tvm, tb, w.who);
            vmx.optSetBool(tb, "reflection", true);
            let twin = input.instance(tvm);
            w.twin = twin;
            w.twinBag = tb;
            w.twinSprite = R.createReflectionSprite(r, "wingRefl_" + w.who, twin, 192, 192, 1);
            twinned = true;
        }
        w.sprite = R.createSprite(r, "wing_" + w.who, art, 320, 320, 1, !twinned, false);
        let trs = new Array<R.Trail>(1);
        trs.push(R.newTrail(16, 1, 0.1, 0.36, 1, 0.62, 0.28, 0.9, 0.8));
        trs.push(R.newTrail(16, 1, 0.1, 0.36, 1, 0.62, 0.28, 0.9, 0.8));
        w.trails = trs;
    }
    // Their sprites (and twins, in the same order: the slow atlases take
    // turns down the list) go just before the hero's: sprites draw in list
    // order, and in formation they fly ahead of him, further from the lens
    // (QA round 4: drawn after him, a wingman behind him showed on his
    // helmet). Without a 'pilot' sprite the list is left as it is.
    // (r.sprites is 0-based: hi = -1 none)
    let list = r.sprites;
    let hi = -1;
    for (let i = 0; i < list.length; i++) {
        if (list[i].name == "pilot") {
            hi = i;
            break;
        }
    }
    if (hi >= 0) {
        for (let wi = 1; wi < W.list.length; wi++) {
            let w = W.list[wi];
            for (let k = 0; k < 2; k++) {
                let sp = k == 0 ? w.twinSprite : w.sprite;
                if (sp == null) continue;
                let j = list.indexOf(sp);
                if (j > hi) {
                    // (table.remove(list, j); table.insert(list, hi, sp))
                    for (let m = j; m > hi; m--) list[m] = list[m - 1];
                    list[hi] = sp;
                    hi += 1;
                }
            }
        }
    }
}

// Billboard roll: the painted poses lean into the bank themselves, so (like
// the hero) only a small residual rides on top of the barrel roll.
export function roll(w: Wing): f64 {
    return w.painted ? w.bank * 0.12 + w.roll : w.bank * 0.5 + w.roll;
}

// How much of an exhaust ribbon may show (0..1). The ribbon trails back
// toward the lens, so on screen it runs away from the vanishing point: under
// it that is down past the boots (the painted flames' own line), but above or
// outside it the ribbon runs up / across the pilot's own legs and arms. From
// the ribbon's first segment on screen against the sprite's axes (roll):
// down or outward (side -1 left, 1 right) it shows, up or inward it fades.
export function ribbonVis(tr: R.Trail, eye: Vector, f: Vector, rt: Vector, up: Vector, roll: f64, side: f64): f64 {
    if (tr.n < 2) {
        return 1;
    }
    let h = tr.head;
    let q = h == 1 ? tr.cap : h - 1;
    let ox = tr.xs[h] - <f64>eye.x, oy = tr.ys[h] - <f64>eye.y, oz = tr.zs[h] - <f64>eye.z;
    let dx = tr.xs[q] - tr.xs[h], dy = tr.ys[q] - tr.ys[h], dz = tr.zs[q] - tr.zs[h];
    let fx = <f64>f.x, fy = <f64>f.y, fz = <f64>f.z;
    let rx = <f64>rt.x, ry = <f64>rt.y, rz = <f64>rt.z;
    let ux = <f64>up.x, uy = <f64>up.y, uz = <f64>up.z;
    let cz = ox * fx + oy * fy + oz * fz;
    // (a hovering flyer's ribbon has no direction yet)
    if (cz < 0.5 || dx * dx + dy * dy + dz * dz < 0.09) {
        return 1;
    }
    let cx = ox * rx + oy * ry + oz * rz;
    let cy = ox * ux + oy * uy + oz * uz;
    let ddz = dx * fx + dy * fy + dz * fz;
    // screen direction (isotropic pixels, y up) of the segment from the tip
    let sx = dx * rx + dy * ry + dz * rz - cx / cz * ddz;
    let sy = dx * ux + dy * uy + dz * uz - cy / cz * ddz;
    let l = Math.sqrt(sx * sx + sy * sy);
    if (l < 1e-5) {
        return 1;
    }
    sx = sx / l;
    sy = sy / l;
    let c = Math.cos(roll), s = Math.sin(roll);
    let down = sx * s - sy * c;
    let out = side * (sx * c + sy * s);
    return mathx.smoothstep(0.05, 0.6, down + 0.8 * lmax(0, out));
}

// Feed the exhaust ribbons from the flame tips (painted: read from the art
// every frame; vector rig: nozzles at +-0.17 m, tips 0.72 m below centre on a
// 3.4 m sprite). Painted flames are the hot core, so the ribbons are a short
// heat shimmer past the tips at cruise, a longer streak while boosting (the
// hero's). camR / camU: camera basis; t: game time; eye / dt: when dt is
// given (not NaN), each ribbon's visibility (ribbonVis) is eased toward this
// frame's.
export function pushTrails(W: Wingmen, camR: Vector, camU: Vector, t: f64, eye: Vector = Vector.xyz(0, 0, 0), dt: f64 = NaN): void {
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        if (w.phase != "away" && w.trails.length - 1 == 2) {
            let painted = w.tips != null;
            let k = painted ? 1 : w.size / 3.4;
            let rl = roll(w);
            let c0 = Math.cos(rl), s0 = Math.sin(rl);
            let thin = 1.0;
            if (painted) {
                let life = w.thrust > 0.9 ? 0.065 : 0.045;
                w.trails[1].life = life;
                w.trails[2].life = life;
                thin = 0.6 * w.size / 3.4;
            }
            let o = w.anc;
            for (let side = 1; side <= 2; side++) {
                let ox = o[side * 2 - 1] * k, oy = o[side * 2] * k;
                let q = w.pos + camR * <f32>(ox * c0 - oy * s0) + camU * <f32>(ox * s0 + oy * c0);
                R.trailPush(w.trails[side], <f64>q.x, <f64>q.y, <f64>q.z, t, (0.2 + w.thrust * 0.25) * k * thin);
            }
            if (!isNaN(dt)) {
                let f = mathx.cross(camU, camR);
                for (let side = 1; side <= 2; side++) {
                    let vis = ribbonVis(w.trails[side], eye, f, camR, camU, rl, <f64>(side * 2 - 3));
                    w.exVis[side] = mathx.damp(w.exVis[side], vis, 14, dt);
                }
            }
        } else if (w.trails.length - 1 == 2) {
            R.trailClear(w.trails[1]);
            R.trailClear(w.trails[2]);
        }
    }
}

export function reset(W: Wingmen): void {
    W.window = 0;
    W.say.length = 1;
    W.positions.length = 1;
    W.reactT = 8;
    W.hold = false;
    W.holdT = 0;
    W.edgeT = HUGE;
    W.pend.length = 1;
    W.pendT = 0;
    W.hist.n = 0;
    W.echoSkip = 2;
    W.echoLast = 0;
    W.cardK = 0;
    W.cardT = 0;
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        w.phase = "away";
        w.phaseT = 0;
        w.rollT = 0;
        w.rollDelay = -1;
        w.flinchT = 0;
        w.glance = 0;
        w.glanceT = 0;
        w.avX = 0;
        w.avY = 0;
        w.avT = 0;
        w.avGX = 0;
        w.avGY = 0;
        w.way = 0;
        w.clrX = 0;
        w.clrY = 0;
        w.clrGX = 0;
        w.clrGY = 0;
        w.clrT = 0;
        w.glanceP = 0;
        w.evadeT = 0;
        w.rollCd = 0;
        w.boosting = false;
        w.braking = false;
        w.pend.length = 1;
        w.twinPend.length = 1;
        w.near.length = 1;
    }
}

// Queue a Pilot trigger (roll / hit) for the art and its twin: fired just
// before each one's next (staggered) advance.
function trigger(w: Wing, name: string): void {
    if (w.pend.lastIndexOf(name) < 1) {
        w.pend.push(name);
    }
    if (w.twinBag != null && w.twinPend.lastIndexOf(name) < 1) {
        w.twinPend.push(name);
    }
}

function flush(b: vmx.Bag?, pend: Array<string>): void {
    if (b != null) {
        for (let i = 1; i < pend.length; i++) {
            vmx.fire(b, pend[i]);
        }
    }
    pend.length = 1;
}

function say(W: Wingmen, lines: Array<Line>): void {
    for (let i = 1; i < lines.length; i++) {
        W.say.push(lines[i]);
    }
}

function flavor(who: string, speaker: string, text: string): Line {
    return new Line(who, speaker, text, 1);
}

// Reactive chatter (hit, combo, boss down), rate limited; flavor priority on
// the core's comms channel (dropped when the channel stays busy).
export function react(W: Wingmen, kind: string): void {
    // (none in the last 4 s of a window: the peel call gets the channel)
    if (W.window == 0 || W.reactT > 0 || W.edgeT < 4) {
        return;
    }
    let l: Line? = null;
    let heads = lrandom() < 0.5;
    if (kind == "hit") {
        l = heads
            ? flavor("vi", "VI", "Corsair, you're taking fire! Roll it off!")
            : flavor("hank", "HANK", "Shake em off, kid! Barrel roll!");
    } else if (kind == "combo") {
        l = heads
            ? flavor("vi", "VI", "Now THAT's flying!")
            : flavor("hank", "HANK", "Ha! Save some for the rest of us!");
    } else if (kind == "ring") {
        l = flavor("vi", "VI", "Beautiful line through those rings!");
    }
    if (l != null) {
        W.say.push(l);
        W.reactT = 14;
    }
}

// A barrel roll (the Pilot roll tuck), dir 1 = to the left like the lead's,
// with `step` of a 16 m/s sidestep the way he rolls (formation).
function startRoll(w: Wing, dir: f64, step: f64): void {
    w.rollDir = dir;
    w.rollT = playerMod.ROLL_TIME;
    w.rollCd = 1.4;
    w.glanceT = 0;
    trigger(w, "roll");
    if (w.phase == "form") {
        w.vx -= dir * 16 * step;
    }
}

function rndW(W: Wingmen): f64 {
    W.rng = mod(W.rng * 16807, 2147483647);
    return W.rng / 2147483647;
}

// The lead's barrel roll: about one in three is echoed, by one of them only,
// on his own beat (VI ~0.3 s, HANK ~0.55 s), in place (QA PT2: both
// mirrored every roll, sidestep and all). They take turns, the one who
// echoed last now and then again (his echoW / 2), the first by the clock's
// parity (QA round 4: drawn fresh from a generator every session starts
// the same, VI took ~5 in 6).
export function echoRoll(W: Wingmen, dir: f64): void {
    let a = W.list[1], b = W.list[2];
    let okA = a.phase == "form" && a.rollT <= 0 && a.rollDelay < 0;
    let okB = b.phase == "form" && b.rollT <= 0 && b.rollDelay < 0;
    if (!okA && !okB) {
        return;
    }
    W.echoSkip -= 1;
    if (W.echoSkip > 0) {
        return;
    }
    W.echoSkip = 2 + Math.floor(rndW(W) * 2.999);
    if (W.echoLast == 0) {
        W.echoLast = 1 + mod(W.tick, 2);
    }
    let last = W.echoLast == 1 ? a : b;
    let again = rndW(W) < 0.5 * last.style.echoW;
    let pickA = W.echoLast == 1 ? again : !again;
    let w = (pickA && okA) || !okB ? a : b;
    W.echoLast = w == a ? 1 : 2;
    w.rollDelay = w.style.echo + 0.08 * rnd(w);
    w.rollDir = dir;
}

// rail point -> world; RAIL_WORLD_2 / _3: rail right x / z
let RAIL_WORLD_2: f64 = 0;
let RAIL_WORLD_3: f64 = 0;

function railWorld(s: f64, x: f64, y: f64): Vector {
    track.frame(level.track, s);
    let tp = track.FRAME_P, rt = track.FRAME_R;
    RAIL_WORLD_2 = <f64>rt.x;
    RAIL_WORLD_3 = <f64>rt.z;
    return mathx.v3(<f64>tp.x + <f64>rt.x * x, <f64>tp.y + y, <f64>tp.z + <f64>rt.z * x);
}

// The rock near a stretch of rail (s0..s1, rail x x0..x1, up to y1), into
// `out`: his probes test only these. Baked chunks only (scenery.collide
// bakes an unbaked chunk near the query on the spot, 30-50 ms measured on
// the look-ahead; and unbaked rock is not drawn yet). Collider bounds:
// collide.extent each time (Luau caches them by collider).
function gather(out: Array<Collider>, s0: f64, s1: f64, x0: f64, x1: f64, y1: f64, pad: f64): void {
    out.length = 1;
    let L = level.track.length - 1;
    let minx = HUGE, minz = HUGE, maxx = -HUGE, maxz = -HUGE, ty = -HUGE;
    for (let k = 0; k <= 2; k++) {
        track.frame(level.track, lclamp(s0 + (s1 - s0) * <f64>k * 0.5, 0, L));
        let tp = track.FRAME_P, rt = track.FRAME_R;
        let ax = <f64>tp.x + <f64>rt.x * x0, az = <f64>tp.z + <f64>rt.z * x0;
        let bx = <f64>tp.x + <f64>rt.x * x1, bz = <f64>tp.z + <f64>rt.z * x1;
        minx = lmin(lmin(minx, ax), bx);
        maxx = lmax(lmax(maxx, ax), bx);
        minz = lmin(lmin(minz, az), bz);
        maxz = lmax(lmax(maxz, az), bz);
        ty = lmax(ty, <f64>tp.y);
    }
    minx -= pad;
    minz -= pad;
    maxx += pad;
    maxz += pad;
    let top = ty + y1 + pad;
    let chunks = scenery.build();
    let e = collide.EXT;
    for (let ci = 1; ci < chunks.length; ci++) {
        let c = chunks[ci];
        let bb = c.bounds;
        if (c.ready && maxx >= bb.minx && minx <= bb.maxx && maxz >= bb.minz && minz <= bb.maxz && bb.miny <= top) {
            let cols = c.colliders;
            for (let j = 1; j < cols.length; j++) {
                let cl = cols[j];
                collide.extent(cl);
                if (maxx >= e[0] && minx <= e[3] && maxz >= e[2] && minz <= e[5] && e[1] <= top) {
                    out.push(cl);
                }
            }
        }
    }
}

// Rock at a rail point among `list` (gather): hit (returned), push-out
// normal, depth -> ROCK_IN_2..5.
let ROCK_IN_2: f64 = 0;
let ROCK_IN_3: f64 = 0;
let ROCK_IN_4: f64 = 0;
let ROCK_IN_5: f64 = 0;

function rockIn(list: Array<Collider>, s: f64, x: f64, y: f64, rad: f64): bool {
    if (list.length - 1 == 0) {
        ROCK_IN_2 = 0;
        ROCK_IN_3 = 0;
        ROCK_IN_4 = 0;
        ROCK_IN_5 = 0;
        return false;
    }
    let q = railWorld(lclamp(s, 0, level.track.length - 1), x, y);
    let qx = <f64>q.x, qy = <f64>q.y, qz = <f64>q.z;
    let best = 0.0, bx = 0.0, by = 0.0, bz = 0.0;
    for (let i = 1; i < list.length; i++) {
        collide.test(list[i], qx, qy, qz, rad);
        let d = collide.T_D;
        if (d > best) {
            best = d;
            bx = collide.T_NX;
            by = collide.T_NY;
            bz = collide.T_NZ;
        }
    }
    ROCK_IN_2 = bx;
    ROCK_IN_3 = by;
    ROCK_IN_4 = bz;
    ROCK_IN_5 = best;
    return best > 0;
}

// Rock his way across (dir: rail x) over the next 0.35 s, a barrier's
// push that way and his speed that way taken in: a barrier never pushes him
// into it (QA round 5: 0.15 s and 2 m out saw a stack too late at 40 m/s).
function rockAcross(w: Wing, s: f64, dir: f64): bool {
    if (w.near.length - 1 == 0) {
        return false;
    }
    let rad = w.size * 0.4 + 0.3;
    let vo = lmax(0, w.vx * dir);
    return rockIn(w.near, s + w.sv * 0.15, w.x + dir * (2 + vo * 0.15), w.y, rad)
        || rockIn(w.near, s + w.sv * 0.35, w.x + dir * (2 + vo * 0.35), w.y, rad);
}

// s ahead his way is probed for rock, every PROBE_DS m along the rail at most
const PROBE_T: f64 = 1.1;
const PROBE_DS: f64 = 6;
// m of air he keeps off rock past his own radius (0.4 x size)
const ROCK_PAD: f64 = 1.0;

// Screen-space keeper (optional; the core implements it): world -> (u, v, w)
// like R.project (project returns u, sets pjU / pjV / pjD), and the half
// width of the hero safe zone in NDC (landscape 0.4, portrait 0.5).
export abstract class Keeper {
    halfW: f64 = 0;
    pjU: f64 = 0;
    pjV: f64 = 0;
    pjD: f64 = 0;
    abstract project(x: f64, y: f64, z: f64): f64;
}

// The lead's figure on screen (W.fU.., once a frame): the painted sprite
// (3.4 m, facing the lens) rolled with him, as a box off his centre: FIG_W
// across (hands, the scarf), FIG_UP to the helmet's top, FIG_DN to the
// boots (the painted poses, measured), at the sprite's own u / v per metre
// (the projection's derivatives across the line of sight: exact off the
// middle of the screen; QA round 4: a box on the rail's axes left out the
// helmet in portrait, world up is ~0.7x as tall on screen there).
const FIG_W: f64 = 1.35;
const FIG_UP: f64 = 1.45;
const FIG_DN: f64 = 1.45;
// a wingman's own box (x his size: half across, half up / down)
const WING_W: f64 = 0.36;
const WING_H: f64 = 0.45;

function figure(W: Wingmen, keep: Keeper?, p: Player): void {
    W.figOk = false;
    if (keep == null) {
        return;
    }
    let P = p.pos;
    let Px = <f64>P.x, Py = <f64>P.y, Pz = <f64>P.z;
    keep.project(Px, Py, Pz);
    let u0 = keep.pjU, v0 = keep.pjV, z0 = keep.pjD;
    if (z0 <= 0.5) {
        return;
    }
    let e = 0.05;
    keep.project(Px + e, Py, Pz);
    let u1 = keep.pjU, v1 = keep.pjV, z1 = keep.pjD;
    keep.project(Px, Py + e, Pz);
    let u2 = keep.pjU, v2 = keep.pjV, z2 = keep.pjD;
    keep.project(Px, Py, Pz + e);
    let u3 = keep.pjU, v3 = keep.pjV, z3 = keep.pjD;
    if (z1 <= 0 || z2 <= 0 || z3 <= 0) {
        return;
    }
    // (the lens's forward: the depth's gradient; u / v across it)
    let fx = z1 - z0, fy = z2 - z0, fz = z3 - z0;
    let fl = Math.sqrt(fx * fx + fy * fy + fz * fz);
    if (fl < 1e-7) {
        return;
    }
    fx = fx / fl;
    fy = fy / fl;
    fz = fz / fl;
    let ax = u1 - u0, ay = u2 - u0, az = u3 - u0;
    let d = ax * fx + ay * fy + az * fz;
    ax = ax - d * fx;
    ay = ay - d * fy;
    az = az - d * fz;
    let bx = v1 - v0, by = v2 - v0, bz = v3 - v0;
    d = bx * fx + by * fy + bz * fz;
    bx = bx - d * fx;
    by = by - d * fy;
    bz = bz - d * fz;
    let ku = Math.sqrt(ax * ax + ay * ay + az * az) / e;
    let kv = Math.sqrt(bx * bx + by * by + bz * bz) / e;
    // (rolled with him: the painted hero's billboard roll)
    let rl = p.bank * 0.12 + p.roll;
    let c = Math.abs(Math.cos(rl)), s = Math.abs(Math.sin(rl));
    let hm = (FIG_UP + FIG_DN) * 0.5;
    let off = (FIG_UP - FIG_DN) * 0.5 * c;
    let ex = FIG_W * c + hm * s;
    let ey = FIG_W * s + hm * c;
    W.figOk = true;
    W.fU = u0;
    W.fV = v0;
    W.fZ = z0;
    W.fKu = ku;
    W.fKv = kv;
    W.fL = ex * ku;
    W.fR = ex * ku;
    W.fT = (ey + off) * kv;
    W.fB = (ey - off) * kv;
}

// A wingman at wp against the lead's figure (needs W.figOk): ok (returned),
// his offset from its centre on screen (du, dv; v down), the room his box
// needs off it that way across / up-down (nu, nv), his u / v per metre (kw,
// kvw: the sprite's, at his depth) and where he is on screen -> FIG_AT_2..9.
let FIG_AT_2: f64 = 0;
let FIG_AT_3: f64 = 0;
let FIG_AT_4: f64 = 0;
let FIG_AT_5: f64 = 0;
let FIG_AT_6: f64 = 0;
let FIG_AT_7: f64 = 0;
let FIG_AT_8: f64 = 0;
let FIG_AT_9: f64 = 0;

function figAt(W: Wingmen, keep: Keeper, wp: Vector, size: f64): bool {
    keep.project(<f64>wp.x, <f64>wp.y, <f64>wp.z);
    let wu = keep.pjU, wv = keep.pjV, wz = keep.pjD;
    if (!W.figOk || wz <= 0.5) {
        FIG_AT_2 = 0;
        FIG_AT_3 = 0;
        FIG_AT_4 = 1;
        FIG_AT_5 = 1;
        FIG_AT_6 = 1;
        FIG_AT_7 = 1;
        FIG_AT_8 = wu;
        FIG_AT_9 = wv;
        return false;
    }
    let k = W.fZ / wz;
    let kw = W.fKu * k, kvw = W.fKv * k;
    let du = wu - W.fU, dv = wv - W.fV;
    let nu = (du < 0 ? W.fL : W.fR) + WING_W * size * kw;
    let nv = (dv < 0 ? W.fT : W.fB) + WING_H * size * kvw;
    FIG_AT_2 = du;
    FIG_AT_3 = dv;
    FIG_AT_4 = nu;
    FIG_AT_5 = nv;
    FIG_AT_6 = kw;
    FIG_AT_7 = kvw;
    FIG_AT_8 = wu;
    FIG_AT_9 = wv;
    return true;
}

// The frame his slot keeps inside (u / v 0..1, v down): out of the top 30%
// (the alert banner and the docked comms window, QA PT2: VI behind the
// banner on a third of the formation), the bottom edge risen in portrait
// over the touch controls (DIRECTION #16). COMF_*: where his slot sits
// comfortably; past it he answers the lead (sooner the further out).
const EDGE_U: f64 = 0.08;
const EDGE_TOP: f64 = 0.29;
const EDGE_BOT: f64 = 0.88;
const EDGE_BOT_P: f64 = 0.66;
const COMF_U: f64 = 0.13;
const COMF_U_P: f64 = 0.12;
const COMF_TOP: f64 = 0.32;
const COMF_BOT: f64 = 0.8;
const COMF_BOT_P: f64 = 0.6;
// s ahead his slot is checked against the comfort zone (x1.5 portrait)
const COMF_T: f64 = 0.3;
// m the lead may move off where he keeps him before he answers (sideways,
// up / down; landscape, portrait): within it he holds his slot
const BAND_X: f64 = 6;
const BAND_X_P: f64 = 4;
const BAND_Y: f64 = 4;
const BAND_Y_P: f64 = 3;
// m: he keeps at least this far to his own side of the lead (his target,
// on the lead his reflex sees; himself, on the lead now)
const SIDE_MIN: f64 = 2.5;
const SIDE_HARD: f64 = 2;
// m/s^2: his barriers let him close on their line only as fast as he could
// stop in the room left: the lead's side (rail), the lead's figure on screen
// (soft and early: a last-moment 400 m/s^2 dodge read as a dash)
const BAR_ACC: f64 = 110;
const FIG_ACC: f64 = 220;
// the frame's edge on him (u 0..1, his box whole inside; past the comfort
// zone and the target's edge: late, he may be, never off it), m/s^2
const EDGE_B: f64 = 0.05;
const EDGE_ACC: f64 = 120;
// The comms card while a line is on air: its foot is the frame's top over
// its span (QA playtest 3: HANK's landscape slot is where the card is drawn,
// inside it 40-52% of the time on air, drawn over him). 1/s it eases in /
// out, held CARD_HOLD s past a line (half the gaps between lines are under
// 2 s); his box clear under its foot by CARD_PAD; eased in across over
// CARD_SOFT of overlap (screen); his slide out from under it, m/s^2 (no
// kick)
const CARD_IN: f64 = 14;
const CARD_OUT: f64 = 1.2;
const CARD_HOLD: f64 = 1.5;
const CARD_PAD: f64 = 0.012;
const CARD_SOFT: f64 = 0.03;
const CARD_ACC: f64 = 150;
// (m over the floor the lowest he goes under it)
const CARD_LOW: f64 = 0.1;
// m/s: the most a barrier / a shove changes his speed in a frame (60 fps);
// the figure's less: a sweep at him faster than that passes in front of him
// (he is drawn under the lead) rather than kick him away (QA round 4: dozens
// of capped kicks a run)
const BAR_DV: f64 = 9;
const FIG_DV: f64 = 7;
// he keeps his own box off the lead's figure on screen by at most CLR_MAX
// m, held CLR_HOLD s
const CLR_MAX: f64 = 6;
const CLR_HOLD: f64 = 0.5;
// (x the room: where he starts to ease away; where his barrier stops him)
const CLR_M: f64 = 1.15;
const FIG_PAD: f64 = 1.2;
// m: the highest he flies (the lead's box tops out at 32), the furthest
// across, the lowest (the rail's floor: closed on no faster than he could
// stop on it)
const CEIL: f64 = 38;
const X_MAX: f64 = 34;
const FLOOR: f64 = 1.4;
// m: VI and HANK keep this far apart
const SEP: f64 = 7;

// The rock guard: his way at his own speed over the next GUARD_T s (`n`
// steps of GUARD_T / 5; 5 by default), `ax` / `ay` m/s^2 held on it
// (across, up) up to `vmax`: the first step in rock (0 = clear; more =
// sooner), where across it ends and (`all`: looked over to its end) how
// much rock it meets (its steps' depths, m). GUARD_X / Y: the ways he may
// turn off it; GUARD_NR: m past his radius the rock's normal is read for
// them.
const GUARD_T: f64 = 0.4;
const GUARD_X: Array<f64> = [0.0, -1, 1, 0, 0, -0.71, 0.71, -0.71, 0.71];
const GUARD_Y: Array<f64> = [0.0, 0, 0, 1, -1, 0.71, 0.71, -0.71, -0.71];
const GUARD_NR: f64 = 2;
// (each way's score this frame; HUGE: not a way)
const GUARD_S: Array<f64> = zeros(9);

// returns the first step in rock; GUARD_HIT_2 / _3: where across it ends, rock met
let GUARD_HIT_2: f64 = 0;
let GUARD_HIT_3: f64 = 0;

// n: NaN = 5; all: Luau nil = false
function guardHit(w: Wing, s: f64, vx: f64, vy: f64, ax: f64, ay: f64, vmax: f64, rad: f64, n: f64 = NaN, all: bool = false): f64 {
    let x = w.x, y = w.y, h = GUARD_T / 5;
    let k = isNaN(n) ? 5.0 : n;
    let first = 0.0, cnt = 0.0;
    for (let i = 1; <f64>i <= k; i++) {
        let fi = <f64>i;
        let vx1 = vx + ax * h, vy1 = vy + ay * h;
        let v = Math.sqrt(vx1 * vx1 + vy1 * vy1);
        if (v > vmax) {
            vx1 = vx1 * vmax / v;
            vy1 = vy1 * vmax / v;
        }
        x += (vx + vx1) * 0.5 * h;
        y = lmax(y + (vy + vy1) * 0.5 * h, FLOOR);
        vx = vx1;
        vy = vy1;
        let hit = rockIn(w.near, s + w.sv * h * fi, x, y, rad);
        let d = ROCK_IN_5;
        if (hit) {
            if (!all) {
                GUARD_HIT_2 = x;
                GUARD_HIT_3 = d;
                return k + 1 - fi;
            }
            if (first == 0) {
                first = k + 1 - fi;
            }
            cnt += d;
        }
    }
    GUARD_HIT_2 = x;
    GUARD_HIT_3 = cnt;
    return first;
}

// Steps of his way the guard looks over at this speed: GUARD_T, or as long
// as his whole dodge takes to stop him and 0.1 s (QA: at 50 m/s a stack
// 0.5 s out was past the look and past stopping when it came in).
function guardN(vx: f64, vy: f64, ga: f64): f64 {
    return lclamp(Math.ceil((Math.sqrt(vx * vx + vy * vy) / ga + 0.1) * 5 / GUARD_T), 5, 10);
}

// Where on screen a rail point lands (u returned; SCREEN_2 / _3: v, z; z <=
// 0: behind the lens).
let SCREEN_2: f64 = 0;
let SCREEN_3: f64 = 0;

function screen(keep: Keeper, s: f64, x: f64, y: f64): f64 {
    let q = railWorld(lmin(s, level.track.length - 1), x, y);
    keep.project(<f64>q.x, <f64>q.y, <f64>q.z);
    SCREEN_2 = keep.pjV;
    SCREEN_3 = keep.pjD;
    return keep.pjU;
}

// A point on the rail (s, x, y) moved back inside the frame's edges: x / y
// shifted by what puts it on screen again (as is behind the lens). x
// returned, IN_FRAME_2: y.
let IN_FRAME_2: f64 = 0;

function inFrame(keep: Keeper, s: f64, x: f64, y: f64, por: f64): f64 {
    let u = screen(keep, s, x, y);
    let v = SCREEN_2, z = SCREEN_3;
    if (z <= 0) {
        IN_FRAME_2 = y;
        return x;
    }
    let eu = EDGE_U + 0.04 * por;
    if (u < eu || u > 1 - eu) {
        let k = screen(keep, s, x + 1, y) - u;
        if (Math.abs(k) > 1e-4) {
            x += mathx.clamp(((u < eu ? eu : 1 - eu) - u) / k, -12, 12);
        }
    }
    let bot = mathx.lerp(EDGE_BOT, EDGE_BOT_P, por);
    if (v < EDGE_TOP || v > bot) {
        screen(keep, s, x, y + 1);
        let v1 = SCREEN_2;
        let k = v1 - v;
        if (Math.abs(k) > 1e-4) {
            y += mathx.clamp(((v < EDGE_TOP ? EDGE_TOP : bot) - v) / k, -12, 12);
        }
    }
    IN_FRAME_2 = y;
    return x;
}

// The comms card on air over a box at u (half width hw): its weight, eased
// in as their spans meet across.
function cardW(W: Wingmen, u: f64, hw: f64): f64 {
    if (W.cardK < 0.002) {
        return 0;
    }
    return W.cardK * mathx.smoothstep(0, CARD_SOFT, lmin(u + hw - W.cU0, W.cU1 - u + hw));
}

// The frame's top for his centre at u (box hw / hh): `top`, or the comms
// card's foot over him.
function cardTop(W: Wingmen, u: f64, hw: f64, hh: f64, top: f64): f64 {
    let f = cardW(W, u, hw);
    if (f <= 0) {
        return top;
    }
    return mathx.lerp(top, lmax(top, W.cV1 + hh + CARD_PAD), f);
}

// The lowest his centre at u (box hw / hh) goes under the comms card: over
// the lead's figure, its top (FIG_PAD; squeezed between them, the card
// gives way: hidden either way, and over him the lead's sweeps pass under).
function cardLow(W: Wingmen, u: f64, hw: f64, hh: f64): f64 {
    if (W.figOk && Math.abs(u - W.fU) < ((u < W.fU ? W.fL : W.fR) + hw) * FIG_PAD) {
        return W.fV - (W.fT + hh) * FIG_PAD;
    }
    return 2;
}

// His target (tx, ty; rate up tvy) out under the comms card on air: his box
// under its foot, as far as the floor (CARD_LOW m over it) and the lead's
// figure allow; eased with it. ty returned, UNDER_CARD_2: tvy.
let UNDER_CARD_2: f64 = 0;

function underCard(W: Wingmen, w: Wing, keep: Keeper, s: f64, tx: f64, ty: f64, tvy: f64): f64 {
    let u = screen(keep, s, tx, ty);
    let v = SCREEN_2, z = SCREEN_3;
    screen(keep, s, tx, ty + 1);
    let v1 = SCREEN_2;
    if (z <= 0 || v1 - v > -1e-4) {
        UNDER_CARD_2 = tvy;
        return ty;
    }
    let kv = v - v1;
    let hw = WING_W * w.size * Math.abs(screen(keep, s, tx + 1, ty) - u), hh = WING_H * w.size * kv;
    let f = cardW(W, u, hw);
    let dn = lmin(W.cV1 + hh + CARD_PAD, cardLow(W, u, hw, hh)) - v;
    if (f <= 0 || dn <= 0) {
        UNDER_CARD_2 = tvy;
        return ty;
    }
    UNDER_CARD_2 = tvy - lmax(tvy, 0) * f;
    return ty - f * lclamp(dn / kv, 0, lmax(ty - FLOOR - CARD_LOW, 0));
}

// Out of rock / off the lead along (l, n) (rail x, up) at up to `rate` m/s
// past his own speed that way: a quick slide, never a jump.
function shoveOut(w: Wing, l: f64, n: f64, rate: f64, dt: f64): void {
    let vo = w.vx * l + w.vy * n;
    let extra = lmin(rate - vo, BAR_DV * dt * 60);
    if (extra > 0) {
        w.vx += l * extra;
        w.vy += n * extra;
        w.x += l * extra * dt;
        w.y += n * extra * dt;
    }
}

// His slot off where he keeps the lead (sxM / syM; the fight's height and
// width eased in): x returned, SLOT_OF_2 / _3: y, depth.
let SLOT_OF_2: f64 = 0;
let SLOT_OF_3: f64 = 0;

function slotOf(w: Wing, por: f64): f64 {
    let s = mathx.lerp(w.slotS, w.style.slotP[3], por);
    SLOT_OF_2 = mathx.lerp(w.syM, w.style.fightY, w.fk);
    SLOT_OF_3 = s;
    return w.sxM * (1 + 0.15 * w.fk);
}

// The slot as designed for the frame (landscape -> portrait), before the
// lens's scale is known: x returned, SLOT_RAW_2: y.
let SLOT_RAW_2: f64 = 0;

function slotRaw(w: Wing, por: f64): f64 {
    let sp = w.style.slotP;
    SLOT_RAW_2 = mathx.lerp(w.slotY, sp[2], por);
    return mathx.lerp(w.slotX, sp[1], por);
}

// Rock ahead (every other frame, staggered): the way to where his answer
// ends (ex, ey; his target while he holds) is probed PROBE_T s out (from
// where he is, at the rate he can turn); blocked, he takes the cheapest
// clear lane from where he is (LANES across, LIFTS up / down): off where
// his answer ends, off the frame's comfort zone, the lead's figure,
// his side and the other wingman cost more (looked over in order of how
// far off his slot they are); the way he took is kept while it stays clear,
// looked over again every 0.25 s (two ways at once took him into the stack
// between them); none clear with 1 m to spare, a tighter pass; none in the
// frame, one past its edge (rock first: the frame held VI's way round a
// stack and pulled her back into it); none at all, the one that runs into
// rock last. Each way is probed where the frame holds it. As offsets on
// his target (the way held where it is on the rail), eased in at 10/s,
// held 0.7 s, out at 2.5/s (at once when it leads into rock).
const LANES: Array<f64> = [0.0, 0, -3, 3, -6, 6, -9, 9, -13, 13, -18, 18];
const LIFTS: Array<f64> = [0.0, 0, 6, -4, 12, 20];
// (rockPlan's lanes: x, y, cost off his slot; reused; 1-based)
const CAND_X: Array<f64> = zeros(64);
const CAND_Y: Array<f64> = zeros(64);
const CAND_C: Array<f64> = zeros(64);
// (where the frame holds each: worked out once a plan, as needed)
const CAND_HX: Array<f64> = zeros(64);
const CAND_HY: Array<f64> = zeros(64);

// His way to (cx, cy) over the next PROBE_T s, from where he is and where
// his speed takes him, turning at `acc` m/s^2: the first probe in rock (0 =
// clear; earlier = worse). Probed closer while he crosses fast (a 20 m/s
// answer slipped between probes into a thin stack).
function laneHit(w: Wing, cx: f64, cy: f64, rad: f64, acc: f64): f64 {
    let list = w.near;
    let n = lclamp(Math.ceil(lmax(lmax(Math.abs(w.sv), 3 * Math.abs(w.vx)), 3 * Math.abs(w.vy)) * PROBE_T / PROBE_DS), 5, 16);
    for (let i = 1; <f64>i <= n; i++) {
        let tau = PROBE_T * <f64>i / n;
        let r = 0.5 * acc * tau * tau;
        let fx = w.x + w.vx * tau, fy = w.y + w.vy * tau;
        let x = lclamp(cx, fx - r, fx + r);
        let y = lmax(lclamp(cy, fy - r, fy + r), 1);
        if (rockIn(list, w.s + w.sv * tau, x, y, rad)) {
            return n + 1 - <f64>i;
        }
    }
    return 0;
}

// (JOB 27) laneHit inside rockPlan: there his s, x, y, speed and w.near stay put, so every lane is probed at the same
// n points along the rail. The rail frame at each, his course there and its time are worked out once a plan
// (planOpen); a probe stops at the first rock (laneHit asks only whether there is any); and each point's answer is
// kept for the rest of the plan (lanes, passes and the way he took meet the same points: his course clamps the early
// probes to a few). The same expressions on the same values as laneHit / rockIn / railWorld, so the same answers to
// the bit (docs/qa/WINGMEN_PERF_JOB27.md).
let PP_N: f64 = 0;
const PP_TAU: Array<f64> = zeros(17);
const PP_FX: Array<f64> = zeros(17);
const PP_FY: Array<f64> = zeros(17);
const PP_S: Array<f64> = zeros(17);
// (the rail frame at probe i: worked out on its first use, PP_F[i] = the plan it was worked out for)
const PP_F: Array<f64> = zeros(17);
const PP_TPX: Array<f64> = zeros(17);
const PP_TPY: Array<f64> = zeros(17);
const PP_TPZ: Array<f64> = zeros(17);
const PP_RTX: Array<f64> = zeros(17);
const PP_RTZ: Array<f64> = zeros(17);
let PP_ID: f64 = 0;
// (the answers: per radius (the plan's two, rad and tight) and probe, exact x -> its first entry, then the entries'
// y / answer / next (0: none); never x = 0 (+0 and -0 are one key) nor NaN (no key); y is >= 1 or NaN, never +-0.
// 2 x 16 maps: sized for laneHit's 16-probe cap; 1-based)
let PP_R1: f64 = 0;
let PP_R2: f64 = 0;
function makeMaps(): Array<Map<f64, i32>> {
    let a = new Array<Map<f64, i32>>(0);
    for (let k = 0; k <= 32; k++) {
        a.push(new Map<f64, i32>());
    }
    return a;
}
const PP_MAP: Array<Map<f64, i32>> = makeMaps();
const PM_Y: Array<f64> = zeros(257);
const PM_HIT: Array<bool> = new Array<bool>(257);
const PM_NEXT: Array<i32> = new Array<i32>(257);
let PM_N: i32 = 0;

// (n, the probes' times and the tight radius repeat laneHit's / rockPlan's: change them together)
function planOpen(w: Wing, rad: f64, tight: f64): void {
    let n = lclamp(Math.ceil(lmax(lmax(Math.abs(w.sv), 3 * Math.abs(w.vx)), 3 * Math.abs(w.vy)) * PROBE_T / PROBE_DS), 5, 16);
    PP_N = n;
    PP_ID += 1;
    PP_R1 = rad;
    PP_R2 = tight;
    if (PM_N > 0) {
        for (let k = 1; k <= 32; k++) {
            PP_MAP[k].clear();
        }
        PM_N = 0;
    }
    for (let i = 1; <f64>i <= n; i++) {
        let tau = PROBE_T * <f64>i / n;
        PP_TAU[i] = tau;
        PP_FX[i] = w.x + w.vx * tau;
        PP_FY[i] = w.y + w.vy * tau;
        PP_S[i] = w.s + w.sv * tau;
    }
}

// (one probe: rock at point i, x, y with radius rad among w.near, as rockIn says)
function planProbe(list: Array<Collider>, i: i32, x: f64, y: f64, rad: f64): bool {
    if (PP_F[i] != PP_ID) {
        track.frame(level.track, lclamp(PP_S[i], 0, level.track.length - 1));
        let tp = track.FRAME_P, rt = track.FRAME_R;
        PP_F[i] = PP_ID;
        PP_TPX[i] = <f64>tp.x;
        PP_TPY[i] = <f64>tp.y;
        PP_TPZ[i] = <f64>tp.z;
        PP_RTX[i] = <f64>rt.x;
        PP_RTZ[i] = <f64>rt.z;
    }
    let q = mathx.v3(PP_TPX[i] + PP_RTX[i] * x, PP_TPY[i] + y, PP_TPZ[i] + PP_RTZ[i] * x);
    let qx = <f64>q.x, qy = <f64>q.y, qz = <f64>q.z;
    for (let j = 1; j < list.length; j++) {
        collide.test(list[j], qx, qy, qz, rad);
        if (collide.T_D > 0) {
            return true;
        }
    }
    return false;
}

// (only inside rockPlan, after planOpen for this wing)
function planHit(w: Wing, cx: f64, cy: f64, rad: f64, acc: f64): f64 {
    let list = w.near;
    let n = PP_N;
    let slot = rad == PP_R1 ? 0 : rad == PP_R2 ? 16 : -1;
    for (let i = 1; <f64>i <= n; i++) {
        let tau = PP_TAU[i];
        let r = 0.5 * acc * tau * tau;
        let fx = PP_FX[i], fy = PP_FY[i];
        let x = lclamp(cx, fx - r, fx + r);
        let y = lmax(lclamp(cy, fy - r, fy + r), 1);
        let hit: bool;
        if (slot >= 0 && x != 0 && !isNaN(x)) {
            let m = PP_MAP[slot + i];
            let first = getOr<f64>(m, x, 0);
            let e = first;
            while (e > 0 && PM_Y[e] != y) {
                e = PM_NEXT[e];
            }
            if (e > 0) {
                hit = PM_HIT[e];
            } else {
                hit = planProbe(list, i, x, y, rad);
                PM_N += 1;
                if (PM_N >= PM_Y.length) {
                    PM_Y.push(0);
                    PM_HIT.push(false);
                    PM_NEXT.push(0);
                }
                PM_Y[PM_N] = y;
                PM_HIT[PM_N] = hit;
                PM_NEXT[PM_N] = first;
                m.set(x, PM_N);
            }
        } else {
            hit = planProbe(list, i, x, y, rad);
        }
        if (hit) {
            return n + 1 - <f64>i;
        }
    }
    return 0;
}

// (where the frame holds a point: rockPlan's `held`; x returned, HELD_2: y)
let HELD_2: f64 = 0;

function held(keep: Keeper?, sNow: f64, por: f64, cx: f64, cy: f64): f64 {
    if (keep != null) {
        let x = inFrame(keep, sNow, cx, cy, por);
        HELD_2 = IN_FRAME_2;
        return x;
    }
    HELD_2 = cy;
    return cx;
}

// (rockPlan's `cost` of a lane)
function laneCost(W: Wingmen, w: Wing, p: Player, keep: Keeper?, sNow: f64, por: f64, ex: f64, ey: f64, side: f64, cu: f64, mate: Wing?, cx: f64, cy: f64): f64 {
    // (aside costs more in portrait: a few metres there are the edge)
    let c = Math.abs(cx - ex) * (1 + por) + 1.3 * Math.abs(cy - ey);
    if (keep != null) {
        let u = screen(keep, sNow, cx, cy);
        let v = SCREEN_2, z = SCREEN_3;
        if (z > 0) {
            c += 150 * (lmax(lmax(0, cu - u), u - 1 + cu) + lmax(0, COMF_TOP - v));
            if (W.figOk && z > 0.5) {
                // (on the lead's figure)
                let k = W.fZ / z;
                let du = u - W.fU, dv = v - W.fV;
                let nu = (du < 0 ? W.fL : W.fR) + WING_W * w.size * W.fKu * k;
                let nv = (dv < 0 ? W.fT : W.fB) + WING_H * w.size * W.fKv * k;
                if (Math.abs(du) < nu * 1.1 && Math.abs(dv) < nv * 1.1) {
                    c += 150;
                }
            }
        }
    }
    // (the lead's other side: only when nothing on his own is clear)
    let o = (cx - p.x) * side;
    if (o < SIDE_MIN) {
        c += 120 + 10 * (SIDE_MIN - o);
    }
    if (mate != null) {
        let d = Math.abs(cx - mate.x) + Math.abs(cy - mate.y) + 0.5 * Math.abs(w.s - mate.s);
        c += 2 * lmax(0, SEP + 2 - d);
    }
    return c;
}

function rockPlan(W: Wingmen, w: Wing, p: Player, tx: f64, ty: f64, keep: Keeper?, sNow: f64, por: f64, ex: f64, ey: f64): void {
    let rad = w.size * 0.4 + ROCK_PAD;
    let side = w.slotX < 0 ? -1.0 : 1.0;
    let acc = w.style.acc * 0.6;
    gather(w.near, w.s - 2, w.s + w.sv * 1.2 + 4, lmin(lmin(lmin(w.x, tx), ex), p.x) - 20, lmax(lmax(lmax(w.x, tx), ex), p.x) + 20, lmax(lmax(w.y, ty), ey) + 14, rad);
    if (w.near.length - 1 == 0) {
        w.way = 0;
        return;
    }
    planOpen(w, rad, w.size * 0.4 + 0.3);
    let hx = held(keep, sNow, por, ex, ey);
    let hy = HELD_2;
    if (planHit(w, hx, hy, rad, acc) == 0) {
        // (his slot is clear: what is left of a way round eases out, at once
        // when it now leads into rock)
        w.way = 0;
        if ((Math.abs(w.avX) > 0.5 || Math.abs(w.avY) > 0.5) && planHit(w, tx + w.avX, ty + w.avY, rad, acc) > 0) {
            w.avGX = 0;
            w.avGY = 0;
            w.avT = 0.3;
        }
        return;
    }
    // (the way he took, while it stays clear: looked over again every 0.25 s)
    let wx = w.wayX, wy = w.wayY;
    if (w.way < 2) {
        wx = held(keep, sNow, por, wx, wy);
        wy = HELD_2;
    }
    let keepWay = w.avT > 0 && w.way > 0 && planHit(w, wx, wy, rad, acc) == 0;
    if (keepWay && w.planT > 0) {
        w.avGX = mathx.clamp(wx - tx, -18, 18);
        w.avGY = mathx.clamp(wy - ty, -24, 24);
        w.avT = 0.7;
        return;
    }
    w.planT = 0.25;
    let mate: Wing? = null;
    for (let oi = 1; oi < W.list.length; oi++) {
        let o = W.list[oi];
        if (o != w && o.phase == "form") {
            mate = o;
        }
    }
    let cu = mathx.lerp(COMF_U, COMF_U_P, por);
    // (the lanes in order of how far off his slot they are: past the
    // cheapest clear one found, no other can beat it)
    let CX = CAND_X, CY = CAND_Y, CC = CAND_C;
    let nc = 0;
    for (let li = 1; li < LIFTS.length; li++) {
        let cy = lclamp(w.y + LIFTS[li], 2, CEIL - 1);
        for (let la = 1; la < LANES.length; la++) {
            let cx = mathx.clamp(w.x + LANES[la], -X_MAX + 1, X_MAX - 1);
            let c0 = Math.abs(cx - ex) * (1 + por) + 1.3 * Math.abs(cy - ey);
            nc += 1;
            let j = nc;
            while (j > 1 && CC[j - 1] > c0) {
                CX[j] = CX[j - 1];
                CY[j] = CY[j - 1];
                CC[j] = CC[j - 1];
                j -= 1;
            }
            CX[j] = cx;
            CY[j] = cy;
            CC[j] = c0;
        }
    }
    let bx = tx, by = ty, bc = HUGE, bw = 1.0;
    let lx = tx, ly = ty, lh = HUGE, lw = 1.0;
    // (none clear with room to spare, or only past the lead or on his
    // figure: the tighter way through; none in the frame: past its edge;
    // none: turning as hard as he can dodge, in the frame, then past it (at
    // 0.6 of it VI found none over a stack's top as her slot sank onto it).
    // Past the edge only the lanes the frame would move: the rest were
    // probed as held)
    let tight = w.size * 0.4 + 0.3;
    let HX = CAND_HX, HY = CAND_HY;
    let nh = 0;
    for (let pass = 1; pass <= 5; pass++) {
        let out = pass == 3 || pass == 5;
        if (out && keep == null) {
            continue;
        }
        let rp = pass == 1 ? rad : tight;
        let pa = pass >= 4 ? w.style.acc * 1.3 : acc;
        let pc = pass == 1 ? 0.0 : pass == 2 ? 5.0 : 10.0;
        for (let i = 1; i <= nc; i++) {
            if (CC[i] + pc >= bc) {
                break;
            }
            while (nh < i) {
                nh += 1;
                HX[nh] = held(keep, sNow, por, CX[nh], CY[nh]);
                HY[nh] = HELD_2;
            }
            let cx = CX[i], cy = CY[i];
            if (!out) {
                cx = HX[i];
                cy = HY[i];
            } else if (HX[i] == cx && HY[i] == cy) {
                continue;
            }
            let h = planHit(w, cx, cy, rp, pa);
            if (h == 0) {
                let c = laneCost(W, w, p, keep, sNow, por, ex, ey, side, cu, mate, cx, cy) + pc;
                if (c < bc) {
                    bx = cx;
                    by = cy;
                    bc = c;
                    bw = out ? 2 : 1;
                }
            } else if (h < lh) {
                lx = cx;
                ly = cy;
                lh = h;
                lw = out ? 2 : 1;
            }
        }
        if (bc < 100) {
            break;
        }
    }
    // (the way he took, while it stays clear, unless one is much cheaper)
    if (keepWay && laneCost(W, w, p, keep, sNow, por, ex, ey, side, cu, mate, wx, wy) < bc + 8) {
        bx = wx;
        by = wy;
        bc = 0;
        bw = w.way;
    }
    if (bc == HUGE) {
        bx = lx;
        by = ly;
        bw = lw;
    }
    w.wayX = bx;
    w.wayY = by;
    w.way = bw;
    w.avGX = mathx.clamp(bx - tx, -18, 18);
    w.avGY = mathx.clamp(by - ty, -24, 24);
    w.avT = 0.7;
}

// His answer on one axis: a path of his own from where he keeps the lead
// (k, its rate and acceleration) to `to`, mBase s + 1 s per mSpd m (x urgK
// when forced, quicker past the frame's comfort zone), never quicker than
// his aacc / avmax (x scale) allow. False: nothing worth a move.
function answer(q: Plan, k: f64, kv: f64, ka: f64, to: f64, st: Style, urgent: bool, ctch: f64, scale: f64): bool {
    let D = Math.abs(to - k);
    if (D < 0.4) {
        return false;
    }
    let T = (st.mBase + D / st.mSpd) * (urgent ? st.urgK : 1) / (1 + st.catchK * ctch);
    // (a quintic's peak rate is 1.875 D / T, its peak acceleration 5.77 D / T^2)
    let vm = st.avmax * scale * (1 + 0.5 * ctch);
    let am = st.aacc * scale * (1 + ctch);
    T = lmax(lmax(lmax(T, 1.875 * D / vm), Math.sqrt(5.77 * D / am)), 0.25);
    planStart(q, k, kv, ka, to, T);
    return true;
}

// One wingman in formation, flying as himself (owner: 'they match my
// movements exactly instead of feeling like their own individuals'; QA PT2:
// each answered every sideways move in full ~0.2 s late, VI overshot; QA
// round 4: big moves still copied, the pair in step: where he kept the lead
// chased the lead as he saw it, at its rate, half the time).
// He sees the lead `delay` s late (smoothed over `tau`) and keeps him where
// he last settled on him (kx, ky): moves of the lead within BAND m (less where
// his slot would leave the comfort zone of the frame, or the lead's figure
// would come at him) he lets go by and holds his slot; past it he answers
// with a path of his own (`answer`: to where he sees the lead, a little
// ahead on its rate, VI quick, HANK late and slow), looked at again at most
// every mHold s; the lead sitting off for `settle` s he eases back on
// slowly. On that: his slot (beside the lead's figure on screen, at his
// share of the room), its variant, his own height, weave, rock offsets, and
// room off the lead's figure on screen (out or up over him, at clrV m/s);
// then his spring (the rock guard has the last word on his turn), his
// throttle, his barriers (the lead's side, the lead's figure, the frame's
// edge and the comms card on air on screen, the rail's floor: late he may
// be, never across them, never into rock) and rock push-out, as slides,
// never jumps.
function fly(W: Wingmen, w: Wing, wi: i32, p: Player, t: f64, dt: f64, keep: Keeper?): void {
    let st = w.style;
    let fight = W.fight;
    let side = w.slotX < 0 ? -1.0 : 1.0;
    let por = keep != null ? mathx.saturate((keep.halfW - 0.4) / 0.1) : 0.0;
    // (a narrow frame: a touch quicker; never changed in flight, what he saw
    // would jump)
    let quick = 1 - 0.1 * por;
    let MVX = playerMod.MAX_VX, MVY = playerMod.MAX_VY;
    histAt(W.hist, t, st.delay * quick);
    let hx = HIST_AT_1, hvx = HIST_AT_3;
    histAt(W.hist, t, st.vdelay * quick);
    let hy = HIST_AT_2, hvy = HIST_AT_4;
    // (a rock's shove on the lead is no rate to fly after him at)
    hvx = mathx.clamp(hvx, -MVX, MVX);
    hvy = mathx.clamp(hvy, -MVY, MVY);
    let kf = 1 - Math.exp(-dt / st.tau);
    w.fx += (hx - w.fx) * kf;
    w.fvx += (hvx - w.fvx) * kf;
    w.fy += (hy - w.fy) * kf;
    w.fvy += (hvy - w.fvy) * kf;
    histAt(W.hist, t, st.thrDelay * quick);
    let hv = HIST_AT_5, hbo = HIST_AT_6, hbr = HIST_AT_7;
    // the lead as his reflex sees him (coming at him)
    histAt(W.hist, t, st.reflex * quick);
    let rx = HIST_AT_1, rvx = HIST_AT_3;
    rvx = mathx.clamp(rvx, -MVX, MVX);
    w.fk = mathx.damp(w.fk, fight ? 1 : 0, 1.5, dt);
    let sx = slotOf(w, por);
    let sy = SLOT_OF_2, ss = SLOT_OF_3;
    ss *= w.depthK;
    let sNow = lmin(w.s, level.track.length - 1);
    // his own clock: slot variant, height, weave
    w.slotT -= dt;
    if (w.slotT <= 0) {
        let k = 1 + Math.floor(rnd(w) * <f64>(st.slots.length - 1 - 1));
        w.slotK = k >= w.slotK ? k + 1 : k;
        w.slotT = rndIn(w, st.slotT);
    }
    let o = st.slots[<i32>w.slotK];
    w.oX = mathx.damp(w.oX, o[1], st.slotV, dt);
    w.oY = mathx.damp(w.oY, o[2], st.slotV, dt);
    w.oS = mathx.damp(w.oS, o[3], st.slotV, dt);
    w.hT -= dt;
    if (w.hT <= 0) {
        w.hGoal = rndIn(w, st.heights);
        w.hT = rndIn(w, st.heightT);
    }
    w.hOff = mathx.damp(w.hOff, w.hGoal, st.heightV, dt);
    let wv = st.weave;
    let tt = t + w.seed * 7;
    let TAU = mathx.TAU;
    let dx = wv[1] * Math.sin(tt * wv[2] * TAU) + wv[3] * Math.sin(tt * wv[4] * TAU + 1.3);
    let dy = wv[5] * Math.sin(tt * wv[6] * TAU + 0.7) + wv[7] * Math.sin(tt * wv[8] * TAU + 2.1);
    let ds = wv[9] * Math.sin(tt * wv[10] * TAU + 0.4);
    // (narrow portrait frame: less of it sideways)
    let ownX = (side * w.oX + dx) * (1 - 0.4 * por);
    let ownY = (w.oY + w.hOff + dy) * (1 - 0.4 * por);
    let bandX = mathx.lerp(BAND_X, BAND_X_P, por);
    let bandY = mathx.lerp(BAND_Y, BAND_Y_P, por);
    // (the rail rate that holds his slot still on screen: the lens's drift)
    let holdX = 0.0, holdY = 0.0;
    // his answers, along their paths
    let qx = w.qx, qy = w.qy;
    if (qx.T > 0) {
        qx.t = lmin(qx.t + dt, qx.T);
        w.kx = planAt(qx, qx.t);
        w.kvx = PLAN_AT_2;
        w.kax = PLAN_AT_3;
        if (qx.t >= qx.T) {
            qx.T = 0;
            w.kvx = 0;
            w.kax = 0;
            w.modeX = 0;
            w.inX = false;
        }
    }
    if (qy.T > 0) {
        qy.t = lmin(qy.t + dt, qy.T);
        w.ky = planAt(qy, qy.t);
        w.kvy = PLAN_AT_2;
        w.kay = PLAN_AT_3;
        if (qy.t >= qy.T) {
            qy.T = 0;
            w.kvy = 0;
            w.kay = 0;
            w.modeY = 0;
        }
    }
    if (W.titleForm) {
        // echelon left of the hidden lead (the key art is the hero)
        w.kx = p.x;
        w.ky = p.y;
        w.kvx = p.vx;
        w.kvy = p.vy;
        w.kax = 0;
        w.kay = 0;
        qx.T = 0;
        qy.T = 0;
        w.modeX = 0;
        w.modeY = 0;
    } else {
        // (where he keeps the lead once his answer is made)
        let kxE = qx.T > 0 ? qx.to : w.kx;
        let kyE = qy.T > 0 ? qy.to : w.ky;
        // the frame's comfort zone: where his slot on the lead as he keeps
        // him lands on screen now; past it (m, the way back in) he answers,
        // harder the further out
        let pushX = 0.0, pushY = 0.0;
        let atFig = true;
        // (over the lead's figure on screen his slot keeps its box clear of
        // it: the lowest it may sit, the span across where that holds)
        let overV = 2.0, spanU = 0.0;
        if (keep != null) {
            let u = screen(keep, sNow, kxE + sx, kyE + sy);
            let v = SCREEN_2, z = SCREEN_3;
            if (z <= 0) {
                w.scrU = -1;
            } else {
                let cu = mathx.lerp(COMF_U, COMF_U_P, por);
                let bot = mathx.lerp(COMF_BOT, COMF_BOT_P, por);
                let ku = screen(keep, sNow, kxE + sx + 1, kyE + sy) - u;
                screen(keep, sNow, kxE + sx, kyE + sy + 1);
                let v1 = SCREEN_2;
                let kv = v1 - v;
                // (his slot's metres at the lens's scale: beside the lead's
                // figure (where it sits on screen, slowly), across `scr` of
                // the room between it and the comfort edge, up a share of
                // its top half; from the lead's line at his depth; eased so
                // it never moves him)
                let lu = screen(keep, sNow, p.x, p.y);
                let lv = SCREEN_2, lz = SCREEN_3;
                if (W.figOk && lz > 0.5) {
                    // (the lead's figure and his line at this depth, eased
                    // alike: a lead's move never shifts the slot itself)
                    if (w.layT <= 0) {
                        w.huS = W.fU;
                        w.hvS = W.fV;
                        w.luS = lu;
                        w.lvS = lv;
                    }
                    w.layT = 1;
                    w.huS = mathx.damp(w.huS, W.fU, 0.8, dt);
                    w.hvS = mathx.damp(w.hvS, W.fV, 0.8, dt);
                    w.luS = mathx.damp(w.luS, lu, 0.8, dt);
                    w.lvS = mathx.damp(w.lvS, lv, 0.8, dt);
                    let lku = screen(keep, sNow, p.x + 1, p.y) - lu;
                    screen(keep, sNow, p.x, p.y + 1);
                    let lv1 = SCREEN_2;
                    let lkv = lv1 - lv;
                    if (Math.abs(lku) > 1e-4 && lkv < -1e-4) {
                        let k = W.fZ / lz;
                        let hw = WING_W * w.size * W.fKu * k, hh = WING_H * w.size * W.fKv * k;
                        let sc = st.scr;
                        let needU = (side < 0 ? W.fL : W.fR) + hw + 0.01;
                        let inner = w.huS + side * needU;
                        let ut = w.huS + side * lmax((mathx.lerp(inner, 0.5 + side * (0.5 - cu), mathx.lerp(sc[1], sc[2], por)) - w.huS) * side, needU);
                        let vt = w.hvS - mathx.lerp(sc[3], sc[4], por) * (W.fT + hh + 0.01);
                        vt = mathx.clamp(vt, COMF_TOP + 0.03, bot - hh);
                        let needM = (ut - w.luS) / lku * side;
                        w.sxM = mathx.damp(w.sxM, side * mathx.clamp(needM, 4.5, 16), 0.8, dt);
                        // (the rail bending away: far ahead, his side of the
                        // lead's line lands on the lead's figure, or past it,
                        // however wide he flies; he comes nearer)
                        w.depthK = mathx.damp(w.depthK, mathx.clamp(14 / lmax(needM, 1), 0.5, 1), 0.8, dt);
                        w.syM = mathx.damp(w.syM, mathx.clamp((vt - w.lvS) / lkv, -3, 8), 0.8, dt);
                        // (level with the lead's figure: it may come at him
                        // on screen only so far before his room runs out)
                        atFig = Math.abs(vt - w.hvS) < W.fT + hh;
                        w.roomIn = lmax(1, ((ut - w.huS) * side - needU * CLR_M) / Math.abs(lku));
                        if (W.fV - (W.fT + hh) * 1.05 > COMF_TOP + 0.04) {
                            overV = W.fV - (W.fT + hh) * 1.05;
                            spanU = needU;
                        }
                    }
                }
                // (and where it lands in COMF_T s as the lens drifts on: the
                // room runs out before he could answer. The drift is the
                // lens's own, measured on his slot held still: it follows
                // the lead late and only part of the way)
                let sxw = kxE + sx, syw = kyE + sy;
                if (w.scrU >= 0 && dt > 0) {
                    let du = (u - w.scrU - (sxw - w.scrX) * ku) / dt;
                    let dvv = (v - w.scrV - (syw - w.scrY) * kv) / dt;
                    if (Math.abs(du) < 3 && Math.abs(dvv) < 3) {
                        w.driftU = mathx.damp(w.driftU, du, 12, dt);
                        w.driftV = mathx.damp(w.driftV, dvv, 12, dt);
                    }
                }
                w.scrU = u;
                w.scrV = v;
                w.scrX = sxw;
                w.scrY = syw;
                if (Math.abs(ku) > 1e-4) {
                    holdX = mathx.clamp(-w.driftU / ku, -MVX, MVX);
                }
                if (Math.abs(kv) > 1e-4) {
                    holdY = mathx.clamp(-w.driftV / kv, -MVY, MVY);
                }
                let ct = COMF_T * (1 + 0.5 * por);
                let up = u + w.driftU * ct;
                let vp = v + w.driftV * ct;
                if (Math.abs(ku) > 1e-4) {
                    if (lmin(u, up) < cu) {
                        pushX = (cu - lmin(u, up)) / ku;
                    } else if (lmax(u, up) > 1 - cu) {
                        pushX = (1 - cu - lmax(u, up)) / ku;
                    }
                }
                if (Math.abs(kv) > 1e-4) {
                    if (lmin(v, vp) < COMF_TOP) {
                        pushY = (COMF_TOP - lmin(v, vp)) / kv;
                    } else if (lmax(v, vp) > bot) {
                        pushY = (bot - lmax(v, vp)) / kv;
                    } else if (lmax(v, vp) > overV && Math.abs(u - W.fU) < spanU) {
                        pushY = (overV - lmax(v, vp)) / kv;
                    }
                }
            }
            // (and how much of his own drift the frame leaves room for)
            let u2 = screen(keep, sNow, w.kx + sx + ownX, w.ky + sy + ownY);
            let v2 = SCREEN_2, z2 = SCREEN_3;
            let cu2 = mathx.lerp(COMF_U, COMF_U_P, por) - 0.03;
            let bot2 = mathx.lerp(COMF_BOT, COMF_BOT_P, por) + 0.03;
            let out = z2 > 0 && (u2 < cu2 || u2 > 1 - cu2 || v2 < COMF_TOP - 0.03 || v2 > bot2);
            w.own = mathx.damp(w.own, out ? 0.25 : 1, out ? 3 : 0.6, dt);
        } else {
            w.scrU = -1;
        }
        let cT = mathx.smoothstep(0.2, 3, lmax(Math.abs(pushX), Math.abs(pushY) * 1.5));
        w.catch = mathx.damp(w.catch, cT, cT > w.catch ? 10 : 3, dt);
        // sideways: hold, or answer on his own path: the lead coming at him
        // past his room (his reflex, a little ahead on its rate), his slot
        // leaving the frame's comfort zone, the lead off past his band
        let bandIn = lmax(1.5, lmin(lmin(bandX, Math.abs(sx) + side * ownX * w.own - SIDE_MIN - 1), atFig ? w.roomIn : bandX));
        let needX = 0;
        if ((rx - kxE) * side > bandIn) {
            needX = 2;
        } else if (Math.abs(pushX) > 0.2) {
            needX = 3;
        } else if (Math.abs(w.fx - kxE) > bandX) {
            needX = 1;
        }
        if (needX > 0 && (qx.T <= 0 || qx.t >= st.mHold * (needX > 1 ? 0.5 : 1))) {
            // (narrow portrait frame: less of the lead's rate)
            let lead = st.lead * (1 - 0.5 * por);
            let to = w.fx + w.fvx * lead;
            if (needX == 2) {
                // (the lead coming at him: out of the way of where the lead
                // will be as his answer ends, then he holds)
                let Te = (st.mBase + Math.abs(rx - w.kx) / st.mSpd) * st.urgK;
                to = rx + mathx.clamp(rvx * (lead + 0.5 * Te), -10, 10);
            }
            if (needX == 3) {
                // (the frame: at least back inside its comfort zone, and on
                // with the lens's drift over his answer: a long sweep away
                // from him ran on and left him behind the lens's edge)
                to = pushX > 0 ? lmax(to, kxE + pushX * 1.2) : lmin(to, kxE + pushX * 1.2);
                if (holdX * pushX > 0) {
                    to += holdX * 0.7 * (st.mBase + Math.abs(to - w.kx) / st.mSpd) * st.urgK / (1 + st.catchK * w.catch);
                }
            }
            if (answer(qx, w.kx, w.kvx, w.kax, to, st, needX > 1, w.catch, needX == 2 ? 1.5 : needX == 3 ? 1.3 : 1)) {
                w.modeX = 1;
                w.inX = needX == 2;
                w.offX = 0;
            }
        } else if (qx.T <= 0) {
            // (the lead sitting off where he keeps him, quiet, for `settle`
            // s: he eases back on, slowly)
            if (Math.abs(w.fx - w.kx) > 1.5 && Math.abs(w.fvx) < 4) {
                w.offX += dt;
                if (w.offX > st.settle) {
                    w.offX = 0;
                    let D = Math.abs(w.fx - w.kx);
                    planStart(qx, w.kx, 0, 0, w.fx, 1.2 + D / 5);
                    w.modeX = 2;
                }
            } else {
                w.offX = 0;
            }
        }
        // up / down: the same, his band and the frame's
        let needY = 0;
        if (Math.abs(pushY) > 0.2) {
            needY = 3;
        } else if (Math.abs(w.fy - kyE) > bandY) {
            needY = 1;
        }
        if (needY > 0 && (qy.T <= 0 || qy.t >= st.mHold * (needY > 1 ? 0.5 : 1))) {
            let to = w.fy + w.fvy * st.leadY;
            if (needY == 3) {
                to = pushY > 0 ? lmax(to, kyE + pushY * 1.2) : lmin(to, kyE + pushY * 1.2);
                if (holdY * pushY > 0) {
                    to += holdY * 0.7 * (st.mBase + Math.abs(to - w.ky) / st.mSpd) * st.urgK / (1 + st.catchK * w.catch);
                }
            }
            if (answer(qy, w.ky, w.kvy, w.kay, to, st, needY > 1, w.catch, 0.8)) {
                w.modeY = 1;
                w.offY = 0;
            }
        } else if (qy.T <= 0) {
            if (Math.abs(w.fy - w.ky) > 1 && Math.abs(w.fvy) < 3) {
                w.offY += dt;
                if (w.offY > st.settle) {
                    w.offY = 0;
                    let D = Math.abs(w.fy - w.ky);
                    planStart(qy, w.ky, 0, 0, w.fy, 1.2 + D / 4);
                    w.modeY = 2;
                }
            } else {
                w.offY = 0;
            }
        }
    }
    // rock offsets ease back once his way is clear
    w.avT = lmax(0, w.avT - dt);
    w.planT -= dt;
    // room off the lead's figure: toward its goal at clrV m/s, held, then back
    w.clrT = lmax(0, w.clrT - dt);
    if (w.clrT <= 0) {
        w.clrGX = 0;
        w.clrGY = 0;
    }
    let cr = w.clrT > 0 ? st.clrV : 3.0;
    w.clrX += mathx.clamp(w.clrGX - w.clrX, -cr * dt, cr * dt);
    w.clrY += mathx.clamp(w.clrGY - w.clrY, -cr * dt, cr * dt);
    let own = w.own;
    let cross = mathx.smoothstep(4, 16, Math.abs(w.kvx));
    let tx = w.kx + sx + ownX * own + w.clrX;
    let ty = w.ky + sy + ownY * own + (w.inX ? 1 : st.hop) * cross + w.clrY;
    let tvx = w.kvx, tvy = w.kvy;
    let rsT = ss + w.oS * own + ds;
    let rsLo = lmax(4, ss - 4);
    let heldX = false, heldY = false;
    if (W.titleForm) {
        let k = w.slotX < 0 ? 1.0 : 2.0;
        tx = p.x - 6.5 * k + dx * 0.5;
        ty = p.y + (k == 1 ? 1.8 : 0.4) + dy * 0.6;
        tvx = p.vx;
        tvy = p.vy;
        rsT = (k == 1 ? 2.0 : -4.0) + ds * 0.6;
        rsLo = rsT - 3;
    } else {
        // under the comms card while a line is on air (none of his answer's
        // climb into it)
        if (keep != null && W.cardK > 0.002) {
            ty = underCard(W, w, keep, sNow, tx, ty, tvy);
            tvy = UNDER_CARD_2;
        }
        // never on the lead's other side (VI left of him, HANK right): held
        // there, his own answer brings him on
        if ((tx - rx) * side < SIDE_MIN) {
            tx = rx + side * SIDE_MIN;
            heldX = true;
        }
        // off the lead's figure on screen (his box and the lead's, over the
        // next 0.15 s): nearer than CLR_M of the room it needs he eases away
        // from it the way he is clearest of it (out his side, or up / down;
        // up only as far as the alert band: over him he is clear already,
        // and pushing him out from there copied the lead's sweeps under
        // him), at clrV m/s, held CLR_HOLD s; in a fight out, not up
        if (keep != null) {
            let wp = railWorld(sNow, tx, ty);
            let ok = figAt(W, keep, wp, w.size);
            let du = FIG_AT_2, dvv = FIG_AT_3, nu = FIG_AT_4, nv = FIG_AT_5, kw = FIG_AT_6, kvw = FIG_AT_7, wu = FIG_AT_8, wvv = FIG_AT_9;
            if (ok) {
                // (closing on screen: their rates apart at his scale, the
                // lens following the lead)
                let du2 = du + (w.vx - p.vx) * 0.15 * kw;
                let dv2 = dvv - (w.vy - p.vy) * 0.15 * kvw;
                let duN = du * du2 < 0 ? 0 : Math.abs(du) < Math.abs(du2) ? du : du2;
                let dvN = dvv * dv2 < 0 ? 0 : Math.abs(dvv) < Math.abs(dv2) ? dvv : dv2;
                let eu = duN / nu;
                let ev = dvN / nv;
                let d = lmax(Math.abs(eu), Math.abs(ev));
                if (d < CLR_M) {
                    let f = CLR_M - d;
                    let mu = 0.0, mv = 0.0;
                    let cu = mathx.lerp(COMF_U, COMF_U_P, por);
                    let room = lmax(0, side > 0 ? 1 - cu - wu : wu - cu) / kw;
                    let upRoom = lmax(0, wvv - EDGE_TOP + 0.02) / kvw;
                    let across = eu * side >= Math.abs(ev) || (fight && eu * side > -0.15) || Math.abs(ev) < 0.3;
                    // (no room out his side, the frame's or the rail's edge:
                    // up)
                    if (across && (room < 0.5 || tx * side > X_MAX - 2)) {
                        across = false;
                        ev = -lmax(Math.abs(ev), 0.1);
                    }
                    if (across) {
                        mu = side * lmin(f * nu / kw, room);
                    } else if (ev < 0 || (ty - FLOOR) * kvw < nv * CLR_M - dvN) {
                        // (up; under him, too, with no room under before the floor)
                        mv = lmin(ev < 0 ? f * nv / kvw : (dvN + nv * CLR_M) / kvw, upRoom);
                    } else {
                        mv = -f * nv / kvw;
                    }
                    if (mu * side > 0) {
                        w.clrGX = side * lmin(lmax(w.clrGX * side, (w.clrX + mu) * side), CLR_MAX);
                    }
                    if (mv > 0) {
                        w.clrGY = lmin(lmax(w.clrGY, w.clrY + mv), CLR_MAX);
                    } else if (mv < 0) {
                        w.clrGY = lmax(lmin(w.clrGY, w.clrY + mv), -CLR_MAX);
                    }
                    w.clrT = CLR_HOLD;
                }
            }
        }
        // rocks ahead (every other frame, staggered): round his slot
        if (mod(W.tick + <f64>wi, 2) == 0) {
            // (probed to where his answer ends: on its way it ran him into
            // a stack it never looked at; held short of the rock, or over it)
            let qx2 = w.qx, qy2 = w.qy;
            let ex = tx + (qx2.T > 0 ? qx2.to - w.kx : 0);
            let ey = ty + (qy2.T > 0 ? qy2.to - w.ky : 0);
            rockPlan(W, w, p, tx, ty, keep, sNow, por, ex, ey);
        } else if (w.way > 0 && w.avT > 0) {
            w.avGX = mathx.clamp(w.wayX - tx, -18, 18);
            w.avGY = mathx.clamp(w.wayY - ty, -24, 24);
        }
        let way = w.way > 0 && w.avT > 0;
        if (w.avT > 0) {
            if (way) {
                // (a way round rock stays put on the rail: his slot's own
                // move taken out, and none of its rate; QA round 5: the way
                // crept along with his answer into the stack it went round)
                w.avX -= tx - w.wayTx;
                w.avY -= ty - w.wayTy;
                tvx = 0;
                tvy = 0;
            }
            w.avX = mathx.damp(w.avX, w.avGX, 10, dt);
            w.avY = mathx.damp(w.avY, w.avGY, 10, dt);
        } else {
            w.avX = mathx.damp(w.avX, 0, 2.5, dt);
            w.avY = mathx.damp(w.avY, 0, 2.5, dt);
        }
        w.wayTx = tx;
        w.wayTy = ty;
        tx = mathx.clamp(tx + w.avX, -X_MAX + 1, X_MAX - 1);
        ty += w.avY;
        // (a way past the frame's edge, or one the frame would move into
        // rock as the lens moves on (looked over again at once): rock
        // first, late at the edge he may be)
        if (keep != null && !(way && w.way == 2)) {
            let fx0 = tx, fy0 = ty;
            tx = inFrame(keep, sNow, tx, ty, por);
            ty = IN_FRAME_2;
            let moved = Math.abs(tx - fx0) > 0.05 || Math.abs(ty - fy0) > 0.05;
            if (moved && way && laneHit(w, tx, ty, w.size * 0.4 + ROCK_PAD, st.acc * 0.6) > 0) {
                tx = fx0;
                ty = fy0;
                moved = false;
                w.planT = 0;
            }
            heldX = heldX || (moved && Math.abs(tx - fx0) > 0.05);
            heldY = moved && Math.abs(ty - fy0) > 0.05;
        }
        // (and the rock offsets easing back after a way, the frame's hold:
        // out from the card again; a way held: rock first)
        if (keep != null && W.cardK > 0.002 && !way) {
            ty = underCard(W, w, keep, sNow, tx, ty, tvy);
            tvy = UNDER_CARD_2;
        }
    }
    ty = mathx.clamp(ty, 1.6, CEIL);
    // his spring onto the slot (sharper past the frame's comfort zone and
    // round a rock); the slot moves only at his own answer's rate
    let n = lclamp(Math.ceil(dt * 60 - 1e-3), 1, 4);
    let h = dt / n;
    let dodge = w.avT > 0 ? 1.0 : w.clrT > 0 ? 0.6 : 0.0;
    if (heldX) {
        tvx = 0;
    }
    if (heldY) {
        tvy = 0;
    }
    // (he himself past the frame's comfort zone: back in sharper, and on
    // with the lens's drift there: a sweep away from him at full tilt ran
    // on past his answer, the lens's edge and then the lens itself)
    let edge = 0.0;
    if (keep != null && !W.titleForm) {
        keep.project(<f64>w.pos.x, <f64>w.pos.y, <f64>w.pos.z);
        let u = keep.pjU, v = keep.pjV, z = keep.pjD;
        if (z > 0) {
            let cu = mathx.lerp(COMF_U, COMF_U_P, por);
            let bot = mathx.lerp(COMF_BOT, COMF_BOT_P, por);
            let eX = mathx.smoothstep(0, 0.08, lmax(cu - u, u - 1 + cu));
            let eY = mathx.smoothstep(0, 0.08, lmax(COMF_TOP - 0.02 - v, v - bot));
            edge = lmax(eX, eY);
            // (under the comms card on air: back out sharper too)
            if (W.cardK > 0.002 && W.figOk) {
                let k = W.fZ / z;
                let top = cardTop(W, u, WING_W * w.size * W.fKu * k, WING_H * w.size * W.fKv * k, COMF_TOP - 0.02);
                edge = lmax(edge, mathx.smoothstep(0, 0.08, top - v));
            }
            w.emX = mathx.damp(w.emX, holdX * (u < 0.5 ? 1 : -1) > 0 ? eX : 0, 8, dt);
            w.emY = mathx.damp(w.emY, holdY * (v < 0.5 ? -1 : 1) > 0 ? eY : 0, 8, dt);
            tvx += holdX * w.emX;
            tvy += holdY * w.emY;
        } else if (z > -30) {
            edge = 1;
        }
    }
    let om = st.w * (1 + 0.8 * lmax(w.catch, edge)) * (1 + 0.6 * dodge);
    let om2 = om * om, c = 2 * st.z * om;
    let acc = st.acc * (1 + 0.3 * dodge) * (1 + 0.5 * w.catch);
    let vmax = st.vmax * (1 + 0.3 * w.catch + 0.1 * dodge);
    // (closing faster than he can stop in, a big step overshot by metres)
    let brake = 2 * acc * 0.7;
    // (stiffer up / down: the frame is shorter than it is wide)
    let omy2 = om2 * 1.5, cy = c * 1.22;
    // (rock off his side: the barriers take him over it)
    let sideRock = !W.titleForm && rockAcross(w, sNow, side);
    // the rock guard, the last word on his turn: his way at his speed runs
    // into rock within GUARD_T s (longer the faster he goes: guardN): he
    // turns off it as hard as he can dodge, the way clear longest over 2 x
    // GUARD_T, then not past the lead's line, then nearest his target's,
    // last frame's kept while as good (none clear: the one in rock last,
    // then least of it, then out along the rock's normal); the frame's
    // edge, the comms card, the lead's figure and the lead's side not
    // pushing him (QA round 5: a sinking slot, the frame's pull and
    // barrier kicks ran him into stacks his ways went round; those model
    // his turn, not them. QA: the way nearest his target, clear for 0.4 s,
    // took HANK across a stack's face, the lead's side kicked him up into
    // its top, his way flipped up / out / up)
    let guard = false;
    let gx = 0.0, gy = 0.0;
    let grad = w.size * 0.4 + 0.3;
    let ga = st.acc * 1.3;
    if (!W.titleForm && w.near.length - 1 > 0 && guardHit(w, sNow, w.vx, w.vy, 0, 0, HUGE, grad, guardN(w.vx, w.vy, ga)) > 0) {
        guard = true;
        let gdx = tx - w.x, gdy = ty - w.y;
        let gdl = lmax(Math.sqrt(gdx * gdx + gdy * gdy), 1e-3);
        let best = HUGE, bi = 0;
        let blocked = true;
        for (let i = 1; i < GUARD_X.length; i++) {
            let ux = GUARD_X[i], uy = GUARD_Y[i];
            GUARD_S[i] = HUGE;
            if (!(uy < 0 && w.y < FLOOR + 2) && !(uy > 0 && w.y > CEIL - 2) && !(ux * w.x > 0 && Math.abs(w.x) > X_MAX - 2)) {
                let hit = guardHit(w, sNow, w.vx, w.vy, ux * ga, uy * ga, vmax, grad, 10);
                let xe = GUARD_HIT_2;
                let sc = hit * 4 - (ux * gdx + uy * gdy) / gdl;
                if ((xe - p.x) * side < SIDE_HARD) {
                    sc += 2;
                }
                if (<f64>i == w.gW) {
                    sc -= 0.6;
                }
                GUARD_S[i] = sc;
                blocked = blocked && hit > 0;
                if (sc < best) {
                    best = sc;
                    bi = i;
                }
            }
        }
        // (none clear: the peel's rule, the way in rock last, then least of
        // it (its depths, m: by steps, at 41 m/s HANK crossed a pillar),
        // then out along the rock's normal, last frame's kept within 0.25
        // of it; the rest as above. QA: inside his look's radius every way
        // met rock at once and the way nearest his target took HANK 3.9 m
        // into a stack)
        if (blocked && bi > 0) {
            rockIn(w.near, sNow, w.x, w.y, grad + GUARD_NR);
            let nx = ROCK_IN_2, ny = ROCK_IN_3, nz = ROCK_IN_4;
            let nl = nx * w.rtx + nz * w.rtz;
            let bh = HUGE, bn = HUGE, bd = HUGE;
            for (let i = 1; i < GUARD_X.length; i++) {
                if (GUARD_S[i] < HUGE) {
                    let ux = GUARD_X[i], uy = GUARD_Y[i];
                    let hit = guardHit(w, sNow, w.vx, w.vy, ux * ga, uy * ga, vmax, grad, 10, true);
                    let nIn = GUARD_HIT_3;
                    let d = -(ux * nl + uy * ny) - (<f64>i == w.gW ? 0.25 : 0);
                    if (hit < bh || (hit == bh && (nIn < bn || (nIn == bn && (d < bd - 1e-6 || (d <= bd + 1e-6 && GUARD_S[i] < GUARD_S[bi])))))) {
                        bh = hit;
                        bn = nIn;
                        bd = d;
                        bi = i;
                    }
                }
            }
        }
        if (bi > 0) {
            gx = GUARD_X[bi] * ga;
            gy = GUARD_Y[bi] * ga;
        }
        w.gW = <f64>bi;
    } else {
        w.gW = 0;
    }
    for (let step = 1; <f64>step <= n; step++) {
        let ex = tx - w.x, ey = ty - w.y;
        // (each way capped on its own: a climb never starves a dodge)
        let ax = mathx.clamp(om2 * ex + c * (tvx - w.vx), -acc, acc);
        let ay = mathx.clamp(omy2 * ey + cy * (tvy - w.vy), -acc, acc);
        if (guard) {
            ax = gx;
            ay = gy;
        }
        w.vx += ax * h;
        w.vy += ay * h;
        // (closing faster than he could stop in: braked, at most 2x his
        // acceleration: a target held still at once no longer stops him dead)
        let rvx2 = w.vx - tvx, rvy2 = w.vy - tvy;
        let bmax = guard ? 0 : 2 * acc * h;
        if (rvx2 * ex > 0) {
            let cap = Math.sqrt(brake * Math.abs(ex)) + 2;
            if (Math.abs(rvx2) > cap) {
                w.vx -= mathx.clamp(rvx2 - (rvx2 > 0 ? cap : -cap), -bmax, bmax);
            }
        }
        if (rvy2 * ey > 0) {
            let cap = Math.sqrt(brake * Math.abs(ey)) + 2;
            if (Math.abs(rvy2) > cap) {
                w.vy -= mathx.clamp(rvy2 - (rvy2 > 0 ? cap : -cap), -bmax, bmax);
            }
        }
        let v = Math.sqrt(w.vx * w.vx + w.vy * w.vy);
        if (v > vmax) {
            let vx = w.vx * vmax / v, vy = w.vy * vmax / v;
            w.vx = vx;
            w.vy = vy;
        }
        if (!W.titleForm && !guard) {
            // never on the lead's other side (VI left of him, HANK right):
            // closing on SIDE_HARD off the lead now no faster than he could
            // stop in the room left; past it, back out (a slide). Rock his
            // side: over it instead
            let m = (w.x - p.x) * side - SIDE_HARD;
            let cap = m >= 0 ? Math.sqrt(2 * BAR_ACC * m) : -lmin(12, -m * 6);
            let over = (p.vx - w.vx) * side - cap;
            if (over > 0) {
                if (sideRock) {
                    w.vy += lmin(over, BAR_DV * h * 60);
                } else {
                    w.vx += side * lmin(over, BAR_DV * h * 60);
                }
            }
        }
        // the rail's floor / ceiling: closed on no faster than he could stop
        // on it (QA round 4: a plunge stopped dead on the floor, 38 m/s in a
        // frame)
        let mf = w.y - FLOOR;
        let capF = mf >= 0 ? Math.sqrt(2 * BAR_ACC * mf) : -lmin(12, -mf * 6);
        if (-w.vy > capF) {
            w.vy += lmin(-w.vy - capF, BAR_DV * h * 60);
        }
        let mc = CEIL - w.y;
        let capC = mc >= 0 ? Math.sqrt(2 * BAR_ACC * mc) : -lmin(12, -mc * 6);
        if (w.vy > capC) {
            w.vy -= lmin(w.vy - capC, BAR_DV * h * 60);
        }
        w.x += w.vx * h;
        w.y += w.vy * h;
        w.ax = ax;
        w.ay = ay;
    }
    if (w.y < FLOOR - 0.2) {
        w.y = FLOOR - 0.2;
        w.vy = lmax(w.vy, 0);
    } else if (w.y > CEIL) {
        w.y = CEIL;
        w.vy = lmin(w.vy, 0);
    }
    if (Math.abs(w.x) > X_MAX) {
        w.x = mathx.clamp(w.x, -X_MAX, X_MAX);
        w.vx = 0;
    }
    // along the rail: his own speed answers the lead's late throttle and his
    // place in the slot; his throttle pose is what he asks of it (the lead's
    // boost / brake late, or a gap to close), never the lead's speed against
    // his: a boost left him behind in the BRAKE pose until his late boost
    let lead = W.dsH / lmax(dt, 1e-4);
    // (a gap opening as the lead brakes / boosts he notices on his throttle
    // delay: his throttle had answered on the lead's frame)
    w.gap = mathx.damp(w.gap, rsT - w.rs, 1 / lmax(st.thrDelay * quick, 0.05), dt);
    let tv = hv + mathx.clamp(w.gap * st.sz, -24, 24);
    let want = tv - w.sv;
    w.sv = mathx.damp(w.sv, tv, st.sw * (fight ? 1.5 : 1), dt);
    w.rs += w.sv * dt - W.dsH;
    let hi = rsT + 7;
    // (dragged along at the back of his slot / held back at its front: full
    // throttle / brake)
    let pinned = 0;
    if (w.rs < rsLo) {
        w.rs = rsLo;
        w.sv = lmax(w.sv, lead);
        pinned = 1;
    } else if (w.rs > hi) {
        w.rs = hi;
        w.sv = lmin(w.sv, lead);
        pinned = -1;
    }
    w.s = p.s + w.rs;
    w.boosting = hbo || want > 9 || pinned > 0;
    w.braking = !w.boosting && (hbr || want < -9 || pinned < 0);
    w.thrust = w.boosting ? 1 : w.braking ? 0.3 : 0.6;
    // the frame's edge and the lead's figure on screen (his own box, WING_W
    // / WING_H x his size): slides, never jumps.
    let kvx0 = w.vx, kvy0 = w.vy;
    if (keep != null && !W.titleForm && dt > 0) {
        let wp = railWorld(lmin(w.s, level.track.length - 1), w.x, w.y);
        let ok = figAt(W, keep, wp, w.size);
        let du = FIG_AT_2, dvv = FIG_AT_3, needU = FIG_AT_4, needV = FIG_AT_5, kw = FIG_AT_6, kvw = FIG_AT_7, wu = FIG_AT_8, wvv = FIG_AT_9;
        if (ok) {
            if (w.figOk) {
                // (what the lead and the lens did to it, his own move left out)
                let eu = (du - w.figU) / dt - w.vx * kw;
                let ev = (dvv - w.figV) / dt + w.vy * kvw;
                if (Math.abs(eu) < 4 && Math.abs(ev) < 4) {
                    w.figEU = mathx.damp(w.figEU, eu, 30, dt);
                    w.figEV = mathx.damp(w.figEV, ev, 30, dt);
                }
                let au = (wu - w.edU) / dt - w.vx * kw;
                let av = (wvv - w.edV) / dt + w.vy * kvw;
                if (Math.abs(au) < 4 && Math.abs(av) < 4) {
                    w.edEU = mathx.damp(w.edEU, au, 15, dt);
                    w.edEV = mathx.damp(w.edEV, av, 15, dt);
                }
            }
            w.figU = du;
            w.figV = dvv;
            w.figOk = true;
            w.edU = wu;
            w.edV = wvv;
            // the frame's edge: as the lens drifts him toward it, he closes
            // on it no faster than he could stop in the room left
            let eu0 = EDGE_B;
            let dvE = BAR_DV * dt * 60;
            let ue = wu < 0.5 ? -1.0 : 1.0;
            let mu = (ue < 0 ? wu - eu0 : 1 - eu0 - wu) / kw;
            let capU = mu >= 0 ? Math.sqrt(2 * EDGE_ACC * mu) : -lmin(25, -mu * 6);
            let closeU = ue * (w.edEU / kw + w.vx);
            // (never into rock or across the lead's side for it, nor off a
            // way round rock past it: at the edge late, he may be)
            let inward = -ue * side < 0;
            if (closeU > capU && !(inward && (w.x - p.x) * side < SIDE_HARD + 2)
                && !(w.way == 2 && w.avT > 0) && !rockAcross(w, sNow, -ue)) {
                w.vx -= ue * lmin(closeU - capU, dvE);
            }
            let top = EDGE_TOP - 0.02, bot = mathx.lerp(EDGE_BOT, EDGE_BOT_P, por);
            let ve = wvv < (top + bot) * 0.5 ? -1.0 : 1.0;
            let mv = (ve < 0 ? wvv - top : bot - wvv) / kvw;
            let capV = mv >= 0 ? Math.sqrt(2 * EDGE_ACC * mv) : -lmin(25, -mv * 6);
            let closeV = ve * (w.edEV / kvw - w.vy);
            if (closeV > capV) {
                w.vy += ve * lmin(closeV - capV, dvE);
            }
            // the comms card on air: its foot the same over its span (over
            // the lead's figure, its top); under it, out as a slide
            // (CARD_ACC: the card eases in over him)
            let hwS = WING_W * w.size * kw, hhS = WING_H * w.size * kvw;
            let topC = cardTop(W, wu, hwS, hhS, top);
            if (topC > top) {
                topC = lmax(top, lmin(topC, cardLow(W, wu, hwS, hhS)));
            }
            if (topC > top) {
                let mc = (wvv - topC) / kvw;
                let capC = mc >= 0 ? Math.sqrt(2 * EDGE_ACC * mc) : -lmin(12, -mc * 6);
                let closeC = w.vy - w.edEV / kvw;
                if (closeC > capC) {
                    w.vy -= lmin(closeC - capC, CARD_ACC * dt);
                }
            }
            // the lead's figure: kept clear the way he is clearest of it
            // (out his side across; over / under it up / down; across
            // blocked by the rail's edge, rock his side or his being past
            // its middle on screen, up blocked by the alert band, down by the
            // floor: the other way), his closing on its box (x FIG_PAD) no
            // faster than he could stop in the room left, as measured on
            // screen (the lens moves the figure faster there than on the
            // rail); that way held while nearly as clear as the other (QA
            // round 4: a push weighted by both let a diagonal sweep graze him)
            let eu = du / needU, ev = dvv / needV;
            if (guard) {
                w.vx = kvx0;
                w.vy = kvy0;
            } else if (Math.abs(eu) < 1.8 && Math.abs(ev) < 1.8) {
                let dvMax = FIG_DV * dt * 60;
                let cuF = (w.x * side > X_MAX - 1) || sideRock || du * side <= 0 ? -1 : Math.abs(eu);
                // (under him only with the room to get under before the
                // floor: the lead low by the rail's edge pressed VI down to
                // the water, on his figure)
                let under = dvv >= 0 && (w.y - FLOOR) * kvw > needV * FIG_PAD - dvv + 0.01;
                let cv = (dvv < 0 && wvv < EDGE_TOP + 0.02) || (dvv >= 0 && !under) ? -1 : Math.abs(ev);
                let across = w.figAx ? cuF >= cv * 0.85 : cuF > cv * 1.15;
                if (cuF < 0 && cv < 0) {
                    across = du * side > 0;
                }
                w.figAx = across;
                if (across) {
                    let m = (Math.abs(du) - needU * FIG_PAD) / kw;
                    let cap = m >= 0 ? Math.sqrt(2 * FIG_ACC * m) : -lmin(14, -m * 6);
                    let close = -side * (w.figEU / kw + w.vx);
                    if (close > cap) {
                        w.vx += side * lmin(close - cap, dvMax);
                    }
                } else {
                    // (1: over him, climbs away; -1: under him)
                    let sg = dvv < 0 || !under ? 1.0 : -1.0;
                    let m = (sg * -dvv - needV * FIG_PAD) / kvw;
                    let cap = m >= 0 ? Math.sqrt(2 * FIG_ACC * m) : -lmin(14, -m * 6);
                    let close = sg * (w.figEV / kvw - w.vy);
                    if (close > cap) {
                        w.vy += sg * lmin(close - cap, dvMax);
                    }
                }
            }
        } else {
            w.figOk = false;
        }
    } else {
        w.figOk = false;
    }
    if (!w.figOk) {
        w.figEU = 0;
        w.figEV = 0;
        w.edEU = 0;
        w.edEV = 0;
    }
    // (a barrier's kick that runs him into rock within his guard's look is
    // taken back: at the frame's edge or on the lead's figure late he may be)
    if ((w.vx != kvx0 || w.vy != kvy0) && w.near.length - 1 > 0) {
        let gk = guardN(w.vx, w.vy, ga);
        if (guardHit(w, sNow, w.vx, w.vy, 0, 0, HUGE, grad, gk) > 0 && guardHit(w, sNow, kvx0, kvy0, 0, 0, HUGE, grad, gk) == 0) {
            w.vx = kvx0;
            w.vy = kvy0;
        }
    }
    // never inside rock (the look-ahead missed it): out along the face's
    // normal (sideways and / or up) at up to 20 m/s, a slide (last: the
    // lead's figure gives way to rock)
    if (!W.titleForm && w.near.length - 1 > 0) {
        let hit = rockIn(w.near, w.s, w.x, w.y, w.size * 0.4 + 0.3);
        let nx = ROCK_IN_2, ny = ROCK_IN_3, nz = ROCK_IN_4, d = ROCK_IN_5;
        if (hit) {
            let l = nx * w.rtx + nz * w.rtz;
            if (Math.abs(l) < 0.3 && Math.abs(ny) < 0.3) {
                // (a face across his way: up over it)
                l = 0;
                ny = 1;
            }
            if (ny > 0.5 && w.y > CEIL - 1) {
                l = 0;
                ny = -1;
            }
            let m = Math.sqrt(l * l + ny * ny);
            if (m > 1e-3) {
                l = l / m;
                ny = ny / m;
                // (out of one stack into the next: up instead)
                if (Math.abs(l) > 0.3 && rockIn(w.near, w.s + w.sv * 0.2, w.x + l * 2.5, w.y + ny * 2.5, w.size * 0.4)) {
                    l = 0;
                    ny = 1;
                }
                // (at the rail's edge no further out: up and in, else the
                // edge held him in the face)
                if (Math.abs(w.x) > X_MAX - 1.5 && l * w.x > 0) {
                    l = w.x > 0 ? -0.4 : 0.4;
                    ny = 0.92;
                }
                shoveOut(w, l, ny, lmin(d * 12, 20), dt);
                // (and his target with him, out of the face)
                w.avGX = mathx.clamp(w.avGX + l * (d + 0.5), -14, 14);
                w.avGY = mathx.clamp(w.avGY + ny * (d + 0.5), -24, 24);
                w.wayX += l * (d + 0.5);
                w.wayY += ny * (d + 0.5);
            }
            w.avT = lmax(w.avT, 0.5);
        }
    }
    // looks round: over the shoulder (mostly toward the lead), up or down
    // now and then (VI often, HANK seldom); a wing rock is VI's
    let bpose = -w.bank / 0.75;
    w.lookT -= dt;
    if (w.glanceT > 0) {
        w.glanceT = lmax(0, w.glanceT - dt);
        let k = 1 - w.glanceT / w.glanceLen;
        let env = mathx.smoothstep(0, 0.22, k) * (1 - mathx.smoothstep(0.7, 1, k));
        if (w.wag) {
            // VI's wing rock: left-right-left
            w.glance = Math.sin(k * TAU * 1.5) * 0.62 * env;
            w.glanceP = 0;
        } else {
            w.glance = w.glanceDir * 0.5 * env;
            w.glanceP = w.lookP * env;
        }
    } else {
        w.glance = 0;
        w.glanceP = 0;
        if (w.lookT <= 0) {
            w.lookT = rndIn(w, st.lookT);
            if (w.rollT <= 0 && Math.abs(bpose) < 0.45) {
                w.glanceDir = rnd(w) < 0.65 ? -side : side;
                w.glanceLen = st.lookLen * (0.8 + 0.4 * rnd(w));
                w.glanceT = w.glanceLen;
                w.lookP = st.lookP * (2 * rnd(w) - 1);
                w.wag = false;
            }
        }
    }
    // VI's flourish now and then when it is quiet: a roll outboard or a
    // wing rock (not while the other rolls or just has: it read as a
    // second echo)
    let ft = st.flourT;
    if (ft != null) {
        w.flourT -= dt;
        if (w.flourT <= 0) {
            let other = false;
            for (let oi = 1; oi < W.list.length; oi++) {
                let ow = W.list[oi];
                other = other || (ow != w && (ow.rollT > 0 || ow.rollDelay >= 0 || ow.rollCd > 0.4));
            }
            if (w.rollT <= 0 && w.rollDelay < 0 && w.rollCd <= 0 && !other && !fight && w.catch < 0.2 && p.rollT <= 0 && Math.abs(w.vx) < 8 && w.glanceT <= 0) {
                if (rnd(w) < 0.55) {
                    startRoll(w, -side, 0.35);
                } else {
                    w.wag = true;
                    w.glanceLen = 1.1;
                    w.glanceT = 1.1;
                }
                w.flourT = rndIn(w, ft);
            } else {
                w.flourT = 1.5;
            }
        }
    }
}

// VI and HANK keep SEP m apart: eased apart across / up, harder the nearer
// and the faster they close; nearer than 4.5 m, slid apart.
function keepApart(W: Wingmen, dt: f64): void {
    if (W.list.length - 1 < 2) {
        return;
    }
    let a = W.list[1], b = W.list[2];
    if (a.phase != "form" || b.phase != "form") {
        return;
    }
    let dS = a.s - b.s, dX = a.x - b.x, dY = a.y - b.y;
    let d = Math.sqrt(dS * dS + dX * dX + dY * dY);
    if (d >= SEP) {
        return;
    }
    let l = Math.sqrt(dX * dX + dY * dY);
    let ux = a.slotX < b.slotX ? -1.0 : 1.0, uy = 0.0;
    if (l > 0.3) {
        ux = dX / l;
        uy = dY / l;
    }
    let k = (SEP - d) / SEP;
    let closing = lmax(0, -((a.vx - b.vx) * ux + (a.vy - b.vy) * uy));
    let dv = (60 * k + 12 * k * closing) * dt;
    a.vx += ux * dv;
    a.vy += uy * dv;
    b.vx -= ux * dv;
    b.vy -= uy * dv;
    if (d < 4.5) {
        shoveOut(a, ux, uy, 6, dt);
        shoveOut(b, -ux, -uy, 6, dt);
    }
}

// A peel's ways round rock when his break is blocked (across: -1 in toward
// his side of the rail's middle, off a canyon wall, 0 none, 1 out; up: 1
// the break's climb + 30 m/s, 0 level, -1 down at 20 m/s): up and in, up,
// up and out, in, out, down and in, down, down and out (QA: rock over him,
// every way up or level met it and HANK climbed 12 m into it).
const PEEL_X: Array<f64> = [0.0, -1, 0, 1, -1, 1, -1, 0, 1];
const PEEL_Y: Array<f64> = [0.0, 1, 1, 1, 0, 0, -1, -1, -1];

// vx returned, PEEL_RATE_2: vy
let PEEL_RATE_2: f64 = 0;

function peelRate(w: Wing, i: i32, by: f64): f64 {
    let ax = PEEL_X[i], ay = PEEL_Y[i];
    let vx = ax < 0 ? mathx.clamp(w.peelDir * 5 - w.x, -1, 1) * 28 : ax * w.peelDir * 28;
    PEEL_RATE_2 = ay < 0 ? -20 : ay * (by + 30);
    return vx;
}

// His peel over the next `la` s at these rates (across, up, along the
// rail), in PEEL_N steps, closer near him (QA: a first look 0.2 s out
// stepped over a stack's top 3 frames ahead): the first in rock (0 =
// clear; more = sooner) and how many are (PEEL_HIT_2).
const PEEL_N: i32 = 20;
let PEEL_HIT_2: f64 = 0;

function peelHit(w: Wing, vx: f64, vy: f64, vs: f64, rad: f64, la: f64): f64 {
    let first = 0.0, n = 0.0;
    for (let i = 1; i <= PEEL_N; i++) {
        let f = la * Math.pow(<f64>i / <f64>PEEL_N, 1.5);
        if (rockIn(w.near, w.s + vs * f, w.x + vx * f, lmax(w.y + vy * f, FLOOR), rad)) {
            if (first == 0) {
                first = <f64>(PEEL_N + 1 - i);
            }
            n += 1;
        }
    }
    PEEL_HIT_2 = n;
    return first;
}

// The last of a join swoop (it never looks for rock): his way over the next
// GUARD_T s at the swoop's rates runs his body into rock (gathered into
// w.near for his guard; QA: at his guard's room a near miss handed VI over
// 1 s early, onto the alert banner).
function joinRock(w: Wing, s0: f64, x0: f64, y0: f64, dt: f64): bool {
    if (dt <= 0) {
        return false;
    }
    let vs = (w.s - s0) / dt, vx = (w.x - x0) / dt, vy = (w.y - y0) / dt;
    let rad = w.size * 0.3 + 0.2;
    let dx = vx * GUARD_T;
    gather(w.near, w.s - 2, w.s + vs * GUARD_T + 4, w.x + lmin(dx, 0) - 6, w.x + lmax(dx, 0) + 6, w.y + lmax(vy * GUARD_T, 0) + 6, rad);
    for (let i = 1; i <= 5; i++) {
        let tau = GUARD_T * <f64>i / 5;
        if (rockIn(w.near, w.s + vs * tau, w.x + vx * tau, w.y + vy * tau, rad)) {
            return true;
        }
    }
    return false;
}

// Swoop in over the camera from behind and above, overtake, then drop back
// into the slot.
function swoop(w: Wing, p: Player): void {
    w.phase = "join";
    w.phaseT = 0;
    w.fromS = p.s - 15;
    w.fromX = w.slotX * 2.3;
    w.fromY = p.y + 9;
    w.s = w.fromS;
    w.x = w.fromX;
    w.y = w.fromY;
    // (nothing held over from the last window)
    w.avX = 0;
    w.avY = 0;
    w.avT = 0;
    w.avGX = 0;
    w.avGY = 0;
    w.way = 0;
    w.clrX = 0;
    w.clrY = 0;
    w.clrGX = 0;
    w.clrGY = 0;
    w.clrT = 0;
    w.glance = 0;
    w.glanceP = 0;
    w.glanceT = 0;
    w.figOk = false;
    w.scrU = -1;
    w.layT = 0;
    w.qx.T = 0;
    w.qy.T = 0;
    w.near.length = 1;
}

function lines1Of(l: Line): Array<Line> {
    let a = lines1();
    a.push(l);
    return a;
}

// keep: null = no screen rules (Luau nil).
export function update(W: Wingmen, p: Player, t: f64, dt: f64, active: bool, keep: Keeper? = null): void {
    W.reactT = lmax(0, W.reactT - dt);
    W.joined = false;
    W.tick += 1;
    // the lead's flight, for what each wingman saw of it a beat ago
    let dsH = p.s - W.lastS;
    W.lastS = p.s;
    if (Math.abs(dsH) > 40 || W.hist.n == 0) {
        dsH = p.speed * p.railK * dt;
    }
    W.dsH = dsH;
    // (the lead moved further than he can fly in a frame: a portal, a
    // respawn; what they saw of him before is gone)
    let h = W.hist;
    if (h.n > 0 && Math.abs(p.x - h.x[h.head]) + Math.abs(p.y - h.y[h.head]) > 8) {
        h.n = 0;
        for (let wi = 1; wi < W.list.length; wi++) {
            let w = W.list[wi];
            if (w.phase == "form") {
                // (he keeps the lead where he is now and answers on to him)
                w.fx = p.x;
                w.fy = p.y;
                w.fvx = p.vx;
                w.fvy = p.vy;
                w.kx = w.x - w.sxM;
                w.ky = w.y - w.syM;
                w.kvx = 0;
                w.kvy = 0;
                w.kax = 0;
                w.kay = 0;
                w.qx.T = 0;
                w.qy.T = 0;
                w.modeX = 0;
                w.modeY = 0;
                if (answer(w.qx, w.kx, 0, 0, p.x, w.style, true, 0, 1)) {
                    w.modeX = 1;
                }
                if (answer(w.qy, w.ky, 0, 0, p.y, w.style, true, 0, 0.8)) {
                    w.modeY = 1;
                }
                w.figOk = false;
                w.scrU = -1;
                w.layT = 0;
            }
        }
    }
    histPush(W.hist, t, p);
    // the next wingman with his own join call swoops in as the channel frees
    // (QA M14: both swooped together and the second intro played 3 s later)
    if (W.pend.length - 1 > 0) {
        W.pendT += dt;
        if (!active) {
            W.pend.length = 1;
        } else if (!W.hold || W.pendT >= JOIN_WAIT) {
            let e = W.pend[1];
            W.pend.splice(1, 1);
            for (let wi = 1; wi < W.list.length; wi++) {
                let w = W.list[wi];
                if (w.who == e.who && w.phase == "away") {
                    swoop(w, p);
                }
            }
            say(W, lines1Of(e.line));
            W.pendT = 0;
            W.joined = true;
        }
    }
    // which window are we in?
    let want = 0;
    if (active) {
        for (let i = 1; i < WINDOWS.length; i++) {
            let win = WINDOWS[i];
            if (p.s >= win.s0 && p.s < win.s1) {
                want = i;
                break;
            }
        }
    }
    // a join / peel waits while the comms channel is busy (W.hold), so the
    // pair swoops in / breaks off as its call plays (QA M14): a join up to
    // JOIN_WAIT s, a peel up to the window's `wait` m past its end
    let gate = false;
    if (want != W.window && active && W.hold) {
        if (W.window > 0) {
            let cur = WINDOWS[W.window];
            gate = want == 0 && cur.peel.length - 1 > 0 && p.s < cur.s1 + (isNaN(cur.wait) ? 0 : cur.wait);
        } else {
            gate = W.holdT < JOIN_WAIT;
        }
    }
    if (gate) {
        W.holdT += dt;
    } else if (want == W.window) {
        W.holdT = 0;
    } else {
        W.holdT = 0;
        W.pend.length = 1;
        W.pendT = 0;
        let old = W.window;
        if (old != 0) {
            for (let wi = 1; wi < W.list.length; wi++) {
                let w = W.list[wi];
                if (w.phase == "form" || w.phase == "join") {
                    // (VI breaks off with a roll)
                    if (w.phase == "form" && w.style.flourT != null && w.rollT <= 0) {
                        startRoll(w, -w.peelDir, 0);
                    }
                    w.phase = "peel";
                    w.phaseT = 0;
                    w.peelK = 1;
                    w.avT = 0;
                    w.peelW = 1;
                    w.peelGo = 0;
                }
            }
            if (active) {
                say(W, WINDOWS[old].peel);
            }
        }
        if (want != 0) {
            // the first call's wingman and any without a call of his own
            // swoop in now; one whose call comes later waits for it
            let join = WINDOWS[want].join;
            let first = join.length - 1 > 0 ? join[1].who : "";
            for (let wi = 1; wi < W.list.length; wi++) {
                let w = W.list[wi];
                let later = false;
                for (let i = 2; i < join.length; i++) {
                    later = later || (join[i].who == w.who && w.who != first);
                }
                if (!later) {
                    swoop(w, p);
                }
            }
            for (let i = 1; i < join.length; i++) {
                let l = join[i];
                if (i > 1 && l.who != first) {
                    W.pend.push(new PendJoin(l.who, l));
                } else {
                    say(W, lines1Of(l));
                }
            }
            W.joined = true;
        }
        W.window = want;
    }
    W.edgeT = W.window > 0 ? (WINDOWS[W.window].s1 - p.s) / lmax(p.speed, 10) : HUGE;

    W.positions.length = 1;
    if (keep != null) {
        // (the lens on something else, a set-piece beat's kill cam: no
        // screen rules)
        let P = p.pos;
        keep.project(<f64>P.x, <f64>P.y, <f64>P.z);
        let hu = keep.pjU, hv = keep.pjV, hz = keep.pjD;
        if (hz <= 0 || hu < 0.05 || hu > 0.95 || hv < 0.02 || hv > 0.98) {
            keep = null;
        }
    }
    let por = keep != null ? mathx.saturate((keep.halfW - 0.4) / 0.1) : 0.0;
    figure(W, keep, p);
    // the comms card while a line is on air (where the HUD draws it)
    popups.comms();
    let con = popups.COMMS_1, c0 = popups.COMMS_2, c1 = popups.COMMS_3, c2 = popups.COMMS_4, c3 = popups.COMMS_5;
    if (c3 > c1) {
        W.cU0 = c0;
        W.cU1 = c2;
        W.cV1 = c3;
    }
    W.cardT = con && c3 > c1 ? CARD_HOLD : lmax(0, W.cardT - dt);
    W.cardK = mathx.damp(W.cardK, W.cardT > 0 ? 1 : 0, W.cardT > 0 ? CARD_IN : CARD_OUT, dt);
    keepApart(W, dt);
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        w.phaseT += dt;
        let st = w.style;
        let ox = w.x, oy = w.y, os0 = w.s;
        if (w.phase != "form") {
            w.catch = 0;
        }
        if (w.phase == "join") {
            // the swoop lands on his slot on the lead as he is now
            let wob = t * 0.9 + w.seed;
            let sx = slotRaw(w, por);
            let sy = SLOT_RAW_2;
            let ss = mathx.lerp(w.slotS, st.slotP[3], por);
            let tx = lclamp(p.x + sx + Math.sin(wob) * 1.4, -32, 32);
            let ty = lclamp(p.y + sy + Math.sin(wob * 1.3) * 0.7, 1.4, 34);
            let ts = p.s + ss + Math.sin(wob * 0.7) * 1.2;
            if (W.titleForm) {
                let k = w.slotX < 0 ? 1.0 : 2.0;
                tx = p.x - 6.5 * k + Math.sin(wob) * 0.8;
                ty = p.y + (k == 1 ? 1.8 : 0.4) + Math.sin(wob * 1.3) * 0.5;
                ts = p.s + (k == 1 ? 2.0 : -4.0) + Math.sin(wob * 0.7) * 1.2;
            }
            let u = mathx.saturate(w.phaseT / 2.4);
            let k = mathx.easeInOutCubic(u);
            w.s = mathx.lerp(w.fromS, ts, mathx.easeOutCubic(u)) + Math.sin(u * Math.PI) * 9;
            w.x = mathx.lerp(w.fromX, tx, k);
            w.y = mathx.lerp(w.fromY, ty, k);
            w.thrust = 1;
            // VI settles in with a roll
            if (st.flourT != null && w.phaseT >= 1.6 && w.phaseT - dt < 1.6 && !W.titleForm) {
                startRoll(w, w.slotX < 0 ? 1 : -1, 0);
            }
            // (rock on the last of the swoop: he flies the rest himself,
            // his guard on; QA round 5: HANK landed in a stack. From 1.4 s
            // he is near his slot's depth: no snap)
            if (w.phaseT >= 2.4 || (w.phaseT >= 1.4 && !W.titleForm && mod(W.tick + <f64>wi, 2) == 0 && joinRock(w, os0, ox, oy, dt))) {
                // (his own flight picks up the swoop's rates; he keeps the
                // lead where he lands on him)
                w.phase = "form";
                w.rs = w.s - p.s;
                w.sv = p.speed * p.railK + 6;
                w.ax = 0;
                w.ay = 0;
                w.fx = p.x;
                w.fy = p.y;
                w.fvx = p.vx;
                w.fvy = p.vy;
                w.kx = p.x;
                w.ky = p.y;
                w.kvx = 0;
                w.kvy = 0;
                w.kax = 0;
                w.kay = 0;
                w.qx.T = 0;
                w.qy.T = 0;
                w.modeX = 0;
                w.modeY = 0;
                w.inX = false;
                w.offX = 0;
                w.offY = 0;
                w.oX = 0;
                w.oY = 0;
                w.oS = 0;
                w.hOff = 0;
                w.hGoal = 0;
                w.own = 1;
                w.depthK = 1;
                w.sxM = slotRaw(w, por);
                w.syM = SLOT_RAW_2;
                w.fk = W.fight ? 1 : 0;
                w.gap = 0;
                w.slotK = 1;
                w.slotT = rndIn(w, st.slotT);
                w.hT = rndIn(w, st.heightT);
                w.lookT = rndIn(w, st.lookT);
                let ft = st.flourT;
                if (ft != null) {
                    w.flourT = rndIn(w, ft);
                }
            }
        } else if (w.phase == "form") {
            fly(W, w, wi, p, t, dt, keep);
        } else if (w.phase == "peel") {
            // break outward and climb, pulling ahead and away (a rock in the
            // way out: the first clear of his ways round it, PEEL_X / Y; still
            // in it: out along the face, and he is gone sooner)
            let k = w.phaseT;
            let bx = w.peelDir * (8 + k * 22), by = 4 + k * 10;
            // (pulling ahead only while his way out is clear: a stack face
            // just ahead of his slot met him as he broke)
            let ahead = 10 + k * 30;
            let sv = p.speed + ahead * w.peelK;
            let first = w.phaseT <= dt * 1.5;
            if (mod(W.tick + <f64>wi, 2) == 0 || first) {
                // (his way out over the next 1.2 s, in six steps; at once as
                // he breaks: QA round 4, a peel beside a stack was 1.2 m into
                // it before the easing turned him)
                let rad = w.size * 0.4 + 2;
                let la = 1.2;
                gather(w.near, w.s - 2, w.s + (p.speed + ahead) * la + 6, w.x - 36, w.x + 36, w.y + (by + 30) * la + 8, rad);
                if (peelHit(w, bx, by, p.speed + ahead, rad, la) > 0) {
                    w.avT = 0.6;
                    if (w.phaseT < 0.15) {
                        w.peelK = 0;
                    }
                    // (each of his ways as he would fly it, the one he is on
                    // kept while clear; none clear, the one that meets rock
                    // last, then least of it. QA round 5: up and in, never
                    // probed, took HANK into the stack he broke beside)
                    let vx0 = peelRate(w, <i32>w.peelW, by);
                    let vy0 = PEEL_RATE_2;
                    if (first || peelHit(w, vx0, vy0, p.speed, rad, la) > 0) {
                        let bi = 1, bh = HUGE, bn = HUGE;
                        for (let i = 1; i < PEEL_X.length; i++) {
                            let vx = peelRate(w, i, by);
                            let vy = PEEL_RATE_2;
                            let hit = peelHit(w, vx, vy, p.speed, rad, la);
                            let n = PEEL_HIT_2;
                            if (hit < bh || (hit == bh && n < bn)) {
                                bi = i;
                                bh = hit;
                                bn = n;
                            }
                            if (hit == 0) {
                                break;
                            }
                        }
                        w.peelW = <f64>bi;
                    }
                }
            }
            // (in it after all: out along the face, a slide, and he is gone
            // sooner, his climb no steeper for it (QA: it steepened into
            // the rock over him); a face across his way holds him off it)
            let hit = rockIn(w.near, w.s, w.x, w.y, w.size * 0.4 + 0.3);
            let nx = ROCK_IN_2, ny = ROCK_IN_3, nz = ROCK_IN_4, d = ROCK_IN_5;
            if (hit) {
                let l = nx * w.rtx + nz * w.rtz;
                let up = lmax(ny, 0.3);
                let m = lmin(d + 0.2, 40 * dt);
                if (Math.abs(l) < 0.3 && Math.abs(ny) < 0.3) {
                    track.frame(level.track, lmin(w.s, level.track.length - 1));
                    let fw = track.FRAME_F;
                    let fa = nx * <f64>fw.x + nz * <f64>fw.z;
                    sv *= 1 + lmin(fa, 0);
                    w.s += fa * m;
                    up = ny;
                }
                w.x += l * m;
                w.y += up * m;
                w.avT = 0.6;
                if (d > 0.6) {
                    w.peelGo += 0.12;
                }
            }
            w.avT = lmax(0, w.avT - dt);
            w.peelK = mathx.damp(w.peelK, w.avT > 0 ? 0 : 1, 10, dt);
            w.s += sv * dt;
            // (his way out blocked: his way round; in goes to his side of the
            // middle of the rail, off the canyon wall: both to the middle met
            // there)
            let vx = peelRate(w, <i32>w.peelW, by);
            let vy = PEEL_RATE_2;
            w.x += (bx * w.peelK + (1 - w.peelK) * vx) * dt;
            w.y = lmax(w.y + (by * w.peelK + (1 - w.peelK) * vy) * dt, FLOOR);
            w.thrust = 1;
            if (k + w.peelGo > 3.2) {
                w.phase = "away";
            }
        }
        if (w.phase != "away") {
            let formed = w.phase == "form";
            let bankT: f64, pitchT: f64, rate: f64;
            if (formed) {
                // his own lean: from his own sideways speed, a touch ahead of
                // it from his own acceleration (not the lead's stick)
                bankT = -mathx.clamp(w.vx / st.bankV + w.ax * st.bankAcc, -1.1, 1.1) * 0.75;
                pitchT = mathx.clamp(w.vy / 20 + w.ay * st.bankAcc * 0.8, -1, 1) * 0.4;
                rate = st.bankRate;
            } else {
                let vx = (w.x - ox) / lmax(dt, 1e-4);
                let vy = (w.y - oy) / lmax(dt, 1e-4);
                w.vx = mathx.damp(w.vx, vx, 8, dt);
                w.vy = mathx.damp(w.vy, vy, 8, dt);
                bankT = -mathx.clamp(w.vx / 26, -1.1, 1.1) * 0.75;
                if (w.phase == "peel") {
                    bankT = -w.peelDir * 0.9;
                }
                pitchT = mathx.clamp(w.vy / 20, -1, 1) * 0.4;
                rate = 5;
            }
            w.bank = mathx.damp(w.bank, bankT, rate, dt);
            w.pitch = mathx.damp(w.pitch, pitchT, rate, dt);
            // delayed barrel roll echo
            if (w.rollDelay >= 0) {
                w.rollDelay -= dt;
                if (w.rollDelay < 0) {
                    startRoll(w, w.rollDir, 0);
                }
            }
            if (w.rollT > 0) {
                w.rollT = lmax(0, w.rollT - dt);
                let k = 1 - w.rollT / playerMod.ROLL_TIME;
                w.roll = w.rollDir * (1 - Math.pow(1 - k, 2.6)) * mathx.TAU;
            } else {
                w.roll = 0;
            }
            w.rollCd = lmax(0, w.rollCd - dt);
            w.evadeT = lmax(0, w.evadeT - dt);
            let pos = railWorld(lmin(w.s, level.track.length - 1), w.x, w.y);
            w.pos = pos;
            w.rtx = RAIL_WORLD_2;
            w.rtz = RAIL_WORLD_3;
            W.positions.push(w.pos);
            // flight state -> poses (bank / hard bank, boost, brake, climb /
            // dive), quantized so the view model only changes on real moves;
            // a look over the shoulder leans the pose, not the flight
            let bank = Math.floor(mathx.clamp(-w.bank / 0.75 + w.glance, -1, 1) * 100 + 0.5) / 100;
            let pitch = Math.floor(mathx.clamp(w.pitch / 0.4 + w.glanceP, -1, 1) * 100 + 0.5) / 100;
            let thrust = Math.floor(w.thrust * 20 + 0.5) / 20;
            let boost = w.thrust > 0.9;
            let b = w.bag;
            if (b != null) {
                vmx.num(b, "bank", bank);
                vmx.num(b, "pitch", pitch);
                vmx.num(b, "thrust", thrust);
                vmx.bool(b, "boost", boost);
            }
            // The sprites redraw their art every other frame (the renderer's
            // slow atlases), so each artboard advances every other frame by
            // the time since, staggered: one wingman or one twin per frame.
            let even = mod(W.tick + <f64>wi, 2) == 0;
            w.artDt = lmin(w.artDt + dt, 0.25);
            let a = w.art;
            if (a != null && even) {
                flush(w.bag, w.pend);
                a.advance(w.artDt);
                w.artDt = 0;
                let tp = w.tips;
                if (tp != null) {
                    // this frame's flame tips in sprite meters (the pose Solo moves them)
                    let k = w.size / tp.w;
                    let cx = tp.w * 0.5, cy = tp.h * 0.5;
                    let o = w.anc;
                    let wl = tp.l.worldTransform(), wr = tp.r.worldTransform();
                    o[1] = (<f64>wl.tx - cx) * k;
                    o[2] = (cy - <f64>wl.ty) * k;
                    o[3] = (<f64>wr.tx - cx) * k;
                    o[4] = (cy - <f64>wr.ty) * k;
                }
            }
            // the underside twin only poses while he is low over the water
            let tw = w.twin, tb = w.twinBag;
            if (tw != null && tb != null && <f64>w.pos.y < 18) {
                w.twinDt = lmin(w.twinDt + dt, 0.25);
                if (!even) {
                    vmx.num(tb, "bank", bank);
                    vmx.num(tb, "pitch", pitch);
                    vmx.num(tb, "thrust", thrust);
                    vmx.bool(tb, "boost", boost);
                    flush(tb, w.twinPend);
                    tw.advance(w.twinDt);
                    w.twinDt = 0;
                }
            } else {
                // out of the water pass: no stale roll / hit when he comes back low
                w.twinPend.length = 1;
            }
        } else {
            w.pend.length = 1;
            w.twinPend.length = 1;
        }
        w.flinchT = lmax(0, w.flinchT - dt);
    }
}

// A shot passing within `rad` of a wingman in formation: he flinches (the
// painted hit pose: shake, red flash), at most every 2.5 s. Returns true
// when one flinched (the caller adds sparks / sound). A shot passing a bit
// further off (his style's evadeR) makes him roll away from it, at most
// every evadeCd s (VI readily, HANK only when it is close), never while the
// other one rolls (QA PT2: both rolled off the same shot).
export function flinch(W: Wingmen, x: f64, y: f64, z: f64, rad: f64): bool {
    let rolling = false;
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        rolling = rolling || w.rollT > 0 || w.rollDelay >= 0;
    }
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        if (w.phase == "form" && w.rollT <= 0) {
            let dx = <f64>w.pos.x - x, dy = <f64>w.pos.y - y, dz = <f64>w.pos.z - z;
            let d2 = dx * dx + dy * dy + dz * dz;
            if (w.flinchT <= 0 && d2 < rad * rad) {
                w.flinchT = 2.5;
                trigger(w, "hit");
                return true;
            }
            let er = w.style.evadeR;
            if (w.evadeT <= 0 && !rolling && d2 < er * er && d2 >= rad * rad) {
                // (dir 1 rolls him left: away from a shot on his right)
                w.evadeT = w.style.evadeCd;
                startRoll(w, dx * w.rtx + dz * w.rtz > 0 ? -1 : 1, 0.4);
                rolling = true;
            }
        }
    }
    return false;
}

// cutoffS: hide wingmen that are past this rail distance (dived into the Eye;
// NaN = none). r / t: when given (r non-null, t not NaN), their exhaust
// ribbons are drawn too.
export function draw(W: Wingmen, cutoffS: f64 = NaN, r: R.Gfx? = null, t: f64 = NaN): void {
    let cut = isNaN(cutoffS) ? HUGE : cutoffS;
    for (let wi = 1; wi < W.list.length; wi++) {
        let w = W.list[wi];
        let s = w.sprite;
        if (s != null && w.phase != "away" && w.s < cut && r != null && !isNaN(t) && w.trails.length - 1 == 2) {
            let a = 0.5 + 0.5 * w.thrust;
            if (w.tips != null) {
                // painted flames are the hot core: the ribbons fade in past the tips
                // (never across his own body: ribbonVis)
                let fi = 2.2 * w.size / 3.4;
                R.trail(r, w.trails[1], t, a * 0.5 * w.exVis[1], fi);
                R.trail(r, w.trails[2], t, a * 0.5 * w.exVis[2], fi);
            } else {
                R.trail(r, w.trails[1], t, a * w.exVis[1]);
                R.trail(r, w.trails[2], t, a * w.exVis[2]);
            }
        }
        if (s != null && w.phase != "away" && w.s < cut) {
            let fade = 1.0;
            if (w.phase == "peel") {
                fade = 1 - mathx.smoothstep(2.2, 3.2, w.phaseT);
            } else if (w.phase == "join") {
                fade = mathx.smoothstep(0, 0.5, w.phaseT);
            }
            let rl = roll(w);
            let P = w.pos;
            let px = <f64>P.x, py = <f64>P.y, pz = <f64>P.z;
            R.spriteAdd(s, px, py, pz, rl, w.size, w.size, 0.5, fade);
            let ts = w.twinSprite;
            if (ts != null) {
                // the underside twin, mirrored in the water pass; fades with altitude
                let ro = fade * (1 - mathx.smoothstep(5, 18, py));
                if (ro > 0.01) {
                    R.spriteAdd(ts, px, py, pz, rl, w.size, w.size, 0.5, ro);
                }
                // the sprite no longer reflects, so it no longer gets the auto contact shadow
                if (r != null) {
                    let k = 1 - mathx.smoothstep(0.5, 14.0, py);
                    R.shadow(r, px, pz, w.size * (0.26 + 0.1 * (1 - k)), k * 0.8 * fade);
                }
            }
        }
    }
}
