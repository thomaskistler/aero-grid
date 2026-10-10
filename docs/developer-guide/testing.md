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
modules. Each test gets a fresh `lupa.LuaRuntime` and the repository root as
its chunk argument. A failed assertion stops the run with a traceback and
non-zero exit status.

Every suite runs once with the string metatable removed to resemble EdgeTX.
Runtime code should use
`string.sub(value, ...)`, not assume `value:sub(...)` works on the radio.

`make check` runs those same tests and then parses all source/test Lua with
the detected compiler. `lupa`'s Lua version is not guaranteed to be EdgeTX's;
**passing behavior tests does not prove Lua 5.3 compatibility**. Install the
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

For a firmware error, use the simulator's logs and the **Host** diagnostic
layout. Record the loaded package identity, failing module/source, exact
message, model, and layout. An unavailable sensor is not automatically a Lua
failure: verify its binding and link state first.

If the display ignores your code change, check the active SD path, saved layout
override, and stale `.luac` before investigating rendering.

## Validate on a radio when needed

Hardware-sensitive work includes native
resource lifetime, telemetry freshness/recovery, timer behavior, and flight
count persistence. Record radio/firmware/package versions, layout, duration,
memory/CPU observations, and receiver state; distinguish actual telemetry from
synthetic inputs.

Do not infer broader radio support from the TX16S fixture. Use the release
package and [installation instructions](../user-guide/installation.md) for a
hardware check, with your custom layouts backed up before replacement.
