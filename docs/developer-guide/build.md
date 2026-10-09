# Build and simulator

## Prerequisites

Clone the [repository](https://github.com/thomaskistler/aero-grid) and run commands
from its root. Development uses Python 3 with virtual-environment support, Make,
and rsync. Runtime modules target EdgeTX's Lua 5.3 environment.

For validation, install EdgeTX's `edgetx-luac` or a Lua 5.3 compiler,
`lua-language-server` for linting, and StyLua for formatting.
CI checks formatting with StyLua 2.5.2.

## Development

Runtime modules target EdgeTX's Lua 5.3 environment.

### Documentation website

The site uses MkDocs with the Markdown sources in `docs/`. Run `make docs` to
install the separate documentation dependencies and build a strictly validated
site in `build/docs/`. Run `make docs-serve` for a local preview at
`http://127.0.0.1:8000`; stop it with Ctrl-C.

`.github/workflows/docs.yml` validates documentation changes in pull requests
and publishes to GitHub Pages after they land on `main`. Repository
**Settings > Pages > Source** must be set to **GitHub Actions**. The workflow
can also be run manually from `main`. Panel references remain ordinary
Markdown files, readable directly on GitHub.

### Make targets

| Target | Purpose |
| --- | --- |
| `make help` | List the supported Make targets. |
| `make setup` | Create `build/venv` and install `requirements-dev.txt`. |
| `make test` | Run unit and mocked EdgeTX integration suites in normal and firmware-like string modes. |
| `make check` | Run `make test`, then parse every source and test Lua file with an EdgeTX/Lua compiler. |
| `make build` | Recreate `build/sdcard` from `tests/fixtures/sdcard`, then overlay `src/WIDGETS/AeroGrid`. |
| `make docs` | Build and strictly validate the MkDocs documentation site. |
| `make docs-serve` | Preview the documentation locally with live reload. |
| `make clean` | Remove all generated `build/` output, including the virtual environment and simulator SD image. |

Typical workflow:

```sh
make setup
make test
make check LUA_COMPILER=/path/to/edgetx-luac
make build
```

`make test` and `make check` run `make setup` automatically when the development environment is missing or `requirements-dev.txt` changed. `make check` looks for `edgetx-luac`, `luac5.3`, then `luac` on `PATH`; `LUA_COMPILER` overrides detection. Use EdgeTX's `edgetx-luac` when available because it validates the firmware's exact Lua 5.3 configuration.

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, malformed and corrupt layout handling, forward-compatible unknown keys, layout-name path sanitization, the append-only layout registry, the panel module contract, declared settings and spans, panel lifecycle failure isolation, hostile modules, theme derivation and legibility, panel states, zone reflow, Layout reload behavior, snapshot immutability, service scheduling and subscription caps, telemetry freshness against a dropped link and a valid zero, trim scaling, global variable bounds, arm-switch flight sessions, GPS distance and bearing, graceful degradation when a firmware API or a whole service module is missing, per-metric range and threshold settings, timer count-up and expired-countdown semantics, the optional transmitter charge estimate, global variable and bar normalization, trim rounding and three-position handling, model bitmap fallback, width-aware font fitting, cells-table shape validation, protocol-dependent link source selection, a link that drops and returns, a missing GPS fix, an unavailable home position, and a protocol that populates no RSSI sensor at all. Each Lua behavior suite runs once with normal string methods and once with the string metatable removed to match EdgeTX firmware behavior.

Additional commands: `make lint` checks Lua with lua-language-server; `make format` runs StyLua; `make mocks` renders panel geometry.

## EdgeTX Dev Kit simulator

Open the repository folder in VS Code. The repository includes a TX16S/EdgeTX 2.12 profile. Set **EdgeTX: SD Card Path** to the absolute path of the ignored `build/sdcard/` directory in your checkout.

1. Run `make build` or the **AeroGrid: Build Simulator SD** task once to create the complete image.
2. Open `src/WIDGETS/AeroGrid/main.lua`.
3. Run **EdgeTX: Toggle EdgeTX Mode** if EdgeTX mode is not already active.
4. Run **EdgeTX: Simulate Script** (`Cmd+Alt+S`) or **EdgeTX: Watch Script** (`Cmd+Alt+W`).
5. Open **Logs** in the simulator when the dashboard reports an error.

The build starts from the tracked baseline in `tests/fixtures/sdcard/`, then overlays the current `src/WIDGETS/AeroGrid/` sources. The baseline contains the fixed radio and model configuration needed to boot directly into AeroGrid. The generated `build/sdcard/` image is ignored and may be changed by the simulator. Run `make build` again after source changes or whenever you want to reset the image to the checked-in baseline.

The baseline selects **AEROGRID REVIEW** (`model2.yml`) at startup. Its radio
settings carry `manuallyEdited: 1` so EdgeTX accepts the edited selection
despite the original checksum, then writes a fresh checksum on save. Keep
that flag set when manually changing the tracked radio settings.

The review model already uses all ten available screens. Select **AEROGRID TEXT**
(`model3.yml`) for the `review-text` dashboard. Its first screen compares compact,
tall, wide, and large text panels with one to three readings. SF changes MODE,
SA changes RATE, and SB changes FLAP. The NO MIDDLE panel deliberately leaves
SA's middle position unmapped.

Select **AEROGRID DEFAULT** (`model4.yml`) for a dedicated model whose first
screen displays the default dashboard in App mode with the Modern theme.

**Rebuilding resets simulator radio and model configuration to the fixture.**
To verify packaging without overwriting customized simulator state, use a separate
output directory:

```sh
make build BUILD_DIR=build/package-check
```

### Stale bytecode

EdgeTX compiles each script to a `.luac` beside it on the SD card and then prefers
the bytecode. `rsync` preserves source timestamps, so a freshly copied `.lua` can
look older than bytecode the radio compiled from the previous build, and the radio
keeps running code that is no longer on disk. Symptoms include a fix that visibly
does nothing and errors citing line numbers that no longer exist in the source.

`make build` therefore deletes every `.luac` from the image and stamps the sources
as new. When incrementally copying development sources to a simulator or radio,
remove stale `.luac` files within the AeroGrid package and stamp the Lua sources
for recompilation. For normal user upgrades, replace the complete folder as
described in [Installation and upgrades](../user-guide/installation.md#upgrade).

`lib/package.lua` defines the package version and the runtime, panel, and
layout API versions. The host rejects incompatible or unversioned runtime modules;
a failed service leaves unrelated panels running. Layout `host` reports the
loaded version. These checks detect API-incompatible mixtures, not every mixture
of compatible releases or stale bytecode.

## Documentation screenshots

### Editor screenshots

On macOS with EdgeTX Companion 2.12 and the Xcode command-line tools, run:

```sh
python3 tools/capture-editor.py
```

This uses only Python's standard library. It captures the overview, metric
settings and entry dialogs, exit menu, and Save As dialog in
`build/editor-capture/`. Use `--companion /path/to/Companion.app` to select a
different installation.

The tool boots an isolated fixture SD card, enters fullscreen through a native
long-press, and automates the production editor commands in a copied widget.
It does not modify `src/` or `build/sdcard/`. Frames are captured after the UI
settles; `provenance.json` records the source and simulator hashes. Copy reviewed
PNGs and the provenance file into `docs/assets/editor/` to update the guide.

### Panel screenshots

On macOS with EdgeTX Companion 2.12 installed and the Xcode command-line tools,
run from the repository root:

```sh
make capture-setup
build/capture-venv/bin/python tools/capture-panels.py --panel trim-panel
build/capture-venv/bin/python tools/capture-panels.py --panel flight-timer
build/capture-venv/bin/python tools/capture-panels.py --panel text
build/capture-venv/bin/python tools/capture-panels.py --panel flight-counter
build/capture-venv/bin/python tools/capture-panels.py --all
```

Use `--companion /path/to/Companion.app` for a different installation location.
The capture tool supports the single-architecture native TX16S library;
an Intel library requires Rosetta on Apple Silicon. It does not need VS Code.
`make capture-setup` installs the optional PyYAML dependency into a separate
`build/capture-venv/` environment, without changing runtime or documentation dependencies.

Captures are saved directly under `build/doc-capture/<panel>/`, containing a
dedicated SD image, simulator log, full-frame PNG, `1x2.png`, `2x1.png`, `2x2.png`,
recipe, and provenance. Regenerating a panel replaces its entire previous output;
no run history is kept. A failed attempt leaves diagnostic output in that panel's
directory, not a retained set of old images. `--all` regenerates every bundled
panel recipe sequentially; on failure, already completed panels remain updated.
Documentation assets are not overwritten.
All eleven display panels are supported. Captures use the Modern theme, a 480 x 272 App-mode dashboard,
and placements outside the menu overlay. Stored aileron/elevator/rudder trims
are +26/-26/0 (displayed as +20%/-20%/0% at standard range). The flight-timer
recipe uses a stopped, persistent countdown named Flight with 3:04 remaining
of a 5:00 start.

The isolated widget copy verifies recipe values through real services and waits
for populated panel presentation before capture. Trim, timer, flight mode,
and model identity use actual isolated firmware model settings. Other panels use
**real EdgeTX rendering with synthetic sample data**: capture-only firmware API
overrides are passed into the real service environment in the isolated widget.
Telemetry resolution, precision scanning, battery calculations, link
classification, and GPS distance/bearing calculations still run in the real
services and panels. These images demonstrate presentation, not receiver
telemetry validity. Production widget files and APIs on your radio or active
simulator are not changed.

| Recipe | Baseline sample |
| --- | --- |
| `metric` | ALTITUDE 128 m, MAX 176 m, VS 2.4 m/s (synthetic maximum vertical speed). |
| `flight-timer` | Flight countdown, 3:04 remaining of 5:00. |
| `flight-counter` | Active count 42 and IN-FLIGHT badge, with synthetic armed/motor/link inputs and real isolated GV9 persistence. |
| `flight-mode` | Active mode 0 named ACRO. |
| `tx-battery` | 7.9 V, explicitly calibrated to 6.4-8.4 V; percentage disabled because 2x1 does not support it. |
| `trim-panel` | Stored aileron/elevator/rudder +26/-26/0. |
| `model-identity` | Crack Yak, with the user-supplied `crackyak.png` model image; redistribution permission confirmed by the contributor. |
| `cell-battery` | RX BATTERY: four cells at 3.91/3.89/3.92/3.90 V; lowest-cell headline. |
| `link-status` | Synthetic live ELRS link: 98% quality, -87 dBm RSSI, RFMD 6, 8 dB SNR, 100 mW power. |
| `navigation` | Fixed model/home coordinates producing approximately 318 m distance and 046-degree bearing. |

Native crop dimensions are
117 x 134, 238 x 65, and 238 x 134 pixels respectively. Each panel PNG adds a
10-pixel black border on every side without scaling or covering panel pixels,
giving output sizes of 137 x 154, 258 x 85, and 258 x 154.
Provenance includes the
simulator library digest, widget and capture-tool hashes, synthetic-input
disclosure, settings, and crop geometry.

The native runner stops firmware tasks after capture or its readiness timeout.
Failures are explicit and point to the simulator log; failed captures do not
publish documentation assets. Existing simulator SD images are not modified.
The capture tool runs locally on macOS; it is not part of CI.

### Configure a capture

Named recipes live in `tools/capture-recipes/*.yaml`. Copy one to create another
example, edit it, and select it explicitly:

```sh
build/capture-venv/bin/python tools/capture-panels.py --recipe /path/to/example.yaml
```

`--panel` selects that panel's bundled default recipe; `--all` selects
all YAML recipes in the bundled directory. These options are mutually exclusive.
Each run saves the selected recipe alongside its images and provenance.

Recipes configure `panel`, `theme` (`modern` or `edgetx`), `border.pixels`,
`border.rgb`, named `panels` placements, panel `config` settings, and `sample`
values. `config` also accepts nested metric lists. Positions are zero-based in the
4 x 4 grid. Panel names are used in image
filenames; a span-shaped name such as `2x2` must match the placement's span.
Placements must not overlap. Captures support row spans of 1 or 2.

Baseline captures omit bottom progress bars: metric and link-status use
`config.visual: none`. The timer recipe uses `hide_bottom_bar: true`, a
capture-only presentation override that hides the existing bar without reflowing
the panel. This is not a production timer setting. Battery glyphs and trim
indicators remain visible.

Bundled recipes also set `brighten_supporting_text: true`: the isolated theme's
`textFaint` changes from `#69737A` to `#A7B0B6` for readability on computer
displays. This is a capture-only color override, recorded in the saved recipe
and provenance; fonts, geometry, and production radio colors are unchanged.
Documentation using these images should disclose the brighter supporting text.
Set it to `false` or omit it to capture the exact production palette.

The flight-counter recipe uses the exact production palette, one-second
qualification, and no history or audio. Synthetic SF and CH3 readings stay at
`+1024` with RSSI `80`. Its three gallery instances each qualify once against real
GV9 FM0, initialized to `sample.count - 3`; readiness requires the final shared
count and active `IN-FLIGHT` presentation in every span. This isolated screenshot
fixture is not a supported multi-tracker layout: install only one tracker per
model. `sample.count` sets the final displayed total.

For example, a timer recipe can change its sample without code edits:

```yaml
sample:
  name: Flight
  start_seconds: 600
  remaining_seconds: 123
```

The fixture then supplies 2:03 remaining of 10:00 and readiness checks those
same values. `config.timer` selects index 0, 1, or 2; the fixture keeps it stopped.
Trim recipes configure signed stored `aileron`, `elevator`, and `rudder` values,
and currently require the axes presentation with the default axis sources.
Other trim presentations need an adapter extension, not just a YAML change.

Flight-mode and model-identity recipes set `sample.name` (at most 10 printable
ASCII characters). Model identity accepts `sample.bitmap`, a PNG path relative
to the recipe with a firmware-safe basename. The bundled example uses the
user-supplied `tools/capture-assets/crackyak.png`; its digest is recorded in
provenance. The contributor confirmed permission to redistribute this image in
the documentation. Establish redistribution permission for any replacement image.
Omitting `sample.bitmap` uses the original generated aircraft silhouette.
TX battery sets `sample.voltage`
and explicitly configures `packEmpty` and `packFull`.

Metric, cell-battery, link-status, and navigation recipes define
`sample.sources`: a mapping from exact source names to `value`, EdgeTX `unit`
code, and `precision`. Numeric sources have numeric values; cells use a voltage
list with unit 38; GPS uses a coordinate mapping with unit 40 (`lat`, `lon`,
`pilot-lat`, `pilot-lon`, and `delay`). `sample.rssi` provides a fixed positive
link indicator. Every configured source needs a sample; the readiness check
verifies values and precision before emitting images. See the bundled recipes
for complete examples.

Recipe structure, sample ranges, and placements are checked before startup.
The actual widget validates panel settings during loading; invalid settings
fail capture and leave diagnostic logs rather than publishing an image.

`tools/capture_recipes.py` holds each panel's model setup and Lua readiness
adapters, deriving both from the recipe sample. `capture-panels.py` handles shared fixture
preparation, simulator invocation, cropping, borders, and provenance. The native
runner reads capture regions generated by Python rather than hardcoding panel
positions.
Run recipe tests with `build/capture-venv/bin/python -m unittest discover -s tools -p 'test_capture_*.py'`.

### Publish generated examples

Panel reference pages use checked-in PNGs under
`docs/assets/panels/<panel>/<span>.png`. After regeneration and visual
review, copy only `1x2.png`, `2x1.png`, and `2x2.png` from each panel's build
directory into that panel's asset directory, then run `make docs`.
Keep SD images, framebuffer dumps, logs, and full frames in ignored build output.
Normal documentation builds use the checked-in images without the simulator.

The example captions disclose synthetic inputs and capture-only presentation
overrides. Update those captions when changing a recipe's sample or settings.

## Continuous integration

### Publishing a release

Releases are manually initiated, not created on every merge. Update
`src/WIDGETS/AeroGrid/lib/package.lua` in a PR and merge it into `main`.
Versions must be `X.Y.Z`, `X.Y.Z-beta.N`, or `X.Y.Z-rc.N`; beta and release-candidate
versions are published as prereleases.

In GitHub, open **Actions > Release > Run workflow**, select **main**, and run.
The workflow uses the exact commit selected when the run starts, executes the
existing CI checks, validates documentation and packaging, then creates the
matching `v<version>` tag. It uploads `AeroGrid-<version>.zip` and its SHA-256
checksum to a draft and publishes only after both uploads succeed.
Generated release notes include installation links and hardware coverage.
No release has to be created manually in the Releases UI.

`make release-package` builds the same deterministic archive locally in
`build/release/`. It contains source Lua files, only `default` and `host` layouts,
and the license. It never packages a simulator SD image, bytecode, or capture
assets. The layout allowlist is defined in `tools/package-release.py`.

If validation fails, fix and merge before running again. If publishing fails
after creating the tag or draft, rerun the **same workflow run** against the same
commit: a matching tag and draft can be resumed, replacing incomplete assets.
A tag pointing to another commit or an already public release is rejected.
Do not move a published tag; fixes require a new package version. A changed
commit cannot reuse a version whose tag already exists. If abandoning an
unpublished attempt, explicitly remove its draft and tag before retrying that
version. Release runs are serialized and are not cancelled by newer requests.
The write token is scoped to the publishing job; validation uses read access.

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`. It installs Lua 5.3, runs `make check` (the behaviour suites in both string modes, then parses every Lua file with `luac5.3`), builds the SD image, and verifies the packaged image matches its sources and that the build leaves no untracked output.

The Lua 5.3 parse is the part that cannot be reproduced locally on every machine: the test suites execute under whichever Lua `lupa` provides, so CI is what actually validates the sources against the language version the radio runs.

## Simulator fixture convention

`tests/fixtures/sdcard/` is version-controlled test and development input. Keep only deterministic files required to reproduce simulator startup there:

```text
tests/fixtures/sdcard/
├── MODELS/
│   ├── labels.yml
│   └── model1.yml
└── RADIO/
    └── radio.yml
```

Do not check generated `.luac` files, logs, screenshots, or mutable `build/sdcard/` state into source control. When a deliberate model or radio configuration change should become the new baseline, update the corresponding fixture file explicitly and verify a clean `make build` before committing it.

Pure module tests live under `tests/unit/`. Tests that exercise the AeroGrid host through mocked EdgeTX APIs live under `tests/integration/`. `tests/run.py` executes both groups in normal Lua mode and with method-style string lookup disabled to match EdgeTX firmware behavior.

See [plans/aerogrid-spec.md](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md) for the complete project specification.
