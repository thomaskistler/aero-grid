# Test and debug

Start with the smallest test covering the change. Mocks validate logic,
simulators validate firmware UI, and radios validate hardware behavior;
none replaces the others.

## Run the automated Lua suites

```sh
make test
make check
```

`make test` checks menu artwork and the Python runner, then runs every `test_*.lua` under
`tests/`, excluding support modules. Each suite gets a fresh Lua 5.3 runtime
and the repository root as its chunk argument. The runner stops at the first
failure and prints its captured AeroGrid errors and traceback.

Tests must be ASCII. The runner removes the string metatable to resemble
EdgeTX: use `string.sub(value, ...)`, not `value:sub(...)`.
The desktop runtime does not reproduce radio integer/float widths or native
resource behavior.

`make check` also parses source/test Lua with an EdgeTX or Lua 5.3 compiler.
Install the [validation tools](build.md#install-the-validation-tools), or pass:

```sh
make check LUA_COMPILER=/absolute/path/to/edgetx-luac
```

## Choose the right test layer

| Change | Start here |
| --- | --- |
| Layout parsing, validation, geometry, persistence | Corresponding `tests/unit/lib/` suites. |
| Source resolution or service data | Corresponding service suites in `tests/unit/lib/`. |
| Panel settings/presentation | `tests/unit/panels/` and `tests/integration/widget/test_*_review.lua`. |
| Loading, scheduling, callback budgets | Focused `test_catalog_loading.lua`, `test_host_faults.lua`, `test_callback_budget.lua`, and widget queue/slot suites. |
| Editor commands/dialogs | `test_editor.lua`, `test_editor_ui.lua`, and `test_panel_installation.lua`. |
| Arming, flight detection, model settings, reset | Shared-arming/shared-flight, model-settings, and session-reset suites. |
| Reflow or resource lifetime | Rendered-geometry, all-panel-spans, panel-reflow, font-callback, and resource-stability suites. |

Use `tests/support/runtime_fixture.lua` for runtime helpers without LVGL,
`widget_fixture.lua` for a mocked host, and `edgetx.lua` for firmware behavior
and LVGL inspection. Firmware-dependent mocks require implementation citations;
do not make a mock agree with an unverified assumption.

## Performance and resource regressions

`tests/integration/widget/test_callback_budget.lua` measures callback instructions across
loading, dense layouts, services, and reflow. Its ceiling is below 15,000,
leaving headroom against EdgeTX's 20,000-instruction limit. Focused suites add
their own budgets; these are mock measurements, not hardware timing guarantees.

Resource suites check reload collection, retained Lua memory, LVGL object
counts, sustained output updates, and font callbacks. They do not measure
native bitmap/LVGL memory or firmware GC cadence. Chart tests cover functional
behavior; evaluate responsiveness on a radio.

On macOS with Companion 2.12, measure Model and panel drawer construction:

```sh
python3 tools/measure-model-settings.py
python3 tools/measure-model-settings.py --mode callbacks --output build/model-settings-callbacks.json
python3 tools/measure-panel-settings.py
python3 tools/measure-panel-settings.py --mode callbacks --output build/panel-settings-callbacks.json
```

Reports include per-row grants and native instruction bounds with firmware
property polling. Callback mode includes scheduler/host work and rejects usage
reaching 15,000 instructions. Neither mode establishes physical-radio timing
or safety; mock regression envelopes remain separate from production grants.

Both drawers use `lib/settings_ui.lua`. Model construction reserves 14 slots:
one per step except two for the logical-switch list. Panel rows reserve one slot
and can share callbacks; lifecycle operations retain full grants and dialog
opening/replacement/closing boundaries. The panel profiler covers every catalog
panel, maximum-size lists, nested editors and conditional rows.

## Browser installer tests

Use Python's standard library and Node.js 22:

```sh
make test-installer
```

Tests cover release mirroring, connections, confirmation, integrity, and
preservation of non-widget files. Never use a real radio for automated
destructive tests.

For an optional rendered check, install Playwright/Chromium separately and
serve a [built site with mirrored assets](build.md#browser-installer-assets):

```sh
node tests/browser/radio-panel.smoke.mjs http://127.0.0.1:8000/
```

It needs two available mirrored stable releases and uses disposable browser storage, not a radio
or the OS folder picker. Optional environment variables are `PLAYWRIGHT_MODULE`
(external `index.mjs` path), `PLAYWRIGHT_CHANNEL=chrome`, and
`INSTALLER_KEYBOARD=1` for keyboard activation.

## Python tooling tests

Run the suites relevant to the changed tool; `make test` does not run these.

Release packaging (standard library):

```sh
python3 -m unittest discover -s tools -p 'test_release_*.py'
```

Menu icon and tile artwork checks also use only the standard library:

```sh
make test-artwork
```

They run as part of `make test` / `make check`, including CI.

Screenshot recipes/adapters (PyYAML, no Companion required):

```sh
make capture-setup
build/capture-venv/bin/python -m unittest discover -s tools -p 'test_capture_*.py'
```

Documentation publishing and browser layout:

```sh
python3 -m venv build/docs-venv
build/docs-venv/bin/python -m pip install -r requirements-docs-test.txt
build/docs-venv/bin/python -m playwright install chromium
build/docs-venv/bin/python -m unittest discover -s tools -p 'test_docs_*.py'
```

See [Tutorial videos](videos.md#validate-changes) for video tests and
[Maintain simulator fixtures](contributing.md#maintain-simulator-fixtures)
for model generation and checksum checks.

## Lint and formatting

```sh
make lint
stylua --check src/WIDGETS tests
```

`lint-config.lua` declares runtime globals; `stylua.toml` defines formatting.
Use StyLua 2.5.2 to match CI. `make format` rewrites files; inspect its diff.

## Debug a failure

Start with the failing suite/traceback and minimize the fixture. Verify whether
the defect is in code, expectations, or a mock before changing assertions.

For firmware problems, record package identity, module, exact error,
model/layout, and source/link state. If changes do not appear, check the active
SD path, saved-layout override, and stale `.luac` files.

### Simulator logs and caught errors

In Companion 2.12, open **View > Debug Output** (**F6**, or **Fn+F6**).
Disable filters or include `AeroGrid`. For persistent logs, enable
**Radio Firmware (in Simulator)** and choose an **Output Logs Folder** in
application preferences before simulation.

AeroGrid prints caught errors with `[AeroGrid] ERROR`, including operation and
layout/panel context. Identical messages are deduplicated per widget across
reloads, with 64 distinct messages retained. AeroGrid does not write an error
file; use Companion's logging for persistence.

The development **Diagnostics** layout reports only its own host. To inspect
another dashboard, add **Host diagnostics** there and select **panels** for rejected
or failed panels and their reasons. Editor errors remain in their dialogs.

For Navigation capture timing, select **log** before reproducing the issue.
This enables a radio-wide in-memory buffer, including hidden dashboards,
without recording coordinates. **Maximum log entries** is 1-256 (default 64);
the largest active setting wins. Removing all log panels stops recording.
Restarting the radio or unloading the script loses the buffer.

In widget fullscreen, tap the log panel to open a scrollable snapshot;
Close/RTN dismisses it. Reopen for newer events. Entries include uptime,
host/panel identity, capture outcome, and source reliability/age. Timestamps
use 10 ms ticks; GPS `delay` uses 160 ms units, so combined age in ticks is
`delay * 16 + now - updatedAt`. Logging does not relax capture rules.

Native capture logs are separate: see `simulator.log` under
`build/doc-capture/<panel>/` or `build/editor-capture/<scene>/`.

## Validate on a radio when needed

Hardware-sensitive work includes native resource lifetime, telemetry
freshness/recovery, timers, and flight persistence. Record radio/firmware/package,
layout, duration, CPU/memory, and receiver state; distinguish real telemetry
from synthetic inputs.

Do not infer other-radio support from the TX16S fixture. Use the release ZIP
and [installation procedure](../user-guide/installation.md), with user data
backed up.
