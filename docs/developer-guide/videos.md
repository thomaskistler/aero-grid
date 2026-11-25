# Record and recreate tutorial videos

`tools/video.py` records native TX16S interactions, uses cached Microsoft Cora
narration, and composites with FFmpeg. It is local-only and does not upload.
Recipes/actions live in `tools/video-recipes/`; generated media, SD cards,
caches, and provenance stay in ignored `build/video/`.

## Install and run

```sh
make video-setup
build/video-venv/bin/python tools/video.py --help
build/video-venv/bin/python tools/video.py validate
build/video-venv/bin/python tools/video.py capture
```

Setup installs pinned `imageio-ffmpeg`, including its encoder. Native capture
also requires macOS, Xcode command-line tools, and Companion 2.12.
The default library is:

```text
/Applications/EdgeTX Companion 2.12.app/Contents/Resources/libedgetx-tx16s-simulator.dylib
```

Override with `--library`; universal libraries also need `--architecture arm64`
or `--architecture x86_64`. Intel firmware on Apple Silicon requires Rosetta.
Rendering and speech caching do not require Companion.

The default recipe is `add-move-resize-panel.json`. Pass
`--recipe tools/video-recipes/<name>.json` on each command for another tutorial.
`--output` overrides `build/video/<recipe-id>/`.
`compile` builds the recorder; `prepare` creates the SD card; `capture` does
both and records. Preparation refuses an existing SD card, so use a new output
directory for another capture.

Capture uses current widget sources, including uncommitted changes, in an
isolated copy. Touch/key scripts operate the firmware UI. The editing recipe
injects demonstration telemetry only into that copy; it does not validate
receiver telemetry.

## Narration without storing credentials

`speech` is offline by default. Clips are keyed by text, voice, rate, and PCM
format. Text/rate changes need new clips; timing changes can reuse them.
WAVs must be intact 48 kHz, 16-bit mono PCM and fit their slots with 0.3 seconds
to spare. Shorten text, increase recipe rate, or adjust timing if a clip fails.
The tool does not truncate or automatically accelerate audio.

Paid Azure synthesis requires explicit opt-in:

```sh
# Set AZURE_SPEECH_KEY securely in your environment, never in tracked files.
export AZURE_SPEECH_REGION=westus2
build/video-venv/bin/python tools/video.py speech --online
unset AZURE_SPEECH_KEY AZURE_SPEECH_REGION
```

This sends narration text to Azure and can incur charges. It uses
`en-US-CoraMultilingualNeural` and reuses valid cached clips.
Never put credentials in recipes, arguments, or shell history.

`--cache` selects another ignored cache directory.
`speech --cache-source /path/to/clips` imports recipe `legacy_cache` filenames:
format/duration are checked, but you must listen to verify their content/rate.

## Render and inspect

```sh
# Offline screen-only excerpt:
build/video-venv/bin/python tools/video.py render --silent --limit 12

# Photo composite with cached narration:
build/video-venv/bin/python tools/video.py render --photo /path/to/tx16s.webp

# Review selected rendered-timeline frames:
build/video-venv/bin/python tools/video.py frames --times 0,7.3,21.3,42.1
```

`render` never synthesizes speech. `--silent` bypasses speech requirements;
`--limit` renders an excerpt. Omit `--photo` for a 480 x 272 screen-only video
without physical-button feedback. `--raw` accepts an external recording.
Re-rendering replaces output files.

Photo geometry is configured for a user-supplied 4000 x 4000 image based on the
[RadioMaster TX16S product photograph](https://radiomasterrc.com/cdn/shop/files/478937e8d66c767632b986b2cb0362f5_1800x1800.jpg?v=1755743144).
The tool neither supplies nor downloads/upscales it. Verify usage rights and
retain RadioMaster attribution; the repository GPL does not license the photo.
Other images need matching crop, screen, and mask geometry.

| Output | Purpose |
| --- | --- |
| `frames.rgb565`, `last-frame.png`, `simulator.log` | Raw recording and diagnostics. |
| `frame-*.png`, `frames-sheet.png` | Frame review. |
| `sdcard/`, `video-native` | Isolated fixture and recorder. |
| `feedback.mov`, `radio.png`, `bezel.png` | Regenerable composite intermediates. |
| `<recipe-id>.mp4`, `transcript.txt` | Video and narration transcript. |
| `capture-provenance.json`, `render-provenance.json` | Inputs/hashes, disclosures, and verification limits. |

Recordings are RGB565 little-endian, 480 x 272, 20 fps. Rendering removes
`trim_start` and holds the last frame when needed; provenance records the hold.
Capture checks that timeline touches reached firmware, not that navigation
succeeded. External raw recordings have no reconstructed capture provenance.
Watch the complete result for navigation, save behavior, voice alignment,
units, and photo placement before publishing.

## Recipe format and reproducibility

Use a bundled JSON recipe as the schema example. Version 1 rejects unknown
fields and requires initial state, timing, action path, narration, radio
geometry, and provenance. Actions are recipe-relative `tick x y down` rows
with 10 ms ticks; negative `x` encodes key `-x-1` (`-2` is RTN). Consecutive
touch-down positions form a drag; end with release and do not overlap contacts.

Optional `edits` list source `start`/`end` seconds after `trim_start`, each with
an output `duration`. They cut/retime video and touch feedback together; their
durations must sum to the recipe duration. Use 0.05-second frame boundaries.
Narration uses output time.

The bundled tutorials cover:

| Recipe | Demonstrated scope |
| --- | --- |
| `create-empty-dashboard` | Add an App-mode widget with Empty and Modern Dark. |
| `add-move-resize-panel` | Configure, move, resize, and save a panel. Restart/layout selection are narrated, not replayed. |
| `model-settings` | Arm/detection settings, Sticky L01 with start sound, flight-status output, and session reset. The end sound is narrated, not replayed. |
| `flight-debrief` | Flight-detection prerequisites, derived-sensor discovery, post-flight charts, and layout-specific debrief customization. |

The debrief tutorial reuses the six-chart recording from PR #256. Supply its
local `replay/` directory with `--debrief-replay` when preparing or capturing;
the recording is not bundled. Only use trusted replay files: EdgeTX loads them
as Lua. The charts retain their recorded values; Expo is the saved 30%, not
logged telemetry, and threshold colors were not reconstructed.

Fixed-coordinate scripts depend on firmware, widget behavior, and machine load.
There is no UI-state recovery: maintain the scripts and retain approved videos
separately rather than assuming byte-identical recreation.

## Validate changes

```sh
build/video-venv/bin/python -m unittest discover -s tools -p 'test_video.py'
```

Tests cover validation, source isolation, cache behavior, mocked synthesis, and
offline screen/photo render-and-decode checks. Native capture needs separate
local review. Tests must never require paid speech.
