#!/usr/bin/env python3
"""Writes src/render/image_names.as: every ImageAsset name in scene/*.rml, sorted, 1-based (slot 0 is a dummy).
The renderer uses it as its first-use warm-up list. Rerun after adding or removing an ImageAsset.
    python3 tools/gen_image_names.py
"""
import glob, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
names = set()
for f in sorted(glob.glob(os.path.join(ROOT, 'scene', '*.rml'))):
    for m in re.finditer(r'<ImageAsset\b[^>]*?\bname="([^"]+)"', open(f, encoding='utf-8').read()):
        names.add(m.group(1))
out = ['// Every ImageAsset in scene/*.rml (the renderer\'s first-use warm-up list).',
       '// Regenerate with tools/gen_image_names.py. 1-based: slot 0 is a dummy.',
       'export const IMAGE_NAMES: Array<string> = [', '    "",']
out += ['    "%s",' % n for n in sorted(names)]
out += ['];']
open(os.path.join(ROOT, 'src', 'render', 'image_names.as'), 'w').write('\n'.join(out) + '\n')
print('%d image names' % len(names))
