// Port of scene/sprites.rml ScriptAsset PilotColorFallback (inline Luau). Pilot
// color fallback. A view model instance made with ViewModel.create("Pilot")
// starts with black colors; show the hero palette until the host sets real ones.
import { Converter } from "rive/host";
import { Color } from "rive/color";
import { DataValue, DataValueColor } from "rive/data_value";

export class PilotColorFallback extends Converter {
    @input fallback: Color = 0xffffffff;
    out: DataValueColor = new DataValueColor();

    override convert(input: DataValue): DataValue? {
        if (!(input instanceof DataValueColor)) return null;
        let c = <DataValueColor>input;
        let out = this.out;
        if (c.alpha == 0 || (c.red == 0 && c.green == 0 && c.blue == 0)) {
            out.value = this.fallback;
        } else {
            out.value = c.value;
        }
        return out;
    }

    override reverseConvert(input: DataValue): DataValue? {
        return input;
    }
}
