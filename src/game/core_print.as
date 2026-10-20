// Port of src/game/core_print.luau. JOB 26: the print plates' values for the
// renderer. The screens' plate nodes (PrintScreen Blue / Red, StingCard(P)
// Blue / Dense / Crimson) no longer draw: their keyed opacities, their keyed
// parents' (PrintScreen Root, the cards' Print) and the rollers' x are
// written back into the Game view model every frame (PrintScreen /
// StingCard, DataBindContext direction true), so every fade,
// flicker, mix and roll stays Rive's own. Read in draw, right before frame:
// there they are the values Rive draws this frame (in advance they are a
// frame old).
//
// Port: the view model reads (vm.optNum) come in as PrintVals, one field per
// Game view model number (same names); NaN = missing (the `or` defaults).
import * as R from "../render/renderer";
import { Gfx } from "../render/renderer";
import { opt } from "../lib/compat";

export class PrintVals {
    printRootK: f64 = NaN;
    printRedK: f64 = NaN;
    printBlueK: f64 = NaN;
    printRollX: f64 = NaN;
    viewW: f64 = NaN;
    viewH: f64 = NaN;
    stingPrintK: f64 = NaN;
    stingCrimK: f64 = NaN;
    stingDenseK: f64 = NaN;
    stingBlueK: f64 = NaN;
    stingRollX: f64 = NaN;
    stingPrintKP: f64 = NaN;
    stingCrimKP: f64 = NaN;
    stingDenseKP: f64 = NaN;
    stingBlueKP: f64 = NaN;
    stingRollXP: f64 = NaN;
}

export function feed(r: Gfx, g: PrintVals? = null): void {
    if (g == null) return;
    let root = opt(g.printRootK, 0);
    let red = opt(g.printRedK, 0) * root;
    let blue = opt(g.printBlueK, 0) * root;
    let rollX = opt(g.printRollX, -1100);
    // both cards run; Main shows the portrait one when the view is narrower than tall (s_main.orient_layer)
    let portrait = opt(g.viewW, 0) < opt(g.viewH, 0);
    let pk = opt(portrait ? g.stingPrintKP : g.stingPrintK, 0);
    let crim = opt(portrait ? g.stingCrimKP : g.stingCrimK, 0) * pk;
    let dense = opt(portrait ? g.stingDenseKP : g.stingDenseK, 0) * pk;
    let sblue = opt(portrait ? g.stingBlueKP : g.stingBlueK, 0) * pk;
    let sroll = opt(portrait ? g.stingRollXP : g.stingRollX, portrait ? -780 : -760);
    R.setPlates(r, red, blue, rollX, crim, dense, sblue, sroll, portrait);
}
