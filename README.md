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

Copy `WIDGETS/AeroGrid/` into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode screen. The ordinary `1 x 1` layout is also supported.

Each widget instance has a native **Dashboard ID** setting (`DashID` in Lua). AeroGrid combines that value with `model.getInfo().filename` and loads:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

If that file does not exist, AeroGrid loads `/WIDGETS/AeroGrid/layouts/default.yaml`.

Phase one never writes layout files.

## EdgeTX Dev Kit simulator

Open the repository folder in VS Code. The repository includes a TX16S/EdgeTX 2.12 profile. Set **EdgeTX: SD Card Path** to the absolute path of the ignored `build/sdcard/` directory in your checkout.

1. Run the **AeroGrid: Sync Simulator SD** task.
2. Open `WIDGETS/AeroGrid/main.lua`.
3. Run **EdgeTX: Toggle EdgeTX Mode** if EdgeTX mode is not already active.
4. Run **EdgeTX: Simulate Script** (`Cmd+Alt+S`) or **EdgeTX: Watch Script** (`Cmd+Alt+W`).
5. Open **Logs** in the simulator when the dashboard reports an error.

The sync task copies the complete multi-file widget into `build/sdcard/WIDGETS/AeroGrid/`. This is required because the Dev Kit's Simulate Script command deploys only the active `main.lua` file.

## Development

Runtime modules target EdgeTX's Lua 5.3 environment. Pure runtime and mocked-widget tests can be executed through Python:

```sh
python3 -m pip install -r requirements-dev.txt
python3 tests/run.py
```

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, layout-path sanitization, component loading, zone reflow, and Dashboard ID reload behavior.

See [plans/aerogrid-spec.md](plans/aerogrid-spec.md) for the complete project specification and implementation milestones.