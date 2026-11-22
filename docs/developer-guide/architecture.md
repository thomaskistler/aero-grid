# Repository and architecture

AeroGrid is one EdgeTX widget. Its panels are modules hosted by that widget,
not separate EdgeTX widgets. Use the implementation and tests for exact
signatures; `plans/` contains design material, not the runtime contract.

## Find your way around

| Path | Responsibility |
| --- | --- |
| `src/WIDGETS/AeroGrid/main.lua` | EdgeTX entry points, native options, event routing, and task enrollment. |
| `src/WIDGETS/AeroGrid/lib/` | Loading, scheduling, services, geometry, rendering, themes, persistence, and editor. |
| `src/WIDGETS/AeroGrid/panels/` | Panel modules, including host diagnostics. |
| `src/WIDGETS/AeroGrid/layouts/` | Shipped layouts. |
| `src/WIDGETS/AeroGrid/assets/` | Runtime editor assets and licenses. |
| `tests/unit/`, `tests/integration/` | Module tests and mocked host/UI tests. |
| `tests/support/` | Firmware-aware mocks, assertions, and fixture helpers. |
| `tests/fixtures/` | Deterministic SD card, development layouts, and test-only modules. |
| `tools/` | Packaging, documentation publishing, captures, videos, and tooling tests. |
| `docs/` | Website sources and reviewed assets. |
| `.vscode/` | TX16S profile and build/test tasks. |
| `.github/workflows/` | CI, documentation, and release workflows. |
| `build/` | Ignored generated output. |

## Follow a dashboard from disk to display

1. EdgeTX loads `main.lua` with a zone and native **Layout** and **Theme**
   options. Their stable choice positions are maintained by separate registries
   under `/AEROGRID/`; do not reorder them.
2. `layout_store.lua` resolves the selected layout. A saved
   `/AEROGRID/layouts/<name>.yaml` overrides its bundled counterpart under
   `/WIDGETS/AeroGrid/layouts/`. A missing layout can fall back to `Default`.
3. `yaml.lua` parses the constrained YAML format, `layout.lua` validates it,
   and `grid.lua` maps zero-based placements in the 4 x 4 grid to rectangles.
4. `dashboard_loader.lua` stages service and panel construction, checks module
   compatibility, and resolves typed settings.
5. Scheduled callbacks update services and panels.
   `dashboard_lifecycle.lua` handles bounded reflow and page replacement;
   `editor_controller.lua` coordinates editing, previews, and saved-page adoption.

Loading, schema conversion, construction, reflow, and save work are split across
callbacks. Page retirement and replacement occur in separate callbacks.
Keep these boundaries: a synchronous whole-dashboard operation can exceed the
firmware budget or invalidate deferred native objects.

Glass shares sampled background brightness through
`/AEROGRID/cache/backgrounds.yml`. This generated cache survives widget updates
and can be deleted to regenerate it.

`lib/package.lua` declares the package and layout versions. Deploy the
complete widget directory; modules carry no separate API versions.

Layout conversion uses adjacent header and panel steps in `layout.lua`, at
most one transition per respective loader/save turn. Unsupported versions or
missing transitions are rejected. Loading converts only in memory and reports
an upgrade notice; explicit editor **Save** persists the current schema.

## Scheduling and callback budgets

`scheduler.lua` is firmware-independent. Flight, host transitions, services,
and panels share one persistent list ordered by due tick, which changes only
when the dashboard changes. Each callback runs due tasks from the front and
stops at the first task that is not due; ties go to the task that ran least
recently. Tasks set their own next due tick; a source that makes a task due
early moves it forward. Host readiness gates enforce input and lifecycle
ordering; transitions can hold service or panel work.

The default callback segment has eight nominal 2,000-instruction slots
(`CAPACITY` and `INSTRUCTIONS_PER_SLOT`). A task receives at most eight slots
per turn (`SLOTS`). Fixed-cost tasks reserve their declared cost; variable-cost
tasks declare a minimum and report consumption. Unused slots become available
to later tasks. Unfinished work retains its place across callbacks.

A continuation requests another turn after the other tasks have had theirs;
it needs no separate opt-in. Pending work can run before its next due time.
Return no continuation when work should wait for that time.

The model's **Pre-release features** setting permits up to four additional
segments for pending/deferred work in the same callback. It is disabled by
default and also requires an explicitly enabled saved setting during startup.
`native_budget.lua` owns the EdgeTX-specific mechanism for running those
segments beyond the firmware instruction limit; the scheduler does not.

Slots are estimates, not measured instruction limits, and exclude scheduler
overhead. Keep normal callbacks within the
[regression budgets](testing.md#performance-and-resource-regressions), rather
than relying on the pre-release extension to hide excessive work.

## Shared services own firmware reads

Panels subscribe in `create`, retain read-only live views, and render them.
Do not poll firmware independently or mutate service-owned data. Shared
subscriptions reuse polling; views can change in place without allocation.

| Module | Responsibility |
| --- | --- |
| `telemetry_service.lua` | Source resolution, values, units, precision, and link freshness. |
| `model_service.lua` | Identity/image, timers, flight mode, and TX voltage. |
| `control_service.lua` | Trims, channel outputs, switches, GVs, and verified flight-count increments. |
| `armed_service.lua` | Effective model/consumer arm condition over shared Control polls. |
| `flight_service.lua` | Shared flight detection, counting, optional Sticky output, and boundary journal. |
| `smart_flight.lua` | Protocol-identified flight sensors and per-sensor receipt/freshness. |
| `navigation_service.lua` | GPS fix, home/pilot position, distance, and bearing. |
| `history_service.lua` | Bounded recordings, cumulative time, extrema, and flight intervals. |
| `services.lua` | Service environment, subscriptions, and scheduled dispatch. |

Handle unavailable and stale data explicitly. Zero is a valid telemetry value;
link-wide freshness cannot prove that a particular sensor has been received.
Local controls remain usable without a receiver. Arm consumers use the shared
five-second maximum sample age; unknown/stale arm data is not disarmed.
A saved model arm condition overrides consumer fallbacks; an explicit empty
condition disables arming.

### Shared flight tracking

The factory-scoped flight broker owns a non-UI Control/Telemetry runtime and
optional Smart poller. Widgets enroll its shared tasks, which run at most once
per tick. Dashboard declarations must agree; a qualified flight pins its arm,
detector settings, and output through completion and cleanup. Counter panels
only render the shared result.

Consumers use `services.flight:state()` and
`:boundaries(afterSequence, epoch)`, never the Sticky output as an event bus.
The boundary journal retains 64 start/end records. Reconcile journal gaps and
epoch changes. Boundary `at` is the candidate/disarm time; `observedAt` is its
confirmation time, so duration excludes the disarm grace.

Smart detection requires supported protocol metadata and per-sensor
`getSourceValue` receipt evidence. Cached values and link-wide freshness do not
renew it. Unsupported, ambiguous, or stale inputs fall back to standard
detection. Keep qualification and output effects in the broker rather than
duplicating them in panels.

### Chart history

History observes completed polls, including unchanged values and intervening
extrema. Matching condition/source/options subscriptions share bounded storage.
Recording pauses on disarm unless a matching flight remains active, and while
any AeroGrid layout editor or Model settings dialog is open.

Charts render live pixel columns rather than replaying stored history. Late
attachment, resizing, and read-only previews start an empty plot; a service
runtime rebuild clears recordings. Compatible previews can be adopted after
saving without replacing their subscriptions. Appends, rescaling, drawing, and
reset work must fit granted slots; charts refresh at most four times a second.

## Add or change a panel

Start with `panels/flight-mode.lua`; `lib/panel_host.lua` defines the contract.
Put a module at `panels/<type>.lua`, with an `id` matching that layout type.

| Declaration or callback | Contract |
| --- | --- |
| `id`, `supportedSpans` | Identity and supported grid spans. |
| `settings` | Typed fields, defaults, bounds, and choices shared by validation and the editor. |
| `refreshInterval` | Interval in 10 ms ticks; zero or absent means every frame. |
| `refreshCost`, `refreshMinCost` | Fixed cost of 0-8 slots (default 1), or `"variable"` with a minimum of 1-8. |
| `create(parent, rect, settings, services)` | Construct objects, subscribe, and return instance state. |
| `refresh(instance, creating, slots)` | Update objects; scheduled calls pass `false`. Returns next interval (1-6000 ticks, or nil to retain it), continuation, and consumed slots. Variable work must report consumption. |
| `update(instance, rect, settings, detailsOnly, placement)` | Reflow/configuration update; host reflows and editor resizes pass placement as the fifth argument. |
| `background(instance, creating, slots)` | Hidden-dashboard work; variable-cost when `backgroundMinCost` is declared, otherwise one slot. Returns an optional delay in ticks before the next call, continuation, and consumed slots. |
| `resetSession(instance, now)` | Reset session state; second result true requests another bounded reset turn. |
| `rebindArming(instance, services)` | Reconnect arming-dependent subscriptions after a model arm-switch change, keeping existing native objects. Receives the service registry's `byId` table. |
| `event(instance, event)` | Return true when consumed. |
| `destroy(instance)` | Release panel-owned references. |
| `validateSettings(settings, span, config, modelArmed)` | Cross-field or span-dependent validation, with the effective model arm condition. |
| `thresholds(settings)` | Configured `{ sensor, warning, critical, falling, strict }` list, registered with telemetry when the layout is built or saved; for each sensor the first panel in layout order wins. |

A lifecycle failure disables the affected panel and reports its error without
repeatedly invoking the failed panel.

Use `supportedSpans = { "any" }` only when every in-bounds span renders
correctly. Use container-local coordinates and shared geometry, including the
top-left menu reservation; never assume a TX16S-sized screen.

List settings (`type = "table"`) declare entry `fields` for the shared drawer.
Use `itemLabel` for singular row names. Do not add a panel-specific settings UI.

Use `theme.lua` and `primitives.lua` for shared typography, geometry, colors,
readings, and LVGL objects. They compose `typography.lua`, `panel_layout.lua`,
and `reading.lua`; tests use `tests/support/module_loader.lua` to compose the
same APIs. Choose stable reading fonts from the widest expected representation.
Update a label's backing font with `primitives.setFont` rather than replacing
its persistent callback.

Cover settings, absent data, every declared span, reflow, and editor installation.
Add a [panel reference page](../reference-guide/index.md) and, when needed, a
[capture recipe](tools.md#change-a-capture-recipe).

## Editor and persistence

`editor.lua` owns drafts; `editor_ui.lua` and `editor_drawer.lua` present them.
`editor_controller.lua` coordinates the live dashboard. Settings drawers put
**Label** first when declared, then preserve declaration order.

`layout_store.lua` owns layout resolution, verified saves, and backups;
`layout_registry.lua` maintains choice positions. **Save** writes under
`/AEROGRID/layouts/`, never over bundled layouts. New **Save as...** names need a
script restart to enter the native Layout picker. Failed saves preserve drafts.

`model_settings_store.lua` validates and serializes revisioned documents;
`model_settings_sidecar.lua` stores `/AEROGRID/models/<ID>.yaml`, linked by the CH32 name. Reads never write;
after the broker accepts settings, filename changes fork the record while
disarmed. Verified records are installed before claiming CH32, preserving all
channel fields. Saves guard model identity, CH32 name, and revision.
Layout saves and previews do not write model settings.
Changing the arm condition rebuilds registered dashboards and clears captured
homes, while preserving layouts and active-flight completion/cleanup.

Legacy filename-encoded development records are not imported.

A model change or session reset advances the flight epoch. Session reset
cancels detection, releases its owned output, and clears dashboard session
data in bounded callbacks without replacing subscriptions, objects, or drafts.
Counting waits for a fresh disarm observation; persistent flight totals remain.
