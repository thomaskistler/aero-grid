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

Each widget instance has a native **Dashboard ID** setting (`DashID` in Lua). AeroGrid combines that value with `model.getInfo().filename` and loads:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

If that file does not exist, AeroGrid loads `/WIDGETS/AeroGrid/layouts/default.yaml`.

Phase one never writes layout files.

## EdgeTX Dev Kit simulator

Open the repository folder in VS Code. The repository includes a TX16S/EdgeTX 2.12 profile. Set **EdgeTX: SD Card Path** to the absolute path of the ignored `build/sdcard/` directory in your checkout.

1. Run `make build` or the **AeroGrid: Build Simulator SD** task once to create the complete image.
2. Open `src/WIDGETS/AeroGrid/main.lua`.
3. Run **EdgeTX: Toggle EdgeTX Mode** if EdgeTX mode is not already active.
4. Run **EdgeTX: Simulate Script** (`Cmd+Alt+S`) or **EdgeTX: Watch Script** (`Cmd+Alt+W`).
5. Open **Logs** in the simulator when the dashboard reports an error.

The build starts from the tracked baseline in `simulator/sdcard/`, then overlays the current `src/WIDGETS/AeroGrid/` sources. The baseline contains the fixed radio and model configuration needed to boot directly into AeroGrid. The generated `build/sdcard/` image is ignored and may be changed by the simulator. Run `make build` again after source changes or whenever you want to reset the image to the checked-in baseline.

## Development

Runtime modules target EdgeTX's Lua 5.3 environment. The Makefile provides the standard development entry points:

```sh
make setup
make test
make check LUA_COMPILER=/path/to/edgetx-luac
```

`make setup` installs development-only Python dependencies under ignored `build/venv/`. `make check` runs the behavior tests and parses every Lua file with `edgetx-luac`, `luac5.3`, or `luac` when one is on `PATH`; `LUA_COMPILER` overrides detection.

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, layout-path sanitization, component loading, zone reflow, and Dashboard ID reload behavior. Each Lua behavior suite runs once with normal string methods and once with the string metatable removed to match EdgeTX firmware behavior.

## Simulator fixture convention

`simulator/sdcard/` is version-controlled test and development input. Keep only deterministic files required to reproduce simulator startup there:

```text
simulator/sdcard/
├── MODELS/
│   ├── labels.yml
│   └── model1.yml
└── RADIO/
	└── radio.yml
```

Do not check generated `.luac` files, logs, screenshots, or mutable `build/sdcard/` state into source control. When a deliberate model or radio configuration change should become the new baseline, update the corresponding fixture file explicitly and verify a clean `make build` before committing it.

See [plans/aerogrid-spec.md](plans/aerogrid-spec.md) for the complete project specification and implementation milestones.