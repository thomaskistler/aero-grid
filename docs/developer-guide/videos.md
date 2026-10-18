# Record and recreate tutorial videos

`tools/video.py` provides reusable **local** native TX16S recording, Microsoft
Cora narration, and FFmpeg compositing. It does not upload to YouTube.
Recipes and real input scripts are versioned in `tools/video-recipes/`.
Generated SD cards, recordings, caches, and provenance belong in ignored
`build/video/`. No product photograph, credentials, or video is distributed
with the repository.

## Install and run

Use Python 3.9+ and `make video-setup` to install pinned
`imageio-ffmpeg==0.6.0` (including its encoder) into `build/video-venv`.
Capture additionally requires macOS, Xcode command-line tools, and EdgeTX
Companion 2.12. The default simulator library is:

```text
/Applications/EdgeTX Companion 2.12.app/Contents/Resources/libedgetx-tx16s-simulator.dylib
```

Override with `--library /path/to/libedgetx-tx16s-simulator.dylib`.
Compilation selects the library's architecture; for a universal library use
`--architecture arm64` or `--architecture x86_64`. Running Intel firmware on
Apple Silicon requires Rosetta. The symbol ABI and geometry are TX16S-specific.
Rendering and speech caching do not require Companion.

```sh
make video-setup
build/video-venv/bin/python tools/video.py --help
build/video-venv/bin/python tools/video.py validate
build/video-venv/bin/python tools/video.py capture
```

The default recipe is `add-move-resize-panel.json`. Select the other tutorial
with `--recipe tools/video-recipes/create-empty-dashboard.json` on **each**
command. `--output build/video/my-run` selects a different working directory.
`compile` only builds the recorder; `prepare` only creates an SD card.
`capture` does both, then records. Preparation refuses an existing SD card:
use a new output directory for another capture. It never replaces your
development SD image.

Capture uses `capture-editor.py`'s SD preparation and the current checkout's
widget source, including uncommitted changes. All editor interactions go
through genuine simulator touch/key input. No panel code is rewritten.
The editing recipe explicitly injects demonstration telemetry **only in its
isolated widget copy**: registered `GSpd`/maximum sensor, values 48/72, RSSI
85. Those values demonstrate the UI, not receiver telemetry accuracy.

## Narration without storing credentials

`speech` is **offline by default**. Cache files are addressed by SHA-256 of
text, voice, rate, and PCM format. Text/rate changes require new speech;
timing changes reuse a clip if it still fits. Each WAV must be 48 kHz,
16-bit mono PCM, nonempty, intact, and at least 0.3 seconds shorter than its
slot. Oversized clips fail rather than silently speeding up or truncating
the voice. Increase a recipe's `rate` percentage or shorten text and retry.

Paid synthesis requires an explicit opt-in:

```sh
# Set AZURE_SPEECH_KEY securely in your terminal/environment, not in a file,
# command argument, recipe, shell history, or checked-in configuration.
export AZURE_SPEECH_REGION=westus2
build/video-venv/bin/python tools/video.py speech --online
unset AZURE_SPEECH_KEY AZURE_SPEECH_REGION
```

The REST request uses `en-US-CoraMultilingualNeural`; existing clips are not
resynthesized. The tool never writes keys or logs request headers. Synthesis
can incur Azure charges and sends narration text to Azure. A failed later
clip leaves previously successful cache entries for retry.

To reuse privately retained prototype clips without synthesis:

```sh
build/video-venv/bin/python tools/video.py speech --cache-source /path/to/private/clips
```

This trusts recipe `legacy_cache` filenames as matching the text. WAV
format and duration are checked, but spoken content and synthesis rate cannot
be inferred from audio: listen before importing. Import provenance records this
uncertainty. No imported media is required or included. `--cache` selects an alternate cache directory; keep it ignored.

## Render and inspect

```sh
# Screen-only preview, no network or speech needed:
build/video-venv/bin/python tools/video.py render --silent --limit 12

# Final photo composite with previously cached narration:
build/video-venv/bin/python tools/video.py render --photo /path/to/private/tx16s-upscaled.webp

# Render a retained raw recording instead of capturing again:
build/video-venv/bin/python tools/video.py render --raw /path/to/recording.rgb565 \
  --photo /path/to/private/tx16s-upscaled.webp
```

`render` never synthesizes speech. Omit `--photo` for a 480×272 screen-only
video (physical button feedback is then omitted). `--silent` bypasses all
speech cache requirements. `--limit` renders an initial excerpt, not a new
capture. Re-rendering replaces outputs in that directory.

The supplied photograph must match the recipe geometry. Original source:
[RadioMaster TX16S product photograph](https://radiomasterrc.com/cdn/shop/files/478937e8d66c767632b986b2cb0362f5_1800x1800.jpg?v=1755743144).
The original retrieved image was 1000×1000; the prototypes used a
**user-supplied 4000×4000 upscale**. The tool does not download or upscale
it. Confirm usage rights and retain attribution to RadioMaster when
publishing; the repository's GPL does not license that photograph.

For that upscale, recipes crop `[width,height,x,y] = [2080,1000,960,2700]`,
scale to 1560×750, place the 930×532 simulator screen at (317,80), and place
RTN feedback at (147,507). The generated bezel mask keeps dark irregular
screen edges: inside the screen rectangle, average RGB brightness 80–120
ramps from opaque photo to transparent opening. Inspect the result; a
different photo requires different geometry/thresholds.

Feedback is a 15%-opacity ring with transparent interior, expanding and
fading over 1.2 seconds. Its color adapts to the local framebuffer luminance;
drag contacts follow their scripted points. RTN uses a white ring on the
dark physical key; other keys have no invented photo coordinates.
No titles or subtitle track are burned in.

Outputs include:

| File | Purpose |
| --- | --- |
| `frames.rgb565`, `last-frame.png`, `simulator.log` | Recorder evidence and diagnostics. |
| `frame-*.png`, `frames-sheet.png` | Frames exported by the `frames` command for review. |
| `sdcard/`, `video-native` | Isolated firmware fixture and compiled recorder. |
| `feedback.mov`, `radio.png`, `bezel.png` | Regenerable render intermediates. |
| `<recipe-id>.mp4`, `transcript.txt` | H.264/AAC deliverable and narration text. |
| `capture-provenance.json`, `render-provenance.json` | Recipe, source/input digests, disclosures, tail holds, verification limits. |

Capture fails if any touch press in the rendered timeline (after warmup and
`trim_start`) has no matching firmware `TE_PRESSED` entry in
`simulator.log`, and records `unaccepted_touch_ticks` in capture provenance.
This catches dropped input, not wrong navigation. Export frames to check
key states:

```sh
build/video-venv/bin/python tools/video.py frames --times 0,7.3,21.3,42.1,54.65
```

`--times` uses rendered-timeline seconds. PNGs and a tiled
`frames-sheet.png` are written to the output directory.

Raw capture is RGB565 little-endian, 480×272, 20 fps. The recorder uses
10 ms ticks, drops the warmup interval, and samples every five ticks.
Rendering trims `trim_start` seconds from that recording and holds the
final frame if narration extends past it; the hold duration is recorded.
Capture hashes all current widget sources, not just the Git revision.
External recordings have no automatically reconstructed capture provenance.
FFmpeg decoding and frame counts prove media integrity, **not UI success**.
Review the whole video for correct navigation, drag, save behavior, voice
alignment, source units, and photo placement before publishing.

## Recipe format and reproducibility

Version 1 is validated before execution; unknown fields are rejected.
Recipes require `id`, `initial` (`fresh-model` or `empty-dashboard`), `ticks`,
`warmup_ticks`, `trim_start`, `duration`, recipe-relative `actions`,
`narration`, `radio`, and `provenance`. Optional `sample_telemetry: true`
is supported only for the editing fixture. Tick totals/warmup are multiples
of five. Action rows contain `tick x y down`; `down` is 1 or 0. Negative
`x` encodes key `-x-1` (`-2` is RTN). Consecutive touch-down positions are
a drag, terminated by a release. Contacts cannot overlap.

Narration entries have ordered, nonoverlapping `start`/`end` seconds,
`text`, and nonnegative `rate` (percentage); `legacy_cache` is optional.
Radio entries contain `crop`, even-sized `canvas`, `[x,y,width,height]`
`screen`, `[x,y]` `return_button`, `[low,high]` `mask_threshold`, and `source`.
Provenance requires `status` and `notes`.

**Create Empty dashboard:** a clean native replay starting from a fresh
model with no configured screens. It replaces the default screen with an
App-mode AeroGrid widget using the Empty layout (tapped at (220,85)) and
Modern Dark, then presses RTN three times. No recorded frames are edited.
The firmware dropped the first scripted touch of a fresh simulator session
in earlier attempts, desynchronizing every later step. The action script
therefore primes input before recorded frames start: a center tap opens the
EdgeTX menu and RTN closes it (ticks 100–220), so the video begins on the
unchanged main view. Two consecutive Companion 2.12 captures were visually
verified before rendering the published 54.7-second video.

**Add/move/resize panel:** the recipe preserves the prototype's real touch
script, current/maximum speed configuration, movement, resizing, and save
interaction. Nine seconds are trimmed from the raw capture, including most
of its first long-press; check intro timing. The last second is a held frame.
Radio restart and selecting the new layout after Save as are **narrated
instructions**, not automated or demonstrated steps. Panel unit appearance
comes from production source, never simulator-only rendering patches.

Fixed-coordinate/realtime scripts can change behavior with firmware,
machine load, or widget changes. There is no UI-state assertion or automatic
recovery. Keep the approved published videos separately; recipes are
maintainable starting points, not a guarantee of identical recreation.

## Validate changes

```sh
build/video-venv/bin/python -m unittest discover -s tools -p test_video.py
```

Tests cover recipe/action validation, isolated source preservation, cache
behavior, request escaping via a mocked Azure response, and offline
screen/photo render-and-decode smoke checks. Real native capture is local
and must be checked separately. Never require paid speech in tests.
