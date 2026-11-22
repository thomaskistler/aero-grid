# Project tools

Native capture tools create documentation images from Companion's TX16S
simulator library. They use isolated widget/SD copies, not `src/` or the active
development image. Outputs stay in ignored `build/` directories until reviewed.
For recordings and narration, see [Tutorial videos](videos.md).

## Capture documentation images with native firmware

Requirements: **macOS**, EdgeTX Companion 2.12, and Xcode command-line tools
(`clang++`, `lipo`). The simulator library must be single-architecture;
Intel firmware on Apple Silicon needs Rosetta. The default application is
`/Applications/EdgeTX Companion 2.12.app`; override it with
`--companion "/path/to/Companion.app"`. These tools do not run in CI.

### Panel screenshots

```sh
make capture-setup
build/capture-venv/bin/python tools/capture-panels.py --panel trim-panel
build/capture-venv/bin/python tools/capture-panels.py --all
```

Select one of `--panel <type>`, `--recipe <path>`, or `--all`.
The setup target installs pinned PyYAML. Bundled recipes cover user-facing
panels and Host diagnostics.

Outputs go to `build/doc-capture/<panel>/`: gallery crops, `full-frame.png`,
`frame.rgb565`, `recipe.yaml`, `provenance.json`, `sdcard/`, and `simulator.log`.
Regeneration replaces that panel's output. `--all` runs sequentially; failure
keeps diagnostics and any completed panels, but never publishes assets.

Defaults are 480 x 272, Modern Dark, App mode, unscaled crops, and a 10-pixel
border. Recipes control samples and readiness checks. Synthetic inputs pass
through real services/panels; the images show firmware rendering, not receiver
telemetry validation.

### Change a capture recipe

Copy a recipe from `tools/capture-recipes/` and run it explicitly:

```sh
build/capture-venv/bin/python tools/capture-panels.py --recipe /path/to/example.yaml
```

Recipes specify `panel`, `theme`, `border`, named `panels` placements/config,
and `sample`. Placements are zero-based in the 4 x 4 grid, cannot overlap, and
have row spans of 1 or 2. Span-shaped image names must match their dimensions.
Use bundled recipes for supported sample fields, sensor units, and precision;
every configured source needs a sample.

`tools/capture_recipes.py` owns validation, model setup, input adapters, and
readiness. `capture-panels.py` prepares, captures, crops, and records provenance.
Add adapters here, not capture-specific behavior in production modules.

Variants under `tools/capture-recipes/variants/` require `--recipe`.
The Host diagnostics scheduler variant accepts uncropped `companions` panels;
publish its crop/provenance as `scheduler-2x2.png` and
`scheduler-provenance.json`.

Disclose capture-only presentation changes, notably
`brighten_supporting_text: true` and the timer's `hide_bottom_bar: true`.
Production `config.visual: none` is not a capture override.
Model-image paths are recipe-relative and need firmware-safe PNG names;
verify redistribution rights before publishing.

Capture hooks patch only isolated copies: synthetic panel inputs enter through
`dashboard_loader.lua`, editor activation uses
`context.editorController.openEditor`, and readiness wraps the refresh export.
Keep those hooks aligned with runtime boundaries.
Run [capture tests](testing.md#python-tooling-tests) and inspect frames/provenance.

### Editor and setup screenshots

```sh
build/capture-venv/bin/python tools/capture-editor.py --scene select-layout
build/capture-venv/bin/python tools/capture-editor.py --scene chart-settings
build/capture-venv/bin/python tools/capture-editor.py --scene navigation-location
```

Use `--help` for scene names. Omitting `--scene` captures the default editor/setup
set; dashboard, theme, and model-menu scenes are opt-in. Panel drawers use the
capture recipes and need `make capture-setup`. Inputs use native touch/key
actions or production editor commands in the isolated copy.

Each scene writes its PNG, SD card, framebuffer, and log under
`build/editor-capture/<scene>/`. Selected directories are replaced; the root
`provenance.json` describes only that invocation.

Tall settings drawers are stitched from captures with leading rows hidden in
the isolated copy, not scrolled screenshots. The tool removes the scrollbar;
review the resulting image before publication. `navigation-location` captures
the location overlay and its frozen QR code.

### Full dashboard screenshot

```sh
build/capture-venv/bin/python tools/capture-editor.py --scene dashboard
```

This captures the full display with **Default** and **Modern Dark**, without
color/presentation overrides or an open editor. It uses fixture model data and
synthetic telemetry through real services. Readiness checks cover all nine
panels and their primary readings. Outputs are under
`build/editor-capture/dashboard/`, with inputs/hashes in the root provenance.

Theme samples use `--scene theme-modern-dark`, `theme-modern-light`, or
`theme-custom`; panel recipes also accept `theme: modern-light`.

Flight debrief scenes are `debrief-settings`, `debrief-tile`, `debrief-ready`,
and `debrief-view`. The last two fly a scripted flight of about 45 seconds
through real services, so each takes over a minute.

### Publish reviewed images

Review the full frame, crops, sample disclosures, and provenance, then copy
only intended PNGs and matching provenance:

| Asset | Destination |
| --- | --- |
| Panel galleries | `docs/assets/panels/<panel>/` |
| Editor/setup captures | `docs/assets/editor/` |
| Full dashboard shared by README/home | `docs/assets/dashboard/` |
| Theme samples | `docs/assets/theme/` |

Keep captions consistent with synthetic inputs and overrides. Do not use
single-scene provenance to describe unrelated captures. Leave SD cards, logs,
raw frames, and incidental images in `build/`. Run `make docs` after publishing.

## Package a release deterministically

See [Build an installable package](build.md#build-an-installable-package) for
the command and contents. `tools/package-release.py` enforces explicit runtime
allowlists, required layouts/assets, and symlink rejection.
Use `--version-only` to print the version or `--output <directory>` to relocate
the ZIP/checksum. Run the
[packaging tests](testing.md#python-tooling-tests) when changing it.
