// Port of scene/hud.rml ScriptAsset hud_phase_head (inline Luau). The phase
// head: the text before a '//', trailing whitespace stripped.
import { Converter } from "rive/host";
import { DataValue, DataValueString } from "rive/data_value";

// Lua %s: space, \t \n \v \f \r
function isSpace(c: i32): bool {
    return c == 32 || (c >= 9 && c <= 13);
}

export function head(s: string): string {
    let i = s.indexOf("//");
    if (i >= 0) {
        let e = i;
        while (e > 0 && isSpace(s.charCodeAt(e - 1))) e--;
        s = s.substring(0, e);
    }
    return s;
}

export class PhaseHead extends Converter {
    override convert(input: DataValue): DataValue? {
        if (input instanceof DataValueString) {
            return new DataValueString(head(input.value));
        }
        return null;
    }

    override reverseConvert(input: DataValue): DataValue? {
        return input;
    }
}
