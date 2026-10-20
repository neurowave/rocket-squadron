// Port of src/lib/mathx.luau. Multi-returns go through module globals
// (rgb -> RGB_R/G/B, basis -> BASIS_*).
import { Vector } from "rive/vector";
import { mod, sinL, Rng, rng as crng, rand as crand } from "./compat";

export const TAU: f64 = Math.PI * 2;

@inline export function clamp(x: f64, a: f64, b: f64): f64 {
    if (x < a) return a;
    if (x > b) return b;
    return x;
}

@inline export function saturate(x: f64): f64 {
    return clamp(x, 0, 1);
}

export function lerp(a: f64, b: f64, t: f64): f64 {
    return a + (b - a) * t;
}

export function invLerp(a: f64, b: f64, x: f64): f64 {
    if (b == a) return 0;
    return (x - a) / (b - a);
}

export function remap(x: f64, a: f64, b: f64, c: f64, d: f64): f64 {
    return c + (d - c) * saturate(invLerp(a, b, x));
}

export function smoothstep(a: f64, b: f64, x: f64): f64 {
    let t = saturate((x - a) / (b - a));
    return t * t * (3 - 2 * t);
}

export function damp(current: f64, target: f64, rate: f64, dt: f64): f64 {
    return target + (current - target) * Math.exp(-rate * dt);
}

export function wrapAngle(a: f64): f64 {
    a = mod(a + Math.PI, TAU);
    if (a < 0) a += TAU;
    return a - Math.PI;
}

export function dampAngle(current: f64, target: f64, rate: f64, dt: f64): f64 {
    let d = wrapAngle(target - current);
    return current + d * (1 - Math.exp(-rate * dt));
}

export function sign(x: f64): f64 {
    if (x > 0) return 1;
    else if (x < 0) return -1;
    return 0;
}

export function approach(x: f64, target: f64, step: f64): f64 {
    if (x < target) return Math.min(x + step, target);
    return Math.max(x - step, target);
}

export function easeOutCubic(t: f64): f64 {
    let u = 1 - saturate(t);
    return 1 - u * u * u;
}

export function easeInOutCubic(t: f64): f64 {
    t = saturate(t);
    if (t < 0.5) return 4 * t * t * t;
    let u = -2 * t + 2;
    return 1 - u * u * u / 2;
}

export function easeOutBack(t: f64): f64 {
    t = saturate(t);
    let c1 = 1.70158;
    let c3 = c1 + 1;
    let u = t - 1;
    return 1 + c3 * u * u * u + c1 * u * u;
}

export function easeInQuad(t: f64): f64 {
    t = saturate(t);
    return t * t;
}

// 3D vectors (f32 components, as Luau's Vector) ------------------------------

export function v3(x: f64, y: f64, z: f64): Vector {
    return Vector.xyz(<f32>x, <f32>y, <f32>z);
}

// (in f64, rounded once, as Luau's component math)
export function cross(a: Vector, b: Vector): Vector {
    let ax = <f64>a.x, ay = <f64>a.y, az = <f64>a.z, bx = <f64>b.x, by = <f64>b.y, bz = <f64>b.z;
    return v3(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx);
}

export function dot(a: Vector, b: Vector): f64 {
    return <f64>a.x * <f64>b.x + <f64>a.y * <f64>b.y + <f64>a.z * <f64>b.z;
}

export function len(a: Vector): f64 {
    let x = <f64>a.x, y = <f64>a.y, z = <f64>a.z;
    return Math.sqrt(x * x + y * y + z * z);
}

export function norm(a: Vector): Vector {
    let l = len(a);
    if (l < 1e-9) return Vector.xyz(0, 0, 0);
    return v3(<f64>a.x / l, <f64>a.y / l, <f64>a.z / l);
}

export function dist(a: Vector, b: Vector): f64 {
    let dx = <f64>a.x - <f64>b.x, dy = <f64>a.y - <f64>b.y, dz = <f64>a.z - <f64>b.z;
    return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

export function dist2(a: Vector, b: Vector): f64 {
    let dx = <f64>a.x - <f64>b.x, dy = <f64>a.y - <f64>b.y, dz = <f64>a.z - <f64>b.z;
    return dx * dx + dy * dy + dz * dz;
}

export function vlerp(a: Vector, b: Vector, t: f64): Vector {
    return v3(<f64>a.x + (<f64>b.x - <f64>a.x) * t, <f64>a.y + (<f64>b.y - <f64>a.y) * t, <f64>a.z + (<f64>b.z - <f64>a.z) * t);
}

export function vdamp(a: Vector, b: Vector, rate: f64, dt: f64): Vector {
    let k = Math.exp(-rate * dt);
    return v3(<f64>b.x + (<f64>a.x - <f64>b.x) * k, <f64>b.y + (<f64>a.y - <f64>b.y) * k, <f64>b.z + (<f64>a.z - <f64>b.z) * k);
}

// Rotate v around unit axis k by angle (Rodrigues).
export function rotateAxis(v: Vector, k: Vector, ang: f64): Vector {
    let c = Math.cos(ang), s = Math.sin(ang);
    let kv = cross(k, v);
    let kd = dot(k, v) * (1 - c);
    return v3(<f64>v.x * c + <f64>kv.x * s + <f64>k.x * kd, <f64>v.y * c + <f64>kv.y * s + <f64>k.y * kd, <f64>v.z * c + <f64>kv.z * s + <f64>k.z * kd);
}

// Orthonormal basis from a forward direction and an up hint: BASIS_R, BASIS_U, BASIS_F.
export let BASIS_R: Vector = Vector.xyz(1, 0, 0);
export let BASIS_U: Vector = Vector.xyz(0, 1, 0);
export let BASIS_F: Vector = Vector.xyz(0, 0, 1);
export function basis(fwd: Vector, upHint: Vector): void {
    let f = norm(fwd);
    let r = norm(cross(f, upHint));
    if (len(r) < 1e-6) r = Vector.xyz(1, 0, 0);
    BASIS_R = r;
    BASIS_U = cross(r, f);
    BASIS_F = f;
}

// Deterministic RNG (Park-Miller) ----------------------------------------------

export { Rng };

@inline export function rng(seed: f64): Rng {
    return crng(seed);
}

@inline export function rand(r: Rng): f64 {
    return crand(r);
}

@inline export function randRange(r: Rng, a: f64, b: f64): f64 {
    return a + (b - a) * crand(r);
}

@inline export function randInt(r: Rng, a: f64, b: f64): f64 {
    return Math.floor(a + (b - a + 1) * crand(r));
}

// Hash + value noise -----------------------------------------------------------

@inline export function hash(x: f64, y: f64): f64 {
    let h = sinL(x * 127.1 + y * 311.7) * 43758.5453123;
    return h - Math.floor(h);
}

@inline export function hash3(x: f64, y: f64, z: f64): f64 {
    let h = sinL(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453123;
    return h - Math.floor(h);
}

export function noise2(x: f64, y: f64): f64 {
    let ix = Math.floor(x), iy = Math.floor(y);
    let fx = x - ix, fy = y - iy;
    let ux = fx * fx * (3 - 2 * fx);
    let uy = fy * fy * (3 - 2 * fy);
    let a = hash(ix, iy);
    let b = hash(ix + 1, iy);
    let c = hash(ix, iy + 1);
    let d = hash(ix + 1, iy + 1);
    return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
}

export function fbm2(x: f64, y: f64, octaves: i32): f64 {
    let s = 0.0, a = 0.5;
    for (let o = 0; o < octaves; o++) {
        s += a * noise2(x, y);
        x = x * 2.03 + 17.1;
        y = y * 2.03 + 9.3;
        a *= 0.5;
    }
    return s;
}

// Colors: 0xRRGGBB -> RGB_R, RGB_G, RGB_B in 0..1
export let RGB_R: f64 = 0;
export let RGB_G: f64 = 0;
export let RGB_B: f64 = 0;

export function rgb(hex: f64): void {
    let h = <u32>hex;
    RGB_R = <f64>((h >> 16) & 0xFF) / 255;
    RGB_G = <f64>((h >> 8) & 0xFF) / 255;
    RGB_B = <f64>(h & 0xFF) / 255;
}
