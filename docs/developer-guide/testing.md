# Test and debug

Use the quickest test that exercises your change while iterating, then run the
broader checks before submitting. Mock tests validate logic; simulators validate
the actual firmware UI; a radio validates hardware behavior. None substitutes
for all the others.

## Run the automated Lua suites

```sh
make test
make check
```

`make test` executes every `test_*.lua` beneath `tests/`, excluding support
modules. Each test gets a fresh `lupa.lua53.LuaRuntime` and the repository root as
its chunk argument. A failed assertion stops the run with a traceback and
non-zero exit status.

Every suite runs once with the string metatable removed to resemble EdgeTX.
Runtime code should use
`string.sub(value, ...)`, not assume `value:sub(...)` works on the radio.

`make check` runs those same tests and then parses all source/test Lua with
the detected compiler. The runner explicitly selects Lua 5.3 to match EdgeTX,
rather than `lupa`'s default runtime, which can change between releases.
Mock behavior tests still do not replace firmware compiler validation. Install the
[compiler](build.md#install-the-validation-tools), or specify it:

```sh
make check LUA_COMPILER=/absolute/path/to/edgetx-luac
```

## Choose the right test layer

| Change | Start here |
| --- | --- |
| YAML, layout validation, geometry, or persistence | `tests/unit/lib/` and `tests/support/assertions.lua`. |
| Source resolution, freshness, model/control/navigation data | The corresponding service suite in `tests/unit/lib/`. |
| Panel settings or presentation | `tests/unit/panels/`, then the relevant `tests/integration/widget/test_*_review.lua`. |
| Host load/reload, failure isolation, scheduling, or callback budgets | `tests/integration/test_widget.lua`. |
| Editor commands and settings dialogs | `tests/unit/lib/test_editor.lua` and `tests/integration/test_editor_ui.lua`. |
| Shared rendering or reflow | Builder-matrix, panel-reflow, font-callback, and resource-stability integration suites. |

The runtime suite under `tests/unit/runtime/` is split into
contracts/settings/documentation, palette/state, service behavior, and
typography/geometry suites. `tests/support/runtime_fixture.lua` preserves the
minimal constants/LCD surface: these tests deliberately do not install LVGL or
radio APIs. The full-widget integration suite remains intact so budgeting,
cross-panel agreement, and deferred cleanup are still exercised together.

`test_module_composition.lua` checks direct API references, per-instance state,
and reading/unit reconciliation. `test_service_subscriptions.lua` checks stable
subscription identity across domain services. `test_runtime_modules.lua` checks
missing/incompatible coordination and visual dependencies, including error
visibility after resizing.

Reuse `tests/support/widget_fixture.lua` to load a host with mocked APIs.
Use `tests/support/edgetx.lua` for firmware behavior and LVGL object inspection
instead of inventing another mock. That module separates **firmware claims**
(with source-file/symbol citations) from invented test **scaffold** values.
If a new regression depends on how EdgeTX behaves, verify and cite the firmware
implementation; making the mock agree with an assumption can hide a real bug.

## Performance and resource regressions

`tests/integration/test_widget.lua` measures widget callbacks with instruction
hooks, including dense sixteen-panel layouts, service work, loading, and reflow.
It fails at **15,000 instructions or more**, reserving headroom against EdgeTX's 20,000-instruction
callback budget. Read the printed `budget headroom` and `steady state` results
when changing scheduling or rendering.

The resource suites check reload collectibility, object counts, sustained
updates, and font callback retention. They cannot measure native LVGL/bitmap
memory, firmware GC cadence, or radio timing. A short green mock run is not
evidence of long-term hardware stability.

## Python tooling tests

Release packaging uses only Python's standard library:

```sh
python3 -m unittest discover -s tools -p 'test_release_*.py'
```

Capture-recipe tests need the optional PyYAML environment, but not Companion
or the native screenshot runner:

```sh
make capture-setup
build/capture-venv/bin/python -m unittest discover -s tools -p 'test_capture_*.py'
```

Neither command is included in `make test`. CI runs the release-packaging
tests; run capture-recipe tests locally when changing recipes or adapters.

## Lint and formatting

```sh
make lint
stylua --check src/WIDGETS tests
```

`make lint` uses `lint-config.lua`, including the EdgeTX globals the runtime
expects. `stylua.toml` defines repository formatting.
`make format` **changes files**; inspect the diff afterwards.
Use StyLua 2.5.2 to match CI.

## Debug a failure

For a mock assertion, start with the failing file and traceback, reproduce it
with `make test`, and minimize the fixture. Check whether the failure
is in code, expected behavior, or an inaccurate mock before changing expectations.

For a firmware error, use the simulator's logs and the **Diagnostics**
layout. Record the loaded package identity, failing module/source, exact
message, model, and layout. An unavailable sensor is not automatically a Lua
failure: verify its binding and link state first.

If the display ignores your code change, check the active SD path, saved layout
override, and stale `.luac` before investigating rendering.

### Simulator logs and caught errors

In Companion 2.12's simulator, open **View > Debug Output** (**F6**, or
**Fn+F6** on some Macs). Disable its filter initially so it does not hide
messages. Firmware Lua errors and Lua `print(...)` output go to this console.
For a persistent log, enable **Radio Firmware (in Simulator)** in Companion's
application preferences and choose an **Output Logs Folder** before starting
the simulation. Files are named `FirmwareDebug_<timestamp>.log`.

AeroGrid mirrors caught runtime, panel, and editor validation/save errors to
Lua `print(...)`, prefixed with `[AeroGrid] ERROR`. Messages include the layout,
model filename when known, operation, and panel/setting details when relevant.
Identical messages are suppressed per widget instance across layout reloads.
The last 64 distinct messages are retained for deduplication; an older message
may be logged again after eviction or when a new widget instance is created.
Disable console filters or include `AeroGrid` to see these messages.

Logging does not replace the live host's retained failures, dashboard error
overlay, or editor validation messages. Preview errors still appear in
**Panel preview failed** messages; open the details to read the complete
explanation. AeroGrid does not write a separate persistent error file; use
Companion's firmware logging option above when persistence is needed.

The **Diagnostics** layout shows the host it belongs to, not the errors of
another dashboard. To inspect a failing dashboard's own panels, add a
**Host diagnostics** panel there and select its **panels** section. It lists
rejected and failed panels first, including their reasons. The other sections
show package/layout identity, theme notices, and source bindings.

For Navigation first-arm home failures, select **log** on a Host diagnostics
panel before reproducing the problem. This enables a radio-wide, in-memory
event buffer, including events from Navigation services on hidden screens.
It is independent of the per-widget console-error deduplication above.
Entries identify uptime, layout/host instance, panel, and captured/missed
or switch unavailable. Each event records `now`, availability, freshness,
stale state, value, `updatedAt`, reported delay, and coordinate validity,
never coordinates. Inputs describe GPS for capture attempts or the arm
switch for switch-unavailable events; inapplicable fields appear as `nil`.
Timestamps are 10 ms ticks; delay is seconds.
Calculate poll age as `now - updatedAt` and combined age as
`delay * 100 + now - updatedAt`. Capture policy is not relaxed for diagnosis. **Maximum log
entries** defaults to 64 (1–256); the largest active log panel setting wins.
In widget fullscreen, tap the log panel and use drag/wheel scrolling to read
a stable snapshot; Close/RTN dismisses it. Reopen for newer events. Removing
all log panels stops recording. The buffer is never saved to the SD card
and is lost when the radio restarts or the widget script unloads.

The unit and widget-integration `test_diagnostics_log.lua` suites,
`test_host_diagnostics.lua`, and the Navigation service suite cover
retention, multi-host activation, hidden-screen capture
logging, viewer interaction, wrapping, and the strict 15,000-instruction
callback ceiling. These are mocked checks, not evidence of radio timing or
native LVGL behavior; reproduce the original symptom on hardware with the
log enabled to obtain that evidence.

The native capture tools already redirect simulator output to
`build/doc-capture/<panel>/simulator.log` or
`build/editor-capture/<scene>/simulator.log`; these are separate from an
interactive Companion session.

## Validate on a radio when needed

Hardware-sensitive work includes native
resource lifetime, telemetry freshness/recovery, timer behavior, and flight
count persistence. Record radio/firmware/package versions, layout, duration,
memory/CPU observations, and receiver state; distinguish actual telemetry from
synthetic inputs.

Do not infer broader radio support from the TX16S fixture. Use the release
package and [installation instructions](../user-guide/installation.md) for a
hardware check, with your custom layouts backed up before replacement.
