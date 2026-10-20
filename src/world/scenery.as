// Port of src/world/scenery.luau: the static scenery along the rail, baked
// into world-space meshes split into chunks for culling (plan, time-sliced
// bake queue, collision broad phase, near lists, quality, fades).
//
// Not ported here: the debug probes (M.PROBE, archVerts, M.AUDIT /
// collaudit, DEBUG's build probes, DRAW_STATS).
//
// Port rules as in cliffs.as: sequences 1-based with a dummy slot 0 (chunk
// lists, collider lists, cbs); optional numbers NaN; multi-returns as module
// globals (FA_* for frameAt, HIT_* for collide / nearCollide). The Luau M.*
// tunables live on `knobs` (importers cannot assign module lets).
import { Vector } from "rive/vector";
import { Mat4 } from "rive/mat4";
import { GPUBuffer } from "rive/gpu";
import { BufferUsage } from "rive/gpu_enums";
import { clock } from "rive/os";
import { format, FormatArg } from "rive/format";
import * as mathx from "../lib/mathx";
import { rand, randRange } from "../lib/mathx";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as gpu from "../lib/gpu";
import * as track from "./track";
import * as lv from "./level";
import { KnotFn, knots } from "./level";
import * as coll from "./collide";
import { Collider, Bounds } from "./collide";
import * as geo from "./geo";
import * as terrain from "./terrain";
import { StripSpec } from "./terrain";
import * as cliffs from "./cliffs";
import * as arches from "./arches";
import * as props from "./props";
import * as life from "./life";
import * as ambient from "./ambient";
import * as palette from "./palette";
import * as R from "../render/renderer";
import { HUGE, lmin, lmax, lclamp } from "../lib/compat";

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}
@inline function S(v: string): FormatArg {
    return FormatArg.string(v);
}

export class Chunk {
    s0: f64 = 0;
    s1: f64 = 0;
    batch: gpu.Batch;
    colliders: Array<Collider>; // 1-based
    bounds: Bounds;
    gs0: f64 = 0; // geometric s range (where the content sits)
    gs1: f64 = 0;
    verts: i32 = 0;
    name: string = "";
    ready: bool = false; // baked and uploaded (isVisible is false until then)
    readyT: f64 = 0; // game time it became ready (background bakes fade in)
    // Luau's gridSet / farSet membership (AnimaScript Set / Map keyed by an
    // object lose entries when the per-frame GC moves it: flags instead)
    grid: bool = false; // grid chunk (quality: draw distance)
    far: bool = false; // distant layer (quality: cull, reflection)
    constructor(batch: gpu.Batch, colliders: Array<Collider>, bounds: Bounds) {
        this.batch = batch;
        this.colliders = colliders;
        this.bounds = bounds;
    }
}

export const CHUNK: f64 = 300;

// The Luau M.* switches and tunables.
export class Knobs {
    DEBUG: bool = false;
    AUDIT: bool = false; // (collaudit: not ported)
    BAKE_HASH: bool = false;
    BUDGET_MS: f64 = 3;
    BUDGET_IDLE_MS: f64 = 1.5;
    BUDGET_SLOW_MS: f64 = 1;
    BUDGET_VISIBLE_MS: f64 = 6;
    BUDGET_MENU_MS: f64 = 8;
    BUDGET_CATCHUP_MS: f64 = 12;
    CATCHUP_AHEAD: f64 = 650;
    NEAR_AHEAD: f64 = 900; // a missing chunk this close ahead gets the big budget
    URGENT_AHEAD: f64 = 450; // a chunk this close ahead (content s) is baked on the spot when needed
    SLOW_THUNK_MS: f64 = NaN; // debug: print thunks slower than this
    // build() bakes the start chunks in the same call (Luau). Off: they are
    // left to pump (first by priority), so build() stays one short call (the
    // CLI dev preview runs ~6x slower than published: 120 ms -> over the
    // 200 ms watchdog).
    START_SYNC: bool = true;
    // harness hook: every chunk at its upload (the scratch builder holds it)
    onUpload: ((name: string, b: Builder) => void)? = null;
}
export const knobs = new Knobs();

const DRAW_AHEAD: f64 = 1700;
const DRAW_BEHIND: f64 = 150;

// Deferred emission into one chunk's builder (world space). A thunk is a
// plain emitter (`fn`) or a step that may return its continuation (`st`, the
// rest of a big piece, run as the next bake step; `emitStep`).
export type Emit = (b: Builder, cols: Array<Collider>) => void;
export type StepFn = (b: Builder, cols: Array<Collider>) => Thunk?;
// One bake step of a multi-step piece (gateSteps, portalRingSteps, ...).
export type PieceStep = (b: Builder, cols: Array<Collider>?) => void;

export class Thunk {
    fn: Emit? = null;
    st: StepFn? = null;
}

class CB {
    gs0: f64;
    gs1: f64;
    vis0: f64; // drawn while vis0 < p.s < vis1
    vis1: f64;
    thunks: Array<Thunk?> = [null];
    cols: Array<Collider>;
    name: string;
    cs0: f64; // content s range (strips are split on these)
    cs1: f64;
    coast: bool; // coast biome (coast strips never spill into violet chunks)
    chunk: Chunk;
    near: Bounds? = null; // grid chunks: world box around their rail (bake on contact)
    constructor(name: string, gs0: f64, gs1: f64, vis0: f64, vis1: f64, coast: bool, cols: Array<Collider>, chunk: Chunk) {
        this.name = name;
        this.gs0 = gs0;
        this.gs1 = gs1;
        this.vis0 = vis0;
        this.vis1 = vis1;
        this.cols = cols;
        this.cs0 = gs0;
        this.cs1 = gs1;
        this.coast = coast;
        this.chunk = chunk;
    }
}

const tr = lv.track;
const A = lv.anchors;
const PORTAL_S: f64 = lv.portalS;
const LEN: f64 = tr.length;

// Rail helpers ------------------------------------------------------------------

export let FA_P: Vector = Vector.xyz(0, 0, 0);
export let FA_F: Vector = Vector.xyz(0, 0, 0);
export let FA_RT: Vector = Vector.xyz(0, 0, 0);

function frameAt(s: f64): void {
    track.frame(tr, lclamp(s, 0, LEN));
    let p = track.FRAME_P, f = track.FRAME_F, rt = track.FRAME_R;
    if (s < 0) {
        p = p + f * <f32>s;
    } else if (s > LEN) {
        p = p + f * <f32>(s - LEN);
    }
    FA_P = p;
    FA_F = f;
    FA_RT = rt;
}

function yawAlong(s: f64): f64 {
    frameAt(s);
    return Math.atan2(<f64>FA_F.z, <f64>FA_F.x);
}

// world x, z at lateral offset x from the rail at s
let LAT_X: f64 = 0, LAT_Z: f64 = 0;
function lat(s: f64, x: f64): void {
    frameAt(s);
    LAT_X = <f64>FA_P.x + <f64>FA_RT.x * x;
    LAT_Z = <f64>FA_P.z + <f64>FA_RT.z * x;
}

// true when (x, z) keeps at least `d` meters (horizontal) from every rail
// sample in [sa, sb]
function railClear(x: f64, z: f64, d: f64, sa: f64, sb: f64): bool {
    let d2 = d * d;
    let k0 = <i32>lmax(1, Math.floor(sa / tr.step) + 1);
    let k1 = <i32>lmin(<f64>tr.n, Math.floor(sb / tr.step) + 1);
    let k = k0;
    while (k <= k1) {
        let dx = tr.px[k] - x, dz = tr.pz[k] - z;
        if (dx * dx + dz * dz < d2) return false;
        k += 3;
    }
    if (sa <= 0) {
        frameAt(-200);
        let dx = <f64>FA_P.x - x, dz = <f64>FA_P.z - z;
        if (dx * dx + dz * dz < d2) return false;
    }
    return true;
}

function constF(v: f64): KnotFn {
    return (_s: f64): f64 => v;
}

// the rail callback terrain reads (railRight): frame p and right vector
class SceneryRail extends terrain.Rail {
    override at(s: f64): void {
        frameAt(s);
        this.p = FA_P;
        this.rt = FA_RT;
    }
}
const railRight = new SceneryRail();
const insideLimit = terrain.insideLimit(railRight);

// Chunks --------------------------------------------------------------------------

function emptyBounds(): Bounds {
    return new Bounds();
}
let placeholder: gpu.Batch? = null;

// Shared stand-in batch for chunks that are not baked yet (never drawn).
function placeholderBatch(): gpu.Batch {
    let pb = placeholder;
    if (pb != null) return pb;
    let mesh = new gpu.Mesh();
    mesh.vb = new GPUBuffer(BufferUsage.vertex, 32);
    mesh.ib = new GPUBuffer(BufferUsage.index, 4);
    let nb = gpu.batch("scenery_pending", mesh, 1, false, false);
    placeholder = nb;
    return nb;
}

function newCB(name: string, gs0: f64, gs1: f64, vis0: f64, vis1: f64, coast: bool): CB {
    // convert the visibility window into the s0/s1 game.luau tests
    let s0 = vis0 == -HUGE ? -1e9 : vis0 + DRAW_AHEAD;
    let s1 = vis1 == HUGE ? 1e9 : vis1 - DRAW_BEHIND;
    let cols = new Array<Collider>(1);
    let chunk = new Chunk(placeholderBatch(), cols, EMPTY_BOUNDS);
    chunk.s0 = s0;
    chunk.s1 = s1;
    chunk.gs0 = gs0;
    chunk.gs1 = gs1;
    chunk.name = name;
    return new CB(name, gs0, gs1, vis0, vis1, coast, cols, chunk);
}
const EMPTY_BOUNDS = emptyBounds();

function emit(cb: CB, fn: Emit): void {
    let t = new Thunk();
    t.fn = fn;
    cb.thunks.push(t);
}

function emitStep(cb: CB, st: StepFn): void {
    let t = new Thunk();
    t.st = st;
    cb.thunks.push(t);
}

// A piece baked as a job (`make` returns it; each call runs its next part
// and returns true when done): one bake step per part.
function emitJob(cb: CB, make: (b: Builder, cols: Array<Collider>) => (() => bool)): void {
    emitStep(cb, (b: Builder, cols: Array<Collider>): Thunk? => {
        let job = make(b, cols);
        let cont = new Thunk();
        cont.st = (_b: Builder, _cols: Array<Collider>): Thunk? => {
            if (job()) return null;
            return cont;
        };
        return cont.st!(b, cols);
    });
}

class World {
    grid: Array<CB> = new Array<CB>(1); // grid[i] covers s in [(i-1) * CHUNK, i * CHUNK)
    kPortal: i32 = 0; // grid index holding the portal (coast only)
    far: Array<CB> = new Array<CB>(1); // distant coast layers (long windows)
    farV: Array<CB> = new Array<CB>(1); // distant violet layers
    range: CB; // the pale mountain range on the coast horizon (whole coast)
    canyonWalls: Map<i32, StripSpec> = new Map<i32, StripSpec>(); // per side, for the climb's clouds
    constructor(range: CB) {
        this.range = range;
    }
}

// Regular chunk for content at rail distance s. Violet content in the
// portal's chunk moves to the next one (the portal chunk is coast only and
// stops drawing right after the portal).
function chunkAt(w: World, s: f64): CB {
    let ng = w.grid.length - 1;
    let k = <i32>lclamp(Math.floor(s / CHUNK) + 1, 1, <f64>ng);
    if (k == w.kPortal && s >= PORTAL_S) k = min(k + 1, ng);
    return w.grid[k];
}

// Distant-layer chunk covering s (coast, or violet after the portal).
function farAt(w: World, s: f64): CB {
    let list = s >= PORTAL_S ? w.farV : w.far;
    for (let i = 1; i < list.length; i++) {
        let cb = list[i];
        if (s >= cb.cs0 && s < cb.cs1) return cb;
    }
    return list[list.length - 1];
}

// Promontories and coves on top of a coastline: the wrapped coast (pulled
// toward the rail on promontories) and edge (taller there). (No caller sets
// `promo` in the game.)
let PROMO_C: KnotFn = constF(0);
let PROMO_E: KnotFn = constF(0);
function promontories(coast: KnotFn, edge: KnotFn, amp: f64, freq: f64, seed: f64): void {
    let L = lv.lighthouse;
    let featPr = (s: f64): f64 => {
        let n = mathx.fbm2(s * freq + seed * 0.37, seed * 0.11, 2) / 0.75;
        let keep = 1 - mathx.smoothstep(L.s - 220, L.s - 120, s) * mathx.smoothstep(L.s + 200, L.s + 110, s);
        return mathx.smoothstep(0.52, 0.78, n) * keep;
    };
    let featCv = (s: f64): f64 => {
        let n = mathx.fbm2(s * freq + seed * 0.37, seed * 0.11, 2) / 0.75;
        let keep = 1 - mathx.smoothstep(L.s - 220, L.s - 120, s) * mathx.smoothstep(L.s + 200, L.s + 110, s);
        return mathx.smoothstep(0.42, 0.2, n) * keep;
    };
    PROMO_C = (s: f64): f64 => lmax(coast(s) - amp * featPr(s) + amp * 0.7 * featCv(s), 18);
    PROMO_E = (s: f64): f64 => edge(s) + amp * 0.35 * featPr(s) - amp * 0.2 * featCv(s);
}

// The strip config is a StripSpec (Luau StripCfg: every extra field is a
// StripSpec field); `promo` / `piece` are scenery's own.
function stripSpec(c: StripSpec, promo: Array<f64>?): StripSpec {
    if (promo != null) {
        promontories(c.coast, c.edge, promo[1], promo[2], promo[3]);
        c.coast = PROMO_C;
        c.edge = PROMO_E;
    }
    c.s0 = c.gs0;
    c.s1 = c.gs1;
    c.rail = railRight;
    c.limit = insideLimit;
    c.cache = new terrain.StripCache();
    return c;
}

// Longest strip piece per bake step (m of rail): keeps each background
// bake step to a few ms. Columns hash their index, so pieces line up.
const PIECE_M: f64 = 24;
const PIECE_FAR_M: f64 = 150;

function strip(w: World, c: StripSpec, far: bool = false, piece: f64 = NaN, promo: Array<f64>? = null): StripSpec {
    let spec = stripSpec(c, promo);
    let list = far ? w.far : w.grid;
    let coastLook = !terrain.isViolet(c.look);
    let maxLen = (isNaN(piece) ? (far ? PIECE_FAR_M : PIECE_M) : piece) * lmax(1, c.step / 6);
    let runsDone = false;
    for (let li = 1; li < list.length; li++) {
        let cb = list[li];
        let a = lmax(c.gs0, cb.cs0), b = lmin(c.gs1, cb.cs1);
        if (b > a && (cb.coast == coastLook || far)) {
            // whole columns per piece (seams fall on the column grid)
            let n = lmax(1, Math.ceil((b - a) / maxLen));
            let len = lmax(c.step, Math.floor((b - a) / n / c.step + 0.5) * c.step);
            let pa = a;
            if (!runsDone) {
                // the turn-limit runs of the whole strip: their own bake
                // steps (a long strip's in parts)
                runsDone = true;
                let parts = terrain.runsParts(spec);
                for (let pi = 1; pi <= parts; pi++) {
                    let pk = pi;
                    emit(cb, (_bb: Builder, _cols: Array<Collider>): void => {
                        terrain.runsPart(spec, pk, parts);
                    });
                }
            }
            for (let k = 1.0; k <= n; k++) {
                let pb = k == n ? b : lmin(b, pa + len);
                if (pb > pa) {
                    let pc = spec.clone();
                    pc.s0 = pa;
                    pc.s1 = pb;
                    emitJob(cb, (bb: Builder, cols: Array<Collider>): (() => bool) => terrain.stripJob(bb, pc, far ? null : cols));
                }
                pa = pb;
            }
        }
    }
    return spec;
}

// strip config with the fields every caller sets
function cfg(gs0: f64, gs1: f64, side: f64, step: f64, seed: f64, look: terrain.Look, coast: KnotFn, edge: KnotFn, rise: KnotFn, depth: KnotFn): StripSpec {
    let c = new StripSpec();
    c.gs0 = gs0;
    c.gs1 = gs1;
    c.side = side;
    c.step = step;
    c.seed = seed;
    c.look = look;
    c.coast = coast;
    c.edge = edge;
    c.rise = rise;
    c.depth = depth;
    return c;
}

// A separate headland: a short coast strip whose foot bulges toward the rail
// mid-way (`lateral` at its nearest) and whose ends sink into the sea.
function headlandStrip(w: World, side: f64, a: f64, b: f64, lateral: f64, edge: f64, rise: f64, seed: f64): void {
    let len = b - a;
    let c = cfg(a, b, side, 6, seed, terrain.COAST,
        knots([a, lateral + 55, a + len * 0.35, lateral, a + len * 0.7, lateral + 12, b, lateral + 60], 8, 0.02, seed + 1),
        knots([a, edge * 0.8, a + len * 0.45, edge, b, edge * 0.85], 5, 0.02, seed + 2),
        knots([a, rise * 0.8, a + len * 0.5, rise, b, rise * 0.8], 6, 0.015, seed + 3),
        constF(80));
    c.endTaper = lmin(90, len * 0.3);
    c.tiers = 3;
    c.strata = 6;
    strip(w, c);
}

// Placement helpers -------------------------------------------------------------

// Plan reach of a stack / floating island as a multiple of its radius
// (lean, spurs, rubble / rim shrubs): the boss clearance list uses it.
const STACK_REACH: f64 = 1.6;
const ISLAND_REACH: f64 = 1.3;

// Sea stack at rail coords: one leaning, tapering mass whose upper tier
// breaks into its own facets, with a grass cap and rubble at its foot.
function seaStack(w: World, s: f64, x: f64, rad: f64, h: f64, seed: f64): void {
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = chunkAt(w, s);
    let la = mathx.hash(seed, 1.7) * mathx.TAU;
    let lm = rad * (0.2 + 0.35 * mathx.hash(seed, 2.9));
    let sp = new cliffs.HeadSpec();
    sp.x = cx;
    sp.z = cz;
    sp.yaw = seed * 0.91;
    sp.rx = rad;
    sp.rz = rad * (0.7 + 0.25 * mathx.hash(seed, 4.1));
    sp.h = h;
    sp.seed = seed;
    sp.look = cliffs.COAST_WARM;
    sp.leanX = Math.cos(la) * lm;
    sp.leanZ = Math.sin(la) * lm;
    sp.cols = 16;
    sp.rough = 0.3;
    sp.taper = 0.24;
    sp.bulge = -0.06;
    sp.lip = 0.08;
    sp.dome = rad * 0.3;
    sp.tip = 0.2;
    sp.skew = (mathx.hash(seed, 6.1) - 0.5) * 0.3;
    sp.drape = lmin(3, h * 0.12);
    sp.crack = 0.4;
    sp.spurs = 0.3;
    sp.fracture = 1.5;
    sp.tier = 0.35 + 0.3 * mathx.hash(seed, 7.7);
    sp.boulders = 6;
    sp.tufts = 2;
    sp.rowH = lmax(2.6, h / 9);
    // (the backdrop stacks, 40 m+ off the rail: no face creases)
    sp.detail = Math.abs(x) < 40 ? 1 : 0.6;
    emit(cb, (b: Builder, cols: Array<Collider>): void => {
        cliffs.headland(b, sp, cols);
    });
}

// Low wave-washed rock (skim hazard) at rail coords.
function skerry(w: World, s: f64, x: f64, rad: f64, h: f64, seed: f64): void {
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = chunkAt(w, s);
    emit(cb, (b: Builder, cols: Array<Collider>): void => {
        cliffs.skerry(b, cx, cz, rad, h, seed, cliffs.COAST_BARE, cols);
    });
}

// Grass-topped islet at rail coords (mid distance depth layer).
function islet(w: World, s: f64, x: f64, rx: f64, rz: f64, h: f64, seed: f64, far: bool = false): void {
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = far ? farAt(w, s) : chunkAt(w, s);
    // 140 m+ out: coarser outline, fewer shrubs and boulders (one bake step
    // stays ~2-3 ms; the detail is sub-pixel there)
    let out = !far && Math.abs(x) >= 140;
    let per = Math.PI * (3 * (rx + rz) - Math.sqrt((3 * rx + rz) * (rx + 3 * rz)));
    let sp = new cliffs.HeadSpec();
    sp.x = cx;
    sp.z = cz;
    sp.yaw = yawAlong(s) + (mathx.hash(seed, 0.3) - 0.5) * 0.8;
    sp.rx = rx;
    sp.rz = rz;
    sp.h = h;
    sp.seed = seed;
    sp.look = far ? cliffs.COAST_FAR : cliffs.COAST;
    sp.dome = lmin(rx, rz) * 0.22;
    sp.hills = lmin(rx, rz) * 0.08;
    sp.tip = 0.35;
    sp.rough = 0.24;
    sp.taper = 0.1;
    sp.lip = 0.04;
    sp.drape = lmin(3, h * 0.2);
    sp.boulders = far ? 0 : out ? Math.floor((rx + rz) / 22) : NaN;
    sp.tufts = far ? 0 : out ? Math.floor(lmin(rx, rz) * 0.1) : NaN;
    sp.crack = far ? 0 : 0.2;
    sp.ink = far ? 0.8 : 1;
    sp.cols = far ? 18 : out ? lclamp(Math.floor(per / 12), 9, 28) : NaN;
    emit(cb, (b: Builder, cols: Array<Collider>): void => {
        cliffs.headland(b, sp, far ? null : cols);
    });
}

// A piece built in several bake steps (the first makes them; each runs
// one; they share the chunk's builder in order). Steps are 0-based.
function emitSteps(cb: CB, make: () => Array<PieceStep>): void {
    emitStep(cb, (_b: Builder, _cols: Array<Collider>): Thunk? => {
        // the setup (profiles, lattices) is a step of its own
        let steps = make();
        let i = 0;
        let next = new Thunk();
        next.st = (b: Builder, cols: Array<Collider>): Thunk? => {
            i += 1;
            if (i <= steps.length) steps[i - 1](b, cols);
            return i < steps.length ? next : null;
        };
        return steps.length > 0 ? next : null;
    });
}

// Toon cumulus in a chunk: the hull is sampled in four bake steps (the
// lobes and rings 0..6, 7..14, 15..21, 22..28 and the smoothing) and emitted
// in a fifth (each well under 1 ms).
class CloudSlot {
    plan: geo.CloudPlanState? = null;
    hull: geo.CloudHull? = null;
}
function cloudAt(cb: CB, csp: geo.CloudSpec): void {
    let slot = new CloudSlot();
    emit(cb, (_b: Builder, _cols: Array<Collider>): void => {
        slot.plan = geo.cloudPlanA(csp, 6);
    });
    emit(cb, (_b: Builder, _cols: Array<Collider>): void => {
        let pl = slot.plan;
        if (pl != null) geo.cloudRings(pl, 7, 14);
    });
    emit(cb, (_b: Builder, _cols: Array<Collider>): void => {
        let pl = slot.plan;
        if (pl != null) geo.cloudRings(pl, 15, 21);
    });
    emit(cb, (_b: Builder, _cols: Array<Collider>): void => {
        let pl = slot.plan;
        if (pl != null) {
            slot.hull = geo.cloudPlanB(pl, 22);
            slot.plan = null;
        }
    });
    emit(cb, (b: Builder, _cols: Array<Collider>): void => {
        let h = slot.hull;
        if (h != null) {
            geo.cloudEmit(b, h);
            slot.hull = null;
        }
    });
}

// Natural arch spanning the rail at s (`extra`: the GateSpec fields callers
// set beyond these).
function gateAt(w: World, s: f64, halfW: f64, height: f64, crown: f64, leg: f64, depth: f64, seed: f64, look: terrain.Look, spec: arches.GateSpec): void {
    frameAt(s);
    let p = FA_P, rt = FA_RT;
    let cb = chunkAt(w, s);
    spec.x = p.x;
    spec.z = p.z;
    spec.rx = rt.x;
    spec.rz = rt.z;
    spec.halfW = halfW;
    spec.height = height;
    spec.crown = crown;
    spec.leg = leg;
    spec.depth = depth;
    spec.seed = seed;
    spec.look = look;
    // one bake step per part (the arch is a few thousand quads)
    emitSteps(cb, (): Array<PieceStep> => arches.gateSteps(spec));
}

// Waterfalls (level.waterfalls) inside [s0, s1]. `walls` (per side, -1 / +1)
// snaps each lip onto the rendered cliff edge (and updates the level entry).
function falls(w: World, s0: f64, s1: f64, colors: Array<f64>, foam: f64, seedBase: f64, walls: Map<i32, StripSpec>?): void {
    let wfs = lv.waterfalls;
    for (let i = 1; i < wfs.length; i++) {
        let f = wfs[i];
        if (f.s >= s0 && f.s <= s1) {
            let prof: Array<f64>? = null; // 1-based
            if (walls != null) {
                frameAt(f.s);
                let p = FA_P, rt = FA_RT;
                let fx = (f.x - <f64>p.x) * <f64>rt.x + (f.z - <f64>p.z) * <f64>rt.z;
                let side: i32 = fx >= 0 ? 1 : -1;
                if (walls.has(side)) {
                    let ws = walls.get(side);
                    terrain.lipAt(ws, f.s);
                    let lipLat = terrain.LIP_LAT, lipY = terrain.LIP_Y;
                    let l = lipLat + 0.9;
                    f.x = <f64>p.x + <f64>rt.x * <f64>side * l;
                    f.z = <f64>p.z + <f64>rt.z * <f64>side * l;
                    f.y = lipY - 0.6;
                    // the sheet follows the face down: the lip sits well back
                    // from the foot (lean, jutting lower tiers), so a plain arc
                    // runs inside the rock and only its plunge pokes out (a
                    // white egg on the water)
                    terrain.faceAt(ws, f.s - f.width * 0.5, f.s + f.width * 0.5);
                    let lats = terrain.FACE_LATS, ys = terrain.FACE_YS;
                    let H = lmax(f.y - f.bottom, 1);
                    const NB = 24;
                    let need: Array<f64> = [0.0];
                    for (let q = 1; q <= NB + 1; q++) need.push(-HUGE);
                    for (let q = 1; q < lats.length; q++) {
                        if (ys[q] > f.bottom + 0.3) {
                            let t = Math.pow(lclamp((f.y - ys[q]) / H, 0, 1), 1 / 1.15);
                            let bi = <i32>(Math.floor(t * NB + 0.5) + 1);
                            need[bi] = lmax(need[bi], l - lats[q] + 0.9);
                        }
                    }
                    // the water eases out at most 0.55 m per meter of drop
                    // ahead of what it must clear, and never tucks back in
                    let dy = 0.55 * H / NB;
                    for (let bi = NB; bi >= 1; bi--) need[bi] = lmax(need[bi], need[bi + 1] - dy);
                    let pr: Array<f64> = [0.0];
                    let run = 0.0;
                    for (let bi = 1; bi <= NB + 1; bi++) {
                        let t = <f64>(bi - 1) / NB;
                        let natural = 2 * (1 - Math.pow(1 - lmin(t * 3, 1), 2)) + t * 1.5;
                        run = lmax(run, lmax(need[bi], natural));
                        pr.push(run);
                    }
                    prof = pr;
                }
            }
            let cb = chunkAt(w, f.s);
            let arcF = prof != null ? prof[prof.length - 1] - 1.5 : 4;
            // in a slot canyon the pool is a few meters off the flight line:
            // no splash puffs there (they read as snowballs at arm's length;
            // ambient mist fades near the lens instead)
            frameAt(f.s);
            let pf = FA_P, prt = FA_RT;
            let poolLat = Math.abs((f.x - <f64>pf.x) * <f64>prt.x + (f.z - <f64>pf.z) * <f64>prt.z) - arcF - 1.5;
            let fs = new geo.FallSpec();
            fs.x = f.x;
            fs.y = f.y;
            fs.z = f.z;
            fs.bottom = f.bottom;
            fs.width = f.width;
            fs.ox = f.ox;
            fs.oz = f.oz;
            fs.seed = seedBase + <f64>i;
            fs.colors = colors;
            fs.foam = foam;
            fs.arc = 4;
            fs.splash = poolLat > 24;
            if (prof != null) {
                let pr2 = prof!;
                let np = pr2.length - 1;
                fs.outAt = (t: f64): f64 => {
                    let x = lclamp(t, 0, 1) * <f64>(np - 1);
                    let ii = lmin(Math.floor(x), <f64>(np - 2));
                    let u = x - ii;
                    let k = <i32>ii;
                    return pr2[k + 1] + (pr2[k + 2] - pr2[k + 1]) * u;
                };
            }
            emit(cb, (b: Builder, _cols: Array<Collider>): void => {
                geo.waterfall(b, fs);
            });
            let af = new ambient.Fall();
            af.x = f.x;
            af.y = f.y;
            af.z = f.z;
            af.bottom = f.bottom;
            af.width = f.width;
            af.ox = f.ox;
            af.oz = f.oz;
            af.arc = arcF;
            af.s = f.s;
            ambient.addFall(af);
        }
    }
}

// Walls rise (or dip) to meet each waterfall lip on their side.
function fallLift(s: f64, side: f64, h: f64): f64 {
    let wfs = lv.waterfalls;
    for (let i = 1; i < wfs.length; i++) {
        let f = wfs[i];
        let dd = Math.abs(s - f.s);
        if (dd < 50) {
            frameAt(f.s);
            let p = FA_P, rt = FA_RT;
            let fx = (f.x - <f64>p.x) * <f64>rt.x + (f.z - <f64>p.z) * <f64>rt.z;
            if (fx * side > 0) {
                let t = mathx.smoothstep(50, 12, dd);
                h = h + (f.y + 1 - h) * t;
            }
        }
    }
    return h;
}

// Coast ----------------------------------------------------------------------------

const COAST: terrain.Look = terrain.COAST;
const FAR: terrain.Look = terrain.COAST_FAR;

function sectionLighthouse(w: World): void {
    let L = lv.lighthouse;
    // The launch bay opens onto the sea: a low hamlet shore on the left,
    // then the lighthouse headland jutting toward the rail's bend; a dark
    // cliff guards the bay mouth on the right, then open water with islets
    // and hazy headlands out to the horizon.
    let c = cfg(-600, 330, -1, 6, 101, COAST,
        knots([-500, 74, -150, 88, 100, 100, 230, 118, 330, 150], 7, 0.028, 1),
        knots([-500, 20, 100, 14, 250, 18], 4, 0.02, 2),
        knots([-500, 34, 200, 26, 330, 18], 5, 0.015, 3),
        knots([-500, 90, 330, 70]));
    c.tiers = 2;
    c.strata = 5;
    c.crevices = 0.45;
    c.startTaper = 200; // the school lane end: sinks into the sea
    let leftSpec = strip(w, c);
    c = cfg(400, 900, -1, 6, 107, COAST,
        knots([400, 150, 480, 104, L.s - 40, 80, L.s + 30, 74, 720, 92, 820, 140, 900, 190], 6, 0.028, 17),
        knots([400, 16, 500, 20, L.s, L.ground - 0.5, 720, 24, 900, 18], 3, 0.02, 18),
        knots([400, 16, L.s, 5, 760, 24, 900, 20], 4, 0.015, 19),
        knots([400, 70, L.s, 90, 900, 80]));
    c.tiers = 2;
    c.strata = 5;
    c.flats = [[0.0], [0.0, L.s + 4, L.x, 26, L.ground], [0.0, L.s + 30, L.x + 18, 16, L.ground + 1]];
    strip(w, c);
    // right: tall dark cliff at the bay mouth, then open sea until the
    // headland before the arch
    c = cfg(-600, 190, 1, 6, 131, COAST,
        knots([-500, 54, -200, 50, 60, 52, 190, 80], 6, 0.03, 4),
        knots([-500, 38, 0, 36, 190, 30], 6, 0.022, 5),
        knots([-500, 26, 190, 30], 6, 0.015, 6),
        knots([-500, 80, 190, 90]));
    c.tiers = 3;
    c.strata = 6;
    c.crevices = 0.6;
    c.startTaper = 200;
    strip(w, c);
    headlandStrip(w, 1, 720, 900, 225, 30, 28, 137);
    // the lighthouse and the keeper's cottage on the promontory
    {
        let cb = chunkAt(w, L.s);
        lat(L.s + 4, -L.x);
        let lx = LAT_X, lz = LAT_Z;
        lat(L.s + 28, -(L.x + 16));
        let hx = LAT_X, hz = LAT_Z;
        let hy = yawAlong(L.s) + 0.35;
        emit(cb, (b: Builder, cols: Array<Collider>): void => {
            meshgen.push(b, Mat4.fromTranslation(<f32>lx, <f32>L.ground, <f32>lz) * Mat4.fromUniformScale(<f32>L.scale));
            props.lighthouse(b, 0, 0, 0, null);
            meshgen.pop(b);
            cols.push(coll.cylinder(lx, lz, 3.6 * L.scale, L.ground - 2, L.ground + 32 * L.scale));
            props.cottage(b, hx, L.ground + 1.2, hz, hy);
        });
    }
    // pier and buoys at the start line
    {
        let s = 40.0;
        lat(s, -(leftSpec.coast(s) + 1));
        let x0 = LAT_X, z0 = LAT_Z;
        frameAt(s);
        let rt = FA_RT;
        let cb = chunkAt(w, s);
        let pyaw = Math.atan2(<f64>rt.z, <f64>rt.x);
        emit(cb, (b: Builder, _cols: Array<Collider>): void => {
            props.pier(b, x0, z0, pyaw, 34, 1.7);
        });
        // a fishing hamlet on the shore above the pier
        const houses: StaticArray<f64> = [10, 11, 0xC23A30, 0xF1ECDF, 34, 17, 0x2F5C7A, 0xEDE4D2, 58, 10, 0xB8862E, 0xF4EEE2, 84, 19, 0x3F7F7A, 0xE9E1CF, -16, 16, 0xC23A30, 0xEFE8DA];
        for (let i = 1; i <= 5; i++) {
            let o = (i - 1) * 4;
            let hs = houses[o];
            let la = leftSpec.coast(hs) + houses[o + 1];
            let gy = terrain.groundAt(leftSpec, hs, la);
            lat(hs, -la);
            let hx = LAT_X, hz = LAT_Z;
            let hcb = chunkAt(w, hs);
            let cyaw = yawAlong(hs) + <f64>(i % 2) * 1.57 + 0.2;
            let roof = houses[o + 2], wall = houses[o + 3], sc = 0.8 + <f64>(i % 3) * 0.12;
            emit(hcb, (b: Builder, _cols: Array<Collider>): void => {
                props.cottage(b, hx, gy - 0.4, hz, cyaw, roof, wall, sc);
            });
        }
        const buoys: StaticArray<f64> = [150, -19, 1, 235, 19, 0, 380, -20, 1, 470, 20, 0, 820, -21, 1, 860, 21, 0];
        for (let i = 0; i < 6; i++) {
            let bs = buoys[i * 3];
            lat(bs, buoys[i * 3 + 1]);
            let bx = LAT_X, bz = LAT_Z;
            let cbb = chunkAt(w, bs);
            let red = buoys[i * 3 + 2] != 0;
            emit(cbb, (b: Builder, _cols: Array<Collider>): void => {
                props.buoy(b, bx, bz, red);
            });
        }
    }
    // sea stacks off the headlands, islets out on the open right side
    seaStack(w, 250, 64, 10, 34, 311);
    seaStack(w, 300, 86, 6, 22, 313);
    seaStack(w, 360, -84, 8, 26, 327);
    seaStack(w, 790, -66, 11, 38, 315);
    // the first obstacles, after the lighthouse beat: a staggered fence
    // across the whole flight box (weave, or eat rock). The fence stacks'
    // colliders top out at 26 m: a climb to the 30 m ceiling clears them
    seaStack(w, 760, 4, 6, 22, 335);
    seaStack(w, 810, 18, 7, 24, 339);
    seaStack(w, 870, -5, 6.5, 23, 337);
    seaStack(w, 935, -14, 7, 23, 341);
    seaStack(w, 972, 10, 5.6, 21, 343);
    seaStack(w, 840, -88, 7, 26, 317);
    skerry(w, 610, 46, 4.5, 3.2, 319);
    skerry(w, 250, -34, 3.2, 2.2, 321);
    skerry(w, 470, 36, 3.6, 2.4, 329);
    islet(w, 330, 250, 40, 28, 20, 323);
    islet(w, 520, 150, 30, 22, 16, 325);
    islet(w, 600, 420, 70, 44, 30, 331);
    islet(w, 700, 290, 44, 30, 22, 333);
}

function gateSpec(flare: f64, rough: f64, square: f64, facet: f64, foam: i32): arches.GateSpec {
    let g = new arches.GateSpec();
    g.flare = flare;
    g.rough = rough;
    g.square = square;
    g.facet = facet;
    if (foam >= 0) g.foam = foam != 0;
    return g;
}

function sectionArch(w: World): void {
    // slalom: stacks alternating just inside the flight box, each one half
    // of a gate whose other half stands at the box edge (see the Luau
    // original): (s, x, height)
    const slalom: StaticArray<f64> = [1010, 6, 23, 1090, -6.5, 22, 1170, 6, 24, 1250, -6, 21, 1330, 6.5, 24, 1410, -6, 22];
    for (let i = 1; i <= 6; i++) {
        let o = (i - 1) * 3;
        let r = mathx.rng(<f64>(i * 17));
        seaStack(w, slalom[o], slalom[o + 1], randRange(r, 5.6, 7), slalom[o + 2], 2000 + <f64>(i * 13));
    }
    const outer: StaticArray<f64> = [1010, -19, 1090, 19, 1170, -19, 1250, 19, 1330, -19, 1410, 19];
    for (let i = 1; i <= 6; i++) {
        let o = (i - 1) * 2;
        seaStack(w, outer[o], outer[o + 1], 7, 30 + <f64>(i % 2) * 6, 2050 + <f64>(i * 11));
    }
    let g = A.arch;
    // separate headlands with sea between them, then the coast closes into
    // the gate only over the last stretch: both walls meet the arch's legs
    headlandStrip(w, -1, 990, 1240, 225, 30, 30, 201);
    headlandStrip(w, 1, 1090, 1330, 330, 30, 34, 205);
    let c = cfg(1550, 1810, -1, 6, 207, COAST,
        knots([1550, 160, 1605, 80, g.s - 30, g.w * 0.5 + 12, g.s + 25, g.w * 0.5 + 12, g.s + 70, 80, 1810, 170], 5, 0.03, 11),
        knots([1550, 26, g.s - 40, 44, g.s + 40, 46, 1810, 26], 5, 0.02, 12),
        knots([1550, 22, g.s, 18, 1810, 24], 6, 0.015, 13),
        knots([1550, 70, g.s, 70, 1810, 70]));
    c.endTaper = 60;
    c.tiers = 3;
    c.strata = 7;
    c.bands = 0.76;
    c.cracks = 0.45;
    c.facet = 3.2;
    strip(w, c);
    c = cfg(1565, 1800, 1, 6, 211, COAST,
        knots([1565, 165, 1615, 78, g.s - 30, g.w * 0.5 + 12, g.s + 25, g.w * 0.5 + 12, g.s + 65, 85, 1800, 175], 5, 0.03, 14),
        knots([1565, 26, g.s - 40, 46, g.s + 40, 44, 1800, 26], 5, 0.02, 15),
        knots([1565, 24, g.s, 16, 1800, 24], 6, 0.015, 16),
        knots([1565, 70, g.s, 70, 1800, 70]));
    c.endTaper = 60;
    c.tiers = 3;
    c.strata = 7;
    c.bands = 0.76;
    c.cracks = 0.45;
    c.facet = 3.2;
    strip(w, c);
    // the arch
    gateAt(w, g.s, g.w * 0.5, g.h, lv.ARCH_CROWN, lv.ARCH_LEG, lv.ARCH_DEPTH, 3131, terrain.COAST_CANYON, gateSpec(5, 1.1, 3.4, 1.7, -1));
    // stacks and skerries around the gate, islets out in the gaps
    seaStack(w, 1560, -40, 8, 30, 2101);
    seaStack(w, 1600, 44, 9, 34, 2103);
    skerry(w, 1520, 26, 3.4, 2.4, 2105);
    skerry(w, 1780, -30, 3, 2, 2107);
    islet(w, 1330, -150, 30, 20, 14, 2109);
    islet(w, 1420, 170, 24, 17, 12, 2111);
}

function sectionLowPass(w: World): void {
    // wide open water: low headlands far out with sea gaps between them
    let c = cfg(1880, 2240, -1, 7, 301, COAST,
        knots([1880, 170, 2000, 230, 2150, 280, 2240, 330], 12, 0.02, 21),
        knots([1880, 24, 2100, 18, 2240, 16], 5, 0.02, 22),
        knots([1880, 36, 2240, 30], 8, 0.015, 23),
        knots([1880, 100, 2240, 110]));
    c.tiers = 2;
    c.strata = 5;
    strip(w, c);
    // (the shores stop short of the canyon: it stands as a rock peninsula
    // with open sea on either side)
    headlandStrip(w, -1, 2420, 2720, 270, 26, 34, 305);
    c = cfg(1860, 2120, 1, 7, 311, COAST,
        knots([1860, 190, 2000, 250, 2120, 320], 12, 0.02, 24),
        knots([1860, 22, 2120, 16], 5, 0.02, 25),
        knots([1860, 40, 2120, 30], 8, 0.015, 26),
        knots([1860, 100, 2120, 110]));
    c.tiers = 2;
    c.strata = 5;
    strip(w, c);
    headlandStrip(w, 1, 2660, 2840, 330, 28, 30, 319);
    // skim hazards: low rocks inside the flight box
    const rocks: StaticArray<f64> = [1900, -17, 3.4, 1.8, 1985, 20, 3.8, 2.4, 2100, -8, 2.8, 1.3, 2210, 16, 3.2, 2, 2320, -20, 4, 2.6, 2470, 7, 2.6, 1.2, 2580, -14, 3.6, 2, 2690, 18, 3, 1.8, 2790, -5, 2.4, 1.1];
    for (let i = 1; i <= 9; i++) {
        let o = (i - 1) * 4;
        skerry(w, rocks[o], rocks[o + 1], rocks[o + 2], rocks[o + 3], 4000 + <f64>(i * 31));
    }
    // an old ketch run aground on a reef, just off the flight line
    {
        let ws = 2480.0;
        lat(ws, 44);
        let wx = LAT_X, wz = LAT_Z;
        let cb = chunkAt(w, ws);
        let wyaw = yawAlong(ws) + 0.6;
        emit(cb, (b: Builder, cols: Array<Collider>): void => {
            props.wreck(b, wx, wz, wyaw, 26, cols);
        });
        skerry(w, ws + 18, 36, 3, 1.6, 4201);
        skerry(w, ws - 14, 52, 2.4, 1.2, 4203);
    }
    // fang rocks standing across the skim lane (weave round them, low)
    const fangs: StaticArray<f64> = [2060, -15, 4.2, 14, 2140, 14, 4.2, 13, 2220, 9.5, 4.2, 14, 2250, -21, 4.4, 15, 2300, -12, 4.2, 15, 2385, 15, 4.2, 14, 2520, 10, 4.2, 15, 2585, -21, 4.5, 16, 2610, 21, 4.4, 14, 2665, -15, 4.3, 15, 2740, 16, 4.2, 14, 2815, -9, 4.2, 15];
    for (let i = 1; i <= 12; i++) {
        let o = (i - 1) * 4;
        seaStack(w, fangs[o], fangs[o + 1], fangs[o + 2], fangs[o + 3], 4300 + <f64>(i * 3));
    }
    // stacks and islets for depth
    seaStack(w, 1950, 74, 10, 30, 4101);
    seaStack(w, 2150, -96, 12, 40, 4103);
    seaStack(w, 2380, 88, 8, 26, 4105);
    seaStack(w, 2620, -72, 10, 34, 4107);
    islet(w, 2060, -160, 40, 26, 18, 4109);
    islet(w, 2300, 150, 46, 30, 22, 4111);
    islet(w, 2540, -140, 30, 22, 14, 4113);
    islet(w, 2760, 130, 20, 15, 10, 4115);
}

const CANYON_FALLS: StaticArray<f64> = [0xB4E4F4, 0x86C8E6, 0xCBEEF8, 0x72B8DE];

function seq4(a: StaticArray<f64>): Array<f64> {
    return [0.0, a[0], a[1], a[2], a[3]];
}

// the boss sight lines read the canyon faces (level.sightFrom): per side,
// the nearest face lateral per strip column, cached
class FaceCache {
    walls: Map<i32, StripSpec>;
    k: Map<i32, Map<f64, f64>> = new Map<i32, Map<f64, f64>>();
    constructor(walls: Map<i32, StripSpec>) {
        this.walls = walls;
        this.k.set(-1, new Map<f64, f64>());
        this.k.set(1, new Map<f64, f64>());
    }
    at(s: f64, side: f64): f64 {
        let ws = this.walls.get(<i32>side);
        let cache = this.k.get(<i32>side);
        let m = HUGE;
        for (let k = Math.floor((s - 6) / ws.step + 0.5); k <= Math.floor((s + 6) / ws.step + 0.5); k++) {
            let v: f64;
            if (cache.has(k)) {
                v = cache.get(k);
            } else {
                v = HUGE;
                terrain.faceAt(ws, k * ws.step, k * ws.step);
                let lats = terrain.FACE_LATS;
                for (let q = 1; q < lats.length; q++) v = lmin(v, lats[q]);
                cache.set(k, v);
            }
            m = lmin(m, v);
        }
        return m;
    }
}

function bridge(w: World, s: f64, height: f64, crown: f64, seed: f64): void {
    let hw = lmax(lv.cliffTurnDist(s, 1), lv.cliffTurnDist(s, -1)) + 0.12 * height + 3;
    gateAt(w, s, hw, height, crown, 12, 5.5, seed, COAST, gateSpec(0, 1.4, 2.6, NaN, 0));
    // (sight lines: the opening, and the top with its jitter and cap)
    lv.addCeiling(s, 5.5 * 1.1 + 2, hw, height, height + crown + 4.5);
}

function sectionCanyon(w: World): void {
    let c0 = A.canyonS0, c1 = A.canyonS1;
    // one strip per side from the canyon mouth through the climb: the walls
    // open out into a valley mouth and the shore drops away below the climb
    let walls = new Map<i32, StripSpec>();
    for (let side = -1; side <= 1; side += 2) {
        let sd = <f64>side;
        let o0 = lv.CANYON_OPEN0, o1 = lv.CANYON_OPEN1;
        let farE = knots([o0, 60, 3950, 44, 4350, 34, 5700, 30], 8, 0.02, 33 + sd);
        let farR = knots([o0, 20, 4050, 40, 4650, 70, 5700, 60], 24, 0.008, 35 + sd);
        let c = cfg(c0 - 80, PORTAL_S + 300, sd, 6, 6200 + sd, terrain.COAST_CANYON,
            (s: f64): f64 => lv.canyonFoot(s, sd),
            (s: f64): f64 => {
                let n = mathx.fbm2(s * 0.006 + 9, sd * 5.1, 3) / 0.875;
                let h = fallLift(s, sd, 64 + (n - 0.5) * 44 + (sd > 0 ? 6 : 0));
                let t = mathx.smoothstep(o0, o1, s);
                return h * (1 - t) + farE(s) * t;
            },
            (s: f64): f64 => {
                let t = mathx.smoothstep(o0, o1, s);
                return 14 * (1 - t) + farR(s) * t;
            },
            (s: f64): f64 => {
                let t = mathx.smoothstep(o0 + 40, o0 + 540, s);
                return 55 + 250 * t;
            });
        c.back = 40;
        c.lean = 0.12;
        c.facet = 2.6;
        c.tiers = 4;
        c.strata = 9;
        c.ledge = 2.8;
        c.hills = 26;
        c.bands = 0.74;
        c.cracks = 0.45;
        c.caves = 0.06;
        walls.set(side, strip(w, c, false, 16));
    }
    w.canyonWalls = walls;
    // the boss sight lines read these faces (level.sightFrom)
    let fc = new FaceCache(walls);
    lv.setCanyonFace((s: f64, side: f64): f64 => fc.at(s, side));
    lv.sightPrep();
    falls(w, c0, c1, seq4(CANYON_FALLS), 0xF4FAFF, 6600, walls);
    // rock bridges overhead: one high, one low to duck under, one mid
    // (none past 3570: the Stormcrow's reveal is seen down the slot)
    bridge(w, 3130, 50, 9, 6301);
    bridge(w, 3470, 24, 8, 6311);
    bridge(w, 3560, 44, 10, 6321);
    // pillars inside the canyon, staggered across it (on the boss sight list)
    const pil: StaticArray<f64> = [3060, -9, 3.4, 28, 6421, 3260, 3, 3.6, 30, 6401, 3380, 9, 3.4, 30, 6431, 3580, -3, 3.4, 26, 6411];
    for (let i = 0; i < 4; i++) {
        let o = i * 5;
        seaStack(w, pil[o], pil[o + 1], pil[o + 2], pil[o + 3], pil[o + 4]);
        lv.addSolid(pil[o], pil[o + 1], pil[o + 2] * STACK_REACH + 1, -5, pil[o + 3] + pil[o + 2] * 0.3 + 3);
    }
}

// a climb island's rim, handed from its bake step to its waterfall's
class RimSlot {
    rim: Array<f64>? = null;
}

function sectionClimb(w: World): void {
    let sEnd = PORTAL_S;
    // sea stacks flanking the canyon mouth, out in the bay either side of
    // the Stormcrow's arena (both in level.bossRoomS and on the sight list)
    const st2: StaticArray<f64> = [3960, -130, 10, 38, 7101, 4040, 80, 11, 44, 7103];
    for (let i = 0; i < 2; i++) {
        let o = i * 5;
        seaStack(w, st2[o], st2[o + 1], st2[o + 2], st2[o + 3], st2[o + 4]);
        lv.addSolid(st2[o], st2[o + 1], st2[o + 2] * STACK_REACH + 1, -5, st2[o + 3] + st2[o + 2] * 0.3 + 3);
    }
    // floating islands along the climb
    {
        let r = mathx.rng(801);
        let s = 4180.0;
        let k = 0;
        while (s < sEnd - 70) {
            k += 1;
            let side: f64 = k % 2 == 0 ? 1 : -1;
            frameAt(s);
            let py = <f64>FA_P.y;
            let near = rand(r) < 0.4;
            let x = side * (near ? randRange(r, 42, 62) : randRange(r, 75, 170));
            let rad = near ? randRange(r, 10, 16) : randRange(r, 15, 34);
            let topY = py + (near ? randRange(r, -16, 22) : randRange(r, -40, 45));
            lat(s, x);
            let cx = LAT_X, cz = LAT_Z;
            if (topY > 34 && railClear(cx, cz, rad + 30, 3800, sEnd)) {
                let cb = chunkAt(w, s);
                let depth = rad * randRange(r, 1.3, 2.2);
                // out of the Stormcrow's arena (same draws, so the rest of
                // the climb is unchanged), and on the boss clearance list
                let reach = rad * ISLAND_REACH;
                let y0 = topY - rad * 0.4 - depth - 2, y1 = topY + rad * 0.3 + 2;
                x = lv.arenaClearX(s, x, reach, y0, y1);
                lat(s, x);
                cx = LAT_X;
                cz = LAT_Z;
                lv.addSolid(s, x, reach, y0, y1);
                let isp = new cliffs.IslandSpec();
                isp.x = cx;
                isp.y = topY;
                isp.z = cz;
                isp.r = rad;
                isp.depth = depth;
                isp.seed = 8000 + <f64>(k * 11);
                isp.look = cliffs.COAST;
                let slot = new RimSlot();
                emit(cb, (b: Builder, cols: Array<Collider>): void => {
                    cliffs.island(b, isp, cols);
                    slot.rim = cliffs.ISLAND_RIM;
                });
                if (!near && rand(r) < 0.5) {
                    // the falls face back down the rail and a little toward
                    // it, so the pilot flying in sees the sheet, not its edge
                    frameAt(s);
                    let f2 = FA_F, rt2 = FA_RT;
                    let ox = -<f64>rt2.x * side * 0.6 - <f64>f2.x * 0.8, oz = -<f64>rt2.z * side * 0.6 - <f64>f2.z * 0.8;
                    let ol = lmax(Math.sqrt(ox * ox + oz * oz), 1e-6);
                    ox = ox / ol;
                    oz = oz / ol;
                    let fw = rad * 0.5;
                    let fsp = new geo.FallSpec();
                    fsp.x = cx + ox * rad * 0.82;
                    fsp.y = topY - 1;
                    fsp.z = cz + oz * rad * 0.82;
                    fsp.bottom = 0;
                    fsp.width = fw;
                    fsp.ox = ox;
                    fsp.oz = oz;
                    fsp.seed = 8500 + <f64>k;
                    fsp.colors = seq4(CANYON_FALLS);
                    fsp.foam = 0xF4FAFF;
                    fsp.arc = 3 + rad * 0.12;
                    fsp.spread = 0.9;
                    fsp.ragged = 0.3;
                    fsp.lipFoam = true;
                    fsp.plume = 1.8;
                    let af = new ambient.Fall();
                    af.x = fsp.x;
                    af.y = fsp.y;
                    af.z = fsp.z;
                    af.bottom = 0;
                    af.width = fw * 1.6;
                    af.ox = ox;
                    af.oz = oz;
                    af.arc = fsp.arc;
                    af.s = s;
                    emit(cb, (b: Builder, _cols: Array<Collider>): void => {
                        // the lip on the island's rim, where it faces (x, z
                        // per rim point from cliffs.island)
                        let rp = slot.rim;
                        if (rp != null) {
                            let best = -HUGE;
                            let bi = 1;
                            for (let q = 1; q < rp.length; q += 3) {
                                let dx = rp[q] - cx, dz = rp[q + 2] - cz;
                                let dl = lmax(Math.sqrt(dx * dx + dz * dz), 1e-6);
                                let d = (dx * ox + dz * oz) / dl;
                                if (d > best) {
                                    best = d;
                                    bi = q;
                                }
                            }
                            // (just over the edge: the sheet pours off the
                            // rim it hugs, not out of the wall under it)
                            fsp.x = rp[bi] + ox * 0.3;
                            fsp.y = rp[bi + 1] - 0.15;
                            fsp.z = rp[bi + 2] + oz * 0.3;
                            fsp.rim = rp;
                            af.x = fsp.x;
                            af.y = fsp.y;
                            af.z = fsp.z;
                        }
                        geo.waterfall(b, fsp);
                    });
                    ambient.addFall(af);
                }
            }
            s += randRange(r, 70, 140);
        }
    }
    // toon cumulus towers you fly between: big ones close to the rail,
    // banks of smaller ones further out
    {
        let r = mathx.rng(901);
        let s = 4200.0;
        let k = 0;
        // the portal chunk's clouds (some stand past the portal) get their
        // own chunk, gone at the crossing under the flash like farRange
        let kp = w.grid[w.kPortal];
        let pc = newCB("climbClouds", kp.gs0, PORTAL_S, kp.vis0, PORTAL_S, true);
        pc.cs0 = HUGE; // (farAt never picks it)
        pc.cs1 = HUGE;
        w.far.push(pc); // table.insert(w.far, 2, pc)
        for (let i = w.far.length - 1; i > 2; i--) w.far[i] = w.far[i - 1];
        w.far[2] = pc;
        while (s < sEnd + 380) {
            k += 1;
            frameAt(lmin(s, sEnd));
            let py = <f64>FA_P.y;
            let side: f64 = rand(r) < 0.5 ? -1 : 1;
            let near = rand(r) < 0.45;
            let size = near ? randRange(r, 22, 38) : randRange(r, 34, 80);
            let x = side * (near ? size * 1.2 + randRange(r, 26, 44) : size * 1.3 + randRange(r, 70, 260));
            let y = py + (near ? randRange(r, -40, 6) : randRange(r, -90, 60));
            lat(s, x);
            let cx = LAT_X, cz = LAT_Z;
            // never rest on the land below: the base stays 15 m above it
            let si = <i32>side;
            let ground = w.canyonWalls.has(si) && s < PORTAL_S + 300 ? terrain.groundAt(w.canyonWalls.get(si), s, Math.abs(x) - size * 0.6) : 0;
            if (y > lmax(size * 0.6, 55) && y - size * 0.35 > ground + 15 && railClear(cx, cz, size * 1.25 + 24, 3900, sEnd + 400)) {
                let cb = chunkAt(w, lmin(s, sEnd - 1));
                if (cb == kp) cb = pc;
                let csp = new geo.CloudSpec();
                csp.x = cx;
                csp.y = y;
                csp.z = cz;
                csp.sx = size;
                csp.sy = size * 0.75;
                csp.sz = size * 0.75;
                csp.puffs = near ? 9 : 11;
                csp.seed = 9000 + <f64>k;
                cloudAt(cb, csp);
            }
            s += randRange(r, 45, 90);
        }
    }
}

// Far layers (coast): headlands in rows further out, pale mountains --------------

function farCoast(w: World): void {
    // hazy headlands further out, in separate pieces so the sea horizon
    // shows between them: side, s0, s1, lateral, edge, rise
    let pieces: StaticArray<f64> = [
        -1, -700, 160, 330, 34, 60,
        -1, 520, 1250, 470, 40, 70,
        -1, 1650, 2350, 560, 44, 80,
        -1, 2800, 3300, 600, 50, 90,
        -1, 3800, 4700, 620, 44, 70,
        -1, 4950, PORTAL_S + 300, 700, 40, 60,
        1, -700, -80, 360, 36, 60,
        1, 220, 980, 560, 40, 70,
        1, 1350, 1950, 480, 44, 80,
        1, 2250, 2800, 620, 46, 80,
        1, 3250, 3900, 470, 50, 90,
        1, 4250, 5100, 660, 44, 70,
    ];
    for (let i = 1; i <= 12; i++) {
        let o = (i - 1) * 6;
        let side = pieces[o], a = pieces[o + 1], b = pieces[o + 2], d = pieces[o + 3], e = pieces[o + 4], rs = pieces[o + 5];
        let len = b - a;
        let fi = <f64>i;
        let c = cfg(a, b, side, 18, 3000 + fi * 7, FAR,
            knots([a, d + 90, a + len * 0.3, d, a + len * 0.7, d + 30, b, d + 110], 40, 0.006, 41 + fi),
            knots([a, e * 0.7, a + len * 0.4, e, b, e * 0.8], 10, 0.008, 43 + fi),
            knots([a, rs * 0.6, a + len * 0.5, rs, b, rs * 0.7], 18, 0.006, 45 + fi),
            constF(180));
        c.back = 60;
        c.endTaper = lmin(160, len * 0.3);
        c.tiers = 1;
        c.strata = 3;
        c.facet = 6;
        c.ledge = 0;
        c.hills = 14;
        c.far = true;
        c.collide = false;
        c.ink = 0.8;
        c.drape = 5;
        strip(w, c, true);
    }
    // towering cumulus banks on the coast horizon
    const banks: StaticArray<f64> = [1250, -950, 150, 260, 1650, 1150, 190, 330, 2550, -1300, 210, 360, 3300, 1250, 200, 300, 700, 1400, 170, 300];
    for (let i = 1; i <= 5; i++) {
        let o = (i - 1) * 4;
        let bs = banks[o];
        lat(bs, banks[o + 1]);
        let csp = new geo.CloudSpec();
        csp.x = LAT_X;
        csp.y = banks[o + 2];
        csp.z = LAT_Z;
        csp.sx = banks[o + 3];
        csp.sy = banks[o + 3] * 0.8;
        csp.sz = banks[o + 3] * 0.7;
        csp.puffs = 12;
        csp.seed = 3900 + <f64>(i * 17);
        csp.ink = 0.6;
        cloudAt(farAt(w, bs), csp);
    }
    // pale mountains far away
    let r = mathx.rng(3101);
    for (let k = 1; k <= 18; k++) {
        let sa = randRange(r, -600, PORTAL_S + 200);
        let side: f64 = k % 2 == 0 ? 1 : -1;
        let d = randRange(r, 1300, 2400);
        let rad = randRange(r, 260, 520);
        lat(sa, side * (d + rad));
        let cx = LAT_X, cz = LAT_Z;
        if (railClear(cx, cz, d + rad * 0.5, 0, PORTAL_S)) {
            let cb = farAt(w, sa);
            let msp = new cliffs.HeadSpec();
            msp.x = cx;
            msp.z = cz;
            msp.yaw = rand(r) * 6;
            msp.rx = rad;
            msp.rz = rad * randRange(r, 0.6, 1);
            msp.h = randRange(r, 60, 140);
            msp.seed = 31000 + <f64>k;
            msp.look = cliffs.COAST_FAR;
            msp.cols = 14;
            msp.rough = 0.35;
            msp.taper = 0.45;
            msp.dome = rad * randRange(r, 0.35, 0.6);
            msp.hills = rad * 0.08;
            msp.drape = 10;
            msp.boulders = 0;
            msp.tufts = 0;
            msp.foam = false;
            msp.ink = 0.45;
            msp.crack = 0;
            msp.collide = false;
            msp.rowH = 40;
            emit(cb, (b: Builder, _cols: Array<Collider>): void => {
                cliffs.headland(b, msp, null);
            });
        }
    }
    // a pale range on the horizon: massive mountains well off the route, in
    // world coords (x, z, half length of the ridge, highest summit)
    const massifs: StaticArray<f64> = [
        -1500, -5150, 900, 360,
        -350, -5650, 1100, 440,
        900, -5250, 800, 300,
        2250, -5750, 1000, 470,
        3700, -5350, 850, 390,
        5200, -5900, 1050, 430,
        -2700, -2500, 800, 210,
        -2350, -300, 700, 170,
        2500, -1250, 750, 190,
    ];
    for (let i = 1; i <= 9; i++) {
        let o = (i - 1) * 4;
        let r3 = mathx.rng(33000 + <f64>i);
        // the northern ranges lie across the view; the flank ones turn with the coast
        let yaw = massifs[o + 1] < -4000 ? randRange(r3, -0.35, 0.35) : randRange(r3, 0.9, 2.2);
        let rsp = new cliffs.RidgeSpec();
        rsp.x = massifs[o];
        rsp.z = massifs[o + 1];
        rsp.yaw = yaw;
        rsp.len = massifs[o + 2];
        rsp.h = massifs[o + 3];
        rsp.seed = 33100 + <f64>i;
        rsp.tones = [0.0, 0x84A6C6, 0x6389AF, 0x52779E];
        rsp.ink = 0.3;
        emit(w.range, (b: Builder, _cols: Array<Collider>): void => {
            cliffs.ridge(b, rsp);
        });
    }
    // islets scattered far out on the open water
    let r2 = mathx.rng(3201);
    for (let k = 1; k <= 22; k++) {
        let s = randRange(r2, -300, PORTAL_S - 200);
        let side: f64 = rand(r2) < 0.5 ? -1 : 1;
        let d = randRange(r2, 180, 420);
        let rx = randRange(r2, 16, 50);
        lat(s, side * (d + rx));
        if (railClear(LAT_X, LAT_Z, d + rx * 0.6, 0, PORTAL_S)) {
            let rz = rx * randRange(r2, 0.55, 0.85);
            let h = randRange(r2, 8, 24);
            islet(w, s, side * (d + rx), rx, rz, h, 32000 + <f64>k, true);
        }
    }
}

// Violet world ---------------------------------------------------------------------

const VLOOK: cliffs.Look = cliffs.VIOLET;

// The tower's steps share one baker, made by its first step.
class TowerSlot {
    tb: cliffs.TowerBaker? = null;
}

// Rounded rock tower at world (x, z): stacked boulder blocks, frosted tops.
// (Luau optionals: peak / segs / shrink / cols NaN = nil; withCols false =
// no colliders.)
function rockTower(cb: CB, x: f64, z: f64, rx: f64, rz: f64, h: f64, yaw: f64, seed: f64, far: bool = false, peak: f64 = NaN, segs: f64 = NaN, withCols: bool = true, shrink: f64 = NaN, cols: f64 = NaN): void {
    let tsp = new cliffs.TowerSpec();
    tsp.x = x;
    tsp.z = z;
    tsp.yaw = yaw;
    tsp.h = h;
    tsp.rx = rx;
    tsp.rz = rz;
    tsp.seed = seed;
    tsp.look = far ? cliffs.VIOLET_FAR : VLOOK;
    tsp.segs = segs;
    tsp.peak = peak;
    tsp.shrink = shrink;
    tsp.far = far;
    tsp.ink = far ? 0.7 : NaN;
    tsp.foam = !far;
    tsp.n = cols;
    let keep = !(!withCols || far);
    // big towers bake in two steps (their block segments in halves)
    let nst = cliffs.towerStepCount(tsp);
    let slot = new TowerSlot();
    for (let i = 1; i <= nst; i++) {
        emit(cb, (b: Builder, cl: Array<Collider>): void => {
            if (i == 1) slot.tb = new cliffs.TowerBaker(tsp);
            let tb = slot.tb;
            if (tb != null && i <= tb.count) tb.step(i, b, keep ? cl : null);
            if (i == nst) slot.tb = null;
        });
    }
}

// Kept for callers placing a plain stack (w, d half sizes).
function pillar(cb: CB, x: f64, z: f64, hw: f64, hd: f64, h: f64, blocks: f64, yaw: f64, seed: f64, far: bool = false, shrink: f64 = NaN, withCols: bool = true): void {
    rockTower(cb, x, z, hw, hd, h, yaw, seed, far, 0.15, blocks, withCols, shrink);
}

// Rock cluster at rail coords: a massive central tower (blunt peak when
// tall) with shorter rounded towers leaning on it.
function spires(w: World, s: f64, x: f64, rad: f64, h: f64, seed: f64, far: bool = false, cbOverride: CB? = null): void {
    let r = mathx.rng(seed);
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = cbOverride != null ? cbOverride : (far ? farAt(w, lmax(s, PORTAL_S)) : chunkAt(w, s));
    let yaw = yawAlong(s) + randRange(r, -0.5, 0.5);
    let n = <i32>mathx.randInt(r, 2, 4);
    let tw = lmax(rad * randRange(r, 0.72, 0.9), h * randRange(r, 0.17, 0.22));
    let slim = h / tw;
    let peak = far ? (slim > 3 ? randRange(r, 0.4, 0.8) : randRange(r, 0.1, 0.4)) : slim > 4.5 ? randRange(r, 0.15, 0.4) : randRange(r, 0, 0.15);
    let trz = tw * randRange(r, 0.75, 0.95);
    rockTower(cb, cx, cz, tw, trz, h, yaw, seed, far, peak, NaN, true, 0.84);
    for (let i = 1; i <= n; i++) {
        let a = (<f64>i / <f64>n) * mathx.TAU + randRange(r, -0.4, 0.4);
        let d = tw * randRange(r, 0.75, 1.05);
        let pw = tw * randRange(r, 0.45, 0.65);
        let ph = h * randRange(r, 0.25, 0.62);
        let pk = ph / pw > 4 ? randRange(r, 0.15, 0.45) : randRange(r, 0, 0.15);
        let px = cx + Math.cos(a) * d, pz = cz + Math.sin(a) * d;
        let prz = pw * randRange(r, 0.75, 1.05);
        let pyaw = yaw + randRange(r, -0.6, 0.6);
        rockTower(cb, px, pz, pw, prz, ph, pyaw, seed + <f64>(i * 13), far, pk, NaN, true, 0.85);
    }
}

// Massif at rail coords: several rounded towers of different heights
// fused into one irregular mass (in place of flat mesas).
function mesa(w: World, s: f64, x: f64, hw: f64, hd: f64, h: f64, seed: f64, far: bool = false): void {
    let r = mathx.rng(seed);
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = far ? farAt(w, lmax(s, PORTAL_S)) : chunkAt(w, s);
    let yaw = yawAlong(s) + (mathx.hash(seed, 1.3) - 0.5) * 0.9;
    let c = Math.cos(yaw), sn = Math.sin(yaw);
    let n = <i32>mathx.randInt(r, 3, 5);
    for (let i = 1; i <= n; i++) {
        let u = n > 1 ? (<f64>(i - 1) / <f64>(n - 1) * 2 - 1) * hw * 0.62 : 0.0;
        let v = randRange(r, -0.3, 0.3) * hd;
        let rr = hd * randRange(r, 0.55, 0.85);
        let hh = h * (i == <i32>Math.ceil(<f64>n / 2) ? 1.0 : randRange(r, 0.5, 0.9));
        let px = cx + u * c - v * sn, pz = cz + u * sn + v * c;
        let trx = rr * randRange(r, 0.9, 1.25);
        let tyaw = yaw + randRange(r, -0.5, 0.5);
        let pk = hh > rr * 3 ? randRange(r, 0.1, 0.4) : 0.0;
        rockTower(cb, px, pz, trx, rr, hh, tyaw, seed + <f64>(i * 29), far, pk, hh > rr * 1.6 ? 2 : 1, true, 0.82);
    }
}

// Frost-capped rock in the lagoon at rail coords.
function vrock(w: World, s: f64, x: f64, rad: f64, h: f64, seed: f64): void {
    lat(s, x);
    let cx = LAT_X, cz = LAT_Z;
    let cb = chunkAt(w, s);
    rockTower(cb, cx, cz, rad, rad * 0.8, h, yawAlong(s) + mathx.hash(seed, 0.7) * 3, seed, false, 0.1, h > 8 ? 2 : 1, true, 0.8);
}

// cliffs.rockArchSteps: the arch baker's steps as closures (0-based)
function rockArchSteps(asp: cliffs.RockArchSpec): Array<PieceStep> {
    let ab = new cliffs.ArchBaker(asp);
    let out: Array<PieceStep> = [];
    for (let i = 1; i <= ab.total; i++) {
        out.push((b: Builder, cols: Array<Collider>?): void => {
            ab.step(i, b, cols);
        });
    }
    return out;
}

// Natural rock arch beside the rail (lateral center, opening faces the rail).
function vArch(w: World, s: f64, lateral: f64, halfW: f64, height: f64, seed: f64, legTop: f64 = NaN): void {
    frameAt(s);
    let rt = FA_RT;
    lat(s, lateral);
    let cx = LAT_X, cz = LAT_Z;
    let cb = chunkAt(w, s);
    let asp = new cliffs.RockArchSpec();
    asp.x = cx;
    asp.z = cz;
    asp.rx = rt.x;
    asp.rz = rt.z;
    asp.halfW = halfW;
    asp.height = height;
    asp.leg = halfW * 0.6;
    asp.depth = lmax(12, halfW * 0.6);
    asp.lintel = lmax(12, height * 0.36);
    asp.seed = seed;
    asp.look = VLOOK;
    asp.legTop = legTop;
    emitSteps(cb, (): Array<PieceStep> => rockArchSteps(asp));
}

const VIOLET_FALLS: StaticArray<f64> = [0xA6EAFA, 0x74D4F0, 0xC0F2FC, 0x5EC6EA];

function vwall(w: World, side: f64, a: f64, b: f64, coast: KnotFn, edge: KnotFn, seed: f64): StripSpec {
    let c = cfg(a, b, side, 8, seed, terrain.VIOLET_WALL, coast, edge, constF(16), constF(60));
    c.back = 30;
    c.lean = 0.05;
    c.facet = 5;
    c.tiers = 4;
    c.strata = 8;
    c.ledge = 3;
    c.hills = 6;
    c.blocky = true;
    c.endTaper = 80;
    c.caves = 0;
    return strip(w, c);
}

function violetSections(w: World): void {
    let VT = terrain.VIOLET;
    // 06 VIOLET REACH: a wide lagoon between massive blocky walls, a natural
    // arch through the left wall, a waterfall down the right one, twin peaks
    // at the far end framing the falls canyon, and only small frost rocks in
    // the water. The dive threads the colossal gate at 6170. Two colossal
    // towers still frame the portal exit.
    let P0 = PORTAL_S;
    spires(w, P0 + 190, -160, 46, 250, 12001);
    spires(w, P0 + 240, 170, 42, 280, 12002);
    // left: two runs with the natural arch punched between them
    vwall(w, -1, P0 + 280, 5900,
        knots([P0 + 280, 240, P0 + 480, 175, 5700, 140, 5900, 160], 16, 0.012, 12702),
        knots([P0 + 280, 90, 5600, 150, 5900, 128], 22, 0.01, 12703), 12701);
    vArch(w, 5948, -148, 36, 66, 12511, 96);
    vwall(w, -1, 5995, 6600,
        knots([5995, 160, 6120, 120, 6400, 100, 6600, 74], 14, 0.012, 12712),
        knots([5995, 130, 6250, 118, 6600, 96], 20, 0.01, 12713), 12711);
    // right: one long wall, lifting to a waterfall lip at 6040
    let rightWall = vwall(w, 1, P0 + 340, 6590,
        knots([P0 + 340, 250, P0 + 560, 180, 5800, 140, 6040, 120, 6300, 108, 6590, 80], 16, 0.012, 12722),
        (s: f64): f64 => {
            let n = mathx.fbm2(s * 0.006 + 5, 7.3, 3) / 0.875;
            return fallLift(s, 1, 110 + (n - 0.5) * 50);
        }, 12721);
    let rw = new Map<i32, StripSpec>();
    rw.set(1, rightWall);
    falls(w, 5800, 6300, seq4(VIOLET_FALLS), 0xF0FEFF, 14400, rw);
    // twin peaks at the far end of the lagoon, framing the falls canyon
    spires(w, 6555, -92, 34, 200, 13111);
    spires(w, 6590, 96, 36, 240, 13121);
    // small frost rocks in the water (scale), none in the flight box
    {
        let r = mathx.rng(1203);
        for (let i = 1; i <= 16; i++) {
            let s = randRange(r, P0 + 250, 6350);
            let side: f64 = rand(r) < 0.5 ? -1 : 1;
            let x = side * randRange(r, 34, 88);
            let rad = randRange(r, 2.5, 6.5);
            vrock(w, s, x, rad, rad * randRange(r, 0.9, 1.8), 13200 + <f64>(i * 7));
        }
    }
    // the violet gate: a colossal arch the dive threads at its bottom
    {
        let s = 6170.0;
        frameAt(s);
        let p = FA_P, rt = FA_RT;
        let cb = chunkAt(w, s);
        let gsp = new cliffs.RockArchSpec();
        gsp.x = p.x;
        gsp.z = p.z;
        gsp.rx = rt.x;
        gsp.rz = rt.z;
        gsp.halfW = 40;
        gsp.height = <f64>p.y + 46;
        gsp.leg = 22;
        gsp.depth = 17;
        gsp.lintel = 24;
        gsp.seed = 12501;
        gsp.look = VLOOK;
        emitSteps(cb, (): Array<PieceStep> => rockArchSteps(gsp));
    }
    // natural arch on the way to the Eye
    vArch(w, 7930, 150, 30, 52, 12531);
    // the lagoon where the dive levels out
    const rocks: StaticArray<f64> = [6390, -18, 4.5, 6, 6450, 21, 5, 9, 6520, -9, 3.2, 4, 6575, 15, 4, 5.5, 6440, -42, 7, 14, 6560, 46, 8, 18];
    for (let i = 1; i <= 6; i++) {
        let o = (i - 1) * 4;
        vrock(w, rocks[o], rocks[o + 1], rocks[o + 2], rocks[o + 3], 13000 + <f64>(i * 7));
    }

    // 07 THE FALLS: violet canyon with waterfalls ------------------------------------
    {
        let c0 = 6620.0, c1 = 7680.0;
        let walls = new Map<i32, StripSpec>();
        for (let side = -1; side <= 1; side += 2) {
            let sd = <f64>side;
            let c = cfg(c0, c1, sd, 6, 14000 + sd, VT,
                (s: f64): f64 => lv.fallsDist(s, sd),
                (s: f64): f64 => {
                    let n = mathx.fbm2(s * 0.007 + 3, sd * 2.3, 3) / 0.875;
                    return fallLift(s, sd, 72 + (n - 0.5) * 40);
                },
                constF(10), constF(55));
            c.back = 20;
            c.lean = 0.12;
            c.facet = 5.5;
            c.tiers = 3;
            c.strata = 7;
            c.ledge = 1.8;
            c.hills = 4;
            walls.set(side, strip(w, c));
        }
        falls(w, c0, c1, seq4(VIOLET_FALLS), 0xF0FEFF, 14500, walls);
        // massive rounded boulders stud both walls (deep seams between
        // them), leaving the waterfalls and the curtain clear
        for (let side = -1; side <= 1; side += 2) {
            let sd = <f64>side;
            let r = mathx.rng(14800 + sd);
            let s = c0 + 14;
            let k = 0;
            while (s < c1 - 14) {
                k += 1;
                let clear = Math.abs(s - A.fallsS) > 46;
                let wfs = lv.waterfalls;
                for (let i = 1; i < wfs.length; i++) {
                    let f = wfs[i];
                    if (f.s > c0 && f.s < c1) {
                        frameAt(f.s);
                        let p = FA_P, rt = FA_RT;
                        let fx = (f.x - <f64>p.x) * <f64>rt.x + (f.z - <f64>p.z) * <f64>rt.z;
                        if (fx * sd > 0 && Math.abs(f.s - s) < f.width * 0.5 + 24) clear = false;
                    }
                }
                let rx = randRange(r, 13, 23);
                if (clear) {
                    let d = lv.fallsDist(s, sd) + rx * randRange(r, 0.3, 0.55);
                    let n = mathx.fbm2(s * 0.007 + 3, sd * 2.3, 3) / 0.875;
                    let wallH = fallLift(s, sd, 72 + (n - 0.5) * 40);
                    let h = wallH * randRange(r, 0.5, 1.12);
                    lat(s, sd * d);
                    let cx = LAT_X, cz = LAT_Z;
                    let rz = rx * randRange(r, 0.7, 0.92);
                    let yaw = yawAlong(s) + randRange(r, -0.4, 0.4);
                    let pk = randRange(r, 0, 0.12);
                    let sg = mathx.randInt(r, 2, 3);
                    rockTower(chunkAt(w, s), cx, cz, rx, rz, h, yaw, 14900 + <f64>(k * 7) + sd, false, pk, sg, true, 0.86, 12);
                }
                s += rx * randRange(r, 1.45, 2.0);
            }
        }
        // the curtain: a bridge pouring a wall of water across the rail
        let s = A.fallsS;
        let height = 52.0, lintel = 20.0;
        gateAt(w, s, 44, height, lintel, 20, 13, 14601, VT, gateSpec(4, 1.4, 5, NaN, 1));
        frameAt(s);
        let p = FA_P, f = FA_F;
        let cb = chunkAt(w, s);
        let csp = new geo.FallSpec();
        csp.x = <f64>p.x - <f64>f.x * 13.5;
        csp.y = height + lintel - 1;
        csp.z = <f64>p.z - <f64>f.z * 13.5;
        csp.bottom = 0;
        csp.width = 64;
        csp.ox = -<f64>f.x;
        csp.oz = -<f64>f.z;
        csp.seed = 14611;
        csp.colors = [0.0, 0x9CE6F8, 0x6FD2F0, 0xB6F0FC, 0x58C2E8];
        csp.foam = 0xF0FEFF;
        csp.arc = 3;
        csp.splash = false;
        emit(cb, (b: Builder, _cols: Array<Collider>): void => {
            geo.waterfall(b, csp);
        });
        let af = new ambient.Fall();
        af.x = <f64>p.x - <f64>f.x * 13.5;
        af.y = height + lintel - 1;
        af.z = <f64>p.z - <f64>f.z * 13.5;
        af.bottom = 0;
        af.width = 64;
        af.ox = -<f64>f.x;
        af.oz = -<f64>f.z;
        af.arc = 3;
        af.s = s;
        ambient.addFall(af);
        const pr: StaticArray<f64> = [6760, 22, 3.5, 5, 6990, -21, 4, 6, 7180, 23, 3, 4, 7520, -22, 3.6, 5];
        for (let i = 1; i <= 4; i++) {
            let o = (i - 1) * 4;
            vrock(w, pr[o], pr[o + 1], pr[o + 2], pr[o + 3], 14700 + <f64>(i * 5));
        }
    }

    // 08 THE EYE: open lagoon, spire gauntlet, final climb -------------------------
    {
        let r = mathx.rng(1501);
        let s = 7760.0;
        let k = 0;
        while (s < LEN - 280) {
            k += 1;
            frameAt(s);
            let py = <f64>FA_P.y;
            for (let side = -1; side <= 1; side += 2) {
                let sd = <f64>side;
                let roll = rand(r);
                let ss = s + randRange(r, -30, 30);
                if (roll < 0.6) {
                    let h = lmax(py + randRange(r, 40, 110), randRange(r, 60, 120));
                    let rad = lmax(randRange(r, 24, 40), h * 0.24);
                    let x = sd * (rad * 1.1 + randRange(r, 34, 110));
                    lat(ss, x);
                    if (railClear(LAT_X, LAT_Z, rad + 26, PORTAL_S, LEN)) spires(w, ss, x, rad, h, 15000 + <f64>(k * 13) + sd);
                } else if (roll < 0.85) {
                    let hw = randRange(r, 26, 46);
                    let x = sd * (hw + randRange(r, 120, 200));
                    lat(ss, x);
                    if (railClear(LAT_X, LAT_Z, hw + 60, PORTAL_S, LEN)) {
                        let hd = hw * randRange(r, 0.5, 0.8);
                        let mh = randRange(r, 40, 90);
                        mesa(w, ss, x, hw, hd, mh, 15300 + <f64>(k * 13) + sd);
                    }
                }
            }
            s += randRange(r, 100, 150);
        }
        // the Watcher's avenue: paired monoliths flank the fight (nothing
        // within ~27 m of the rail at s 7720-8650)
        const g: StaticArray<f64> = [7885, -39, 7, 58, 7915, 40, 6.5, 44, 8125, 39, 7.5, 66, 8150, -40, 6.5, 48, 8365, -41, 8, 74, 8390, 40, 7, 54, 8600, 41, 7, 60, 8625, -40, 6.5, 46];
        for (let i = 1; i <= 8; i++) {
            let o = (i - 1) * 4;
            lat(g[o], g[o + 1]);
            let cx = LAT_X, cz = LAT_Z;
            pillar(chunkAt(w, g[o]), cx, cz, g[o + 2], g[o + 2] * 0.85, g[o + 3], 3, yawAlong(g[o]) + <f64>i, 15500 + <f64>(i * 9), false, 0.86);
        }
        // the Eye stands between two colossal towers
        let e = lv.eye;
        spires(w, e.s - 70, -(e.radius + 135), 50, 290, 15601);
        spires(w, e.s - 40, e.radius + 140, 46, 320, 15611);
        vArch(w, e.s - 450, -(e.radius + 150), 36, 64, 15621);
        // a jagged peak cluster behind the Eye frames it
        const peaks: StaticArray<f64> = [230, -40, 46, 330, 300, 120, 52, 390, 380, -170, 60, 300, 470, 40, 70, 420, 420, 260, 56, 280, 330, -290, 50, 240];
        for (let i = 1; i <= 6; i++) {
            let o = (i - 1) * 4;
            let ps = LEN + peaks[o];
            lat(ps, peaks[o + 1]);
            let cx = LAT_X, cz = LAT_Z;
            let r2 = mathx.rng(15700 + <f64>i);
            let prz = peaks[o + 2] * randRange(r2, 0.75, 0.95);
            let pyaw = randRange(r2, 0, 6);
            let ppk = randRange(r2, 0.6, 0.95);
            let psg = mathx.randInt(r2, 3, 4);
            rockTower(farAt(w, ps), cx, cz, peaks[o + 2], prz, peaks[o + 3], pyaw, 15700 + <f64>(i * 11), true, ppk, psg, false, 0.8);
        }
    }
}

function farViolet(w: World): void {
    // distant spire clusters and mesas in the haze
    let r = mathx.rng(4001);
    let s = PORTAL_S;
    while (s < LEN + 600) {
        for (let side = -1; side <= 1; side += 2) {
            let sd = <f64>side;
            if (rand(r) < 0.8) {
                let d = randRange(r, 320, 850);
                let rad = randRange(r, 40, 90);
                lat(s, sd * (d + rad));
                let cx = LAT_X, cz = LAT_Z;
                if (railClear(cx, cz, d + rad * 0.5, PORTAL_S, LEN)) {
                    if (rand(r) < 0.65) {
                        let h = randRange(r, 140, 360);
                        spires(w, s, sd * (d + rad), rad, h, 40000 + Math.floor(s) + sd, true);
                    } else {
                        let cb = farAt(w, s);
                        let hd = rad * randRange(r, 0.5, 0.8);
                        let h = randRange(r, 50, 110);
                        let yaw = rand(r) * 6;
                        pillar(cb, cx, cz, rad, hd, h, 2, yaw, 41000 + Math.floor(s) + sd, true, 0.8);
                    }
                }
            }
        }
        s += randRange(r, 200, 340);
    }
}

// Set-piece gates ---------------------------------------------------------------------

function ringSteps(cb: CB, rsp: props.RingSpec): void {
    emitSteps(cb, (): Array<PieceStep> => props.portalRingSteps(rsp));
}

function portalPiece(cb: CB): void {
    let g = lv.portal;
    let c = lv.world(g.s, g.x, g.y);
    frameAt(g.s);
    let f = FA_F;
    let fl = Math.sqrt(<f64>f.x * <f64>f.x + <f64>f.z * <f64>f.z);
    let rsp = new props.RingSpec();
    rsp.x = c.x;
    rsp.y = c.y;
    rsp.z = c.z;
    rsp.fx = <f64>f.x / fl;
    rsp.fz = <f64>f.z / fl;
    rsp.radius = g.radius;
    rsp.rim = 9;
    rsp.depth = 10;
    rsp.seed = 5555;
    rsp.rimColors = [0.0, 0xD6AE55, 0xF7E9C2, 0xEFE0B8, 0xD2B064];
    rsp.rocks = 26;
    rsp.rockStyle = geo.COAST;
    ringSteps(cb, rsp);
}

function eyePiece(cb: CB): void {
    let g = lv.eye;
    let c = lv.world(g.s, g.x, g.y);
    frameAt(g.s);
    let f = FA_F;
    let fl = Math.sqrt(<f64>f.x * <f64>f.x + <f64>f.z * <f64>f.z);
    let rsp = new props.RingSpec();
    rsp.x = c.x;
    rsp.y = c.y;
    rsp.z = c.z;
    rsp.fx = <f64>f.x / fl;
    rsp.fz = <f64>f.z / fl;
    rsp.radius = g.radius;
    rsp.rim = 10;
    rsp.depth = 12;
    rsp.seed = 7777;
    rsp.rimColors = [0.0, 0xE8BE4E, 0xFFF3CC, 0xB9F0FA, 0x6A45B6];
    rsp.rocks = 34;
    rsp.rockStyle = geo.VIOLET;
    rsp.shards = true;
    ringSteps(cb, rsp);
}

// Build ----------------------------------------------------------------------------------

export class Stats {
    verts: f64 = 0;
    tris: f64 = 0;
    chunks: f64 = 0;
    colliders: f64 = 0;
    ms: f64 = 0;
    maxVerts: f64 = 0;
    planMs: f64 = 0;
    initMs: f64 = 0;
    frames: f64 = 0;
    urgent: f64 = 0;
}
export let stats = new Stats();

// Background bake budget per frame (ms): see the Luau original (BUDGET_MS):
// paced budget under a creeping ceiling, fixed budgets when near content is
// missing, BUDGET_CATCHUP_MS once it is close.
const PACE_LATE: f64 = 0.0202;
const PACE_UP: f64 = 0.1;
const PACE_CREEP: f64 = 0.002;
// A jump further than this between two draws while the draw loop was not
// running bakes the whole window at once (see the Luau original).
const JUMP_M: f64 = 30;
const JUMP_QUERIES: i32 = 12;

// Graphics quality (DIRECTION #27): draw-time only (no rebake).
export class Quality {
    ahead: f64;
    farCull: bool;
    farRefl: bool;
    life: f64;
    mist: f64;
    budget: f64;
    constructor(ahead: f64, farCull: bool, farRefl: bool, life: f64, mist: f64, budget: f64) {
        this.ahead = ahead;
        this.farCull = farCull;
        this.farRefl = farRefl;
        this.life = life;
        this.mist = mist;
        this.budget = budget;
    }
}
export class QualityTable {
    high: Quality = new Quality(DRAW_AHEAD, false, true, 1, 1, 1);
    medium: Quality = new Quality(1400, true, true, 0.75, 0.7, 1);
    low: Quality = new Quality(1100, true, false, 0.5, 0.5, 1);
}
export const QUALITY = new QualityTable();
let quality: Quality = QUALITY.high;
export let qualityLevel: string = "high";

class Cur {
    cb: CB;
    i: i32 = 1;
    ci: i32 = 0;
    nm: i32 = 0;
    nh: i32 = 0;
    constructor(cb: CB) {
        this.cb = cb;
    }
}

let cache: Array<Chunk>? = null;
let cbs: Array<CB> = new Array<CB>(1); // every chunk's plan, in chunk order
let pending: i32 = 0;
let scratch: Builder? = null;
// the chunk being baked: its next thunk, then the index lists' cursor (byte
// offset into its indices) and how many indices each list holds so far
let current: Cur? = null;
let gameT: f64 = 0; // last game time seen by drawDynamic
let urgent = false; // baking on the spot: no fade
let t0Build: f64 = 0;
let lastVisS: f64 = 0; // player s at the last isVisible call (jump detection)
let queries: i32 = 0; // collision queries since the last isVisible call
// Collision broad phase (EFFICIENCY_REVIEW 1.1): every baked chunk's
// colliders by 16 m xz cell, filled at upload; ties by (chunk, collider)
// key = chunk index * 65536 + collider index (exact: i32 keys, i64 cells).
// Each grid entry gets a dense id (colOf / keyOf / markOf by id).
const CELL_INV: f64 = 1.0 / 16;
let cells = new Map<i64, Array<i32>>(); // cell -> dense ids
let colOf: Array<Collider> = new Array<Collider>(1); // dense id -> collider
let keyOf: Array<i32> = [0]; // dense id -> collider key
let markOf: Array<i32> = [0]; // dense id -> last query that tested it
let stamp: i32 = 0;
// (gridSet / farSet: Chunk.grid / Chunk.far)

@inline function cellKey(ix: f64, iz: f64): i64 {
    return (<i64>ix + 32768) * 65536 + <i64>iz + 32768;
}

// Debug (knobs.BAKE_HASH): a checksum of each baked chunk's buffers.
function bakeHash(cb: CB, b: Builder): void {
    let s1 = hashWords(b.vu, b.vcount * 8);
    let a1 = H1, a2 = H2;
    hashWords(b.iu, b.icount);
    let c1 = H1, c2 = H2;
    console.log(format("  bake hash %s verts %d idx %d vb %08x%08x ib %08x%08x bounds %.3f %.3f %.3f %.3f %.3f %.3f cols %d", [
        S(cb.name), N(<f64>b.vcount), N(<f64>b.icount), N(<f64>a1), N(<f64>a2), N(<f64>c1), N(<f64>c2),
        N(b.minx), N(b.miny), N(b.minz), N(b.maxx), N(b.maxy), N(b.maxz), N(<f64>(cb.cols.length - 1))]));
}
let H1: u32 = 0, H2: u32 = 0;
function hashWords(w: Uint32Array, n: i32): bool {
    let h1: u32 = 0, h2: u32 = 0;
    for (let k = 0; k < n; k++) {
        let x = w[k];
        h1 = h1 * 31 + x;
        h2 = h2 + x * <u32>(k % 251 + 1);
    }
    H1 = h1;
    H2 = h2;
    return true;
}

// The broad phase's cells for a chunk being uploaded (its colliders are
// final from here on).
function gridAdd(cb: CB): void {
    let idx = cbs.indexOf(cb);
    let e = coll.EXT;
    for (let j = 1; j < cb.cols.length; j++) {
        let c = cb.cols[j];
        let id = colOf.length;
        colOf.push(c);
        keyOf.push(idx * 65536 + j);
        markOf.push(0);
        coll.extent(c);
        let x0 = e[0], z0 = e[2], x1 = e[3], z1 = e[5];
        for (let ix = Math.floor(x0 * CELL_INV); ix <= Math.floor(x1 * CELL_INV); ix++) {
            for (let iz = Math.floor(z0 * CELL_INV); iz <= Math.floor(z1 * CELL_INV); iz++) {
                let k = cellKey(ix, iz);
                if (cells.has(k)) {
                    cells.get(k).push(id);
                } else {
                    cells.set(k, [id]);
                }
            }
        }
    }
}

// Index lists for upload (EFFICIENCY_REVIEW 1.3): scratch, grown as needed
// and released with the scratch builder once every chunk is baked.
let ixFull = new ArrayBuffer(4), ixMain = new ArrayBuffer(4), ixHull = new ArrayBuffer(4);
let ixCap: i32 = 0;

function releaseIndexScratch(): void {
    ixFull = new ArrayBuffer(4);
    ixMain = new ArrayBuffer(4);
    ixHull = new ArrayBuffer(4);
    ixCap = 0;
}

// An immutable index buffer holding the first `n` indices of `src` (`isz`
// bytes each).
function indexBuffer(src: ArrayBuffer, n: i32, isz: i32): GPUBuffer {
    let size = max(<i32>Math.ceil(<f64>(n * isz) / 4) * 4, 4);
    let data = new ArrayBuffer(size);
    Uint8Array.wrap(data).set(Uint8Array.wrap(src, 0, n * isz));
    return new GPUBuffer(BufferUsage.index, <u32>size, data, true);
}

// The per-pass index lists of the finished builder `b`, up to `count`
// triangles from the cursor `cur.ci` (byte offset), in slices like the
// thunks: a triangle whose three vertices are shell vertices is a shell copy
// (left out of ixMain); one with any outline weight is inked (in ixHull).
// With 16-bit indices ixFull gets the converted full list.
function classify(cur: Cur, b: Builder, count: i32): void {
    let ni = b.icount;
    if (cur.ci == 0 && ni * 4 > ixCap) {
        ixCap = ni * 4;
        ixFull = new ArrayBuffer(ixCap);
        ixMain = new ArrayBuffer(ixCap);
        ixHull = new ArrayBuffer(ixCap);
    }
    let small = b.vcount <= 65535;
    let v8 = b.v8, iu = b.iu;
    let SW = <u8>meshgen.SHELL_W;
    let nm = cur.nm, nh = cur.nh;
    let o1 = min(ni * 4, cur.ci + count * 12);
    if (small) {
        let full = Uint16Array.wrap(ixFull), main = Uint16Array.wrap(ixMain), hull = Uint16Array.wrap(ixHull);
        for (let o = cur.ci; o <= o1 - 12; o += 12) {
            let w = o >> 2;
            let i0 = iu[w], i1 = iu[w + 1], i2 = iu[w + 2];
            let a0 = <i32>i0 * 32 + 28, a1 = <i32>i1 * 32 + 28, a2 = <i32>i2 * 32 + 28;
            let shell = v8[a0 + 3] == SW && v8[a1 + 3] == SW && v8[a2 + 3] == SW;
            let inked = v8[a0 + 1] > 0 || v8[a1 + 1] > 0 || v8[a2 + 1] > 0;
            full[w] = <u16>i0;
            full[w + 1] = <u16>i1;
            full[w + 2] = <u16>i2;
            if (!shell) {
                main[nm] = <u16>i0;
                main[nm + 1] = <u16>i1;
                main[nm + 2] = <u16>i2;
                nm += 3;
            }
            if (inked) {
                hull[nh] = <u16>i0;
                hull[nh + 1] = <u16>i1;
                hull[nh + 2] = <u16>i2;
                nh += 3;
            }
        }
    } else {
        let main = Uint32Array.wrap(ixMain), hull = Uint32Array.wrap(ixHull);
        for (let o = cur.ci; o <= o1 - 12; o += 12) {
            let w = o >> 2;
            let i0 = iu[w], i1 = iu[w + 1], i2 = iu[w + 2];
            let a0 = <i32>i0 * 32 + 28, a1 = <i32>i1 * 32 + 28, a2 = <i32>i2 * 32 + 28;
            let shell = v8[a0 + 3] == SW && v8[a1 + 3] == SW && v8[a2 + 3] == SW;
            let inked = v8[a0 + 1] > 0 || v8[a1 + 1] > 0 || v8[a2 + 1] > 0;
            if (!shell) {
                main[nm] = i0;
                main[nm + 1] = i1;
                main[nm + 2] = i2;
                nm += 3;
            }
            if (inked) {
                hull[nh] = i0;
                hull[nh + 1] = i1;
                hull[nh + 2] = i2;
                nh += 3;
            }
        }
    }
    cur.ci = o1;
    cur.nm = nm;
    cur.nh = nh;
}

// Upload the scratch builder into a chunk (the vertex buffer takes a prefix
// of the builder's buffer, which is then reused), with the index lists
// `classify` built (`nm` / `nh` indices).
function upload(cb: CB, b: Builder, nm: i32, nh: i32): void {
    if (knobs.BAKE_HASH) bakeHash(cb, b);
    let hook = knobs.onUpload;
    if (hook != null) hook(cb.name, b);
    let small = b.vcount <= 65535;
    let isz = small ? 2 : 4;
    let ni = b.icount;
    let rad = 0.0;
    if (b.vcount > 0) {
        let ax = lmax(Math.abs(b.minx), Math.abs(b.maxx));
        let ay = lmax(Math.abs(b.miny), Math.abs(b.maxy));
        let az = lmax(Math.abs(b.minz), Math.abs(b.maxz));
        rad = Math.sqrt(ax * ax + ay * ay + az * az);
    }
    let vbytes = max(b.vcount * 32, 32);
    let vbuf = new GPUBuffer(BufferUsage.vertex, <u32>vbytes);
    if (b.vcount > 0) vbuf.update(0, b.vb, <u32>(b.vcount * 32));
    let mesh = new gpu.Mesh();
    mesh.vb = vbuf;
    mesh.ib = indexBuffer(small ? ixFull : b.ib, ni, isz);
    mesh.count = b.icount;
    mesh.ifmt = small ? "uint16" : "uint32";
    mesh.ibMain = indexBuffer(ixMain, nm, isz);
    mesh.countMain = <f64>nm;
    mesh.ibHull = indexBuffer(ixHull, nh, isz);
    mesh.countHull = <f64>nh;
    mesh.minx = b.minx;
    mesh.miny = b.miny;
    mesh.minz = b.minz;
    mesh.maxx = b.maxx;
    mesh.maxy = b.maxy;
    mesh.maxz = b.maxz;
    mesh.radius = rad;
    let batch = gpu.batch("scenery_" + cb.name, mesh, 1, true, true);
    gpu.addIdentity(batch);
    let ch = cb.chunk;
    if (ch.far) batch.reflect = quality.farRefl;
    ch.batch = batch;
    ch.bounds = coll.bounds(cb.cols);
    gridAdd(cb);
    ch.verts = b.vcount;
    ch.readyT = urgent ? -HUGE : gameT;
    ch.ready = true;
    stats.verts += <f64>b.vcount;
    stats.tris += <f64>(b.icount / 3);
    stats.chunks += 1;
    stats.colliders += <f64>(cb.cols.length - 1);
    stats.maxVerts = lmax(stats.maxVerts, <f64>b.vcount);
    if (knobs.DEBUG) {
        console.log(format("  chunk %s gs %d..%d draw %d..%d verts %d cols %d", [S(cb.name), N(cb.gs0), N(cb.gs1), N(ch.s0), N(ch.s1), N(<f64>b.vcount), N(<f64>(cb.cols.length - 1))]));
    }
}

function allDone(): void {
    stats.ms = Math.floor((clock() - t0Build) * 1000);
    console.log(format("scenery: %d chunks, %d verts (max %d/chunk), %d tris, %d colliders; plan %d ms, first frame %d ms, all baked after %d ms over %d frames", [
        N(stats.chunks), N(stats.verts), N(stats.maxVerts), N(stats.tris), N(stats.colliders), N(stats.planMs), N(stats.initMs), N(stats.ms), N(stats.frames)]));
    scratch = null;
    releaseIndexScratch();
}

// Bake state: the chunk in progress owns the shared scratch builder until
// its last thunk has run (thunks run whole; the bake resumes next frame).
function scratchBuilder(): Builder {
    let sb = scratch;
    if (sb != null) return sb;
    let nb = meshgen.create(65536);
    scratch = nb;
    return nb;
}

function begin(cb: CB): void {
    let b = scratchBuilder();
    meshgen.reset(b);
    // ink shells are built in their own time-sliced steps (bit-identical)
    meshgen.inkDefer(b, true);
    current = new Cur(cb);
}

// Running average of one thunk's cost (s): the bake stops before a thunk
// that would likely overrun the frame's budget.
let thunkAvg: f64 = 0.002;
let uploadAvg: f64 = 0.0008; // upload of a finished chunk (its own step)
let frameSpent: f64 = 0; // bake time spent since the last drawDynamic (s)
let paceB: f64 = knobs.BUDGET_SLOW_MS; // the paced budget (ms) and its ceiling
let paceC: f64 = knobs.BUDGET_MENU_MS;
let lastDraw: f64 = 0;
// isVisible's on-the-spot bakes this draw (s; reset by drawDynamicBake): past
// VIEW_BAKE_MS the next chunk is left to the pump (drawn a frame or two later)
// so one draw stays under the watchdog
let viewSpent: f64 = 0;
const VIEW_BAKE_MS: f64 = 40;
const INK_MIN: f64 = 0.00015; // an ink slice starts only with this much budget left (s)
const CLASSIFY_SLICE: i32 = 2048; // triangles per index-list slice (~0.2 ms on an M4)
const CLASSIFY_MIN: f64 = 0.0002; // a slice starts only with this much budget left (s)

// Runs thunks of the current chunk until done (true) or until the next one
// would likely end past `untilT`. `force` runs at least one (progress).
function step(untilT: f64, force: bool = false): bool {
    let cur = current;
    if (cur == null) return true;
    let cb = cur.cb;
    let b = scratchBuilder();
    let th = cb.thunks;
    let n = th.length - 1;
    let must = force;
    while (true) {
        // the last thunk's ink shells first, in slices (the next thunk's
        // marks must see them in place)
        if (meshgen.inkPending(b)) {
            let t = clock();
            if (!must && t + INK_MIN > untilT) return false;
            must = false;
            let vc0 = b.vcount;
            let done = meshgen.inkStep(b, untilT);
            let dt = clock() - t;
            let slow = knobs.SLOW_THUNK_MS;
            if (!isNaN(slow) && dt * 1000 > slow) {
                console.log(format("  slow thunk %s #%d ink %.2f ms (+%d verts)", [S(cb.name), N(<f64>(cur.i - 1)), N(dt * 1000), N(<f64>(b.vcount - vc0))]));
            }
            if (!done) return false;
        }
        if (cur.i > n) break;
        let t = clock();
        if (!must && t + thunkAvg > untilT) return false;
        must = false;
        let tk = th[cur.i]!;
        let vc0 = b.vcount;
        let nxt: Thunk? = null;
        let fn = tk.fn;
        if (fn != null) {
            fn(b, cb.cols);
        } else {
            nxt = tk.st!(b, cb.cols);
        }
        if (nxt != null) {
            th[cur.i] = nxt; // the rest of the piece: the next step
        } else {
            th[cur.i] = null;
            cur.i += 1;
        }
        let dt = clock() - t;
        thunkAvg += (dt - thunkAvg) * 0.2;
        let slow = knobs.SLOW_THUNK_MS;
        if (!isNaN(slow) && dt * 1000 > slow) {
            console.log(format("  slow thunk %s #%d %.2f ms (+%d verts)", [S(cb.name), N(<f64>(cur.i - (nxt != null ? 0 : 1))), N(dt * 1000), N(<f64>(b.vcount - vc0))]));
        }
    }
    // the index lists, a slice at a time
    while (cur.ci < b.icount * 4) {
        if (!must && clock() + CLASSIFY_MIN > untilT) return false;
        must = false;
        classify(cur, b, CLASSIFY_SLICE);
    }
    // the upload is its own step (it can take a millisecond or more)
    if (!must && clock() + uploadAvg > untilT) return false;
    let tu = clock();
    upload(cb, b, cur.nm, cur.nh);
    uploadAvg += (clock() - tu - uploadAvg) * 0.3;
    meshgen.reset(b);
    th.length = 1;
    current = null;
    pending -= 1;
    if (pending == 0) allDone();
    return true;
}

function ensure(cb: CB, qa: string? = null): void {
    if (cb.chunk.ready) return;
    if (qa != null) {
        // QA metric: a chunk the background bake had not reached in time
        stats.urgent += 1;
        console.log(format("scenery: %s baked on the spot (%s, %d so far)", [S(cb.name), S(qa), N(stats.urgent)]));
    }
    // the chunk in progress owns the builder: finish it first
    let t0 = clock();
    urgent = true;
    if (current != null) step(HUGE);
    if (!cb.chunk.ready) {
        begin(cb);
        step(HUGE);
    }
    urgent = false;
    // (the frame's bake budget is spent)
    frameSpent += clock() - t0;
}

// Priority of a chunk that still has to be baked, player at s (lower first):
// visible now, then upcoming by distance, chunks already left behind last.
function priority(cb: CB, s: f64): f64 {
    if (s >= cb.vis0 && s < cb.vis1) {
        return lmax(0, cb.gs0 - s) * 0.01;
    } else if (s < cb.vis0) {
        return 100 + cb.vis0 - s;
    }
    return 1e6 + s - cb.vis1;
}

@inline function isFar(name: string): bool {
    return name.indexOf("far") >= 0;
}

// Background bake: a millisecond or two per frame, nearest chunks first.
// Every call in a frame shares one budget; only the first call of a frame
// may start a thunk it cannot fit (progress), later calls only fill slack.
// budgetMs NaN = nil (drawDynamic's top-up).
export function pump(s: f64, budgetMs: f64 = NaN): void {
    if (pending == 0) return;
    let start = clock();
    // game.advance pumps first in a frame (with a budget); drawDynamic tops up
    if (!isNaN(budgetMs)) frameSpent = 0;
    // what is missing: near content on screen (pops) > anything in a draw
    // window (fades in when late) > the rest (far ahead)
    let nearMissing = false, visibleMissing = false, catchup = false;
    for (let i = 1; i < cbs.length; i++) {
        let cb = cbs[i];
        if (!cb.chunk.ready && s >= cb.vis0 && s < cb.vis1) {
            visibleMissing = true;
            if (cb.gs0 < s + knobs.NEAR_AHEAD && !isFar(cb.name)) {
                nearMissing = true;
                if (cb.gs0 < s + knobs.CATCHUP_AHEAD) {
                    catchup = true;
                    break;
                }
            }
        }
    }
    let budget: f64;
    if (catchup && isNaN(budgetMs)) {
        budget = knobs.BUDGET_CATCHUP_MS;
    } else if (nearMissing) {
        budget = knobs.BUDGET_VISIBLE_MS;
    } else if (!isNaN(budgetMs)) {
        budget = lmin(paceB, knobs.BUDGET_MENU_MS);
    } else {
        budget = lmin(paceB, visibleMissing ? knobs.BUDGET_MS : knobs.BUDGET_IDLE_MS);
    }
    budget *= quality.budget;
    budget -= frameSpent * 1000;
    if (budget <= 0.05) return;
    stats.frames += 1;
    let untilT = start + budget / 1000;
    let first = frameSpent == 0 || nearMissing;
    while (pending > 0 && clock() < untilT) {
        if (current == null) {
            let best: CB? = null;
            let bp = HUGE;
            for (let i = 1; i < cbs.length; i++) {
                let cb = cbs[i];
                if (!cb.chunk.ready) {
                    let pr = priority(cb, s);
                    if (pr < bp) {
                        best = cb;
                        bp = pr;
                    }
                }
            }
            if (best == null) break;
            begin(best);
        }
        let done = step(untilT, first);
        first = false;
        if (!done) break;
    }
    frameSpent += clock() - start;
}

// True when every chunk is baked.
export function ready(): bool {
    return pending == 0;
}

// World box around the rail over [s0, s1], grown by `pad` (collision
// queries inside it bake the chunk first: collision never waits for draw).
function railBox(s0: f64, s1: f64, pad: f64): Bounds {
    let minx = HUGE, miny = HUGE, minz = HUGE;
    let maxx = -HUGE, maxy = -HUGE, maxz = -HUGE;
    let s = s0;
    while (true) {
        frameAt(s);
        let px = <f64>FA_P.x, py = <f64>FA_P.y, pz = <f64>FA_P.z;
        minx = lmin(minx, px);
        maxx = lmax(maxx, px);
        miny = lmin(miny, py);
        maxy = lmax(maxy, py);
        minz = lmin(minz, pz);
        maxz = lmax(maxz, pz);
        if (s >= s1) break;
        s = lmin(s1, s + 20);
    }
    let bd = new Bounds();
    bd.minx = minx - pad;
    bd.miny = lmin(miny - pad, -20);
    bd.minz = minz - pad;
    bd.maxx = maxx + pad;
    bd.maxy = maxy + pad;
    bd.maxz = maxz + pad;
    return bd;
}

// Bake every chunk whose window holds s, with no fade.
function syncAt(s: f64): void {
    if (pending == 0) return;
    for (let i = 1; i < cbs.length; i++) {
        let cb = cbs[i];
        if (!cb.chunk.ready && s >= cb.vis0 && s < cb.vis1) ensure(cb);
    }
}

// Flight school -------------------------------------------------------------------

// The school lane out at sea (s < 0: the rail runs straight back along frame
// 0): marker buoys either side every 120 m and the school barge under the
// launch hover. Its own chunk after the grid and the far layers (never c1),
// drawn only over the lane. No colliders.
export const SCHOOL_VIS0: f64 = -4700;
export const SCHOOL_VIS1: f64 = -1100;
export const SCHOOL_BUOY_X: f64 = 30;

function schoolLane(cb: CB): void {
    let sc = lv.school;
    let s = sc.s;
    while (s <= -1200) {
        lat(s, -SCHOOL_BUOY_X);
        let rx = LAT_X, rz = LAT_Z;
        lat(s, SCHOOL_BUOY_X);
        let gx = LAT_X, gz = LAT_Z;
        emit(cb, (b: Builder, _cols: Array<Collider>): void => {
            props.buoy(b, rx, rz, true);
            props.buoy(b, gx, gz, false);
        });
        s += 120;
    }
    lat(sc.s, 0);
    let bx = LAT_X, bz = LAT_Z;
    let yaw = yawAlong(sc.s);
    emit(cb, (b: Builder, _cols: Array<Collider>): void => {
        props.schoolBarge(b, bx, bz, yaw);
    });
}

// The school's far coast: two low arms of headlands 2-3 km ahead flank the
// horizon. No colliders. (s, lateral, half length, half width, cliff
// height, seed)
export const SCHOOL_COAST: StaticArray<f64> = [
    -2750, -700, 230, 110, 58, 1,
    -2380, -770, 260, 120, 74, 2,
    -2020, -880, 300, 130, 64, 3,
    -1700, -1060, 320, 150, 92, 4,
    -2950, 880, 240, 110, 62, 5,
    -2560, 820, 280, 120, 78, 6,
    -2180, 930, 300, 140, 60, 7,
    -1850, 1120, 340, 150, 96, 8,
];
// rolling hills behind the arms (paler, taller domes): s, lateral, half
// length, half width, height, seed
export const SCHOOL_HILLS: StaticArray<f64> = [
    -2250, -1250, 420, 260, 120, 11,
    -1650, -1500, 460, 280, 150, 12,
    -2450, 1330, 440, 260, 130, 13,
    -1800, 1600, 480, 300, 160, 14,
];

function schoolCoast(cb: CB): void {
    for (let i = 0; i < SCHOOL_COAST.length; i += 6) {
        let s = SCHOOL_COAST[i], x = SCHOOL_COAST[i + 1];
        lat(s, x);
        let cx = LAT_X, cz = LAT_Z;
        let rx = SCHOOL_COAST[i + 2], rz = SCHOOL_COAST[i + 3], h = SCHOOL_COAST[i + 4], k = SCHOOL_COAST[i + 5];
        let sp = new cliffs.HeadSpec();
        sp.x = cx;
        sp.z = cz;
        sp.yaw = yawAlong(s) + (mathx.hash(k, 5.3) - 0.5) * 0.3;
        sp.rx = rx;
        sp.rz = rz;
        sp.h = h;
        sp.seed = 34000 + k;
        sp.look = cliffs.COAST;
        sp.front = x < 0 ? 1 : -1;
        sp.rise = h * 0.35;
        sp.tip = 0.55;
        sp.skew = (mathx.hash(k, 2.1) - 0.5) * 0.4;
        sp.dome = rz * 0.12;
        sp.hills = 6;
        sp.cols = 22;
        sp.rough = 0.28;
        sp.taper = 0.1;
        sp.lip = 0.03;
        sp.drape = 5;
        sp.crack = 0;
        sp.spurs = 0.2;
        sp.boulders = 0;
        sp.tufts = 0;
        sp.foam = false;
        sp.ink = 0.7;
        sp.collide = false;
        sp.rowH = h / 4;
        emit(cb, (b: Builder, _cols: Array<Collider>): void => {
            cliffs.headland(b, sp, null);
        });
    }
    for (let i = 0; i < SCHOOL_HILLS.length; i += 6) {
        lat(SCHOOL_HILLS[i], SCHOOL_HILLS[i + 1]);
        let cx = LAT_X, cz = LAT_Z;
        let rx = SCHOOL_HILLS[i + 2], rz = SCHOOL_HILLS[i + 3], h = SCHOOL_HILLS[i + 4], k = SCHOOL_HILLS[i + 5];
        let sp = new cliffs.HeadSpec();
        sp.x = cx;
        sp.z = cz;
        sp.yaw = yawAlong(SCHOOL_HILLS[i]) + (mathx.hash(k, 5.3) - 0.5) * 0.4;
        sp.rx = rx;
        sp.rz = rz;
        sp.h = h * 0.45;
        sp.seed = 34000 + k;
        sp.look = cliffs.COAST_FAR;
        sp.tip = 0.7;
        sp.dome = h * 0.55;
        sp.hills = 14;
        sp.cols = 16;
        sp.rough = 0.2;
        sp.taper = 0.3;
        sp.lip = 0.02;
        sp.drape = 10;
        sp.crack = 0;
        sp.spurs = 0;
        sp.boulders = 0;
        sp.tufts = 0;
        sp.foam = false;
        sp.ink = 0.45;
        sp.collide = false;
        sp.rowH = h / 3;
        emit(cb, (b: Builder, _cols: Array<Collider>): void => {
            cliffs.headland(b, sp, null);
        });
    }
}

function plan(w: World): void {
    sectionLighthouse(w);
    sectionArch(w);
    sectionLowPass(w);
    sectionCanyon(w);
    sectionClimb(w);
    farCoast(w);
    violetSections(w);
    farViolet(w);
    portalPiece(chunkAt(w, PORTAL_S - 1));
    eyePiece(chunkAt(w, lv.eye.s));
}

// Plans every chunk and bakes the ones around the start (cached: later
// calls share the same chunks). The returned list (1-based) is complete
// from the start (chunks[i] covers [(i-1) * CHUNK, i * CHUNK)); chunks become
// `ready` as they are baked.
export function build(): Array<Chunk> {
    let cached = cache;
    if (cached != null) return cached;
    let t0 = clock();
    t0Build = t0;
    stats = new Stats();
    let n = <i32>Math.ceil(LEN / CHUNK);
    let kPortal = <i32>Math.floor(PORTAL_S / CHUNK) + 1;
    // the horizon range: one chunk drawn over the whole coast, cut at the
    // crossing; farAt never picks it (empty content range)
    let range = newCB("farRange", -800, PORTAL_S, -HUGE, PORTAL_S, true);
    range.cs0 = HUGE;
    range.cs1 = HUGE;
    let w = new World(range);
    w.kPortal = kPortal;
    w.far.push(range);
    for (let k = 1; k <= n; k++) {
        let gs0 = <f64>(k - 1) * CHUNK, gs1 = lmin(<f64>k * CHUNK, LEN);
        let vis0 = gs0 - DRAW_AHEAD, vis1 = gs1 + DRAW_BEHIND;
        if (k == kPortal) {
            vis1 = PORTAL_S + 60; // coast content: gone once through the portal
        } else if (k > kPortal) {
            vis0 = lmax(vis0, PORTAL_S); // violet appears the moment you cross
        }
        w.grid.push(newCB((k <= kPortal ? "c" : "v") + k.toString(), gs0, gs1, vis0, vis1, k <= kPortal));
    }
    w.grid[1].cs0 = -HUGE;
    w.grid[n].cs1 = HUGE;
    w.grid[kPortal].cs1 = PORTAL_S;
    if (kPortal < n) w.grid[kPortal + 1].cs0 = PORTAL_S;
    // distant coast layers: a few long chunks with wide windows
    const farBreaks: StaticArray<f64> = [-Infinity, 1400, 2900, Infinity];
    for (let i = 0; i < farBreaks.length - 1; i++) {
        let a = farBreaks[i], b = farBreaks[i + 1];
        let ga = a == -HUGE ? -800 : a;
        let gb = b == HUGE ? PORTAL_S + 300 : b;
        let cb = newCB("farCoast" + (i + 1).toString(), ga, gb, a == -HUGE ? -HUGE : ga - 2400, lmin(gb + 500, PORTAL_S + 60), true);
        cb.cs0 = a;
        cb.cs1 = b;
        w.far.push(cb);
    }
    let farVBreaks: StaticArray<f64> = [PORTAL_S, 6700, 7900, Infinity];
    for (let i = 0; i < farVBreaks.length - 1; i++) {
        let a = farVBreaks[i], b = farVBreaks[i + 1];
        let gb = b == HUGE ? LEN + 600 : b;
        let cb = newCB("farViolet" + (i + 1).toString(), a, gb, lmax(PORTAL_S, a - 2400), b == HUGE ? HUGE : gb + 500, false);
        cb.cs0 = a;
        cb.cs1 = b;
        w.farV.push(cb);
    }
    // the flight school lane (farAt never picks it: empty content range)
    let school = newCB("school", lv.school.s - 100, SCHOOL_VIS1, SCHOOL_VIS0, SCHOOL_VIS1, true);
    school.cs0 = HUGE;
    school.cs1 = HUGE;

    plan(w);
    schoolLane(school);
    schoolCoast(school);
    for (let i = 1; i < w.grid.length; i++) {
        let cb = w.grid[i];
        cb.near = railBox(cb.gs0 - 60, cb.gs1 + 220, 70);
    }
    stats.planMs = Math.floor((clock() - t0) * 1000);

    for (let i = 1; i < w.grid.length; i++) w.grid[i].chunk.grid = true;
    for (let i = 1; i < w.far.length; i++) w.far[i].chunk.far = true;
    for (let i = 1; i < w.farV.length; i++) w.farV[i].chunk.far = true;
    let out = new Array<Chunk>(1);
    cbs = new Array<CB>(1);
    cells.clear();
    colOf = new Array<Collider>(1);
    keyOf = [0];
    markOf = [0];
    let sl = new Array<CB>(1);
    sl.push(school);
    let lists: Array<Array<CB>> = [w.grid, w.far, w.farV, sl];
    for (let li = 0; li < lists.length; li++) {
        let list = lists[li];
        for (let i = 1; i < list.length; i++) {
            out.push(list[i].chunk);
            cbs.push(list[i]);
        }
    }
    pending = cbs.length - 1;
    cache = out;
    if (knobs.DEBUG) {
        for (let i = 1; i < cbs.length; i++) ensure(cbs[i]);
    } else if (knobs.START_SYNC) {
        // the start (title attract, launch): the near chunks right away
        for (let i = 1; i < cbs.length; i++) {
            let cb = cbs[i];
            if (cb.coast && cb.gs0 < knobs.URGENT_AHEAD && cb.gs1 > -200 && !isFar(cb.name)) ensure(cb);
        }
    }
    stats.initMs = Math.floor((clock() - t0) * 1000);
    console.log(format("scenery: planned %d chunks in %d ms, first chunks in %d ms", [N(<f64>(cbs.length - 1)), N(stats.planMs), N(stats.initMs)]));
    return out;
}

// True when a chunk should be drawn with the player at rail distance s
// (same test game.luau uses: s1 > s - 150 and s0 < s + 1700). A chunk that
// is not baked yet is baked on the spot when its content is close ahead.
export function isVisible(c: Chunk, s: f64): bool {
    if (Math.abs(s - lastVisS) > JUMP_M && queries > JUMP_QUERIES) syncAt(s);
    lastVisS = s;
    queries = 0;
    if (!(c.s1 > s - DRAW_BEHIND && c.s0 < s + DRAW_AHEAD)) return false;
    // quality: a shorter draw distance for the grid, and no distant layer
    // still fully faded into the sky
    let q = quality;
    if (q.ahead < DRAW_AHEAD && c.grid && c.gs0 - s > q.ahead) return false;
    if (q.farCull && c.far && c.gs0 - s >= DRAW_AHEAD) return false;
    if (!c.ready) {
        if (c.gs0 < s + knobs.URGENT_AHEAD && c.gs1 > s - DRAW_BEHIND && !isFar(c.name) && viewSpent * 1000 < VIEW_BAKE_MS) {
            for (let i = 1; i < cbs.length; i++) {
                let cb = cbs[i];
                if (cb.chunk == c) {
                    let t0 = clock();
                    ensure(cb, "in view");
                    viewSpent += clock() - t0;
                    break;
                }
            }
        }
        return c.ready;
    }
    return true;
}

// Fade chunks in as they enter the draw window (and when they were baked
// late), blending toward the sky's horizon colour (see the Luau original):
// writes the batch's instance extra (flash share, ink scale, fog).
const FADE_M: f64 = 260;
const FADE_S: f64 = 0.9;
const FLASH: StaticArray<f64> = [0, 1.6, 1.5, 1.4]; // toon.wgsl hit-flash colour (1-based)
const SKY_TINT: StaticArray<f64> = [0, 1.05, 1.0, 1.08];

// sky.wgsl horizonColor() for a palette, and the flash share k whose blend
// with its fogColor matches it best (least squares over rgb).
function skyMix(pal: palette.Palette): f64 {
    let F = pal.fogColor, Sk = pal.skyHorizon;
    let T: Array<f64> = [0.0, 0, 0, 0];
    for (let i = 1; i <= 3; i++) {
        if (pal.biome < 0.5) {
            T[i] = Sk[i] + (1 - Sk[i]) * 0.28;
        } else {
            T[i] = (Sk[i] + (F[i] - Sk[i]) * 0.35) * SKY_TINT[i];
        }
    }
    let num = 0.0, den = 0.0;
    for (let i = 1; i <= 3; i++) {
        let d = FLASH[i] - F[i];
        num += (T[i] - F[i]) * d;
        den += d * d;
    }
    // 0.85: the sky just above the horizon sits a touch darker than horizonColor
    return lclamp(num / den * 0.85, 0, 0.6);
}
const SKY_K_COAST: f64 = skyMix(palette.coast);
const SKY_K_VIOLET: f64 = skyMix(palette.violet);

export function fades(s: f64): void {
    if (cache == null) return;
    let now = gameT;
    for (let i = 1; i < cbs.length; i++) {
        let cb = cbs[i];
        let c = cb.chunk;
        if (c.ready && c.s1 > s - DRAW_BEHIND && c.s0 < s + DRAW_AHEAD) {
            // content entering at the far edge of the draw window
            let ahead = c.grid ? quality.ahead : DRAW_AHEAD;
            let u = mathx.saturate((c.gs0 - s - (ahead - FADE_M)) / FADE_M);
            if (now < c.readyT) c.readyT = -HUGE; // the clock restarted (new run)
            u = lmax(u, 1 - mathx.saturate((now - c.readyT) / FADE_S));
            let k = cb.coast ? SKY_K_COAST : SKY_K_VIOLET;
            let e = (1 - k) * u;
            let df = c.batch.df;
            df[19] = <f32>(k * u / lmax(1 - e, 1e-3));
            df[22] = <f32>(1 - u);
            df[23] = <f32>e;
        }
    }
}

// Collision query: deepest contact of a sphere against the scenery near it.
// Returns hit; HIT_NX / HIT_NY / HIT_NZ (push-out normal), HIT_D (depth).
export let HIT_NX: f64 = 0;
export let HIT_NY: f64 = 0;
export let HIT_NZ: f64 = 0;
export let HIT_D: f64 = 0;

export function collide(chunks: Array<Chunk>, x: f64, y: f64, z: f64, radius: f64): bool {
    queries += 1;
    if (pending > 0) {
        // colliders exist once a chunk is baked: bake the ones around the
        // query now (normally the background bake got there first)
        for (let i = 1; i < cbs.length; i++) {
            let cb = cbs[i];
            let nb = cb.near;
            if (nb != null && !cb.chunk.ready && x >= nb.minx && x <= nb.maxx && z >= nb.minz && z <= nb.maxz && y >= nb.miny && y <= nb.maxy) {
                ensure(cb, "contact");
            }
        }
    }
    // deepest contact; ties go to the lowest (chunk, collider) key, the
    // first one the linear scan met
    let best = 0.0, bx = 0.0, by = 0.0, bz = 0.0;
    let bkey: i32 = i32.MAX_VALUE;
    let first = 1;
    let n = cbs.length - 1;
    if (chunks == cache && n > 0 && chunks.length > n && chunks[n] == cbs[n].chunk && Math.abs(x) < 1e7 && Math.abs(z) < 1e7 && radius < 1e4) {
        // the scenery's own chunks (the first n of the list) through the
        // grid; anything appended after them by the scan below
        stamp += 1;
        let st = stamp;
        let izA = Math.floor((z - radius) * CELL_INV), izB = Math.floor((z + radius) * CELL_INV);
        for (let ix = Math.floor((x - radius) * CELL_INV); ix <= Math.floor((x + radius) * CELL_INV); ix++) {
            for (let iz = izA; iz <= izB; iz++) {
                let k = cellKey(ix, iz);
                if (cells.has(k)) {
                    let l = cells.get(k);
                    for (let li = 0; li < l.length; li++) {
                        let id = l[li];
                        if (markOf[id] != st) {
                            markOf[id] = st;
                            coll.test(colOf[id], x, y, z, radius);
                            let d = coll.T_D;
                            let key = keyOf[id];
                            if (d > best || (d == best && d > 0 && key < bkey)) {
                                best = d;
                                bx = coll.T_NX;
                                by = coll.T_NY;
                                bz = coll.T_NZ;
                                bkey = key;
                            }
                        }
                    }
                }
            }
        }
        first = n + 1;
    }
    for (let i = first; i < chunks.length; i++) {
        let c = chunks[i];
        let bb = c.bounds;
        if (x + radius >= bb.minx && x - radius <= bb.maxx && z + radius >= bb.minz && z - radius <= bb.maxz && y - radius <= bb.maxy && y + radius >= bb.miny) {
            let cl = c.colliders;
            for (let j = 1; j < cl.length; j++) {
                coll.test(cl[j], x, y, z, radius);
                let d = coll.T_D;
                let key = i * 65536 + j;
                if (d > best || (d == best && d > 0 && key < bkey)) {
                    best = d;
                    bx = coll.T_NX;
                    by = coll.T_NY;
                    bz = coll.T_NZ;
                    bkey = key;
                }
            }
        }
    }
    HIT_NX = bx;
    HIT_NY = by;
    HIT_NZ = bz;
    HIT_D = best;
    return best > 0;
}

// Near list (EFFICIENCY_REVIEW 1.1, JOB 19): the broad phase's cells under
// an xz box, gathered once for a burst of probes that lie in it.
// `nearCollide(nl, x, y, z, radius)` returns exactly what
// `collide(nl.chunks, x, y, z, radius)` returns, with the same effects (see
// the Luau original).
export class Near {
    chunks: Array<Chunk> = new Array<Chunk>(1);
    minx: f64 = 0;
    minz: f64 = 0;
    maxx: f64 = -1;
    maxz: f64 = -1;
    ok: bool = false; // the box's cells are in `cell` (else every probe takes collide)
    pend: i32 = -1; // `pending` at the fill
    ix0: f64 = 0;
    iz0: f64 = 0;
    nz: i32 = 0;
    n: i32 = 0;
    cols: Array<Collider> = new Array<Collider>(1); // local index -> collider (1-based)
    keys: Array<i32> = [0]; // local index -> collider key (the tie-break)
    cell: Array<Array<i32>> = [[]]; // box cell -> local indices (1-based)
    mark: Array<i32> = [0]; // local index -> last probe that tested it
    st: i32 = 0;
    idx: Map<i32, i32> = new Map<i32, i32>(); // (fill scratch: dense id -> local index)
    cand: Array<CB> = []; // pending chunks whose `near` box meets the box (cbs order, 0-based)
}
const NEAR_CELLS: f64 = 4096; // a box over this many cells is not gathered

export function newNear(): Near {
    return new Near();
}

function nearFill(nl: Near): void {
    let chunks = nl.chunks;
    let minx = nl.minx, minz = nl.minz, maxx = nl.maxx, maxz = nl.maxz;
    let n = cbs.length - 1;
    nl.pend = pending;
    nl.n = 0;
    nl.cand.length = 0;
    let ix0 = Math.floor(minx * CELL_INV), ix1 = Math.floor(maxx * CELL_INV);
    let iz0 = Math.floor(minz * CELL_INV), iz1 = Math.floor(maxz * CELL_INV);
    let ok = chunks == cache && n > 0 && chunks.length > n && chunks[n] == cbs[n].chunk && minx <= maxx && minz <= maxz && minx > -1e7 && maxx < 1e7 && minz > -1e7 && maxz < 1e7 && (ix1 - ix0 + 1) * (iz1 - iz0 + 1) <= NEAR_CELLS;
    nl.ok = ok;
    if (!ok) return;
    if (pending > 0) {
        for (let i = 1; i < cbs.length; i++) {
            let cb = cbs[i];
            let nb = cb.near;
            if (nb != null && !cb.chunk.ready && nb.maxx >= minx && nb.minx <= maxx && nb.maxz >= minz && nb.minz <= maxz) nl.cand.push(cb);
        }
    }
    nl.ix0 = ix0;
    nl.iz0 = iz0;
    nl.nz = <i32>(iz1 - iz0 + 1);
    let idx = nl.idx, cols = nl.cols, keys = nl.keys, cell = nl.cell, mark = nl.mark;
    idx.clear();
    let nc = 0, ci = 0;
    for (let ix = ix0; ix <= ix1; ix++) {
        for (let iz = iz0; iz <= iz1; iz++) {
            ci += 1;
            let lc: Array<i32>;
            if (ci >= cell.length) {
                lc = [];
                cell.push(lc);
            } else {
                lc = cell[ci];
                lc.length = 0;
            }
            let k = cellKey(ix, iz);
            if (cells.has(k)) {
                let l = cells.get(k);
                for (let j = 0; j < l.length; j++) {
                    let id = l[j];
                    let li: i32;
                    if (idx.has(id)) {
                        li = idx.get(id);
                    } else {
                        nc += 1;
                        li = nc;
                        idx.set(id, nc);
                        if (nc >= cols.length) {
                            cols.push(colOf[id]);
                            keys.push(keyOf[id]);
                            mark.push(0);
                        } else {
                            cols[nc] = colOf[id];
                            keys[nc] = keyOf[id];
                        }
                    }
                    lc.push(li);
                }
            }
        }
    }
    nl.n = nc;
}

// Fill `out` for probes of `chunks` (the list collide would be given)
// inside the xz box minx..maxx, minz..maxz (a probe's whole square).
export function near(out: Near, chunks: Array<Chunk>, minx: f64, minz: f64, maxx: f64, maxz: f64): void {
    out.chunks = chunks;
    out.minx = minx;
    out.minz = minz;
    out.maxx = maxx;
    out.maxz = maxz;
    nearFill(out);
}

// collide(nl.chunks, x, y, z, radius) through the near list (see near).
export function nearCollide(nl: Near, x: f64, y: f64, z: f64, radius: f64): bool {
    let chunks = nl.chunks;
    let n = cbs.length - 1;
    if (!(nl.ok && radius >= 0 && radius < 1e4 && x - radius >= nl.minx && x + radius <= nl.maxx && z - radius >= nl.minz && z + radius <= nl.maxz && chunks == cache && n > 0 && chunks.length > n && chunks[n] == cbs[n].chunk)) {
        return collide(chunks, x, y, z, radius);
    }
    queries += 1;
    if (pending > 0) {
        // (collide's on-the-spot bake: every pending chunk whose `near` box
        // holds this point meets the box, so it is in `cand`, in cbs order)
        for (let i = 0; i < nl.cand.length; i++) {
            let cb = nl.cand[i];
            let nb = cb.near!;
            if (!cb.chunk.ready && x >= nb.minx && x <= nb.maxx && z >= nb.minz && z <= nb.maxz && y >= nb.miny && y <= nb.maxy) ensure(cb, "contact");
        }
    }
    // a chunk was uploaded since the fill: its colliders are in the grid
    if (pending != nl.pend) nearFill(nl);
    let best = 0.0, bx = 0.0, by = 0.0, bz = 0.0;
    let bkey: i32 = i32.MAX_VALUE;
    let st = nl.st + 1;
    nl.st = st;
    let mark = nl.mark, cols = nl.cols, keys = nl.keys, cell = nl.cell;
    let ix0 = nl.ix0, iz0 = nl.iz0, nz = nl.nz;
    let izA = Math.floor((z - radius) * CELL_INV), izB = Math.floor((z + radius) * CELL_INV);
    for (let ix = Math.floor((x - radius) * CELL_INV); ix <= Math.floor((x + radius) * CELL_INV); ix++) {
        let base = <i32>((ix - ix0) * <f64>nz - iz0) + 1;
        for (let iz = izA; iz <= izB; iz++) {
            let lc = cell[base + <i32>iz];
            for (let j = 0; j < lc.length; j++) {
                let li = lc[j];
                if (mark[li] != st) {
                    mark[li] = st;
                    coll.test(cols[li], x, y, z, radius);
                    let d = coll.T_D;
                    let key = keys[li];
                    if (d > best || (d == best && d > 0 && key < bkey)) {
                        best = d;
                        bx = coll.T_NX;
                        by = coll.T_NY;
                        bz = coll.T_NZ;
                        bkey = key;
                    }
                }
            }
        }
    }
    // appended chunks: collide's scan
    for (let i = n + 1; i < chunks.length; i++) {
        let c = chunks[i];
        let bb = c.bounds;
        if (x + radius >= bb.minx && x - radius <= bb.maxx && z + radius >= bb.minz && z - radius <= bb.maxz && y - radius <= bb.maxy && y + radius >= bb.miny) {
            let cl = c.colliders;
            for (let j = 1; j < cl.length; j++) {
                coll.test(cl[j], x, y, z, radius);
                let d = coll.T_D;
                let key = i * 65536 + j;
                if (d > best || (d == best && d > 0 && key < bkey)) {
                    best = d;
                    bx = coll.T_NX;
                    by = coll.T_NY;
                    bz = coll.T_NZ;
                    bkey = key;
                }
            }
        }
    }
    HIT_NX = bx;
    HIT_NY = by;
    HIT_NZ = bz;
    HIT_D = best;
    return best > 0;
}

// The quality tier (see QUALITY): `level` is low / medium / high.
export function setQuality(level: string): void {
    let q: Quality;
    if (level == "high") {
        q = QUALITY.high;
    } else if (level == "medium") {
        q = QUALITY.medium;
    } else if (level == "low") {
        q = QUALITY.low;
    } else {
        return;
    }
    quality = q;
    qualityLevel = level;
    life.setDensity(q.life);
    ambient.setDensity(q.mist);
    for (let i = 1; i < cbs.length; i++) {
        let c = cbs[i].chunk;
        if (c.far && c.ready) c.batch.reflect = q.farRefl;
    }
}

// The bake's share of drawDynamic (the pace, the top-up pump, the fades).
export function drawDynamicBake(t: f64, s: f64): void {
    gameT = t;
    let now = clock();
    if (lastDraw > 0) {
        // the bake's pace (see BUDGET_MS)
        if (now - lastDraw > PACE_LATE) {
            paceC = lmax(knobs.BUDGET_SLOW_MS, paceB * 0.8);
            paceB = lmax(knobs.BUDGET_SLOW_MS, paceB * 0.5);
        } else {
            paceC = lmin(paceC + PACE_CREEP, knobs.BUDGET_MENU_MS);
            paceB = lmin(paceB + PACE_UP, paceC);
        }
    }
    lastDraw = now;
    // tops up the frame's shared budget (game.advance usually pumped first)
    pump(s);
    frameSpent = 0;
    viewSpent = 0;
    fades(s);
}

const NOHUD: bool = false; // capture aid (the visor off): never true in the shipped file

// Animated ambient life (gull flocks, debris orbiting the portals). Call once
// per frame from draw(), next to the chunk loop.
export function drawDynamic(r: R.Gfx, t: f64, s: f64): void {
    drawDynamicBake(t, s);
    let gb = life.update(t, s);
    R.addBatch(r, gb);
    R.addBatch(r, life.UPDATE_DEBRIS!);
    ambient.update(r, t, s);
    if (NOHUD) r.visor.opacity = 0;
}
