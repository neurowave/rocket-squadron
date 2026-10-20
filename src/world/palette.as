// Port of src/world/palette.luau: biome palettes feeding the Frame uniform
// (see DESIGN.md "Frame uniform"). `lerp` blends two palettes for the portal
// transition.
//
// Port: an RGB is a 1-based Array<f64> (slot 0 a dummy): [0, r, g, b].

export class Palette {
    name: string = "";
    biome: f64 = 0; // 0 coast, 1 violet
    skyTop: Array<f64> = [0.0, 0, 0, 0];
    skyHorizon: Array<f64> = [0.0, 0, 0, 0];
    sunDir: Array<f64> = [0.0, 0, 0, 0]; // toward the sun (normalised by the renderer)
    sunSize: f64 = 0;
    sunColor: Array<f64> = [0.0, 0, 0, 0];
    ambient: Array<f64> = [0.0, 0, 0, 0];
    shadowStrength: f64 = 0;
    shadowTint: Array<f64> = [0.0, 0, 0, 0];
    fogColor: Array<f64> = [0.0, 0, 0, 0];
    fogDensity: f64 = 0;
    ink: Array<f64> = [0.0, 0, 0, 0];
    inkWidth: f64 = 0;
    waterDeep: Array<f64> = [0.0, 0, 0, 0];
    waterShallow: Array<f64> = [0.0, 0, 0, 0];
    foam: Array<f64> = [0.0, 0, 0, 0];
    halftone: f64 = 0;
    cloudCover: f64 = 0;
    // post grade
    saturation: f64 = 0;
    contrast: f64 = 0;
    warmth: f64 = 0;
    exposure: f64 = 0;
}

export function hex(h: f64): Array<f64> {
    let u = <u32>h;
    let r = <f64>((u >> 16) & 0xFF) / 255;
    let g = <f64>((u >> 8) & 0xFF) / 255;
    let b = <f64>(u & 0xFF) / 255;
    return [0.0, r, g, b];
}

function rgb3(r: f64, g: f64, b: f64): Array<f64> {
    return [0.0, r, g, b];
}

function makeCoast(): Palette {
    let p = new Palette();
    p.name = "coast";
    p.biome = 0;
    p.skyTop = hex(0x2F74D0);
    p.skyHorizon = hex(0xAED8F2);
    p.sunDir = rgb3(-0.45, 0.72, 0.35);
    p.sunSize = 1;
    p.sunColor = hex(0xFFF6E2);
    p.ambient = hex(0x8AA4C4);
    p.shadowStrength = 1;
    p.shadowTint = hex(0x94A4CC);
    p.fogColor = hex(0xB9DDF3);
    p.fogDensity = 0.00034;
    p.ink = hex(0x151A2B);
    p.inkWidth = 0.0022;
    p.waterDeep = hex(0x0F5E86);
    p.waterShallow = hex(0x2F90B0);
    p.foam = hex(0xF4FAFF);
    p.halftone = 0.6;
    p.cloudCover = 0.06;
    p.saturation = 1.08;
    p.contrast = 1.04;
    p.warmth = 0.25;
    p.exposure = 1.0;
    return p;
}

function makeViolet(): Palette {
    let p = new Palette();
    p.name = "violet";
    p.biome = 1;
    p.skyTop = hex(0x3B2A8F);
    p.skyHorizon = hex(0x9C9BE6);
    p.sunDir = rgb3(0.35, 0.6, -0.55);
    p.sunSize = 1.4;
    p.sunColor = hex(0xF4ECFF);
    p.ambient = hex(0x7C6CC4);
    p.shadowStrength = 1;
    p.shadowTint = hex(0x6650C4);
    p.fogColor = hex(0x7F7AD8);
    p.fogDensity = 0.0005;
    p.ink = hex(0x1B0C3A);
    p.inkWidth = 0.0024;
    p.waterDeep = hex(0x0E86C2);
    p.waterShallow = hex(0x41D0EE);
    p.foam = hex(0xE8FDFF);
    p.halftone = 1.0;
    p.cloudCover = 0.16;
    p.saturation = 1.15;
    p.contrast = 1.06;
    p.warmth = -0.2;
    p.exposure = 1.0;
    return p;
}

export const coast: Palette = makeCoast();
export const violet: Palette = makeViolet();

@inline function lc(a: Array<f64>, b: Array<f64>, t: f64): Array<f64> {
    return [0.0, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t];
}

@inline function ln(a: f64, b: f64, t: f64): f64 {
    return a + (b - a) * t;
}

export function lerp(a: Palette, b: Palette, t: f64): Palette {
    let p = new Palette();
    p.name = t < 0.5 ? a.name : b.name;
    p.biome = ln(a.biome, b.biome, t);
    p.skyTop = lc(a.skyTop, b.skyTop, t);
    p.skyHorizon = lc(a.skyHorizon, b.skyHorizon, t);
    p.sunDir = lc(a.sunDir, b.sunDir, t);
    p.sunSize = ln(a.sunSize, b.sunSize, t);
    p.sunColor = lc(a.sunColor, b.sunColor, t);
    p.ambient = lc(a.ambient, b.ambient, t);
    p.shadowStrength = ln(a.shadowStrength, b.shadowStrength, t);
    p.shadowTint = lc(a.shadowTint, b.shadowTint, t);
    p.fogColor = lc(a.fogColor, b.fogColor, t);
    p.fogDensity = ln(a.fogDensity, b.fogDensity, t);
    p.ink = lc(a.ink, b.ink, t);
    p.inkWidth = ln(a.inkWidth, b.inkWidth, t);
    p.waterDeep = lc(a.waterDeep, b.waterDeep, t);
    p.waterShallow = lc(a.waterShallow, b.waterShallow, t);
    p.foam = lc(a.foam, b.foam, t);
    p.halftone = ln(a.halftone, b.halftone, t);
    p.cloudCover = ln(a.cloudCover, b.cloudCover, t);
    p.saturation = ln(a.saturation, b.saturation, t);
    p.contrast = ln(a.contrast, b.contrast, t);
    p.warmth = ln(a.warmth, b.warmth, t);
    p.exposure = ln(a.exposure, b.exposure, t);
    return p;
}
