# AeroGrid Project Specification

## Status

- Draft specification
- Date: 2026-09-07
- Status last updated: 2026-10-04
- EdgeTX source: `../edgetx`
- Project root: `aero-grid/`
- Implementation: Phase 1 runtime complete; Phase 2 has a schema-driven on-radio editor, strict whole-layout validation, and recoverable YAML persistence. Thirteen shipped panels, seven using the shared standard panel. The original nine display panels are reviewed and documented; the text and flight-counter panels are documented with simulator captures. Global-variable display uses ordinary metric sources; the flight counter reserves GV9 FM0 for its persistent total.
- Next work: Verify the editor controls and file operations on the target-radio/EdgeTX matrix, then complete milestone 9 resource baselining. Initial dashboard validation passed on TX16S v2 with EdgeTX 2.12.4, as reported by the user on 2026-10-04.
- The retirement and software-hardening work is merged into `main`. The aircraft dashboard, compact-layout refinements, and initial hardware records are the current follow-up change set. See [Resuming work](#resuming-work) for the state and the exact next steps.

## Summary

Build a modern EdgeTX dashboard as one Lua widget running in the built-in `1 x 1` or App mode layout. The dashboard divides its available area into a logical 4 x 4 grid and hosts rewritten widget-like Lua panels. Each panel occupies a configurable rectangular set of contiguous grid cells.

EdgeTX does not support nesting independently registered widgets inside one layout zone. Panels therefore run under one dashboard host widget rather than as native child widgets. The host loads each panel from its own Lua file, creates its LVGL parent container, dispatches lifecycle calls, and persists the panel arrangement in a YAML file on the SD card.

## Goals

- Provide a logical 4 x 4 dashboard grid.
- Place a panel at any grid column and row.
- Allow rectangular panel sizes from 1 x 1 through 4 x 4.
- Load each panel implementation from a separate Lua script.
- Use LVGL parent containers for panel containment and clipping.
- Provide an on-radio UI for adding, moving, resizing, configuring, and removing panels.
- Persist layouts per model in human-readable YAML.
- Run without modifying EdgeTX firmware for the first implementation.
- Support App mode for an application-like, decoration-free experience.
- Support multiple independent AeroGrid instances for one model.

## Non-Goals

- Nest existing independently registered EdgeTX widget factories.
- Make unmodified third-party widgets run as dashboard panels.
- Add a native dynamic layout to EdgeTX firmware in the first implementation.
- Support non-rectangular or overlapping panel regions.
- Use the EdgeTX model YAML parser directly from Lua; it is not exposed by the Lua API.
- Provide internal multi-page dashboards; each AeroGrid instance renders one page.
- Automatically detect or increment a flight counter; the initial implementation only displays an existing global variable.

## EdgeTX Findings

### Native layouts

Color-screen EdgeTX currently provides these layouts:

- Uniform: Full screen (`1 x 1`), `1 x 2`, `1 x 3`, `1 x 4`, `1 x 6`, `2 x 1`, `2 x 2`, `2 x 3`, and `2 x 4`.
- Mixed: `1 + 2`, `1 + 3`, `1 + 4`, `2 + 1`, `2 + 3`, `4 + 2`, and `4 + 2B`.
- Special: App mode.

Native layouts use fixed C++ zone maps. `Layout::getZone()` converts each compile-time zone map entry into a screen rectangle. Lua widgets receive the resulting rectangle but cannot change their native zone allocation.

Relevant EdgeTX files:

- `../edgetx/radio/src/gui/colorlcd/mainview/layout.cpp`
- `../edgetx/radio/src/gui/colorlcd/mainview/layout.h`
- `../edgetx/radio/src/gui/colorlcd/layouts/`
- `../edgetx/radio/src/gui/colorlcd/mainview/datastructs_screen.h`

### Native layout limits

- `MAX_LAYOUT_ZONES` is currently 10.
- Native zone geometry is fixed by the selected C++ layout.
- A native 4 x 4 layout would require up to 16 zones.
- A fixed 4 x 4 native layout would only provide sixteen 1 x 1 zones; it would not provide arbitrary spanning without further firmware and persistence changes.

### Full screen layout

The built-in Full screen layout is a normal persistent `1 x 1` dashboard layout. It has one widget zone and retains the standard configurable layout options, including top bar, flight mode, sliders, trims, and mirroring.

### App mode

App mode is a persistent single-zone layout intended for application-like Lua widgets. It always disables:

- Top bar
- Flight-mode decoration
- Sliders
- Trims
- Mirroring

The widget can detect this layout through `lvgl.isAppMode()`. Activating the widget enters temporary widget fullscreen mode directly rather than opening the normal widget menu -- which hides EdgeTX's own menu button with it, so the widget must also ask `lvgl.isFullScreen()` before reserving the corner that button occupies.

Relevant EdgeTX file:

- `../edgetx/radio/src/gui/colorlcd/layouts/layout1x1AppMode.cpp`

### Temporary widget fullscreen

Temporary fullscreen is a runtime state available to a widget from any layout. EdgeTX hides the main view and decorations, expands the selected widget to the complete parent rectangle, captures interaction, and disables normal horizontal screen-swiping behavior. Exiting fullscreen restores the original layout.

This is distinct from both the persistent Full screen layout and the persistent App mode layout.

Relevant EdgeTX file:

- `../edgetx/radio/src/gui/colorlcd/mainview/widget.cpp`

## Architecture

```text
EdgeTX 1 x 1 or App mode zone
└── AeroGrid host widget
    ├── Layout manager
    ├── YAML configuration codec
    ├── Panel registry/loader
    ├── Lifecycle and event dispatcher
    ├── Dashboard editor
    └── LVGL panel containers
      ├── Cell battery panel
      ├── Metric panel
      ├── Flight timer panel
      └── Other catalog panels
```

Only the dashboard host is registered as an EdgeTX widget. Dashboard panels are ordinary Lua modules loaded and managed by the host.

### The standard panel

Most panels are variations of one arrangement: a heading, a dominant reading, an optional compact visual beside it, and an optional supporting row beneath. The decisions that arrangement rests on have always lived in `theme` -- the frame, the ladder, the bands, the band-derived font, the two slots, the fitting. The **assembly** did not: every panel repeated the same sequence of calls, and the same band was called `valueY` in one file, `nameY` in another and `clockY` in a third.

`theme.panel(resolved, rect, fonts, spec, out)` performs that assembly once. Three properties of its interface are deliberate and are the reason it exists rather than conveniences:

- **It fills a table the caller owns.** A reflow runs every panel on the screen inside one callback, and a helper that returned a fresh table would allocate once per panel per reflow.
- **It is told what the panel draws, never what its span permits.** `spec.draws` carries the panel's own answer, and `theme.ladder` may only narrow it. The interface has no way to express "permitted", because the gap between the two is a recurring defect in this project rather than a subtlety.
- **It builds nothing itself that the panel was handed.** It takes `spec.frame` rather than calling `theme.frame`, because the host wraps that function per panel to lay a panel out around the menu button's corner, and a shared helper reaching for the module's own copy draws the heading under the button.

Six panels use it: `cell-battery`, `flight-mode`, `flight-timer`, `link-status`, `metric`, and `text`. Three keep their own arrangement: `navigation` draws two supporting rows; `tx-battery` retains the arrangement recorded in the design guide; `model-identity` fits a picture and moves the model name into the heading. Three draw no panel reading and are exempt: `trim-panel`, `host-diagnostics`, and `service-probe`.

**A panel is expected to carry special code only where it has a special visualization** -- the compass, the battery glyph, the trim cells. A flag on the builder for one panel's preference is the thing this is meant to replace, not a way of extending it: a builder that can express everything expresses nothing.

**Font callbacks are installed once per label.** EdgeTX 2.12.4 overwrites
callback registry references without releasing the previous one when a
function-valued font is passed to `set`. Shared primitives therefore use
a persistent callback with mutable font state; all refresh/reflow paths
change that state with `primitives.setFont`, never replace the callback.
Weak object keys keep retired labels collectible. The firmware-like mock
retains overwritten references and regression tests assert none accumulate
during timer advancement, reconnects, or resizing. The user confirmed the
timer-correlated hardware memory fix on 2026-10-05.

### Bundled EdgeTX widget baseline

The bundled color-screen widgets are intentionally generic: Value, Gauge, Timer, Model Bitmap, Outputs, Text, Radio Info, Date/Time, and Internal GPS. AeroGrid should reuse their source selection and model APIs, but replace their presentation with a smaller set of responsive, domain-aware panels.

### Panel catalog

The initial release should provide these panels:

| Panel | Purpose | Classification |
| --- | --- | --- |
| `cell-battery` | Lowest/average cell or pack voltage, upright battery glyph, optional supporting voltage and measured/configured cell count; explicit bar mode retained | Specialized |
| `metric` | Up to three independently configured numeric readings | Generic |
| `text` | Up to three explicit physical-switch position text mappings | Generic |
| `flight-timer` | EdgeTX model timer with count-up or count-down presentation | Specialized |
| `flight-counter` | Qualified-flight GV9 FM0 total, disarm-timeout completion, blue active state, announcements, and CSV history | Specialized |
| `link-status` | RSSI, link quality, optional minimum quality, and link freshness | Specialized |
| `navigation` | GPS position, bearing from home to model, distance to home, and GPS state | Specialized and responsive |
| `flight-mode` | Current EdgeTX flight-mode name | Simple |
| `model-identity` | Model bitmap, model name, or both | Specialized |
| `tx-battery` | Transmitter voltage and optional battery indication | Simple; primarily intended for the status rail |
| `trim-panel` | Three configured effective trim positions in a centered three-axis square | Specialized |
| `service-probe` | The live state of one shared service, for diagnosis on the radio | Diagnostic |
| `host-diagnostics` | What the host loaded and what it resolved to, in one section per panel | Diagnostic |

Thirteen panels ship, two of them diagnostic. Two more, `heartbeat` and `placeholder`, live under `tests/fixtures/panels`: they prove the host contract and never ship. `service-probe` inspects a service on the radio; `host-diagnostics` reports what the host loaded.

The `metric` panel accepts an ordered `metrics` list of one to three
EdgeTX numeric sources. The first entry supplies the large reading and header;
the second uses the lower-left supporting slot, and the third the lower-right.
With only two entries the supporting reading is centred across the footer.
The shared panel builder tries a footer first, then a right-hand stack when
the footer cannot fit, then hides the supporting readings if neither fits.
Both supporting readings must fit as a group; neither arrangement shrinks the
primary reading. A surviving radial reserves the right slot and prevents the
side-stack fallback. This is an opt-in builder capability, used by the metrics
list; unrelated panels retain their presentations. Link status uses the same
stack geometry with its existing explicit `2x1` side presentation.

Each entry accepts `source`, optional `label` (defaults to the source name),
optional `unit`, and optional `precision` (integer 0–3). Units and precision
default independently to each sensor; an explicit empty unit suppresses it.
Units label values without conversion. An unavailable reading shows `--`
without a unit. Each entry also accepts `rangeMin`, `rangeMax`, `warning`,
`critical`, and `direction`; these describe that source, not the panel.
Only the primary entry's range and thresholds drive font sizing, visualization,
and panel alarms. Supporting entries do not drive visuals or panel alarms.
Visualization and accent remain panel-level settings.
Sensor extrema are ordinary sources such as
`GAlt-` and `GAlt+`; the list has no flight-session extrema option.

```yaml
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: altitude
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: GAlt
          label: ALT
          unit: m
          precision: 0
          rangeMin: 0
          rangeMax: 400
        - source: GAlt+
          label: MAX
          unit: m
          precision: 0
        - source: VSpd
          label: VS
          unit: m/s
          precision: 1
```

Each metric panel requires a `metrics` list. Sources, labels, units, precision,
ranges, and thresholds belong to individual entries; accent and visualization
belong to the panel.

### Panel requirements

#### Cell battery

- Accept an EdgeTX cells source. A cells source may return a table of individual voltages.
- Also accept a numeric pack-voltage source such as `RxBt` with explicit `sourceType: pack` and a configured integer `cells` count from 1 to 16. Never guess the count. The source must measure the pack, not a regulated receiver supply.
- For a pack source, offer pack voltage as the headline with average cell voltage and count underneath, or average as the headline with pack voltage and count underneath. The average is derived, not a measurement of individual cells; lowest-cell mode is refused without a cells monitor.
- Use the lowest valid cell voltage as the primary safety reading by default.
- By default show an upright battery glyph beside the reading, using the shared transmitter-battery primitive, with no bottom progress bar. Retain `visual: bar` for explicitly configured layouts. Scale either visualization over the configured usable voltage range, not from zero volts.
- Support warning, critical, stale, and unavailable states.
- Optionally show cell count and summed pack voltage.
- In text-only (`visual: none`) one-row panels at least two columns wide, allow count and supporting voltage in a right-side stack. Use the shared footer -> side -> hidden fallback without shrinking the primary. Disabled items reserve no empty stack row. One-row glyph/bar presentations do not support this stack; use two rows to combine the glyph with supporting values.
- Do not estimate remaining battery percentage unless a future panel explicitly defines and labels its estimation model.
- Validate the table rather than trusting it. Entries that are not plausible cell voltages are rejected instead of folded into a lowest or an average, the walk is bounded because the table comes from the firmware, and a value that is not a table at all is reported as a configuration mistake rather than as a missing source.
- Judge the thresholds on the worst cell even when the panel shows the pack sum, because a sum is exactly what hides one sagging cell.
- With a pack-voltage source, judge those same per-cell thresholds on the derived average instead. This cannot detect a weak cell or imbalance. See [`cell-battery` settings](../docs/panels/cell-battery.md).
- Allow an explicitly configured lowest-cell source, such as `Cels-`, to win for that reading. The receiver maintaining it has seen samples between the dashboard's polls, and it keeps the panel useful when the table itself is unreadable.

#### Metric

- Accept a primary source, optional extrema source, and optional secondary source.
- Preserve EdgeTX source units by default and support an explicit display-unit override where conversion is reliable.
- Allow extrema mode `source`, `flight`, or `none`, defaulting to `source`.
- In `source` mode, read an explicitly selected EdgeTX minimum or maximum source.
- In `flight` mode, use the shared flight-session extrema service.
- Altitude may show vertical speed only when a configured source is valid. Derived vertical speed is deferred until filtering and sampling behavior are defined.

#### Text

- Require an ordered `texts` list of one to three entries with `label`,
  a lowercase physical switch `source`, and `positions` mapping `up` and
  `down`, optionally `middle`. These correspond to `-1024`, `+1024`, and `0`.
- Use shared radio-local source subscriptions; never poll EdgeTX from the panel.
- Display the first entry as the main reading and the others as supporting
  captions/readings through the shared footer, side-stack, or hidden fallback.
- Fit all configured texts by measured width. Retain exact mapped text,
  selecting a smaller font rather than truncating. Refuse impossible main
  text with `NO FIT`; hide supporting text that cannot fit intact.
- Distinguish unavailable sources from unmapped positions. Infer neither
  aircraft state nor alarm colors from configured text.
- Static text and telemetry text sources are outside this panel's scope.

#### Flight timer

- Read `model.getTimer(index)` and preserve the model's configured count-up, count-down, persistence, name, and elapsed behavior.
- Do not implement a second timer engine.
- Support compact and detailed presentations based on available span.
- Clearly distinguish elapsed-beyond-zero state for countdown timers.

#### Link status

- Accept separate RSSI and link-quality source settings because protocols expose different sensors and units.
- Make link quality optional and never infer it directly from RSSI.
- Support an explicitly selected EdgeTX minimum-quality source and dashboard flight-minimum tracking.
- Treat stale or unavailable telemetry separately from a valid low reading.
- Allow protocol-specific multi-antenna values to be selected as ordinary sources without hard-coding a protocol.
- Distinguish three situations that all look like a zero: a link that is down, a protocol that populates no RSSI sensor, and a reading that genuinely is zero. The first is reported as critical with its own badge, because on this panel a dead link is the measurement rather than merely stale data. The second keeps whichever source the protocol does have and says the sensor is absent. The third is shown as the reading it is.
- Read that distinction from `telemetryService:link()` rather than inferring it again. Only the telemetry service knows whether a source has ever contradicted `getRSSI()`.
- Default no thresholds. What counts as a bad link depends entirely on the unit, and a default would warn constantly on dBm or never on a percentage.
- After a previously available reading loses the receiver link, replace the headline with `NO LINK`, omit its unit, empty any bar, and retain the critical state. Fit the wording to the available primary slot; restore numeric geometry on reconnection. This is a link-panel-only exception to retaining stale primary values. Before any reading arrives, retain the unavailable presentation rather than raising a critical alarm.
- Mark retained stale auxiliary readings with `*`; withhold RSSI margin when its inputs are stale. Supporting captions, RSSI, margin, and RF details use `textFaint`, matching metric and battery supporting readings.

#### Navigation

- Accept a GPS source.
- Use current and pilot coordinates returned by an EdgeTX GPS source to calculate distance and the initial bearing from the home/pilot position toward the model.
- Calculate distance and bearing from the GPS and home positions.
- Render direction as an absolute north-up bearing or compass arrow from home to model. Aircraft heading and transmitter orientation are not required and must not rotate this arrow.
- Provide responsive modes: compact distance, distance and bearing, north-up compass/bearing arrow, and detailed navigation with coordinates.
- `showBearing` and `showCoordinates` independently override the selected
  presentation's footer defaults. Omitted settings preserve the presentation;
  explicit booleans allow either row, both, or neither without changing the
  compass. Rows are still shed when the available height cannot hold them.
- Surface missing fix, stale GPS, and unavailable home-position states explicitly. A missing home position is not a broken fix: the coordinates stay visible and only the two values measured from home are withheld.
- Hide the dial's pointer when there is no bearing. A pointer resting at north reads as a real due-north fix.
- State in words that the direction is north-up and measured from home, because an arrow on a dial is exactly the thing a pilot would otherwise read as aircraft heading.

#### Flight mode

- Read the current mode through `getFlightMode()`.
- Support a compact status-rail presentation and a grid presentation.

#### Model identity

- Read name and bitmap metadata through `model.getInfo()`.
- Create the assigned image once, with `lvgl.image`, and retain the object. `Bitmap.open()` belongs to the legacy `lcd.drawBitmap` drawing model and cannot be rendered by an LVGL widget, so it is not used.
- Fall back to the model name when the image is missing or cannot be loaded. EdgeTX's `StaticImage` clears its source and reports nothing to Lua when a file will not decode, so the file must be checked with `fstat` before the image object is created. Where `fstat` is unavailable the name stays visible alongside the image rather than being hidden behind a picture that may never appear.
- Resolve the path as `/IMAGES/<bitmap>`, matching the firmware's own model bitmap widget.
- Support name-only, image-only, and combined presentations subject to panel span. An automatic choice must not spend space on a picture that a single cell cannot show.

#### Transmitter battery

- Read the EdgeTX transmitter-voltage source.
- Show voltage as the authoritative value.
- Treat any percentage or battery-fill estimate as optional and configurable because battery chemistry and voltage range vary by radio.
- Current `1x1` presentation is voltage-only; larger panels may add the glyph if it fits without shrinking the voltage.
- **Proposed, not implemented:** a glyph-only presentation for a compact `1x1` slot, centered without numeric voltage. Its fill would remain a voltage-range estimate, not measured remaining charge. The setting name and unavailable-state presentation still need design before implementation.

#### Trim panel

- Present trims inside a normal grid panel rather than along the display edges.
- Always display the configured aileron, elevator, and rudder sources in a square three-axis arrangement, with aileron above, elevator left, and rudder below.
- Use center-zero bars with persistent neutral markers, signed displacement, and optional percentage or raw readouts.
- Plot aileron and elevator together with a dot; keep the axis positions and directions fixed.
- Read effective current-flight-mode values through selectable EdgeTX trim sources so EdgeTX resolves trim inheritance.
- Persist the selected source for each axis, with defaults for aileron, elevator, and rudder.
- Remain read-only in the initial release; changing trims remains the responsibility of EdgeTX trim controls.
- Support `standard`, `extended`, and `auto` display scales. Auto may expand after observing a value outside the standard range, but cannot reliably detect the model's extended-trim setting because EdgeTX does not expose that flag to Lua. A trim source returns eight times the stored trim, and EdgeTX clamps that to `TRIM_MAX` or `TRIM_EXTENDED_MAX`, so the raw spans are 1024 and 4096, not 1000 and 4000. Rounding those down makes a standard trim held at its own end stop widen the scale permanently.
- Clearly represent centered, positive, negative, unavailable, and unsupported three-position trim states. A three-position trim returns full deflection or nothing, which is exactly what a standard trim at its end stop returns, so one sample can never distinguish them. `controlService` claims a toggle only after seeing both a centre and a full deflection with no intermediate position between them.

#### Global-variable readings

Use `metric` with ordinary sources such as `gvar1` and `gvar2`. EdgeTX resolves
the active flight mode, inheritance, and decimal scaling. Configure display
labels, units, precision, and visualization ranges explicitly; the ordinary
source API does not provide GV display metadata. The panel remains read-only.
A flight counter already stored in a GV can be displayed this way; AeroGrid
does not increment it or own its persistence. There is no separate GV panel,
no pinned-flight-mode display option, and no bipolar metric visualization.

### Status rail

Deferred. EdgeTX's own top bar already provides a configurable widget rail that reserves the same corner and costs no Lua instruction budget, and a dashboard-owned rail in App mode leaves no more grid area than inserting AeroGrid as an ordinary Full screen widget. The full reasoning, and the settled default should it be revisited, is under [Why there is no status rail](#why-there-is-no-status-rail).

Were it built, the optional dashboard-owned rail would carry model name, flight mode, transmitter voltage, link state, clock, and active timer items, reusing the same shared services as grid panels rather than polling again. Enabling it would reduce the rectangle available to the 4 x 4 grid and must trigger a complete grid geometry update.

### Shared services

The host provides shared services so panels do not duplicate polling, conversion, or tracking logic:

- `telemetryService`: source lookup, cached values, units, freshness, and stale/unavailable classification.
- `extremaService`: source, session, and flight minimum/maximum tracking.
- `navigationService`: GPS fix, pilot/home coordinates, distance, and absolute bearing from home to model.
- `modelService`: model identity, bitmap path, model timers, flight mode, and transmitter voltage.
- `controlService`: current flight mode, resolved trim-source values, global-variable values, bounds, precision, and units.
- `themeService`: resolved semantic colors, contrast correction, and state precedence.

Two rules keep that affordable, because every service update is charged to the same per-callback instruction budget as panel refreshes:

- A service only reads what a loaded panel subscribed to. A service nothing references is skipped entirely, so a dashboard of metrics never pays for GPS, trims, or global variables.
- At most one service is updated per host cycle, chosen round robin among those due, and each service caps how many subscriptions it refreshes in one update. Per-callback cost follows the caps, not the layout.

Panels consume immutable snapshots. A service mutates its own state table in place, which allocates nothing per cycle, and publishes a proxy whose writes raise. Services update before panel refreshes, so every panel rendering a cycle sees one consistent set of readings.

## Proposed SD-Card Structure

```text
/WIDGETS/AeroGrid/
├── main.lua
├── dashboard.lua
├── grid.lua
├── layout_store.lua
├── yaml.lua
├── panels/
│   ├── cell-battery.lua
│   ├── metric.lua
│   ├── text.lua
│   ├── flight-timer.lua
│   ├── link-status.lua
│   ├── navigation.lua
│   ├── flight-mode.lua
│   ├── model-identity.lua
│   ├── tx-battery.lua
│   ├── trim-panel.lua
├── lib/
│   ├── services.lua
│   ├── telemetry_service.lua
│   ├── model_service.lua
│   ├── control_service.lua
│   ├── extrema_service.lua
│   ├── navigation_service.lua
│   ├── theme.lua
│   └── ...
└── layouts/
    ├── Default.yaml
    ├── services.yaml
    ├── services2.yaml
    └── <model-identifier>--<dashboard-id>.yaml
```

EdgeTX automatically registers `/WIDGETS/AeroGrid/main.lua`. Files under `panels/` are loaded by the dashboard and are not independently registered widgets.

The package ships with bundled panels. Advanced users may add compatible panel files directly under `/WIDGETS/AeroGrid/panels/`. The host loads only panel types referenced by the active YAML, requires a compatible panel API version, and rejects unsafe names and paths.

The widget `create(zone, options, path)` callback receives the widget folder path. Panel scripts can therefore be loaded with:

```lua
local chunk, err = loadScript(path .. "panels/cell-battery.lua")
if not chunk then
  error(err)
end
local panel = chunk()
```

## Grid Model

The dashboard uses zero-based logical coordinates:

- `col`: 0 through 3
- `row`: 0 through 3
- `colSpan`: 1 through `4 - col`
- `rowSpan`: 1 through `4 - row`

Panels must occupy contiguous rectangular cells and must not overlap.

Pixel boundaries are calculated independently to avoid cumulative rounding gaps:

```lua
local x1 = math.floor(item.col * zone.w / 4)
local y1 = math.floor(item.row * zone.h / 4)
local x2 = math.floor((item.col + item.colSpan) * zone.w / 4)
local y2 = math.floor((item.row + item.rowSpan) * zone.h / 4)

local rect = {
  x = x1,
  y = y1,
  w = x2 - x1,
  h = y2 - y1,
}
```

The host creates one LVGL box or equivalent parent object for each rectangle. Panels use coordinates relative to their own parent. Recursive LVGL children and explicit parent objects are supported by EdgeTX in `api_colorlcd_lvgl.cpp`.

## Visual Design Direction

**The design decisions and their reasoning live in [`aerogrid-design-guide.md`](aerogrid-design-guide.md).** Ten panels draw a panel reading: seven assemble it through `theme.panel`, while `model-identity`, `navigation`, and `tx-battery` use shared slots directly. All thirteen shipped panels use `theme.frame`. The three without a panel reading are `host-diagnostics`, `service-probe`, and `trim-panel`.

The claim was true when this section was first written and survived the milestone that built it, the presentation pass, the vertical-rhythm pass and the #85 audit -- which corrected the same sentence in the design guide and did not find this copy. **That is the shape worth naming: a claim copied into two documents is corrected in one of them.** It is the fifth time in this project, and it is the most dangerous kind of stale, because a reader is told that a section describing working behaviour is aspirational and may build it a second time.

The default interface should feel like a modern flight instrument rather than a collection of legacy widget boxes. The supplied references establish the intended direction: dense and glanceable, with strong numeric hierarchy, restrained color, crisp panel boundaries, and minimal decoration.

The primary reference viewport is 480 x 272, matching the TX16S and several other color-screen targets. The same layout model must scale to other supported color displays without scaling type directly from viewport width.

### Design principles

- Optimize for recognition during flight: the current value, unit, label, trend, and warning state must be distinguishable at a glance.
- Use dark neutral surfaces with luminance separation rather than a one-hue dark blue or slate palette.
- Reserve saturated color for meaning: cyan for electrical or selected data, green for healthy/current state, amber for caution, red for critical state, and orange only where it identifies a distinct measurement family.
- Use one dominant reading per panel. Supporting values must be visibly secondary.
- Keep panel framing quiet. A panel is defined by its elevated fill against the darker screen, not by an outline. Prefer surface separation and a narrow semantic accent over any stroke.
- **The fill is a condition of the data; the outline is where the interaction is.** Warning and critical tint the panel's field and draw no border. Selection and editing draw the border and are the only things that do. Area is seen in peripheral vision where a line is not, which is what matters on a moving aircraft: an outline has to be looked at, a tinted field is noticed while looking elsewhere. Keeping the two apart also means a panel can be alarming and focused at once, which it could not while the border carried both.
- Stale and unavailable are in neither group. They dim, because absent data is not an alarm and a panel that shouted whenever a sensor went quiet would teach a pilot to ignore it.
- An alert tint is derived from the state's own accent rather than stated, so a palette taken from the radio tints from the surface the radio gave it. It is mixed by the smallest amount that is noticeable beside an untinted panel, because every step beyond that spends contrast the text drawn on it has to give back, and it may be darkened as well as lightened: a dark surface tints by moving toward a bright accent, and a mid-grey one has no room to lighten without losing the faint text on it.
- **Every guarantee the resting surface carries is re-checked against each tint.** None of them transfer. Body, muted and faint text, elevation above the screen, separation from an untinted panel, and the state's own accent all have to hold on the tinted field, and a palette where none can is left untinted rather than made illegible.
- Avoid ornamental gradients, glow effects, glossy styling, decorative blobs, and excessive gauge rings.
- Keep animation purposeful and sparse: value interpolation, state changes, and editor transitions only.
- Preserve stable geometry when values, units, labels, or warning states change.

### Screen composition

- A compact status rail across the top was specified and is deferred; EdgeTX's own top bar fills that role at no cost to the Lua budget. See [Why there is no status rail](#why-there-is-no-status-rail).
- In App mode the top-left 47 x 45 corner belongs to EdgeTX's menu button. Panels lay out around it through `theme.frame` rather than the grid surrendering a strip. A reading on that panel is centred on the panel like any other, but never above the button's own bottom edge and never larger than what the button leaves below it -- so the corner keeps the half-height budget while the button is drawn, and gains nothing from the whole-panel one.
- **While the button is drawn.** Taking the widget fullscreen hides it -- `ViewMain::onLongPress` calls `setFullscreen(true)` (`radio/src/gui/colorlcd/mainview/view_main.cpp:313`), `Widget::setFullscreen` runs `ViewMain::instance()->show(!enable)` (`radio/src/gui/colorlcd/mainview/widget.cpp:224`), and `ViewMain::show` passes that to `setEdgeTxButtonVisible` (`view_main.cpp:327`) -- and the corner is then released, so that panel follows every other panel. `lvgl.isAppMode` cannot see it, because `LayoutAppMode::isAppMode` returns a constant `true` (`radio/src/gui/colorlcd/layouts/layout1x1AppMode.cpp:40`); `lvgl.isFullScreen` can. **The Lua name has a capital S**: the C function is `luaLvglIsFullscreen` (`radio/src/lua/api_colorlcd_lvgl.cpp:402`), the name it is registered under is `isFullScreen` (`api_colorlcd_lvgl.cpp:447`), and a guarded read of the wrong spelling answers false rather than failing.
- **Nothing about the zone changes when that happens**, so the reflow trigger reads the flag rather than waiting for a geometry change. On a `Layout1x1AM` screen the widget already has the whole display; entering fullscreen does call the widget's `update` (`widget.cpp:265`) and leaving it does not, that call being guarded by `if (fullscreen)`. The reflow therefore arrives on the next callback -- one `MENU_TASK_PERIOD`, 50 ms (`radio/src/tasks.cpp:50`) -- at a cost of 15 instructions a frame.
- Use a compact footer only for genuinely global data such as coordinates or an active flight timer. Do not reserve footer space by default.
- Use 4 px outer margins and 4 px grid gutters at 480 x 272 as the initial baseline, subject to hardware verification.
- Panel panels use an 8 px corner radius. The originally specified 4 to 6 px reads as a square panel with the corners shaved at 480 x 272, and the reference design's corners are visibly softer. Nested cards are prohibited.
- The semantic accent occupies a column exactly one accent width across, down the panel's left edge, and fills whatever of the panel lies inside that column. Between the corners that is the full width; through each corner it narrows as the panel's own curve crosses the column, reaching nothing where the curve leaves it. It never extends past the accent width and never leaves the panel's rounded shape.
- It is built as a straight rectangle and two quarter-circle arcs, inside a clipping container. The straight run spans `y = radius` to `y = height - radius`. Each corner is an `lvgl.arc` centred on the panel's corner centre with the panel's corner radius and a thickness of the accent width, so its outer edge is exactly the curve the panel's fill is rounded by. Unclipped, those arcs reach `2 * radius` across; the container removes everything beyond the accent width.
- That the outer edges coincide follows from the firmware. LVGL draws an arc band between `radius` and `radius - width` measured from the centre (`lv_draw_arc.c`, `rout` and `rin`), and the object's box is `2 * radius` square about the position EdgeTX was given (`LvglWidgetArc::build` calls `setRadius`; `get_center` in `lv_arc.c` takes `min(w, h) / 2`). Rasterising with the clip simulated confirms the result: within the accent's column the accent covers exactly the panel's own pixels, on every row of every panel size tried, with nothing outside the column and nothing outside the panel.
- Corner bands are arcs, so hard-won constraint 11 applies. Every colour change is a `set`, and a `set` on a round object walks it up and left by its own radius unless the centre is restated, so both bands go through the shared `setRound` helper.
- A panel spanning several cells remains one coherent panel; it must not visually imitate multiple unrelated cards unless its data model genuinely contains repeated items.

### Typography and values

- Use EdgeTX-provided fonts and font sizes to avoid extra memory cost unless a later target-specific benchmark permits a bundled font.
- Use tabular or fixed-width numerals where available so changing values do not shift adjacent content.
- Labels are short, uppercase where appropriate, and visually quiet.
- Primary values use the largest size that fits their panel at every supported span.
- **The unit rides beside the value, on its baseline, at a smaller size and lower contrast.** It is its own label rather than characters of the reading, so the reading is digits alone and the two are measured together but drawn apart. Two steps down the reading ladder puts it between two fifths and three fifths of the number's height at every pairing the dashboard produces.
- **Baseline alignment is exact, and EdgeTX does not help.** The only font metric a script can ask for is `lcd.sizeText`, whose second return is `getFontHeight`, which is `lv_font_get_line_height`; nothing in `radio/src/lua/` exposes ascent or baseline. The numbers are nonetheless knowable, because `base_line` is a compile-time constant of each shipped font, sitting beside the line height in `radio/src/fonts/lvgl/std/lv_font_en_*.c`, and `lv_draw_sw_letter` places a glyph at `pos.y + (line_height - base_line) - box_h - ofs_y`. Aligning the two labels' **tops** instead puts the unit 31 pixels high at the largest pairing; aligning their **bottoms** puts it 9 pixels low, which is most of a `MIDSIZE` descender. Neither approximation is needed, and the suite fails if one is reintroduced.
- Supporting values and captions must remain legible on the physical radio, not merely in the simulator.
- Letter spacing is zero. Text must wrap, abbreviate, or reduce to a defined smaller font before it clips.
- A supporting row cannot shrink its font, because it is already at the smallest size the dashboard uses. A row therefore offers its wordings longest first, and `theme.fitLabel` takes the longest that fits the width it will actually be given. **Every supporting row in the catalogue is meant to go through it**, and most offer one wording, because one well-chosen form fits every panel that draws a row.

  **Five of the seven panels that draw a row call it today**: `cell-battery`, `flight-timer`, `link-status`, `navigation`, and `tx-battery`. `flight-mode` writes its single form directly; `metric` uses measured widths and the shared builder to choose a footer, side stack, or hidden supporting group.

  The two budgets a row is written against: **105 px** for a row spanning the panel at `1 x 2`, the narrowest panel the ladder grants a row at all, and **86 px** for one sharing a line with another at `2 x 2`. A form that clears the tighter of those cannot be broken by any arrangement this dashboard can reach.

  **The property is that the row fits**, and `testSupportingRowsFitTheirBox` holds it directly, at every span that grants a row, in both zones, with each panel driven into the state that words the most. That is the check that was missing: `flight-timer` drew `ELAPSED PAST ZERO`, 125 px into that 105 px box, and it was centred on a box wider than its panel and ran ten pixels off each edge. Nothing caught it, because the suite could only check which panels *called the helper* -- and that panel did not, so there was no rule for it to be seen breaking.

  **Corrected twice, and the second correction reverses the first.** On finding that five of eight row-drawing panels called `fitLabel`, this sentence was rewritten to say that the mechanism was the wrong thing to require and the property was all that mattered. The user decided the other way: the sentence was right, the code was wrong, and every row should go through the helper. The measurements support them -- routing a single-wording row through `fitLabel` costs nothing, since a one-entry list comes back unchanged, and having one path for every row is worth more than the exception. **What was salvaged from the first correction is the property check**, which the mechanism alone would not have given: calling the helper does not make a form fit, and only a measurement can say that it does.

  **A ladder earns its place only where the longer form carries something the shorter cannot**, and there is a panel wide enough to show it. That is a judgement about wording rather than about width. Most states in the catalogue have no such pair, which is why most rows are one form.

- **A panel's composition is decided from its box, not by the panel drawing it.** One shared ladder says whether a panel of this size carries a supporting row and a visualization, and every panel gets the same answer. A panel may decline what it was granted; it cannot claim what it was not. Eight private copies of that decision were why two panels of identical size disagreed: each had shed a different amount before measuring anything.
- **A reading's font follows from that composition, not from its own string.** Two panels of one size agree because they are answering the same question. Before this the four panels of the `2 x 2` span gallery drew their readings at XXLSIZE, DBLSIZE, MIDSIZE and SMLSIZE, a range of four to one, on panels identical to the pixel.
- **A form may drop redundancy, never magnitude.** A reading offers lossless wordings longest-first and `theme.fitReading` takes the largest that fits; where none does, the font steps down instead. A unit the panel's own label already states, a name, a suffix: those are redundancy and may go. A digit of precision, or a field of a clock, may not. `4.44V` to `4.44` removes something the panel says elsewhere. `1:04:12` to `04:12` removes an hour and reports a different reading, which a pilot would believe and no font size is worth. `888.88km` to `888km` removes 880 metres of a number someone is flying by.
- A panel whose reading holds no redundancy offers exactly one form, and that is how it says so. Every reading is now of that kind, because the unit left the string: `flight-timer` draws a clock, `navigation` draws a distance, and the other four print digits with the unit beside them. What used to be a second form -- `4.44V` shortened to `4.44` -- is no longer a wording at all, it is whether the rider is drawn.
- **A unit is dropped rather than paid for with a size.** The reading is fitted first and the unit rides at whatever font that produced, or it is not drawn. Buying the unit by shrinking the number would be paying for redundancy with magnitude, and the first thing a pilot reads is how big the number is. The change from a glued-on unit is that dropping it is now rare rather than routine: a `V` beside an `XXLSIZE` number cost 40 pixels as a character of the reading and costs 23 including its gap as a rider.
- **A unit qualifies a value, so a panel with no value draws no unit.** A reading that has nothing to report prints a sentinel -- `--` everywhere, and `N/A` where `link-status` has a source the protocol does not publish -- and a unit beside one says the pack is measured in volts and declines to say how many. Four panels drew that: `tx-battery` and `cell-battery`, whose unit is a constant they know before any reading arrives, and `link-status` and `metric`, which keep a resolved sensor's unit while its value is withheld.

  **The test is on the string the panel is drawing, and it is in `primitives` rather than in any panel.** That is the [permitted-versus-drawn seam](#fixture-discipline) again: whether a panel is *allowed* a unit is settled when it is built, from its box, and whether there is a value is not knowable until there is one. Nothing in the build-time answer can carry the runtime one, so the two meet at the point of drawing, which is the only place both are known.

  **Freshness is the wrong key and availability is nearly the wrong key.** A `stale` reading still shows its last number and keeps its unit, because staleness is about how old a measurement is rather than whether there is one. A sensor reading exactly zero prints `0` and keeps its unit, because this specification is explicit that a valid zero is the reading it is -- and `link-status` exists in part to separate a genuine zero from a dead link, so a rule that caught zeroes would be wrong in precisely the panel that cares most. Only the sentinel means there is nothing to qualify.

  **The reading does not move when the unit goes.** Its x is `valueCentre - measureText(font, text) / 2`, its own width and not the pair's, so the unit only widens the drawn box; taking it away shrinks that box and leaves the digits where they were. Nothing is laid out from that box -- supporting rows and compact visuals take their positions from the panel's own slot centres -- so hiding is the whole of the change and there is no space to reclaim. Had it been false, a sensor dropping and returning would twitch the reading each time and hiding would have been the wrong answer, which is why it is measured by `testUnitNeedsAValueToQualify` rather than assumed.
- **A unit that carries magnitude is not redundancy and is never dropped.** A distance's unit changes with its range, so `1.23km` and `1.23m` are different readings rather than one abbreviated. `navigation` says so, and for it the pair is what the ladder is walked against: the number steps down until both fit, because a distance with no scale on it is worse than a small one.
- Stepping down one size is the intent and is what happens almost everywhere, but it is not a cap: the alternative to stepping again is clipping, which is never acceptable. A panel needing two steps is saying its column is genuinely too narrow, which happens where a dial takes half the width.
- **A badge names the state; the supporting row says why.** The badge vocabulary is a closed set on the theme, and short, because the column is reserved on every panel whether or not a badge is showing: a long word is paid for by every header on the dashboard rather than by the state that uses it. Panels do not override it. A distinction such as a dead link against a protocol with no RSSI sensor belongs in the row, which is fitted to its width and words it at whatever length fits.

  **Corrected: the example this sentence was built on is no longer a distinction the row makes.** It read "a cells sensor returning a number against one returning nonsense", and that pair has been merged: `cell-battery` prints `CELLS ERR` for both. Neither width nor vocabulary forced it -- `NOT CELLS` and `BAD CELLS` are 67 and 66 px against budgets of 105 and 86, so both fitted comfortably. **The test is whether the reader can act on the difference, and a pilot cannot.** Both mean something is arriving and is wrong, and both are fixed on the ground; only `NO CELLS`, which means nothing has arrived and may yet, asks for something else, which is to wait.

  So the rule the row is held to is narrower than "say which failure occurred": **say what the reader should do about it.** Two failures with one remedy are one thing to say. The distinction itself is not discarded -- `summarize` still separates five shapes and the host diagnostics view still reports which arrived, because someone at a desk *can* act on it. It is withheld from the panel rather than lost.

  This is the fourth time a claim here has outlived the thing it described, and the shape is the same each time: the sentence was written while the example was true, the example changed, and the sentence went on being quoted. The defence is not care but the example itself -- **an argument carried by a concrete case has to be re-read whenever that case moves**, which is why this one names its cases rather than gesturing at them.
  **What carries that distinction is the vocabulary, not the width**, and the difference matters because the width changed. This sentence used to say the row "has room for words", which was true of a row spanning the panel and stopped being true when a two-item row moved onto the panel's slot centres: each item now gets 40% of the content where the split it replaced reached all of it. A defence resting on room would have been quietly false from that moment, in the same way the claim about compressed font advances sat here being wrong for a milestone.

  So the property is stated as something a test can hold: **the shortest wording of each state a row reports must differ from the shortest wording of every other state it reports.** The shortest form is what a cramped panel prints, so a row can be as narrow as the layout makes it and still say which failure occurred. `navigation` keeps `NO GPS` against `NO FIX` -- no sensor against a sensor with no fix -- and `link-status` keeps `DOWN` against `NO RSS`. `cell-battery` keeps `NO CELLS` against `CELLS ERR`: wait, against go and fix it. Shortening costs detail and must never cost meaning; `testSupportingWordingsStayDistinct` is what holds a panel to it.
- The badge column is exactly as wide as its widest word, and is never squeezed. Clamping it to a fraction of a narrow panel protects the label by clipping the badge, which is the wrong way round: `CRIT` and `CRI` are not equally alarming, while a shortened source name is merely less informative. A header label with too little room left is dropped rather than clipped, on any panel, not only one obstructed by the menu button.
- Horizontal padding is asymmetric. The left clears the accent; the right has nothing to clear, so it is smaller. On a single cell those four pixels are a character of header label.
- **The badge column is reserved whether or not a badge is showing, and the header label's width never depends on whether one is.** Handing the label the empty column and taking it back when a badge appears would reflow the label at exactly the moment the panel changes state. That is worse than a permanently shorter label, and not by a little: a header that moves draws the eye to itself, at the instant the reading beside it has just gone critical and is the thing that needs looking at. It is also the stable-geometry rule above, which requires that a warning state does not shift neighbouring content. Every panel in the catalogue can reach a badged state, so a column that was conditional would be conditional on nothing in practice.

### Initial color tokens

Exact colors require physical-display testing, but panels must consume semantic theme tokens rather than hard-coded colors:

```lua
local theme = {
  canvas = 0x0A0C0E,
  surface = 0x212830,
  surfaceRaised = 0x2E3841,
  border = 0x3A434B,
  text = 0xF4F6F7,
  textMuted = 0xDCE2E6,
  textFaint = 0xC4CDD3,
  cyan = 0x70D6F3,
  green = 0x55D990,
  amber = 0xF2B84B,
  orange = 0xFF762E,
  critical = 0xF05252,
}
```

Panels may select a semantic accent, but the dashboard should not become a rainbow of unrelated panel colors. Warning and freshness states override decorative accents.

### Panel anatomy

A typical telemetry panel should contain only the elements it needs from this hierarchy:

1. Short label or source name.
2. Primary value and unit.
3. Optional secondary value, limit, maximum, or trend.
4. Optional compact visualization such as a bar, arc, direction indicator, or sparkline.
5. A narrow state accent or warning treatment.

Panels must define responsive presentations for the spans they support. A 1 x 1 panel may show only a value and label; a 2 x 1 variant may add units and a trend; a larger variant may add history or related measurements. Unsupported spans must be rejected by panel metadata rather than producing a cramped layout.

#### A visualization beside the reading, not beneath it

A bar sits under the reading and costs it nothing but height, which the ladder already accounts for. A **battery glyph** sits beside it and costs it width, and width is what decides the reading's font.

**A reading is never shrunk to make room for something beside it.** It takes the size the whole panel allows, and the visualization then either fits in what remains or is shed. This is the same order this document states everywhere else -- a form may drop redundancy, never magnitude -- applied to a decoration rather than to a unit: a dial is the most droppable thing on a panel and the number is the least, so the number is not what pays.

This corrects an earlier rule, which allowed **one** step down to keep a visualization and shed it only at two. That was wrong in a way worth recording, because it could charge a reading for something it did not receive: the reading was narrowed to half the panel so a dial would have somewhere to go, the dial was then found not to fit anyway, and the panel drew a smaller number and no dial. The two halves of that decision were made in different places, which is the recurring seam this document describes, and they are now one question answered once -- by `theme.slotsFor`, the only thing that knows how wide the reading turned out to be.

`tx-battery` already behaved this way, taking its font from the band rather than from the fitting ladder, so it is the pattern rather than the exception. The `metric` at `1 x 2` trades its dial for two font sizes.

The glyph is sized by search rather than by formula. The answer is not smooth: a glyph one pixel narrower can be the difference between a reading keeping XXLSIZE and dropping to DBLSIZE, and there is no expression for where that edge falls that is not the loop written out longhand.

`primitives.batteryGlyph` is three rectangles, because `lvgl.box` accepts a `color` and silently ignores it. Its outline is built at its final weight and never restated, since a border width only reaches LVGL through `LvglWidgetBorderedObject::setOpacity` and is discarded by a later `set`; the **fill** carries the state, the way a bar's fill does and its track does not. An outline with no fill is a picture of a flat pack, so a panel with no range to measure against hides the whole glyph rather than drawing it empty.

**A compact visual sits on the optical centre of the reading's ink.** Not its baseline, not its top, and not its line box. This was decided from rendered mocks rather than argued: the three were drawn side by side from the real geometry at every span, and the centre is the one that reads as belonging to the number rather than hanging off it. It applies to every compact visual in every panel -- a battery, a dial, a compass -- so two panels of different panels at the same span place theirs identically. A visual that spans the panel's width, which is to say a bar, has nothing to centre against and is unaffected.

It said **line box** until the band started being measured as ink, and the two are not separable: a line box carries a descent and a leading that no reading in this catalogue draws into, so centring the box centres a rectangle taller than the glyphs and leaves the number sitting high. Choosing the font by ink and centring the box would have split the two by 4.5 px on a `navigation 4 x 2`. The design guide records the decision and what it cost.

**Content is placed on two slots derived from the panel, at 30% and 70% of the content width.** Agreed from rendered mocks and **implemented by every panel that puts two things side by side** -- six through `theme.panel` and three directly.

*Corrected: this said "not yet implemented by any panel", the second copy of the same stale claim in this file.* The reading takes the left slot and a compact visual the right, and every row below them uses the same two centres -- a row of one item centres across the whole content box, a row of two takes the slots -- so the arrangement is one rule at every level rather than a body rule with a footer exception. A panel holding only a reading does not split; it centres across the whole box.

The point of deriving the slots from the panel rather than from the content is that a slot cannot move when what is in it changes width, and across a row of equal-width panels every reading lands at the same x. Two earlier proposals were rejected for failing exactly that: left-aligned flow collects all its slack after the content, and fully centred content re-centres whenever a reading gains a digit, which put its reading 186px from its own heading against the slotted 91.

**Where the tightened slots would let two elements meet, the panel falls back to strict halves at 25% and 75%, and the fallback is decided at build from the widest string the panel can print.** Deciding it from the current value would make the arrangement a function of the data: a voltage crossing from `9.9` to `10.0` would flip the whole panel between two layouts, which is the moves-when-content-changes objection that ruled out centring, in a worse form. Asking the widest form fixes the arrangement once, so a panel with room to spare today keeps the layout it will need at its widest. The fallback is per panel and never per row -- a tightened body over a strict footer would leave the columns disagreeing down the panel, which is the one thing slot-derived positions exist to prevent.

### States

- `normal`: Elevated panel with a semantic measurement accent, and no outline.
- `selected`: Clear focus outline suitable for touch and rotary navigation.
- `stale`: Muted value plus an explicit stale indicator; color alone is insufficient.
- `warning`: Amber accent, a tinted panel field, and concise threshold indication. No outline.
- `critical`: Red accent and a tinted panel field, with high contrast; avoid continuous distracting animation. No outline.
- `unavailable`: Placeholder label identifying the missing source or panel.
- `editing`: Visible grid, selection bounds, and resize or move affordances without obscuring readings unnecessarily.

### Theme ownership

The host owns theme tokens and passes the active theme to every panel. Panels must not define independent background palettes. Panel-specific configuration may choose a semantic accent only from host-provided tokens. A global theme may be exposed as a native host widget option and persisted by EdgeTX.

The host provides complete named themes from separate `.yml` files. The
`modern-dark` and `modern-light` palettes are shipped entries; user themes live
under `/AEROGRID/themes/` and override same-named shipped files. Each theme
defines all color tokens, spacing, and optional alert-tint preferences. A
separate append-only theme registry preserves the Theme widget option's
positions. Layout documents do not select or override themes.

The dashboard must never call `lcd.setColor()` because doing so changes the entire radio interface and other widgets. Follow EdgeTX mode maps Primary, Secondary, Focus, Edit, Active, Warning, and Disabled roles into dashboard tokens, then applies contrast correction and dashboard fallbacks where EdgeTX has no suitable role. Critical red remains dashboard-controlled. Warning and critical colors are not independently configurable per panel.

## Panel Contract

Each panel script returns a table implementing this interface:

```lua
return {
  id = "battery",
  name = "Battery",
  version = 1,

  settings = {
    {
      key = "source",
      label = "Voltage source",
      type = "source",
      default = 0,
    },
    {
      key = "warning",
      label = "Warning voltage",
      type = "number",
      default = 14.0,
      min = 0,
      max = 100,
      step = 0.1,
    },
    {
      key = "showLabel",
      label = "Show label",
      type = "boolean",
      default = true,
    },
  },

  create = function(parent, rect, config)
    return {}
  end,

  update = function(context, rect, config)
  end,

  refresh = function(context)
  end,

  background = function(context)
  end,

  event = function(context, event)
    return false
  end,

  destroy = function(context)
  end,
}
```

### Required callbacks

- `create`: Builds the panel's LVGL objects and returns private context.
- `refresh`: Updates visible state.

### Optional callbacks

- `update`: Applies changed geometry or configuration.
- `background`: Performs low-frequency work while the dashboard is not visible.
- `event`: Handles an event and returns true when consumed.
- `destroy`: Releases panel-owned references before rebuilding or removal.

Panels must not assume full-screen dimensions. They must use the supplied rectangle and adapt to all supported spans.

Each panel must also publish supported spans or minimum dimensions so the editor can prevent visually invalid placements. The host passes shared theme and service objects through the panel context or an additional services argument; panels must not duplicate global styling or telemetry caches.

## Panel Settings

Legacy EdgeTX Lua widgets declare a static `options` array. EdgeTX converts each option type into a settings control, stores the selected values in the model's `WidgetPersistentData`, and passes an options table to the widget's `create` and `update` callbacks. A `SOURCE` option stores the selected source identifier; the widget later reads its live value with `getSourceValue(sourceId)` or `getValue(sourceId)`.

AeroGrid has only one native EdgeTX widget and therefore only one native option set. The host cannot ask EdgeTX to create independent native settings pages for dynamic child panels. Instead, every panel publishes a typed `settings` schema and the dashboard builds an equivalent LVGL form in its own editor.

### Supported setting types

The initial panel schema should support:

- `source`: EdgeTX source and telemetry picker
- `switch`: EdgeTX switch picker
- `number`: Bounded numeric editor with optional step
- `boolean`: Toggle
- `choice`: List of declared values and labels
- `color`: Color picker
- `string`: Text editor
- `timer`: Model timer picker
- `file`: File picker with a declared base path and filter

Additional types may be added without changing the layout schema. Each setting definition must have a stable `key`, display `label`, `type`, and `default`. Types may define relevant constraints such as `min`, `max`, `step`, `choices`, `path`, or `filter`.

### Settings vocabulary

Eleven shipped panels and two fixtures, written to the same contract by different sessions, produced five names for "how should this look", four meanings for `min`, and a per-panel setting for a dashboard-wide singleton. Names are part of the contract, not decoration: a layout author reads one panel and expects the next to answer the same question the same way. The rules below are what the vocabulary converged on.

**One name per concept.** Three questions exist and each has exactly one key:

- `visual` — the shape the reading is drawn as: `bar`, `radial`, `none`. It selects a drawing, never content.
- `presentation` — which arrangement of content the panel shows when several are possible and the box decides between them. Only `navigation` and `model-identity` have more than one arrangement.
- `reading` — which of the panel's own values leads the panel when it holds several, as `cell-battery` holds lowest, pack and average.

A panel that offers one of these but not the others declares only the one it offers. `display` and `primary` are not used; both were re-spellings of `reading`, and `display` also stood in for `readout` on `trim-panel`, which is neither.

**Every enum declares its `choices`.** A `string` setting whose values are drawn from a fixed list must declare them, so the loader rejects `presentation: nonsense` at load with the panel and key named, rather than falling back silently and leaving the author to wonder why the panel looks wrong. Undeclared keys are reported the same way: a renamed setting left behind in a layout is a defect, not a comment.

**A setting whose meaning is decided at runtime is refused, not documented.** `link-status` can lead with RSSI in dBm or with link quality in percent, and under `reading: auto` the choice is made by whichever source the protocol publishes. A threshold is a bare number, so `warning: 50` is plausible in both units and means a different thing in each, and nothing downstream can tell: the panel alarms at the wrong moment rather than failing. The first pass at this vocabulary named the unit "the leading source's", which described the trap precisely and left it in place. That was the wrong call. A panel may state a rule spanning two of its settings through `validateSettings`, and this one refuses a threshold unless `reading` names a source. The shipped dashboard was relying on the old behaviour, with percentage thresholds under `auto`, and `auto` falls back to RSSI when no quality sensor exists — where every reading is below 30, so that panel would have sat permanently critical on any protocol without one.

**A setting must have more than one answer a layout could sensibly give.** Where the answer is fixed by what the value physically is, the behaviour is documented rather than configured. `direction` was added to every panel with thresholds, and on five of them there was only ever one answer: a voltage and a link quality alarm downward, a distance from home upward, and a timer's direction is EdgeTX's own `countdown` flag, which `flight-timer` had always read instead of the setting. A setting with one valid value is not configuration; it is a fact spelled as a question, and it makes a reader wonder what the other value would do. Only `metric` keeps `direction`, because it reads an arbitrary source and a current, a temperature and an altitude genuinely alarm upward where a voltage and an RSSI alarm downward. The suite holds every declared `choices` list to more than one entry.

**Use source metadata where the source interface supplies it, and allow explicit overrides.** `tx-battery` reads the radio's battery-meter range through `getGeneralSettings`. Metric telemetry sources supply units and sensor precision; ordinary GV sources require explicit display settings because that interface does not publish their metadata.

This is the same shape as `armSource` moving to the layout's session block: both were a panel asking for something that was already known somewhere else. When adding a setting, the question to ask first is whether EdgeTX can be asked instead.

**Thresholds state their direction and their unit.** `warning` and `critical` are bare numbers, so nothing about them says whether crossing downward or upward is the alarm, or what they are measured in. Both are stated: `direction` is declared by every panel that has thresholds, and the unit belongs in the setting's label — `Warning volts per cell` and `Warning seconds`, not `Warning`. Where the unit genuinely depends on configuration, as `link-status` measures in whatever its leading source reports, the label says so rather than naming a unit that may be wrong.

**A range is named for what it bounds.** `min` and `max` meant a normalisation range, a per-cell voltage range, a whole-pack voltage range and a bar-only range, in four panels, all under one word. The range now carries its subject: `rangeMin`/`rangeMax` normalise a visualization, `cellEmpty`/`cellFull` bound one cell, `packEmpty`/`packFull` bound a pack, `barMin`/`barMax` bound a bar. A normalisation range is not a limit, and stating that in its comment is worth the two lines: a value outside it is still drawn as itself.

**Dashboard-wide state belongs to the dashboard.** A setting that describes the session rather than the panel belongs in the layout's top-level `session` block, not in each panel's `config`. `armSource` was per-panel, which let two panels name two different switches while the extrema service documented that the first caller wins — so the second was configured, accepted, and ignored. Anything that a second panel could contradict is a candidate for the same move.

**Accent defaults follow the colour rule.** The palette reserves cyan for electrical data and green for healthy state; a panel's default accent obeys that rather than its author's taste. `tx-battery` was green and `cell-battery` cyan for the same concept.

**An empty `label` means derive, not omit.** Panels whose heading is only knowable at runtime leave `label` empty by default — for example, the timer's name or the probed service. A panel with a fixed heading states it as its default. The empty string is a deliberate instruction and each such declaration says what it derives from.

### Value flow

1. The panel module publishes its `settings` schema.
2. The layout loader reads the panel's persisted `config` map.
3. The host fills missing values from schema defaults and validates stored values.
4. The host passes the resolved config to panel `create` or `update`.
5. The panel settings editor binds LVGL controls to an in-memory working copy.
6. Apply validates the working copy, updates the live panel, and persists the layout YAML.
7. Cancel discards the working copy and leaves live and persisted values unchanged.

Runtime or derived values belong in the panel context and are not persisted. Only user configuration belongs under the panel's YAML `config` map.

### Source settings

**A source setting persists the sensor's name, not its numeric identifier and not its value.** `telemetryService:subscribe` takes a name, rejects anything that is not a string, resolves it once through `getFieldInfo`, and holds the identifier only for as long as the dashboard is loaded.

```yaml
- id: pack
  type: cell-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 1
  config:
    source: Cels
```

This section previously specified the opposite — a numeric identifier, authoritative, with a name beside it as recovery metadata — and no code was ever written towards it. The specification was wrong, for two reasons.

**A telemetry source identifier is not stable across rediscovery.** EdgeTX allocates a sensor into the first free slot as it first arrives: `setTelemetryValue` calls `availableTelemetryIndex`, which returns the lowest index whose sensor is not in use (`radio/src/telemetry/telemetry_sensors.cpp`). The source identifier follows directly from that slot, as `MIXSRC_FIRST_TELEM + 3 * index` (`radio/src/dataconstants.h`). So the identifier records *what order the sensors happened to arrive in*, not which sensor it is. Delete the sensors and let them be rediscovered — which a pilot does after changing a receiver, or by accident — and the numbers shift under every layout that stored them. A stored `216` silently becomes a different sensor; a stored `Cels` either resolves or reports that it cannot. We watched the simulator re-detect its sensors during this work, and the layouts kept working precisely because they name them.

**A numeric identifier cannot be authored by hand.** This specification states elsewhere that phase 1 dashboards are externally authored YAML, read-only on the radio, and that is the whole delivery mechanism until the editor exists. Nobody can write `216` from memory, and nobody reading a layout back can tell what it selected. The document was contradicting its own goal as well as the code.

The trade this gives up is real and is accepted: a *renamed* sensor breaks a layout that names it, where an identifier would have survived. That is the rarer event, it is the one a person causes deliberately, and it fails loudly — the panel reports an unavailable source rather than quietly reading the wrong one. Being wrong noisily beats being wrong silently on a source a pilot is flying by.

Source names are stored directly in the declared source settings.

### Native host options

Settings that apply to the dashboard as a whole, such as a global theme or diagnostic mode, may remain native options declared by `main.lua`. EdgeTX will generate their settings UI and persist them in the model. Placement and dynamic per-panel settings must remain in the dashboard YAML.

Each widget instance also declares a native string option keyed `DashID` and displayed as `Dashboard ID`, defaulting to `main`. The host combines the sanitized current model filename and Dashboard ID to select:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

Different EdgeTX custom screens use different Dashboard IDs, allowing multiple independent AeroGrid screens for the same model. An instance renders exactly one YAML dashboard and does not implement internal paging or swipe navigation.

## Host Lifecycle

### Create

1. Receive the EdgeTX zone, options, and widget folder path.
2. Select the layout filename for the active model.
3. Read and parse the YAML layout, falling back to `Default.yaml`.
4. Validate and normalize all placements.
5. Load each referenced panel script.
6. Create an LVGL parent container for each placement.
7. Call each panel's `create` callback.

### Update

1. Apply changed dashboard options.
2. Recalculate grid rectangles if the host zone changed.
3. Call panel `update` callbacks where possible.
4. Rebuild only panels that cannot update in place.

### Refresh

Call each visible panel's `refresh` callback. Expensive telemetry calculations should be cached or scheduled rather than repeated by every panel.

### Background

Call panel `background` callbacks at a controlled rate. Panels must not update LVGL objects while hidden unless EdgeTX permits that operation.

### Events

The host routes touch, key, rotary, and editor events. Events should first go to dashboard/editor controls and then to the panel under focus or pointer position.

Interactive LVGL controls are only available while the Lua widget is in temporary fullscreen mode. App mode provides the cleanest route into this interactive state.

## Telemetry and Flight Semantics

### Source resolution

- Persist the sensor's name. See [Source settings](#source-settings) for why it is the name and not the identifier.
- Resolve the name to an identifier at subscribe time and hold it no longer than the dashboard is loaded.
- A name that does not resolve is an unavailable source, reported as such. Never bind a different source in its place.
- Preserve the source's reported unit and precision unless the user selects a supported conversion.
- Handle numeric, cells-table, and GPS-table source values without treating them as interchangeable.

### Freshness

Every telemetry-backed panel distinguishes:

- `current`: Valid and recently updated.
- `stale`: Previously valid but no longer current.
- `unavailable`: Never received, invalid source, or unsupported value shape.

Last-known values may remain visible in the stale state, but must be visually marked and must not update flight extrema. Unavailable data displays a concise placeholder rather than zero, because zero may be a valid reading.

### Units and formatting

- Use EdgeTX source units and configured radio unit preferences where available.
- Keep conversion and formatting in the telemetry service so related panels agree.
- Store thresholds in a documented canonical unit or alongside an explicit unit field; never reinterpret an existing threshold when display units change.
- Use stable precision and avoid rapidly changing decimal places.
- GPS coordinates support decimal degrees initially; additional formats may follow.

### Flight session

Dashboard-tracked "during flight" extrema require an explicit session boundary. The extrema service supports these reset policies:

- `manual`: User resets flight statistics from the dashboard.
- `timer`: Reset when a configured model timer starts a new run.
- `switch`: Reset on the configured arm or motor-switch transition.

The initial policy is `switch`, using a configured arm switch. A disarmed-to-armed transition resets and starts dashboard flight extrema; an armed-to-disarmed transition stops and freezes them. The `manual` and `timer` policies remain available as fallbacks. EdgeTX-provided minimum/maximum telemetry sources are preferred by panels and remain independent of dashboard flight sessions.

Flight-session state is runtime state and is not written on every telemetry update. A future requirement may add explicit snapshot or log persistence.

## YAML Layout Format

Initial schema:

```yaml
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: main-battery
    type: cell-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      source: Cels
      label: PACK
      warning: 3.5
      critical: 3.3
      showCount: true

  - id: flight-timer
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0

  - id: link-overview
    type: link-status
    col: 0
    row: 1
    colSpan: 4
    rowSpan: 2
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: auto
session:
  armSource: sf
```

Every key above is one the named panel declares, every span is one the named panel supports, and this example is loaded by the test suite rather than being read and believed. That is not a stylistic point: since the settings vocabulary work, a key a panel does not declare is reported at load with the layout, panel and key named. The version of this example printed here until 2026-09-18 did not load cleanly — it produced `main-battery: source must be a string; showLabel is not a setting of this panel` — and it was the most likely thing for someone to copy. Correcting it by inspection was not enough: it also gave `link-status` a `4 x 3` span that the panel does not declare, so the host would have dropped the panel from the dashboard. That was found by the test, not by reading, which is the argument for the test.

The second half of that message is the more interesting one. The example showed sources as numeric identifiers with a `sourceName` companion, because [Source settings](#source-settings) used to specify that. It was the specification that was wrong, and it has since been corrected to describe what exists and why: a source identifier records the order sensors happened to arrive in and moves when they are rediscovered, and nobody can hand-author one.

### Schema rules

- `version` is required and currently must equal 1.
- The first implementation always uses a 4 x 4 grid, even though dimensions are recorded for future compatibility.
- `id` must be unique within a layout.
- `type` maps to `panels/<type>.lua` and must be restricted to safe filename characters.
- Placement values must be integers within grid bounds.
- `session` is optional and carries settings that describe the flight rather than a panel. `armSource` names the switch or source that marks the model armed, and lives here because one dashboard has one flight; stated per panel, two panels could name two switches and only the first would be honoured.
- Unknown top-level keys should be ignored for forward compatibility.
- Unknown panel types should produce a visible placeholder rather than prevent the dashboard from loading.
- Panel-specific data belongs under `config`.
- Config keys correspond to stable keys in the panel's `settings` schema.
- Missing config keys receive panel defaults. An unknown config key is preserved when saving, for forward compatibility, but is reported at load with the layout, panel and key named: in practice it is a typo or a rename left behind, and silence is how a renamed setting reaches a radio still doing nothing.
- A config value outside a setting's declared `choices` is reported the same way and falls back to the setting's default.
- A panel may declare `validateSettings(settings, span, config)`, returning messages, for a rule that spans more than one setting, or one that depends on where the panel is placed. `choices` catches a value that is wrong on its own; this catches a pair that is wrong together, or a value that is fine in itself and meaningless at this size.
- **Validation that fires on resolved settings must distinguish what the layout stated from what the defaults filled in.** `settings` arrives complete, with every default applied, so a rule reading it cannot tell a request from a resting value. `config` is what the layout actually said, and a rule that complains should read that. `cell-battery`'s `showPack` and `showCount` default to `true` and need a supporting row no single-row span has, so a rule reading `settings` would have reported the panel's own shedding as an ignored request and failed every layout with a one-row `cell-battery`. The distinction is the difference between a rule and a nuisance, and it applies to any future validation, not only to this one.
- Sources are stored as sensor names in the declared source settings.

## YAML Handling

EdgeTX firmware contains YAML support for model storage, but it is not exposed to Lua. The dashboard therefore needs its own codec.

For the first implementation, use a strict schema-specific parser and serializer supporting only:

- Mappings
- Sequences of mappings
- Strings
- Integers and decimal numbers
- Booleans
- Null or omitted values
- Indentation with spaces

Do not attempt to support general YAML features such as anchors, tags, multiple documents, arbitrary flow syntax, or executable values. This reduces code size, memory use, and ambiguity on the radio.

A Lua table configuration file would be technically simpler and cheaper to load. YAML is selected because it is human-readable and can be edited outside the radio.

## File Persistence

EdgeTX exposes Lua file access through `io.open`, `io.read`, `io.write`, and `io.close`. It also exposes filesystem rename and delete operations.

Release phase 1 is read-only: layouts are authored externally and the dashboard never writes, migrates, or reformats them. The save workflow below applies to the phase 2 editor.

The editor saves a changed draft once when Return exits editing or fullscreen
is left, not after each gesture. Unchanged layouts are not rewritten.

Recommended save sequence:

1. Serialize and validate the complete layout in memory.
2. Write `<layout>.tmp` using `io.open(..., "w")`.
3. Close the temporary file.
4. Read the temporary file and verify it exactly matches the serialized,
   round-trip-validated content. Build and validate one panel per callback.
5. Rotate the existing file to `<layout>.bak` where practical.
6. Rename the temporary file to the final filename.
7. Keep the backup until the next successful save.

On load, try the final file, then the backup, then `Default.yaml`.

Layouts are keyed by sanitized model filename and Dashboard ID as `<model-identifier>--<dashboard-id>.yaml`. Sanitization must be deterministic, reject traversal, and append a short hash when normalization could create collisions.

## Dashboard Editor

The editor runs inside the dashboard's temporary fullscreen state.

Editing starts by long-pressing a panel in explicit fullscreen (Enter is the
key-only alternative). Normal App mode remains read-only. A muted gray circular
gear sits at each panel's top-right. There is no corner X, EDIT
button, toolbar, selection outline, or grid overlay. The gear opens settings,
including Remove panel and fitting supported sizes. Dragging snaps
only to valid placements. A panel-styled + tile with a gray sidebar occupies
the first free 1x1 cell as an editing affordance, not a persisted panel.
New draft panels remain preview cards until saving. Return closes drawers,
then validates, saves, and exits editing; save failure retains the draft.

### Required actions

- Add panel
- Select panel type
- Drag panel between fitting grid positions
- Choose a fitting supported size with the top-left cell fixed
- Edit panel-specific configuration
- Remove panel
- Save and exit with Return

### Panel settings behavior

- Generate the settings form from the selected panel's `settings` schema.
- Use native-style LVGL source, switch, timer, file, color, choice, numeric, text, and toggle controls.
- Edit an isolated in-memory working copy rather than the live YAML data.
- Show defaults for missing values and validation feedback for invalid values.
- Apply settings to the live panel only after validation succeeds.
- Persist settings together with placement when Return exits editing.
- Preserve unknown config keys so a newer panel configuration is not destroyed by an older dashboard host.

### Placement behavior

- Do not show grid guides or a selection outline.
- Reject out-of-bounds placement.
- Snap only to non-overlapping positions; do not move other panels.
- Keep an in-memory working copy until save-on-exit.
- Reposition and update existing LVGL containers for draft geometry changes;
  rebuild the dashboard only after saving.

Touch radios use drag and gear settings. Rotary/key-only radios cycle panels,
open settings with Enter, and use Column, Row, Size, and Remove controls.
The persisted placement model is identical for both input styles.

## Validation and Recovery

The loader must validate every layout before creating panels:

- Schema version is supported.
- Grid dimensions are supported.
- IDs are unique.
- Panel types are safe and available.
- Coordinates and spans are integers in range.
- Rectangles do not overlap.
- Configuration values meet panel-defined constraints where available.
- Source values are names that resolve against the model's sensors, or are reported as unavailable.
- Configured sources return the value shape required by the panel.
- Threshold units and ranges are valid.
- A navigation bearing is shown only when valid model and pilot/home GPS coordinates are available.

Invalid entries should be skipped or replaced with an error placeholder. One broken panel must not disable the entire dashboard.

The UI should expose enough error information to identify the layout file and invalid panel without displaying a Lua stack trace during normal use.

## Performance and Resource Constraints

- All panels share the EdgeTX widget Lua state and instruction budget.
- Keep panel modules namespace-local and return tables rather than creating globals.
- Avoid loading unused panels.
- Cache telemetry sources and derived values where panels can share them.
- Rate-limit expensive work independently from visual refresh.
- Minimize LVGL object count, bitmap memory, and transient table allocation.
- Prefer incremental updates over rebuilding the complete dashboard.
- Test on physical target hardware as well as the EdgeTX simulator.

## Compatibility

- Initial targets: RadioMaster TX16S versions 2 and 3, RadioMaster TX15, and RadioMaster GX15 running EdgeTX 2.12 or newer.
- App mode is the primary deployment because it provides the complete decoration-free screen and the cleanest future path to interaction.
- The ordinary Full screen layout remains a supported fallback when users want EdgeTX decorations.
- Existing native layouts and widgets are unaffected.
- Panels written for this dashboard are not automatically compatible with native EdgeTX widget slots.
- Existing widgets must be adapted to the panel contract and relative geometry.
- Telemetry availability and naming vary by RF protocol, receiver, sensor configuration, and model.
- Missing optional sources must degrade the panel presentation rather than prevent dashboard startup.
- Internal transmitter GPS is not assumed; aircraft telemetry GPS is the primary navigation input.

## Distribution, Versioning, and Diagnostics

- Distribute AeroGrid as one versioned `/WIDGETS/AeroGrid/` package so host, services, editor, and bundled panels are upgraded together.
- Keep `main.lua` small and load implementation modules on demand.
- Define a dashboard package version, layout schema version, and panel API version independently.
- `lib/package.lua` is the package identity source (`0.10.0`); runtime API,
  panel API, and layout schema are independently versioned at `1`.
  Internal modules declare `RUNTIME_API`; increment it when changing their
  contract incompatibly. The host rejects missing or incompatible core modules
  with a visible error and prevents reloading a failed runtime. Incompatible
  services are reported while unrelated panels continue to operate.
  Panels remain governed by their public `apiVersion`, including third-party
  modules. This is API compatibility checking, not a checksum of the installation:
  API-compatible release mixtures and stale bytecode are not proven absent.
  Upgrade the complete package and remove old `.luac` files.
- Every panel declares the panel API version it requires. Incompatible panels render an error placeholder instead of executing.
- Phase 2 layout migrations operate on an in-memory copy, preserve the original file as a backup, and write only after successful validation.
- A newer unsupported layout version must not be rewritten by an older dashboard release.
- The dashboard provides a diagnostics view showing package version, active layout path, loaded panels, unresolved sources, and panel failures. See [The host diagnostics view](#the-host-diagnostics-view).
- Diagnostics must avoid continuous SD-card logging by default. Optional logs are written only on explicit export or when a bounded diagnostic mode is enabled.
- Panel loading and layout filenames must reject path traversal and unsafe filename characters.

## Possible Native Firmware Follow-Up

A later EdgeTX firmware contribution could implement a native flexible grid layout. That would require at least:

- Increasing native layout capacity from 10 to 16 zones.
- Persisting `col`, `row`, `colSpan`, and `rowSpan` per zone.
- A dynamic `Layout` implementation whose `getZone()` reads persisted geometry.
- Native overlap and bounds validation.
- Changes to the widget setup page for movement and resizing.
- Model/YAML migration and compatibility handling.

This would allow independently registered EdgeTX widgets to occupy configurable grid spans. It is outside the first implementation because the composite host can deliver the desired dashboard with a smaller blast radius.

## Resuming Work

State as of 2026-09-20. This section is the entry point after a break: it records where the code lives, what is proven, and what to do next.

### Where the work is

**Everything is on `main`. There is no branch stack, no open pull request, and no work in flight.** Milestones 1 to 8 and the presentation and consistency pass are all merged; every working branch has been deleted. A fresh branch off `main` is the correct starting point for anything.

This section used to carry a table naming the branch currently in flight, which was accurate only while one existed and became a trap the moment it was merged: the first act on resuming was to check out a branch that had been deleted. The shape is gone rather than filled in with `main`. If a branch stack ever returns, record it here again — but only while it is real.

### Hardware validation status

**Acceptance closed by user decision on 2026-10-05 for TX16S v2 / EdgeTX 2.12.4.**
Other radios are unavailable to the user and remain untested, not acceptance
blockers. The user confirmed the font-callback memory fix on 2026-10-05;
that issue is closed. Protocol-specific coverage and physical resource budgets
remain unverified follow-up work rather than
acceptance gates. This decision does not mark unrecorded checks as passed.
Earlier open-status statements below describe the historical validation scope.

On 2026-10-04 the user confirmed AeroGrid `0.10.0` on a TX16S v2 running
EdgeTX 2.12.4 and reported all recommended dashboards verified with no issues
observed. This is the first recorded dashboard acceptance on physical hardware.
Other target radios, protocol-specific evidence,
and physical resource measurements remain open.

The simulator is a real host running real LVGL, so it catches a great deal, and the test suite measures against a mock whose arithmetic is taken from the firmware source. But a simulator on a desktop monitor is not a 480 x 272 transflective panel at arm's length in daylight, and no amount of contrast arithmetic substitutes for looking at one.

The judgements most exposed by this are the ones that were made *because* of how something reads:

- **The alert tints.** `warning` and `critical` now tint the panel's surface instead of drawing a coloured frame, on the argument that area is noticed in peripheral vision where an outline has to be looked at. Every tint is held to the same text and elevation minimums as the resting surface, and that is checked numerically for both palettes. Whether a tinted field is actually noticed while looking elsewhere, on a moving aircraft, has never been tested.
- **The panel as a card.** Elevation of 1.316 canvas to surface, 8 px corners, no resting outline. Chosen from ratios.
- **Text width.** This entry used to say that the Lua API cannot measure text outside a draw callback, so every font choice descended from an assumed mean advance of 0.58 of a line height that had never met a real font. Both halves are now false: `lcd.sizeText` carries no draw-context guard and answers from the font's own advances, and both fitting and placement use it. The estimate survives only where `lcd.sizeText` is absent. What remains untested on hardware is not the width but the *typography* -- whether a reading that now measures its way to a larger font is comfortable rather than merely larger.
- **The responsive ladder.** Which rows a panel keeps at each span is decided from measured box geometry, but whether the result is readable is a question for eyes.

This is carried in the open-items table as milestone 4's physical readability review, which undersells it. It is not one milestone's loose end; it is the standing condition of the whole project.

### What the presentation and consistency pass did

Eleven pull requests over one day, after an audit that measured every panel at every span it declares through the real host. The audit's premise was that thirteen panels written across three milestones by different sessions to the same contract, but not to each other, would agree individually and disagree as a set. They did. The PRs hold the detail; this is the shape.

**Presentation.** A panel is now a card: deepened canvas, lifted surface, 8 px corners, and no outline at rest. Its accent is a full-height stripe with rounded outer corners, drawn as arcs clipped by a box one accent-width wide — five rounds of trying, and the version that worked came from the user rather than from the measurements. Alert states tint the surface instead of colouring the frame, which leaves **fill meaning a condition of the data and outline meaning where the interaction focus is**, where the border previously carried both.

**Consistency.** The badge vocabulary was cut from thirteen strings to five rather than widening the column to fit the longest, because `NOT CELLS` and `BAD CELLS` were nine characters separating two failure modes of one panel. The header gives the label the room an empty badge is not using, permanently rather than conditionally, so a state change never makes the label reflow. Eight private copies of "choose a font for this reading" became one shared responsive ladder: composition comes from the box, and the font from the composition, so two panels of the same size agree. Ten non-monotonic font ladders became none.

**Correctness.** A panel now declares what it renders, and its redraw comparison is derived from that declaration rather than from a hand-listed subset that drifts from `apply` — which was the fourth instance of one defect, after three were fixed individually in milestone 7. The settings vocabulary was unified: one name per concept, declared `choices` the loader enforces, thresholds that state their direction and unit, ranges named for what they bound, and the flight arm switch moved to the layout where two panels cannot contradict each other.

**Cost.** `trim-panel`'s reflow, the worst callback, was found to be half inherent and half invisible work: it hid the text rows a narrow cell cannot fit and then went on positioning, formatting and writing them anyway.

Two lessons generalised past their PRs and are recorded where they will be read rather than only in a PR body: **assert what the panel draws, not what it computed**, in the fixture discipline section, which seven assertions in the existing suite were violating; and **a form may drop redundancy, never magnitude**, under typography, which stopped `flight-timer` rendering `1:04:12` as `04:12`.

### What the vertical-rhythm pass did

Eighteen pull requests after the presentation pass, and where that one made the catalogue agree with itself horizontally, this one did the vertical axis and then the per-panel reviews it exposed. The shape, since the PRs hold the detail:

**The bands, stated three times.** They were proportional but not fixed: an absent part gave its quarter to the body, so a panel drawing a supporting row sized its reading against a half and the identical panel beside it, without one, against three quarters. Two panels of one size laid out differently according to what was *in* them. The user saw that on a radio and rejected it, and the split became a fixed 1/4 : 1/2 : 1/4 with the bottom quarter reserved whether or not anything is drawn in it. Three parameters went with the redistribution -- `hasTertiary`, `floorHeight` and `rowHeight` -- because each of them sized a band from its contents, and `theme.ladder`'s `draws` argument went too once nothing downstream varied with the answer.

**Then the row was pinned to the floor, which is the mirror of the heading.** The
arrangement is four statements and not one of them consults what the panel contains: the
heading at the panel's top inset, the supporting row hung from its bottom inset, the
reading's ink on the panel's own centre, and the reading's font from half the panel's
height -- or all of it where nothing shares the panel. 102 of 258 panels that draw all
three move their row down, none changes size, and the gaps above and below the reading
become equal on 29 where none had been equal before. Where a bar owns the floor the row
hangs from the bar instead and does not move, so the five bar-reserving panels are
unaffected -- including `flight-timer`, which is the panel the whole sequence started from.

**Then the reading came out of the bands altogether.** The user looked at the fixed split on a radio and read the panel as uncentred, which it was: the bands were symmetric, but a heading is pinned to the top of its band while a supporting row is centred in its own, so the slack collected above the number. The rule now is one centre and two budgets -- the reading's ink sits on the panel's own vertical centre, and its font comes from half the panel's height where anything shares the panel and from the whole height where nothing does. The heading's quarter and the supporting row's quarter are unchanged; the middle band survives only as the compass's bound. 155 of 704 panels gain a font size and none lose one, which is more than the fixed split had cost at one-row spans.

Two things about that are worth keeping rather than leaving in a PR. **The symptom the user pointed at is not what the rule fixes**: on the `3 x 2` `flight-timer` they cited, the reading's ink was already centred at 68 on a panel whose centre is 67, and it moves one pixel. What they were seeing is the gap above the number against the gap below it, which is the heading's pinning and not the reading's centre; equalising those means centring the reading *between* the heading and the row, which is a position derived from content and is the rule the first statement was rejected for. And **the safety argument behind the ink rule was true by luck**: the strip below a reading's baseline is unreserved, which is safe only while nothing descends into it over anything, and the middle band happened to leave nine pixels of slack on the panels where a descending unit could reach a supporting row. Sizing against half the panel spent that slack and `testReadingsDoNotDescendOverAnything` went red, so the budget now reserves the rider's depth explicitly.

**The ink.** A reading's font came from the largest whose *line height* fitted its band, and line height is ascent plus descent plus leading. No reading in the catalogue descends, so the band was reserving space nothing draws into. It comes from the ink now and the reading is placed by centring that ink, which had to move together: a font chosen one way and a block centred the other disagree by 4.5 px on a `navigation 4 x 2`. That reversed a recorded decision, and `theme.opticalTop` went with it -- it had no caller at all, which is the same shape as the retired `primitives.arcBounds`.

**The reviews.** Nine panels have completed the simulator review and
documentation pass: `flight-mode`, `tx-battery`, `model-identity`,
`flight-timer`, `cell-battery`, `trim-panel`, `navigation`, `link-status`, and
`metric`. All nine display-panel reviews are complete.
Initial physical dashboard validation passed on TX16S v2 / EdgeTX 2.12.4;
the remaining hardware matrix and resource measurements are outstanding.
Review screens live on a second model because `MAX_CUSTOM_SCREENS` is 10.
The four span galleries remain test fixtures rather than radio screens.

**Navigation review completed for this pass.** The dial has a full outer
circle, ticks, inset cardinal labels, and a green concave arrow with
all-angle text clearance. Bearing supports numeric and quadrant formats.
Bearing and coordinate rows are independently configurable and use readable
primary-color supporting text. The 2x2 review example omits coordinates;
the 2x3 example includes them. Full coordinates can also fit a normal 2x2
detailed panel. One-row panels still show distance only: a bearing
presentation requests a footer, not a bearing headline. This limitation is
documented rather than presented as missing GPS data.
See [navigation documentation](../docs/panels/navigation.md).

**`cell-battery` review changes landed in #93.** The fifth screen selects
`review-cell-battery`, comparing pack-first and average-first readings from
`RxBt` with a configured four-cell count, narrow spans, and a `Cels` monitor.
The count must match the actual pack. Pack sources cannot reveal individual
cells. Its documentation covers the shared battery glyph, equal gaps, 30%
unit-shedding threshold, and digit-ink alignment. The sixth diagnostic screen
confirmed case-sensitive binding: `RxBt` works, `RXBt` does not.

**`trim-panel` simulator review is complete, by user choice.** The fourth screen
on AEROGRID PANEL2 selects `review-trim-panel`, comparing the three-axis square
at several spans, raw and percentage readouts, and single-cell shedding. The
panel uses a three-axis perimeter arrangement:
aileron at the top, elevator on the left, rudder at the bottom, green
center-zero fills with fixed zero ticks, and a white dot following aileron
and elevator. The square and right-hand numeric column are centered as a
group using a fixed full-range budget, with right-aligned `A/E/R` suffix
readouts vertically centered on their bars and equal corner clearances.
Compact typography retains numbers in normal 1x1 cells. This square is the
panel's only presentation.
See [trim-panel documentation](../docs/panels/trim-panel.md).
The fixture now starts on AEROGRID STD (`model1.yml`), with
`manuallyEdited: 1` allowing EdgeTX to accept the changed radio settings
and regenerate their checksum.

**The wordings.** Rows offer single forms wherever one fits, because a form short enough for the narrowest panel is short enough for every panel -- so a ladder's longer rungs were only ever drawn where the shorter one was also correct. `cell-battery`'s three shape wordings became two, `NO CELLS` and `CELLS ERR`, and that one was decided on the reader rather than the width: both of the merged states mean the configuration is wrong and are fixed on the ground, and a row says what to do rather than which failure occurred.

**Cost.** Four figures moved and each is recorded where it moved. The instrument itself was wrong twice more -- a collision sweep that ran one zone while reporting two, and a fixture whose reset restored every telemetry value except the timers -- which brings the tally of apparatus-was-the-defect to seven, every one failing towards pass.

### Current cost

The current suite, including the ELRS 4.x link review and sixteen-panel
ELRS exercise, reports **13800/20000** for the worst
callback (shipped panel refresh), **6600/20000** for the worst steady
frame (link review), and **9800/20000** for shipped reflow. These are
the runner's sampled instruction counts; the figures and reasoning below
record earlier measurements rather than the current panel implementations.

| | Value | Where |
| --- | --- | --- |
| Worst callback | 8097 of 20000 | the staged loader building a trim panel at sixteen cells; the trim-specific baseline predates the fixed three-axis presentation |
| Worst steady frame | 3535 of 20000 | sixteen `link-status` panels |
| Worst reflow | 7573 of 20000 | the shipped dashboard, against the worst other callback at 8097 |

Every figure is what the suite itself reports, re-measured with the count hook set to every instruction. All three are asserted by the suite and are measured at the largest layout the schema permits. Note the second-worst callback is the loader's own header stage rather than any panel -- which means panel work is no longer the binding constraint on a full grid, and the next person looking for headroom should know that before optimising a panel.

**Two of the three are not stable to the instruction, and the ranges are worth stating rather than a single number.** Measured five times against one unchanged checkout, the worst callback comes back 8096, 8097 or 8098 and the worst steady frame 3535 or 3541; on `main` the same two span 8096–8098 and 3503–3512. Only the reflow repeats exactly, on both sides. So a movement of under about ten instructions in either of the first two is the instrument rather than the dashboard, and the figures above are quoted at the value each returns most often.

This paragraph said the worst callback alone was unstable and that "the other two are stable and repeat exactly", which was written after two runs and was false of the steady frame on the third. It is the same shape as every other figure that has drifted here -- a claim about a measurement made from too few measurements -- and it is recorded rather than quietly corrected because the instrument's own reliability is exactly the thing a budget assertion rests on.

**Two of these were wrong, and the correction is the fifth figure in this project to drift.** The worst callback read 7882, which is 136 low and was low on `main` as well as on the branch that found it -- it was not re-measured after whatever moved it. The worst steady frame read 2520 against "the shipped ten-panel dashboard", which is a different subject from the one the suite reports: the suite measures three sixteen-panel exercises and names the worst of them, and that is `link-status`, not the shipped layout. A figure and its subject drifted apart, which is harder to notice than a figure drifting alone, because the number stays plausible.

All three rose when the badge began being placed from its own measured text rather than drawn from its column's left corner: 79 on the worst callback, 60 on the steady frame and 68 on the reflow. That is the cost of a measurement per badge per repaint, and two ways of avoiding it were measured and rejected -- guarding on the word being unchanged, which is `setHeading`'s guard and fails for the same reason, and memoising the five-word vocabulary, which buys the reflow 27 and costs the worst callback 14. The arithmetic is in `primitives.setBadge` so nobody repeats it.

The worst reflow is the figure that moves. It rose 421 when `navigation` began asking the ladder a second time with the height its two supporting rows need, and a further 135 when the fixed-bands rule took that second call away again and gave the panel a row-count decision of its own instead. The worst callback has not moved through either change; the worst steady frame is within 8 instructions of where it was. The assertion that matters is not the number but the comparison -- a reflow may not be the most expensive callback the dashboard makes -- and the margin is 523 to 525 instructions, the spread being the worst callback's own jitter rather than the reflow's.

The steady frame and the reflow each rose when a unit stopped being drawn beside a reading with no value: the steady frame from 3503–3512 to 3535–3541, and the reflow from 7547 to 7573, which is +26 exactly and is the one of the three that repeats. That is the sentinel test and a visibility comparison, paid once per unit-bearing panel per repaint and once per unit-bearing panel per reflow; the worst callback did not move, because the panel that sets it draws no unit. Both figures were measured against `main` at the same hook setting rather than read off the table above, because a comparison between a measurement and a remembered number is the drift this project has now had five of. The comparison was also seen to report a difference before it was trusted to report agreement -- the worst callback agreeing to the instruction is only evidence because the other two did not.

**Re-measured after rebasing onto the supporting-row work, and the answer did not move.** That rebase is why it was checked at all: a delta measured against one base is not a delta against another, and the row work touched `theme.fitLabel`, which every supporting row in the catalogue now goes through. It happens that `main` measures the same before and after it -- 7547 and 3503–3512 either side -- so the figures above stand, but that is a result rather than an assumption, and the row work's own cost is not recorded here because it was not re-measured when it landed.

The worst callback rose 85 when the heading notice started working. It had been reading a field off the label, which is a table here and userdata on a radio, so it was always nil there and the notice never fired: the work it appeared not to cost was work it was not doing.

### Verification state

- `make test`, `make check`, and `make build` pass from a clean tree. `make check` was also run against a real Lua 5.3 `luac`, and both suites were executed under a real Lua 5.3 interpreter, not only under whichever Lua `lupa` provides.
- CI (`.github/workflows/ci.yml`) runs `make check` under Lua 5.3 on every pull request, plus the SD image build and two integrity assertions.
- The dashboard has been confirmed running in the EdgeTX simulator on a TX16S profile through milestone 7. Navigation, link status, the radial and bar metrics and the trim panel have all been read against live simulated telemetry, which is where the arc drift in constraint 11 was found. Two of milestone 7's behaviours still cannot be judged there: whether a cells source on a real receiver returns the table shape assumed here, since nothing on an ELRS link publishes one, and whether a protocol without an RSSI sensor is recognized as a link rather than a dead one.
- Milestone 8's corner work and the whole presentation and consistency pass have been seen in the EdgeTX simulator and judged there. The accent geometry in particular took five rounds of looking, and the version that was accepted came from the person at the screen rather than from any measurement, which is the standing argument for building something to look at rather than reasoning about it in prose. Initial dashboard acceptance has now been reported on TX16S v2 / EdgeTX 2.12.4; see [Hardware validation status](#hardware-validation-status).
- The simulator fixture has **three models**, every screen holding an AeroGrid instance in App mode with the Modern theme. `model1` (**AEROGRID STD**) starts on `Default`, then offers `Empty`, `Host`, `services`, and `services2`: all installation layouts plus both diagnostic panel types. `model2` (**AEROGRID PANEL1**) carries six reviews: cell battery, flight counter, flight mode, flight timer, link status, and metric. `model3` (**AEROGRID PANEL2**) carries five: model identity, navigation, text, trim panel, and TX battery. Each user-facing panel type has exactly one dashboard. The flight-counter review uses only one tracker; resize it to compare spans.

  `MAX_CUSTOM_SCREENS` is 10, so eleven panel reviews are split across two models. Paging between screens switches dashboards without opening widget settings. Auxiliary layouts `sim`, `sim2`, `states`, and `review-cell-sources` remain available through the Layout picker rather than dedicated screens.

  **Corrected: this said nine screens on one model, four of them span galleries.** The galleries were retired to test fixtures in the same pass that added the review screens, and this sentence went on describing the arrangement they were part of -- the next bullet records the retirement, so the two contradicted each other in adjacent lines.
- Two instances running together are held to owning their own root, page, service registry and telemetry service, because EdgeTX runs every Lua widget in one interpreter state and anything a module kept at its own scope would be shared between dashboards that know nothing about each other.
- In App mode, every shipped layout is checked to draw nothing readable inside the corner EdgeTX's menu button covers. The directory is read rather than listed, so a new layout is covered as soon as it is added.
- Every layout under `layouts/` is loaded by the integration suite, not merely the shipped default: each one is built through the real host and panels, held to the same containment rules, and refreshed against radio state. A layout is covered as soon as it is added, because the suite reads the directory rather than a list.
- **The four span galleries have been retired from the radio and kept as test fixtures.** They shipped under the Dashboard IDs `span1x1`, `span2x1`, `span2x2` and `span4x1`, each putting every panel at one span so the catalogue could be caught disagreeing with itself. The user does not page to them, and ten screens is the ceiling, so they now live in `tests/fixtures/layouts/` rather than on the card. What they construct is still built: the single-cell gallery is still held to containing every panel that declares a `1x1` span, read from the panel directory rather than from a list, and all four are still swept by the collision check, where they are the densest arrangement in the suite -- eleven panels in one grid. Retiring a layout from a screen is a decision about the radio; deleting the cases it builds would have been a quiet reduction in coverage.
- **Review screens live on a second model.** `MAX_CUSTOM_SCREENS` is 10 (`radio/src/dataconstants.h`). `model1.yml` keeps the dashboards and diagnostics; `model2.yml` has nine panel review screens and one source-name diagnostic, filling its ten-screen allowance. All nine display-panel reviews are complete. The metric review includes an ordinary GV source.

### Immediate next steps

**Aircraft dashboard follow-up (2026-10-04).** Dashboard ID `aircraft` is a
real model9-oriented operating layout, not a review gallery. Its zero-based
grid placement is:

| Panel | Column, row | Span | Binding |
| --- | --- | --- | --- |
| Flight timer | 0, 0 | 2x1 | Model timer 1 |
| RX battery | 0, 1 | 2x1 | `RxBt`, pack mode, user-confirmed 2S, average headline |
| Link | 0, 2 | 2x1 | `RQly`, `1RSS`, ELRS 4.x `RFMD`, no bar |
| Altitude | 0, 3 | 2x1 | `Alt`, with `Alt+` above `VSpd+` on the right |
| TX battery | 3, 0 | 1x1 | Radio-local transmitter voltage, no glyph at this span |
| Flights | 2, 1 | 1x1 | `gvar9`, integer count |
| Expo | 3, 1 | 1x1 | `gvar1`, integer percent |
| Model image | 2, 2 | 2x2 | Model bitmap |

Column 2 of the top row stays empty. No GPS or airspeed source is configured.
The RX headline is `RxBt / 2`, not an individually measured cell voltage;
total voltage and `2S` appear on the right. Verify that `RxBt` measures the
battery rather than regulated supply. The model also publishes numeric
`CelV`, but it is not bound; there is no `Cels` table in this model.
Separate numeric cell and pack sources are not currently supported together.
GV9 flights and GV1 expo are read-only existing model values.

One-row panels reserve the App-mode button's width on the left rather than
losing a full-width top band. For standalone primaries, retain normal centered
geometry when the declared widest number/unit envelope clears the button;
keep the inset when it intersects. Headers and supporting content retain
their own clearance. Slotted visuals and side stacks remain conservatively
inset as groups. Taller panels keep the vertical reservation. Metric reflows
its primary sample when deferred sensor precision resolves.

Review layouts
are smoke tests, not a representative live-source performance baseline;
future resource baselines should exercise the operating aircraft dashboard.
Repeated VS Code simulator extension-host crashes remain unexplained.
Clearing regenerated `.luac` files is a refresh procedure, not a proven crash
fix. The staged local model9 and its sample simulator bitmap are not shipped
fixtures; keep the original hardware bitmap when copying model settings.
Screenshot automation remains deferred.

Next, verify `NO LINK` and recovery in the simulator and on the bench,
check the live `RxBt` reading, and continue target-matrix/resource baselining.
The glyph-only TX presentation remains proposed follow-up work.

The simulator panel review and documentation pass is complete. Continue with
milestone 9 hardening and the hardware verification below. Simulator acceptance
does not close that separate hardware work.
Record the target-radio and protocol matrix without treating untested cases as passed.

**Metric simulator review and documentation complete:** the ordered `metrics`
list supports one to three numeric EdgeTX sources, each with its own label,
unit override, and precision override. Sensor MIN/MAX uses ordinary `-`/`+`
sources rather than special list options. The primary alone drives thresholds
and the visualization. The shared builder tries the footer, then a right-side
stack, then hides the supporting group, without shrinking the primary.
The accepted link side-stack geometry now uses that same builder. Sensor-derived
primary units display correctly; unavailable readings omit units.
The tenth screen selects `review-metric`.
See [metric documentation](../docs/panels/metric.md).

**Link-status simulator review and documentation complete:** measured link quality
remains the primary reading under `reading: auto`; RSSI is independent supporting
data, never a substitute for LQ. `qualityWarning` / `qualityCritical` use percent,
and `marginWarning` / `marginCritical` use dB above nominal receiver sensitivity.
There are no default alarm thresholds, composite health percentage, universal SNR
penalties, or widget voice/haptic alerts. The most severe configured live condition
sets the panel state; the supporting caption identifies low LQ, low RSSI, or low
margin. Link-down takes precedence. `rssiWarning` / `rssiCritical` use the
RSSI source's numerical units independently of the selected headline.
ELRS quality panels without extrema pair receiver power and margin in one
full-width caption: `-100dBm (+23dB)`. The difference uses dB, not dBm, and
positive margins explicitly carry `+`. Alarm causes take priority over the
RSSI portion if both cannot fit; `LOW MARGIN (+5dB)` retains the headroom
without using an ambiguous `M` abbreviation. Wider rows keep the full pair
alongside the alarm cause. Unavailable margins retain explicit status wording.
For ELRS `2x1` panels with `reading: quality` and both RSSI and mode sources,
the measured LQ sits on the left with RSSI and parenthesized margin stacked
on the right. No supporting font reduction is used: insufficient space sheds
the column. `1x1` remains primary-reading-only, and larger panels retain
their paired footer. The `2x1` review example now includes both LQ and
margin thresholds; its badge and state color show alarms.

`protocol: elrs4` maps `modeSource` RFMD to rate and nominal sensitivity using the
ELRS 4.0.0 and 4.1.0 global `enum_rate` values, not hardware-specific table indices.
The single-band entries cover SX127x, SX128x and LR1121 modes. Dual-band rates are
displayed, but no margin is calculated because the configured antenna RSSI does not
identify its band. Unknown/reserved modes, stale/missing RFMD, stale/missing RSSI,
and incompatible RSSI units do not produce a margin. ELRS 3.x is not supported by
this mapping; select `generic` for raw RFMD without automatic sensitivity.
Freshness follows the shared telemetry service's link-level evidence: EdgeTX
does not expose per-sensor reception age for numeric sensors, so a discovered
RFMD source reporting zero cannot be distinguished from a genuine 25Hz mode
that reports zero. Real receiver testing remains necessary.
The ELRS profile explicitly excludes transmitter-local RFMD and TPWR from
receiver-link evidence; those values can continue when no receiver is connected.
EdgeTX labels CRSF RSSI as dB; the ELRS profile renders that receiver signal power
as dBm. Configure receiver-side RSSI and LQ (usually `1RSS` and `RQly`), not
transmitter-return telemetry (`TRSS` / `TQly`). An antenna source is explicitly
selected; there is no automatic antenna selection.

`snrSource` and `powerSource` add optional measured details alongside rate when
the tertiary band has room for a second row. Optional details shed by width
(power first, then SNR); a one-row panel retains the primary reading and
state badge, with the configured ELRS `2x1` side-column exception above.
A stale auxiliary reading carries `*`; no stale RFMD is decoded.
Screen 5 on AEROGRID PANEL1 provides 2x3, 2x2, 1x1 and 2x1 examples. Its thresholds
are review examples, not protocol recommendations. Real ELRS 4.x telemetry
and hardware verification remain outstanding. The simulator's
RFMD input is limited to 0-8 and TPWR remained fixed at 100 mW, so 2.4 GHz
mode decoding and power transitions were verified by automated tests rather
than simulator input. Empty-card isolation followed by a clean `make build`
resolved the simulator extension-host startup failure; the precise generated
SD-state/bytecode cause was not isolated.

Mapping references:
[ELRS 4.1.0 RFMD enumeration](https://github.com/ExpressLRS/ExpressLRS/blob/4.1.0/src/include/common.h),
[rate/sensitivity tables](https://github.com/ExpressLRS/ExpressLRS/blob/4.1.0/src/src/common.cpp),
and [signal-health guidance](https://www.expresslrs.org/info/signal-health/).

1. **Run the shipped dashboard on a radio.** This is first and has been first for three milestones. One screen exercises telemetry, cells, link, GPS, model timers, flight mode, transmitter voltage, a global variable, trims, and the model bitmap at once. Five things can only be judged there: whether the estimated text widths behind `theme.textWidth` hold against the real fonts, whether an `lvgl.image` of a model bitmap scales the way `StaticImage` is expected to, whether the corrected arc centring places the radial and compass dials where they are meant to go, whether the compass pointer reads as a direction at arm's length, and whether an alert tint is noticed without being looked at.
2. **Run the two diagnostics layouts on a radio.** Set the widget's Dashboard ID to `services` or `services2`; they load on any model without a model-specific file. This is the check that milestone 5's normalization is right against real sensors rather than mocks.
3. **Confirm the value shapes on real hardware, on more than one protocol.** `cell-battery` assumes a cells source returns a contiguous array of per-cell voltages, and `link-status` assumes a protocol without an RSSI sensor is detected by a source contradicting `getRSSI()`. Both are mocked faithfully but neither has met a receiver.
4. **Decide the extrema reset policy beyond arm switch.** The specification names manual, timer, and switch; switch and manual are implemented, timer is not.
5. **Decide whether the status rail is ever built.** It is deferred rather than cancelled, and the reasoning is recorded so the question starts from where it was left.

Items 4 and 5 are decisions rather than work, and can be taken at a desk. Everything above them needs a radio.

### Deliberately set aside

These came out of the presentation and consistency pass and were not done, each for a stated reason. They are recorded here rather than in an issue tracker because the reasoning is the part worth keeping — the work itself is small in every case.

`REFLOW_BATCH` and the reveal frame were the recommended items here and both have been taken; see [Why `REFLOW_BATCH` is three](#why-reflow_batch-is-three) and the render-declaration entry under fixture discipline. `primitives.arcBounds` is gone with them. What is left is the physical readability review, which needs hardware.

| Item | Why it was left | What taking it would involve |
| --- | --- | --- |
| **`link-status` thresholds change unit at runtime** | With `reading: auto`, the leading source can resolve to RSSI in dBm or to link quality in percent, and `warning` and `critical` are bare numbers either way. The settings vocabulary made the label honest — "in the leading source's unit" — rather than fixing it. | Either pin the threshold to a named source, or carry two thresholds and select with the reading. Both change behaviour for an existing layout, which is why it was documented instead. |
| **The physical readability review** | Needs hardware. It is milestone 4's last open item and has been open since milestone 4. | See [Hardware validation status](#hardware-validation-status). It is larger than one milestone's loose end. |

### Open items carried forward

| Item | Where | Note |
| --- | --- | --- |
| ~~`metric` never shows a sensor's own unit~~ | Metric review | Fixed and accepted: sensor-unit updates are collected whenever a unit object exists, independently of its initial visibility. The resolved unit is fitted beside the primary reading. The metric review screen includes a primary reading with no unit override. |
| `navigation` bearing format | Implemented in active review | `bearingFormat: degrees` retains numeric azimuth; `quadrant` offers `N29°E`, `S29°E`, `S29°W`, or `N29°W`, shortening to a cardinal direction when space requires it. Exact cardinal axes display N/E/S/W. The live bearing replaces the fixed NORTH UP caption; degraded-source captions remain distinct. |
| `navigation` coordinates at `2 x 2` | Implemented in active review | Detailed presentations use regular supporting typography with tighter row spacing and primary text color to retain both live bearing and five-decimal GPS coordinates within the existing footer. Short zones still shed rows when they cannot fit. |
| A bar panel's reading has 8 px less space below it than above | Settled, not open | Recorded so it is not reopened. A bar panel's furniture is asymmetric -- a heading above, a supporting row *and* a bar below -- so a reading on the panel's own centre does not have equal gaps around it, and a reading with equal gaps is not on the panel's centre. Measured on a `3 x 2` in App mode: 21 px above and 13 below, and equalising them moves the reading 4 px off the panel's centre. The user chose the centring, because whether a panel reserves a bar is a property of its content and a position derived from content is what every version of this arrangement has been chosen to avoid. The design guide carries the arithmetic and how the question came to be asked three times |
| `theme.badgeWidth` reserves 11 px more than the badge draws | Presentation pass | The column is sized with `theme.textWidth`, the estimate, while the badge is placed at its measured width. Every heading on the dashboard pays it. Recorded in the design guide's header section |
| Physical readability review at 480 x 272 | Milestone 4 | Needs hardware; the only thing keeping milestone 4 from being fully closed |
| The panel presentation has not been seen on a radio | Milestone 4 | Elevation, 8 px corners, the clipped accent stripe, the removal of the resting outline and the alert tints have all been judged in the simulator. None has been seen on a radio, which is where the peripheral-vision argument behind the tints can actually be tested |
| Milestones 5 and 6 have not been run on hardware | Milestones 5 and 6 | The diagnostics layouts exist precisely to make that check quick, and the shipped dashboard now exercises all seven core panels at once |
| Staleness is link-wide, not per sensor | Milestone 5 | EdgeTX exposes no per-sensor age except for GPS, so a sensor that stops arriving, or was never received, while the link holds still reads as live. See below |
| Extrema reset policy covers switch and manual only | Milestone 5 | Timer-based reset is specified but not implemented |
| A `1 x 1` panel in the App mode top-left corner cannot be fully shown | Milestone 8 | The button covers 40% of its width and 69% of its height. Its reading survives, pushed below the button, and its header label is dropped rather than clipped. No approach saves it; avoid the placement. It is fully shown in widget fullscreen, where the button is hidden and the corner released |
| The menu button corner has not been seen on a radio | Milestone 8 | Seen and confirmed in the simulator. Measured against the real host and asserted for every shipped layout. Still unseen on hardware |
| ~~Host notices are collected but not shown anywhere~~ | Milestone 8 | Closed. Contrast corrections and palette fallbacks are listed by the `theme` section of the host diagnostics view, which is where they were always headed |
| The status rail is deferred, not cancelled | Milestone 8 | EdgeTX's own top bar fills the role at no Lua cost, and the geometry does not favour a dashboard rail. Default settled as off should it return |
| Steady-state refresh cost scales with panel count | Milestone 6 | The worst the suite measures is in [Current cost](#current-cost). Watch it as the catalogue grows |
| A cells source's real shape is unverified | Milestone 7 | `cell-battery` assumes a contiguous array of per-cell voltages and validates every entry, but no receiver has produced one yet |
| A protocol without an RSSI sensor is detected indirectly | Milestone 7 | `link-status` relies on `telemetryService` observing a source contradict `getRSSI()`. Until something contradicts it, a genuinely dead link and a missing RSSI sensor are indistinguishable, and both read as no link |
| Text width is estimated everywhere except where the unit is placed | Milestone 6, narrowed in the unit pass | The premise was wrong: `lcd.sizeText` measures text and is **not** gated on a draw callback. `luaLcdSizeText` carries no `luaLcdAllowed` or `luaLcdBuffer` check, because it reads font metrics and returns. Unit placement now uses it; every other fitting decision still uses the 0.58 estimate, and converting them is a decision for the user with the numbers below in front of them |
| Trim sources carry no axis metadata | Milestone 6 | The panel assigns its persisted aileron, elevator, and rudder sources to fixed positions and directions |
| `lvgl.image` cannot report a failed decode | Milestone 6 | `StaticImage` clears its source silently, so `model-identity` checks the file with `fstat` beforehand and keeps the model name visible when `fstat` is unavailable |
| `actions/checkout@v4` and `setup-python@v5` target Node 20 | CI | Non-blocking deprecation warning |
| ~~`primitives.arcBounds` has no production caller~~ | Presentation pass | Closed by deletion. It was also wrong — it placed the outer edge at `radius + thickness / 2` where `lv_draw_arc.c` puts it at `radius` — and nothing caught that, because its only callers were tests using the same arithmetic. The tests now measure the arc the mock drew |
| ~~`REFLOW_BATCH` has never been measured~~ | Presentation pass | Closed. Measured across batch sizes 1 to 16 and set to 3, which is where the saving stops. See [Why `REFLOW_BATCH` is three](#why-reflow_batch-is-three) |
| ~~`link-status` thresholds change unit at runtime~~ | Presentation pass | Closed. A threshold is refused at load unless `reading` names a source, through the new `validateSettings` contract hook. The shipped dashboard was relying on the old behaviour and would have sat permanently critical on a protocol with no quality sensor |
| ~~Three development panels ship~~ | Presentation pass | Decided per panel. `service-probe` ships: milestone 9 wants a host diagnostics view and it is the only thing that inspects a service on a radio. `heartbeat` and `placeholder` are now fixtures under `tests/fixtures/panels`, copied into every scratch package so the host-contract coverage they exist for keeps running |
| ~~Panels are outlined on every state, including healthy~~ | Milestone 4 | Closed. A resting panel is an elevated fill with no stroke; the border is reserved for focus, editing, warning and critical, and is built at the focus weight because a radio will not change a border's weight after the object exists |
| ~~A `1 x 1` metric fits its value vertically but width is unchecked~~ | Milestone 6 | Closed. `theme.fitText` fits a value by measured width as well as height, choosing the font from the widest string the panel can ever produce so geometry stays stable |
| ~~`lvgl.arc` is positioned by its top-left corner~~ | Milestone 7 | Closed, and it never was. EdgeTX positions an arc by its **centre**, so every radial drawn before this milestone was one radius up and to the left of its intended place. See below |
| ~~The navigation distance value does not render in the simulator~~ | Milestone 8 | Closed. It rendered perfectly and EdgeTX's menu button was painted over it: `778m` at (8, 25), inside a corner of 47 x 45. Not a Lua fault, and no error was ever raised |
| ~~Panel errors are invisible in App mode~~ | Milestone 8 | Closed. The overlay was drawn at (8, 8), underneath the menu button |

### Hard-won constraints

Thirteen firmware behaviours cost real debugging time and were invisible to the mocked tests until each mock was made faithful. Each now has a regression test, and each is documented in full further down. Why they were invisible, and what stops the next one, is the fixture discipline section below.

1. **A widget callback may not exceed 20000 Lua VM instructions.** Loading, reflow, refresh, and service updates are all bounded work per callback as a result.
2. **`lvgl.box` accepts a `color` and silently ignores it.** Only a filled `lvgl.rectangle` paints a background.
3. **EdgeTX fonts are much taller than they look.** `XXL` is a 69 px line height at 480 x 272. Lay out from measured heights, never fixed offsets.
4. **`getValue` returns integer zero for a telemetry source whose link is down.** That is indistinguishable from a genuine zero reading, so only a zero may be judged: a non-zero value is proof of life whatever `getRSSI()` says, and `getRSSI()` itself reads zero on a live link whose protocol has no RSSI sensor.

Milestone 6 added three more, all of them about what the Lua API refuses to tell a panel:

5. **Lua cannot measure text.** `lcd.sizeText` is only meaningful inside a draw callback, which an LVGL widget does not have, so width has to be estimated. `theme.textWidth` assumes a mean advance of 0.58 of the line height and `theme.fitText` chooses a font from the widest string a panel can ever produce, never from the current one, so a reading does not resize as it changes.
6. **A trim source carries no axis.** Nothing in `getFieldInfo` says whether a trim is a roll trim or a pitch trim. `trim-panel` therefore gives each configured source an explicit aileron, elevator, or rudder role and fixed position.
7. **`lvgl.image` cannot report a failed decode.** `StaticImage::setSource` clears its own source and traces the error when a file will not load, and tells Lua nothing. The decision has to be made before the object exists, so `model-identity` asks `fstat` first and keeps the model name visible when `fstat` is absent.

Milestone 7 added one more, and it invalidated work already shipped:

8. **`lvgl.arc` is positioned by its centre, not its corner.** `LvglWidgetArc::build` calls `setPos(x, y)`, and `LvglWidgetRoundObject::setPos` stores `x - radius, y - radius`. Every radial written in milestone 6 passed a top-left corner, so on real hardware each one was drawn a full radius up and to the left of where the layout intended, overlapping the panel header and the reading beside it. Nothing in the mocked tests could see it, because the mock stores whatever coordinates it is handed. `primitives.radial` now takes a centre, and the tests assert containment against the square the arc covers rather than against `x` and `y`. That square is centre plus or minus `radius`: `lv_draw_arc.c` sets `rout = radius` and `rin = radius - w`, so the stroke is drawn inside the radius and a thickness does not widen the box.

9. **A `clear()` is collected at a time the script cannot predict.** `LvglWidgetObjectBase::clear` only destroys windows and sets `clearRequest`; the reference cleanup happens later, in `callRefs`, which EdgeTX skips while the widget is off screen, such as behind the settings dialog, and once an error has been reported. When it does run, `clearChildRefs` invalidates every reference in that object's child list, including ones created long after the clear. Rebuilding the dashboard in place after a Dashboard ID or Theme change hit this: the canvas was recreated under the cleared root and then silently invalidated, and the next callback failed with `Invalid object (it has been probably been cleared)`, which disables the widget until the radio restarts. The dashboard now draws into a page container. A reload discards the whole page and builds the next generation as a fresh child of the root, which is never cleared, so no pending cleanup can reach it whenever it eventually lands. Deferring the rebuild by one callback is not sufficient on its own, because the collection point is not guaranteed to be the next callback.

10. **EdgeTX prefers `.luac` bytecode and compiles it beside each script.** The radio writes a `.luac` next to every `.lua` it loads and uses the bytecode on the next run. Copying a new image with `rsync -a` preserves source timestamps, so the new scripts can appear older than bytecode compiled from the previous build and the radio silently keeps running the old code. This cost several rounds of debugging: fixes appeared to do nothing, and the widget reported an error at a line number that no longer existed in the source. `make build` now deletes the bytecode and stamps the sources as new. When a fix appears to have no effect on a radio, confirm which code is actually running before changing anything else.

11. **Every update to an arc moves it, unless the update restates its centre.** `lvgl.arc` is positioned by its centre but stores `centre - radius`, and `LvglWidgetRoundObject::refresh` subtracts the radius twice: once inside `setRadius`, which converts the stored corner back to a centre, and again through the inherited `LvglWidgetObjectBase::refresh`, which calls `setPos(x, y)` with members that already hold a corner. Any `set` call runs `refresh`, whatever keys it carries, so an arc walks up and to the left by its own radius each time it is touched. `build` does not call `refresh`, so a dial is correct until its first update and wrong afterwards: the compass vanished the moment a GPS fix arrived, and the quality dial crept off its panel over a few telemetry readings. `primitives` now routes every arc update through one helper that adds the centre to the change set, which overwrites the drifted members with absolute coordinates so the doubled subtraction lands correctly. The test mock models this arithmetic rather than recording the coordinates it was handed, because a mock that stores what it is given cannot see the object move.

Milestone 8 added one firmware behaviour, and one about what a constant means:

12. **EdgeTX paints its menu button over the widget in App mode, and says how big it is in a unit nobody expects.** `ViewMain` creates the top bar after the screen, commented `// create last to be on top`, and the button is parented to `ViewMain` rather than to the bar, so hiding the bar in App mode leaves the button drawn over the dashboard's top-left corner. Anything underneath it is simply not visible: the shipped dashboard's distance reading was painted over for two releases without a single error being raised. The firmware does publish the size, as `MENU_HEADER_HEIGHT`, but registers it beside the colour constants so it passes through `COLOR2FLAGS` and arrives shifted left by sixteen bits. The global reads 2949120 on a TX16S, not 45. A host that never unshifts it falls back to a hard-coded 45 and is then wrong on every radio whose display class scales the constant, which is why the mock publishes the shifted value and the tests measure a 62 px button as well as a 45 px one.

The presentation pass added one more, and it had been silently wrong for as long as the panels had states:

13. **A rectangle's border width and corner radius are build-time properties.** `LvglWidgetRectangle::build` is the only caller of `lv_obj_set_style_radius` for a rectangle, and `LvglWidgetRectangle` adds no refresh of its own, so a `rounded` passed to `set` is parsed and then ignored. Border width is worse, because it looks like it works: `lv_obj_set_style_border_width` is called only from `LvglWidgetBorderedObject::setOpacity`, which runs behind `LvglParamFuncOrValue::changedValue`, and `refresh()` hands it the opacity the object already has. So `set{thickness = n}` updates the C++ member, never reaches LVGL, and reports nothing. Every panel therefore drew whatever weight it was born with: a panel created healthy and later going critical asked for the focus weight and kept the resting one, on every radio, for three milestones. The panel now builds its border at the focus weight and shows or hides it, because visibility is the only property of a border that can actually change after the object exists. The mock keeps what was applied at build apart from what was last passed, so a test asserting the latter fails.

Two more lessons came from the tests rather than the firmware:

- A budget test that measured only the shipped layout could not fail, and hid a loader that broke on any layout larger than twelve panels. Measure the worst case the schema permits, and assert that the measured work actually happened.
- An assertion can be vacuous without being wrong. A test that a missing model bitmap falls back to the model name passed while the panel was too short to have shown an image at all. It now asserts first that the panel could have shown one.
- A geometry test that only checks the right and bottom edges cannot see two rows resolved onto the same line. Milestone 7's region tests assert that every supporting row clears the one above it and every column clears the one beside it, and that shedding a row actually buys the dominant reading a larger font, which is the reason for shedding it.
- A fallback can hide the bug a test was written for. The reserved-corner test passed with the `MENU_HEADER_HEIGHT` unshifting removed, because the code's own 45 px default was right for the display the test used. Only measuring a display whose button is a different size made the shift load bearing. A default that rescues the mistake is worth keeping; a test that cannot see past it is not.
- A panel that reimplements a shared helper stops receiving that helper's fixes. `service-probe` had its own copy of the panel frame arithmetic, so it kept drawing its title into the menu button's corner after every catalogue panel had stopped. `metric` shadowed a subset of the frame's fields and handed that to the header primitive, so it silently missed the new one.
- A fixture's own limitation can be written up as firmware behaviour. A global variable test asserted that switching flight mode left the value unmoved and explained it as EdgeTX resolving inheritance; the mock ignored the flight mode argument, so the assertion could not have failed and the explanation was invented. See the fixture discipline section below.
- A refresh short-circuit is a cache, and a cache that misses a change shows an old number with a straight face. Three of milestone 7's panels compared only their dominant reading and froze supporting content: pack sum, RSSI while LQ was unchanged, and GPS fix state. Every drawn field must participate in the comparison; model-identity coverage also checks labels changing without the model name changing.

  The list is the defect. A panel now declares what it draws, into one table, and is handed that table to paint from; the comparison is over exactly those values. A field the paint step reads but the declaration never wrote is `nil` on screen, which is loud, and a field declared but not painted costs a comparison and nothing worse. The list cannot drift from the drawing because there is no list.

  Auditing the catalogue for the same shape once the mechanism existed found three more, all latent: `flight-mode` drew the mode number and compared only the name, so two modes sharing a configured name would have frozen it; `flight-timer` drew the configured total and compared only the elapsed value, so a timer reconfigured mid-flight kept the old one; and `navigation` drew the coordinates and compared distance and bearing, which are measured *from home* and do not move when a model tracks an arc at constant range. `model-identity` had it too and could not be made to fail, because a model's labels change only when its name does — unreachable by coincidence rather than by construction. All nine panels with a short-circuit now share the one mechanism.

  **What a panel declares follows what it currently draws, not what it was built with.** Every panel that can shed a supporting row went on declaring that row while it was shed, which is the same invisible work `trim-panel`'s reflow was made of, and it also meant a row coming back was only correct because `update` discarded the last drawn record to force a repaint. The discard is remembering; the declaration is construction. All of them now gate on whether the row is showing, so a shed row declares nothing, a returning row declares a key that was absent, and `changed` sees the reveal by counting keys. The discards are gone.

  The finding worth recording is that **none of those discards was load-bearing**, and it took some effort to establish rather than assume. With a gate removed, no test could be made to fail on a stale row, because a reveal is always caused by a resize and a resize always moves some other declared value — a fitted caption's width, if nothing else — so the panel repainted anyway. The discards were protecting a path that is not reachable. That is the same shape as `model-identity` above: correct by coincidence. The tests therefore assert the property directly, that every declared key belongs to a row that is drawn and every drawn row has one, rather than trying to observe staleness that cannot currently occur.

### Fixture discipline

Six defects reached a radio while this suite stayed green, and a seventh was found in the tree before it could. They are listed below, and they are one defect: **a fixture encoded what we assumed, so it could not fail when the assumption was wrong.** A green suite told us nothing, because the mock and the code under test agreed with each other and both were wrong about the radio.

The rule has grown a part for each shape the failures came in, and each part is here because something shipped.

**A fixture that stands in for firmware must reproduce that firmware's arithmetic, ordering and data shape, and must cite the file it came from.** Not the result we expect it to produce: the behaviour. A mock that records the coordinates it is handed cannot see an object move. A mock whose `clear()` is an immediate flag cannot reproduce a deferred cleanup. A mock that returns its input unchanged cannot distinguish two encodings that are only the same number here. Where the firmware raises, the mock raises; where the firmware caps a value at 99, so does the mock; where the firmware accepts a fixed set of keys, the mock rejects everything else.

**A function that answers "the largest thing that fits" must also answer whether it fits.** This has now cost the same mistake twice. `theme.fitReading` returned the smallest font on the ladder whether or not the text fitted at it, and `tx-battery` read that as success and spent width on a battery the reading needed. Then the design-mock generator's own band fitter did exactly the same thing -- returned the smallest font and a cost of zero sizes when the truth was that nothing fitted at all -- and reported `navigation` at `1x1` as free when its widest distance is 60 pixels in a 48 pixel slot.

Both were written by someone who knew about the first one. The shape survives being known about because the failing answer is indistinguishable from a good one: a font comes back, it is a real font, and the caller has no way to tell that it was a surrender rather than a fit. The rule is therefore structural rather than a matter of care. **Where a search can fail, the failure is a return value, not a convention about the answer.** A caller that ignores it gets what it always got; a caller that is deciding whether to spend space on something else has to check it, and now can.

**A position derived from a size must be recomputed when the size changes, never carried as an offset.** This is the most persistent defect in the project, now at eight appearances and it has now happened in the tests, in three panels, in `theme` itself and in the design-mock generator: something decides a size and something else draws at a position computed for the old one. The most recent was a unit printed twelve pixels inside its own reading, because the reading was resized from `SMLSIZE` to `MIDSIZE` and the unit was shifted by the reading's displacement rather than re-placed against its new end. It appeared only where the font actually changed, so two panels of the same width behaved differently and width looked like the cause. The overlap was exactly the growth minus the gap, which is what an offset held across a resize always produces.

It survives because the stale offset is usually right -- it is wrong only in the cases where something resized, which are the cases nobody renders while working. The two most recent are worth their own note, because each hid somewhere the first six did not.

The seventh was a **width estimate standing in for a measurement in a placement decision**. `theme.textWidth` over-reports on purpose, so that text shrinks rather than clips, and a generous number is the right answer to "does this fit" and the wrong one to "where does this start": half of the generosity lands in the left edge of anything centred with it. A transmitter reading sat thirteen pixels left of its slot for that reason, and ten and a half more because the width being centred was the widest string the panel can ever print rather than the one on the screen. That was first resolved as **the estimate decides whether something fits; the measurement decides where it goes**, and `lcd.sizeText` is available in both `create` and `update` because `luaLcdSizeText` touches neither the draw context nor the LCD buffer. The boundary did not survive: the estimate is one allowance per character, sized between a digit and a capital, so it over-reports digits and under-reports capitals, and `model-identity` -- which fits against a row of `M`, because that is the widest name EdgeTX stores -- was drawing its name eleven pixels past the panel at `1 x 2`. **Both questions are answered by the measurement now**, and the estimate remains only as `measureText`'s fallback for a host with no `lcd.sizeText`.

The eighth was found **latent, in an anchor guarding an expensive recomputation**. `followUnit` re-placed a unit only when the reading's text changed, and tested that by comparing the text's *length*. Two strings of one length are not one width -- `--` and `12` are both two characters and differ by twelve pixels at DBLSIZE, because a dash is a fifth of a line height and a digit is three sevenths -- so the unit held station across exactly the change every telemetry panel makes when its sensor goes quiet. **An anchor that guards a recomputation is a place this shape hides**, because the guard is a proxy for the thing rather than the thing, and a proxy that is usually faithful is the same trap as an offset that is usually right. Anchor on the value itself: Lua interns short strings, so comparing them costs no more than comparing their lengths. The defence is not care but arithmetic: **derive the dependent position from the current value at the point of drawing**, and check the result mechanically. A collision check over every drawn label, comparing ink rectangles pairwise and against the panel edge, is cheap, catches every member of this family at once, and found this one after four other measures on the same page reported everything healthy.

**A check that would pass if everything moved together is not a check on position.** Overlap, containment and wrap are each satisfied by a uniformly displaced element, and all three passed a reading sitting 23.5 pixels outside the slot the layout rule put it in -- on a shipped dashboard, until a user looked at it. Nothing overlapped, because the displacement moved the number *away* from the battery beside it; nothing left its panel, because a panel is wider than a number; nothing wrapped, because the label was as wide as before. The rule had been implemented, and the words `slotCentres`, `slotX` and `slotsFor` appeared nowhere in the suite.

So a rule about where something goes needs an assertion about where it went, and the two are not the same kind of claim: relational checks constrain elements against each other and a positional one constrains an element against the panel. **Derive the expected position from the geometry rather than by calling the function under test** -- an assertion that restates the implementation passes for any self-consistent wrong answer, which is the failure mode already recorded above. Where a choice between arrangements has to be recovered, read it off something placed by different means: the battery's own drawn x says which slot set is in force, because a glyph is positioned from its geometry and not from a text width.

**An assertion must pin the value the contract names, not assert that something differs from something else.** "Differs from" is satisfied by every wrong answer as well as the right one, and is therefore satisfied when every value is wrong in the same way, which is precisely what happened. The same applies to "is not nil", "is greater than zero", and any assertion whose truth does not depend on the implementation at all: `contrast(a, b) >= 1.0` was in this suite for two milestones and is a tautology.

**An assertion must be about what the panel draws, not about what it computed.** This is the newest of the shapes and was found by accident. Seven assertions in this suite described the text of supporting rows on panels that shed those rows: the shipped dashboard's cell count, both link panels of the telemetry layout, a trim panel's caption, and others. Every one passed, because the panel computed the row's text and then hid the label, so the string existed and was correct and was on no screen anywhere. They only failed once the panel stopped doing work for labels nobody sees, which also recovered 298 instructions a frame in the header case, and 736 from the worst callback in the trim panel. The two facts are the same fact. Invisible work is work nothing is checking, and an assertion that reads state the panel does not draw is testing the panel's bookkeeping rather than its output. Where a panel can shed an element, assert that it sheds it, and assert the content at a span that shows it.

The hard part is that invisible work is invisible to assertions as well as to eyes: nothing about what is *drawn* can see a panel repositioning a label it has hidden, so the cost grows unnoticed and the only symptom is a number on a budget report. The harness therefore counts writes and visibility calls per object, which is its own bookkeeping and not a claim about firmware, so a test can assert that a shed row costs nothing to keep shed. Those counters are swapped out rather than branched around while a callback is measured, for the same reason property validation is: see the mock rule below. Branching cost 261 instructions of a measured callback before they were swapped, which is the same mistake as charging a Lua stand-in for a C++ call, made by the tool built to detect it.

**What a panel is permitted and what it draws are different questions, and whatever decides the layout must be told the second.** This is a seam rather than a mistake: composition is decided centrally, from the panel's box alone, so that two panels of one size agree -- and a panel may then decline what it was granted, because only it knows whether its optional content is configured. The grant and the decline are computed in different files, and the shared half has twice acted on the grant.

The first instance placed a row: `metric` may carry a secondary reading at `2 x 2`, but whether it does depends on a source being set, and the geometry was handed only the span. A panel drawing one supporting item arranged it as a row of two, so a lone caption sat on the left slot instead of centred.

The second reserved a band. `theme.ladder` granted a supporting row from the panel's height and passed that grant to `theme.bands`, which took the tertiary quarter out of the body. Three panels default their row off -- `flight-mode`'s mode number, `model-identity`'s label list, `tx-battery`'s estimate -- so all three were charged a quarter of the panel for a row they would never fill, and their readings came from a band 31 pixels shorter than the panel had. Each lost a font size at every two-row span, and `flight-mode` additionally built a label and wrote an empty string into it, which is the invisible work this document forbids, in a panel that had already been swept for exactly that.

**The second instance was closed and then the closure was withdrawn, which is worth following.** Telling the band what the panel draws fixed the font, and it did so by making the band a function of the content: a panel with a row got a half and the identical panel without one got three quarters. The user put that on a radio and rejected it -- two panels of one size are supposed to agree, and these did not. The bands are fixed proportions now and take no argument at all, so the seam is closed by removing the question rather than by answering it correctly. The invisible-work half of the finding stands: a shed row still builds no object.

That is the better shape wherever it is available. A seam exists because two places have to agree about something; if the something can be made not to vary, there is nothing left to disagree about. It is not always available -- `metric`'s secondary reading genuinely depends on configuration -- but it was here, and it was reached only after the content-dependent answer had been built, measured and shipped.

**Neither instance was visible to any check**, and that is the property worth remembering: a reading centred in a band smaller than it should be is correctly centred, correctly sized for that band, and inside its panel. Containment, collision and position all pass. The only symptom is a font one step down, and nothing was comparing what was reserved against what was drawn.

So the interface carried the answer rather than the question for a while, and then stopped needing to. `theme.ladder` took what the panel would draw and could only narrow its own grant with it. That argument is gone, because nothing downstream of it varied with the answer any more, and an argument a caller passes and believes is honoured is worse than an absent one. The tests are `testReadingsIgnoreTheRowBeneathThem`, which holds that the same panel with its optional row off puts its reading on the *same line* as with it on -- the reverse of what its predecessor asserted -- and `testTertiaryQuarterHoldsItsFurniture`, which holds that a panel drawing no row builds no object for one and that nothing else grows into the quarter it leaves empty.

**Closing a seam in the data does not close it in the ordering.** `theme.panel` takes `spec.bar` to reserve the floor, while the ladder inside the builder decides whether a visual survives. Floor reservation is therefore a separate decision from current visibility; panels must not independently predict the builder's answer.

**The fourth instance is the unit beside a reading, and it is the one where neither place could have carried the other's answer.** `showUnit` says a panel has room for a unit; whether there is a value for that unit to qualify is a property of a sensor that may not have reported yet. Four panels therefore drew `-- V`: the permission was true, so the unit was drawn, and nothing downstream asked whether the number beside it existed. It is unlike the three above in that no amount of telling the builder what the panel draws would have fixed it -- the answer changes after the builder has finished, every time a link drops -- so the seam is closed the other way, by moving the *decision* to the point of drawing rather than the *information* to the point of deciding. `primitives.centreReading` is handed the reading's current text on every repaint and already computed the pair's width from it; asking there whether that text is a value costs a table lookup and cannot go stale.

**The shape to take from it is that a seam closes wherever both halves are simultaneously true, and that is not always the earlier place.** Three of the four were closed by giving the central decision better information, which works when the information exists by then. This one is a permission that stops being sufficient later, and the only place both halves are known is the last one.

**It also had to be closed twice, which is the part that nearly went wrong.** A unit reaches the screen from two functions -- the per-frame placement and the reflow's reconciliation -- and the first version put the test in only the per-frame one. Every panel was then correct until the zone changed, at which point the reflow asked "does a unit fit here" and, satisfied, showed one beside `--`. A rule that holds in one of two paths holds in neither, and the way that was found was by writing the reflow assertion and watching it fail rather than by reading the call sites.

**A sizing form is a claim about the future, and nothing in a fixture can check one.** A panel sizes its reading against the widest string it will *ever* print, which is what keeps a value from resizing as it changes. That string is an assertion about every future value, and a test can only ever build present ones -- so the form can be measured perfectly, placed perfectly and be the wrong string, and every check will pass.

It has now been wrong twice, in opposite directions, with opposite costs, and neither was caught by a test:

- **Sized for less than it draws, so it clipped.** `model-identity` sized against a row of `M` through an estimate that under-reports capitals, and drew the model name eleven pixels past the panel at `1 x 2`. A user saw it.
- **Sized for more than it draws, so it cost a size.** `flight-timer` sized against `-88:88:88`, reserving for a countdown ten hours past zero. It fitted a `2 x 2` content box by 8 px here and did not on a radio, so that panel stepped its clock down while the `3 x 2` beside it did not. A user saw that too.

The second is the more interesting failure, because over-reserving looks like caution. It is not: a form wider than anything the panel will print buys nothing and spends a font size, and it spends it *silently*, because a panel reading one step small is a panel that looks fine.

What is checkable is the **loop**, and only where a panel bounds what it can print. If the panel clamps its own reading, then the clamp's output must equal the form, and both are present-tense facts a fixture can build. `flight-timer` now clamps at `99:59`, declares `-99:59` -- a string the clamp genuinely produces rather than a row of eights that is not a valid clock -- and `testClockNeverOutgrowsItsForm` asserts the two agree. Break either end and it fails by name.

**Where there is no bound there is still no check**, and that is the residue rather than an oversight. `model-identity` prints a name the pilot typed; nothing bounds it but EdgeTX's own field length, and a form is a genuine guess there. The rule that follows is about the *shape of the form* rather than about testing it: **prefer a form the panel can actually produce over a placeholder, and prefer bounding the reading over widening the form.** A bound converts a claim about the future into an assertion about the present, which is the only kind a suite can hold.

**A declaration that does not construct the case is not coverage.** Two of this suite's checks are declarations rather than tests: a panel states what it slots and what it words, and the check covers it. That is right, and it introduced a failure mode the tests it replaced did not have -- a declaration can name a case the declared configuration never builds, and then the check watches nothing while reporting a panel covered.

It was found by breaking something and watching nothing happen. `metric`'s supporting row was moved off its slot deliberately, and the whole suite stayed green: the panel was declared with a source but no *secondary* source, so it only ever drew a one-item row, and the two-item arrangement the break corrupted was never constructed. The declaration named `metric`; the coverage was of half of it. Adding a variant that configures a secondary source makes the same break fail by name.

So a declaration carries the configuration that builds each arrangement, not merely the panel that can draw them, and **the way to know a declaration covers what it claims is to break the thing and watch it fail** -- which is the general rule above, applied to the declaration rather than to the assertion.

The corollary is about the panels rather than the tests, and it generalises past this suite. **A panel whose content depends on configuration rather than on span must be told which, because a span says only what is permitted.** `metric` may carry a secondary reading at `2 x 2`; whether it does depends on a source being set. Handing the geometry the span alone made it arrange a two-item row on a panel that draws one, so a lone supporting row sat on the left slot instead of centred -- correct for the arrangement it was told about and wrong for the one on screen.

**A document that states a contract must be executed, not read.** The layout example in this specification did not load for at least two milestones, and nobody noticed because nothing ran it: it named a setting no panel declares, gave a source as a numeric identifier the telemetry service rejects, and asked `link-status` for a `4 x 3` span it does not support, so the host would have dropped that panel. Two of those three survived being corrected by hand, which is the point — reading an example carefully is not the same as running it. The suite now extracts every fenced YAML block from this file at test time and puts it through `yaml.parse`, `layout.validate` and `panelHost.resolveSettings`. It is extracted rather than copied into the test, because a copy is a second source of truth and would drift from the document exactly as the document drifted from the code. A block that matches no known kind fails rather than being skipped, and an extraction that finds nothing fails rather than passing over an empty string, because a test that reads a document it cannot find is a vacuous assertion wearing a new hat.

**A fixture must model what an object *is*, not only what it accepts.** This one cost a user a dashboard of error banners, and it is the narrowest shape yet. The LVGL stand-in already refused a property key `parseParam` does not accept, which models what an object accepts through `set`. Nothing modelled what the object is. An object handed back by `lvgl.*` is userdata: `LvglWidgetObjectBase::getRef` allocates one pointer with `lua_newuserdata` and attaches `lvgl_base_mt` or `lvgl_mt`, and neither metatable declares `__newindex`, so a field assigned onto a label raises and a field read off one is always nil. The stand-in was a plain Lua table, which accepts any name you invent and returns it again. So `label.headingText = text` in `primitives.header` stored the heading happily here and broke **every panel on the radio at once**, with the suite green; and `label.headingText` in `placeHeader` read back the truth here and nil there, so a reflow silently never refitted. The write was loud and the read was silent, and both came from the same wrong idea about what the fixture was standing in for. The mock now seals its objects with a `__newindex` that raises in the radio's own words, and reaches its own bookkeeping through `rawset`, which is the honest admission that `properties`, `writes` and the rest are the fixture's fields and not the firmware's. Ask of any stand-in not only *what does the real thing accept* but *what kind of thing is it*, because the second question is the one nobody asked for eight milestones.

**Where something sits is a property, and it needs an assertion of its own.** A reading's *font* is covered many times over, because a font is what changes when a rule about size is got wrong. Its *position* was not, and four separate defects in one panel hid there: a heading centred in a band drifted 30 px down as panels grew; a picture was cropped rather than fitted, which no test could see because `fill` changes no coordinate; a model name was promoted to the heading with nothing observing the heading's text; and the name was drawn at the panel's content top rather than in its body band, 59 px above where every other reading in the catalogue sits.

All four passed every check the suite had. The reason is worth stating because it generalises past this panel: **the band rule chooses the same font wherever the reading is drawn in the band**, so a font assertion is satisfied by a correct size in the wrong place. Containment is satisfied too, and so is collision, because a reading placed too high overlaps nothing -- it is simply not where the rule says.

The panel that hid all four is the one whose reading is text rather than a number, which is the second half of the explanation: no cross-panel comparison ever lined it up against a neighbour, and every check written for readings was written while looking at digits. A property that only one panel can violate is a property nobody writes a check for.

**Two layers of the suite can measure the same thing differently, and agree until something exercises the difference.** The integration collision check measures a label by its ink -- `themeModule.fontAscent`, because a font's descent and leading are not drawn and a reading that "overlaps" a bar by its leading overlaps nothing. Two unit tests measured the same readings by their line box, `valueY + fontHeight`. Both were defensible in isolation and the two never disagreed, because every reading was centred by its line box, so the slack sat above the glyphs where neither measure looked.

Changing the placement rule to centre the ink moved that slack below the glyphs, and the two measures immediately disagreed: the unit tests reported a reading sitting on a bar at `2 x 1` and on a supporting row at `cell-battery 2 x 2`, in both cases by a margin no glyph reaches. Nothing was wrong with the dashboard; two parts of the suite had different definitions of where a reading ends.

The shape is worth naming because it is not the same as a check being wrong. Both checks were right about what they measured. **What was missing was that they measured different things and nothing said so**, and the disagreement was invisible for as long as the system happened not to produce a case that separated them. A suite with two definitions of one quantity is carrying a latent contradiction, and the way it surfaces is as a false failure during an unrelated change -- which is the moment when it is most likely to be "fixed" by adjusting whichever measure is in the way.

**A shared helper's name can promise more reach than it has.** `theme.bandFont` is named as though it decides the reading font for panels generally, and it decides it for `tx-battery` and nothing else: every other panel goes through `theme.fitReading` or `theme.fitReadingUnit`, which walk the same ladder against `ladder.room` and never call it. Changing `bandFont` to choose by ink rather than by line height therefore moved eight cases out of the catalogue's 272, where the intent was to move all of them, and the fitting ladder had to be changed as well.

That is not a defect in either function -- they do different jobs for different callers. It is a trap in the naming, and the cost is that a change made in the obvious place lands in a twelfth of the dashboard and looks finished. Anything altering how a font is chosen has to alter `bandFont` **and** both fitting entry points, or state deliberately why one of them is being left alone.

**The thing that checks is also a thing that can be wrong, and it fails silently by agreeing.** Three times now the apparatus has been the defect. A collision check could not see non-text objects, so a reading lay across its own bar through a whole revision of the design mocks. A declaration named a panel but not the configuration that builds its two-item row, so the check watched a case that was never constructed. And a verification harness written to compare two checkouts used a shell `cd` that persisted between invocations, so it compared one tree against itself and reported agreement -- which was then used to correct a true finding into a false one.

The shape is that all three failed towards *pass*. A check that is broken towards failure announces itself on the next run; a check that is broken towards success is indistinguishable from the thing it is supposed to be proving, and the stronger the rest of the discipline is, the more weight its agreement carries. The defence is not more checks but the same rule applied one level up: **break the thing the check covers and watch it fail by name** -- and for a comparison, make it disagree on purpose before trusting it when it agrees. A harness that has never been seen to report a difference has not been shown to be capable of reporting one.

**A comment must not explain a test's behaviour with a claim about the radio that nobody has checked.** This is the least obvious of the three and the most corrosive. A global variable test asserted that switching flight mode left a value unmoved, and explained the non-movement as EdgeTX resolving inheritance. The explanation was invented. The value did not move because the fixture ignored the flight mode argument entirely and answered the same number for every mode, so the assertion could not have failed however wrong the host was. A vacuous assertion is inert; a vacuous assertion with a confident explanation actively stops the next reader checking, because it answers the question they were about to ask. If a comment states what the radio does, it is a claim, and it carries the same obligation as a value: cite it or do not write it.

#### The evidence

| # | Defect | What the fixture encoded |
| --- | --- | --- |
| 1 | Arc drift. Every dial walked off the screen a radius per update | The LVGL mock stored the coordinates it was handed instead of modelling `LvglWidgetRoundObject`'s doubled subtraction, so it could not see an object move |
| 2 | An unbounded loader that broke on any layout over twelve panels | The budget test measured the shipped five-panel layout against a ceiling it used a third of |
| 3 | `Invalid object (it has been probably been cleared)` after a theme change | The mock's `clear()` was an immediate flag with no parent/child tracking, so EdgeTX's deferred cleanup ordering could not occur |
| 4 | Healthy panels drew yellow and warnings drew critical red | The theme fixture invented EdgeTX role colours to match the role *names*. The firmware ships `ACTIVE` yellow, `EDIT` green and `WARNING` red |
| 5 | Every panel of every theme drew dark red | `lcd.getColor` returned a bare RGB565 where the firmware returns an `LcdFlags` word, so the suite exercised a decode path that does not exist on a radio |
| 6 | Supporting rows overran their boxes unchecked | Six assertions pinned the text of rows their panel does not draw. The text was computed for a hidden label, so it was correct, asserted, and invisible |
| 7 | Every panel on the radio failed to build: `attempt to index a userdata value (local 'label')` | The LVGL stand-in was a plain Lua table, so a field written onto a label was stored. On a radio an object is userdata with no `__newindex` and the assignment raises |

Defect 5 also produced the clearest example of the second shape. The assertion checked only that the derived canvas *differed* from Modern's, which is trivially satisfied when every colour is wrong in the same way. With the bug reintroduced, the entire suite passed.

The audit that followed found a sixth of the same family, still in the tree: `lcd.RGB` was returning its 24-bit input where the firmware returns the same flag word. It had not yet caused a defect, but it made `theme.rgb` and `theme.color` the same number under test, so nothing could tell a palette token apart from a display value. Drawing every panel with the wrong one passed the whole suite.

#### What holds the rule up

Prose does not. Each part of the rule has a mechanism.

- `tests/support/edgetx.lua` splits every value into `firmware`, which is a claim about the radio and must name the file and symbol it was read from, and `scaffold`, which is invented and owes nothing. The citation is enforced at load: an uncited value, a path outside `radio/src/`, or a citation naming no symbol raises before any test runs, and there is no warning-only mode. The obligation covers behaviour as well as constants, because three of the five defects were wrong arithmetic rather than a wrong number.
- The LVGL mock rejects a property key the firmware's `parseParam` does not accept, and a colour that is not a word `lcd.RGB` produced. Both are faithfulness rather than extra rules: the firmware raises `Invalid property '%s'`, and a 24-bit token on a radio paints a colour belonging to no theme.
- Every test is proved able to fail. Break the thing it covers, watch it fail with a message that names the problem, restore. A test that cannot be made to fail is not a test, and several in this suite could not be.
- Keep the mock out of the instruction budget. `parseParam`, `lcd.RGB` and `getValue` are C in the firmware and cost a script nothing, so charging a Lua stand-in for them to a widget callback measures the fixture and slowly squeezes the thing being measured. This applies to the harness's own bookkeeping as much as to its stand-ins: the per-object write and visibility counters exist so a test can see work that leaves no trace on screen, and they are swapped out rather than branched around while a callback is measured, so a measured callback pays nothing for them.

**LVGL's own behaviour is citable, but only once the submodule is initialised.** `radio/src/thirdparty/lvgl` starts uninitialised, and while it is, `lv_draw_arc.c` and everything else below EdgeTX's own wrappers cannot be read, so anything the dashboard depends on from inside LVGL is an unverifiable claim. The rule's third part applies to those with particular force. One shipped example was found and removed during the presentation pass: a panel's accent was built as a pill on the strength of a comment asserting that LVGL clamps a corner radius to half the shorter side, which nobody had checked. Run `git submodule update --init --depth 1 radio/src/thirdparty/lvgl` in the EdgeTX tree before writing a claim about LVGL, and cite `lv_*.c` the same way as any other firmware file. Where a construction can be made indifferent to LVGL's behaviour rather than dependent on it, prefer that even so.


## Proposed Release Phases

### Implementation status

Status last verified on 2026-09-21:

| Work item | Status | Implemented | Remaining |
| --- | --- | --- | --- |
| Build and test foundation | Complete | Make targets, isolated Python environment, unit/integration suites, EdgeTX Lua parsing, tracked simulator fixture, reproducible `build/sdcard` assembly, and GitHub Actions CI running `make check` against Lua 5.3 | None |
| Milestone 1: Runtime skeleton | Complete | LVGL host, integer 4 x 4 geometry, gutters, per-panel containers, batched reflow, App mode fixture, and `1 x 1`-sized mocked tests | Additional physical-radio verification belongs to hardening |
| Milestone 2: Read-only YAML loader | Complete | Constrained parser, empty flow collections, schema version check, model/Dashboard ID resolution, default fallback, fail-closed document validation, per-entry validation, preserved unknown keys, and a malformed-input matrix | Physical-radio verification belongs to hardening |
| Milestone 3: Panel runtime | Complete | Referenced-module loading, metatable-safe contract validation, declared settings with typed defaults, `supportedSpans` enforcement, host-owned containers, declared refresh intervals with phase staggering, and isolated create/update/refresh/background/event/destroy dispatch | Production panels arrive in milestones 6 and 7 |
| Milestone 4: Design system | Complete | Semantic tokens, panel/typography/bar/radial/badge primitives, YAML-defined named themes, guaranteed-legible customizable palettes, all seven states, and one shared responsive ladder deciding composition from the box and the font from the composition | Physical readability review at 480 x 272 on a TX16S-class display |
| Milestone 5: Shared data services | Complete | Registry with per-service intervals, staggering, and subscription caps; telemetry, model, control, extrema, and navigation services; immutable snapshots; graceful degradation for missing sources, unseen sensors, absent firmware APIs, and stale telemetry; `service-probe` diagnostic views and two shipped diagnostics layouts | Hardware verification, and timer-based extrema reset |
| Milestone 6: Core panels | Complete | `metric` with independent numeric readings and GV sources; `flight-timer`, `flight-mode`, `tx-battery`, `trim-panel`, and `model-identity`; shared panel geometry, bars/radials, and images; a shipped dashboard demonstrating all six | Physical-radio verification of text widths and model bitmap scaling |
| Milestone 7: Telemetry-specialized panels | Complete | `cell-battery` with cells-table validation; `link-status` with independent RSSI and quality; `navigation` with responsive presentations and a north-up dial; a shipped dashboard demonstrating the nine display panels, with separate diagnostics screens | Hardware confirmation of the cells shape and of no-RSSI-sensor detection |
| Milestone 8: The App mode menu button and multiple screens | Complete | Dashboard ID option, per-model/per-dashboard filename resolution, dashboard-scoped layouts shared by every model, panels laid out around the App mode menu button through the shared frame, an error overlay that clears it, notices separated from errors, and two-instance and model-change coverage | Status rail deferred by decision, not outstanding; simulator confirmation of the corner on a radio |
| Milestone 9: Hardening | In progress | Unit/integration tests, firmware-like string behavior tests, CI running Lua 5.3 parsing, simulator fixture, corrupt-layout, contract-rejection, hostile-module, and legibility coverage, panel failure isolation, an enforced instruction budget measured at the largest legal layout for both panels and services, diagnostic views over every service, and a host diagnostics view on its own screen | Target-radio matrix and physical-radio testing |
| Milestone 10: On-radio editor | In progress | Touch and rotary/key editor for add, move, resize, configure, remove, defaults, Apply, and Cancel; strict validation; deterministic YAML writing; verified temporary-file saves and backup rotation; backup/default recovery; unit and simulator integration coverage | Physical-radio control/usability checks and verification of EdgeTX file write/rename/remove behavior |
| Presentation and consistency pass | Complete | An audit of every panel at every declared span measured through the real host, then: the panel as a card with a clipped accent stripe, alert states tinting the surface instead of the frame, the badge vocabulary cut from thirteen strings to five, header geometry that never reflows on a state change, one shared responsive ladder replacing eight private copies, a render declaration the redraw comparison is derived from, one settings vocabulary with enforced `choices`, and `trim-panel` no longer drawing what it hides | Six items deliberately set aside, listed under [Deliberately set aside](#deliberately-set-aside); none of it seen on a radio |
| Vertical-rhythm pass and panel reviews | Complete | The heading pinned to the top inset and the supporting row hung from the bottom one, the reading's ink centred on the panel and sized from the panel's height, superseding fixed band proportions, which superseded redistribution; font choice and placement moved onto a font's ink; headings pinned to the top of their band; badges placed from their measured text; `model-identity`'s picture fitted whole and its name moved into the body band or the heading; single-form supporting rows wherever one fits; a display clamp on the timer's clock; a unit withheld beside a reading with no value; per-panel review screens on a second model and the span galleries retired to fixtures | Navigation visual acceptance remains in progress; bearing formats and compact coordinate rows are implemented. Three panels do not yet route their row through `fitLabel`. |

The design system is in place: the host owns every color, resolves one theme per dashboard, and hands each panel a `services` table carrying the theme, shared primitives, span-appropriate typography, a state resolver, and the five shared data services. The `metric` panel is the reference implementation and now reads real telemetry; the temporary `demo` setting is gone. Milestone 4's remaining item is a physical readability review, which requires hardware.

Measured cost is in [Current cost](#current-cost), which is the one place that carries it. It used to be restated here as 7518 and 2520, and both had drifted from what the suite reports; a figure kept in two places is a figure that will disagree with itself. Fourteen layouts are exercised, thirteen of them at sixteen panels: metrics with sixteen distinct live sources, sixteen diagnostic panels spanning all five services, sixteen panels that demand a refresh every frame, one layout per catalogue panel type, and the shipped ten-panel dashboard.

**The worst callback is the staged loader, not any panel's own work.** The cited panel-specific instruction baseline predates the fixed three-axis presentation and needs to be regenerated before it can be treated as current. Every layout's second-worst is the loader's header stage, between 6209 and 7361. The three telemetry panels at sixteen cells reach 6721, 6593 and 6337, all of them in that header stage, and their worst steady frames are 2290, 2380 and 2562. Removing the services' subscription caps raises the worst steady frame to 6200, which is what the caps are for. On a full grid, panel work is no longer the binding constraint, which is worth knowing before optimising a panel.

### Proposed flight-status panel: aircraft-reported state

**The dashboard shows nothing the aircraft reports about its own state.** `flight-mode` shows EdgeTX's transmitter mixer modes, not an aircraft-reported mode. Ordinary GV sources displayed by `metric` also resolve against the active transmitter flight mode.

It is **not** arming state, not the flight controller's mode — Angle, Acro, Horizon, Rescue — and not gyro or stabilisation state. Those live on the aircraft and can only arrive as telemetry, and no panel reads them. That is a gap in the catalogue rather than a decision, and it is recorded here so it can be seen without being noticed as an absence.

A `flight-status` panel is **proposed, not implemented**. The existing display-panel
review pass is now complete, so its earlier prerequisite is satisfied; this
does not make the new panel part of the implemented catalogue. It should show
aircraft-reported armed/disarmed state, flight-controller mode, and optional
gyro/stabilization mode when configured sources actually provide them.
The research is below because it is the expensive part and would otherwise be redone.

Proposed requirements:

- Select sources independently for arming, flight-controller mode, and gyro
  mode; allow only the available fields to be configured.
- Display text sensors verbatim, or use explicit layout-owned mappings for
  numeric values and known text strings. Do not invent a universal FC or
  gyro vocabulary, or infer arming from arbitrary mode names.
- Distinguish receiver-reported state from a transmitter switch command.
  If switch-driven status is supported, label it as commanded state rather
  than claiming the aircraft acknowledged it.
- Keep valid disarmed state distinct from unavailable or stale telemetry.
  Missing or disconnected data must never imply disarmed or gyro-off.
- Use shared responsive text sizing, semantic states, and supporting colors;
  compact spans may show one leading status, larger spans additional fields.
- Remain read-only. Source mappings, setting names, leading-field selection,
  and loss-of-link presentation require design and real receiver examples
  before implementation.

### Text-only and image-only catalogue scope

There is currently **no generic text panel** for arbitrary static text or a
selected text telemetry source. `flight-mode` shows the transmitter's mode
name, and `model-identity` with `presentation: name` shows the current model
name; neither is a general text widget. `metric` remains numeric-only.
The text-sensor capability discussed below is a proposed foundation for
flight status, not shipped functionality.

`model-identity` with `presentation: image` supplies an **image-body panel**
using the current model's assigned bitmap, with the model name still shown
in the header and a name fallback when the bitmap is unavailable. It is not
a generic arbitrary-image panel, nor a completely caption-free image mode.
Generic text and arbitrary/caption-free image panels have no implemented
settings contract yet.

### Proposed panel to-dos

These are backlog items, not implemented features or Phase 1 acceptance claims.

- [ ] Design and implement `flight-status` for configured armed/disarmed,
  flight-controller mode, and gyro/stabilization sources, with explicit
  mappings and honest stale/unavailable states.
- [ ] Design and implement a generic text-only panel for static text or a
  selected text telemetry source, with responsive fitting and optional
  layout-owned state mappings.
- [ ] Design and implement a generic image-only panel for a configured SD-card
  image, including a caption-free presentation, aspect-preserving scaling,
  and an explicit missing-image fallback.
- [ ] Design and implement a glyph-only TX battery presentation for compact
  panels, without numeric voltage and with explicit unavailable-range behavior.

### Aircraft-state telemetry research

**What the radio actually publishes.** This table is the design constraint: the same sensor name carries a different shape on different links.

| Protocol | Flight mode | Arming | Evidence |
| --- | --- | --- | --- |
| Crossfire / ELRS | `FM`, `UNIT_TEXT` | none | `CS(FLIGHT_MODE_ID, 0, STR_SENSOR_FLIGHT_MODE, UNIT_TEXT, 0)`, `telemetry/crossfire.cpp`; frame `0x21`, `telemetry/crossfire.h` |
| Spektrum | `FM`, `UNIT_TEXT` | none | `SS(I2C_PSEUDO_TX, 8, uint32, STR_SENSOR_FLIGHT_MODE, UNIT_TEXT, 0)`, `telemetry/spektrum.cpp` |
| FlySky AFHDS2A | `FM`, `UNIT_RAW` — a mode **index** | `Arm`, `UNIT_RAW` | `telemetry/flysky_ibus.cpp` |
| FrSky S.Port | absent | absent | no entry in `telemetry/frsky_sport.cpp` |

`STR_SENSOR_FLIGHT_MODE` is `"FM"` and `STR_SENSOR_ARM` is `"Arm"` (`telemetry/sensor_names.h`). A text sensor's value is capped at `TELEMETRY_SENSOR_TEXT_LENGTH`, which is 16, and EdgeTX stores a hash of the string in the numeric slot "so changes can be detected quickly" (`telemetry/telemetry_sensors.cpp`). Lua receives the string itself, not the hash: `case UNIT_TEXT: lua_pushstring(L, telemetryItems[...].text)` (`radio/src/lua/api_general.cpp`). `getFieldInfo` reports the unit for a telemetry source, so a panel can tell a text sensor from a numeric one before reading it.

**Arming is not separately published on ELRS.** The only `Arm` sensor EdgeTX defines is FlySky's. Flight controllers are understood to encode arming inside the `FM` string, but **that vocabulary is the flight controller's and is not in the EdgeTX tree**, so a panel that recognised specific mode strings would be designed against a guess. That is the fixture-discipline mistake in a new place, and it is the single most important thing recorded here.

**The proposed text-source foundation.** Display a `UNIT_TEXT` sensor and let
the *layout* map strings to states rather than embedding a universal aircraft
mode vocabulary. For example, an explicit mapping could classify `!ERR` as
critical; this is illustrative, not an implemented YAML setting. The
vocabulary lives where someone who knows their flight controller can state
it, and the panel is honest about what it knows: it shows what the
aircraft sent. A flight-status panel may compose such readings with explicit
numeric arming or gyro mappings.

`metric` cannot absorb this. It formats a number to a precision and normalises it to a range; thresholds, extrema and `fraction` are all meaningless for text, and its ladder sizes the reading from the widest **numeric** form with a unit riding beside it, which a string has no equivalent of. Fitting text into it would make one name cover two panels, which is what the settings vocabulary work undid.

**Groundwork already in place.** The telemetry service maps `UNIT_TEXT` to a `text` kind and holds the string in `raw` with no numeric value. That path existed and had never been exercised by anything, so the test fixture now carries an `FM` text sensor and the service's handling of one is covered, including the common case of the sensor being absent. That is worth having whether or not the panel is ever built.

### The host diagnostics view

Initial dashboard acceptance has been reported on TX16S v2 / EdgeTX 2.12.4. When something looks wrong on hardware, inferring from pixels alone can conceal geometry defects or stale bytecode. The `host-diagnostics` panel exists so a hardware session can answer "what is loaded and what did it resolve to" by reading it instead of deducing it.

It ships as four sections, one per panel, on the `host` dashboard:

| Section | Answers |
| --- | --- |
| `identity` | Widget version, `main.lua`'s size and modification time, **whether a `main.luac` is sitting beside it**, which of the three candidate filenames answered, the full path, and the model name the path was derived from |
| `theme` | The resolved mode, whether the layout or the widget option asked for it, whether a mode that does not exist fell back to Modern, and every notice the theme recorded |
| `panels` | One line per placement: id, type, span, and whether it built, failed later, or was rejected before it built |
| `sources` | One line per telemetry source any panel asked for, spelled as the layout spelled it, and whether it bound |

**It reads the live host context and re-derives nothing.** A diagnostics view that resolved the layout filename a second time, or rebuilt the theme to see what it would say, would be reporting on a world assembled for it rather than the one the dashboard is running, and would be confidently wrong at exactly the moment it is being trusted. That is the same mistake as a fixture that encodes what we assume. Where a fact was not recoverable afterwards, the host now records it where it is decided rather than letting the view guess later, and each of those was a guess the view would otherwise have had to make:

- `layoutStore.read` reports **which** of the three candidate names answered, not only the path it settled on. A dashboard called `main` on a model called `main` produces two candidates that read alike, and a layout quietly falling back to `Default.yaml` looks exactly like one that was found.
- `context.themeSource` records that the widget option chose the theme.
- `theme.build` reports the theme it was **asked** for beside the one it settled on, because a fallback to Modern Dark reports `modern-dark` and is otherwise invisible.
- `context.rejected` holds placements that never built, with the reason. A panel that raises during `create` is discarded and is not in `panels` at all, so before this the view could have reported every panel that works and no panel that does not, which is the wrong half.

**The bytecode line is the one that earns the view.** EdgeTX compiles a `.luac` beside every script it loads and prefers it afterwards, so a radio can run code that is no longer on the card; that is constraint 10 and it cost hours. `make build` deletes the bytecode, but a card assembled any other way will not have. `fstat` reports `{size, attrib, time}` and nothing at all for a file it cannot stat (`luaFstat`, `radio/src/lua/api_filesystem.cpp`), so the view stamps the source and says plainly when a `.luac` is beside it — in which case the timestamp shown is not the code that is executing.

**Reachability.** It is a panel on its own dashboard, reached by paging like everything else. It cannot be a widget setting: in App mode `Widget::openMenu` returns before opening anything, so the settings menu is unreachable from the main view, which is precisely where somebody diagnosing a dashboard is standing.

**Cost.** Nothing when it is not showing, because a panel no layout places is never loaded. When it is showing it builds a fixed number of line objects, so its build cost does not depend on how much there turns out to be to say, and repaints only the lines whose text changed. Sixteen panels of it — the worst the schema permits — peak at 6215 instructions, in the loader's header stage rather than in the panel; the trim-panel build figure cited here predates the fixed three-axis presentation and needs to be regenerated before comparison. It does not become the worst callback.

**Panels shed lines.** A two-cell panel shows about five, so each section is ordered by what someone is there to find: the bytecode alarm above the layout path, failures above the roll call, unbound sources above bound ones, and a count on the first line that says whether anything was shed. A list that pushes the one broken panel off the bottom is worse than no list.

### Text reaches a label only through something that measured it

Four defects shared one shape: a string drawn without being measured. A flight
mode's name sized from a probe rather than the name itself, supporting rows
handed to LVGL at whatever length they came out, a navigation origin the same,
and the panel heading, which went through no fitting at all.

The last was the worst and the least visible. A Lua label is
`lv_label_create` with a font style and nothing else (`etx_label_create`,
`gui/colorlcd/libui/etx_lv_theme.cpp`), so its long mode is LVGL's default,
which `lv_label_constructor` sets to `LV_LABEL_LONG_WRAP`
(`thirdparty/lvgl/src/widgets/lv_label.c`). A height of zero is not zero
either: `LvglSimpleWidgetObject::parseParam` turns it into `LV_SIZE_CONTENT`
(`lua/lua_lvgl_widget.cpp`). So a heading wider than its column wrapped and
grew downward over the reading it labels. `TRANSMITTER` in a single cell's 52
pixel column took three lines and 51 pixels of a 65 pixel panel. Nothing about
the text changed, so no assertion about what a label says could see it.

**Lua cannot choose a different long mode.** `lv_label_set_long_mode` is not
exposed, so clipping and dots are not available. The only levers are the text,
the width and the font.

So `theme.fitHeading` steps the font down first, which costs nothing and keeps
the whole name, and cuts the name only where even the smallest font cannot
carry it -- reporting what was dropped, because a heading is a name the author
chose and losing part of it silently is the `ACRO` against `ACROTRAINER`
problem. Being told is what makes it an abbreviation rather than a corruption.
The column is what the badge leaves, so it is refitted on every reflow rather
than fixed at build.

**Where the string goes decides who can get it wrong.** Every other string in
the dashboard is already measured: the reading by the shared ladder,
supporting rows by `fitLabel`. The heading was the one string the *host*
writes, in `primitives.header`, which is why eleven of twelve panels never
touched it and could not have got it right or wrong. Fixing the host fixed
eleven panels. The two that rewrite their heading at runtime go through
`primitives.setHeading`, and a test forbids writing it directly.

**This is detectable rather than unrepresentable, and that is worth saying.**
The render declaration made its mistake impossible: a panel cannot compare
a field it never declared, because the host derives the comparison. The same
move is not available here, because the host does not own paint -- a panel
holds its own LVGL objects and calls `set` on them. Making this
unrepresentable would mean the host owning drawing as well as deciding, which
is a much larger change than this defect justifies. Detectable is what is
available: the host writes the heading, and a directory-reading test fails on
a panel that writes its own.

**The heading text is held beside the label rather than on it.** The first
version of this stored it and its dropped flag as fields on the label object,
which is a plain table here and userdata on a radio, so every panel failed to
build and the suite noticed nothing. `primitives.header` now appends what it
had to cut to a list the host drains after each panel is built -- a by-product
of the drawing rather than a second opinion assembled beside it -- and
`placeHeader` is handed the text to refit instead of asking the label, because
asking returned nil on a radio and a reflow therefore never refitted. See the
fixture discipline rule about modelling what an object *is*.

### Why `REFLOW_BATCH` is three

**Updated during the cell-battery glyph review:** the batch is now two. Adding
the upright glyph made the three-panel reflow reach the worst loader callback
(both reported 8200 instructions by the suite), violating the requirement that
reflow not be the binding callback. Two panels measured 5600 before the shared
glyph-size extraction, leaving headroom; the enforced comparison remains the
authority. The original measurements and reasoning below are historical.

It was 4, nothing had ever measured it, and it made a reflow the most expensive callback in the dashboard. It is the only per-callback cost the dashboard chooses rather than earns, so it was worth measuring properly rather than assuming a smaller number is better.

Measured at single-instruction resolution on sixteen `trim-panel` panels, the largest layout the schema permits using the most expensive panel to reposition:

| Batch | Worst reflow callback | Callbacks to settle | Total reflow work | Headline worst callback |
| --- | --- | --- | --- | --- |
| 1 | 2280 | 16 | 34641 | 7509 |
| 2 | 4364 | 8 | 34057 | 7509 |
| **3** | **6448** | **6** | **33911** | **7509** |
| 4 | 8532 | 4 | 33765 | 8532 |
| 5 | 10616 | 4 | 33765 | 10616 |
| 6 | 12700 | 3 | 33692 | 12700 |
| 8 | 16868 | 2 | — | exceeds the suite's ceiling |

**The relationship is linear and the per-callback overhead is negligible.** Each step adds exactly 2084 instructions, which is what one `trim-panel` costs to reposition, and the intercept is 196. So a batch of *n* costs `2084n + 196`, and the overhead the schema pays for splitting the work is under a tenth of one panel. Total reflow work is 2.6% higher at a batch of 1 than at 4, which is that overhead paid sixteen times instead of four.

**Three is where the saving stops.** Below it the headline does not move at all, because the binding constraint becomes the loader building one panel at 7509, and no batch size affects that — the panel stage already builds one panel per callback. A batch of 2 or 1 therefore settles a reflow more slowly and buys nothing.

**What it costs is passes.** Sixteen panels settle in six callbacks rather than four. `MainWindow::run` calls `ViewMain::refreshWidgets` once per `MENU_TASK_PERIOD`, which is 50 ms (`radio/src/tasks.cpp:50`), so a full reflow takes about 300 ms rather than 200. A reflow runs only when the host zone moves or resizes — a screen change or a dashboard change — so the extra 100 ms is spent at a moment nobody is reading a value.

**The headroom is the real argument, not the 12%.** Both 8532 and 7509 are comfortable against 20000. But reflow is the only per-callback cost that multiplies one panel's work by a constant, which makes the constant the cheapest protection against a future panel being expensive to move. At 4, a panel costing 3750 instructions to reposition breaches the suite's ceiling; at 3 it takes 4935 to do the same.

The suite asserts the conclusion rather than the number: **a reflow may not be the most expensive callback the dashboard makes.** That comparison fails at a batch of 4 and at 5, which a fixed ceiling chosen today would not have done, and it is paired with an assertion that a reflow was measured at all — without which a zero compares less than everything and the whole check passes having proved nothing. That hole was real and was found by breaking the recording and watching the comparison stay green.

This question is closed. Re-open it only with a measurement.

**Trim-panel measurement status.** The historical trim-specific reflow
measurements above predate the fixed three-axis design. Re-run resource
profiling before using them as current build or reflow costs.

The worst steady frame rose from 2000 to 2400 with milestone 7, on sixteen
`link-status` panels, which is the panel that reads the most per refresh:
two sources, a minimum, and the link view. A panel's declared refresh
interval, not its size, is what decides steady-state cost: `cell-battery`
walks its cells table on every refresh and declares 20 ticks for it, and
`navigation` declares 25 because telemetry GPS never arrives faster. It is
now 2562 on sixteen `navigation` panels; the trim panel's previous
steady-state measurement is no longer a current comparison.

### Panel module contract

A panel file under `panels/<type>.lua` returns a table describing itself:

| Field | Required | Purpose |
| --- | --- | --- |
| `id` | Yes | Must equal the `type` name used in YAML, so a renamed file cannot load silently. |
| `apiVersion` | Yes | Must equal the host panel API version. Anything else is rejected visibly. |
| `create(parent, rect, settings, services)` | Yes | Builds LVGL objects and returns the panel's own context. |
| `supportedSpans` | No | Span strings such as `"2x1"`, or `"any"`. Absent means every span is accepted. |
| `settings` | No | Declared `{key, label, type, default}` entries. Absent and mistyped YAML values fall back to the default. |
| `update(instance, rect, settings)` | No | Applies changed geometry or configuration. |
| `refresh(instance)` | No | Runs once per visible host cycle. |
| `background(instance)` | No | Runs while the dashboard screen is not visible. |
| `event(instance, event)` | No | Returns true when the event is consumed, which stops propagation. |
| `destroy(instance)` | No | Runs before the host tears the panel down. |

The host creates one LVGL container per placement and passes it as `parent`, with a container-local rectangle starting at the origin. A panel therefore cannot draw over a neighbour or reach the dashboard root. Contract fields are read with `rawget`, so a module with a raising `__index` cannot break the host.

Every callback is dispatched under `pcall`. The first failure permanently disables that one panel and reports it, so a broken module cannot repeatedly raise or disable the surrounding dashboard. A panel that fails during `create` has its container cleared, leaving no partial drawing behind.

### Measuring text, against estimating it

`lcd.sizeText(text, flags)` returns the real rendered width. `luaLcdSizeText` calls `getTextWidth`, which is `lv_txt_get_width(s, len, getFont(flags), 0, LV_TEXT_FLAG_EXPAND)` -- a sum of the font's own per-glyph advances. Three properties make it usable from a widget rather than only from a paint: it carries **no `luaLcdAllowed` or `luaLcdBuffer` guard**, alone among the drawing entry points in `api_colorlcd.cpp`, because it touches neither; our size constants **are** the flags it wants, since `SMLSIZE` is `FONT(XS)` and `getFont` indexes on exactly that; and the font it consults is decompressed once and cached by `decompressFont`, so a call is a C loop over the string rather than a decode.

**The estimate is 0.58 of a line height per character, and it is generous only for characters narrower than that.** It was described here as generous by design, which is true of digits and false of capitals: a digit is 0.429 of a line height and a capital `M` is 0.667. So it over-reports a reading and under-reports a name, and a fitting decision made on it shrinks the first and clips the second. Both questions are answered by measurement now. Against the real advances of `lv_font_en_STD.c`, the one font in the tree whose `glyph_dsc` is uncompressed:

| reading | estimated | measured | over by |
| --- | --- | --- | --- |
| `7.9` | 37 | 22 | **+68%** |
| `88.8` | 49 | 31 | +58% |
| `-100` | 49 | 31 | +58% |
| `dBm` | 37 | 33 | +12% |
| `m` | 12 | 14 | **-14%** |

A digit is 0.429 of a line height and a decimal point 0.199, so the error grows with how many points a reading holds rather than how large it is. At XXLSIZE that put `7.9`'s right edge roughly 48 pixels beyond where the radio draws it, which is the gap a user reported between a number and its unit.

**Unit placement is measured. Nothing else is, yet.** Converting the rest is a larger change than it looks, and these are the numbers it turns on.

- **Cost.** Measured through the harness, `theme.textWidth` is 27 instructions and `theme.measureText` is 34 when `lcd.sizeText` costs what it costs on a radio -- **+7 per call**. There are twelve call sites; the hot ones are inside `fitReading`, which walks a ladder of up to five fonts against up to three forms, so a single fitting decision could pay it fifteen times.
- **What it would change.** Across seven panels at every span they declare, **17 of 112 pairs would resolve to a larger font**, every one of them larger and none smaller, which is what removing generosity predicts. `flight-timer` gains a size at nine spans and `navigation` at seven. Those are improvements, but they are visible ones, and they would arrive across the whole catalogue at once.
- **What it would not fix.** The mock cannot reproduce the radio's advances exactly. It models them from `lv_font_en_STD.c`, the one font whose `glyph_dsc` is uncompressed in the tree, and applies that one font's proportions to every size; the bold faces in particular are wider on a radio than in the harness. What that buys is the thing that matters, which is that the harness **disagrees with the estimate** -- `7.9` is 22 pixels there against the estimate's 37 -- so a test can tell a measured placement from an estimated one. A model that merely repeated the estimate could not, and the placement defect that reached a user's screen would have been invisible to the suite either way.

**Correction to a claim that stood here and was wrong.** This section previously said the compressed advances "are not readable from source at all". They are. EdgeTX's `lz4_fonts.h` states that `glyph_dsc` sits at offset zero of the compressed payload, with `uncomp_size` and `glyph_bitmap` declared beside the blob; extracting `lv_font_en_XS`'s array and decompressing it as an LZ4 block against the declared size yields the advance table directly, first attempt, and `adv_w` in sixteenths is the same number `lv_txt_get_width` sums. Building a fixture from that is a morning's work and the result would be exact rather than modelled.

It is not worth doing yet, and the reason is worth stating so nobody does it out of tidiness. The `STD`-derived model is adequate for everything the harness is asked to do, because what the suite must catch is wrong arithmetic rather than the radio predicted to the pixel, and it already distinguishes the two width sources that matter. **The one case it cannot settle is a fit landing within a pixel or two of a font-step boundary**, where the harness and the radio could choose different sizes. That risk is narrow and bounded, and if it ever bites, the door is open and this paragraph is how to walk through it.

**It has now bitten, and the door was not the way through.** `flight-timer` sized against `-88:88:88`, which measures 218 px here against a `2 x 2` content box of 226 -- 8 px of margin, 3.5%, and the bold faces the dashboard draws in are wider than the `STD` model by more than that. So the radio stepped the clock down to `DBLSIZE` and the harness kept `XXLSIZE`, and a user saw a `2 x 2` and a `3 x 2` of identical height disagree while the suite reported them agreeing. Exactly the predicted shape.

The fix was not to make the harness exact. It was to stop the panel needing a fit that fine: the sizing form became `-99:59`, which is 146 px against the same 226 and leaves 55% of headroom before any font model could change the answer. **A fit that the harness cannot settle is a fit that is too tight to be worth having**, whichever way it resolves, because the same margin that defeats the model is the margin a slightly wider glyph or a slightly narrower panel would defeat on a radio. Treat a harness disagreement as evidence about the *design* first and about the fixture second.

The extraction remains available and remains unnecessary. What changed is the estimate of how often it would matter: the one case it cannot settle turned out to be reachable, and turned out not to need it.

The decision is the user's. What is recorded here is that the measurement exists, that it is reachable, and what it costs.

### Instruction budget

EdgeTX aborts any widget callback that exceeds **20000 Lua VM instructions**, raising `CPU limit` (`radio/src/lua/widgets.cpp`). Building a full dashboard costs far more than that, so the host never loads in one call. `create` only loads runtime modules and the root container, then `refresh` advances a staged loader one step per call:

1. `read` — resolve and read the layout file.
2. `tokenize` — convert the text into indentation tokens.
3. `parse` — build the document, validate it, and resolve the theme.
4. `panels` — instantiate exactly one panel, repeated until done.

Every stage is bounded by a fixed amount of work rather than by the size of the layout: the file is tokenized a fixed number of lines per call, and each panel is parsed, validated, and built in its own call. A zone change is batched the same way. A layout that fills the grid therefore costs more callbacks, never a larger callback.

The regression test measures every callback with a 200-instruction count hook, mirroring the firmware, and fails if any exceeds 75% of the budget. It exercises **the largest layout the schema permits**, sixteen single-cell panels, not just the shipped one. Measuring only the shipped layout previously hid a loader that passed on five panels and failed on twelve.

Panel authors must respect the same ceiling: `create`, `update`, `refresh`, `background`, and `event` each run inside the host's callback and share its allowance. Avoid per-character string loops, which are the most common way to exhaust it.

**Anything the harness does to observe must be excluded from what it measures, and a number that moves when only the harness changed is the harness.** This has now caught the instrument charging us for its own work three times: property validation standing in for `parseParam`, which is C++ and free on a radio; the per-object write and visibility counters, which cost 261 instructions of a measured callback while they were branched around rather than swapped out; and sealing every object against field assignment, which a radio's userdata is already and pays nothing to become, and which cost 276 of the worst callback and 126 of the steady frame before it was moved behind the same switch. The last of those was very nearly reported as a regression in the widget. Before attributing a movement to the code, change nothing in the code and see whether it still moves.

Current figures are in **Current cost**, and they are measured with the count hook set to every instruction rather than every 200, because the 200-instruction hook the firmware uses rounds a reading to the nearest 200 and hides exactly the size of change most of this work produces.

Shared data services share the same allowance, and are bounded the same way. The test measures three sixteen-panel layouts: metrics with sixteen distinct live telemetry sources, sixteen diagnostic panels spanning all five services, and sixteen panels demanding a refresh every frame. Each exercise declares which services it must actually run, and the test fails if one of them never updated during the sampled frames, so a layout that quietly subscribed to nothing cannot make the service layer measure zero.

##### Refresh scheduling

EdgeTX refreshes widgets on every main loop pass, so steady-state cost is paid tens of times per second and is shared by every panel on the dashboard. Two mechanisms keep it bounded.

A panel declares `refreshInterval`, in 10ms ticks, stating how often it actually needs servicing. A numeric telemetry readout is indistinguishable at 5 Hz and 50 Hz in flight, so `metric` declares 20 ticks, where the `heartbeat` fixture, which animates, declares 10. Absent or zero means every frame.

Panels that share an interval are then **phase staggered**: each is assigned an offset derived from its position in the layout, so they fall due on different frames instead of all at once. Staggering preserves each panel's exact declared rate, which simple batching would not.

A per-frame dispatch cap is retained as a guarantee for layouts that defeat staggering, such as many panels all asking to refresh every frame. The cap serves panels in rotation so none is starved, and a panel delayed by the cap does not accumulate a backlog of missed deadlines.

### Masking with a container

EdgeTX exposes no masking primitive to Lua, but it does not need to: **a container clips its children to its own rectangle, so a box is a rectangular mask.**

`lv_refr.c`'s `refr_obj` intersects the clip area passed to an object's children with that object's coordinates, and keeps the original area only when the object carries `LV_OBJ_FLAG_OVERFLOW_VISIBLE`. EdgeTX never sets that flag anywhere outside the LVGL submodule, so every child of every `lvgl.box` the dashboard creates is already clipped to it. Where the intersection is empty the children are skipped entirely.

This is what lets the panel accent be drawn as shapes that are deliberately too large and then trimmed, rather than as shapes computed to fit. A quarter-circle band whose outer edge is the panel's own corner curve is easy to state exactly and impossible to express as a rectangle; clipping it to a column one accent width across turns it into the tapering corner the design asks for, without any arithmetic that could drift.

Two limits are worth knowing. The mask is rectangular: `lv_obj_set_style_clip_corner` would clip children to a parent's *rounded* corners, but EdgeTX neither calls it nor exposes it, so a rounded mask is not available. And the container must be resized with whatever it masks, because a stale mask either clips away part of a panel that grew or fails to clip a band on one that shrank.

The container itself paints nothing, which is hard-won constraint 2 read in the dashboard's favour: `LvglWidgetBox::build` creates a bare `lv_obj` and its `setColor` is the base class's empty virtual. A mask that asked for a colour would be relying on that silence, so it asks for none.

### Painting backgrounds

EdgeTX's `lvgl.box` accepts a `color` parameter and silently ignores it: `LvglWidgetBox::build` creates a bare `lv_obj` and, unlike `LvglWidgetBorderedObject`, never applies the color as a background. A box therefore keeps the radio theme's own styling, so a dashboard drawn on boxes renders in EdgeTX's palette rather than its own, and the radio's screen background, including its logo, remains visible behind it.

Every visible surface must be a **filled `lvgl.rectangle`**. Boxes are used only as unpainted containers for grouping and clipping. A regression test asserts that the dashboard canvas and every panel panel background is a filled rectangle, and that no box relies on a `color` parameter.

### Services passed to panels

| Key | Purpose |
| --- | --- |
| `theme` | Resolved theme with `rgb` (24-bit), `color` (display values), and `spacing`. |
| `primitives` | Shared panel, label, value, bar, radial, and badge builders. |
| `fonts` | Typography roles chosen for this panel's span. |
| `span` | The panel's `colSpan` and `rowSpan`. |
| `state(name, accent)` | Resolves a state name into concrete colors, border weight, and badge text. |
| `telemetry` | Cached source readings with units, precision, and freshness. |
| `model` | Model identity, bitmap path, timers, flight mode, and transmitter voltage. |
| `control` | Effective trims and global-variable snapshots; verified GV9 FM0 increments for the flight counter. |
| `extrema` | EdgeTX sensor extrema and dashboard flight sessions. |
| `navigation` | GPS fix, pilot position, distance, and north-up home-to-model bearing. |

Any data service may be absent when its module failed to load, so a panel must tolerate `nil` rather than assume.

### Subscribing to a service

A panel subscribes once, in `create`, and keeps the returned snapshot for its lifetime:

```lua
function example.create(parent, rect, settings, services)
  local telemetry = services.telemetry
  return {feed = telemetry and telemetry:subscribe(settings.source)}
end

function example.refresh(context)
  local feed = context.feed
  if not feed or not feed.available then return end
  -- feed.value, feed.unitText, feed.precision, feed.state, feed.age
end
```

Subscribing in `create` is not a convention, it is the mechanism: a source nothing subscribed to is never read. Two panels naming the same source share one subscription and therefore one poll.

| Service | Subscription | Snapshot highlights |
| --- | --- | --- |
| `telemetry` | `subscribe(name, linkEvidence?)`, `link()` | `value`, `raw`, `kind`, `unit`, `unitText`, `precision`, `state`, `available`, `fresh`, `stale`, `age`; `live`, `rssi`, `indicator` |
| `model` | `identity()`, `timer(index)`, `flightMode()`, `txVoltage()` | `name`/`bitmapPath`; `value`, `countdown`, `elapsed`, `remaining`, `expired`, `text`; `index`/`name`; a telemetry-shaped reading |
| `control` | `trim(name, scale)`, `globalVariable(index, flightMode)` | `raw`, `value`, `fraction`, `scale`, `centered`, `threePosition`; `name`, `value`, `min`, `max`, `precision`, `unitText`, `flightMode` |
| `extrema` | `sourceExtreme(name, mode)`, `sessionExtrema(name)`, `flight(armSource)` | an ordinary reading of `<name>-`/`<name>+`; `min`, `max`, `samples`, `session`; `armed`, `active`, `count`, `duration` |
| `navigation` | `subscribe(name)` | `fix`, `home`, `latitude`, `longitude`, `pilotLatitude`, `pilotLongitude`, `distance`, `distanceUnit`, `bearing`, `age` |

Every snapshot is a read-only view over state the service mutates in place. Writing to one raises, and the metatable is hidden so the mutable state stays unreachable.

### Freshness and degradation

Freshness is the subtlest part of EdgeTX telemetry. `getValue` returns integer zero for a telemetry source both when the sensor genuinely reads zero and when telemetry is not streaming, and the Lua API exposes no per-sensor age except for GPS, which carries a `delay` field.

Only a zero is ambiguous, so `telemetryService` judges only a zero:

- A non-zero value is always stored, whatever the link indicator says, because EdgeTX returns exactly zero when it has nothing.
- A zero is stored only while the link is believed up. Otherwise the last live value is kept and classified `stale`.
- The link indicator is `getRSSI() > 0`, the only liveness signal the Lua API offers. It is not universally reliable: a protocol that never populates an RSSI sensor reads zero on a live link. A telemetry source returning a non-zero value while the indicator says otherwise proves the indicator wrong, so the service learns that once and stops trusting it.
- A source the radio does not recognize is `unavailable`, and resolution is retried periodically, because a sensor only appears once telemetry has delivered it.
- Precision comes from the model's sensor table, searched by name a bounded number of entries per update.
- A sensor's extremes, `<name>-` and `<name>+`, report the base sensor's unit but not always its value shape. `Cels-` and `Cels+` return a plain number where `Cels` returns a table, and the service normalizes that.

Two limitations remain, and neither is solvable from Lua:

- Staleness is link-wide, not per sensor. A single sensor that stops arriving while the link stays up still reads as live.
- A sensor that is configured but has never been received reads as a valid zero while the link is up, because EdgeTX exposes no per-sensor availability.

Closing either needs a per-sensor age from the firmware, or a heuristic this specification is not willing to guess at.

Every service degrades the same way. A missing firmware API, an out-of-range timer index, a radio without global variables, a GPS source that has never produced a position, and a source name that is simply wrong all produce an `unavailable` snapshot rather than an error, and no service raises inside a widget callback. A service whose update does raise is reported once and then retired.

### Theme resolution

Every named theme is a complete mapping in its own `.yml` file, which supplies the
palette tokens, spacing, default accent, and optional alert-tint preferences.
The widget reads shipped and user themes with the shared YAML parser and offers
them in the native Theme setting. An append-only registry preserves the stored
choice positions, and a user file takes precedence over a shipped file with the
same name. Themes enable contrast correction by default; a theme can disable it
to preserve deliberately specified values. The layout schema rejects legacy
layout-level `theme` blocks; theme selection belongs to the widget setting, not
individual layout files. The dashboard never calls `lcd.setColor()`.

### Phase 1: YAML-configured dashboard

Phase 1 reads externally authored YAML and never creates, edits, migrates, or rewrites layout files on the radio.

#### Milestone 1: Runtime skeleton

- Register one LVGL dashboard host widget with a native Dashboard ID option.
- Implement grid rectangle calculation and nested LVGL panel containers.
- Render a hard-coded 4 x 4 arrangement of labeled placeholder panels.
- Respond correctly when the host zone changes.
- Verify App mode as the primary deployment and ordinary `1 x 1` as the fallback.

Deliverable: a runnable dashboard whose placeholder panels occupy stable configured spans.

#### Milestone 2: Read-only YAML loader

- Implement the constrained schema-versioned YAML parser.
- Resolve `<model-identifier>--<dashboard-id>.yaml` and fall back to `Default.yaml`.
- Validate panel IDs, safe type names, coordinates, spans, overlap, and supported schema version.
- Preserve unknown keys in memory for forward compatibility.
- Render visible placeholders for invalid entries without preventing valid entries from loading.
- Keep all layout file access read-only.

Deliverable: changing YAML rearranges the complete dashboard without changing Lua code.

This is the first architecture checkpoint. Further panel work should not begin until two separately loaded placeholder panels render from YAML in both App mode and `1 x 1`.

#### Milestone 3: Panel runtime

- Load only referenced panel modules with `loadScript()`.
- Finalize panel metadata, API version, lifecycle callbacks, settings schema, and supported-span declarations.
- Support bundled modules and compatible user-copied modules under `panels/`.
- Reject incompatible API versions and unsafe module names visibly.
- Isolate panel creation and refresh failures so one panel cannot disable the dashboard.

Deliverable: independently authored panel files run together under a stable host contract.

#### Milestone 4: Design system

- Implement semantic theme tokens and shared panel, typography, spacing, bar, radial, and state primitives.
- Implement complete YAML-defined themes with contrast protection.
- Implement normal, stale, unavailable, warning, critical, and selected states.
- Establish responsive presentations for `1 x 1`, `2 x 1`, and `2 x 2` spans before expanding to unusual spans.
- Verify physical readability at 480 x 272 on a TX16S-class display.

Deliverable: one polished metric panel demonstrating every state, named theme, and baseline span.

#### Milestone 5: Shared data services

- Implement `telemetryService` for cached values, units, precision, and freshness.
- Implement `modelService` for identity, bitmap, timers, flight mode, and transmitter voltage.
- Implement `controlService` for effective trims and read-only global variables.
- Implement `extremaService` for EdgeTX extrema and arm-switch flight sessions.
- Implement `navigationService` for GPS fix, pilot position, distance, and north-up home-to-model bearing.
- Update each service once per host cycle and expose immutable snapshots to panels.

Deliverable: diagnostic views prove normalized service output independently of final panel rendering.

Delivered. The `service-probe` panel renders any service's normalized output as label and value rows, and two layouts ship: `services.yaml` for telemetry and navigation, `services2.yaml` for model, control, and extrema. Both load from their Dashboard ID alone, on any model.

The cadence is deliberate rather than "once per host cycle" literally. Polling five services on every cycle was measured and rejected: at most one service is updated per cycle, services are phase staggered on registration, a service nothing subscribed to is never scheduled, and each service caps how many subscriptions it refreshes in one update. A panel still sees one consistent set of readings per cycle, because services update before panel refreshes.

#### Milestone 6: Core panels

Implement these panels in order:

1. `metric`
2. `flight-timer`
3. `flight-mode`
4. `tx-battery`
5. `trim-panel`
6. `model-identity`

This order establishes value formatting, source access (including ordinary GV sources), model APIs, bars, radial indicators, trim semantics, and bitmap handling before the more protocol-sensitive panels.

Deliverable: six responsive core panels operating from YAML configuration.

Delivered. All six ship, driven by YAML and shared services, and the shipped `layouts/Default.yaml` demonstrates all of them. Global-variable readings use `metric` through ordinary EdgeTX sources.

Three shared additions came out of the work rather than being planned:

- `theme.frame` resolves the padded content geometry, header row, and badge column that every panel shares, so a badge cannot land on the label it accompanies and two panels cannot disagree about where a header sits. Widening a narrow panel's badge past half its content width was a real defect this found.
- `theme.textWidth` and `theme.fitText` fit a reading by measured width as well as height. This closes milestone 6's carried-forward item about a `1 x 1` metric whose value was only checked vertically.
- `primitives.bipolarBar`, an optional centre marker on `primitives.bar`, and `primitives.image` cover the three shapes the new panels needed and the earlier catalog did not.

Milestone 7 added two more, both about arcs:

- `primitives.compass` draws a north-up home-to-model bearing dial with a continuous outer ring, inward ticks, inset N/E/S/W, and a green filled concave pointer. Two triangles form the pointer and are hidden when bearing is unavailable. The pointer's maximum radius reserves clearance from all cardinal labels at every bearing. Explicit compass/detailed presentations reserve space for the dial; auto retains distance-first shedding.
- `primitives.arcBounds` was added here to convert an arc's centre into the rectangle it occupies. It has since been deleted: no panel ever called it, its only callers were tests, and it was wrong — it put the outer edge half a stroke too far out, which nothing noticed because the only thing checking it repeated its arithmetic. The tests now measure the arc the mock actually drew.

Model bitmaps cannot use `Bitmap.open()` under LVGL; this implementation detail is recorded in the model identity requirements.

#### Milestone 7: Telemetry-specialized panels

Implement these panels in order:

1. `cell-battery`
2. `link-status`
3. `navigation`

- Validate cells-table and GPS-table value shapes.
- Handle protocol-dependent RSSI and link-quality source selection.
- Test telemetry disconnect, reconnect, stale data, missing GPS fix, and unavailable home position.

Deliverable: the full ten-panel catalog with graceful telemetry degradation.

Delivered. All three ship, and `layouts/Default.yaml` now demonstrates the
complete ten-panel catalogue on one screen.

Value shapes are validated rather than assumed. `cellBattery.summarize`
classifies what EdgeTX actually returned as `none`, `number`, `empty`,
`invalid`, or `cells`, rejecting entries that are not plausible cell voltages
and bounding its walk, because the table comes from the firmware and the walk
is charged to the widget's instruction budget. A `number` shape means the
layout named `Cels-` or an ordinary voltage sensor as its cells source, which
is a configuration mistake rather than a failed link, so it reads
`NOT CELLS` rather than `NO SOURCE`. GPS tables are validated by
`navigationService`, which already refuses a null-island position, and
`navigation` reports no source, no fix, and no home position as three
different states because each has a different cause and a different fix.

Protocol-dependent source selection is a panel setting, not a heuristic.
`link-status` takes independent RSSI and link-quality source names, never
infers one from the other, and its `auto` primary reading prefers quality
because a percentage means the same thing on every protocol where RSSI does
not. An explicitly chosen primary is never overridden, however bad that source
looks, so a dBm antenna reading can be the headline where a layout says so.

The three situations that all look like a zero are now separated by the
telemetry service rather than guessed at again. `telemetryService:link()`
publishes `live`, `rssi`, and `indicator`, where `indicator` goes false once a
source has returned a non-zero value while `getRSSI()` read zero. A dead link
is reported as `critical` with a `NO LINK` badge, because on this panel a dead
link is the measurement rather than merely stale data; a protocol with no RSSI
sensor keeps the quality reading, stays out of alarm, and says
`NO RSSI SENSOR`; and a genuine zero on a live link is shown as a reading.

One specification detail was corrected by the implementation: `lvgl.arc` is
positioned by its centre, which invalidated every radial milestone 6 shipped.
It is recorded under the hard-won constraints.

#### Milestone 8: The App mode menu button and multiple screens

- Lay panels out around the EdgeTX App mode menu button described below.
- Verify separate Dashboard IDs for multiple screens on one model.
- Verify model switching reloads the correct layout and that each instance remains one page.

Deliverable: multiple independent, model-scoped dashboards, none of which hides a reading behind the radio's own furniture.

The status rail this milestone originally carried is deferred. See [Why there is no status rail](#why-there-is-no-status-rail).

##### Reserved App mode menu button

In App mode EdgeTX always draws its own menu button over the top-left corner of the screen. `ViewMain::updateTopbarVisibility` sets `setEdgeTxButtonVisible(hasTopbar(view) || isAppMode(view))`, and the button opens the quick menu, so in App mode it is the only route to the radio's menus and must not be hidden.

Four firmware facts fix where it is, and all four are load bearing:

- **It is drawn above the widget, deliberately.** `ViewMain`'s constructor creates the tile view and then the top bar, with the comment `// create last to be on top`. The button is a `HeaderIcon` parented to `ViewMain`, not to the top bar, so hiding the bar in App mode leaves the button. Anything the dashboard draws underneath it is painted over.
- **Only App mode overlaps.** `ViewMainDecoration::getWidgetsZone` starts the widget zone at `MENU_HEADER_HEIGHT` and takes the same amount off its height whenever a top bar is shown, so an ordinary Full screen layout sits below the button. A layout with no top bar hides the button altogether. The `1 x 1` fallback therefore needs nothing.
- **A widget's `zone.x` and `zone.y` are always zero.** `lua_widget_factory.cpp` pushes them as zero and carries the real screen position in `xabs` and `yabs`, which `updateZoneRect` keeps current. The overlap is whatever of the button reaches into the zone, so it is computed rather than assumed.
- **`MENU_HEADER_HEIGHT` is published to Lua, but shifted.** `api_general.cpp` registers it beside the colour constants, so it passes through `COLOR2FLAGS` and arrives shifted left by sixteen bits: the global reads 2949120 on a TX16S, not 45. Unshifted it is correct on every display class, because the firmware scales the real constant. The width kept clear is `MENU_HEADER_BUTTONS_LEFT`, which is not published; the firmware's own values at 320, 480 and 800 pixels are reproduced exactly by rounding `height * 47 / 45`.

The button is 47 x 45 at 480 x 272. Measured against the 4 x 4 grid, it covers 40% of the width and 69% of the height of a top-left `1 x 1` cell, 20% and 34% of a `2 x 2`, and 10% and 17% of the whole screen.

The damage was worse than the label row this specification originally anticipated. On the shipped dashboard the `navigation` panel's compass takes the right of the panel, which left `theme.fitText` choosing `SMLSIZE` for the distance, so `778m` was drawn 39 x 17 at (8, 25) and vanished completely. Nothing failed and nothing was reported. A layout author cannot predict that, because it depends on which font was chosen at which span, so it cannot be left to a documented convention.

Three approaches were measured before choosing:

| Approach | Cost at `2 x 2` | Cost at `1 x 1` | Other |
| --- | --- | --- | --- |
| Reserve a full-width strip | 45 px of 272 for the whole dashboard | same | Gives up the entire area beside the button to clear something 47 px wide |
| Inset the top-left container | 47 px of 238, a fifth of its width | 117 px falls to 70 | Leaves a notch where the cell no longer lines up with the column beneath it |
| Reserve inside `theme.frame` | 20 px of 134, on that panel only | reading survives, label is dropped | No notch; every other cell is unchanged |

`theme.frame` owns the padded content geometry, header row, and badge column for all eleven catalogue panels. Giving it the obstructed corner fixes every panel in one place. The header moves to the right of the button without changing the grid geometry.
For one-row spans (`1x1`, `2x1`, `3x1`, `4x1`), the shared frame reserves width
on the left instead of raising the content start. Taller panels continue to
start content below the obstruction. This keeps a short panel's reading
vertically centred while all readable content stays clear of the menu button.
An ungrouped primary first tries its ordinary centered sizing envelope, including
the unit, against the icon. A clear envelope keeps its ordinary font and centre;
the header and supporting content retain left clearance independently. Slotted
visuals and side stacks remain conservatively inset as a group. Metric samples
are not hard value bounds: out-of-envelope live text is prevented from extending
left into the icon, without changing the sample-based font on each value update.

The corner reaches the frame through the theme builder each panel is handed, rather than through a new argument on every panel, so a panel written by someone else is laid out correctly without knowing any of this exists. It is read on each call rather than captured, so a zone that moves is picked up by the update that follows it.

The reading gets larger rather than smaller. With the dial shrunk to suit the reduced height, the shipped dashboard's distance is chosen at `MIDSIZE` where it was previously `SMLSIZE`.

A `1 x 1` cell in that corner has limited width after the left reservation.
Its heading and optional content may be dropped; the reading is fitted within
the remaining width rather than pushed below the button.

The error overlay was subject to the same problem and was fixed first. It was drawn at (8, 8), so in App mode a panel could fail, the host could report it, and the radio would show nothing.

##### Why there is no status rail

This milestone originally specified a dashboard-owned status rail carrying model name, flight mode, transmitter voltage, link state, clock and active timer. It is deferred, not cancelled, and the reasoning is recorded here so it is not re-litigated from scratch.

EdgeTX's own top bar is already a configurable widget rail. `TopBar` is a `WidgetsContainer` over `{0, 0, LCD_W, MENU_HEADER_HEIGHT}` with per-model configurable zone widths, it accepts any widget, and `TopBar::getZone` already starts its zones at `MENU_HEADER_BUTTONS_LEFT + 1`, reserving the menu-button corner exactly as a dashboard rail would have to. It is C++, so it costs nothing against the 20000-instruction Lua callback budget, whereas a dashboard rail would spend from the same allowance as the grid.

The arithmetic then settles it. A full-width rail in App mode leaves the grid `272 - 45 = 227` px. The ordinary Full screen layout with EdgeTX's top bar leaves the widget zone `272 - 45 = 227` px as well, by `ViewMainDecoration::getWidgetsZone`, and Full screen can also show flight mode, sliders and trims, which reduce it further. So a dashboard rail in App mode is at best a tie on grid area against simply inserting AeroGrid as a Full screen widget, and it buys a less capable status bar for a share of the instruction budget. AeroGrid already works inserted either way.

Note that an earlier comparison used 232 px for the Full screen zone. That number appears nowhere in the firmware; it came from a test fixture. The correct figure is 227.

If the rail is revisited, the arguments for it are that App mode has no top bar at all, that a dashboard rail would follow AeroGrid's theme rather than the radio's, that it would share the telemetry service instead of polling a second time, and that it could show dashboard state such as which layout is loaded or which service has gone stale. None of those outweighed the geometry.

The visibility policy is settled even though the feature is not built: **the rail defaults to off when a layout says nothing about it.** Not automatic, not on. A layout must opt in. Off by default means the rail can never silently take 45 px from a dashboard or force a reflow its author did not ask for, and every layout that exists today keeps its geometry unchanged if the rail ever arrives. Choosing the default automatically, from whether EdgeTX gave the widget a top bar, was considered and rejected: it makes a layout's geometry depend on which EdgeTX layout it happens to be inserted into, which is exactly the invisible coupling that is painful to debug on a radio.

#### Milestone 9: Phase 1 hardening

- Test corrupt, missing, and future-version YAML files. Covered through the
  staged host loader in `tests/integration/test_widget.lua`, including empty
  files, visible errors, and stable refresh after rejection.
- Test missing, incompatible, and failing panel modules. Host integration
  coverage includes syntax errors, module-execution errors, non-table returns,
  API and ID mismatches, unsupported spans, and missing files. A valid panel
  continues running alongside rejected modules; callback failure isolation is
  also covered.
- Test package and panel API compatibility. Host integration covers missing
  and malformed package identity, future runtime/panel/layout contracts,
  missing or unversioned core modules, incompatible core/service modules, and
  panel-host API mismatch. Diagnostics reads the package version from the
  live host rather than maintaining a separate version constant.
- Add a diagnostics view for versions, layout path, panels, unresolved sources, and failures. Delivered as `host-diagnostics`; see [The host diagnostics view](#the-host-diagnostics-view).
- Validate on TX16S v2, TX16S v3, TX15, and GX15 with EdgeTX 2.12+.
- Measure instruction use, Lua and bitmap memory, LVGL object count, and refresh cost.
- Automated resource stability now covers repeated switching across six
  dashboards, three zone sizes, retired-page/service collection, live mock object
  counts, post-GC Lua memory growth, and informational desktop refresh timing.
  Native LVGL and decoded bitmap memory still require simulator/radio evidence.
- Establish release budgets from simulator and physical-radio baselines.

The mocked instruction baseline remains 13600 of 20000 instructions for the
worst loading callback, 6000 for steady refresh, and 9800 for reflow. The suite
enforces a 15000-instruction ceiling, leaving at least 25% headroom below the
firmware limit. This is not a physical-radio memory or timing baseline and does
not complete the hardware or release-budget requirements.

Deliverable: a read-only YAML-configured phase 1 release suitable for normal radio use.

### Phase 2: On-radio editor

#### Milestone 10: On-radio editor

- Display the editing grid and selection state in temporary fullscreen mode.
- Add, move, resize, configure, and remove panels.
- Generate per-panel settings forms from typed schemas.
- Implement source, switch, number, boolean, choice, color, string, timer, and file controls.
- Add Apply, Cancel, defaults, validation feedback, and recovery workflows.
- Implement validated temporary-file saves, backups, schema migration, and interrupted-save recovery.
- Support touch and rotary/key navigation according to the remaining phase 2 input decision.
- Add selected/editing state refinements and explicit diagnostic export.

Deliverable: layouts created and safely maintained entirely on the radio.

## Acceptance Criteria

- A user can run AeroGrid in a single `1 x 1` or App mode zone.
- The dashboard displays at least two independently implemented Lua panel files.
- A panel can be placed at any valid 4 x 4 grid coordinate.
- A panel can span multiple rows and columns.
- Overlapping and out-of-bounds placements cannot be saved.
- Phase 1 loads complete dashboards from read-only YAML without requiring an on-radio editor.
- Separate Dashboard IDs load separate screens for the same model without internal paging.
- Phase 2 supports adding, moving, resizing, configuring, and removing panels.
- Panel settings forms are generated from panel metadata rather than hard-coded in the host.
- A source setting can select an EdgeTX telemetry/input source, persist its name, and read its live value after reload, including after the sensors have been rediscovered in a different order.
- Telemetry panels distinguish current, stale, unavailable, and valid zero values.
- Altitude and speed displays use the shared metric panel with explicitly configured labels and supporting values.
- Navigation shows a north-up direction from home to model and never presents it as aircraft-relative orientation.
- Flight extrema follow the configured manual, timer, or switch reset policy.
- The dashboard offers Modern Dark, Modern Light, and user-defined YAML themes without changing global EdgeTX colors.
- Trim panels display effective trim positions inside the grid without replacing or modifying EdgeTX trim controls.
- The metric panel displays ordinary global-variable sources for the active flight mode, with explicitly configured label, precision, unit, and visualization range.
- Bar and radial indicators remain geometrically stable at minimum, maximum, zero, and out-of-range values.
- Invalid panel configuration cannot be applied or persisted.
- In phase 2, Apply writes a valid per-model and per-Dashboard-ID YAML layout to the SD card.
- In phase 2, Cancel leaves both the active and persisted layout unchanged.
- The dashboard recovers from an invalid primary layout using backup or default data.
- One missing or failing panel does not prevent other panels from running.
- Layouts render without gaps caused by grid rounding.
- Panels work in both App mode and the ordinary Full screen layout, subject to available decorations and interaction state.
- The 480 x 272 dashboard follows the defined visual hierarchy and remains legible on physical hardware.
- Dynamic values and state changes do not resize panels or shift neighboring content.
- Panels use host theme tokens and provide valid presentations for every span they advertise.
- Incompatible panels and future layout versions fail visibly without corrupting the saved layout.
- Diagnostics identify missing sources and panel failures without requiring continuous SD-card writes.

## Open Decisions

- Whether collision handling rejects, swaps, or automatically relocates panels.
- Whether phase 2 editing supports rotary/keys from its first release or initially targets touch input.
- Exact automatic source defaults and name-recovery behavior for each RF protocol.
- Whether flight-session statistics need optional persistence or export.
- Whether status-rail item ordering is configurable in the first release.
- Which default YAML dashboard examples ship for aircraft, helicopter, and long-range use.
- Phase 2 collision and resize-anchor behavior.
- Numeric performance budgets after simulator and physical-radio baselining.
- Whether the three development panels ship in a release.
