// Port of scene/hud_comms.luau. Hud comms typewriter (scene/hud.rml, Comms window). Types Hud.commText at a
// steady rate, capped so the whole line is out before the channel moves on,
// and drives the portrait's mouth from the typing:
//   commTyped    characters shown, fractional while the next one fades in
//                (the Body text's reveal range reads it)
//   commProgress 0..1 (the RX rule)
//   commTalking  true while letters are still coming; false on the short
//                holds after punctuation and once the line is out
//   commPage     the text on the plate: the whole line, or one page of it
//   commMore     > 0 while more pages follow (0.5 typing, 1 typed out: the
//                continuation mark)
//   commDone     characters of the whole line out (commTyped counts within a
//                page on phones; the core cuts a stepped-on line on a whole
//                word from this)
//   commPlateEm  the typed part of the page in em (paged only, else 0): the
//                phone plate hugs it, so a short line leaves the aim reticle
//                clear
// Optional inputs: commSeconds (the line's on-screen seconds, game -> UI),
// commCols (HUD-internal: the plate's line in em at the body size; 0 = no
// paging), commRows (HUD-internal: lines a page holds, default 1). On phones
// the plate holds one line above the aim reticle, in a small landscape
// window the box holds commRows lines at the type floor, so a longer line is
// shown a page at a time inside the same seconds (the core adds the page
// holds to them): commTyped then counts within the page. No line types
// faster than READ_CPS.
//
// Port: a Node (ScriptedDrawable "CommTyper"). Sequences stay 1-based (slot 0
// dummy). paginate's closures are module functions over module state (PG_*);
// its three returns are PAGINATE_1 / _2 / _3.
import { Node, Context } from "rive/host";
import { PropertyString, PropertyBoolean, PropertyNumber, ViewModel } from "rive/data";
import { lmin, lmax, lclamp } from "../src/lib/compat";

const RATE: f64 = 15; // characters per second, when the line has the time
const LEAD_OPEN: f64 = 0.27; // the window slides in and locks on first
const LEAD_NEXT: f64 = 0.14; // a cut to the next line on an open channel
const DONE: f64 = 9999; // reveal everything
const READ_CPS: f64 = 21; // never types faster (src/game.luau READ_CPS: the core paces no line faster, page holds included)
const PAGE_HOLD: f64 = 0.5; // a typed-out page holds 0.1 of the line's budget, PAGE_MIN..PAGE_HOLD s, before the next
const PAGE_MIN: f64 = 0.3; // (the core allows this a page turn: src/game/core_pages.as, keep in step)
const MARK: f64 = 1.5; // em kept free at the end of a page that continues (the continuation mark)
const FIT: f64 = 0.97; // of the line's width (kerning, rounding)
// Montserrat 620 advances, ASCII 32-126, 1/1000 em (the core's copy: src/game/core_pages.as)
const ADV: Array<f64> = [
    0, // (slot 0)
    277, 280, 418, 713, 631, 863, 711, 222, 349, 350, 420, 592, 248, 385, 248, 375, 674, 383, 583,
    584, 681, 586, 629, 611, 653, 629, 248, 248, 592, 592, 592, 582, 1035, 752, 762, 728, 826, 671,
    637, 771, 810, 321, 530, 731, 600, 955, 810, 842, 727, 842, 732, 631, 605, 789, 732, 1148, 697,
    664, 665, 354, 375, 354, 593, 500, 600, 609, 687, 583, 688, 624, 373, 695, 686, 292, 297, 641,
    292, 1052, 686, 647, 687, 687, 422, 518, 426, 682, 582, 922, 577, 582, 534, 374, 304, 374, 592,
];

// BEGIN PAGINATE: the same text here (the typer) and in src/game/core_pages.as (the core's page count); keep the
// two copies in step.
function advOf(ch: string): f64 {
    // (one UTF-8 byte: an ASCII character; others 0.7)
    if (ch.length == 1) {
        let c = ch.charCodeAt(0);
        if (c >= 32 && c <= 126) return ADV[c - 31] / 1000;
    }
    return 0.7;
}

// paginate's returns: first and last character of each page (1-based lists), the fewest pages
export let PAGINATE_1: Array<i32> = [0, 1];
export let PAGINATE_2: Array<i32> = [0, 0];
export let PAGINATE_3: f64 = 1;

// paginate's shared state (Luau upvalues of its local functions)
let PG_chars: Array<string> = [""];
let PG_wa: Array<i32> = [0];
let PG_wb: Array<i32> = [0];
let PG_acc: Array<f64> = [0.0];
let PG_full: f64 = 0;
let WR_LINES: f64 = 0;
let WR_LW: f64 = 0;

// words a..b wrapped greedily into lines of `full`: lines (returned, WR_LINES), the last line's width (WR_LW)
function wrapped(a: i32, b: i32): f64 {
    let wa = PG_wa;
    let wb = PG_wb;
    let acc = PG_acc;
    let lines: f64 = 1;
    let x0 = wa[a];
    for (let k = a + 1; k <= b; k++) {
        if (acc[wb[k] + 1] - acc[x0] > PG_full) {
            lines += 1;
            x0 = wa[k];
        }
    }
    WR_LINES = lines;
    WR_LW = acc[wb[b] + 1] - acc[x0];
    return lines;
}

function stop(w: i32): i32 {
    // 2 sentence end, 1 clause end, 0 mid-phrase
    let chars = PG_chars;
    let e = PG_wb[w];
    let ch = chars[e];
    if (e - PG_wa[w] >= 2 && ch == "." && chars[e - 1] == ".") return 1;
    if (ch == "." || ch == "!" || ch == "?") return 2;
    if (ch == "," || ch == ";" || ch == ":" || ch == "-") return 1;
    return 0;
}

// a break after word j strands a word: j opens a sentence (or follows an ellipsis) and runs on, or j + 1
// closes a sentence j is in
function strands(j: i32): f64 {
    let p = j > 1 ? PG_chars[PG_wb[j - 1]] : ".";
    if ((p == "." || p == "!" || p == "?") && stop(j) == 0) return 1;
    if (stop(j + 1) == 2 && stop(j) != 2) return 1;
    return 0;
}

function better(s: f64, pg: f64, c: f64, s0: f64, pg0: f64, c0: f64): bool {
    if (s != s0) return s < s0;
    if (pg != pg0) return pg < pg0;
    return c < c0;
}

// Pages of at most `rows` lines of cols em (whole words, wrapped as the text
// box wraps them). Chosen by, in order: the fewest stranded words (a page
// never ends on a sentence's first word, nor starts on its last one: "Arch
// dead ahead. Kessel" / "us. Pop the lenses"; a page more if that is what it
// takes; QA HUD2-5), the fewest pages, then the best breaks (a sentence end,
// else a clause) and even fill. A page that continues leaves room for the
// mark on its last line. Returns the first and last character of each page
// (the space at a break is dropped) and the fewest pages the text needs: the
// line is timed for that many (the core's readNeed; the typer spreads the
// same page holds over a page added to avoid a strand), so no line takes
// longer to read than before.
function paginate(chars: Array<string>, cols: f64, rows: f64): f64 {
    let n = chars.length - 1;
    if (cols <= 0 || n == 0) {
        PAGINATE_1 = [0, 1];
        PAGINATE_2 = [0, n];
        PAGINATE_3 = 1;
        return 1;
    }
    let full = cols * FIT;
    let room = full - MARK;
    // words: first / last character, width up to each word's end
    let wa: Array<i32> = [0];
    let wb: Array<i32> = [0];
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
    let acc = new Array<f64>(n + 2); // 1-based, n + 1 entries, zeros
    for (let i = 1; i <= n; i++) acc[i + 1] = acc[i] + advOf(chars[i]);
    PG_chars = chars;
    PG_wa = wa;
    PG_wb = wb;
    PG_acc = acc;
    PG_full = full;
    // best[j]: strands, pages, cost and previous break for words 1..j ending a page that continues
    const INF: f64 = 1e9;
    let strand = new Array<f64>(nw + 2);
    let pages = new Array<f64>(nw + 2);
    let cost = new Array<f64>(nw + 2);
    let prev = new Array<i32>(nw + 2);
    for (let i = 1; i <= nw + 1; i++) {
        strand[i] = INF;
        pages[i] = INF;
        cost[i] = INF;
    }
    strand[1] = 0; // (index j + 1: j words placed)
    pages[1] = 0;
    cost[1] = 0;
    let endStrand = INF;
    let endPages = INF;
    let endCost = INF;
    let endPrev = -1;
    for (let j = 1; j <= nw; j++) {
        let sj = j < nw ? strands(j) : 0.0;
        for (let i = 0; i <= j - 1; i++) {
            if (pages[i + 1] < INF) {
                let nl = wrapped(i + 1, j);
                let lw = WR_LW;
                let w = (nl - 1) * full + lw; // (one line: the words' width)
                if (j == nw && nl <= rows && lw <= full) {
                    let s = strand[i + 1];
                    let pg = pages[i + 1] + 1;
                    let t = 1 - w / (rows * full);
                    let c = cost[i + 1] + 0.35 * (t * t);
                    if (better(s, pg, c, endStrand, endPages, endCost)) {
                        endStrand = s;
                        endPages = pg;
                        endCost = c;
                        endPrev = i;
                    }
                }
                if (j < nw && nl <= rows && lw <= room) {
                    let k = stop(j);
                    let pen = k == 2 ? 0.0 : k == 1 ? 0.12 : 0.4;
                    let s = strand[i + 1] + sj;
                    let pg = pages[i + 1] + 1;
                    let t = 1 - w / ((rows - 1) * full + room);
                    let c = cost[i + 1] + pen + 0.6 * (t * t);
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
    let least: f64 = 1;
    let s0 = 1;
    while (true) {
        let nl = wrapped(s0, nw);
        let lw = WR_LW;
        if (nl <= rows && lw <= full) break;
        let j = s0;
        while (j < nw) {
            let nl2 = wrapped(s0, j + 1);
            let lw2 = WR_LW;
            if (nl2 > rows || lw2 > room) break;
            j += 1;
        }
        if (j >= nw) break; // (a word wider than the plate)
        s0 = j + 1;
        least += 1;
    }
    let pa: Array<i32> = [0];
    let pb: Array<i32> = [0];
    if (endPrev >= 0) {
        let j = nw;
        let i = endPrev;
        // (Luau inserts each at the front: collected backwards, then reversed)
        let ra = new Array<i32>();
        let rb = new Array<i32>();
        while (true) {
            ra.push(wa[i + 1]);
            rb.push(wb[j]);
            if (i == 0) break;
            let ni = prev[i + 1];
            j = i;
            i = ni;
        }
        for (let q = ra.length - 1; q >= 0; q--) {
            pa.push(ra[q]);
            pb.push(rb[q]);
        }
        pb[pb.length - 1] = n;
        PAGINATE_1 = pa;
        PAGINATE_2 = pb;
        PAGINATE_3 = least;
        return least;
    }
    // a word wider than the plate: fill each page as far as it goes, cutting inside the word
    let a = 1;
    while (a <= n) {
        if (acc[n + 1] - acc[a] <= full) {
            pa.push(a);
            pb.push(n);
            break;
        }
        let cut = 0;
        let b = a;
        for (let i = a; i <= n; i++) {
            if (acc[i + 1] - acc[a] > room) break;
            b = i;
            if (chars[i] == " " && i > a) cut = i;
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
    return PAGINATE_3;
}
// END PAGINATE

function holdAfter(ch: string, nextCh: string): f64 {
    if (nextCh == "") return 0;
    if (ch == "," || ch == ";" || ch == ":") return 0.16;
    if (ch == "." || ch == "!" || ch == "?") {
        if (nextCh == "." || nextCh == "!" || nextCh == "?") return 0.07; // inside "..." or "?!"
        return 0.26;
    }
    if (ch == "-" && nextCh == " ") return 0.12;
    return 0;
}

// a string's characters (code points), 1-based (utf8.codes)
function codepoints(s: string): Array<string> {
    let out: Array<string> = [""];
    let i = 0;
    let n = s.length;
    while (i < n) {
        let cp = s.codePointAt(i);
        out.push(String.fromCodePoint(cp));
        i += cp > 0xffff ? 2 : 1;
    }
    return out;
}

// Luau table.concat(chars, '', a, b)
function joinRange(chars: Array<string>, a: i32, b: i32): string {
    let s = "";
    for (let i = a; i <= b; i++) s += chars[i];
    return s;
}

export class CommTyper extends Node {
    ctx: Context? = null;
    bound: ViewModel? = null; // the view model the properties below belong to
    text: PropertyString? = null;
    active: PropertyBoolean? = null;
    seconds: PropertyNumber? = null;
    typed: PropertyNumber? = null;
    progress: PropertyNumber? = null;
    talking: PropertyBoolean? = null;
    page: PropertyString? = null;
    more: PropertyNumber? = null;
    cols: PropertyNumber? = null;
    rows: PropertyNumber? = null;
    done: PropertyNumber? = null;
    plateEm: PropertyNumber? = null;
    acc: Array<f64> = [0.0, 0.0]; // 1-based
    last: string = "";
    lastCols: f64 = 0;
    lastRows: f64 = 1;
    lead: f64 = 0;
    chars: Array<string> = [""]; // 1-based
    pageA: Array<i32> = [0, 1]; // 1-based
    pageB: Array<i32> = [0, 0];
    shownPage: string = "";
    wasActive: bool = false;
    openAge: f64 = 0;
    t: f64 = 0;
    n: i32 = 0;
    times: Array<f64> = [0.0]; // 1-based
    quiet: Array<f64> = [0.0]; // 1-based
    stop: f64 = 0;
    step: f64 = 0.066;
    shown: f64 = -1;
    talk: bool = false;

    // Properties are resolved against the view model bound this frame: an artboard instanced
    // from script clones this node's state, so anything cached at init would still point at
    // the source's view model. Kept while it is the same instance (each lookup mints host
    // handles: 13 a frame).
    bind(): bool {
        let c = this.ctx;
        if (c == null) return false;
        let vm = c.viewModel();
        if (vm == null) return false;
        let bound = this.bound;
        if (bound != null && vm.equals(bound)) {
            vm.release();
            return this.text != null && this.active != null;
        }
        this.bound = vm;
        this.text = vm.getString("commText");
        this.active = vm.getBoolean("commActive");
        this.seconds = vm.getNumber("commSeconds");
        this.typed = vm.getNumber("commTyped");
        this.progress = vm.getNumber("commProgress");
        this.talking = vm.getBoolean("commTalking");
        this.page = vm.getString("commPage");
        this.more = vm.getNumber("commMore");
        this.cols = vm.getNumber("commCols");
        this.rows = vm.getNumber("commRows");
        this.done = vm.getNumber("commDone");
        this.plateEm = vm.getNumber("commPlateEm");
        return this.text != null && this.active != null;
    }

    schedule(s: string, lead: f64): void {
        let chars = codepoints(s);
        let n = chars.length - 1;
        let cols: f64 = 0;
        let cp = this.cols;
        if (cp != null) cols = Math.floor(cp.value * 4 + 0.5) / 4;
        let rows: f64 = 1;
        let rp = this.rows;
        if (rp != null) rows = lmax(1, Math.floor(rp.value + 0.5));
        this.lastCols = cols;
        this.lastRows = rows;
        this.lead = lead;
        this.chars = chars;
        let acc = new Array<f64>(n + 2);
        for (let i = 1; i <= n; i++) acc[i + 1] = acc[i] + advOf(chars[i]);
        this.acc = acc;
        let least = paginate(chars, cols, rows);
        let pa = PAGINATE_1;
        let pb = PAGINATE_2;
        this.pageA = pa;
        this.pageB = pb;
        let npb = pb.length - 1;
        let turn = new Set<i32>();
        for (let p = 1; p <= npb - 1; p++) turn.add(pb[p]);
        let holds = new Array<f64>(n + 1);
        let total: f64 = 0;
        for (let i = 1; i <= n; i++) {
            let h = turn.has(i) ? 0.0 : holdAfter(chars[i], i < n ? chars[i + 1] : "");
            holds[i] = h;
            total += h;
        }
        // budget: the line's seconds when the game says, else the rule its lines follow (~1.4 s + n / 33)
        let secs: f64 = 0;
        let sp = this.seconds;
        if (sp != null) secs = sp.value;
        // (the lead-in counts; ~0.45 s of the full line stays up at the end)
        let est = secs > 0 ? secs : 1.3 + <f64>n / 33;
        let budget = lmax(0.6, est - 0.45 - lead);
        // page turns come out of the same budget: each typed-out page holds a moment (the last one too, on top of
        // the line's own hold), never out of the typing at READ_CPS with its holds squeezed (the core's readNeed, which
        // adds PAGE_MIN a turn). Short of time the last page's hold goes first, then the turns shorten (below PAGE_MIN
        // only on a line paced too short for its pages); only a line too short even for that types faster
        // (the line is timed for the fewest pages, `least`, as the core counts them: a page added to avoid a stranded
        // word shares those turns' holds, so it never takes longer to read)
        let pageHold: f64 = 0;
        let turns = least - 1;
        if (turns > 0) {
            let floor = <f64>n / READ_CPS;
            let ph = lclamp(budget * 0.1, PAGE_MIN, PAGE_HOLD);
            let spare = lmax(0, budget - lmin(floor + total, floor / 0.75));
            pageHold = lmin(ph, spare / turns);
            budget = lmax(0.6, budget - pageHold * turns - lclamp(spare - pageHold * turns, 0, ph));
            pageHold = (pageHold * turns) / lmax(1, <f64>(npb - 1));
        }
        let typeTime = <f64>n / RATE;
        if (typeTime + total > budget) {
            // squeeze the pauses first (to at most a quarter of the budget), then type faster
            let k = lmin(1, (budget * 0.25) / lmax(total, 0.001));
            for (let i = 1; i <= n; i++) holds[i] *= k;
            total *= k;
            typeTime = lmax(budget - total, <f64>n / 45);
        }
        let tv = turn.values();
        for (let i = 0; i < tv.length; i++) holds[tv[i]] = pageHold;
        let step = typeTime / lmax(<f64>n, 1);
        let times = new Array<f64>(n + 1);
        let quiet: Array<f64> = [0.0];
        let t = lead;
        for (let i = 1; i <= n; i++) {
            times[i] = t;
            t += step;
            if (holds[i] >= 0.1) {
                quiet.push(t + 0.02);
                quiet.push(t + holds[i] - 0.03);
            }
            t += holds[i];
        }
        this.times = times;
        this.quiet = quiet;
        this.n = n;
        this.step = step;
        this.t = 0;
        this.stop = t;
    }

    write(shown: f64, talk: bool): void {
        this.shown = shown;
        this.talk = talk;
        // the page the newest character is on, and the characters out within it
        let pa = this.pageA;
        let pb = this.pageB;
        let npb = pb.length - 1;
        let pg = 1;
        while (pg < npb && shown < DONE && shown > <f64>pb[pg]) pg += 1;
        if (shown >= DONE) pg = npb;
        let a = pg < pa.length ? pa[pg] : 1;
        let b = pg < pb.length ? pb[pg] : 0;
        let inPage = shown;
        let more: f64 = 0;
        if (npb > 1) {
            inPage = shown >= DONE || shown >= <f64>b ? DONE : lmax(0, shown - <f64>(a - 1));
            if (pg < npb) more = inPage >= DONE ? 1.0 : 0.5;
        }
        let text = this.last;
        if (npb > 1) text = joinRange(this.chars, a, b);
        let pp = this.page;
        if (pp != null && (text != this.shownPage || pp.value != text)) {
            pp.value = text;
            this.shownPage = text;
        }
        let mp = this.more;
        if (mp != null && mp.value != more) mp.value = more;
        let p = this.typed;
        if (p != null && p.value != inPage) p.value = inPage;
        let wp = this.plateEm;
        if (wp != null) {
            // the typed part of the page in em (the phone plate hugs it)
            let em: f64 = 0;
            let acc = this.acc;
            if (this.lastCols > 0 && acc.length - 1 > b) {
                let len = b - a + 1;
                let c = inPage >= DONE ? <f64>len : lclamp(inPage, 0, <f64>len);
                let w = <i32>Math.floor(c);
                em = acc[a + w] - acc[a];
                if (w < len) em += (c - <f64>w) * (acc[a + w + 1] - acc[a + w]);
                em = Math.floor(em * 100 + 0.5) / 100;
            }
            if (wp.value != em) wp.value = em;
        }
        let dp = this.done;
        let whole = shown >= DONE ? <f64>this.n : shown;
        if (dp != null && dp.value != whole) dp.value = whole;
        let q = this.progress;
        if (q != null) {
            let v = shown >= DONE ? 1.0 : this.n > 0 ? lmin(1, shown / <f64>this.n) : 1.0;
            if (q.value != v) q.value = v;
        }
        let tk = this.talking;
        if (tk != null && tk.value != talk) tk.value = talk;
    }

    override init(context: Context): bool {
        this.ctx = context;
        return true;
    }

    override advance(seconds: f64): bool {
        if (!this.bind()) return true;
        let tp = this.text;
        let ap = this.active;
        if (tp == null || ap == null) return true;
        let s = tp.value;
        let on = ap.value;
        if (on && !this.wasActive) {
            this.schedule(s, LEAD_OPEN);
            this.openAge = 0;
        } else if (on && s != this.last) {
            this.schedule(s, this.openAge < 0.3 ? LEAD_OPEN : LEAD_NEXT);
        }
        this.last = s;
        this.wasActive = on;
        let cp = this.cols;
        let rp = this.rows;
        if (
            on &&
            ((cp != null && Math.floor(cp.value * 4 + 0.5) / 4 != this.lastCols) ||
                (rp != null && lmax(1, Math.floor(rp.value + 0.5)) != this.lastRows))
        ) {
            // the plate changed (layout settling, rotation): page again, same clock
            let t0 = this.t;
            this.schedule(s, this.lead);
            this.t = t0;
        }
        if (!on) {
            this.write(this.shown, false);
            return true;
        }
        this.openAge += seconds;
        this.t += seconds;
        let t = this.t;
        let times = this.times;
        let n = this.n;
        // characters out so far (the reveal range fades the next one in)
        let k = 0;
        let lo = 1;
        let hi = n;
        while (lo <= hi) {
            let mid = (lo + hi) >> 1; // (lo + hi >= 2: floor division)
            if (times[mid] <= t) {
                k = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        let shown: f64 = 0;
        if (k >= n && n > 0 && t >= times[n] + this.step) {
            shown = DONE;
        } else if (k > 0) {
            shown = <f64>(k - 1) + lclamp((t - times[k]) / this.step, 0, 1);
        }
        let talk = t >= (n > 0 ? times[1] : 0.0) && k < n;
        if (talk) {
            let qs = this.quiet;
            let nq = qs.length - 1;
            for (let i = 1; i <= nq; i += 2) {
                if (t >= qs[i] && t < qs[i + 1]) {
                    talk = false;
                    break;
                }
            }
        }
        this.write(shown, talk);
        return true;
    }
}
