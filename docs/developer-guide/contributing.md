# Contributing

## Prepare a change

Start from the current `main` branch in your own branch or fork. Keep changes
focused, follow existing naming and formatting, and update the relevant guide or
component reference when behavior changes.

Use the [build instructions](build.md) to set up development. Runtime code lives
in `src/WIDGETS/AeroGrid/`; pure module tests live in `tests/unit/`, and mocked
EdgeTX host tests live in `tests/integration/`.

Add regression coverage for fixes and test both normal operation and unavailable
data. For layout changes, cover supported spans, resizing, content shedding and
restoration, and App mode's menu-button reservation.

## Validate and submit

Run the checks relevant to your change:

```sh
make check
make lint
make build BUILD_DIR=build/package-check
make docs
```

Use `make format` for Lua changes and inspect the resulting diff. CI runs tests,
Lua 5.3 parsing, linting, formatting, and package/source parity checks.
The separate Documentation workflow validates documentation changes.

Open a pull request describing the purpose, behavior changes, and evidence.
Distinguish mock/simulator results from hardware observations, and state remaining
limitations rather than treating a short run as proof of long-term stability.

## Keep fixtures deterministic

`tests/fixtures/sdcard/` is checked-in input, not simulator output. Update a fixture
explicitly when changing the baseline. Keep `manuallyEdited: 1` in the fixture
radio settings when manually changing model selection so EdgeTX accepts it and
can regenerate the checksum.

Do not commit generated `.luac` files, logs, screenshots, virtual environments,
or mutable `build/sdcard/` state. Preserve personal model configuration outside
the fixture.

## Adding a component

Read the [architecture guide](architecture.md) and the
[component module contract](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md)
before adding a panel. Declare supported spans and typed settings, use shared
services and primitives, and respect the callback instruction budget.

Include tests and a component reference page, add it to `mkdocs.yml`, and provide
a reachable fixture layout when introducing a shipped dashboard.
