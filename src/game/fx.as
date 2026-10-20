// Port of src/game/fx.luau: particle effects: toon fireballs, smoke,
// shockwaves, sparks, splashes, flames, muzzle flashes and tumbling debris
// chunks. The core loop calls create/explosion/sparks/spray/update/draw; keep
// those signatures (additive changes only).
//
// Particles are pooled objects (no per-spawn garbage in steady state). A
// particle with negative age is delayed: invisible and frozen until age >= 0.
// Colors lerp from (r,g,b) to (r2,g2,b2) over the particle's life.
//
// Kills are printed in the ROCKET SQUADRON palette (DIRECTION #21): a white-hot
// flash that burns to brass gold and crimson toon puffs with cream highlights,
// cobalt-ink smoke (never grey), confetti flakes in the four brand inks, and a
// cream ring chased by a misregistered crimson one. Fire puffs cap the age the
// particle shader sees (`cap`), so its warm ramp stops at the brand colour
// instead of burning on to sooty grey.
//
// Port notes: Luau sequences stay 1-based (slot 0 a dummy), the tuple lists
// (spots, crowns, rings, bolts) too, each tuple 1-based. Optional numbers: NaN
// = nil. Multi-returns: stormLocal -> STORM_LOCAL_X / Y / Z. stormUpdate's
// railFrame(s) leaves its frame in track.FRAME_P / FRAME_F / FRAME_R (as
// track.frame). The storm meshes are built on first use (stormBuild; Luau
// builds them at require).
import { Mat4 } from "rive/mat4";
import * as R from "../render/renderer";
import * as gpu from "../lib/gpu";
import { Batch } from "../lib/gpu";
import * as models from "./models";
import { Xf } from "./models";
import * as meshgen from "../lib/meshgen";
import { Builder } from "../lib/meshgen";
import * as mathx from "../lib/mathx";
import * as geo from "../world/geo";
import { CloudSpec } from "../world/geo";
import * as track from "../world/track";
import { HUGE, lmin, lmax, lclamp, mod, opt, lrandom } from "../lib/compat";

export class Particle {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    size: f64 = 1;
    grow: f64 = 0;
    gdrag: f64 = 0;
    r: f64 = 1;
    g: f64 = 1;
    b: f64 = 1;
    a: f64 = 1;
    r2: f64 = 1;
    g2: f64 = 1;
    b2: f64 = 1;
    kind: f64 = 0;
    life: f64 = 1;
    age: f64 = 0;
    seed: f64 = 0;
    rot: f64 = 0;
    spin: f64 = 0;
    drag: f64 = 0;
    gravity: f64 = 0;
    stretch: f64 = 0;
    cap: f64 = 1; // max age the shader sees (0.3: a warm puff stays fire-coloured; 1 = off)
    // velocity carried off a moving source (carry), bled away at CARRY_DRAG
    cvx: f64 = 0;
    cvy: f64 = 0;
    cvz: f64 = 0;
}

export class Debris {
    x: f64 = 0;
    y: f64 = 0;
    z: f64 = 0;
    vx: f64 = 0;
    vy: f64 = 0;
    vz: f64 = 0;
    a: f64 = 0;
    b: f64 = 0;
    sa: f64 = 0;
    sb: f64 = 0;
    sx: f64 = 0;
    sy: f64 = 0;
    sz: f64 = 0;
    tr: f64 = 0;
    tg: f64 = 0;
    tb: f64 = 0;
    life: f64 = 0;
    age: f64 = 0;
    smokeT: f64 = 0;
    fire: bool = false;
    flat: bool = false; // confetti flake: flutters (drag, light gravity), no smoke trail, no splash
}

// The Stormcrow's storm (storm*, below).
export class Storm {
    on: bool = false;
    t: f64 = 0; // seconds since it brewed
    s0: f64 = 0; // the boss cue (rail s)
    smax: f64 = HUGE; // its anchor never stands past this rail s
    ds: f64 = 0; // drift down the valley since released (m of rail)
    x: f64 = 0; // lateral (m right of the rail)
    drift: f64 = 0; // m/s down the valley (0 until released)
    breakT: f64 = -1; // < 0 whole; else seconds since it began to fade
    shelfT: f64 = -1; // < 0 whole; else seconds since the shelf began to collapse
    flash: f64 = 0; // lightning wash on the cloud (0..1)
    big: f64 = 0; // the last big strike's wash (0..1, frame kick)
    nextT: f64 = 0; // next ambient flicker (Storm.t)
    seed: f64 = 1; // own LCG state
    // age, seed, top x / y / z (local), end x / z, width, crawler (1) / strike (0) (1-based, each 1-based)
    bolts: Array<Array<f64>> = [[0.0]];
    xf: Xf = models.xf(); // the cell's frame
    xs: Xf = models.xf(); // the shelf's frame (sinks as it collapses)
    shelfK: f64 = 1; // the shelf's height scale (slumps as it collapses)
    vis: f64 = 0; // 1 whole .. 0 gone (sky fade)
    shelfVis: f64 = 0;
    sweep: f64 = 0; // its shadow rolling up the slot over the pilot (0 .. 1, stormSweep)
}

export class Fx {
    parts: Array<Particle> = new Array<Particle>(1); // 1-based
    free: Array<Particle> = new Array<Particle>(1); // 1-based
    debris: Array<Debris> = new Array<Debris>(1); // 1-based
    debrisBatch: Batch? = null;
    xf: Xf = models.xf();
    budget: f64 = MAX_PARTS;
    // graphics quality (setQuality): share of puffs, foam and sparks kept
    density: f64 = 1;
    thin: f64 = 0;
    // camera eye of the last drawn frame (size clamp near the lens)
    camX: f64 = 0;
    camY: f64 = 0;
    camZ: f64 = 0;
    camSet: bool = false; // camX..Z were set this frame by the enemies draw (else r.camEye)
    // kill cam on a falling boss: the near side of the framed boss (m from
    // the lens); fire, smoke and chunks nearer the lens thin out (0 = off;
    // set every frame by the enemies draw)
    shotNear: f64 = 0;
    // velocity the next emits carry (carry; 0 = at rest in the world)
    cvx: f64 = 0;
    cvy: f64 = 0;
    cvz: f64 = 0;
    // seconds the next emits wait before they show (delay; 0 = now)
    delay: f64 = 0;
    // painted foam on the water under fresh splashes (R.foam): x, z, radius, age, life
    spots: Array<Array<f64>> = [[0.0]];
    // a splash this tick (radius 0 = none): burst spray under it is part of it
    splX: f64 = 0;
    splZ: f64 = 0;
    splR: f64 = 0;
    // splash crowns (toon meshes): x, z, scale, age, life, yaw, jet (1 / 0)
    crowns: Array<Array<f64>> = [[0.0]];
    crownBatch: Batch? = null;
    jetBatch: Batch? = null;
    // foam shockwave rings on the sea (flat foam lace mesh): x, z, scale, age, life
    rings: Array<Array<f64>> = [[0.0]];
    ringBatch: Batch? = null;
    // the storm the Stormcrow rises out of (storm*)
    storm: Storm = new Storm();
}

const MAX_PARTS: f64 = 2900;
const MAX_DEBRIS: i32 = 150;

export function create(): Fx {
    return new Fx();
}

// A private stream for set-piece weather (quiet): its emits leave
// math.random alone, so the seeded gameplay runs stay as they were.
let QUIET: bool = false;
let quietSeed: f64 = 1;
function quietRand(): f64 {
    quietSeed = mod(quietSeed * 16807, 2147483647);
    return (quietSeed - 1) / 2147483646;
}
export function quiet(on: bool): void {
    QUIET = on;
}
@inline function rand(): f64 {
    return QUIET ? quietRand() : lrandom();
}

// Takes a particle from the pool (or null when over budget). Caller fills every field it cares about.
function take(F: Fx): Particle? {
    if (<f64>(F.parts.length - 1) >= F.budget) return null;
    let free = F.free;
    let n = free.length - 1;
    let p: Particle;
    if (n > 0) {
        p = free[n];
        free.pop();
    } else {
        p = new Particle();
    }
    F.parts.push(p);
    return p;
}

// Generic emitter used by every recipe below. cap: NaN = nil (1).
export function emit(
    F: Fx, kind: f64,
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    size: f64, grow: f64, gdrag: f64,
    r: f64, g: f64, b: f64, a: f64,
    r2: f64, g2: f64, b2: f64,
    life: f64, delay: f64, drag: f64, gravity: f64, stretch: f64, cap: f64 = NaN
): void {
    // low / medium quality thin puffs, foam and sparks (flashes, rings and
    // glows stay); the skipped one still takes its random draws, so gameplay
    // randomness does not depend on the tier
    if (F.density < 1 && (kind == 0 || kind == 5 || stretch > 0)) {
        F.thin += 1 - F.density;
        if (F.thin >= 1) {
            F.thin -= 1;
            rand();
            rand();
            rand();
            return;
        }
    }
    let p = take(F);
    if (p == null) return;
    p.x = x;
    p.y = y;
    p.z = z;
    p.vx = vx;
    p.vy = vy;
    p.vz = vz;
    p.size = size;
    p.grow = grow;
    p.gdrag = gdrag;
    p.r = r;
    p.g = g;
    p.b = b;
    p.a = a;
    p.r2 = r2;
    p.g2 = g2;
    p.b2 = b2;
    p.kind = kind;
    p.life = lmax(life, 0.01);
    p.age = -delay - F.delay;
    p.seed = rand();
    p.rot = rand() * 6.283;
    p.spin = (rand() - 0.5) * 2;
    p.drag = drag;
    p.gravity = gravity;
    p.stretch = stretch;
    p.cap = opt(cap, 1);
    p.cvx = F.cvx;
    p.cvy = F.cvy;
    p.cvz = F.cvz;
}

// sphereDir outputs
let SD_X: f64 = 0;
let SD_Y: f64 = 0;
let SD_Z: f64 = 0;
function sphereDir(): void {
    let z = rand() * 2 - 1;
    let a = rand() * 6.2831853;
    let r = Math.sqrt(1 - z * z);
    SD_X = r * Math.cos(a);
    SD_Y = z;
    SD_Z = r * Math.sin(a);
}

// Tumbling mesh chunk with gravity; smokes, burns, splashes into the sea.
// `flat` makes it a confetti flake: thin, flutters down, no trail, no splash.
export function debris(F: Fx, x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, size: f64, tr: f64, tg: f64, tb: f64, fire: bool, flat: bool = false): void {
    if (F.debris.length - 1 >= MAX_DEBRIS) return;
    let k = size * (0.6 + rand() * 0.8);
    let fl = flat;
    let spin = fl ? 26.0 : 16.0;
    // (draws in the Luau table constructor's order)
    let d = new Debris();
    d.x = x;
    d.y = y;
    d.z = z;
    d.vx = vx;
    d.vy = vy;
    d.vz = vz;
    d.a = rand() * 6.28;
    d.b = rand() * 6.28;
    d.sa = (rand() - 0.5) * spin;
    d.sb = (rand() - 0.5) * spin;
    d.sx = k * (0.7 + rand() * 0.8);
    d.sy = fl ? k * 0.12 : k * (0.5 + rand() * 0.6);
    d.sz = k * (0.7 + rand() * 0.9);
    d.tr = tr;
    d.tg = tg;
    d.tb = tb;
    d.life = fl ? 1.8 + rand() * 1.0 : 2.6 + rand() * 1.2;
    d.age = -F.delay;
    d.smokeT = rand() * 0.05;
    d.fire = fire && !fl;
    d.flat = fl;
    F.debris.push(d);
}

// Brand palette: crimson spot, brass gold, cream
// stock, cobalt ink. Crimson and gold read as "warm" to the particle shader
// (fire ramp: white-hot first); cream stays under its white test (no foam).
const CR_R: f64 = 0.86, CR_G: f64 = 0.14, CR_B: f64 = 0.38;
const GO_R: f64 = 0.97, GO_G: f64 = 0.74, GO_B: f64 = 0.2;
const CM_R: f64 = 0.97, CM_G: f64 = 0.9, CM_B: f64 = 0.76;
const INK_R: f64 = 0.34, INK_G: f64 = 0.4, INK_B: f64 = 0.8; // 60% cobalt screen
const INKL_R: f64 = 0.68, INKL_G: f64 = 0.72, INKL_B: f64 = 0.93; // 30% screen
// max shader age of a fire puff: its warm ramp ends at the brand colour
const FIRE_CAP: f64 = 0.3;

// Confetti inks, cycled.
const FLAKES: Array<Array<f64>> = [[0.0],
    [0.0, CR_R, CR_G, CR_B], [0.0, GO_R, GO_G, GO_B], [0.0, CM_R, CM_G, CM_B], [0.0, 0.2, 0.28, 0.78],
];

// Recipes ----------------------------------------------------------------------

// White-gold flash + a cream shockwave chased by a misregistered crimson one
// (the menus' second print plate).
function flashRing(F: Fx, x: f64, y: f64, z: f64, s: f64, warm: bool): void {
    emit(F, 1, x, y, z, 0, 0, 0, 3.2 * s, 7 * s, 9, 1, 0.92, 0.7, 1, 1, 0.6, 0.3, 0.2, 0, 0, 0, 0);
    let rr = CM_R, rg = CM_G, rb = CM_B;
    if (!warm) {
        rr = 0.85;
        rg = 0.95;
        rb = 1;
    }
    emit(F, 2, x, y, z, 0, 0, 0, 1.2 * s, 26 * s, 6, rr, rg, rb, 0.95, rr, rg, rb, 0.42, 0.02, 0, 0, 0);
    if (warm && s > 0.35) {
        emit(F, 2, x + 0.2 * s, y - 0.14 * s, z, 0, 0, 0, 1.0 * s, 30 * s, 6, CR_R, CR_G, CR_B, 0.9, CR_R, CR_G, CR_B, 0.5, 0.07, 0, 0, 0);
    }
}

// Toon fireball: gold puffs in the heart, crimson thrown wider, a few cream
// highlights; each flashes white-hot, then holds its colour (capped age).
function fireball(F: Fx, x: f64, y: f64, z: f64, s: f64, n: f64): void {
    for (let i = 1.0; i <= n; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let pick = rand();
        let cr = GO_R, cg = GO_G, cb = GO_B, sp = (2.5 + rand() * 4) * s;
        if (pick > 0.86) {
            cr = CM_R;
            cg = CM_G;
            cb = CM_B;
            sp = (3 + rand() * 5) * s;
        } else if (pick > 0.42) {
            cr = CR_R;
            cg = CR_G;
            cb = CR_B;
            sp = (5 + rand() * 6) * s;
        }
        emit(F, 0,
            x + dx * 0.5 * s, y + dy * 0.5 * s, z + dz * 0.5 * s,
            dx * sp, dy * sp + 1.5 * s, dz * sp,
            (0.9 + rand() * 0.9) * s, (5 + rand() * 3) * s, 4.5,
            cr, cg, cb, 1, cr, cg, cb,
            0.5 + rand() * 0.35, rand() * 0.06, 3.2, -2, 0, FIRE_CAP);
    }
    // hot cores: gold, white-hot the longest
    let nh = lmax(2, Math.floor(n / 4));
    for (let i = 1.0; i <= nh; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        emit(F, 0, x + dx * 0.3 * s, y + dy * 0.3 * s, z + dz * 0.3 * s, dx * 2 * s, dy * 2 * s, dz * 2 * s,
            (0.8 + rand() * 0.5) * s, 4 * s, 5, 1, 0.84, 0.3, 1, 1, 0.84, 0.3, 0.3 + rand() * 0.1, 0, 2, 0, 0, 0.12);
    }
}

// Cobalt-ink smoke: dense ink that lifts to a lighter screen as it spreads
// (short-lived: the pilot reaches where a kill went off within a second or
// two, and a cloud still standing there walls off the view).
function smokeBurst(F: Fx, x: f64, y: f64, z: f64, s: f64, n: f64, delay: f64): void {
    for (let i = 1.0; i <= n; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = (1 + rand() * 3) * s;
        let m = rand() * 0.3;
        emit(F, 0,
            x + dx * 0.8 * s, y + dy * 0.6 * s, z + dz * 0.8 * s,
            dx * sp, Math.abs(dy) * sp + 2.5, dz * sp,
            (0.75 + rand() * 0.45) * s, 1.4 * s, 1.2,
            INK_R + m * 0.1, INK_G + m * 0.1, INK_B + m * 0.05, 1,
            INKL_R, INKL_G, INKL_B,
            0.75 + rand() * 0.4, delay + rand() * 0.25, 1.4, -1.5, 0);
    }
}

function sparkBurst(F: Fx, x: f64, y: f64, z: f64, s: f64, n: f64, r: f64, g: f64, b: f64): void {
    for (let i = 1.0; i <= n; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = (14 + rand() * 20) * s;
        emit(F, 1, x, y, z, dx * sp, dy * sp + 4, dz * sp,
            (0.16 + rand() * 0.12) * Math.sqrt(s), -0.1, 0,
            r, g, b, 1, r, g * 0.6, b * 0.4,
            0.35 + rand() * 0.35, 0, 2.2, 14, 1.4);
    }
}

// Confetti: flat flakes in the four brand inks that tumble and flutter down.
export function confetti(F: Fx, x: f64, y: f64, z: f64, s: f64, n: f64): void {
    let rs = Math.sqrt(s);
    let nf = FLAKES.length - 1;
    for (let i = 1; <f64>i <= n; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = (7 + rand() * 11) * rs;
        let c = FLAKES[(i % nf) + 1];
        debris(F, x, y, z, dx * sp, Math.abs(dy) * sp + 5, dz * sp, (0.3 + rand() * 0.2) * rs, c[1], c[2], c[3], false, true);
    }
}

// Hull chunks: dense cobalt-ink pieces; half of them trail brand fire.
function chunks(F: Fx, x: f64, y: f64, z: f64, s: f64, n: f64): void {
    for (let i = 1.0; i <= n; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = (8 + rand() * 12) * Math.sqrt(s);
        let m = rand() * 0.12;
        debris(F, x, y, z, dx * sp, Math.abs(dy) * sp + 6, dz * sp, 0.55 * s, 0.2 + m, 0.24 + m, 0.5 + m, rand() < 0.5);
    }
}

// Splash: a toon-mesh crown of water (models.splashBatches: cel bands, ink
// edges, sea aqua at the waterline, white at the crest) that bursts up, flares
// and sinks back, a jet that climbs out of its middle and falls back in,
// drops flung off the petal tips and the jet's head, a fan of spray streaks
// and churned foam painted on the water. No white puff stack, no billboard
// ring. Drops and spray are small white foam paint (the particle shader's
// near-white kind 0) stretched along their flight.
const SC_R: f64 = 0.9, SC_G: f64 = 0.97, SC_B: f64 = 1;
const MAX_SPOTS: i32 = 4;
const MAX_CROWNS: i32 = 32;
const JET_DELAY: f64 = 0.07;

// crown: height (m), life (s); jet: height (m), life (s)
function crownH(s: f64): f64 {
    return 1.7 * Math.pow(s, 0.8);
}
function crownLife(s: f64): f64 {
    return 0.9 + 0.15 * lmin(s, 2);
}
function jetH(s: f64): f64 {
    return 2.7 * Math.pow(s, 0.8);
}
function jetLife(s: f64): f64 {
    return 0.9 + 0.1 * lmin(s, 2);
}

// `breach`: something rising out of the sea throws it (no jet).
function splashAt(F: Fx, x: f64, z: f64, s: f64, breach: bool): void {
    let rs = Math.sqrt(s);
    let big = lmin(s, 2);
    let jet = s >= 0.45 && !breach;
    let L = crownLife(s), Lj = jetLife(s);
    let yaw = rand() * 6.283;
    let crowns = F.crowns;
    if (crowns.length - 1 >= MAX_CROWNS) crowns.splice(1, 1);
    crowns.push([0.0, x, z, s, -F.delay, jet ? lmax(L, JET_DELAY + Lj) : L, yaw, jet ? 1.0 : 0.0]);
    // drops flung off every other petal tip as the crown tops out
    let tipT = 0.28 * L;
    let tipR = s * (0.5 + 0.55 * (1 - Math.pow(1 - 0.28, 2))) * 1.45;
    let tipY = crownH(s) * 0.9;
    for (let k = 0.0; k <= 7; k += 2) {
        let a = yaw + (k + 0.5) / 8 * 6.283;
        let ca = Math.cos(a), sa = Math.sin(a);
        let out = (1.5 + rand() * 1.5) * s;
        emit(F, 0, x + ca * tipR, tipY, z + sa * tipR, ca * out, (2.5 + rand() * 2) * rs, sa * out,
            (0.1 + rand() * 0.04) * s, 0, 0,
            SC_R, SC_G, SC_B, 1, SC_R, SC_G, SC_B,
            0.5 + rand() * 0.2, tipT, 0.8, 18, 1.2);
    }
    if (s < 0.45) return;
    // the jet's head breaks into a few drops at its top
    let topT = JET_DELAY + 0.4 * Lj;
    let topY = jetH(s) * 0.96;
    let nTop = jet ? Math.floor(2 + big) : 0.0;
    for (let i = 1.0; i <= nTop; i++) {
        let a = rand() * 6.283;
        let out = (0.8 + rand() * 1.4) * s;
        emit(F, 0, x + Math.cos(a) * 0.15 * s, topY, z + Math.sin(a) * 0.15 * s, Math.cos(a) * out, (1.5 + rand() * 2.5) * rs, Math.sin(a) * out,
            (0.12 + rand() * 0.05) * s, 0, 0,
            SC_R, SC_G, SC_B, 1, SC_R, SC_G, SC_B,
            0.7 + rand() * 0.2, topT + rand() * 0.06, 0.6, 18, 1.2);
    }
    // spray: fine streaks fanning out low and fast
    let nSpray = Math.floor(5 + 3 * big);
    for (let i = 1.0; i <= nSpray; i++) {
        let a = rand() * 6.283;
        let out = (3.5 + rand() * 3.5) * s;
        emit(F, 0, x + Math.cos(a) * 0.5 * s, 0.3, z + Math.sin(a) * 0.5 * s, Math.cos(a) * out, (5 + rand() * 5) * rs, Math.sin(a) * out,
            (0.08 + rand() * 0.04) * s, 0, 0,
            SC_R, SC_G, SC_B, 1, SC_R, SC_G, SC_B,
            0.45 + rand() * 0.2, rand() * 0.05, 1, 20, 3);
    }
    // foam painted on the water, churning out from the impact
    let spots = F.spots;
    if (spots.length - 1 >= MAX_SPOTS) {
        // the spot closest to gone makes room
        let wi = 1, wk = HUGE;
        for (let i = 1; i < spots.length; i++) {
            let sp = spots[i];
            let k = sp[3] * (1 - sp[4] / sp[5]);
            if (k < wk) {
                wi = i;
                wk = k;
            }
        }
        spots.splice(wi, 1);
    }
    spots.push([0.0, x, z, 3 * s, -F.delay, 1.2 + 0.2 * big]);
    // the burst of skim spray the core throws in with a splash joins it
    F.splX = x;
    F.splZ = z;
    F.splR = 2 + 1.5 * s;
}

// (a splash stays on the water: its drops and spray never take carry)
export function splash(F: Fx, x: f64, z: f64, s: f64, breach: bool = false): void {
    let cx = F.cvx, cy = F.cvy, cz = F.cvz;
    F.cvx = 0;
    F.cvy = 0;
    F.cvz = 0;
    splashAt(F, x, z, s, breach);
    F.cvx = cx;
    F.cvy = cy;
    F.cvz = cz;
}

// Shockwave on the sea under a low blast: a flat band of foam lace lying on
// the water (the shoreline foam paint), racing outward and melting away.
const MAX_RINGS: i32 = 16;
const RING_LIFE: f64 = 0.95;

export function waterRing(F: Fx, x: f64, z: f64, s: f64): void {
    let rings = F.rings;
    if (rings.length - 1 >= MAX_RINGS) rings.splice(1, 1);
    rings.push([0.0, x, z, s, -F.delay, RING_LIFE]);
}

// Blasts close to the lens shrink (a kill at arm's length is a punchy pop,
// not a wall of fire): full size beyond NEAR_FULL meters, down to NEAR_MIN.
const NEAR_FULL: f64 = 26;
const NEAR_MIN: f64 = 0.4;

function nearScale(F: Fx, x: f64, y: f64, z: f64): f64 {
    let dx = x - F.camX, dy = y - F.camY, dz = z - F.camZ;
    let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
    return lclamp(d / NEAR_FULL, NEAR_MIN, 1);
}

// Explosion: kind 'small' | 'big' | 'huge' | 'boom' | 'water' | 'mine' | 'air' | 'pop'
export function explosion(F: Fx, x: f64, y: f64, z: f64, scale: f64, kind: string = "small"): void {
    let k = kind;
    let s = scale * nearScale(F, x, y, z);
    if (k == "water") {
        splash(F, x, z, s);
        return;
    }
    if (k == "air") {
        // flak burst: a cobalt-ink cotton puff with a crimson-gold heart (in
        // the lighter smoke ink: the old navy read as an opaque hole in the
        // sky when a burst went off near the lens)
        emit(F, 1, x, y, z, 0, 0, 0, 2.4 * s, 4 * s, 8, 1, 0.7, 0.3, 1, 1, 0.4, 0.1, 0.16, 0, 0, 0, 0);
        emit(F, 0, x, y, z, 0, 0, 0, 0.9 * s, 3 * s, 4, CR_R, CR_G, CR_B, 1, CR_R, CR_G, CR_B, 0.35, 0, 1, 0, 0, FIRE_CAP);
        for (let i = 1; i <= 5; i++) {
            sphereDir();
            let dx = SD_X, dy = SD_Y, dz = SD_Z;
            emit(F, 0, x + dx * 0.6 * s, y + dy * 0.6 * s, z + dz * 0.6 * s, dx * 3 * s, dy * 3 * s, dz * 3 * s,
                (0.8 + rand() * 0.4) * s, 1.8 * s, 2, INK_R, INK_G, INK_B, 1, INKL_R, INKL_G, INKL_B,
                0.8 + rand() * 0.4, rand() * 0.05, 2, -1, 0);
        }
        sparkBurst(F, x, y, z, s * 0.7, 6, 1, 0.75, 0.3);
        return;
    }
    if (k == "pop") {
        flashRing(F, x, y, z, s * 0.7, true);
        sparkBurst(F, x, y, z, s * 0.6, 8, 1, 0.8, 0.4);
        fireball(F, x, y, z, s * 0.6, 5);
        return;
    }
    // 'boom': a big fireball without the debris shower (chained boss blasts)
    let big = k == "big" || k == "huge" || k == "boom";
    let mult = k == "huge" ? 2.0 : (big ? 1.4 : 1.0);
    // tiny puffs (a crashing pilot's smoke, sparks) stay cheap
    let few = lmin(1, s * 2.2);
    flashRing(F, x, y, z, s * mult, true);
    fireball(F, x, y, z, s * mult, Math.ceil((big ? 16.0 : 11.0) * few));
    // (a mine chain on the sea lines its smoke up under the pilot's legs on
    // screen: lighter there)
    smokeBurst(F, x, y, z, s * mult * (k == "mine" ? 0.65 : 1.0), Math.ceil((k == "boom" ? 3.0 : (big ? 6.0 : 4.0)) * few), 0.18);
    sparkBurst(F, x, y, z, s * mult, Math.ceil((big ? 16.0 : 10.0) * few), 1, 0.82, 0.4);
    sparkBurst(F, x, y, z, s * mult * 0.8, Math.ceil((big ? 6.0 : 4.0) * few), CR_R + 0.1, 0.35, 0.5);
    if (s >= 0.3) {
        let nc = k == "huge" ? 18.0 : (k == "boom" ? 3.0 : (big ? 11.0 : 8.0));
        confetti(F, x, y, z, s * mult, nc);
        chunks(F, x, y, z, s * Math.sqrt(mult), k == "huge" ? 6.0 : (k == "boom" ? 1.0 : (big ? 3.0 : 2.0)));
    }
    if (k == "huge") {
        // rolling secondary blasts
        for (let i = 1; i <= 5; i++) {
            sphereDir();
            let dx = SD_X, dy = SD_Y, dz = SD_Z;
            let ox = x + dx * 4 * s, oy = y + dy * 3 * s, oz = z + dz * 4 * s;
            let d = 0.12 * <f64>i;
            let warm = i % 2 == 0;
            emit(F, 2, ox, oy, oz, 0, 0, 0, 1.5 * s, 20 * s, 5, CM_R, CM_G, CM_B, 0.9, CM_R, CM_G, CM_B, 0.4, d, 0, 0, 0);
            for (let j = 1; j <= 5; j++) {
                sphereDir();
                let ex = SD_X, ey = SD_Y, ez = SD_Z;
                let cr = GO_R, cg = GO_G, cb = GO_B;
                if (warm) {
                    cr = CR_R;
                    cg = CR_G;
                    cb = CR_B;
                }
                emit(F, 0, ox, oy, oz, ex * 5 * s, ey * 5 * s, ez * 5 * s, (1.2 + rand()) * s, 5 * s, 4,
                    cr, cg, cb, 1, cr, cg, cb, 0.6 + rand() * 0.3, d + rand() * 0.05, 3, -2, 0, FIRE_CAP);
            }
        }
    }
    if (k == "mine" && y < 4) {
        splash(F, x, z, s * 1.2);
    }
    // a low blast punches a ring into the sea under it
    if (y < 9 && k != "boom" && s >= 0.3) {
        waterRing(F, x, z, s * mult * (1 - y / 12));
    }
}

// Muzzle / impact sparks (core API).
export function sparks(F: Fx, x: f64, y: f64, z: f64, count: f64, r: f64, g: f64, b: f64): void {
    for (let i = 1.0; i <= count; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = 8 + rand() * 18;
        emit(F, 1, x, y, z, dx * sp, dy * sp, dz * sp, 0.22 + rand() * 0.1, -0.2, 0,
            r, g, b, 1, r, g * 0.7, b * 0.5, 0.25 + rand() * 0.15, 0, 4, 6, 1);
    }
    emit(F, 1, x, y, z, 0, 0, 0, 0.9, 2, 6, r, g, b, 0.9, r, g, b, 0.1, 0, 0, 0, 0);
}

// Armor ping: shots bouncing off something that cannot be hurt yet.
export function ricochet(F: Fx, x: f64, y: f64, z: f64): void {
    for (let i = 1; i <= 4; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        let sp = 12 + rand() * 10;
        emit(F, 1, x, y, z, dx * sp, dy * sp, dz * sp, 0.18, -0.2, 0, 0.8, 0.95, 1, 1, 0.5, 0.7, 1, 0.2, 0, 3, 0, 1.2);
    }
    emit(F, 2, x, y, z, 0, 0, 0, 0.3, 5, 6, 0.8, 0.95, 1, 0.8, 0.8, 0.95, 1, 0.16, 0, 0, 0, 0);
}

// Water spray under a low-flying body (core API; call every frame while skimming).
export function spray(F: Fx, x: f64, y: f64, z: f64, intensity: f64): void {
    if (rand() > intensity) return;
    // under a splash thrown this tick (the crash): its own spray covers it
    let sr = F.splR;
    if (sr > 0 && (x - F.splX) * (x - F.splX) + (z - F.splZ) * (z - F.splZ) < sr * sr) return;
    emit(F, 0, x + (rand() - 0.5), 0.2, z + (rand() - 0.5),
        (rand() - 0.5) * 4, 2 + rand() * 3, (rand() - 0.5) * 4,
        0.18 + rand() * 0.15, 0.25, 0,
        0.95, 0.98, 1, 1, 0.85, 0.94, 1,
        0.6, 0, 1, 14, 0);
}

// Damage smoke puff (dark 0..1: 0 pale steam, 1 dense ink), in cobalt ink
// rather than grey.
export function smoke(F: Fx, x: f64, y: f64, z: f64, size: f64, dark: f64): void {
    let g = 0.5 - dark * 0.32;
    let r0 = g * 0.8, g0 = g * 0.9, b0 = lmin(1, g * 1.45 + 0.1);
    emit(F, 0, x, y, z, (rand() - 0.5) * 1.5, 1 + rand(), (rand() - 0.5) * 1.5,
        size * (0.6 + rand() * 0.4), size * 1.4, 0.6,
        r0, g0, b0, 1, r0 + 0.22, g0 + 0.24, lmin(1, b0 + 0.2),
        0.9 + rand() * 0.6, 0, 1, -1, 0);
}

// Velocity (world m/s) every emit from here on carries (0, 0, 0 = at rest
// in the world again). Set it round the emits of a moving source (a
// burning engine on the Stormcrow, a damaged drone): puffs left at rest
// by a craft that keeps pace with the pilot stream back at the camera as a
// column as long as the rail covers in their life (~60 m of navy puffs).
export function carry(F: Fx, vx: f64, vy: f64, vz: f64): void {
    F.cvx = vx;
    F.cvy = vy;
    F.cvz = vz;
}

// Seconds every emit from here on waits before it shows (puffs, flakes,
// chunks, splashes, foam; 0 = now again). Kills landing together go up
// one after another instead of as one wall (ai_patterns.kill).
export function delay(F: Fx, seconds: f64): void {
    F.delay = lmax(seconds, 0);
}

// Thin wisp of light ink (rocket plumes, blown armor): small, short-lived,
// fading from `alpha`, so a trail reads as a pencil line, not a string of
// cobalt boulders.
export function wisp(F: Fx, x: f64, y: f64, z: f64, size: f64, alpha: f64): void {
    emit(F, 0, x, y, z, (rand() - 0.5) * 1.2, 0.4 + rand() * 0.6, (rand() - 0.5) * 1.2,
        size * (0.8 + rand() * 0.4), size * 1.1, 1.5,
        INKL_R, INKL_G, INKL_B, alpha, INKL_R, INKL_G, INKL_B,
        0.4 + rand() * 0.2, 0, 1, -1, 0);
}

// Burning puff (wrecks, damaged engines): brass gold or crimson, flashing
// white-hot first, never burning down to grey.
export function fire(F: Fx, x: f64, y: f64, z: f64, size: f64): void {
    let cr = GO_R, cg = GO_G, cb = GO_B;
    if (rand() < 0.45) {
        cr = CR_R;
        cg = CR_G;
        cb = CR_B;
    }
    emit(F, 0, x, y, z, (rand() - 0.5) * 2, 1 + rand() * 2, (rand() - 0.5) * 2,
        size * (0.7 + rand() * 0.5), -size * 0.6, 0,
        cr, cg, cb, 1, cr, cg, cb,
        0.3 + rand() * 0.2, 0, 2, -3, 0, FIRE_CAP);
}

// Jet flame: short stretched additive streak along (dx,dy,dz) plus a toon puff.
export function flame(F: Fx, x: f64, y: f64, z: f64, dx: f64, dy: f64, dz: f64, size: f64, r: f64, g: f64, b: f64): void {
    let sp = 14 + rand() * 6;
    emit(F, 1, x, y, z, dx * sp, dy * sp, dz * sp, size * (0.8 + rand() * 0.4), -size * 2, 0,
        1, 0.95, 0.9, 1, r, g, b, 0.14 + rand() * 0.06, 0, 0, 0, 1.3);
    if (rand() < 0.5) {
        emit(F, 0, x + dx * 0.4, y + dy * 0.4, z + dz * 0.4, dx * sp * 0.4, dy * sp * 0.4, dz * sp * 0.4,
            size * 0.55, -size * 1.5, 0, r, g, b, 1, r * 0.7, g * 0.5, b * 0.8, 0.16, 0, 3, 0, 0);
    }
}

// Muzzle flash: additive star + stretched streak along the barrel.
export function muzzle(F: Fx, x: f64, y: f64, z: f64, dx: f64, dy: f64, dz: f64, size: f64, r: f64, g: f64, b: f64): void {
    emit(F, 1, x, y, z, 0, 0, 0, size, size * 4, 10, 1, 0.95, 0.8, 1, r, g, b, 0.08, 0, 0, 0, 0);
    emit(F, 1, x + dx * size * 0.6, y + dy * size * 0.6, z + dz * size * 0.6, dx * 40, dy * 40, dz * 40,
        size * 0.7, 0, 0, r, g, b, 1, r, g, b, 0.07, 0, 30, 0, 1.2);
}

// Transient additive glow (engine flare, charge-up).
export function glow(F: Fx, x: f64, y: f64, z: f64, size: f64, r: f64, g: f64, b: f64, life: f64): void {
    emit(F, 1, x, y, z, 0, 0, 0, size, 0, 0, r, g, b, 1, r, g, b, life, 0, 0, 0, 0);
}

// Expanding ring (kind 2).
export function ring(F: Fx, x: f64, y: f64, z: f64, size: f64, grow: f64, r: f64, g: f64, b: f64, life: f64): void {
    emit(F, 2, x, y, z, 0, 0, 0, size, grow, 3, r, g, b, 1, r, g, b, life, 0, 0, 0, 0);
}

// Warp-in sparkle (violet troopers, boss entrances).
export function warp(F: Fx, x: f64, y: f64, z: f64, s: f64, r: f64, g: f64, b: f64): void {
    emit(F, 2, x, y, z, 0, 0, 0, 5 * s, -8 * s, 0, r, g, b, 1, 1, 1, 1, 0.5, 0, 0, 0, 0);
    for (let i = 1; i <= 12; i++) {
        sphereDir();
        let dx = SD_X, dy = SD_Y, dz = SD_Z;
        emit(F, 1, x + dx * 4 * s, y + dy * 4 * s, z + dz * 4 * s, -dx * 8 * s, -dy * 8 * s, -dz * 8 * s,
            0.3 * s, -0.2, 0, 1, 1, 1, 1, r, g, b, 0.45, 0, 0, 0, 1);
    }
}

// Storm ----------------------------------------------------------------------------
// The squall the Stormcrow rises out of (events cues it at STORMCROW_S - 150,
// boss_stormcrow drives it): a low SHELF of storm cloud across the bay past
// the CLIFF TURN mouth, the cover she hides in and heaves up out of, and
// the CELL over it on a flat base STORM_BASE m up (towers, a sunlit anvil),
// so a bright band of horizon shows between the two. Rain hangs from the
// cell, lightning flickers in it, the sea goes dark under it. Once she is
// out the shelf collapses into rain, then the cell drifts off down the
// valley and fades into the sky. World-anchored at rail s0 + STORM_D0 +
// STORM_D1 x the rise's stand-off (stormFar: a narrow screen stands the
// boss off further, but she rises nearer, with the landscape's storm, and
// eases back to the hold), lateral x. Own random stream; cloud, not rock:
// nothing collides with it.

// anchor (m past the cue: fixed + per unit of the rise's stand-off)
export let STORM_D0: f64 = 32;
export let STORM_D1: f64 = 165;
// the share of the boss stand-off past 1 the rise keeps
export let STORM_FAR: f64 = 0;
// the cell's flat base (local m): rain hangs from it, bolts drop from it
export let STORM_BASE: f64 = 52;
// seconds it brews in, seconds it fades into the sky once it breaks up
const BREW: f64 = 1.6;
const BREAK_DUR: f64 = 0.9;
// the shelf collapses into rain: seconds it slumps, how far it sinks (m),
// the share of its height left; opaque until she is up out of it (a fade
// showed her through it, ghosted), then it rains out into the sky from
// SHELF_FADE of its fall (its last lumps read as rock on the sea)
const SHELF_FALL: f64 = 0.55;
const SHELF_SINK: f64 = 40;
const SHELF_SLUMP: f64 = 0.45;
const SHELF_FADE: f64 = 0.45;
// a bolt's life (s): strike, flicker, restrike
const BOLT_LIFE: f64 = 0.34;
// rain streaks and veils hanging from the cell
const RAIN: i32 = 48;
const CURTAINS: i32 = 10;
// storm light on the world while it stands ahead (exposure share), the
// extra dip while its shadow is over the pilot, the white-violet kick a big
// strike gives the frame
const DIM: f64 = 0.14;
const DIM_UNDER: f64 = 0.24;
const KICK: f64 = 0.12;

// Parts (local m: x right, z toward the pilot; base, half length, height,
// depth, seed, group: 1 the shelf, 0 the cell). Each cumulus hull is laid
// long across the view.
const STORM_PARTS: Array<Array<f64>> = [[0.0],
    // the shelf: a bank across the bay, a wall of cloud 28-30 m tall across
    // her whole length where she hides (34 behind her: from every line the
    // pilot flies), a low roll at its foot in front, raised tails either
    // side (17 m+ off the shore)
    [0.0, -4, 6, -1, 24, 28, 30, 5101, 1],
    [0.0, 18, 2, -1, 24, 30, 30, 5133, 1],
    [0.0, 38, 0, -1, 22, 28, 28, 5149, 1],
    [0.0, 26, -32, -1, 40, 34, 34, 5167, 1],
    [0.0, -30, -10, -1, 14, 18, 18, 5181, 1],
    [0.0, 62, -12, -1, 16, 18, 20, 5191, 1],
    [0.0, 16, 14, -1, 40, 9, 16, 5203, 1],
    // the cell on its flat base: towers, then the anvil
    [0.0, -32, -54, 52, 34, 30, 30, 5211, 0],
    [0.0, 30, -62, 54, 32, 34, 30, 5223, 0],
    [0.0, -2, -84, 56, 44, 38, 36, 5171, 0],
    [0.0, 0, -96, 86, 76, 14, 50, 5199, 0],
];
// shades by height (local y, colour): the shelf a dark slate-navy bank (a
// squall, not a fair-weather cumulus) with a cool lit lip and a lighter
// rain-grey foot (never a dark lump on the sea), the cell dark slate at its
// base to a sunlit lilac anvil
const SHELF_SHADE: Array<Array<f64>> = [[0.0],
    [0.0, 0, 0x7C7CA6], [0.0, 7, 0x464976], [0.0, 15, 0x363964], [0.0, 23, 0x4A4D7C], [0.0, 30, 0x8A8CB6],
];
const CELL_SHADE: Array<Array<f64>> = [[0.0],
    [0.0, 54, 0x353966], [0.0, 66, 0x474A7C], [0.0, 82, 0x7672A8], [0.0, 96, 0xB4ACD0], [0.0, 110, 0xE6DFF0],
];

// stormShade outputs
let SH_R: f64 = 0;
let SH_G: f64 = 0;
let SH_B: f64 = 0;
function shadeHex(hex: f64): void {
    mathx.rgb(hex);
    SH_R = mathx.RGB_R;
    SH_G = mathx.RGB_G;
    SH_B = mathx.RGB_B;
}
function stormShade(tab: Array<Array<f64>>, y: f64): void {
    let n = tab.length - 1;
    if (y <= tab[1][1]) {
        shadeHex(tab[1][2]);
        return;
    }
    for (let i = 2; i <= n; i++) {
        let y1 = tab[i][1];
        if (y <= y1) {
            let y0 = tab[i - 1][1];
            let u = mathx.smoothstep(y0, y1, y);
            mathx.rgb(tab[i - 1][2]);
            let r0 = mathx.RGB_R, g0 = mathx.RGB_G, b0 = mathx.RGB_B;
            mathx.rgb(tab[i][2]);
            let r1 = mathx.RGB_R, g1 = mathx.RGB_G, b1 = mathx.RGB_B;
            SH_R = r0 + (r1 - r0) * u;
            SH_G = g0 + (g1 - g0) * u;
            SH_B = b0 + (b1 - b0) * u;
            return;
        }
    }
    shadeHex(tab[n][2]);
}

// the shelf's top (local m) on a grid over local x / z (cells of TOP_CELL m
// from TOP_X0 / TOP_Z0; -1: no cloud), 1-based
const TOP_CELL: f64 = 4, TOP_X0: f64 = -72, TOP_Z0: f64 = -72, TOP_NX: f64 = 44, TOP_NZ: f64 = 30;
const shelfTop: Array<f64> = newShelfTop();
function newShelfTop(): Array<f64> {
    let a = new Array<f64>(<i32>(TOP_NX * TOP_NZ) + 1);
    a.fill(-1);
    a[0] = 0;
    return a;
}

// One group's mesh (CPU); the shelf also fills its top grid.
function stormMesh(group: f64): Builder {
    let b = meshgen.create(12000);
    for (let qi = 1; qi < STORM_PARTS.length; qi++) {
        let q = STORM_PARTS[qi];
        if (q[8] != group) continue;
        let rng = mathx.rng(q[7]);
        let yaw = mathx.rand(rng) * Math.PI * 2;
        let v0 = b.vcount;
        let spec = new CloudSpec();
        spec.x = 0;
        spec.y = q[3] + q[5] * 0.12;
        spec.z = 0;
        spec.sx = q[4];
        spec.sy = q[5];
        spec.sz = q[6];
        spec.puffs = 0;
        spec.seed = q[7];
        spec.tint = 0xFFFFFF;
        spec.ink = group == 1 ? 0.4 : 0.3;
        // (turned by the hull's own random yaw: these seeds then lie long
        // across the view)
        meshgen.push(b, Mat4.fromTranslation(<f32>q[1], 0, <f32>q[2]) * Mat4.fromRotationY(<f32>yaw));
        geo.cloud(b, spec);
        meshgen.pop(b);
        let tab = group == 1 ? SHELF_SHADE : CELL_SHADE;
        let vf = b.vf, vu = b.vu;
        for (let v = v0; v < b.vcount; v++) {
            let x = <f64>vf[v * 8];
            let y = <f64>vf[v * 8 + 1];
            let z = <f64>vf[v * 8 + 2];
            stormShade(tab, y);
            vu[v * 8 + 6] = meshgen.pack8(SH_R, SH_G, SH_B, 1);
            if (group == 1) {
                let ix = Math.floor((x - TOP_X0) / TOP_CELL), iz = Math.floor((z - TOP_Z0) / TOP_CELL);
                if (ix >= 0 && ix < TOP_NX && iz >= 0 && iz < TOP_NZ) {
                    let k = <i32>(iz * TOP_NX + ix + 1);
                    shelfTop[k] = lmax(shelfTop[k], y);
                }
            }
        }
    }
    return b;
}

// (CPU meshes until the first draw uploads them)
let stormMade: bool = false;
let shelfB: Builder? = null;
let cellB: Builder? = null;

// Builds the storm meshes (shelf, then cell) and the shelf's top grid once:
// Luau does it at require; here on first use, or call it while loading.
export function stormBuild(): void {
    if (stormMade) return;
    stormMade = true;
    shelfB = stormMesh(1);
    cellB = stormMesh(0);
}

// The shelf's top (local m) over local x / z, before it slumps (-1: none).
export function stormShelfTop(lx: f64, lz: f64): f64 {
    stormBuild();
    let ix = Math.floor((lx - TOP_X0) / TOP_CELL), iz = Math.floor((lz - TOP_Z0) / TOP_CELL);
    if (ix < 0 || ix >= TOP_NX || iz < 0 || iz >= TOP_NZ) return -1;
    return shelfTop[<i32>(iz * TOP_NX + ix + 1)];
}

let stormCell: Batch? = null;
let stormShelf: Batch? = null;

function stormRnd(Q: Storm): f64 {
    Q.seed = mod(Q.seed * 16807, 2147483647);
    return (Q.seed - 1) / 2147483646;
}

function clearBolts(Q: Storm): void {
    let bolts = Q.bolts;
    while (bolts.length > 1) bolts.pop();
}

// Brew it: anchored at the cue s0, x m right of the rail, never past smax.
export function stormStart(F: Fx, s0: f64, x: f64, smax: f64): void {
    let Q = F.storm;
    if (Q.on) return;
    Q.on = true;
    Q.t = 0;
    Q.s0 = s0;
    Q.x = x;
    Q.smax = smax;
    Q.ds = 0;
    Q.drift = 0;
    Q.breakT = -1;
    Q.shelfT = -1;
    Q.flash = 0;
    Q.big = 0;
    Q.sweep = 0;
    Q.nextT = 0.5;
    Q.seed = 12345;
    Q.vis = 0;
    Q.shelfVis = 0;
    Q.shelfK = 1;
    clearBolts(Q);
}

// Fully brewed now (a run that starts at her cue: she hides in it at once).
export function stormRipen(F: Fx): void {
    let Q = F.storm;
    Q.t = lmax(Q.t, BREW);
}

export function stormClear(F: Fx): void {
    F.storm.on = false;
    clearBolts(F.storm);
}

// The rise's stand-off for the boss stand-off `far`.
export function stormFar(far: f64): f64 {
    return 1 + (far - 1) * STORM_FAR;
}

// Rail s of its anchor (before the drift) for the boss stand-off `far`.
export function stormAnchorS(F: Fx, far: f64): f64 {
    let Q = F.storm;
    return lmin(Q.s0 + STORM_D0 + STORM_D1 * stormFar(far), Q.smax);
}

// Lightning: a bolt out of the cell's base to the sea (big: lit wide, kicks
// the frame), a crawler across the base (crawl), or (bolt = false) sheet
// lightning inside. lx: local x of the strike (NaN: anywhere along it).
export function stormStrike(F: Fx, big: bool, bolt: bool, lx: f64 = NaN, crawl: bool = false): void {
    let Q = F.storm;
    Q.flash = lmax(Q.flash, big ? 1.0 : 0.5);
    if (big) Q.big = 1;
    if (!bolt) return;
    let base = STORM_BASE;
    let x = isNaN(lx) ? (stormRnd(Q) - 0.5) * 110 : lx;
    if (crawl) {
        let y = base - 1 - stormRnd(Q) * 4;
        let z = -30 - stormRnd(Q) * 20;
        Q.bolts.push([0.0, 0, stormRnd(Q) * 1000, x - 30, y, z, x + 30 + stormRnd(Q) * 16, y - 2 - stormRnd(Q) * 4, 1.6, 1]);
        return;
    }
    Q.bolts.push([0.0,
        0, stormRnd(Q) * 1000,
        x, base - 1, -24 - stormRnd(Q) * 24,
        x + (stormRnd(Q) - 0.5) * 26, -6 - stormRnd(Q) * 24,
        big ? 4.2 : 2.4, 0,
    ]);
}

// It drifts off down the valley at `speed` m/s (0: holds).
export function stormRelease(F: Fx, speed: f64): void {
    F.storm.drift = speed;
}

// The shelf collapses into rain (she is up out of it).
export function stormCollapse(F: Fx): void {
    let Q = F.storm;
    if (Q.shelfT < 0) Q.shelfT = 0;
}

// Fade it into the sky.
export function stormBreakUp(F: Fx): void {
    let Q = F.storm;
    if (Q.breakT < 0) Q.breakT = 0;
}

// Its shadow over the slot: 0 .. 1 (1: its edge has rolled past the pilot).
export function stormSweep(F: Fx, k: f64): void {
    F.storm.sweep = lclamp(k, 0, 1);
}

// Local storm coordinates of a world point (x right, y up from its base on
// the sea, z toward the pilot), against the shelf's frame (shelf) or the
// cell's: STORM_LOCAL_X / Y / Z.
export let STORM_LOCAL_X: f64 = 0;
export let STORM_LOCAL_Y: f64 = 0;
export let STORM_LOCAL_Z: f64 = 0;
export function stormLocal(F: Fx, wx: f64, wy: f64, wz: f64, shelf: bool = false): void {
    let x = shelf ? F.storm.xs : F.storm.xf;
    let dx = wx - x.px, dy = wy - x.py, dz = wz - x.pz;
    let s = lmax(x.s, 1e-6);
    let sy = s * (shelf ? lmax(F.storm.shelfK, 1e-3) : 1.0);
    STORM_LOCAL_X = (dx * x.rx + dy * x.ry + dz * x.rz) / s;
    STORM_LOCAL_Y = (dx * x.ux + dy * x.uy + dz * x.uz) / sy;
    STORM_LOCAL_Z = -(dx * x.fx + dy * x.fy + dz * x.fz) / s;
}

// Tick (game time): brew, flickers, bolts, drift, and its frame on the rail.
// railFrame(s) leaves the rail frame in track.FRAME_P / FRAME_F / FRAME_R.
export function stormUpdate(F: Fx, railFrame: (s: f64) => void, far: f64, dt: f64): void {
    let Q = F.storm;
    if (!Q.on) return;
    Q.t += dt;
    Q.ds += Q.drift * dt;
    if (Q.breakT >= 0) Q.breakT += dt;
    if (Q.shelfT >= 0) Q.shelfT += dt;
    let brew = mathx.smoothstep(0, BREW, Q.t);
    let gone = Q.breakT >= 0 ? mathx.smoothstep(0, BREAK_DUR, Q.breakT) : 0.0;
    Q.vis = brew * (1 - gone);
    // (the shelf slumps and sinks whole, raining out at the end; it only
    // fades with the cell when it never collapsed)
    let fall = Q.shelfT >= 0 ? mathx.smoothstep(0, SHELF_FALL, Q.shelfT) : 0.0;
    Q.shelfK = 1 - (1 - SHELF_SLUMP) * fall;
    Q.shelfVis = Q.shelfT >= 0 ? brew * (1 - mathx.smoothstep(SHELF_FADE, 0.9, fall)) : Q.vis;
    if (Q.breakT > BREAK_DUR + 0.2 && Q.shelfVis <= 0.002) {
        stormClear(F);
        return;
    }
    Q.flash = lmax(0, Q.flash - dt * 5);
    Q.big = lmax(0, Q.big - dt * 7);
    // ambient flickers while it stands (the boss's strikes come on top)
    if (Q.t >= Q.nextT && Q.breakT < 0) {
        let u = stormRnd(Q);
        stormStrike(F, false, u < 0.55, NaN, u < 0.2);
        Q.nextT = Q.t + 0.5 + stormRnd(Q) * 0.9;
    }
    let bolts = Q.bolts;
    let i = 1;
    while (i < bolts.length) {
        let bt = bolts[i];
        bt[1] += dt;
        if (bt[1] > BOLT_LIFE) {
            bolts[i] = bolts[bolts.length - 1];
            bolts.pop();
        } else {
            i += 1;
        }
    }
    railFrame(stormAnchorS(F, far) + Q.ds);
    let pos = track.FRAME_P, f = track.FRAME_F, rt = track.FRAME_R;
    let fx = <f64>f.x, fz = <f64>f.z;
    let fl = lmax(Math.sqrt(fx * fx + fz * fz), 1e-6);
    let px = <f64>pos.x + <f64>rt.x * Q.x, pz = <f64>pos.z + <f64>rt.z * Q.x;
    // heaves up out of the sea as it brews; as it fades the cell lifts off
    // (sinking, its dark base came down on her nose) and the shelf slumps
    // into the sea
    let y0 = -(1 - mathx.easeOutCubic(brew)) * 12;
    models.aim(Q.xf, px, y0 + gone * 10, pz, fx / fl, 0, fz / fl, 0, 1, 0, 0, 1);
    models.aim(Q.xs, px, y0 - SHELF_SINK * fall * fall, pz, fx / fl, 0, fz / fl, 0, 1, 0, 0, 1);
}

@inline function boltJitter(seed: f64, k: f64): f64 {
    let h = Math.sin(seed * 12.9898 + k * 78.233) * 43758.5453;
    return (h - Math.floor(h)) - 0.5;
}

// a jagged bolt from local (x0, y0, z0) to (x1, y1, z1): a wide violet glow
// under a white-hot core, with forks
function drawBolt(Q: Storm, r: R.Gfx, bt: Array<f64>, a: f64): void {
    let x = Q.xf;
    let seed = bt[2];
    let crawl = bt[9] == 1;
    let n = crawl ? 7 : 9;
    let fn = <f64>n;
    let x0 = bt[3], y0 = bt[4], z0 = bt[5];
    let x1 = bt[6], y1 = crawl ? bt[7] : 0.0, z1 = crawl ? bt[5] + 2 : bt[7];
    models.point(x, x0, y0, z0);
    let px = models.POINT_X, py = models.POINT_Y, pz = models.POINT_Z;
    let w = bt[8];
    for (let k = 1; k <= n; k++) {
        let fk = <f64>k;
        let u = fk / fn;
        let jx = k < n ? boltJitter(seed, fk) * (crawl ? 6.0 : 11.0) : 0.0;
        let jy = k < n ? boltJitter(seed, fk + 17) * (crawl ? 6.0 : 3.0) : 0.0;
        let lx = x0 + (x1 - x0) * u + jx;
        let ly = y0 + (y1 - y0) * u + jy;
        let lz = z0 + (z1 - z0) * u + (k < n ? boltJitter(seed, fk + 31) * 6 : 0.0);
        models.point(x, lx, ly, lz);
        let qx = models.POINT_X, qy = models.POINT_Y, qz = models.POINT_Z;
        R.ribbon(r, px, py, pz, w * 3.2, a * 0.35, qx, qy, qz, w * 3.2, a * 0.35, 0.55, 0.5, 1, 1, 1, 0, 0, NaN, NaN, NaN, NaN, NaN, NaN, seed + fk);
        R.ribbon(r, px, py, pz, w, a, qx, qy, qz, w, a, 0.85, 0.82, 1, 1, 1, 0, 0, NaN, NaN, NaN, NaN, NaN, NaN, seed + fk + 50);
        if (k == 3 || k == 6) {
            models.point(x, lx + boltJitter(seed, 77 + fk) * 26, ly - (crawl ? 6.0 : ly * 0.4), lz + 6 + boltJitter(seed, 78 + fk) * 8);
            let fx2 = models.POINT_X, fy2 = models.POINT_Y, fz2 = models.POINT_Z;
            R.ribbon(r, qx, qy, qz, w * 0.6, a * 0.8, fx2, fy2, fz2, w * 0.25, a * 0.3, 0.8, 0.78, 1, 1, 1, 0, 0, NaN, NaN, NaN, NaN, NaN, NaN, seed + 40 + fk);
        }
        px = qx;
        py = qy;
        pz = qz;
    }
    if (!crawl) {
        models.point(x, x1, 0.5, z1);
        R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 9 * w, 0.7, 0.72, 1, 0.5 * a, 1, 0.5, seed, 0);
    }
}

function stormDraw(F: Fx, r: R.Gfx): void {
    let Q = F.storm;
    if (!Q.on || (Q.vis <= 0.002 && Q.shelfVis <= 0.002)) return;
    stormBuild();
    let cb = cellB, sb = shelfB;
    if (stormCell == null && cb != null && sb != null) {
        stormCell = gpu.batch("bossStorm", gpu.uploadMesh(cb), 1, true, true);
        stormShelf = gpu.batch("bossStormShelf", gpu.uploadMesh(sb), 1, true, true);
        cellB = null;
        shelfB = null;
    }
    let cell = stormCell, shelf = stormShelf;
    if (cell == null || shelf == null) return;
    gpu.reset(cell);
    gpu.reset(shelf);
    let x = Q.xf;
    // lightning lights the murk from inside: a pale violet wash
    let wash = Q.flash * Q.flash;
    if (models.put(cell, x, 1 + 0.5 * wash, 1 + 0.55 * wash, 1 + 0.8 * wash, 0.35 * wash, 0, 0) && Q.vis < 0.999) {
        gpu.setSkyFade(cell, cell.n, 1 - Q.vis);
    }
    R.addBatch(r, cell);
    if (Q.shelfVis > 0.002) {
        let xs = Q.xs;
        let k = Q.shelfK;
        if (gpu.addBasis(shelf, xs.px, xs.py, xs.pz, xs.rx, xs.ry, xs.rz, xs.ux, xs.uy, xs.uz, xs.fx, xs.fy, xs.fz, xs.s, xs.s * k, xs.s,
            1 + 0.4 * wash, 1 + 0.45 * wash, 1 + 0.7 * wash, 0.3 * wash, 0, 0) && Q.shelfVis < 0.999) {
            gpu.setSkyFade(shelf, shelf.n, 1 - Q.shelfVis);
        }
        R.addBatch(r, shelf);
    }
    // the sea goes dark under it; its shadow rolls up the slot over the
    // pilot (Storm.sweep: centred past him, edge behind him at 1)
    models.point(x, 0, 0, -20);
    let sx = models.POINT_X, sz = models.POINT_Z;
    R.shadow(r, sx, sz, 120, 0.55 * Q.vis);
    let ex = F.camX, ez = F.camZ;
    let sw = Q.sweep * Q.vis;
    if (sw > 0.01) {
        let dx = ex - sx, dz = ez - sz;
        let dl = lmax(Math.sqrt(dx * dx + dz * dz), 1);
        let dc = (dl + 30) * mathx.easeInOutCubic(sw);
        R.shadow(r, sx + dx / dl * dc, sz + dz / dl * dc, 90, 0.5 * sw);
    }
    let bolts = Q.bolts;
    for (let i = 1; i < bolts.length; i++) {
        let bt = bolts[i];
        let age = bt[1] / BOLT_LIFE;
        // strike, a flicker off, a restrike, then gone
        let a = age < 0.22 ? 1.0 : (age < 0.36 ? 0.1 : (age < 0.7 ? 0.9 : (1 - age) * 3));
        drawBolt(Q, r, bt, a * Q.vis);
    }
    // rain from the cell's base: hazy veils behind the shelf (lighter than
    // the cloud: rain, not rock) with streaks falling in front of them
    let base = STORM_BASE;
    let t = Q.t;
    for (let i = 1; i <= CURTAINS; i++) {
        let fi = <f64>i;
        let h = Math.sin(fi * 53.3 + 1.7) * 43758.5453;
        let u = h - Math.floor(h);
        let lx = (fi - 0.5) / <f64>CURTAINS * 150 - 75 + (u - 0.5) * 14 + Math.sin(t * 0.4 + fi) * 4;
        let lz = -34 - u * 36;
        models.point(x, lx, base - 2, lz);
        let ax = models.POINT_X, ay = models.POINT_Y, az = models.POINT_Z;
        models.point(x, lx + base * 0.16, 0, lz + 6);
        let bx = models.POINT_X, by = models.POINT_Y, bz = models.POINT_Z;
        R.ribbon(r, ax, ay, az, 16 + u * 10, 0.45, bx, by, bz, 24 + u * 12, 0.8, 0.62, 0.64, 0.8, 0.6 * Q.vis, 0, 0, 0.15, NaN, NaN, NaN, NaN, NaN, NaN, 200 + fi);
    }
    for (let i = 1; i <= RAIN; i++) {
        let fi = <f64>i;
        let h = Math.sin(fi * 91.7) * 43758.5453;
        let u = h - Math.floor(h);
        let h2 = Math.sin(fi * 37.1 + 4.0) * 43758.5453;
        let u2 = h2 - Math.floor(h2);
        let lx = (u - 0.5) * 170;
        let lz = -10 - u2 * 70;
        let top = base - 3 - u2 * 6;
        let fall = mod(t * (0.7 + u * 0.4) + u2, 1);
        let y0 = top * (1 - fall);
        let y1 = lmax(0, y0 - 26);
        models.point(x, lx + y0 * 0.16, y0, lz);
        let ax = models.POINT_X, ay = models.POINT_Y, az = models.POINT_Z;
        models.point(x, lx + y1 * 0.16, y1, lz);
        let bx = models.POINT_X, by = models.POINT_Y, bz = models.POINT_Z;
        R.ribbon(r, ax, ay, az, 2, 0.1, bx, by, bz, 2, 0.7, 0.7, 0.72, 0.86, 0.5 * Q.vis, 0, 0, 0.3, NaN, NaN, NaN, NaN, NaN, NaN, fi);
    }
    // glow in the cell while lit
    if (Q.flash > 0.05) {
        models.point(x, 0, base + 14, -60);
        R.particle(r, models.POINT_X, models.POINT_Y, models.POINT_Z, 90, 0.62, 0.62, 1, 0.22 * Q.flash * Q.vis, 1, 0.5, 0.2, 0);
    }
    // storm light on the world (deeper while its shadow is over him), and a
    // white-violet kick on a big strike
    let p = r.post;
    p.exposure *= 1 - DIM * Q.vis - DIM_UNDER * mathx.smoothstep(0.55, 0.95, sw);
    let kick = KICK * Q.big * Q.vis;
    if (kick > p.flash) {
        p.flash = kick;
        p.flashR = 0.86;
        p.flashG = 0.84;
        p.flashB = 1;
    }
}

// Simulation ---------------------------------------------------------------------

// a falling chunk trails ink for this long (s)
const TRAIL_AGE: f64 = 0.9;
// carried velocity (carry) bleeds away at this rate (1/s): smoke off a
// ship doing 50 m/s trails ~10 m behind the stack over its life
const CARRY_DRAG: f64 = 0.4;

export function update(F: Fx, dt: f64): void {
    F.splR = 0;
    let spots = F.spots;
    for (let i = spots.length - 1; i >= 1; i--) {
        let sp = spots[i];
        sp[4] += dt;
        if (sp[4] >= sp[5]) spots.splice(i, 1);
    }
    let rings = F.rings;
    for (let i = rings.length - 1; i >= 1; i--) {
        let c = rings[i];
        c[4] += dt;
        if (c[4] >= c[5]) rings.splice(i, 1);
    }
    let crowns = F.crowns;
    for (let i = crowns.length - 1; i >= 1; i--) {
        let c = crowns[i];
        c[4] += dt;
        if (c[4] >= c[5]) crowns.splice(i, 1);
    }
    let parts = F.parts;
    let free = F.free;
    let i = 1;
    while (i < parts.length) {
        let p = parts[i];
        p.age += dt;
        if (p.age >= p.life) {
            parts[i] = parts[parts.length - 1];
            parts.pop();
            free.push(p);
        } else {
            if (p.age >= 0) {
                let k = Math.exp(-p.drag * dt);
                p.vx *= k;
                p.vy = p.vy * k - p.gravity * dt;
                p.vz *= k;
                p.x += p.vx * dt;
                p.y += p.vy * dt;
                p.z += p.vz * dt;
                p.size = lmax(0.02, p.size + p.grow * dt);
                if (p.gdrag > 0) p.grow *= Math.exp(-p.gdrag * dt);
                p.rot += p.spin * dt;
                if (p.cvx != 0 || p.cvy != 0 || p.cvz != 0) {
                    let kc = Math.exp(-CARRY_DRAG * dt);
                    p.cvx *= kc;
                    p.cvy *= kc;
                    p.cvz *= kc;
                    p.x += p.cvx * dt;
                    p.y += p.cvy * dt;
                    p.z += p.cvz * dt;
                }
            }
            i += 1;
        }
    }
    // debris
    let ds = F.debris;
    let j = 1;
    while (j < ds.length) {
        let d = ds[j];
        d.age += dt;
        if (d.age < 0) {
            j += 1;
            continue;
        }
        let fl = d.flat;
        let k = Math.exp(-(fl ? 1.8 : 0.4) * dt);
        d.vx *= k;
        d.vz *= k;
        d.vy = d.vy * k - (fl ? 11.0 : 26.0) * dt;
        d.x += d.vx * dt;
        d.y += d.vy * dt;
        d.z += d.vz * dt;
        d.a += d.sa * dt;
        d.b += d.sb * dt;
        d.smokeT -= dt;
        let cx = d.x - F.camX, cy = d.y - F.camY, cz = d.z - F.camZ;
        if (d.smokeT <= 0 && !fl && cx * cx + cy * cy + cz * cz > 14 * 14) {
            let sz = (d.sx + d.sz) * 0.5;
            if (d.fire && d.age < 1.2) {
                d.smokeT = 0.06;
                fire(F, d.x, d.y, d.z, sz * 1.2);
            } else if (d.age < TRAIL_AGE) {
                // wispy ink trail: small puffs in the lighter ink that thin
                // out fast, and only over the first part of the fall (a
                // puff every 0.06 s all the way down stood as a cobalt
                // column under every blast)
                d.smokeT = 0.09;
                emit(F, 0, d.x, d.y, d.z, (rand() - 0.5) * 1.5, 0.5 + rand(), (rand() - 0.5) * 1.5,
                    sz * 0.35, sz * 1.3, 1.2,
                    INKL_R, INKL_G, INKL_B, 1 - 0.5 * d.age / TRAIL_AGE, INKL_R, INKL_G, INKL_B,
                    0.4 + rand() * 0.2, 0, 1, -1, 0);
            }
        }
        let gone = false;
        if (d.y < 0 && d.vy < 0) {
            if (!fl) splash(F, d.x, d.z, 0.35 + (d.sx + d.sz) * 0.25);
            gone = true;
        } else if (d.age > d.life) {
            gone = true;
        }
        if (gone) {
            ds[j] = ds[ds.length - 1];
            ds.pop();
        } else {
            j += 1;
        }
    }
}

// kill cam thinning band (m) in front of the framed boss (see Fx.shotNear)
const SHOT_FADE: f64 = 18;
// smoke (not fire) near the lens thins to wisps, all the time: from
// LENS_SMOKE + LENS_SMOKE_SIZE m per m of puff (a 1 m puff from 21 m, a 3 m
// one from 39 m; size capped at 4), gone by 4 m. A kill at gun range leaves
// its smoke where the pilot is a second later: the bigger the puff, the
// sooner it opens up, so none stands more than ~1/12 of the view tall
const LENS_SMOKE: f64 = 12;
const LENS_SMOKE_SIZE: f64 = 9;
// fire puffs (warm, capped; over 0.5 m, not the crash's licks) burn off
// before they reach the lens, all the time: from LENS_FIRE +
// LENS_FIRE_SIZE m per m of puff (a 1 m puff from 14 m, a 3 m one from
// 22 m), shrinking to LENS_FIRE_MIN of their size, gone by LENS_FIRE0 m.
// The pilot rides 10-16 m out: a blast he flies into (a mine chain at his
// legs, a squadron's fireballs) opens up round him instead of standing as
// a wall of blobs over him and the gauges
const LENS_FIRE: f64 = 10;
const LENS_FIRE_SIZE: f64 = 4;
const LENS_FIRE0: f64 = 6;
const LENS_FIRE_MIN: f64 = 0.55;

export function draw(F: Fx, r: R.Gfx): void {
    let ex = F.camX, ey = F.camY, ez = F.camZ;
    if (!F.camSet) {
        let eye = r.camEye;
        ex = <f64>eye.x;
        ey = <f64>eye.y;
        ez = <f64>eye.z;
        F.camX = ex;
        F.camY = ey;
        F.camZ = ez;
    }
    F.camSet = false;
    stormDraw(F, r);
    // splash foam: spreads fast, then thins out
    let spots = F.spots;
    for (let i = 1; i < spots.length; i++) {
        let sp = spots[i];
        if (sp[4] < 0) continue;
        let t = sp[4] / sp[5];
        let u = 1 - t;
        R.foam(r, sp[1], sp[2], sp[3] * (0.35 + 0.65 * (1 - u * u * u)), 0.75 * u * Math.sqrt(u));
    }
    // kill cam: the blast flies at the lens as the orbit swings in; what is
    // nearer than the boss's near side fades over SHOT_FADE m, so the eye /
    // hull stays readable in its own fireball
    let shot = F.shotNear;
    F.shotNear = 0;
    let shot0 = shot - SHOT_FADE;
    let parts = F.parts;
    for (let i = 1; i < parts.length; i++) {
        let p = parts[i];
        if (p.age >= 0) {
            let t = p.age / p.life;
            let u = t * t * (3 - 2 * t);
            let cr = p.r + (p.r2 - p.r) * u;
            let cg = p.g + (p.g2 - p.g) * u;
            let cb = p.b + (p.b2 - p.b) * u;
            let a = p.a;
            if (p.kind == 0) {
                a *= 1 - t * t * t;
            } else {
                a *= 1 - t * t;
            }
            // keep anything close to the lens from swallowing the screen
            let dx = p.x - ex, dy = p.y - ey, dz = p.z - ez;
            let d = Math.sqrt(dx * dx + dy * dy + dz * dz);
            // keep every sprite under ~1/6 of the view height (glows ~1/8: an
            // additive flash that size already whites out its patch)
            let size = p.size;
            let maxS = p.kind == 1 ? d * 0.075 : d * 0.1;
            if (size > maxS) size = maxS;
            if (d < 9) a *= lmax(0, (d - 3) / 6);
            // big puffs (blast smoke, splash columns) thin out sooner as the
            // pilot flies through where a boss went down, so they never wall
            // off the view (the skim spray is far smaller and unaffected)
            if (p.size > 1.2 && d < 18) a *= lclamp((d - 6) / 12, 0, 1);
            // smoke puffs (ink smoke, flak; not fire, not the small skim
            // spray) erode to wisps near the lens at any time: kill smoke and
            // flak at arm's length walled off the fight view
            if (p.kind == 0 && p.cap >= 1 && p.size > 0.6) {
                let far = LENS_SMOKE + LENS_SMOKE_SIZE * lmin(p.size, 4);
                if (d < far) {
                    let k = lclamp((d - 4) / (far - 4), 0, 1);
                    a *= k * k * (3 - 2 * k);
                }
            }
            if (p.kind == 0 && p.cap < 1 && p.size > 0.5) {
                let far = LENS_FIRE + LENS_FIRE_SIZE * lmin(p.size, 3);
                if (d < far) {
                    let k = lclamp((d - LENS_FIRE0) / (far - LENS_FIRE0), 0, 1);
                    k = k * k * (3 - 2 * k);
                    a *= k;
                    size *= LENS_FIRE_MIN + (1 - LENS_FIRE_MIN) * k;
                }
            }
            if (shot > 0 && d < shot) {
                let k = lclamp((d - shot0) / SHOT_FADE, 0, 1);
                a *= k * k * (3 - 2 * k);
            }
            if (a > 0.01) {
                R.particle(r, p.x, p.y, p.z, size, cr, cg, cb, a, p.kind, lmin(t, p.cap), p.seed, p.rot, p.vx, p.vy, p.vz, p.stretch);
            }
        }
    }
    let b = F.debrisBatch;
    if (b != null) {
        gpu.reset(b);
        let x = F.xf;
        let ds = F.debris;
        for (let i = 1; i < ds.length; i++) {
            let d = ds[i];
            if (d.age < 0) continue;
            // chunks the pilot flies through shrink away before they can
            // fill the lens
            let cx = d.x - ex, cy = d.y - ey, cz = d.z - ez;
            let dd = Math.sqrt(cx * cx + cy * cy + cz * cz);
            let near = lclamp((dd - 5) / 12, 0, 1);
            if (shot > 0) near = lmin(near, lclamp((dd - shot0) / SHOT_FADE, 0, 1));
            let fade = lmin(1, (d.life - d.age) * 3) * near;
            if (fade > 0.02) {
                let ca = Math.cos(d.a), sa = Math.sin(d.a), cb2 = Math.cos(d.b), sb2 = Math.sin(d.b);
                models.aim(x, d.x, d.y, d.z, ca * cb2, sb2, sa * cb2, 0, 1, 0, d.a * 0.7, 1);
                models.putScaled(b, x, d.sx * fade, d.sy * fade, d.sz * fade, d.tr, d.tg, d.tb, 0, 0);
            }
        }
        R.addBatch(r, b);
    }
    // splash crowns and jets: burst up, flare, sink back into the sea
    if ((F.crowns.length > 1 || F.rings.length > 1) && F.crownBatch == null) {
        models.splashBatches();
        F.crownBatch = models.SPLASH_CROWN;
        F.jetBatch = models.SPLASH_JET;
        F.ringBatch = models.SPLASH_RING;
    }
    let cb = F.crownBatch, jb = F.jetBatch, rb = F.ringBatch;
    if (cb != null && jb != null && rb != null) {
        gpu.reset(cb);
        gpu.reset(jb);
        gpu.reset(rb);
        // foam rings race out and melt (a dissolving mesh also melts near
        // the lens, so one sweeping under the camera never bands the view)
        let rings = F.rings;
        for (let i = 1; i < rings.length; i++) {
            let c = rings[i];
            if (c[4] < 0) continue;
            let u = c[4] / c[5];
            let rr = c[3] * (1.2 + 7 * (1 - Math.pow(1 - u, 2.5)));
            let melt = lmax(0.001, Math.pow(lclamp((u - 0.15) / 0.85, 0, 1), 1.3));
            gpu.addBasis(rb, c[1], 0.04, c[2], 1, 0, 0, 0, 1, 0, 0, 0, -1, rr, 1, rr, 1, 1, 1, 0, 0, melt, 0);
        }
        let crowns = F.crowns;
        for (let i = 1; i < crowns.length; i++) {
            let c = crowns[i];
            let x = c[1], z = c[2], s = c[3], age = c[4];
            let cx = x - ex, cz = z - ez;
            let hc = crownH(s);
            let cy = hc * 0.5 - ey;
            let dd = Math.sqrt(cx * cx + cy * cy + cz * cz);
            // the pilot flying through one: it shrinks away before the lens
            let near = lclamp((dd - 3) / 6, 0, 1);
            if (shot > 0) near = lmin(near, lclamp((dd - shot0) / SHOT_FADE, 0, 1));
            if (near > 0.02 && age >= 0) {
                let yaw = c[6];
                let rx = Math.cos(yaw), rz = Math.sin(yaw);
                let u = age / crownLife(s);
                if (u < 1) {
                    let rise = 1 - Math.pow(1 - lmin(u / 0.3, 1), 3);
                    let k = Math.pow(lclamp((u - 0.4) / 0.6, 0, 1), 1.6);
                    let rc = s * (0.5 + 0.55 * (1 - Math.pow(1 - u, 2))) * near;
                    let sy = hc * rise * (1 - 0.5 * k) * near;
                    gpu.addBasis(cb, x, -sy * k, z, rx, 0, rz, 0, 1, 0, rz, 0, -rx, rc, sy, rc, 1, 1, 1, 0, 0, 0, 1);
                }
                if (c[7] > 0) {
                    let uj = (age - JET_DELAY) / jetLife(s);
                    if (uj > 0 && uj < 1) {
                        let rise = 1 - Math.pow(1 - lmin(uj / 0.42, 1), 2.2);
                        let k = Math.pow(lclamp((uj - 0.5) / 0.5, 0, 1), 1.5);
                        let sy = jetH(s) * rise * near;
                        let w = 1.2 * s * near;
                        gpu.addBasis(jb, x, -sy * k, z, rx, 0, rz, 0, 1, 0, rz, 0, -rx, w, sy, w, 1, 1, 1, 0, 0, 0, 1);
                    }
                }
            }
        }
        R.addBatch(r, cb);
        R.addBatch(r, jb);
        R.addBatch(r, rb);
    }
}

// Graphics quality (DIRECTION #27, called by core_quality): 'low' | 'medium' | 'high'.
export function setQuality(F: Fx, level: string): void {
    F.density = level == "low" ? 0.6 : (level == "medium" ? 0.8 : 1.0);
    F.thin = 0;
}

export function count(F: Fx): f64 {
    return <f64>(F.parts.length - 1);
}
