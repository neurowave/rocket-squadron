// Port of scene/hud.rml ScriptAsset hud_phase_len (inline Luau). A string's
// length in characters (utf8.len).
import { Converter } from "rive/host";
import { DataValue, DataValueString, DataValueNumber } from "rive/data_value";

// code points (a surrogate pair is one)
export function ulen(s: string): f64 {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c < 0xdc00 || c > 0xdfff) n++;
    }
    return <f64>n;
}

export class PhaseLen extends Converter {
    override convert(input: DataValue): DataValue? {
        if (input instanceof DataValueString) {
            return new DataValueNumber(ulen(input.value));
        }
        return new DataValueNumber(0);
    }

    override reverseConvert(input: DataValue): DataValue? {
        return new DataValueString();
    }
}
