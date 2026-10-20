// Port of src/game/core_autopilot.luau. AUTOPILOT (Game.autopilot): flies the mission with no input so headless
// captures and QA can play the level. Threads upcoming rings, weaves around colliders, skims where the route asks
// for it, taps at targets under the reticle and charges lock-on volleys when several targets line up.
//
// Port: `new` -> create. rings: core_rings Ring list (Luau RingRef: s, x, y, taken), 1-based; chunks 1-based.
import * as mathx from "../lib/mathx";
import * as level from "../world/level";
import * as scenery from "../world/scenery";
import { Chunk } from "../world/scenery";
import * as coll from "../world/collide";
import { Collider } from "../world/collide";
import { Enemy, World } from "./ai_types";
import * as playerMod from "./player";
import { Player, Controls } from "./player";
import { Ring } from "./core_rings";
import { HUGE, lmin, lmax, lclamp, mod, lrandom } from "../lib/compat";

const SHELL_CLEAR: f64 = 3; // m kept from a rock shell's drawn outline
const SIDESTEP: f64 = 20; // m/s he counts on sideways
const HUSH_MAX: f64 = 8; // s a fight's killing blow may wait on the comms
// Rings: a ring sits in a clear gap (world.md: 5.2 m+ from ring centre to rock), so flying for one he leaves its
// line only for a rock the line really meets (the rock's own shape, not its outline's projection).
const PILOT_R: f64 = playerMod.RADIUS;
const LINE_R: f64 = playerMod.RADIUS + playerMod.GRAZE; // m kept from rock along the line to the ring (no close call)
const BLOCK_HYST: f64 = 1; // m more the line must clear a rock he is dodging by, before he lets go
const DODGE_CLEAR: f64 = 4.5; // m from a rock's drawn outline he dodges to, flying for a ring
const SLIDE_T: f64 = 0.35; // s of his current slide (sideways speed) checked against rock beside or ahead of him
const SLIDE_R: f64 = LINE_R + 0.5; // m: a slide that would bring him this close to rock bars his target from that side
const SLIDE_HOLD: f64 = 0.3; // s the bar holds once set (no flicker back to the ring)
const LEAD_Y: f64 = 2; // m he aims past a ring's height toward the next one, close to it (climbs, dives)
const LEAD_D: f64 = 60; // m before the ring the lead starts
const BOX_RING: f64 = 0.3; // m inside the box edge a ring past it is aimed at (it is caught from the edge)

export class Pilot {
    mode: string = "tap"; // 'tap' | 'charge' | 'release'
    modeT: f64 = 0;
    frame: f64 = 0;
    lastShield: f64 = 1;
    boostT: f64 = 0;
    tx: f64 = 0;
    ty: f64 = 6;
    bossPick: Enemy? = null; // the weak point it is working on (sticky)
    orbRolled: bool = false; // flight school: rolled for the orb closing now
    hushT: f64 = 0; // s the killing blow has waited on the comms this fight
    block: Collider? = null; // the collider it dodged last frame (released only once clear by BLOCK_HYST)
    ringWon: f64 = -1; // s of the ring that already beat the boss to his attention (no flip back)
    slideT: f64 = 0; // s left on the slide bar
    barLo: f64 = -HUGE; // the slide bar: his target is kept within barLo..barHi (rail x)
    barHi: f64 = HUGE;
}

export function create(): Pilot {
    return new Pilot();
}

function sectionKind(idx: i32): string {
    let secs = level.sections;
    if (idx < 1 || idx >= secs.length) return "";
    return secs[idx].label;
}

// A boss piece the guns can hurt right now.
function exposed(e: Enemy): bool {
    return e.part && e.alive && !e.hidden && e.dying <= 0 && e.lockable && !e.armored
        && (e.minHp <= 0 || e.hp > e.minHp + 1e-3);
}

// The boss's last weak point: its kill downs her (her armor plates are not in the list; parts still hidden are
// alive).
function lastPart(E: World, e: Enemy): bool {
    let l = E.list;
    for (let i = 1; i < l.length; i++) {
        let o = l[i];
        if (o != e && o.part && o.alive && o.dying <= 0) return false;
    }
    return true;
}

// A box collider's half-extent along the horizontal unit direction (dx, dz).
function boxExt(col: Collider, dx: f64, dz: f64): f64 {
    return Math.abs(col.ux * dx + col.uz * dz) * col.hx + Math.abs(col.vx * dx + col.vz * dz) * col.hy
        + Math.abs(col.wx * dx + col.wz * dz) * col.hz;
}

// A ball of radius r swept from rail point (s0, x0, y0) to (s1, x1, y1): does it touch the collider (sampled every
// `step` m, ~4: the balls overlap)?
function sweep(col: Collider, s0: f64, x0: f64, y0: f64, s1: f64, x1: f64, y1: f64, r: f64, step: f64 = 4): bool {
    let n = lclamp(Math.ceil((s1 - s0) / step), 1, 30);
    for (let i = 0.0; i <= n; i++) {
        let u = i / n;
        let w = level.world(s0 + (s1 - s0) * u, x0 + (x1 - x0) * u, y0 + (y1 - y0) * u);
        coll.test(col, <f64>w.x, <f64>w.y, <f64>w.z, r);
        if (coll.T_D > 0) return true;
    }
    return false;
}

// hush: a line is typing on the comms. The killing blow (no pacing floor left) waits for it (the DOWNED card
// closes the channel: 'Armor's off! That glowi'), HUSH_MAX a fight at most.
export function drive(ap: Pilot, p: Player, c: Controls, rings: Array<Ring>, E: World?, chunks: Array<Chunk>, hot: bool, locks: f64, t: f64, dt: f64, hush: bool): void {
    ap.frame += 1;
    ap.modeT += dt;
    playerMod.clearControls(c);

    // 1. where to be: next ring, else an enemy to line up, else cruise
    let label = sectionKind(level.sectionAt(p.s));
    let low = label == "LOW PASS" || label == "THE FALLS";
    let tx = Math.sin(t * 0.35) * 6;
    let ty = low && p.overWater ? 2.2 : 6 + Math.sin(t * 0.27) * 2;
    let ringS = HUGE;
    let ring: Ring? = null;
    for (let i = 1; i < rings.length; i++) {
        let r = rings[i];
        if (!r.taken && r.s > p.s + 4 && r.s < p.s + 480 && r.s < ringS) {
            ringS = r.s;
            ring = r;
        }
    }
    if (ring != null) {
        tx = ring.x;
        ty = ring.y;
        if (low && ring.y < 5) {
            // skim sections: thread low rings from under the skim ceiling
            ty = 2.2;
        } else {
            // close to it, aim a little past its height toward the next one (a climbing or diving chain is
            // threaded, not chased)
            let nextS = HUGE, ny = ring.y;
            for (let i = 1; i < rings.length; i++) {
                let r = rings[i];
                if (!r.taken && r.s > ringS && r.s < nextS) {
                    nextS = r.s;
                    ny = r.y;
                }
            }
            if (nextS < ringS + 150) {
                let w = mathx.saturate(1 - (ringS - p.s) / LEAD_D);
                ty += mathx.clamp(ny - ring.y, -LEAD_Y, LEAD_Y) * w;
            }
        }
    }
    let ringX = tx, ringY = ty;
    if (E == null || E.boss == null) ap.ringWon = -1;
    let enemiesAhead = 0.0;
    let pick: Enemy? = null;
    let ppx = <f64>p.pos.x, ppy = <f64>p.pos.y, ppz = <f64>p.pos.z;
    let pfx = <f64>p.fwd.x, pfy = <f64>p.fwd.y, pfz = <f64>p.fwd.z;
    let prx = <f64>p.right.x, prz = <f64>p.right.z;
    if (E != null) {
        let bestD = HUGE;
        // a boss on the field outranks the rings while one of its weak points is exposed (lockable, unarmored,
        // above its pacing floor); only a ring about to be threaded still wins
        let bossUp = false;
        // (it wins earlier the further off its line he is: he needs the time to get there, ~SIDESTEP m/s
        // sideways, climbs and dives slower)
        // (once a ring has won it keeps him until it is taken or passed; a field with no boss clears it, so a
        // replayed reel starts fresh)
        let need = lmax(Math.abs(ringX - p.x), Math.abs(ringY - p.y) * 1.5) / SIDESTEP;
        let ringWins = ringS <= p.s + 30 + lmax(p.speed, 10) * need || ringS == ap.ringWon;
        if (E.boss != null && ringWins && ringS < HUGE) ap.ringWon = ringS;
        let l = E.list;
        if (E.boss != null && !ringWins) {
            for (let i = 1; i < l.length; i++) {
                let e = l[i];
                if (exposed(e)) {
                    let dx = e.x - ppx, dy = e.y - ppy, dz = e.z - ppz;
                    let along = dx * pfx + dy * pfy + dz * pfz;
                    if (along > 20 && along < 380) {
                        bossUp = true;
                        break;
                    }
                }
            }
        }
        for (let i = 1; i < l.length; i++) {
            let e = l[i];
            if (e.alive && !e.hidden && e.dying <= 0) {
                let dx = e.x - ppx, dy = e.y - ppy, dz = e.z - ppz;
                let along = dx * pfx + dy * pfy + dz * pfz;
                if (along > 20 && along < 380) {
                    let lat = dx * prx + dz * prz;
                    if (Math.abs(lat) < 70) enemiesAhead += 1;
                    let wanted = bossUp ? exposed(e) : ringS == HUGE;
                    // weak points: the cheapest to line up, sticking with the current one (no flip-flopping
                    // between pods)
                    let cost = along;
                    if (bossUp) {
                        cost += (Math.abs(lat) + Math.abs(e.y - <f64>p.railPos.y - p.y)) * 2.5;
                        if (e == ap.bossPick) cost *= 0.6;
                    }
                    if (wanted && cost < bestD && Math.abs(lat) < 40) {
                        bestD = cost;
                        if (bossUp) pick = e;
                        // line up (the guns converge ahead, so aim a bit short); height: the aim line (rail
                        // slope + weapons.aimDir's 0.03 lift) meets it (its world height over the rail put a
                        // climbing rail's aim ~17 m high, on the gasbag)
                        tx = mathx.clamp(p.x + lat * 0.8, -20, 20);
                        ty = mathx.clamp(p.y + e.y - (ppy + (pfy + 0.03) * along), 1.8, 26);
                    }
                }
            }
        }
    }

    ap.bossPick = pick;
    // the boss's last weak point is up (no pacing floor left)
    let killUp = false;
    if (E != null && E.boss != null) {
        let l = E.list;
        for (let i = 1; i < l.length; i++) {
            let e = l[i];
            if (exposed(e) && e.minHp <= 0 && lastPart(E, e)) {
                killUp = true;
                break;
            }
        }
    } else {
        ap.hushT = 0;
    }
    let holdKill = killUp && hush && ap.hushT < HUSH_MAX;
    if (holdKill) ap.hushT += dt;

    // 2. weave around colliders coming up: the nearest blocker wins, the dodge commits to the side he is already
    // on.
    // Flying for a ring, a rock is in the way only if the line from him to the ring passes within LINE_R of it
    // (its real shape, swept) or it stands straight on past the ring within 44 m (0.8 s at cruise); he then
    // dodges to DODGE_CLEAR from its outline. A rock level with the ring beside its gap is no reason to leave the
    // line. If SLIDE_T s of his current sideways speed would bring him within SLIDE_R of a rock beside him (up to
    // 40 m behind, the chunk behind included) or ahead, his target may not cross SLIDE_R off that rock's outline
    // for SLIDE_HOLD s (a bar, not a stop: a target short of it is kept). Other targets (an enemy, cruising) are
    // checked as before: the target, the path there and where the drift carries him.
    let rtx = <f64>p.right.x, rtz = <f64>p.right.z, fx = pfx, fz = pfz;
    let ci = Math.floor(p.s / scenery.CHUNK) + 1;
    let bx0 = playerMod.boxX(p.s);
    let bx1 = playerMod.BOX_X_2;
    let urgent = 0.0;
    let nearest = HUGE;
    let dodge = tx;
    let toRing = ringS < HUGE && tx == ringX;
    let ringAl = ringS - p.s;
    let spd = lmax(p.speed, 10);
    let rpx = <f64>p.railPos.x, rpz = <f64>p.railPos.z;
    let fy = <f64>p.railPos.y;
    let ya = fy + lmin(p.y, ty) - 2, yb = fy + lmax(p.y, ty) + 2;
    let block: Collider? = null;
    let slideHit = false;
    let barLo = -HUGE, barHi = HUGE;
    // a rock (stack, fang, pillar) in the box at his heights within 120 m: no boosting into it
    let rockNear = false;
    for (let k = toRing ? ci - 1 : ci; k <= ci + 1; k++) {
        if (k < 1 || k >= <f64>chunks.length) continue;
        let ch = chunks[<i32>k];
        let cols = ch.colliders;
        for (let ic = 1; ic < cols.length; ic++) {
            let col = cols[ic];
            if (col.kind == 3 && !rockNear) {
                let bxr = col.bx - rpx, bzr = col.bz - rpz, br = col.br;
                let bal = bxr * fx + bzr * fz, blat = bxr * rtx + bzr * rtz;
                if (bal > -br && bal < 120 + br && blat - br < bx1 - 2 && blat + br > bx0 + 2 && col.b1 > ya && col.b0 < yb) {
                    rockNear = true;
                }
            }
            let rx = col.x - rpx, rz = col.z - rpz;
            let along = rx * fx + rz * fz;
            // (flying for a ring, a rock still beside him counts: his slide)
            if (along > (toRing ? -40 : -2) && along < 170 && along < nearest) {
                let lat = rx * rtx + rz * rtz;
                let clear = col.r + 4.5;
                let half = col.r; // the outline's half-width across the rail
                let a0 = along - col.r, a1 = along + col.r;
                if (col.kind == 3) {
                    // rock shells: the drawn outline over the heights he flies
                    coll.span(col, rpx, rpz, rtx, rtz, ya, yb);
                    let l0 = coll.SPAN_LO, l1 = coll.SPAN_HI;
                    if (l0 <= l1) {
                        lat = (l0 + l1) * 0.5;
                        half = (l1 - l0) * 0.5;
                        clear = half + SHELL_CLEAR;
                        // its length along the rail: the bounding circle (the swept test below has the real shape)
                        let bal = (col.bx - rpx) * fx + (col.bz - rpz) * fz;
                        a0 = bal - col.br;
                        a1 = bal + col.br;
                    } else {
                        clear = -1;
                        half = -1;
                    }
                } else if (col.kind == 1) {
                    // boxes (arch, bridges, gate walls): their real extents (col.r is the inscribed radius), when
                    // they reach the heights he flies (a span overhead is no wall)
                    if (col.y1 > ya && col.y0 < yb) {
                        half = boxExt(col, rtx, rtz);
                        let al = boxExt(col, fx, fz);
                        a0 = along - al;
                        a1 = along + al;
                    } else {
                        half = -1;
                    }
                }
                let left = lat - clear, right = lat + clear;
                let tAl = lmin(along / spd, 1.2);
                let pred = p.x + p.vx * tAl;
                let inWay = false;
                if (toRing) {
                    if (half >= 0 && a1 > -2) {
                        left = lat - half - DODGE_CLEAR;
                        right = lat + half + DODGE_CLEAR;
                        // the line to the ring over the rock's length (a rock already beside him only counts for
                        // his slide, below)
                        let r = LINE_R + (col == ap.block ? BLOCK_HYST : 0);
                        let sa = lmax(a0, 0), sb = lmin(a1, ringAl);
                        if (sb > sa && along > -2) {
                            let k0 = sa / lmax(ringAl, 1), k1 = sb / lmax(ringAl, 1);
                            let xa = p.x + (tx - p.x) * k0, xb = p.x + (tx - p.x) * k1;
                            if (lmax(xa, xb) > lat - half - r && lmin(xa, xb) < lat + half + r) {
                                inWay = sweep(col, p.s + sa, xa, p.y + (ty - p.y) * k0, p.s + sb, xb, p.y + (ty - p.y) * k1, r);
                            }
                        }
                        // straight on past the ring, 0.8 s at cruise (boosting, the next ring's line takes over
                        // long before)
                        let sc = lmax(a0, ringAl), sd = lmin(a1, ringAl + 44);
                        if (!inWay && along > -2 && sd > sc && Math.abs(tx - lat) < half + PILOT_R + 1) {
                            inWay = sweep(col, p.s + sc, tx, ty, p.s + sd, tx, ty, PILOT_R + 1);
                        }
                        // his slide toward it, SLIDE_T s of it (the sideways speed he has: checking the sidestep
                        // he is about to start as well held the QA bots off ring 810 beside the 760 stack)
                        if (!inWay && a0 < spd * SLIDE_T && (lat - p.x) * p.vx > 0) {
                            let sx = p.x + p.vx * SLIDE_T;
                            if (lmax(p.x, sx) > lat - half - SLIDE_R && lmin(p.x, sx) < lat + half + SLIDE_R
                                && sweep(col, p.s, p.x, p.y, p.s + spd * SLIDE_T, sx, p.y, SLIDE_R, 2)) {
                                slideHit = true;
                                if (lat < p.x) {
                                    barLo = lmax(barLo, lat + half + SLIDE_R);
                                } else {
                                    barHi = lmin(barHi, lat - half - SLIDE_R);
                                }
                            }
                        }
                    }
                } else {
                    let yIn = ty + fy > col.y0 && ty + fy < col.y1 + 2;
                    let lo = lmin(p.x, tx), hi = lmax(p.x, tx);
                    let onPath = along < 110 && lat + clear > lo && lat - clear < hi;
                    inWay = yIn && (Math.abs(lat - tx) < clear || Math.abs(lat - pred) < clear || onPath);
                }
                if (inWay) {
                    // the side the target is on if he can make it, else his own
                    let pickLeft = pred < lat;
                    let want = tx < lat ? left : right;
                    if (Math.abs(want - p.x) < lmax(along - clear, 0) / lmax(p.speed, 10) * SIDESTEP) {
                        pickLeft = tx < lat;
                    }
                    if (left < bx0 + 1) {
                        pickLeft = false;
                    } else if (right > bx1 - 1) {
                        pickLeft = true;
                    }
                    dodge = pickLeft ? left : right;
                    nearest = along;
                    urgent = 1 - along / 170;
                    block = col;
                }
            }
        }
    }
    if (slideHit) {
        ap.slideT = SLIDE_HOLD;
        ap.barLo = barLo;
        ap.barHi = barHi;
    }
    ap.slideT = lmax(ap.slideT - dt, 0);
    if (toRing && ap.slideT > 0 && block == null && ap.barLo <= ap.barHi) {
        dodge = mathx.clamp(dodge, ap.barLo, ap.barHi);
    }
    ap.block = block;
    // (a ring past the box edge is caught from the edge)
    let edge = toRing && block == null ? BOX_RING : 1.5;
    tx = mathx.clamp(dodge, bx0 + edge, bx1 - edge);
    ty = mathx.clamp(ty, 1.6, playerMod.BOX_Y1 - 2);
    ap.tx = tx;
    ap.ty = ty;

    // 3. steer: PD toward the target
    c.sx = mathx.clamp((tx - p.x) * (0.22 + urgent * 0.3) - p.vx * 0.055, -1, 1);
    c.sy = mathx.clamp((ty - p.y) * 0.3 - p.vy * 0.06, -1, 1);

    // 4. guns (the kill by taps: a nova charge held through a hush covered him with its rings; holding the killing
    // blow: no taps, a charge is held)
    if (ap.mode == "tap") {
        if (hot && p.heat < 80 && !holdKill) c.fire = mod(ap.frame, 8) < 3;
        if (enemiesAhead >= 2 && p.heat < 60 && ap.modeT > 2 && !killUp) {
            ap.mode = "charge";
            ap.modeT = 0;
        }
    } else if (ap.mode == "charge") {
        c.fire = true;
        if (!holdKill && ((ap.modeT > 1.0 && locks >= lmin(enemiesAhead, 4)) || ap.modeT > 2.2)) {
            ap.mode = "release";
            ap.modeT = 0;
        }
    } else {
        c.fire = false;
        if (ap.modeT > 0.15) {
            ap.mode = "tap";
            ap.modeT = 0;
        }
    }

    // 5. boost on open stretches, roll when hit
    ap.boostT -= dt;
    if (enemiesAhead == 0 && p.boost > 80 && ap.boostT <= 0 && !low && !rockNear) ap.boostT = 5;
    c.boost = ap.boostT > 3.6 && !rockNear;
    if (p.shield < ap.lastShield - 0.01) {
        if (lrandom() < 0.5) {
            c.rollL = true;
        } else {
            c.rollR = true;
        }
    }
    ap.lastShield = p.shield;
}

// Flight school coach bot (debugTraining + autopilot), after drive: in the deflect drill it holds fire (the lobber
// must live to lob) and rolls once per orb as it closes (Game.trainTiming >= 0.8).
export function school(ap: Pilot, c: Controls, lesson: string, timing: f64): void {
    if (lesson != "deflect") {
        ap.orbRolled = false;
        return;
    }
    c.fire = false;
    if (timing >= 0.8 && !ap.orbRolled) {
        ap.orbRolled = true;
        c.rollR = true;
    } else if (timing < 0.5) {
        ap.orbRolled = false;
    }
}
