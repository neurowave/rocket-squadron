// Port of src/game/sfx.luau. Sound. OWNER: audio. Names are the contract (DESIGN.md "Sounds").
//
// One-shots: per-name cooldown, voice caps with stealing, random variants
// (laser/hit/explode_small), rising pitch steps for ring chains, automatic
// music ducking under stingers (the set-piece stings: sting_<kind>, sting;
// a sting follows its card: paused with the game, cut with the card, and off
// with the music toggle).
// Loops: gapless, scheduled sample-exact on the engine's frame clock
// (Audio.playAtFrame; playAtTime rounds to whole ms) at the exact generated
// period (META below), volume ramps, crossfades.
// Fades: AudioSound.stop() takes engine PCM frames, not seconds (stopSound).
// Music: music() crossfades, starting the new track on the old one's next beat.
// scene() maps game state -> music + ambience; flight() drives jet/wind;
// charge() runs the charge whine into its hold loop; comm() opens the radio
// channel (chirp, static bed, squelch on close).
// Mix: per-sound balance (BASE), a soft bus compressor and a peak limiter on
// the sfx voices (PEAK, DENS below; the stings and the flight-school cues lead,
// the rest of the bus makes room), music ducking under big moments and open comms.
// Files: music, jingles, stings and the wind/jet loops are MP3 (META.lead =
// decoder lead-in), the rest FLAC.
// Everything is a silent no-op when a source is missing.
//
// Port: engine handles are wrapped (Src, Snd) so a test Tap (TAP) can stand
// in for the engine; play / stinger return Snd? (Luau AudioSound?). Optional
// numbers are NaN (nil); beat() sets BEAT_1 / BEAT_2. Lists 1-based.
import { Context } from "rive/host";
import { Audio, AudioSource, AudioSound } from "rive/audio";
import { lmin, lmax, lclamp, lstr, HUGE, lrandom, lrandomInt } from "../lib/compat";

// BEGIN GENERATED (tools/gen_audio.py)
// META: name, dur, loop, bpm, beats, lead
function genMeta(): void {
    meta("laser", 0.220340136, false, 0, 0, 0.000000000);
    meta("laser2", 0.220340136, false, 0, 0, 0.000000000);
    meta("laser3", 0.220340136, false, 0, 0, 0.000000000);
    meta("charge", 1.000000000, false, 0, 0, 0.000000000);
    meta("charge_hold", 0.500000000, true, 0, 0, 0.000000000);
    meta("nova", 2.200000000, false, 0, 0, 0.000000000);
    meta("hit", 0.220000000, false, 0, 0, 0.000000000);
    meta("hit2", 0.220000000, false, 0, 0, 0.000000000);
    meta("explode_small", 1.000000000, false, 0, 0, 0.000000000);
    meta("explode_small2", 1.000000000, false, 0, 0, 0.000000000);
    meta("explode_big", 3.200000000, false, 0, 0, 0.000000000);
    meta("ring", 0.750000000, false, 0, 0, 0.000000000);
    meta("ring2", 0.750000000, false, 0, 0, 0.000000000);
    meta("ring3", 0.750000000, false, 0, 0, 0.000000000);
    meta("ring4", 0.750000000, false, 0, 0, 0.000000000);
    meta("ring5", 0.750000000, false, 0, 0, 0.000000000);
    meta("ring_silver", 1.670340136, false, 0, 0, 0.000000000);
    meta("boost_start", 1.390068027, false, 0, 0, 0.000000000);
    meta("roll", 0.595056689, false, 0, 0, 0.000000000);
    meta("lock", 0.135192744, false, 0, 0, 0.000000000);
    meta("lock_full", 0.600000000, false, 0, 0, 0.000000000);
    meta("warning", 1.500000000, false, 0, 0, 0.000000000);
    meta("damage", 0.795056689, false, 0, 0, 0.000000000);
    meta("overheat", 1.795056689, false, 0, 0, 0.000000000);
    meta("ui_move", 0.070000000, false, 0, 0, 0.000000000);
    meta("ui_select", 0.450000000, false, 0, 0, 0.000000000);
    meta("ui_back", 0.350000000, false, 0, 0, 0.000000000);
    meta("pause", 0.500000000, false, 0, 0, 0.000000000);
    meta("countdown", 0.400000000, false, 0, 0, 0.000000000);
    meta("go", 1.590068027, false, 0, 0, 0.000000000);
    meta("portal", 4.500000000, false, 0, 0, 0.000000000);
    meta("checkpoint", 2.842494331, false, 0, 0, 0.000000000);
    meta("comm", 0.405147392, false, 0, 0, 0.000000000);
    meta("enemy_fire", 0.210136054, false, 0, 0, 0.000000000);
    meta("flyby", 1.600000000, false, 0, 0, 0.000000000);
    meta("splash", 0.690068027, false, 0, 0, 0.000000000);
    meta("score_tick", 0.040000000, false, 0, 0, 0.000000000);
    meta("rank", 1.600000000, false, 0, 0, 0.000000000);
    meta("jingle_clear", 6.784784580, false, 0, 0, 0.025056689);
    meta("jingle_over", 7.575714286, false, 0, 0, 0.025056689);
    meta("music_title", 39.183673469, true, 98, 4, 0.025056689);
    meta("music_level", 54.857142857, true, 140, 4, 0.025056689);
    meta("music_boss", 36.000000000, true, 160, 4, 0.025056689);
    meta("music_violet", 48.000000000, true, 120, 4, 0.025056689);
    meta("wind", 8.000000000, true, 0, 0, 0.034531250);
    meta("jet", 4.000000000, true, 0, 0, 0.025056689);
    meta("jet_boost", 4.000000000, true, 0, 0, 0.025056689);
    meta("horn", 2.800000000, false, 0, 0, 0.000000000);
    meta("cannon", 1.165124717, false, 0, 0, 0.000000000);
    meta("beep", 0.090158730, false, 0, 0, 0.000000000);
    meta("comm_static", 3.000000000, true, 0, 0, 0.000000000);
    meta("comm_out", 0.275102041, false, 0, 0, 0.000000000);
    meta("stamp", 0.345283447, false, 0, 0, 0.000000000);
    meta("ticket", 0.270113379, false, 0, 0, 0.000000000);
    meta("pop", 0.800000000, false, 0, 0, 0.000000000);
    meta("sting_training_complete", 2.400000000, false, 0, 0, 0.025056689);
    meta("sting_boss_stormcrow", 2.300000000, false, 0, 0, 0.025056689);
    meta("sting_boss_watcher", 2.300000000, false, 0, 0, 0.025056689);
    meta("sting_down_stormcrow", 2.450000000, false, 0, 0, 0.025056689);
    meta("sting_down_watcher", 2.450000000, false, 0, 0, 0.025056689);
    meta("sting_chapter_violet", 2.245056689, false, 0, 0, 0.025056689);
    meta("sting_arch_threaded", 1.340068027, false, 0, 0, 0.025056689);
    meta("sting_mission_complete", 2.500000000, false, 0, 0, 0.025056689);
    meta("sting", 1.500000000, false, 0, 0, 0.025056689);
    meta("thunder", 3.720226757, false, 0, 0, 0.000000000);
}
// peak envelopes (limiter): PK_ALPHA step per 25 ms window; loops: p99
function genPeak(): void {
    peak("laser", "DDnd95421");
    peak("laser2", "DDmf95321");
    peak("laser3", "DDme95321");
    peak("charge", "abbbadghhhfmooooooooooommoppuuurrrxxzzzxx");
    peak("charge_hold", "t");
    peak("nova", "sDKTTTLKHDDEEEEEEEzzzxvyyyxponpppmmlkkiiiifeeeba99999866655444443333233323332222222222221");
    peak("hit", "IIzqhb753");
    peak("hit2", "IIzphb754");
    peak("explode_small", "wJQQQBsssrponkjigddc997765544333322222211");
    peak("explode_small2", "rQQQLDAAxvsrpmkigfcba98766554444332222221");
    peak("explode_big", "SSSQWWWTTTSSJJJEEILLLGBCCCyyyBBBxxuooppppppmqqqghhhddeeeeeebabbbaaa88999967776666556777665444333333333223333333332222222222222222");
    peak("ring", "fvAIIICzwvuqnlhgfedcba999877642");
    peak("ring2", "lvxIIIEDBBuqollkihfedcbaa997642");
    peak("ring3", "tDIIIFFFAyuolkhfedbbbaa99986641");
    peak("ring4", "htCIIIDAyutroljhgedccbaa9986542");
    peak("ring5", "lxFIIIFAyywupoljhffeddcbbaa8632");
    peak("ring_silver", "epwyzJMNNNJIHHHzzwwssspppnnkkkkgffeeeedddcba97665443222211111111111");
    peak("boost_start", "NNNNNGGCFFFxAAAzzzrAAAyywuuumlnnnnnkkhhhgfhhhfffaaa75431");
    peak("roll", "1469eilrxxCCDDDvomfe6631");
    peak("lock", "ppoonk");
    peak("lock_full", "joopvvvnddcaa999888862111");
    peak("warning", "wGGIIIHIIIHHHHHGGGHHHDzzoe6uHHHFGGGDDDEHHHDCCFFFCxxpj94332111");
    peak("damage", "TTOLGCxvqlljddaa8777644443322221");
    peak("overheat", "JNNNMHFFGGGzzzyymjopppooonllkkkiiiiffgggddccbbbbb99888776655544443332211");
    peak("ui_move", "kk3");
    peak("ui_select", "hvzzzxqlkeec987554");
    peak("ui_back", "jsssoiec9865431");
    peak("pause", "ppvvvrmjgec987654433");
    peak("countdown", "IIIIBBynfda987652");
    peak("go", "TTTRRRKJHHAFFFBBuuutttqnjeddcbbaa9999887777666665555444443332211");
    peak("portal", "122233455677777766778999bbbdfffhhhheecc999beeeeeehhhbbaacefiiieeecffjjjgggfffffgggeefffgjjjiijjmnnnhggffjjjfllmmnnnlmqqqnljuuvvvppqqqrrrmqsswwwKKKQQQOIEuuvvvtuuummgggfedddb876643211");
    peak("checkpoint", "styzzCCEEEEEGHHMMMNNNMMMMMMTTTLOPRRRKKJJJHFFADGGGFFFFEEBBvsnmllljhhhfdddcbbbaa998888777776666554433333222222111111");
    peak("comm", "aa8vvvttspe222111");
    peak("enemy_fire", "xzzzxmc74");
    peak("flyby", "333444445566668abcdddflovvvvwCFFHIIIqqoooljfda9988776544444444321");
    peak("splash", "htttzzzngoookqqql65444332221");
    peak("score_tick", "gg");
    peak("rank", "QQQQQQLTTTMMLLBByyxxxxxttqqoolllkjjjjjhiiigffeeeddddddd987755321");
    peak("jingle_clear", "ijmuuuuBBByxxxBBBxxxxvuummpvvvurqqqqrxyBBBztrstuuustvvvzzzzzzxsstwwwuvvvvDDDAAACCCyxzzzzyzzCENNNKKRRRIIIGGHHHGGGGACCCACHHHDDCBAzzzzxxxxvvvzCCCwxxGSUUURRQMMMKKKIKKKIJJJGLLLHEEEBBCCCBCCCBAAAxxxBBBvxAAAyvvuwwwttonnpqqqnjlllljjjjllljjgjjjjigbb9998886554333333332333222111111111");
    peak("jingle_over", "gtHHHEEEEECDDDGGGAAzHHHDDBBBAAFFFKKKFyEEEBBAAADDDBBBEEEEHLLLKHHJMOOOFDEGGGCFFOOONDCstttrrttDDDxEEEyyyxwvvDDDCCzEEECzzzDDDEEEzywxxxyAAAuwwwxAEHIIIGzwxyEGGGBBByBBBDDDGGLLLJJLLLOOOPPPNNQQQMMPPPLJLOOOONNNNMMMLLLNNNJJJGGGGFFFEAtttoopppnmkkhhhfffeddddeeeccbbbaa999999999988888877777777666654322222211111111111111");
    peak("music_title", "z");
    peak("music_level", "w");
    peak("music_boss", "y");
    peak("music_violet", "x");
    peak("wind", "l");
    peak("jet", "w");
    peak("jet_boost", "x");
    peak("horn", "369fmmpzEEIIIJJJIHHBBCFFFIIIDBDELLLIIIJJJIIKLLLIIJJJMMMJJJIINNNHHHKKKKKKGGGKKKIIIGIIIFQQQEEBAwwwussrmmkiffc986321");
    peak("cannon", "KKQTTTGwsjjhfdca9776554333222221111111111111111");
    peak("beep", "ppnl");
    peak("comm_static", "i");
    peak("comm_out", "uuutomk21111");
    peak("stamp", "NNIzfe86322111");
    peak("ticket", "IIIHlf64211");
    peak("pop", "NNNygfcbbba9877777766665555443321");
    peak("sting_training_complete", "joxCFFFECCCsuzzzyyxwxzzzyvvszzzxxxtsrssvvvwBBBAADDDBBACPTTTSSSSSRMMNNNNRRRMFDCAAAtsplkgfdba8664431");
    peak("sting_boss_stormcrow", "3578dfLSSSSSSRKIIHEDHHHFFFDBwwvxxxwuusstttttrqqnmmmjjnnnlmnnnmptttIIPQRRRKIHHHCAAAytnlihda86421");
    peak("sting_boss_watcher", "3589cgJUUUUUURLLOORSSSQKOOOKKKKGGGDAAAFFGGGFCBBAutwwwunqwwwquuullgzMOOOGGDDDDCBCCCutnmlge975321");
    peak("sting_down_stormcrow", "13566tCFFFBBBBFIIIxruuxBBBwwrruuAAAzGGGCCAttEEEEBAAzEOSSTTTSRRQQQOOOLJLQQQJHOOOQTTTAzzwwwtiic9754321");
    peak("sting_down_watcher", "12477uBFFFEEECBBBxxnotttsqnnooprzzzxCCCAAxssDDDAAzzzEOSSTTTTSSQQQOOOLJLQQQJHOOOQTTTAzzwwwtjjc9754321");
    peak("sting_chapter_violet", "pOQRVVVOMMMMMHHEAACPPPJDDwwrwwwrvvCCCzzvvvssttwwwsuuusvvvvrruuussssrrsssmijjjeb999864442211");
    peak("sting_arch_threaded", "236999JTTTQQQFDDCCCxtrmmiiihhhfgggeeggggggeccc9765432111");
    peak("sting_mission_complete", "2577bbAKKTTTSSLKOOOFFEEDCCEEEzzzzyyxxxEEGMOOOOLLMMMKKKHFFFHHHGCCDJJJEAAAAAAyzzzwwqjiihedba877553322111");
    peak("sting", "12377GKWWWPTTTCCJJJyywvsrnnnmliiiigggeeedcccaaaa98776544332211");
    peak("thunder", "TTTIAGGGECBBynrtAAArrrrruuummihhbbchwwwvvvohhgggmwwwrpmjeecagjqqqpkieehhhbaaaccccbccc777bbbccc9999888888888776666336688866777774433333222111111111111");
}
// rms / peak envelope over each file's loud windows (limiter); loops: rms / p99
function genDens(): void {
    dens("laser", 0.38);
    dens("laser2", 0.38);
    dens("laser3", 0.37);
    dens("charge", 0.42);
    dens("charge_hold", 0.41);
    dens("nova", 0.41);
    dens("hit", 0.52);
    dens("hit2", 0.54);
    dens("explode_small", 0.55);
    dens("explode_small2", 0.55);
    dens("explode_big", 0.51);
    dens("ring", 0.48);
    dens("ring2", 0.41);
    dens("ring3", 0.42);
    dens("ring4", 0.44);
    dens("ring5", 0.42);
    dens("ring_silver", 0.38);
    dens("boost_start", 0.44);
    dens("roll", 0.33);
    dens("lock", 0.74);
    dens("lock_full", 0.46);
    dens("warning", 0.43);
    dens("damage", 0.58);
    dens("overheat", 0.38);
    dens("ui_move", 0.29);
    dens("ui_select", 0.50);
    dens("ui_back", 0.45);
    dens("pause", 0.49);
    dens("countdown", 0.50);
    dens("go", 0.41);
    dens("portal", 0.40);
    dens("checkpoint", 0.45);
    dens("comm", 0.61);
    dens("enemy_fire", 0.51);
    dens("flyby", 0.33);
    dens("splash", 0.33);
    dens("score_tick", 0.28);
    dens("rank", 0.38);
    dens("jingle_clear", 0.38);
    dens("jingle_over", 0.46);
    dens("music_title", 0.38);
    dens("music_level", 0.39);
    dens("music_boss", 0.39);
    dens("music_violet", 0.35);
    dens("wind", 0.33);
    dens("jet", 0.40);
    dens("jet_boost", 0.42);
    dens("horn", 0.48);
    dens("cannon", 0.57);
    dens("beep", 0.58);
    dens("comm_static", 0.37);
    dens("comm_out", 0.52);
    dens("stamp", 0.47);
    dens("ticket", 0.52);
    dens("pop", 0.35);
    dens("sting_training_complete", 0.39);
    dens("sting_boss_stormcrow", 0.35);
    dens("sting_boss_watcher", 0.39);
    dens("sting_down_stormcrow", 0.38);
    dens("sting_down_watcher", 0.38);
    dens("sting_chapter_violet", 0.36);
    dens("sting_arch_threaded", 0.35);
    dens("sting_mission_complete", 0.38);
    dens("sting", 0.38);
    dens("thunder", 0.42);
}
// END GENERATED

class Meta {
    dur: f64 = 0;
    loop: bool = false;
    bpm: f64 = 0;
    beats: f64 = 0;
    lead: f64 = 0;
}

const META: Map<string, Meta> = new Map<string, Meta>();
const PEAK: Map<string, string> = new Map<string, string>();
const DENS: Map<string, f64> = new Map<string, f64>();

function meta(name: string, dur: f64, loop: bool, bpm: f64, beats: f64, lead: f64): void {
    let m = new Meta();
    m.dur = dur;
    m.loop = loop;
    m.bpm = bpm;
    m.beats = beats;
    m.lead = lead;
    META.set(name, m);
}

function peak(name: string, env: string): void {
    PEAK.set(name, env);
}

function dens(name: string, d: f64): void {
    DENS.set(name, d);
}

// Engine access ------------------------------------------------------------------

// A stand-in for the audio engine (tests): with TAP set every source lookup,
// play, stop, volume write, clock read goes to it instead (ids: 0 = nil).
export abstract class Tap {
    abstract source(name: string): bool; // context.audio(name) ~= nil
    // how: 0 play, 1 playAtFrame (at = frame), 2 playAtTime (at = seconds); 0 = nil
    abstract play(name: string, how: i32, at: f64): i32;
    abstract time(): f64;
    abstract timeFrame(): f64;
    abstract sampleRate(): f64;
    abstract stop(id: i32, frames: f64): void;
    abstract setVolume(id: i32, v: f64): void;
    abstract completed(id: i32): bool;
    abstract pause(id: i32): void;
    abstract resume(id: i32): void;
}

export let TAP: Tap? = null;

// (an imported `let` cannot be assigned through the namespace)
export function setTap(t: Tap?): void {
    TAP = t;
}

// An audio source (Luau AudioSource)
export class Src {
    name: string = "";
    src: AudioSource? = null;
}

// A playing sound (Luau AudioSound)
export class Snd {
    snd: AudioSound? = null;
    id: i32 = 0; // TAP's handle
}

// Test hook: replaces Audio.time() (Luau timeFn)
export abstract class TimeFn {
    abstract time(): f64;
}

function aTime(): f64 {
    let tp = TAP;
    return tp != null ? tp.time() : Audio.time();
}

function aTimeFrame(): f64 {
    let tp = TAP;
    return tp != null ? tp.timeFrame() : Audio.timeFrame();
}

function aSampleRate(): f64 {
    let tp = TAP;
    return tp != null ? tp.sampleRate() : Audio.sampleRate();
}

function wrapSnd(s: AudioSound?): Snd? {
    if (s == null) return null;
    let w = new Snd();
    w.snd = s;
    return w;
}

function tapSnd(id: i32): Snd? {
    if (id == 0) return null;
    let w = new Snd();
    w.id = id;
    return w;
}

function aPlay(src: Src): Snd? {
    let tp = TAP;
    if (tp != null) return tapSnd(tp.play(src.name, 0, 0));
    let s = src.src;
    return s != null ? wrapSnd(Audio.play(s)) : null;
}

function aPlayAtFrame(src: Src, frame: f64): Snd? {
    let tp = TAP;
    if (tp != null) return tapSnd(tp.play(src.name, 1, frame));
    let s = src.src;
    return s != null ? wrapSnd(Audio.playAtFrame(s, frame)) : null;
}

function aPlayAtTime(src: Src, t: f64): Snd? {
    let tp = TAP;
    if (tp != null) return tapSnd(tp.play(src.name, 2, t));
    let s = src.src;
    return s != null ? wrapSnd(Audio.playAtTime(s, t)) : null;
}

function sStop(w: Snd, frames: f64): void {
    let tp = TAP;
    if (tp != null) {
        tp.stop(w.id, frames);
        return;
    }
    let s = w.snd;
    if (s != null) s.stop(frames);
}

function sVol(w: Snd, v: f64): void {
    let tp = TAP;
    if (tp != null) {
        tp.setVolume(w.id, v);
        return;
    }
    let s = w.snd;
    if (s != null) s.volume = v;
}

function sDone(w: Snd): bool {
    let tp = TAP;
    if (tp != null) return tp.completed(w.id);
    let s = w.snd;
    return s != null ? s.completed() : true;
}

function sPause(w: Snd): void {
    let tp = TAP;
    if (tp != null) {
        tp.pause(w.id);
        return;
    }
    let s = w.snd;
    if (s != null) s.pause();
}

function sResume(w: Snd): void {
    let tp = TAP;
    if (tp != null) {
        tp.resume(w.id);
        return;
    }
    let s = w.snd;
    if (s != null) s.resume();
}

// raw: volume before the category gain (setVolume re-applies it to live voices);
// half: started under the pause menu; pk, dn: its PEAK envelope and DENS;
// lead: keeps its level in the limiter; held: paused with the game (a sting)
export class Voice {
    snd: Snd;
    fam: string = "";
    t: f64 = 0;
    dur: f64 = 0;
    vol: f64 = 0;
    raw: f64 = 0;
    cat: string = "";
    bus: bool = false;
    half: bool = false;
    pk: string? = null;
    dn: f64 = 1;
    lead: bool = false;
    held: bool = false;
    constructor(snd: Snd) {
        this.snd = snd;
    }
}

// a music duck: level, seconds left
class Duck {
    level: f64 = 1;
    hold: f64 = 0;
}

export class Loop {
    name: string = "";
    src: Src;
    cur: Snd? = null;
    nxt: Snd? = null;
    t0: f64 = 0; // audio-clock start of `cur`
    dur: f64 = 0; // 0 = unknown length (poll completed())
    vol: f64 = 1; // fade 0..1
    target: f64 = 1;
    rate: f64 = 100; // fade units per second
    base: f64 = 1; // caller volume
    cat: string = "";
    constructor(src: Src) {
        this.src = src;
    }
}

export class Sfx {
    ctx: Context? = null;
    sources: Map<string, Src> = new Map<string, Src>();
    missing: Map<string, f64> = new Map<string, f64>(); // name -> clock of the failed lookup (retried after 2 s)
    loops: Map<string, Loop> = new Map<string, Loop>();
    voices: Array<Voice> = new Array<Voice>(1); // 1-based
    last: Map<string, f64> = new Map<string, f64>();
    lastPick: Map<string, string> = new Map<string, string>();
    t: f64 = 0;
    ticking: bool = false;
    master: f64 = 1; // user volume (HEADROOM is applied on top)
    cat: Map<string, f64> = new Map<string, f64>();
    duck: f64 = 1;
    duckTarget: f64 = 1;
    ducks: Map<string, Duck> = new Map<string, Duck>(); // live ducks by owner: the music sits at the lowest
    pauseGain: f64 = 1;
    pauseTarget: f64 = 1;
    musicName: string? = null;
    pending: string? = null;
    pendingAt: f64 = 0;
    ringStep: f64 = 0;
    ringT: f64 = -10;
    sceneKey: string = "";
    charging: bool = false;
    chargeSnd: Snd? = null;
    chargeT: f64 = 0;
    chargeVol: f64 = 1;
    chargeExplicit: bool = false; // charge() drives it (else play('charge') auto mode)
    commOn: bool = false;
    commEnd: f64 = 0; // auto mode: S.t when the channel closes
    commExplicit: bool = false; // comm() drives it (else play('comm') auto mode)
    inFlight: bool = true; // scene is launch / playing / paused (comms allowed)
    busGain: f64 = 1; // sfx bus gain 0..1 (compressor + limiter)
    leadGain: f64 = 1; // the lead voices' gain 0..1 (limiter only)
    busApplied: f64 = 1; // gains last written to the live voices
    leadApplied: f64 = 1;
    prevMusic: string? = null;
    prevMusicT0: f64 = 0;
    prevMusicAt: f64 = -10;
    lastCount: f64 = -1;
    sting: Voice? = null; // the live stinger (follows its card)
    stingHeldAt: f64 = 0; // clock when the pause stopped it
    stingFade: f64 = 1; // 1 sounding .. 0 stopped (the hold / resume ramp)
    stingStopped: bool = false;
    timeFn: TimeFn? = null; // test hook: replaces Audio.time()
}

// Mix ------------------------------------------------------------------------------

// in-engine balance per family (files are normalized by peak). Set from measured
// short-term loudness at the game's call volumes: flight music sits about 4 dB
// over the player's lasers; kills, hits, enemy fire and comms read over the music.
const BASE: Map<string, f64> = new Map<string, f64>();

// fixed headroom under the user's master volume. 0.85 left the big moments no
// room: a boss kill summed to +5 dBFS before the bus and the limiter took the
// blast and its sting down to a third. At 0.6 (-3 dB on everything, balance
// unchanged) the kills stand over the fighting again with the mix under 0 dBFS.
const HEADROOM: f64 = 0.6;

// per-play volume spread (+-) so rapid repeats do not sound like one sample
const JITTER: Map<string, f64> = new Map<string, f64>();

// sfx bus compressor: summed (power) level of the live sfx voices (the leads
// aside) over BUS_KNEE is pulled down with gain (knee / level) ^ BUS_SLOPE (about
// 2.5:1); instant attack, BUS_RELEASE per second back up. Over BUS_DUCK the music
// also dips. (Levels are voice volumes: both scale with HEADROOM.)
const BUS_KNEE: f64 = 1.0 * HEADROOM / 0.85;
const BUS_SLOPE: f64 = 0.6;
const BUS_RELEASE: f64 = 2.5;
const BUS_DUCK: f64 = 1.25 * HEADROOM / 0.85;
// sfx bus peak limiter: the mix's sample peak over the next PK_AHEAD windows is
// estimated from each live sound's peak envelope (PEAK: PK_RATE windows a second)
// and density (DENS: rms / peak), both measured on the shipped files. The sounds'
// phases are unknown, so the estimate is one sound's peak plus PK_SIGMA times the
// rms of everything else (voices and loops), or the two loudest peaks in full plus
// that for the rest when it is lower.
// Two gains keep it under PK_LIMIT: the lead voices (the stings and LEAD) hold
// their level while the rest of the bus makes room, down to PK_FLOOR; only then
// do the leads give way. ui, jingles and loops are never touched.
const PK_RATE: f64 = 40; // windows per second (tools/gen_audio.py PK_WIN)
const PK_AHEAD: i32 = 3;
const PK_LIMIT: f64 = 1.0;
const PK_SIGMA: f64 = 3.5;
const PK_FLOOR: f64 = 0.25;
// bus sounds that lead with the stings: the flight-school feedback
const LEAD: Set<string> = new Set<string>();
const PK_ALPHA = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const PK_DEC: Array<f64> = new Array<f64>(256); // by char code; -1 = Luau nil

// auto-mode comm channel: a typical comms line (core holds a line for
// max(seconds, 1.8 + 0.042 * #text); wingmen lines are 4.2 s). comm() is exact.
const COMM_HOLD: f64 = 4.2;

// minimum seconds between two plays of the same family
const COOL: Map<string, f64> = new Map<string, f64>();

// max simultaneous voices per family (oldest is stolen)
const MAXV: Map<string, f64> = new Map<string, f64>();
const MAX_VOICES: i32 = 28;

// music duck (level at call volume 1, seconds) under big moments; a quieter
// play dips the music less (the chain bonus is a 'checkpoint' at 0.5)
const DUCK: Map<string, Duck> = new Map<string, Duck>();

// music level under a stinger (default 0.35) for 0.8 of its length: the boss
// posters are in D minor over the level / violet loops (the boss loop starts
// after them), so those dip further
const STING_DUCK: Map<string, f64> = new Map<string, f64>();

const VARIANTS: Map<string, Array<string>> = new Map<string, Array<string>>(); // 1-based lists

const RING: Array<string> = ["", "ring", "ring2", "ring3", "ring4", "ring5"]; // 1-based
const RING_WINDOW: f64 = 1.4; // seconds between rings to keep climbing

const FAMILY: Map<string, string> = new Map<string, string>();

function kv(m: Map<string, f64>, k: string, v: f64): void {
    m.set(k, v);
}

function duckSpec(k: string, level: f64, hold: f64): void {
    let d = new Duck();
    d.level = level;
    d.hold = hold;
    DUCK.set(k, d);
}

function variants(fam: string, a: string, b: string, c: string): void {
    let l: Array<string> = ["", a, b];
    if (c.length > 0) l.push(c);
    VARIANTS.set(fam, l);
}

// Module tables (run once, before any use: enemies / boss_stormcrow read
// duration() from their module init)
let TABLES = false;
function tables(): void {
    if (TABLES) return;
    TABLES = true;
    genMeta();
    genPeak();
    genDens();
    let b = BASE;
    kv(b, "laser", 1.0); kv(b, "charge", 0.55); kv(b, "charge_hold", 0.4); kv(b, "nova", 1.05); kv(b, "hit", 0.85);
    kv(b, "explode_small", 1.2); kv(b, "explode_big", 1.2); kv(b, "ring", 0.68); kv(b, "ring_silver", 0.8);
    kv(b, "boost_start", 0.7); kv(b, "roll", 0.7); kv(b, "lock", 0.45); kv(b, "lock_full", 0.8); kv(b, "warning", 0.8);
    kv(b, "damage", 0.9); kv(b, "overheat", 0.7); kv(b, "ui_move", 1.0); kv(b, "ui_select", 0.8); kv(b, "ui_back", 0.7);
    kv(b, "pause", 0.7); kv(b, "countdown", 0.85); kv(b, "go", 0.95); kv(b, "portal", 0.9); kv(b, "checkpoint", 0.85);
    kv(b, "comm", 0.95); kv(b, "comm_out", 0.7); kv(b, "comm_static", 0.36);
    kv(b, "enemy_fire", 0.8); kv(b, "flyby", 0.75); kv(b, "splash", 0.8); kv(b, "score_tick", 0.5);
    kv(b, "rank", 0.9); kv(b, "jingle_clear", 0.9); kv(b, "jingle_over", 0.85); kv(b, "horn", 0.9); kv(b, "cannon", 0.8); kv(b, "beep", 1.0);
    kv(b, "stamp", 0.9); kv(b, "ticket", 1.05); kv(b, "pop", 1.2); kv(b, "sting", 0.85); kv(b, "sting_training_complete", 0.85);
    kv(b, "sting_boss_stormcrow", 0.85); kv(b, "sting_boss_watcher", 0.85); kv(b, "sting_down_stormcrow", 0.85);
    kv(b, "sting_down_watcher", 0.85); kv(b, "sting_chapter_violet", 0.85); kv(b, "sting_arch_threaded", 0.95);
    kv(b, "sting_mission_complete", 0.85); kv(b, "thunder", 0.9);
    kv(b, "music_title", 0.78); kv(b, "music_level", 0.61); kv(b, "music_boss", 0.65); kv(b, "music_violet", 0.55);
    kv(b, "wind", 0.7); kv(b, "jet", 0.72); kv(b, "jet_boost", 0.6);
    let j = JITTER;
    kv(j, "laser", 0.1); kv(j, "hit", 0.1); kv(j, "explode_small", 0.12); kv(j, "enemy_fire", 0.12); kv(j, "splash", 0.1);
    kv(j, "flyby", 0.1); kv(j, "cannon", 0.08); kv(j, "beep", 0.05);
    LEAD.add("pop");
    LEAD.add("stamp");
    LEAD.add("ticket");
    for (let i = 0; i < 256; i++) PK_DEC[i] = -1;
    let na = PK_ALPHA.length;
    for (let i = 1; i <= na; i++) {
        PK_DEC[PK_ALPHA.charCodeAt(i - 1)] = <f64>(i - 1) / <f64>(na - 1);
    }
    let c = COOL;
    kv(c, "laser", 0.05); kv(c, "hit", 0.035); kv(c, "explode_small", 0.05); kv(c, "explode_big", 0.2); kv(c, "ring", 0.03);
    kv(c, "lock", 0.06); kv(c, "warning", 1.0); kv(c, "damage", 0.12); kv(c, "overheat", 0.8); kv(c, "ui_move", 0.03);
    kv(c, "countdown", 0.25); kv(c, "enemy_fire", 0.06); kv(c, "flyby", 0.35); kv(c, "splash", 0.3); kv(c, "score_tick", 0.035);
    kv(c, "roll", 0.15); kv(c, "boost_start", 0.25); kv(c, "comm", 0.25); kv(c, "comm_out", 0.25); kv(c, "go", 0.5); kv(c, "checkpoint", 0.5); kv(c, "nova", 0.2);
    kv(c, "horn", 2.0); kv(c, "cannon", 0.12); kv(c, "beep", 0.08); kv(c, "charge", 0.3);
    kv(c, "stamp", 0.2); kv(c, "ticket", 0.15); kv(c, "pop", 0.05); kv(c, "thunder", 0.5);
    let m = MAXV;
    kv(m, "laser", 4); kv(m, "hit", 4); kv(m, "explode_small", 5); kv(m, "enemy_fire", 4); kv(m, "ring", 3); kv(m, "score_tick", 2);
    kv(m, "ui_move", 2); kv(m, "flyby", 3); kv(m, "splash", 2); kv(m, "lock", 2); kv(m, "cannon", 3); kv(m, "beep", 3); kv(m, "pop", 3); kv(m, "thunder", 2);
    duckSpec("checkpoint", 0.4, 2.2); duckSpec("explode_big", 0.65, 1.2);
    duckSpec("nova", 0.7, 0.9); duckSpec("portal", 0.45, 3.8); duckSpec("rank", 0.5, 1.2);
    duckSpec("ring_silver", 0.75, 0.8); duckSpec("warning", 0.75, 1.2); duckSpec("damage", 0.75, 0.4);
    duckSpec("horn", 0.6, 2.4);
    kv(STING_DUCK, "sting_boss_stormcrow", 0.25);
    kv(STING_DUCK, "sting_boss_watcher", 0.25);
    variants("laser", "laser", "laser2", "laser3");
    variants("hit", "hit", "hit2", "");
    variants("explode_small", "explode_small", "explode_small2", "");
    let fams = VARIANTS.keys();
    for (let i = 0; i < fams.length; i++) {
        let list = VARIANTS.get(fams[i]);
        for (let k = 1; k < list.length; k++) FAMILY.set(list[k], fams[i]);
    }
    for (let k = 1; k < RING.length; k++) FAMILY.set(RING[k], "ring");
}

@inline function getF(m: Map<string, f64>, k: string, d: f64): f64 {
    return m.has(k) ? m.get(k) : d;
}

function family(name: string): string {
    return FAMILY.has(name) ? FAMILY.get(name) : name;
}

// the music category's default level (M: 0 = music off)
const MUSIC_CAT: f64 = 0.62;

function category(name: string): string {
    if (name.startsWith("music_") || name.startsWith("jingle_")) {
        return "music";
    } else if (name == "sting" || name.startsWith("sting_")) {
        return "sting"; // scored music on the sfx bus
    } else if (name == "wind" || name == "jet" || name == "jet_boost" || name == "comm_static") {
        return "amb";
    } else if (name.startsWith("ui_") || name == "countdown" || name == "pause" || name == "comm" || name == "comm_out" || name == "score_tick") {
        return "ui";
    }
    return "sfx";
}

// Core -------------------------------------------------------------------------------

export function create(ctx: Context?): Sfx {
    tables();
    let S = new Sfx();
    S.ctx = ctx;
    S.cat.set("sfx", 1);
    S.cat.set("ui", 0.8);
    S.cat.set("music", MUSIC_CAT);
    S.cat.set("amb", 0.55);
    return S;
}

function source(S: Sfx, name: string): Src? {
    if (S.sources.has(name)) {
        return S.sources.get(name);
    }
    if (S.missing.has(name) && S.t - S.missing.get(name) < 2) {
        return null;
    }
    let ctx = S.ctx;
    let tp = TAP;
    let a: Src? = null;
    if (tp != null) {
        if (tp.source(name)) {
            a = new Src();
            a.name = name;
        }
    } else {
        if (ctx == null) {
            return null;
        }
        let s = ctx.audio(name);
        if (s != null) {
            a = new Src();
            a.name = name;
            a.src = s;
        }
    }
    if (a != null) {
        S.sources.set(name, a);
        S.missing.delete(name);
    } else {
        S.missing.set(name, S.t);
    }
    return a;
}

// Engine clock in seconds. The frame clock is exact; Audio.time() is whole ms in a
// float32 (and the int frame count wraps after ~12 h, so fall back when they disagree).
function engineTime(S: Sfx): f64 {
    let f = S.timeFn;
    if (f != null) {
        return f.time();
    }
    let t = aTime();
    let sr = aSampleRate();
    if (sr > 0) {
        let ft = aTimeFrame() / sr;
        if (Math.abs(ft - t) < 0.5) {
            return ft;
        }
    }
    return t;
}

// Round an engine time to the frame grid (sample-exact loop chains).
function snap(t: f64): f64 {
    let sr = aSampleRate();
    if (sr > 0) {
        return Math.floor(t * sr + 0.5) / sr;
    }
    return t;
}

// Schedule a sound at an engine time, to the nearest frame.
function playAt(src: Src, t: f64): Snd? {
    let sr = aSampleRate();
    if (sr > 0) {
        return aPlayAtFrame(src, Math.floor(t * sr + 0.5));
    }
    return aPlayAtTime(src, t);
}

// Stop with a native fade of `fade` seconds (NaN: none). AudioSound.stop takes
// engine PCM frames (stop(1.2) is a 1-frame cut).
function stopSound(snd: Snd, fade: f64): void {
    let f = isNaN(fade) ? 0 : fade;
    let sr = aSampleRate();
    sStop(snd, f > 0 && sr > 0 ? Math.floor(f * sr + 0.5) : 0);
}

// Audio-engine clock when it runs, else our own (headless the engine clock is 0).
function clock(S: Sfx): f64 {
    let at = engineTime(S);
    if (at > 0) {
        return at;
    }
    return S.t;
}

function gainFor(S: Sfx, cat: string): f64 {
    let g = HEADROOM * S.master * getF(S.cat, cat, 1);
    if (cat == "music") {
        g *= S.duck * S.pauseGain;
    } else if (cat == "amb") {
        g *= lmin(1, 0.5 + 0.5 * S.duck) * (S.pauseTarget < 1 ? 0 : S.pauseGain);
    } else if (cat == "sting") {
        // scored: on and off with the music (M), at the sfx level
        g *= getF(S.cat, "sfx", 1) * lclamp(getF(S.cat, "music", 0) / MUSIC_CAT, 0, 1);
    }
    return g;
}

// A one-shot's volume before the bus: a bus sound started under the pause menu
// plays at half level for its whole length; one already sounding keeps its level.
function voiceVol(S: Sfx, raw: f64, cat: string, half: bool): f64 {
    return raw * gainFor(S, cat) * (half ? 0.5 : 1);
}

/// Exact length of a generated sound in seconds (0 when unknown).
export function duration(name: string): f64 {
    tables();
    return META.has(name) ? META.get(name).dur : 0;
}

/// True when the named sound exists in the file.
export function has(S: Sfx, name: string): bool {
    return source(S, name) != null;
}

/// Name of the pitch step `step` (1-based) of a stepped family: pitchVariant(S, 'ring', 3) -> 'ring3'.
/// Clamps to the highest step that exists; step 1 is the base name.
export function pitchVariant(S: Sfx, base: string, step: f64): string {
    let k = Math.floor(step);
    while (k > 1) {
        let n = base + lstr(k);
        if (source(S, n) != null) {
            return n;
        }
        k -= 1;
    }
    return base;
}

/// Duck music (and a little ambience) to `level` for `hold` seconds. Each owner
/// (`key`, default 'duck') holds its own duck; the music sits at the lowest live
/// one, so a long light duck (open comms) never keeps a deep short one alive.
export function duck(S: Sfx, level: f64, hold: f64, key: string? = null): void {
    let k = key != null ? key : "duck";
    if (S.ducks.has(k)) {
        let d = S.ducks.get(k);
        d.level = lmin(d.level, level);
        d.hold = lmax(d.hold, hold);
    } else {
        let d = new Duck();
        d.level = level;
        d.hold = hold;
        S.ducks.set(k, d);
    }
    if (S.pauseTarget >= 1) {
        S.duckTarget = lmin(S.duckTarget, level);
    }
}

// The gain a bus voice plays at: lead or rest, and the live sting's hold ramp.
function busOf(S: Sfx, e: Voice): f64 {
    let g = e.lead ? S.leadGain : S.busGain;
    return e == S.sting ? g * S.stingFade : g;
}

function prune(S: Sfx, now: f64): void {
    let v = S.voices;
    let i = 1;
    while (i <= v.length - 1) {
        let e = v[i];
        if (!e.held && (now > e.t + e.dur + 0.25 || sDone(e.snd))) {
            if (S.sting == e) {
                S.sting = null;
            }
            v[i] = v[v.length - 1];
            v.length = v.length - 1;
        } else {
            i += 1;
        }
    }
}

// oldest voice of `fam` (any family but a sting when null)
function steal(S: Sfx, fam: string?): void {
    let v = S.voices;
    let idx = 0;
    let oldest = HUGE;
    for (let i = 1; i < v.length; i++) {
        let e = v[i];
        if ((fam == null ? e.cat != "sting" : e.fam == fam) && e.t < oldest) {
            oldest = e.t;
            idx = i;
        }
    }
    if (idx > 0) {
        stopSound(v[idx].snd, 0.03);
        v.splice(idx, 1);
    }
}

// Peak of a sound `age` s in, 0..1 of full scale (PEAK envelope; none: full for its length).
function peakAt(pk: string?, dur: f64, age: f64): f64 {
    if (pk == null) {
        return age < dur ? 1 : 0;
    }
    let k = lmax(1, Math.floor(age * PK_RATE) + 1);
    if (k > <f64>pk.length) {
        return 0;
    }
    let d = PK_DEC[pk.charCodeAt(<i32>k - 1)];
    return d < 0 ? 1 : d;
}

// limiter scratch: peak, rms and tier (0 untouched, 1 lead, 2 rest) per live voice (1-based)
const LIM_P: Array<f64> = [0.0];
const LIM_R: Array<f64> = [0.0];
const LIM_T: Array<i32> = [0];

function limSet(n: i32, p: f64, r: f64, t: i32): void {
    while (LIM_P.length <= n) {
        LIM_P.push(0);
        LIM_R.push(0);
        LIM_T.push(0);
    }
    LIM_P[n] = p;
    LIM_R[n] = r;
    LIM_T[n] = t;
}

// Estimated mix peak over the first n scratch rows and the loops (`bed`: their
// power), with the leads at gl and the rest of the bus at gr.
function mixPeak(n: i32, bed: f64, gl: f64, gr: f64): f64 {
    let pow = bed;
    let p1 = 0.0, r1 = 0.0, p2 = 0.0, r2 = 0.0; // the two loudest: peak, rms
    for (let i = 1; i <= n; i++) {
        let t = LIM_T[i];
        let g = t == 1 ? gl : t == 2 ? gr : 1;
        let p = LIM_P[i] * g, r = LIM_R[i] * g;
        pow += r * r;
        if (p > p1) {
            p2 = p1;
            r2 = r1;
            p1 = p;
            r1 = r;
        } else if (p > p2) {
            p2 = p;
            r2 = r;
        }
    }
    // one sound's peak over the rms of all the others, whichever sound leads
    let one = 0.0;
    for (let i = 1; i <= n; i++) {
        let t = LIM_T[i];
        let g = t == 1 ? gl : t == 2 ? gr : 1;
        let r = LIM_R[i] * g;
        let e = LIM_P[i] * g + PK_SIGMA * Math.sqrt(lmax(0, pow - r * r));
        if (e > one) {
            one = e;
        }
    }
    // or the two loudest in full over the rest (the second adds its peak at most)
    let two = p1 + p2 + PK_SIGMA * Math.sqrt(lmax(0, pow - r1 * r1 - r2 * r2));
    return lmax(PK_SIGMA * Math.sqrt(pow), lmin(one, two));
}

// Largest gain in PK_FLOOR..hi that keeps mixPeak under PK_LIMIT (`lead`: solve
// the leads' gain with the rest at the floor, else the rest's with the leads at gl).
function fit(n: i32, bed: f64, lead: bool, gl: f64, hi: f64): f64 {
    let lo = PK_FLOOR;
    if (mixPeak(n, bed, lead ? lo : gl, lo) > PK_LIMIT) {
        return lo;
    }
    for (let k = 1; k <= 8; k++) {
        let mid = (lo + hi) * 0.5;
        if (mixPeak(n, bed, lead ? mid : gl, lead ? PK_FLOOR : mid) > PK_LIMIT) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    return lo;
}

// The bus gains: a power compressor on the rest of the bus (each live voice counts
// at full volume for its first 120 ms, then fades linearly over the rest of its
// length) under the peak limiter (PK_*). Instant attack; releases at most
// BUS_RELEASE * dt, so dt = 0 only pulls them down.
function busUpdate(S: Sfx, now: f64, dt: f64): void {
    let sum = 0.0;
    let vs = S.voices;
    for (let i = 1; i < vs.length; i++) {
        let e = vs[i];
        if (e.bus && !e.lead && !e.held) {
            let age = now - e.t;
            let k = age < 0.12 ? 1 : lmax(0, 1 - (age - 0.12) / lmax(0.1, e.dur - 0.12));
            let a = e.vol * k;
            sum += a * a;
        }
    }
    let level = Math.sqrt(sum);
    let rest = level > BUS_KNEE ? Math.pow(BUS_KNEE / level, BUS_SLOPE) : 1;
    let lead = 1.0;
    // limiter: the loops (rms, power) are a fixed bed
    // (Luau pairs order over S.loops: the sum may differ in the last ulp)
    let bed = 0.0;
    let ls = S.loops.values();
    for (let i = 0; i < ls.length; i++) {
        let L = ls[i];
        let pkf = 1.0;
        if (PEAK.has(L.name)) {
            let d = PK_DEC[PEAK.get(L.name).charCodeAt(0)];
            pkf = d < 0 ? 1 : d;
        }
        let a = loopVol(S, L) * pkf * getF(DENS, L.name, 1);
        bed += a * a;
    }
    let cs = S.chargeSnd;
    let chargeLvl = cs != null ? S.chargeVol * getF(BASE, "charge", 1) * gainFor(S, "sfx") : 0;
    for (let j = 0; j <= PK_AHEAD; j++) {
        let ahead = <f64>j / PK_RATE;
        let n = 0, leads = 0, rests = 0;
        if (chargeLvl > 0) {
            let p = chargeLvl * peakAt(PEAK.has("charge") ? PEAK.get("charge") : null, duration("charge"), S.t - S.chargeT + ahead);
            if (p > 0) {
                n += 1;
                limSet(n, p, p * getF(DENS, "charge", 1), 0);
            }
        }
        for (let i = 1; i < vs.length; i++) {
            let e = vs[i];
            if (!e.held) {
                let p = e.vol * peakAt(e.pk, e.dur, now - e.t + ahead);
                if (p > 0) {
                    n += 1;
                    limSet(n, p, p * e.dn, !e.bus ? 0 : e.lead ? 1 : 2);
                    if (e.bus) {
                        leads += e.lead ? 1 : 0;
                        rests += e.lead ? 0 : 1;
                    }
                }
            }
        }
        if (n > 0 && mixPeak(n, bed, lead, rest) > PK_LIMIT) {
            if (rests > 0 && mixPeak(n, bed, lead, PK_FLOOR) <= PK_LIMIT) {
                rest = fit(n, bed, false, lead, rest);
            } else {
                if (rests > 0) {
                    rest = lmin(rest, PK_FLOOR);
                }
                if (leads > 0) {
                    lead = fit(n, bed, true, lead, lead);
                }
            }
        }
    }
    S.busGain = lmin(lmax(PK_FLOOR, rest), S.busGain + BUS_RELEASE * dt);
    S.leadGain = lmin(lmax(PK_FLOOR, lead), S.leadGain + BUS_RELEASE * dt);
    if (level > BUS_DUCK) {
        duck(S, 0.8, 0.25, "bus");
    }
}

function applyBus(S: Sfx): void {
    S.busApplied = S.busGain;
    S.leadApplied = S.leadGain;
    let vs = S.voices;
    for (let i = 1; i < vs.length; i++) {
        let e = vs[i];
        // completed() is safe on a sound the engine already disposed; volume is not
        if (e.bus && !e.held && !sDone(e.snd)) {
            sVol(e.snd, e.vol * busOf(S, e));
        }
    }
}

/// Play a one-shot. Variants, ring steps, cooldown, voice caps and ducking are automatic.
/// 'charge' also starts the gapless charge_hold loop; nova/laser/overheat end it.
/// volume: NaN = 1.
export function play(S: Sfx, name: string, volume: f64 = NaN): Snd? {
    // with charge() driving the player's charge, a played 'charge' is someone else's
    // charge-up (a boss): a plain one-shot
    if (name == "charge" && !S.chargeExplicit) {
        if (!S.charging) {
            S.charging = true;
            startCharge(S, isNaN(volume) ? 1 : volume);
        }
        return S.chargeSnd;
    }
    if (S.charging && !S.chargeExplicit && (name == "nova" || name == "laser" || name == "overheat")) {
        S.charging = false;
        stopCharge(S);
    }
    let fam = family(name);
    let now = clock(S);
    if (S.last.has(fam) && now - S.last.get(fam) < getF(COOL, fam, 0.02)) {
        return null;
    }
    let pick = name;
    if (VARIANTS.has(name)) {
        let vars = VARIANTS.get(name);
        let prev: string? = S.lastPick.has(name) ? S.lastPick.get(name) : null;
        for (let k = 1; k <= 3; k++) {
            pick = vars[lrandomInt(1, vars.length - 1)];
            if (prev == null || pick != prev) {
                break;
            }
        }
        S.lastPick.set(name, pick);
    } else if (name == "ring") {
        if (now - S.ringT < RING_WINDOW) {
            S.ringStep = lmin(<f64>(RING.length - 1), S.ringStep + 1);
        } else {
            S.ringStep = 1;
        }
        S.ringT = now;
        pick = RING[<i32>S.ringStep];
    }
    let src = source(S, pick);
    if (src == null && pick != name) {
        pick = name;
        src = source(S, name);
    }
    if (src == null) {
        return null;
    }
    prune(S, now);
    if (MAXV.has(fam)) {
        let cap = MAXV.get(fam);
        let n = 0.0;
        let vs = S.voices;
        for (let i = 1; i < vs.length; i++) {
            if (vs[i].fam == fam) {
                n += 1;
            }
        }
        if (n >= cap) {
            steal(S, fam);
        }
    }
    if (S.voices.length - 1 >= MAX_VOICES) {
        steal(S, null);
    }
    let snd = aPlay(src);
    if (snd == null) {
        return null;
    }
    let cat = category(name);
    let raw = (isNaN(volume) ? 1 : volume) * getF(BASE, fam, 1);
    if (JITTER.has(fam)) {
        let j = JITTER.get(fam);
        raw *= 1 + (lrandom() * 2 - 1) * j;
    }
    let bus = cat == "sfx" || cat == "sting";
    let half = bus && S.pauseTarget < 1;
    let vol = voiceVol(S, raw, cat, half);
    let lead = cat == "sting" || LEAD.has(fam);
    S.last.set(fam, now);
    let e = new Voice(snd);
    e.fam = fam;
    e.t = now;
    e.dur = META.has(pick) ? META.get(pick).dur : 3;
    e.vol = vol;
    e.raw = raw;
    e.cat = cat;
    e.bus = bus;
    e.half = half;
    e.pk = PEAK.has(pick) ? PEAK.get(pick) : null;
    e.dn = getF(DENS, pick, 1);
    e.lead = lead;
    e.held = false;
    S.voices.push(e);
    if (bus) {
        busUpdate(S, now, 0);
        if (S.busGain < S.busApplied - 0.002 || S.leadGain < S.leadApplied - 0.002) {
            applyBus(S); // attack: pull the live bus voices down now
        }
        sVol(snd, vol * busOf(S, e));
    } else {
        sVol(snd, vol);
    }
    if (DUCK.has(fam)) {
        let d = DUCK.get(fam);
        duck(S, 1 - (1 - d.level) * lclamp(isNaN(volume) ? 1 : volume, 0, 1), d.hold, fam);
    }
    if (name == "comm" && !S.commExplicit) {
        S.commEnd = S.t + COMM_HOLD;
        commOpen(S);
    }
    return snd;
}

// The live sting's card is paused (hold) or resumed with the game: the sound
// ramps out over STING_RAMP, stops, and resumes where it was with the ramp back
// in (update runs the ramp: the engine has no fade on a pause, and volume
// changes are steps). Its clock and its duck stand still while it is stopped.
const STING_RAMP: f64 = 0.07;

function stingHold(S: Sfx, hold: bool): void {
    let e = S.sting;
    if (e == null || e.held == hold) {
        return;
    }
    if (hold) {
        if (sDone(e.snd)) {
            S.sting = null;
            return;
        }
        e.held = true;
    } else {
        e.held = false;
        // its level now (M or N may have been pressed under the pause)
        e.vol = voiceVol(S, e.raw, e.cat, e.half);
        if (S.stingStopped) {
            S.stingStopped = false;
            e.t += clock(S) - S.stingHeldAt;
            sVol(e.snd, e.vol * busOf(S, e));
            sResume(e.snd);
        }
    }
}

// The hold / resume ramp of the live sting (every frame).
function stingRamp(S: Sfx, dt: f64): void {
    let e = S.sting;
    if (e == null) {
        S.stingFade = 1;
        S.stingStopped = false;
        return;
    }
    let target: f64 = e.held ? 0 : 1;
    if (S.stingFade == target || S.stingStopped) {
        return;
    }
    let step = dt / STING_RAMP;
    S.stingFade = target > 0 ? lmin(1, S.stingFade + step) : lmax(0, S.stingFade - step);
    if (sDone(e.snd)) {
        return;
    }
    sVol(e.snd, e.vol * busOf(S, e));
    if (e.held && S.stingFade <= 0) {
        sPause(e.snd);
        S.stingStopped = true;
        S.stingHeldAt = clock(S);
    }
}

// The live sting's card was cut: fade it out (a held one is already silent) and lift its duck.
function stingCut(S: Sfx): void {
    let e = S.sting;
    if (e == null) {
        return;
    }
    S.sting = null;
    S.stingFade = 1;
    S.stingStopped = false;
    S.ducks.delete("sting");
    if (!sDone(e.snd)) {
        stopSound(e.snd, 0.15);
    }
    let v = S.voices;
    for (let i = v.length - 1; i >= 1; i--) {
        if (v[i] == e) {
            v.splice(i, 1);
        }
    }
}

/// Play a one-shot and duck the music under it for 0.8 of its length. A sting
/// (sting, sting_*) becomes the live stinger (it replaces the one before, like its
/// card): scene() pauses, resumes and cuts it with the card. level / volume: NaN = default.
export function stinger(S: Sfx, name: string, level: f64 = NaN, volume: f64 = NaN): Snd? {
    let scored = category(name) == "sting";
    if (scored && source(S, name) != null) {
        stingCut(S);
    }
    let snd = play(S, name, volume);
    if (snd != null) {
        let lv = !isNaN(level) ? level : getF(STING_DUCK, name, 0.35);
        duck(S, lv, lmax(0.5, duration(name) * 0.8), "sting");
        let n = S.voices.length - 1;
        if (scored && n >= 1 && S.voices[n].snd == snd) {
            S.sting = S.voices[n];
        }
    }
    return snd;
}

// Loops ------------------------------------------------------------------------------

function loopVol(S: Sfx, L: Loop): f64 {
    return L.vol * L.base * getF(BASE, L.name, 1) * gainFor(S, L.cat);
}

function applyLoop(S: Sfx, L: Loop): void {
    let v = loopVol(S, L);
    let c = L.cur;
    if (c != null) {
        sVol(c, v);
    }
    let n = L.nxt;
    if (n != null) {
        sVol(n, v);
    }
}

// fade / at: NaN = nil
function startLoop(S: Sfx, name: string, volume: f64, fade: f64, at: f64): Loop? {
    if (S.loops.has(name)) {
        let existing = S.loops.get(name);
        existing.base = volume;
        existing.target = 1;
        if (fade > 0) {
            existing.rate = 1 / fade;
        } else {
            existing.vol = 1;
        }
        applyLoop(S, existing);
        return existing;
    }
    let src = source(S, name);
    if (src == null) {
        return null;
    }
    let now = engineTime(S);
    let t0 = snap(lmax(isNaN(at) ? 0 : at, now + 0.05));
    let snd = playAt(src, t0);
    if (snd == null) {
        return null;
    }
    let fading = !isNaN(fade) && fade > 0 && S.ticking;
    let L = new Loop(src);
    L.name = name;
    L.cur = snd;
    L.nxt = null;
    L.t0 = t0;
    L.dur = META.has(name) ? META.get(name).dur : 0;
    L.vol = fading ? 0 : 1;
    L.target = 1;
    L.rate = fading ? 1 / fade : 100;
    L.base = volume;
    L.cat = category(name);
    S.loops.set(name, L);
    applyLoop(S, L);
    return L;
}

/// Start (or keep) a gapless loop. volume scales the loop; fade is a fade-in time.
/// A music track started right after another was stopped lands on the old
/// track's next beat with a short fade-in (so stop(old) + loop(new) crossfades in time).
/// volume / fade: NaN = nil.
export function loop(S: Sfx, name: string, volume: f64 = NaN, fade: f64 = NaN): void {
    let at = NaN;
    let f = fade;
    if (category(name) == "music" && !S.loops.has(name)) {
        let prev = S.prevMusic;
        let m: Meta? = prev != null && META.has(prev) ? META.get(prev) : null;
        let now = engineTime(S);
        if (m != null && m.bpm > 0 && now - S.prevMusicAt < 0.25) {
            let beat = 60 / m.bpm;
            let k = Math.ceil((now + 0.06 - S.prevMusicT0) / beat);
            at = S.prevMusicT0 + k * beat;
            f = isNaN(f) ? 0.25 : f;
        }
        S.musicName = name;
    }
    startLoop(S, name, isNaN(volume) ? 1 : volume, f, at);
}

/// Stop a loop, fading out over `fade` seconds (native fade in engine frames, needs no update).
export function stop(S: Sfx, name: string, fade: f64 = NaN): void {
    if (!S.loops.has(name)) {
        return;
    }
    let L = S.loops.get(name);
    if (L.cat == "music") {
        S.prevMusic = name;
        S.prevMusicT0 = L.t0;
        S.prevMusicAt = engineTime(S);
        let mn = S.musicName;
        if (mn != null && mn == name) {
            S.musicName = null;
        }
    }
    let c = L.cur;
    if (c != null) {
        stopSound(c, fade);
    }
    let n = L.nxt;
    if (n != null) {
        stopSound(n, fade); // still scheduled: never starts, or starts mid-fade
    }
    S.loops.delete(name);
}

/// Set a running loop's volume (0..1 times its mix).
export function loopVolume(S: Sfx, name: string, volume: f64): void {
    if (!S.loops.has(name)) {
        return;
    }
    let L = S.loops.get(name);
    L.base = volume;
    applyLoop(S, L);
}

/// Crossfade the music to `name` (null = silence). The new track starts on the
/// old track's next beat; the old one fades over `fade` seconds (NaN = 1.2).
export function music(S: Sfx, name: string?, fade: f64 = NaN): void {
    let f = isNaN(fade) ? 1.2 : fade;
    S.pending = null;
    let mn = S.musicName;
    if (name != null && mn != null && name == mn) {
        startLoop(S, name, 1, f, NaN);
        return;
    }
    let old = S.musicName;
    let at = NaN;
    if (old != null) {
        let L: Loop? = S.loops.has(old) ? S.loops.get(old) : null;
        let m: Meta? = META.has(old) ? META.get(old) : null;
        if (L != null && m != null && m.bpm > 0) {
            let beat = 60 / m.bpm;
            let now = engineTime(S);
            let k = Math.ceil((now + 0.06 - L.t0) / beat);
            at = L.t0 + k * beat;
        }
        stop(S, old, f);
    }
    S.musicName = name;
    if (name != null) {
        startLoop(S, name, 1, lmin(f, 0.6), at);
    }
}

export let BEAT_1: f64 = 0;
export let BEAT_2: f64 = 0;

/// Musical clock of the current music: beats since it started (float) and the
/// phase within the bar 0..1 (BEAT_1, BEAT_2; returns BEAT_1). (0, 0) when no
/// music is playing. Drive visor/HUD pulses from it: `let b = sfx.beat(S);
/// let pulse = 1 - mod(b, 1)`.
export function beat(S: Sfx): f64 {
    BEAT_1 = 0;
    BEAT_2 = 0;
    let name = S.musicName;
    if (name == null) {
        return 0;
    }
    if (!S.loops.has(name) || !META.has(name)) {
        return 0;
    }
    let L = S.loops.get(name);
    let m = META.get(name);
    if (m.bpm <= 0) {
        return 0;
    }
    let t = engineTime(S) - L.t0 - m.lead; // MP3 decoders start `lead` seconds late
    if (t < 0) {
        return 0;
    }
    let beats = t * m.bpm / 60;
    let bar = beats / m.beats;
    BEAT_1 = beats;
    BEAT_2 = bar - Math.floor(bar);
    return beats;
}

/// Play a one-shot music cue (jingle), silence the loop, then return to `after` (optional).
export function jingle(S: Sfx, name: string, after: string? = null): void {
    music(S, null, 0.5);
    play(S, name);
    if (after != null) {
        let d = duration(name);
        S.pending = after;
        S.pendingAt = S.t + (d > 0 ? d : 4) + 0.5;
    }
}

// Game hooks ---------------------------------------------------------------------------

/// Map a game state to music and ambience. Call every frame (idempotent).
/// state: title | briefing | launch | playing | paused | results | gameover
/// biome: 'coast' | 'violet' (null = coast); boss: a boss fight is on (Luau nil = false).
export function scene(S: Sfx, state: string, biome: string? = null, boss: bool = false): void {
    let key = state + "|" + (biome != null ? biome : "") + "|" + (boss ? "b" : "");
    if (key == S.sceneKey) {
        return;
    }
    let bar = S.sceneKey.indexOf("|");
    let prevState = bar < 0 ? S.sceneKey : S.sceneKey.substring(0, bar);
    S.sceneKey = key;
    S.pauseTarget = state == "paused" ? 0.3 : 1;
    // the live sting follows its card (screens: a pause holds it and RESUME brings
    // it back; RESTART, title, briefing, game over and results cut it, but the
    // finale's rolls off over the report)
    let sting = S.sting;
    if (sting != null) {
        if (state == "paused") {
            stingHold(S, true);
        } else if (state == "playing") {
            stingHold(S, false);
        } else if (sting.held || !(state == "launch" || (state == "results" && sting.fam == "sting_mission_complete"))) {
            stingCut(S);
        }
    }
    // transition cues
    if (state != prevState && prevState != "") {
        if (state == "paused") {
            play(S, "pause");
        } else if (prevState == "paused") {
            play(S, "ui_back");
        } else if (state == "briefing") {
            play(S, "ui_select");
        } else if (state == "title" && (prevState == "results" || prevState == "gameover")) {
            play(S, "ui_back");
        } else if (state == "launch") {
            play(S, "comm");
        } else if (prevState == "launch" && state == "playing" && S.lastCount > 0) {
            play(S, "go"); // the 0 frame and the switch to playing coincide
        }
    }
    if (state != "launch") {
        S.lastCount = -1;
    }
    S.inFlight = state == "launch" || state == "playing" || state == "paused";
    if (!S.inFlight) {
        commClose(S, false);
    }
    if (state == "paused") {
        charge(S, false);
        return;
    }
    if (state == "title" || state == "briefing") {
        music(S, "music_title", 1.5);
        stop(S, "jet", 0.6);
        stop(S, "jet_boost", 0.3);
        stop(S, "wind", 1.0);
    } else if (state == "launch") {
        // hold the music for the countdown; the level loop's downbeat lands on GO
        music(S, null, 1.2);
    } else if (state == "playing") {
        let track = boss ? "music_boss" : biome != null && biome == "violet" ? "music_violet" : "music_level";
        music(S, track, prevState == "launch" ? 0 : boss ? 0.8 : 2.0);
    } else if (state == "results") {
        if (prevState != "results") {
            jingle(S, "jingle_clear", "music_title");
        }
        stop(S, "jet", 1.5);
        stop(S, "jet_boost", 0.5);
        stop(S, "wind", 2.0);
        charge(S, false);
    } else if (state == "gameover") {
        if (prevState != "gameover") {
            jingle(S, "jingle_over", "music_title");
        }
        stop(S, "jet", 0.4);
        stop(S, "jet_boost", 0.2);
        stop(S, "wind", 1.0);
        charge(S, false);
    }
}

/// Launch countdown: pass the displayed number (3, 2, 1, 0) every frame; ticks on
/// each change and fires the 'go' stab at 0.
export function countdown(S: Sfx, n: f64): void {
    if (n == S.lastCount) {
        return;
    }
    if (n > 0) {
        play(S, "countdown");
    } else if (S.lastCount > 0) {
        play(S, "go");
    } else {
        return; // stale 0 before the first tick
    }
    S.lastCount = n;
}

function commClose(S: Sfx, squelch: bool): void {
    if (!S.commOn) {
        return;
    }
    S.commOn = false;
    stop(S, "comm_static", 0.18);
    if (squelch && S.pauseTarget >= 1) {
        play(S, "comm_out");
    }
}

function commOpen(S: Sfx): void {
    if (S.commOn) {
        return;
    }
    S.commOn = true;
    // the bed starts under the tail of the chirp's static burst
    startLoop(S, "comm_static", 1, 0.12, engineTime(S) + 0.06);
}

/// Radio channel: pass true while a comms line is on screen (call every frame).
/// Opening plays under the 'comm' chirp as a static bed and dips the music;
/// closing plays the 'comm_out' squelch (never while paused, never outside
/// flight). Without this call, play('comm') opens the channel for COMM_HOLD
/// seconds of unpaused time (auto mode).
export function comm(S: Sfx, active: bool): void {
    S.commExplicit = true;
    if (active && S.inFlight) {
        commOpen(S);
    } else {
        commClose(S, true);
    }
}

/// Jetpack and wind ambience. Call each frame while flying.
/// thrust 0..1, boosting, speed01 0..1 (0 = brake, 1 = boost speed), altitude in meters.
export function flight(S: Sfx, thrust: f64, boosting: bool, speed01: f64, altitude: f64): void {
    if (!S.loops.has("jet")) {
        startLoop(S, "jet", 0, 0.8, NaN);
    }
    if (!S.loops.has("wind")) {
        startLoop(S, "wind", 0, 1.5, NaN);
    }
    if (S.loops.has("jet")) {
        S.loops.get("jet").base = 0.45 + 0.55 * lclamp(thrust, 0, 1);
    }
    if (boosting) {
        startLoop(S, "jet_boost", 1, 0.15, NaN);
    } else if (S.loops.has("jet_boost")) {
        stop(S, "jet_boost", 0.35);
    }
    if (S.loops.has("wind")) {
        let high = lclamp((altitude - 8) / 20, 0, 1);
        S.loops.get("wind").base = 0.3 + 0.5 * lclamp(speed01, 0, 1) + 0.25 * high;
    }
}

function startCharge(S: Sfx, volume: f64): void {
    S.chargeT = S.t;
    S.chargeVol = volume;
    let src = source(S, "charge");
    if (src == null) {
        return;
    }
    let t0 = snap(engineTime(S) + 0.02);
    let snd = playAt(src, t0);
    if (snd != null) {
        sVol(snd, volume * getF(BASE, "charge", 1) * gainFor(S, "sfx"));
        S.chargeSnd = snd;
    }
    let d = duration("charge");
    if (d > 0) {
        startLoop(S, "charge_hold", volume, NaN, t0 + d);
    }
}

function stopCharge(S: Sfx): void {
    let c = S.chargeSnd;
    if (c != null) {
        stopSound(c, 0.06);
        S.chargeSnd = null;
    }
    stop(S, "charge_hold", 0.08);
}

/// Charge whine while `holding` (call every frame); hands off gaplessly to the
/// charge_hold loop. Without this call, play('charge') runs the same thing in auto mode.
export function charge(S: Sfx, holding: bool): void {
    S.chargeExplicit = true;
    if (holding == S.charging) {
        return;
    }
    S.charging = holding;
    if (holding) {
        startCharge(S, 1);
    } else {
        stopCharge(S);
    }
}

/// Master / category volumes. cat: 'sfx' | 'ui' | 'music' | 'amb' | null (master).
/// The stings follow 'music' (off at 0, full at its default) at the 'sfx' level.
export function setVolume(S: Sfx, cat: string?, volume: f64): void {
    if (cat == null) {
        S.master = volume;
    } else {
        S.cat.set(cat, volume);
    }
    let ls = S.loops.values();
    for (let i = 0; i < ls.length; i++) {
        applyLoop(S, ls[i]);
    }
    // one-shots already playing follow too (N silences a big explosion, M the jingle or a sting)
    let vs = S.voices;
    for (let i = 1; i < vs.length; i++) {
        let e = vs[i];
        // completed() is safe on a sound the engine already disposed; volume is not
        if (!sDone(e.snd)) {
            e.vol = voiceVol(S, e.raw, e.cat, e.half);
            sVol(e.snd, e.bus ? e.vol * busOf(S, e) : e.vol);
        }
    }
    S.busApplied = S.busGain;
    S.leadApplied = S.leadGain;
    let c = S.chargeSnd;
    if (c != null && !sDone(c)) {
        sVol(c, S.chargeVol * getF(BASE, "charge", 1) * gainFor(S, "sfx"));
    }
}

// Frame ---------------------------------------------------------------------------------

function approach(v: f64, target: f64, rate: f64, dt: f64): f64 {
    if (v < target) {
        return lmin(target, v + rate * dt);
    }
    return lmax(target, v - rate * dt);
}

export function update(S: Sfx, dt: f64): void {
    S.ticking = true;
    S.t += dt;
    // ducking: the lowest live duck, fast down, slow up. The pause menu has its own
    // level (pauseGain); the ducks run out under it like their sounds, but a held
    // sting's waits for the resume with it
    let paused = S.pauseTarget < 1;
    let sting = S.sting;
    let stingHeld = sting != null && sting.held;
    let target = 1.0;
    let keys = S.ducks.keys();
    for (let i = 0; i < keys.length; i++) {
        let k = keys[i];
        let d = S.ducks.get(k);
        if (!(stingHeld && k == "sting")) {
            d.hold -= dt;
        }
        if (d.hold <= 0) {
            S.ducks.delete(k);
        } else if (d.level < target) {
            target = d.level;
        }
    }
    S.duckTarget = paused ? 1 : target;
    S.duck = approach(S.duck, S.duckTarget, S.duck > S.duckTarget ? 8 : 0.9, dt);
    S.pauseGain = approach(S.pauseGain, S.pauseTarget, 3, dt);
    // auto-mode charge safety: nobody told us the button was released
    if (S.charging && !S.chargeExplicit && S.t - S.chargeT > 4) {
        S.charging = false;
        stopCharge(S);
    }
    // comm channel: auto-mode close, music dip while open
    if (S.commOn) {
        if (!S.commExplicit && S.pauseTarget < 1) {
            S.commEnd += dt; // the comms window is frozen while paused
        }
        if (!S.commExplicit && S.t >= S.commEnd) {
            commClose(S, true);
        } else {
            duck(S, 0.82, 0.15, "comm");
        }
    }
    // deferred music (after a jingle)
    let p = S.pending;
    if (p != null && S.t >= S.pendingAt) {
        S.pending = null;
        music(S, p, 2.5);
    }
    let now = engineTime(S);
    // (Luau pairs order over S.loops: the engine calls of two loops on one frame may swap)
    let ls = S.loops.values();
    for (let i = 0; i < ls.length; i++) {
        let L = ls[i];
        if (L.dur > 0) {
            let boundary = L.t0 + L.dur;
            if (L.nxt != null && now >= boundary) {
                L.cur = L.nxt;
                L.nxt = null;
                L.t0 = boundary;
                boundary += L.dur;
            }
            if (L.nxt == null && now > boundary + 0.05) {
                // fell behind (hitch or suspended engine): restart cleanly
                let c = L.cur;
                if (c != null) {
                    stopSound(c, 0.02);
                }
                L.t0 = snap(now + 0.03);
                L.cur = playAt(L.src, L.t0);
                boundary = L.t0 + L.dur;
            }
            if (L.nxt == null && now >= boundary - lmin(0.5, L.dur * 0.5)) {
                L.nxt = playAt(L.src, boundary);
            }
        } else {
            let c = L.cur;
            if (c != null && sDone(c)) {
                L.cur = aPlay(L.src);
            }
        }
        L.vol = approach(L.vol, L.target, L.rate, dt);
        applyLoop(S, L);
    }
    // sfx bus compressor and limiter
    if (S.voices.length - 1 > 0) {
        let cnow = clock(S);
        prune(S, cnow);
        busUpdate(S, cnow, dt);
        if (Math.abs(S.busGain - S.busApplied) > 0.002 || Math.abs(S.leadGain - S.leadApplied) > 0.002) {
            applyBus(S);
        }
    } else {
        S.busGain = 1;
        S.leadGain = 1;
        S.busApplied = 1;
        S.leadApplied = 1;
    }
    stingRamp(S, dt);
}
