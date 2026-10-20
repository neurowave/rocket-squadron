// Port of src/game/core_hudlive.luau. 2.1 (EFFICIENCY_REVIEW; JOB 25): the HUD artboard advances only on the
// frames the renderer draws it (R.hudAdvance), except on the frames the core
// reads it back, a layout input changes, or the game writes a flag to it.
// Everything the simulation takes from the HUD (Hud.commDone paces the radio,
// which spawns threats; the comms window the wingmen keep off in portrait
// fights; the comms page size) stays exactly as it was on every frame, so
// gameplay never depends on the HUD's raster cadence (and so not on the tier
// or the display rate: fx.luau:191).
//
// Port: the per-bag state is keyed by Bag.id (Luau: a weak table keyed by the bag).
import * as vmx from "./vm";
import { Bag } from "./vm";
import { lmax } from "../lib/compat";

class State {
    keys: Array<f64>; // last frame's layout keys and inputs (KEYS, then BKEYS as 0 / 1), 1-based
    t: f64 = 0; // seconds the HUD keeps advancing every frame after one moved
    writes: f64 = -1; // the bag's discrete-write count at the last check (vm.as Bag.writes)
    constructor(n: i32) {
        this.keys = new Array<f64>(n + 1); // zeros (Luau table.create(n, 0))
    }
}

// the HUD numbers the core reads back for its layout (comms pages, the
// comms window, the legend boxes, the HUD's pixel size), and the layout
// inputs the game writes (the view size, touch mode, the attract reel): the
// HUD is advanced on the frame an input changes, so the keys the core reads
// on the next frame are today's (a resize landing on a skipped frame read
// one stale commCols, and the radio played a different line)
const KEYS: Array<string> = ["commCols", "commRows", "legScoreDy", "legBoxH", "legBoxW", "legRoute", "hudPx", "viewW", "viewH"];
const BKEYS: Array<string> = ["touchUi", "attract"];
const HOLD: f64 = 1.0;

// one state per HUD view model (one per game instance)
const states: Map<i32, State> = new Map<i32, State>();

// Whether the HUD must advance this frame whether or not it is drawn.
// flying: the HUD is on and the visor up (game.luau hudOn); typing: a comms
// line types; portrait: the view is portrait; boss: a boss fight (or its
// death); alert: the alert slot is busy (a banner up or queued).
export function live(h: Bag?, dt: f64, flying: bool, typing: bool, portrait: bool, boss: bool, alert: bool): bool {
    // the comms pages / window settling (resize, rotation, touch mode): a
    // read-back layout key moved
    let moved = false;
    let st: State? = null;
    if (h != null) {
        if (states.has(h.id)) {
            st = states.get(h.id);
        } else {
            st = new State(KEYS.length + BKEYS.length);
            states.set(h.id, st);
        }
        let k = st.keys;
        for (let i = 0; i < KEYS.length; i++) {
            let o = vmx.optNum(h, KEYS[i]);
            let v = isNaN(o) ? 0.0 : o;
            if (v != k[i + 1]) {
                k[i + 1] = v;
                moved = true;
            }
        }
        let nk = KEYS.length;
        for (let i = 0; i < BKEYS.length; i++) {
            let v = vmx.optBool(h, BKEYS[i]) ? 1.0 : 0.0;
            if (v != k[nk + i + 1]) {
                k[nk + i + 1] = v;
                moved = true;
            }
        }
    }
    // a discrete write to the HUD this frame (a trigger, a boolean, an enum):
    // its state machine sees it on this frame's advance, as before. A trigger
    // is consumed only by that advance, else it is lost; a flag set and
    // cleared between two advances would never be seen (strings and numbers
    // persist: the next advance sees them)
    let wrote = false;
    if (h != null && st != null && h.writes != st.writes) {
        st.writes = h.writes;
        wrote = true;
    }
    let hold: f64 = 0;
    if (st != null) {
        hold = moved ? HOLD : lmax(0, st.t - dt);
        st.t = hold;
    }
    // 1. anything but flying with the visor up advances every frame (as before)
    if (!flying) return true;
    if (wrote) return true;
    // 2. a line typing: Hud.commDone paces the channel
    if (typing) return true;
    // 3. a portrait fight with the alert slot busy: alertK x fightK x bannerK
    //    move the comms window the wingmen keep off (popups.comms, wingmen.luau)
    if (portrait && h != null) {
        let f0 = vmx.optNum(h, "fightK");
        let a0 = vmx.optNum(h, "alertK");
        let fk = isNaN(f0) ? 0.0 : f0;
        let ak = isNaN(a0) ? 0.0 : a0;
        if ((boss || fk > 0.001) && (alert || ak > 0.001)) return true;
    }
    return hold > 0;
}
