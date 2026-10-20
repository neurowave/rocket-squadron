r"""Font subsets for the build: tools/fonts/src/*.ttf (the full fonts) -> *.ttf at the project root, the
files scene/assets.rml packs.

Per font, glyph ids, metrics, layout and variation data stay as delivered; only the glyphs nothing can reach are
emptied (outline and variations) and the cmap keeps only the characters below. Reachable = fontTools' subsetter
closure over:
- every character the game can show: all non-ASCII characters in scene/*.rml, scene/*.as and src/ text files
  (text runs, view model strings, script string literals incl. the comms lines, with \u{...} / \xHH / \ddd escapes
  decoded; comments too, a superset), plus Latin-1 (U+0020-U+007E, U+00A0-U+00FF) as a safety net for strings built
  at run time, plus the control characters the full font maps (CR, NUL);
- fontTools' default layout features (rvrn among them: RobotoFlex swaps '$' through it; a list without it turned
  the heavy '$' into a blob) and any feature a TextStyleFeature in scene/*.rml requests;
- .notdef with its outline (a missing character still draws the box it drew before).
Not done: pinning RobotoFlex's unused axes. Dropping the glyph variation tuples that are zero at those axes'
defaults is exact for HarfBuzz (outlines, advances, kerning: checked), but the runtime then drew a few text pixels
1 level off; a renumbering subset rebuilt HVAR / GDEF and moved advances and
kerning by float ulps, so glyph ids are kept.

usage (from the repository root):
  python3 tools/fonts/subset_fonts.py           write the *.ttf at the root
  python3 tools/fonts/subset_fonts.py --check   build check (exit 1 on failure): every scanned character a full font
                                                 has is in the root *.ttf, and they are what this step writes now
Rerun after adding text with a character outside Latin-1 (the check names it), or a TextStyleFeature. Deterministic:
a rerun reproduces the root *.ttf byte for byte (written with fontTools 4.60.2; another version may report the fonts
stale without any text change: rerun to refresh them).
"""
import io, os, re, struct, sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import Glyph

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(HERE, 'src')
OUT = ROOT
FONTS = ['Montserrat.ttf', 'RobotoFlex.ttf', 'Tomorrow.ttf']
LATIN1 = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100))
CONTROLS = set(range(0, 0x20)) | set(range(0x7F, 0xA0))  # kept where the full font maps them (CR, NUL)
TEXT_EXT = ('.as', '.luau', '.lua', '.json', '.txt', '.rml')


def luau_escapes(s):
    """the characters Luau string escapes spell: \\u{XXXX}, and UTF-8 byte runs written as \\xHH / \\ddd"""
    out = [chr(int(m.group(1), 16)) for m in re.finditer(r'\\u\{([0-9A-Fa-f]+)\}', s)]
    for m in re.finditer(r'(?:\\x[0-9A-Fa-f]{2}|\\[0-9]{1,3})+', s):
        bs = bytes(int(t[1:], 16) if t[0] == 'x' else int(t) for t in re.findall(r'x[0-9A-Fa-f]{2}|[0-9]{1,3}', m.group(0)) if (int(t[1:], 16) if t[0] == 'x' else int(t)) < 256)
        out.append(bs.decode('utf-8', 'ignore'))
    return ''.join(out)


def scanned_chars():
    """{codepoint: first place seen} for every non-ASCII character in scene/*.rml and src/ text files"""
    seen = {}
    files = [os.path.join(ROOT, 'scene.rml')]
    files += [os.path.join(ROOT, 'scene', f) for f in sorted(os.listdir(os.path.join(ROOT, 'scene'))) if f.endswith(('.rml', '.as', '.luau'))]
    for dp, _dn, fn in sorted(os.walk(os.path.join(ROOT, 'src'))):
        files += [os.path.join(dp, f) for f in sorted(fn) if f.endswith(TEXT_EXT)]
    for p in files:
        with open(p, encoding='utf-8') as f:
            s = f.read()
        if p.endswith('.rml'):
            s = re.sub(r'&#x([0-9A-Fa-f]+);', lambda m: chr(int(m.group(1), 16)), s)
            s = re.sub(r'&#([0-9]+);', lambda m: chr(int(m.group(1))), s)
        else:
            s += luau_escapes(s)
        for c in s:
            o = ord(c)
            if o > 0x7E and o not in seen:
                seen[o] = os.path.relpath(p, ROOT)
    return seen


def used_features():
    """OpenType feature tags the scenes request (TextStyleFeature tag, as a number or a 4-char string)"""
    tags = set()
    for f in sorted(os.listdir(os.path.join(ROOT, 'scene'))):
        if f.endswith('.rml'):
            s = open(os.path.join(ROOT, 'scene', f), encoding='utf-8').read()
            for m in re.finditer(r'<TextStyleFeature\b[^>]*\btag="([^"]+)"', s):
                v = m.group(1)
                tags.add(struct.pack('>I', int(v)).decode('latin-1') if v.isdigit() else v)
    return tags


def build(name, chars, features):
    """the subset of tools/fonts/src/<name> as bytes (see the module comment)"""
    path = os.path.join(SRC, name)
    font = TTFont(path, recalcTimestamp=False, recalcBBoxes=False)  # (reproducible; bounding boxes as delivered)
    have = set(font.getBestCmap())
    keep_u = (LATIN1 | CONTROLS | set(chars)) & have
    # the closure, from the subsetter on a copy
    probe = TTFont(path)
    opts = subset.Options()
    opts.notdef_outline = True
    opts.layout_features = list(opts.layout_features) + sorted(features - set(opts.layout_features))
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=sorted(keep_u))
    sub.subset(probe)
    keep_g = set(probe.getGlyphOrder())
    glyf = font['glyf']
    gvar = font['gvar'] if 'gvar' in font else None
    for g in font.getGlyphOrder():
        if g not in keep_g:
            glyf[g] = Glyph()
            if gvar is not None:
                gvar.variations[g] = []
    for t in font['cmap'].tables:
        if hasattr(t, 'cmap') and t.cmap:
            t.cmap = {u: g for u, g in t.cmap.items() if u in keep_u}
    buf = io.BytesIO()
    font.save(buf)
    return buf.getvalue()


def main():
    check = '--check' in sys.argv
    chars = scanned_chars()
    features = used_features()
    ok = True
    for name in FONTS:
        data = build(name, chars, features)
        full = set(TTFont(os.path.join(SRC, name)).getBestCmap())
        dst = os.path.join(OUT, name)
        # coverage of the font the build packs (on disk) when checking, of the new subset when writing
        packed = dst if check and os.path.exists(dst) else io.BytesIO(data)
        got = set(TTFont(packed).getBestCmap())
        miss = sorted(o for o in (set(chars) | LATIN1) if o in full and o not in got)
        if miss:
            ok = False
            print('%s: MISSING %s' % (name, ', '.join('U+%04X %r (%s)' % (o, chr(o), chars.get(o, 'Latin-1')) for o in miss)))
        if check:
            cur = open(dst, 'rb').read() if os.path.exists(dst) else b''
            if cur != data:
                ok = False
                print('%s: %s is stale (rerun tools/fonts/subset_fonts.py)' % (name, name))
        else:
            with open(dst, 'wb') as f:
                f.write(data)
        print('%s: %d -> %d bytes, %d characters' % (name, os.path.getsize(os.path.join(SRC, name)), len(data), len(got)))
    extra = sorted(chars)
    print('scanned non-ASCII characters (%d): %s; features requested: %s' % (
        len(extra), ''.join(chr(o) for o in extra), ','.join(sorted(features)) or '-'))
    if check:
        print('fonts check: %s' % ('OK' if ok else 'FAILED'))
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
