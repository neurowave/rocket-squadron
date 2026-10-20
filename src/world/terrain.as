// Port of src/world/terrain.luau: rail-following coastline strips (a sea
// cliff whose foot runs coast(s) m from the rail, a grass top climbing
// inland to a rolling crest), one strip per side, chopped into s-range
// pieces so each scenery chunk owns its part. Every per-column random value
// is hashed from the column index, so pieces line up at their seams.
//
// Port rules (as cliffs.as): Luau sequences stay 1-based (slot 0 a dummy);
// optional spec numbers are NaN ("nil"); multi-returns go through module
// globals (lipAt -> LIP_LAT / LIP_Y, faceAt -> FACE_LATS / FACE_YS).
// - The rail callback is a Rail subclass: at(s) sets p (position) and rt
//   (right, horizontal unit), f32 Vectors as in Luau. Callers that need both
//   copy them right after the call (insideLimit calls at() again).
// - buildPiece's closures (face / top / decor) are Piece methods; stripJob's
//   queue holds tasks instead of closures (same order).
import { Vector } from "rive/vector";
import * as mathx from "../lib/mathx";
import { Rng, rand, randRange, smoothstep, saturate, hash, noise2 } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as coll from "./collide";
import { Collider } from "./collide";
import { HUGE, lmin, lmax, lclamp, mod, opt } from "../lib/compat";

function seq(a: Array<f64>): Array<f64> {
    let out: Array<f64> = [0.0];
    for (let i = 0; i < a.length; i++) out.push(a[i]);
    return out;
}

@inline function len(a: Array<f64>): f64 {
    return <f64>(a.length - 1);
}

// Looks ------------------------------------------------------------------------

export class Look {
    rock: Array<f64>; // strata tones (1-based)
    wet: f64; // waterline band
    crack: f64;
    grass: Array<f64>; // top tones, blended by noise (1-based)
    drape: f64; // grass spilling over the lip
    ledge: f64; // grass on ledges
    back: f64; // faces nobody sees up close
    foam: f64;
    boulder: Array<f64>; // 1-based
    shrub: f64;
    cave: f64; // sea cave mouths (unlit)
    constructor(rock: Array<f64>, wet: f64, crack: f64, grass: Array<f64>, drape: f64, ledge: f64, back: f64, foam: f64, boulder: Array<f64>, shrub: f64, cave: f64) {
        this.rock = rock;
        this.wet = wet;
        this.crack = crack;
        this.grass = grass;
        this.drape = drape;
        this.ledge = ledge;
        this.back = back;
        this.foam = foam;
        this.boulder = boulder;
        this.shrub = shrub;
        this.cave = cave;
    }
    // table.clone: shallow (shares the tone lists)
    clone(): Look {
        return new Look(this.rock, this.wet, this.crack, this.grass, this.drape, this.ledge, this.back, this.foam, this.boulder, this.shrub, this.cave);
    }
}

export const COAST = new Look(seq([0x5A7792, 0x4F6B86, 0x445F79, 0x66819C, 0x57738E]), 0x2F3D4E, 0x28354A,
    seq([0x9C8628, 0x857526, 0xA89232]), 0x8E7D2A, 0x978328, 0x546C84, 0xF4FAFF, seq([0x475A6E, 0x53677C, 0x384B5E]), 0x6E6C2A, 0x1B2330);

// Canyon walls: stronger light / dark slate bands with ochre seams.
export const COAST_CANYON = new Look(seq([0x536E8A, 0x6A849E, 0x3E556E, 0x7890A8, 0x455E78, 0x5C7894]), 0x2A3748, 0x212C3C,
    seq([0x9C8628, 0x857526, 0xA89232]), 0x8E7D2A, 0x978328, 0x4E657C, 0xF4FAFF, seq([0x475A6E, 0x53677C, 0x384B5E]), 0x6E6C2A, 0x161E2A);

// Paler, bluer layer for distant headlands (aerial perspective baked in).
export const COAST_FAR = new Look(seq([0x7F98AE, 0x7690A8, 0x86A0B5]), 0x5E7890, 0x6A8298,
    seq([0xA99E58, 0x9E955A, 0xB3A762]), 0x9D945A, 0xA59B5A, 0x7690A8, 0xF4FAFF, seq([0x6E88A0]), 0x8C8C5E, 0x4A5E74);

export const VIOLET = new Look(seq([0x8656C6, 0x7649B6, 0x673EA6, 0x9062D0, 0x7C4EBC]), 0x33206E, 0x2E1C6A,
    seq([0xC6F5FC, 0xA9EAF8, 0xE6FCFF]), 0xA4E6F6, 0xBDF1FB, 0x6C48B8, 0xF0FEFF, seq([0x5A3CA2, 0x6C48B8, 0x4A3294]), 0x8ED8F0, 0x1A0E48);

// Violet lagoon walls: rock tops with frost in patches.
function violetWall(): Look {
    let l = VIOLET.clone();
    l.grass = seq([0x8458C4, 0xC6F5FC, 0x7348B2]);
    return l;
}
export const VIOLET_WALL = violetWall();

// True for the looks built in violet chunks (after the portal).
export function isViolet(look: Look): bool {
    return look == VIOLET || look == VIOLET_WALL;
}

// Strip spec -----------------------------------------------------------------------

// Rail callback (Luau `rail(s) -> (Vector, Vector)`): at(s) sets p (rail
// position) and rt (right, horizontal unit).
export abstract class Rail {
    p: Vector = Vector.xyz(0, 0, 0);
    rt: Vector = Vector.xyz(1, 0, 0);
    abstract at(s: f64): void;
}

export type Fn = (s: f64) => f64;
export type LimitFn = (s: f64, side: f64) => f64;

// Shared by a strip's pieces (runs computed once).
export class StripCache {
    runs: Array<Array<f64>>? = null; // 1-based list of { a, z } (1-based) column ranges
    fits: Array<i32>? = null; // 1-based by k - gk0 + 1: -1 nil, 0 false, 1 true
}

export class StripSpec {
    s0: f64 = 0; // this piece
    s1: f64 = 0;
    gs0: f64 = 0; // whole strip (end taper + caps)
    gs1: f64 = 0;
    side: f64 = 1; // +1 right of the rail, -1 left
    step: f64 = 6;
    coast: Fn = (s: f64): f64 => 0.0; // waterline foot, lateral m from the rail
    edge: Fn = (s: f64): f64 => 0.0; // cliff-edge height
    rise: Fn = (s: f64): f64 => 0.0; // the top climbs this much from the edge to the crest
    depth: Fn = (s: f64): f64 => 0.0; // crest distance inland from the lip
    look: Look = COAST;
    seed: f64 = 0;
    rail: Rail? = null; // required
    limit: LimitFn? = null; // max lateral distance (inside of curves)
    back: f64 = NaN; // back slope length behind the crest
    lean: f64 = NaN; // face lean back per m of height
    facet: f64 = NaN; // facet in/out amplitude (m)
    ledge: f64 = NaN; // ledge depth (m), 0 = none
    drape: f64 = NaN; // grass tongue depth (m)
    hills: f64 = NaN; // rolling amplitude on the top (m)
    strata: f64 = NaN; // face bands
    tiers: f64 = NaN; // independent facet tiers up the face
    ink: f64 = NaN;
    foam: bool = true; // Luau: foam ~= false
    boulders: f64 = NaN; // per 100 m
    cracks: f64 = NaN; // chance per column
    crevices: f64 = NaN; // seam density between columns (default 0.9)
    endTaper: f64 = NaN; // m over which the strip ends sink
    startTaper: f64 = NaN; // the gs0 end only (default endTaper)
    collide: bool = true; // Luau: collide ~= false
    base: f64 = NaN; // bottom of the face (default -4)
    blocky: bool = false; // Luau: blocky == true
    flats: Array<Array<f64>>? = null; // plateaus on the top: 1-based list of 1-based { s, lateral, radius, y }
    far: bool = false; // distant layer: no boulders, cracks or foam (Luau: if sp.far)
    shrubs: f64 = NaN; // chance of gorse / an outcrop per column
    caves: f64 = NaN; // chance of a sea cave per column (0 = none)
    bands: f64 = NaN; // darkness of the dark strata bands (default 0.84)
    cache: StripCache? = null; // shared by a strip's pieces
    flute: f64 = NaN; // groove depth of the crease between columns (m)
    piece: f64 = NaN; // scenery's piece length (StripCfg; not read here)

    // table.clone: shallow (shares cache, flats, look, closures, rail)
    clone(): StripSpec {
        let c = new StripSpec();
        c.s0 = this.s0;
        c.s1 = this.s1;
        c.gs0 = this.gs0;
        c.gs1 = this.gs1;
        c.side = this.side;
        c.step = this.step;
        c.coast = this.coast;
        c.edge = this.edge;
        c.rise = this.rise;
        c.depth = this.depth;
        c.look = this.look;
        c.seed = this.seed;
        c.rail = this.rail;
        c.limit = this.limit;
        c.back = this.back;
        c.lean = this.lean;
        c.facet = this.facet;
        c.ledge = this.ledge;
        c.drape = this.drape;
        c.hills = this.hills;
        c.strata = this.strata;
        c.tiers = this.tiers;
        c.ink = this.ink;
        c.foam = this.foam;
        c.boulders = this.boulders;
        c.cracks = this.cracks;
        c.crevices = this.crevices;
        c.endTaper = this.endTaper;
        c.startTaper = this.startTaper;
        c.collide = this.collide;
        c.base = this.base;
        c.blocky = this.blocky;
        c.flats = this.flats;
        c.far = this.far;
        c.shrubs = this.shrubs;
        c.caves = this.caves;
        c.bands = this.bands;
        c.cache = this.cache;
        c.flute = this.flute;
        c.piece = this.piece;
        return c;
    }
}

function paintMul(b: Builder, hex: f64, f: f64): void {
    mathx.rgb(hex);
    meshgen.colorf(b, mathx.RGB_R * f, mathx.RGB_G * f, mathx.RGB_B * f);
}

@inline function quad(
    b: Builder,
    ax: f64, ay: f64, az: f64,
    bx: f64, by: f64, bz: f64,
    cx: f64, cy: f64, cz: f64,
    dx: f64, dy: f64, dz: f64,
    hx: f64, hy: f64, hz: f64
): void {
    meshgen.quadFlat(b, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, hx, hy, hz);
}

// id: ledge patch index (0 = plain row); amp: wander of the row along the strip (face fraction)
export class Row {
    t: f64 = 0;
    tier: f64 = 1;
    back: f64 = 0;
    id: f64 = 0;
    amp: f64 = 0;
}

function row(t: f64, tier: f64, back: f64, id: f64): Row {
    let r = new Row();
    r.t = t;
    r.tier = tier;
    r.back = back;
    r.id = id;
    return r;
}

export class Col {
    s: f64 = 0;
    px: f64 = 0;
    pz: f64 = 0;
    ox: f64 = 0;
    oz: f64 = 0;
    fx: Array<f64> = [0.0]; // face rows (1-based)
    fy: Array<f64> = [0.0];
    fz: Array<f64> = [0.0];
    tx: Array<f64> = [0.0]; // top rows (1-based)
    ty: Array<f64> = [0.0];
    tz: Array<f64> = [0.0];
    e: f64 = 0;
    foot: f64 = 0;
    fk: f64 = 0;
    streak: f64 = 0;
    crack: bool = false;
    ea: f64 = 0;
    brk: Array<bool> = [false]; // face row j..j+1 runs along a facet edge (a crevice), 1-based
}

// Row template shared by the whole strip: fractions of the face height,
// facet tiers and ledges. A tier boundary or a ledge is two rows at the same
// height (a shelf, or an overhang when the upper tier juts out). 1-based.
export function template(sp: StripSpec): Array<Row> {
    let r = mathx.rng(sp.seed * 7 + 3);
    let n = opt(sp.strata, 5);
    let rows: Array<Row> = [new Row()];
    let ledge = opt(sp.ledge, 1.6);
    let nTier = opt(sp.tiers, 2);
    let tier = 1.0;
    let nl = 0.0;
    // which strata rows become tier boundaries
    let bounds = new Array<bool>(<i32>n + 1);
    let placed = 0.0;
    let guard = 0;
    while (placed < nTier - 1 && guard < 50) {
        guard += 1;
        let q = <i32>mathx.randInt(r, 1, n - 1);
        if (!bounds[q]) {
            bounds[q] = true;
            placed += 1;
        }
    }
    let nq = <i32>n - 1;
    for (let q = 1; q <= nq; q++) {
        let t = <f64>q / n + randRange(r, -0.28, 0.28) / n;
        rows.push(row(t, tier, 0, 0));
        if (bounds[q]) {
            tier += 1;
            nl += 1;
            rows.push(row(t, tier, ledge * randRange(r, 0.2, 0.9), nl));
        } else if (ledge > 0 && q > 1 && rand(r) < 0.35) {
            nl += 1;
            rows.push(row(t, tier, ledge * randRange(r, 0.6, 1.3), nl));
        }
    }
    // strata and tier lines wander along the strip: each row may drift by
    // 30% of the gap to its neighbours (rows sharing a height drift together)
    let nr = rows.length - 1;
    for (let i = 1; i <= nr; i++) {
        let rw = rows[i];
        let below = rw.t, above = 1 - rw.t;
        for (let j = i - 1; j >= 1; j--) {
            if (rows[j].t < rw.t - 1e-6) {
                below = rw.t - rows[j].t;
                break;
            }
        }
        for (let j = i + 1; j <= nr; j++) {
            if (rows[j].t > rw.t + 1e-6) {
                above = rows[j].t - rw.t;
                break;
            }
        }
        rw.amp = 0.3 * lmin(below, above);
    }
    return rows;
}

// Facet offset of column k in a tier: piecewise linear between irregular
// breakpoints (every 1-4 columns): a few big planar fracture facets.
function isBreak(k: f64, tier: f64, seed: f64): bool {
    return mod(k, 4) == 0 || hash(k * 0.917 + tier * 13.1, seed * 0.023) < 0.4;
}

function breakOff(k: f64, tier: f64, seed: f64): f64 {
    return (hash(k * 1.731 + tier * 5.3, seed * 0.031) - 0.5) * 2;
}

function facetOff(k: f64, tier: f64, seed: f64, blocky: bool): f64 {
    if (blocky) {
        // square pillars: runs of columns at one offset, abrupt steps
        let blk = Math.floor((k + Math.floor(hash(Math.floor(k / 3) * 0.7 + tier, seed * 0.03) * 3)) / 2.5);
        return (hash(blk * 2.13 + tier * 3.7, seed * 0.017) - 0.5) * 1.8;
    }
    if (isBreak(k, tier, seed)) return breakOff(k, tier, seed);
    let kp = k - 1, kn = k + 1;
    while (!isBreak(kp, tier, seed)) kp -= 1;
    while (!isBreak(kn, tier, seed)) kn += 1;
    let t = (k - kp) / (kn - kp);
    return breakOff(kp, tier, seed) * (1 - t) + breakOff(kn, tier, seed) * t;
}

function limitOf(sp: StripSpec, s: f64): f64 {
    let lf = sp.limit;
    if (lf != null) return lf(s, sp.side);
    return HUGE;
}

// Soft cap on lateral distance: untouched below 60% of the limit, then
// eased toward it (monotonic, so rows never fold or collapse).
function softLimit(lat: f64, lim: f64): f64 {
    if (lim == HUGE) return lat;
    let k = lim * 0.6;
    if (lat <= k) return lat;
    let span = lim - k;
    return k + span * (1 - Math.exp(-(lat - k) / span));
}

const FR: StaticArray<f64> = [0.1, 0.24, 0.42, 0.62, 0.82, 1];

// Column k of the strip (world-space rows), deterministic per k.
export function column(sp: StripSpec, tpl: Array<Row>, k: f64): Col {
    let side = sp.side, seed = sp.seed;
    let s = k * sp.step;
    let rail = sp.rail!;
    rail.at(s);
    let px = <f64>rail.p.x, pz = <f64>rail.p.z;
    let ox = <f64>rail.rt.x * side, oz = <f64>rail.rt.z * side;
    let taper = opt(sp.endTaper, 60);
    let ea = smoothstep(sp.gs0, sp.gs0 + opt(sp.startTaper, taper), s) * smoothstep(sp.gs1, sp.gs1 - taper, s);
    let lim = limitOf(sp, s);
    let foot = sp.coast(s);
    let base = opt(sp.base, -4);
    // strip ends round off into a headland tip: every row converges on a
    // point inland while the height eases down a little
    let conv = Math.pow(1 - ea, 1.6);
    let e = lmax(2.2, sp.edge(s) * (0.72 + 0.28 * ea));
    let rise = sp.rise(s) * ea;
    let dep = sp.depth(s);
    let tipLat = foot + lmin(dep * 0.3, 40) + 6;
    let lean = opt(sp.lean, 0.1);
    let facet = opt(sp.facet, 2.6);
    // facet offsets per tier (planar facets), plus a slow bulge
    let blocky = sp.blocky;
    let bulge = (noise2(k * 0.06, seed * 0.07) - 0.5) * facet * 1.4;
    let fk = facet * facetOff(k, 1, seed, blocky) + bulge;
    let streak = 1 + (hash(k * 0.91, seed * 0.051) - 0.5) * 0.1;
    if (hash(k * 2.31, seed * 0.19) > 0.8) streak *= 0.86;
    let crack = hash(k * 0.731, seed * 0.1) < opt(sp.cracks, 0.28);
    // grass tongue depth at the lip
    let drape = opt(sp.drape, 2.6);
    let dd = drape * (mod(k, 2) == 0 ? 0.55 + 0.75 * hash(k * 3.3, seed) : 0.12 + 0.35 * hash(k * 5.1, seed));
    if (hash(k * 0.47, seed * 0.3) > 0.9) dd = drape * 2.8; // a long tongue
    dd = lmin(dd, (e - 0.9) * 0.35);
    let topFace = e - dd;
    let c = new Col();
    c.s = s;
    c.px = px;
    c.pz = pz;
    c.ox = ox;
    c.oz = oz;
    c.e = e;
    c.foot = foot;
    c.fk = fk;
    c.streak = streak;
    c.crack = crack;
    c.ea = ea;
    let leanK = blocky ? lean * 0.3 : lean;
    // base (talus under the water) and the wave-cut notch
    let l = foot + fk * 0.5 - 1.4;
    put(c, softLimit(l + (tipLat - l) * conv, lim), base);
    l = foot + fk + 0.7;
    put(c, softLimit(l + (tipLat - l) * conv, lim), 0.9 + (hash(k * 0.7, seed) - 0.5) * (blocky ? 0.3 : 1.0));
    let setback = 0.0;
    let lastTier = 1.0;
    let b1 = isBreak(k, 1, seed);
    c.brk.push(false);
    c.brk.push(b1);
    let tilt = blocky ? 0.0 : facet * 0.5;
    for (let ri = 1; ri < tpl.length; ri++) {
        let rw = tpl[ri];
        // tier lines wander: a slow drift plus a per-column kick (bounded by
        // amp, so rows never cross)
        let wn = (noise2(k * 0.23 + rw.t * 17.3, seed * 0.07 + 3.1) - 0.5) * 2;
        let wh = (hash(k * 0.917 + rw.t * 5.3, seed * 0.029) - 0.5) * 2;
        let wob = (wn * 0.6 + wh * 0.4) * rw.amp;
        let y = 0.9 + (topFace - 0.9) * (rw.t + wob);
        if (rw.id > 0) {
            // ledges run along the face in patches
            let ln = noise2(k * 0.21 + rw.id * 7.7, seed * 0.11 + rw.id);
            setback += rw.back * saturate((ln - 0.3) / 0.4);
        }
        lastTier = rw.tier;
        // crags: each face vertex stands a little in or out
        let crag = tilt * (hash(k * 1.37 + <f64>ri * 0.71, seed * 0.057) - 0.5);
        l = foot + (facet * facetOff(k, rw.tier, seed, blocky) + bulge) + leanK * (y - 0.9) + setback + crag;
        put(c, softLimit(l + (tipLat - l) * conv, lim), y);
        c.brk.push(isBreak(k, rw.tier, seed) && !blocky);
    }
    c.brk.push(false);
    // drape start and lip (grass overhang toward the rail)
    let ft = facet * facetOff(k, lastTier, seed, blocky) + bulge;
    l = foot + ft * 0.8 + leanK * (topFace - 0.9) + setback;
    put(c, softLimit(l + (tipLat - l) * conv, lim), topFace);
    let lipLat = foot + ft * 0.55 + leanK * (e - 0.9) + setback - 0.7;
    put(c, softLimit(lipLat + (tipLat - lipLat) * conv, lim), e);
    // top rows
    let hills = opt(sp.hills, 5);
    top(c, softLimit(lipLat + (tipLat - lipLat) * conv, lim), e, e, conv);
    let l1 = lipLat + 1.3;
    top(c, softLimit(l1 + (tipLat - l1) * conv, lim), e + 0.45, e, conv);
    let crestY = e;
    let flats = sp.flats;
    for (let fi = 0; fi < 6; fi++) {
        let f = FR[fi];
        let lat = l1 + dep * f;
        let prof = 1 - Math.pow(1 - f, 1.7);
        let hn = (mathx.fbm2(s * 0.011 + seed * 0.01, lat * 0.013 + seed * 0.003, 3) / 0.875 - 0.5) * 2;
        let y = e + 0.45 + rise * prof + hills * hn * lmin(1, f * 2.2) * ea;
        if (flats != null) {
            for (let i = 1; i < flats.length; i++) {
                let fl = flats[i];
                let ds = s - fl[1], dl = lat - fl[2];
                let d = Math.sqrt(ds * ds + dl * dl);
                let wgt = smoothstep(fl[3], fl[3] * 0.45, d);
                y += (fl[4] - y) * wgt;
            }
        }
        crestY = y;
        top(c, softLimit(lat + (tipLat - lat) * conv, lim), y, e, conv);
    }
    let back = opt(sp.back, 30);
    l = l1 + dep + back * 0.5;
    top(c, softLimit(l + (tipLat - l) * conv, lim), crestY - lmax(3, rise * 0.25), e, conv);
    l = l1 + dep + back;
    top(c, softLimit(l + (tipLat - l) * conv, lim), lmax(e * 0.4, 2), e, conv);
    l = l1 + dep + back + 8;
    top(c, softLimit(l + (tipLat - l) * conv, lim), base, e, conv);
    return c;
}

// Luau column's put / top (l: the limited lateral distance)
@inline function put(c: Col, l: f64, y: f64): void {
    c.fx.push(c.px + c.ox * l);
    c.fy.push(y);
    c.fz.push(c.pz + c.oz * l);
}

@inline function top(c: Col, l: f64, y: f64, e: f64, conv: f64): void {
    c.tx.push(c.px + c.ox * l);
    c.ty.push(y + (e - y) * conv * (y > 0 ? 1.0 : 0.0));
    c.tz.push(c.pz + c.oz * l);
}

// Turn-limit runs ---------------------------------------------------------------

// Runs of columns that fit inside the turn limit (the same for every piece
// of a strip: computed once when the strip shares a cache; scenery bakes it
// as its own steps before the pieces). Null when the strip has no limit.
function fitsAt(sp: StripSpec, k: f64): bool {
    let s = k * sp.step;
    let lim = limitOf(sp, s);
    return lim == HUGE || sp.coast(s) + 0.5 * sp.depth(s) < 0.9 * lim;
}

// Columns per bake step when a long strip's runs are computed in parts.
export const RUNS_PART: f64 = 48;

// Number of bake steps `runsPart` needs for the strip (0: no limit).
export function runsParts(sp: StripSpec): i32 {
    if (sp.limit == null) return 0;
    let n = Math.floor(sp.gs1 / sp.step) - Math.ceil(sp.gs0 / sp.step) + 1;
    return <i32>lmax(1, Math.ceil(n / RUNS_PART));
}

// Part `part` (1-based) of `parts` of the turn-limit test (cached on
// sp.cache); the last part assembles the runs.
export function runsPart(sp: StripSpec, part: i32, parts: i32): void {
    let cache = sp.cache;
    if (sp.limit == null || cache == null || cache.runs != null) return;
    let step = sp.step;
    let gk0 = Math.ceil(sp.gs0 / step), gk1 = Math.floor(sp.gs1 / step);
    let fitsT = cache.fits;
    if (fitsT == null) {
        fitsT = [-1];
        cache.fits = fitsT;
    }
    let span = gk1 - gk0 + 1;
    let ka = gk0 + Math.floor(span * <f64>(part - 1) / <f64>parts);
    let kb = gk0 + Math.floor(span * <f64>part / <f64>parts) - 1;
    for (let k = ka; k <= kb; k += 1) {
        let idx = <i32>(k - gk0 + 1);
        while (fitsT.length <= idx) fitsT.push(-1);
        fitsT[idx] = fitsAt(sp, k) ? 1 : 0;
    }
    if (part == parts) {
        runs(sp);
        cache.fits = null;
    }
}

// 1-based list of 1-based { first, last } column ranges; null without a limit.
export function runs(sp: StripSpec): Array<Array<f64>>? {
    if (sp.limit == null) return null;
    let step = sp.step;
    let gk0 = Math.ceil(sp.gs0 / step), gk1 = Math.floor(sp.gs1 / step);
    let cache = sp.cache;
    let rr: Array<Array<f64>>? = cache != null ? cache.runs : null;
    if (rr == null) {
        let fitsT: Array<i32>? = cache != null ? cache.fits : null;
        let list: Array<Array<f64>> = [[0.0]];
        let ra = NaN; // nil
        let k = gk0;
        while (k <= gk1 + 1) {
            let ok = false;
            if (k <= gk1) {
                let idx = <i32>(k - gk0 + 1);
                if (fitsT != null && idx < fitsT.length && fitsT[idx] >= 0) ok = fitsT[idx] == 1;
                else ok = fitsAt(sp, k);
            }
            if (ok && isNaN(ra)) {
                ra = k;
            } else if (!ok && !isNaN(ra)) {
                let a = ra, z = k - 1;
                ra = NaN;
                if (z - a >= 4) list.push([0.0, a, z]);
            }
            k += 1;
        }
        rr = list;
        if (cache != null) cache.runs = list;
    }
    return rr;
}

// Build the strip piece (sp.s0..s1) now. Appends colliders.
export function strip(b: Builder, sp: StripSpec, cols: Array<Collider>?): void {
    let rr = runs(sp);
    if (rr == null) {
        buildPiece(b, sp, cols);
        return;
    }
    let step = sp.step;
    for (let i = 1; i < rr.length; i++) {
        let rn = rr[i];
        let a0 = rn[1] * step, a1 = rn[2] * step;
        if (sp.s1 > a0 && sp.s0 < a1) {
            let run = sp.clone();
            run.gs0 = a0;
            run.gs1 = a1;
            buildPiece(b, run, cols);
        }
    }
}

function buildPiece(b: Builder, sp: StripSpec, cols: Array<Collider>?): void {
    let pc = new Piece(b, sp, cols);
    if (pc.setup()) {
        pc.face();
        pc.top();
        pc.decor();
    }
}

// stripJob: each step() runs the next part (the runs, a run's setup, face,
// top, decorations) and returns true when done. Output identical to strip.
class Task {
    kind: i32; // 0 runs, 1 build a run's setup, 2 face, 3 top, 4 decor
    sp: StripSpec;
    pc: Piece?;
    constructor(kind: i32, sp: StripSpec, pc: Piece?) {
        this.kind = kind;
        this.sp = sp;
        this.pc = pc;
    }
}

export class StripJob {
    b: Builder;
    sp: StripSpec;
    cols: Array<Collider>?;
    q: Array<Task?> = [];
    qi: i32 = 0;
    ins: i32 = 0;

    constructor(b: Builder, sp: StripSpec, cols: Array<Collider>?) {
        this.b = b;
        this.sp = sp;
        this.cols = cols;
        this.q.push(new Task(0, sp, null));
    }

    // Luau table.insert(q, ins, fn); ins += 1
    defer(t: Task): void {
        let q = this.q;
        q.push(null);
        for (let i = q.length - 1; i > this.ins; i--) q[i] = q[i - 1];
        q[this.ins] = t;
        this.ins += 1;
    }

    build(sp: StripSpec): void {
        let pc = new Piece(this.b, sp, this.cols);
        if (pc.setup()) {
            this.defer(new Task(2, sp, pc));
            this.defer(new Task(3, sp, pc));
            this.defer(new Task(4, sp, pc));
        }
    }

    run(t: Task): void {
        let k = t.kind;
        if (k == 0) {
            let sp = t.sp;
            let rr = runs(sp);
            if (rr == null) {
                this.build(sp);
                return;
            }
            let step = sp.step;
            for (let i = 1; i < rr.length; i++) {
                let rn = rr[i];
                let a0 = rn[1] * step, a1 = rn[2] * step;
                if (sp.s1 > a0 && sp.s0 < a1) {
                    let run = sp.clone();
                    run.gs0 = a0;
                    run.gs1 = a1;
                    this.defer(new Task(1, run, null));
                }
            }
        } else if (k == 1) {
            this.build(t.sp);
        } else {
            let pc = t.pc!;
            if (k == 2) pc.face();
            else if (k == 3) pc.top();
            else pc.decor();
        }
    }

    step(): bool {
        let q = this.q;
        if (this.qi >= q.length) return true;
        let t = q[this.qi];
        if (t == null) return true;
        this.ins = this.qi + 1;
        this.run(t);
        q[this.qi] = null;
        this.qi += 1;
        return this.qi >= q.length || q[this.qi] == null;
    }
}

// The same strip piece as a job for the bake (Luau returns a closure).
export function stripJob(b: Builder, sp: StripSpec, cols: Array<Collider>?): () => bool {
    let job = new StripJob(b, sp, cols);
    return (): bool => job.step();
}

// One piece of the strip (Luau buildPiece): setup() builds the columns and
// the crease lattice; face / top / decor emit the rest.
class Piece {
    b: Builder;
    sp: StripSpec;
    cols: Array<Collider>?;
    look: Look;
    gk0: f64 = 0;
    gk1: f64 = 0;
    k0: f64 = 0;
    k1: f64 = 0;
    data: Array<Col> = [];
    prev: Col = new Col();
    nxt: Col = new Col();
    nCol: i32 = 0;
    qEnd: i32 = 0;
    nr: i32 = 0;
    nt: i32 = 0;
    r: Rng = new Rng();
    col0: u32 = 0;
    aux0: u32 = 0;
    v0: i32 = 0;
    i0: i32 = 0;
    tones: Array<f64> = [0.0];
    tf: Array<f64> = [0.0];
    seed: f64 = 0;
    fl: f64 = 0;
    rTier: Array<f64> = [0.0];
    rT: Array<f64> = [0.0];
    rAmp: Array<f64> = [0.0];
    rShelf: Array<bool> = [false];
    // crease points per column pair and face row (x, y, z, fraction, depth)
    MX: Array<Array<f64>> = [[0.0]];
    MY: Array<Array<f64>> = [[0.0]];
    MZ: Array<Array<f64>> = [[0.0]];
    MF: Array<Array<f64>> = [[0.0]];
    MD: Array<Array<f64>> = [[0.0]];
    MG: Array<f64> = [0.0]; // deepest groove of the pair (crevice ink goes there)
    LOD: Array<i32> = [0];
    // surf / at / footAt outputs
    SX: f64 = 0;
    SY: f64 = 0;
    SZ: f64 = 0;
    AX: f64 = 0;
    AY: f64 = 0;
    AZ: f64 = 0;
    FOX: f64 = 0;
    FOZ: f64 = 0;

    constructor(b: Builder, sp: StripSpec, cols: Array<Collider>?) {
        this.b = b;
        this.sp = sp;
        this.cols = cols;
        this.look = sp.look;
    }

    setup(): bool {
        let sp = this.sp, b = this.b;
        let step = sp.step;
        let gk0 = Math.ceil(sp.gs0 / step), gk1 = Math.floor(sp.gs1 / step);
        let k0 = lmax(Math.floor(sp.s0 / step), gk0);
        let k1 = lmin(Math.ceil(sp.s1 / step), gk1);
        if (k1 <= k0) return false;
        this.gk0 = gk0;
        this.gk1 = gk1;
        this.k0 = k0;
        this.k1 = k1;
        let tpl = template(sp);
        let look = this.look;
        let data: Array<Col> = [new Col()];
        for (let k = k0; k <= k1; k += 1) data.push(column(sp, tpl, k));
        this.data = data;
        // neighbours for smooth top normals across piece seams
        this.prev = column(sp, tpl, k0 - 1);
        this.nxt = column(sp, tpl, k1 + 1);
        let nCol = data.length - 1;
        this.nCol = nCol;
        // the seam column belongs to the next piece's decorations
        this.qEnd = k1 < gk1 ? nCol - 1 : nCol;
        let nr = data[1].fy.length - 1;
        this.nr = nr;
        this.nt = data[1].ty.length - 1;
        this.r = mathx.rng(sp.seed + k0 * 31);
        this.col0 = b.col;
        this.aux0 = b.aux;
        this.v0 = b.vcount;
        this.i0 = b.icount;
        meshgen.aux(b, 0, 1, 0, 0);

        // rock tones per band: bands alternate lighter / darker with the odd accent
        let tr = mathx.rng(sp.seed * 3 + 1);
        let tones = this.tones, tf = this.tf;
        let dark = rand(tr) < 0.5;
        for (let j = 1; j <= nr; j++) {
            if (j == 1 || rand(tr) > 0.3) dark = !dark;
            tones.push(look.rock[<i32>mathx.randInt(tr, 1, len(look.rock))]);
            let bd = opt(sp.bands, 0.84);
            tf.push(dark ? randRange(tr, bd, bd + 0.06) : randRange(tr, 1.0, 1.08));
        }

        // fluting: each face quad folds along a crease between its two columns
        let seed = sp.seed;
        this.seed = seed;
        let fl = (sp.far || sp.blocky) ? 0.0 : opt(sp.flute, opt(sp.facet, 2.6) * 0.75);
        this.fl = fl;
        let rTier = this.rTier, rT = this.rT, rAmp = this.rAmp, rShelf = this.rShelf;
        rTier.push(1); rTier.push(1);
        rT.push(-1); rT.push(-2);
        rAmp.push(0); rAmp.push(0);
        rShelf.push(false); rShelf.push(false);
        let lastT = -1.0;
        for (let i = 1; i < tpl.length; i++) {
            let rw = tpl[i];
            rTier.push(rw.tier);
            rT.push(rw.t);
            rAmp.push(rw.amp);
            rShelf.push(Math.abs(rw.t - lastT) < 1e-9);
            lastT = rw.t;
        }
        let lt = tpl.length - 1 > 0 ? tpl[tpl.length - 1].tier : 1;
        for (let i = 0; i < 2; i++) {
            rTier.push(lt);
            rT.push(-3);
            rAmp.push(0);
            rShelf.push(false);
        }
        // detail by distance: 2 creases + folded halves, 1 creases only, 0 plain panels
        let flOk = fl > 0 && !isViolet(look);
        let LOD = this.LOD;
        for (let q = 1; q <= nCol - 1; q++) {
            let a = data[q], c = data[q + 1];
            let kq = k0 + <f64>q - 1;
            let near = lmin(a.foot, c.foot);
            LOD.push(!flOk || near > 220 ? 0 : near > 70 ? 1 : 2);
            let f0 = 0.3 + 0.4 * hash(kq * 0.713 + 1.3, seed * 0.047);
            let ox = (a.ox + c.ox) * 0.5, oz = (a.oz + c.oz) * 0.5;
            let hA = a.fy[nr - 1] - 0.9, hC = c.fy[nr - 1] - 0.9;
            let live = LOD[q] > 0 && a.ea > 0.3 && c.ea > 0.3;
            let xs: Array<f64> = [0.0], ys: Array<f64> = [0.0], zs: Array<f64> = [0.0], fs: Array<f64> = [0.0], ds: Array<f64> = [0.0];
            let dPrev = 0.0, g = 0.0;
            for (let j = 1; j <= nr; j++) {
                let f = f0, d = 0.0, jy = 0.0;
                if (live) {
                    if (rShelf[j]) {
                        d = dPrev;
                    } else if (j == 2) {
                        d = this.creaseD(kq, 1) * 0.45;
                    } else if (j == nr - 1) {
                        d = this.creaseD(kq, rTier[j]) * 0.35;
                    } else if (j > 2 && j < nr - 1) {
                        d = this.creaseD(kq, rTier[j]) * (0.5 + 0.9 * hash(kq * 2.1 + <f64>j * 0.37, seed * 0.11));
                    }
                    if (rT[j] >= 0) {
                        f += (hash(kq * 3.3 + rT[j] * 13.7, seed * 0.13) - 0.5) * 0.14;
                        jy = (hash(kq * 0.37 + rT[j] * 31.7, seed * 0.41) - 0.5) * rAmp[j] * (hA + (hC - hA) * f);
                    }
                }
                dPrev = d;
                if (j > 2 && j < nr - 1) g = lmax(g, d);
                xs.push(a.fx[j] + (c.fx[j] - a.fx[j]) * f + ox * d);
                ys.push(a.fy[j] + (c.fy[j] - a.fy[j]) * f + jy);
                zs.push(a.fz[j] + (c.fz[j] - a.fz[j]) * f + oz * d);
                fs.push(f);
                ds.push(d);
            }
            this.MX.push(xs);
            this.MY.push(ys);
            this.MZ.push(zs);
            this.MF.push(fs);
            this.MG.push(g);
            this.MD.push(ds);
        }
        return true;
    }

    creaseD(kq: f64, tier: f64): f64 {
        let seed = this.seed;
        let h = hash(kq * 1.913 + tier * 7.1, seed * 0.061);
        if (h < 0.16) return 0; // a broad facet stays whole
        let amp = this.fl * (0.35 + 0.65 * hash(kq * 0.37 + tier * 1.3, seed * 0.09));
        return h < 0.3 ? -lmin(0.25, 0.3 * amp) : amp;
    }

    // point on the fluted face of pair q, row j, at fraction f across it -> SX, SY, SZ
    surf(q: i32, j: i32, f: f64): void {
        let a = this.data[q], c = this.data[q + 1];
        let fc = this.MF[q][j];
        let mx = this.MX[q][j], my = this.MY[q][j], mz = this.MZ[q][j];
        if (f <= fc) {
            let t = f / lmax(fc, 1e-6);
            this.SX = a.fx[j] + (mx - a.fx[j]) * t;
            this.SY = a.fy[j] + (my - a.fy[j]) * t;
            this.SZ = a.fz[j] + (mz - a.fz[j]) * t;
            return;
        }
        let t = (f - fc) / lmax(1 - fc, 1e-6);
        this.SX = mx + (c.fx[j] - mx) * t;
        this.SY = my + (c.fy[j] - my) * t;
        this.SZ = mz + (c.fz[j] - mz) * t;
    }

    // one face cell (row j..j+1 of pair q): two quads folded at the crease,
    // painted hex x fm. half: 0 both (Luau nil), 1 or 2.
    cell(q: i32, j: i32, hx: f64, hy: f64, hz: f64, hex: f64, fm: f64, half: i32): void {
        let b = this.b;
        let a = this.data[q], c = this.data[q + 1];
        let fl = this.fl;
        if (this.LOD[q] == 0) {
            paintMul(b, hex, fm);
            quad(b, a.fx[j], a.fy[j], a.fz[j], c.fx[j], c.fy[j], c.fz[j], c.fx[j + 1], c.fy[j + 1], c.fz[j + 1], a.fx[j + 1], a.fy[j + 1], a.fz[j + 1], hx, hy, hz);
            return;
        }
        let mx = this.MX[q], my = this.MY[q], mz = this.MZ[q];
        let md = this.MD[q];
        if (hy != 0 || this.LOD[q] == 1) {
            // shelves, overhangs and mid-distance faces: flat halves
            let dn = hy == 0 ? lclamp((md[j] + md[j + 1]) * 0.5 / fl, -1, 1) : 0.0;
            paintMul(b, hex, fm * (1 - 0.12 * dn));
            if (half != 2) {
                quad(b, a.fx[j], a.fy[j], a.fz[j], mx[j], my[j], mz[j], mx[j + 1], my[j + 1], mz[j + 1], a.fx[j + 1], a.fy[j + 1], a.fz[j + 1], hx, hy, hz);
            }
            if (half != 1) {
                paintMul(b, hex, fm * (1 + 0.04 * dn));
                quad(b, mx[j], my[j], mz[j], c.fx[j], c.fy[j], c.fz[j], c.fx[j + 1], c.fy[j + 1], c.fz[j + 1], mx[j + 1], my[j + 1], mz[j + 1], hx, hy, hz);
            }
            return;
        }
        // faces: each half folds along a diagonal too
        let dn = lclamp((md[j] + md[j + 1]) * 0.5 / fl, -1, 1);
        let kq = this.k0 + <f64>q - 1;
        for (let hh = 1; hh <= 2; hh++) {
            if (half == 0 || half == hh) {
                let p0x: f64, p0y: f64, p0z: f64, p1x: f64, p1y: f64, p1z: f64, p2x: f64, p2y: f64, p2z: f64, p3x: f64, p3y: f64, p3z: f64;
                if (hh == 1) {
                    p0x = a.fx[j]; p0y = a.fy[j]; p0z = a.fz[j];
                    p1x = mx[j]; p1y = my[j]; p1z = mz[j];
                    p2x = mx[j + 1]; p2y = my[j + 1]; p2z = mz[j + 1];
                    p3x = a.fx[j + 1]; p3y = a.fy[j + 1]; p3z = a.fz[j + 1];
                } else {
                    p0x = mx[j]; p0y = my[j]; p0z = mz[j];
                    p1x = c.fx[j]; p1y = c.fy[j]; p1z = c.fz[j];
                    p2x = c.fx[j + 1]; p2y = c.fy[j + 1]; p2z = c.fz[j + 1];
                    p3x = mx[j + 1]; p3y = my[j + 1]; p3z = mz[j + 1];
                }
                let hf = hh == 1 ? 1 - 0.12 * dn : 1 + 0.04 * dn;
                let hd = hash(kq * 1.37 + <f64>j * 0.53 + <f64>hh * 0.29, this.sp.seed * 0.071);
                let t2 = hd < 0.5 ? 0.95 : 1.03;
                if (hd < 0.5) {
                    paintMul(b, hex, fm * hf);
                    meshgen.flatTriFacing(b, p0x, p0y, p0z, p1x, p1y, p1z, p2x, p2y, p2z, hx, 0, hz);
                    paintMul(b, hex, fm * hf * t2);
                    meshgen.flatTriFacing(b, p0x, p0y, p0z, p2x, p2y, p2z, p3x, p3y, p3z, hx, 0, hz);
                } else {
                    paintMul(b, hex, fm * hf);
                    meshgen.flatTriFacing(b, p0x, p0y, p0z, p1x, p1y, p1z, p3x, p3y, p3z, hx, 0, hz);
                    paintMul(b, hex, fm * hf * t2);
                    meshgen.flatTriFacing(b, p1x, p1y, p1z, p2x, p2y, p2z, p3x, p3y, p3z, hx, 0, hz);
                }
            }
        }
    }

    face(): void {
        let b = this.b, sp = this.sp, look = this.look, data = this.data;
        let nCol = this.nCol, nr = this.nr, k0 = this.k0;
        let tones = this.tones, tf = this.tf;
        for (let q = 1; q <= nCol - 1; q++) {
            let a = data[q], c = data[q + 1];
            let hx = -(a.ox + c.ox) * 0.5, hz = -(a.oz + c.oz) * 0.5;
            let st = (a.streak + c.streak) * 0.5;
            let kq = k0 + <f64>q - 1;
            for (let j = 1; j <= nr - 1; j++) {
                let ay0 = a.fy[j], ay1 = a.fy[j + 1];
                let shelf = Math.abs(ay1 - ay0) < 0.05 && j > 1;
                if (shelf) {
                    // upper row further from the rail: a ledge; closer: an overhang
                    let la = (a.fx[j + 1] - a.fx[j]) * a.ox + (a.fz[j + 1] - a.fz[j]) * a.oz;
                    let lc = (c.fx[j + 1] - c.fx[j]) * c.ox + (c.fz[j + 1] - c.fz[j]) * c.oz;
                    if (la + lc >= 0) {
                        // grass in short tufts, half a cell at most
                        let split = this.LOD[q] > 0;
                        let nh = split ? 2 : 1;
                        for (let half = 1; half <= nh; half++) {
                            let gk = hash(kq * 0.73 + <f64>j * 1.9 + <f64>half * 0.371, sp.seed * 0.13);
                            let hf = split ? half : 0;
                            if (gk < 0.26) {
                                this.cell(q, j, 0, 1, 0, look.ledge, 1, hf);
                                if (split) {
                                    // a clump standing on the ledge
                                    let mf = this.MF[q][j];
                                    let fq = half == 1 ? mf * 0.5 : (1 + mf) * 0.5;
                                    this.surf(q, j, fq);
                                    let x0 = this.SX, y0 = this.SY, z0 = this.SZ;
                                    this.surf(q, j + 1, fq);
                                    let x1 = this.SX, z1 = this.SZ;
                                    let sz = 1.0 + 0.9 * hash(kq * 2.7 + <f64>j, sp.seed * 0.7);
                                    paintMul(b, look.ledge, 0.96);
                                    meshgen.rock(b, (x0 + x1) * 0.5, y0 + sz * 0.15, (z0 + z1) * 0.5, sz, sz * 0.62, sz * 0.9, kq * 3.1 + <f64>j, 5, 3);
                                }
                            } else {
                                this.cell(q, j, 0, 1, 0, tones[j], st * 0.92, hf);
                            }
                        }
                    } else {
                        this.cell(q, j, 0, -1, 0, tones[j], st * 0.9, 0);
                    }
                } else {
                    let hex = tones[j], fm = st * tf[j];
                    if (j == 1) {
                        hex = look.wet;
                        fm = 1;
                    } else if (j == nr - 1) {
                        hex = look.drape;
                        fm = 1;
                    }
                    this.cell(q, j, hx, j == nr - 1 ? 0.3 : 0, hz, hex, fm, 0);
                }
            }
        }
    }

    colAt(q: i32): Col {
        if (q < 1) return this.prev;
        if (q > this.nCol) return this.nxt;
        return this.data[q];
    }

    cap(c: Col, fx: f64, fz: f64): void {
        let b = this.b;
        let px: Array<f64> = [0.0], py: Array<f64> = [0.0], pz: Array<f64> = [0.0];
        for (let j = 1; j < c.fy.length; j++) {
            px.push(c.fx[j]);
            py.push(c.fy[j]);
            pz.push(c.fz[j]);
        }
        for (let m = 2; m < c.ty.length; m++) {
            px.push(c.tx[m]);
            py.push(c.ty[m]);
            pz.push(c.tz[m]);
        }
        let n = px.length - 1;
        let mx = 0.0, my = 0.0, mz = 0.0;
        for (let i = 1; i <= n; i++) {
            mx += px[i];
            my += py[i];
            mz += pz[i];
        }
        mx /= <f64>n;
        my /= <f64>n;
        mz /= <f64>n;
        meshgen.color(b, this.look.back);
        for (let i = 1; i <= n; i++) {
            let i2 = (i % n) + 1;
            meshgen.flatTriFacing(b, px[i], py[i], pz[i], px[i2], py[i2], pz[i2], mx, my, mz, fx, 0, fz);
        }
    }

    top(): void {
        let b = this.b, sp = this.sp, look = this.look, data = this.data;
        let nCol = this.nCol, nt = this.nt, k0 = this.k0, r = this.r;
        // top: smooth indexed grid
        let grid: Array<Array<i32>> = [[0]];
        let gph = sp.seed * 0.37;
        let nTop = nt - 1; // the last row belongs to the back face
        for (let q = 1; q <= nCol; q++) {
            let ids: Array<i32> = [0];
            let c0 = this.colAt(q), ca = this.colAt(q - 1), cb = this.colAt(q + 1);
            for (let m = 1; m <= nTop; m++) {
                let x = c0.tx[m], y = c0.ty[m], z = c0.tz[m];
                let ax = ca.tx[m], ay = ca.ty[m], az = ca.tz[m];
                let bx = cb.tx[m], by = cb.ty[m], bz = cb.tz[m];
                let mc = max(m - 1, 1), md = min(m + 1, nTop);
                let cx = c0.tx[mc], cy = c0.ty[mc], cz = c0.tz[mc];
                let dx = c0.tx[md], dy = c0.ty[md], dz = c0.tz[md];
                let ux = bx - ax, uy = by - ay, uz = bz - az;
                let vx = dx - cx, vy = dy - cy, vz = dz - cz;
                let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
                if (ny < 0) {
                    nx = -nx;
                    ny = -ny;
                    nz = -nz;
                }
                let l = Math.sqrt(nx * nx + ny * ny + nz * nz);
                if (l < 1e-9) {
                    nx = 0;
                    ny = 1;
                    nz = 0;
                    l = 1;
                }
                if (m == 1) {
                    meshgen.color(b, look.drape);
                } else {
                    let g = noise2(x * 0.021 + gph, z * 0.021);
                    let g2 = noise2(x * 0.07 - gph, z * 0.07);
                    let tone = g > 0.62 ? look.grass[2] : g2 > 0.72 ? look.grass[3] : look.grass[1];
                    meshgen.color(b, tone);
                }
                ids.push(meshgen.vertex(b, x, y, z, nx / l, ny / l, nz / l));
            }
            grid.push(ids);
        }
        for (let q = 1; q <= nCol - 1; q++) {
            let cq = data[q], cn = data[q + 1];
            for (let m = 1; m <= nTop - 1; m++) {
                let a = grid[q][m], bq = grid[q + 1][m], c = grid[q + 1][m + 1], d = grid[q][m + 1];
                let ax = cq.tx[m], az = cq.tz[m];
                let bx = cn.tx[m], bz = cn.tz[m];
                let cx = cq.tx[m + 1], cz = cq.tz[m + 1];
                let ny = (bz - az) * (cx - ax) - (bx - ax) * (cz - az);
                if (ny >= 0) {
                    meshgen.tri(b, a, bq, c);
                    meshgen.tri(b, a, c, d);
                } else {
                    meshgen.tri(b, a, c, bq);
                    meshgen.tri(b, a, d, c);
                }
            }
        }
        // back face down to the sea
        meshgen.color(b, look.back);
        for (let q = 1; q <= nCol - 1; q++) {
            let a = data[q], c = data[q + 1];
            quad(b, a.tx[nTop], a.ty[nTop], a.tz[nTop], c.tx[nTop], c.ty[nTop], c.tz[nTop], c.tx[nt], c.ty[nt], c.tz[nt], a.tx[nt], a.ty[nt], a.tz[nt], a.ox, 0.1, a.oz);
        }
        // end caps at the strip's ends
        if (k0 == this.gk0) {
            let c = data[1];
            this.cap(c, -c.oz * sp.side, c.ox * sp.side);
        }
        if (this.k1 == this.gk1) {
            let c = data[nCol];
            this.cap(c, c.oz * sp.side, -c.ox * sp.side);
        }
        let qEnd = this.qEnd;
        // boulders at the foot
        let nb = sp.far ? 0.0 : opt(sp.boulders, 7);
        if (nb > 0) {
            for (let q = 1; q <= qEnd; q++) {
                let c = data[q];
                if (hash(k0 + <f64>q + 0.3, sp.seed * 0.77) < nb * sp.step / 100 && c.ea > 0.3) {
                    let sz = randRange(r, 0.9, 3.4);
                    let lat = c.foot + c.fk - randRange(r, 0.2, 2.2) - sz * 0.6;
                    let x = c.px + c.ox * lat, z = c.pz + c.oz * lat;
                    meshgen.color(b, look.boulder[<i32>mathx.randInt(r, 1, len(look.boulder))]);
                    meshgen.rock(b, x, sz * randRange(r, -0.25, 0.2), z, sz, sz * randRange(r, 0.55, 0.85), sz * randRange(r, 0.7, 1.1), rand(r) * 100, 6, 4);
                }
            }
        }
        // gorse and rock outcrops on the top, thickest near the lip
        if (!sp.far) {
            let shrubs = opt(sp.shrubs, 0.35);
            for (let q = 1; q <= qEnd; q++) {
                let c = data[q];
                let hq = hash(c.s * 0.113 + 0.7, sp.seed * 0.31);
                if (hq < shrubs && c.ea > 0.4) {
                    let m = 2 + <i32>Math.floor(hash(c.s * 0.71, sp.seed) * 3);
                    let x = c.tx[m], y = c.ty[m], z = c.tz[m];
                    let jx = (hash(c.s * 1.3, 2.1) - 0.5) * sp.step;
                    let fwx = -c.oz, fwz = c.ox;
                    x += fwx * jx;
                    z += fwz * jx;
                    if (hq < shrubs * 0.25) {
                        let sz = randRange(r, 1.6, 3.4);
                        meshgen.color(b, look.boulder[<i32>mathx.randInt(r, 1, len(look.boulder))]);
                        meshgen.rock(b, x, y - sz * 0.35, z, sz, sz * 0.6, sz * 0.9, rand(r) * 100, 6, 4);
                    } else {
                        let sz = randRange(r, 1.1, 2.4);
                        meshgen.color(b, look.shrub);
                        meshgen.rock(b, x, y - sz * 0.15, z, sz * 1.2, sz * 0.55, sz, rand(r) * 100, 6, 3);
                        if (rand(r) < 0.5) {
                            meshgen.rock(b, x + fwx * sz * 1.3, y - sz * 0.2, z + fwz * sz * 1.3, sz * 0.8, sz * 0.4, sz * 0.7, rand(r) * 100, 5, 3);
                        }
                    }
                }
            }
        }
        meshgen.inkShell(b, this.v0, this.i0, opt(sp.ink, 1));
    }

    // Luau decor's at(f, dyv) -> AX, AY, AZ
    at(q: i32, j: i32, f: f64, dyv: f64, fy: f64, hx: f64, hz: f64): void {
        this.surf(q, j, f);
        let x0 = this.SX, y0 = this.SY, z0 = this.SZ;
        this.surf(q, j + 1, f);
        let x1 = this.SX, y1 = this.SY, z1 = this.SZ;
        this.AX = x0 + (x1 - x0) * fy + hx * 0.2;
        this.AY = y0 + (y1 - y0) * fy + dyv;
        this.AZ = z0 + (z1 - z0) * fy + hz * 0.2;
    }

    // point on the rock foot at fractional column u (1..nCol) -> SX, SZ, FOX, FOZ
    footAt(u: f64, off: f64): void {
        let data = this.data, nCol = this.nCol;
        let q = <i32>lclamp(Math.floor(u), 1, <f64>(nCol - 1));
        let f = lclamp(u - <f64>q, 0, 1);
        let a = data[q], c = data[q + 1];
        let lat = (a.foot + a.fk) * (1 - f) + (c.foot + c.fk) * f + 0.5 - off;
        let ox = a.ox + (c.ox - a.ox) * f, oz = a.oz + (c.oz - a.oz) * f;
        let px = a.px + (c.px - a.px) * f, pz = a.pz + (c.pz - a.pz) * f;
        this.SX = px + ox * lat;
        this.SZ = pz + oz * lat;
        this.FOX = ox;
        this.FOZ = oz;
    }

    decor(): void {
        let b = this.b, sp = this.sp, look = this.look, data = this.data;
        let nCol = this.nCol, nr = this.nr, k0 = this.k0, r = this.r, fl = this.fl, qEnd = this.qEnd;
        // crevices: dark strips along the facet edges, then a few zig-zag
        // cracks down the faces (no ink)
        meshgen.aux(b, 0, 0, 0, 0);
        meshgen.color(b, look.crack);
        if (!sp.far) {
            for (let q = 1; q <= qEnd; q++) {
                let c = data[q];
                if (c.ea > 0.5) {
                    let hx = -c.ox, hz = -c.oz;
                    let tx = -hz, tz = hx;
                    let w = 0.22 + 0.2 * hash(c.s * 0.37, sp.seed * 0.2);
                    for (let j = 2; j <= nr - 2; j++) {
                        if (c.brk[j] && c.brk[j + 1] && Math.abs(c.fy[j + 1] - c.fy[j]) > 0.5) {
                            let x0 = c.fx[j] + hx * 0.18, y0 = c.fy[j], z0 = c.fz[j] + hz * 0.18;
                            let x1 = c.fx[j + 1] + hx * 0.18, y1 = c.fy[j + 1], z1 = c.fz[j + 1] + hz * 0.18;
                            quad(b, x0 - tx * w, y0, z0 - tz * w, x0 + tx * w, y0, z0 + tz * w, x1 + tx * w, y1, z1 + tz * w, x1 - tx * w, y1, z1 - tz * w, hx, 0, hz);
                        }
                    }
                }
            }
        }
        // more crevices between the columns: dark seams at a random fraction
        // across a face quad, running over a few rows
        if (!sp.far) {
            let dens = opt(sp.crevices, 0.9);
            let qn = min(qEnd, nCol - 1);
            for (let q = 1; q <= qn; q++) {
                let a = data[q], c = data[q + 1];
                for (let n2 = 0; n2 <= 1; n2++) {
                    let kq = k0 + <f64>q - 1 + <f64>n2 * 0.5;
                    if (a.ea > 0.5 && c.ea > 0.5 && hash(kq * 0.613 + 2.7, sp.seed * 0.29) < dens * (1 - <f64>n2 * 0.4)) {
                        let f = n2 == 0 ? 0.15 + 0.35 * hash(kq * 1.91, sp.seed * 0.37) : 0.55 + 0.3 * hash(kq * 1.91, sp.seed * 0.37);
                        let j0 = 2 + <i32>Math.floor(hash(kq * 0.77 + 9, sp.seed) * lmax(1, <f64>(nr - 5)));
                        let j1 = min(nr - 2, j0 + 1 + <i32>Math.floor(hash(kq * 2.3, sp.seed * 0.5) * 4));
                        let hx = -(a.ox + c.ox) * 0.5, hz = -(a.oz + c.oz) * 0.5;
                        let tx = -hz, tz = hx;
                        let w0 = 0.16 + 0.22 * hash(kq * 3.7, sp.seed * 0.11);
                        let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                        let started = false;
                        for (let j = j0; j <= j1; j++) {
                            this.surf(q, j, f);
                            let x = this.SX, y = this.SY, z = this.SZ;
                            x = x + hx * 0.2;
                            z = z + hz * 0.2;
                            let jit = (hash(kq * 5.1 + <f64>j, sp.seed * 0.9) - 0.5) * 0.7 * (fl > 0 ? 0.3 : 1.0);
                            x = x + tx * jit;
                            z = z + tz * jit;
                            let t = <f64>(j - j0) / lmax(<f64>(j1 - j0), 1);
                            let wj = w0 * (0.3 + 0.7 * Math.pow(Math.sin(Math.PI * t), 0.5));
                            if (started && Math.abs(y - py) > 0.5) {
                                quad(b, px - tx * pw, py, pz - tz * pw, px + tx * pw, py, pz + tz * pw, x + tx * wj, y, z + tz * wj, x - tx * wj, y, z - tz * wj, hx, 0, hz);
                            }
                            px = x;
                            py = y;
                            pz = z;
                            pw = wj;
                            started = true;
                        }
                    }
                }
                // short bedding seams across a panel (horizontal hatching)
                let kq = k0 + <f64>q - 1;
                if (a.ea > 0.5 && c.ea > 0.5) {
                    let hx = -(a.ox + c.ox) * 0.5, hz = -(a.oz + c.oz) * 0.5;
                    for (let j = 2; j <= nr - 2; j++) {
                        let hs = hash(kq * 0.917 + <f64>j * 3.1, sp.seed * 0.61);
                        if (hs < 0.16 && a.fy[j + 1] - a.fy[j] > 1.5) {
                            let fy = 0.25 + 0.5 * hash(kq * 1.3 + <f64>j, sp.seed * 0.2);
                            let f0 = 0.05 + 0.3 * hash(kq * 2.9 + <f64>j, sp.seed * 0.4);
                            let f1 = f0 + 0.4 + 0.25 * hash(kq * 3.7 + <f64>j, sp.seed * 0.8);
                            let th = 0.1 + 0.1 * hs / 0.16;
                            // folded at the crease when it crosses one
                            f1 = lmin(f1, 1);
                            let mfq = this.MF[q];
                            let fc = mfq[j] + (mfq[j + 1] - mfq[j]) * fy;
                            let fm = fl > 0 && fc > f0 + 0.02 && fc < f1 - 0.02 ? fc : (f0 + f1) * 0.5;
                            let tm = (fm - f0) / (f1 - f0);
                            this.at(q, j, f0, th, fy, hx, hz);
                            let ax2 = this.AX, ay2 = this.AY, az2 = this.AZ;
                            this.at(q, j, fm, th + (th * 0.4 - th) * tm, fy, hx, hz);
                            let mx2 = this.AX, my2 = this.AY, mz2 = this.AZ;
                            this.at(q, j, fm, -th + (th - th * 0.4) * tm, fy, hx, hz);
                            let nx2 = this.AX, ny2 = this.AY, nz2 = this.AZ;
                            this.at(q, j, f1, th * 0.4, fy, hx, hz);
                            let bx2 = this.AX, by2 = this.AY, bz2 = this.AZ;
                            this.at(q, j, f1, -th * 0.4, fy, hx, hz);
                            let cx2 = this.AX, cy2 = this.AY, cz2 = this.AZ;
                            this.at(q, j, f0, -th, fy, hx, hz);
                            let dx2 = this.AX, dy2 = this.AY, dz2 = this.AZ;
                            quad(b, ax2, ay2, az2, mx2, my2, mz2, nx2, ny2, nz2, dx2, dy2, dz2, hx, 0, hz);
                            quad(b, mx2, my2, mz2, bx2, by2, bz2, cx2, cy2, cz2, nx2, ny2, nz2, hx, 0, hz);
                        }
                    }
                }
            }
        }
        // dark ink down the deeper grooves (the crags' shadowed clefts)
        if (fl > 0) {
            let qn = min(qEnd, nCol - 1);
            for (let q = 1; q <= qn; q++) {
                let a = data[q], c = data[q + 1];
                let kq = k0 + <f64>q - 1;
                if (this.LOD[q] > 0 && this.MG[q] > fl * 0.5 && hash(kq * 0.271 + 5.3, sp.seed * 0.17) < 0.6) {
                    let hx = -(a.ox + c.ox) * 0.5, hz = -(a.oz + c.oz) * 0.5;
                    let tx = -hz, tz = hx;
                    let w0 = 0.12 + 0.13 * hash(kq * 1.7, sp.seed * 0.23);
                    let j0 = 2 + <i32>Math.floor(hash(kq * 0.93, sp.seed * 0.31) * 3);
                    let j1 = nr - 2 - <i32>Math.floor(hash(kq * 1.37, sp.seed * 0.53) * 3);
                    let px = 0.0, py = 0.0, pz = 0.0, pw = 0.0;
                    let mx = this.MX[q], my = this.MY[q], mz = this.MZ[q];
                    for (let j = j0; j <= j1; j++) {
                        let x = mx[j] + hx * 0.2, y = my[j], z = mz[j] + hz * 0.2;
                        let t = <f64>(j - j0) / lmax(<f64>(j1 - j0), 1);
                        let wj = w0 * (0.35 + 0.65 * Math.pow(Math.sin(Math.PI * t), 0.5));
                        if (j > j0 && y - py > 0.5) {
                            quad(b, px - tx * pw, py, pz - tz * pw, px + tx * pw, py, pz + tz * pw, x + tx * wj, y, z + tz * wj, x - tx * wj, y, z - tz * wj, hx, 0, hz);
                        }
                        px = x;
                        py = y;
                        pz = z;
                        pw = wj;
                    }
                }
            }
        }
        for (let q = 1; q <= qEnd; q++) {
            let c = data[q];
            if (c.crack && c.e > 8 && !sp.far) {
                let jt = <i32>lmax(3, <f64>(nr - 2) - mathx.randInt(r, 0, 2));
                let hx = -c.ox, hz = -c.oz;
                let tx = -hz, tz = hx;
                let w = randRange(r, 0.25, 0.5);
                let prevX = 0.0, prevY = 0.0, prevZ = 0.0, prevW = 0.0;
                for (let j = 2; j <= jt; j++) {
                    let off = randRange(r, -0.3, 0.3);
                    let t = <f64>(j - 2) / lmax(<f64>(jt - 2), 1);
                    let wj = w * (0.3 + 0.7 * Math.pow(Math.sin(Math.PI * t), 0.5));
                    let x = c.fx[j] + tx * off + hx * 0.1;
                    let y = c.fy[j];
                    let z = c.fz[j] + tz * off + hz * 0.1;
                    if (j > 2) {
                        quad(b, prevX - tx * prevW, prevY, prevZ - tz * prevW, prevX + tx * prevW, prevY, prevZ + tz * prevW, x + tx * wj, y, z + tz * wj, x - tx * wj, y, z - tz * wj, hx, 0, hz);
                    }
                    prevX = x;
                    prevY = y;
                    prevZ = z;
                    prevW = wj;
                }
            }
        }
        // sea caves: dark mouths punched into the foot of tall faces
        if (!sp.far && sp.caves != 0) {
            let caveP = opt(sp.caves, 0.035);
            let col1 = b.col, aux1 = b.aux;
            meshgen.aux(b, 0, 0, 1, 0);
            meshgen.color(b, look.cave);
            for (let q = 2; q <= nCol - 1; q++) {
                let c = data[q];
                if (c.e > 18 && c.ea > 0.9 && hash(c.s * 0.0917 + 3.1, sp.seed * 0.43) < caveP) {
                    let hx = -c.ox, hz = -c.oz;
                    let tx = -hz, tz = hx;
                    let wdt = sp.step * (0.55 + 0.5 * hash(c.s, 1.9));
                    let hgt = lmin(c.e * 0.3, 3 + 5 * hash(c.s, 2.7));
                    // sit on the face just above the waterline, a hair toward the rail
                    let bx = c.fx[2] + hx * 0.25, bz = c.fz[2] + hz * 0.25;
                    let n = 9;
                    let cx = bx, cy = 0.3, cz = bz;
                    let px = 0.0, py = 0.0, pz = 0.0;
                    for (let k = 0; k <= n; k++) {
                        let a = Math.PI * <f64>k / <f64>n;
                        let u = Math.cos(a) * wdt * 0.5;
                        let v = Math.pow(Math.sin(a), 0.8) * hgt;
                        let x = bx + tx * u + hx * (v * 0.1);
                        let y = 0.3 + v;
                        let z = bz + tz * u + hz * (v * 0.1);
                        if (k > 0) meshgen.flatTriFacing(b, cx, cy, cz, px, py, pz, x, y, z, hx, 0, hz);
                        px = x;
                        py = y;
                        pz = z;
                    }
                }
            }
            meshgen.setPaint(b, col1, aux1);
        }
        // waterline foam lace: irregular strokes hugging the rock foot, and a
        // broken outer band that sometimes joins the rock
        if (sp.foam && !sp.far && nCol > 1) {
            meshgen.aux(b, 0, 0, 1, 0.25);
            meshgen.color(b, look.foam);
            let fnc = <f64>nCol;
            let u = 1 + hash(k0 * 0.31, sp.seed * 0.9) * 0.5;
            let n = 0.0;
            while (u < fnc - 0.05 && n < 400) {
                n += 1;
                let h1 = hash(k0 * 1.7 + n * 0.61, sp.seed * 0.71);
                let h2 = hash(k0 * 0.9 + n * 1.37, sp.seed * 0.23);
                let ln = 0.5 + 1.1 * h1;
                let u1 = lmin(u + ln, fnc);
                let ea = data[<i32>lclamp(Math.floor(u), 1, fnc)].ea;
                if (ea > 0.05 && h2 < 0.85) {
                    let wmax = 0.45 + 1.4 * hash(n * 2.3 + k0, sp.seed * 0.41);
                    // the outer band: a thin tapered stroke at its own steady
                    // distance from the foot over the middle of the stroke
                    let out2 = h2 < 0.3;
                    let o2 = wmax * 0.7 + 0.45 + 0.7 * hash(n * 0.77 + k0, 7.7);
                    let th2 = 0.18 + 0.25 * hash(n * 4.4 + k0, 3.1);
                    let ta = 0.12 + 0.2 * hash(n * 1.9 + k0, 5.3);
                    let tb = 0.88 - 0.2 * hash(n * 2.9 + k0, 6.1);
                    let steps = <i32>lmax(3, Math.ceil((u1 - u) * 4));
                    let pax = 0.0, paz = 0.0, pox = 0.0, poz = 0.0, pw = 0.0, pw2 = 0.0, pt = 0.0;
                    for (let i = 0; i <= steps; i++) {
                        let t = <f64>i / <f64>steps;
                        let uu = u + (u1 - u) * t;
                        this.footAt(uu, 0);
                        let x = this.SX, z = this.SZ, ox = this.FOX, oz = this.FOZ;
                        let env = Math.pow(smoothstep(0, 0.3, t) * smoothstep(1, 0.7, t), 0.6);
                        let rag = 0.75 + 0.5 * hash(n * 7.1 + <f64>i, sp.seed * 0.19);
                        let w = wmax * env * rag + 0.12;
                        let t2 = saturate((t - ta) / lmax(tb - ta, 0.05));
                        let w2 = th2 * Math.pow(Math.sin(Math.PI * t2), 0.7) * (0.8 + 0.4 * rag);
                        if (i > 0) {
                            quad(b, pax, 0.07, paz, x, 0.07, z, x - ox * w, 0.07, z - oz * w, pax - pox * pw, 0.07, paz - poz * pw, 0, 1, 0);
                            if (out2 && t > ta && pt < tb && (pw2 > 0.01 || w2 > 0.01)) {
                                quad(b, pax - pox * o2, 0.07, paz - poz * o2, x - ox * o2, 0.07, z - oz * o2, x - ox * (o2 + w2), 0.07, z - oz * (o2 + w2), pax - pox * (o2 + pw2), 0.07, paz - poz * (o2 + pw2), 0, 1, 0);
                            }
                        }
                        pax = x;
                        paz = z;
                        pox = ox;
                        poz = oz;
                        pw = w;
                        pw2 = w2;
                        pt = t;
                    }
                }
                // gaps, sometimes an overlap
                u = u1 + (hash(n * 3.3 + k0, sp.seed * 0.57) - 0.25) * 0.5;
            }
        }
        meshgen.setPaint(b, this.col0, this.aux0);

        // colliders: tilted boxes whose inner face follows the cliff face
        let cols = this.cols;
        if (cols != null && sp.collide) {
            let lean = sp.blocky ? opt(sp.lean, 0.1) * 0.3 : opt(sp.lean, 0.1);
            let q = 1;
            while (q < nCol) {
                let q2 = min(q + 2, nCol);
                let a = data[q], c = data[q2];
                // innermost rendered face point in the flying band (y < 34),
                // projected down the lean to the waterline
                let ia = inner(a, lean), ic = inner(c, lean);
                let sh = lmin(ia - a.foot, ic - c.foot) + 0.3;
                let la = a.foot + sh, lc = c.foot + sh;
                let ax = a.px + a.ox * la, az = a.pz + a.oz * la;
                let cx = c.px + c.ox * lc, cz = c.pz + c.oz * lc;
                let ux = cx - ax, uz = cz - az;
                let ul = Math.sqrt(ux * ux + uz * uz);
                let hgt = lmin(a.e, c.e);
                if (ul > 1e-3 && hgt > 1) {
                    ux = ux / ul;
                    uz = uz / ul;
                    // outward normal of the segment, pointing away from the rail
                    let nx = uz, nz = -ux;
                    if (nx * (a.ox + c.ox) + nz * (a.oz + c.oz) < 0) {
                        nx = -nx;
                        nz = -nz;
                    }
                    // v: up the leaning face; w: into the rock
                    let vl = Math.sqrt(1 + lean * lean);
                    let vx = nx * lean / vl, vy = 1 / vl, vz = nz * lean / vl;
                    let wx = nx / vl, wy = -lean / vl, wz = nz / vl;
                    let hy = (hgt + 6) * 0.5 * vl;
                    let hz = 14.0;
                    let fy = -6.0;
                    let mx = (ax + cx) * 0.5 + vx * hy + wx * hz;
                    let my = fy + vy * hy + wy * hz;
                    let mz = (az + cz) * 0.5 + vz * hy + wz * hz;
                    cols.push(coll.box(mx, my, mz, Vector.xyz(<f32>ux, 0, <f32>uz), Vector.xyz(<f32>vx, <f32>vy, <f32>vz), Vector.xyz(<f32>wx, <f32>wy, <f32>wz), ul * 0.5 + 0.6, hy, hz));
                }
                q = q2;
            }
        }
    }
}

function inner(cc: Col, lean: f64): f64 {
    let best = HUGE;
    for (let j = 2; j <= cc.fy.length - 2; j++) {
        if (cc.fy[j] < 34) {
            let l = (cc.fx[j] - cc.px) * cc.ox + (cc.fz[j] - cc.pz) * cc.oz - lean * (cc.fy[j] - 0.9);
            best = lmin(best, l);
        }
    }
    return best == HUGE ? cc.foot : best;
}

// Queries ---------------------------------------------------------------------------

// Cliff lip at rail distance s: lateral distance of the grass edge and its
// height -> LIP_LAT, LIP_Y.
export let LIP_LAT: f64 = 0;
export let LIP_Y: f64 = 0;
export function lipAt(sp: StripSpec, s: f64): void {
    let tpl = template(sp);
    let c = column(sp, tpl, Math.floor(s / sp.step + 0.5));
    let n = c.fy.length - 1;
    LIP_LAT = (c.fx[n] - c.px) * c.ox + (c.fz[n] - c.pz) * c.oz;
    LIP_Y = c.fy[n];
}

// Face points of the columns in [s0, s1] as parallel 1-based lists: lateral
// distance from the rail and height -> FACE_LATS (also returned), FACE_YS.
export let FACE_LATS: Array<f64> = [0.0];
export let FACE_YS: Array<f64> = [0.0];
export function faceAt(sp: StripSpec, s0: f64, s1: f64): Array<f64> {
    let tpl = template(sp);
    let lats: Array<f64> = [0.0], ys: Array<f64> = [0.0];
    let ka = Math.floor(s0 / sp.step + 0.5), kb = Math.floor(s1 / sp.step + 0.5);
    for (let k = ka; k <= kb; k += 1) {
        let c = column(sp, tpl, k);
        for (let m = 1; m < c.fy.length; m++) {
            lats.push((c.fx[m] - c.px) * c.ox + (c.fz[m] - c.pz) * c.oz);
            ys.push(c.fy[m]);
        }
    }
    FACE_LATS = lats;
    FACE_YS = ys;
    return lats;
}

// Height of the strip's top at rail distance s, lateral distance lat.
export function groundAt(sp: StripSpec, s: f64, lat: f64): f64 {
    let tpl = template(sp);
    let c = column(sp, tpl, Math.floor(s / sp.step + 0.5));
    let prevL = -HUGE, prevY = c.ty[1];
    for (let m = 1; m <= c.ty.length - 2; m++) {
        let l = (c.tx[m] - c.px) * c.ox + (c.tz[m] - c.pz) * c.oz;
        if (lat <= l) {
            if (prevL == -HUGE) return c.ty[m];
            let t = (lat - prevL) / lmax(l - prevL, 1e-6);
            return prevY + (c.ty[m] - prevY) * t;
        }
        prevL = l;
        prevY = c.ty[m];
    }
    return prevY;
}

// Signed turn rate of the rail (rad per m, > 0 = turning right).
export function turnRate(rail: Rail, s: f64): f64 {
    rail.at(s - 12);
    let rax = <f64>rail.rt.x, raz = <f64>rail.rt.z;
    rail.at(s + 12);
    let rbx = <f64>rail.rt.x, rbz = <f64>rail.rt.z;
    // right vectors rotate with the heading
    let cr = rax * rbz - raz * rbx;
    return Math.asin(lclamp(cr, -1, 1)) / 24;
}

// Max lateral distance on `side` before rail normals cross (inside of turns).
const LIMIT_OFFSETS: StaticArray<f64> = [-40, -20, 0, 20, 40];
export function insideLimit(rail: Rail): LimitFn {
    return (s: f64, side: f64): f64 => {
        let best = HUGE;
        for (let i = 0; i < 5; i++) {
            let k = turnRate(rail, s + LIMIT_OFFSETS[i]);
            if (k * side > 1e-5) best = lmin(best, 0.7 / (k * side));
        }
        return best;
    };
}
