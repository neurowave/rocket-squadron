// Port of src/game/core_pages.luau. The core's comms helpers: phone plate page counts, typer pace, moods, radio rules.
//
// The phone comms plate (Hud.commCols > 0, hud.md Phone comms; Hud.commRows
// lines a page, 3 in a small landscape window) shows a long line a page at a
// time; each typed-out page that continues holds before the next. The core
// counts the pages to give a line that time on air (game readNeed /
// typeOut): paginate is the typer's own code (scene/hud_comms, between the
// PAGINATE markers), and the page holds follow the typer's schedule: keep in
// step.
//
// Port: game.luau's untyped comm lines / alerts are CommLine / CoreAlert
// (below); events' queues are events.Alert / events.Follow. Lists 1-based.
// Multi-returns: holds -> HOLDS_1 / _2, recut -> RECUT_1 / _2. Luau nil: string? null,
// number NaN. cols / rows are set with setPlate (imported bindings are
// read-only). rockAt (weak table by line) -> CommLine.rockAt.
import { Pattern } from "rive/pattern";
import { format, FormatArg } from "rive/format";
import * as level from "../world/level";
import * as playerMod from "./player";
import * as wingmen from "./wingmen";
import { Boss } from "./ai_types";
import { Alert, Follow } from "./events";
import { HUGE, lmin, lmax, lclamp, lfind, lsub } from "../lib/compat";

// game.luau's CommLine (a line in the core's comm queue / on air)
export class CommLine {
    who: string = "";
    speaker: string = "";
    text: string = "";
    seconds: f64 = 0;
    mood: string? = null;
    prio: f64 = 0;
    age: f64 = 0;
    maxAge: f64 = 0;
    wing: bool = false;
    boss: Boss? = null;
    phase: f64 = 0;
    rock: bool = false;
    react: bool = false;
    yield: bool = false;
    rockAt: f64 = NaN; // lineMoot: where this rock line goes moot (Luau rockAt[l])
}

// game.luau's Alert (a slab in the core's queue)
export class CoreAlert {
    warn: bool = false;
    text: string = "";
    sub: string = "";
    kind: string = "";
    seconds: f64 = 0;
    prio: f64 = 0;
    age: f64 = 0;
    maxAge: f64 = 0;
}

// a page that continues holds 0.1 of the line's budget, PAGE_MIN..PAGE_HOLD s
// (the last page too, on top of the line's own hold); the core allows
// PAGE_MIN a page turn
export const PAGE_MIN: f64 = 0.3;
export const PAGE_HOLD: f64 = 0.5;
const MARK: f64 = 1.5; // em kept free at the end of a page that continues
const FIT: f64 = 0.97; // of the line's width

// Montserrat 620 advances, ASCII 32-126, 1/1000 em: the typer's ADV (1-based)
const ADV: Array<f64> = [
    0.0,
    277, 280, 418, 713, 631, 863, 711, 222, 349, 350, 420, 592, 248, 385, 248, 375, 674, 383, 583,
    584, 681, 586, 629, 611, 653, 629, 248, 248, 592, 592, 592, 582, 1035, 752, 762, 728, 826, 671,
    637, 771, 810, 321, 530, 731, 600, 955, 810, 842, 727, 842, 732, 631, 605, 789, 732, 1148, 697,
    664, 665, 354, 375, 354, 593, 500, 600, 609, 687, 583, 688, 624, 373, 695, 686, 292, 297, 641,
    292, 1052, 686, 647, 687, 687, 422, 518, 426, 682, 582, 922, 577, 582, 534, 374, 304, 374, 592,
];

// BEGIN PAGINATE: the same text in scene/hud_comms (the typer) and core_pages (the core's page count).
function advOf(ch: string): f64 {
    let c = ch.length > 0 ? ch.charCodeAt(0) : 0;
    if (ch.length == 1 && c >= 32 && c <= 126) {
        return ADV[c - 31] / 1000;
    }
    return 0.7;
}

// (Luau's local closures over the words: a class; wrapped -> wrapL / wrapW)
class Pager {
    chars: Array<string>;
    wa: Array<i32> = [0];
    wb: Array<i32> = [0];
    acc: Array<f64> = [0.0];
    full: f64 = 0;
    wrapL: f64 = 0;
    wrapW: f64 = 0;
    constructor(chars: Array<string>) {
        this.chars = chars;
    }
    // words a..b wrapped greedily into lines of `full`: lines, the last line's width
    wrapped(a: i32, b: i32): void {
        let wa = this.wa, wb = this.wb, acc = this.acc;
        let lines = 1.0;
        let x0 = wa[a];
        for (let k = a + 1; k <= b; k++) {
            if (acc[wb[k] + 1] - acc[x0] > this.full) {
                lines += 1;
                x0 = wa[k];
            }
        }
        this.wrapL = lines;
        this.wrapW = acc[wb[b] + 1] - acc[x0];
    }
    stop(w: i32): i32 { // 2 sentence end, 1 clause end, 0 mid-phrase
        let chars = this.chars;
        let e = this.wb[w];
        let ch = chars[e];
        if (e - this.wa[w] >= 2 && ch == "." && chars[e - 1] == ".") {
            return 1;
        }
        if (ch == "." || ch == "!" || ch == "?") {
            return 2;
        }
        if (ch == "," || ch == ";" || ch == ":" || ch == "-") {
            return 1;
        }
        return 0;
    }
    // a break after word j strands a word: j opens a sentence (or follows an ellipsis) and runs on, or j + 1
    // closes a sentence j is in
    strands(j: i32): f64 {
        let p = j > 1 ? this.chars[this.wb[j - 1]] : ".";
        if ((p == "." || p == "!" || p == "?") && this.stop(j) == 0) {
            return 1;
        }
        if (this.stop(j + 1) == 2 && this.stop(j) != 2) {
            return 1;
        }
        return 0;
    }
}

// table.insert(t, 1, v) on a 1-based list
function insert1(t: Array<f64>, v: f64): void {
    t.push(0);
    for (let k = t.length - 1; k > 1; k--) t[k] = t[k - 1];
    t[1] = v;
}

function better(s: f64, pg: f64, c: f64, s0: f64, pg0: f64, c0: f64): bool {
    if (s != s0) {
        return s < s0;
    }
    if (pg != pg0) {
        return pg < pg0;
    }
    return c < c0;
}

let PAGINATE_1: Array<f64> = [0.0];
let PAGINATE_2: Array<f64> = [0.0];
let PAGINATE_3: f64 = 0;

// Pages of at most `rows` lines of cols em (whole words, wrapped as the text
// box wraps them). Chosen by, in order: the fewest stranded words (a page
// never ends on a sentence's first word, nor starts on its last one; a page
// more if that is what it takes; QA HUD2-5), the fewest pages, then the best
// breaks (a sentence end, else a clause) and even fill. A page that
// continues leaves room for the mark on its last line. Returns the first and
// last character of each page (the space at a break is dropped) and the
// fewest pages the text needs: the line is timed for that many.
// chars: 1-based. Returns pa; PAGINATE_1 / _2 / _3 = pa, pb (1-based), least.
function paginate(chars: Array<string>, cols: f64, rows: f64): Array<f64> {
    let n = chars.length - 1;
    if (cols <= 0 || n == 0) {
        PAGINATE_1 = [0.0, 1];
        PAGINATE_2 = [0.0, <f64>n];
        PAGINATE_3 = 1;
        return PAGINATE_1;
    }
    let P = new Pager(chars);
    let full = cols * FIT;
    P.full = full;
    let room = full - MARK;
    // words: first / last character, width up to each word's end
    let wa = P.wa, wb = P.wb;
    let from = 0;
    for (let i = 1; i <= n; i++) {
        if (chars[i] == " ") {
            if (from > 0) {
                wa.push(from);
                wb.push(i - 1);
                from = 0;
            }
        } else if (from == 0) {
            from = i;
        }
    }
    if (from > 0) {
        wa.push(from);
        wb.push(n);
    }
    let nw = wa.length - 1;
    let acc = P.acc;
    for (let i = 1; i <= n + 1; i++) acc.push(0.0);
    for (let i = 1; i <= n; i++) {
        acc[i + 1] = acc[i] + advOf(chars[i]);
    }
    // best[j]: strands, pages, cost and previous break for words 1..j ending a page that continues
    const INF: f64 = 1e9;
    let strand: Array<f64> = [0.0];
    let pages: Array<f64> = [0.0];
    let cost: Array<f64> = [0.0];
    let prev: Array<i32> = [0];
    for (let i = 1; i <= nw + 1; i++) {
        strand.push(INF);
        pages.push(INF);
        cost.push(INF);
        prev.push(0);
    }
    strand[1] = 0;
    pages[1] = 0;
    cost[1] = 0; // (index j + 1: j words placed)
    let endStrand = INF, endPages = INF, endCost = INF;
    let endPrev = -1;
    for (let j = 1; j <= nw; j++) {
        let sj = j < nw ? P.strands(j) : 0.0;
        for (let i = 0; i <= j - 1; i++) {
            if (pages[i + 1] < INF) {
                P.wrapped(i + 1, j);
                let nl = P.wrapL, lw = P.wrapW;
                let w = (nl - 1) * full + lw; // (one line: the words' width)
                if (j == nw && nl <= rows && lw <= full) {
                    let q = 1 - w / (rows * full);
                    let s = strand[i + 1], pg = pages[i + 1] + 1, c = cost[i + 1] + 0.35 * (q * q);
                    if (better(s, pg, c, endStrand, endPages, endCost)) {
                        endStrand = s;
                        endPages = pg;
                        endCost = c;
                        endPrev = i;
                    }
                }
                if (j < nw && nl <= rows && lw <= room) {
                    let k = P.stop(j);
                    let pen = k == 2 ? 0.0 : k == 1 ? 0.12 : 0.4;
                    let s = strand[i + 1] + sj, pg = pages[i + 1] + 1;
                    let q = 1 - w / ((rows - 1) * full + room);
                    let c = cost[i + 1] + pen + 0.6 * (q * q);
                    if (better(s, pg, c, strand[j + 1], pages[j + 1], cost[j + 1])) {
                        strand[j + 1] = s;
                        pages[j + 1] = pg;
                        cost[j + 1] = c;
                        prev[j + 1] = i;
                    }
                }
            }
        }
    }
    // the fewest pages (greedy fill gives the same count as the search without strands)
    let least = 1.0;
    let s0 = 1;
    while (true) {
        P.wrapped(s0, nw);
        if (P.wrapL <= rows && P.wrapW <= full) {
            break;
        }
        let j = s0;
        while (j < nw) {
            P.wrapped(s0, j + 1);
            if (P.wrapL > rows || P.wrapW > room) {
                break;
            }
            j += 1;
        }
        if (j >= nw) {
            break; // (a word wider than the plate)
        }
        s0 = j + 1;
        least += 1;
    }
    let pa: Array<f64> = [0.0], pb: Array<f64> = [0.0];
    if (endPrev >= 0) {
        let j = nw, i = endPrev;
        while (true) {
            insert1(pa, wa[i + 1]);
            insert1(pb, wb[j]);
            if (i == 0) {
                break;
            }
            let pi = prev[i + 1];
            j = i;
            i = pi;
        }
        pb[pb.length - 1] = n;
        PAGINATE_1 = pa;
        PAGINATE_2 = pb;
        PAGINATE_3 = least;
        return pa;
    }
    // a word wider than the plate: fill each page as far as it goes, cutting inside the word
    let a = 1;
    while (a <= n) {
        if (acc[n + 1] - acc[a] <= full) {
            pa.push(a);
            pb.push(n);
            break;
        }
        let cut = 0, b = a;
        for (let i = a; i <= n; i++) {
            if (acc[i + 1] - acc[a] > room) {
                break;
            }
            b = i;
            if (chars[i] == " " && i > a) {
                cut = i;
            }
        }
        pa.push(a);
        if (cut > 0) {
            pb.push(cut - 1);
            a = cut + 1;
        } else {
            pb.push(b);
            a = b + 1;
        }
    }
    PAGINATE_1 = pa;
    PAGINATE_2 = pb;
    PAGINATE_3 = <f64>(pb.length - 1);
    return pa;
}
// END PAGINATE

let memoCols: f64 = 0;
let memoRows: f64 = 1;
const memo: Map<string, f64> = new Map<string, f64>();

// Page turns `text` is timed for on a plate of `rows` lines (NaN: 1) `cols`
// em wide (0: no paging): the fewest pages - 1, from the typer's own
// pagination (paginate above). The typer may show a page more to avoid a
// stranded word, inside the same page holds.
export function turns(text: string, cols: f64, rows: f64 = NaN): f64 {
    cols = Math.floor(cols * 4 + 0.5) / 4; // (the typer's quarter em)
    let nr = lmax(1, Math.floor((isNaN(rows) ? 1.0 : rows) + 0.5));
    if (cols <= 0) {
        return 0;
    }
    if (cols != memoCols || nr != memoRows) {
        memo.clear();
        memoCols = cols;
        memoRows = nr;
    }
    if (memo.has(text)) {
        return memo.get(text);
    }
    let chars: Array<string> = [""];
    for (let i = 0; i < text.length; i++) chars.push(text.charAt(i));
    paginate(chars, cols, nr);
    let least = PAGINATE_3;
    memo.set(text, least - 1);
    return least - 1;
}

export let HOLDS_1: f64 = 0;
export let HOLDS_2: f64 = 0;

// The page holds of a paged line with `budget` s for typing and holds, of
// which `need` types it at READ_CPS with its punctuation holds squeezed:
// (each turn's hold, the last page's) -> HOLDS_1 / HOLDS_2. Short of time the
// last page's hold goes first, then the turns shorten (below PAGE_MIN only
// on a line paced too short for its pages); the typing never gives way.
export function holds(budget: f64, need: f64, turns: f64): f64 {
    let ph = lclamp(budget * 0.1, PAGE_MIN, PAGE_HOLD);
    let spare = lmax(0, budget - need);
    let turn = lmin(ph, spare / turns);
    HOLDS_1 = turn;
    HOLDS_2 = lclamp(spare - turn * turns, 0, ph);
    return turn;
}

// Comms pacing (the core's channel, game commPush / commPump) ------------------

// Portrait expression for a comms line (when the caller gives none).
const HAPPY: Array<string> = ["ha!", "ha ha", "nice", "beautiful", "that's flying", "save some", "milkshake", "well done", "good work", "show the baron", "bring us home", "take us home", "kettle", "threaded", "welcome aboard"];
const WORRIED: Array<string> = ["taking fire", "pull up", "careful", "watch", "incoming", "on your six", "look out", "mayday", "hurry", "roll it", "shake", "where in the world", "big on radar", "whoa", "looking at us", "heads up", "signal's thin"];
// Baron: angry on his losses, smug (the portrait's happy) on every gloat and threat
const BARON_ANGRY: Array<string> = ["no, no", "stop that", "enough", "my beautiful", "my lift core", "pay for", "retreat", "cost"];
export function mood(who: string, text: string): string {
    let t = text.toLowerCase();
    if (who == "baron") {
        for (let i = 0; i < BARON_ANGRY.length; i++) {
            if (lfind(t, BARON_ANGRY[i]) > 0) {
                return "angry";
            }
        }
        return "happy";
    }
    for (let i = 0; i < HAPPY.length; i++) {
        if (lfind(t, HAPPY[i]) > 0) {
            return "happy";
        }
    }
    for (let i = 0; i < WORRIED.length; i++) {
        if (lfind(t, WORRIED[i]) > 0) {
            return "worried";
        }
    }
    // a mostly upper-case line or an exclamation opener is shouted
    let up = 0.0, letters = 0.0;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            up += 1;
            letters += 1;
        } else if (c >= 97 && c <= 122) {
            letters += 1;
        }
    }
    if (letters > 0 && up / letters > 0.6) {
        return "shout";
    }
    let bang = lfind(text, "!");
    if (bang != 0 && bang < 24) {
        return "shout";
    }
    return "neutral";
}

// The HUD typer (scene/hud_comms): TYPE_CPS letters a second when the line
// has the time, after a lead-in while the window opens, with holds after
// punctuation; the whole line then stays up TYPE_TAIL. A line paced
// (`commSeconds`) shorter than that types faster. READ_CPS is the fastest a
// line is ever paced (QA M14). On the phone plate a long line pages and
// each page holds on top: the typer never types faster than READ_CPS either.
export const TYPE_CPS: f64 = 15;
export const READ_CPS: f64 = 21;
export const TYPE_LEAD: f64 = 0.27;
export const TYPE_TAIL: f64 = 0.45;
// the plate as the core's commPump read it last: Hud.commCols (0: no
// paging), Hud.commRows (lines a page holds: 3 in a small landscape window)
export let cols: f64 = 0;
export let rows: f64 = 1;
// (Luau: the core assigns M.cols / M.rows)
export function setPlate(c: f64, r: f64): void {
    cols = c;
    rows = r;
}

// The typer's punctuation holds over a line, seconds.
export function typeHolds(text: string): f64 {
    let total = 0.0;
    for (let i = 0; i < text.length - 1; i++) {
        let c = text.charCodeAt(i);
        let d = text.charCodeAt(i + 1);
        if (c == 44 || c == 59 || c == 58) { // , ; :
            total += 0.16;
        } else if (c == 46 || c == 33 || c == 63) { // . ! ?
            total += d == 46 || d == 33 || d == 63 ? 0.07 : 0.26;
        } else if (c == 45 && d == 32) { // ' - '
            total += 0.12;
        }
    }
    return total;
}

// The typing at READ_CPS and its punctuation holds, squeezed to a quarter
// of that at most (the typer squeezes them before it types faster).
export function typeNeed(text: string): f64 {
    let n = <f64>text.length;
    return lmin(n / READ_CPS + typeHolds(text), n / READ_CPS / 0.75);
}

// Seconds on air a line needs to be typed at READ_CPS at most and read; on
// the phone plate PAGE_MIN more a page turn.
export function readNeed(text: string): f64 {
    return TYPE_LEAD + typeNeed(text) + turns(text, cols, rows) * PAGE_MIN + TYPE_TAIL;
}

// Seconds into a line paced for `secs` by which the typer has all of it out
// (its schedule, page holds included).
export function typeOut(text: string, secs: f64): f64 {
    let n = <f64>text.length;
    let hl = typeHolds(text);
    let budget = lmax(0.6, secs - TYPE_TAIL - TYPE_LEAD);
    let tn = turns(text, cols, rows);
    let turnT = 0.0;
    if (tn > 0) {
        holds(budget, typeNeed(text), tn);
        let turn = HOLDS_1, last = HOLDS_2;
        turnT = turn * tn;
        budget = lmax(0.6, budget - turnT - last);
    }
    let typeTime = n / TYPE_CPS;
    if (typeTime + hl > budget) {
        hl *= lmin(1, budget * 0.25 / lmax(hl, 0.001));
        typeTime = lmax(budget - hl, n / 45);
    }
    return TYPE_LEAD + typeTime + hl + turnT;
}

// The longest run of whole sentences from the start of `text` that can be
// typed at a readable pace and read in `t` s (the whole line when it fits;
// null when not even the first sentence does): the last resort for a line
// about a moment ahead that starts too late for all of it.
export function fitLine(text: string, t: f64): string? {
    if (readNeed(text) <= t) {
        return text;
    }
    let best: string? = null;
    let i = 1;
    while (true) {
        let m = Pattern.find(text, "[%.!?]+%s", i - 1);
        if (m == null) {
            break;
        }
        let b = m.end; // (Luau's 1-based inclusive end)
        let head = text.substring(0, b - 1);
        if (readNeed(head) > t) {
            break;
        }
        best = head;
        i = b + 1;
    }
    return best;
}

// The first sentence of `text` (the whole line when it has one).
export function lead(text: string): string {
    let m = Pattern.find(text, "^(.-[%.!?]+)%s");
    return m != null ? m.group(1) : text;
}

// The longest run of whole sentences from the start of `text` typed out
// within `t` s at the fastest readable pace (the whole line when it is; null
// when not even the first sentence is): a line due to end its typing before
// a warning goes up.
export function fitTyped(text: string, t: f64): string? {
    return fitLine(text, t + TYPE_TAIL);
}

export let RECUT_1: string = "";
export let RECUT_2: f64 = 0;

// A line as it goes on air at rail s, `v` m/s, `warn` s before the next
// warning (game warnIn), and the most seconds it may be paced for (HUGE:
// any) -> RECUT_1 (text) / RECUT_2. A wingman (not a shot reaction, nor a
// peel call: peelCall) says only his first sentence in a hazard stretch or
// when he would type on into one (r4). A script line still typing when a
// warning goes up says its leading sentences typed out before it, paced to
// be; not a section's call (`pair`: the instruction) nor an urgent one (r4).
export function recut(l: CommLine, text: string, s: f64, v: f64, warn: f64): string {
    if (l.wing) {
        if (!l.react && !peelCall(l.text) && (readNeed(text) - TYPE_TAIL) * v > stretchIn(s)) {
            RECUT_1 = lead(text);
            RECUT_2 = HUGE;
            return RECUT_1;
        }
        RECUT_1 = text;
        RECUT_2 = HUGE;
        return text;
    }
    let wr = warn - 0.15;
    if (l.prio >= 4 || wr <= 0 || wr == HUGE) {
        RECUT_1 = text;
        RECUT_2 = HUGE;
        return text;
    }
    if (pair(text) == null) {
        let ft = fitTyped(text, wr);
        if (ft != null) text = ft;
    }
    RECUT_1 = text;
    RECUT_2 = wr + TYPE_TAIL;
    return text;
}

// Where a line with `k` letters out can stop on a whole word: the end of the
// sentence being typed when that is within `reach` letters (the line's own
// end too: it finishes), else the end of the word. Returns the letters out
// by then.
export function cutPoint(text: string, k: f64, reach: f64, whole: bool = false): f64 {
    let n = text.length;
    if (whole && <f64>n - k <= reach) {
        // (to its end when that is in reach: QA PT2)
        return n;
    }
    let word = n;
    for (let i = <i32>lmax(k, 1); i <= n; i++) {
        if (i == n || text.charCodeAt(i) == 32) {
            let c = text.charCodeAt(i - 1);
            if (word == n && c != 45) {
                word = i;
            }
            if (<f64>i - k > reach) {
                break;
            }
            if (c == 46 || c == 33 || c == 63) {
                return i;
            }
        }
    }
    return word;
}

// The radio's script rules ------------------------------------------------------

// The radio where the flying is hardest (QA PT1-4): no flavor in the stack
// field, the Low Pass and the Cliff Turn canyon. The Baron's hello (cued at
// 770) is held to just past the sea arch (KESSEL_S) and recut short: the
// one open slot before the Stormcrow (QA PT2-1). The mines call is recut
// short and goes out with MINEFIELD AHEAD, at prio 2 so it never cuts the
// kamikaze call (1240); boosting into the arch it says only 'Mines on the
// arch!'.
const HAZARDS: Array<Array<f64>> = [[0.0], [0.0, 740, 1500], [0.0, 1800, 3900]];
export const MINES_S: f64 = 1375;
export const MINES_LINE: string = "Mines on the arch! Pop one and they all go.";
export const KESSEL_S: f64 = level.anchors.archS + 12;
// The scripted hazard calls (events' cues, game BEATS: keep in step): the
// kamikazes, the mines call, the canyon's gun nests. The first-rock line
// only starts when it is over before the next of them (QA PT2-5). 1-based.
export const HAZARD_CALLS: Array<f64> = [0.0, 1240, MINES_S, 2870];

// The hazard calls' lines (by their lead): a beat that takes over the
// first-rock line cuts it at once only for one of these; any other beat lets
// it finish (QA PT2-4).
const HAZARD_LEADS: Array<string> = ["Kamikazes!", "Mines on the arch!", "Gun nests on the canyon walls"];
export function hazardLine(text: string): bool {
    for (let i = 0; i < HAZARD_LEADS.length; i++) {
        let h = HAZARD_LEADS[i];
        if (lsub(text, 1, h.length) == h) {
            return true;
        }
    }
    return false;
}

// The end (rail s, its s1) of the formation window whose join call this
// is, else NaN (`peeled`: only a window with a peel call). A join call not
// started JOIN_LATE m before a peel call's window end is stale (QA PT2-1);
// window 1 has none.
export const JOIN_LATE: f64 = 120;
function joinEnd(text: string, peeled: bool = false): f64 {
    let W = wingmen.WINDOWS;
    for (let i = 1; i < W.length; i++) {
        let w = W[i];
        if (!peeled || w.peel.length - 1 > 0) {
            for (let k = 1; k < w.join.length; k++) {
                if (w.join[k].text == text) {
                    return w.s1;
                }
            }
        }
    }
    return NaN;
}

// Where the first-rock line for a hit at rail s is moot: the end of the
// hazard stretch it is in (QA PT2-5), else ROCK_AFTER m on. The Low Pass
// stacks end at the canyon mouth (CLIFF TURN). An arch hit's line is moot
// once he is past the arch (QA PT2-1).
const ROCK_AFTER: f64 = 300;
function canyonS(): f64 {
    let c = 0.0;
    let S = level.sections;
    for (let i = 1; i < S.length; i++) {
        if (S[i].label == "CLIFF TURN") {
            c = S[i].s0;
        }
    }
    return c;
}
const CANYON_S: f64 = canyonS();
export function rockUntil(s: f64): f64 {
    let a = level.anchors.arch;
    if (s > a.s0 - 6 && s < a.s1 + 6) {
        return a.s1 + 6;
    }
    for (let i = 1; i < HAZARDS.length; i++) {
        let h = HAZARDS[i];
        if (s >= h[1] && s <= h[2]) {
            return s < CANYON_S && h[2] > CANYON_S ? CANYON_S : h[2];
        }
    }
    return s + ROCK_AFTER;
}

// A wingman's peel call (he leaves the formation with it): said whole even
// in a hazard stretch (recut), so the pair never leave on a line that only
// reads as a warning (QA PT3-5).
export function peelCall(text: string): bool {
    let W = wingmen.WINDOWS;
    for (let i = 1; i < W.length; i++) {
        let w = W[i];
        for (let k = 1; k < w.peel.length; k++) {
            if (w.peel[k].text == text) {
                return true;
            }
        }
    }
    return false;
}

// The seconds the line on air (`on`; `t` left, `age` on air, typed out at
// `outAt`) has left, cut short:
// - the first of two joining wingmen (`pend` the second still waiting)
//   hands the channel over once her call is typed out and read (QA PT3-5);
// - while the Watcher's beam charges or sweeps (`quiet`) a flavor / Baron
//   line ends once typed out (QA PT1-4).
export function lineEnd(on: CommLine?, t: f64, age: f64, outAt: f64, text: string, pend: f64, quiet: bool, cutTail: f64): f64 {
    if (t <= 0 || on == null) {
        return t;
    }
    if (quiet && (on.prio <= 1 || on.who == "baron")) {
        t = lmin(t, outAt + cutTail - age);
    }
    if (on.wing && pend > 0 && !isNaN(joinEnd(on.text))) {
        t = lmin(t, lmax(outAt + cutTail, readNeed(text)) - age);
    }
    return t;
}

// A wingman's formation call (a join or peel) is waiting: the first-rock
// line lets it go first (QA PT2-1). q: 1-based.
export function formationWaiting(q: Array<CommLine>): bool {
    let W = wingmen.WINDOWS;
    for (let j = 1; j < q.length; j++) {
        let l = q[j];
        if (l.wing) {
            if (!isNaN(joinEnd(l.text))) {
                return true;
            }
            for (let i = 1; i < W.length; i++) {
                let w = W[i];
                for (let k = 1; k < w.peel.length; k++) {
                    if (w.peel[k].text == l.text) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

// A waiting line gone moot at rail s (game commPump): the first-rock line
// past its stretch (`rockUntil`), a formation join call past its peel
// window's end - JOIN_LATE.
export function lineMoot(l: CommLine, s: f64): bool {
    if (l.rock) {
        let u = l.rockAt;
        if (isNaN(u)) {
            u = rockUntil(s);
            l.rockAt = u;
        }
        return s > u;
    }
    if (l.wing) {
        let e = joinEnd(l.text, true);
        return !isNaN(e) && s > e - JOIN_LATE;
    }
    return false;
}

// The Baron's hello has the post-card slot: flavor waiting for it goes.
export function dropFlavor(q: Array<CommLine>): void {
    for (let k = q.length - 1; k >= 1; k--) {
        if (q[k].prio <= 1) {
            q.splice(k, 1);
        }
    }
}

// A peel call of `who`: his join call still waiting is moot.
export function dropJoins(q: Array<CommLine>, who: string): void {
    for (let k = q.length - 1; k >= 1; k--) {
        if (q[k].wing && q[k].who == who && !isNaN(joinEnd(q[k].text))) {
            q.splice(k, 1);
        }
    }
}

// Seconds until the next hazard call at rail s, speed v (HUGE: none). A
// formation window with a peel call counts too: its end, and none at all
// from there to its `wait` m past it, where the pair breaks off with its
// call (QA PT2-1).
export function hazardIn(s: f64, v: f64): f64 {
    let best = HUGE;
    for (let i = 1; i < HAZARD_CALLS.length; i++) {
        let c = HAZARD_CALLS[i];
        if (c > s) {
            best = lmin(best, c);
            break;
        }
    }
    let W = wingmen.WINDOWS;
    for (let i = 1; i < W.length; i++) {
        let w = W[i];
        if (w.peel.length - 1 > 0) {
            if (s < w.s1) {
                best = lmin(best, w.s1);
            } else if (s < w.s1 + (isNaN(w.wait) ? 0.0 : w.wait)) {
                return 0;
            }
        }
    }
    return best == HUGE ? best : (best - s) / lmax(v, 10);
}
// s the visor stays down past a checkpoint count's GO (game postFx): the
// count's plates and its GO! exit clear before the panels come back (QA PT2-6)
export const GO_HOLD: f64 = 0.5;
export const KESSEL_LINE: string = "Baron Kessel here. This is MY sky!";

// s: held until that rail s; pair: the slab / warning it goes out with (it
// starts as that comes up; `hold`: held until it shows); drop: not said. A
// section's call pairs with its checkpoint slab, should that come late.
export class Radio {
    lead: string = "";
    s: f64 = NaN;
    text: string? = null;
    seconds: f64 = NaN;
    prio: f64 = NaN;
    pair: string? = null;
    pairAll: bool = false;
    hold: bool = false;
    drop: bool = false;
}
function radioOf(lead: string, s: f64, text: string?, seconds: f64, prio: f64, pair: string?, pairAll: bool, hold: bool): Radio {
    let r = new Radio();
    r.lead = lead;
    r.s = s;
    r.text = text;
    r.seconds = seconds;
    r.prio = prio;
    r.pair = pair;
    r.pairAll = pairAll;
    r.hold = hold;
    return r;
}
// 1-based
const RADIO: Array<Radio> = [
    new Radio(),
    radioOf("Baron Kessel speaking", KESSEL_S, KESSEL_LINE, 2.4, 2, null, false, false),
    radioOf("Arch dead ahead", NaN, MINES_LINE, 2.6, 2, "MINEFIELD AHEAD", false, true),
    radioOf("Low pass.", NaN, null, NaN, NaN, "03  LOW PASS", false, false),
    radioOf("Gun nests on the canyon walls", NaN, null, NaN, NaN, "04  CLIFF TURN", false, false),
    // (VI's window-2 rejoin goes out with BOGEYS ON YOUR SIX!, QA RP-1)
    radioOf("Back with you!", NaN, null, NaN, NaN, "BOGEYS ON YOUR SIX!", true, false),
    // (the Baron's troopers line and their warning share a cue: they go out together)
    radioOf("My Jet Troopers", NaN, null, NaN, NaN, "JET TROOPERS ON YOUR SIX", false, false),
    radioOf("Portal's open!", NaN, null, NaN, NaN, "SKY PORTAL", false, false),
];
// a pair goes this long into its slab / warning
export const PAIR_WIN: f64 = 1.0;
// events' warning cues not in game BEATS (BOGEYS ON YOUR SIX! twice,
// UNKNOWN CONTACT; keep in step): the wingmen keep clear of them. 1-based.
export const WARN_CUES: Array<f64> = [0.0, 560, 2230, 7450];
// The Baron's taunt before the Watcher rises (events WATCHER_S - 210): typed
// out before WARNING  UNKNOWN CONTACT or not said (QA RP-2)
export const WATCHER_LEAD: string = "You want the Eye";
export function watcherLine(text: string): bool {
    return lsub(text, 1, WATCHER_LEAD.length) == WATCHER_LEAD;
}
// the boss cues (events STORMCROW_S, WATCHER_S; keep in step). 1-based.
export const BOSS_CUES: Array<f64> = [0.0, 3600, 7450];
// a warning waits this long at most for the line on air's letters (game
// alertPump), so a wingman's line may end its typing WARN_SLACK past a
// warning cue
export const WARN_HOLD: f64 = 0.7;
export const WARN_SLACK: f64 = 0.5;

// A warning waits in events' queue `evAlerts` (1-based) for the slot.
export function warnWaits(evAlerts: Array<Alert>): bool {
    for (let i = 1; i < evAlerts.length; i++) {
        if (evAlerts[i].kind == "warning") {
            return true;
        }
    }
    return false;
}

// Seconds before the next warning goes up at rail s, `v` m/s: 0 while one
// waits for the slot (the core's queue `alerts`, events' `evAlerts`; both
// 1-based), else the next warning cue.
export function warnIn(alerts: Array<CoreAlert>, evAlerts: Array<Alert>, s: f64, v: f64): f64 {
    for (let i = 1; i < alerts.length; i++) {
        if (alerts[i].warn) {
            return 0;
        }
    }
    if (warnWaits(evAlerts)) {
        return 0;
    }
    let best = HUGE;
    for (let i = 1; i < WARN_CUES.length; i++) {
        let c = WARN_CUES[i];
        if (c > s) {
            best = lmin(best, (c - s) / v);
        }
    }
    for (let i = 1; i < BOSS_CUES.length; i++) {
        let c = BOSS_CUES[i];
        if (c > s) {
            best = lmin(best, (c - s) / v);
        }
    }
    return best;
}

// The radio rule for a script line (by its lead; the mines call by its
// recut text too), else null.
export function radio(text: string): Radio? {
    for (let i = 1; i < RADIO.length; i++) {
        let r = RADIO[i];
        let rt = r.text;
        if ((rt != null && text == rt) || lsub(text, 1, r.lead.length) == r.lead) {
            return r;
        }
    }
    return null;
}

// A centre slab is read, then gives way to a call: headline and sub are out
// by 1.27 s; SLAB_MIN by the slab's priority: an info slab as its sub is
// out, a checkpoint 0.3 s on, an objective result 0.7 s; the alert slot
// then goes to idle and stays free SLAB_CLR.
const SLAB_MIN: Array<f64> = [0.0, 1.3, 1.6, 2.0];
export const SLAB_CLR: f64 = 0.2;

// Seconds a slab of priority `prio` is up before it gives way to a call.
export function slabMin(prio: f64): f64 {
    return SLAB_MIN[<i32>lclamp(prio, 1, 3)];
}
// a retry skips these once heard: the tower's hello, the pair's intros,
// the mines call, the Baron's hello
const OPENING: Array<string> = ["Lighthouse to Corsair", "Vi on your left wing", "Hank on the right", MINES_LINE, KESSEL_LINE];

// The slab / warning a line goes out with (RADIO pair), else null.
export function pair(text: string): string? {
    let r = radio(text);
    return r != null ? r.pair : null;
}

// How long into its slab a paired line may still go out with it: PAIR_WIN,
// or the whole slab (`pairAll`: VI's rejoin).
export function pairWin(text: string): f64 {
    let r = radio(text);
    return r != null && r.pairAll ? HUGE : PAIR_WIN;
}

// A line goes out with the slab up (its pair): that slab, or an objective
// result raised at its pair's section edge `sec` in its place.
export function paired(text: string, slab: string, sec: f64): bool {
    let p = pair(text);
    if (p == null) {
        return false;
    }
    let S = level.sections;
    let i = <i32>sec;
    let has = <f64>i == sec && i >= 1 && i < S.length;
    return p == slab || (has && lsub(slab, 1, 9) == "OBJECTIVE" && p == S[i].num + "  " + S[i].label);
}

// The first line in the comm queue `q` (1-based) that goes out with the slab
// up `age` s (`paired`, inside its `pairWin`), else 0.
export function pairedIn(q: Array<CommLine>, slab: string, sec: f64, age: f64): i32 {
    for (let k = 1; k < q.length; k++) {
        if (age < pairWin(q[k].text) && paired(q[k].text, slab, sec)) {
            return k;
        }
    }
    return 0;
}

// A slab whose pair line is still to come (events' follow queue `follow`,
// the core's `queue`; 1-based) or waiting behind a line on air (`busy`): it
// waits to go up with it.
export function pairDue(follow: Array<Follow>, queue: Array<CommLine>, slab: string, busy: bool): bool {
    for (let i = 1; i < follow.length; i++) {
        let p = pair(follow[i].text);
        if (p != null && p == slab) {
            return true;
        }
    }
    if (busy) {
        for (let i = 1; i < queue.length; i++) {
            let p = pair(queue[i].text);
            if (p != null && p == slab) {
                return true;
            }
        }
    }
    return false;
}

// The portal call still in events' follow queue (it waits behind the kill
// cheer), else null: the line before it leaves it its read.
export function portalFollow(follow: Array<Follow>): string? {
    for (let i = 1; i < follow.length; i++) {
        let t = follow[i].text;
        if (lfind(t.toLowerCase(), "portal") != 0) {
            return t;
        }
    }
    return null;
}

// Seconds a line (not about the portal) has while the tower's portal call
// still waits in events' follow queue: the call, starting after it, still
// has its read before the portal as if he runs at it flat out (game
// momentLeft), while this one is said at his speed now (cruise at least);
// HUGE otherwise.
export function portalRoom(follow: Array<Follow>, text: string, s: f64, speed: f64): f64 {
    let pf = portalFollow(follow);
    if (pf == null || lfind(text.toLowerCase(), "portal") != 0 || s >= level.portalS) {
        return HUGE;
    }
    let B = playerMod.BOOST;
    return (level.portalS - s - B * (0.3 + readNeed(pf))) / lmax(speed, playerMod.CRUISE);
}

// An objective result's sub when its section was named twice in a row: the
// objective in its own words ('STAY UNDER 3.2 M  +1000': the HUD chip's
// skim line; THE FALLS: the pool slab's words), not a bare '+1000' (r2).
const SKIM_LINE: string = format("%g M", [FormatArg.number(playerMod.SKIM_ALT)]);
export function resultSub(i: f64, sub: string): string {
    let S = level.sections;
    let k = <i32>i;
    if (<f64>k != i || k < 1 || k >= S.length) {
        return sub;
    }
    let sec = S[k];
    let name = sec.label == "THE FALLS" ? "SKIM THE POOL" : Pattern.gsub(sec.objective, "[%d%.]+ M$", SKIM_LINE).text;
    let a = lfind(sub, sec.label);
    if (a == 0) {
        return sub;
    }
    let b = a + sec.label.length - 1;
    return lsub(sub, 1, a - 1) + name + lsub(sub, b + 1);
}

export function opening(text: string): bool {
    for (let i = 0; i < OPENING.length; i++) {
        let o = OPENING[i];
        if (lsub(text, 1, o.length) == o) {
            return true;
        }
    }
    return false;
}

// In a hazard stretch at rail s.
export function hazard(s: f64): bool {
    for (let i = 1; i < HAZARDS.length; i++) {
        let h = HAZARDS[i];
        if (s >= h[1] && s < h[2]) {
            return true;
        }
    }
    return false;
}

// Meters from rail s to the next hazard stretch (0: in one, HUGE: none ahead).
export function stretchIn(s: f64): f64 {
    for (let i = 1; i < HAZARDS.length; i++) {
        let h = HAZARDS[i];
        if (s >= h[1] && s < h[2]) {
            return 0;
        } else if (s < h[1]) {
            return h[1] - s;
        }
    }
    return HUGE;
}

// The section a text names (its label, any case), 0 none.
export function secNamed(text: string): i32 {
    let u = text.toUpperCase();
    let S = level.sections;
    for (let i = 1; i < S.length; i++) {
        if (lfind(u, S[i].label) != 0) {
            return i;
        }
    }
    return 0;
}
