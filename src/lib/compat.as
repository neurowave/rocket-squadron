// Luau compatibility for the AnimaScript port: the numeric semantics the
// Luau game relies on, spelled out (AnimaScript's own differ).
//
// - `mod` / `imod`: Luau `%` is floored (a - floor(a / b) * b); AnimaScript's
//   `%` truncates.
// - `idiv`: Luau `//` (floor of the quotient).
// - `lmin` / `lmax`: Luau math.min / math.max pick by `<` only (NaN and
//   signed zero follow Luau, not Math.min / Math.max).
// - `lclamp`: Luau math.clamp (x < lo, then > hi).
// - `lround`: Luau math.round, half away from zero (Math.round(-2.5) is -2).
// - `Rng` / `rng` / `rand`: mathx's Park-Miller stream (exact in doubles).
// - `f32r`: the f32 rounding a Luau `Vector` component gets.
// - `opt`: Luau `v or d` for optional numbers carried as NaN.
// - `getOr`: Map lookup that does not trap on a missing key.
// - `sinL` / `cosL`: Math.sin / Math.cos return the wrong quadrant for
//   |x| >= 2^20 * pi / 2 (~1.647e6) in rasc (CLI 1.6.0-uat.47): mathx.hash
//   feeds them up to ~1e7. Reduced here with a 4-part pi/2 (exact for
//   |x| < 2^26 * pi / 2), then the small-argument Math.sin / Math.cos.
// - Luau sequences are 1-based: ported as arrays whose slot 0 is a dummy
//   (`seqF` / `len`), so indices and `#t` carry over unchanged.

import { formatNumber } from "rive/format";

export const HUGE: f64 = Infinity;
export const TWO32: f64 = 4294967296.0;

@inline export function mod(a: f64, b: f64): f64 {
    return a - Math.floor(a / b) * b;
}

@inline export function imod(a: i32, b: i32): i32 {
    let r = a % b;
    return r != 0 && ((r ^ b) < 0) ? r + b : r;
}

@inline export function idiv(a: f64, b: f64): f64 {
    return Math.floor(a / b);
}

@inline export function lmin(a: f64, b: f64): f64 {
    return b < a ? b : a;
}

@inline export function lmax(a: f64, b: f64): f64 {
    return b > a ? b : a;
}

@inline export function lclamp(x: f64, lo: f64, hi: f64): f64 {
    let r = x < lo ? lo : x;
    return r > hi ? hi : r;
}

export function lround(x: f64): f64 {
    let t = Math.trunc(x);
    if (Math.abs(x - t) >= 0.5) {
        t += x > 0 ? 1.0 : -1.0;
    }
    return t;
}

@inline export function f32r(x: f64): f64 {
    return <f64><f32>x;
}

@inline export function opt(v: f64, d: f64): f64 {
    return isNaN(v) ? d : v;
}

export function getOr<K>(m: Map<K, i32>, k: K, d: i32): i32 {
    return m.has(k) ? m.get(k) : d;
}

const PIO2_1: f64 = 1.570796325802803;
const PIO2_2: f64 = 9.920935739593517e-10;
const PIO2_3: f64 = 5.721188709663575e-18;
const PIO2_4: f64 = 1.6446256936324258e-26;
const TRIG_SAFE: f64 = 1.6e6;
const INV_PIO2: f64 = 0.63661977236758134308;

let RED_R: f64 = 0;
let RED_Q: i32 = 0;
function reduce(x: f64): void {
    let n = Math.floor(x * INV_PIO2 + 0.5);
    RED_R = (((x - n * PIO2_1) - n * PIO2_2) - n * PIO2_3) - n * PIO2_4;
    RED_Q = <i32>mod(n, 4);
}

export function sinL(x: f64): f64 {
    if (Math.abs(x) < TRIG_SAFE) return Math.sin(x);
    reduce(x);
    let r = RED_R;
    switch (RED_Q) {
        case 0: return Math.sin(r);
        case 1: return Math.cos(r);
        case 2: return -Math.sin(r);
        default: return -Math.cos(r);
    }
}

export function cosL(x: f64): f64 {
    if (Math.abs(x) < TRIG_SAFE) return Math.cos(x);
    reduce(x);
    let r = RED_R;
    switch (RED_Q) {
        case 0: return Math.cos(r);
        case 1: return -Math.sin(r);
        case 2: return -Math.cos(r);
        default: return Math.sin(r);
    }
}

// Park-Miller minimal standard on doubles (mathx.rng / rand).
export class Rng {
    s: f64 = 1;
}

export function rng(seed: f64): Rng {
    let r = new Rng();
    r.s = mod(seed, 2147483646.0) + 1;
    return r;
}

@inline export function rand(r: Rng): f64 {
    r.s = mod(r.s * 16807.0, 2147483647.0);
    return (r.s - 1) / 2147483646.0;
}

// 1-based sequences: slot 0 is a dummy.
@inline export function seqF(): Array<f64> {
    return [0.0];
}

@inline export function len<T>(a: Array<T>): i32 {
    return a.length - 1;
}

// Luau math.random / math.randomseed: PCG32 (lmathlib.cpp), one global
// stream. Unseeded Luau seeds from a VM address (not reproducible): seed
// both lanes (lrandomseed(42)) for A/B runs.
let RNG_STATE: u64 = 0;

function pcg32(): u32 {
    let old = RNG_STATE;
    RNG_STATE = old * 6364136223846793005 + 105;
    let xs = <u32>(((old >> 18) ^ old) >> 27);
    let rot = <u32>(old >> 59);
    return (xs >> rot) | (xs << (<u32>(-<i32>rot) & 31));
}

export function lrandomseed(seed: f64): void {
    RNG_STATE = 0;
    pcg32();
    RNG_STATE += <u64><i64><i32>seed;
    pcg32();
}

// math.random(): [0, 1) from two draws
export function lrandom(): f64 {
    let rl = <u64>pcg32();
    let rh = <u64>pcg32();
    return <f64>(rl | (rh << 32)) * 5.421010862427522e-20;
}

// math.random(l, u) (math.random(m) is lrandomInt(1, m))
export function lrandomInt(l: i32, u: i32): i32 {
    let ul = <u32>u - <u32>l;
    let x = <u64>(ul + 1) * <u64>pcg32();
    return l + <i32>(x >> 32);
}

// Luau table.sort (ltablib.cpp sort_rec / sort_heap): the same compares and
// swaps in the same order, so equal keys land where Luau puts them (Array.sort
// does not). `lt` is the Luau comparator (a < b). lsort: a 1-based sequence,
// sorts a[1..n]; lsort0: a 0-based array, sorts a[0..n-1].
export function lsort<T>(a: Array<T>, n: i32, lt: (x: T, y: T) => bool): void {
    if (n > 0) sortRec<T>(a, 1, n, n, lt);
}

export function lsort0<T>(a: Array<T>, n: i32, lt: (x: T, y: T) => bool): void {
    if (n > 0) sortRec<T>(a, 0, n - 1, n, lt);
}

@inline function sortSwap<T>(a: Array<T>, i: i32, j: i32): void {
    let t = a[i];
    a[i] = a[j];
    a[j] = t;
}

function siftHeap<T>(a: Array<T>, l: i32, u: i32, lt: (x: T, y: T) => bool, root: i32): void {
    let count = u - l + 1;
    while (root * 2 + 2 < count) {
        let left = root * 2 + 1, right = root * 2 + 2;
        let next = root;
        next = lt(a[l + next], a[l + left]) ? left : next;
        next = lt(a[l + next], a[l + right]) ? right : next;
        if (next == root) break;
        sortSwap<T>(a, l + root, l + next);
        root = next;
    }
    let lastleft = root * 2 + 1;
    if (lastleft == count - 1 && lt(a[l + root], a[l + lastleft])) sortSwap<T>(a, l + root, l + lastleft);
}

function sortHeap<T>(a: Array<T>, l: i32, u: i32, lt: (x: T, y: T) => bool): void {
    let count = u - l + 1;
    for (let i = count / 2 - 1; i >= 0; --i) siftHeap<T>(a, l, u, lt, i);
    for (let i = count - 1; i > 0; --i) {
        sortSwap<T>(a, l, l + i);
        siftHeap<T>(a, l, l + i - 1, lt, 0);
    }
}

function sortRec<T>(a: Array<T>, l: i32, u: i32, limit: i32, lt: (x: T, y: T) => bool): void {
    while (l < u) {
        if (limit == 0) {
            sortHeap<T>(a, l, u, lt);
            return;
        }
        if (lt(a[u], a[l])) sortSwap<T>(a, u, l);
        if (u - l == 1) break;
        let m = l + ((u - l) >> 1);
        if (lt(a[m], a[l])) sortSwap<T>(a, m, l);
        else if (lt(a[u], a[m])) sortSwap<T>(a, m, u);
        if (u - l == 2) break;
        let p = u - 1;
        sortSwap<T>(a, m, u - 1);
        let i = l;
        let j = u - 1;
        for (;;) {
            while (lt(a[++i], a[p])) {
                if (i >= u) throw new Error("invalid order function for sorting");
            }
            while (lt(a[p], a[--j])) {
                if (j <= l) throw new Error("invalid order function for sorting");
            }
            if (j < i) break;
            sortSwap<T>(a, i, j);
        }
        sortSwap<T>(a, p, i);
        limit = (limit >> 1) + (limit >> 2);
        if (i - l < u - i) {
            sortRec<T>(a, l, i - 1, limit, lt);
            l = i + 1;
        } else {
            sortRec<T>(a, i + 1, u, limit, lt);
            u = i - 1;
        }
    }
}

// Luau strings (ASCII here: the game's text is): 1-based, inclusive, negative
// from the end, as string.sub.
export function lsub(s: string, i: i32, j: i32 = -1): string {
    let n = s.length;
    if (i < 0) i = n + i + 1;
    if (i < 1) i = 1;
    if (j < 0) j = n + j + 1;
    if (j > n) j = n;
    if (i > j) return "";
    return s.substring(i - 1, j);
}

// string.find(s, p, init, true): 1-based position or 0 (Luau nil)
export function lfind(s: string, p: string, init: i32 = 1): i32 {
    return s.indexOf(p, init - 1) + 1;
}

// tostring(number) / `..` on a number: shortest round trip, Luau's formats
export function lstr(x: f64): string {
    return formatNumber(x);
}
