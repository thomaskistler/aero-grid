# Repository and architecture

Start with `main.lua` for host behavior, an existing panel for presentation,
or a service for data acquisition. AeroGrid runs as **one EdgeTX widget**;
the dashboard's panels are modules managed by that widget, not separate
EdgeTX widgets.

## Find your way around

| Path | What belongs here |
| --- | --- |
| `src/WIDGETS/AeroGrid/main.lua` | EdgeTX entry points, native options, event routing, and callback scheduling. |
| `src/WIDGETS/AeroGrid/lib/` | Layout parsing/storage, grid geometry, panel hosting, shared services, rendering primitives, themes, and editor modules. |
| `src/WIDGETS/AeroGrid/panels/` | Eleven user-facing panel types plus `host-diagnostics`, `service-probe`, and the fixed-data `theme-showcase`. |
| `src/WIDGETS/AeroGrid/layouts/` | Shipped layouts. |
| `tests/fixtures/layouts/development/` | Simulator and review layouts used by tests and disposable SD images. |
| `src/WIDGETS/AeroGrid/assets/` | Runtime editor icon and its license. |
| `tests/unit/` | Focused module and panel tests. |
| `tests/integration/` | Host, editor, dashboard, budget, and resource tests using mocked EdgeTX. |
| `tests/support/` | Assertions, firmware-aware EdgeTX/LVGL mocks, and widget/layout fixture helpers. |
| `tests/fixtures/` | Deterministic simulator SD card, test-only panels, and test layouts. |
| `tools/` | Release packaging, native screenshots, capture recipes, and Python tooling tests. |
| `docs/` | Website sources, reference pages, reviewed images, and hardware evidence. |
| `.vscode/` | TX16S profile and build/test tasks; local settings are ignored. |
| `.github/workflows/` | CI, documentation publication, and manual release workflow. |
| `plans/` | Design specifications and historical planning material, not runtime input. |
| `build/` | Ignored, generated output; never the source of truth. |

The [project specification](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md)
provides design background. Check the implementation and its tests for exact
current signatures; planning examples can describe earlier contracts.

## Follow a dashboard from disk to display

1. EdgeTX loads `main.lua` and passes a zone and the native **Layout** and
   **Theme** options. Layout choices use stable positions maintained by
   `layout_registry.lua`.
   Stable layout positions are stored in `/AEROGRID/layout-registry.txt`,
   separately from `/AEROGRID/theme-registry.txt`.
2. The host resolves the selected name through `layout_store.lua`. A saved
   `/AEROGRID/layouts/<name>.yaml` takes precedence over the bundled
   `/WIDGETS/AeroGrid/layouts/<name>.yaml`; a missing file can fall back to
   `Default`.
3. `yaml.lua` tokenizes the constrained YAML format; `layout.lua` validates
   version, grid, placements, and configuration. `grid.lua` turns zero-based
   positions and spans in the 4 x 4 grid into pixel rectangles.
4. The host loads services and panel modules, checks compatibility, resolves
   typed settings, and creates each panel inside its own LVGL container.
5. Foreground/background callbacks update subscribed services and dispatch
   panel work. A zone or fullscreen change triggers bounded reflow rather
   than reconstructing every object in a single frame.

Host coordination has three boundaries:

| Module | Ownership |
| --- | --- |
| `dashboard_loader.lua` | Layout recovery, staged parsing, service/panel construction, and placement-local services. |
| `dashboard_lifecycle.lua` | Empty-page decoration, batched reflow, fullscreen-to-App rebuilds, and page retirement/replacement. |
| `editor_controller.lua` | Editor activation, staged advancement, dashboard previews, draft restoration, and adoption after saving. |

Their `new` functions bind host operations once per widget. They do not capture
another widget's context or introduce per-refresh forwarding wrappers. `main.lua`
decides which operation advances; loading and cleanup keep their explicit stages.
Page retirement and replacement run in separate callbacks so deferred cleanup
cannot invalidate objects belonging to the replacement page.

Panels use container-local coordinates. They must not draw at absolute screen
coordinates or assume the TX16S's dimensions. In App mode the host accounts
for the top-left EdgeTX menu button; fullscreen removes that reservation.
Use the shared geometry instead of adding panel-specific menu offsets.

`lib/package.lua` records package, runtime API, panel API, and layout versions.
Runtime modules expose `RUNTIME_API`; panels expose `apiVersion`.
The host surfaces incompatible modules and isolates failures where possible.
These checks detect incompatible mixtures, not every stale or mixed package:
deploy the **complete** widget directory.

## Shared services own firmware reads

Panels subscribe in `create`, retain read-only snapshots, and render them.
They do not each poll EdgeTX or maintain their own telemetry cache.
Subscriptions to the same source share polling, and an unsubscribed service
does not consume scheduled work.

| Service module | Responsibility |
| --- | --- |
| `telemetry_service.lua` | Source resolution, readings, units, precision, freshness, and link status. |
| `model_service.lua` | Model identity/image, timers, flight mode, TX voltage, and flight history/audio support. |
| `control_service.lua` | Trims, switch conditions, GV snapshots, and verified GV9 FM0 increments. |
| `extrema_service.lua` | Sensor extrema and dashboard flight-session tracking. |
| `navigation_service.lua` | GPS fix, pilot/home position, distance, and north-up bearing. |
| `services.lua` | Environment/snapshots, subscription registration, and bounded scheduling/update dispatch. |

Snapshots are read-only views over service-owned state, mutated in place by
the service to avoid per-frame allocations. Missing APIs, unknown sources, and
missing fixes yield unavailable data; panel code must handle that explicitly.

`services.addSubscription` publishes an entry's live view and records its polling
order/count. Each domain service still owns name lookup, duplicate detection,
source resolution, and its polling metadata. Link/session-only subscriptions
remain separate from source polling lists.

Telemetry zero is not inherently unavailable. EdgeTX can return zero both for
a real reading and for a stopped stream. AeroGrid preserves the last live
value when an ambiguous zero arrives with a down link, but accepts a live zero.
`getRSSI()` is not reliable for every protocol; the service can stop trusting
it when a non-zero source proves that telemetry is arriving. Staleness is
link-wide, not per sensor, and a configured but never-received sensor can
appear as valid zero on a live link. Local switch values remain usable
without a receiver.

The `flight-counter` panel is deliberately stateful: it owns qualification
and disarm-timeout transitions, requests verified count updates, and asks
the model service for history/audio side effects. Its `armSwitch` is distinct
from the extrema session's `armSource`. Each dashboard has independent
services, so install **only one flight tracker per model**; other dashboards
can display GV9 through `metric`. Detection state resets on dashboard reload;
the persisted GV count does not.

## Add or change a panel

Use `panels/flight-mode.lua` as a small working example and
`lib/panel_host.lua` as the authoritative contract.

| Declaration or callback | Role |
| --- | --- |
| `id`, `apiVersion`, `supportedSpans` | Identify the module, check compatibility, and advertise valid grid sizes. |
| `settings` | Typed fields, defaults, bounds, and choices used by validation and the editor. |
| `refreshInterval` | Desired foreground interval in 10 ms ticks; work still shares the host budget. |
| `create(parent, rect, settings, services)` | Build LVGL objects, subscribe to data, and return private instance state. |
| `refresh(context)` | Optional callback to update existing objects from snapshots. |
| `update(context, rect, settings)` | Optional geometry/configuration update. |
| `background(context)` | Optional work when the dashboard is not visible. |
| `event(context, event)` | Optional event handling; return true when consumed. |
| `destroy(context)` | Optional cleanup of panel-owned references. |
| `validateSettings(settings, span, config)` | Optional cross-field and span-dependent validation. |

Put the module at `panels/<type>.lua` and reference that type in a layout.
Declare only spans you actually render correctly. A list setting
(`type = "table"`) declares entry `fields` with keys or nested paths, labels,
types, and appropriate defaults/bounds/choices. The editor uses this schema
to offer even fields omitted from the YAML, and can remove cleared optional
fields. Do not build a separate settings UI for each panel.

The public `theme.lua` API composes palette/state resolution with
`typography.lua` (measurement, font fitting, unit metrics) and `panel_layout.lua`
(frames, slots, bands, and regions). The public `primitives.lua` API composes LVGL
objects with `reading.lua` (reading/unit composition, redraw detection, and
visibility/reflow reconciliation). Installed functions are direct references,
not per-call wrappers; each widget has its own caches and mutable API tables.

The host supplies these dependencies when executing the modules. Pure-Lua tests
use `tests/support/module_loader.lua` to compose the same APIs without installing
firmware globals.

Use `theme.lua` for bands, font fitting, shared colors, and spacing, and
`primitives.lua` for reusable LVGL objects. `primitives.reading` constructs the
matching value/unit arrangement used by the battery and link readouts; optional
units and differing initial geometry remain panel-specific. Keep a reading's font stable as
its value changes, using the widest expected representation to choose it.
When changing settings vocabulary or rendering, inspect sibling panels so
the same setting retains the same meaning.

Add focused tests, an integration case at every declared span, a simulator
review layout when useful, and a [panel reference page](../reference-guide/index.md).
If adding screenshot support, add a capture recipe and adapter as described
in [Project tools](tools.md#change-a-capture-recipe).

## Editor and persistence

`editor.lua` owns draft operations; `editor_ui.lua` and `editor_drawer.lua`
present them; `editor_controller.lua` coordinates them with the live dashboard.
`layout_store.lua` handles saving, backups, and user-versus-shipped
resolution; `layout_registry.lua` maintains name-to-choice positions.
Keep these boundaries intact when changing save behavior.

Editing does not overwrite bundled layouts. Save writes to `/AEROGRID/layouts/`,
and Save As creates a named user layout. The layout registry is initialized
at script load, so new names require a restart before appearing in the native
Layout picker. Save errors must preserve the draft and report failure.
Test persistence through the store/editor suites, not just the visible dialog.

## Firmware constraints that affect design

EdgeTX limits a widget callback to **20,000 Lua VM instructions**. Creation,
parsing, panel building, reload, and reflow are staged across callbacks.
Services have bounded subscription updates, and panel work is capped and
phase-staggered. Do not replace this with one synchronous "simpler" loader.
The [budget tests](testing.md#performance-and-resource-regressions) require
strictly less than 75% of the callback allowance.

Avoid object churn and retained callbacks. Shared labels install a persistent
font callback; change its backing state through `primitives.setFont` rather
than replacing the callback during refresh/reflow. Replacement retained Lua
registry references in EdgeTX 2.12.4.

Other firmware details already have helpers and regression coverage:
`theme.measureText` uses `lcd.sizeText` where available and estimates otherwise;
trim sources do not identify their axis, image decode failure is not reported
by `lvgl.image`, and
`lvgl.arc` positions use the center rather than the bounding-box corner.
Reuse the existing panel logic, file checks, and `primitives.arcBounds`
instead of introducing alternate assumptions.
