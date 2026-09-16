# AeroGrid

A configurable 4 x 4 glass-cockpit dashboard for EdgeTX color radios.

## Current checkpoint

The phase-one runtime currently provides:

- One EdgeTX LVGL host widget.
- A responsive 4 x 4 grid with multi-cell spans and gutters.
- A constrained, read-only YAML parser and layout validator.
- Per-model and per-screen layout selection through `Dashboard ID`.
- Dynamically loaded component modules with API-version checks.
- A placeholder component used to validate nested LVGL layout behavior.

The on-radio editor and production telemetry components are intentionally not part of this checkpoint.

## Install on an SD card

Copy `src/WIDGETS/AeroGrid/` into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode screen. The ordinary `1 x 1` layout is also supported.

Each widget instance has two native settings: **Dashboard ID** (`DashID` in Lua) and **Theme**. AeroGrid combines the Dashboard ID with `model.getInfo().filename` and loads:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

If that file does not exist, AeroGrid loads `/WIDGETS/AeroGrid/layouts/default.yaml`.

Changing either setting rebuilds the dashboard safely. Phase one never writes layout files.

## EdgeTX Dev Kit simulator

Open the repository folder in VS Code. The repository includes a TX16S/EdgeTX 2.12 profile. Set **EdgeTX: SD Card Path** to the absolute path of the ignored `build/sdcard/` directory in your checkout.

1. Run `make build` or the **AeroGrid: Build Simulator SD** task once to create the complete image.
2. Open `src/WIDGETS/AeroGrid/main.lua`.
3. Run **EdgeTX: Toggle EdgeTX Mode** if EdgeTX mode is not already active.
4. Run **EdgeTX: Simulate Script** (`Cmd+Alt+S`) or **EdgeTX: Watch Script** (`Cmd+Alt+W`).
5. Open **Logs** in the simulator when the dashboard reports an error.

The build starts from the tracked baseline in `tests/fixtures/sdcard/`, then overlays the current `src/WIDGETS/AeroGrid/` sources. The baseline contains the fixed radio and model configuration needed to boot directly into AeroGrid. The generated `build/sdcard/` image is ignored and may be changed by the simulator. Run `make build` again after source changes or whenever you want to reset the image to the checked-in baseline.

## Development

Runtime modules target EdgeTX's Lua 5.3 environment.

### Make targets

| Target | Purpose |
| --- | --- |
| `make help` | List the supported Make targets. |
| `make setup` | Create `build/venv` and install `requirements-dev.txt`. |
| `make test` | Run unit and mocked EdgeTX integration suites in normal and firmware-like string modes. |
| `make check` | Run `make test`, then parse every source and test Lua file with an EdgeTX/Lua compiler. |
| `make build` | Recreate `build/sdcard` from `tests/fixtures/sdcard`, then overlay `src/WIDGETS/AeroGrid`. |
| `make clean` | Remove all generated `build/` output, including the virtual environment and simulator SD image. |

Typical workflow:

```sh
make setup
make test
make check LUA_COMPILER=/path/to/edgetx-luac
make build
```

`make test` and `make check` run `make setup` automatically when the development environment is missing or `requirements-dev.txt` changed. `make check` looks for `edgetx-luac`, `luac5.3`, then `luac` on `PATH`; `LUA_COMPILER` overrides detection. Use EdgeTX's `edgetx-luac` when available because it validates the firmware's exact Lua 5.3 configuration.

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, malformed and corrupt layout handling, forward-compatible unknown keys, layout-path sanitization across real model filenames, the component module contract, declared settings and spans, component lifecycle failure isolation, hostile modules, theme derivation and legibility, component states, zone reflow, and Dashboard ID reload behavior. Each Lua behavior suite runs once with normal string methods and once with the string metatable removed to match EdgeTX firmware behavior.

## Components

AeroGrid loads each component from `src/WIDGETS/AeroGrid/components/<type>.lua`, where `<type>` is the `type` named in the layout YAML. The host creates one LVGL container per placement, so a component receives container-local coordinates and cannot draw over its neighbours.

| Component | Purpose |
| --- | --- |
| `metric` | Reference telemetry metric with thresholds, states, and `1 x 1`, `2 x 1`, and `2 x 2` presentations. |
| `placeholder` | Verifies placement and resizing at any span. |
| `heartbeat` | Verifies the lifecycle callbacks and span restrictions. |

See the component module contract in [plans/aerogrid-spec.md](plans/aerogrid-spec.md) for the fields a component declares and the services it receives.

### Demo readings

Telemetry services arrive in milestone 5, so `metric` accepts a temporary `demo: true` setting that drives synthetic readings through every state: normal, warning, critical, stale, and unavailable. The shipped `layouts/default.yaml` enables it so the design system can be reviewed on a radio. Remove the setting once real telemetry exists.

## Theming

The host owns every color; components never define palettes. Three modes are available through the native **Theme** widget option or a layout's optional `theme` block, which takes precedence:

| Mode | Behavior |
| --- | --- |
| `modern` | The designed dark instrument palette. Used verbatim. |
| `edgetx` | Derives tokens from the radio's active EdgeTX theme via `lcd.getColor()`. |
| `custom` | Modern plus a limited override set: `canvas`, `surface`, `text`, and `accent`. |

Both derived modes pass through a legibility pass that enforces minimum contrast for text, panel elevation, borders, and every semantic accent, so a hostile or pale source theme cannot produce an unreadable dashboard. Critical red is never theme-derived, and AeroGrid never calls `lcd.setColor()`.

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

See [plans/aerogrid-spec.md](plans/aerogrid-spec.md) for the complete project specification and implementation milestones.