// Port of src/game/input.luau. Keyboard + gamepad state folded into named actions.
// Keys are GLFW codes (what KeyboardEvent.key reports). See DESIGN.md "Controls".
// Double-tapping left/right (keys, d-pad or a stick flick) raises rollL/rollR.
//
// Port: keys Set<i32>; edge / touchLatch / padLatch Set<string> (Luau true = in
// the set); pad / touch Map<string, bool>; lastTap Map<string, f64>. A
// GamepadEvent is copied into a PadState (named standard-mapping reads; the
// harness feeds PadStates directly: gamepadState). steer returns x and sets
// STEER_1 / STEER_2.
import { Vector } from "rive/vector";
import { GamepadEvent } from "rive/events";
import { clock } from "rive/os";
import * as vmx from "./vm";
import { Bag } from "./vm";
import { lclamp } from "../lib/compat";

export class Input {
    keys: Set<i32> = new Set<i32>();
    edge: Set<string> = new Set<string>();
    lx: f64 = 0;
    ly: f64 = 0;
    lt: f64 = 0;
    rt: f64 = 0;
    pad: Map<string, bool> = new Map<string, bool>();
    // pointer steering (normalized -1..1 from screen center), active while held
    px: f64 = 0;
    py: f64 = 0;
    pointerActive: bool = false;
    // touch controls (on-screen joystick and buttons, fed from the Game view model)
    tx: f64 = 0;
    ty: f64 = 0;
    touch: Map<string, bool> = new Map<string, bool>();
    // touch controls still held across releaseAll: ignored until they let go,
    // so a held PAUSE (or FIRE) never re-presses on the next frame
    touchLatch: Set<string> = new Set<string>();
    // pad buttons (and 'lt' / 'rt' past half) held across releaseAll, the
    // same way: every pad event re-reports them (QA PT1-7: START held while
    // the stick moved re-paused and resumed each frame)
    padLatch: Set<string> = new Set<string>();
    // double-tap detection
    clock: f64 = 0;
    lastTap: Map<string, f64> = new Map<string, f64>();
    stickDir: f64 = 0; // -1, 0, 1: last left-stick x zone (for flick taps)
    stickY: f64 = 0; // -1, 0, 1: last left-stick y zone (menu navigation)
    anyKey: bool = false; // any key or button went down this frame
    wall: f64 = -1; // os.clock at the last keysLost (-1 none)
    lead: f64 = 0; // os.clock's lead over the frame clock that frame
    step: f64 = -1; // the last frame step (s)
    steps: f64 = 0; // frame step changes seen (a real-time host varies it)
    modAt: f64 = -1; // clock when Alt / Cmd / Win was first seen held (-1 none)
    padActive: bool = false; // the gamepad steered or pressed something this frame
}

export class K {
    static readonly space: i32 = 32;
    static readonly a: i32 = 65;
    static readonly b: i32 = 66;
    static readonly d: i32 = 68;
    static readonly e: i32 = 69;
    static readonly j: i32 = 74;
    static readonly k: i32 = 75;
    static readonly l: i32 = 76;
    static readonly m: i32 = 77;
    static readonly n: i32 = 78;
    static readonly p: i32 = 80;
    static readonly q: i32 = 81;
    static readonly s: i32 = 83;
    static readonly w: i32 = 87;
    static readonly c: i32 = 67;
    static readonly x: i32 = 88;
    static readonly z: i32 = 90;
    static readonly escape: i32 = 256;
    static readonly enter: i32 = 257;
    static readonly tab: i32 = 258;
    static readonly backspace: i32 = 259;
    static readonly right: i32 = 262;
    static readonly left: i32 = 263;
    static readonly down: i32 = 264;
    static readonly up: i32 = 265;
    static readonly kpEnter: i32 = 335;
    static readonly leftShift: i32 = 340;
    static readonly leftControl: i32 = 341;
    static readonly leftAlt: i32 = 342;
    static readonly leftSuper: i32 = 343;
    static readonly rightShift: i32 = 344;
    static readonly rightControl: i32 = 345;
    static readonly rightAlt: i32 = 346;
    static readonly rightSuper: i32 = 347;
}

// A gamepad's named standard-mapping reads (GamepadEvent getters).
export class PadState {
    south: bool = false;
    east: bool = false;
    west: bool = false;
    north: bool = false;
    leftShoulder: bool = false;
    rightShoulder: bool = false;
    start: bool = false;
    forward: bool = false;
    back: bool = false;
    dpadUp: bool = false;
    dpadDown: bool = false;
    dpadLeft: bool = false;
    dpadRight: bool = false;
    leftStickButton: bool = false;
    rightStickButton: bool = false;
    rightTriggerPressed: bool = false;
    leftTriggerPressed: bool = false;
    leftStick: Vector = Vector.xy(0, 0);
    rightStick: Vector = Vector.xy(0, 0);
    leftTrigger: f64 = 0;
    rightTrigger: f64 = 0;
}

export function padState(e: GamepadEvent): PadState {
    let s = new PadState();
    s.south = e.south;
    s.east = e.east;
    s.west = e.west;
    s.north = e.north;
    s.leftShoulder = e.leftShoulder;
    s.rightShoulder = e.rightShoulder;
    s.start = e.start;
    s.forward = e.forward;
    s.back = e.back;
    s.dpadUp = e.dpadUp;
    s.dpadDown = e.dpadDown;
    s.dpadLeft = e.dpadLeft;
    s.dpadRight = e.dpadRight;
    s.leftStickButton = e.leftStickButton;
    s.rightStickButton = e.rightStickButton;
    s.rightTriggerPressed = e.rightTriggerPressed;
    s.leftTriggerPressed = e.leftTriggerPressed;
    s.leftStick = e.leftStick;
    s.rightStick = e.rightStick;
    s.leftTrigger = <f64>e.leftTrigger;
    s.rightTrigger = <f64>e.rightTrigger;
    return s;
}

class Bind {
    action: string;
    keys: Array<i32>;
    constructor(action: string, keys: Array<i32>) {
        this.action = action;
        this.keys = keys;
    }
}

class PadBind {
    action: string;
    fields: Array<string>;
    constructor(action: string, fields: Array<string>) {
        this.action = action;
        this.fields = fields;
    }
}

// action -> keys. Shift/Ctrl alone never reach scripts in the macOS
// previewer (no modifier-only key events), so every action also has a plain
// letter key: Z fire, X boost, C brake.
const BIND_LIST: Array<Bind> = [
    new Bind("fire", [K.space, K.j, K.z]),
    new Bind("boost", [K.leftShift, K.rightShift, K.k, K.x]),
    new Bind("brake", [K.leftControl, K.rightControl, K.l, K.c]),
    new Bind("rollL", [K.q]),
    new Bind("rollR", [K.e]),
    new Bind("bomb", [K.b]),
    new Bind("muteMusic", [K.m]),
    new Bind("muteAll", [K.n]),
    new Bind("pause", [K.escape, K.p]),
    new Bind("confirm", [K.enter, K.kpEnter, K.space]),
    // confirm without Space (Space is also FIRE): results, game over, outro skip
    new Bind("accept", [K.enter, K.kpEnter]),
    new Bind("back", [K.escape, K.backspace]),
    // flight school skip (hold): never Space
    new Bind("skip", [K.enter, K.kpEnter]),
    new Bind("up", [K.up, K.w]),
    new Bind("down", [K.down, K.s]),
    new Bind("left", [K.left, K.a]),
    new Bind("right", [K.right, K.d]),
];

// action -> gamepad field names (standard mapping)
const PAD_LIST: Array<PadBind> = [
    new PadBind("fire", ["south", "rightTriggerPressed"]),
    new PadBind("boost", ["west"]),
    new PadBind("brake", ["east", "leftTriggerPressed"]), // LT: a brake alternate
    new PadBind("rollL", ["leftShoulder"]),
    new PadBind("rollR", ["rightShoulder"]),
    new PadBind("bomb", ["north"]),
    new PadBind("pause", ["start", "forward"]),
    new PadBind("confirm", ["south", "start", "forward"]),
    new PadBind("accept", ["south", "start", "forward"]),
    new PadBind("back", ["east", "back"]),
    new PadBind("skip", ["back"]),
    new PadBind("up", ["dpadUp"]),
    new PadBind("down", ["dpadDown"]),
    new PadBind("left", ["dpadLeft"]),
    new PadBind("right", ["dpadRight"]),
];

const BIND: Map<string, Array<i32>> = new Map<string, Array<i32>>();
const PAD: Map<string, Array<string>> = new Map<string, Array<string>>();
// key code -> actions, pad field -> actions (built once; Luau builds them in
// pairs order: each press is independent, the order does not matter)
const KEY_ACTIONS: Map<i32, Array<string>> = new Map<i32, Array<string>>();
const PAD_ACTIONS: Map<string, Array<string>> = new Map<string, Array<string>>();

function buildTables(): void {
    for (let i = 0; i < BIND_LIST.length; i++) {
        let bnd = BIND_LIST[i];
        BIND.set(bnd.action, bnd.keys);
        for (let j = 0; j < bnd.keys.length; j++) {
            let k = bnd.keys[j];
            if (!KEY_ACTIONS.has(k)) KEY_ACTIONS.set(k, new Array<string>());
            KEY_ACTIONS.get(k).push(bnd.action);
        }
    }
    for (let i = 0; i < PAD_LIST.length; i++) {
        let pb = PAD_LIST[i];
        PAD.set(pb.action, pb.fields);
        for (let j = 0; j < pb.fields.length; j++) {
            let f = pb.fields[j];
            if (!PAD_ACTIONS.has(f)) PAD_ACTIONS.set(f, new Array<string>());
            PAD_ACTIONS.get(f).push(pb.action);
        }
    }
}
buildTables();

const DOUBLE_TAP: f64 = 0.26;

export function create(): Input {
    return new Input();
}

function press(inp: Input, action: string): void {
    inp.edge.add(action);
    if (action == "left" || action == "right") {
        if (inp.lastTap.has(action) && inp.clock - inp.lastTap.get(action) < DOUBLE_TAP) {
            inp.edge.add(action == "left" ? "rollL" : "rollR");
            inp.lastTap.delete(action);
        } else {
            inp.lastTap.set(action, inp.clock);
        }
    }
}

// code: KeyboardEvent.key; phase: 'down' | 'repeat' | 'up'
export function key(inp: Input, code: f64, phase: string): void {
    let c = <i32>code;
    if (phase == "down") {
        if (!inp.keys.has(c)) {
            inp.anyKey = true;
            if (KEY_ACTIONS.has(c)) {
                let list = KEY_ACTIONS.get(c);
                for (let i = 0; i < list.length; i++) press(inp, list[i]);
            }
        }
        inp.keys.add(c);
    } else if (phase == "repeat") {
        // auto-repeat moves menu cursors only
        if (KEY_ACTIONS.has(c)) {
            let list = KEY_ACTIONS.get(c);
            for (let i = 0; i < list.length; i++) {
                let a = list[i];
                if (a == "up" || a == "down" || a == "left" || a == "right") {
                    inp.edge.add("nav" + a);
                }
            }
        }
    } else if (phase == "up") {
        inp.keys.delete(c);
    }
}

const PAD_FIELDS: Array<string> = [
    "south", "east", "west", "north", "leftShoulder", "rightShoulder", "start", "forward", "back",
    "dpadUp", "dpadDown", "dpadLeft", "dpadRight", "rightTriggerPressed", "leftTriggerPressed",
];

function padRead(e: PadState, f: string): bool {
    if (f == "south") return e.south;
    if (f == "east") return e.east;
    if (f == "west") return e.west;
    if (f == "north") return e.north;
    if (f == "leftShoulder") return e.leftShoulder;
    if (f == "rightShoulder") return e.rightShoulder;
    if (f == "start") return e.start;
    if (f == "forward") return e.forward;
    if (f == "back") return e.back;
    if (f == "dpadUp") return e.dpadUp;
    if (f == "dpadDown") return e.dpadDown;
    if (f == "dpadLeft") return e.dpadLeft;
    if (f == "dpadRight") return e.dpadRight;
    if (f == "rightTriggerPressed") return e.rightTriggerPressed;
    if (f == "leftTriggerPressed") return e.leftTriggerPressed;
    return false;
}

@inline function padHeld(inp: Input, f: string): bool {
    return inp.pad.has(f) && inp.pad.get(f);
}

export function gamepad(inp: Input, e: GamepadEvent): void {
    gamepadState(inp, padState(e));
}

export function gamepadState(inp: Input, e: PadState): void {
    inp.lx = <f64>e.leftStick.x;
    inp.ly = <f64>e.leftStick.y;
    let latch = inp.padLatch;
    // (a trigger latched by releaseAll reads 0 until it is let go)
    let lt = e.leftTrigger;
    let rt = e.rightTrigger;
    if (latch.has("lt")) {
        if (lt > 0.5) lt = 0;
        else latch.delete("lt");
    }
    if (latch.has("rt")) {
        if (rt > 0.5) rt = 0;
        else latch.delete("rt");
    }
    // LT / RT past 0.5 are brake / fire presses too (a pad that reports only the analog value; QA FAIL-N4)
    if (lt > 0.5 && inp.lt <= 0.5) press(inp, "brake");
    if (rt > 0.5 && inp.rt <= 0.5) press(inp, "fire");
    inp.lt = lt;
    inp.rt = rt;
    if (Math.abs(inp.lx) > 0.35 || Math.abs(inp.ly) > 0.35 || inp.lt > 0.5 || inp.rt > 0.5) {
        inp.padActive = true;
    }
    for (let i = 0; i < PAD_FIELDS.length; i++) {
        let f = PAD_FIELDS[i];
        let now = padRead(e, f);
        if (latch.has(f)) {
            // held through releaseAll: neither down nor a new press until let go
            if (now) now = false;
            else latch.delete(f);
        }
        if (now && !padHeld(inp, f)) {
            inp.anyKey = true;
            inp.padActive = true;
            if (PAD_ACTIONS.has(f)) {
                let list = PAD_ACTIONS.get(f);
                for (let j = 0; j < list.length; j++) press(inp, list[j]);
            }
        }
        inp.pad.set(f, now);
    }
    // stick flicks count as left/right taps (double flick = barrel roll) and
    // as up/down presses for menus
    let zx = inp.lx < -0.6 ? -1.0 : inp.lx > 0.6 ? 1.0 : Math.abs(inp.lx) < 0.3 ? 0.0 : inp.stickDir;
    if (zx != inp.stickDir) {
        if (zx == -1) press(inp, "left");
        else if (zx == 1) press(inp, "right");
        inp.stickDir = zx;
    }
    let zy = inp.ly < -0.6 ? -1.0 : inp.ly > 0.6 ? 1.0 : Math.abs(inp.ly) < 0.3 ? 0.0 : inp.stickY;
    if (zy != inp.stickY) {
        if (zy == -1) inp.edge.add("navup");
        else if (zy == 1) inp.edge.add("navdown");
        inp.stickY = zy;
    }
}

@inline function touchHeld(inp: Input, k: string): bool {
    return inp.touch.has(k) && inp.touch.get(k);
}

// Touch buttons: set the held state each frame; a new press raises the edge.
// A control latched by releaseAll counts again only after it was let go.
export function touchButton(inp: Input, action: string, held: bool): void {
    if (!held) {
        inp.touchLatch.delete(action);
    } else if (!touchHeld(inp, action) && !inp.touchLatch.has(action)) {
        press(inp, action);
        inp.anyKey = true;
    }
    inp.touch.set(action, held);
}

// A touch control that only raises an edge (held state tracked under `key`),
// e.g. the ROLL button rolling toward the joystick's side.
export function touchEdge(inp: Input, key: string, held: bool, action: string): void {
    if (!held) {
        inp.touchLatch.delete(key);
    } else if (!touchHeld(inp, key) && !inp.touchLatch.has(key)) {
        press(inp, action);
        inp.anyKey = true;
    }
    inp.touch.set(key, held);
}

export function down(inp: Input, action: string): bool {
    if (touchHeld(inp, action) && !inp.touchLatch.has(action)) return true;
    if (BIND.has(action)) {
        let keys = BIND.get(action);
        for (let i = 0; i < keys.length; i++) {
            if (inp.keys.has(keys[i])) return true;
        }
    }
    if (PAD.has(action)) {
        let fields = PAD.get(action);
        for (let i = 0; i < fields.length; i++) {
            if (padHeld(inp, fields[i])) return true;
        }
    }
    // (RT is FIRE only, through rightTriggerPressed or its analog value; LT is a brake alternate)
    if (action == "brake" && inp.lt > 0.5) return true;
    if (action == "fire" && inp.rt > 0.5) return true;
    return false;
}

// True once per press (cleared by endFrame).
export function pressed(inp: Input, action: string): bool {
    return inp.edge.has(action);
}

// Menu navigation: -1 previous, 1 next, 0 none (presses, key repeat, stick
// flicks). Up / down always step; left / right too when the menu is laid out
// in a row (`horiz`), so the arrows match what is on screen.
export function nav(inp: Input, horiz: bool = false): f64 {
    let e = inp.edge;
    if (e.has("up") || e.has("navup") || (horiz && (e.has("left") || e.has("navleft")))) return -1;
    if (e.has("down") || e.has("navdown") || (horiz && (e.has("right") || e.has("navright")))) return 1;
    return 0;
}

@inline function sign(x: f64): f64 {
    return x > 0 ? 1.0 : x < 0 ? -1.0 : 0.0;
}

// steer's second value (y); STEER_1 = x
export let STEER_1: f64 = 0;
export let STEER_2: f64 = 0;

// Steering in -1..1 (x right, y up), with a response curve on analog input.
// Returns x; sets STEER_1 (x), STEER_2 (y).
export function steer(inp: Input): f64 {
    let x: f64 = 0;
    let y: f64 = 0;
    if (down(inp, "left")) x -= 1;
    if (down(inp, "right")) x += 1;
    if (down(inp, "up")) y += 1;
    if (down(inp, "down")) y -= 1;
    let dz: f64 = 0.12;
    let ax = Math.abs(inp.lx);
    if (ax > dz) {
        let k = (ax - dz) / (1 - dz);
        x += sign(inp.lx) * Math.pow(k, 1.5);
    }
    // stick up is negative on the standard mapping
    let ay = Math.abs(inp.ly);
    if (ay > dz) {
        let k = (ay - dz) / (1 - dz);
        y -= sign(inp.ly) * Math.pow(k, 1.5);
    }
    if (inp.pointerActive) {
        x += inp.px;
        y += inp.py;
    }
    x += inp.tx;
    y += inp.ty;
    STEER_1 = lclamp(x, -1, 1);
    STEER_2 = lclamp(y, -1, 1);
    return STEER_1;
}

export function tick(inp: Input, dt: f64): void {
    inp.clock += dt;
}

export function endFrame(inp: Input): void {
    inp.edge.clear();
    inp.anyKey = false;
    inp.padActive = false;
}

// Keys the page dropped: the web runtime sends no key-up after a click outside the canvas, a tab switch or a window
// blur, so a held key stayed held. Each frame, held keys (`inp.keys` only: pad events and touch controls re-report
// their state) are released on:
// - keysLost (Main: the key holder 1:26 lost Rive focus, a click outside the canvas);
// - os.clock running CLOCK_SKIP ahead of the frame clock and staying ahead a second frame (a hidden tab resumes as if
//   no time passed; a long task's late frame is caught up by the next), once the frame step has changed REAL_N times
//   (a real-time host; the headless CLI's step is fixed, so its runs never read the wall clock);
// - Alt or Cmd / Win held MOD_HOLD (app and window switches start there; their key-ups go elsewhere).
// A window blur that keeps the page visible and starts from the mouse goes unseen (runtime / host side).
const CLOCK_SKIP: f64 = 0.5; // s
const REAL_N: f64 = 30;
const MOD_HOLD: f64 = 0.5; // s
export function keysLost(inp: Input, g: Bag, seconds: f64): void {
    keysLostAt(inp, g, seconds, clock());
}

// keysLost with the wall clock given (`now`: os.clock; harness)
export function keysLostAt(inp: Input, g: Bag, seconds: f64, now: f64): void {
    let lost = vmx.optTakeBool(g, "keysLost");
    if (inp.wall >= 0) {
        if (inp.steps < REAL_N && seconds != inp.step) {
            inp.step = seconds;
            inp.steps += 1;
        }
        let lead = now - inp.wall - seconds;
        if (inp.steps >= REAL_N && inp.lead > CLOCK_SKIP && inp.lead + lead > CLOCK_SKIP) {
            lost = true;
        }
        inp.lead = lead;
    }
    inp.wall = now;
    let k = inp.keys;
    if (k.has(K.leftAlt) || k.has(K.rightAlt) || k.has(K.leftSuper) || k.has(K.rightSuper)) {
        if (inp.modAt < 0) {
            inp.modAt = inp.clock;
        } else if (inp.clock - inp.modAt > MOD_HOLD) {
            lost = true;
        }
    } else {
        inp.modAt = -1;
    }
    if (lost) {
        k.clear();
        inp.modAt = -1;
    }
}

// Drop every held key and button (on pause / state changes) so nothing sticks.
// Touch controls are UI state re-read every frame, and every pad event
// re-reports the pad's buttons: the ones still held are latched (ignored
// until released) instead of forgotten, or the next frame / pad event would
// read them as a fresh press.
export function releaseAll(inp: Input): void {
    inp.keys.clear();
    let pk = inp.pad.keys();
    for (let i = 0; i < pk.length; i++) {
        if (inp.pad.get(pk[i])) inp.padLatch.add(pk[i]);
    }
    if (inp.lt > 0.5) inp.padLatch.add("lt");
    if (inp.rt > 0.5) inp.padLatch.add("rt");
    inp.pad.clear();
    inp.edge.clear();
    let tk = inp.touch.keys();
    for (let i = 0; i < tk.length; i++) {
        if (inp.touch.get(tk[i])) inp.touchLatch.add(tk[i]);
    }
    inp.lx = 0;
    inp.ly = 0;
    inp.lt = 0;
    inp.rt = 0;
    inp.tx = 0;
    inp.ty = 0;
}
