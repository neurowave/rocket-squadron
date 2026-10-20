// Port of src/game/core_quality.luau. Graphics quality (DIRECTION #27): the setting (auto / low / medium / high),
// the AUTO frame-time probe and the tier hooks. Same rules as the control mode
// (training.md 5.1): the core is the only writer of Game.quality (the setting)
// and Game.qualityNow (the level in effect); the UI requests a change through
// Game.qualityPick (1 low, 2 medium, 3 high, 4 auto, 9 next); the core resets
// it to 0. Session only. HIGH is today's look; the tiers live in
// renderer.setQuality / scenery.setQuality / fx.setQuality.
//
// Port: ORDER is 1-based; futile a Map; trialFrom null = nil; rawDt NaN = nil.
// The tier hooks are called directly (all three exist in the port).
import { format, FormatArg } from "rive/format";
import * as vmx from "./vm";
import { Bag } from "./vm";
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import * as scenery from "../world/scenery";
import * as fx from "./fx";
import { Fx } from "./fx";
import { lmax, mod } from "../lib/compat";

export const ORDER: Array<string> = ["", "auto", "low", "medium", "high"]; // the menu cycle, 1-based
export const LOG: bool = false;

// AUTO (EFFICIENCY_REVIEW 1.4), only while the setting is auto (a switch to
// auto starts it over from the level AUTO last had).
// - Late frames, not mean intervals: a frame is late when it misses the 60 Hz
//   pace (over LATE_DT, ~49.5 fps: a skipped vsync at 60 Hz, 2 vsyncs at 90
//   Hz, 3 at 120 / 144 Hz; a steady 60 on a fast display is on pace, and so
//   is a steady 50 uncapped). LATE_DT sits off 1/48 s and 1/50 s, which
//   vsync quantizes to exactly.
// - The probe waits for steady flight: WARM_T s in, and the course baked
//   (scenery.ready) or PROBE_WAIT s of flight, so the bake's slices do not
//   pick the tier. Over PROBE_T s: up to HIGH_LATE late keeps the level, past
//   LOW_LATE (the frame rate halved) goes to LOW, else one step down.
// - The watch, once the course is baked: WATCH_T windows; two in a row over
//   WATCH_LATE late step down one level; QUIET_T s of windows at most
//   QUIET_LATE late (a stray GC or OS hiccup allowed) step up one. A step up
//   that a step down follows within FAIL_T caps later step ups below that
//   level for the session. HOLD_T s pass between changes.
// - A step down is a trial: if the next TRIAL_WINS windows are not at least
//   FUTILE_K fewer late frames, the late frames are not the tier's (a CPU-
//   bound phone, OS jank) and it reverts; that late share becomes the
//   baseline the watch's thresholds sit on, and the level steps down again
//   only past FUTILE_WORSE times the share it had.
// - Intervals over HITCH s are skipped: the game passes the unclamped
//   interval (`rawDt`; its clamped `rdt` never exceeds 1/20 s).
const WARM_T: f64 = 1;
const PROBE_WAIT: f64 = 20;
const PROBE_T: f64 = 3;
const LATE_DT: f64 = 0.0202;
const HIGH_LATE: f64 = 0.04;
const LOW_LATE: f64 = 0.9;
const WATCH_T: f64 = 4;
const WATCH_LATE: f64 = 0.08;
const QUIET_LATE: f64 = 0.02;
const QUIET_T: f64 = 30;
const FAIL_T: f64 = 20;
const HOLD_T: f64 = 10;
const TRIAL_WINS: f64 = 2;
const FUTILE_K: f64 = 0.5;
const FUTILE_WORSE: f64 = 1.5;
const HITCH: f64 = 0.25;

function rank(level: string): f64 {
    if (level == "low") return 1;
    if (level == "medium") return 2;
    if (level == "high") return 3;
    return NaN; // (Luau nil: never compared)
}

export class Quality {
    setting: string = "auto"; // auto / low / medium / high
    level: string = "high"; // in effect: low / medium / high
    auto: string = "high"; // AUTO's level (high until the probe says otherwise)
    written: string = "";
    writtenNow: string = "";
    applied: string = "";
    probeT: f64 = 0;
    probeSum: f64 = 0;
    probeN: f64 = 0;
    probeLate: f64 = 0;
    probed: bool = false;
    flyT: f64 = 0; // flying time under AUTO (s)
    winT: f64 = 0; // the WATCH_T window: time, frames, late frames, interval sum
    winN: f64 = 0;
    winLate: f64 = 0;
    winSum: f64 = 0;
    lateWins: f64 = 0; // late windows in a row, and the sum of their shares
    badSum: f64 = 0;
    quietT: f64 = 0; // time in quiet windows in a row
    holdT: f64 = 0; // time until the next change may happen
    upT: f64 = -1; // flyT of the last step up (-1: none)
    ceiling: string = "high"; // step ups go no higher (a step up that did not hold)
    base: f64 = 0; // late share no tier removed (futile step downs)
    trialFrom: string? = null; // a step down on trial: from, the share it had there,
    trialShare: f64 = 0; // frames / late frames / windows since
    trialN: f64 = 0;
    trialLate: f64 = 0;
    trialWins: f64 = 0;
    futile: Map<string, f64> = new Map<string, f64>(); // level -> late share a step down from it did not cut
}

// AUTO's learning (a new session, and every switch to auto)
function restart(q: Quality): void {
    q.probeT = 0;
    q.probeSum = 0;
    q.probeN = 0;
    q.probeLate = 0;
    q.probed = false;
    q.flyT = 0;
    q.winT = 0;
    q.winN = 0;
    q.winLate = 0;
    q.winSum = 0;
    q.lateWins = 0;
    q.badSum = 0;
    q.quietT = 0;
    q.holdT = 0;
    q.upT = -1;
    q.ceiling = "high";
    q.base = 0;
    q.trialFrom = null;
    q.trialShare = 0;
    q.trialN = 0;
    q.trialLate = 0;
    q.trialWins = 0;
    q.futile = new Map<string, f64>();
}

export function create(): Quality {
    return new Quality();
}

function log(q: Quality, what: string): void {
    if (LOG) {
        console.log(
            format("[quality] %s: setting %s, level %s", [
                FormatArg.string(what),
                FormatArg.string(q.setting),
                FormatArg.string(q.level),
            ]),
        );
    }
}

function resolve(q: Quality): void {
    q.level = q.setting == "auto" ? q.auto : q.setting;
}

// An explicit choice (menus, qualityPick).
export function set(q: Quality, setting: string): void {
    if (setting == "auto" && q.setting != "auto") restart(q);
    q.setting = setting;
    resolve(q);
    log(q, "pick");
}

// Previous (-1) / next (1) in the cycle auto -> low -> medium -> high.
export function step(q: Quality, d: f64): void {
    let i = 1;
    let n = ORDER.length - 1;
    for (let k = 1; k <= n; k++) {
        if (ORDER[k] == q.setting) i = k;
    }
    set(q, ORDER[<i32>mod(<f64>(i - 1) + d, <f64>n) + 1]);
}

function down(level: string): string {
    return level == "high" ? "medium" : "low";
}

function up(level: string): string {
    return level == "low" ? "medium" : "high";
}

function setAuto(q: Quality, level: string, why: string, ms: f64): void {
    q.auto = level;
    if (q.setting == "auto") resolve(q);
    if (LOG) log(q, format("%s %.1f ms", [FormatArg.string(why), FormatArg.number(ms)]));
}

function baked(): bool {
    return scenery.ready();
}

// A step down from q.auto to `to`, the late share having been `share`: on
// trial for TRIAL_WINS windows.
function stepDown(q: Quality, to: string, share: f64, why: string, ms: f64): void {
    let from = q.auto;
    if (q.upT >= 0 && q.flyT - q.upT < FAIL_T && rank(q.ceiling) >= rank(from)) {
        q.ceiling = down(from);
    }
    setAuto(q, to, why, ms);
    q.trialFrom = from;
    q.trialShare = share;
    q.trialN = 0;
    q.trialLate = 0;
    q.trialWins = 0;
    q.lateWins = 0;
    q.badSum = 0;
    q.quietT = 0;
    q.holdT = HOLD_T;
}

function pct(pat: string, f: f64): string {
    return LOG ? format(pat, [FormatArg.number(f * 100)]) : "";
}

// The AUTO probe and the pace watch (real seconds, while flying under AUTO).
function watch(q: Quality, dt: f64): void {
    if (dt <= 0 || dt > HITCH) return;
    let late = dt > LATE_DT;
    q.flyT += dt;
    if (!q.probed) {
        if (q.flyT < WARM_T || !(q.flyT >= PROBE_WAIT || baked())) return;
        q.probeT += dt;
        q.probeSum += dt;
        q.probeN += 1;
        if (late) q.probeLate += 1;
        if (q.probeT >= PROBE_T) {
            q.probed = true;
            let f = q.probeLate / q.probeN;
            let why = pct("probe %.0f%% late", f);
            if (f > HIGH_LATE && q.auto != "low") {
                stepDown(q, f > LOW_LATE ? "low" : down(q.auto), f, why, (q.probeSum / q.probeN) * 1000);
            } else {
                log(q, why);
            }
        }
        return;
    }
    // (the bake's slices are not the tier's: the watch starts once it is done)
    if (!baked()) {
        q.winT = 0;
        q.winN = 0;
        q.winLate = 0;
        q.winSum = 0;
        return;
    }
    q.holdT -= dt;
    q.winT += dt;
    q.winN += 1;
    q.winSum += dt;
    if (late) q.winLate += 1;
    if (q.winT < WATCH_T) return;
    let n = q.winN;
    let nl = q.winLate;
    let wt = q.winT;
    let avg = q.winSum / n;
    let share = nl / n;
    q.winT = 0;
    q.winN = 0;
    q.winLate = 0;
    q.winSum = 0;
    let from = q.trialFrom;
    if (from != null) {
        q.trialN += n;
        q.trialLate += nl;
        q.trialWins += 1;
        if (q.trialWins >= TRIAL_WINS) {
            q.trialFrom = null;
            let f = q.trialLate / q.trialN;
            if (f > QUIET_LATE && f >= FUTILE_K * q.trialShare) {
                // not the tier's late frames: back up, and they are the baseline
                q.futile.set(from, q.trialShare);
                q.base = lmax(q.base, f);
                if (rank(q.ceiling) < rank(from)) q.ceiling = from;
                setAuto(q, from, pct("futile (%.0f%% late after)", f), avg * 1000);
                q.lateWins = 0;
                q.badSum = 0;
                q.quietT = 0;
                q.holdT = HOLD_T;
                return;
            }
        }
    }
    let hasFut = q.futile.has(q.auto);
    let bad = share > WATCH_LATE + q.base && (!hasFut || share > q.futile.get(q.auto) * FUTILE_WORSE);
    if (bad) {
        q.lateWins += 1;
        q.badSum += share;
    } else {
        q.lateWins = 0;
        q.badSum = 0;
    }
    q.quietT = share <= QUIET_LATE + q.base ? q.quietT + wt : 0;
    if (q.holdT > 0) return;
    if (q.lateWins >= 2 && q.auto != "low") {
        stepDown(q, down(q.auto), q.badSum / q.lateWins, "slow", avg * 1000);
    } else if (q.quietT >= QUIET_T && q.auto != "high" && rank(up(q.auto)) <= rank(q.ceiling)) {
        setAuto(q, up(q.auto), "quiet", avg * 1000);
        q.trialFrom = null;
        q.lateWins = 0;
        q.badSum = 0;
        q.quietT = 0;
        q.holdT = HOLD_T;
        q.upT = q.flyT;
    }
}

// The tiers: called on the first frame and whenever the level changes.
function apply(q: Quality, r: Gfx?, F: Fx?): void {
    if (q.applied == q.level) return;
    q.applied = q.level;
    if (r != null) R.setQuality(r, q.level);
    scenery.setQuality(q.level);
    if (F != null) fx.setQuality(F, q.level);
    log(q, "apply");
}

// Per frame: QA / pick input, the probe, the VM writes (change-only), the tiers.
// `rawDt`: the unclamped frame interval (the hitch filter needs it; NaN: the
// clamped `rdt` is used).
export function update(q: Quality, g: Bag?, rdt: f64, flying: bool, r: Gfx?, F: Fx?, rawDt: f64 = NaN): void {
    if (g != null) {
        // QA: --data=quality=low|medium|high is there before the first write
        // (the file default is auto)
        if (q.written == "") {
            let live = vmx.optEnumLive(g, "quality");
            if (live != null && live != "auto") set(q, live);
        }
        let pk = vmx.optNum(g, "qualityPick");
        let pick = isNaN(pk) ? 0.0 : pk;
        if (pick != 0) {
            if (pick == 1 || pick == 2 || pick == 3) {
                set(q, ORDER[<i32>pick + 1]);
            } else if (pick == 4) {
                set(q, "auto");
            } else if (pick == 9) {
                step(q, 1);
            }
            vmx.optSetNumLive(g, "qualityPick", 0);
        }
    }
    if (flying && q.setting == "auto") watch(q, isNaN(rawDt) ? rdt : rawDt);
    write(q, g);
    apply(q, r, F);
}

// The VM writes: quality and qualityNow change-only (the core is their only writer).
export function write(q: Quality, g: Bag?): void {
    if (g == null) return;
    if (q.written != q.setting) {
        vmx.optSetEnumLive(g, "quality", q.setting);
        q.written = q.setting;
    }
    if (q.writtenNow != q.level) {
        vmx.optSetEnumLive(g, "qualityNow", q.level);
        q.writtenNow = q.level;
    }
}
