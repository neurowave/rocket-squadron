// Port of scene/screens_sting.rml ScriptAsset cert_strike (inline Luau). The
// certificate strike-through's width (of 228) for a row label.
import { Converter } from "rive/host";
import { DataValue, DataValueString, DataValueNumber } from "rive/data_value";

// label widths (px)
function known(s: string): f64 {
    if (s == "RINGS") return 112.6;
    if (s == "BOOST") return 124.4;
    if (s == "BRAKE") return 120.3;
    if (s == "BARREL ROLL") return 243.9;
    if (s == "DEFLECT") return 161.2;
    if (s == "FIRE") return 81.2;
    if (s == "LOCK-ON") return 164.9;
    if (s == "BOMB") return 109.6;
    return NaN;
}

// code points (utf8.len)
function ulen(s: string): f64 {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c < 0xdc00 || c > 0xdfff) n++;
    }
    return <f64>n;
}

export function strike(s: string): f64 {
    let w = known(s);
    if (isNaN(w)) w = ulen(s) * 21;
    return (w + 10) / 228;
}

export class CertStrike extends Converter {
    override convert(input: DataValue): DataValue? {
        let s = "";
        if (input instanceof DataValueString) s = (<DataValueString>input).value;
        return new DataValueNumber(strike(s));
    }

    override reverseConvert(input: DataValue): DataValue? {
        return new DataValueString();
    }
}
