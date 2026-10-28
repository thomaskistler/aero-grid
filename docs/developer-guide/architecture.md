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
| `src/WIDGETS/AeroGrid/panels/` | Twelve user-facing panel types plus `host-diagnostics`, `service-probe`, and the fixed-data `theme-showcase`. |
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
| `plans/` | Design specifications and planning material, not runtime input. |
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
The current layout schema is version 4. The central layout module keeps an
adjacent migration registry: each source version provides a header step and a
panel step for that version-to-next-version transition. A future version must
add every intervening step; a layout is rejected if its source version is newer
or any transition is missing.

Runtime loading validates the header, applies at most one header transition per
loader callback, then parses each panel and applies at most one panel transition
per callback before validating and building that panel. Staged Save follows the
same bounded progression, keeping header migration, each panel migration,
validation, and persistence in separate callbacks. The synchronous whole-layout
helpers are for tests and tools, not runtime callback paths. Loading changes
only the in-memory document and emits an upgrade notice; only explicit editor
Save persists the current schema. Runtime modules expose `RUNTIME_API`; panels
expose `apiVersion`. The host surfaces incompatible modules and isolates
failures where possible. These checks detect incompatible mixtures, not every
stale or mixed package: deploy the **complete** widget directory.

## Shared services own firmware reads

Panels subscribe in `create`, retain read-only snapshots, and render them.
They do not each poll EdgeTX or maintain their own telemetry cache.
Subscriptions to the same source share polling, and an unsubscribed service
does not consume scheduled work.

| Service module | Responsibility |
| --- | --- |
| `telemetry_service.lua` | Source resolution, readings, units, precision, freshness, and link status. |
| `model_service.lua` | Model identity/image, timers, flight mode, TX voltage, and flight history/audio support. |
| `control_service.lua` | Trims, final channel outputs and their trim associations, switch conditions, GV snapshots, and verified GV9 FM0 increments. |
| `armed_service.lua` | Native widget Armed precedence, legacy switch fallback, and immutable effective arm views over shared Control polls. |
| `extrema_service.lua` | Sensor extrema and dashboard flight-session tracking. |
| `navigation_service.lua` | GPS fix, pilot/home position, distance, and north-up bearing. |
| `history_service.lua` | Error-bounded chart recordings, cumulative armed time, raw extrema, line-only smoothing, and bounded rolling expiration. |
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

Chart history observes completed telemetry polls rather than reading changed
revisions during redraw: unchanged numeric samples still occupy armed time,
and raw spikes must not be lost between frames. Observer failures are isolated
from telemetry polling and reported through normal service failure handling.
`services.armed:state()` describes the native widget condition;
`:state(legacySwitch)` resolves native-over-legacy precedence for a consumer.
Snapshots expose `condition`, `key`, `origin`, `generation`, `configured`,
`available`, `fresh`, `updatedAt`, Boolean `value`, `revision`, and `status`.
An unavailable/stale reading is not disarmed. Reliability is evaluated on
access with a one-second maximum sample age, so a failed poller cannot leave a
permanently fresh reading. `revision` changes on observed sample/reliability
changes; `generation` changes when the widget runtime is rebuilt.
`status` is `unconfigured`, `ready`, or `unavailable`; invalid configuration
is reported through normal host error isolation.
The resolver owns no separate polling work: Control still reads each switch
once. Native configuration and state are per widget, not model-wide.

History and extrema key sessions by the effective condition. A configured
native Armed unifies their arm inputs; unset Armed retains independent legacy
switches. Each chart arm configuration has its own cumulative session.
It pauses on disarm and resumes the same recording;
geometry reflow keeps it, while rebuilding the service runtime clears it.
Each source/options subscription stores at most 6,144 connected linear knots.
A fixed-anchor slope corridor chooses synthesized shared endpoints within half
a displayed precision step of every observed value (filtered values if EMA is
enabled). Numerical margin is reserved before accepting a segment; when that
margin consumes the tolerance, exact native values are retained. Unknown sensor
precision uses the strictest supported tolerance until discovery completes.

Knots use chunked `<I4n` / `<I4j` packing: cumulative armed ticks with gap/type
bits and a lossless native Lua float or integer. Payload is 48 KiB per full recording on float32
firmware, or 72 KiB on double-precision hosts, excluding string/table/index and
rendering overhead. Matching armed-switch/source/options subscriptions share storage.
Absolute `first`/`last` sequence IDs and scalar `history:point` reads avoid
per-knot snapshot tables. Growing history freezes at capacity without relaxing
accuracy; rolling expiration reuses ring slots while retaining an interpolation
anchor. Raw readouts/extrema continue even when plot storage is full.

Multilevel extrema/gap indexes accelerate projection only inside one pixel
column; they never replace stored knots. Projection, native trace updates and
gap-marker updates are staged with bounded work per callback. Geometry changes
restart pending projection. Recorded gaps stay separate except when their
endpoints coincide on screen; marker objects are pooled by pixel column.
Unchanged readouts are cached so their callback budget can process a larger
bounded projection batch; same-pixel extrema do not add redundant geometry.

The `flight-counter` panel is deliberately stateful: it owns qualification
and disarm-timeout transitions, requests verified count updates, and asks
the model service for history/audio side effects. It consumes the effective
Armed view, without changing its qualification/disarm policy. Each dashboard has independent
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
| `refreshCost` | Whole-number share of the six host refresh slots (default 1). Chart uses all six so dense layouts cannot batch expensive redraws into one callback. |
| `create(parent, rect, settings, services)` | Build LVGL objects, subscribe to data, and return private instance state. |
| `refresh(context)` | Optional callback to update existing objects from snapshots. May return a whole-number interval of 1–6000 ticks to adapt subsequent scheduling; nil preserves the current interval. |
| `update(context, rect, settings, detailsOnly, placement)` | Optional geometry/configuration update. Host reflows and editor resizes pass the current grid placement as the fifth argument, leaving the internal `detailsOnly` argument unset. |
| `background(context)` | Optional work when the dashboard is not visible. |
| `event(context, event)` | Optional event handling; return true when consumed. |
| `destroy(context)` | Optional cleanup of panel-owned references. |
| `validateSettings(settings, span, config)` | Optional cross-field and span-dependent validation. |

Put the module at `panels/<type>.lua` and reference that type in a layout.
Regular panels declare `supportedSpans = { "any" }` and adapt their contents to
every in-bounds span of the 4 x 4 grid. Use an explicit span list when there is a
real rendering constraint: Host diagnostics and Service probe need at least
2x2, Chart needs a wide or square placement at least 2x1, while Theme showcase requires 4x4. Declare only spans you actually render
correctly. A list setting
(`type = "table"`) declares entry `fields` with keys or nested paths, labels,
types, and appropriate defaults/bounds/choices. The editor uses this schema
to offer even fields omitted from the YAML, and can remove cleared optional
fields. List declarations, including nested lists, can set `itemLabel` to a
singular name such as `"Metric"` or `"State"`. The editor names rows using the
first nonempty label or source, then `itemLabel` and the one-based index;
lists without `itemLabel` use `"Entry"`. Do not build a separate settings UI
for each panel.

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
Panel settings drawers, including entry subdrawers, put **Label** first when
declared, preserving the declaration order of all remaining controls.

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
