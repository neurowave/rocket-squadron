// Port of src/game/scoring.luau. Score, combo chains, ring chains, route
// objectives (done / failed per section), mission timer, hit ratio, rank and
// the session best score.
//
// Port: `new` -> create. statuses / details / objectives are 1-based (slot 0
// a hole). mission -> MISSION_1 (done) / MISSION_2 (total). TIPS /
// ROCK_LINES are Map<string, string>. bossShot / hitCause take the enemies
// world (ai_types.World) and the hull boxes (Map<string, Array<f64>>, each a
// 1-based list of 6).
import { Vector } from "rive/vector";
import { format, FormatArg } from "rive/format";
import * as mathx from "../lib/mathx";
import { lmin, lmax, mod, lstr } from "../lib/compat";
import * as level from "../world/level";
import { Ctx, Stats } from "./types";
import * as playerMod from "./player";
import { Player } from "./player";
import * as ai from "./ai_types";

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}
@inline function S_(v: string): FormatArg {
    return FormatArg.string(v);
}

export const COMBO_WINDOW: f64 = 2.0;

// Session best (module state lives as long as the file is loaded).
let sessionBest: f64 = 0;

export class Objective {
    kind: string = ""; // 'clear' | 'arch' | 'low' | 'nohit' | 'boss' | 'skim' | 'finish'
    result: string = ""; // '' | 'done' | 'failed'
    progress: f64 = 0;
    t: f64 = 0; // seconds accumulated (low / skim)
    kills0: f64 = 0;
    total0: f64 = 0;
    bossSeen: bool = false;
    bossHealth: f64 = 1;
    bossDown: bool = false;
    hits: f64 = 0;
    grace: f64 = 0; // 'clear': seconds left to finish the stragglers past the edge (0 = none)
    totEdge: f64 = 0; // 'clear': spawns counted at the edge
    skipped: bool = false; // a debug start began past it (reads done on the route, never counts)

    // (table.clone)
    clone(): Objective {
        let c = new Objective();
        c.kind = this.kind;
        c.result = this.result;
        c.progress = this.progress;
        c.t = this.t;
        c.kills0 = this.kills0;
        c.total0 = this.total0;
        c.bossSeen = this.bossSeen;
        c.bossHealth = this.bossHealth;
        c.bossDown = this.bossDown;
        c.hits = this.hits;
        c.grace = this.grace;
        c.totEdge = this.totEdge;
        c.skipped = this.skipped;
        return c;
    }
}

export class Scoring {
    score: f64 = 0;
    combo: f64 = 0;
    comboT: f64 = 0;
    comboBest: f64 = 0;
    comboPulse: bool = false;
    ringChain: f64 = 0;
    ringCount: f64 = 0;
    ringsTotal: f64 = <f64>(level.rings.length - 1);
    ringsMissed: f64 = 0;
    lastKills: f64 = 0;
    killPulse: bool = false;
    time: f64 = 0;
    timeText: string = "00:00.00";
    timeCs: f64 = -1; // last formatted centisecond (to avoid reformatting)
    sectionIdx: i32 = 1;
    statuses: Array<string> = [""]; // 1-based
    details: Array<string> = [""]; // 1-based
    objectives: Array<Objective> = new Array<Objective>(1); // 1-based
    best: f64 = sessionBest;
    newBest: bool = false;
    rank: string = "C";
    hitRatio: f64 = 0;
    deflects: f64 = 0;
    detailM: f64 = -1; // last formatted distance-to-go (route detail)
    lastChain: f64 = 0; // links in the chain that just paid out
    retries: f64 = 0; // checkpoint retries this run (the rank tops out at A)
}

// A checkpoint's tally (RETRY picks the run up from it).
export class Snap {
    score: f64 = 0;
    ringChain: f64 = 0;
    ringCount: f64 = 0;
    ringsMissed: f64 = 0;
    time: f64 = 0;
    sectionIdx: i32 = 1;
    statuses: Array<string> = [""]; // 1-based
    objectives: Array<Objective> = new Array<Objective>(1); // 1-based
    hitRatio: f64 = 0;
    deflects: f64 = 0;
    retries: f64 = 0;
}

function kindByLabel(label: string): string {
    if (label == "LIGHTHOUSE") return "clear";
    if (label == "SEA ARCH") return "arch";
    if (label == "LOW PASS") return "low";
    if (label == "CLIFF TURN") return "nohit";
    if (label == "SKY PORTAL") return "boss";
    if (label == "VIOLET REACH") return "clear";
    if (label == "THE FALLS") return "skim";
    if (label == "THE EYE") return "finish";
    return "";
}
const KIND_BY_INDEX: StaticArray<string> = ["", "clear", "arch", "low", "nohit", "boss", "clear", "skim", "finish"]; // 1-based

export const LOW_TIME: f64 = 8;
export const SKIM_TIME: f64 = 5;
export const CLEAR_FRAC: f64 = 0.5; // 'clear': share of the section's planes to down
export const CLEAR_GRACE: f64 = 3; // seconds past the edge the last stragglers still count
export const NOHIT_FREE: f64 = 1; // 'nohit': wall scrapes forgiven
export const CHAIN_CAP: f64 = 20; // chain payout: min(links, cap)^2 * 25

export function create(): Scoring {
    let S = new Scoring();
    S.best = sessionBest;
    return S;
}

// (Luau S.objectives[i] / S.statuses[i]: nil past the end)
function obj(S: Scoring, i: i32): Objective? {
    return i >= 1 && i < S.objectives.length ? S.objectives[i] : null;
}
function status(S: Scoring, i: i32): string {
    return i >= 1 && i < S.statuses.length ? S.statuses[i] : "";
}
function setStatus(S: Scoring, i: i32, v: string): void {
    while (S.statuses.length <= i) S.statuses.push("");
    S.statuses[i] = v;
}

export function reset(S: Scoring, stats: Stats): void {
    S.score = 0;
    S.combo = 0;
    S.comboT = 0;
    S.comboBest = 0;
    S.ringChain = 0;
    S.ringCount = 0;
    S.ringsMissed = 0;
    S.ringsTotal = <f64>(level.rings.length - 1);
    S.lastKills = stats.kills;
    S.time = 0;
    S.timeCs = -1;
    S.timeText = "00:00.00";
    S.sectionIdx = 1;
    S.newBest = false;
    S.rank = "C";
    S.hitRatio = 0;
    S.deflects = 0;
    S.detailM = -1;
    S.retries = 0;
    S.statuses.length = 1;
    S.details.length = 1;
    S.objectives.length = 1;
    let secs = level.sections;
    for (let i = 1; i < secs.length; i++) {
        let sec = secs[i];
        S.statuses.push(i == 1 ? "current" : "pending");
        S.details.push("");
        let o = new Objective();
        let k = kindByLabel(sec.label);
        o.kind = k != "" ? k : i < KIND_BY_INDEX.length ? KIND_BY_INDEX[i] : "finish";
        o.kills0 = stats.kills;
        o.total0 = stats.killsTotal;
        S.objectives.push(o);
    }
}

// Debug starts deep in the level: sections before s count as skipped (done,
// no bonus) so the route list reads cleanly.
export function startAt(S: Scoring, s: f64): void {
    let idx = level.sectionAt(s);
    for (let i = 1; i <= idx - 1; i++) {
        setStatus(S, i, "done");
        let o = obj(S, i);
        if (o != null) {
            o.result = "done";
            o.progress = 1;
            o.skipped = true;
        }
    }
    S.sectionIdx = idx;
    setStatus(S, idx, "current");
}

export function formatTime(t: f64): string {
    let cs = Math.floor(t * 100);
    let m = Math.floor(cs / 6000);
    let s = mod(Math.floor(cs / 100), 60);
    return format("%02d:%02d.%02d", [N(m), N(s), N(mod(cs, 100))]);
}

// Multiplier from the current chain (x1 .. x2).
export function comboMult(S: Scoring): f64 {
    return 1 + lmin(S.combo, 10) * 0.1;
}

// Points from the world (kills, set pieces). Returns the awarded amount.
export function add(S: Scoring, p: Player, points: f64): f64 {
    let pts = Math.floor(points * p.skim * comboMult(S) + 0.5);
    S.score += pts;
    return pts;
}

export function ring(S: Scoring, p: Player, kind: string): f64 {
    S.ringCount += 1;
    S.ringChain += 1;
    let base = kind == "silver" ? 250.0 : kind == "boost" ? 150.0 : 100.0;
    let pts = Math.floor(base * lmin(S.ringChain, 8) * p.skim + 0.5);
    S.score += pts;
    S.comboT = COMBO_WINDOW;
    S.combo += 1;
    S.comboPulse = true;
    return pts;
}

// A close call past the scenery: points (skim + combo multiplied) and a chain link.
export function closeCall(S: Scoring, p: Player): f64 {
    let pts = Math.floor(150 * p.skim * comboMult(S) + 0.5);
    S.score += pts;
    S.combo += 1;
    S.comboT = COMBO_WINDOW;
    S.comboPulse = true;
    return pts;
}

export function ringMissed(S: Scoring): void {
    S.ringsMissed += 1;
    S.ringChain = 0;
}

export function wallHit(S: Scoring): void {
    let o = obj(S, S.sectionIdx);
    if (o != null) {
        o.hits += 1;
    }
}

// Boss HUD reports (from ctx.boss).
export function boss(S: Scoring, active: bool, health: f64): void {
    let o = obj(S, S.sectionIdx);
    for (let i = 1; i < S.objectives.length; i++) {
        let ob = S.objectives[i];
        if (ob.kind == "boss") {
            o = ob;
            break;
        }
    }
    if (o == null) {
        return;
    }
    if (active) {
        o.bossSeen = true;
        o.bossHealth = health;
        if (health <= 0) {
            o.bossDown = true;
        }
    } else if (o.bossSeen && health <= 0.001) {
        o.bossDown = true;
    }
}

function resolve(S: Scoring, i: i32, result: string, ctx: Ctx): void {
    let o = obj(S, i);
    if (o == null || o.result != "") {
        return;
    }
    o.result = result;
    setStatus(S, i, result);
    let sec = level.sections[i];
    if (result == "done") {
        o.progress = 1;
        let bonus = 1000.0;
        S.score += bonus;
        ctx.banner("OBJECTIVE COMPLETE", sec.label + "  +" + lstr(bonus), "success");
        ctx.sfx("checkpoint", 0.8);
        let pp = ctx.player.pos;
        let f = ctx.player.fwd;
        ctx.popup("+" + lstr(bonus), "bonus", <f64>pp.x + <f64>f.x * 55, <f64>pp.y + 4, <f64>pp.z + <f64>f.z * 55);
    } else {
        ctx.banner("OBJECTIVE FAILED", sec.label, "warning");
    }
}

// Per-frame bookkeeping while flying. Returns the chain bonus awarded when a
// combo of 3+ ends (0 otherwise).
export function update(S: Scoring, p: Player, ctx: Ctx, dt: f64): f64 {
    // the mission clock runs on the course only (the flight school's cut
    // lands at s -340)
    if (!p.frozen && p.s >= 0) {
        S.time += dt;
    }
    let cs = Math.floor(S.time * 100);
    if (cs != S.timeCs) {
        S.timeCs = cs;
        S.timeText = formatTime(S.time);
    }

    // kills -> combo
    S.killPulse = false;
    S.comboPulse = false;
    let kills = ctx.stats.kills;
    if (kills > S.lastKills) {
        S.combo += kills - S.lastKills;
        S.comboT = COMBO_WINDOW;
        S.killPulse = true;
        S.comboPulse = true;
        S.lastKills = kills;
    } else if (kills < S.lastKills) {
        S.lastKills = kills;
    }
    S.comboBest = lmax(S.comboBest, S.combo);
    let bonus = 0.0;
    if (S.comboT > 0) {
        S.comboT -= dt;
        if (S.comboT <= 0) {
            if (S.combo >= 3) {
                let n = lmin(S.combo, CHAIN_CAP);
                bonus = n * n * 25;
                S.lastChain = S.combo;
                S.score += bonus;
            }
            S.combo = 0;
        }
    }

    let st = ctx.stats;
    S.hitRatio = st.shotsFired > 0 ? lmin(1, st.shotsHit / st.shotsFired) : 0;

    // sections
    let idx = level.sectionAt(p.s);
    let nsec = level.sections.length - 1;
    if (idx != S.sectionIdx) {
        // leaving: settle the objective that was pending
        let prev = S.sectionIdx;
        let o = obj(S, prev);
        if (o != null && o.result == "") {
            let ok = false;
            let pend = false;
            if (o.kind == "clear") {
                let tot = st.killsTotal - o.total0;
                let k = st.kills - o.kills0;
                ok = tot <= 0 || k / tot >= CLEAR_FRAC;
                if (!ok) {
                    // the last planes are still in the crosshair: a short
                    // grace settles it (on the ratio of the spawns so far)
                    o.grace = CLEAR_GRACE;
                    o.totEdge = tot;
                    pend = true;
                }
            } else if (o.kind == "nohit") {
                ok = o.hits <= NOHIT_FREE;
            } else if (o.kind == "boss") {
                ok = o.bossDown || !o.bossSeen;
            } else if (o.kind == "arch") {
                ok = false;
            } else if (o.kind == "finish") {
                ok = true;
            }
            if (!pend) {
                resolve(S, prev, ok ? "done" : "failed", ctx);
            }
        }
        for (let i = prev; i <= idx - 1; i++) {
            let oi = obj(S, i);
            let waiting = oi != null && oi.grace > 0;
            let si = status(S, i);
            if ((si == "current" || si == "pending") && !waiting) {
                setStatus(S, i, "failed");
            }
        }
        S.sectionIdx = idx;
        if (status(S, idx) == "pending") {
            setStatus(S, idx, "current");
        }
        let no = obj(S, idx);
        if (no != null) {
            no.kills0 = st.kills;
            no.total0 = st.killsTotal;
        }
        let sec = level.sections[idx];
        // the objective itself is on the HUD's objective line: the slab says
        // where you are instead
        let km = (lmin(sec.s1, level.track.length) - sec.s0) / 1000;
        ctx.banner(sec.num + "  " + sec.label, format("CHECKPOINT %s/%02d  //  %.1f KM", [S_(sec.num), N(<f64>nsec), N(km)]), "checkpoint");
        ctx.sfx("checkpoint", 0.6);
    }

    // 'clear' objectives settling in their grace past the edge
    for (let i = 1; i < S.objectives.length; i++) {
        let og = S.objectives[i];
        if (og.grace > 0 && og.result == "") {
            og.grace -= dt;
            let k = st.kills - og.kills0;
            if (og.totEdge <= 0 || k / og.totEdge >= CLEAR_FRAC) {
                og.grace = 0;
                resolve(S, i, "done", ctx);
            } else if (og.grace <= 0) {
                og.grace = 0;
                resolve(S, i, "failed", ctx);
            }
        }
    }

    // live objective progress
    let o = obj(S, idx);
    let sec = level.sections[idx];
    if (o != null && o.result == "") {
        let frac = mathx.saturate((p.s - sec.s0) / lmax(1, lmin(sec.s1, level.track.length) - sec.s0));
        if (o.kind == "clear") {
            let tot = st.killsTotal - o.total0;
            o.progress = tot > 0 ? mathx.saturate((st.kills - o.kills0) / tot / CLEAR_FRAC) : frac;
        } else if (o.kind == "low" || o.kind == "skim") {
            if (<f64>p.pos.y < playerMod.SKIM_ALT && p.overWater) {
                o.t += dt;
            }
            let need = o.kind == "low" ? LOW_TIME : SKIM_TIME;
            o.progress = mathx.saturate(o.t / need);
            if (o.t >= need) {
                resolve(S, idx, "done", ctx);
            }
        } else if (o.kind == "nohit") {
            o.progress = frac;
            if (o.hits > NOHIT_FREE) {
                o.progress = 0;
                resolve(S, idx, "failed", ctx);
            }
        } else if (o.kind == "boss") {
            o.progress = o.bossSeen ? 1 - o.bossHealth : 0;
            if (o.bossDown) {
                resolve(S, idx, "done", ctx);
            }
        } else if (o.kind == "arch") {
            o.progress = 0;
        } else if (o.kind == "finish") {
            o.progress = frac;
        }
    }
    for (let i = 1; i <= nsec; i++) {
        let sct = level.sections[i];
        if (i == idx) {
            let m = lmax(0, Math.floor(lmin(sct.s1, level.track.length) - p.s));
            if (m != S.detailM) {
                S.detailM = m;
                while (S.details.length <= i) S.details.push("");
                S.details[i] = format("%d m", [N(m)]);
            }
        } else if (i < S.details.length && S.details[i] != "") {
            S.details[i] = "";
        }
    }
    return bonus;
}

// The finale: the last checkpoint is reached (ticks off in the route list
// under MISSION COMPLETE, no extra banner).
export function completeFinal(S: Scoring): void {
    let n = S.objectives.length - 1;
    let o = obj(S, n);
    if (o != null && o.result == "") {
        o.result = "done";
        o.progress = 1;
        setStatus(S, n, "done");
        S.score += 1000;
    }
}

// The mission objectives the briefing lists: the route's arch, boss and
// finish objectives. Returns done (flown this run: a debug start's skipped
// ones never count; also MISSION_1), total (MISSION_2).
export let MISSION_1: f64 = 0;
export let MISSION_2: f64 = 0;
export function mission(S: Scoring): f64 {
    let done = 0.0, total = 0.0;
    for (let i = 1; i < S.objectives.length; i++) {
        let o = S.objectives[i];
        if (o.kind == "arch" || o.kind == "boss" || o.kind == "finish") {
            total += 1;
            if (o.result == "done" && !o.skipped) {
                done += 1;
            }
        }
    }
    MISSION_1 = done;
    MISSION_2 = total;
    return done;
}

// What downed him (Game.failCause) and one tip for it (Game.failTip, <= 44).
function mkTips(): Map<string, string> {
    let m = new Map<string, string>();
    m.set("SEA STACKS", "WEAVE THE GAPS · RINGS SIT IN OPEN WATER");
    m.set("THE SEA ARCH", "LINE UP EARLY · AIM FOR THE MIDDLE");
    m.set("CANYON WALLS", "KEEP TO THE MIDDLE OF THE CANYON");
    m.set("CANYON PILLARS", "PILLARS MID-CANYON · PICK A SIDE EARLY");
    m.set("CANYON BRIDGES", "ROCK BRIDGES · STAY LOW UNDER THEM");
    m.set("ROCKS", "LOOK AHEAD · STEER BEFORE THE ROCK");
    m.set("ENEMY FIRE", "ROLL AS SHOTS CLOSE IN TO RETURN THEM");
    m.set("ENEMY PLANES", "SHOOT FIRST · OR ROLL THROUGH THEM");
    m.set("KAMIKAZE", "SHOOT KAMIKAZES BEFORE THEY CLOSE IN");
    m.set("MINES", "POP ONE MINE AND THE WHOLE STRING GOES");
    m.set("THE WATCHER'S BEAM", "ROLL THROUGH THE BEAM AS IT SWEEPS");
    m.set("THE WATCHER", "AIM FOR THE PUPIL · ROLL ITS ORBS BACK");
    m.set("STORMCROW", "KNOCK OUT THE ENGINES · ROLL THE FLAK");
    return m;
}
export const TIPS: Map<string, string> = mkTips();
// The tower on the first rock hit of a run, by what he hit.
function mkRockLines(): Map<string, string> {
    let m = new Map<string, string>();
    m.set("SEA STACKS", "Watch the stacks! Stay in the open water.");
    m.set("THE SEA ARCH", "Easy! Line up early and aim for the middle.");
    m.set("CANYON WALLS", "Watch the walls and keep to the middle!");
    m.set("CANYON PILLARS", "Watch the pillars and pick a side early!");
    m.set("CANYON BRIDGES", "Watch the bridges and stay low under them!");
    m.set("ROCKS", "Watch the rocks! Steer early.");
    return m;
}
export const ROCK_LINES: Map<string, string> = mkRockLines();

// How near a contact has to be to a registered rock pillar (level.addSolid)
// to be that pillar, not the canyon wall behind it.
const PILLAR_PAD: f64 = 0.5;

// The rock he hit at rail s; lat / y (NaN: nil): where the contact is, rail
// lateral and world height. In CLIFF TURN a contact on one of the mid-canyon
// pillars is CANYON PILLARS, under a rock bridge CANYON BRIDGES, the rest
// CANYON WALLS.
export function rockCause(s: f64, lat: f64 = NaN, y: f64 = NaN): string {
    let a = level.anchors.arch;
    if (s > a.s0 - 6 && s < a.s1 + 6) {
        return "THE SEA ARCH";
    }
    let si = level.sectionAt(s);
    if (si >= 1 && si < level.sections.length && level.sections[si].label == "CLIFF TURN") {
        if (!isNaN(lat) && !isNaN(y) && level.solidAt(s, lat, y, PILLAR_PAD) > 0) {
            return "CANYON PILLARS";
        }
        // (a head-high contact under a rock bridge's span)
        if (!isNaN(y)) {
            let cl = level.ceilings;
            for (let i = 1; i < cl.length; i++) {
                let ce = cl[i];
                if (Math.abs(s - ce.s) <= ce.half + 2 && y >= ce.h * 0.6) {
                    return "CANYON BRIDGES";
                }
            }
        }
        return "CANYON WALLS";
    }
    if (s >= 700 && s < level.portalS) {
        return "SEA STACKS";
    }
    return "ROCKS";
}

// Which boss fired the shot at (x, y, z) ('stormcrow' / 'eye'), else null:
// her flak and rockets, her cannons' orbs, the Watcher's orbs by colour
// (boss_stormcrow / boss_eye: keep in step), a tracer from inside the boss's
// hull `box` (game HULL_BOX, 1-based x0 x1 y0 y1 z0 z1, +3) where it was then.
export function bossShot(E: ai.World, box: Array<f64>?, x: f64, y: f64, z: f64): string? {
    let B = E.boss;
    let bl = E.bullets;
    for (let i = 1; i < bl.length; i++) {
        let b = bl[i];
        if (b.x == x && b.y == y && b.z == z) {
            if (b.kind >= 2) {
                return "stormcrow";
            } else if (b.kind == 1) {
                if (Math.abs(b.g - 0.45) < 0.01 && b.b < 0.25) {
                    return "stormcrow";
                } else if ((b.g > 0.9 && b.b > 0.9) || (Math.abs(b.g - 0.3) < 0.01 && Math.abs(b.b - 0.75) < 0.01)) {
                    return "eye";
                }
                return null;
            }
            if (box == null || B == null || B.escaped) {
                return null;
            }
            let bx = box!;
            let f = B!.xf, v = B!.v, a = b.age;
            let dx = b.x - b.vx * a - (f.px - v.hvx * a);
            let dy = b.y - b.vy * a - (f.py - v.hvy * a);
            let dz = b.z - b.vz * a - (f.pz - v.hvz * a);
            let k = 1 / lmax(f.s, 0.01);
            let lx = (dx * f.rx + dy * f.ry + dz * f.rz) * k;
            let ly = (dx * f.ux + dy * f.uy + dz * f.uz) * k;
            let lz = -(dx * f.fx + dy * f.fy + dz * f.fz) * k;
            let inside = lx > bx[1] - 3 && lx < bx[2] + 3 && ly > bx[3] - 3 && ly < bx[4] + 3 && lz > bx[5] - 3 && lz < bx[6] + 3;
            return inside ? B!.kind : null;
        }
    }
    return null;
}

// What a ctx.hurtPlayer hit at (x, y, z) was: the Watcher's beam (it hits at
// his centre P), a body that rammed or burst on him, else a shot (a boss's
// own: bossShot). E: the enemies world (null: none), boxes: game HULL_BOX.
export function hitCause(E: ai.World?, P: Vector, boxes: Map<string, Array<f64>>, x: f64, y: f64, z: f64): string {
    if (E == null) {
        return "ENEMY FIRE";
    }
    let W = E!;
    let B = W.boss;
    if (B != null && B.kind == "eye" && B.v.beamState == 2 && x == <f64>P.x && y == <f64>P.y && z == <f64>P.z) {
        return "THE WATCHER'S BEAM";
    }
    let bossName: string? = B == null || B.escaped ? null : B.kind == "eye" ? "THE WATCHER" : "STORMCROW";
    let list = W.list;
    for (let i = 1; i < list.length; i++) {
        let e = list[i];
        if (e.x == x && e.y == y && e.z == z) {
            if (e.kind == "kamikaze") {
                return "KAMIKAZE";
            } else if (e.kind == "mine") {
                return "MINES";
            } else if (e.part && bossName != null) {
                return bossName!;
            }
            return "ENEMY PLANES";
        }
    }
    let box: Array<f64>? = null;
    if (B != null && boxes.has(B.kind)) {
        box = boxes.get(B.kind);
    }
    let k = bossShot(W, box, x, y, z);
    return k == "eye" ? "THE WATCHER" : k != null ? "STORMCROW" : "ENEMY FIRE";
}

// Arch window check result for the SEA ARCH objective.
export function archPassed(S: Scoring, ok: bool, ctx: Ctx): void {
    for (let i = 1; i < S.objectives.length; i++) {
        let o = S.objectives[i];
        if (o.kind == "arch" && o.result == "") {
            resolve(S, i, ok ? "done" : "failed", ctx);
            return;
        }
    }
}

// The tally as it stands (a checkpoint).
export function snapshot(S: Scoring): Snap {
    let n = new Snap();
    for (let i = 1; i < S.objectives.length; i++) {
        n.objectives.push(S.objectives[i].clone());
    }
    n.score = S.score;
    n.ringChain = S.ringChain;
    n.ringCount = S.ringCount;
    n.ringsMissed = S.ringsMissed;
    n.time = S.time;
    n.sectionIdx = S.sectionIdx;
    n.statuses = S.statuses.slice(0);
    n.hitRatio = S.hitRatio;
    n.deflects = S.deflects;
    n.retries = S.retries;
    return n;
}

// RETRY from a checkpoint: its tally back (after reset), one retry more.
// What the failed stretch scored counts for nothing; the combo starts over.
export function restore(S: Scoring, n: Snap, stats: Stats): void {
    S.score = n.score;
    S.ringChain = n.ringChain;
    S.ringCount = n.ringCount;
    S.ringsMissed = n.ringsMissed;
    S.time = n.time;
    S.timeCs = -1;
    S.timeText = formatTime(n.time);
    S.sectionIdx = n.sectionIdx;
    S.hitRatio = n.hitRatio;
    S.deflects = n.deflects;
    S.retries = n.retries + 1;
    S.lastKills = stats.kills;
    for (let i = 1; i < n.statuses.length; i++) {
        setStatus(S, i, n.statuses[i]);
    }
    for (let i = 1; i < n.objectives.length; i++) {
        let c = n.objectives[i].clone();
        while (S.objectives.length <= i) S.objectives.push(c);
        S.objectives[i] = c;
        if (c.grace > 0 && c.result == "") {
            // a CLEAR THE SKIES left settling past the edge: no straggler is
            // left to down, so it settles now
            let ok = c.totEdge <= 0 || (stats.kills - c.kills0) / c.totEdge >= CLEAR_FRAC;
            c.grace = 0;
            c.result = ok ? "done" : "failed";
            c.progress = ok ? 1.0 : c.progress;
            setStatus(S, i, c.result);
            if (ok) {
                S.score += 1000;
            }
        }
    }
}

// Settle everything at the end of the run and compute the rank. (ctx: unused,
// as in Luau)
export function finish(S: Scoring, p: Player, stats: Stats, completed: bool, ctx: Ctx? = null): void {
    if (completed) {
        for (let i = 1; i < S.objectives.length; i++) {
            let o = S.objectives[i];
            if (o.result == "") {
                o.result = o.kind == "finish" || o.kind == "clear" || (o.kind == "boss" && !o.bossSeen) || o.kind == "nohit" ? "done" : "failed";
                setStatus(S, i, o.result);
            }
        }
        // clear bonus: shield left + chain
        S.score += Math.floor(p.shield * 2000);
    }
    let killsTotal = lmax(stats.killsTotal, stats.kills);
    let killsPct = killsTotal > 0 ? stats.kills / killsTotal : 1.0;
    let ringsPct = S.ringsTotal > 0 ? S.ringCount / S.ringsTotal : 1.0;
    // the mission objectives, as the results OBJECTIVES row counts them
    let done = mission(S);
    let total = MISSION_2;
    let objPct = done / lmax(1, total);
    let hit = S.hitRatio;
    let v = killsPct * 0.3 + ringsPct * 0.25 + objPct * 0.25 + hit * 0.1 + p.shield * 0.1;
    if (!completed) {
        S.rank = "C";
    } else if (v >= 0.82 && S.retries == 0) {
        S.rank = "S";
    } else if (v >= 0.66) {
        S.rank = "A";
    } else if (v >= 0.48) {
        S.rank = "B";
    } else {
        S.rank = "C";
    }
    // a best only counts against an earlier run of this session
    S.newBest = sessionBest > 0 && S.score > sessionBest;
    if (S.score > sessionBest) {
        sessionBest = S.score;
    }
    S.best = sessionBest;
}
