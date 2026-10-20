// Port of src/game/popups.luau. World-space score popups: a pool of Popup artboard instances.
// Each with its own sprite (canvas), that pop in at a hit point, rise and fade. Drawn as
// overlay billboards at a steady screen size (never ballooning up close),
// kept inside the open band of the screen, off the HUD's panels (route
// list, comms, score, gauges), the alert slot while it shows, the hero safe
// zone and the hero, the boss weak point (DIRECTION #16; her whole hull
// while she is revealed), the enemies the game feeds (foe) and each
// other, on every frame of a move too; in portrait flight a kill chip docks
// under the score line first (the enemies' band is narrow there); the same label
// within 0.4 s merges into one chip ('RETURNED! x3  +150'), so do rings
// ('RING x4  +700') and nearby kills ('+600  x2').
//
// Port: optional numbers are NaN (nil); comms() sets COMMS_1 (bool) ..
// COMMS_5. Lists 1-based (Popups.list, foes as Luau). The internal
// multi-returns go through module globals (ST_*, CR_*, ED_*, PL_*, ...),
// copied at once. rects / pads / fromIn are 0-based here (Luau offsets + 1).
import { ViewModel } from "rive/data";
import { Artboard } from "rive/artboard";
import { format, FormatArg } from "rive/format";
import * as mathx from "../lib/mathx";
import * as R from "../render/renderer";
import * as vmx from "./vm";
import * as camera from "./camera";
import { Enemy } from "./ai_types";
import { HUGE, lmin, lmax, lstr, opt, mod, lsort } from "../lib/compat";

// The Popup view model (Data.Popup): names the artboard input's view model
// (`@input popup: Artboard<Popup>? = null` on the game Layout).
export class Popup extends ViewModel {
    constructor(handle: u32) {
        super(handle);
    }
}

export const POOL: f64 = 4;
export const LIFE: f64 = 1.15;

export class Pop {
    active: bool = false;
    age: f64 = 0;
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    rise: f64 = 3;
    scale: f64 = 1;
    art: Artboard<Popup>? = null;
    bag: vmx.Bag? = null;
    sprite: R.Sprite? = null;
    serial: f64 = 0;
    kind: string = "score";
    pts: f64 = 0; // accumulated points (merged kill popups)
    hits: f64 = 0;
    label: string = ""; // 'RETURNED!' for 'RETURNED! +50' ('' = no label)
    chars: f64 = 0; // text length (its drawn width)
    placed: bool = false; // ou / ov hold a placement
    ou: f64 = 0; // eased screen offset from its own spot (panel / stack dodge)
    ov: f64 = 0;
    hopT: f64 = 10; // seconds since it last hopped to a free spot (re-pops)
    hops: f64 = 0; // hops so far (one at most; swallowed again, it retires)
    zoned: bool = false; // it may sit on the hero zone (its last resort) this frame
    wide: bool = false; // no room in the open band: it keeps to the wider one
    dw: f64 = 0; // half extents as drawn last frame (0: not drawn)
    dh: f64 = 0;
    cw: f64 = HUGE; // the most it is drawn at once it had to shrink (else huge)
    ch: f64 = HUGE;
    su: f64 = 0; // this frame's screen centre and half extents (stacking)
    sv: f64 = 0;
    hw: f64 = 0;
    hh: f64 = 0;
    nx: f64 = 0; // last projected spot (NDC), held once the anchor passes the lens
    ny: f64 = 0;
    seen: bool = false;
    value: f64 = 0; // points it shows (a crowd drops the chip worth least, not the newest)
    bumped: bool = false; // it already retired a lesser chip to find room (once)
    dock: bool = false; // portrait: it sits in the column under the score line
    foeOk: bool = false; // it had to go over an enemy: enemies steer its spot, never shove it
}

// What the popups keep clear of this frame (written by the game):
// touch = the touch overlay is up (the HUD's gauges move), fight = a boss
// fight (the alert slot drops under the boss stack), alert = the alert slot
// shows (a banner or warning), route = Hud.routeK (0 tucked .. 1 the route
// list unfolded), bossU / bossV = the boss weak point on screen (-1 none),
// hullU0 .. hullV1 = the boss's hull on screen while she is revealed (her
// spawn through her poster; hullU1 <= hullU0: none),
// heroU / heroV / heroHu / heroHv = the hero's box on screen (centre, half
// extents; heroU -1 hidden), yieldK / bannerK / fightK = Hud.alertK /
// bannerK / fightK (the portrait score and comms step down under the slot),
// hudPx / legScoreDy / legBoxH / legBoxW / legRoute = the HUD's legibility
// growth (hud.md Legibility floors: the panels grow on small screens).
export class Layout {
    touch: bool = false;
    school: bool = false; // the flight school (Game.trainActive): the ticket, no score / route
    fight: bool = false;
    alert: bool = false;
    route: f64 = 0;
    bossU: f64 = -1;
    bossV: f64 = -1;
    hullU0: f64 = -1;
    hullV0: f64 = -1;
    hullU1: f64 = -1;
    hullV1: f64 = -1;
    heroU: f64 = -1;
    heroV: f64 = -1;
    heroHu: f64 = 0;
    heroHv: f64 = 0;
    yieldK: f64 = 0;
    bannerK: f64 = 1;
    fightK: f64 = 0;
    hudPx: f64 = 1;
    legScoreDy: f64 = 0;
    legBoxH: f64 = 190;
    legBoxW: f64 = 452;
    legRoute: f64 = 1;
    commCols: f64 = 0; // > 0: the phone comms (one paged line, hud.md Phone comms)
    chainK: f64 = 0; // (unread: the chain count rides the portrait score line)
}

export const MAX_FOES: f64 = 24;
const FOE_K: f64 = 1.3; // an enemy's drawn half extent per collision radius (wings, props)

// alertK: the landscape alert slot's keep-out, eased in / out with the slot;
// hud: the Hud view model (its published legScoreLine, bannerStep,
// objectiveTrack, viewW / viewH); foes: this frame's enemies (x, y, z,
// radius; nFoes of them, cleared by draw; 1-based)
export class Popups {
    list: Array<Pop> = new Array<Pop>(1); // 1-based
    serial: f64 = 0;
    dt: f64 = 1.0 / 60.0;
    layout: Layout = new Layout();
    alertK: f64 = 0;
    hud: vmx.Bag? = null;
    foes: Array<f64> = new Array<f64>(<i32>MAX_FOES * 4 + 1);
    nFoes: f64 = 0;
}

export function create(): Popups {
    return new Popups();
}

// A live enemy this frame (world centre, radius in m): chips keep off it.
// Fed before draw, which clears the list.
export function foe(P: Popups, x: f64, y: f64, z: f64, radius: f64): void {
    let n = P.nFoes;
    if (n >= MAX_FOES) {
        return;
    }
    let f = P.foes, o = <i32>n * 4;
    f[o + 1] = x;
    f[o + 2] = y;
    f[o + 3] = z;
    f[o + 4] = radius;
    P.nFoes = n + 1;
}

// This frame's live enemies from the game's list (x, y, z, radius, alive,
// part, hidden): the MAX_FOES nearest ahead of the lens `cam`, a boss's
// parts left out (her hull is its own keep-out). QA RP-6: RETURNED! and
// RING x3 sat on biplanes and drone chains: nothing fed them.
const feedD: Array<f64> = [0.0]; // 1-based
const feedE: Array<Enemy> = new Array<Enemy>(1);
const feedK: Array<i32> = [0];
function feedNearer(a: i32, b: i32): bool {
    return feedD[a] < feedD[b];
}
// (a craft closer than FEED_NEAR m ahead of the lens is faded at it, or
// behind it: no keep-out, its box would fill the screen)
const FEED_NEAR: f64 = 6;
// list: 1-based (enemies.list)
export function feed(P: Popups, list: Array<Enemy>, cam: R.Camera): void {
    let eye = cam.eye;
    let f = mathx.norm(cam.target - eye);
    let n = 0;
    for (let i = 1; i < list.length; i++) {
        let e = list[i];
        if (e.alive && !e.part && !e.hidden) {
            let z = (e.x - <f64>eye.x) * <f64>f.x + (e.y - <f64>eye.y) * <f64>f.y + (e.z - <f64>eye.z) * <f64>f.z;
            if (z > FEED_NEAR) {
                n += 1;
                if (feedE.length <= n) {
                    feedE.push(e);
                    feedD.push(z);
                } else {
                    feedE[n] = e;
                    feedD[n] = z;
                }
            }
        }
    }
    if (<f64>n <= MAX_FOES) {
        for (let k = 1; k <= n; k++) {
            let e = feedE[k];
            foe(P, e.x, e.y, e.z, e.radius);
        }
    } else {
        feedK.length = 1;
        for (let k = 1; k <= n; k++) {
            feedK.push(k);
        }
        lsort<i32>(feedK, n, feedNearer);
        for (let k = 1; k <= <i32>MAX_FOES; k++) {
            let e = feedE[feedK[k]];
            foe(P, e.x, e.y, e.z, e.radius);
        }
    }
    // (table.clear(feedE): stale rows past n are never read)
}

// (the renderer's Sprite.art is a plain Artboard; Artboard<Popup> does not convert)
unsafe function asPopupVm(vm: ViewModel): Popup {
    return changetype<Popup>(vm);
}
unsafe function plainArt(a: Artboard<Popup>): Artboard {
    return changetype<Artboard>(a);
}

export function attach(P: Popups, r: R.Gfx, input: Artboard<Popup>): void {
    let ha = r.hudArt;
    if (ha != null) {
        let d = ha.data();
        if (d != null) P.hud = vmx.bag(d);
    }
    for (let i = 1; i <= <i32>POOL; i++) {
        let vm = ViewModel.create("Popup");
        // (the same object, typed: a second wrapper of the handle would own it
        // too, and its collection released the view model under the bag)
        let art = input.instance(asPopupVm(vm));
        let p = new Pop();
        p.art = art;
        p.bag = vmx.bag(vm);
        p.sprite = R.createSprite(r, "popup" + i.toString(), plainArt(art), 768, 240, 1, false, true);
        P.list.push(p);
    }
}

// Lua pattern helpers (ASCII): digits at [i, j) as a number
function isDigit(c: i32): bool {
    return c >= 48 && c <= 57;
}

function digitsAt(s: string, i: i32): i32 {
    let j = i;
    while (j < s.length && isDigit(s.charCodeAt(j))) j++;
    return j;
}

function numOf(s: string, i: i32, j: i32): f64 {
    let v = 0.0;
    for (let k = i; k < j; k++) v = v * 10 + <f64>(s.charCodeAt(k) - 48);
    return v;
}

// string.match(s, '%+(%d+)'): the first '+' with digits after it (NaN: nil)
function matchPlusNum(s: string): f64 {
    for (let i = 0; i < s.length; i++) {
        if (s.charCodeAt(i) == 43) {
            let j = digitsAt(s, i + 1);
            if (j > i + 1) return numOf(s, i + 1, j);
        }
    }
    return NaN;
}

// string.match(s, '%+(%d+)$') (NaN: nil)
function matchPlusNumEnd(s: string): f64 {
    let i = s.lastIndexOf("+");
    if (i < 0) return NaN;
    let j = digitsAt(s, i + 1);
    if (j == i + 1 || j != s.length) return NaN;
    return numOf(s, i + 1, j);
}

// string.match(s, 'x(%d+)') (NaN: nil)
function matchXNum(s: string): f64 {
    for (let i = 0; i < s.length; i++) {
        if (s.charCodeAt(i) == 120) {
            let j = digitsAt(s, i + 1);
            if (j > i + 1) return numOf(s, i + 1, j);
        }
    }
    return NaN;
}

// string.match(s, '^(%u[%u !]-) %+(%d+)$'): MATCH_LABEL (null: no match), MATCH_N
let MATCH_LABEL: string? = null;
let MATCH_N: f64 = 0;
function matchLabel(s: string): void {
    MATCH_LABEL = null;
    let i = s.lastIndexOf(" +");
    if (i < 1) return;
    let j = digitsAt(s, i + 2);
    if (j == i + 2 || j != s.length) return;
    let c0 = s.charCodeAt(0);
    if (c0 < 65 || c0 > 90) return;
    for (let k = 1; k < i; k++) {
        let c = s.charCodeAt(k);
        if (!((c >= 65 && c <= 90) || c == 32 || c == 33)) return;
    }
    MATCH_LABEL = s.substring(0, i);
    MATCH_N = numOf(s, i + 2, j);
}

// Points a chip's text shows ('RING x4  +700' 700, 'HIT!' 0).
function textValue(text: string): f64 {
    return opt(matchPlusNum(text), 0);
}

function fmtLabel(label: string, hits: f64, pts: f64): string {
    return format("%s x%d  +%d", [FormatArg.string(label), FormatArg.number(hits), FormatArg.number(pts)]);
}

function fmtRing(chain: f64, pts: f64): string {
    return format("RING x%d  +%d", [FormatArg.number(chain), FormatArg.number(pts)]);
}

function fmtKill(pts: f64, hits: f64): string {
    return format("+%d  x%d", [FormatArg.number(pts), FormatArg.number(hits)]);
}

// kind: 'score' | 'ring' | 'kill' | 'bonus'
// vx/vy/vz: world velocity (e.g. the pilot's, so the popup rides along). NaN = nil.
export function spawn(P: Popups, text: string, kind: string, x: f64, y: f64, z: f64,
                      scale: f64 = NaN, vx: f64 = NaN, vy: f64 = NaN, vz: f64 = NaN): void {
    if (P.list.length - 1 == 0) {
        return;
    }
    // 'LABEL +N' (a stamp may end in '!'): the same label again inside
    // 0.4 s merges into one chip
    matchLabel(text);
    let label = MATCH_LABEL;
    let n = MATCH_N;
    let list = P.list;
    if (label != null) {
        let pts = n;
        for (let i = 1; i < list.length; i++) {
            let q = list[i];
            if (q.active && q.label == label && q.age < 0.4) {
                q.hits += 1;
                q.pts += pts;
                q.value = q.pts;
                q.age = lmin(q.age, 0.12);
                let t2 = fmtLabel(label, q.hits, q.pts);
                q.chars = t2.length;
                let b = q.bag;
                if (b != null) {
                    vmx.str(b, "text", t2);
                }
                return;
            }
        }
    }
    // rings threaded together: one chip with the latest chain count and the
    // summed points ('RING x4  +700'); a chain rides one chip while it is
    // still up (rings ~0.5 s apart kept spawning new chips into a full pool)
    let ringPts = kind == "ring" ? matchPlusNumEnd(text) : NaN;
    if (!isNaN(ringPts)) {
        for (let i = 1; i < list.length; i++) {
            let q = list[i];
            if (q.active && q.kind == "ring" && q.age < 0.8) {
                q.pts += ringPts;
                q.value = q.pts;
                q.age = lmin(q.age, 0.12);
                let chain = opt(matchXNum(text), 1);
                let t2 = chain >= 2 ? fmtRing(chain, q.pts) : "+" + lstr(q.pts);
                q.chars = t2.length;
                let b = q.bag;
                if (b != null) {
                    vmx.str(b, "text", t2);
                }
                return;
            }
        }
    }
    // free slot, else the chip worth least (a fading one, in its last
    // 0.2 s, counts as worth nothing; ties: the oldest) makes way for a
    // newcomer worth more, or worth as much once it is past its pop
    // (0.4 s); else the newcomer is dropped (the score counts either way;
    // QA: a burst dropped 'RING x4  +700' for being the newest, then for
    // a 'HIT!' once it was 0.4 s old)
    let value = textValue(text);
    let pick: Pop? = null;
    let low: Pop? = null;
    let lowV = HUGE;
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        if (!p.active) {
            pick = p;
            break;
        }
        let v = p.age > LIFE - 0.2 ? -1 : p.value;
        if (low == null || v < lowV || (v == lowV && p.age > low.age)) {
            low = p;
            lowV = v;
        }
    }
    if (pick == null && low != null && (lowV < value || (lowV == value && low.age >= 0.4))) {
        pick = low;
    }
    if (pick == null) {
        return;
    }
    let p = pick;
    P.serial += 1;
    p.active = true;
    p.age = 0;
    p.x = x;
    p.y = y;
    p.z = z;
    p.vx = opt(vx, 0);
    p.vy = opt(vy, 0);
    p.vz = opt(vz, 0);
    p.rise = kind == "bonus" ? 2 : 3.2;
    p.scale = !isNaN(scale) ? scale : (kind == "bonus" ? 1.25 : 1);
    p.serial = P.serial;
    p.kind = kind;
    p.pts = 0;
    p.hits = 0;
    p.label = "";
    p.chars = text.length;
    p.placed = false;
    p.foeOk = false;
    p.ou = 0;
    p.ov = 0;
    p.hopT = 10;
    p.hops = 0;
    p.zoned = false;
    p.wide = false;
    p.dw = 0;
    p.dh = 0;
    p.cw = HUGE;
    p.ch = HUGE;
    p.seen = false;
    p.value = value;
    p.bumped = false;
    p.dock = false;
    if (label != null) {
        p.label = label;
        p.pts = n;
        p.hits = 1;
    } else if (!isNaN(ringPts)) {
        p.pts = ringPts;
        p.hits = opt(matchXNum(text), 1);
    }
    let b = p.bag;
    if (b != null) {
        vmx.setEnum(b, "kind", kind);
        vmx.str(b, "text", text);
        // optional entrance trigger on the Popup view model
        if (b.vm.getTrigger("pop") != null) {
            vmx.fire(b, "pop");
        }
    }
}

// Kill points: kills landing within a short window near each other merge into
// one popup that counts up ("+600  x3"), so a wave stays legible.
export function kill(P: Popups, pts: f64, combo: f64, x: f64, y: f64, z: f64): void {
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        if (p.active && p.kind == "kill" && p.age < 0.35) {
            let dx = p.x - x, dy = p.y - y, dz = p.z - z;
            if (dx * dx + dy * dy + dz * dz < 60 * 60) {
                p.pts += pts;
                p.hits += 1;
                p.value = p.pts;
                p.age = lmin(p.age, 0.12);
                p.scale = lmin(1.2, 1 + p.hits * 0.05);
                let t2 = fmtKill(p.pts, p.hits);
                p.chars = t2.length;
                let b = p.bag;
                if (b != null) {
                    vmx.str(b, "text", t2);
                }
                return;
            }
        }
    }
    let text = combo >= 2 ? fmtKill(pts, combo) : "+" + lstr(pts);
    let s0 = P.serial;
    spawn(P, text, "kill", x, y, z);
    // the newest popup is the one just spawned (if it was)
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        if (P.serial != s0 && p.serial == P.serial) {
            p.pts = pts;
            p.hits = 1;
            p.value = pts;
        }
    }
}

export function clear(P: Popups): void {
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        p.active = false;
        p.dw = 0;
        p.dh = 0;
    }
}

// (the instance last updated: comms reads its layout)
let cur: Popups? = null;

export function update(P: Popups, dt: f64): void {
    cur = P;
    P.dt = dt;
    P.alertK = mathx.damp(P.alertK, P.layout.alert ? 1 : 0, 12, dt);
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        if (p.active) {
            p.age += dt;
            p.hopT += dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
            p.z += p.vz * dt;
            if (p.age >= LIFE) {
                p.active = false;
            } else {
                let a = p.art;
                if (a != null) {
                    a.advance(dt);
                }
            }
        }
    }
}

// HUD panels in screen fractions (x0, y0, x1, y1; y down), from the HUD's
// stage placements (the Hud artboard's Stage): the Stage is 1920 x
// 1080 at 16:9, W x 1080 wider, 1920 x 1920 / aspect down to 1:1, 1920 *
// aspect x 1920 in portrait (1080 x 1080 / aspect below 9:16, plus the 5.5 %
// notch inset on tall phones). Then the hero safe zone (DIRECTION #16), the
// hero and the boss weak point; the popups already placed this frame are
// appended. Refilled every frame. (0-based: rect i at [4i, 4i + 3])
const rects: Array<f64> = new Array<f64>(1024);
// extra half extents (u, v) of the moving keep-outs (the hero, the boss
// point) for picking a spot, so a chip settles with slack and is not
// swallowed the moment they drift; the per-frame moves check the bare rects
// (0-based: rect i at [2i, 2i + 1])
const pads: Array<f64> = new Array<f64>(512);
let nRects: i32 = 0;
let zoneIdx: i32 = -1; // the hero safe zone's rect (the last resort may overlap it)
// the HUD's published layout this frame (read in draw): the portrait time row
// under the score (legScoreLine 0..1), a banner's step under a kept objective
// track (bannerStep, stage units, while objectiveTrack), the window in points
let hudLine: f64 = 0, hudStep: f64 = 0, hudVW: f64 = 0, hudVH: f64 = 0;
// portrait flight: the dock column under the score line (screen fractions; dV1
// < dV0: none this frame)
let dU0: f64 = 0, dU1: f64 = 0, dV0: f64 = 1, dV1: f64 = 0;
const DOCK_V1: f64 = 0.33; // its foot (above the hero zone): the enemies fly from ~0.28 down
// the portrait score slab's drawn foot under its flat one (screen fraction; hud.md: keep-outs take the drawn
// rect, flat + 0.012; measured at 1080 x 1920 under a banner: flat 0.201, digits 0.208, slab 0.2135)
const SCORE_LOW: f64 = 0.012;
const PAD: f64 = 0.3; // of the hero's / boss point's half extents
const HERO_HARD: f64 = 0.9; // a drawn chip may drift to 0.9 of the hero's box (~1.53 m)

function addRaw(x0: f64, y0: f64, x1: f64, y1: f64): void {
    let o = nRects * 4;
    if (o + 4 > rects.length) {
        rects.length = o + 256;
        pads.length = (o + 256) / 2;
    }
    rects[o] = x0;
    rects[o + 1] = y0;
    rects[o + 2] = x1;
    rects[o + 3] = y1;
    pads[nRects * 2] = 0;
    pads[nRects * 2 + 1] = 0;
    nRects += 1;
}

function addRect(x0: f64, y0: f64, x1: f64, y1: f64, W: f64, H: f64, inset: f64): void {
    addRaw(x0 / W, inset + (y0 / H) * (1 - inset), x1 / W, inset + (y1 / H) * (1 - inset));
}

// A portrait panel placed in units from the stage's top: the tall phones' notch inset moves the stage down, its
// scale unchanged (hud.md Tall phones: v = inset + y / H; addRect is for places in percent of the stage)
function addTop(x0: f64, y0: f64, x1: f64, y1: f64, W: f64, H: f64, inset: f64): void {
    addRaw(x0 / W, inset + y0 / H, x1 / W, inset + y1 / H);
}

// The comms window as drawn: the visor's inward wrap draws the landscape
// window nearer the middle than its flat stage place (452 x 190 at right
// 4.8 %, top 330): its left edge sits at 0.5 + k x its flat offset from the
// centre, k measured in game from the glass edge (1018 / 1342 / 1921 px at
// 1440x1080 / 1920x1080 / 2560x1080, flat 1032 / 1376 / 1985), less ~8 px
// of glow. Portrait: within ~2 px of the flat place, the bottom ~7 px lower.
function commsK(a: f64): f64 {
    if (a <= 16.0 / 9.0) {
        return mathx.lerp(0.955, 0.919, mathx.saturate((a - 4.0 / 3.0) / (16.0 / 9.0 - 4.0 / 3.0)));
    }
    return mathx.lerp(0.919, 0.909, mathx.saturate((a - 16.0 / 9.0) / (2.37 - 16.0 / 9.0)));
}

// The landscape flight school ticket's band foot (screen fraction): s_train
// k_expr's scale as the HUD mirrors it, 180 k points under 0.105 (0: no window)
function schoolBand(): f64 {
    let w = hudVW, h = hudVH;
    let tk = lmin(lmin(1.2, lmax(0.7, lmin(w, h) / 1080)), 0.75 / 800 * w - 0.03);
    return (0.105 + 180 * tk / lmax(1, h)) * lmin(1, h);
}

// The stage for this aspect (units, ST_W x ST_H) and the tall phones' notch inset (ST_I, screen fraction)
let ST_W: f64 = 0, ST_H: f64 = 0, ST_I: f64 = 0;
function stage(a: f64): void {
    if (a >= 1) {
        if (a >= 16.0 / 9.0) {
            ST_W = 1080 * a;
            ST_H = 1080;
            ST_I = 0;
            return;
        }
        ST_W = 1920;
        ST_H = 1920 / a;
        ST_I = 0;
        return;
    }
    ST_W = a >= 0.5625 ? 1920 * a : 1080;
    ST_H = a >= 0.5625 ? 1920 : 1080 / a;
    ST_I = 0.055 * mathx.saturate((0.54 - a) / 0.04);
}

// The comms window (CR_0..CR_3: x0, y0, x1, y1; y down) and its right edge in stage units (CR_4: the portrait
// dock starts past it). Landscape: where the visor draws it, grown by the legibility floors, the school's
// stepped down to max(330, 0.28 H). Portrait: under the route tab, in fights stepped down under the slot (hud.md
// Portrait yield; phones: one paged line, -35 / +18 under a warning / banner, 24 units clear under the plate:
// chips sat flush on it); the school's under the ticket (HUD: top max(350, (0.21 - 0.012 n) H), k keeps the
// drawn glass (its legible box) over 0.34 H; mapped as inset + y / H, +0.012 for the low draw)
let CR_0: f64 = 0, CR_1: f64 = 0, CR_2: f64 = 0, CR_3: f64 = 0, CR_4: f64 = 0;
function commsRect(a: f64, L: Layout): void {
    stage(a);
    let W = ST_W, H = ST_H, inset = ST_I;
    if (a >= 1) {
        let y0 = (L.school ? lmax(330, H * 0.28) : 330) + L.legScoreDy;
        let x1 = W * 0.952;
        CR_0 = 0.5 + ((x1 - 452) / W - 0.5) * commsK(a) - 0.004;
        CR_1 = y0 / H;
        CR_2 = x1 / W;
        CR_3 = (y0 + L.legBoxH) / H;
        CR_4 = x1;
        return;
    }
    if (L.school) {
        let n = inset / 0.055;
        let top = lmax(350, (0.21 - 0.012 * n) * H);
        let bh = L.legBoxH;
        let k = mathx.clamp(((0.328 - 0.055 * n) * H - top) / bh, 0.85, 1);
        let r = 40 + L.legBoxW * k;
        CR_0 = 40 / W;
        CR_1 = inset + top / H;
        CR_2 = r / W;
        CR_3 = inset + (top + bh * k) / H + 0.012;
        CR_4 = r;
        return;
    }
    let bk = L.bannerK;
    let dyC = L.yieldK * L.fightK * (L.commCols > 0 ? -35 + 53 * bk : 20 + 38 * bk) + 116 * (L.legRoute - 1);
    let cr = 40 + L.legBoxW, cb = 360 + dyC + L.legBoxH + (L.commCols > 0 ? 24 : 0);
    CR_0 = 40 / W;
    CR_1 = inset + (350 + dyC) / H;
    CR_2 = cr / W;
    CR_3 = inset + cb / H;
    CR_4 = cr;
}

// Read-only, for the wingmen (they keep off it too): a line on air (Hud.commActive) and the comms window
// (x0, y0, x1, y1; y down) for the layout last updated, at the HUD's window (viewW / viewH; unknown: none).
// Multi-return: COMMS_1 (bool) .. COMMS_5; returns COMMS_1.
export let COMMS_1: bool = false;
export let COMMS_2: f64 = 0;
export let COMMS_3: f64 = 0;
export let COMMS_4: f64 = 0;
export let COMMS_5: f64 = 0;
export function comms(): bool {
    COMMS_1 = false;
    COMMS_2 = 0;
    COMMS_3 = 0;
    COMMS_4 = 0;
    COMMS_5 = 0;
    let P = cur;
    if (P == null) {
        return false;
    }
    let hb = P.hud;
    if (hb == null) {
        return false;
    }
    let w = opt(vmx.optNum(hb, "viewW"), 0), h = opt(vmx.optNum(hb, "viewH"), 0);
    if (w <= 0 || h <= 0) {
        return false;
    }
    commsRect(lmax(w / h, 0.2), P.layout);
    COMMS_1 = vmx.optBool(hb, "commActive");
    COMMS_2 = CR_0;
    COMMS_3 = CR_1;
    COMMS_4 = CR_2;
    COMMS_5 = CR_3;
    return COMMS_1;
}

function hudRects(aspect: f64, L: Layout, alertK: f64): void {
    nRects = 0;
    dV0 = 1;
    dV1 = 0;
    let a = lmax(aspect, 0.2);
    stage(a);
    let W = ST_W, H = ST_H, inset = ST_I;
    if (a >= 1) {
        // route tab (+ the list while unfolded), score, comms (grown by the HUD's legibility floors); the
        // school holds the route and score out and has its lesson ticket (centred, top 0.10 .. 0.27, 40 %
        // wide, 760..1100 units; the HUD steps the shield tab left under the ticket band and the comms down
        // while it runs, still under the score block's growth)
        let lr = L.legRoute, ds = L.legScoreDy;
        if (L.school) {
            // (short windows: the ticket's band ends lower and the HUD drops the shield tab under it)
            let band = schoolBand();
            let hw = mathx.clamp(W * 0.2, 380, 550);
            addRect(W * 0.5 - hw, H * 0.1, W * 0.5 + hw, H * lmax(0.27, band), W, H, 0);
            addRect(90, H * lmax(0.28, band), 622, H * lmax(0.28, band) + 77, W, H, 0);
        } else {
            addRect(90, 112, 90 + 356 * lr, 112 + (96 + 326 * mathx.saturate(L.route)) * lr, W, H, 0);
            if (L.route > 0.01) {
                // a spot is picked clear of the whole list while it unfolds
                pads[nRects * 2 - 1] = 326 * (1 - mathx.saturate(L.route)) * lr / H;
            }
            let sr = L.touch ? 0.898 : 0.952;
            addRect(W * sr - 440, 56, W * sr, 306 + ds, W, H, 0);
        }
        commsRect(a, L);
        addRaw(CR_0, CR_1, CR_2, CR_3);
        // gauges: bottom corners, or stepped in over the touch controls
        // (up to the SKIM chip over the boost slab and the NOVA / LOCK strip
        // over heat / altitude, measured in game)
        if (L.touch) {
            addRect(W * 0.275 + 11.5, H * 0.96 - 246, W * 0.275 + 334, H * 0.96, W, H, 0);
            addRect(W * 0.705 - 403, H * 0.96 - 208, W * 0.705, H * 0.96, W, H, 0);
            // the touch overlay (screens TouchShellL: the stick contained in
            // 25% x 42% at left 1.5% bottom 3%, the 520 x 560 buttons in
            // 27% x 45% at right 1.5%)
            let sw = lmin(0.25, 0.42 / a), sh = lmin(0.25 * a, 0.42);
            addRaw(0.015, 0.97 - sh, 0.015 + sw, 0.97);
            let bw = lmin(0.27, 0.45 * 520 / 560 / a), bh = lmin(0.27 * 560 / 520 * a, 0.45);
            addRaw(0.985 - bw, 0.97 - bh, 0.985, 0.97);
        } else {
            addRect(W * 0.044 + 16, H * 0.96 - 302, W * 0.044 + 474, H * 0.96, W, H, 0);
            addRect(W * 0.956 - 560, H * 0.96 - 238, W * 0.956, H * 0.96, W, H, 0);
        }
        // the alert slot: under the boss stack in a fight (headline y 300,
        // sub under it); in flight while it shows (kind chip from y 186,
        // headline centre 258, sub to ~335; bannerStep lower under a kept
        // objective track), grown down from the top as it eases in so a
        // popup under it is pushed, never jumped
        if (L.fight) {
            addRect(W * 0.5 - 560, 0, W * 0.5 + 560, 392, W, H, 0);
        } else if (alertK > 0.01) {
            addRect(W * 0.5 - 440, 0, W * 0.5 + 440, (348 + hudStep) * alertK, W, H, 0);
        }
    } else {
        if (L.school) {
            // the school: no route / score; the lesson ticket (top 0.085 .. 0.195 + the notch inset) and the
            // comms stepped down under it
            addRaw(0.04, 0.085 + inset, 0.96, 0.195 + inset);
            commsRect(a, L);
            addRaw(CR_0, CR_1, CR_2, CR_3);
        } else {
            // (while the slot shows the score line steps down, and in fights the comms too: hud.md Portrait
            // yield, by banner / warning strip, plus the banner's bannerStep and the fight's phase chip step;
            // the comms by the grown route tab)
            let bk = L.bannerK, lr = L.legRoute;
            let dyS = L.yieldK * (36 + 64 * bk + (108 - 22 * bk) * L.fightK + bk * hudStep) + 14 * L.fightK;
            addTop(40, 224, 40 + 428 * lr, 224 + 116 * lr, W, H, inset);
            // the score line (hud.md Portrait score line: 520 wide, 62 tall, the time row under it on phones;
            // the chain count rides the line), as drawn: the visor draws its slab SCORE_LOW lower
            let gRow = mathx.clamp(20 / (30 * lmax(L.hudPx, 0.05)), 1, 1.5);
            let sb = 224 + dyS + 62 + hudLine * (12 + 36 * gRow);
            addTop(W * 0.947 - 520, 224 + dyS, W * 0.947, sb, W, H, inset);
            rects[nRects * 4 - 1] += SCORE_LOW;
            commsRect(a, L);
            let c3 = CR_3, cr = CR_4;
            addRaw(CR_0, CR_1, CR_2, CR_3);
            // the dock: the free column right of the comms from the score line down, or (phones: the plate
            // spans the width) under the plate, right-aligned to the score (its foot set below)
            let x0 = W * 0.947 - 520;
            let side = cr + 16 <= W * 0.947 - 300;
            dU0 = (side ? lmax(x0, cr + 16) : x0) / W;
            dU1 = 0.947;
            dV0 = inset + sb / H + SCORE_LOW;
            if (!side) {
                dV0 = lmax(dV0, c3);
            }
        }
        // the alert slot (over the route / score row; lower in a fight; bannerStep lower under a kept
        // objective track)
        addTop(W * 0.5 - 520, 120, W * 0.5 + 520, L.fight ? 470 : 360 + hudStep, W, H, inset);
        // the gauge strip above the touch zone (PortTouch; bottom 32 %, 0.76)
        let gb = L.touch ? 0.68 : 0.97;
        addRect(W * 0.037 + 12, H * gb - 232, W * 0.037 + 337, H * gb, W, H, inset);
        addRect(W * 0.963 - 426, H * gb - 182, W * 0.963, H * gb, W, H, inset);
    }
    // the hero safe zone (camera.zone: NDC half width, bottom, top; y up)
    camera.zone(a);
    let zw = camera.ZONE_1, zb = camera.ZONE_2, zt = camera.ZONE_3;
    zoneIdx = nRects;
    addRaw(0.5 - zw * 0.5, 0.5 - zt * 0.5, 0.5 + zw * 0.5, 0.5 - zb * 0.5);
    if (dV0 < 1) {
        dV1 = lmin(DOCK_V1, 0.5 - zt * 0.5);
    }
    // the hero himself (he can lean out of the zone; never skipped)
    if (L.heroU >= 0) {
        let hu = L.heroHu * HERO_HARD, hv = L.heroHv * HERO_HARD;
        addRaw(L.heroU - hu, L.heroV - hv, L.heroU + hu, L.heroV + hv);
        pads[nRects * 2 - 2] = L.heroHu * (1 + PAD) - hu;
        pads[nRects * 2 - 1] = L.heroHv * (1 + PAD) - hv;
    }
    // the boss weak point the player is shooting at
    if (L.bossU >= 0 && L.bossV >= 0) {
        let rr = 0.075 * lmin(1, a);
        addRaw(L.bossU - rr / a, L.bossV - rr, L.bossU + rr / a, L.bossV + rr);
        pads[nRects * 2 - 2] = rr / a * PAD;
        pads[nRects * 2 - 1] = rr * PAD;
    }
    // the boss while she is revealed: her whole hull
    if (L.hullU1 > L.hullU0) {
        addRaw(L.hullU0, L.hullV0, L.hullU1, L.hullV1);
        pads[nRects * 2 - 2] = 0.01 / a;
        pads[nRects * 2 - 1] = 0.01;
    }
}

// Keep-out search: the nearest spot (screen-height units, a move down costs
// a little more than one up) inside the band that meets no rect: from the
// first rect a spot meets, try its four sides, recursively (depth 3), best
// first with pruning. skipZone lets the last resort sit on the hero zone.
// A spot is picked with the full GAP and the moving keep-outs padded; a
// drawn chip only has to keep HARD, so a drift or a merge that grows it does
// not shove it.
const GAP: f64 = 0.012;
const HARD: f64 = 0.006;
let gap: f64 = GAP;
let sAsp: f64 = 1, sHw: f64 = 0, sHh: f64 = 0, sU0: f64 = 0, sU1: f64 = 1, sV0: f64 = 0, sV1: f64 = 1, sOu: f64 = 0, sOv: f64 = 0;
let bestU: f64 = 0, bestV: f64 = 0, bestD: f64 = HUGE;
let skipZone = false;
// the fed enemies' rects are [foeLo, foeHi); with no free spot a chip goes
// over an enemy before the hero zone (`place`, `placedOnFoe`), and from then
// on enemies no longer block its moves (`Pop.foeOk`: QA RP-6 r2, in portrait
// each pass shoved such chips, hopped and retired them)
let skipFoes = false;
let foeLo: i32 = 0, foeHi: i32 = 0;
let placedOnFoe = false;
function skipped(i: i32): bool {
    return (skipZone && i == zoneIdx) || (skipFoes && i >= foeLo && i < foeHi);
}
let padded = false;

// the rect i widened by the chip's half extents, the gap and any pad (ED_0..ED_3)
let ED_0: f64 = 0, ED_1: f64 = 0, ED_2: f64 = 0, ED_3: f64 = 0;
function edges(i: i32): void {
    let o = i * 4;
    let pu = sHw + gap, pv = sHh + gap;
    if (padded) {
        pu += pads[i * 2];
        pv += pads[i * 2 + 1];
    }
    ED_0 = rects[o] - pu;
    ED_1 = rects[o + 1] - pv;
    ED_2 = rects[o + 2] + pu;
    ED_3 = rects[o + 3] + pv;
}

function hitAt(u: f64, v: f64): i32 {
    for (let i = 0; i < nRects; i++) {
        if (!skipped(i)) {
            edges(i);
            if (u > ED_0 && u < ED_2 && v > ED_1 && v < ED_3) {
                return i;
            }
        }
    }
    return -1;
}

function cost(u: f64, v: f64): f64 {
    let dv = v - sOv;
    return Math.abs(u - sOu) * sAsp + (dv > 0 ? dv * 1.2 : -dv);
}

function search(u: f64, v: f64, depth: i32): void {
    let d = cost(u, v);
    if (d >= bestD) {
        return;
    }
    let i = hitAt(u, v);
    if (i < 0) {
        bestU = u;
        bestV = v;
        bestD = d;
        return;
    }
    if (depth <= 0) {
        return;
    }
    // a hair past the edge, so the spot clears the rect it steps off
    edges(i);
    let x0 = ED_0 - 1e-4, y0 = ED_1 - 1e-4, x1 = ED_2 + 1e-4, y1 = ED_3 + 1e-4;
    // nearest side first (better pruning)
    let c1 = cost(x0, v), c2 = cost(x1, v), c3 = cost(u, y0), c4 = cost(u, y1);
    for (let k = 1; k <= 4; k++) {
        let m = lmin(lmin(lmin(c1, c2), c3), c4);
        if (m == HUGE) {
            break;
        }
        if (m == c1) {
            c1 = HUGE;
            if (x0 >= sU0) {
                search(x0, v, depth - 1);
            }
        } else if (m == c2) {
            c2 = HUGE;
            if (x1 <= sU1) {
                search(x1, v, depth - 1);
            }
        } else if (m == c3) {
            c3 = HUGE;
            if (y0 >= sV0) {
                search(u, y0, depth - 1);
            }
        } else {
            c4 = HUGE;
            if (y1 <= sV1) {
                search(u, y1, depth - 1);
            }
        }
    }
}

// The nearest free spot to (u, v) (PL_U, PL_V), whether it had to use the hero zone (PL_Z) and
// whether there is one at all (PL_F; else (u, v) back). pad: pick with the moving
// keep-outs widened (dropped when that finds none); zoneOk: the hero zone is
// open from the start.
let PL_U: f64 = 0, PL_V: f64 = 0, PL_Z = false, PL_F = false;
function place(u: f64, v: f64, hw: f64, hh: f64, aspect: f64, u0: f64, u1: f64, v0: f64, v1: f64, pad: bool, zoneOk: bool): void {
    // (from inside the band: a spot the band clamp moves is no spot)
    u = mathx.clamp(u, u0, u1);
    v = mathx.clamp(v, v0, v1);
    sAsp = aspect;
    sHw = hw;
    sHh = hh;
    sU0 = u0;
    sU1 = u1;
    sV0 = v0;
    sV1 = v1;
    sOu = u;
    sOv = v;
    bestU = u;
    bestV = v;
    bestD = HUGE;
    skipZone = zoneOk;
    padded = pad;
    placedOnFoe = false;
    gap = pad ? GAP : HARD;
    search(u, v, 3);
    if (bestD == HUGE && pad) {
        padded = false;
        search(u, v, 3);
    }
    if (bestD == HUGE && !zoneOk && !skipFoes && foeHi > foeLo) {
        // no free spot: over an enemy before the hero zone (QA RP-6 r2: in
        // portrait keeping off them sent chips onto the zone, +56 %)
        skipFoes = true;
        search(u, v, 3);
        skipFoes = false;
        if (bestD < HUGE) {
            padded = false;
            placedOnFoe = true;
            PL_U = bestU;
            PL_V = bestV;
            PL_Z = false;
            PL_F = true;
            return;
        }
    }
    let onZone = zoneOk;
    if (bestD == HUGE && !zoneOk) {
        // no free spot off the hero zone: stay off the panels, the hero and
        // the other popups
        skipZone = true;
        search(u, v, 3);
        skipZone = false;
        onZone = true;
    }
    padded = false;
    PL_U = bestU;
    PL_V = bestV;
    PL_Z = onZone;
    PL_F = bestD < HUGE;
}

// A move from (au, av) to (bu, bv) is clear when the end meets no rect and
// no point on the way enters a rect the start is not already in (a chip a
// keep-out moved onto may step out of it, never through another).
const fromIn: Array<bool> = new Array<bool>(256); // 0-based
function moveClear(au: f64, av: f64, bu: f64, bv: f64): bool {
    if (hitAt(bu, bv) >= 0) {
        return false;
    }
    if (fromIn.length < nRects) fromIn.length = nRects + 64;
    for (let i = 0; i < nRects; i++) {
        edges(i);
        fromIn[i] = !skipped(i) && au > ED_0 && au < ED_2 && av > ED_1 && av < ED_3;
    }
    let du = bu - au, dv = bv - av;
    let n = lmin(48, Math.ceil(lmax(Math.abs(du) / (sHw + gap), Math.abs(dv) / (sHh + gap)) * 2));
    for (let k = 1.0; k <= n - 1; k += 1) {
        let t = k / n;
        let u = au + du * t, v = av + dv * t;
        for (let i = 0; i < nRects; i++) {
            if (!fromIn[i] && !skipped(i)) {
                edges(i);
                if (u > ED_0 && u < ED_2 && v > ED_1 && v < ED_3) {
                    return false;
                }
            }
        }
    }
    return true;
}

// A drawn chip moves at most STEP (screen heights, see cost) a frame to stay
// clear; a keep-out swallowing it with no free spot that near hops it to its
// spot once (it re-pops there), and a second time retires it.
const STEP: f64 = 0.06;

// This frame's open and wider bands (set in draw), and a chip's band for its
// half extents (the whole chip on screen: BD_0..BD_3).
let bU0: f64 = 0, bU1: f64 = 1, bV0: f64 = 0, bV1: f64 = 1, wU0: f64 = 0, wU1: f64 = 1, wV0: f64 = 0, wV1: f64 = 1;
let curDock = false; // the chip being placed sits in the dock (its band)
let BD_0: f64 = 0, BD_1: f64 = 0, BD_2: f64 = 0, BD_3: f64 = 0;
function bandOf(hw: f64, hh: f64, wide: bool): void {
    let mu = hw + 0.01, mv = hh + 0.01;
    if (curDock) {
        BD_0 = dU0 + hw;
        BD_1 = dU1 - hw;
        BD_2 = dV0 + hh;
        BD_3 = dV1 - hh;
        return;
    }
    if (wide) {
        BD_0 = lmax(wU0, mu);
        BD_1 = lmin(wU1, 1 - mu);
        BD_2 = lmax(wV0, mv);
        BD_3 = lmin(wV1, 1 - mv);
        return;
    }
    BD_0 = lmax(bU0, mu);
    BD_1 = lmin(bU1, 1 - mu);
    BD_2 = lmax(bV0, mv);
    BD_3 = lmin(bV1, 1 - mv);
}

// Where a drawn chip at (u, v) with half extents (hw, hh) can be this frame
// without a hop: where it is, else the free spot nearest it within STEP
// (HARD gap; zoneOk: the hero zone does not count). NA_OK, NA_U, NA_V.
let NA_OK = false, NA_U: f64 = 0, NA_V: f64 = 0;
function nearAt(u: f64, v: f64, hw: f64, hh: f64, wide: bool, zoneOk: bool, aspect: f64): void {
    bandOf(hw, hh, wide);
    let u0 = BD_0, u1 = BD_1, v0 = BD_2, v1 = BD_3;
    sHw = hw;
    sHh = hh;
    gap = HARD;
    padded = false;
    skipZone = zoneOk;
    let clear = u >= u0 && u <= u1 && v >= v0 && v <= v1 && hitAt(u, v) < 0;
    skipZone = false;
    if (clear) {
        NA_OK = true;
        NA_U = u;
        NA_V = v;
        return;
    }
    place(u, v, hw, hh, aspect, u0, u1, v0, v1, false, zoneOk);
    let pu = PL_U, pv = PL_V, found = PL_F;
    let qu = mathx.clamp(pu, u0, u1), qv = mathx.clamp(pv, v0, v1);
    NA_OK = found && Math.abs(qu - u) * aspect + Math.abs(qv - v) <= STEP;
    NA_U = qu;
    NA_V = qv;
}

// The largest scale in [sMin, s0] at which the chip still has a spot
// (nearAt), and the spot (scale 0: none, even at sMin). SN_S, SN_U, SN_V.
let SN_S: f64 = 0, SN_U: f64 = 0, SN_V: f64 = 0;
function shrinkNear(u: f64, v: f64, hw: f64, hh: f64, s0: f64, sMin: f64, wide: bool, zoneOk: bool, aspect: f64): void {
    nearAt(u, v, hw * s0, hh * s0, wide, zoneOk, aspect);
    let ok = NA_OK;
    let cu = NA_U, cv = NA_V;
    if (ok) {
        SN_S = s0;
        SN_U = cu;
        SN_V = cv;
        return;
    }
    if (sMin >= s0) {
        SN_S = 0;
        SN_U = u;
        SN_V = v;
        return;
    }
    nearAt(u, v, hw * sMin, hh * sMin, wide, zoneOk, aspect);
    let okm = NA_OK, mu = NA_U, mv = NA_V;
    if (!okm) {
        SN_S = 0;
        SN_U = u;
        SN_V = v;
        return;
    }
    let lo = sMin, hi = s0;
    cu = mu;
    cv = mv;
    for (let k = 1; k <= 4; k++) {
        let m = (lo + hi) * 0.5;
        nearAt(u, v, hw * m, hh * m, wide, zoneOk, aspect);
        if (NA_OK) {
            lo = m;
            cu = NA_U;
            cv = NA_V;
        } else {
            hi = m;
        }
    }
    SN_S = lo;
    SN_U = cu;
    SN_V = cv;
}

// A spot for a chip of half extents (hw, hh) near (u, v): in the open band
// (unless wide), else in the wider one (a docked chip: the dock only); which
// band it found it in. PB_U, PB_V, PB_Z, PB_F, PB_W.
let PB_U: f64 = 0, PB_V: f64 = 0, PB_Z = false, PB_F = false, PB_W = false;
function placeBand(u: f64, v: f64, hw: f64, hh: f64, wide: bool, aspect: f64): void {
    if (!wide || curDock) {
        bandOf(hw, hh, false);
        let a0 = BD_0, a1 = BD_1, b0 = BD_2, b1 = BD_3;
        place(u, v, hw, hh, aspect, a0, a1, b0, b1, true, false);
        if (PL_F || curDock) {
            PB_U = PL_U;
            PB_V = PL_V;
            PB_Z = PL_Z;
            PB_F = PL_F;
            PB_W = false;
            return;
        }
    }
    bandOf(hw, hh, true);
    let a0 = BD_0, a1 = BD_1, b0 = BD_2, b1 = BD_3;
    place(u, v, hw, hh, aspect, a0, a1, b0, b1, true, false);
    PB_U = PL_U;
    PB_V = PL_V;
    PB_Z = PL_Z;
    PB_F = PL_F;
    PB_W = true;
}

// The pool in spawn order (older popups keep their spot; newer ones stack). 1-based.
const order: Array<Pop> = new Array<Pop>(1);
function bySerial(a: Pop, b: Pop): bool {
    return a.serial < b.serial;
}

// Legibility first (DIRECTION #23): a long label shrinks to fit 392 of the
// art's 512 units (~34 a glyph at its 66 of 160 font); the chip is drawn
// larger so its glyphs keep at least MIN_TEXT of the short side (portrait
// more), up to MAX_GROW. With no room at that size a chip shrinks back
// (rather than drop, hop or retire), never below the art's own size nor
// glyphs of SHRINK_TEXT (~2/3 of the portrait floor).
const TEXT_K: f64 = 0.068 * 66 / 160;
const MIN_TEXT: f64 = 0.03, MIN_TEXT_PORT: f64 = 0.034, MAX_GROW: f64 = 2;
const SHRINK_TEXT: f64 = 0.022;

// A chip with no room anywhere: its points go to a like chip on screen
// (same label, or both rings / kills), else it is dropped (the score still
// counts): never drawn over the hero or a panel.
function absorb(P: Popups, p: Pop): bool {
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let q = list[i];
        if (q != p && q.active && q.placed && q.dw > 0 && q.kind == p.kind) {
            let t2: string? = null;
            if (p.label != "" && q.label == p.label) {
                q.hits += p.hits;
                q.pts += p.pts;
                t2 = fmtLabel(q.label, q.hits, q.pts);
            } else if (p.label == "" && q.label == "" && p.kind == "ring") {
                q.hits = lmax(q.hits, p.hits);
                q.pts += p.pts;
                t2 = q.hits >= 2 ? fmtRing(q.hits, q.pts) : "+" + lstr(q.pts);
            } else if (p.label == "" && q.label == "" && p.kind == "kill") {
                q.hits += lmax(1, p.hits);
                q.pts += p.pts;
                t2 = fmtKill(q.pts, q.hits);
            }
            if (t2 != null) {
                q.value = q.pts;
                q.age = lmin(q.age, 0.12);
                q.chars = t2.length;
                let b = q.bag;
                if (b != null) {
                    vmx.str(b, "text", t2);
                }
                return true;
            }
        }
    }
    return false;
}

// A new chip with no room anywhere that no like chip can take: the chip on
// screen worth least retires for it if it is worth less (its sprite is out
// next frame; the newcomer is placed then, in the room it leaves). Once.
function bump(P: Popups, p: Pop): bool {
    if (p.bumped) {
        return false;
    }
    let low: Pop? = null;
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let q = list[i];
        if (q != p && q.active && q.placed && q.dw > 0 && q.value < p.value && (low == null || q.value < low.value)) {
            low = q;
        }
    }
    if (low == null) {
        return false;
    }
    low.active = false;
    low.hw = 0;
    low.dw = 0;
    p.bumped = true;
    return true;
}

// cam: this frame's camera; aspect: viewport width / height. Popups keep a
// steady screen size (at most 1.2x their base); their centres stay inside
// the open band (landscape x 0.1-0.9, y 0.28-0.76, from 0.40 in a fight;
// portrait x 0.12-0.88, y 0.28-0.66, above the touch zone; the school from
// 0.38), or a kill chip in portrait flight the dock (right-aligned under the
// score line: the column right of the comms, or under the phones' plate, to
// DOCK_V1; a new chip takes its top right free spot when it has one), off the HUD
// panels, the alert slot, the hero safe zone, the hero, the boss weak point,
// the fed enemies and each other, easing to a new spot around them along clear paths on
// every drawn frame (hopping there once when a keep-out swallows one). With
// no room in the band (a hero filling it) a chip takes the wider band, else
// merges into a like chip or is dropped; it never lands on the hero. A
// popup whose anchor passes the lens holds its last spot.
export function draw(P: Popups, cam: R.Camera, aspect: f64): void {
    let eye = cam.eye;
    let f = mathx.norm(cam.target - eye);
    let rt = mathx.norm(mathx.cross(f, cam.up));
    let up = mathx.cross(rt, f);
    let th = Math.tan(cam.fov * 0.5);
    let L = P.layout;
    let portrait = aspect < 1;
    // (the school, both aspects: the band starts at 0.36 under the ticket and the stepped-down comms / shield
    // tab, training.md 6; centres at 0.38 keep a chip's top there, the wider band too)
    let bv0 = L.fight && !portrait ? 0.4 : L.school ? 0.38 : 0.28;
    let bv1 = portrait ? 0.66 : 0.76;
    let bu0 = portrait ? 0.12 : 0.1, bu1 = portrait ? 0.88 : 0.9;
    // the wider band (panels still keep-outs): above the touch zone in portrait, under the boss stack in a fight
    let wu0 = portrait ? 0.05 : 0.04, wu1 = portrait ? 0.95 : 0.96;
    let wv0 = L.school ? 0.38 : portrait ? 0.19 : L.fight ? 0.4 : 0.18;
    let wv1 = portrait ? 0.68 : 0.84;
    bU0 = bu0;
    bU1 = bu1;
    bV0 = bv0;
    bV1 = bv1;
    wU0 = wu0;
    wU1 = wu1;
    wV0 = wv0;
    wV1 = wv1;
    let minText = portrait ? MIN_TEXT_PORT : MIN_TEXT;
    // text height as a fraction of the screen height (short side in portrait)
    let frac = 0.068 * lmin(1, aspect);
    let hb = P.hud;
    hudLine = 0;
    hudStep = 0;
    hudVW = 0;
    hudVH = 0;
    if (hb != null) {
        hudLine = opt(vmx.optNum(hb, "legScoreLine"), 0);
        if (vmx.optBool(hb, "objectiveTrack") && !L.fight) {
            hudStep = opt(vmx.optNum(hb, "bannerStep"), 0);
        }
        hudVW = opt(vmx.optNum(hb, "viewW"), 0);
        hudVH = opt(vmx.optNum(hb, "viewH"), 0);
    }
    hudRects(aspect, L, P.alertK);
    // the enemies (a box their radius around each, padded like the hero)
    foeLo = nRects;
    for (let i = 0; i < <i32>P.nFoes; i++) {
        let o = i * 4;
        let fo = P.foes;
        let d = mathx.v3(fo[o + 1] - <f64>eye.x, fo[o + 2] - <f64>eye.y, fo[o + 3] - <f64>eye.z);
        let z = mathx.dot(d, f);
        if (z > 2) {
            let fu = 0.5 + mathx.dot(d, rt) / (z * th * aspect) * 0.5;
            let fv = 0.5 - mathx.dot(d, up) / (z * th) * 0.5;
            let rv = fo[o + 4] * FOE_K / (z * th) * 0.5;
            let ru = rv / aspect;
            if (fu + ru > 0 && fu - ru < 1 && fv + rv > 0 && fv - rv < 1) {
                addRaw(fu - ru, fv - rv, fu + ru, fv + rv);
                pads[nRects * 2 - 2] = ru * PAD;
                pads[nRects * 2 - 1] = rv * PAD;
            }
        }
    }
    P.nFoes = 0;
    foeHi = nRects;
    let ease = 1 - Math.exp(-14 * lmax(P.dt, 0));
    order.length = 1;
    let list = P.list;
    for (let i = 1; i < list.length; i++) {
        let p = list[i];
        p.hw = 0;
        if (p.active) {
            order.push(p);
        }
    }
    lsort<Pop>(order, order.length - 1, bySerial);
    for (let oi = 1; oi < order.length; oi++) {
        let p = order[oi];
        skipFoes = false;
        let s = p.sprite;
        if (s == null) continue;
        let k = p.age / LIFE;
        let dx = p.x - <f64>eye.x, dy = p.y - <f64>eye.y, dz = p.z - <f64>eye.z;
        let d = mathx.v3(dx, dy, dz);
        let z = mathx.dot(d, f);
        let nx = p.nx, ny = p.ny;
        if (z > 2) {
            nx = mathx.dot(d, rt) / (z * th * aspect);
            ny = mathx.dot(d, up) / (z * th);
            p.nx = nx;
            p.ny = ny;
            p.seen = true;
        }
        if (!p.seen) {
            p.hw = 0;
            p.dw = 0;
            continue;
        }
        // drawn at a steady depth (screen-constant size either way)
        z = 10;
        // screen (0..1, y down): rise, stagger, then clamp into the band
        let u = 0.5 + nx * 0.5 + (mod(p.serial, 3) - 1) * 0.045;
        let v = 0.5 - ny * 0.5 - mathx.easeOutCubic(k) * 0.05 * (p.rise / 3) + mod(p.serial, 2) * 0.03;
        // drawn size (screen fractions): the quad is 3.2 x its height;
        // the text + sparkles fill ~34 of its 512 units per glyph + 90
        let sc = lmin(p.scale, 1.2);
        let fit = lmin(1, 392 / lmax(34 * p.chars, 1));
        let grow = mathx.clamp(minText / (TEXT_K * sc * fit), 1, MAX_GROW);
        let hk = frac * sc * grow;
        let hw = 0.5 * 3.2 * hk / aspect * lmin(1, (lmin(392, 34 * p.chars) + 90) / 512);
        let hh = 0.5 * hk * 0.72;
        // once it had to shrink it keeps that size (a merge never
        // grows it back); sMin: the least it may shrink to
        let cs = lmin(lmin(1, p.cw / hw), p.ch / hh);
        hk = hk * cs;
        hw = hw * cs;
        hh = hh * cs;
        let sMin = lmin(1, lmax(1 / grow, SHRINK_TEXT / (TEXT_K * sc * fit * grow)) / cs);
        p.hw = hw;
        p.hh = hh;
        // portrait flight: a new kill chip docks where the dock has
        // room for it; a docked chip leaves with the dock
        curDock = true;
        bandOf(hw, hh, false);
        let da0 = BD_0, da1 = BD_1, db0 = BD_2, db1 = BD_3;
        let dockOk = dV1 > dV0 && da0 <= da1 && db0 <= db1;
        if (!p.placed && p.kind == "kill") {
            let df = false;
            if (dockOk) {
                place(da1, db0, hw, hh, aspect, da0, da1, db0, db1, true, false);
                // (not over an enemy: the open band may have a free spot)
                df = PL_F && !placedOnFoe;
            }
            p.dock = df;
        } else if (!p.placed) {
            p.dock = false;
        } else if (p.dock && !dockOk) {
            p.active = false;
            p.hw = 0;
            p.dw = 0;
            curDock = false;
            continue;
        }
        curDock = p.dock;
        if (p.dock) {
            // its own spot: the dock's top right (no rise, no stagger)
            u = da1;
            v = db0;
        }
        // its band: the open band, or the wider one once that had no
        // room (or the dock); either way the whole chip stays on screen
        let mu = hw + 0.01, mv = hh + 0.01;
        let wu0c = lmax(wu0, mu), wu1c = lmin(wu1, 1 - mu);
        let wv0c = lmax(wv0, mv), wv1c = lmin(wv1, 1 - mv);
        let u0 = lmax(bu0, mu), u1 = lmin(bu1, 1 - mu), v0 = lmax(bv0, mv), v1 = lmin(bv1, 1 - mv);
        if (p.dock) {
            u0 = da0;
            u1 = da1;
            v0 = db0;
            v1 = db1;
        } else if (p.wide) {
            u0 = wu0c;
            u1 = wu1c;
            v0 = wv0c;
            v1 = wv1c;
        }
        let ru = u, rv = v;
        u = mathx.clamp(u, u0, u1);
        v = mathx.clamp(v, v0, v1);
        // where it would sit clear of the panels, the hero, the boss
        // target (both with slack) and the popups before it
        place(u, v, hw, hh, aspect, u0, u1, v0, v1, true, false);
        let pu = PL_U, pv = PL_V, onZone = PL_Z, found = PL_F;
        // (whether the spot it takes is over an enemy)
        let onFoe = placedOnFoe;
        if (!found && !p.wide && !p.dock) {
            // no room in the open band (a hero filling it): the wider one
            let wu = mathx.clamp(u, wu0c, wu1c), wv = mathx.clamp(v, wv0c, wv1c);
            place(wu, wv, hw, hh, aspect, wu0c, wu1c, wv0c, wv1c, true, false);
            let qu = PL_U, qv = PL_V, qz = PL_Z, qf = PL_F;
            if (qf) {
                p.wide = true;
                u0 = wu0c;
                u1 = wu1c;
                v0 = wv0c;
                v1 = wv1c;
                u = wu;
                v = wv;
                pu = qu;
                pv = qv;
                onZone = qz;
                found = qf;
                onFoe = placedOnFoe;
            }
        }
        if (onFoe) {
            p.foeOk = true;
        }
        // (eased there: an enemy flying onto it does not shove it)
        skipFoes = p.placed && p.foeOk;
        if (!found && !p.placed && sMin < 1) {
            // no room at its legible size: the largest size down to
            // sMin that has a spot (open band, else the wide one)
            let lo = 0.0, hi = 1.0;
            let sk = sMin;
            for (let it = 1; it <= 4; it++) {
                placeBand(ru, rv, hw * sk, hh * sk, p.wide, aspect);
                if (PB_F) {
                    lo = sk;
                    pu = PB_U;
                    pv = PB_V;
                    onZone = PB_Z;
                    found = PB_F;
                    p.wide = PB_W;
                    onFoe = placedOnFoe;
                } else if (sk == sMin) {
                    break;
                } else {
                    hi = sk;
                }
                sk = (lmax(lo, sMin) + hi) * 0.5;
            }
            if (found) {
                hk = hk * lo;
                hw = hw * lo;
                hh = hh * lo;
                p.hw = hw;
                p.hh = hh;
                p.cw = hw;
                p.ch = hh;
                bandOf(hw, hh, p.wide);
                u0 = BD_0;
                u1 = BD_1;
                v0 = BD_2;
                v1 = BD_3;
                u = mathx.clamp(ru, u0, u1);
                v = mathx.clamp(rv, v0, v1);
            }
        }
        if (!found && !p.placed) {
            // nowhere to show it: merged into a like chip, else the
            // lesser chip on screen makes way (it shows next frame),
            // else dropped
            if (absorb(P, p) || !bump(P, p)) {
                p.active = false;
            }
            p.hw = 0;
            p.dw = 0;
            continue;
        }
        if (onFoe) {
            p.foeOk = true;
        }
        let su = mathx.clamp(pu, u0, u1);
        let sv = mathx.clamp(pv, v0, v1);
        let du = su - u, dv = sv - v;
        if (p.placed) {
            // ease its offset there (a spot freeing up never snaps it
            // across), moving only along clear paths from where it
            // was drawn, so it keeps the side of a keep-out it is on:
            // the eased spot, else the free spot within STEP of it
            // (sliding along the edge), else riding its anchor, else
            // staying, else the free spot within STEP of where it was
            // (a keep-out moved in); swallowed, it hops (once). Its moves
            // keep off the newer popups as drawn last frame too (they
            // are placed around it next), and one sent onto the hero
            // zone (its last resort) may stay on it until it can step
            // off.
            let lu = p.su, lv = p.sv;
            let base = nRects;
            gap = HARD;
            for (let j = oi + 1; j < order.length; j++) {
                let q = order[j];
                if (q.dw > 0) {
                    addRaw(q.su - q.dw, q.sv - q.dh, q.su + q.dw, q.sv + q.dh);
                }
            }
            edges(zoneIdx);
            let zx0 = ED_0, zy0 = ED_1, zx1 = ED_2, zy1 = ED_3;
            let zoneOk = onZone || (p.zoned && lu > zx0 && lu < zx1 && lv > zy0 && lv < zy1);
            let gu = du, gv = dv;
            if (zoneOk && !onZone) {
                // left on the zone: head for the nearest way off it
                place(lu, lv, hw, hh, aspect, u0, u1, v0, v1, false, false);
                let ou = PL_U, ov = PL_V, oz = PL_Z, ofd = PL_F;
                if (ofd && !oz) {
                    gu = mathx.clamp(ou, u0, u1) - u;
                    gv = mathx.clamp(ov, v0, v1) - v;
                }
            }
            let cu = mathx.clamp(u + p.ou + (gu - p.ou) * ease, u0, u1);
            let cv = mathx.clamp(v + p.ov + (gv - p.ov) * ease, v0, v1);
            skipZone = zoneOk;
            let ok = moveClear(lu, lv, cu, cv);
            if (!ok) {
                place(cu, cv, hw, hh, aspect, u0, u1, v0, v1, false, zoneOk);
                let pqu = PL_U, pqv = PL_V, pf = PL_F;
                let qu = mathx.clamp(pqu, u0, u1), qv = mathx.clamp(pqv, v0, v1);
                skipZone = zoneOk;
                if (pf && Math.abs(qu - lu) * aspect + Math.abs(qv - lv) <= STEP && moveClear(lu, lv, qu, qv)) {
                    cu = qu;
                    cv = qv;
                    ok = true;
                }
            }
            if (!ok) {
                let hu = mathx.clamp(u + p.ou, u0, u1);
                let hv = mathx.clamp(v + p.ov, v0, v1);
                if (moveClear(lu, lv, hu, hv)) {
                    cu = hu;
                    cv = hv;
                    ok = true;
                } else if (lu >= u0 && lu <= u1 && lv >= v0 && lv <= v1 && hitAt(lu, lv) < 0) {
                    // (staying only inside its band: a merge that grows
                    // it may push it off an edge)
                    cu = lu;
                    cv = lv;
                    ok = true;
                }
            }
            if (!ok) {
                place(lu, lv, hw, hh, aspect, u0, u1, v0, v1, false, zoneOk);
                let pqu = PL_U, pqv = PL_V, pf = PL_F;
                let qu = mathx.clamp(pqu, u0, u1), qv = mathx.clamp(pqv, v0, v1);
                if (pf && Math.abs(qu - lu) * aspect + Math.abs(qv - lv) <= STEP) {
                    cu = qu;
                    cv = qv;
                    ok = true;
                }
            }
            if (!ok && p.dw > 0 && sMin < 1) {
                // no room at this size: it keeps the size it was
                // drawn at (a merge grew it), else shrinks back as
                // little as it must (to sMin), where it is or within
                // STEP: no flash off and back
                let s0 = lmax(sMin, lmin(lmin(1, p.dw / hw), p.dh / hh));
                shrinkNear(lu, lv, hw, hh, s0, sMin, p.wide, zoneOk, aspect);
                let sk = SN_S, qu = SN_U, qv = SN_V;
                if (sk > 0) {
                    cu = qu;
                    cv = qv;
                    ok = true;
                    hk = hk * sk;
                    hw = hw * sk;
                    hh = hh * sk;
                    p.hw = hw;
                    p.hh = hh;
                    p.cw = hw;
                    p.ch = hh;
                    bandOf(hw, hh, p.wide);
                    u0 = BD_0;
                    u1 = BD_1;
                    v0 = BD_2;
                    v1 = BD_3;
                    u = mathx.clamp(ru, u0, u1);
                    v = mathx.clamp(rv, v0, v1);
                }
            }
            skipZone = false;
            let hu0 = 0.0, hv0 = 0.0, hz0 = false, hf = false;
            if (!ok && p.hops == 0) {
                // its spot, clear of the newer popups too (else in the
                // wider band)
                place(u, v, hw, hh, aspect, u0, u1, v0, v1, true, false);
                hu0 = PL_U;
                hv0 = PL_V;
                hz0 = PL_Z;
                hf = PL_F;
                if (!hf && !p.wide && !p.dock) {
                    let wu = mathx.clamp(u, wu0c, wu1c), wv = mathx.clamp(v, wv0c, wv1c);
                    place(wu, wv, hw, hh, aspect, wu0c, wu1c, wv0c, wv1c, true, false);
                    hu0 = PL_U;
                    hv0 = PL_V;
                    hz0 = PL_Z;
                    hf = PL_F;
                    if (hf) {
                        p.wide = true;
                        u0 = wu0c;
                        u1 = wu1c;
                        v0 = wv0c;
                        v1 = wv1c;
                    }
                }
                if (!hf && sMin < 1) {
                    // no room at this size: at sMin
                    placeBand(ru, rv, hw * sMin, hh * sMin, p.wide, aspect);
                    if (PB_F) {
                        hu0 = PB_U;
                        hv0 = PB_V;
                        hz0 = PB_Z;
                        hf = PB_F;
                        p.wide = PB_W;
                        hk = hk * sMin;
                        hw = hw * sMin;
                        hh = hh * sMin;
                        p.hw = hw;
                        p.hh = hh;
                        p.cw = hw;
                        p.ch = hh;
                        bandOf(hw, hh, p.wide);
                        u0 = BD_0;
                        u1 = BD_1;
                        v0 = BD_2;
                        v1 = BD_3;
                        u = mathx.clamp(ru, u0, u1);
                        v = mathx.clamp(rv, v0, v1);
                    }
                }
            }
            if (!ok && !hf) {
                // swallowed again, or no room anywhere: it retires
                // rather than re-pop (or sit on the hero)
                nRects = base;
                p.active = false;
                p.hw = 0;
                p.dw = 0;
                continue;
            }
            if (!ok) {
                cu = mathx.clamp(hu0, u0, u1);
                cv = mathx.clamp(hv0, v0, v1);
                zoneOk = hz0;
                p.hopT = 0;
                p.hops += 1;
            }
            nRects = base;
            du = cu - u;
            dv = cv - v;
            onZone = zoneOk;
        }
        p.zoned = onZone;
        p.ou = du;
        p.ov = dv;
        p.placed = true;
        u = mathx.clamp(u + du, u0, u1);
        v = mathx.clamp(v + dv, v0, v1);
        p.su = u;
        p.sv = v;
        p.dw = hw;
        p.dh = hh;
        // the next popups stack around this one
        addRaw(u - hw, v - hh, u + hw, v + hh);
        // pops in on spawn and again after a hop
        let pop = mathx.easeOutBack(lmin(1, lmin(p.age, p.hopT) / 0.22));
        let fade = (1 - mathx.smoothstep(0.65, 1, k)) * mathx.smoothstep(0, 0.07, p.hopT);
        let wx = (u - 0.5) * 2, wy = (0.5 - v) * 2;
        // (Luau vector ops: f32 per component)
        let z32 = <f32>z, s1 = <f32>(wx * z * th * aspect), s2 = <f32>(wy * z * th);
        let qx = eye.x + f.x * z32 + rt.x * s1 + up.x * s2;
        let qy = eye.y + f.y * z32 + rt.y * s1 + up.y * s2;
        let qz = eye.z + f.z * z32 + rt.z * s1 + up.z * s2;
        let h = 2 * z * th * hk * (0.55 + 0.45 * pop);
        R.spriteAdd(s, qx, qy, qz, 0, h * 3.2, h, 0.5, fade);
    }
    curDock = false;
    skipFoes = false;
}
