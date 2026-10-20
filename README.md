# Rocket Squadron

https://github.com/user-attachments/assets/380118aa-a8b0-481e-a557-1c7b45fd79dd

An on-rails jetpack shooter built entirely with the [Rive CLI](https://rive.app/docs/cli/overview). The
simulation and the renderer are written in AnimaScript, the cel-shaded 3D world is drawn with WGSL shaders on
Rive's GPU canvas, and every screen, the pilot and the HUD are RML artboards with state machines, data binding
and layouts. The HUD is rendered onto a curved 3D helmet visor, and the painted comms portraits are rigged
with bones and meshes. The whole game builds into one `.riv` file.

You fly a coastal run with two wingmen: chain gold rings, skim the sea for score multipliers, thread the sea
arches, fight drones, biplanes and jet troopers, and take on two bosses. A flight school teaches the controls on the first
run, and an attract reel plays the game on autopilot when the title screen sits idle.

## Run it

1. Install the Rive CLI:

   ```bash
   curl -fsSL https://releases.rive.app/cli/install.sh | sh
   ```

2. From this folder:

   ```bash
   rive . --aot
   ```

   This builds `build/rocket-squadron.riv` and opens the preview window. `--aot` compiles the scripts ahead
   of time (much faster at runtime). The build takes about 15 seconds.

The repository ships every generated file (the audio and the font subsets), so no Python is needed just to
run it. Builds with Rive CLI 1.5.1 and newer.

The game lays itself out to the window, in landscape or portrait. Pick keyboard, gamepad or touch prompts
under CONTROLS on the title screen, and trade effects for speed under QUALITY (AUTO, LOW, MED, HIGH).

### Troubleshooting

- **`script tier: interp, no wamrc`** in the log means the ahead-of-time compiler wasn't found, so scripts
  run in the interpreter. Everything still works, just at a lower frame rate. Point `RIVE_WAMRC` at a
  `wamrc` binary to enable it.
- **Shift and Ctrl do nothing** in the macOS preview window: modifier-only key presses don't reach scripts
  there. Use the letter keys (X boost, C brake).
- Eight `[lint] W1002: unused parameter` warnings during the build are expected.

## Controls

| Keyboard | Gamepad | Action |
|---|---|---|
| W A S D / arrows | left stick / d-pad | steer |
| Z / Space / J | A / RT | fire (hold to charge a lock-on nova) |
| X / Shift / K | X | boost |
| C / Ctrl / L | B / LT | brake |
| Q / E, or double-tap A / D | LB / RB, or flick the stick twice | barrel roll (deflects bullets) |
| B | Y | bomb |
| Esc / P | Start | pause |
| Enter | A / Start | confirm |
| hold Enter | hold Back | skip the flight school |
| M / N | | mute music / mute all |

Touch: drag the on-screen stick, and use the FIRE (hold to charge), BOOST, BRAKE, ROLL, BOMB and PAUSE
buttons. The mouse works the menus.

## Edit it in the Rive Editor

The project is laid out the way `rive pull` writes it (`scene.rml` and the artboard files in `scene/`, with
every script, shader, image, sound and font as a file), so it round-trips cleanly between the CLI and the
Rive Editor:

```bash
rive login
rive push            # first push: creates a file in your Rive account and records the link in rive.yaml
```

Designers open that file in the Rive Editor and change layouts, colors, text, animations and state machines.
Bring their work back with:

```bash
rive pull            # writes the Editor's version over the scene, script and asset files
git diff             # review what changed
```

Keep the project in Git: a pull overwrites the local files with the Editor's version, and a push replaces the
Editor's content with yours, so commit before either one. Edits made on both sides at once are not merged.

Some things are tied to the artboards by code, so keep them in step when you change them:

- The game script reads and writes the view models (`Game`, `Hud`, `Pilot`, `Reticle`, `LockOn`, `Popup`)
  by property name, and receives the `Hud`, `Pilot`, `Reticle`, `LockOn` and `Popup` artboards as script
  inputs. Keep those names.
- The pilot's flames and wrist blasters are placed from named nodes on the `Pilot` artboard (`FlameTipL`,
  `FlameTipR`, `RasterMuzzleL`, `RasterMuzzleR`).
- Score popups avoid the HUD panels using fixed screen fractions copied from the `Hud` artboard's stage
  (`src/game/popups.as`). If a designer moves a HUD panel, update those numbers.
- The comms window pages its text with a table of Montserrat glyph widths (`scene/scene_hud_comms.as`, with
  a copy in `src/game/core_pages.as`). Changing the comms font or size means updating both copies.
- The print plates on the title, pause, results and game over screens are drawn by the post shader from
  opacities the screens write back to the `Game` view model (`src/game/core_print.as`).
- `src/render/image_names.as` lists every image asset by name. Rerun `python3 tools/gen_image_names.py`
  after adding or removing an image.

## How it's built

| Piece | Where |
|---|---|
| Game loop, app states (title, briefing, launch, flight school, playing, results), input | `src/src_game.as`, `src/game/input.as`, `src/game/core_*.as` |
| Player, wingmen, enemies, bosses, weapons, scoring, events, autopilot | `src/game/*.as` |
| World: terrain, cliffs, sea arches, props, the track, collision, all generated in code at load | `src/world/*.as`, `src/lib/meshgen.as` |
| Renderer: cel shading, ink outlines, water with reflections and foam, sky, particles, trails, bloom, the visor, print-plate post effects | `src/render/renderer.as`, `src_render_*.wgsl` |
| Title, briefing, countdown, pause, results, game over, set-piece stings, touch controls | `scene/main.rml`, `scene/screens_*.rml` |
| HUD (drawn onto the 3D visor) and its comms window | `scene/hud.rml`, `scene/scene_hud_comms.as`, `scene/conv/*.as` |
| Painted comms portraits, rigged with bones and meshes (blink, talk, moods) | `scene/hud_portraits.rml`, `mags_*`, `vi_*`, `hank_*`, `baron_*` images |
| Pilot and wingmen (painted poses, flames, scarf), reticle, lock-on, score popups | `scene/sprites.rml`, `pilot_*`, `vi_pilot_*`, `hank_pilot_*` images |
| Title key art, signature, halftone and grain textures | `scene/screens_brand.rml`, `hero_*`, `signature*`, `halftone*`, `grain*` images |
| Sound effects and music (`*.flac`, `*.mp3`, `*.wav`) | `scene/audio.rml`, `src/game/sfx.as` |
| Fonts (`*.ttf`, glyph subsets) | `scene/assets.rml` |

The game was first written in Luau and then ported to AnimaScript, so some comments still refer to the
Luau originals.

### Rebuilding the generated assets

The markup in `scene.rml` and `scene/` is the source: edit it directly, in a text editor or in the Rive
Editor. Two Python tools regenerate asset files the scene points at, and one refreshes a list in code:

```bash
# Audio: every sound and music loop is synthesized from scratch (Python 3 standard library, no samples).
# Rewrites the sound files and the generated block in src/game/sfx.as. A new sound also needs an
# AudioAsset in scene/audio.rml.
# Encoders: lame (MP3) and afconvert (FLAC, macOS); falls back to ffmpeg, then WAV.
python3 tools/gen_audio.py
python3 tools/gen_audio.py --list      # every sound, its kind and format

# Fonts: subsets tools/fonts/src/*.ttf (the full fonts) to the characters the game uses.
python3 -m venv .venv && .venv/bin/pip install -r tools/requirements.txt
.venv/bin/python tools/fonts/subset_fonts.py
.venv/bin/python tools/fonts/subset_fonts.py --check   # fails when text needs a missing glyph

# Image warm-up list (src/render/image_names.as): rerun after adding or removing an image.
python3 tools/gen_image_names.py

rive . --aot
```

`gen_audio.py` is deterministic: it reproduces the shipped FLAC and WAV files byte for byte. The MP3 files
decode to the same audio with any LAME version; for byte-identical MP3s, put the LAME 3.100 command-line
encoder on your `PATH`.

## Credits

- **Fonts**, all under the [SIL Open Font License 1.1](https://openfontlicense.org) (license texts in
  `licenses/`):
  [Roboto Flex](https://github.com/googlefonts/roboto-flex) by The Roboto Flex Project Authors,
  [Montserrat](https://github.com/JulietaUla/Montserrat) by The Montserrat Project Authors,
  [Tomorrow](https://github.com/MonicaRizzolli/Tomorrow) by The Tomorrow Project Authors.
  The `.ttf` files in the root are glyph subsets; the full fonts are in `tools/fonts/src/`.
- **Painted art** (the `.webp` images: the pilot's poses, the title key art and signature, the comms
  portraits, the halftone and grain textures) was generated with ChatGPT for this project, then cut out,
  cleaned up, tinted and rigged.
- **Audio** is synthesized by `tools/gen_audio.py`.
- **3D world**: every mesh and texture is generated in code. No third-party models or textures.
- All characters, call signs and squadrons are fictitious.

## License

The code and generators are released under the [MIT License](LICENSE). Third-party content keeps its own
license as listed under Credits (fonts: SIL OFL 1.1). The Rive name and logo are trademarks of Rive Inc.
