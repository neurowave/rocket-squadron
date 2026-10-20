// Port of src/game/vm.luau. View model access by name, cached and change-only.
// A missing property is a silent no-op (logged once), so the UI and the game
// can evolve independently as long as they agree on the names in DESIGN.md.
//
// Port: Luau number? returns -> f64 NaN (nil); string? -> string? (null).
// Handle caches are Map<string, PropertyX>; `missing` is a Set of 'k:name'.
// Lists (routeItems, certItems, statuses, details, labels, states) stay
// 1-based (slot 0 dummy); index past the end = Luau nil.
import {
    ViewModel,
    PropertyNumber,
    PropertyString,
    PropertyBoolean,
    PropertyEnum,
    PropertyTrigger,
    PropertyColor,
} from "rive/data";
import { Color } from "rive/color";
import { format, FormatArg } from "rive/format";
import { Section } from "../world/level";

// Cached TrainRow handles (Game.trainCert, the flight school certificate).
export class CertItem {
    state: PropertyEnum? = null;
    last: string = "";
}

// Cached RouteItem property handles (so the per-frame route sync is cheap).
export class RouteItem {
    state: PropertyEnum? = null;
    detail: PropertyString? = null;
    lastState: string = "";
    lastDetail: string = "\0";
}

let BAG_IDS: i32 = 0;

export class Bag {
    vm: ViewModel;
    nums: Map<string, PropertyNumber> = new Map<string, PropertyNumber>();
    strs: Map<string, PropertyString> = new Map<string, PropertyString>();
    bools: Map<string, PropertyBoolean> = new Map<string, PropertyBoolean>();
    enums: Map<string, PropertyEnum> = new Map<string, PropertyEnum>();
    trigs: Map<string, PropertyTrigger> = new Map<string, PropertyTrigger>();
    cols: Map<string, PropertyColor> = new Map<string, PropertyColor>();
    missing: Set<string> = new Set<string>();
    lastN: Map<string, f64> = new Map<string, f64>();
    lastS: Map<string, string> = new Map<string, string>();
    lastB: Map<string, bool> = new Map<string, bool>();
    lastC: Map<string, f64> = new Map<string, f64>();
    routeBuilt: bool = false;
    routeItems: Array<RouteItem> = [new RouteItem()]; // 1-based
    certItems: Array<CertItem> = [new CertItem()]; // 1-based
    // discrete writes through this bag: booleans, enums, colours, list items, triggers. Not
    // numbers or strings (gauges, the clock: every frame; a later advance still sees them).
    // core_hudlive advances the HUD on a frame with one: a trigger is consumed only by that
    // frame's advance
    writes: f64 = 0;
    // port: a unique id per bag (core_hudlive keys its state by it; Luau keys by the table)
    id: i32 = 0;
    constructor(vm: ViewModel) {
        this.vm = vm;
        BAG_IDS += 1;
        this.id = BAG_IDS;
    }
}

export function bag(vm: ViewModel): Bag {
    return new Bag(vm);
}

function miss(b: Bag, kind: string, name: string): void {
    let key = kind + ":" + name;
    if (!b.missing.has(key)) {
        b.missing.add(key);
        console.log("vm: no " + kind + " property '" + name + "'");
    }
}

@inline function sameN(b: Bag, name: string, v: f64): bool {
    return b.lastN.has(name) && b.lastN.get(name) == v;
}

@inline function sameS(b: Bag, name: string, v: string): bool {
    return b.lastS.has(name) && b.lastS.get(name) == v;
}

@inline function sameB(b: Bag, name: string, v: bool): bool {
    return b.lastB.has(name) && b.lastB.get(name) == v;
}

// Number handle, cached. log: miss() logs it (readNum) or not (optNum).
function numProp(b: Bag, name: string, log: bool): PropertyNumber? {
    if (b.nums.has(name)) return b.nums.get(name);
    if (b.missing.has("n:" + name)) return null;
    let q = b.vm.getNumber(name);
    if (q == null) {
        if (log) miss(b, "n", name);
        else b.missing.add("n:" + name);
        return null;
    }
    b.nums.set(name, q);
    return q;
}

export function num(b: Bag, name: string, v: f64): void {
    if (sameN(b, name, v)) return;
    let p = numProp(b, name, true);
    if (p == null) return;
    p.value = v;
    b.lastN.set(name, v);
}

export function str(b: Bag, name: string, v: string): void {
    if (sameS(b, name, v)) return;
    let p: PropertyString? = null;
    if (b.strs.has(name)) {
        p = b.strs.get(name);
    } else {
        if (b.missing.has("s:" + name)) return;
        let q = b.vm.getString(name);
        if (q == null) {
            miss(b, "s", name);
            return;
        }
        p = q;
        b.strs.set(name, q);
    }
    p!.value = v;
    b.lastS.set(name, v);
}

function boolProp(b: Bag, name: string): PropertyBoolean? {
    if (b.bools.has(name)) return b.bools.get(name);
    if (b.missing.has("b:" + name)) return null;
    let q = b.vm.getBoolean(name);
    if (q == null) {
        miss(b, "b", name);
        return null;
    }
    b.bools.set(name, q);
    return q;
}

export function bool(b: Bag, name: string, v: bool): void {
    if (sameB(b, name, v)) return;
    let p = boolProp(b, name);
    if (p != null) {
        p.value = v;
        b.lastB.set(name, v);
        b.writes += 1;
    }
}

// Reads a boolean the UI sets (a button press) and clears it. True once per press.
export function takeBool(b: Bag, name: string): bool {
    let p = boolProp(b, name);
    if (p != null && p.value) {
        p.value = false;
        b.lastB.set(name, false);
        b.writes += 1;
        return true;
    }
    return false;
}

export function readBool(b: Bag, name: string): bool {
    let p = boolProp(b, name);
    return p != null && p.value;
}

// NaN = nil
export function readNum(b: Bag, name: string): f64 {
    let p = numProp(b, name, true);
    return p == null ? NaN : p.value;
}

// Optional properties: read without logging when the UI does not define them. NaN = nil.
export function optNum(b: Bag, name: string): f64 {
    let p = numProp(b, name, false);
    return p == null ? NaN : p.value;
}

function optBoolProp(b: Bag, name: string): PropertyBoolean? {
    if (b.bools.has(name)) return b.bools.get(name);
    if (b.missing.has("b:" + name)) return null;
    let q = b.vm.getBoolean(name);
    if (q == null) {
        b.missing.add("b:" + name);
        return null;
    }
    b.bools.set(name, q);
    return q;
}

export function optBool(b: Bag, name: string): bool {
    let p = optBoolProp(b, name);
    return p != null && p.value;
}

// Write an optional boolean (silently skipped when absent).
export function optSetBool(b: Bag, name: string, v: bool): void {
    if (sameB(b, name, v)) return;
    let p = optBoolProp(b, name);
    if (p != null) {
        p.value = v;
        b.lastB.set(name, v);
        b.writes += 1;
    }
}

// Optional boolean both sides write (Game.touchMode): compared with the live
// value, so a UI write since our last one is never mistaken for no change.
export function optSetBoolLive(b: Bag, name: string, v: bool): void {
    let p = optBoolProp(b, name);
    if (p != null) {
        if (p.value != v) {
            p.value = v;
            b.writes += 1;
        }
        b.lastB.set(name, v);
    }
}

// Write an optional number / string (silently skipped when absent).
export function optSetNum(b: Bag, name: string, v: f64): void {
    if (sameN(b, name, v) || b.missing.has("n:" + name)) return;
    let p = numProp(b, name, false);
    if (p == null) return;
    p.value = v;
    b.lastN.set(name, v);
}

export function optSetStr(b: Bag, name: string, v: string): void {
    if (sameS(b, name, v) || b.missing.has("s:" + name)) return;
    let p: PropertyString? = null;
    if (b.strs.has(name)) {
        p = b.strs.get(name);
    } else {
        let q = b.vm.getString(name);
        if (q == null) {
            b.missing.add("s:" + name);
            return;
        }
        p = q;
        b.strs.set(name, q);
    }
    p!.value = v;
    b.lastS.set(name, v);
}

// Read-and-clear an optional boolean the UI sets (silently false when absent).
export function optTakeBool(b: Bag, name: string): bool {
    if (optBool(b, name)) {
        if (b.bools.has(name)) {
            let p = b.bools.get(name);
            p.value = false;
            b.lastB.set(name, false);
            b.writes += 1;
        }
        return true;
    }
    return false;
}

// Whether the view model declares a trigger / string / boolean of that name.
// Typed on purpose: a failed lookup of another type first (getNumber on a
// trigger) makes later getTrigger calls on that name return nil. Cached in
// the typed handle caches, so fire / optSetStr / optSetBool reuse the handle.
export function hasTrigger(b: Bag, name: string): bool {
    if (b.trigs.has(name)) return true;
    if (b.missing.has("t:" + name)) return false;
    let q = b.vm.getTrigger(name);
    if (q == null) {
        b.missing.add("t:" + name);
        return false;
    }
    b.trigs.set(name, q);
    return true;
}

export function hasStr(b: Bag, name: string): bool {
    if (b.strs.has(name)) return true;
    if (b.missing.has("s:" + name)) return false;
    let q = b.vm.getString(name);
    if (q == null) {
        b.missing.add("s:" + name);
        return false;
    }
    b.strs.set(name, q);
    return true;
}

export function hasBool(b: Bag, name: string): bool {
    if (b.bools.has(name)) return true;
    if (b.missing.has("b:" + name)) return false;
    let q = b.vm.getBoolean(name);
    if (q == null) {
        b.missing.add("b:" + name);
        return false;
    }
    b.bools.set(name, q);
    return true;
}

// Whether the view model declares a property of that name (any type; not for
// triggers, see hasTrigger).
export function has(b: Bag, name: string): bool {
    let key = "h:" + name;
    if (!b.lastN.has(key)) {
        let vm = b.vm;
        let found =
            vm.getNumber(name) != null ||
            vm.getString(name) != null ||
            vm.getBoolean(name) != null ||
            vm.getEnum(name) != null ||
            vm.getTrigger(name) != null;
        b.lastN.set(key, found ? 1.0 : 0.0);
    }
    return b.lastN.get(key) == 1.0;
}

// Optional enum-or-string property (e.g. Hud.commMood): sets whichever the UI
// declares, silently skipped when it declares neither.
export function optEnumOrString(b: Bag, name: string, v: string): void {
    let key = "o:" + name;
    if (sameS(b, key, v) || b.missing.has(key)) return;
    let ep: PropertyEnum? = b.enums.has(name) ? b.enums.get(name) : null;
    let sp: PropertyString? = b.strs.has(name) ? b.strs.get(name) : null;
    if (ep == null && sp == null) {
        let q = b.vm.getEnum(name);
        if (q != null) {
            b.enums.set(name, q);
            ep = q;
        } else {
            let s = b.vm.getString(name);
            if (s != null) {
                b.strs.set(name, s);
                sp = s;
            } else {
                b.missing.add(key);
                return;
            }
        }
    }
    if (ep != null) {
        ep.value = v;
        b.writes += 1;
    } else if (sp != null) {
        sp.value = v;
    }
    b.lastS.set(key, v);
}

// Optional enum (by key), read live; nil when the UI does not declare it.
function optEnumProp(b: Bag, name: string): PropertyEnum? {
    if (b.enums.has(name)) return b.enums.get(name);
    if (b.missing.has("e:" + name)) return null;
    let q = b.vm.getEnum(name);
    if (q == null) {
        b.missing.add("e:" + name);
        return null;
    }
    b.enums.set(name, q);
    return q;
}

// null = nil
export function optEnumLive(b: Bag, name: string): string? {
    let p = optEnumProp(b, name);
    return p != null ? p.value : null;
}

// Optional enum only the core may write (Game.controlMode): compared with the
// live value, so an outside write is put back.
export function optSetEnumLive(b: Bag, name: string, v: string): void {
    let p = optEnumProp(b, name);
    if (p != null && p.value != v) {
        p.value = v;
        b.writes += 1;
    }
}

// Optional number both sides write (Game.modePick): compared with the live value.
export function optSetNumLive(b: Bag, name: string, v: f64): void {
    let p = numProp(b, name, false);
    if (p == null) return;
    if (p.value != v) p.value = v;
    b.lastN.set(name, v);
}

// Number the UI may also write (menuIndex on hover): re-reads the live value. NaN = nil.
export function readNumLive(b: Bag, name: string): f64 {
    let p = numProp(b, name, true);
    if (p == null) return NaN;
    let v = p.value;
    b.lastN.set(name, v);
    return v;
}

export function setEnum(b: Bag, name: string, v: string): void {
    if (sameS(b, "e:" + name, v)) return;
    let p: PropertyEnum? = null;
    if (b.enums.has(name)) {
        p = b.enums.get(name);
    } else {
        if (b.missing.has("e:" + name)) return;
        let q = b.vm.getEnum(name);
        if (q == null) {
            miss(b, "e", name);
            return;
        }
        b.enums.set(name, q);
        p = q;
    }
    p!.value = v;
    b.lastS.set("e:" + name, v);
    b.writes += 1;
}

export function fire(b: Bag, name: string): void {
    let p: PropertyTrigger? = null;
    if (b.trigs.has(name)) {
        p = b.trigs.get(name);
    } else {
        if (b.missing.has("t:" + name)) return;
        let q = b.vm.getTrigger(name);
        if (q == null) {
            miss(b, "t", name);
            return;
        }
        b.trigs.set(name, q);
        p = q;
    }
    b.writes += 1;
    p!.fire();
}

// Color property from 0xRRGGBB (opaque).
export function color(b: Bag, name: string, hex: f64): void {
    if (b.lastC.has(name) && b.lastC.get(name) == hex) return;
    let p: PropertyColor? = null;
    if (b.cols.has(name)) {
        p = b.cols.get(name);
    } else {
        if (b.missing.has("c:" + name)) return;
        let q = b.vm.getColor(name);
        if (q == null) {
            miss(b, "c", name);
            return;
        }
        b.cols.set(name, q);
        p = q;
    }
    let h = <u32><i64>hex;
    let r = <i32>((h >> 16) & 0xff);
    let g = <i32>((h >> 8) & 0xff);
    let bl = <i32>(h & 0xff);
    p!.value = Color.rgba(r, g, bl, 255);
    b.lastC.set(name, hex);
    b.writes += 1;
}

// Route list on the HUD: one RouteItem per section (level.sections, 1-based).
// statuses[i] is 'pending' | 'current' | 'done' | 'failed'; details[i] the
// right-hand text for that row ('' for none). Both 1-based.
export function syncRoute(b: Bag, sections: Array<Section>, statuses: Array<string>, details: Array<string>): void {
    if (!b.routeBuilt) {
        if (b.missing.has("l:route")) return;
        let list = b.vm.getList("route");
        if (list == null) {
            b.missing.add("l:route");
            console.log("vm: no list property 'route'");
            return;
        }
        if (!ViewModel.exists("RouteItem")) {
            b.missing.add("l:route");
            return;
        }
        list.clear();
        b.routeItems.length = 1;
        for (let i = 1; i < sections.length; i++) {
            let sec = sections[i];
            let item = ViewModel.create("RouteItem");
            let n = item.getString("num");
            if (n != null) n.value = sec.num;
            let l = item.getString("label");
            if (l != null) l.value = sec.label;
            list.push(item);
            b.writes += 1;
            let it = new RouteItem();
            it.state = item.getEnum("state");
            it.detail = item.getString("detail");
            b.routeItems.push(it);
        }
        b.routeBuilt = true;
    }
    for (let i = 1; i < b.routeItems.length; i++) {
        let it = b.routeItems[i];
        let st = i < statuses.length ? statuses[i] : "pending";
        if (it.lastState != st) {
            let e = it.state;
            if (e != null) {
                e.value = st;
                b.writes += 1;
            }
            it.lastState = st;
        }
        let txt = i < details.length ? details[i] : "";
        if (it.lastDetail != txt) {
            let d = it.detail;
            if (d != null) d.value = txt;
            it.lastDetail = txt;
        }
    }
}

// Flight school certificate (Game.trainCert, List of TrainRow). Rows are made
// once (the file's; init pushes any missing) and only rewritten after: a row
// made later drew at full opacity once a non-certificate card woke the
// sleeping card (a new list item misses its hidden group's opacity). relabel
// writes nums and labels; states change-only. Skipped when the UI lacks it.
function setStr(vm: ViewModel, name: string, v: string): void {
    let p = vm.getString(name);
    if (p != null && p.value != v) p.value = v;
}

// labels / states 1-based
export function syncTrainCert(b: Bag, labels: Array<string>, states: Array<string>, relabel: bool): void {
    if (b.missing.has("l:trainCert")) return;
    let nl = labels.length - 1;
    if (relabel || b.certItems.length - 1 != nl) {
        let list = b.vm.getList("trainCert");
        let hasFactory = ViewModel.exists("TrainRow");
        if (list == null || (!hasFactory && list.length < nl)) {
            b.missing.add("l:trainCert");
            return;
        }
        while (list.length > nl) {
            list.pop();
            b.writes += 1;
        }
        while (list.length < nl) {
            list.push(ViewModel.create("TrainRow"));
            b.writes += 1;
        }
        b.certItems.length = 1;
        for (let i = 1; i <= nl; i++) {
            let item = list[i - 1]; // Luau lists are 1-based
            setStr(item, "num", format("%02d", [FormatArg.number(<f64>i)]));
            setStr(item, "label", labels[i]);
            let c = new CertItem();
            c.state = item.getEnum("state");
            b.certItems.push(c);
        }
    }
    for (let i = 1; i < b.certItems.length; i++) {
        let it = b.certItems[i];
        let st = i < states.length ? states[i] : "pending";
        if (it.last != st) {
            let e = it.state;
            if (e != null && e.value != st) {
                e.value = st;
                b.writes += 1;
            }
            it.last = st;
        }
    }
}
