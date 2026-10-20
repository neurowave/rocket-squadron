// Port of src/game/core_mode.luau. Control mode (DIRECTION #25, training.md 5.1): keyboard / gamepad / touch.
// The core is the only writer of Game.controlMode (and its touchMode mirror);
// the UI asks through Game.modePick (1 keyboard, 2 gamepad, 3 touch, 9 next).
// Before the lock the mode is inferred from the core's own pointer / key / pad
// hooks (never from UI writes) and follows the evidence live; START MISSION /
// FLIGHT SCHOOL (or any explicit pick) locks it, menus only after that.
//
// Port: pointer hooks take a PointerEvent (or pointerXxxAt with id / x / y);
// pad takes a GamepadEvent (or padState with an input.PadState). down is a
// Set<f64> of pointer ids; padOn a 1-based Array<bool>. ORDER is 1-based.
import { Vector } from "rive/vector";
import { PointerEvent, GamepadEvent } from "rive/events";
import { format, FormatArg } from "rive/format";
import * as vmx from "./vm";
import { Bag } from "./vm";
import * as input from "./input";
import { PadState } from "./input";
import { lmin, lmax, mod } from "../lib/compat";

export const LOG: bool = false; // prints evidence, locks and picks

export const ORDER: Array<string> = ["", "keyboard", "gamepad", "touch"]; // 1-based
const HOVER_WIN: f64 = 1.5; // a press within this long of a hover is the mouse
const HINT_T: f64 = 3; // seconds modeHint stays up
const NEVER: f64 = -1e9;

const NPAD: i32 = 23; // padButtons entries

export class Mode {
    mode: string = "keyboard"; // the setting now
    locked: bool = false;
    phone: bool = false; // phone-sized window (tie-breaker)
    portrait: bool = false; // a tall window (a weaker tie-breaker)
    clock: f64 = 0; // real seconds
    hoverT: f64 = NEVER; // last pointerMove with no pointer down
    touchT: f64 = NEVER; // last touch signal
    hovered: bool = false; // a hover was ever seen (a mouse is here)
    hx: f64 = 0; // where it last hovered
    hy: f64 = 0;
    upT: f64 = NEVER; // last pointerUp (the web runtime follows a touch up with an exit, sent as a move)
    ux: f64 = 0;
    uy: f64 = 0;
    down: Set<f64> = new Set<f64>(); // pointer ids down
    nDown: f64 = 0;
    lastDev: string = ""; // last non-pointer input: '' | 'key' | 'pad'
    press: string = ""; // device of the latest press: '' | 'key' | 'pad' | 'tap' | 'click'
    padOn: Array<bool> = new Array<bool>(NPAD + 1); // pad items active on the last event (edges), 1-based
    keySeen: bool = false; // evidence since the last update (modeHint)
    padSeen: bool = false;
    hint: f64 = 0; // Game.modeHint: 0 none, 1 keyboard?, 2 gamepad?
    hintT: f64 = 0;
    written: string = ""; // last controlMode value written ('' = none yet)
    shown: string = ""; // controlMode as shown when this frame's input came in
}

export function create(): Mode {
    return new Mode();
}

function log(m: Mode, what: string): void {
    if (LOG) {
        console.log(
            format("[mode %7.2f] %s -> %s%s", [
                FormatArg.number(m.clock),
                FormatArg.string(what),
                FormatArg.string(m.mode),
                FormatArg.string(m.locked ? " (locked)" : ""),
            ]),
        );
    }
}

// Provisional mode from the evidence so far. A tall window that is not
// phone-sized reads touch only until a key or pad says otherwise.
export function infer(m: Mode): string {
    let touchSeen = m.touchT > NEVER && m.touchT >= m.hoverT;
    let noPointer = m.hoverT == NEVER && m.touchT == NEVER;
    if (touchSeen || (noPointer && (m.phone || (m.portrait && m.lastDev == "")))) {
        return "touch";
    } else if (m.lastDev == "pad") {
        return "gamepad";
    }
    return "keyboard";
}

function refresh(m: Mode, what: string): void {
    if (!m.locked) {
        let was = m.mode;
        m.mode = infer(m);
        if (was != m.mode) log(m, what);
    }
}

// Window size (points) and scale (device pixels per point).
export function window(m: Mode, size: Vector, scale: f64): void {
    if (size.y <= 0) return;
    let short = lmin(<f64>size.x, <f64>size.y);
    // portrait: touch with no evidence at all (the headless 1080x1920 phone
    // reports scale 1); a desktop mouse hovers, a key or pad press outranks it
    m.phone = short < 500 || scale >= 2.75;
    m.portrait = size.x < size.y;
    refresh(m, "window");
}

// Pointer hooks (every pointer event in the artboard reaches the layout).
export function pointerMove(m: Mode, e: PointerEvent): void {
    pointerMoveAt(m, <f64>e.position.x, <f64>e.position.y);
}

export function pointerMoveAt(m: Mode, x: f64, y: f64): void {
    // the exit after a release (same frame, same spot) is not a hover
    if (m.upT == m.clock && Math.abs(x - m.ux) < 2 && Math.abs(y - m.uy) < 2) return;
    if (m.nDown == 0) {
        m.hoverT = m.clock;
        m.hovered = true;
        m.hx = x;
        m.hy = y;
        refresh(m, "hover");
    }
}

export function pointerDown(m: Mode, e: PointerEvent): void {
    pointerDownAt(m, e.id, <f64>e.position.x, <f64>e.position.y);
}

export function pointerDownAt(m: Mode, id: f64, px: f64, py: f64): void {
    if (!m.down.has(id)) {
        m.down.add(id);
        m.nDown += 1;
    }
    // a press where the pointer last hovered is the mouse clicking in place
    let parked = m.hovered && Math.abs(px - m.hx) < 2 && Math.abs(py - m.hy) < 2;
    let touch = m.nDown >= 2 || (m.clock - m.hoverT > HOVER_WIN && !parked);
    if (touch) {
        m.touchT = m.clock;
        m.press = "tap";
    } else {
        m.press = "click";
    }
    refresh(m, m.press);
}

export function pointerUp(m: Mode, e: PointerEvent): void {
    pointerUpAt(m, e.id, <f64>e.position.x, <f64>e.position.y);
}

export function pointerUpAt(m: Mode, id: f64, x: f64, y: f64): void {
    m.upT = m.clock;
    m.ux = x;
    m.uy = y;
    if (m.down.has(id)) {
        m.down.delete(id);
        m.nDown = lmax(0, m.nDown - 1);
    }
}

// A key went down (not repeats).
export function key(m: Mode): void {
    m.lastDev = "key";
    m.press = "key";
    m.keySeen = true;
    refresh(m, "key");
}

// Pad evidence: any button going down, or a stick / trigger crossing 0.5 (1-based).
function padButtons(e: PadState): Array<bool> {
    return [
        false,
        e.south, e.east, e.west, e.north, e.leftShoulder, e.rightShoulder, e.back, e.forward, e.start,
        e.dpadUp, e.dpadDown, e.dpadLeft, e.dpadRight, e.leftStickButton, e.rightStickButton,
        e.leftTriggerPressed, e.rightTriggerPressed,
        Math.abs(e.leftStick.x) > 0.5, Math.abs(e.leftStick.y) > 0.5,
        Math.abs(e.rightStick.x) > 0.5, Math.abs(e.rightStick.y) > 0.5,
        e.leftTrigger > 0.5, e.rightTrigger > 0.5,
    ];
}

export function pad(m: Mode, e: GamepadEvent): void {
    padState(m, input.padState(e));
}

export function padState(m: Mode, e: PadState): void {
    let on = m.padOn;
    let fresh = false;
    let b = padButtons(e);
    for (let i = 1; i <= NPAD; i++) {
        let now = b[i];
        if (now && !on[i]) fresh = true;
        on[i] = now;
    }
    if (fresh) {
        m.lastDev = "pad";
        m.press = "pad";
        m.padSeen = true;
        refresh(m, "pad");
    }
}

// A pad connected (a browser reports it with its first press, a native
// host as it starts): pad evidence like a press (playtest 1 G1: the title
// showed keys to a pad holder until the first press).
export function padConnect(m: Mode): void {
    m.lastDev = "pad";
    m.padSeen = true;
    refresh(m, "connect");
}

// Lock on a confirm (START MISSION / FLIGHT SCHOOL): the device that pressed
// it wins. A tap locks touch unless a mouse hovered; a click locks keyboard.
export function lock(m: Mode): void {
    if (m.locked) return;
    let p = m.press;
    if (p == "pad") {
        m.mode = "gamepad";
    } else if (p == "key" || p == "click") {
        m.mode = "keyboard";
    } else if (p == "tap") {
        m.mode = m.hovered ? "keyboard" : "touch";
    } else {
        m.mode = infer(m);
    }
    m.locked = true;
    if (LOG) log(m, "lock (" + (p == "" ? "no press" : p) + ")");
}

// An explicit choice (menus, modePick): sets and locks. The press that made
// it is no hint to switch (it was judged against the old mode).
export function set(m: Mode, mode: string): void {
    m.mode = mode;
    m.shown = mode;
    m.locked = true;
    m.hint = 0;
    m.hintT = 0;
    m.keySeen = false;
    m.padSeen = false;
    log(m, "pick");
}

// Previous (-1) / next (1) in the cycle keyboard -> gamepad -> touch, from
// the mode shown: the press that steps may already have moved the
// provisional mode (a pad press on a KEYBOARD row steps to GAMEPAD).
export function step(m: Mode, d: f64): void {
    let from = m.shown != "" ? m.shown : m.mode;
    let i = 1;
    let n = ORDER.length - 1;
    for (let k = 1; k <= n; k++) {
        if (ORDER[k] == from) i = k;
    }
    set(m, ORDER[<i32>mod(<f64>(i - 1) + d, <f64>n) + 1]);
}

// The VM writes: controlMode and its touchMode mirror change-only (the core
// is their only writer), modeHint change-only.
export function write(m: Mode, g: Bag?): void {
    if (g == null) return;
    if (m.written != m.mode) {
        vmx.optSetEnumLive(g, "controlMode", m.mode);
        vmx.optSetBool(g, "touchMode", m.mode == "touch");
        m.written = m.mode;
    }
    vmx.optSetNum(g, "modeHint", m.hint);
}

// Per frame: QA / pick input, modeHint, the VM writes.
export function update(m: Mode, g: Bag?, rdt: f64): void {
    m.clock += rdt;
    m.shown = m.written; // (before this frame's evidence is written)
    if (g != null) {
        // QA: --data=controlMode=gamepad|touch is there before the first
        // write (the file default is keyboard)
        if (m.written == "") {
            let live = vmx.optEnumLive(g, "controlMode");
            if (live != null && live != "keyboard") set(m, live);
        }
        let pk = vmx.optNum(g, "modePick");
        let pick = isNaN(pk) ? 0.0 : pk;
        if (pick != 0) {
            if (pick == 1 || pick == 2 || pick == 3) {
                set(m, ORDER[<i32>pick]);
            } else if (pick == 9) {
                step(m, 1);
            }
            vmx.optSetNumLive(g, "modePick", 0);
        }
    }
    // modeHint (P2): the other device is in use; never from a pointer
    if (m.keySeen && m.mode == "gamepad") {
        m.hint = 1;
        m.hintT = HINT_T;
    } else if (m.padSeen && m.mode != "gamepad") {
        m.hint = 2;
        m.hintT = HINT_T;
    } else if (m.hintT > 0) {
        m.hintT -= rdt;
        if (m.hintT <= 0) m.hint = 0;
    }
    m.keySeen = false;
    m.padSeen = false;
    write(m, g);
}
