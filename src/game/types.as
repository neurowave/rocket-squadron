// Port of src/game/types.luau. Shared gameplay types: the context the core
// loop hands to the enemies, events and effects modules each frame.
// Additive changes only (DESIGN.md).
//
// Port: Ctx is an abstract class the core (game.as) implements; Luau's
// closure fields are its methods. Multi-returns land in Ctx fields, read at
// once after the call: railFrame -> rfPos / rfFwd / rfRight / rfUp, project
// -> pjU / pjV / pjD, commState -> csLeft / csAge / csPrio / csWait.
// Optional Luau args: number? -> NaN, string? -> null (addScore returns NaN
// for Luau nil). The optional practice hooks: practiceOn says they exist.
import { Vector } from "rive/vector";

export class Player {
    s: f64 = 0; // distance along the rail
    x: f64 = 0; // lateral offset from the rail (m)
    y: f64 = 0; // height above rail base (m)
    vx: f64 = 0;
    vy: f64 = 0;
    speed: f64 = 0; // m/s along the rail
    bank: f64 = 0;
    pitch: f64 = 0;
    roll: f64 = 0;
    pos: Vector = Vector.xyz(0, 0, 0); // world position
    fwd: Vector = Vector.xyz(0, 0, -1); // rail forward at s
    right: Vector = Vector.xyz(1, 0, 0);
    up: Vector = Vector.xyz(0, 1, 0);
    shield: f64 = 1; // 0..1
    invuln: f64 = 0; // seconds of invulnerability left (barrel roll, respawn)
    rolling: bool = false; // barrel roll in progress (deflects bullets)
    // additive (core)
    boosting: bool = false;
    braking: bool = false;
    alive: bool = true; // false while crashing / after the shield is gone
    aim: Vector = Vector.xyz(0, 0, -1); // unit direction the guns point (toward the far reticle)
}

export class Stats {
    kills: f64 = 0;
    killsTotal: f64 = 0;
    shotsFired: f64 = 0;
    shotsHit: f64 = 0;
}

// Services the core loop provides. See types.luau for each one's contract.
export abstract class Ctx {
    t: f64 = 0; // game time (s)
    dt: f64 = 0;
    player: Player = new Player();
    railS: f64 = 0; // same as player.s
    stats: Stats = new Stats();
    // 'title' | 'briefing' | 'launch' | 'training' | 'playing' | 'paused' |
    // 'dying' | 'outro' | 'results' | 'gameover'
    state: string = "title";
    // wingmen world positions (empty while they are away), 1-based (slot 0 dummy)
    wingmen: Array<Vector> = [Vector.xyz(0, 0, 0)];
    // flight school hooks exist (Luau: ctx.onPractice / ctx.practiceHit non-nil)
    practiceOn: bool = false;

    // multi-returns
    rfPos: Vector = Vector.xyz(0, 0, 0);
    rfFwd: Vector = Vector.xyz(0, 0, -1);
    rfRight: Vector = Vector.xyz(1, 0, 0);
    rfUp: Vector = Vector.xyz(0, 1, 0);
    pjU: f64 = 0;
    pjV: f64 = 0;
    pjD: f64 = 0;
    csLeft: f64 = 0;
    csAge: f64 = 0;
    csPrio: f64 = 0;
    csWait: f64 = 0;

    // points credited, NaN when no run is scoring (Luau nil)
    abstract addScore(points: f64, x: f64, y: f64, z: f64, label: string?): f64;
    abstract hurtPlayer(amount: f64, x: f64, y: f64, z: f64): void;
    // mood: null = inferred; prio: NaN = 2
    abstract comm(who: string, speaker: string, text: string, seconds: f64, mood: string?, prio: f64): void;
    abstract banner(text: string, sub: string, kind: string): void;
    abstract warning(text: string, seconds: f64): void;
    abstract boss(active: bool, name: string, health: f64): void;
    abstract shake(amount: f64): void;
    // volume: NaN = default
    abstract sfx(name: string, volume: f64): void;
    // sets rfPos / rfFwd / rfRight / rfUp, returns rfPos
    abstract railFrame(s: f64): Vector;
    abstract toWorld(s: f64, x: f64, y: f64): Vector;
    abstract focus(x: f64, y: f64, z: f64, weight: f64): void;
    abstract popup(text: string, kind: string, x: f64, y: f64, z: f64): void;
    abstract deflect(x: f64, y: f64, z: f64): void;
    // v: NaN releases the cap (Luau nil)
    abstract holdSpeed(v: f64): void;
    abstract alertFree(): bool;
    abstract sting(kind: string, title: string, sub: string): void;
    abstract stingActive(): bool;
    // sets pjU / pjV / pjD, returns pjU
    abstract project(x: f64, y: f64, z: f64): f64;
    // sets csLeft / csAge / csPrio / csWait, returns csLeft
    abstract commState(): f64;
    // flight school (only when practiceOn)
    onPractice(kind: string, x: f64, y: f64, z: f64): void {}
    practiceHit(amount: f64, x: f64, y: f64, z: f64): void {}
}
