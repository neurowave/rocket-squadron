// Port of src/render/renderer.luau. Frame renderer: owns every GPU target and
// pipeline and composites the result into the scripted layout. Game code only
// queues work:
//
//   addBatch(r, batch)           instanced toon meshes (gpu.Batch)
//   spriteAdd(sprite, ...)       billboards textured with a Rive artboard
//   particle(r, ...)             procedural particles
//   trail(r, trail, time)        camera-facing ribbons from point history
//   portal(r, ...)               swirling vortex discs
//   shadow / foam / wake         water contact shadows, foam spots, pilot wake
//   frame(r, renderer2d, cam, palette, time)
//
// Passes per frame (see docs/notes/render.md):
//   1. artboard canvases (HUD + sprites) via the Rive 2D renderer
//   2. reflection  -> refl (half res, world mirrored about y = 0)
//   3. main (4x MSAA, 2 targets) -> hdr + gbuf (normal, distance):
//        sky, toon, ink hulls, water, portals, sprites, trails, particles, overlays
//   4. bloom: 13-tap down chain (1/2 .. 1/16) + tent upsample back to 1/2
//   5. final: post (ink edges, bloom, grade, fx) + curved visor HUD, straight
//      into Rive's render target (context.gpuTarget(), under all Rive content)
//      when the host exposes one the layout fills; else into a GPUCanvas and
//   6. drawImage of the GPUCanvas into the layout
//   (3.1, mobile tier with render size < output, and desktop HIGH pixel-capped
//   below the output: post's first half runs at the render size into postA
//   (rgba16float), its second half in the final pass at the output size;
//   POST_SPLIT)
//   (JOB 26: on frames where the screens' print plates are up with the visor,
//   the visor is drawn alone into visorOff first; post composites it and prints
//   the frame, HUD included: post.wgsl printPlates)
//
// Port: optional numbers are NaN (nil); multi-returns go through module
// globals (copy them right away); 1-based sequences keep a dummy slot 0.
// No pcall: pipeline / pass failures raise (the Luau fallbacks are gone).
import { Context } from "rive/host";
import { format, FormatArg } from "rive/format";
import { Renderer } from "rive/renderer";
import { Artboard } from "rive/artboard";
import { Canvas } from "rive/canvas";
import { ImageSampler, ImageWrap, ImageFilter } from "rive/image";
import { Path } from "rive/path";
import { Paint, BlendMode } from "rive/paint";
import { Color } from "rive/color";
import { Mat2D } from "rive/mat2d";
import { Mat4 } from "rive/mat4";
import { Vector } from "rive/vector";
import {
    GPUBuffer, GPUCanvas, GPUTarget, GPUTexture, GPUTextureDesc, GPUTextureView, GPUSampler, GPUShaderModule,
    GPUPipeline, GPUPipelineDesc, GPUColorTargetDesc, GPUBlendState, GPUDepthStencilDesc, GPUVertexBufferLayout,
    GPUVertexAttribute, GPUBindGroup, GPUBindGroupUBO, GPUBindGroupTexture, GPUBindGroupSampler,
    GPUPassDesc, GPUColorAttachment, GPURenderPass,
} from "rive/gpu";
import {
    BufferUsage, TextureFormat, VertexFormat, VertexStepMode, CullMode, CompareFunction, BlendFactor, BlendOp,
    Filter, WrapMode, LoadOp, StoreOp, IndexFormat,
} from "rive/gpu_enums";
import * as gpu from "../lib/gpu";
import { Batch, Mesh } from "../lib/gpu";
import * as meshgen from "../lib/meshgen";
import * as mathx from "../lib/mathx";
import { Palette } from "../world/palette";
import * as track from "../world/track";
import { Track } from "../world/track";
import * as level from "../world/level";
import { IMAGE_NAMES } from "./image_names";
import { lclamp, lmax, lmin, mod, HUGE, opt, lrandom } from "../lib/compat";

export class Camera {
    eye: Vector = Vector.xyz(0, 0, 0);
    target: Vector = Vector.xyz(0, 0, -1);
    up: Vector = Vector.xyz(0, 1, 0);
    fov: f64 = 1; // vertical, radians
    near: f64 = 0.3;
    far: f64 = 6000;
}

export class Sprite {
    name: string = "";
    art: Artboard? = null;
    // the shared sprite atlas (every sprite artboard is drawn into one canvas
    // per frame: one Rive flush instead of one per sprite); null until packed
    canvas: Canvas? = null;
    pxW: f64 = 0; // requested texture size
    pxH: f64 = 0;
    buf: GPUBuffer;
    data: ArrayBuffer;
    df: Float32Array; // f32 view of data
    cap: i32 = 0;
    n: i32 = 0;
    reflect: bool = false;
    overlay: bool = false;
    // drawn only in the reflection pass (e.g. the hero's underside twin)
    reflOnly: bool = false;
    // kept for compatibility: the atlas redraws visible sprites every frame
    redraw: bool = true;
    drawn: bool = false;
    // opaque texels write depth + gbuffer (setSpriteSolid): world particles,
    // trails and post ink edges from behind stop at the silhouette
    solid: bool = false;
    // atlas rect (pixels) and clip; vis = some instance is in view this frame
    ax: f64 = 0;
    ay: f64 = 0;
    aw: f64 = 1;
    ah: f64 = 1;
    clip: Path? = null;
    vis: bool = false;
    // content refresh: 1 = every frame, 2 = every other frame (setSpriteRate)
    every: i32 = 1;
    ai: i32 = 1; // atlas index (1 fast, 2 / 3 slow)
    fresh: bool = false; // its atlas holds current content for it

    constructor(cap: i32) {
        this.cap = cap;
        this.data = new ArrayBuffer(cap * 64);
        this.df = Float32Array.wrap(this.data);
        this.buf = new GPUBuffer(BufferUsage.vertex, <u32>(cap * 64));
    }
}

// One shared canvas of sprite artboards, redrawn every `every` frames.
export class Atlas {
    canvas: Canvas? = null;
    w: f64 = 0;
    h: f64 = 0;
    every: i32 = 1;
    phase: i32 = 0;
    bgDirty: bool = true;
    bgMain: GPUBindGroup? = null;
    bgRefl: GPUBindGroup? = null;
    bgOver: GPUBindGroup? = null;
    bgMask: GPUBindGroup? = null;
    constructor(every: i32, phase: i32) {
        this.every = every;
        this.phase = phase;
    }
}

// Point history for a ribbon. Fill with trailPush, draw with trail.
export class Trail {
    cap: i32 = 2;
    n: i32 = 0;
    head: i32 = 0; // index of the newest point (1-based ring)
    xs: Array<f64>;
    ys: Array<f64>;
    zs: Array<f64>;
    ws: Array<f64>;
    ts: Array<f64>;
    kind: f64 = 0; // 0 vapor, 1 exhaust (additive), 2 toon smoke, 3 energy (additive)
    life: f64 = 1; // seconds a point lives
    width: f64 = 1;
    minDist: f64 = 1.5;
    cr: f64 = 1;
    cg: f64 = 1;
    cb: f64 = 1;
    ca: f64 = 1;
    seed: f64 = 0;
    constructor(cap: i32) {
        this.cap = cap;
        this.xs = new Array<f64>(cap + 1);
        this.ys = new Array<f64>(cap + 1);
        this.zs = new Array<f64>(cap + 1);
        this.ws = new Array<f64>(cap + 1);
        this.ts = new Array<f64>(cap + 1);
    }
}

export class PostParams {
    exposure: f64 = 1;
    vignette: f64 = 0.28;
    speedLines: f64 = 0;
    chroma: f64 = 0.15;
    damage: f64 = 0;
    fade: f64 = 0;
    fadeR: f64 = 0;
    fadeG: f64 = 0;
    fadeB: f64 = 0;
    letterbox: f64 = 0;
    saturation: f64 = 1.08;
    contrast: f64 = 1.04;
    warmth: f64 = 0.2;
    grain: f64 = 0.018;
    flashR: f64 = 1;
    flashG: f64 = 1;
    flashB: f64 = 1;
    flash: f64 = 0;
    portal: f64 = 0; // portal dive 0..1 (swirl + zoom blur + tunnel)
    portalX: f64 = 0.5;
    portalY: f64 = 0.5;
    portalR: f64 = 0.2;
    focusX: f64 = 0.5;
    focusY: f64 = 0.45;
    // added with the bloom / ink pass (all optional to touch)
    bloom: f64 = 0.55; // bloom strength
    bloomThreshold: f64 = 1.05; // applied on resize
    edges: f64 = 0.85; // screen-space ink edge strength (0 = off)
    edgeFade: f64 = 900; // meters where ink edges have faded out
    creases: f64 = 0; // screen-space crease ink from normals (0 = off; hulls ink the scenery)
    lens: f64 = 1; // portal lens distortion strength (auto from portal)
    smear: f64 = 1; // periphery zoom smear: a ~0.3 s kick when r.boost reaches 1, then 0.35 while boosting
    autoPortalFocus: bool = true; // aim the dive at the first queued portal
    // set-piece stings (DIRECTION #21), both 0 = off:
    slow: f64 = 0; // bullet-time grade 0..1: desaturate, cobalt halftone vignette, chromatic kiss
    print: f64 = 0; // print flash 0..1 held by the caller (printFlash fires a self-decaying one)
}

export class VisorParams {
    boot: f64 = 1;
    glitch: f64 = 0;
    opacity: f64 = 1;
    tintR: f64 = 0.35;
    tintG: f64 = 0.75;
    tintB: f64 = 1.0;
    tintA: f64 = 0.0;
    scan: f64 = 0.25;
    edgeGlow: f64 = 0.35;
    flicker: f64 = 0;
    chroma: f64 = 0.15;
    // sway, radians / units, driven by the camera rig
    yaw: f64 = 0;
    pitch: f64 = 0;
    roll: f64 = 0;
    push: f64 = 0;
    // added
    glow: f64 = 0.55; // holographic halo around HUD content
    sheen: f64 = 0.05; // diagonal glass highlight
    damageTint: f64 = 0; // red tint on HUD content (post.damage also drives it)
    bowX: f64 = 0.028; // barrel bow of the visor frame (mesh rebuilds when changed)
    bowY: f64 = 0.05;
    curve: f64 = 0.38; // resting helmet curvature: 0 flat .. 1 full wrap (boot and boost add on top)
    rim: f64 = 0.62; // darkness of the glass rim / skirt past the HUD (0..1)
}

// per frame: draw calls, instances, culled single-instance batches (main /
// reflection), sprites drawn into the atlas, particles, trail segments,
// batches on the sky-fade path (main / reflection)
export class Stats {
    draws: i32 = 0;
    instances: i32 = 0;
    culled: i32 = 0;
    culledRefl: i32 = 0;
    sprites: i32 = 0;
    particles: i32 = 0;
    trails: i32 = 0;
    fading: i32 = 0;
    fadingRefl: i32 = 0;
    hudLate: i32 = 0;
    hudAdv: i32 = 0;
    hudCalls: i32 = 0;
}

// The frame's render-pass descriptors, built once per set of target views
// (EFFICIENCY_REVIEW 1.6). The sky clear colours are written each frame into
// the cached attachments.
class PassDescs {
    kRefl: GPUTextureView;
    kReflDepth: GPUTextureView;
    kMsaa: GPUTextureView;
    kMsaaG: GPUTextureView;
    kHdr: GPUTextureView;
    kGbuf: GPUTextureView;
    kDepth: GPUTextureView;
    kSamples: i32;
    kBloomN: i32;
    bloomKey: Array<GPUTextureView> = [];
    reflClear: GPUColorAttachment;
    skyClear: GPUColorAttachment;
    refl: GPUPassDesc;
    main: GPUPassDesc;
    bloomDown: Array<GPUPassDesc> = []; // 1-based
    bloomUp: Array<GPUPassDesc> = []; // 1-based
    constructor(rv: GPUTextureView, rdv: GPUTextureView, mv: GPUTextureView, mgv: GPUTextureView, hv: GPUTextureView,
        gv: GPUTextureView, dv: GPUTextureView, samples: i32, nl: i32, reflClear: GPUColorAttachment,
        skyClear: GPUColorAttachment, refl: GPUPassDesc, main: GPUPassDesc) {
        this.kRefl = rv;
        this.kReflDepth = rdv;
        this.kMsaa = mv;
        this.kMsaaG = mgv;
        this.kHdr = hv;
        this.kGbuf = gv;
        this.kDepth = dv;
        this.kSamples = samples;
        this.kBloomN = nl;
        this.reflClear = reflClear;
        this.skyClear = skyClear;
        this.refl = refl;
        this.main = main;
    }
}

const COLOR_FMT: TextureFormat = TextureFormat.rgba16float;
// where the final pass goes (GPUTARGET.md). auto: Rive's render target when the
// host exposes one the layout covers (direct; blit past maxOutputPixels), else
// the GPUCanvas + drawImage. The other values force one path (A/B).
const FINAL_MODE: string = "auto";
// 3.1, post at render resolution (EFFICIENCY_REVIEW; JOB 25): 'auto' splits post
// on the mobile tier whenever the render size differs from the output (every
// tier of a 3x phone; MED / LOW of a 2x phone), and on desktop HIGH when the
// render size is pixel-capped below the output (JOB 26); 'off' keeps one full-size post
// everywhere; 'force' splits on every size and tier (the exactness test: with
// render size = output size the split must reproduce fs_main)
const POST_SPLIT: string = "auto";
// 3.1 ink on MED / LOW (post.wgsl edgesUpS): a near-side ink weight per tier,
// 0 everywhere: at the render size the line keeps its total ink (JOB 25
// measured 0.15 / 0.3 / 0.5 on ring / rock crops: no visible gain). HIGH takes
// the native ink (the 3.1 look)
function inkSplitBias(_q: string): f64 {
    return 0;
}
const GBUF_FMT: TextureFormat = TextureFormat.rgba16float;
const DEPTH_FMT: TextureFormat = TextureFormat.depth32float;
const FRAME_BYTES: i32 = 448;
const POST_BYTES: i32 = 272;
// the print rollers' tilt (the screens' PrintScreen / StingCard rollers: 0.30 rad)
const ROLL_COS: f64 = Math.cos(0.3);
const ROLL_SIN: f64 = Math.sin(0.3);
const VISOR_BYTES: i32 = 224;
// uv margin of the dark glass skirt around the HUD rect
const VISOR_SKIRT: f64 = 0.14;
// HUD content margin on screen (DIRECTION #20: 4% of each side), in NDC
const VISOR_SAFE: f64 = 0.92;
// softness of the rim-only containment profile (visor.wgsl `contain`)
const VISOR_CONTAIN_E: f64 = 0.3;
// squash the sway alone may cause at the rim (containment pull): linear up to
// the knee, then eased toward the cap; past it the sway itself yields
const VISOR_SWAY_KNEE: f64 = 0.05;
const VISOR_SWAY_CAP: f64 = 0.1;
// NDC the skirt's outer edge is kept past (the dark glass meets the screen edge)
const VISOR_SKIRT_REACH: f64 = 1.02;
const WATER_BYTES: i32 = 1056;
const RAIL_POINTS: i32 = 48;
const RAIL_STEP: f64 = 32;
const RAIL_OFF: f64 = -1e9; // railS: no flight path (s < 0 is the school lane)
const BLOOM_BYTES: i32 = 32;
const BLOOM_LEVELS: i32 = 4;
const MAX_SHADOWS: i32 = 16;
const MAX_SPOTS: i32 = 8;
const WAKE_POINTS: i32 = 16;
const WAKE_STEP: f64 = 4.5;
const TRAIL_STRIDE: i32 = 96;
const PORTAL_STRIDE: i32 = 64;
const GBUF_CLEAR_W: f32 = 60000;

// Graphics quality tiers (DIRECTION #27; docs/notes/render.md "Graphics
// quality"). high = the look above, untouched. Fields: render pixel cap and
// scale, MSAA, bloom levels skipped, reflection divisor, reflection trails, HUD
// rate floor, slow atlas period, contact shadows, water detail.
export class QualityTier {
    pixels: f64;
    scale: f64;
    samples: i32;
    bloom: i32;
    reflDiv: f64;
    reflFx: bool;
    hud: i32;
    slow: i32;
    shadows: i32;
    water: f64;
    constructor(pixels: f64, scale: f64, samples: i32, bloom: i32, reflDiv: f64, reflFx: bool, hud: i32, slow: i32, shadows: i32, water: f64) {
        this.pixels = pixels;
        this.scale = scale;
        this.samples = samples;
        this.bloom = bloom;
        this.reflDiv = reflDiv;
        this.reflFx = reflFx;
        this.hud = hud;
        this.slow = slow;
        this.shadows = shadows;
        this.water = water;
    }
}

export const QUALITY_HIGH = new QualityTier(HUGE, 1, 4, 0, 2, true, 1, 2, MAX_SHADOWS, 1);
export const QUALITY_MEDIUM = new QualityTier(2.6e6, 0.85, 4, 0, 2, true, 1, 2, 12, 1);
export const QUALITY_LOW = new QualityTier(2.07e6, 0.7, 2, 1, 4, false, 2, 4, 8, 0);

export function qualityTier(level: string): QualityTier? {
    if (level == "high") return QUALITY_HIGH;
    if (level == "medium") return QUALITY_MEDIUM;
    if (level == "low") return QUALITY_LOW;
    return null;
}

export class Gfx {
    ctx: Context;
    ok: bool = false;
    // sizes
    ptW: f64 = 0;
    ptH: f64 = 0;
    scale: f64 = 1;
    renderScale: f64 = 1; // resolved on resize: render pixels per point
    maxRenderPixels: f64 = 2560 * 1440; // cap for the main pass resolution
    // mobile tier (phone-class devices: scale >= 2.5, or scale >= 2 with a
    // short side <= 600 pt; decided on the first resize): main pass capped at
    // mobilePixels in either orientation with mobileSamples MSAA.
    // mobileTier 1 / 0 forces it; -1 = auto.
    mobileTier: i32 = -1;
    mobile: bool = false; // resolved on the first resize (device class, never a window drag)
    mobileAuto: i32 = -1; // -1 unresolved, 0 / 1
    mobilePixels: f64 = 1.6e6;
    mobileSamples: i32 = 1;
    maxSamples: i32 = 4;
    rw: f64 = 0;
    rh: f64 = 0;
    ow: f64 = 0;
    oh: f64 = 0;
    samples: i32 = 4;
    // graphics quality (setQuality, DIRECTION #27): 'high' is the look
    // described in docs/notes/render.md; the tiers only lower these
    quality: string = "high";
    qScale: f64 = 1; // main-pass render scale on top of the pixel caps
    qPixels: f64 = HUGE; // main-pass pixel cap
    qSamples: i32 = 4; // MSAA cap
    qBloom: i32 = 0; // bloom levels skipped at the fine end (0: chain starts at 1/2)
    qReflDiv: f64 = 2; // reflection target = render size / qReflDiv
    qReflFx: bool = true; // trails in the reflection pass (particles always)
    qHudEvery: i32 = 1; // adaptive HUD rate floor (2: every other frame)
    qSlowEvery: i32 = 2; // redraw period of the every-other-frame sprite atlases
    qShadows: i32 = MAX_SHADOWS; // contact shadow cap
    qWater: f64 = 1; // water detail (1 full, 0 lite: no crest dashes / glints / fine fray)
    // targets
    canvas: GPUCanvas? = null; // the fallback final target (created on first use)
    // final pass destination (FINAL_MODE): 'auto' | 'canvas' | 'direct' |
    // 'blit'; finalPath: the one the last frame took
    finalMode: string = FINAL_MODE;
    finalPath: string = "";
    noTarget: bool = false; // no render target from this host
    noTargetWhy: string = "";
    tFmt: i32 = -1; // format / sampleCount the target pipelines were built for
    tSamples: i32 = 0;
    // the target the previous frame read (0: none yet; -1: after a hidden
    // frame): a frame whose target changed takes the canvas (finalTarget)
    tPrevW: f64 = 0;
    tPrevH: f64 = 0;
    tPrevFmt: i32 = -1;
    tPrevSc: i32 = 0;
    pPostT: GPUPipeline? = null;
    pVisorT: GPUPipeline? = null;
    pBlitT: GPUPipeline? = null;
    bgCvBlit: GPUBindGroup? = null; // (blit path) samples the canvas; rebuilt when cvGen changes
    bgCvBlitGen: i32 = -1;
    cvGen: i32 = 0; // bumped whenever the canvas is created or resized
    cvW: f64 = 0; // the canvas's size
    cvH: f64 = 0;
    cvIdle: i32 = 0; // direct frames since the canvas was last used
    pathLog: i32 = 0; // final-path log lines printed (capped)
    // JOB 26: the print plates (setPlates), 1-based: PrintScreen red, blue amounts, roller x; sting crimson,
    // dense, blue amounts, roller x; portrait (1: StingCardP's frame)
    plates: Array<f64> = [0.0, 0, 0, 0, 0, 0, 0, 0, 0];
    visorOff: GPUTextureView? = null; // (plates up with the visor) the visor drawn alone; post composites it, then prints
    visorOffDesc: GPUPassDesc? = null;
    visorOffW: f64 = 0;
    visorOffH: f64 = 0;
    visorOffIdle: i32 = 0; // frames since the visor offscreen was last used (released after CANVAS_IDLE)
    visorDummy: GPUTextureView? = null; // bound in its place otherwise (post's binding 6 is always declared)
    visorIn: bool = false; // this frame post composites the visor offscreen (writePost: plate1.w)
    layW: f64 = 0; // the layout's size as resize last saw it (coverLayout)
    layH: f64 = 0;
    tw: f64 = 0; // the target's size this frame (the layout covers it)
    th: f64 = 0;
    fw: f64 = 0; // post / visor output size this frame
    fh: f64 = 0;
    msaaView: GPUTextureView? = null;
    msaaGView: GPUTextureView? = null;
    depthView: GPUTextureView? = null;
    hdrView: GPUTextureView? = null;
    gbufView: GPUTextureView? = null;
    reflView: GPUTextureView? = null;
    reflDepthView: GPUTextureView? = null;
    bloomViews: Array<GPUTextureView?> = [null]; // 1-based
    bloomW: Array<f64> = [0.0];
    bloomH: Array<f64> = [0.0];
    bloomN: i32 = BLOOM_LEVELS; // levels in the chain (BLOOM_LEVELS - qBloom)
    // shaders
    shToon: GPUShaderModule? = null;
    shOutline: GPUShaderModule? = null;
    shSky: GPUShaderModule? = null;
    shWater: GPUShaderModule? = null;
    shBillboard: GPUShaderModule? = null;
    shParticle: GPUShaderModule? = null;
    shPost: GPUShaderModule? = null;
    shVisor: GPUShaderModule? = null;
    shBloom: GPUShaderModule? = null;
    shTrail: GPUShaderModule? = null;
    shPortal: GPUShaderModule? = null;
    shBlit: GPUShaderModule? = null;
    // pipelines
    pToon: GPUPipeline? = null;
    pToonRefl: GPUPipeline? = null;
    pOutline: GPUPipeline? = null;
    // sky-fade path (gpu.setSkyFade): depth prepass, blended shade, hulls
    pToonPre: GPUPipeline? = null;
    pToonFade: GPUPipeline? = null;
    pOutlineFade: GPUPipeline? = null;
    pToonPreRefl: GPUPipeline? = null;
    pToonFadeRefl: GPUPipeline? = null;
    pSky: GPUPipeline? = null;
    pSkyRefl: GPUPipeline? = null;
    pWater: GPUPipeline? = null;
    pBillboard: GPUPipeline? = null;
    pBillboardRefl: GPUPipeline? = null;
    pBillboardMask: GPUPipeline? = null;
    pOverlay: GPUPipeline? = null;
    pParticle: GPUPipeline? = null;
    pParticleRefl: GPUPipeline? = null;
    pTrail: GPUPipeline? = null;
    pTrailRefl: GPUPipeline? = null;
    pPortal: GPUPipeline? = null;
    pPortalRefl: GPUPipeline? = null;
    pBloomDown: GPUPipeline? = null;
    pBloomUp: GPUPipeline? = null;
    pPost: GPUPipeline? = null;
    pVisor: GPUPipeline? = null;
    // 3.1 (post at render resolution, JOB 25): fs_head into postA at the
    // render size, then fs_tail into the final target at the output size
    pPostA: GPUPipeline? = null;
    pPostB: GPUPipeline? = null;
    pPostBT: GPUPipeline? = null; // fs_tail for Rive's render target
    postSplit: bool = false; // this size / tier splits post (applyResize)
    postAView: GPUTextureView? = null;
    postADesc: GPUPassDesc? = null;
    bgPostB: GPUBindGroup? = null;
    // uniforms
    frameData: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
    frameUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
    frameUboRefl: GPUBuffer = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
    postData: ArrayBuffer = new ArrayBuffer(POST_BYTES);
    postUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, <u32>POST_BYTES);
    visorData: ArrayBuffer = new ArrayBuffer(VISOR_BYTES);
    visorUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, <u32>VISOR_BYTES);
    waterData: ArrayBuffer = new ArrayBuffer(WATER_BYTES);
    waterUbo: GPUBuffer = new GPUBuffer(BufferUsage.uniform, <u32>WATER_BYTES);
    bloomUbos: Array<GPUBuffer> = []; // 1-based (slot 0: a placeholder)
    // frame bind groups, one per pipeline (auto layouts are per pipeline)
    bgToon: GPUBindGroup? = null;
    bgToonRefl: GPUBindGroup? = null;
    bgOutline: GPUBindGroup? = null;
    bgToonPre: GPUBindGroup? = null;
    bgToonFade: GPUBindGroup? = null;
    bgOutlineFade: GPUBindGroup? = null;
    bgToonPreRefl: GPUBindGroup? = null;
    bgToonFadeRefl: GPUBindGroup? = null;
    bgSky: GPUBindGroup? = null;
    bgSkyRefl: GPUBindGroup? = null;
    bgWater0: GPUBindGroup? = null;
    bgWater1: GPUBindGroup? = null;
    bgBillboard: GPUBindGroup? = null;
    bgBillboardRefl: GPUBindGroup? = null;
    bgBillboardMask: GPUBindGroup? = null;
    bgOverlay: GPUBindGroup? = null;
    bgParticle: GPUBindGroup? = null;
    bgParticleRefl: GPUBindGroup? = null;
    bgTrail: GPUBindGroup? = null;
    bgTrailRefl: GPUBindGroup? = null;
    bgPortal: GPUBindGroup? = null;
    bgPortalRefl: GPUBindGroup? = null;
    bgBloom: Array<GPUBindGroup?> = []; // 1-based, filled to 2 nl - 1
    bgBloomN: i32 = 0;
    bgPost: GPUBindGroup? = null;
    bgVisor: GPUBindGroup? = null;
    linear: GPUSampler = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.clampToEdge, WrapMode.clampToEdge);
    // geometry
    waterMesh: Mesh? = null;
    visorVB: GPUBuffer? = null;
    visorIB: GPUBuffer? = null;
    visorK: f64 = 0.4;
    visorKT: f64 = 0;
    visorCount: i32 = 0;
    visorAspect: f64 = 0;
    visorBowX: f64 = -1;
    visorBowY: f64 = -1;
    visorAx: f64 = 1; // fitted shell section (buildVisor), for the CPU copy of vs_main
    visorAy: f64 = 0.5;
    visorWrap: f64 = 0;
    visorTanV: f64 = 0.6;
    visorRing: Array<f64>? = null; // HUD uv pairs that sit on the 4% screen margin at rest (1-based)
    visorRingK: f64 = -1;
    // HUD
    hudArt: Artboard? = null;
    hudCanvas: Canvas? = null;
    hudW: f64 = 1920;
    hudH: f64 = 1080;
    hudScale: f64 = 1;
    maxHudScale: f64 = 3; // HUD texels per HUD unit cap (the visor filters it anyway)
    maxHudPixels: f64 = 4.7e6; // HUD canvas pixel budget (portrait phones get full resolution too)
    // sprite atlases: [1] redrawn every frame, [2] / [3] every other frame on
    // alternate frames (wingmen, reflection twin); atlas / atlasW / atlasH mirror [1]
    atlases: Array<Atlas> = [new Atlas(1, 0), new Atlas(1, 0), new Atlas(2, 1), new Atlas(2, 0)];
    frameN: i32 = 0;
    // redraw the HUD canvas every N frames; 0 = adaptive: every frame while
    // the frame rate holds ~60 fps (and always during the HUD boot / glitch),
    // every other frame (alternating with atlas 2) when it does not, ~60 Hz
    // on high-refresh displays
    hudEvery: f64 = 0;
    // first-use warm-up: every image asset (image_names) is drawn once into a
    // tiny offscreen canvas over the first frames (QA L28)
    warmI: i32 = 1;
    warmCanvas: Canvas? = null;
    no2d: bool = false; // offscreen canvases unavailable (immediate mode)
    noGpu: bool = false;
    gpuChecked: bool = false;
    hudFast: bool = true;
    hudHold: f64 = 0;
    hudBackoff: f64 = 2;
    dtAvg: f64 = 1.0 / 60;
    hudDirty: bool = true;
    atlas: Canvas? = null;
    atlasW: f64 = 0;
    atlasH: f64 = 0;
    atlasDirty: bool = true;
    atlasBgDirty: bool = true;
    bgAtlasMain: GPUBindGroup? = null;
    bgAtlasRefl: GPUBindGroup? = null;
    bgAtlasOver: GPUBindGroup? = null;
    bgAtlasMask: GPUBindGroup? = null;
    spriteDensity: f64 = 1; // atlas texels per artboard unit at 1080p (caps oversized requests)
    maxOutputPixels: f64 = 2560 * 1440 * 1.6; // cap for the post / visor output canvas
    tanHalfV: f64 = 0.6;
    tanHalfH: f64 = 1;
    lensDist: f64 = 0; // lens ripple gate distance (post): only the sky beyond it ripples
    nearFade: f64 = 0; // > 0: moving instances within this many meters of the lens fade out (death cam)
    // queues
    batches: Array<Batch> = [];
    sprites: Array<Sprite> = [];
    partData: ArrayBuffer = new ArrayBuffer(6000 * 64);
    partF: Float32Array;
    partBuf: GPUBuffer = new GPUBuffer(BufferUsage.vertex, 6000 * 64);
    partCap: i32 = 6000;
    partN: i32 = 0;
    trailData: ArrayBuffer = new ArrayBuffer(2048 * TRAIL_STRIDE);
    trailF: Float32Array;
    trailBuf: GPUBuffer = new GPUBuffer(BufferUsage.vertex, <u32>(2048 * TRAIL_STRIDE));
    trailCap: i32 = 2048;
    trailN: i32 = 0;
    portalData: ArrayBuffer = new ArrayBuffer(4 * PORTAL_STRIDE);
    portalF: Float32Array;
    portalBuf: GPUBuffer = new GPUBuffer(BufferUsage.vertex, <u32>(4 * PORTAL_STRIDE));
    portalCap: i32 = 4;
    portalN: i32 = 0;
    shadows: Array<f64> = new Array<f64>(MAX_SHADOWS * 4 + 1); // packed x, z, radius, strength (1-based)
    shadowN: i32 = 0;
    spots: Array<f64> = new Array<f64>(MAX_SPOTS * 4 + 1);
    spotN: i32 = 0;
    // pilot wake: explicit wake this frame, else the first 'pilot' sprite instance
    wakeSet: bool = false;
    wakeX: f64 = 0;
    wakeY: f64 = 100;
    wakeZ: f64 = 0;
    wakeStr: f64 = 0;
    wakeHist: Array<f64> = new Array<f64>(WAKE_POINTS * 4 + 1); // packed x, y, z, strength (newest first, 1-based)
    wakeHistN: i32 = 0;
    autoShadows: bool = true;
    autoWake: bool = true;
    // flight path the water foam streams along (setRail; defaults to the level)
    rail: Track? = level.track;
    railS: f64 = RAIL_OFF;
    pendW: f64 = NaN;
    pendH: f64 = NaN;
    pendS: f64 = NaN;
    pendAt: f64 = 0;
    // params
    post: PostParams = new PostParams();
    visor: VisorParams = new VisorParams();
    time: f64 = 0;
    lastTime: f64 = -1;
    speed: f64 = 0; // m/s, estimated from the camera
    boost: f64 = 0; // 0..1, optional hint from the game
    boostPrev: f64 = 0;
    smearKick: f64 = 0; // 1 at boost start, gone after ~0.3 s (post zoom smear)
    // print flash (printFlash): strength, length (s), start time, plate angle
    printKick: f64 = 0;
    printDur: f64 = 0.5;
    printT0: f64 = -100;
    printAng: f64 = 0.6;
    flowX: f64 = 0;
    flowZ: f64 = -1;
    reflStrength: f64 = 1;
    // camera basis of the current frame (for game-side projection)
    viewProj: Mat4 = Mat4.identity();
    // per-frame storage reused every frame (EFFICIENCY_REVIEW 1.6)
    ivpM: Mat4 = Mat4.identity();
    vpRM: Mat4 = Mat4.identity();
    ivpRM: Mat4 = Mat4.identity();
    mirrorM: Mat4 = Mat4.fromScale(1, -1, 1);
    identM: Mat4 = Mat4.identity();
    projM: Mat4 = Mat4.identity();
    viewM: Mat4 = Mat4.identity();
    viewRotM: Mat4 = Mat4.identity();
    vpRotM: Mat4 = Mat4.identity();
    vpRotRM: Mat4 = Mat4.identity();
    passDescs: PassDescs? = null;
    finalDesc: GPUPassDesc;
    compSampler: ImageSampler = ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear);
    coverPaths: Array<Path?> = [null, null, null, null, null]; // frames with no 3D (1-based)
    coverPaints: Array<Paint?> = [null, null, null, null, null];
    camRight: Vector = Vector.xyz(1, 0, 0);
    camUp: Vector = Vector.xyz(0, 1, 0);
    camFwd: Vector = Vector.xyz(0, 0, -1);
    camEye: Vector = Vector.xyz(0, 0, 0);
    stats: Stats = new Stats();
    hudLag: f64 = 0; // seconds of HUD time not yet advanced (2.1: hudAdvance)

    constructor(ctx: Context) {
        this.ctx = ctx;
        this.partF = Float32Array.wrap(this.partData);
        this.trailF = Float32Array.wrap(this.trailData);
        this.portalF = Float32Array.wrap(this.portalData);
        this.shadows.fill(0);
        this.spots.fill(0);
        this.wakeHist.fill(0);
        let ca = new GPUColorAttachment();
        ca.clearA = 1;
        let fd = new GPUPassDesc();
        fd.color = [ca];
        this.finalDesc = fd;
    }
}

// Queues ---------------------------------------------------------------------

export function addBatch(r: Gfx, b: Batch): void {
    if (b.n > 0) r.batches.push(b);
}

// kind: 0 toon puff (warm colors burn from white-hot to smoke), 1 additive glow
// (stretched = laser bolt), 2 ring, 3 hard disc, 4 twinkle star (additive),
// 5 foam splash blob. Color straight alpha.
export function particle(
    r: Gfx,
    x: f64, y: f64, z: f64, size: f64,
    cr: f64, cg: f64, cb: f64, ca: f64,
    kind: f64, age: f64, seed: f64, rot: f64,
    vx: f64 = 0, vy: f64 = 0, vz: f64 = 0, stretch: f64 = 0
): void {
    if (r.partN >= r.partCap) return;
    let d = r.partF;
    let o = r.partN * 16;
    d[o] = <f32>x;
    d[o + 1] = <f32>y;
    d[o + 2] = <f32>z;
    d[o + 3] = <f32>size;
    d[o + 4] = <f32>cr;
    d[o + 5] = <f32>cg;
    d[o + 6] = <f32>cb;
    d[o + 7] = <f32>ca;
    d[o + 8] = <f32>vx;
    d[o + 9] = <f32>vy;
    d[o + 10] = <f32>vz;
    d[o + 11] = <f32>stretch;
    d[o + 12] = <f32>kind;
    d[o + 13] = <f32>age;
    d[o + 14] = <f32>seed;
    d[o + 15] = <f32>rot;
    r.partN += 1;
}

// Blob contact shadow on the water (x, z world; radius m; strength 0..1).
// Up to 16 per frame. World sprites (reflect = true, not overlay) get one
// automatically while r.autoShadows is true.
export function shadow(r: Gfx, x: f64, z: f64, radius: f64, strength: f64): void {
    if (r.shadowN >= r.qShadows || strength <= 0.001) return;
    let o = r.shadowN * 4;
    let s = r.shadows;
    s[o + 1] = x;
    s[o + 2] = z;
    s[o + 3] = radius;
    s[o + 4] = strength;
    r.shadowN += 1;
}

// Churning foam disc on the water (waterfall pools, splashes). Up to 8 per frame.
export function foam(r: Gfx, x: f64, z: f64, radius: f64, strength: f64): void {
    if (r.spotN >= MAX_SPOTS || strength <= 0.001) return;
    let o = r.spotN * 4;
    let s = r.spots;
    s[o + 1] = x;
    s[o + 2] = z;
    s[o + 3] = radius;
    s[o + 4] = strength;
    r.spotN += 1;
}

// Pilot position for the V wake + downwash rings. Optional: without it the
// renderer follows the first instance of the sprite named 'pilot'.
// strength (NaN) defaults from altitude (full below ~2.5 m, gone above ~7 m).
export function wake(r: Gfx, x: f64, y: f64, z: f64, strength: f64 = NaN): void {
    r.wakeSet = true;
    r.wakeX = x;
    r.wakeY = y;
    r.wakeZ = z;
    r.wakeStr = isNaN(strength) ? 1 - mathx.smoothstep(2.5, 7.0, y) : strength;
}

// JOB 26: the print plates, from the screens' keyed plate opacities and roller x (the game reads them back from the
// view model in its draw, right before frame: src/game/core_print). Amounts 0..1 (already multiplied by
// their keyed parents), roller x in artboard units, portrait = StingCardP. Printed in post after the visor
// (post.wgsl printPlates), in the old layers' order: PrintScreen red, blue; sting crimson, dense, blue.
export function setPlates(r: Gfx, psRed: f64, psBlue: f64, psRollX: f64, stCrim: f64, stDense: f64,
    stBlue: f64, stRollX: f64, portrait: bool): void {
    let p = r.plates;
    p[1] = psRed;
    p[2] = psBlue;
    p[3] = psRollX;
    p[4] = stCrim;
    p[5] = stDense;
    p[6] = stBlue;
    p[7] = stRollX;
    p[8] = portrait ? 1 : 0;
}

function platesOn(r: Gfx): bool {
    let p = r.plates;
    return p[1] > 0 || p[2] > 0 || p[4] > 0 || p[5] > 0 || p[6] > 0;
}

// Print flash (set-piece sting slams): the frame is re-printed for a beat as
// two misregistered halftone plates (crimson + cobalt on cream) that slide
// back into register and dissolve into the color image. amount 0..1
// (default 1), seconds (default 0.5). Runs on the time given to frame.
// For a held look, drive r.post.print directly instead.
export function printFlash(r: Gfx, amount: f64 = 1, seconds: f64 = 0.5): void {
    r.printKick = lclamp(amount, 0, 1);
    r.printDur = lmax(seconds, 0.05);
    r.printT0 = r.time;
    // a new plate direction every slam (never the same diagonal twice)
    r.printAng = mod(r.printAng + 2.39996, Math.PI * 2);
}

// Swirling vortex portal facing (fx, fy, fz). radius in meters; intensity 0..1
// opens it (0 closed). t drives the swirl (seconds). Up to 4 per frame.
// spin: +1 / -1 swirl direction; tr, tg, tb: rim color multiplier.
export function portal(
    r: Gfx,
    x: f64, y: f64, z: f64,
    radius: f64,
    fx: f64, fy: f64, fz: f64,
    t: f64,
    intensity: f64,
    spin: f64 = 1, tr: f64 = 1, tg: f64 = 1, tb: f64 = 1
): void {
    if (r.portalN >= r.portalCap) return;
    let d = r.portalF;
    let o = r.portalN * 16;
    d[o] = <f32>x;
    d[o + 1] = <f32>y;
    d[o + 2] = <f32>z;
    d[o + 3] = <f32>radius;
    d[o + 4] = <f32>fx;
    d[o + 5] = <f32>fy;
    d[o + 6] = <f32>fz;
    d[o + 7] = <f32>t;
    d[o + 8] = <f32>intensity;
    d[o + 9] = <f32>spin;
    d[o + 10] = <f32>r.portalN;
    d[o + 11] = 0;
    d[o + 12] = <f32>tr;
    d[o + 13] = <f32>tg;
    d[o + 14] = <f32>tb;
    d[o + 15] = 0;
    r.portalN += 1;
}

// Trails ---------------------------------------------------------------------

// kind: 0 vapor, 1 exhaust (additive, white-hot core), 2 toon smoke, 3 energy.
// life: seconds a point lives; width in meters; minDist: meters between points.
export function newTrail(cap: i32, kind: f64, life: f64, width: f64, cr: f64, cg: f64, cb: f64, ca: f64, minDist: f64 = 1.5): Trail {
    let c = max(2, cap);
    let t = new Trail(c);
    t.xs.fill(0);
    t.ys.fill(0);
    t.zs.fill(0);
    t.ws.fill(0);
    t.ts.fill(0);
    t.kind = kind;
    t.life = life;
    t.width = width;
    t.minDist = minDist;
    t.cr = cr;
    t.cg = cg;
    t.cb = cb;
    t.ca = ca;
    t.seed = lrandom() * 100;
    return t;
}

export function trailClear(tr: Trail): void {
    tr.n = 0;
    tr.head = 0;
}

// Record the emitter position. Adds a point once it moved minDist from the
// previous one, otherwise slides the newest point (the ribbon stays attached).
export function trailPush(tr: Trail, x: f64, y: f64, z: f64, time: f64, width: f64 = NaN): void {
    let w = opt(width, tr.width);
    if (tr.n >= 2) {
        let h = tr.head;
        let p = h == 1 ? tr.cap : h - 1;
        let dx = x - tr.xs[p], dy = y - tr.ys[p], dz = z - tr.zs[p];
        if (dx * dx + dy * dy + dz * dz < tr.minDist * tr.minDist) {
            tr.xs[h] = x;
            tr.ys[h] = y;
            tr.zs[h] = z;
            tr.ws[h] = w;
            tr.ts[h] = time;
            return;
        }
    }
    let h = (tr.head % tr.cap) + 1;
    tr.head = h;
    tr.xs[h] = x;
    tr.ys[h] = y;
    tr.zs[h] = z;
    tr.ws[h] = w;
    tr.ts[h] = time;
    tr.n = min(tr.n + 1, tr.cap);
}

// One raw ribbon segment (straight alpha color). u0 / u1: age 0 (head) .. 1 (tail).
// Optional tangents (NaN = the segment direction) at both ends keep joints seamless.
export function ribbon(
    r: Gfx,
    x0: f64, y0: f64, z0: f64, w0: f64, a0: f64,
    x1: f64, y1: f64, z1: f64, w1: f64, a1: f64,
    cr: f64, cg: f64, cb: f64, ca: f64,
    kind: f64, u0: f64, u1: f64,
    tx0: f64 = NaN, ty0: f64 = NaN, tz0: f64 = NaN, tx1: f64 = NaN, ty1: f64 = NaN, tz1: f64 = NaN, seed: f64 = 0
): void {
    if (r.trailN >= r.trailCap) return;
    let d = r.trailF;
    let o = r.trailN * 24;
    let dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
    d[o] = <f32>x0;
    d[o + 1] = <f32>y0;
    d[o + 2] = <f32>z0;
    d[o + 3] = <f32>w0;
    d[o + 4] = <f32>x1;
    d[o + 5] = <f32>y1;
    d[o + 6] = <f32>z1;
    d[o + 7] = <f32>w1;
    d[o + 8] = <f32>opt(tx0, dx);
    d[o + 9] = <f32>opt(ty0, dy);
    d[o + 10] = <f32>opt(tz0, dz);
    d[o + 11] = <f32>a0;
    d[o + 12] = <f32>opt(tx1, dx);
    d[o + 13] = <f32>opt(ty1, dy);
    d[o + 14] = <f32>opt(tz1, dz);
    d[o + 15] = <f32>a1;
    d[o + 16] = <f32>cr;
    d[o + 17] = <f32>cg;
    d[o + 18] = <f32>cb;
    d[o + 19] = <f32>ca;
    d[o + 20] = <f32>kind;
    d[o + 21] = <f32>u0;
    d[o + 22] = <f32>u1;
    d[o + 23] = <f32>seed;
    r.trailN += 1;
}

// Queue a trail for this frame. Points older than life fade out; alpha scales all.
// fadeIn (m, NaN = none): the ribbon ramps in from 0 over that length from its head.
export function trail(r: Gfx, tr: Trail, time: f64, alpha: f64 = 1, fadeIn: f64 = NaN): void {
    let n = tr.n;
    if (n < 2) return;
    let cap = tr.cap;
    let al = alpha;
    let xs = tr.xs, ys = tr.ys, zs = tr.zs;
    // walk newest -> oldest
    let idx = tr.head;
    let prev = idx;
    let fi = opt(fadeIn, 0);
    let dist = 0.0;
    for (let k = 1; k <= n - 1; k++) {
        let i0 = idx;
        let i1 = idx == 1 ? cap : idx - 1;
        let age0 = (time - tr.ts[i0]) / tr.life;
        let age1 = (time - tr.ts[i1]) / tr.life;
        if (age0 >= 1) break;
        let a0 = al, a1 = age1 >= 1 ? 0.0 : al;
        if (fi > 0) {
            let sx = xs[i1] - xs[i0], sy = ys[i1] - ys[i0], sz = zs[i1] - zs[i0];
            let d1 = dist + Math.sqrt(sx * sx + sy * sy + sz * sz);
            a0 *= lmin(1, dist / fi);
            a1 *= lmin(1, d1 / fi);
            dist = d1;
        }
        // central-difference tangents (pointing toward the tail) for seamless joints
        let tx0 = xs[i1] - xs[prev], ty0 = ys[i1] - ys[prev], tz0 = zs[i1] - zs[prev];
        let tx1 = xs[i1] - xs[i0], ty1 = ys[i1] - ys[i0], tz1 = zs[i1] - zs[i0];
        if (k + 1 <= n - 1) {
            let i2 = i1 == 1 ? cap : i1 - 1;
            tx1 = xs[i2] - xs[i0];
            ty1 = ys[i2] - ys[i0];
            tz1 = zs[i2] - zs[i0];
        }
        ribbon(
            r,
            xs[i0], ys[i0], zs[i0], tr.ws[i0], a0,
            xs[i1], ys[i1], zs[i1], tr.ws[i1], a1,
            tr.cr, tr.cg, tr.cb, tr.ca,
            tr.kind, age0, lmin(age1, 1),
            tx0, ty0, tz0, tx1, ty1, tz1, tr.seed
        );
        prev = i0;
        idx = i1;
    }
}

// Projection helper for game code: world -> normalized screen (0..1, y down) and
// depth, through PROJ_U / PROJ_V / PROJ_W (-1, -1, -1 behind the eye).
export let PROJ_U: f64 = 0;
export let PROJ_V: f64 = 0;
export let PROJ_W: f64 = 0;
const T4: StaticArray<f32> = new StaticArray<f32>(4);
export function project(r: Gfx, x: f64, y: f64, z: f64): void {
    xform4(r.viewProj, <f32>x, <f32>y, <f32>z, 1);
    let cx = <f64>T4[0], cy = <f64>T4[1], cw = <f64>T4[3];
    if (cw <= 0.0001) {
        PROJ_U = -1;
        PROJ_V = -1;
        PROJ_W = -1;
        return;
    }
    PROJ_U = (cx / cw) * 0.5 + 0.5;
    PROJ_V = 0.5 - (cy / cw) * 0.5;
    PROJ_W = cw;
}

// Construction ---------------------------------------------------------------

function blendState(sc: BlendFactor, dc: BlendFactor, co: BlendOp, sa: BlendFactor, da: BlendFactor, ao: BlendOp): GPUBlendState {
    let b = new GPUBlendState();
    b.srcColor = sc;
    b.dstColor = dc;
    b.colorOp = co;
    b.srcAlpha = sa;
    b.dstAlpha = da;
    b.alphaOp = ao;
    return b;
}

const PREMUL: GPUBlendState = blendState(BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendOp.add, BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendOp.add);
// leaves the target untouched (transparent passes must not write the gbuffer)
const KEEP: GPUBlendState = blendState(BlendFactor.zero, BlendFactor.one, BlendOp.add, BlendFactor.zero, BlendFactor.one, BlendOp.add);
// gbuffer "no ink here" mark from translucent layers: the fragment writes
// (3, 3, 3, m) with m = 1 where it is opaque enough; normals become the mark
// (post skips edges there), the distance channel is kept
const MARK: GPUBlendState = blendState(BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendOp.add, BlendFactor.zero, BlendFactor.one, BlendOp.add);
// straight alpha over (sky-fade path); alpha accumulates like coverage so
// the reflection target keeps marking mirrored objects for the water
const OVER: GPUBlendState = blendState(BlendFactor.srcAlpha, BlendFactor.oneMinusSrcAlpha, BlendOp.add, BlendFactor.one, BlendFactor.oneMinusSrcAlpha, BlendOp.add);
// reflection sky-fade path: the prepass leaves color alone and writes the
// object / rock mark (toon.wgsl reflAlpha) as max(dst, src); the blended
// fade pass then keeps that alpha
const REFL_PRE: GPUBlendState = blendState(BlendFactor.zero, BlendFactor.one, BlendOp.add, BlendFactor.one, BlendFactor.one, BlendOp.max);
const REFL_FADE: GPUBlendState = blendState(BlendFactor.srcAlpha, BlendFactor.oneMinusSrcAlpha, BlendOp.add, BlendFactor.zero, BlendFactor.one, BlendOp.add);
const ADD: GPUBlendState = blendState(BlendFactor.one, BlendFactor.one, BlendOp.add, BlendFactor.one, BlendFactor.one, BlendOp.add);

function f4Layout(stride: u32, n: i32): GPUVertexBufferLayout {
    let l = new GPUVertexBufferLayout();
    l.stride = stride;
    l.stepMode = VertexStepMode.instance;
    let a: Array<GPUVertexAttribute> = [];
    for (let i = 0; i < n; i++) a.push(new GPUVertexAttribute(VertexFormat.float4, <u32>i, <u32>(i * 16)));
    l.attributes = a;
    return l;
}

const BB_LAYOUT: GPUVertexBufferLayout = f4Layout(64, 4);
const PART_LAYOUT: GPUVertexBufferLayout = BB_LAYOUT;
const PORTAL_LAYOUT: GPUVertexBufferLayout = BB_LAYOUT;
const TRAIL_LAYOUT: GPUVertexBufferLayout = f4Layout(96, 6);

function waterLayout(): GPUVertexBufferLayout {
    let l = new GPUVertexBufferLayout();
    l.stride = 32;
    l.attributes = [new GPUVertexAttribute(VertexFormat.float3, 0, 0)];
    return l;
}
const WATER_LAYOUT: GPUVertexBufferLayout = waterLayout();

function visorLayout(): GPUVertexBufferLayout {
    let l = new GPUVertexBufferLayout();
    l.stride = 32;
    l.attributes = [
        new GPUVertexAttribute(VertexFormat.float3, 0, 0),
        new GPUVertexAttribute(VertexFormat.float3, 1, 12),
        new GPUVertexAttribute(VertexFormat.float2, 2, 24),
    ];
    return l;
}
const VISOR_LAYOUT: GPUVertexBufferLayout = visorLayout();

function ct(fmt: TextureFormat, blend: GPUBlendState? = null): GPUColorTargetDesc {
    let c = new GPUColorTargetDesc();
    c.format = fmt;
    c.blend = blend;
    return c;
}

// main-pass color targets: scene color + gbuffer (normal xyz, distance)
function mainTargets(blend: GPUBlendState?, gbufWrite: bool): Array<GPUColorTargetDesc> {
    return [ct(COLOR_FMT, blend), ct(GBUF_FMT, gbufWrite ? null : KEEP)];
}

// bias NaN = none (Luau nil)
function depthDesc(compare: CompareFunction, write: bool, bias: f64 = NaN): GPUDepthStencilDesc {
    let d = new GPUDepthStencilDesc();
    d.format = DEPTH_FMT;
    d.compare = compare;
    d.write = write;
    d.depthBias = isNaN(bias) ? 0 : <i32>bias;
    d.depthBiasSlopeScale = isNaN(bias) ? 0 : 2.5;
    return d;
}

function pipeDesc(sh: GPUShaderModule, frag: string, vbs: Array<GPUVertexBufferLayout>, targets: Array<GPUColorTargetDesc>): GPUPipelineDesc {
    let d = new GPUPipelineDesc();
    d.vertexModule = sh;
    d.fragmentModule = sh;
    d.fragmentEntryPoint = frag;
    d.vertexBuffers = vbs;
    d.colorTargets = targets;
    return d;
}

function meshPipeline(sh: GPUShaderModule, samples: i32, cull: CullMode, depthWrite: bool, compare: CompareFunction, refl: bool, gbufWrite: bool, bias: f64 = NaN): GPUPipeline {
    let d = pipeDesc(sh, refl ? "fs_refl" : "fs_main", [gpu.MESH_LAYOUT, gpu.INSTANCE_LAYOUT], refl ? [ct(COLOR_FMT)] : mainTargets(null, gbufWrite));
    d.depthStencil = depthDesc(compare, depthWrite, bias);
    d.cullMode = cull;
    d.sampleCount = <u32>samples;
    return new GPUPipeline(d);
}

// toon / hull pipeline with an explicit fragment entry and targets (sky-fade path)
function fadePipeline(sh: GPUShaderModule, entry: string, samples: i32, cull: CullMode, depthWrite: bool, compare: CompareFunction, targets: Array<GPUColorTargetDesc>, bias: f64 = NaN): GPUPipeline {
    let d = pipeDesc(sh, entry, [gpu.MESH_LAYOUT, gpu.INSTANCE_LAYOUT], targets);
    d.depthStencil = depthDesc(compare, depthWrite, bias);
    d.cullMode = cull;
    d.sampleCount = <u32>samples;
    return new GPUPipeline(d);
}

function skyPipeline(sh: GPUShaderModule, samples: i32, refl: bool): GPUPipeline {
    let d = pipeDesc(sh, refl ? "fs_refl" : "fs_main", [], refl ? [ct(COLOR_FMT)] : mainTargets(null, true));
    d.depthStencil = depthDesc(CompareFunction.lessEqual, false);
    d.sampleCount = <u32>samples;
    return new GPUPipeline(d);
}

function quadPipeline(sh: GPUShaderModule, layout: GPUVertexBufferLayout, samples: i32, compare: CompareFunction, refl: bool): GPUPipeline {
    let d = pipeDesc(sh, refl ? "fs_refl" : "fs_main", [layout], refl ? [ct(COLOR_FMT, PREMUL)] : [ct(COLOR_FMT, PREMUL), ct(GBUF_FMT, MARK)]);
    d.depthStencil = depthDesc(compare, false);
    d.cullMode = CullMode.none;
    d.sampleCount = <u32>samples;
    return new GPUPipeline(d);
}

function frameBG(p: GPUPipeline?, ubo: GPUBuffer): GPUBindGroup? {
    if (p == null) return null;
    return new GPUBindGroup(p.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)]);
}

function log(r: Gfx, s: string): void {
    r.ctx.log(s);
}

// Main-pass pipelines (MSAA sample count baked in) and their frame bind
// groups; rebuilt when the quality tier changes the sample count.
function buildMsPipelines(r: Gfx, ms: i32): void {
    let sT = r.shToon, sO = r.shOutline, sS = r.shSky, sW = r.shWater, sB = r.shBillboard, sP = r.shParticle, sTr = r.shTrail, sPt = r.shPortal;
    if (sT == null || sO == null || sS == null || sW == null || sB == null || sP == null || sTr == null || sPt == null) return;
    r.pToon = meshPipeline(sT, ms, CullMode.back, true, CompareFunction.less, false, true);
    // hulls pushed back in depth so they never z-fight faces of intersecting parts
    r.pOutline = meshPipeline(sO, ms, CullMode.front, true, CompareFunction.less, false, false, 60);
    // sky-fade path: depth only, then the front surface blended over what
    // the sky / water already drew behind it, then its thinning hull
    r.pToonPre = fadePipeline(sT, "fs_pre", ms, CullMode.back, true, CompareFunction.less, [ct(COLOR_FMT, KEEP), ct(GBUF_FMT, KEEP)]);
    r.pToonFade = fadePipeline(sT, "fs_fade", ms, CullMode.back, false, CompareFunction.lessEqual, [ct(COLOR_FMT, OVER), ct(GBUF_FMT)]);
    r.pOutlineFade = fadePipeline(sO, "fs_fade", ms, CullMode.front, false, CompareFunction.less, [ct(COLOR_FMT, OVER), ct(GBUF_FMT, KEEP)], 60);
    r.pSky = skyPipeline(sS, ms, false);
    let dw = pipeDesc(sW, "", [WATER_LAYOUT], mainTargets(null, true));
    dw.depthStencil = depthDesc(CompareFunction.less, true);
    dw.cullMode = CullMode.none;
    dw.sampleCount = <u32>ms;
    r.pWater = new GPUPipeline(dw);
    r.pBillboard = quadPipeline(sB, BB_LAYOUT, ms, CompareFunction.less, false);
    // solid sprites: depth + gbuffer where the texture is opaque, color untouched
    let dm = pipeDesc(sB, "fs_mask", [BB_LAYOUT], [ct(COLOR_FMT, KEEP), ct(GBUF_FMT)]);
    dm.depthStencil = depthDesc(CompareFunction.less, true);
    dm.cullMode = CullMode.none;
    dm.sampleCount = <u32>ms;
    r.pBillboardMask = new GPUPipeline(dm);
    r.pOverlay = quadPipeline(sB, BB_LAYOUT, ms, CompareFunction.always, false);
    r.pParticle = quadPipeline(sP, PART_LAYOUT, ms, CompareFunction.less, false);
    r.pTrail = quadPipeline(sTr, TRAIL_LAYOUT, ms, CompareFunction.less, false);
    r.pPortal = quadPipeline(sPt, PORTAL_LAYOUT, ms, CompareFunction.less, false);
    r.bgToon = frameBG(r.pToon, r.frameUbo);
    r.bgOutline = frameBG(r.pOutline, r.frameUbo);
    r.bgToonPre = frameBG(r.pToonPre, r.frameUbo);
    r.bgToonFade = frameBG(r.pToonFade, r.frameUbo);
    r.bgOutlineFade = frameBG(r.pOutlineFade, r.frameUbo);
    r.bgSky = frameBG(r.pSky, r.frameUbo);
    r.bgWater0 = frameBG(r.pWater, r.frameUbo);
    r.bgBillboard = frameBG(r.pBillboard, r.frameUbo);
    r.bgBillboardMask = frameBG(r.pBillboardMask, r.frameUbo);
    r.bgOverlay = frameBG(r.pOverlay, r.frameUbo);
    r.bgParticle = frameBG(r.pParticle, r.frameUbo);
    r.bgTrail = frameBG(r.pTrail, r.frameUbo);
    r.bgPortal = frameBG(r.pPortal, r.frameUbo);
}

// (Luau R.new)
// A shader asset is named by its file path in an RML project (src/render/toon),
// by its bare name in a script-only one (the phase 3 demo).
function shaderAt(ctx: Context, n: string): GPUShaderModule? {
    let m = ctx.shader(n);
    return m != null ? m : ctx.shader("src/render/" + n);
}

export function create(ctx: Context): Gfx {
    let r = new Gfx(ctx);
    r.shToon = shaderAt(ctx, "toon");
    r.shOutline = shaderAt(ctx, "outline");
    r.shSky = shaderAt(ctx, "sky");
    r.shWater = shaderAt(ctx, "water");
    r.shBillboard = shaderAt(ctx, "billboard");
    r.shParticle = shaderAt(ctx, "particle");
    r.shPost = shaderAt(ctx, "post");
    r.shVisor = shaderAt(ctx, "visor");
    r.shBloom = shaderAt(ctx, "bloom");
    r.shTrail = shaderAt(ctx, "trail");
    r.shPortal = shaderAt(ctx, "portal");
    r.shBlit = shaderAt(ctx, "blit");

    let feats = ctx.features();
    r.maxSamples = <i32>feats.maxSamples;
    // (0: the MSAA pipeline set is built on the first resize, once its
    // sample count is known, EFFICIENCY_REVIEW 1.11)
    r.samples = 0;

    let sT = r.shToon, sO = r.shOutline, sS = r.shSky, sW = r.shWater, sB = r.shBillboard, sP = r.shParticle, sPo = r.shPost, sV = r.shVisor;
    let sBl = r.shBloom, sTr = r.shTrail, sPt = r.shPortal;
    if (sT == null || sO == null || sS == null || sW == null || sB == null || sP == null || sPo == null || sV == null || sBl == null || sTr == null || sPt == null) {
        log(r, "renderer: missing shader(s)");
        return r;
    }
    r.pToonRefl = meshPipeline(sT, 1, CullMode.front, true, CompareFunction.less, true, true);
    r.pToonPreRefl = fadePipeline(sT, "fs_refl_pre", 1, CullMode.front, true, CompareFunction.less, [ct(COLOR_FMT, REFL_PRE)]);
    r.pToonFadeRefl = fadePipeline(sT, "fs_refl_fade", 1, CullMode.front, false, CompareFunction.lessEqual, [ct(COLOR_FMT, REFL_FADE)]);
    r.pSkyRefl = skyPipeline(sS, 1, true);
    r.pBillboardRefl = quadPipeline(sB, BB_LAYOUT, 1, CompareFunction.less, true);
    r.pParticleRefl = quadPipeline(sP, PART_LAYOUT, 1, CompareFunction.less, true);
    r.pTrailRefl = quadPipeline(sTr, TRAIL_LAYOUT, 1, CompareFunction.less, true);
    r.pPortalRefl = quadPipeline(sPt, PORTAL_LAYOUT, 1, CompareFunction.less, true);
    r.pBloomDown = new GPUPipeline(pipeDesc(sBl, "fs_down", [], [ct(COLOR_FMT)]));
    r.pBloomUp = new GPUPipeline(pipeDesc(sBl, "fs_up", [], [ct(COLOR_FMT, ADD)]));
    // every stage names its entry point: a stage given only a module takes the
    // module's FIRST @fragment, so an entry added above fs_main would silently
    // replace post (JOB 24's prototype trap)
    let dp = pipeDesc(sPo, "fs_main", [], [ct(TextureFormat.rgba8unorm)]);
    dp.vertexEntryPoint = "vs_main";
    let pp = new GPUPipeline(dp);
    r.pPost = pp;
    let dv = pipeDesc(sV, "fs_main", [VISOR_LAYOUT], [ct(TextureFormat.rgba8unorm, PREMUL)]);
    dv.vertexEntryPoint = "vs_main";
    dv.cullMode = CullMode.none;
    r.pVisor = new GPUPipeline(dv);
    // 3.1: the two halves of post (fs_head shares pPost's layout, so bgPost
    // serves it; fs_tail has its own: scene, gbuf, postA). (Luau: a failure
    // left them nil; here it raises)
    let da = pipeDesc(sPo, "fs_head", [], [ct(COLOR_FMT)]);
    da.vertexEntryPoint = "vs_main";
    da.bindGroupLayouts = [pp.getBindGroupLayout(0)];
    r.pPostA = new GPUPipeline(da);
    let db = pipeDesc(sPo, "fs_tail", [], [ct(TextureFormat.rgba8unorm)]);
    db.vertexEntryPoint = "vs_main";
    r.pPostB = new GPUPipeline(db);

    r.bgToonRefl = frameBG(r.pToonRefl, r.frameUboRefl);
    r.bgToonPreRefl = frameBG(r.pToonPreRefl, r.frameUboRefl);
    r.bgToonFadeRefl = frameBG(r.pToonFadeRefl, r.frameUboRefl);
    r.bgSkyRefl = frameBG(r.pSkyRefl, r.frameUboRefl);
    r.bgBillboardRefl = frameBG(r.pBillboardRefl, r.frameUboRefl);
    r.bgParticleRefl = frameBG(r.pParticleRefl, r.frameUboRefl);
    r.bgTrailRefl = frameBG(r.pTrailRefl, r.frameUboRefl);
    r.bgPortalRefl = frameBG(r.pPortalRefl, r.frameUboRefl);
    r.bloomUbos = [new GPUBuffer(BufferUsage.uniform, <u32>BLOOM_BYTES)]; // (slot 0 unused)
    for (let i = 1; i <= BLOOM_LEVELS * 2 - 1; i++) r.bloomUbos.push(new GPUBuffer(BufferUsage.uniform, <u32>BLOOM_BYTES));

    // water grid that follows the camera (see water.wgsl)
    let wb = meshgen.create(80 * 80);
    meshgen.grid(wb, 6000, 6000, 72, 72);
    r.waterMesh = gpu.uploadMesh(wb);

    r.ok = true;
    return r;
}

// Visor mesh: a gently curved shell in front of the eye whose projection at
// rest is a barrel-bowed rectangle (edges bow out, corners pulled in), so the
// HUD frame bows like glass without cutting content at the edges.
//
// Helmet glass: a section of a sphere whose center sits IN FRONT of the eye
// (the eye is `wrap` radii behind it), so the shell wraps around the viewer:
// the middle recedes, the sides and corners come closer, and straight HUD
// edges bow inward. The section is fitted so its corners land just inside
// the screen corners; the mid-edges pull in and reveal the world beyond.
// (Luau's local closures fit / proj / shell; results through FIT_* / PJ_* / SH_*)
let FV_TANV: f64 = 0;
let FV_TX: f64 = 0;
let FV_TY: f64 = 0;
let PJ_X: f64 = 0;
let PJ_Y: f64 = 0;
let FIT_AX: f64 = 0;
let FIT_AY: f64 = 0;
let FIT_MY: f64 = 0;
let SH_X: f64 = 0;
let SH_Y: f64 = 0;
let SH_Z: f64 = 0;

function fvProj(ax: f64, ay: f64, tanH: f64, wrap: f64): void {
    let x = Math.sin(ax) * Math.cos(ay), y = Math.sin(ay), z = -wrap - Math.cos(ax) * Math.cos(ay);
    PJ_X = (x / -z) / tanH;
    PJ_Y = (y / -z) / FV_TANV;
}

// fit the shell so its corners land at (tx, ty) of the screen; the section
// half angles and where the top edge's middle lands (pinch)
function fvFit(asp: f64, wrap: f64): void {
    let tanH = FV_TANV * asp;
    let Ax = Math.atan(tanH), Ay = Math.atan(FV_TANV);
    for (let k = 1; k <= 60; k++) {
        fvProj(Ax, Ay, tanH, wrap);
        let px = PJ_X, py = PJ_Y;
        Ax *= Math.pow(FV_TX / lmax(px, 1e-4), 0.5);
        Ay *= Math.pow(FV_TY / lmax(py, 1e-4), 0.5);
        Ax = lmin(Ax, 1.45);
        Ay = lmin(Ay, 1.35);
    }
    fvProj(0, Ay, tanH, wrap);
    FIT_AX = Ax;
    FIT_AY = Ay;
    FIT_MY = PJ_Y;
}

function fvShell(ax: f64, ay: f64, wrap: f64): void {
    SH_X = Math.sin(ax) * Math.cos(ay);
    SH_Y = Math.sin(ay);
    SH_Z = -wrap - Math.cos(ax) * Math.cos(ay);
}

function buildVisor(r: Gfx, aspect: f64, fovV: f64): void {
    let nx = 72, ny = 48;
    let vb = new ArrayBuffer((nx + 1) * (ny + 1) * 32);
    let ib = new ArrayBuffer(nx * ny * 6 * 4);
    let vf = Float32Array.wrap(vb);
    let iu = Uint32Array.wrap(ib);
    let tanV = Math.tan(fovV * 0.5);
    let bx = r.visor.bowX, by = r.visor.bowY;
    FV_TANV = tanV;
    FV_TX = 1.04;
    FV_TY = 1.08 - by;
    let wrap = 0.1 + bx * 4; // eye offset behind the sphere center, in radii
    fvFit(aspect, wrap);
    let Ax = FIT_AX, Ay = FIT_AY, pinch = FIT_MY;
    // wider than 16:9: soften the wrap so the top / bottom middle stays where
    // it sits at 16:9 (a fixed wrap pinches ultrawide views into a slot)
    if (aspect > 16.0 / 9 + 0.01) {
        fvFit(16.0 / 9, wrap);
        let ref = FIT_MY;
        if (pinch < ref) {
            let lo = 0.0, hi = 1.0;
            for (let k = 1; k <= 14; k++) {
                let mid = (lo + hi) * 0.5;
                fvFit(aspect, wrap * mid);
                if (FIT_MY < ref) {
                    hi = mid;
                } else {
                    lo = mid;
                }
            }
            wrap *= lo;
            fvFit(aspect, wrap);
            Ax = FIT_AX;
            Ay = FIT_AY;
            pinch = FIT_MY;
        }
    }
    // Two shapes per vertex, blended in the shader by the live curvature:
    // a flat screen-filling pane and the fitted helmet shell. The grid runs
    // VISOR_SKIRT past the HUD rect on every side; that skirt carries no HUD,
    // only the darkening glass rim, so the visor never ends in a hard edge.
    let tanH = tanV * aspect;
    let m = VISOR_SKIRT;
    let v = 0;
    for (let j = 0; j <= ny; j++) {
        for (let i = 0; i <= nx; i++) {
            let u = -m + (1 + 2 * m) * <f64>i / <f64>nx;
            let w = -m + (1 + 2 * m) * <f64>j / <f64>ny;
            let x0 = u * 2 - 1, y0 = 1 - w * 2;
            let ay = lclamp(y0 * Ay, -1.45, 1.45);
            fvShell(x0 * Ax, ay, wrap);
            let o = v * 8;
            vf[o] = <f32>(x0 * tanH * 0.995);
            vf[o + 1] = <f32>(y0 * tanV * 0.99);
            vf[o + 2] = -1;
            vf[o + 3] = <f32>SH_X;
            vf[o + 4] = <f32>SH_Y;
            vf[o + 5] = <f32>SH_Z;
            vf[o + 6] = <f32>u;
            vf[o + 7] = <f32>w;
            v += 1;
        }
    }
    let idx = 0;
    for (let j = 0; j < ny; j++) {
        for (let i = 0; i < nx; i++) {
            let a = j * (nx + 1) + i;
            let b = a + 1;
            let c = a + nx + 1;
            let d = c + 1;
            iu[idx] = <u32>a;
            iu[idx + 1] = <u32>c;
            iu[idx + 2] = <u32>b;
            iu[idx + 3] = <u32>b;
            iu[idx + 4] = <u32>c;
            iu[idx + 5] = <u32>d;
            idx += 6;
        }
    }
    r.visorVB = new GPUBuffer(BufferUsage.vertex, <u32>vb.byteLength, vb);
    r.visorIB = new GPUBuffer(BufferUsage.index, <u32>ib.byteLength, ib);
    r.visorCount = nx * ny * 6;
    r.visorAspect = aspect;
    r.visorBowX = bx;
    r.visorBowY = by;
    r.visorAx = Ax;
    r.visorAy = Ay;
    r.visorWrap = wrap;
    r.visorTanV = tanV;
    r.visorRing = null;
}

// CPU copy of visor.wgsl vs_main's vertex: HUD uv (u, w) on the pane / shell
// blend at curvature k, before the model-view-projection (VV_X / VV_Y / VV_Z)
let VV_X: f64 = 0;
let VV_Y: f64 = 0;
let VV_Z: f64 = 0;
function visorVertex(r: Gfx, u: f64, w: f64, k: f64): void {
    let tanV = r.visorTanV;
    let x0 = u * 2 - 1, y0 = 1 - w * 2;
    let ax = x0 * r.visorAx, ay = lclamp(y0 * r.visorAy, -1.45, 1.45);
    let sx = Math.sin(ax) * Math.cos(ay), sy = Math.sin(ay), sz = -r.visorWrap - Math.cos(ax) * Math.cos(ay);
    let fx = x0 * tanV * r.visorAspect * 0.995, fy = y0 * tanV * 0.99;
    VV_X = fx + (sx - fx) * k;
    VV_Y = fy + (sy - fy) * k;
    VV_Z = -1 + (sz + 1) * k;
}

// The HUD uv points that land on the 4% screen margin when the visor rests
// (curvature k, no sway, push or boost): 8 per side, walking the rectangle.
function visorRing(r: Gfx, k: f64): Array<f64> {
    let cached = r.visorRing;
    if (cached != null && r.visorRingK == k) return cached;
    let tanV = r.visorTanV;
    let tanH = tanV * r.visorAspect;
    let B = VISOR_SAFE, n = 8;
    let ring: Array<f64> = [0.0];
    for (let side = 0; side <= 3; side++) {
        for (let i = 0; i <= n - 1; i++) {
            let t = -B + 2 * B * <f64>i / <f64>n;
            let tx = t, ty = B;
            if (side == 1) {
                tx = B;
                ty = -t;
            } else if (side == 2) {
                tx = -t;
                ty = -B;
            } else if (side == 3) {
                tx = -B;
                ty = t;
            }
            let u = (tx + 1) * 0.5, w = (1 - ty) * 0.5;
            for (let it = 1; it <= 24; it++) {
                visorVertex(r, u, w, k);
                let x = VV_X, y = VV_Y, z = VV_Z;
                u += (tx - x / (-z * tanH)) * 0.5;
                w -= (ty - y / (-z * tanV)) * 0.5;
            }
            ring.push(u);
            ring.push(w);
        }
    }
    r.visorRing = ring;
    r.visorRingK = k;
    return ring;
}

// visor.wgsl `contain` profile: ~0 at the screen centre, ~linear toward the rim
function containH(v: f64): f64 {
    let m = lmin(Math.abs(v), 1);
    return Math.sqrt(m * m + VISOR_CONTAIN_E * VISOR_CONTAIN_E) - VISOR_CONTAIN_E;
}

// the ring at the live curvature, before the pose (x, y, z triples, 1-based)
let ringXYZ: Array<f64> = [0.0];

function visorPose(proj: Mat4, v: VisorParams, sw: f64): Mat4 {
    let ty = multiply4(new Mat4(), Mat4.fromTranslation(0, 0, <f32>v.push), Mat4.fromRotationY(<f32>(v.yaw * sw)));
    let tyx = multiply4(new Mat4(), ty, Mat4.fromRotationX(<f32>(v.pitch * sw)));
    let tyxz = multiply4(new Mat4(), tyx, Mat4.fromRotationZ(<f32>(v.roll * sw)));
    return multiply4(new Mat4(), proj, tyxz);
}

// largest containment pull any ring point needs under this pose
function visorOver(mvp: Mat4): f64 {
    let B = VISOR_SAFE;
    let m = 0.0;
    for (let i = 1; i <= ringXYZ.length - 1; i += 3) {
        xform4(mvp, <f32>ringXYZ[i], <f32>ringXYZ[i + 1], <f32>ringXYZ[i + 2], 1);
        let cx = <f64>T4[0], cy = <f64>T4[1], pw = <f64>T4[3];
        if (pw > 1e-4) {
            let nx = Math.abs(cx / pw), ny = Math.abs(cy / pw);
            if (nx > B) m = lmax(m, (nx - B) / containH(nx));
            if (ny > B) m = lmax(m, (ny - B) / containH(ny));
        }
    }
    return m;
}

// Least (a, b) with (1 - s) a + s b >= q at every constraint, a, b >= 0: the
// pulls at the two ends of one rim side (linear between them in the shader).
// The nearest point of a convex polygon to the origin is the projection onto
// one edge line or a vertex, so it tries those; continuous as the pose moves.
// (FS_A / FS_B; Luau's `try` closure writes FS_BA / FS_BB / FS_BN)
let FS_A: f64 = 0;
let FS_B: f64 = 0;
let FS_BA: f64 = 0;
let FS_BB: f64 = 0;
let FS_BN: f64 = 0;

function fsTry(s: Array<f64>, q: Array<f64>, n: i32, a: f64, b: f64): void {
    let nn = a * a + b * b;
    if (a < -1e-6 || b < -1e-6 || nn >= FS_BN) return;
    for (let i = 1; i <= n; i++) {
        if ((1 - s[i]) * a + s[i] * b < q[i] - 1e-6) return;
    }
    FS_BA = lmax(a, 0);
    FS_BB = lmax(b, 0);
    FS_BN = nn;
}

function fitSide(s: Array<f64>, q: Array<f64>, n: i32): void {
    if (n == 0) {
        FS_A = 0;
        FS_B = 0;
        return;
    }
    FS_BA = 0;
    FS_BB = 0;
    FS_BN = HUGE;
    for (let i = 1; i <= n; i++) {
        let si = s[i], qi = q[i];
        let l = (1 - si) * (1 - si) + si * si;
        fsTry(s, q, n, qi * (1 - si) / l, qi * si / l);
        if (si > 1e-4) fsTry(s, q, n, 0, qi / si);
        if (si < 1 - 1e-4) fsTry(s, q, n, qi / (1 - si), 0);
        for (let j = i + 1; j <= n; j++) {
            let sj = s[j], qj = q[j];
            let det = sj - si;
            if (Math.abs(det) > 1e-5) fsTry(s, q, n, (qi * sj - qj * si) / det, ((1 - si) * qj - (1 - sj) * qi) / det);
        }
    }
    if (FS_BN == HUGE) {
        let m = 0.0;
        for (let i = 1; i <= n; i++) m = lmax(m, q[i]);
        FS_A = m;
        FS_B = m;
        return;
    }
    FS_A = FS_BA;
    FS_B = FS_BB;
}

// per side: cross position (0 bottom / left .. 1 top / right) and pull needed (1-based)
let sideS: Array<Array<f64>> = [[0.0], [0.0], [0.0], [0.0], [0.0]];
let sideQ: Array<Array<f64>> = [[0.0], [0.0], [0.0], [0.0], [0.0]];

@inline function put1(a: Array<f64>, i: i32, v: f64): void {
    if (i < a.length) a[i] = v;
    else a.push(v);
}

// Per-corner containment pulls for this pose (VC[0..7]): left at bottom / top,
// right at bottom / top, bottom at left / right, top at left / right. Only the
// corner that overflows is pulled; the opposite one keeps its shape.
const VC: StaticArray<f64> = new StaticArray<f64>(8);
function visorContain(mvp: Mat4): void {
    let B = VISOR_SAFE;
    let nL = 0, nR = 0, nB = 0, nT = 0;
    let sL = sideS[1], sR = sideS[2], sB = sideS[3], sT = sideS[4];
    let qL = sideQ[1], qR = sideQ[2], qB = sideQ[3], qT = sideQ[4];
    for (let i = 1; i <= ringXYZ.length - 1; i += 3) {
        xform4(mvp, <f32>ringXYZ[i], <f32>ringXYZ[i + 1], <f32>ringXYZ[i + 2], 1);
        let cx = <f64>T4[0], cy = <f64>T4[1], pw = <f64>T4[3];
        if (pw > 1e-4) {
            let nx = cx / pw, ny = cy / pw;
            let sx = lclamp(0.5 + 0.5 * nx, 0, 1), sy = lclamp(0.5 + 0.5 * ny, 0, 1);
            if (nx < -B) {
                nL += 1;
                put1(sL, nL, sy);
                put1(qL, nL, (-nx - B) / containH(nx));
            } else if (nx > B) {
                nR += 1;
                put1(sR, nR, sy);
                put1(qR, nR, (nx - B) / containH(nx));
            }
            if (ny < -B) {
                nB += 1;
                put1(sB, nB, sx);
                put1(qB, nB, (-ny - B) / containH(ny));
            } else if (ny > B) {
                nT += 1;
                put1(sT, nT, sx);
                put1(qT, nT, (ny - B) / containH(ny));
            }
        }
    }
    fitSide(sL, qL, nL);
    VC[0] = FS_A;
    VC[1] = FS_B;
    fitSide(sR, qR, nR);
    VC[2] = FS_A;
    VC[3] = FS_B;
    fitSide(sB, qB, nB);
    VC[4] = FS_A;
    VC[5] = FS_B;
    fitSide(sT, qT, nT);
    VC[6] = FS_A;
    VC[7] = FS_B;
}

// HUD content stays inside the 4% screen margin (DIRECTION #20, QA B-N4): what
// sits inside it at rest stays inside while the boost push + bulge and the
// sway / roll carry the glass outward. Each corner's overflow is taken back
// near that corner only (the centre keeps the bulge and the lag sway, the
// other corners keep their shape). The sway may squash the rim only so far;
// past that it yields (`sw` scales it). wk: 0 while the boot's strong wrap
// plays as authored, 1 once settled.
// Returns the model-view-projection; sw in VF_SW, the pulls (visorContain
// order) in VF_P.
let VF_SW: f64 = 1;
const VF_P: StaticArray<f64> = new StaticArray<f64>(8);
function visorFit(r: Gfx, v: VisorParams, proj: Mat4, k: f64, wk: f64): Mat4 {
    let mvp = visorPose(proj, v, 1);
    if (wk <= 0) {
        VF_SW = 1;
        for (let i = 0; i < 8; i++) VF_P[i] = 0;
        return mvp;
    }
    let ring = visorRing(r, v.curve);
    ringXYZ.length = 1;
    for (let i = 1; i <= ring.length - 1; i += 2) {
        visorVertex(r, ring[i], ring[i + 1], k);
        ringXYZ.push(VV_X);
        ringXYZ.push(VV_Y);
        ringXYZ.push(VV_Z);
    }
    let sw = 1.0;
    let m1 = visorOver(mvp);
    if (m1 > VISOR_SWAY_KNEE) {
        let m0 = visorOver(visorPose(proj, v, 0));
        let extra = m1 - m0;
        if (extra > VISOR_SWAY_KNEE) {
            let span = VISOR_SWAY_CAP - VISOR_SWAY_KNEE;
            let target = m0 + VISOR_SWAY_KNEE + span * Math.tanh((extra - VISOR_SWAY_KNEE) / span);
            let lo = 0.0, hi = 1.0;
            for (let it = 1; it <= 10; it++) {
                let mid = (lo + hi) * 0.5;
                if (visorOver(visorPose(proj, v, mid)) > target) {
                    hi = mid;
                } else {
                    lo = mid;
                }
            }
            sw = 1 + (lo - 1) * wk;
            mvp = visorPose(proj, v, sw);
        }
    }
    visorContain(mvp);
    VF_SW = sw;
    for (let i = 0; i < 8; i++) VF_P[i] = lmin(VC[i], 0.8) * wk;
    return mvp;
}

function rebuildHudCanvas(r: Gfx): void {
    let art = r.hudArt;
    if (art == null || r.ptW <= 0) return;
    let aspect = r.ptW / r.ptH;
    r.hudH = 1080;
    r.hudW = Math.floor(1080 * aspect + 0.5);
    let changed = art.width != r.hudW || art.height != r.hudH;
    art.width = r.hudW;
    art.height = r.hudH;
    if (changed) {
        // lay the HUD out at its new size now (a resize applied inside the frame
        // would otherwise draw one frame of the old layout)
        art.advance(0);
    }
    // about one HUD texel per output pixel, capped by a pixel budget (not a
    // fixed factor: a 9:19.5 phone wants 2.3x on its narrow artboard)
    let budget = Math.sqrt(r.maxHudPixels / lmax(1, r.hudW * r.hudH));
    r.hudScale = lclamp(lmin(r.oh / 1080, budget), 0.75, lmax(0.75, r.maxHudScale));
    let cw = lmax(1, Math.floor(r.hudW * r.hudScale));
    let ch = lmax(1, Math.floor(r.hudH * r.hudScale));
    let hc = r.hudCanvas;
    if (hc == null) {
        r.hudCanvas = r.ctx.canvas(<u32>cw, <u32>ch);
    } else {
        hc.resize(<u32>cw, <u32>ch);
    }
    // the bind group is built after the canvas's next endFrame (its image view
    // only resolves once drawn)
    r.bgVisor = null;
}

function buildVisorBG(r: Gfx): void {
    let pv = r.pVisor, hc = r.hudCanvas;
    if (pv != null && hc != null) {
        let view = hc.image.view();
        if (view == null) return;
        r.bgVisor = new GPUBindGroup(pv.getBindGroupLayout(0), [new GPUBindGroupUBO(0, r.visorUbo)],
            [new GPUBindGroupTexture(2, view)], [new GPUBindGroupSampler(1, r.linear)]);
    }
}

// Atlas bind groups, built after the atlas canvas has been drawn once.
function atlasBG(r: Gfx, p: GPUPipeline?, view: GPUTextureView): GPUBindGroup? {
    if (p == null) return null;
    return new GPUBindGroup(p.getBindGroupLayout(1), [], [new GPUBindGroupTexture(1, view)], [new GPUBindGroupSampler(0, r.linear)]);
}

function buildAtlasBGs(r: Gfx, A: Atlas): void {
    let at = A.canvas;
    if (at == null) return;
    let view = at.image.view();
    if (view == null) return;
    A.bgDirty = false;
    A.bgMain = atlasBG(r, r.pBillboard, view);
    A.bgRefl = atlasBG(r, r.pBillboardRefl, view);
    A.bgOver = atlasBG(r, r.pOverlay, view);
    A.bgMask = atlasBG(r, r.pBillboardMask, view);
    if (A == r.atlases[1]) {
        r.bgAtlasMain = A.bgMain;
        r.bgAtlasRefl = A.bgRefl;
        r.bgAtlasOver = A.bgOver;
        r.bgAtlasMask = A.bgMask;
    }
}

function rt(w: f64, h: f64, fmt: TextureFormat): GPUTextureView {
    let d = new GPUTextureDesc();
    d.width = <u32>w;
    d.height = <u32>h;
    d.format = fmt;
    d.renderTarget = true;
    return new GPUTexture(d).view();
}

function rtMs(w: f64, h: f64, fmt: TextureFormat, samples: i32): GPUTextureView {
    let d = new GPUTextureDesc();
    d.width = <u32>w;
    d.height = <u32>h;
    d.format = fmt;
    d.renderTarget = true;
    d.sampleCount = <u32>samples;
    return new GPUTexture(d).view();
}

// post's bind groups (fs_main / fs_head: bgPost; 3.1's fs_tail: bgPostB). Binding 6 is the visor offscreen while
// the plates print the HUD (JOB 26), a 1 x 1 stand-in otherwise. Both bind all of 0-6 (post.wgsl keepLayout): CLI
// 1.5 bakes the file's layout, 1.7 each entry's, and web 2.45+ rejects a group that misses or adds an entry
function postBGs(r: Gfx): void {
    let hdr = r.hdrView, gb = r.gbufView;
    if (r.visorDummy == null) r.visorDummy = rt(1, 1, TextureFormat.rgba8unorm);
    let vo = r.visorOff;
    let vz: GPUTextureView = vo != null ? vo : r.visorDummy!;
    let pp = r.pPost;
    let b1 = r.bloomViews.length > 1 ? r.bloomViews[1] : null;
    if (pp != null && hdr != null && gb != null && b1 != null) {
        r.bgPost = new GPUBindGroup(pp.getBindGroupLayout(0), [new GPUBindGroupUBO(0, r.postUbo)], [
            new GPUBindGroupTexture(2, hdr),
            new GPUBindGroupTexture(3, gb),
            new GPUBindGroupTexture(4, b1),
            new GPUBindGroupTexture(5, r.visorDummy!), // the tail's postA (fs_head draws into it)
            new GPUBindGroupTexture(6, vz),
        ], [new GPUBindGroupSampler(1, r.linear)]);
    }
    let pb = r.pPostB, pa = r.postAView;
    if (r.postSplit && pb != null && pa != null && hdr != null && gb != null) {
        r.bgPostB = new GPUBindGroup(pb.getBindGroupLayout(0), [new GPUBindGroupUBO(0, r.postUbo)], [
            new GPUBindGroupTexture(2, hdr),
            new GPUBindGroupTexture(3, gb),
            new GPUBindGroupTexture(4, b1 != null ? b1 : r.visorDummy!),
            new GPUBindGroupTexture(5, pa),
            new GPUBindGroupTexture(6, vz),
        ], [new GPUBindGroupSampler(1, r.linear)]);
    }
}

// reflection target size (half the render size on high)
function reflW(r: Gfx): f64 {
    return lmax(2, Math.floor(r.rw / r.qReflDiv));
}
function reflH(r: Gfx): f64 {
    return lmax(2, Math.floor(r.rh / r.qReflDiv));
}

// quality tiers: floors of the scaled main pass (short side, px) and of the
// ink hull width (render px: thinner breaks up under 2x MSAA)
const QUALITY_MIN_SIDE: f64 = 540;
const QUALITY_MIN_INK: f64 = 1.2;

function applyResize(r: Gfx, w: f64, h: f64, scale: f64): void {
    if (!r.ok || w < 2 || h < 2) return;
    r.ptW = w;
    r.ptH = h;
    r.scale = scale;
    // output (post + visor) at device resolution, capped: drawImage upscales
    let os = lmin(scale, Math.sqrt(r.maxOutputPixels / (w * h)));
    os = lmax(os, 0.5);
    r.ow = lmax(2, Math.floor(w * os));
    r.oh = lmax(2, Math.floor(h * os));
    // main pass at device resolution, capped for fill rate; the mobile tier
    // (phones, tablets) caps lower in either orientation and drops MSAA
    // device class, decided once (window drags never flip MSAA): a phone-size
    // screen (short side <= 600 pt at 2x), or >= 2.5x
    if (r.mobileAuto < 0) r.mobileAuto = (scale >= 2.5 || (scale >= 2 && lmin(w, h) <= 600)) ? 1 : 0;
    let mobile = r.mobileTier < 0 ? r.mobileAuto == 1 : r.mobileTier == 1;
    r.mobile = mobile;
    let cap = r.maxRenderPixels;
    let ms = min(4, r.maxSamples);
    if (mobile) {
        cap = lmin(cap, r.mobilePixels);
        ms = max(1, min(r.mobileSamples, ms));
    }
    // graphics quality: lower pixel cap, render scale and MSAA (high: none)
    cap = lmin(cap, r.qPixels);
    ms = max(1, min(r.qSamples, ms));
    if (ms != r.samples) {
        r.samples = ms;
        buildMsPipelines(r, ms);
        for (let ai = 1; ai < r.atlases.length; ai++) {
            let A = r.atlases[ai];
            if (A.canvas != null) buildAtlasBGs(r, A);
        }
    }
    let rs = lmin(scale, Math.sqrt(cap / (w * h)));
    if (r.qScale < 1) {
        // small windows: the quality scale stops at QUALITY_MIN_SIDE px on the
        // short side (390x844 at 1x on low was 273 px wide: blocky)
        rs = lmax(rs * r.qScale, lmin(rs, QUALITY_MIN_SIDE / lmin(w, h)));
    }
    rs = lmax(rs, 0.5);
    r.renderScale = rs;
    r.rw = lmax(2, Math.floor(w * rs));
    r.rh = lmax(2, Math.floor(h * rs));
    // (the fallback canvas is sized when a frame uses it: ensureCanvas)
    r.depthView = rtMs(r.rw, r.rh, DEPTH_FMT, ms);
    let hdrView = rt(r.rw, r.rh, COLOR_FMT);
    r.hdrView = hdrView;
    let gbufView = rt(r.rw, r.rh, GBUF_FMT);
    r.gbufView = gbufView;
    if (ms > 1) {
        r.msaaView = rtMs(r.rw, r.rh, COLOR_FMT, ms);
        r.msaaGView = rtMs(r.rw, r.rh, GBUF_FMT, ms);
    } else {
        // no MSAA: the main pass renders straight into the resolve targets
        r.msaaView = hdrView;
        r.msaaGView = gbufView;
    }
    let fw = reflW(r), fh = reflH(r);
    let reflView = rt(fw, fh, COLOR_FMT);
    r.reflView = reflView;
    r.reflDepthView = rt(fw, fh, DEPTH_FMT);

    // bloom chain 1/2 .. 1/16 (qBloom drops levels at the fine end: the
    // first pass then reads the hdr target with wider taps)
    r.bloomViews = [null];
    r.bloomW = [0.0];
    r.bloomH = [0.0];
    let nl = BLOOM_LEVELS - r.qBloom;
    r.bloomN = nl;
    let bw = r.rw, bh = r.rh;
    for (let i = 1; i <= r.qBloom; i++) {
        bw = lmax(2, Math.floor(bw / 2));
        bh = lmax(2, Math.floor(bh / 2));
    }
    for (let i = 1; i <= nl; i++) {
        bw = lmax(2, Math.floor(bw / 2));
        bh = lmax(2, Math.floor(bh / 2));
        r.bloomViews.push(rt(bw, bh, COLOR_FMT));
        r.bloomW.push(bw);
        r.bloomH.push(bh);
    }
    r.bgBloom = [null];
    r.bgBloomN = 0;
    let pd = r.pBloomDown, pu = r.pBloomUp;
    if (pd != null && pu != null) {
        let d = new ArrayBuffer(BLOOM_BYTES);
        let f = Float32Array.wrap(d);
        // downsample passes: source hdr, b1, b2, b3
        let tap = Math.pow(2, <f64>r.qBloom);
        for (let i = 1; i <= nl; i++) {
            let srcW = i == 1 ? r.rw : r.bloomW[i - 1];
            let srcH = i == 1 ? r.rh : r.bloomH[i - 1];
            let k = i == 1 ? tap : 1.0;
            f[0] = <f32>(k / srcW);
            f[1] = <f32>(k / srcH);
            f[2] = <f32>r.post.bloomThreshold;
            f[3] = 0.15;
            f[4] = i == 1 ? 1 : 0;
            f[5] = 1;
            f[6] = 0;
            f[7] = 0;
            let ubo = r.bloomUbos[i];
            ubo.update(0, d, <u32>BLOOM_BYTES);
            let src: GPUTextureView = i == 1 ? hdrView : r.bloomViews[i - 1]!;
            r.bgBloom.push(new GPUBindGroup(pd.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(2, src)], [new GPUBindGroupSampler(1, r.linear)]));
        }
        // upsample passes: b4 -> b3, b3 -> b2, b2 -> b1
        for (let k = 1; k <= nl - 1; k++) {
            let srcI = nl - k + 1;
            f[0] = <f32>(1 / r.bloomW[srcI]);
            f[1] = <f32>(1 / r.bloomH[srcI]);
            f[2] = 0;
            f[3] = 0;
            f[4] = 0;
            f[5] = 1;
            let ubo = r.bloomUbos[nl + k];
            ubo.update(0, d, <u32>BLOOM_BYTES);
            r.bgBloom.push(new GPUBindGroup(pu.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
                [new GPUBindGroupTexture(2, r.bloomViews[srcI]!)], [new GPUBindGroupSampler(1, r.linear)]));
        }
        r.bgBloomN = r.bgBloom.length - 1;
    }

    let pw = r.pWater;
    if (pw != null) {
        r.bgWater1 = new GPUBindGroup(pw.getBindGroupLayout(1), [new GPUBindGroupUBO(2, r.waterUbo)],
            [new GPUBindGroupTexture(1, reflView)], [new GPUBindGroupSampler(0, r.linear)]);
    }
    // 3.1: split post when the render size differs from the output: on the mobile tier, and on the desktop
    // tier's HIGH when the render size is pixel-capped below the output (windows above 3.7 Mpx: its ink would
    // otherwise be found at output pixels on an upscaled gbuffer and break up, JOB 26). Desktop MED / LOW keep
    // their art-tuned output-size ink
    let split = r.pPostA != null && r.pPostB != null
        && (POST_SPLIT == "force" || (POST_SPLIT == "auto" && (r.rw != r.ow || r.rh != r.oh) && (mobile || r.qScale >= 1)));
    r.postSplit = split;
    if (split) {
        let pa = rt(r.rw, r.rh, COLOR_FMT);
        r.postAView = pa;
        let ca = new GPUColorAttachment();
        ca.view = pa;
        let pdsc = new GPUPassDesc();
        pdsc.color = [ca];
        r.postADesc = pdsc;
    } else {
        r.postAView = null;
        r.postADesc = null;
        r.bgPostB = null;
    }
    postBGs(r);
    buildVisor(r, w / h, 62 * Math.PI / 180);
    rebuildHudCanvas(r);
}

// Window drags call resize every frame; rebuilding every target each time
// stalls the GPU and drops draws. Apply the first size immediately, then only
// once the size has been stable for a moment (the old targets are stretched
// to the new size meanwhile).
export function resize(r: Gfx, w: f64, h: f64, scale: f64): void {
    r.layW = w; // coverLayout's size, even before (or without) a working renderer
    r.layH = h;
    // immediately: before the first frame (start-up / headless captures) and
    // when the orientation flips; debounced only for continuous window drags
    let flip = r.ptW > 0 && ((w > h) != (r.ptW > r.ptH));
    if (r.rw == 0 || r.lastTime < 0 || flip) {
        r.pendW = NaN;
        r.pendH = NaN;
        r.pendS = NaN;
        applyResize(r, w, h, scale);
        return;
    }
    r.pendW = w;
    r.pendH = h;
    r.pendS = scale;
    r.pendAt = r.time;
}

// 2.1 (EFFICIENCY_REVIEW; JOB 25): the HUD artboard advances only on the frames
// draw2d rasters it. The game calls hudAdvance where it advanced the HUD;
// the time of a skipped frame waits and is applied, summed, on the next drawn
// frame (or now, when the game itself reads the HUD that frame: game.luau
// hudLive). false advances it every frame, as before.
const HUD_SKIP: bool = true;

// HUD raster interval in frames (draw2d; hudDue predicts it with the same
// code): every frame on a fast desktop, every other frame on phones, LOW,
// above 90 Hz or when frames run long; every frame during the visor's boot /
// glitch
function hudInterval(r: Gfx, dtAvg: f64, fast: bool): i32 {
    let ev = <i32>Math.floor(r.hudEvery);
    if (ev <= 0) {
        let vzs = r.visor;
        if (dtAvg < 1.0 / 90) {
            ev = 2;
        } else if (vzs.boot < 0.999 || vzs.glitch > 0.02) {
            ev = 1;
        } else if (r.mobile || r.qHudEvery >= 2) {
            // phones (and the low quality tier): full-resolution HUD,
            // drawn every other frame
            ev = 2;
        } else if (fast) {
            ev = 1;
        } else {
            ev = 2;
        }
    }
    return ev;
}

// Frame pacing for the adaptive HUD rate after a frame at `time`: drop to 30 Hz
// when frames run long, retry after a hold that doubles on every relapse (max
// 30 s). frame commits it; hudDue only reads it. Call before r.lastTime is
// overwritten. (HP_AVG / HP_FAST / HP_HOLD / HP_BACKOFF)
let HP_AVG: f64 = 0;
let HP_FAST: bool = true;
let HP_HOLD: f64 = 0;
let HP_BACKOFF: f64 = 0;
function hudPace(r: Gfx, time: f64): void {
    let avg = r.dtAvg, fast = r.hudFast, hold = r.hudHold, backoff = r.hudBackoff;
    if (r.lastTime >= 0) {
        let dt = lclamp(time - r.lastTime, 0, 0.1);
        avg += (lclamp(dt, 0.004, 0.1) - avg) * 0.08;
        if (fast) {
            if (avg > 1.0 / 50) {
                fast = false;
                hold = backoff;
                backoff = lmin(backoff * 2, 30);
            }
        } else {
            hold -= dt;
            if (hold <= 0 && avg < 1.0 / 57) fast = true;
        }
    }
    HP_AVG = avg;
    HP_FAST = fast;
    HP_HOLD = hold;
    HP_BACKOFF = backoff;
}

// Whether draw2d will raster the HUD on frame at `time` (the game's clock,
// which it passes to frame). True whenever no raster can be skipped or the
// frame cannot be foreseen; draw2d's safety net catches anything else.
export function hudDue(r: Gfx, time: f64): bool {
    if (!HUD_SKIP || r.hudCanvas == null || r.hudArt == null || r.no2d || r.noGpu || !r.ok || r.rw == 0) return true;
    if (r.visor.opacity <= 0.001 || r.hudDirty || r.bgVisor == null) return true;
    if (!isNaN(r.pendW) && (time - r.pendAt >= 0.2 || time < 0.5)) {
        return true; // frame applies a resize first: a new HUD canvas, drawn at once
    }
    hudPace(r, time);
    return (r.frameN + 1) % hudInterval(r, HP_AVG, HP_FAST) == 0;
}

// The HUD artboard's advance: the time waits for a frame the HUD is drawn,
// unless `now`. On every frame it does not skip, the step is exactly dt.
export function hudAdvance(r: Gfx, dt: f64, now: bool, time: f64): void {
    let art = r.hudArt;
    if (art == null) return;
    r.hudLag += dt;
    r.stats.hudCalls += 1;
    if (now || hudDue(r, time)) {
        art.advance(r.hudLag);
        r.hudLag = 0;
        r.stats.hudAdv += 1;
    }
}

// Catch the HUD up now (before a write it must see on its own frame, a reset,
// a resize).
export function hudFlush(r: Gfx?): void {
    if (r == null) return;
    let art = r.hudArt;
    if (art != null && r.hudLag > 0) {
        art.advance(r.hudLag);
        r.hudLag = 0;
    }
}

// level: 'low' | 'medium' | 'high' (core_quality calls it on the first frame
// and on every change). Re-runs the resize-dependent setup when the render
// size, MSAA, bloom chain or reflection target change.
export function setQuality(r: Gfx, level: string): void {
    let q = qualityTier(level);
    if (q == null || r.quality == level) return;
    r.quality = level;
    let rsz = r.qPixels != q.pixels || r.qScale != q.scale || r.qSamples != q.samples || r.qBloom != q.bloom || r.qReflDiv != q.reflDiv;
    r.qPixels = q.pixels;
    r.qScale = q.scale;
    r.qSamples = q.samples;
    r.qBloom = q.bloom;
    r.qReflDiv = q.reflDiv;
    r.qReflFx = q.reflFx;
    r.qHudEvery = q.hud;
    r.qShadows = q.shadows;
    r.qWater = q.water;
    if (r.qSlowEvery != q.slow) {
        // the two slow atlases alternate: phases 1 and slow / 2 + 1 (2: odd / even frames)
        r.qSlowEvery = q.slow;
        r.atlases[2].every = q.slow;
        r.atlases[2].phase = 1;
        r.atlases[3].every = q.slow;
        r.atlases[3].phase = (q.slow / 2 + 1) % q.slow;
    }
    if (rsz && r.ptW > 0) {
        // (a pending window size is applied with it)
        let w = opt(r.pendW, r.ptW), h = opt(r.pendH, r.ptH), s = opt(r.pendS, r.scale);
        r.pendW = NaN;
        r.pendH = NaN;
        r.pendS = NaN;
        applyResize(r, w, h, s);
        // sprite texels follow the render height
        r.atlasDirty = true;
    }
}

export function setHud(r: Gfx, art: Artboard): void {
    r.hudArt = art;
    rebuildHudCanvas(r);
}

// Sprites --------------------------------------------------------------------

// A billboard textured with a Rive artboard. Every sprite artboard is drawn
// into one shared atlas canvas, once per frame, only while it has instances
// in view. pxW / pxH: requested texture size (capped by the artboard size and
// r.spriteDensity, so oversized requests cost nothing).
export function createSprite(r: Gfx, name: string, art: Artboard?, pxW: f64, pxH: f64, cap: i32, reflect: bool, overlay: bool): Sprite {
    let s = new Sprite(cap);
    s.name = name;
    s.art = art;
    s.pxW = pxW;
    s.pxH = pxH;
    s.reflect = reflect;
    s.overlay = overlay;
    // the hero and screen overlays refresh every frame; other world
    // sprites (wingmen, the reflection twin) every other frame
    s.every = name == "pilot" || overlay ? 1 : 2;
    r.sprites.push(s);
    r.atlasDirty = true;
    return s;
}

// How often a sprite's artboard content is redrawn: 1 = every frame,
// 2 = every other frame (its billboard still moves every frame).
export function setSpriteRate(r: Gfx, s: Sprite, every: f64): void {
    let e = every >= 2 ? 2 : 1;
    if (s.every != e) {
        s.every = e;
        r.atlasDirty = true;
    }
}

// A sprite drawn only in the water reflection pass (the mirror flips it).
// Used for art posed from below, so the reflection shows the underside.
export function createReflectionSprite(r: Gfx, name: string, art: Artboard?, pxW: f64, pxH: f64, cap: i32): Sprite {
    let s = createSprite(r, name, art, pxW, pxH, cap, true, false);
    s.reflOnly = true;
    return s;
}

// Change a sprite's texture size (repacks the atlas).
export function setSpriteSize(r: Gfx, s: Sprite, pxW: f64, pxH: f64): void {
    if (s.pxW == pxW && s.pxH == pxH) return;
    s.pxW = pxW;
    s.pxH = pxH;
    s.drawn = false;
    r.atlasDirty = true;
}

const ATLAS_W: f64 = 2048;
const ATLAS_PAD: f64 = 4;

// texels a sprite gets in the atlas: the request, capped at the artboard size
// times the density (more on tall targets), never below 16 (STS_W / STS_H)
let STS_W: f64 = 0;
let STS_H: f64 = 0;
function spriteTexSize(r: Gfx, s: Sprite): void {
    let w = s.pxW, h = s.pxH;
    let art = s.art;
    if (art != null && art.width > 0 && art.height > 0) {
        // reflection-only art is seen rippled and posterized in the water
        let k = r.spriteDensity * lmax(1, r.rh / 1080) * (s.reflOnly ? 0.6 : 1);
        w = lmin(w, Math.ceil(art.width * k));
        h = lmin(h, Math.ceil(art.height * k));
    }
    STS_W = lmax(16, Math.floor(w));
    STS_H = lmax(16, Math.floor(h));
}

// Skyline-pack sprites (tallest first) into one atlas canvas; rebuild clips.
// (the skyline lists are 0-based here)
function packInto(r: Gfx, order: Array<Sprite>, A: Atlas): void {
    for (let i = 0; i < order.length; i++) {
        let s = order[i];
        spriteTexSize(r, s);
        s.aw = STS_W;
        s.ah = STS_H;
    }
    order.sort((a: Sprite, b: Sprite): i32 => (a.ah > b.ah ? -1 : a.ah < b.ah ? 1 : 0));
    // skyline: segments { x, width, top } across the atlas width
    let skX: Array<f64> = [0.0], skW: Array<f64> = [ATLAS_W], skY: Array<f64> = [0.0];
    let usedW = 0.0, usedH = 0.0;
    for (let oi = 0; oi < order.length; oi++) {
        let s = order[oi];
        let w = s.aw + ATLAS_PAD, h = s.ah + ATLAS_PAD;
        let bestI = -1, bestY = HUGE, bestX = 0.0;
        for (let i = 0; i < skX.length; i++) {
            let x = skX[i];
            if (x + w <= ATLAS_W) {
                let y = 0.0, need = w, k = i;
                while (need > 0 && k < skX.length) {
                    y = lmax(y, skY[k]);
                    need -= skW[k];
                    k += 1;
                }
                if (need <= 0 && (y + h < bestY + 0.5 && (y + h < bestY || x < bestX))) {
                    bestI = i;
                    bestY = y + h;
                    bestX = x;
                }
            }
        }
        if (bestI < 0) {
            bestI = 0;
            bestX = 0;
            bestY = usedH + h;
        }
        s.ax = bestX + ATLAS_PAD;
        s.ay = bestY - h + ATLAS_PAD;
        usedW = lmax(usedW, bestX + w + ATLAS_PAD);
        usedH = lmax(usedH, bestY + ATLAS_PAD);
        // raise the skyline over [bestX, bestX + w)
        let nx: Array<f64> = [], nw: Array<f64> = [], ny: Array<f64> = [];
        let x0 = bestX, x1 = bestX + w;
        let inserted = false;
        for (let i = 0; i < skX.length; i++) {
            let sx = skX[i], sw2 = skW[i], sy = skY[i];
            let ex = sx + sw2;
            if (ex <= x0 || sx >= x1) {
                if (sx >= x1 && !inserted) {
                    nx.push(x0);
                    nw.push(w);
                    ny.push(bestY);
                    inserted = true;
                }
                nx.push(sx);
                nw.push(sw2);
                ny.push(sy);
            } else {
                if (sx < x0) {
                    nx.push(sx);
                    nw.push(x0 - sx);
                    ny.push(sy);
                }
                if (!inserted) {
                    nx.push(x0);
                    nw.push(w);
                    ny.push(bestY);
                    inserted = true;
                }
                if (ex > x1) {
                    nx.push(x1);
                    nw.push(ex - x1);
                    ny.push(sy);
                }
            }
        }
        if (!inserted) {
            nx.push(x0);
            nw.push(w);
            ny.push(bestY);
        }
        skX = nx;
        skW = nw;
        skY = ny;
        let cp = new Path();
        cp.moveTo(Vector.xy(<f32>s.ax, <f32>s.ay));
        cp.lineTo(Vector.xy(<f32>(s.ax + s.aw), <f32>s.ay));
        cp.lineTo(Vector.xy(<f32>(s.ax + s.aw), <f32>(s.ay + s.ah)));
        cp.lineTo(Vector.xy(<f32>s.ax, <f32>(s.ay + s.ah)));
        cp.close();
        s.clip = cp;
    }
    let W = lmax(64, Math.ceil(usedW / 64) * 64);
    let H = lmax(64, Math.ceil(usedH / 64) * 64);
    if (A.canvas == null || W != A.w || H != A.h) {
        let at = A.canvas;
        if (at == null) {
            A.canvas = r.ctx.canvas(<u32>W, <u32>H);
        } else {
            at.resize(<u32>W, <u32>H);
        }
        A.w = W;
        A.h = H;
        A.bgDirty = true;
        A.bgMain = null;
        A.bgRefl = null;
        A.bgOver = null;
        A.bgMask = null;
    }
    for (let i = 0; i < order.length; i++) {
        order[i].canvas = A.canvas;
        order[i].fresh = false;
    }
}

function packAtlas(r: Gfx): void {
    r.atlasDirty = false;
    // every-frame sprites -> atlas 1; the every-other-frame ones alternate
    // between atlases 2 (odd frames) and 3 (even frames), so each frame
    // carries about half of their raster cost instead of all of it every
    // second frame
    let lists: Array<Array<Sprite>> = [[], [], [], []];
    let slow = 0;
    for (let i = 0; i < r.sprites.length; i++) {
        let s = r.sprites[i];
        let ai = 1;
        if (s.every >= 2) {
            ai = 2 + slow % 2;
            slow += 1;
        }
        s.ai = ai;
        lists[ai].push(s);
    }
    for (let ai = 1; ai <= 3; ai++) {
        if (lists[ai].length > 0) packInto(r, lists[ai], r.atlases[ai]);
    }
    let A1 = r.atlases[1];
    r.atlas = A1.canvas;
    r.atlasW = A1.w;
    r.atlasH = A1.h;
}

// Opaque texels (alpha > 0.5, opacity > 0.9) write depth and a gbuffer mark:
// particles / trails behind the sprite and post ink edges stop at its silhouette.
export function setSpriteSolid(s: Sprite, on: bool): void {
    s.solid = on;
}

// Add one billboard instance. Size in meters; pivotY 0 = bottom, 0.5 = center.
export function spriteAdd(
    s: Sprite,
    x: f64, y: f64, z: f64,
    roll: f64,
    w: f64, h: f64,
    pivotY: f64,
    opacity: f64,
    tr: f64 = 1, tg: f64 = 1, tb: f64 = 1, flash: f64 = 0,
    u0: f64 = 0, v0: f64 = 0, u1: f64 = 1, v1: f64 = 1
): void {
    if (s.n >= s.cap) return;
    let d = s.df;
    let o = s.n * 16;
    d[o] = <f32>x;
    d[o + 1] = <f32>y;
    d[o + 2] = <f32>z;
    d[o + 3] = <f32>roll;
    d[o + 4] = <f32>w;
    d[o + 5] = <f32>h;
    d[o + 6] = <f32>pivotY;
    d[o + 7] = <f32>opacity;
    d[o + 8] = <f32>tr;
    d[o + 9] = <f32>tg;
    d[o + 10] = <f32>tb;
    d[o + 11] = <f32>flash;
    d[o + 12] = <f32>u0;
    d[o + 13] = <f32>v0;
    d[o + 14] = <f32>u1;
    d[o + 15] = <f32>v1;
    s.n += 1;
}

// One-line frame stats (print it behind a debug flag to watch the budget).
export function statsText(r: Gfx): string {
    let st = r.stats;
    return format(
        "render %dx%d out %dx%d | draws %d inst %d | culled %d refl %d | fading %d refl %d | atlas %dx%d sprites %d | particles %d trails %d | hud adv %d/%d late %d",
        [N(r.rw), N(r.rh), N(r.ow), N(r.oh), N(<f64>st.draws), N(<f64>st.instances), N(<f64>st.culled), N(<f64>st.culledRefl),
            N(<f64>st.fading), N(<f64>st.fadingRefl), N(r.atlasW + r.atlases[2].w + r.atlases[3].w),
            N(lmax(lmax(r.atlasH, r.atlases[2].h), r.atlases[3].h)), N(<f64>st.sprites), N(<f64>st.particles), N(<f64>st.trails),
            N(<f64>st.hudAdv), N(<f64>st.hudCalls), N(<f64>st.hudLate)]
    );
}

@inline function N(v: f64): FormatArg {
    return FormatArg.number(v);
}
@inline function S(v: string): FormatArg {
    return FormatArg.string(v);
}

// Uniform writers -------------------------------------------------------------

@inline function w4(d: Float32Array, o: i32, a: f64, b: f64, c: f64, e: f64): void {
    let i = o >> 2;
    d[i] = <f32>a;
    d[i + 1] = <f32>b;
    d[i + 2] = <f32>c;
    d[i + 3] = <f32>e;
}

@inline function wc(d: Float32Array, o: i32, c: Array<f64>, w: f64): void {
    w4(d, o, c[1], c[2], c[3], w);
}

function writeFrame(r: Gfx, d: ArrayBuffer, vp: Mat4, ivp: Mat4, pal: Palette, reflection: bool, tanHalf: f64): void {
    let f = Float32Array.wrap(d);
    vp.writeToBuffer(d, 0);
    ivp.writeToBuffer(d, 64);
    let e = r.camEye, rt0 = r.camRight, up = r.camUp;
    // the reflection pass sees the world from the eye mirrored under the water
    w4(f, 128, e.x, reflection ? -e.y : e.y, e.z, r.time);
    w4(f, 144, rt0.x, rt0.y, rt0.z, 0);
    w4(f, 160, up.x, up.y, up.z, 0);
    let sd = mathx.norm(Vector.xyz(<f32>pal.sunDir[1], <f32>pal.sunDir[2], <f32>pal.sunDir[3]));
    w4(f, 176, sd.x, sd.y, sd.z, pal.sunSize);
    wc(f, 192, pal.sunColor, 1);
    wc(f, 208, pal.skyTop, 1);
    wc(f, 224, pal.skyHorizon, 1);
    wc(f, 240, pal.ambient, pal.shadowStrength);
    wc(f, 256, pal.shadowTint, 1);
    wc(f, 272, pal.fogColor, pal.fogDensity);
    let inkW = pal.inkWidth;
    if (r.qScale < 1) {
        // hull width is angular (constant on screen); on a scaled tier keep
        // it >= QUALITY_MIN_INK render px
        inkW = lmax(inkW, QUALITY_MIN_INK * 2 * tanHalf / r.rh);
    }
    wc(f, 288, pal.ink, inkW);
    wc(f, 304, pal.waterDeep, 1);
    wc(f, 320, pal.waterShallow, 1);
    wc(f, 336, pal.foam, 1);
    let th = r.rh;
    if (reflection) {
        w4(f, 352, 1, 0, 1, pal.halftone);
        let fw = reflW(r), fh = reflH(r);
        w4(f, 368, fw, fh, 1 / fw, 1 / fh);
        th = fh;
    } else {
        // (clip.y is free in the main pass: -2000 asks water / sky for lite detail)
        w4(f, 352, 0, r.qWater < 1 ? -2000 : -1000, 0, pal.halftone);
        w4(f, 368, r.rw, r.rh, 1 / r.rw, 1 / r.rh);
    }
    w4(f, 384, pal.biome, r.speed, r.post.flash, pal.cloudCover);
    w4(f, 400, r.flowX, r.flowZ, r.boost, th / 1080);
    w4(f, 416, r.wakeX, r.wakeY, r.wakeZ, r.wakeStr);
    let fw0 = r.camFwd;
    w4(f, 432, fw0.x, fw0.y, fw0.z, tanHalf);
}

function writeWater(r: Gfx): void {
    let d = r.waterData;
    let f = Float32Array.wrap(d);
    let hist = r.wakeHist;
    for (let i = 0; i <= WAKE_POINTS - 1; i++) {
        let o = i * 16;
        if (i < r.wakeHistN) {
            w4(f, o, hist[i * 4 + 1], hist[i * 4 + 2], hist[i * 4 + 3], hist[i * 4 + 4]);
        } else {
            w4(f, o, 0, 0, 0, 0);
        }
    }
    let s = r.shadows;
    for (let i = 0; i <= MAX_SHADOWS - 1; i++) {
        let o = 256 + i * 16;
        if (i < r.shadowN) {
            w4(f, o, s[i * 4 + 1], s[i * 4 + 2], s[i * 4 + 3], s[i * 4 + 4]);
        } else {
            w4(f, o, 0, 0, 1, 0);
        }
    }
    let sp = r.spots;
    for (let i = 0; i <= MAX_SPOTS - 1; i++) {
        let o = 512 + i * 16;
        if (i < r.spotN) {
            w4(f, o, sp[i * 4 + 1], sp[i * 4 + 2], sp[i * 4 + 3], sp[i * 4 + 4]);
        } else {
            w4(f, o, 0, 0, 1, 0);
        }
    }
    w4(f, 640, <f64>r.wakeHistN, <f64>r.shadowN, <f64>r.spotN, r.reflStrength);
    // flight path around the camera, points on a fixed s grid (seams stay put)
    let tr = r.rail;
    if (tr != null && r.railS > RAIL_OFF && tr.n > 2) {
        let s0 = Math.floor((r.railS - 220) / RAIL_STEP) * RAIL_STEP;
        let maxS = <f64>(tr.n - 1) * tr.step;
        for (let i = 0; i <= RAIL_POINTS - 1; i++) {
            let sv = lmin(s0 + <f64>i * RAIL_STEP, maxS);
            let fr = lclamp(sv / tr.step, 0, <f64>tr.n - 1.0001);
            let k = <i32>Math.floor(fr);
            let t = fr - <f64>k;
            let x = tr.px[k + 1] + (tr.px[k + 2] - tr.px[k + 1]) * t;
            let z = tr.pz[k + 1] + (tr.pz[k + 2] - tr.pz[k + 1]) * t;
            if (sv < 0) {
                let q = track.pos(tr, sv); // straight back along frame 0
                x = q.x;
                z = q.z;
            }
            f[(656 >> 2) + i * 2] = <f32>x;
            f[(656 >> 2) + i * 2 + 1] = <f32>z;
        }
        w4(f, 656 + RAIL_POINTS * 8, s0, RAIL_STEP, <f64>RAIL_POINTS, 1);
    } else {
        w4(f, 656 + RAIL_POINTS * 8, 0, RAIL_STEP, 0, 0);
    }
    r.waterUbo.update(0, d, <u32>WATER_BYTES);
}

// (JOB 26) the print rollers' edges on a w x h frame, as signed distances from its centre along the rollers'
// normal (cos 0.3, sin 0.3), in the frame's units: PrintScreen is fit cover on 1920 x 1080, the cards contain on
// 1920 x 1080 (landscape) / 1080 x 1920 (portrait); a point is printed where it lies past the edge (RE_P / RE_S)
let RE_P: f64 = 0;
let RE_S: f64 = 0;
function rollEdges(pl: Array<f64>, w: f64, h: f64): void {
    let por = pl[8] > 0.5;
    let sP = lmax(w / 1920, h / 1080);
    let sS = por ? lmin(w / 1080, h / 1920) : lmin(w / 1920, h / 1080);
    RE_P = sP * ((pl[3] - 960) * ROLL_COS - 580);
    RE_S = sS * ((pl[7] - (por ? 540 : 960)) * ROLL_COS - 580);
}

function writePost(r: Gfx, pal: Palette, lensX: f64, lensY: f64, lensR: f64, lensS: f64): void {
    let d = r.postData;
    let f = Float32Array.wrap(d);
    let p = r.post;
    w4(f, 0, r.fw, r.fh, 1 / r.fw, 1 / r.fh);
    w4(f, 16, p.exposure, p.vignette, p.speedLines, p.chroma);
    w4(f, 32, p.damage, p.fade, p.letterbox, r.time);
    w4(f, 48, p.fadeR, p.fadeG, p.fadeB, r.qScale < 1 ? 2 : 1);
    w4(f, 64, p.saturation, p.contrast, p.warmth, p.grain);
    w4(f, 80, p.flashR, p.flashG, p.flashB, p.flash);
    w4(f, 96, p.portal, p.portalX, p.portalY, p.portalR);
    w4(f, 112, p.focusX, p.focusY, p.bloom, p.edges);
    wc(f, 128, pal.ink, p.edgeFade);
    w4(f, 144, r.rw, r.rh, 1 / r.rw, 1 / r.rh);
    w4(f, 160, lensX, lensY, lensR, lensS);
    w4(f, 176, pal.biome, 1, p.creases, r.lensDist);
    // zoom smear: the boost-start kick, then a light edge blur while boosting
    let sk = r.smearKick;
    wc(f, 192, pal.fogColor, p.smear * lmax(sk * sk * (3 - 2 * sk), lclamp(r.boost, 0, 1) * 0.35));
    // stings: bullet-time grade, print flash (held value or the fired kick)
    let age = r.time - r.printT0;
    let kick = 0.0;
    if (age >= 0 && age < r.printDur) {
        let a = age / r.printDur;
        kick = r.printKick * (a < 0.14 ? 1 : Math.pow(1 - (a - 0.14) / 0.86, 2));
    }
    w4(f, 208, lclamp(p.slow, 0, 1), lclamp(lmax(p.print, kick), 0, 1), r.printAng, lmax(age, 0));
    w4(f, 224, inkSplitBias(r.quality), 0, 0, 0);
    // JOB 26: the print plates (amounts, roller edges in final-pass pixels)
    let pl = r.plates;
    rollEdges(pl, r.fw, r.fh);
    w4(f, 240, lclamp(pl[1], 0, 1), lclamp(pl[2], 0, 1), RE_P, RE_S);
    w4(f, 256, lclamp(pl[4], 0, 1), lclamp(pl[5], 0, 1), lclamp(pl[6], 0, 1), r.visorIn ? 1 : 0);
    r.postUbo.update(0, d, <u32>POST_BYTES);
}

function writeVisor(r: Gfx, pal: Palette): void {
    let d = r.visorData;
    let f = Float32Array.wrap(d);
    let v = r.visor;
    let aspect = r.ptW / r.ptH;
    let proj = perspective32(new Mat4(), <f32>(62 * Math.PI / 180), <f32>aspect, 0.05, 10);
    w4(f, 64, v.boot, v.glitch, v.opacity, r.time);
    w4(f, 80, v.tintR, v.tintG, v.tintB, v.tintA);
    w4(f, 96, v.scan, v.edgeGlow, v.flicker, v.chroma);
    let cw = lmax(1, r.hudW * r.hudScale);
    let ch = lmax(1, r.hudH * r.hudScale);
    w4(f, 112, 1 / cw, 1 / ch, v.glow, r.fh / 1080);
    let sky = pal.skyHorizon;
    let dmg = lmax(v.damageTint, r.post.damage * 0.8);
    w4(f, 128, sky[1], sky[2], sky[3], dmg);
    // live curvature: the visor boots in strongly wrapped and relaxes to its
    // resting curve with a small settle; boosting bulges it toward the wrap
    let b = lclamp(v.boot, 0, 1);
    let settle = (1 - b) * (1 - b) * 0.62 - Math.sin(b * Math.PI) * 0.05;
    let kT = v.curve + settle + lclamp(r.boost, 0, 1) * 0.24;
    let dtv = lclamp(r.time - r.visorKT, 0, 0.1);
    r.visorKT = r.time;
    r.visorK = b < 0.999 ? kT : mathx.damp(r.visorK, kT, 5, dtv);
    let k = lclamp(r.visorK, 0, 1.15);
    w4(f, 160, k, v.rim * 0.5, v.rim, VISOR_SKIRT);
    let wk = mathx.smoothstep(0.6, 0.9, b);
    let mvp = visorFit(r, v, proj, k, wk);
    let sw = VF_SW;
    mvp.writeToBuffer(d, 0);
    w4(f, 144, v.yaw * sw, v.pitch * sw, v.roll * sw, v.sheen);
    w4(f, 176, VF_P[0], VF_P[1], VF_P[2], VF_P[3]);
    w4(f, 192, VF_P[4], VF_P[5], VF_P[6], VF_P[7]);
    // the skirt's outer edge stays past the screen edge (not while booting)
    w4(f, 208, VISOR_SKIRT_REACH, wk, 0, 0);
    r.visorUbo.update(0, d, <u32>VISOR_BYTES);
}

// Draw helpers ------------------------------------------------------------------

@inline function ifmtOf(m: Mesh): u32 {
    let f = m.ifmt;
    return f != null && f == "uint16" ? <u32>IndexFormat.uint16 : <u32>IndexFormat.uint32;
}

// fading: draw only the batches on the sky-fade path (true) or only the others
// part: 1 = the opaque toon / reflection passes (ink-shell copies left out:
// they always lose the depth test there), 2 = the opaque hull pass (inked
// triangles only); 0 (Luau nil) = every triangle. Meshes without the lists draw all.
function drawBatches(r: Gfx, pass: GPURenderPass, pipe: GPUPipeline, bg: GPUBindGroup, onlyReflect: bool, onlyOutline: bool, fading: bool, part: i32 = 0): void {
    pass.setPipeline(pipe);
    pass.setBindGroup(0, bg);
    let bs = r.batches;
    for (let i = 0; i < bs.length; i++) {
        let b = bs[i];
        let hidden = onlyReflect ? b.hideRefl : b.hideMain;
        if (!hidden && (!onlyReflect || b.reflect) && (!onlyOutline || b.outline) && b.fading == fading) {
            let m = b.mesh;
            let ibuf = m.ib, cnt = <f64>m.count;
            let im = m.ibMain, ih = m.ibHull;
            if (part == 1 && im != null) {
                ibuf = im;
                cnt = opt(m.countMain, 0);
            } else if (part == 2 && ih != null) {
                ibuf = ih;
                cnt = opt(m.countHull, 0);
            }
            let vb = m.vb, ib2 = b.buf;
            if (cnt > 0 && ibuf != null && vb != null && ib2 != null) {
                pass.setVertexBuffer(0, vb);
                pass.setVertexBuffer(1, ib2);
                pass.setIndexBuffer(ibuf, ifmtOf(m));
                pass.drawIndexed(<u32>cnt, <u32>b.n);
                r.stats.draws += 1;
                r.stats.instances += b.n;
            }
        }
    }
}

function drawSprites(r: Gfx, pass: GPURenderPass, pipe: GPUPipeline, bg: GPUBindGroup, reflection: bool, overlay: bool): void {
    let bound = false;
    let last: GPUBindGroup? = null;
    for (let i = 0; i < r.sprites.length; i++) {
        let s = r.sprites[i];
        let A = r.atlases[s.ai];
        let abg = reflection ? A.bgRefl : overlay ? A.bgOver : A.bgMain;
        if (abg != null && s.vis && s.n > 0 && s.overlay == overlay && (!reflection || s.reflect) && (reflection || !s.reflOnly)) {
            if (!bound) {
                pass.setPipeline(pipe);
                pass.setBindGroup(0, bg);
                bound = true;
            }
            if (abg != last) {
                pass.setBindGroup(1, abg);
                last = abg;
            }
            pass.setVertexBuffer(0, s.buf);
            pass.draw(6, <u32>s.n);
            r.stats.draws += 1;
        }
    }
}

function drawSpriteMasks(r: Gfx, pass: GPURenderPass): void {
    let pipe = r.pBillboardMask, bg = r.bgBillboardMask;
    if (pipe == null || bg == null) return;
    let bound = false;
    let last: GPUBindGroup? = null;
    for (let i = 0; i < r.sprites.length; i++) {
        let s = r.sprites[i];
        let abg = r.atlases[s.ai].bgMask;
        if (abg != null && s.vis && s.solid && s.n > 0 && !s.overlay && !s.reflOnly) {
            if (!bound) {
                pass.setPipeline(pipe);
                pass.setBindGroup(0, bg);
                bound = true;
            }
            if (abg != last) {
                pass.setBindGroup(1, abg);
                last = abg;
            }
            pass.setVertexBuffer(0, s.buf);
            pass.draw(6, <u32>s.n);
            r.stats.draws += 1;
        }
    }
}

// Sphere vs the camera frustum (side planes + behind). my = -1 tests the
// water-mirrored position (reflection pass).
function inView(r: Gfx, x: f64, y: f64, z: f64, rad: f64, my: f64): bool {
    let e = r.camEye, f = r.camFwd;
    let dx = x - <f64>e.x, dy = y * my - <f64>e.y, dz = z - <f64>e.z;
    let d = dx * f.x + dy * f.y + dz * f.z;
    if (d < -rad) return false;
    let rt0 = r.camRight, up = r.camUp;
    let sx = dx * rt0.x + dy * rt0.y + dz * rt0.z;
    let sy = dx * up.x + dy * up.y + dz * up.z;
    let th = r.tanHalfV, tw = r.tanHalfH;
    if (Math.abs(sx) - d * tw > rad * Math.sqrt(1 + tw * tw)) return false;
    if (Math.abs(sy) - d * th > rad * Math.sqrt(1 + th * th)) return false;
    return true;
}

// r.nearFade > 0 (the death cam): every moving instance up to 8 m of
// radius (enemies, wrecks, debris; not the static scenery baked in world
// space, nor a boss hull whose bounds would swallow the lens: the camera
// keeps those out of the lens itself) whose bounding sphere comes within
// nearFade m of the lens fades out on the sky-fade path (gone inside 30%);
// ribbon ends and particles that close lose their alpha the same way.
const NEAR_FADE_MAX_R: f64 = 8;

function nearLensFade(r: Gfx): void {
    let nf = r.nearFade;
    if (nf <= 0) return;
    let e = r.camEye;
    let ex = <f64>e.x, ey = <f64>e.y, ez = <f64>e.z;
    for (let bi = 0; bi < r.batches.length; bi++) {
        let b = r.batches[bi];
        let m = b.mesh;
        if (b.n > 0 && m.count > 0 && m.maxx >= m.minx) {
            let mcx = (m.minx + m.maxx) * 0.5, mcy = (m.miny + m.maxy) * 0.5, mcz = (m.minz + m.maxz) * 0.5;
            let hx = (m.maxx - m.minx) * 0.5, hy = (m.maxy - m.miny) * 0.5, hz = (m.maxz - m.minz) * 0.5;
            let mr = Math.sqrt(hx * hx + hy * hy + hz * hz);
            let d = b.df;
            for (let i = 0; i <= b.n - 1; i++) {
                let o = i * 24;
                let c0x = <f64>d[o], c0y = <f64>d[o + 1], c0z = <f64>d[o + 2];
                let c1x = <f64>d[o + 4], c1y = <f64>d[o + 5], c1z = <f64>d[o + 6];
                let c2x = <f64>d[o + 8], c2y = <f64>d[o + 9], c2z = <f64>d[o + 10];
                let tx = <f64>d[o + 12], ty = <f64>d[o + 13], tz = <f64>d[o + 14];
                let isStatic = tx == 0 && ty == 0 && tz == 0 && c0x == 1 && c1y == 1 && c2z == 1;
                let sc = lmax(lmax(
                    Math.sqrt(c0x * c0x + c0y * c0y + c0z * c0z),
                    Math.sqrt(c1x * c1x + c1y * c1y + c1z * c1z)),
                    Math.sqrt(c2x * c2x + c2y * c2y + c2z * c2z)
                );
                let rad = mr * sc;
                if (!isStatic && rad <= NEAR_FADE_MAX_R) {
                    let cx = c0x * mcx + c1x * mcy + c2x * mcz + tx - ex;
                    let cy = c0y * mcx + c1y * mcy + c2y * mcz + ty - ey;
                    let cz = c0z * mcx + c1z * mcy + c2z * mcz + tz - ez;
                    let gap = Math.sqrt(cx * cx + cy * cy + cz * cz) - rad;
                    if (gap < nf) {
                        let u = 1 - mathx.smoothstep(nf * 0.3, nf, gap);
                        if (u > -<f64>d[o + 23]) gpu.setSkyFade(b, i + 1, u);
                    }
                }
            }
        }
    }
    // ribbons (the crash smoke streak, exhaust) and particles (explosion
    // puffs, debris, sparks) thin out the same way, per end / per particle
    let td = r.trailF;
    for (let i = 0; i <= r.trailN - 1; i++) {
        let o = i * 24;
        for (let k = 0; k <= 1; k++) {
            let q = o + k * 4;
            let dx = <f64>td[q] - ex, dy = <f64>td[q + 1] - ey, dz = <f64>td[q + 2] - ez;
            let gap = Math.sqrt(dx * dx + dy * dy + dz * dz) - <f64>td[q + 3];
            if (gap < nf) {
                let ao = o + 11 + k * 4;
                td[ao] = <f32>(<f64>td[ao] * mathx.smoothstep(nf * 0.3, nf, gap));
            }
        }
    }
    let pd = r.partF;
    for (let i = 0; i <= r.partN - 1; i++) {
        let o = i * 16;
        let dx = <f64>pd[o] - ex, dy = <f64>pd[o + 1] - ey, dz = <f64>pd[o + 2] - ez;
        let gap = Math.sqrt(dx * dx + dy * dy + dz * dz) - <f64>pd[o + 3] * 0.5;
        if (gap < nf) pd[o + 7] = <f32>(<f64>pd[o + 7] * mathx.smoothstep(nf * 0.3, nf, gap));
    }
}

// Per-frame culling: single-instance batches (scenery chunks) against the
// frustum and its mirror; sprites with no instance in view skip the atlas.
function cullQueues(r: Gfx): void {
    nearLensFade(r);
    for (let bi = 0; bi < r.batches.length; bi++) {
        let b = r.batches[bi];
        b.hideMain = false;
        b.hideRefl = false;
        // sky-fade path: some instance has extra.w < 0 (gpu.setSkyFade)
        let fading = false;
        if (b.skyFaded) {
            for (let i = 0; i <= b.n - 1; i++) {
                if (<f64>b.df[i * 24 + 23] < -0.001) {
                    fading = true;
                    break;
                }
            }
        }
        b.fading = fading;
        let m = b.mesh;
        if (b.n == 1 && m.count > 0 && m.maxx >= m.minx) {
            let d = b.df;
            // bounds sphere (object space)
            let mcx = (m.minx + m.maxx) * 0.5, mcy = (m.miny + m.maxy) * 0.5, mcz = (m.minz + m.maxz) * 0.5;
            let hx = (m.maxx - m.minx) * 0.5, hy = (m.maxy - m.miny) * 0.5, hz = (m.maxz - m.minz) * 0.5;
            let mr = Math.sqrt(hx * hx + hy * hy + hz * hz);
            let c0x = <f64>d[0], c0y = <f64>d[1], c0z = <f64>d[2];
            let c1x = <f64>d[4], c1y = <f64>d[5], c1z = <f64>d[6];
            let c2x = <f64>d[8], c2y = <f64>d[9], c2z = <f64>d[10];
            let tx = <f64>d[12], ty = <f64>d[13], tz = <f64>d[14];
            let cx = c0x * mcx + c1x * mcy + c2x * mcz + tx;
            let cy = c0y * mcx + c1y * mcy + c2y * mcz + ty;
            let cz = c0z * mcx + c1z * mcy + c2z * mcz + tz;
            let sc = lmax(lmax(
                Math.sqrt(c0x * c0x + c0y * c0y + c0z * c0z),
                Math.sqrt(c1x * c1x + c1y * c1y + c1z * c1z)),
                Math.sqrt(c2x * c2x + c2y * c2y + c2z * c2z)
            );
            let rad = mr * sc + 0.5;
            b.hideMain = !inView(r, cx, cy, cz, rad, 1);
            // mirrored: anything entirely under the water never reflects
            b.hideRefl = (cy + rad < 0) || !inView(r, cx, cy, cz, rad, -1);
            if (b.hideMain) r.stats.culled += 1;
            if (b.hideRefl && b.reflect) r.stats.culledRefl += 1;
        }
        if (fading && b.n > 0) {
            if (!b.hideMain) r.stats.fading += 1;
            if (!b.hideRefl && b.reflect) r.stats.fadingRefl += 1;
        }
    }
    for (let si = 0; si < r.sprites.length; si++) {
        let s = r.sprites[si];
        let vis = false;
        if (s.n > 0) {
            let d = s.df;
            for (let i = 0; i <= s.n - 1; i++) {
                let o = i * 16;
                let x = <f64>d[o], y = <f64>d[o + 1], z = <f64>d[o + 2];
                let rad = lmax(<f64>d[o + 4], <f64>d[o + 5]);
                if ((!s.reflOnly && inView(r, x, y, z, rad, 1)) || (s.reflect && !s.overlay && inView(r, x, y, z, rad, -1))) {
                    vis = true;
                    break;
                }
            }
        }
        s.vis = vis;
    }
}

function drawInstances(r: Gfx, pass: GPURenderPass, pipe: GPUPipeline?, bg: GPUBindGroup?, buf: GPUBuffer, n: i32): void {
    if (pipe != null && bg != null && n > 0) {
        pass.setPipeline(pipe);
        pass.setBindGroup(0, bg);
        pass.setVertexBuffer(0, buf);
        pass.draw(6, <u32>n);
        r.stats.draws += 1;
    }
}

// Wake history + automatic contact shadows from world sprites.
function gatherAuto(r: Gfx): void {
    let px = 0.0, py = 0.0, pz = 0.0, found = false;
    if (r.wakeSet) {
        px = r.wakeX;
        py = r.wakeY;
        pz = r.wakeZ;
        found = true;
    } else if (r.autoWake) {
        for (let i = 0; i < r.sprites.length; i++) {
            let s = r.sprites[i];
            if (s.name == "pilot" && s.n > 0) {
                px = <f64>s.df[0];
                py = <f64>s.df[1];
                pz = <f64>s.df[2];
                found = true;
                r.wakeStr = 1 - mathx.smoothstep(2.5, 7.0, py);
                break;
            }
        }
    }
    if (r.autoShadows) {
        for (let si = 0; si < r.sprites.length; si++) {
            let s = r.sprites[si];
            if (s.reflect && !s.overlay && !s.reflOnly) {
                let d = s.df;
                for (let i = 0; i <= s.n - 1; i++) {
                    let o = i * 16;
                    let x = <f64>d[o];
                    let y = <f64>d[o + 1];
                    let z = <f64>d[o + 2];
                    let w = <f64>d[o + 4];
                    let op = <f64>d[o + 7];
                    let k = 1 - mathx.smoothstep(0.5, 14.0, y);
                    shadow(r, x, z, w * (0.26 + 0.1 * (1 - k)), k * 0.8 * op);
                }
            }
        }
    }
    if (!found) {
        r.wakeStr = 0;
        r.wakeHistN = 0;
        return;
    }
    r.wakeX = px;
    r.wakeY = py;
    r.wakeZ = pz;
    let h = r.wakeHist;
    let n = r.wakeHistN;
    if (n > 0) {
        let dx = px - h[1], dz = pz - h[3];
        if (dx * dx + dz * dz > 60 * 60) {
            // teleport (restart / debug jump)
            n = 0;
        }
    }
    if (n == 0) {
        // seed a straight path behind the pilot along the heading; real history replaces it
        for (let i = 0; i <= WAKE_POINTS - 1; i++) {
            let o = i * 4;
            let back = i == 0 ? 0 : (<f64>i - 0.2) * WAKE_STEP;
            h[o + 1] = px - r.flowX * back;
            h[o + 2] = py;
            h[o + 3] = pz - r.flowZ * back;
            h[o + 4] = r.wakeStr;
        }
        r.wakeHistN = WAKE_POINTS;
        return;
    }
    // the newest point follows the pilot; a new one is pushed every WAKE_STEP meters
    let dx = px - h[5], dz = pz - h[7];
    if (dx * dx + dz * dz >= WAKE_STEP * WAKE_STEP) {
        for (let i = min(n, WAKE_POINTS - 1); i >= 1; i--) {
            let s = (i - 1) * 4, t = i * 4;
            h[t + 1] = h[s + 1];
            h[t + 2] = h[s + 2];
            h[t + 3] = h[s + 3];
            h[t + 4] = h[s + 4];
        }
        n = min(n + 1, WAKE_POINTS);
    }
    h[1] = px;
    h[2] = py;
    h[3] = pz;
    h[4] = r.wakeStr;
    r.wakeHistN = n;
}

// Follow the flight path: the rail distance nearest the pilot (or the eye).
@inline function railD2(xs: Array<f64>, zs: Array<f64>, i: i32, px: f64, pz: f64): f64 {
    let dx = xs[i] - px, dz = zs[i] - pz;
    return dx * dx + dz * dz;
}

function trackRail(r: Gfx): void {
    let tr = r.rail;
    if (tr == null || tr.n < 3) {
        r.railS = RAIL_OFF;
        return;
    }
    let px = <f64>r.camEye.x, pz = <f64>r.camEye.z;
    if (r.wakeHistN > 0) {
        px = r.wakeX;
        pz = r.wakeZ;
    }
    let n = tr.n, xs = tr.px, zs = tr.pz;
    let lo = 1, hi = n, stride = 8;
    if (r.railS > RAIL_OFF) {
        let c = <i32>lclamp(Math.floor(r.railS / tr.step) + 1, 1, <f64>n);
        if (railD2(xs, zs, c, px, pz) < 250 * 250) {
            lo = max(1, c - 60);
            hi = min(n, c + 160);
            stride = 1;
        }
    }
    let best = HUGE, bi = lo;
    for (let i = lo; i <= hi; i += stride) {
        let v = railD2(xs, zs, i, px, pz);
        if (v < best) {
            best = v;
            bi = i;
        }
    }
    if (stride > 1) {
        for (let i = max(1, bi - stride); i <= min(n, bi + stride); i++) {
            let v = railD2(xs, zs, i, px, pz);
            if (v < best) {
                best = v;
                bi = i;
            }
        }
    }
    r.railS = <f64>(bi - 1) * tr.step;
    if (bi == 1) {
        // behind the start: s < 0 along frame 0's heading
        let fx = tr.fx[1], fz = tr.fz[1];
        let fl = lmax(Math.sqrt(fx * fx + fz * fz), 1e-6);
        r.railS = lmin(0, ((px - xs[1]) * fx + (pz - zs[1]) * fz) / fl);
    }
}

// Flight path for the water foam (null: heading-aligned fallback).
export function setRail(r: Gfx, tr: Track?): void {
    r.rail = tr;
    r.railS = RAIL_OFF;
}

// (oracle captures, --define=MAT_FMA=1) rive::Mat4::invert as the native Luau
// runtime computes it: its compiler contracts the cofactor sums into fused
// multiply-adds. The AnimaScript host runs Mat4 natives unfused (as wasm and
// the web Luau runtime do): 1-ulp differences in vp / ivp. fma32 rounds
// through f64 (double rounding: rare).
declare const MAT_FMA: i32;

// (debug) --define=SKYDUMP=1: a SKY line per frame (camera, sky-ray matrix)
declare const SKYDUMP: i32;
let skyF = 0;
function skyDump(cam: Camera, aspect: f64, ivp: Mat4): void {
    skyF++;
    let e = cam.eye, c = cam.target, u = cam.up, m = ivp.m;
    let a: Array<FormatArg> = [N(skyF), N(e.x), N(e.y), N(e.z), N(c.x), N(c.y), N(c.z), N(u.x), N(u.y), N(u.z), N(cam.fov), N(aspect), N(cam.near), N(cam.far)];
    for (let i = 0; i < 16; i++) a.push(N(<f64>m[i]));
    console.log(format("SKY %d %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.17g %.17g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g", a));
}

@inline function fma32(a: f32, b: f32, c: f32): f32 {
    return <f32>(<f64>a * <f64>b + <f64>c);
}

// rive::Mat4 perspective / lookAt in f32, as the Luau lane computes them. The
// AnimaScript std Mat4 takes 1 / tan and 1 / sqrt in f64 (1-2 f32 ulp off).
function perspective32(out: Mat4, fov: f32, aspect: f32, near: f32, far: f32): Mat4 {
    let t = <f32>Math.tan(<f64>(fov * <f32>0.5));
    let f: f32 = <f32>1.0 / t;
    let nf: f32 = <f32>1.0 / (near - far);
    let m = out.m;
    for (let i = 0; i < 16; i++) m[i] = 0;
    m[0] = f / aspect;
    m[5] = f;
    m[10] = far * nf;
    m[14] = far * near * nf;
    m[11] = -1;
    return out;
}

function lookAt32(out: Mat4, e: Vector, c: Vector, u: Vector): Mat4 {
    let fx: f32 = c.x - e.x, fy: f32 = c.y - e.y, fz: f32 = c.z - e.z;
    let fl: f32, sx: f32, sy: f32, sz: f32;
    if (isDefined(MAT_FMA)) {
        fl = fma32(fz, fz, fma32(fx, fx, fy * fy));
    } else {
        fl = fx * fx + fy * fy + fz * fz;
    }
    let fInv: f32 = <f32>1.0 / <f32>Math.sqrt(<f64>fl);
    fx *= fInv;
    fy *= fInv;
    fz *= fInv;
    if (isDefined(MAT_FMA)) {
        sx = fma32(fy, u.z, -(fz * u.y));
        sy = fma32(fz, u.x, -(fx * u.z));
        sz = fma32(fx, u.y, -(fy * u.x));
    } else {
        sx = fy * u.z - fz * u.y;
        sy = fz * u.x - fx * u.z;
        sz = fx * u.y - fy * u.x;
    }
    let sl: f32 = isDefined(MAT_FMA) ? fma32(sz, sz, fma32(sx, sx, sy * sy)) : sx * sx + sy * sy + sz * sz;
    let sInv: f32 = <f32>1.0 / <f32>Math.sqrt(<f64>sl);
    sx *= sInv;
    sy *= sInv;
    sz *= sInv;
    let tx: f32, ty: f32, tz: f32;
    if (isDefined(MAT_FMA)) {
        tx = fma32(sy, fz, -(sz * fy));
        ty = fma32(sz, fx, -(sx * fz));
        tz = fma32(sx, fy, -(sy * fx));
    } else {
        tx = sy * fz - sz * fy;
        ty = sz * fx - sx * fz;
        tz = sx * fy - sy * fx;
    }
    let m = out.m;
    m[0] = sx;
    m[1] = tx;
    m[2] = -fx;
    m[3] = 0;
    m[4] = sy;
    m[5] = ty;
    m[6] = -fy;
    m[7] = 0;
    m[8] = sz;
    m[9] = tz;
    m[10] = -fz;
    m[11] = 0;
    if (isDefined(MAT_FMA)) {
        m[12] = -fma32(sz, e.z, fma32(sx, e.x, sy * e.y));
        m[13] = -fma32(tz, e.z, fma32(tx, e.x, ty * e.y));
        m[14] = fma32(fz, e.z, fma32(fx, e.x, fy * e.y));
    } else {
        m[12] = -(sx * e.x + sy * e.y + sz * e.z);
        m[13] = -(tx * e.x + ty * e.y + tz * e.z);
        m[14] = fx * e.x + fy * e.y + fz * e.z;
    }
    m[15] = 1;
    return out;
}

function invertFused(out: Mat4, src: Mat4): bool {
    let m = src.m;
    let i0 = fma32(-(m[13] * m[7]), m[10], fma32(m[13] * m[6], m[11], fma32(m[9] * m[7], m[14], fma32(-(m[9] * m[6]), m[15], fma32(m[5] * m[10], m[15], -((m[5] * m[11]) * m[14]))))));
    let i1 = fma32(m[13] * m[3], m[10], fma32(-(m[13] * m[2]), m[11], fma32(-(m[9] * m[3]), m[14], fma32(m[9] * m[2], m[15], fma32(-m[1] * m[10], m[15], (m[1] * m[11]) * m[14])))));
    let i2 = fma32(-(m[13] * m[3]), m[6], fma32(m[13] * m[2], m[7], fma32(m[5] * m[3], m[14], fma32(-(m[5] * m[2]), m[15], fma32(m[1] * m[6], m[15], -((m[1] * m[7]) * m[14]))))));
    let i3 = fma32(m[9] * m[3], m[6], fma32(-(m[9] * m[2]), m[7], fma32(-(m[5] * m[3]), m[10], fma32(m[5] * m[2], m[11], fma32(-m[1] * m[6], m[11], (m[1] * m[7]) * m[10])))));
    let i4 = fma32(m[12] * m[7], m[10], fma32(-(m[12] * m[6]), m[11], fma32(-(m[8] * m[7]), m[14], fma32(m[8] * m[6], m[15], fma32(-m[4] * m[10], m[15], (m[4] * m[11]) * m[14])))));
    let i5 = fma32(-(m[12] * m[3]), m[10], fma32(m[12] * m[2], m[11], fma32(m[8] * m[3], m[14], fma32(-(m[8] * m[2]), m[15], fma32(m[0] * m[10], m[15], -((m[0] * m[11]) * m[14]))))));
    let i6 = fma32(m[12] * m[3], m[6], fma32(-(m[12] * m[2]), m[7], fma32(-(m[4] * m[3]), m[14], fma32(m[4] * m[2], m[15], fma32(-m[0] * m[6], m[15], (m[0] * m[7]) * m[14])))));
    let i7 = fma32(-(m[8] * m[3]), m[6], fma32(m[8] * m[2], m[7], fma32(m[4] * m[3], m[10], fma32(-(m[4] * m[2]), m[11], fma32(m[0] * m[6], m[11], -((m[0] * m[7]) * m[10]))))));
    let i8 = fma32(-(m[12] * m[7]), m[9], fma32(m[12] * m[5], m[11], fma32(m[8] * m[7], m[13], fma32(-(m[8] * m[5]), m[15], fma32(m[4] * m[9], m[15], -((m[4] * m[11]) * m[13]))))));
    let i9 = fma32(m[12] * m[3], m[9], fma32(-(m[12] * m[1]), m[11], fma32(-(m[8] * m[3]), m[13], fma32(m[8] * m[1], m[15], fma32(-m[0] * m[9], m[15], (m[0] * m[11]) * m[13])))));
    let i10 = fma32(-(m[12] * m[3]), m[5], fma32(m[12] * m[1], m[7], fma32(m[4] * m[3], m[13], fma32(-(m[4] * m[1]), m[15], fma32(m[0] * m[5], m[15], -((m[0] * m[7]) * m[13]))))));
    let i11 = fma32(m[8] * m[3], m[5], fma32(-(m[8] * m[1]), m[7], fma32(-(m[4] * m[3]), m[9], fma32(m[4] * m[1], m[11], fma32(-m[0] * m[5], m[11], (m[0] * m[7]) * m[9])))));
    let i12 = fma32(m[12] * m[6], m[9], fma32(-(m[12] * m[5]), m[10], fma32(-(m[8] * m[6]), m[13], fma32(m[8] * m[5], m[14], fma32(-m[4] * m[9], m[14], (m[4] * m[10]) * m[13])))));
    let i13 = fma32(-(m[12] * m[2]), m[9], fma32(m[12] * m[1], m[10], fma32(m[8] * m[2], m[13], fma32(-(m[8] * m[1]), m[14], fma32(m[0] * m[9], m[14], -((m[0] * m[10]) * m[13]))))));
    let i14 = fma32(m[12] * m[2], m[5], fma32(-(m[12] * m[1]), m[6], fma32(-(m[4] * m[2]), m[13], fma32(m[4] * m[1], m[14], fma32(-m[0] * m[5], m[14], (m[0] * m[6]) * m[13])))));
    let i15 = fma32(-(m[8] * m[2]), m[5], fma32(m[8] * m[1], m[6], fma32(m[4] * m[2], m[9], fma32(-(m[4] * m[1]), m[10], fma32(m[0] * m[5], m[10], -((m[0] * m[6]) * m[9]))))));
    let det = fma32(m[3], i12, fma32(m[2], i8, fma32(m[0], i0, m[1] * i4)));
    if (det == 0) return false;
    let id: f32 = <f32>1.0 / det;
    let o = out.m;
    o[0] = i0 * id;
    o[1] = i1 * id;
    o[2] = i2 * id;
    o[3] = i3 * id;
    o[4] = i4 * id;
    o[5] = i5 * id;
    o[6] = i6 * id;
    o[7] = i7 * id;
    o[8] = i8 * id;
    o[9] = i9 * id;
    o[10] = i10 * id;
    o[11] = i11 * id;
    o[12] = i12 * id;
    o[13] = i13 * id;
    o[14] = i14 * id;
    o[15] = i15 * id;
    return true;
}

function invert4(out: Mat4, src: Mat4): bool {
    if (isDefined(MAT_FMA)) return invertFused(out, src);
    return Mat4.invert(out, src);
}

// out = a * b (Mat4.multiply; fused as rive::Mat4::multiply under MAT_FMA)
function multiply4(out: Mat4, a: Mat4, b: Mat4): Mat4 {
    if (!isDefined(MAT_FMA)) return Mat4.multiply(out, a, b);
    let L = a.m, Rm = b.m, o = out.m;
    for (let j = 0; j < 4; j++) {
        let r0 = Rm[j * 4], r1 = Rm[j * 4 + 1], r2 = Rm[j * 4 + 2], r3 = Rm[j * 4 + 3];
        for (let i = 0; i < 4; i++) {
            o[j * 4 + i] = fma32(L[12 + i], r3, fma32(L[8 + i], r2, fma32(L[i], r0, L[4 + i] * r1)));
        }
    }
    return out;
}

// T4 = m * (x, y, z, w) (Mat4.transformVec4; fused as rive::Mat4 under MAT_FMA)
function xform4(m: Mat4, x: f32, y: f32, z: f32, w: f32): void {
    if (!isDefined(MAT_FMA)) {
        m.transformVec4(T4, x, y, z, w);
        return;
    }
    let a = m.m;
    for (let i = 0; i < 4; i++) T4[i] = fma32(a[12 + i], w, fma32(a[8 + i], z, fma32(a[i], x, a[4 + i] * y)));
}

// Frame ---------------------------------------------------------------------------

function resetQueues(r: Gfx): void {
    r.batches.length = 0;
    for (let i = 0; i < r.sprites.length; i++) r.sprites[i].n = 0;
    r.partN = 0;
    r.trailN = 0;
    r.portalN = 0;
    r.shadowN = 0;
    r.spotN = 0;
    r.wakeSet = false;
}

// (Luau gpuUsable probed once for the deferred recorder and skipped the world
// under --immediate; there is no pcall here, so that mode is not handled.)

// First-use warm-up (QA L28): painted poses, portraits and brand art each pay
// a texture upload the first time they are drawn (~0.1-0.3 ms each here, the
// 107 pose images ~7-25 ms in one frame); draw them all once, WARM_PER_FRAME a
// frame, into a 16 x 16 canvas that is never shown.
const WARM_PER_FRAME: i32 = 8;

function warmImages(r: Gfx): void {
    let names = IMAGE_NAMES;
    let n = names.length - 1;
    if (r.warmI > n) return;
    let c = r.warmCanvas;
    if (c == null) {
        c = r.ctx.canvas(16, 16);
        r.warmCanvas = c;
    }
    if (c == null) return;
    let wr = c.beginFrame(0);
    if (wr == null) return;
    let smp = ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear);
    for (let k = 1; k <= WARM_PER_FRAME; k++) {
        if (r.warmI > n) break;
        let nm = names[r.warmI];
        r.warmI += 1;
        let im = r.ctx.image(nm);
        if (im != null && im.width > 0 && im.height > 0) {
            wr.save();
            wr.transform(Mat2D.withScale(<f32>(4.0 / <f64>im.width), <f32>(4.0 / <f64>im.height)));
            wr.drawImage(im, smp, BlendMode.srcOver, 1);
            wr.restore();
        }
    }
    c.endFrame();
    if (r.warmI > n) r.warmCanvas = null;
}

// 1. artboards -> canvases (HUD, sprite atlases).
function draw2d(r: Gfx, fn: i32): void {
    // HUD: every hudEvery frames (on even frames, alternating with atlas 2),
    // immediately when it appears or was resized
    let hc = r.hudCanvas, hart = r.hudArt;
    if (hc != null && hart != null && r.visor.opacity > 0.001) {
        let ev = hudInterval(r, r.dtAvg, r.hudFast);
        if (r.hudDirty || r.bgVisor == null || fn % ev == 0) {
            if (r.hudLag > 0) {
                // a raster hudDue did not foresee: never draw a stale HUD
                // (counted; 0 in the identity runs)
                r.stats.hudLate += 1;
                hart.advance(r.hudLag);
                r.hudLag = 0;
            }
            let hr = hc.beginFrame(0);
            if (hr != null) {
                hr.save();
                hr.transform(Mat2D.withScale(<f32>r.hudScale, <f32>r.hudScale));
                hart.draw(hr);
                hr.restore();
                hc.endFrame();
                r.hudDirty = false;
                if (r.bgVisor == null) buildVisorBG(r);
            }
        }
    } else {
        r.hudDirty = true;
    }
    // sprite artboards into their atlases: one flush per atlas that is due
    for (let ai = 1; ai <= 3; ai++) {
        let A = r.atlases[ai];
        let at = A.canvas;
        if (at != null) {
            let any = false, stale = false;
            for (let i = 0; i < r.sprites.length; i++) {
                let s = r.sprites[i];
                if (s.ai == ai && s.vis && s.art != null) {
                    any = true;
                    if (!s.fresh) stale = true;
                }
            }
            let due = A.every <= 1 || fn % A.every == A.phase || stale || A.bgMain == null;
            if (any && due) {
                let ar = at.beginFrame(0);
                if (ar != null) {
                    for (let i = 0; i < r.sprites.length; i++) {
                        let s = r.sprites[i];
                        if (s.ai == ai) {
                            let art = s.art, cp = s.clip;
                            s.fresh = false;
                            if (s.vis && art != null && cp != null && art.width > 0 && art.height > 0) {
                                ar.save();
                                ar.clipPath(cp);
                                ar.transform(Mat2D.withScaleAndTranslation(<f32>(s.aw / art.width), <f32>(s.ah / art.height), <f32>s.ax, <f32>s.ay));
                                art.draw(ar);
                                ar.restore();
                                s.drawn = true;
                                s.fresh = true;
                                r.stats.sprites += 1;
                            }
                        }
                    }
                    at.endFrame();
                    if (A.bgDirty) buildAtlasBGs(r, A);
                }
            }
        }
    }
    warmImages(r);
}

// Screen v (0 top .. 1 bottom) of the highest point of the water horizon: the
// vanishing line of horizontal directions, evaluated at both screen edges.
function horizonTop(r: Gfx, vp: Mat4): f64 {
    let f = r.camFwd;
    let hl = Math.sqrt(<f64>f.x * f.x + <f64>f.z * f.z);
    if (hl < 0.02) return 0;
    let hx = <f64>f.x / hl, hz = <f64>f.z / hl;
    xform4(vp, <f32>(hx - hz), 0, <f32>(hz + hx), 0);
    let ax = <f64>T4[0], ay = <f64>T4[1], aw = <f64>T4[3];
    xform4(vp, <f32>(hx + hz), 0, <f32>(hz - hx), 0);
    let bx = <f64>T4[0], by = <f64>T4[1], bw = <f64>T4[3];
    if (aw <= 1e-5 || bw <= 1e-5) return 0;
    let u1 = ax / aw * 0.5 + 0.5, v1 = 0.5 - ay / aw * 0.5;
    let u2 = bx / bw * 0.5 + 0.5, v2 = 0.5 - by / bw * 0.5;
    if (Math.abs(u2 - u1) < 1e-5) return 0;
    let k = (v2 - v1) / (u2 - u1);
    let vl = v1 + (0 - u1) * k;
    let vr = v1 + (1 - u1) * k;
    return lmin(vl, vr);
}

// Final pass into Rive's render target ----------------------------------------

// (JOB 26) one print plate on a colour (1-based rgb), as post.wgsl plateInk: desaturate, colorBurn, screen the
// ink, multiply the paper, each by the amount
function plateInk(c: Array<f64>, a: f64, ink: Array<f64>, paper: Array<f64>, b: f64): void {
    if (a <= 0) return;
    let l = 0.30 * c[1] + 0.59 * c[2] + 0.11 * c[3];
    for (let k = 1; k <= 3; k++) {
        let x = c[k] + (l - c[k]) * a;
        let bu = x >= 1 ? 1 : lmax(0, 1 - (1 - x) / b);
        x += (bu - x) * a;
        x += a * ink[k] * (1 - x);
        c[k] = x * (1 - a + a * paper[k]);
    }
}

const P_BLUE_INK: Array<f64> = [0.0, 36.0 / 255, 51.0 / 255, 181.0 / 255];
const P_PAPER: Array<f64> = [0.0, 242.0 / 255, 236.0 / 255, 222.0 / 255];
const P_RED_INK: Array<f64> = [0.0, 158.0 / 255, 24.0 / 255, 70.0 / 255];
const P_RED_PAPER: Array<f64> = [0.0, 246.0 / 255, 232.0 / 255, 228.0 / 255];
const P_DENSE_INK: Array<f64> = [0.0, 23.0 / 255, 32.0 / 255, 127.0 / 255];
const P_CRIM_INK: Array<f64> = [0.0, 216.0 / 255, 36.0 / 255, 95.0 / 255];
const P_CRIM_PAPER: Array<f64> = [0.0, 244.0 / 255, 230.0 / 255, 218.0 / 255];

// (JOB 26) a convex polygon (x, y, x, y, ... 1-based) cut to the part past a roller edge e (rollEdges) on a
// frame centred on (cx, cy)
function rollClip(poly: Array<f64>, cx: f64, cy: f64, e: f64): Array<f64> {
    let out: Array<f64> = [0.0];
    let n = (poly.length - 1) / 2;
    for (let i = 1; i <= n; i++) {
        let j = i % n + 1;
        let x1 = poly[2 * i - 1], y1 = poly[2 * i], x2 = poly[2 * j - 1], y2 = poly[2 * j];
        let d1 = (x1 - cx) * ROLL_COS + (y1 - cy) * ROLL_SIN - e;
        let d2 = (x2 - cx) * ROLL_COS + (y2 - cy) * ROLL_SIN - e;
        if (d1 >= 0) {
            out.push(x1);
            out.push(y1);
        }
        if ((d1 >= 0) != (d2 >= 0)) {
            let t = d1 / (d1 - d2);
            out.push(x1 + (x2 - x1) * t);
            out.push(y1 + (y2 - y1) * t);
        }
    }
    return out;
}

// A frame that draws no 3D: the layout gets the old Main background (a Rive
// fill, so it covers the render target too, which the host clears to its own
// colour when no pass writes it). Sized from resize's last layout, so it
// works even when the renderer never came up.
// (JOB 26) The navy is printed by the plates up behind their rollers, as the screens' layers printed it: the
// unprinted fill, then the parts past PrintScreen's edge, past the cards' edge, past both
function coverLayout(r: Gfx, renderer2d: Renderer): void {
    let w = r.layW, h = r.layH;
    if (w <= 0 || h <= 0) return;
    let pl = r.plates;
    rollEdges(pl, w, h);
    let edgeP = RE_P, edgeS = RE_S;
    let onP = pl[1] > 0 || pl[2] > 0, onS = pl[4] > 0 || pl[5] > 0 || pl[6] > 0;
    for (let k = 1; k <= 4; k++) {
        let inP = k == 2 || k == 4, inS = k >= 3;
        let poly: Array<f64> = [0.0, 0, 0, w, 0, w, h, 0, h];
        if (inP) poly = onP ? rollClip(poly, w / 2, h / 2, edgeP) : [0.0];
        if (inS) poly = onS ? rollClip(poly, w / 2, h / 2, edgeS) : [0.0];
        if (poly.length - 1 >= 6) {
            let c: Array<f64> = [0.0, 11.0 / 255, 16.0 / 255, 32.0 / 255];
            if (inP) {
                plateInk(c, pl[1], P_RED_INK, P_RED_PAPER, 168.0 / 255);
                plateInk(c, pl[2], P_BLUE_INK, P_PAPER, 178.0 / 255);
            }
            if (inS) {
                plateInk(c, pl[4], P_CRIM_INK, P_CRIM_PAPER, 158.0 / 255);
                plateInk(c, pl[5], P_DENSE_INK, P_PAPER, 147.0 / 255);
                plateInk(c, pl[6], P_BLUE_INK, P_PAPER, 178.0 / 255);
            }
            let cp0 = r.coverPaths[k];
            let cp: Path = cp0 != null ? cp0 : new Path();
            let pt0 = r.coverPaints[k];
            let paint: Paint = pt0 != null ? pt0 : new Paint();
            r.coverPaths[k] = cp;
            r.coverPaints[k] = paint;
            paint.color = Color.rgb(<i32>Math.floor(c[1] * 255 + 0.5), <i32>Math.floor(c[2] * 255 + 0.5), <i32>Math.floor(c[3] * 255 + 0.5));
            cp.reset();
            cp.moveTo(Vector.xy(<f32>poly[1], <f32>poly[2]));
            for (let i = 3; i <= poly.length - 2; i += 2) cp.lineTo(Vector.xy(<f32>poly[i], <f32>poly[i + 1]));
            cp.close();
            renderer2d.drawPath(cp, paint);
        }
    }
}

// post writes display-encoded 0..1 values: only plain 8-bit unorm surfaces take
// them as they are (an sRGB, rgba16float / EDR or rgb10a2 surface would
// re-encode them or read them as linear), so anything else keeps the canvas
function fmtName(fmt: i32): string {
    if (fmt == <i32>TextureFormat.bgra8unorm) return "bgra8unorm";
    if (fmt == <i32>TextureFormat.rgba8unorm) return "rgba8unorm";
    if (fmt == <i32>TextureFormat.rgba16float) return "rgba16float";
    if (fmt == <i32>TextureFormat.rgb10a2unorm) return "rgb10a2unorm";
    return "format " + fmt.toString();
}

@inline function directFmt(fmt: i32): bool {
    return fmt == <i32>TextureFormat.bgra8unorm || fmt == <i32>TextureFormat.rgba8unorm;
}

// Post, visor and blit pipelines for the target's format and sample count.
// Each shares its canvas twin's group-0 layout, so the same bind groups serve
// both paths (getBindGroupLayout must not be called on these: it errors on a
// pipeline built with bindGroupLayouts). (Luau latched a failure and kept the
// canvas path; here a failure raises.)
function buildTargetPipelines(r: Gfx, fmt: i32, sc: i32): void {
    r.pPostT = null;
    r.pVisorT = null;
    r.pBlitT = null;
    r.pPostBT = null;
    r.tFmt = fmt;
    r.tSamples = sc;
    let pp = r.pPost, pv = r.pVisor, sPo = r.shPost, sV = r.shVisor, sBt = r.shBlit;
    if (pp == null || pv == null || sPo == null || sV == null || sBt == null) return;
    let tf = <TextureFormat>fmt;
    let dp = pipeDesc(sPo, "fs_main", [], [ct(tf)]);
    dp.vertexEntryPoint = "vs_main";
    dp.bindGroupLayouts = [pp.getBindGroupLayout(0)];
    dp.sampleCount = <u32>sc;
    let dv = pipeDesc(sV, "fs_main", [VISOR_LAYOUT], [ct(tf, PREMUL)]);
    dv.vertexEntryPoint = "vs_main";
    dv.bindGroupLayouts = [pv.getBindGroupLayout(0)];
    dv.cullMode = CullMode.none;
    dv.sampleCount = <u32>sc;
    let db = pipeDesc(sBt, "fs_main", [], [ct(tf)]);
    db.vertexEntryPoint = "vs_main";
    db.sampleCount = <u32>sc;
    r.pPostT = new GPUPipeline(dp);
    r.pVisorT = new GPUPipeline(dv);
    r.pBlitT = new GPUPipeline(db);
    let pb = r.pPostB;
    if (pb != null) {
        let dt = pipeDesc(sPo, "fs_tail", [], [ct(tf)]);
        dt.vertexEntryPoint = "vs_main";
        dt.bindGroupLayouts = [pb.getBindGroupLayout(0)];
        dt.sampleCount = <u32>sc;
        r.pPostBT = new GPUPipeline(dt);
    }
    r.bgCvBlit = null;
}

// Rive's render target when this frame's final pass can go straight into it,
// the path (FT_PATH), and (canvas) why not (FT_WHY):
// - 'direct': post + visor into the target (under all Rive content);
// - 'blit': past maxOutputPixels post stays capped in the canvas, and one
//   bilinear pass copies it into the target (as drawImage upscaled it);
// - 'canvas': the GPUCanvas + drawImage, when the host exposes no target,
//   hides it this frame, recreated it this frame (size, format or sample
//   count changed; GPUTARGET_REVIEW), the layout does not cover it exactly
//   (fit not 'layout', or a scale that is not the pixel ratio: a script cannot
//   read where its layout sits), the format is not plain 8-bit unorm, or its
//   pipelines are missing.
let FT_PATH: string = "";
let FT_WHY: string = "";
function finalTarget(r: Gfx): GPUTarget? {
    let m = r.finalMode;
    FT_WHY = "";
    if (m == "canvas") {
        FT_PATH = "canvas";
        FT_WHY = "forced";
        return null;
    }
    if (r.noTarget) {
        FT_PATH = "canvas";
        FT_WHY = r.noTargetWhy;
        return null;
    }
    let t = r.ctx.gpuTarget();
    if (t == null) {
        r.noTarget = true;
        r.noTargetWhy = "host has no target";
        FT_PATH = "canvas";
        FT_WHY = r.noTargetWhy;
        return null;
    }
    if (t.view == null) {
        r.tPrevW = -1; // the next shown frame counts as a change (the host may recreate it)
        FT_PATH = "canvas";
        FT_WHY = "hidden";
        return null;
    }
    let tw = <f64>t.width, th = <f64>t.height, fmt = <i32>t.format, sc = <i32>t.sampleCount;
    let pw = r.tPrevW;
    let changed = pw < 0 || (pw > 0 && (tw != pw || th != r.tPrevH || fmt != r.tPrevFmt || sc != r.tPrevSc));
    r.tPrevW = tw;
    r.tPrevH = th;
    r.tPrevFmt = fmt;
    r.tPrevSc = sc;
    FT_PATH = "canvas";
    if (changed) {
        FT_WHY = "target changed";
        return null;
    }
    let w = opt(r.pendW, r.ptW), h = opt(r.pendH, r.ptH), s = opt(r.pendS, r.scale);
    if (tw < 2 || th < 2 || Math.abs(w * s - tw) > 2 || Math.abs(h * s - th) > 2) {
        FT_WHY = "layout";
        return null;
    }
    if (!directFmt(fmt)) {
        FT_WHY = "format";
        return null;
    }
    if (fmt != r.tFmt || sc != r.tSamples) buildTargetPipelines(r, fmt, sc);
    if (r.pPostT == null || (r.postSplit && r.pPostBT == null)) {
        FT_WHY = "pipelines";
        return null;
    }
    r.tw = tw;
    r.th = th;
    if (m == "auto") {
        m = tw * th <= r.maxOutputPixels ? "direct" : "blit";
    }
    FT_PATH = m;
    return t;
}

// direct frames before the fallback canvas gives its memory back (it comes back
// at full size on the next frame that needs it)
const CANVAS_IDLE: i32 = 120;

// The fallback canvas, created on the first frame that needs it and sized to
// this frame's output there (applyResize no longer touches it).
function ensureCanvas(r: Gfx): GPUCanvas? {
    let old = r.canvas;
    let cv: GPUCanvas? = null;
    if (old == null) {
        cv = r.ctx.gpuCanvas(<u32>r.ow, <u32>r.oh);
        r.canvas = cv;
        r.cvGen += 1;
    } else {
        cv = old;
        if (r.cvW != r.ow || r.cvH != r.oh) {
            old.resize(<u32>r.ow, <u32>r.oh);
            r.cvGen += 1;
        }
    }
    r.cvW = r.ow;
    r.cvH = r.oh;
    r.cvIdle = 0;
    return cv;
}

// (direct frames) count the canvas's idle frames and shrink it once idle
function idleCanvas(r: Gfx): void {
    let cv = r.canvas;
    if (cv == null || r.cvW <= 2) return;
    r.cvIdle += 1;
    if (r.cvIdle >= CANVAS_IDLE) {
        cv.resize(2, 2);
        r.cvW = 2;
        r.cvH = 2;
        r.cvGen += 1;
        r.bgCvBlit = null; // (it would keep the full-size view alive)
    }
}

// JOB 26: the visor drawn alone into an offscreen the final pass's size, so post can composite it and print it with
// the world (the screens' plates printed the HUD). Made on the first frame that needs it, released after
// CANVAS_IDLE frames without; post's bind groups follow it.
function ensureVisorOff(r: Gfx): bool {
    let w = r.fw, h = r.fh;
    if (w < 1 || h < 1) return false;
    if (r.visorOff == null || r.visorOffW != w || r.visorOffH != h) {
        let v = rt(w, h, TextureFormat.rgba8unorm);
        r.visorOff = v;
        let ca = new GPUColorAttachment();
        ca.view = v;
        ca.clearA = 0;
        let d = new GPUPassDesc();
        d.color = [ca];
        r.visorOffDesc = d;
        r.visorOffW = w;
        r.visorOffH = h;
        postBGs(r);
    }
    r.visorOffIdle = 0;
    return r.bgPost != null;
}

function idleVisorOff(r: Gfx): void {
    if (r.visorOff == null) return;
    r.visorOffIdle += 1;
    if (r.visorOffIdle >= CANVAS_IDLE) {
        r.visorOff = null;
        r.visorOffDesc = null;
        r.visorOffW = 0;
        r.visorOffH = 0;
        postBGs(r);
    }
}

// (blit) the bind group sampling the canvas, rebuilt when the canvas changes
function cvBlitBG(r: Gfx, cv: GPUCanvas): GPUBindGroup? {
    let pb = r.pBlitT;
    if (pb == null) return null;
    if (r.bgCvBlit == null || r.bgCvBlitGen != r.cvGen) {
        r.bgCvBlit = new GPUBindGroup(pb.getBindGroupLayout(0), [], [new GPUBindGroupTexture(1, cv.colorView())], [new GPUBindGroupSampler(0, r.linear)]);
        r.bgCvBlitGen = r.cvGen;
    }
    return r.bgCvBlit;
}

function drawPost(pass: GPURenderPass, pp: GPUPipeline?, bgp: GPUBindGroup?): void {
    if (pp != null && bgp != null) {
        pass.setPipeline(pp);
        pass.setBindGroup(0, bgp);
        pass.draw(3);
    }
}

function drawVisor(r: Gfx, pass: GPURenderPass, pv: GPUPipeline?): void {
    let bgv = r.bgVisor, vvb = r.visorVB, vib = r.visorIB;
    if (pv != null && bgv != null && vvb != null && vib != null && r.visor.opacity > 0.001) {
        pass.setPipeline(pv);
        pass.setBindGroup(0, bgv);
        pass.setVertexBuffer(0, vvb);
        pass.setIndexBuffer(vib, <u32>IndexFormat.uint32);
        pass.drawIndexed(<u32>r.visorCount);
    }
}

function drawBlit(r: Gfx, pass: GPURenderPass, cv: GPUCanvas): void {
    let pb = r.pBlitT, bg = cvBlitBG(r, cv);
    if (pb != null && bg != null) {
        pass.setPipeline(pb);
        pass.setBindGroup(0, bg);
        pass.draw(3);
    }
}

function colorAtt(view: GPUTextureView, resolve: GPUTextureView?, store: StoreOp, a: f32): GPUColorAttachment {
    let ca = new GPUColorAttachment();
    ca.view = view;
    ca.resolveTarget = resolve;
    ca.loadOp = LoadOp.clear;
    ca.storeOp = store;
    ca.clearA = a;
    return ca;
}

// The frame's render-pass descriptors, built once per set of target views
// (EFFICIENCY_REVIEW 1.6: they were ~40 tables a frame). The sky clear
// colours are written into the cached attachments each frame.
function passDescs(r: Gfx, reflView: GPUTextureView, reflDepthView: GPUTextureView, msaaView: GPUTextureView, msaaGView: GPUTextureView,
    hdrView: GPUTextureView, gbufView: GPUTextureView, depthView: GPUTextureView): PassDescs {
    let pd = r.passDescs;
    let nl = r.bloomN, bv = r.bloomViews;
    if (pd != null) {
        let ok = pd.kRefl == reflView && pd.kReflDepth == reflDepthView && pd.kMsaa == msaaView && pd.kMsaaG == msaaGView && pd.kHdr == hdrView
            && pd.kGbuf == gbufView && pd.kDepth == depthView && pd.kSamples == r.samples && pd.kBloomN == nl;
        if (ok) {
            let bk = pd.bloomKey;
            for (let i = 1; i <= nl; i++) {
                if (bk[i] != bv[i]) {
                    ok = false;
                    break;
                }
            }
        }
        if (ok) return pd;
    }
    let reflClear = colorAtt(reflView, null, StoreOp.store, 0);
    let refl = new GPUPassDesc();
    refl.color = [reflClear];
    refl.depthView = reflDepthView;
    refl.depthLoadOp = LoadOp.clear;
    refl.depthStoreOp = StoreOp.discard;
    refl.depthClearValue = 1;
    let skyClear: GPUColorAttachment;
    let gbClear: GPUColorAttachment;
    if (r.samples > 1) {
        skyClear = colorAtt(msaaView, hdrView, StoreOp.discard, 1);
        gbClear = colorAtt(msaaGView, gbufView, StoreOp.discard, GBUF_CLEAR_W);
    } else {
        skyClear = colorAtt(hdrView, null, StoreOp.store, 1);
        gbClear = colorAtt(gbufView, null, StoreOp.store, GBUF_CLEAR_W);
    }
    let main = new GPUPassDesc();
    main.color = [skyClear, gbClear];
    main.depthView = depthView;
    main.depthLoadOp = LoadOp.clear;
    main.depthStoreOp = StoreOp.discard;
    main.depthClearValue = 1;
    let nd = new PassDescs(reflView, reflDepthView, msaaView, msaaGView, hdrView, gbufView, depthView, r.samples, nl, reflClear, skyClear, refl, main);
    nd.bloomKey.push(hdrView); // (slot 0 unused)
    nd.bloomDown.push(main);
    nd.bloomUp.push(main);
    for (let i = 1; i <= nl; i++) {
        let v = bv[i]!;
        nd.bloomKey.push(v);
        let dd = new GPUPassDesc();
        dd.color = [colorAtt(v, null, StoreOp.store, 1)];
        nd.bloomDown.push(dd);
        let ua = new GPUColorAttachment();
        ua.view = v;
        ua.loadOp = LoadOp.load;
        ua.storeOp = StoreOp.store;
        let du = new GPUPassDesc();
        du.color = [ua];
        nd.bloomUp.push(du);
    }
    r.passDescs = nd;
    return nd;
}

export function frame(r: Gfx, renderer2d: Renderer, cam: Camera, pal: Palette, time: f64): void {
    // apply a settled (or start-up) resize BEFORE any target is captured below
    let pw0 = r.pendW, ph0 = r.pendH, ps0 = r.pendS;
    if (!isNaN(pw0) && !isNaN(ph0) && !isNaN(ps0) && (time - r.pendAt >= 0.2 || time < 0.5)) {
        r.pendW = NaN;
        r.pendH = NaN;
        r.pendS = NaN;
        applyResize(r, pw0, ph0, ps0);
    }
    let msaaView = r.msaaView, msaaGView = r.msaaGView, depthView = r.depthView, hdrView = r.hdrView, gbufView = r.gbufView;
    let reflView = r.reflView, reflDepthView = r.reflDepthView;
    if (!r.ok || r.rw == 0 || msaaView == null || msaaGView == null || depthView == null || hdrView == null || gbufView == null || reflView == null || reflDepthView == null) {
        coverLayout(r, renderer2d);
        return;
    }
    // final destination; the canvas exists only once a frame needs it
    let tgt = finalTarget(r);
    let path = FT_PATH, why = FT_WHY;
    let cv: GPUCanvas? = null;
    if (path == "direct") {
        idleCanvas(r);
    } else {
        cv = ensureCanvas(r);
    }
    if (path != r.finalPath) {
        // one greppable line per change (QA), capped so a host that hides the
        // view every other frame, or a window drag, cannot flood the log
        r.finalPath = path;
        r.pathLog += 1;
        if (r.pathLog <= 40) {
            let info = "";
            if (tgt != null) {
                let tw = <f64>tgt.width, th = <f64>tgt.height, ts = <f64>tgt.sampleCount;
                // (post runs at the target's size on the direct path, capped in the canvas on 'blit')
                let pw = path == "direct" ? tw : r.ow, ph = path == "direct" ? th : r.oh;
                info = format(" (target %dx%d %s x%d, post %dx%d)", [N(tw), N(th), S(fmtName(<i32>tgt.format)), N(ts), N(pw), N(ph)]);
            } else {
                info = " (" + why + ")";
            }
            log(r, "renderer: final pass -> " + path + info);
        }
    }
    if (path == "direct") {
        r.fw = r.tw;
        r.fh = r.th;
    } else {
        r.fw = r.ow;
        r.fh = r.oh;
    }
    // passes are opened on the target or the canvas (explicit views)
    let pf: GPUTarget;
    if (tgt != null) {
        pf = tgt;
    } else if (cv != null) {
        pf = cv;
    } else {
        resetQueues(r);
        coverLayout(r, renderer2d);
        return;
    }
    let first = r.lastTime < 0;
    let dt = first ? 1.0 / 60 : lclamp(time - r.lastTime, 0, 0.1);
    // frame pacing for the adaptive HUD rate (hudPace: shared with hudDue)
    if (!first) {
        hudPace(r, time);
        r.dtAvg = HP_AVG;
        r.hudFast = HP_FAST;
        r.hudHold = HP_HOLD;
        r.hudBackoff = HP_BACKOFF;
    }
    r.lastTime = time;
    r.time = time;
    // boost-start kick for the post zoom smear (not on the first frame drawn)
    if (r.boost >= 0.99 && r.boostPrev < 0.99 && !first) {
        r.smearKick = 1;
    } else {
        r.smearKick = lmax(0, r.smearKick - dt / 0.3);
    }
    r.boostPrev = r.boost;

    let st = r.stats;
    st.draws = 0;
    st.instances = 0;
    st.culled = 0;
    st.culledRefl = 0;
    st.sprites = 0;
    st.fading = 0;
    st.fadingRefl = 0;
    st.particles = r.partN;
    st.trails = r.trailN;

    // camera
    let aspect = r.rw / r.rh;
    let proj = perspective32(r.projM, <f32>cam.fov, <f32>aspect, <f32>cam.near, <f32>cam.far);
    let ce = cam.eye, cta = cam.target, cu = cam.up;
    let view = lookAt32(r.viewM, ce, cta, cu);
    let vp = multiply4(r.viewProj, proj, view);
    let fwd = mathx.norm(cta - ce), upv = cu;
    let right = mathx.norm(mathx.cross(fwd, upv));
    r.camRight = right;
    r.camUp = mathx.cross(right, fwd);
    r.camFwd = fwd;
    let jumped = false;
    if (dt > 0) {
        let mv = ce - r.camEye;
        let sp = Math.sqrt(<f64>mv.x * mv.x + <f64>mv.y * mv.y + <f64>mv.z * mv.z) / dt;
        if (sp < 400) {
            r.speed = mathx.damp(r.speed, sp, 4, dt);
        } else {
            jumped = true;
        }
    }
    r.camEye = ce;
    // flow direction for the foam fields follows the heading, eased
    let hx = <f64>fwd.x, hz = <f64>fwd.z;
    let hl = Math.sqrt(hx * hx + hz * hz);
    if (hl > 0.05) {
        hx = hx / hl;
        hz = hz / hl;
        let k = jumped ? 1 : 1 - Math.exp(-dt * 1.5);
        let fx = r.flowX + (hx - r.flowX) * k;
        let fz = r.flowZ + (hz - r.flowZ) * k;
        let fl = Math.sqrt(fx * fx + fz * fz);
        if (fl > 1e-3) {
            r.flowX = fx / fl;
            r.flowZ = fz / fl;
        }
    }
    // Sky rays (invViewProj, read by sky.wgsl only): the inverse of the
    // view-projection without the eye translation. With it the f32 inverse and
    // the shader's near / far points carry the eye's position (thousands of m
    // out): rays off by pixels, jumping frame to frame as the camera moves.
    let rv = r.viewRotM.m, vm = view.m;
    for (let i = 0; i < 12; i++) rv[i] = vm[i];
    let vpRot = multiply4(r.vpRotM, proj, r.viewRotM);
    let ivp = invert4(r.ivpM, vpRot) ? r.ivpM : r.identM;
    let vpR = multiply4(r.vpRM, vp, r.mirrorM);
    let vpRotR = multiply4(r.vpRotRM, vpRot, r.mirrorM);
    let ivpR = invert4(r.ivpRM, vpRotR) ? r.ivpRM : r.identM;
    if (isDefined(SKYDUMP)) skyDump(cam, aspect, ivp);
    let tanHalf = Math.tan(cam.fov * 0.5);
    r.tanHalfV = tanHalf;
    r.tanHalfH = tanHalf * aspect;

    gatherAuto(r);
    trackRail(r);
    if (r.atlasDirty) packAtlas(r);
    cullQueues(r);

    // portal lens + dive focus from the first queued portal
    let lensX = 0.5, lensY = 0.5, lensR = 0.1, lensS = 0.0;
    if (r.portalN > 0) {
        let d = r.portalF;
        let px = <f64>d[0], py = <f64>d[1], pz = <f64>d[2];
        let rad = <f64>d[3], inten = <f64>d[8];
        project(r, px, py, pz);
        let u = PROJ_U, v = PROJ_V, w = PROJ_W;
        if (w > 0) {
            let ru = rad / (w * tanHalf) * 0.5;
            lensX = u;
            lensY = v;
            lensR = ru;
            lensS = r.post.lens * lclamp(inten, 0, 1);
            // ripple gate: only the open sky (gbuffer clear distance 60000)
            // ripples; debris, cliffs, rings and pilots never bend or double
            r.lensDist = 40000;
            if (r.post.autoPortalFocus && r.post.portal > 0) {
                r.post.portalX = u;
                r.post.portalY = v;
                r.post.portalR = lmax(ru, 0.05);
            }
        }
    }

    writeFrame(r, r.frameData, vp, ivp, pal, false, tanHalf);
    r.frameUbo.update(0, r.frameData, <u32>FRAME_BYTES);
    writeFrame(r, r.frameData, vpR, ivpR, pal, true, tanHalf);
    r.frameUboRefl.update(0, r.frameData, <u32>FRAME_BYTES);
    writeWater(r);
    // JOB 26: plates up while the visor shows: the visor is drawn alone first and post composites it, so the
    // plates print the HUD too
    // (the visor's bind group may only appear in draw2d below: drawVisor checks it)
    r.visorIn = platesOn(r) && r.visor.opacity > 0.001 && ensureVisorOff(r);
    if (!r.visorIn) idleVisorOff(r);
    writePost(r, pal, lensX, lensY, lensR, lensS);
    let vz = r.visor;
    if (Math.abs(vz.bowX - r.visorBowX) > 1e-4 || Math.abs(vz.bowY - r.visorBowY) > 1e-4) {
        buildVisor(r, r.ptW / r.ptH, 62 * Math.PI / 180);
    }
    writeVisor(r, pal);

    // instance uploads
    for (let i = 0; i < r.batches.length; i++) gpu.upload(r.batches[i]);
    for (let si = 0; si < r.sprites.length; si++) {
        let s = r.sprites[si];
        if (s.n > 0 && s.vis) {
            let A = r.atlases[s.ai];
            let aw = lmax(A.w, 1), ah = lmax(A.h, 1);
            // map the instance uv rects into the sprite's atlas rect
            let d = s.df;
            let u0 = s.ax / aw, v0 = s.ay / ah;
            let su = s.aw / aw, sv = s.ah / ah;
            for (let i = 0; i <= s.n - 1; i++) {
                // reflection-only sprites carry a negative opacity (billboard
                // fs_refl keeps them whole at the bottom screen edge)
                if (s.reflOnly) {
                    let oo = i * 16 + 7;
                    d[oo] = <f32>(-Math.abs(<f64>d[oo]));
                }
                let o = i * 16 + 12;
                d[o] = <f32>(u0 + <f64>d[o] * su);
                d[o + 1] = <f32>(v0 + <f64>d[o + 1] * sv);
                d[o + 2] = <f32>(u0 + <f64>d[o + 2] * su);
                d[o + 3] = <f32>(v0 + <f64>d[o + 3] * sv);
            }
            s.buf.update(0, s.data, <u32>(s.n * 64));
        }
    }
    if (r.partN > 0) r.partBuf.update(0, r.partData, <u32>(r.partN * 64));
    if (r.trailN > 0) r.trailBuf.update(0, r.trailData, <u32>(r.trailN * TRAIL_STRIDE));
    if (r.portalN > 0) r.portalBuf.update(0, r.portalData, <u32>(r.portalN * PORTAL_STRIDE));

    // 1. artboards -> canvases
    r.frameN += 1;
    let fn = r.frameN;
    if (!r.no2d) draw2d(r, fn);

    let skyC = pal.skyHorizon;
    let descs = passDescs(r, reflView, reflDepthView, msaaView, msaaGView, hdrView, gbufView, depthView);
    let rc = descs.reflClear, mc = descs.skyClear;
    rc.clearR = <f32>skyC[1];
    rc.clearG = <f32>skyC[2];
    rc.clearB = <f32>skyC[3];
    mc.clearR = <f32>skyC[1];
    mc.clearG = <f32>skyC[2];
    mc.clearB = <f32>skyC[3];

    // 2. reflection
    {
        let pass = pf.beginRenderPass(descs.refl);
        // only the rows the water can sample (at/below the horizon, plus the
        // ripple offsets) are rendered; the rest keeps the clear color
        let fw = reflW(r), fh = reflH(r);
        let top = lclamp(horizonTop(r, vp) - 0.035, 0, 1);
        let y0 = lmin(Math.floor(top * fh), fh - 1);
        pass.setScissor(0, <u32>y0, <u32>fw, <u32>(fh - y0));
        let pt = r.pToonRefl, bgt = r.bgToonRefl;
        if (pt != null && bgt != null) drawBatches(r, pass, pt, bgt, true, false, false, 1);
        let p = r.pSkyRefl, bg = r.bgSkyRefl;
        if (p != null && bg != null) {
            pass.setPipeline(p);
            pass.setBindGroup(0, bg);
            pass.draw(3);
        }
        // sky-fade path: blended over the mirrored sky
        let pfp = r.pToonPreRefl, bfp = r.bgToonPreRefl, pff = r.pToonFadeRefl, bff = r.bgToonFadeRefl;
        if (r.stats.fadingRefl > 0 && pfp != null && bfp != null && pff != null && bff != null) {
            drawBatches(r, pass, pfp, bfp, true, false, true);
            drawBatches(r, pass, pff, bff, true, false, true);
        }
        drawInstances(r, pass, r.pPortalRefl, r.bgPortalRefl, r.portalBuf, r.portalN);
        let pb = r.pBillboardRefl, bgb = r.bgBillboardRefl;
        if (pb != null && bgb != null) drawSprites(r, pass, pb, bgb, true, false);
        // low drops the trails only: without the fire puffs the mirrored
        // wrecks and debris read as dark smudges under the hero
        if (r.qReflFx) drawInstances(r, pass, r.pTrailRefl, r.bgTrailRefl, r.trailBuf, r.trailN);
        drawInstances(r, pass, r.pParticleRefl, r.bgParticleRefl, r.partBuf, r.partN);
        pass.finish();
    }

    // 3. main
    {
        let pass = pf.beginRenderPass(descs.main);
        let pt = r.pToon, bgt = r.bgToon;
        let fadePath = r.stats.fading > 0 && r.pToonPre != null && r.pToonFade != null && r.pOutlineFade != null;
        if (pt != null && bgt != null) {
            // without the fade pipelines, fading batches take the opaque path
            // (toon.wgsl then mixes them toward the clear sky)
            drawBatches(r, pass, pt, bgt, false, false, false, 1);
            if (r.stats.fading > 0 && !fadePath) drawBatches(r, pass, pt, bgt, false, false, true);
        }
        let po = r.pOutline, bgo = r.bgOutline;
        if (po != null && bgo != null) {
            drawBatches(r, pass, po, bgo, false, true, false, 2);
            if (r.stats.fading > 0 && !fadePath) drawBatches(r, pass, po, bgo, false, true, true);
        }
        let pw = r.pWater, bw0 = r.bgWater0, bw1 = r.bgWater1, wm = r.waterMesh;
        if (pw != null && bw0 != null && bw1 != null && wm != null) {
            let wvb = wm.vb, wib = wm.ib;
            if (wvb != null && wib != null) {
                pass.setPipeline(pw);
                pass.setBindGroup(0, bw0);
                pass.setBindGroup(1, bw1);
                pass.setVertexBuffer(0, wvb);
                pass.setIndexBuffer(wib, ifmtOf(wm));
                pass.drawIndexed(<u32>wm.count);
                r.stats.draws += 1;
            }
        }
        // sky last among opaques: depth 'less-equal' at the far plane skips covered pixels
        let p = r.pSky, bg = r.bgSky;
        if (p != null && bg != null) {
            pass.setPipeline(p);
            pass.setBindGroup(0, bg);
            pass.draw(3);
        }
        // sky-fade path: fading chunks blend over the sky / clouds / water
        // really behind them (depth prepass: only their front surface shows)
        let pfp = r.pToonPre, bfp = r.bgToonPre, pff = r.pToonFade, bff = r.bgToonFade, pfo = r.pOutlineFade, bfo = r.bgOutlineFade;
        if (fadePath && pfp != null && bfp != null && pff != null && bff != null && pfo != null && bfo != null) {
            drawBatches(r, pass, pfp, bfp, false, false, true);
            drawBatches(r, pass, pff, bff, false, false, true);
            drawBatches(r, pass, pfo, bfo, false, true, true);
        }
        drawInstances(r, pass, r.pPortal, r.bgPortal, r.portalBuf, r.portalN);
        let pb = r.pBillboard, bgb = r.bgBillboard;
        if (pb != null && bgb != null) drawSprites(r, pass, pb, bgb, false, false);
        drawSpriteMasks(r, pass);
        drawInstances(r, pass, r.pTrail, r.bgTrail, r.trailBuf, r.trailN);
        drawInstances(r, pass, r.pParticle, r.bgParticle, r.partBuf, r.partN);
        let pov = r.pOverlay, bgov = r.bgOverlay;
        if (pov != null && bgov != null) drawSprites(r, pass, pov, bgov, false, true);
        pass.finish();
    }

    // 4. bloom
    let pd = r.pBloomDown, pu = r.pBloomUp;
    let nl = r.bloomN;
    if (pd != null && pu != null && r.bgBloomN == nl * 2 - 1 && r.post.bloom > 0.001) {
        for (let i = 1; i <= nl; i++) {
            let pass = pf.beginRenderPass(descs.bloomDown[i]);
            pass.setPipeline(pd);
            pass.setBindGroup(0, r.bgBloom[i]!);
            pass.draw(3);
            pass.finish();
        }
        for (let k = 1; k <= nl - 1; k++) {
            let pass = pf.beginRenderPass(descs.bloomUp[nl - k]);
            pass.setPipeline(pu);
            pass.setBindGroup(0, r.bgBloom[nl + k]!);
            pass.draw(3);
            pass.finish();
        }
    }

    // 5. final composite + visor. 3.1 (render size < output: phones, capped desktop HIGH):
    // post's first half at the render size into postA, then its second half
    // (upscale + output-resolution effects) in the final pass
    let pad = r.postADesc;
    let split = r.postSplit && pad != null && r.bgPostB != null;
    if (split && pad != null) {
        let pass = pf.beginRenderPass(pad);
        drawPost(pass, r.pPostA, r.bgPost);
        pass.finish();
    }
    let vod = r.visorOffDesc;
    if (r.visorIn && vod != null) {
        // (JOB 26) the visor alone, premultiplied over transparent: post composites it before the plates
        let pass = pf.beginRenderPass(vod);
        drawVisor(r, pass, r.pVisor);
        pass.finish();
    }
    if (path == "direct" && tgt != null) {
        // straight into the target (under all Rive content); this frame's
        // first pass into it, and it clears it
        let pass = tgt.beginRenderPass(r.finalDesc);
        if (split) {
            drawPost(pass, r.pPostBT, r.bgPostB);
        } else {
            drawPost(pass, r.pPostT, r.bgPost);
        }
        if (!r.visorIn) drawVisor(r, pass, r.pVisorT);
        pass.finish();
        resetQueues(r);
        return;
    }
    let cvf = cv!;
    {
        let pass = cvf.beginRenderPass(r.finalDesc);
        if (split) {
            drawPost(pass, r.pPostB, r.bgPostB);
        } else {
            drawPost(pass, r.pPost, r.bgPost);
        }
        if (!r.visorIn) drawVisor(r, pass, r.pVisor);
        pass.finish();
    }
    if (path == "blit" && tgt != null) {
        let pass = tgt.beginRenderPass(r.finalDesc);
        drawBlit(r, pass, cvf);
        pass.finish();
        resetQueues(r);
        return;
    }

    // 6. composite into the layout
    renderer2d.save();
    renderer2d.transform(Mat2D.withScale(<f32>(opt(r.pendW, r.ptW) / r.ow), <f32>(opt(r.pendH, r.ptH) / r.oh)));
    renderer2d.drawImage(cvf.image, r.compSampler, BlendMode.srcOver, 1);
    renderer2d.restore();

    resetQueues(r);
}
