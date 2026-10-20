// Port of src/game/events.luau. The mission script: spawns, comms, banners and set-piece triggers keyed by rail distance.
//
// Cues fire once when the pilot crosses their `s` (and only within `w` meters
// of it, so debug starts deep in the level skip what came before). Script
// comms go straight to the core's single channel with their priority and
// mood (the core queues them, drops stale ones and suppresses portal lines
// past the portal); boss lines wait here, reading that channel
// (ctx.commState), until they will play at once, and drop once their phase
// is over. Banners and warnings (ours and the bosses') go through an alert
// queue that gives the HUD's single centre slot room to breathe (DIRECTION
// #16): ours go out one at a time, only when the core's slot is free
// (ctx.alertFree) and has had a breather after its last slab (a mirror of
// the slot: every slab the core is handed), and never where a section edge
// would cut into them.
//
// Port: lists 1-based (slot 0 a dummy). fired / resolved / said (Luau sets
// by number) are Set<i32>; bossPhase a Map. Luau's hook wraps the ctx's
// banner / warning / boss / sting: here the core's Ctx calls onBanner /
// onWarning / onBoss / onSting first thing in those methods (they act only
// on the ctx this Events hooked, as Luau's wrappers). Timers are records
// (wave 0: the ENTER THE EYE banner, n: finale wave n), not closures. The
// storm's rail frame is track.frame (what the core's ctx.railFrame is).
import { format, FormatArg } from "rive/format";
import { Pattern } from "rive/pattern";
import { Ctx } from "./types";
import * as enemies from "./enemies";
import { SquadOpts } from "./enemies";
import * as fx from "./fx";
import * as crow from "./boss_stormcrow";
import * as ai from "./ai_types";
import { World, Comm } from "./ai_types";
import * as level from "../world/level";
import { Anchors } from "../world/level";
import * as track from "../world/track";
import * as pages from "./core_pages";
import { HUGE, lmax, opt, lsub, lfind, mod } from "../lib/compat";

export type Run = (Ev: Events, E: World, ctx: Ctx) => void;

class Timer {
    at: f64 = 0;
    wave: i32 = 0; // 0: ENTER THE EYE; n: finaleWave(n)
}

// kind 'banner' | 'warning'; `run` fires with the alert (a spawn tied to its
// warning) and still runs if the alert expires; `untilS` drops it past a spot;
// boss / phase: a boss phase callout, dropped once that phase is over;
// sec: an instruction for that section's objective, dropped once it settled;
// fromS: armed, held (and not aging) until that rail s; letters: once due,
// waits up to that long (s) for the line on air to be typed out (`typing`).
export class Alert {
    kind: string = "";
    text: string = "";
    sub: string = "";
    style: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    age: f64 = 0;
    maxAge: f64 = 0;
    untilS: f64 = HUGE;
    run: Run? = null;
    boss: string = "";
    phase: f64 = -1;
    sec: f64 = 0;
    fromS: f64 = -HUGE;
    letters: f64 = 0;
    typing: bool = false;
}

// A slab the core was handed (mirror of game alertPush / alertPump).
export class Slab {
    warn: bool = false;
    text: string = "";
    kind: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    age: f64 = 0;
    maxAge: f64 = 0;
}

// A boss line held until the channel is free; `lead` = the first line of its phase.
export class Held {
    c: Comm;
    lead: bool;
    age: f64 = 0;
    maxAge: f64;
    constructor(c: Comm, lead: bool, maxAge: f64) {
        this.c = c;
        this.lead = lead;
        this.maxAge = maxAge;
    }
}

// A line after a boss's end (kill / escape), handed over in turn as the line
// on air ends: dropped past maxAge (`must`: handed over then anyway) or
// once fewer than `need` s are left before rail s `before` (at max(speed,
// 60); `finale`: a wingman's call waiting goes first unless both fit).
export class Follow {
    who: string = "";
    text: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    mood: string = "";
    age: f64 = 0;
    maxAge: f64 = 0;
    must: bool = false;
    before: f64 = HUGE;
    need: f64 = 0;
    finale: bool = false;
    short: string? = null;
    shortNeed: f64 = 0;
}

// A threat that waits for the call announcing it (`lead`: the call's
// opening words): it comes as the call goes on air (lineOn), else at rail s
// `latest`.
export class Lead {
    lead: string;
    latest: f64;
    ctx: Ctx;
    run: Run;
    constructor(lead: string, latest: f64, ctx: Ctx, run: Run) {
        this.lead = lead;
        this.latest = latest;
        this.ctx = ctx;
        this.run = run;
    }
}

export class Events {
    fired: Set<i32> = new Set<i32>();
    E: World? = null;
    crow: string = "none"; // last Stormcrow result seen ('none' | 'active' | 'killed' | 'escaped')
    eye: string = "none";
    portalCued: bool = false;
    archChecked: bool = false;
    eyeOpen: bool = false;
    timers: Array<Timer> = new Array<Timer>(1);
    alerts: Array<Alert> = new Array<Alert>(1);
    secIdx: i32 = 0; // section the pilot was in last frame (checkpoint banners)
    edgeT: f64 = -1; // game time the pilot last crossed a section edge
    resolved: Set<i32> = new Set<i32>(); // sections whose objective slab already played
    // mirror of the core's centre slot
    hooked: Ctx? = null; // the ctx whose banner / warning / boss we observe
    core: Array<Slab> = new Array<Slab>(1); // slabs the core holds, not shown yet
    coreT: f64 = 0; // seconds the slab on screen still owns the slot
    coreGap: f64 = 0; // breathing room after it (seconds)
    coreBoss: bool = false; // the core's boss flag (slabs hold 2.2 s instead of 3.4 s)
    freeT: f64 = 0; // seconds the core's slot has been free (ctx.alertFree)
    said: Set<i32> = new Set<i32>(); // sections a down_* card was fired in (the core drops their result)
    held: Array<Held> = new Array<Held>(1); // boss lines waiting for the channel
    bossPhase: Map<string, f64> = new Map<string, f64>(); // latest phase each boss has spoken in
    follow: Array<Follow> = new Array<Follow>(1); // a boss's end, line by line
    followT: f64 = 1; // seconds since the last one was handed over
    leads: Array<Lead> = new Array<Lead>(1); // threats waiting for the call that announces them
}

function speaker(who: string): string {
    if (who == "tower") return "LIGHTHOUSE";
    if (who == "vi") return "VI";
    if (who == "hank") return "HANK";
    if (who == "baron") return "BARON KESSEL";
    return "";
}

// Debug: park every model in front of the camera instead of running the mission.
const SHOWROOM: bool = false;
// Debug: print the mission timeline (see ai.LOG).
const LOG: bool = ai.LOG;

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}
@inline function S(v: string): FormatArg {
    return FormatArg.string(v);
}

export function create(): Events {
    return new Events();
}

export function reset(Ev: Events): void {
    Ev.fired.clear();
    Ev.crow = "none";
    Ev.eye = "none";
    Ev.portalCued = false;
    Ev.archChecked = false;
    Ev.eyeOpen = false;
    Ev.timers.length = 1;
    Ev.alerts.length = 1;
    Ev.secIdx = 0;
    Ev.edgeT = -1;
    Ev.resolved.clear();
    // the core clears its alert queue on a restart too
    Ev.core.length = 1;
    Ev.coreT = 0;
    Ev.coreGap = 0;
    Ev.coreBoss = false;
    Ev.freeT = 0;
    Ev.said.clear();
    Ev.held.length = 1;
    Ev.bossPhase.clear();
    Ev.follow.length = 1;
    Ev.followT = 1;
    Ev.leads.length = 1;
    let E = Ev.E;
    if (E != null) {
        enemies.clear(E);
        fx.stormClear(E.fx);
    }
}

// Comms ----------------------------------------------------------------------------

// The core owns the one comms channel (game commPush / commPump; core.md One
// comms channel): it plays waiting lines by priority when the channel is
// free, lets a line take over the one on air only at a whole word, keeps the
// scripted beats on their cue (its BEATS list is the spoken cues below: keep
// in step) and drops lines that waited too long (ctx.comm: 10 s at prio 3+,
// 6 s at prio 2, 3 s at prio 1). prio: 1 flavor, 2 useful, 3 must play, 4
// takes over. mood: the speaker's portrait expression (DIRECTION #9):
// 'neutral' | 'happy' | 'worried' | 'shout' | 'angry'. Boss lines wait here
// instead and reach the core only when they will play at once (bossComms
// reads ctx.commState), so none plays after its phase is over.

function say(Ev: Events, ctx: Ctx, who: string, text: string, seconds: f64, prio: f64, mood: string): void {
    let sp = speaker(who);
    if (LOG) {
        console.log(format("[%5.0f m %6.1f s] %s (%d, %s): %s", [N(ctx.railS), N(ctx.t), S(sp != "" ? sp : who), N(prio), S(mood), S(text)]));
    }
    ctx.comm(who, sp != "" ? sp : who.toUpperCase(), text, seconds, mood, prio);
}

// The call leads its threat: `run` waits for the line opening with `lead`
// to go on air (or rail s `latest`).
function leadThreat(Ev: Events, ctx: Ctx, lead: string, latest: f64, run: Run): void {
    Ev.leads.push(new Lead(lead, latest, ctx, run));
}

function runLead(Ev: Events, k: i32): void {
    let L = Ev.leads[k];
    Ev.leads.splice(k, 1);
    let E = Ev.E;
    if (E != null) {
        if (LOG) {
            console.log(format("[%5.0f m %6.1f s] lead %s", [N(L.ctx.railS), N(L.ctx.t), S(L.lead)]));
        }
        L.run(Ev, E, L.ctx);
    }
}

// A threat waits for this line (the core: it reads no slab out).
export function leadWaiting(Ev: Events, text: string): bool {
    for (let i = 1; i < Ev.leads.length; i++) {
        let L = Ev.leads[i];
        if (lsub(text, 1, L.lead.length) == L.lead) {
            return true;
        }
    }
    return false;
}

// A line went on air (the core's commPlay): the threat it announces comes now.
export function lineOn(Ev: Events, text: string): void {
    for (let k = Ev.leads.length - 1; k >= 1; k--) {
        let lead = Ev.leads[k].lead;
        if (lsub(text, 1, lead.length) == lead) {
            runLead(Ev, k);
        }
    }
}

// The longest run of whole sentences from the start of `text` (short of the
// whole line) that is over in `eta` s as bossComms times it and typed out
// (at 15 cps after the 0.27 s lead) with half to spare: should the phase
// end sooner, the next lead takes over at its end and cuts nothing (the
// core cuts only a line still typing); null when not even the first is.
function headFit(text: string, eta: f64): string? {
    let best: string? = null;
    let i = 1;
    while (true) {
        let m = Pattern.find(text, "[%.!?]+%s", i - 1);
        if (m == null) {
            return best;
        }
        let b = m.end; // (Luau's 1-based inclusive end)
        let head = text.substring(0, b - 1);
        let n = <f64>head.length;
        if (1.8 + 0.042 * n > eta || (0.27 + n / 15) * 1.5 > eta) {
            return best;
        }
        best = head;
        i = b + 1;
    }
}

// Boss lines. A kill / escape reaction goes out at once. A phase line waits
// for the channel: the first line of a phase goes out at once at prio 4 (the
// core lets the line on air finish or ends it on a whole word; QA M14); the
// others go out as the line on air ends with nothing of prio 3+ waiting (at
// prio 3, ahead of the wingmen's lines), the ones said with the phase change
// for up to 9 s, later reactions for 3-4 s. Whatever is still waiting when
// the fight moves past its phase is dropped.
function bossComms(Ev: Events, E: World, ctx: Ctx): void {
    let held = Ev.held;
    let turned = "";
    for (let i = 1; i < E.comms.length; i++) {
        let c = E.comms[i];
        if (c.phase < 0) {
            say(Ev, ctx, c.who, c.text, c.seconds, c.prio, c.mood);
        } else {
            let lead = c.phase > (Ev.bossPhase.has(c.boss) ? Ev.bossPhase.get(c.boss) : 0.0);
            if (lead) {
                Ev.bossPhase.set(c.boss, c.phase);
                turned = c.boss;
            }
            let maxAge = lead ? 8.0 : turned == c.boss ? 9.0 : c.prio >= 2 ? 5.0 : 3.0;
            held.push(new Held(c, lead, maxAge));
        }
    }
    E.comms.length = 1;
    let b = E.boss;
    let i = 1;
    while (i < held.length) {
        let h = held[i];
        h.age += ctx.dt;
        let c = h.c;
        // (`leaving`: the Watcher's retreat is called, its fight is over)
        let over = b == null || b.kind != c.boss || b.killed || b.escaped || b.phase > c.phase || b.v.leaving > 0;
        if (over || h.age > h.maxAge) {
            held.splice(i, 1);
            if (LOG) {
                console.log(format("[%5.0f m %6.1f s] COMM DROPPED (%s phase %d, waited %.1f s): %s", [N(ctx.railS), N(ctx.t), S(c.boss), N(c.phase), N(h.age), S(c.text)]));
            }
        } else {
            i += 1;
        }
    }
    if (held.length - 1 == 0) {
        return;
    }
    // the core's channel as it is (a sting holds it: taken until the sting
    // is over). Handed over a frame before the line on air ends, a line
    // plays next
    ctx.commState();
    let left = ctx.csLeft, waiting = ctx.csWait;
    let eta = b != null ? b.v.phaseEta : NaN;
    if (!isNaN(eta)) {
        // a boss that keeps its phase's time left (v.phaseEta: the
        // Stormcrow) has whole lines (QA sweep 2 HUD2-1): the lead, else the
        // next, goes out when the channel is free and only when it is over
        // (the core's commDur, less the read floor) with half of it to spare
        // before the phase may be; else it waits, and goes with its phase
        if (left > 0.05 || waiting >= 3) {
            return;
        }
        // whole lines first (lead, then the rest), else a line's leading
        // whole sentence(s) that fit (the core's fitLine idea)
        for (let pass = 1; pass <= 4; pass++) {
            for (let j = 1; j < held.length; j++) {
                let h = held[j];
                let c = h.c;
                if (h.lead == (pass % 2 == 1)) {
                    let text: string? = pass <= 2 ? c.text : headFit(c.text, eta);
                    if (text != null) {
                        let n = <f64>text.length;
                        let sec = c.seconds * n / <f64>c.text.length;
                        if (pass > 2 || lmax(sec, 1.8 + 0.042 * n) * 1.5 <= eta) {
                            held.splice(j, 1);
                            say(Ev, ctx, c.who, text, sec, h.lead ? 4.0 : lmax(c.prio, 3), c.mood);
                            return;
                        }
                    }
                }
            }
        }
        return;
    }
    let k = 1;
    for (let j = 1; j < held.length; j++) {
        if (held[j].lead) {
            k = j;
            break;
        }
    }
    let h = held[k];
    if (h.lead || (left <= 0.05 && waiting < 3)) {
        held.splice(k, 1);
        let c = h.c;
        say(Ev, ctx, c.who, c.text, c.seconds, h.lead ? 4.0 : lmax(c.prio, 3), c.mood);
    }
}

// A boss's end: the Baron's reaction (the boss says it, at once), then these
// in order, each handed over as the line before it ends (queued together,
// the core played the highest prio first: HANK's kill cheer came ~4 s late,
// after the tower's, or dropped).
// (`short`: what is said instead when the room has shrunk under `need` but
// not under `shortNeed`)
function follow(Ev: Events, who: string, text: string, seconds: f64, prio: f64, mood: string, maxAge: f64, must: bool,
    before: f64 = NaN, need: f64 = NaN, finale: bool = false, short: string? = null, shortNeed: f64 = NaN): void {
    let f = new Follow();
    f.who = who;
    f.text = text;
    f.seconds = seconds;
    f.prio = prio;
    f.mood = mood;
    f.age = 0;
    f.maxAge = maxAge;
    f.must = must;
    f.before = opt(before, HUGE);
    f.need = opt(need, 0);
    f.finale = finale;
    f.short = short;
    f.shortNeed = opt(shortNeed, 0);
    Ev.follow.push(f);
}

// A `finale` line goes ahead of HANK's closing call (waiting in the core)
// only when the call's shortest form still fits after it: WING_CALL m,
// 'Last stretch.' timed flat out as the core times it.
const WING_CALL: f64 = 110;

function followRoom(f: Follow, ctx: Ctx): f64 {
    return (f.before - ctx.railS) / lmax(ctx.player.speed, 60);
}

function pumpFollow(Ev: Events, ctx: Ctx): void {
    let q = Ev.follow;
    Ev.followT += ctx.dt;
    if (q.length - 1 == 0) {
        return;
    }
    let i = 1;
    while (i < q.length) {
        let f = q[i];
        f.age += ctx.dt;
        let room = followRoom(f, ctx);
        let short = f.short;
        if (short != null && room < f.need && room >= f.shortNeed) {
            // (paced as short as it reads: the core's floor)
            f.text = short;
            f.need = f.shortNeed;
            f.short = null;
            f.seconds = 0;
        }
        if (!f.must && (f.age > f.maxAge || room < f.need)) {
            q.splice(i, 1);
            if (LOG) {
                console.log(format("[%5.0f m %6.1f s] FOLLOW DROPPED (waited %.1f s, room %.1f s): %s", [N(ctx.railS), N(ctx.t), N(f.age), N(room), S(f.text)]));
            }
        } else {
            i += 1;
        }
    }
    if (q.length < 2 || Ev.held.length - 1 > 0) {
        return;
    }
    let f = q[1];
    // (handed over a frame before the line on air ends it plays next; the
    // one before it gets 0.5 s to go on air first)
    ctx.commState();
    let left = ctx.csLeft, waiting = ctx.csWait;
    if (f.finale && waiting >= 2 && f.before - ctx.railS - f.need * lmax(ctx.player.speed, 60) < WING_CALL) {
        // (the call goes first, then this if it still fits)
        return;
    }
    if ((Ev.followT > 0.5 && left <= 0.05 && waiting < 3) || (f.must && f.age > f.maxAge)) {
        q.splice(1, 1);
        Ev.followT = 0;
        say(Ev, ctx, f.who, f.text, f.seconds, f.prio, f.mood);
    }
}

// Outside play (the outro, a restart): boss lines go straight to the core
// (of a boss's end only the lines that must play).
function drainBossComms(Ev: Events, E: World, ctx: Ctx): void {
    for (let i = 1; i < E.comms.length; i++) {
        let c = E.comms[i];
        say(Ev, ctx, c.who, c.text, c.seconds, c.prio, c.mood);
    }
    E.comms.length = 1;
    for (let i = 1; i < Ev.follow.length; i++) {
        let f = Ev.follow[i];
        if (f.must) {
            say(Ev, ctx, f.who, f.text, f.seconds, f.prio, f.mood);
        }
    }
    Ev.follow.length = 1;
}

// Alerts ---------------------------------------------------------------------------

// The core's slot rules (game alertPush / alertPump, core notes): a slab
// holds 3.4 s (2.2 s while a boss is up), a warning its seconds; priority
// mission end 5 > warning 4 > objective / boss phase 3 > checkpoint 2 >
// info 1; waiting slabs drop after 2.5 s (warning), 3.5 s (info) or 5 s;
// info, SKY PORTAL, checkpoints and objective results drop while a boss is
// up.
const BANNER_HOLD: f64 = 3.4;
const BANNER_HOLD_FIGHT: f64 = 2.2;
// breathing room after a slab before the next of ours
const WARN_GAP: f64 = 0.6;
const BANNER_GAP: f64 = 0.3;
// air left (ctx.commState) once a line's letters are out: the core's typer
// ends its letters TYPE_TAIL before the line's air ends (QA RP-3)
const LETTERS_LEFT: f64 = pages.TYPE_TAIL;

// The section an objective slab is about (its sub starts with the label).
function objSection(sub: string): i32 {
    let SS = level.sections;
    for (let i = 1; i < SS.length; i++) {
        if (lfind(sub, SS[i].label) == 1) {
            return i;
        }
    }
    return 0;
}

function mirrorPush(Ev: Events, ctx: Ctx, warn: bool, text: string, sub: string, kind: string, seconds: f64): void {
    let objective = !warn && lsub(text, 1, 9) == "OBJECTIVE";
    // an objective settled mid-section: its edge will only raise the checkpoint
    if (objective && ctx.t != Ev.edgeT) {
        Ev.resolved.add(level.sectionAt(ctx.railS));
    }
    // what never takes the core's slot: during a boss fight the phase
    // callouts ('warning'-kind banners) go to the chip under the boss bar
    // (Hud.bossPhase), checkpoint slabs and objective results are dropped
    // (the route tab ticks them); a result a down_* card already said is
    // dropped too
    if (!warn && Ev.coreBoss && (kind == "warning" || kind == "checkpoint" || objective)) {
        return;
    }
    if (objective && Ev.said.has(objSection(sub))) {
        return;
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
    let s = new Slab();
    s.warn = warn;
    s.text = text;
    s.kind = kind;
    s.seconds = seconds;
    s.prio = prio;
    s.age = 0;
    s.maxAge = maxAge;
    Ev.core.push(s);
}

// Observe every slab the core is handed (scoring's checkpoint / objective
// slabs, the finale, ours), its boss flag and our down_* cards (the core
// drops the result of the section a card was fired in). Luau installs
// pass-through wrappers once per ctx; here the core's Ctx calls these at the
// top of its banner / warning / boss / sting (each a no-op unless this
// Events hooked that ctx).
function hook(Ev: Events, ctx: Ctx): void {
    if (Ev.hooked == ctx) {
        return;
    }
    Ev.hooked = ctx;
}

export function onBanner(Ev: Events, ctx: Ctx, text: string, sub: string, kind: string): void {
    if (Ev.hooked != ctx) return;
    mirrorPush(Ev, ctx, false, text, sub, kind, 0);
}

export function onWarning(Ev: Events, ctx: Ctx, text: string, seconds: f64): void {
    if (Ev.hooked != ctx) return;
    mirrorPush(Ev, ctx, true, text, "", "warning", seconds);
}

export function onBoss(Ev: Events, ctx: Ctx, active: bool): void {
    if (Ev.hooked != ctx) return;
    Ev.coreBoss = active;
}

export function onSting(Ev: Events, ctx: Ctx, kind: string): void {
    if (Ev.hooked != ctx) return;
    if (lsub(kind, 1, 5) == "down_") {
        Ev.said.add(level.sectionAt(ctx.railS));
    }
}

function mirrorPump(Ev: Events, ctx: Ctx): void {
    let dt = ctx.dt;
    let q = Ev.core;
    let i = 1;
    while (i < q.length) {
        let a = q[i];
        a.age += dt;
        let moot = Ev.coreBoss && (a.prio <= 1 || a.text == "SKY PORTAL"
            || (!a.warn && (a.kind == "checkpoint" || lsub(a.text, 1, 9) == "OBJECTIVE")));
        if (a.age > a.maxAge || moot) {
            q.splice(i, 1);
        } else {
            i += 1;
        }
    }
    Ev.coreT -= dt;
    if (q.length - 1 == 0 || Ev.coreT > 0) {
        return;
    }
    let best = 1;
    for (let k = 2; k < q.length; k++) {
        if (q[k].prio > q[best].prio) {
            best = k;
        }
    }
    let a = q[best];
    q.splice(best, 1);
    Ev.coreT = a.warn ? a.seconds : Ev.coreBoss ? BANNER_HOLD_FIGHT : BANNER_HOLD;
    Ev.coreGap = a.warn ? WARN_GAP : BANNER_GAP;
    if (LOG) {
        console.log(format("[%5.0f m %6.1f s] SLAB %s (prio %d, waited %.1f s)", [N(ctx.railS), N(ctx.t), S(a.text), N(a.prio), N(a.age)]));
    }
}

// prio: 1 flavor (dropped when it can't play soon), 2 normal (dropped after
// maxAge; a tied spawn still runs), 3 must play (waits as long as it takes).
function alert(Ev: Events, kind: string, text: string, sub: string, style: string, seconds: f64, prio: f64,
    maxAge: f64 = NaN, run: Run? = null, untilS: f64 = NaN): void {
    let a = new Alert();
    a.kind = kind;
    a.text = text;
    a.sub = sub;
    a.style = style;
    a.seconds = seconds;
    a.prio = prio;
    a.age = 0;
    a.maxAge = !isNaN(maxAge) ? maxAge : prio >= 3 ? HUGE : prio == 2 ? 4.0 : 2.5;
    a.untilS = opt(untilS, HUGE);
    a.run = run;
    a.boss = "";
    a.phase = -1;
    a.sec = 0;
    a.fromS = -HUGE;
    a.letters = 0;
    a.typing = false;
    Ev.alerts.push(a);
}

// Armed ahead (`fromS`), a warning already waits in our queue, so the core
// keeps its wingmen's lines clear of it (pages.warnWaits) and a read slab
// gives way to it; `letters`: see Alert.
function warn(Ev: Events, text: string, seconds: f64, prio: f64 = NaN, run: Run? = null, fromS: f64 = NaN, letters: f64 = NaN): void {
    alert(Ev, "warning", text, "", "warning", seconds, opt(prio, 2), NaN, run);
    let a = Ev.alerts[Ev.alerts.length - 1];
    a.fromS = opt(fromS, -HUGE);
    a.letters = opt(letters, 0);
}

function banner(Ev: Events, text: string, sub: string, style: string, prio: f64 = NaN, untilS: f64 = NaN, maxAge: f64 = NaN, sec: f64 = NaN): void {
    alert(Ev, "banner", text, sub, style, 0, opt(prio, 2), maxAge, null, untilS);
    Ev.alerts[Ev.alerts.length - 1].sec = opt(sec, 0);
}

function holdOf(Ev: Events, a: Alert): f64 {
    return a.kind == "warning" ? a.seconds : Ev.coreBoss ? BANNER_HOLD_FIGHT : BANNER_HOLD;
}

// Seconds until the pilot crosses the next section edge (the core raises a
// checkpoint banner there, plus the objective result of the section left).
function toNextCheckpoint(ctx: Ctx): f64 {
    let idx = level.sectionAt(ctx.railS);
    let SS = level.sections;
    if (idx + 1 >= SS.length) {
        return HUGE;
    }
    let nxt = SS[idx + 1];
    return (nxt.s0 - ctx.railS) / lmax(ctx.player.speed, 20);
}

// Can `a` start now without a section edge cutting into it? A must-play slab
// may run over an edge that only raises the checkpoint by up to 2.5 s (the
// core shows the checkpoint right after it, well inside its 5 s).
function edgeClear(Ev: Events, ctx: Ctx, a: Alert): bool {
    let left = toNextCheckpoint(ctx);
    let hold = holdOf(Ev, a);
    if (left >= hold + 0.2) {
        return true;
    }
    if (a.prio >= 3 && Ev.resolved.has(level.sectionAt(ctx.railS))) {
        return left >= hold - 2.5;
    }
    return false;
}

// A boss callout whose phase is over (or whose boss is gone) is stale, and
// so is an instruction for an objective that already settled.
function stale(Ev: Events, E: World, a: Alert): bool {
    if (a.sec > 0 && Ev.resolved.has(<i32>a.sec)) {
        return true;
    }
    if (a.phase < 0) {
        return false;
    }
    let b = E.boss;
    return b == null || b.kind != a.boss || b.killed || b.escaped || b.phase > a.phase;
}

function fire(Ev: Events, E: World, ctx: Ctx, a: Alert, show: bool): void {
    if (show) {
        if (LOG) {
            console.log(format("[%5.0f m %6.1f s] ALERT %s: %s / %s", [N(ctx.railS), N(ctx.t), S(a.kind), S(a.text), S(a.sub)]));
        }
        if (a.kind == "warning") {
            ctx.warning(a.text, a.seconds);
        } else {
            ctx.banner(a.text, a.sub, a.style);
        }
        // the core shows it this frame: own the slot from now
        mirrorPump(Ev, ctx);
    } else if (LOG && a.prio >= 2) {
        console.log(format("[%5.0f m %6.1f s] ALERT DROPPED %s / %s", [N(ctx.railS), N(ctx.t), S(a.text), S(a.sub)]));
    }
    let run = a.run;
    if (run != null) {
        run(Ev, E, ctx);
    }
}

// A set-piece sting is on screen: the core's ctx.stingActive (Luau falls
// back to E.stingT, our own hold, for a ctx without it: every Ctx has it).
function stingBusy(E: World, ctx: Ctx): bool {
    return ctx.stingActive();
}

function pumpAlerts(Ev: Events, E: World, ctx: Ctx): void {
    for (let i = 1; i < E.alerts.length; i++) {
        let b = E.alerts[i];
        alert(Ev, b.kind, b.text, b.sub, b.style, b.seconds, b.prio);
        let a = Ev.alerts[Ev.alerts.length - 1];
        a.boss = b.boss;
        a.phase = b.phase;
    }
    E.alerts.length = 1;
    let idx = level.sectionAt(ctx.railS);
    if (idx != Ev.secIdx) {
        // scoring raises the checkpoint (and the objective result) this frame
        Ev.edgeT = ctx.t;
        if (Ev.secIdx > 0 && LOG) {
            console.log(format("[%5.0f m %6.1f s] CHECKPOINT %d", [N(ctx.railS), N(ctx.t), N(idx)]));
        }
        Ev.secIdx = idx;
    }
    mirrorPump(Ev, ctx);
    // the core's own word on its slot (nothing showing, nothing waiting, no
    // sting): the mirror misses slabs a sting drops (the arch result)
    let free = ctx.alertFree();
    Ev.freeT = free ? Ev.freeT + ctx.dt : 0;
    let q = Ev.alerts;
    let i = 1;
    while (i < q.length) {
        let a = q[i];
        if (ctx.railS >= a.fromS) {
            a.age += ctx.dt;
        }
        if (ctx.railS > a.untilS || stale(Ev, E, a)) {
            q.splice(i, 1);
            if (LOG) {
                console.log(format("[%5.0f m %6.1f s] ALERT STALE %s / %s", [N(ctx.railS), N(ctx.t), S(a.text), S(a.sub)]));
            }
        } else if (a.age > a.maxAge && a.prio < 3) {
            // too late to show: keep what it was tied to (a spawn)
            q.splice(i, 1);
            fire(Ev, E, ctx, a, false);
        } else {
            i += 1;
        }
    }
    // no set-piece sting on screen (DIRECTION #21: the core holds centre
    // alerts through one; ours wait here so they are not dropped stale)
    if (q.length - 1 == 0 || stingBusy(E, ctx)) {
        return;
    }
    // boss phase callouts go to the chip under the boss bar while the bar
    // is up (the core routes them there): no slot to wait for
    if (Ev.coreBoss) {
        let j = 1;
        while (j < q.length) {
            let a = q[j];
            if (a.kind == "banner" && a.style == "warning" && a.phase >= 0) {
                q.splice(j, 1);
                fire(Ev, E, ctx, a, true);
            } else {
                j += 1;
            }
        }
        if (q.length - 1 == 0) {
            return;
        }
    }
    // the core's slot must be free, and have had its breather after the
    // last slab
    if (!free || Ev.freeT < Ev.coreGap) {
        // (a warning waiting for a line's letters goes at once should the
        // core take a slab meanwhile: that waits for the same letters, and
        // the core shows the warning first)
        for (let k = 1; k < q.length; k++) {
            let c = q[k];
            if (c.typing && !free) {
                q.splice(k, 1);
                fire(Ev, E, ctx, c, true);
                return;
            }
        }
        return;
    }
    // (letters out: the typer is done TYPE_TAIL before the line's air ends)
    let left = ctx.commState();
    let best = 0;
    for (let k = 1; k < q.length; k++) {
        let c = q[k];
        c.typing = ctx.railS >= c.fromS && c.age < c.letters && left > LETTERS_LEFT;
        if (ctx.railS >= c.fromS && !c.typing && (best == 0 || c.prio > q[best].prio)) {
            best = k;
        }
    }
    if (best == 0) {
        return;
    }
    let a = q[best];
    if (!edgeClear(Ev, ctx, a)) {
        return;
    }
    q.splice(best, 1);
    fire(Ev, E, ctx, a, true);
}

// Mission cues -----------------------------------------------------------------------

class Cue {
    s: f64;
    w: f64;
    run: Run;
    constructor(s: f64, w: f64, run: Run) {
        this.s = s;
        this.w = w;
        this.run = run;
    }
}

const A: Anchors = level.anchors;
const PORTAL_S: f64 = level.portalS;
const LEN: f64 = level.track.length;
const EYE_S: f64 = A.eyeS;
// boss entrances (spawn + warning), far enough before the next checkpoint
// that the warning clears the slot before the checkpoint slab even if the
// pilot arrives boosting (the boss caps the speed as it spawns)
const STORMCROW_S: f64 = 3600;
const WATCHER_S: f64 = 7450;
// where they give up (escape). The Stormcrow hangs on 50 m more with its core
// out and its final blast lands by PORTAL_S - 220, so STORMCROW DOWN plays
// before the 06 checkpoint; the Watcher's ending (blast or retreat) is over
// by EYE_S - 210, well before the finale at EYE_S - 70.
const CROW_END: f64 = PORTAL_S - 350;
// the stage clears this far (m) before the Stormcrow's cue
const CLEAR_LEAD: f64 = 45;
const WATCHER_END: f64 = EYE_S - 300;

const CUES: Array<Cue> = new Array<Cue>(1); // 1-based

function at(s: f64, run: Run, w: f64 = NaN): void {
    CUES.push(new Cue(s, opt(w, 160), run));
}

// squadron opts (Luau { fire = .., y = .., ... })
function so(fire: f64, y: f64 = NaN, x: f64 = NaN, gap: f64 = NaN, sx: f64 = NaN): SquadOpts {
    let o = new SquadOpts();
    o.fire = fire;
    o.y = y;
    o.x = x;
    o.gap = gap;
    o.sx = sx;
    return o;
}

// Canyon gun nests: rock pedestals hugging the canyon walls (s, side, top height). 1-based, each 1-based.
const TURRETS: Array<Array<f64>> = [
    [0.0],
    [0.0, 2960, 1, 12], [0.0, 3040, -1, 15], [0.0, 3120, 1, 10], [0.0, 3230, -1, 13],
    [0.0, 3330, 1, 16], [0.0, 3440, -1, 11], [0.0, 3560, 1, 14], [0.0, 3660, -1, 12],
];

function ledge(s: f64, side: f64, y: f64): f64 {
    // the inner face leans back 0.12 * height; tuck the pedestal against it
    return side * (level.cliffTurnDist(s, side) + 0.12 * y - 3.2);
}

// 01 LIGHTHOUSE ----------------------------------------------------------------------
at(25, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "tower", "Lighthouse to Corsair. Skies are yours - bring the jacket back in one piece.", 3.6, 3, "happy");
});
at(245, (Ev: Events, E: World, ctx: Ctx): void => {
    banner(Ev, "RING CHAIN", "THREAD EVERY RING FOR A BONUS", "info", 1);
});
// s 300-520 belongs to the lighthouse (upper left in straight flight): the
// first bogeys come in once it has passed, and the head-on line meets them
// on their way back (a pincer, all of it over before the 02 checkpoint so
// CLEAR THE SKIES is fair)
at(560, (Ev: Events, E: World, ctx: Ctx): void => {
    warn(Ev, "BOGEYS ON YOUR SIX!", 2.6, 2, (ev: Events, e: World, c: Ctx): void => {
        enemies.squadron(e, c, "biplane", "overtake", 5, "v", 1, so(2.4));
    });
});
at(610, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.squadron(E, ctx, "biplane", "headon", 3, "line", 1, so(1.8, 1));
});

// 02 SEA ARCH ------------------------------------------------------------------------
// Comms cues (QA M14; the core's BEATS mirrors them): the Baron, the arch
// warning and the kamikaze call each need ~5 / 5 / 3 s of channel, and the
// kamikaze call belongs with its spawn: the Baron speaks from 770 m (his
// drones still come at 960), the kamikazes come at 1240 (their call is off
// the channel by ~1350), the tower's mines call goes at 1360 with MINEFIELD
// AHEAD at 1375 (playtest 1 #4; the core recuts it and pairs it with the
// warning). No mine before that warning (playtest 2): every field is on the
// arch's approach, 'on the arch', in view from 1300.
at(770, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "baron", "Baron Kessel speaking. You are flying through MY sky, little rocket man.", 3.6, 2, "happy");
});
at(960, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.hoverDrones(E, ctx, 3, 75, 30, 7, 7, true);
});
at(1240, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "vi", "Kamikazes! Shoot them or roll!", 2.4, 3, "shout");
    enemies.kamikaze(E, ctx, -8, 0);
    enemies.kamikaze(E, ctx, 8, 0.6);
    enemies.kamikaze(E, ctx, 0, 1.2);
});
at(1200, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.squadron(E, ctx, "biplane", "loop", 3, "column", 1, so(2.2));
});
at(1300, (Ev: Events, E: World, ctx: Ctx): void => {
    // a string of mines across the arch mouth framing the ring line: pop
    // one and the chain takes the rest
    let s0 = level.anchors.archS - 70;
    const STRING: Array<Array<f64>> = [[0.0], [0.0, -5.5, 6], [0.0, 5.5, 6], [0.0, -10.5, 0.75], [0.0, 10.5, 0.75], [0.0, -14.5, 10], [0.0, 14.5, 10], [0.0, 0, 16.5]];
    for (let i = 1; i < STRING.length; i++) {
        let m = STRING[i];
        enemies.mine(E, ctx, s0 + <f64>(i % 2) * 6, m[1], m[2]);
    }
    enemies.mineField(E, ctx, level.anchors.archS - 150, 6, 4, 7, true);
    // and one on the sea between them (was the slalom's)
    enemies.mineField(E, ctx, level.anchors.archS - 110, -4, 5, 8, false);
}, 310);
at(1360, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "tower", "Arch dead ahead. Kessel strung mines across it - pop one and the whole string goes.", 3.8, 3, "worried");
});
at(1375, (Ev: Events, E: World, ctx: Ctx): void => {
    warn(Ev, "MINEFIELD AHEAD", 2.4, 1);
});
at(A.archS + 4, (Ev: Events, E: World, ctx: Ctx): void => {
    let a = level.anchors.arch;
    let p = ctx.player;
    let ok = Math.abs(p.x - a.x) < a.w / 2 && p.y > a.y && p.y < a.y + a.h;
    if (ok) {
        say(Ev, ctx, "hank", "Ha! Threaded it like a needle.", 2.2, 1, "happy");
    }
}, 30);
at(1090, (Ev: Events, E: World, ctx: Ctx): void => {
    // high over the slalom (its stacks top out at 38 m)
    enemies.squadron(E, ctx, "drone", "sweep", 4, "column", -1, so(2.6, 28));
});
at(1740, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.hoverDrones(E, ctx, 4, 80, 36, 9, 6, true);
});

// 03 LOW PASS ------------------------------------------------------------------------
at(1850, (Ev: Events, E: World, ctx: Ctx): void => {
    // under the call, high over the open water (21-34 m, the fangs top out
    // at 15): the column crosses ~400 m of rail while the pilot flies on and
    // leaves the view out wide by ~2230 at cruise, so BOGEYS ON YOUR SIX!
    // goes up with no biplane ahead
    enemies.squadron(E, ctx, "biplane", "sweep", 4, "column", 1, so(2.4, 10));
});
// (1900: HANK's 'Threaded' plays after the arch card first. 'three point
// two': the HUD's STAY UNDER 3.2 M, and no typer stop at a '3.')
at(1900, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "tower", "Low pass. Kiss the water, Corsair - under three point two meters their radar's blind. Score doubles.", 4.2, 2, "neutral");
});
// BOGEYS ON YOUR SIX! and the escort at 2230: after the low pass call's
// letters, ahead of a skimmer's LOW PASS result, the sweep out of the view.
// Armed from 2100; at 2230 it waits up to 2 s for a line still typing. VI's
// rejoin goes out with it (core RADIO pair, QA RP-1)
at(2100, (Ev: Events, E: World, ctx: Ctx): void => {
    warn(Ev, "BOGEYS ON YOUR SIX!", 2.2, 2, (ev: Events, e: World, c: Ctx): void => {
        enemies.squadron(e, c, "biplane", "escort", 4, "v", -1, so(2.2));
    }, 2230, 2.0);
}, 290);
// the loop comes in low and comes down to strafe once the escort has climbed
// away; past the pilot by ~2790 at cruise, before the canyon walls. It keeps
// this cue; the drone dive waits for HANK's call (below)
at(2400, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "hank", "Drone swarm dropping in from the clouds. Heads up!", 2.8, 2, "worried");
    // the dive comes with the call (QA RP-4): on its first letters, by 2680
    // at the latest
    leadThreat(Ev, ctx, "Drone swarm", 2680, (ev: Events, e: World, c: Ctx): void => {
        enemies.squadron(e, c, "drone", "dive", 5, "line", 1, so(2.4));
    });
    enemies.squadron(E, ctx, "biplane", "loop", 3, "column", -1, so(2.0, NaN, 6));
});
at(2560, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.hoverDrones(E, ctx, 3, 70, 26, 4, 5, true);
});

// 04 CLIFF TURN ----------------------------------------------------------------------
at(2870, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "tower", "Gun nests on the canyon walls. Don't give them a straight line.", 3.4, 2, "worried");
    for (let i = 1; i < TURRETS.length; i++) {
        let t = TURRETS[i];
        let s = t[1], side = t[2], y = t[3];
        enemies.turret(E, ctx, s, ledge(s, side, y), y, 1.5 + mod(s, 3) * 0.2);
    }
});
at(3120, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "vi", "Head-on through the gap! Roll and bounce their lead right back!", 3.2, 2, "shout");
    // the canyon is a 16 m slot: a tight V that keeps inside |x| < 12
    enemies.squadron(E, ctx, "biplane", "headon", 5, "v", 1, so(1.6, 2, NaN, 4, 0.15));
});
at(3400, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.kamikaze(E, ctx, -6, 0);
    enemies.kamikaze(E, ctx, 6, 0.4);
});
at(3330, (Ev: Events, E: World, ctx: Ctx): void => {
    // a drone column snaking down into the slot (|x| < 9); whatever is left
    // of it ducks into the sea a beat before the Stormcrow's cue (below)
    enemies.squadron(E, ctx, "drone", "snake", 5, "column", 1, so(2.2));
});
// (3370: over before the Stormcrow's welcome at 3600)
at(3370, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "hank", "Climb, Corsair! Something big on radar... REAL big.", 3.0, 2, "worried");
});

// 05 SKY PORTAL ----------------------------------------------------------------------
// The airship shows up over the canyon exit *before* the 05 checkpoint, so its
// warning, the checkpoint slab and its first callout land ~3.5 s apart and the
// fight gets the whole climb. ~0.8 s before her cue the sky ahead clears;
// the storm she hides in brews over the bay past the canyon mouth
// (boss_stormcrow drives it from there)
at(STORMCROW_S - 150, (Ev: Events, E: World, ctx: Ctx): void => {
    crow.brew(E.fx, STORMCROW_S);
}, 1000);
at(STORMCROW_S - CLEAR_LEAD, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.clearStage(E);
}, CLEAR_LEAD);
at(STORMCROW_S, (Ev: Events, E: World, ctx: Ctx): void => {
    ctx.sfx("horn", 0.9);
    enemies.bossStart(E, ctx, "stormcrow", CROW_END);
    warn(Ev, "WARNING  HEAVY AIRSHIP", 2.6, 3);
    say(Ev, ctx, "baron", "Welcome aboard the STORMCROW, rocket man. Mind the propellers!", 3.4, 3, "happy");
}, 900);

// 06 VIOLET REACH --------------------------------------------------------------------
at(PORTAL_S + 60, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "hank", "Whoa. Everything's... purple. I don't like purple.", 2.8, 1, "worried");
});
at(PORTAL_S + 320, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "baron", "My Jet Troopers will teach you some manners!", 3.0, 2, "happy");
    warn(Ev, "JET TROOPERS ON YOUR SIX", 2.6, 2, (ev: Events, e: World, c: Ctx): void => {
        enemies.troopers(e, c, 3, 48, 24, 7, false);
    });
});
// (+570: after the Baron's line)
at(PORTAL_S + 570, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "vi", "They're fast! Lead 'em, don't chase 'em.", 2.6, 1, "shout");
});
at(PORTAL_S + 700, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.troopers(E, ctx, 4, 60, 30, 9, true);
});
at(PORTAL_S + 900, (Ev: Events, E: World, ctx: Ctx): void => {
    // a diving line over the lagoon
    enemies.squadron(E, ctx, "drone", "dive", 4, "line", 1, so(2.2));
});
at(A.diveS1 - 140, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.troopers(E, ctx, 3, 45, 28, 5, false);
    enemies.hoverDrones(E, ctx, 3, 80, 30, 5, 6, true);
});

// 07 THE FALLS -----------------------------------------------------------------------
at(6620, (Ev: Events, E: World, ctx: Ctx): void => {
    // ('the pool': the route tab and 07 THE FALLS have just named it, QA RP-5)
    say(Ev, ctx, "tower", "Signal's thin out here... skim the pool, it'll carry you.", 3.4, 2, "worried");
});
// The skim instruction goes up over the lagoon, before the 07 edge. If the
// slot is busy it still shows after the checkpoint, unless the objective
// has settled by then.
at(6250, (Ev: Events, E: World, ctx: Ctx): void => {
    banner(Ev, "SKIM THE POOL", "RINGS JUST ABOVE THE WATER", "info", 2, level.anchors.fallsS - 150, HUGE, level.sectionAt(6700));
});
at(6780, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.mineField(E, ctx, 6960, 0, 7, 12, false);
    enemies.troopers(E, ctx, 2, 52, 22, 6, true);
});
at(7060, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.hoverDrones(E, ctx, 4, 75, 30, 6, 6, true);
});
at(7240, (Ev: Events, E: World, ctx: Ctx): void => {
    enemies.troopers(E, ctx, 4, 58, 28, 8, true);
});
// (330 m out: typed out before the Baron speaks)
at(A.fallsS - 330, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "vi", "Through the curtain! Hold your breath!", 2.4, 2, "shout");
});

// 08 THE EYE -------------------------------------------------------------------------
// The Watcher rises from the falls pool just before the 08 checkpoint, for the
// same reason as the Stormcrow: staggered alerts and a full-length fight.
// (210 m before it rises: typed out whole (~3.4 s) before UNKNOWN CONTACT)
at(WATCHER_S - 210, (Ev: Events, E: World, ctx: Ctx): void => {
    say(Ev, ctx, "baron", "You want the Eye? Oh, rocket man... it wants YOU.", 3.2, 3, "happy");
});
at(WATCHER_S, (Ev: Events, E: World, ctx: Ctx): void => {
    ctx.sfx("horn", 0.7);
    enemies.bossStart(E, ctx, "eye", WATCHER_END);
    // (up to 1 s for a line's last letters, QA RP-2)
    warn(Ev, "WARNING  UNKNOWN CONTACT", 2.6, 3, null, WATCHER_S, 1.0);
}, 700);

// After the Watcher goes down: waves out of the Eye (seconds after the kill),
// each only if it has flown past before the finale (~5.5 s per wave). 1-based.
const FINALE_WAVES: Array<f64> = [0.0, 0.8, 4.6, 10.5];
const OUTRO_S: f64 = EYE_S - 70; // the core's finale starts here (enemies freeze)

function finaleWave(Ev: Events, ctx: Ctx, n: i32): void {
    let E = Ev.E;
    if (E == null || ctx.state != "playing") {
        return;
    }
    let room = (OUTRO_S - ctx.railS) / lmax(ctx.player.speed, 55);
    if (room < 5.6) {
        return;
    }
    if (LOG) {
        console.log(format("[%5.0f m %6.1f s] finale wave %d (room %.1f s)", [N(ctx.railS), N(ctx.t), N(n), N(room)]));
    }
    // no callouts: the channel is Kessel's kill reaction, then the tower's
    // ENTER THE EYE (a callout would reach the core queue seconds late)
    if (n == 1) {
        enemies.squadron(E, ctx, "biplane", "headon", 5, "v", 1, so(1.8, 3));
    } else if (n == 2) {
        enemies.squadron(E, ctx, "drone", "dive", 5, "line", 1, so(2.2));
    } else {
        enemies.squadron(E, ctx, "biplane", "loop", 3, "column", -1, so(2.0, NaN, 4));
    }
}

// Update ---------------------------------------------------------------------------------

function showroom(Ev: Events, E: World, ctx: Ctx): void {
    if (Ev.fired.has(-1)) {
        return;
    }
    Ev.fired.add(-1);
    const kinds: Array<string> = ["", "biplane", "drone", "trooper", "mine", "kamikaze"];
    for (let i = 1; i < kinds.length; i++) {
        enemies.pose(E, ctx, kinds[i], 19, <f64>(i - 3) * 6.2, 9.5, 0.7, <f64>i * 1.3);
    }
    enemies.turret(E, ctx, ctx.railS + 40, 12, 7, 99);
    enemies.turret(E, ctx, ctx.railS + 55, -14, 10, 99);
}

// the storm's rail frame (the core's ctx.railFrame is track.frame)
function stormFrame(s: f64): void {
    track.frame(level.track, s);
}

export function update(Ev: Events, E: World, ctx: Ctx): void {
    Ev.E = E;
    hook(Ev, ctx);
    if (ctx.state != "playing" && ctx.state != "launch") {
        drainBossComms(Ev, E, ctx);
        return;
    }
    if (SHOWROOM) {
        showroom(Ev, E, ctx);
        return;
    }
    // the Stormcrow's storm (fx), placed before she updates
    fx.stormUpdate(E.fx, stormFrame, E.far, ctx.dt);
    let s = ctx.railS;
    for (let i = 1; i < CUES.length; i++) {
        let c = CUES[i];
        if (!Ev.fired.has(i) && s >= c.s) {
            Ev.fired.add(i);
            if (s < c.s + c.w) {
                if (LOG) {
                    console.log(format("[%5.0f m %6.1f s] cue %d @%d  kills %d/%d", [N(s), N(ctx.t), N(i), N(c.s), N(ctx.stats.kills), N(ctx.stats.killsTotal)]));
                }
                c.run(Ev, E, ctx);
            }
        }
    }

    // boss outcomes drive the portal and finale beats (reactions to a kill
    // wait for the final blast)
    bossComms(Ev, E, ctx);
    pumpFollow(Ev, ctx);
    for (let k = Ev.leads.length - 1; k >= 1; k--) {
        if (s >= Ev.leads[k].latest) {
            runLead(Ev, k);
        }
    }
    let cr = enemies.bossResult(E, "stormcrow");
    if (cr != Ev.crow && cr != "none") {
        Ev.crow = cr;
        if (LOG) {
            console.log(format("[%5.0f m %6.1f s] stormcrow %s", [N(s), N(ctx.t), S(cr)]));
        }
        if (cr == "killed") {
            // after the Baron's 'My beautiful ship!': HANK's cheer (only its
            // 'Yeehaw!' meets the final fireball, so the rest names the kill;
            // only with room for it and the tower before HANK's portal call
            // must start to be read whole before the portal, PORTAL_S - 420
            // flat out; with less room only its 'Yeehaw!' (2.1 s): QA PT3-5),
            // then the tower
            follow(Ev, "hank", "Yeehaw! Scratch one airship!", 2.4, 3, "happy", 7, false, PORTAL_S - 420, 7.75, false, "Yeehaw!", 6.9);
            follow(Ev, "tower", "Portal's open! Dive in, Corsair - we'll keep the kettle on.", 3.4, 3, "happy", 10, true);
        }
        // (an escape: the Baron's 'Ta-ta' only; it ends ~140 m before the
        // portal, too late for any portal line read flat out)
    }
    // DIVE IN once the airship is out of the picture (right after STORMCROW
    // DOWN; never while it is up, never after an escape)
    if (!Ev.portalCued && s > PORTAL_S - 700 && s < PORTAL_S - 70 && E.boss == null && Ev.crow != "escaped") {
        Ev.portalCued = true;
        banner(Ev, "SKY PORTAL", "DIVE IN", "info", 3, PORTAL_S - 70);
    }
    let er = enemies.bossResult(E, "eye");
    if (er != Ev.eye && er != "none") {
        Ev.eye = er;
        if (LOG) {
            console.log(format("[%5.0f m %6.1f s] watcher %s", [N(s), N(ctx.t), S(er)]));
        }
        if (er == "killed" || er == "escaped") {
            Ev.eyeOpen = true;
            let killed = er == "killed";
            if (killed) {
                // after the Baron's line: the tower, then VI, each only if
                // over by the finale (HANK's closing call first when it
                // would not fit after them)
                follow(Ev, "tower", "The Eye is open. Take us home, Corsair!", 3.2, 3, "happy", 10, false, OUTRO_S, 3.5, true);
                follow(Ev, "vi", "Last one through buys the milkshakes!", 2.6, 2, "happy", 12, false, OUTRO_S, 3.4, true);
            }
            // (an escape: the Baron called the retreat before it; HANK's
            // closing call goes out as it gives up, nothing else fits; its
            // ESCAPED slab says FOLLOW IT INTO THE EYE, so no ENTER THE EYE)
            if (killed) {
                let tm = new Timer();
                tm.at = ctx.t + 4.0;
                tm.wave = 0;
                Ev.timers.push(tm);
                // Kessel's last squadrons pour out of the Eye while it opens
                for (let n = 1; n < FINALE_WAVES.length; n++) {
                    let tw = new Timer();
                    tw.at = ctx.t + FINALE_WAVES[n];
                    tw.wave = n;
                    Ev.timers.push(tw);
                }
            }
        }
    }
    // no Watcher on the field (a debug start past it): open the Eye anyway
    if (!Ev.eyeOpen && s > EYE_S - 150 && s < LEN && E.boss == null) {
        Ev.eyeOpen = true;
        banner(Ev, "ENTER THE EYE", "FULL THROTTLE", "info", 2, EYE_S - 90, 8);
    }
    let tm = Ev.timers;
    let k = 1;
    while (k < tm.length) {
        let tmr = tm[k];
        if (ctx.t >= tmr.at) {
            tm.splice(k, 1);
            if (tmr.wave == 0) {
                banner(Ev, "ENTER THE EYE", "FULL THROTTLE", "info", 2, EYE_S - 90, 8);
            } else {
                finaleWave(Ev, ctx, tmr.wave);
            }
        } else {
            k += 1;
        }
    }
    if (LOG && Math.floor(ctx.t) != Math.floor(ctx.t - ctx.dt)) {
        let alive = 0;
        for (let i = 1; i < E.list.length; i++) {
            let e = E.list[i];
            if (e.alive && !e.hidden && !e.part) {
                alive += 1;
            }
        }
        let b = E.boss;
        // (Luau appends enemies.DBG's name=value pairs: not ported)
        console.log(format("TEL s=%.0f t=%.0f v=%.0f alive=%d boss=%s ph=%s shield=%.2f", [N(s), N(ctx.t), N(ctx.player.speed), N(alive),
            S(b != null ? b.kind : "-"), S(b != null ? format("%g", [N(b.phase)]) : "-"), N(ctx.player.shield)]));
    }
    pumpAlerts(Ev, E, ctx);
}
