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
can also be run manually from `main`. Component references remain ordinary
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

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, malformed and corrupt layout handling, forward-compatible unknown keys, layout-path sanitization across real model filenames, the component module contract, declared settings and spans, component lifecycle failure isolation, hostile modules, theme derivation and legibility, component states, zone reflow, Dashboard ID reload behavior, snapshot immutability, service scheduling and subscription caps, telemetry freshness against a dropped link and a valid zero, trim scaling, global variable bounds, arm-switch flight sessions, GPS distance and bearing, graceful degradation when a firmware API or a whole service module is missing, metric preset resolution, timer count-up and expired-countdown semantics, the optional transmitter charge estimate, global variable and bar normalization, trim rounding and three-position handling, model bitmap fallback, width-aware font fitting, cells-table shape validation, protocol-dependent link source selection, a link that drops and returns, a missing GPS fix, an unavailable home position, and a protocol that populates no RSSI sensor at all. Each Lua behavior suite runs once with normal string methods and once with the string metatable removed to match EdgeTX firmware behavior.

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

`lib/package.lua` defines the package version and the runtime, component, and
layout API versions. The host rejects incompatible or unversioned runtime modules;
a failed service leaves unrelated panels running. Dashboard ID `host` reports the
loaded version. These checks detect API-incompatible mixtures, not every mixture
of compatible releases or stale bytecode.

## Continuous integration

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

See [plans/aerogrid-spec.md](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md) for the complete project specification and implementation milestones.
