// Port of src/game/core_hud.luau. Keeps every Hud, Pilot and Game view model property the game owns live.
// Numbers are quantized and strings re-formatted only when their value changes, so the per-frame sync allocates
// next to nothing.
//
// Port: Cache = Map<string, f64> (a missing key is Luau nil). bossPoint's project callback is a Projector
// (the core implements it); its multi-return lands in BOSS_POINT_1..3.
import { format, FormatArg } from "rive/format";
import * as mathx from "../lib/mathx";
import * as level from "../world/level";
import * as vmx from "./vm";
import { Bag } from "./vm";
import * as playerMod from "./player";
import { Player } from "./player";
import * as scoring from "./scoring";
import { Scoring, Objective } from "./scoring";
import { Weapons } from "./weapons";
import { Enemy, World } from "./ai_types";
import { Stats } from "./types";
import { HUGE, lmin, lmax, lclamp, lsub, lfind } from "../lib/compat";

function N(v: f64): FormatArg {
    return FormatArg.number(v);
}

// last integer keys for formatted strings
export type Cache = Map<string, f64>;

export function newCache(): Cache {
    return new Map<string, f64>();
}

// c[name] or d
@inline function cor(c: Cache, name: string, d: f64): f64 {
    return c.has(name) ? c.get(name) : d;
}
// c[name] ~= v
@inline function cne(c: Cache, name: string, v: f64): bool {
    return !(c.has(name) && c.get(name) == v);
}

// the shield at the last HUD sync, for the results SHIELD row (syncResults has no player)
let shieldLast: f64 = 0;

function fmt(h: Bag, c: Cache, name: string, key: f64, pattern: string, v: f64): void {
    if (cne(c, name, key)) {
        c.set(name, key);
        vmx.str(h, name, format(pattern, [N(v)]));
    }
}

// Rail stretches with rock in the flight lane (scenery.luau: the stack field and arch slalom, the LOW PASS fangs
// and the CLIFF TURN slot, the lagoon and falls pool rocks): a checkpoint or result there only ticks the route tab
// (Hud.routeQuiet), the list stays folded. Pairs (s0, s1).
const HAZARD: StaticArray<f64> = [720, 1620, 1880, level.anchors.canyonS1, level.anchors.diveS1 - 20, 7540];
const HIT_QUIET: f64 = 3; // seconds after a scenery touch
const SHIELD_QUIET: f64 = 0.25;

function quiet(p: Player): bool {
    if (p.hitT < HIT_QUIET || p.shield <= SHIELD_QUIET) return true;
    for (let i = 0; i < HAZARD.length; i += 2) {
        if (p.s >= HAZARD[i] && p.s < HAZARD[i + 1]) return true;
    }
    return false;
}

// A skim objective names the line it is judged on (player.SKIM_ALT), whatever the level text rounds it to
// ('STAY UNDER 3 M' -> 'STAY UNDER 3.2 M').
const SKIM_LINE: string = format("%g M", [N(playerMod.SKIM_ALT)]);

// string.gsub(s, '[%d%.]+ M$', SKIM_LINE)
function skimLine(s: string): string {
    let n = s.length;
    if (n < 3 || s.charCodeAt(n - 1) != 77 || s.charCodeAt(n - 2) != 32) return s;
    let i = n - 2;
    while (i > 0) {
        let ch = s.charCodeAt(i - 1);
        if ((ch >= 48 && ch <= 57) || ch == 46) i--;
        else break;
    }
    if (i == n - 2) return s;
    return s.substring(0, i) + SKIM_LINE;
}

function objectiveText(sec: level.Section, o: Objective?): string {
    if (o != null && o.kind == "low") return skimLine(sec.objective);
    return sec.objective;
}

// The phase call's order in short (Hud.bossPhaseShort): the HUD shows it instead of the call's bare head where the
// whole call cannot fit (a 390 pt phone fits ~30 letters, 'BROADSIDE  //  TAKE OUT THE CANNONS' is 35, and
// 'BROADSIDE' alone gave no order; QA PT3-4). A call headed by a name gets its order, any other keeps its head
// (boss_stormcrow / boss_eye banners).
function phaseShortMap(): Map<string, string> {
    let m = new Map<string, string>();
    m.set("ENGINES", "KNOCK OUT THE ENGINES");
    m.set("BROADSIDE", "TAKE OUT THE CANNONS");
    m.set("CORE EXPOSED", "FIRE AT THE CORE");
    m.set("LENSES", "SHOOT THE LENSES");
    m.set("ROLL!", "ROLL THROUGH THE BEAM");
    return m;
}
const PHASE_SHORT: Map<string, string> = phaseShortMap();

// Lua %s+$
function trimEnd(s: string): string {
    let n = s.length;
    while (n > 0) {
        let ch = s.charCodeAt(n - 1);
        if (ch == 32 || (ch >= 9 && ch <= 13)) n--;
        else break;
    }
    return s.substring(0, n);
}

function phaseShort(h: Bag): void {
    let call = h.lastS.has("bossPhase") ? h.lastS.get("bossPhase") : "";
    let i = lfind(call, "//", 1);
    let head = i > 0 ? trimEnd(lsub(call, 1, i - 1)) : call;
    vmx.optSetStr(h, "bossPhaseShort", PHASE_SHORT.has(head) ? PHASE_SHORT.get(head) : head);
}

// The rock hint (Hud.hintText, faded by Hud.hintK): a rock hit of a kind not yet hinted this life, with the
// tower's rock line not on air HINT_WAIT s on (the radio busy: that line waits behind the scripted calls and is
// dropped at the end of its stretch, heard for 5 of 12 first hits; QA PT3-3), shows its advice over the objective
// chip for HINT_SECS. Seconds of the mission clock (scoring S.time: game time, held through cards and pauses). One
// kind each: a pillar hit after a stack hit still gets its own. While the chip cannot be seen (a boss fight hides
// the objective column, a banner covers it) the hint waits up to HINT_LATE (a checkpoint banner holds 3.4 s), else
// that kind stays unhinted.
function hintMap(): Map<string, string> {
    let m = new Map<string, string>();
    m.set("SEA STACKS", "ROCKS  ·  WEAVE THE GAPS");
    m.set("CANYON PILLARS", "PILLARS  ·  PICK A SIDE EARLY");
    m.set("CANYON WALLS", "WALLS  ·  KEEP TO THE MIDDLE");
    m.set("CANYON BRIDGES", "BRIDGES  ·  STAY LOW");
    m.set("THE SEA ARCH", "ARCH  ·  LINE UP EARLY");
    m.set("ROCKS", "ROCKS  ·  STEER EARLY");
    return m;
}
const HINT: Map<string, string> = hintMap();
const HINT_KINDS: Array<string> = ["", "SEA STACKS", "CANYON PILLARS", "CANYON WALLS", "CANYON BRIDGES", "THE SEA ARCH", "ROCKS"]; // 1-based
const HINT_WAIT: f64 = 0.3;
const HINT_LATE: f64 = 4;
const HINT_SECS: f64 = 3.2;
const HINT_IN: f64 = 0.2;
const HINT_OUT: f64 = 0.4;

// The tower's first-rock line is on air (`on`: the text on the channel, whole or cut to its leading sentences: a
// rock line starts with it).
function rockLine(on: string): bool {
    if (on == "") return false;
    let ts = scoring.ROCK_LINES.values();
    for (let i = 0; i < ts.length; i++) {
        if (lsub(ts[i], 1, on.length) == on) return true;
    }
    return false;
}

// The objective column (the chip's owner) is hidden: a boss fight, or the alert slot's banner over it (Hud alertK
// x bannerK, written by the HUD).
function hintHidden(h: Bag): bool {
    if (h.lastB.has("bossActive") && h.lastB.get("bossActive")) return true;
    let a = vmx.optNum(h, "alertK"), b = vmx.optNum(h, "bannerK");
    return (isNaN(a) ? 0 : a) * (isNaN(b) ? 0 : b) > 0.5;
}

function hint(h: Bag, c: Cache, p: Player, S: Scoring, live: bool): void {
    let now = S.time;
    let hits = p.wallHits;
    let last = cor(c, "hintHits", hits);
    if (hits < last) {
        // (a new life / run: resetRun gives the pilot a fresh hit count)
        c.set("hintMask", 0);
        c.set("hintPend", 0);
        c.set("hintIdx", 0);
        last = hits;
    }
    if (live && hits > last) {
        // (the contact's own place is the core's; the pilot's centre is close enough here, and the canyon walls
        // are out of reach in flight: a contact this near the middle is a pillar)
        let cause = scoring.rockCause(p.s, p.x, <f64>p.pos.y);
        if (cause == "CANYON WALLS" && Math.abs(p.x) < 10) cause = "CANYON PILLARS";
        let k = HINT_KINDS.indexOf(cause);
        if (k < 1) k = HINT_KINDS.length - 1;
        let bit = 1 << (k - 1);
        let mask = <i32>cor(c, "hintMask", 0);
        if ((mask & bit) == 0) {
            c.set("hintMask", <f64>(mask | bit));
            c.set("hintPend", <f64>k);
            c.set("hintPendT", now);
        }
    }
    c.set("hintHits", hits);
    let pend = cor(c, "hintPend", 0);
    if (pend > 0) {
        let age = now - cor(c, "hintPendT", now);
        let on = h.lastS.has("commText") ? h.lastS.get("commText") : "";
        let said = h.lastB.has("commActive") && h.lastB.get("commActive") && rockLine(on);
        if (age >= HINT_WAIT && said) {
            c.set("hintPend", 0);
        } else if (age >= HINT_WAIT && !hintHidden(h)) {
            c.set("hintIdx", pend);
            c.set("hintT0", now);
            vmx.optSetStr(h, "hintText", HINT.get(HINT_KINDS[<i32>pend]));
            c.set("hintPend", 0);
        } else if (age >= HINT_LATE || !live) {
            // (never seen: the next hit of this kind may hint it)
            c.set("hintMask", <f64>(<i32>cor(c, "hintMask", 0) & ~(1 << (<i32>pend - 1))));
            c.set("hintPend", 0);
        }
    }
    let k = 0.0;
    let idx = cor(c, "hintIdx", 0);
    if (idx > 0) {
        let t = now - cor(c, "hintT0", now);
        if (t >= HINT_SECS || !live) {
            c.set("hintIdx", 0);
        } else {
            k = lclamp(lmin(t / HINT_IN, (HINT_SECS - t) / HINT_OUT), 0, 1);
        }
    }
    vmx.optSetNum(h, "hintK", Math.floor(k * 50 + 0.5) / 50);
}

// school: the flight school runs (no objective on the chip; the route and objective are written anew after it).
// (Luau `school: boolean?`, tested `if school`: false)
export function syncHud(h: Bag, c: Cache, p: Player, S: Scoring, W: Weapons, online: bool, school: bool = false): void {
    let shield = Math.floor(p.shield * 100 + 0.5) / 100;
    shieldLast = p.shield;
    vmx.num(h, "shield", shield);
    vmx.num(h, "shieldPips", lmax(0, Math.ceil(p.shield * 4 - 0.001)));
    let boost = Math.floor(p.boost + 0.5);
    vmx.num(h, "boost", boost);
    fmt(h, c, "boostText", boost, "%d%%", boost);
    let heat = Math.floor(p.heat + 0.5);
    vmx.num(h, "heat", heat);
    fmt(h, c, "heatText", heat, "%d%%", heat);
    vmx.bool(h, "overheat", p.overheat > 0);
    // truncated, so ALT reads under the skim line exactly while it counts
    let py = <f64>p.pos.y;
    let alt = Math.floor(lmax(0, py) * 10) / 10;
    vmx.num(h, "alt", alt);
    vmx.bool(h, "skimLine", py < playerMod.SKIM_ALT && p.overWater && p.alive);
    // three digits drop the decimal so the gauge never overflows
    if (alt >= 100) {
        fmt(h, c, "altText", -Math.floor(alt), "%d m", Math.floor(alt));
    } else {
        fmt(h, c, "altText", alt * 10, "%.1f m", alt);
    }
    let kmh = Math.floor(p.speed * 3.6 + 0.5);
    vmx.num(h, "speed", kmh);
    fmt(h, c, "speedText", kmh, "%d", kmh);
    vmx.num(h, "skim", p.skim);
    vmx.bool(h, "skimActive", p.skim > 1);
    fmt(h, c, "skimText", p.skim, "SKIM x%d", p.skim);
    vmx.num(h, "score", S.score);
    fmt(h, c, "scoreText", S.score, "%07d", S.score);
    vmx.num(h, "rings", S.ringCount);
    fmt(h, c, "ringsText", S.ringCount, "%02d", S.ringCount);
    vmx.num(h, "combo", S.combo);
    if (cne(c, "comboText", S.combo)) {
        c.set("comboText", S.combo);
        vmx.str(h, "comboText", S.combo >= 2 ? format("x%d CHAIN", [N(S.combo)]) : "");
    }
    vmx.bool(h, "boosting", p.boosting);
    vmx.bool(h, "braking", p.braking);
    vmx.num(h, "charge", Math.floor(W.charge * 50 + 0.5) / 50);
    vmx.num(h, "lockCount", W.lockCount);
    vmx.bool(h, "online", online);

    let idx = <f64>S.sectionIdx;
    let secs = level.sections;
    let nsec = <f64>(secs.length - 1);
    vmx.num(h, "routeIndex", idx);
    if (school) {
        if (cne(c, "schoolObj", 1)) {
            c.set("schoolObj", 1);
            c.set("routeText", -1);
            vmx.str(h, "objectiveText", "");
        }
    } else if (cne(c, "routeText", idx)) {
        c.set("schoolObj", 0);
        c.set("routeText", idx);
        vmx.str(h, "routeText", format("ROUTE %02d/%02d", [N(idx), N(nsec)]));
        if (idx >= 1 && idx <= nsec && idx == Math.floor(idx)) {
            vmx.str(h, "objectiveText", objectiveText(secs[<i32>idx], objectiveAt(S, idx)));
        }
    }
    let o = objectiveAt(S, idx);
    if (o != null) {
        vmx.num(h, "objectiveProgress", Math.floor(mathx.saturate(o.progress) * 100 + 0.5) / 100);
    }
    // a timed skim objective shows its empty track from the start
    vmx.bool(h, "objectiveTrack", !school && o != null && (o.kind == "low" || o.kind == "skim"));
    vmx.bool(h, "routeQuiet", quiet(p));
    vmx.str(h, "timeText", S.timeText);
    vmx.syncRoute(h, level.sections, S.statuses, S.details);
    phaseShort(h);
    hint(h, c, p, S, online && !school && p.alive);
}

// S.objectives[idx] (null: nil)
function objectiveAt(S: Scoring, idx: f64): Objective? {
    let os = S.objectives;
    if (idx >= 1 && idx < <f64>os.length && idx == Math.floor(idx)) return os[<i32>idx];
    return null;
}

// Pilot sprite view model. bank +1 = banking right, pitch +1 = climbing.
export function syncPilot(pv: Bag, p: Player, firing: bool): void {
    vmx.num(pv, "bank", Math.floor(mathx.clamp(-p.bank / 0.75, -1, 1) * 100 + 0.5) / 100);
    vmx.num(pv, "pitch", Math.floor(mathx.clamp(p.pitch / 0.45, -1, 1) * 100 + 0.5) / 100);
    vmx.num(pv, "thrust", Math.floor(p.thrust * 50 + 0.5) / 50);
    vmx.bool(pv, "boost", p.boosting);
    vmx.bool(pv, "firing", firing);
}

// Game view model: results fields. p: the pilot (else the shield at the last HUD sync).
export function syncResults(g: Bag, S: Scoring, stats: Stats, p: Player? = null): void {
    vmx.num(g, "score", S.score);
    vmx.str(g, "scoreText", format("%07d", [N(S.score)]));
    vmx.num(g, "rings", S.ringCount);
    vmx.num(g, "ringsTotal", S.ringsTotal);
    vmx.num(g, "kills", stats.kills);
    vmx.num(g, "killsTotal", lmax(stats.killsTotal, stats.kills));
    vmx.num(g, "hitRatio", Math.floor(S.hitRatio * 100 + 0.5));
    vmx.str(g, "timeText", S.timeText);
    vmx.str(g, "rank", S.rank);
    vmx.num(g, "bestScore", S.best);
    vmx.bool(g, "newBest", S.newBest);
    // results OBJECTIVES row (hidden while the total is 0): the briefing's three mission objectives (QA L23: it
    // read x / 8 route legs, and a debug start counted the skipped ones)
    let done = scoring.mission(S);
    let total = scoring.MISSION_2;
    vmx.optSetNum(g, "objectives", done);
    vmx.optSetNum(g, "objectivesTotal", total);
    // results SHIELD row (0..100; the screen hides it while < 0)
    let sh = p != null ? p.shield : shieldLast;
    vmx.optSetNum(g, "shieldLeft", Math.floor(mathx.saturate(sh) * 100 + 0.5));
}

// The boss weak point the HUD's boss stack dodges (Hud.bossU / bossV): among the exposed boss parts (alive, shown,
// unarmored) on screen, the one most in the stack's way (highest, nearest the top centre). Sticky: the last pick
// holds unless another is clearly more in the way, so the dodge never flickers between pods. Returns u, v (0..1,
// y down) and the pick (nil: none).
// Projector: the core's camera.project; project returns u and sets pjV / pjD.
export abstract class Projector {
    pjV: f64 = 0;
    pjD: f64 = 0;
    abstract project(x: f64, y: f64, z: f64): f64;
}

// returns u; BOSS_POINT_1 / _2 / _3 = u, v, pick
export let BOSS_POINT_1: f64 = -1;
export let BOSS_POINT_2: f64 = -1;
export let BOSS_POINT_3: Enemy? = null;

export function bossPoint(E: World, proj: Projector, prev: Enemy? = null): f64 {
    let best: Enemy? = null;
    let bestK = HUGE, bu = -1.0, bv = -1.0;
    let prevK = HUGE, pu = -1.0, pv = -1.0;
    let l = E.list;
    for (let i = 1; i < l.length; i++) {
        let e = l[i];
        if (e.part && e.alive && !e.hidden && e.dying <= 0 && !e.armored) {
            let u = proj.project(e.x, e.y, e.z);
            let v = proj.pjV, w = proj.pjD;
            if (w > 0 && u >= 0 && u <= 1 && v >= 0 && v <= 1) {
                let k = v + 2 * lmax(0, Math.abs(u - 0.5) - 0.25);
                if (k < bestK) {
                    best = e;
                    bestK = k;
                    bu = u;
                    bv = v;
                }
                if (e == prev) {
                    prevK = k;
                    pu = u;
                    pv = v;
                }
            }
        }
    }
    if (prev != null && prevK < HUGE && prevK <= bestK + 0.06) {
        BOSS_POINT_1 = pu;
        BOSS_POINT_2 = pv;
        BOSS_POINT_3 = prev;
        return pu;
    }
    BOSS_POINT_1 = bu;
    BOSS_POINT_2 = bv;
    BOSS_POINT_3 = best;
    return bu;
}
