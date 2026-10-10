# Project tools

These tools exist to make AeroGrid development reproducible. They do not run
on the radio, and their generated output belongs in ignored `build/`
directories unless you deliberately publish reviewed documentation assets.

## Capture documentation images with native firmware

The capture tools load Companion's native TX16S simulator library directly
through `tools/capture-native.cpp`. They create isolated SD images and widget
copies; they do not modify `src/` or your active `build/sdcard/`.
VS Code is not involved.

Requirements are **macOS**, EdgeTX Companion 2.12, and Xcode command-line
tools (`clang++` and `lipo`). The tools require a single-architecture TX16S
simulator library; an Intel library on Apple Silicon needs Rosetta.
The default application path is `/Applications/EdgeTX Companion 2.12.app`;
pass `--companion "/path/to/Companion.app"` to choose another installation.
These tools are local-only and do not run in CI.

### Panel screenshots

```sh
make capture-setup
build/capture-venv/bin/python tools/capture-panels.py --panel trim-panel
build/capture-venv/bin/python tools/capture-panels.py --all
```

Choose **one** of `--panel <type>`, `--recipe <path>`, or `--all`.
`make capture-setup` installs pinned PyYAML in a separate environment.
All eleven user-facing panel types have bundled recipes.

Each panel writes to `build/doc-capture/<panel>/`:

| Output | Purpose |
| --- | --- |
| `1x2.png`, `2x1.png`, `2x2.png` | Gallery crops with recipe-defined borders. |
| `full-frame.png`, `frame.rgb565` | Full display and raw framebuffer for inspection. |
| `recipe.yaml`, `provenance.json` | Exact inputs, geometry, source/tool hashes, simulator digest, and disclosures. |
| `sdcard/`, `simulator.log` | Isolated fixture and diagnostics. |

Regenerating a panel **replaces its previous output directory**; there is no
run history. `--all` runs recipes sequentially, so a failure leaves earlier
successful panels updated. A failed run keeps diagnostics, raises an error,
and does not publish documentation assets.

Default panel captures use a 480 x 272 Modern Dark/App-mode dashboard with
placements outside the menu overlay. Crops are unscaled; a 10-pixel border
gives output dimensions of 137 x 154, 258 x 85, and 258 x 154 respectively.
Recipes can override the border.

The runner waits for recipe-specific readiness, not just a fixed delay.
Timer, trim, flight-mode, and model-image samples use isolated firmware model
settings. Other recipes use capture-only firmware API inputs passed through
the **real services and panels**. They demonstrate actual EdgeTX rendering,
not the correctness of a receiver's telemetry.

### Change a capture recipe

Recipes live in `tools/capture-recipes/*.yaml`. Copy an existing recipe to an
untracked experiment location and select it explicitly:

```sh
build/capture-venv/bin/python tools/capture-panels.py --recipe /path/to/example.yaml
```

The recipe specifies `panel`, `theme`, `border`, named `panels` placements,
each placement's `config`, and `sample` inputs. Positions are zero-based in
the 4 x 4 grid and must not overlap. Row spans are currently limited to 1 or
2; span-shaped image names must match the placement's dimensions.
Validation runs before startup, then the widget validates panel settings.

Use the bundled recipe for the exact sample schema. Examples include timer
name/start/remaining seconds, signed stored trim values, TX voltage, and
`sample.sources` with exact sensor names, values, EdgeTX units, and precision.
Cells use a voltage list; GPS uses coordinates including pilot position.
Every configured source needs a sample.

`tools/capture_recipes.py` owns recipe validation, model setup, synthetic
inputs, and readiness adapters. `capture-panels.py` handles preparation,
native invocation, cropping, borders, and provenance. Add an adapter, not
production panel logic, when a new sample type needs capture support.

Be explicit about capture-only differences:

- `brighten_supporting_text: true` uses the resolved muted color for faint text
  (`#C4CDD3` to `#DCE2E6` in Modern Dark) for computer readability; omit it or set false
  for production colors.
- The timer's `hide_bottom_bar: true` hides its bar without reflow. It is not
  a supported production setting.
- Metric/link-status examples can omit visuals through `config.visual: none`.
  This is a production setting, not evidence that all presentations were tested.
- The flight-counter gallery uses three isolated trackers to reach its sample
  count through real GV9 FM0 persistence. This is screenshot scaffolding,
  **not a supported multi-tracker installation**.

Model images resolve relative to the recipe and need a firmware-safe PNG name.
Establish redistribution permission before publishing a replacement image;
the bundled Crack Yak image's permission was confirmed by its contributor.

Run the [capture-recipe tests](testing.md#python-tooling-tests) after changing
recipes/adapters, then inspect the resulting frame and provenance.

### Editor and setup screenshots

```sh
python3 tools/capture-editor.py
python3 tools/capture-editor.py --scene select-layout
```

This tool uses only Python's standard library plus the same native capture
runner. It covers setup/widget/layout choices, editor overview, metric/text
settings, entry dialogs, exit, and Save As. Use `--help` for supported scene
names.

It also captures the telemetry-free **Theme** showcase with real production
primitives. These scenes are opt-in and do not open the editor:

```sh
python3 tools/capture-editor.py --scene theme-modern-dark
python3 tools/capture-editor.py --scene theme-modern-light
python3 tools/capture-editor.py --scene theme-custom
```

The custom scene uses a fixed blue-gray palette with warm text and green
default accents. To experiment interactively, add a `.yml` file in the user
theme directory described
in [Customize themes](../user-guide/dashboards.md#customize-themes).
Panel recipes also accept `theme: modern-light` for checking individual
instruments in the built-in light palette.

Each selected scene writes a PNG, isolated SD card, framebuffer, and log
under `build/editor-capture/<scene>/`. The root `provenance.json` records
the selected scenes and source/simulator hashes. Selected scene directories
are replaced on regeneration, and the root provenance describes the current
invocation, not a merged history of earlier runs.

Setup scenes automate native touch input. Editor scenes enter fullscreen
through a native long-press and automate production editor commands in the
isolated copy. Check images manually: capture success is not a replacement
for interactive editor/persistence tests.

### Publish reviewed images

Panel reference images live in `docs/assets/panels/<panel>/`.
After reviewing the full frame, crops, and provenance, copy only the intended
gallery PNGs there. Update the reference-page captions if samples,
synthetic inputs, or presentation overrides changed.

Editor images live in `docs/assets/editor/`. Copy the selected PNGs and the
corresponding provenance, taking care not to describe images from several
runs with a provenance file for only one scene.

Keep SD images, raw framebuffers, logs, and incidental full frames in ignored
output. Run `make docs` after publishing assets. Website builds use the
checked-in images and need neither Companion nor capture dependencies.

## Package a release deterministically

```sh
make release-package
python3 tools/package-release.py --version-only
python3 -m unittest discover -s tools -p 'test_release_*.py'
```

`tools/package-release.py` reads the package version, checks required
layouts/assets, rejects unexpected runtime files and symlinks, and writes
a deterministic source-only ZIP plus SHA-256 checksum. Its explicit allowlists
include `Default`, `Empty`, `Host`, and `Theme`, excluding review layouts and mutable
simulator data. Use `--output <directory>` to choose another output location.

See [Issues, changes, and releases](contributing.md#publish-a-release)
for publishing; making a local ZIP does not tag or upload anything.
