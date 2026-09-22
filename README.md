# AeroGrid

A configurable 4 x 4 glass-cockpit dashboard for EdgeTX color radios.

## Current checkpoint

The phase-one runtime currently provides:

- One EdgeTX LVGL host widget.
- A responsive 4 x 4 grid with multi-cell spans and gutters.
- A constrained, read-only YAML parser and layout validator.
- Per-model and per-screen layout selection through `Dashboard ID`.
- Dynamically loaded component modules with API-version checks.
- Five shared data services covering telemetry, model, control, extrema, and navigation.
- The complete ten-component catalogue, configured entirely from YAML.
- Diagnostic views that print each service's normalized output.
- Several independent dashboards on one radio, selected per screen by Dashboard ID.
- Panels that lay out around EdgeTX's App mode menu button instead of underneath it.

The status rail and the on-radio editor are intentionally not part of this checkpoint. The rail is deferred rather than planned: EdgeTX's own top bar is already a configurable widget rail that reserves the same corner and costs nothing against the Lua instruction budget.

## Install on an SD card

Copy `src/WIDGETS/AeroGrid/` into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode screen. The ordinary `1 x 1` layout is also supported.

Each widget instance has two native settings: **Dashboard ID** (`DashID` in Lua) and **Theme**. AeroGrid combines the Dashboard ID with `model.getInfo().filename` and loads:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

If that file does not exist, AeroGrid tries `/WIDGETS/AeroGrid/layouts/<dashboard-id>.yaml`, which is shared by every model, and finally `/WIDGETS/AeroGrid/layouts/default.yaml`.

Changing either setting rebuilds the dashboard safely. Phase one never writes layout files.

Use a different Dashboard ID on each custom screen to run several independent dashboards for one model. Each instance renders exactly one layout; paging between them is EdgeTX sliding between its own screens, not anything AeroGrid does. Changing model reloads whatever the new model's files select, because EdgeTX destroys and rebuilds every widget around a model change.

### App mode and the EdgeTX menu button

In App mode EdgeTX draws its menu button over the top-left corner of the screen, above everything the widget draws. It cannot be hidden, because in App mode it is the only route to the radio's menus. It is 47 x 45 pixels on a 480 x 272 display.

AeroGrid lays the affected panel out around it: the header label moves to the right of the button and the panel's content starts below it. Everything else keeps the geometry it would have had, and no grid area is surrendered.

One case cannot be rescued. In a top-left `1 x 1` cell the button covers 40% of the width and 69% of the height, so the panel keeps its reading, pushed below the button, but drops its header label. Give the top-left cell of an App mode layout a span of at least `2 x 2`, or place something there whose label does not matter.

The ordinary `1 x 1` layout is unaffected either way: with a top bar the widget sits below the button, and without one the button is not drawn.

## EdgeTX Dev Kit simulator

Open the repository folder in VS Code. The repository includes a TX16S/EdgeTX 2.12 profile. Set **EdgeTX: SD Card Path** to the absolute path of the ignored `build/sdcard/` directory in your checkout.

1. Run `make build` or the **AeroGrid: Build Simulator SD** task once to create the complete image.
2. Open `src/WIDGETS/AeroGrid/main.lua`.
3. Run **EdgeTX: Toggle EdgeTX Mode** if EdgeTX mode is not already active.
4. Run **EdgeTX: Simulate Script** (`Cmd+Alt+S`) or **EdgeTX: Watch Script** (`Cmd+Alt+W`).
5. Open **Logs** in the simulator when the dashboard reports an error.

The build starts from the tracked baseline in `tests/fixtures/sdcard/`, then overlays the current `src/WIDGETS/AeroGrid/` sources. The baseline contains the fixed radio and model configuration needed to boot directly into AeroGrid. The generated `build/sdcard/` image is ignored and may be changed by the simulator. Run `make build` again after source changes or whenever you want to reset the image to the checked-in baseline.

### Stale bytecode

EdgeTX compiles each script to a `.luac` beside it on the SD card and then prefers the bytecode. `rsync` preserves source timestamps, so a freshly copied `.lua` can look older than bytecode the radio compiled from the previous build, and the radio keeps running code that is no longer on disk. The symptom is a fix that visibly does nothing, including error messages citing line numbers that no longer exist in the source.

`make build` therefore deletes every `.luac` from the image and stamps the sources as new. If you copy an image somewhere by hand, do the same.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`. It installs Lua 5.3, runs `make check` (the behaviour suites in both string modes, then parses every Lua file with `luac5.3`), builds the SD image, and verifies the packaged image matches its sources and that the build leaves no untracked output.

The Lua 5.3 parse is the part that cannot be reproduced locally on every machine: the test suites execute under whichever Lua `lupa` provides, so CI is what actually validates the sources against the language version the radio runs.

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

The tests cover grid rounding, gutters, overlap validation, constrained YAML parsing, malformed and corrupt layout handling, forward-compatible unknown keys, layout-path sanitization across real model filenames, the component module contract, declared settings and spans, component lifecycle failure isolation, hostile modules, theme derivation and legibility, component states, zone reflow, Dashboard ID reload behavior, snapshot immutability, service scheduling and subscription caps, telemetry freshness against a dropped link and a valid zero, trim scaling, global variable bounds, arm-switch flight sessions, GPS distance and bearing, graceful degradation when a firmware API or a whole service module is missing, metric preset resolution, timer count-up and expired-countdown semantics, the optional transmitter charge estimate, global variable and bar normalization, trim rounding and three-position handling, model bitmap fallback, width-aware font fitting, cells-table shape validation, protocol-dependent link source selection, a link that drops and returns, a missing GPS fix, an unavailable home position, and a protocol that populates no RSSI sensor at all. Each Lua behavior suite runs once with normal string methods and once with the string metatable removed to match EdgeTX firmware behavior.

## Components

AeroGrid loads each component from `src/WIDGETS/AeroGrid/components/<type>.lua`, where `<type>` is the `type` named in the layout YAML. The host creates one LVGL container per placement, so a component receives container-local coordinates and cannot draw over its neighbours.

| Component | Purpose |
| --- | --- |
| `metric` | Any numeric source, with `custom`, `altitude`, and `speed` presets, thresholds, extrema, and an optional secondary reading. |
| `flight-timer` | One EdgeTX model timer, counting the way the model configured it. |
| `flight-mode` | The active EdgeTX flight mode. |
| `tx-battery` | Transmitter voltage, with an optional configurable charge estimate. |
| `variable-indicator` | A global variable or bounded source as a value, bar, bipolar bar, or radial. |
| `trim-panel` | One, two, or four effective trim positions as centred bipolar bars. |
| `model-identity` | Model name, model bitmap, or both. |
| `cell-battery` | Flight-pack cells: the lowest cell, a usable-range bar, and an optional cell count and pack sum. |
| `link-status` | RSSI and link quality from independently named sources, with an explicit minimum and link freshness. |
| `navigation` | Distance to home, a north-up bearing from home to the model, a compass dial, and coordinates. |
| `service-probe` | Prints one shared service's normalized output as diagnostic rows. |
| `placeholder` | Verifies placement and resizing at any span. |
| `heartbeat` | Verifies the lifecycle callbacks and span restrictions. |

Each component declares the spans it supports and a typed settings schema with labels and defaults, so `layouts/default.yaml` is the only thing that needs editing to rearrange or reconfigure the dashboard. The shipped layout demonstrates ten of the twelve components on one screen; the two diagnostics views have a screen of their own.

Every component degrades rather than raising: a source the radio does not recognize, a timer index that does not exist, a radio without global variables, a firmware without a flight-mode API, a model bitmap that is not on the card, a cells source that answers with the wrong shape, a GPS sensor with no fix, and a link that has dropped each produce a clear state with a text badge, because colour alone is not enough to communicate one.

The three telemetry components exist because these distinctions are easy to get wrong and dangerous to get wrong:

- **A pack is only as good as its worst cell.** `cell-battery` leads with the lowest cell, validates every entry of the cells table before using it, judges its thresholds on that cell even when the panel shows the pack sum, and scales its bar from the critical voltage to full rather than from zero. It estimates no remaining capacity, because voltage under load does not support one.
- **A zero can mean three different things.** `link-status` separates a dead link, a protocol with no RSSI sensor, and a reading that genuinely is zero, reading the distinction from the telemetry service rather than guessing it again. RSSI and link quality are named independently and one is never inferred from the other.
- **A direction needs somewhere to measure from.** `navigation` reports no source, no fix, and no home position as three different states, withholds a bearing rather than resting the dial at north, and says in words that the dial is north-up and measured from home. EdgeTX reports neither aircraft heading nor transmitter orientation, so nothing here may be read as either.

Four things the Lua API will not tell a component are worth knowing before writing another one:

- **Text cannot be measured.** `theme.fitText` estimates width from the font's line height and picks a size from the widest string a component can ever produce, so a reading never resizes as it changes.
- **A trim source carries no axis.** `trim-panel` takes an orientation, with a per-indicator override, instead of guessing from trim names.
- **`lvgl.image` cannot report a failed decode.** `model-identity` checks the file with `fstat` first and falls back to the model name.
- **`lvgl.arc` is positioned by its centre, not its corner.** `LvglWidgetRoundObject::setPos` stores `x - radius`, so every radial written before milestone 7 was drawn a full radius up and to the left of where it was meant to be. `primitives.arcBounds` converts between the two conventions, and the tests assert containment through it.

See the component module contract in [plans/aerogrid-spec.md](plans/aerogrid-spec.md) for the fields a component declares and the services it receives.

## Shared data services

The host polls EdgeTX; components never do. A component subscribes once, in `create`, and keeps the immutable snapshot it is given:

```lua
function example.create(parent, rect, settings, services)
  local telemetry = services.telemetry
  return {feed = telemetry and telemetry:subscribe(settings.source)}
end
```

| Service | Provides |
| --- | --- |
| `telemetry` | Cached source readings with units, precision, and freshness. |
| `model` | Model identity, bitmap path, timers, flight mode, and transmitter voltage. |
| `control` | Effective trim positions and read-only global variables, for the active or a pinned flight mode. |
| `extrema` | EdgeTX sensor extrema and dashboard flight sessions. |
| `navigation` | GPS fix, pilot position, distance, and north-up home-to-model bearing. |

`telemetry:link()` publishes the link itself: whether it is live, the raw `getRSSI()` reading, and whether that indicator can be trusted at all. It is what lets `link-status` tell a dead link from a protocol that populates no RSSI sensor.

Subscribing in `create` is the mechanism, not a convention: a source nothing subscribed to is never read, and a service nothing subscribed to is never scheduled. Two components naming the same source share one poll. Snapshots are read-only views over state the service mutates in place, so they cost no allocation per cycle and cannot be corrupted by the components reading them.

Freshness deserves care. EdgeTX returns integer zero for a telemetry source both when the sensor reads zero and when telemetry is not streaming, so only a zero is ambiguous and only a zero is judged: a non-zero value is always a reading, and a zero is stored only while the link is believed up, otherwise the last live value is kept and marked stale. The link indicator is `getRSSI() > 0`, which reads zero on a live link whose protocol has no RSSI sensor, so the service stops trusting it once a source proves it wrong.

Two limitations remain, and neither is solvable from Lua: staleness is link-wide rather than per sensor, and a sensor that is configured but has never been received reads as a valid zero while the link is up.

Every service degrades rather than raising. A missing firmware API, an unknown source name, a sensor never received, an out-of-range timer, or a GPS source with no fix all produce an `unavailable` snapshot.

### Service diagnostics

Set the widget's **Dashboard ID** to `services` or `services2` to load the bundled diagnostic screens on any model. They print each service's normalized output directly, so a wrong unit, a missing precision, a stale classification, or a bearing taken from the wrong end is visible before any component depends on it.

## Theming

The host owns every color; components never define palettes. Three modes are available through the native **Theme** widget option or a layout's optional `theme` block, which takes precedence:

| Mode | Behavior |
| --- | --- |
| `modern` | The designed dark instrument palette. Used verbatim. |
| `edgetx` | Derives tokens from the radio's active EdgeTX theme via `lcd.getColor()`. |
| `custom` | Modern plus a limited override set: `canvas`, `surface`, `text`, and `accent`. |

Both derived modes pass through a legibility pass that enforces minimum contrast for text, panel elevation, borders, and every semantic accent, so a hostile or pale source theme cannot produce an unreadable dashboard. Critical red is never theme-derived, and AeroGrid never calls `lcd.setColor()`.

## Instruction budget

EdgeTX aborts a widget callback that exceeds 20000 Lua VM instructions with `CPU limit`. AeroGrid therefore loads in stages: `create` only prepares the runtime, and each `refresh` performs one bounded step (a fixed number of lines tokenized, or one component parsed, validated, and built). Zone changes are batched the same way. The dashboard fills in over a few frames instead of blocking a single callback, and a layout that fills the grid costs more callbacks rather than larger ones.

`make test` measures every callback the firmware can invoke, against the largest layout the schema permits, and fails if one exceeds 75% of the budget, printing the worst case:

```text
budget headroom: worst callback trim-panel x16 refresh/reflow used 7800 of 20000
steady state:    worst frame link-status x16 refresh/steady used 2400 of 20000
```

Component callbacks and service updates share this allowance. Per-character string loops are the usual way to exhaust it.

Fourteen sixteen-component layouts are measured: metrics with sixteen distinct live telemetry sources, sixteen diagnostic panels spanning all five services, sixteen components demanding a refresh every frame, and one layout per catalogue component type. Each declares which services it must actually run, and the test fails if one never updated during the sampled frames, so a layout that subscribed to nothing cannot make the service layer measure zero. The test also asserts that every component really was refreshed during the sampled frames, so a scheduling bug cannot make the measurement pass by measuring an idle dashboard.

Services are bounded the same way components are: at most one service is updated per host cycle, services are phase staggered, an unsubscribed service is never scheduled, and each service caps how many subscriptions it refreshes in one update. Removing those caps raises the worst steady frame to 6200.

Because EdgeTX refreshes widgets on every main loop pass, components declare a `refreshInterval` in 10ms ticks rather than being serviced every frame, and components sharing an interval are phase staggered so they fall due on different frames. A per-frame cap bounds the worst case for layouts that defeat staggering.

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