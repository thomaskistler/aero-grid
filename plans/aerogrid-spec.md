# AeroGrid Project Specification

## Status

- Draft specification
- Date: 2026-09-07
- Status last updated: 2026-09-18
- EdgeTX source: `../edgetx`
- Project root: `aero-grid/`
- Implementation: Phase 1, milestones 1 to 8 complete, plus a presentation and consistency pass over the whole catalogue
- Next work: Milestone 9, hardening, and hardware verification. Nothing in this project has run on a radio.
- Everything is merged into `main`; there is no branch in flight. See [Resuming work](#resuming-work) for the state and the exact next steps.

## Summary

Build a modern EdgeTX dashboard as one Lua widget running in the built-in `1 x 1` or App mode layout. The dashboard divides its available area into a logical 4 x 4 grid and hosts rewritten widget-like Lua components. Each component occupies a configurable rectangular set of contiguous grid cells.

EdgeTX does not support nesting independently registered widgets inside one layout zone. Components therefore run under one dashboard host widget rather than as native child widgets. The host loads each component from its own Lua file, creates its LVGL parent container, dispatches lifecycle calls, and persists the component arrangement in a YAML file on the SD card.

## Goals

- Provide a logical 4 x 4 dashboard grid.
- Place a component at any grid column and row.
- Allow rectangular component sizes from 1 x 1 through 4 x 4.
- Load each component implementation from a separate Lua script.
- Use LVGL parent containers for component containment and clipping.
- Provide an on-radio UI for adding, moving, resizing, configuring, and removing components.
- Persist layouts per model in human-readable YAML.
- Run without modifying EdgeTX firmware for the first implementation.
- Support App mode for an application-like, decoration-free experience.
- Support multiple independent AeroGrid instances for one model.

## Non-Goals

- Nest existing independently registered EdgeTX widget factories.
- Make unmodified third-party widgets run as dashboard components.
- Add a native dynamic layout to EdgeTX firmware in the first implementation.
- Support non-rectangular or overlapping component regions.
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

The widget can detect this layout through `lvgl.isAppMode()`. Activating the widget enters temporary widget fullscreen mode directly rather than opening the normal widget menu.

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
    ├── Component registry/loader
    ├── Lifecycle and event dispatcher
    ├── Dashboard editor
    └── LVGL component containers
      ├── Cell battery component
      ├── Metric component
      ├── Flight timer component
      └── Other catalog components
```

Only the dashboard host is registered as an EdgeTX widget. Dashboard components are ordinary Lua modules loaded and managed by the host.

### Bundled EdgeTX widget baseline

The bundled color-screen widgets are intentionally generic: Value, Gauge, Timer, Model Bitmap, Outputs, Text, Radio Info, Date/Time, and Internal GPS. AeroGrid should reuse their source selection and model APIs, but replace their presentation with a smaller set of responsive, domain-aware components.

### Component catalog

The initial release should provide these components:

| Component | Purpose | Classification |
| --- | --- | --- |
| `cell-battery` | Minimum cell voltage, horizontal usable-capacity bar, optional pack voltage and cell count | Specialized |
| `metric` | Current value, optional minimum/maximum, and optional secondary value | Generic with domain presets |
| `flight-timer` | EdgeTX model timer with count-up or count-down presentation | Specialized |
| `link-status` | RSSI, link quality, optional minimum quality, and link freshness | Specialized |
| `navigation` | GPS position, bearing from home to model, distance to home, and GPS state | Specialized and responsive |
| `flight-mode` | Current EdgeTX flight-mode name | Simple |
| `model-identity` | Model bitmap, model name, or both | Specialized |
| `tx-battery` | Transmitter voltage and optional battery indication | Simple; primarily intended for the status rail |
| `trim-panel` | One or more effective trim positions in a centered dashboard panel | Specialized |
| `variable-indicator` | Global variable or bounded numeric source as a value, bar, or radial indicator | Generic |
| `service-probe` | The live state of one shared service, for diagnosis on the radio | Diagnostic |
| `host-diagnostics` | What the host loaded and what it resolved to, in one section per panel | Diagnostic |

Twelve components ship, two of them diagnostic. Two more, `heartbeat` and `placeholder`, live under `tests/fixtures/components`: they were written to prove the host contract — that a component loads, refreshes, reflows and is torn down correctly — and never to be flown. They are copied into every scratch widget package the suite builds, so that coverage keeps running, but a release does not carry a panel whose purpose is to animate a dot. `service-probe` is the exception among the three and ships, because it is the only thing that can inspect a service on a radio. It reports what a service says; `host-diagnostics` reports what the host loaded, which is the other half and is described under [The host diagnostics view](#the-host-diagnostics-view).

The `metric` component provides built-in presets without creating separate implementations:

- `altitude`: current altitude, maximum altitude, and optional vertical speed.
- `speed`: current speed and maximum speed.
- `custom`: user-selected primary, extrema, and secondary sources.

Presets establish labels, semantic accents, likely source defaults, and supported presentations. Every source remains user-selectable so the dashboard does not depend on protocol-specific sensor names.

A preset cannot be expressed as a settings default, because the host fills declared defaults in before the component runs and a filled default is indistinguishable from a value the layout stated. Preset-overridable keys therefore declare an empty or absent default, and the component applies the preset to any key the layout left empty. Anything the layout states always wins.

### Component requirements

#### Cell battery

- Accept an EdgeTX cells source. A cells source may return a table of individual voltages.
- Use the lowest valid cell voltage as the primary safety reading by default.
- Scale the horizontal bar over the configured usable range from critical to full, not from zero volts.
- Support warning, critical, stale, and unavailable states.
- Optionally show cell count and summed pack voltage.
- Do not estimate remaining battery percentage unless a future component explicitly defines and labels its estimation model.
- Validate the table rather than trusting it. Entries that are not plausible cell voltages are rejected instead of folded into a lowest or an average, the walk is bounded because the table comes from the firmware, and a value that is not a table at all is reported as a configuration mistake rather than as a missing source.
- Judge the thresholds on the worst cell even when the panel shows the pack sum, because a sum is exactly what hides one sagging cell.
- Allow an explicitly configured lowest-cell source, such as `Cels-`, to win for that reading. The receiver maintaining it has seen samples between the dashboard's polls, and it keeps the component useful when the table itself is unreadable.

#### Metric

- Accept a primary source, optional extrema source, and optional secondary source.
- Preserve EdgeTX source units by default and support an explicit display-unit override where conversion is reliable.
- Allow extrema mode `source`, `flight`, or `none`, defaulting to `source`.
- In `source` mode, read an explicitly selected EdgeTX minimum or maximum source.
- In `flight` mode, use the shared flight-session extrema service.
- Altitude may show vertical speed only when a configured source is valid. Derived vertical speed is deferred until filtering and sampling behavior are defined.

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

#### Navigation

- Accept a GPS source and an optional native distance source.
- Use current and pilot coordinates returned by an EdgeTX GPS source to calculate distance and the initial bearing from the home/pilot position toward the model.
- Prefer an explicitly selected native distance source when configured.
- Render direction as an absolute north-up bearing or compass arrow from home to model. Aircraft heading and transmitter orientation are not required and must not rotate this arrow.
- Provide responsive modes: compact distance, distance and bearing, north-up compass/bearing arrow, and detailed navigation with coordinates.
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
- Support name-only, image-only, and combined presentations subject to component span. An automatic choice must not spend space on a picture that a single cell cannot show.

#### Transmitter battery

- Read the EdgeTX transmitter-voltage source.
- Show voltage as the authoritative value.
- Treat any percentage or battery-fill estimate as optional and configurable because battery chemistry and voltage range vary by radio.

#### Trim panel

- Present trims inside a normal grid component rather than along the display edges.
- Offer `single`, `pair`, and `all` under `indicators` so a compact panel may show one trim while a larger panel may show the primary four.
- Use a centered bipolar bar with a persistent neutral marker, signed displacement, and optional percentage or raw value.
- Support horizontal and vertical orientations, with a per-indicator override when automatic axis metadata is unavailable.
- Read effective current-flight-mode values through selectable EdgeTX trim sources so EdgeTX resolves trim inheritance.
- Persist the selected trim source for each indicator rather than assuming fixed trim names or stick-mode mappings.
- Remain read-only in the initial release; changing trims remains the responsibility of EdgeTX trim controls.
- Support `standard`, `extended`, and `auto` display scales. Auto may expand after observing a value outside the standard range, but cannot reliably detect the model's extended-trim setting because EdgeTX does not expose that flag to Lua. A trim source returns eight times the stored trim, and EdgeTX clamps that to `TRIM_MAX` or `TRIM_EXTENDED_MAX`, so the raw spans are 1024 and 4096, not 1000 and 4000. Rounding those down makes a standard trim held at its own end stop widen the scale permanently.
- Clearly represent centered, positive, negative, unavailable, and unsupported three-position trim states. A three-position trim returns full deflection or nothing, which is exactly what a standard trim at its end stop returns, so one sample can never distinguish them. `controlService` claims a toggle only after seeing both a centre and a full deflection with no intermediate position between them.

#### Variable indicator

- Bind to either an EdgeTX global-variable index or a numeric EdgeTX source.
- For a global variable, read the value for the current or explicitly selected flight mode with `model.getGlobalVariable(index, flightMode)`. `controlService:globalVariable(index, flightMode)` pins a mode when one is given and follows the active mode otherwise; a pinned mode is its own subscription, because two components may legitimately show the same variable for different modes.
- Use `model.getGlobalVariableDetails(index)` where available to obtain the configured name, minimum, maximum, precision, and unit.
- Rely on EdgeTX to resolve global-variable flight-mode inheritance.
- Offer `none`, `bar`, `bipolar-bar`, and `radial` under `visual`. These are drawings of one value, not arrangements of different content, which is why they are not `presentation`.
- Normalize bar and radial geometry using GV bounds or explicit source bounds; clamp only the drawing, not the displayed value.
- Show a center marker when the configured range crosses zero.
- Remain read-only. AeroGrid does not modify global variables.
- Allow semantic labels such as Flight count, Expo, Rates, Gain, or Volume while retaining the configured GV name as optional supporting text.

A flight counter that already exists in a global variable is displayed by `variable-indicator`. AeroGrid does not detect or increment flights and does not own flight-counter persistence.

### Status rail

Deferred. EdgeTX's own top bar already provides a configurable widget rail that reserves the same corner and costs no Lua instruction budget, and a dashboard-owned rail in App mode leaves no more grid area than inserting AeroGrid as an ordinary Full screen widget. The full reasoning, and the settled default should it be revisited, is under [Why there is no status rail](#why-there-is-no-status-rail).

Were it built, the optional dashboard-owned rail would carry model name, flight mode, transmitter voltage, link state, clock, and active timer items, reusing the same shared services as grid components rather than polling again. Enabling it would reduce the rectangle available to the 4 x 4 grid and must trigger a complete grid geometry update.

### Shared services

The host provides shared services so components do not duplicate polling, conversion, or tracking logic:

- `telemetryService`: source lookup, cached values, units, freshness, and stale/unavailable classification.
- `extremaService`: source, session, and flight minimum/maximum tracking.
- `navigationService`: GPS fix, pilot/home coordinates, distance, and absolute bearing from home to model.
- `modelService`: model identity, bitmap path, model timers, flight mode, and transmitter voltage.
- `controlService`: current flight mode, resolved trim-source values, global-variable values, bounds, precision, and units.
- `themeService`: resolved semantic colors, contrast correction, and state precedence.

Two rules keep that affordable, because every service update is charged to the same per-callback instruction budget as component refreshes:

- A service only reads what a loaded component subscribed to. A service nothing references is skipped entirely, so a dashboard of metrics never pays for GPS, trims, or global variables.
- At most one service is updated per host cycle, chosen round robin among those due, and each service caps how many subscriptions it refreshes in one update. Per-callback cost follows the caps, not the layout.

Components consume immutable snapshots. A service mutates its own state table in place, which allocates nothing per cycle, and publishes a proxy whose writes raise. Services update before component refreshes, so every component rendering a cycle sees one consistent set of readings.

## Proposed SD-Card Structure

```text
/WIDGETS/AeroGrid/
├── main.lua
├── dashboard.lua
├── grid.lua
├── layout_store.lua
├── yaml.lua
├── components/
│   ├── cell-battery.lua
│   ├── metric.lua
│   ├── flight-timer.lua
│   ├── link-status.lua
│   ├── navigation.lua
│   ├── flight-mode.lua
│   ├── model-identity.lua
│   ├── tx-battery.lua
│   ├── trim-panel.lua
│   └── variable-indicator.lua
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
    ├── default.yaml
    ├── services.yaml
    ├── services2.yaml
    ├── span1x1.yaml
    ├── span2x1.yaml
    ├── span2x2.yaml
    ├── span4x1.yaml
    └── <model-identifier>--<dashboard-id>.yaml
```

EdgeTX automatically registers `/WIDGETS/AeroGrid/main.lua`. Files under `components/` are loaded by the dashboard and are not independently registered widgets.

The package ships with bundled components. Advanced users may add compatible component files directly under `/WIDGETS/AeroGrid/components/`. The host loads only component types referenced by the active YAML, requires a compatible component API version, and rejects unsafe names and paths.

The widget `create(zone, options, path)` callback receives the widget folder path. Component scripts can therefore be loaded with:

```lua
local chunk, err = loadScript(path .. "components/cell-battery.lua")
if not chunk then
  error(err)
end
local component = chunk()
```

## Grid Model

The dashboard uses zero-based logical coordinates:

- `col`: 0 through 3
- `row`: 0 through 3
- `colSpan`: 1 through `4 - col`
- `rowSpan`: 1 through `4 - row`

Components must occupy contiguous rectangular cells and must not overlap.

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

The host creates one LVGL box or equivalent parent object for each rectangle. Components use coordinates relative to their own parent. Recursive LVGL children and explicit parent objects are supported by EdgeTX in `api_colorlcd_lvgl.cpp`.

## Visual Design Direction

**The decisions this section records, together with their rejected alternatives and the reasoning behind both, live in [`aerogrid-design-guide.md`](aerogrid-design-guide.md).** That document is written for someone building a component or a layout and states plainly which parts are implemented and which are agreed but unbuilt; this section remains authoritative on behaviour and the guide on appearance. The content-flow rules in particular -- panel-derived slots, proportional bands, band-derived fonts -- are agreed and **implemented by no component**, and only the guide says so.

The default interface should feel like a modern flight instrument rather than a collection of legacy widget boxes. The supplied references establish the intended direction: dense and glanceable, with strong numeric hierarchy, restrained color, crisp panel boundaries, and minimal decoration.

The primary reference viewport is 480 x 272, matching the TX16S and several other color-screen targets. The same layout model must scale to other supported color displays without scaling type directly from viewport width.

### Design principles

- Optimize for recognition during flight: the current value, unit, label, trend, and warning state must be distinguishable at a glance.
- Use dark neutral surfaces with luminance separation rather than a one-hue dark blue or slate palette.
- Reserve saturated color for meaning: cyan for electrical or selected data, green for healthy/current state, amber for caution, red for critical state, and orange only where it identifies a distinct measurement family.
- Use one dominant reading per component. Supporting values must be visibly secondary.
- Keep component framing quiet. A panel is defined by its elevated fill against the darker screen, not by an outline. Prefer surface separation and a narrow semantic accent over any stroke.
- **The fill is a condition of the data; the outline is where the interaction is.** Warning and critical tint the panel's field and draw no border. Selection and editing draw the border and are the only things that do. Area is seen in peripheral vision where a line is not, which is what matters on a moving aircraft: an outline has to be looked at, a tinted field is noticed while looking elsewhere. Keeping the two apart also means a panel can be alarming and focused at once, which it could not while the border carried both.
- Stale and unavailable are in neither group. They dim, because absent data is not an alarm and a panel that shouted whenever a sensor went quiet would teach a pilot to ignore it.
- An alert tint is derived from the state's own accent rather than stated, so a palette taken from the radio tints from the surface the radio gave it. It is mixed by the smallest amount that is noticeable beside an untinted panel, because every step beyond that spends contrast the text drawn on it has to give back, and it may be darkened as well as lightened: a dark surface tints by moving toward a bright accent, and a mid-grey one has no room to lighten without losing the faint text on it.
- **Every guarantee the resting surface carries is re-checked against each tint.** None of them transfer. Body, muted and faint text, elevation above the screen, separation from an untinted panel, and the state's own accent all have to hold on the tinted field, and a palette where none can is left untinted rather than made illegible.
- Avoid ornamental gradients, glow effects, glossy styling, decorative blobs, and excessive gauge rings.
- Keep animation purposeful and sparse: value interpolation, state changes, and editor transitions only.
- Preserve stable geometry when values, units, labels, or warning states change.

### Screen composition

- A compact status rail across the top was specified and is deferred; EdgeTX's own top bar fills that role at no cost to the Lua budget. See [Why there is no status rail](#why-there-is-no-status-rail).
- In App mode the top-left 47 x 45 corner belongs to EdgeTX's menu button. Panels lay out around it through `theme.frame` rather than the grid surrendering a strip.
- Use a compact footer only for genuinely global data such as coordinates or an active flight timer. Do not reserve footer space by default.
- Use 4 px outer margins and 4 px grid gutters at 480 x 272 as the initial baseline, subject to hardware verification.
- Component panels use an 8 px corner radius. The originally specified 4 to 6 px reads as a square panel with the corners shaved at 480 x 272, and the reference design's corners are visibly softer. Nested cards are prohibited.
- The semantic accent occupies a column exactly one accent width across, down the panel's left edge, and fills whatever of the panel lies inside that column. Between the corners that is the full width; through each corner it narrows as the panel's own curve crosses the column, reaching nothing where the curve leaves it. It never extends past the accent width and never leaves the panel's rounded shape.
- It is built as a straight rectangle and two quarter-circle arcs, inside a clipping container. The straight run spans `y = radius` to `y = height - radius`. Each corner is an `lvgl.arc` centred on the panel's corner centre with the panel's corner radius and a thickness of the accent width, so its outer edge is exactly the curve the panel's fill is rounded by. Unclipped, those arcs reach `2 * radius` across; the container removes everything beyond the accent width.
- That the outer edges coincide follows from the firmware. LVGL draws an arc band between `radius` and `radius - width` measured from the centre (`lv_draw_arc.c`, `rout` and `rin`), and the object's box is `2 * radius` square about the position EdgeTX was given (`LvglWidgetArc::build` calls `setRadius`; `get_center` in `lv_arc.c` takes `min(w, h) / 2`). Rasterising with the clip simulated confirms the result: within the accent's column the accent covers exactly the panel's own pixels, on every row of every panel size tried, with nothing outside the column and nothing outside the panel.
- Corner bands are arcs, so hard-won constraint 11 applies. Every colour change is a `set`, and a `set` on a round object walks it up and left by its own radius unless the centre is restated, so both bands go through the shared `setRound` helper.
- A component spanning several cells remains one coherent panel; it must not visually imitate multiple unrelated cards unless its data model genuinely contains repeated items.

### Typography and values

- Use EdgeTX-provided fonts and font sizes to avoid extra memory cost unless a later target-specific benchmark permits a bundled font.
- Use tabular or fixed-width numerals where available so changing values do not shift adjacent content.
- Labels are short, uppercase where appropriate, and visually quiet.
- Primary values use the largest size that fits their component at every supported span.
- **The unit rides beside the value, on its baseline, at a smaller size and lower contrast.** It is its own label rather than characters of the reading, so the reading is digits alone and the two are measured together but drawn apart. Two steps down the reading ladder puts it between two fifths and three fifths of the number's height at every pairing the dashboard produces.
- **Baseline alignment is exact, and EdgeTX does not help.** The only font metric a script can ask for is `lcd.sizeText`, whose second return is `getFontHeight`, which is `lv_font_get_line_height`; nothing in `radio/src/lua/` exposes ascent or baseline. The numbers are nonetheless knowable, because `base_line` is a compile-time constant of each shipped font, sitting beside the line height in `radio/src/fonts/lvgl/std/lv_font_en_*.c`, and `lv_draw_sw_letter` places a glyph at `pos.y + (line_height - base_line) - box_h - ofs_y`. Aligning the two labels' **tops** instead puts the unit 31 pixels high at the largest pairing; aligning their **bottoms** puts it 9 pixels low, which is most of a `MIDSIZE` descender. Neither approximation is needed, and the suite fails if one is reintroduced.
- Supporting values and captions must remain legible on the physical radio, not merely in the simulator.
- Letter spacing is zero. Text must wrap, abbreviate, or reduce to a defined smaller font before it clips.
- A supporting row cannot shrink its font, because it is already at the smallest size the dashboard uses. A row therefore offers several wordings, longest first, and `theme.fitLabel` takes the longest that fits the width it will actually be given. Every supporting row in the catalogue goes through it.
- **A panel's composition is decided from its box, not by the component drawing it.** One shared ladder says whether a panel of this size carries a supporting row and a visualization, and every component gets the same answer. A component may decline what it was granted; it cannot claim what it was not. Eight private copies of that decision were why two panels of identical size disagreed: each had shed a different amount before measuring anything.
- **A reading's font follows from that composition, not from its own string.** Two panels of one size agree because they are answering the same question. Before this the four panels of the `2 x 2` span gallery drew their readings at XXLSIZE, DBLSIZE, MIDSIZE and SMLSIZE, a range of four to one, on panels identical to the pixel.
- **A form may drop redundancy, never magnitude.** A reading offers lossless wordings longest-first and `theme.fitReading` takes the largest that fits; where none does, the font steps down instead. A unit the panel's own label already states, a name, a suffix: those are redundancy and may go. A digit of precision, or a field of a clock, may not. `4.44V` to `4.44` removes something the panel says elsewhere. `1:04:12` to `04:12` removes an hour and reports a different reading, which a pilot would believe and no font size is worth. `888.88km` to `888km` removes 880 metres of a number someone is flying by.
- A component whose reading holds no redundancy offers exactly one form, and that is how it says so. Every reading is now of that kind, because the unit left the string: `flight-timer` draws a clock, `navigation` draws a distance, and the other four print digits with the unit beside them. What used to be a second form -- `4.44V` shortened to `4.44` -- is no longer a wording at all, it is whether the rider is drawn.
- **A unit is dropped rather than paid for with a size.** The reading is fitted first and the unit rides at whatever font that produced, or it is not drawn. Buying the unit by shrinking the number would be paying for redundancy with magnitude, and the first thing a pilot reads is how big the number is. The change from a glued-on unit is that dropping it is now rare rather than routine: a `V` beside an `XXLSIZE` number cost 40 pixels as a character of the reading and costs 23 including its gap as a rider.
- **A unit that carries magnitude is not redundancy and is never dropped.** A distance's unit changes with its range, so `1.23km` and `1.23m` are different readings rather than one abbreviated. `navigation` says so, and for it the pair is what the ladder is walked against: the number steps down until both fit, because a distance with no scale on it is worse than a small one.
- Stepping down one size is the intent and is what happens almost everywhere, but it is not a cap: the alternative to stepping again is clipping, which is never acceptable. A panel needing two steps is saying its column is genuinely too narrow, which happens where a dial takes half the width.
- **A badge names the state; the supporting row says why.** The badge vocabulary is a closed set on the theme, and short, because the column is reserved on every panel whether or not a badge is showing: a long word is paid for by every header on the dashboard rather than by the state that uses it. Components do not override it. Distinctions such as a cells sensor returning a number against one returning nonsense, or a dead link against a protocol with no RSSI sensor, belong in the row, which has room for words and is fitted to its width.
- The badge column is exactly as wide as its widest word, and is never squeezed. Clamping it to a fraction of a narrow panel protects the label by clipping the badge, which is the wrong way round: `CRIT` and `CRI` are not equally alarming, while a shortened source name is merely less informative. A header label with too little room left is dropped rather than clipped, on any panel, not only one obstructed by the menu button.
- Horizontal padding is asymmetric. The left clears the accent; the right has nothing to clear, so it is smaller. On a single cell those four pixels are a character of header label.
- **The badge column is reserved whether or not a badge is showing, and the header label's width never depends on whether one is.** Handing the label the empty column and taking it back when a badge appears would reflow the label at exactly the moment the panel changes state. That is worse than a permanently shorter label, and not by a little: a header that moves draws the eye to itself, at the instant the reading beside it has just gone critical and is the thing that needs looking at. It is also the stable-geometry rule above, which requires that a warning state does not shift neighbouring content. Every component in the catalogue can reach a badged state, so a column that was conditional would be conditional on nothing in practice.

### Initial color tokens

Exact colors require physical-display testing, but components must consume semantic theme tokens rather than hard-coded colors:

```lua
local theme = {
  canvas = 0x0A0C0E,
  surface = 0x212830,
  surfaceRaised = 0x2E3841,
  border = 0x3A434B,
  text = 0xF4F6F7,
  textMuted = 0xA7B0B6,
  textFaint = 0x69737A,
  cyan = 0x70D6F3,
  green = 0x55D990,
  amber = 0xF2B84B,
  orange = 0xFF762E,
  critical = 0xF05252,
}
```

Components may select a semantic accent, but the dashboard should not become a rainbow of unrelated component colors. Warning and freshness states override decorative accents.

### Component anatomy

A typical telemetry component should contain only the elements it needs from this hierarchy:

1. Short label or source name.
2. Primary value and unit.
3. Optional secondary value, limit, maximum, or trend.
4. Optional compact visualization such as a bar, arc, direction indicator, or sparkline.
5. A narrow state accent or warning treatment.

Components must define responsive presentations for the spans they support. A 1 x 1 component may show only a value and label; a 2 x 1 variant may add units and a trend; a larger variant may add history or related measurements. Unsupported spans must be rejected by component metadata rather than producing a cramped layout.

#### A visualization beside the reading, not beneath it

A bar sits under the reading and costs it nothing but height, which the ladder already accounts for. A **battery glyph** sits beside it and costs it width, and width is what decides the reading's font, so a panel that adds one has to fit the reading against the column that is left rather than against the panel.

The rule is the ladder's own logic read sideways: **a reading may step down one size to make room for something beside it, and no further.** Two steps is the panel saying it is too narrow to hold both, and the shape is shed the way any other visual is. Holding to that, the battery costs `tx-battery` one font size at exactly one span -- `1 x 2`, whose 105 pixels of content cannot carry a DBLSIZE `88.8` and a battery at the same time -- and costs nothing at the other seven, because dropping a unit the panel's own heading already states buys back more width than the glyph takes.

The glyph is sized by search rather than by formula. The answer is not smooth: a glyph one pixel narrower can be the difference between a reading keeping XXLSIZE and dropping to DBLSIZE, and there is no expression for where that edge falls that is not the loop written out longhand.

`primitives.batteryGlyph` is three rectangles, because `lvgl.box` accepts a `color` and silently ignores it. Its outline is built at its final weight and never restated, since a border width only reaches LVGL through `LvglWidgetBorderedObject::setOpacity` and is discarded by a later `set`; the **fill** carries the state, the way a bar's fill does and its track does not. An outline with no fill is a picture of a flat pack, so a panel with no range to measure against hides the whole glyph rather than drawing it empty.

**A compact visual sits on the optical centre of the reading's line box.** Not its baseline, and not its top. This was decided from rendered mocks rather than argued: the three were drawn side by side from the real geometry at every span, and the centre is the one that reads as belonging to the number rather than hanging off it. It applies to every compact visual in every component -- a battery, a dial, a compass -- so two panels of different components at the same span place theirs identically. A visual that spans the panel's width, which is to say a bar, has nothing to centre against and is unaffected.

**Content is placed on two slots derived from the panel, at 30% and 70% of the content width.** Agreed from rendered mocks and **not yet implemented by any component**; `make mocks` is what draws it. The reading takes the left slot and a compact visual the right, and every row below them uses the same two centres -- a row of one item centres across the whole content box, a row of two takes the slots -- so the arrangement is one rule at every level rather than a body rule with a footer exception. A panel holding only a reading does not split; it centres across the whole box.

The point of deriving the slots from the panel rather than from the content is that a slot cannot move when what is in it changes width, and across a row of equal-width panels every reading lands at the same x. Two earlier proposals were rejected for failing exactly that: left-aligned flow collects all its slack after the content, and fully centred content re-centres whenever a reading gains a digit, which put its reading 186px from its own heading against the slotted 91.

**Where the tightened slots would let two elements meet, the panel falls back to strict halves at 25% and 75%, and the fallback is decided at build from the widest string the component can print.** Deciding it from the current value would make the arrangement a function of the data: a voltage crossing from `9.9` to `10.0` would flip the whole panel between two layouts, which is the moves-when-content-changes objection that ruled out centring, in a worse form. Asking the widest form fixes the arrangement once, so a panel with room to spare today keeps the layout it will need at its widest. The fallback is per panel and never per row -- a tightened body over a strict footer would leave the columns disagreeing down the panel, which is the one thing slot-derived positions exist to prevent.

### States

- `normal`: Elevated panel with a semantic measurement accent, and no outline.
- `selected`: Clear focus outline suitable for touch and rotary navigation.
- `stale`: Muted value plus an explicit stale indicator; color alone is insufficient.
- `warning`: Amber accent, a tinted panel field, and concise threshold indication. No outline.
- `critical`: Red accent and a tinted panel field, with high contrast; avoid continuous distracting animation. No outline.
- `unavailable`: Placeholder label identifying the missing source or component.
- `editing`: Visible grid, selection bounds, and resize or move affordances without obscuring readings unnecessarily.

### Theme ownership

The host owns theme tokens and passes the active theme to every component. Components must not define independent background palettes. Component-specific configuration may choose a semantic accent only from host-provided tokens. A global theme may be exposed as a native host widget option and persisted by EdgeTX.

The host provides three theme modes:

- `modern`: The designed instrument palette and default experience.
- `edgetx`: Derive local dashboard tokens by reading the active EdgeTX theme with `lcd.getColor()`.
- `custom`: Start from the Modern palette and allow a small set of global overrides such as canvas, surface, text, and accent.

The dashboard must never call `lcd.setColor()` because doing so changes the entire radio interface and other widgets. Follow EdgeTX mode maps Primary, Secondary, Focus, Edit, Active, Warning, and Disabled roles into dashboard tokens, then applies contrast correction and dashboard fallbacks where EdgeTX has no suitable role. Critical red remains dashboard-controlled. Warning and critical colors are not independently configurable per component.

## Component Contract

Each component script returns a table implementing this interface:

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

- `create`: Builds the component's LVGL objects and returns private context.
- `refresh`: Updates visible state.

### Optional callbacks

- `update`: Applies changed geometry or configuration.
- `background`: Performs low-frequency work while the dashboard is not visible.
- `event`: Handles an event and returns true when consumed.
- `destroy`: Releases component-owned references before rebuilding or removal.

Components must not assume full-screen dimensions. They must use the supplied rectangle and adapt to all supported spans.

Each component must also publish supported spans or minimum dimensions so the editor can prevent visually invalid placements. The host passes shared theme and service objects through the component context or an additional services argument; components must not duplicate global styling or telemetry caches.

## Component Settings

Legacy EdgeTX Lua widgets declare a static `options` array. EdgeTX converts each option type into a settings control, stores the selected values in the model's `WidgetPersistentData`, and passes an options table to the widget's `create` and `update` callbacks. A `SOURCE` option stores the selected source identifier; the widget later reads its live value with `getSourceValue(sourceId)` or `getValue(sourceId)`.

AeroGrid has only one native EdgeTX widget and therefore only one native option set. The host cannot ask EdgeTX to create independent native settings pages for dynamic child components. Instead, every component publishes a typed `settings` schema and the dashboard builds an equivalent LVGL form in its own editor.

### Supported setting types

The initial component schema should support:

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

Eleven shipped components and two fixtures, written to the same contract by different sessions, produced five names for "how should this look", four meanings for `min`, and a per-component setting for a dashboard-wide singleton. Names are part of the contract, not decoration: a layout author reads one component and expects the next to answer the same question the same way. The rules below are what the vocabulary converged on.

**One name per concept.** Three questions exist and each has exactly one key:

- `visual` — the shape the reading is drawn as: `bar`, `radial`, `none`. It selects a drawing, never content.
- `presentation` — which arrangement of content the panel shows when several are possible and the box decides between them. Only `navigation` and `model-identity` have more than one arrangement.
- `reading` — which of the component's own values leads the panel when it holds several, as `cell-battery` holds lowest, pack and average.

A component that offers one of these but not the others declares only the one it offers. `display` and `primary` are not used; both were re-spellings of `reading`, and `display` also stood in for `readout` on `trim-panel`, which is neither.

**Every enum declares its `choices`.** A `string` setting whose values are drawn from a fixed list must declare them, so the loader rejects `presentation: nonsense` at load with the component and key named, rather than falling back silently and leaving the author to wonder why the panel looks wrong. Undeclared keys are reported the same way: a renamed setting left behind in a layout is a defect, not a comment.

**A setting whose meaning is decided at runtime is refused, not documented.** `link-status` can lead with RSSI in dBm or with link quality in percent, and under `reading: auto` the choice is made by whichever source the protocol publishes. A threshold is a bare number, so `warning: 50` is plausible in both units and means a different thing in each, and nothing downstream can tell: the panel alarms at the wrong moment rather than failing. The first pass at this vocabulary named the unit "the leading source's", which described the trap precisely and left it in place. That was the wrong call. A component may state a rule spanning two of its settings through `validateSettings`, and this one refuses a threshold unless `reading` names a source. The shipped dashboard was relying on the old behaviour, with percentage thresholds under `auto`, and `auto` falls back to RSSI when no quality sensor exists — where every reading is below 30, so that panel would have sat permanently critical on any protocol without one.

**A setting must have more than one answer a layout could sensibly give.** Where the answer is fixed by what the value physically is, the behaviour is documented rather than configured. `direction` was added to every component with thresholds, and on five of them there was only ever one answer: a voltage and a link quality alarm downward, a distance from home upward, and a timer's direction is EdgeTX's own `countdown` flag, which `flight-timer` had always read instead of the setting. A setting with one valid value is not configuration; it is a fact spelled as a question, and it makes a reader wonder what the other value would do. Only `metric` keeps `direction`, because it reads an arbitrary source and a current, a temperature and an altitude genuinely alarm upward where a voltage and an RSSI alarm downward. The suite holds every declared `choices` list to more than one entry.

**A setting must not ask for something the radio already knows.** Where EdgeTX holds the answer, read it and let the layout override it, rather than requiring the layout to restate it. `tx-battery` asked for the pack's voltage range, which every radio already carries at SYS then Hardware then Battery meter range and which `getGeneralSettings` reports as `battMin` and `battMax`, already converted to volts. Requiring it made a dark bar the normal case rather than the exceptional one. `variable-indicator` was already right and is the pattern: a global variable's bounds, precision and unit come from `getGlobalVariableDetails`, and its settings override them.

This is the same shape as `armSource` moving to the layout's session block: both were a component asking for something that was already known somewhere else. When adding a setting, the question to ask first is whether EdgeTX can be asked instead.

**Thresholds state their direction and their unit.** `warning` and `critical` are bare numbers, so nothing about them says whether crossing downward or upward is the alarm, or what they are measured in. Both are stated: `direction` is declared by every component that has thresholds, and the unit belongs in the setting's label — `Warning volts per cell` and `Warning seconds`, not `Warning`. Where the unit genuinely depends on configuration, as `link-status` measures in whatever its leading source reports, the label says so rather than naming a unit that may be wrong.

**A range is named for what it bounds.** `min` and `max` meant a normalisation range, a per-cell voltage range, a whole-pack voltage range and a bar-only range, in four components, all under one word. The range now carries its subject: `rangeMin`/`rangeMax` normalise a visualization, `cellEmpty`/`cellFull` bound one cell, `packEmpty`/`packFull` bound a pack, `barMin`/`barMax` bound a bar. A normalisation range is not a limit, and stating that in its comment is worth the two lines: a value outside it is still drawn as itself.

**Dashboard-wide state belongs to the dashboard.** A setting that describes the session rather than the panel belongs in the layout's top-level `session` block, not in each component's `config`. `armSource` was per-component, which let two components name two different switches while the extrema service documented that the first caller wins — so the second was configured, accepted, and ignored. Anything that a second component could contradict is a candidate for the same move.

**Accent defaults follow the colour rule.** The palette reserves cyan for electrical data and green for healthy state; a component's default accent obeys that rather than its author's taste. `tx-battery` was green and `cell-battery` cyan for the same concept.

**An empty `label` means derive, not omit.** Four components leave `label` empty by default because their heading is only knowable at runtime — the timer's name, the preset's label, the probed service, the global variable's configured name. A component with a fixed heading states it as its default. The empty string is a deliberate instruction and each such declaration says what it derives from.

### Value flow

1. The component module publishes its `settings` schema.
2. The layout loader reads the component's persisted `config` map.
3. The host fills missing values from schema defaults and validates stored values.
4. The host passes the resolved config to component `create` or `update`.
5. The component settings editor binds LVGL controls to an in-memory working copy.
6. Apply validates the working copy, updates the live component, and persists the layout YAML.
7. Cancel discards the working copy and leaves live and persisted values unchanged.

Runtime or derived values belong in the component context and are not persisted. Only user configuration belongs under the component's YAML `config` map.

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

`<key>Name` is retained only as a key the settings loader will not report as unknown, so an older layout carrying one still loads. Nothing reads it.

### Native host options

Settings that apply to the dashboard as a whole, such as a global theme or diagnostic mode, may remain native options declared by `main.lua`. EdgeTX will generate their settings UI and persist them in the model. Placement and dynamic per-component settings must remain in the dashboard YAML.

Each widget instance also declares a native string option keyed `DashID` and displayed as `Dashboard ID`, defaulting to `main`. The host combines the sanitized current model filename and Dashboard ID to select:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

Different EdgeTX custom screens use different Dashboard IDs, allowing multiple independent AeroGrid screens for the same model. An instance renders exactly one YAML dashboard and does not implement internal paging or swipe navigation.

## Host Lifecycle

### Create

1. Receive the EdgeTX zone, options, and widget folder path.
2. Select the layout filename for the active model.
3. Read and parse the YAML layout, falling back to `default.yaml`.
4. Validate and normalize all placements.
5. Load each referenced component script.
6. Create an LVGL parent container for each placement.
7. Call each component's `create` callback.

### Update

1. Apply changed dashboard options.
2. Recalculate grid rectangles if the host zone changed.
3. Call component `update` callbacks where possible.
4. Rebuild only components that cannot update in place.

### Refresh

Call each visible component's `refresh` callback. Expensive telemetry calculations should be cached or scheduled rather than repeated by every component.

### Background

Call component `background` callbacks at a controlled rate. Components must not update LVGL objects while hidden unless EdgeTX permits that operation.

### Events

The host routes touch, key, rotary, and editor events. Events should first go to dashboard/editor controls and then to the component under focus or pointer position.

Interactive LVGL controls are only available while the Lua widget is in temporary fullscreen mode. App mode provides the cleanest route into this interactive state.

## Telemetry and Flight Semantics

### Source resolution

- Persist the sensor's name. See [Source settings](#source-settings) for why it is the name and not the identifier.
- Resolve the name to an identifier at subscribe time and hold it no longer than the dashboard is loaded.
- A name that does not resolve is an unavailable source, reported as such. Never bind a different source in its place.
- Preserve the source's reported unit and precision unless the user selects a supported conversion.
- Handle numeric, cells-table, and GPS-table source values without treating them as interchangeable.

### Freshness

Every telemetry-backed component distinguishes:

- `current`: Valid and recently updated.
- `stale`: Previously valid but no longer current.
- `unavailable`: Never received, invalid source, or unsupported value shape.

Last-known values may remain visible in the stale state, but must be visually marked and must not update flight extrema. Unavailable data displays a concise placeholder rather than zero, because zero may be a valid reading.

### Units and formatting

- Use EdgeTX source units and configured radio unit preferences where available.
- Keep conversion and formatting in the telemetry service so related components agree.
- Store thresholds in a documented canonical unit or alongside an explicit unit field; never reinterpret an existing threshold when display units change.
- Use stable precision and avoid rapidly changing decimal places.
- GPS coordinates support decimal degrees initially; additional formats may follow.

### Flight session

Dashboard-tracked "during flight" extrema require an explicit session boundary. The extrema service supports these reset policies:

- `manual`: User resets flight statistics from the dashboard.
- `timer`: Reset when a configured model timer starts a new run.
- `switch`: Reset on the configured arm or motor-switch transition.

The initial policy is `switch`, using a configured arm switch. A disarmed-to-armed transition resets and starts dashboard flight extrema; an armed-to-disarmed transition stops and freezes them. The `manual` and `timer` policies remain available as fallbacks. EdgeTX-provided minimum/maximum telemetry sources are preferred by components and remain independent of dashboard flight sessions.

Flight-session state is runtime state and is not written on every telemetry update. A future requirement may add explicit snapshot or log persistence.

## YAML Layout Format

Initial schema:

```yaml
version: 1
grid:
  columns: 4
  rows: 4
components:
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

Every key above is one the named component declares, every span is one the named component supports, and this example is loaded by the test suite rather than being read and believed. That is not a stylistic point: since the settings vocabulary work, a key a component does not declare is reported at load with the layout, component and key named. The version of this example printed here until 2026-09-18 did not load cleanly — it produced `main-battery: source must be a string; showLabel is not a setting of this component` — and it was the most likely thing for someone to copy. Correcting it by inspection was not enough: it also gave `link-status` a `4 x 3` span that the component does not declare, so the host would have dropped the panel from the dashboard. That was found by the test, not by reading, which is the argument for the test.

The second half of that message is the more interesting one. The example showed sources as numeric identifiers with a `sourceName` companion, because [Source settings](#source-settings) used to specify that. It was the specification that was wrong, and it has since been corrected to describe what exists and why: a source identifier records the order sensors happened to arrive in and moves when they are rediscovered, and nobody can hand-author one.

### Schema rules

- `version` is required and currently must equal 1.
- The first implementation always uses a 4 x 4 grid, even though dimensions are recorded for future compatibility.
- `id` must be unique within a layout.
- `type` maps to `components/<type>.lua` and must be restricted to safe filename characters.
- Placement values must be integers within grid bounds.
- `session` is optional and carries settings that describe the flight rather than a panel. `armSource` names the switch or source that marks the model armed, and lives here because one dashboard has one flight; stated per component, two components could name two switches and only the first would be honoured.
- Unknown top-level keys should be ignored for forward compatibility.
- Unknown component types should produce a visible placeholder rather than prevent the dashboard from loading.
- Component-specific data belongs under `config`.
- Config keys correspond to stable keys in the component's `settings` schema.
- Missing config keys receive component defaults. An unknown config key is preserved when saving, for forward compatibility, but is reported at load with the layout, component and key named: in practice it is a typo or a rename left behind, and silence is how a renamed setting reaches a radio still doing nothing.
- A config value outside a setting's declared `choices` is reported the same way and falls back to the setting's default.
- A component may declare `validateSettings(settings, span, config)`, returning messages, for a rule that spans more than one setting, or one that depends on where the panel is placed. `choices` catches a value that is wrong on its own; this catches a pair that is wrong together, or a value that is fine in itself and meaningless at this size.
- **Validation that fires on resolved settings must distinguish what the layout stated from what the defaults filled in.** `settings` arrives complete, with every default applied, so a rule reading it cannot tell a request from a resting value. `config` is what the layout actually said, and a rule that complains should read that. `cell-battery`'s `showPack` and `showCount` default to `true` and need a supporting row no single-row span has, so a rule reading `settings` would have reported the panel's own shedding as an ignored request and failed every layout with a one-row `cell-battery`. The distinction is the difference between a rule and a nuisance, and it applies to any future validation, not only to this one.
- Sources are stored as sensor names. A `<key>Name` companion from an older layout is accepted and ignored.

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

The editor must save only on an explicit Apply or Save action to reduce SD-card writes.

Recommended save sequence:

1. Serialize and validate the complete layout in memory.
2. Write `<layout>.tmp` using `io.open(..., "w")`.
3. Close the temporary file.
4. Read and parse the temporary file to verify it.
5. Rotate the existing file to `<layout>.bak` where practical.
6. Rename the temporary file to the final filename.
7. Keep the backup until the next successful save.

On load, try the final file, then the backup, then `default.yaml`.

Layouts are keyed by sanitized model filename and Dashboard ID as `<model-identifier>--<dashboard-id>.yaml`. Sanitization must be deterministic, reject traversal, and append a short hash when normalization could create collisions.

## Dashboard Editor

The editor runs inside the dashboard's temporary fullscreen state.

### Required actions

- Add component
- Select component type
- Move component by one grid cell
- Resize component by one grid cell in each direction
- Edit component-specific configuration
- Remove component
- Cancel uncommitted changes
- Apply and persist changes
- Restore the default layout

### Component settings behavior

- Generate the settings form from the selected component's `settings` schema.
- Use native-style LVGL source, switch, timer, file, color, choice, numeric, text, and toggle controls.
- Edit an isolated in-memory working copy rather than the live YAML data.
- Show defaults for missing values and validation feedback for invalid values.
- Apply settings to the live component only after validation succeeds.
- Persist settings together with placement when the dashboard Apply or Save action is confirmed.
- Preserve unknown config keys so a newer component configuration is not destroyed by an older dashboard host.

### Placement behavior

- Show the 4 x 4 grid while editing.
- Highlight the selected component.
- Show occupied and available cells.
- Reject out-of-bounds placement.
- Reject overlap, or optionally offer to swap/move the conflicting component.
- Keep an in-memory working copy until Apply.
- Rebuild affected LVGL containers after an accepted geometry change.

Touch radios may support drag and resize handles. Rotary/key-only radios should use explicit Move and Size modes with directional controls. The persisted placement model is identical for both input styles.

## Validation and Recovery

The loader must validate every layout before creating components:

- Schema version is supported.
- Grid dimensions are supported.
- IDs are unique.
- Component types are safe and available.
- Coordinates and spans are integers in range.
- Rectangles do not overlap.
- Configuration values meet component-defined constraints where available.
- Source values are names that resolve against the model's sensors, or are reported as unavailable.
- Configured sources return the value shape required by the component.
- Threshold units and ranges are valid.
- A navigation bearing is shown only when valid model and pilot/home GPS coordinates are available.

Invalid entries should be skipped or replaced with an error placeholder. One broken component must not disable the entire dashboard.

The UI should expose enough error information to identify the layout file and invalid component without displaying a Lua stack trace during normal use.

## Performance and Resource Constraints

- All components share the EdgeTX widget Lua state and instruction budget.
- Keep component modules namespace-local and return tables rather than creating globals.
- Avoid loading unused components.
- Cache telemetry sources and derived values where components can share them.
- Rate-limit expensive work independently from visual refresh.
- Minimize LVGL object count, bitmap memory, and transient table allocation.
- Prefer incremental updates over rebuilding the complete dashboard.
- Test on physical target hardware as well as the EdgeTX simulator.

## Compatibility

- Initial targets: RadioMaster TX16S versions 2 and 3, RadioMaster TX15, and RadioMaster GX15 running EdgeTX 2.12 or newer.
- App mode is the primary deployment because it provides the complete decoration-free screen and the cleanest future path to interaction.
- The ordinary Full screen layout remains a supported fallback when users want EdgeTX decorations.
- Existing native layouts and widgets are unaffected.
- Components written for this dashboard are not automatically compatible with native EdgeTX widget slots.
- Existing widgets must be adapted to the component contract and relative geometry.
- Telemetry availability and naming vary by RF protocol, receiver, sensor configuration, and model.
- Missing optional sources must degrade the component presentation rather than prevent dashboard startup.
- Internal transmitter GPS is not assumed; aircraft telemetry GPS is the primary navigation input.

## Distribution, Versioning, and Diagnostics

- Distribute AeroGrid as one versioned `/WIDGETS/AeroGrid/` package so host, services, editor, and bundled components are upgraded together.
- Keep `main.lua` small and load implementation modules on demand.
- Define a dashboard package version, layout schema version, and component API version independently.
- Every component declares the component API version it requires. Incompatible components render an error placeholder instead of executing.
- Phase 2 layout migrations operate on an in-memory copy, preserve the original file as a backup, and write only after successful validation.
- A newer unsupported layout version must not be rewritten by an older dashboard release.
- The dashboard provides a diagnostics view showing package version, active layout path, loaded components, unresolved sources, and component failures. See [The host diagnostics view](#the-host-diagnostics-view).
- Diagnostics must avoid continuous SD-card logging by default. Optional logs are written only on explicit export or when a bounded diagnostic mode is enabled.
- Component loading and layout filenames must reject path traversal and unsafe filename characters.

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

State as of 2026-09-18. This section is the entry point after a break: it records where the code lives, what is proven, and what to do next.

### Where the work is

**Everything is on `main`. There is no branch stack, no open pull request, and no work in flight.** Milestones 1 to 8 and the presentation and consistency pass are all merged; every working branch has been deleted. A fresh branch off `main` is the correct starting point for anything.

This section used to carry a table naming the branch currently in flight, which was accurate only while one existed and became a trap the moment it was merged: the first act on resuming was to check out a branch that had been deleted. The shape is gone rather than filled in with `main`. If a branch stack ever returns, record it here again — but only while it is real.

### Nothing has run on a radio

Every decision this project has made rests on two things: the EdgeTX simulator, and arithmetic. That includes all of today's work.

The simulator is a real host running real LVGL, so it catches a great deal, and the test suite measures against a mock whose arithmetic is taken from the firmware source. But a simulator on a desktop monitor is not a 480 x 272 transflective panel at arm's length in daylight, and no amount of contrast arithmetic substitutes for looking at one.

The judgements most exposed by this are the ones that were made *because* of how something reads:

- **The alert tints.** `warning` and `critical` now tint the panel's surface instead of drawing a coloured frame, on the argument that area is noticed in peripheral vision where an outline has to be looked at. Every tint is held to the same text and elevation minimums as the resting surface, and that is checked numerically for both palettes. Whether a tinted field is actually noticed while looking elsewhere, on a moving aircraft, has never been tested.
- **The panel as a card.** Elevation of 1.316 canvas to surface, 8 px corners, no resting outline. Chosen from ratios.
- **Estimated text width.** The Lua API cannot measure text outside a draw callback, so `theme.textWidth` assumes a mean advance of 0.58 of the line height. Every font choice in the dashboard descends from that constant, and it has never met a real font.
- **The responsive ladder.** Which rows a panel keeps at each span is decided from measured box geometry, but whether the result is readable is a question for eyes.

This is carried in the open-items table as milestone 4's physical readability review, which undersells it. It is not one milestone's loose end; it is the standing condition of the whole project.

### What the presentation and consistency pass did

Eleven pull requests over one day, after an audit that measured every component at every span it declares through the real host. The audit's premise was that thirteen components written across three milestones by different sessions to the same contract, but not to each other, would agree individually and disagree as a set. They did. The PRs hold the detail; this is the shape.

**Presentation.** A panel is now a card: deepened canvas, lifted surface, 8 px corners, and no outline at rest. Its accent is a full-height stripe with rounded outer corners, drawn as arcs clipped by a box one accent-width wide — five rounds of trying, and the version that worked came from the user rather than from the measurements. Alert states tint the surface instead of colouring the frame, which leaves **fill meaning a condition of the data and outline meaning where the interaction focus is**, where the border previously carried both.

**Consistency.** The badge vocabulary was cut from thirteen strings to five rather than widening the column to fit the longest, because `NOT CELLS` and `BAD CELLS` were nine characters separating two failure modes of one component. The header gives the label the room an empty badge is not using, permanently rather than conditionally, so a state change never makes the label reflow. Eight private copies of "choose a font for this reading" became one shared responsive ladder: composition comes from the box, and the font from the composition, so two panels of the same size agree. Ten non-monotonic font ladders became none.

**Correctness.** A component now declares what it renders, and its redraw comparison is derived from that declaration rather than from a hand-listed subset that drifts from `apply` — which was the fourth instance of one defect, after three were fixed individually in milestone 7. The settings vocabulary was unified: one name per concept, declared `choices` the loader enforces, thresholds that state their direction and unit, ranges named for what they bound, and the flight arm switch moved to the layout where two components cannot contradict each other.

**Cost.** `trim-panel`'s reflow, the worst callback, was found to be half inherent and half invisible work: it hid the text rows a narrow cell cannot fit and then went on positioning, formatting and writing them anyway.

Two lessons generalised past their PRs and are recorded where they will be read rather than only in a PR body: **assert what the panel draws, not what it computed**, in the fixture discipline section, which seven assertions in the existing suite were violating; and **a form may drop redundancy, never magnitude**, under typography, which stopped `flight-timer` rendering `1:04:12` as `04:12`.

### Current cost

| | Value | Where |
| --- | --- | --- |
| Worst callback | 7882 of 20000 | the staged loader building one `trim-panel` at sixteen cells |
| Worst steady frame | 2520 of 20000 | the shipped ten-component dashboard |

The worst steady frame used to be a `trim-panel` and is not any more. Both figures are asserted by the suite and are measured at the largest layout the schema permits. Note the second-worst callback is the loader's own header stage rather than any component -- which means component work is no longer the binding constraint on a full grid, and the next person looking for headroom should know that before optimising a panel.

The worst callback rose 85 when the heading notice started working. It had been reading a field off the label, which is a table here and userdata on a radio, so it was always nil there and the notice never fired: the work it appeared not to cost was work it was not doing.

### Verification state

- `make test`, `make check`, and `make build` pass from a clean tree. `make check` was also run against a real Lua 5.3 `luac`, and both suites were executed under a real Lua 5.3 interpreter, not only under whichever Lua `lupa` provides.
- CI (`.github/workflows/ci.yml`) runs `make check` under Lua 5.3 on every pull request, plus the SD image build and two integrity assertions.
- The dashboard has been confirmed running in the EdgeTX simulator on a TX16S profile through milestone 7. Navigation, link status, the radial and bar metrics and the trim panel have all been read against live simulated telemetry, which is where the arc drift in constraint 11 was found. Two of milestone 7's behaviours still cannot be judged there: whether a cells source on a real receiver returns the table shape assumed here, since nothing on an ELRS link publishes one, and whether a protocol without an RSSI sensor is recognized as a link rather than a dead one.
- Milestone 8's corner work and the whole presentation and consistency pass have been seen in the EdgeTX simulator and judged there. The accent geometry in particular took five rounds of looking, and the version that was accepted came from the person at the screen rather than from any measurement, which is the standing argument for building something to look at rather than reasoning about it in prose. None of it has been seen on a radio; see [Nothing has run on a radio](#nothing-has-run-on-a-radio).
- The simulator fixture carries nine screens, every one holding an AeroGrid instance: `sim`, which fills its grid with the telemetry components, `sim2`, which covers the radio-local ones that had nowhere to go beside them, the `states` layout twice, the `host` diagnostics view, and the four span galleries. They are ordered by what is being looked at rather than by when they were written: the two dashboards, then the states pages, then the diagnostics, then the galleries, which are reference material for the catalogue audit. A screen that takes six pages to reach does not get looked at, which is the only thing a screen is for. A gallery only ships as a layout, and selecting a layout means setting the widget's Dashboard ID, which in App mode cannot be reached from the main view at all: `Widget::openMenu` returns immediately after `setFullscreen(true)` when the widget is not in the top bar and the view is App mode. Without a screen apiece, reaching a gallery means going through Model Setup and Screens once per gallery. `MAX_CUSTOM_SCREENS` is 10, so nine leaves one spare. Paging between them switches dashboards without opening widget settings, and exercises two widget instances resolving different layouts at once. `sim` carries the Modern palette and `sim2` the EdgeTX-derived one, so the two are one button press apart.
- Two instances running together are held to owning their own root, page, service registry and telemetry service, because EdgeTX runs every Lua widget in one interpreter state and anything a module kept at its own scope would be shared between dashboards that know nothing about each other.
- In App mode, every shipped layout is checked to draw nothing readable inside the corner EdgeTX's menu button covers. The directory is read rather than listed, so a new layout is covered as soon as it is added.
- Every layout under `layouts/` is loaded by the integration suite, not merely the shipped default: each one is built through the real host and components, held to the same containment rules, and refreshed against radio state. A layout is covered as soon as it is added, because the suite reads the directory rather than a list.
- Four span galleries ship alongside the dashboards, under the Dashboard IDs `span1x1`, `span2x1`, `span2x2` and `span4x1`. They are not dashboards. `sim` and `sim2` are arranged to be useful; a gallery is arranged to make the catalogue disagree with itself where a person can see it, by putting one span in front of them for every component at once. Paging between the four then compares the same components across spans. The single-cell gallery is held to containing every component that declares a `1x1` span, read from the component directory rather than from a list, so a component written later cannot quietly drop out of the comparison.

### Immediate next steps

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
| **The physical readability review** | Needs hardware. It is milestone 4's last open item and has been open since milestone 4. | See [Nothing has run on a radio](#nothing-has-run-on-a-radio). It is larger than one milestone's loose end. |

### Open items carried forward

| Item | Where | Note |
| --- | --- | --- |
| Physical readability review at 480 x 272 | Milestone 4 | Needs hardware; the only thing keeping milestone 4 from being fully closed |
| The panel presentation has not been seen on a radio | Milestone 4 | Elevation, 8 px corners, the clipped accent stripe, the removal of the resting outline and the alert tints have all been judged in the simulator. None has been seen on a radio, which is where the peripheral-vision argument behind the tints can actually be tested |
| Milestones 5 and 6 have not been run on hardware | Milestones 5 and 6 | The diagnostics layouts exist precisely to make that check quick, and the shipped dashboard now exercises all seven core components at once |
| Staleness is link-wide, not per sensor | Milestone 5 | EdgeTX exposes no per-sensor age except for GPS, so a sensor that stops arriving, or was never received, while the link holds still reads as live. See below |
| Extrema reset policy covers switch and manual only | Milestone 5 | Timer-based reset is specified but not implemented |
| A `1 x 1` component in the App mode top-left corner cannot be fully shown | Milestone 8 | The button covers 40% of its width and 69% of its height. Its reading survives, pushed below the button, and its header label is dropped rather than clipped. No approach saves it; avoid the placement |
| The menu button corner has not been seen on a radio | Milestone 8 | Seen and confirmed in the simulator. Measured against the real host and asserted for every shipped layout. Still unseen on hardware |
| ~~Host notices are collected but not shown anywhere~~ | Milestone 8 | Closed. Contrast corrections and palette fallbacks are listed by the `theme` section of the host diagnostics view, which is where they were always headed |
| The status rail is deferred, not cancelled | Milestone 8 | EdgeTX's own top bar fills the role at no Lua cost, and the geometry does not favour a dashboard rail. Default settled as off should it return |
| Steady-state refresh cost scales with component count | Milestone 6 | 2562 of 20000 at sixteen `navigation` panels, and 2535 on the shipped ten-component dashboard. Watch it as the catalogue grows |
| A cells source's real shape is unverified | Milestone 7 | `cell-battery` assumes a contiguous array of per-cell voltages and validates every entry, but no receiver has produced one yet |
| A protocol without an RSSI sensor is detected indirectly | Milestone 7 | `link-status` relies on `telemetryService` observing a source contradict `getRSSI()`. Until something contradicts it, a genuinely dead link and a missing RSSI sensor are indistinguishable, and both read as no link |
| Text width is estimated everywhere except where the unit is placed | Milestone 6, narrowed in the unit pass | The premise was wrong: `lcd.sizeText` measures text and is **not** gated on a draw callback. `luaLcdSizeText` carries no `luaLcdAllowed` or `luaLcdBuffer` check, because it reads font metrics and returns. Unit placement now uses it; every other fitting decision still uses the 0.58 estimate, and converting them is a decision for the user with the numbers below in front of them |
| A trim's axis is unknown to the dashboard | Milestone 6 | EdgeTX exposes no axis metadata for a trim source, so `trim-panel` takes an orientation with a per-indicator override instead of matching on trim names |
| `lvgl.image` cannot report a failed decode | Milestone 6 | `StaticImage` clears its source silently, so `model-identity` checks the file with `fstat` beforehand and keeps the model name visible when `fstat` is unavailable |
| `actions/checkout@v4` and `setup-python@v5` target Node 20 | CI | Non-blocking deprecation warning |
| ~~`primitives.arcBounds` has no production caller~~ | Presentation pass | Closed by deletion. It was also wrong — it placed the outer edge at `radius + thickness / 2` where `lv_draw_arc.c` puts it at `radius` — and nothing caught that, because its only callers were tests using the same arithmetic. The tests now measure the arc the mock drew |
| ~~`REFLOW_BATCH` has never been measured~~ | Presentation pass | Closed. Measured across batch sizes 1 to 16 and set to 3, which is where the saving stops. See [Why `REFLOW_BATCH` is three](#why-reflow_batch-is-three) |
| ~~`link-status` thresholds change unit at runtime~~ | Presentation pass | Closed. A threshold is refused at load unless `reading` names a source, through the new `validateSettings` contract hook. The shipped dashboard was relying on the old behaviour and would have sat permanently critical on a protocol with no quality sensor |
| ~~Three development components ship~~ | Presentation pass | Decided per component. `service-probe` ships: milestone 9 wants a host diagnostics view and it is the only thing that inspects a service on a radio. `heartbeat` and `placeholder` are now fixtures under `tests/fixtures/components`, copied into every scratch package so the host-contract coverage they exist for keeps running |
| ~~Panels are outlined on every state, including healthy~~ | Milestone 4 | Closed. A resting panel is an elevated fill with no stroke; the border is reserved for focus, editing, warning and critical, and is built at the focus weight because a radio will not change a border's weight after the object exists |
| ~~A `1 x 1` metric fits its value vertically but width is unchecked~~ | Milestone 6 | Closed. `theme.fitText` fits a value by measured width as well as height, choosing the font from the widest string the component can ever produce so geometry stays stable |
| ~~`lvgl.arc` is positioned by its top-left corner~~ | Milestone 7 | Closed, and it never was. EdgeTX positions an arc by its **centre**, so every radial drawn before this milestone was one radius up and to the left of its intended place. See below |
| ~~The navigation distance value does not render in the simulator~~ | Milestone 8 | Closed. It rendered perfectly and EdgeTX's menu button was painted over it: `778m` at (8, 25), inside a corner of 47 x 45. Not a Lua fault, and no error was ever raised |
| ~~Component errors are invisible in App mode~~ | Milestone 8 | Closed. The overlay was drawn at (8, 8), underneath the menu button |

### Hard-won constraints

Thirteen firmware behaviours cost real debugging time and were invisible to the mocked tests until each mock was made faithful. Each now has a regression test, and each is documented in full further down. Why they were invisible, and what stops the next one, is the fixture discipline section below.

1. **A widget callback may not exceed 20000 Lua VM instructions.** Loading, reflow, refresh, and service updates are all bounded work per callback as a result.
2. **`lvgl.box` accepts a `color` and silently ignores it.** Only a filled `lvgl.rectangle` paints a background.
3. **EdgeTX fonts are much taller than they look.** `XXL` is a 69 px line height at 480 x 272. Lay out from measured heights, never fixed offsets.
4. **`getValue` returns integer zero for a telemetry source whose link is down.** That is indistinguishable from a genuine zero reading, so only a zero may be judged: a non-zero value is proof of life whatever `getRSSI()` says, and `getRSSI()` itself reads zero on a live link whose protocol has no RSSI sensor.

Milestone 6 added three more, all of them about what the Lua API refuses to tell a component:

5. **Lua cannot measure text.** `lcd.sizeText` is only meaningful inside a draw callback, which an LVGL widget does not have, so width has to be estimated. `theme.textWidth` assumes a mean advance of 0.58 of the line height and `theme.fitText` chooses a font from the widest string a component can ever produce, never from the current one, so a reading does not resize as it changes.
6. **A trim source carries no axis.** Nothing in `getFieldInfo` says whether a trim is a roll trim or a pitch trim, and the specification forbids assuming fixed trim names. `trim-panel` therefore takes an orientation, with a per-indicator override.
7. **`lvgl.image` cannot report a failed decode.** `StaticImage::setSource` clears its own source and traces the error when a file will not load, and tells Lua nothing. The decision has to be made before the object exists, so `model-identity` asks `fstat` first and keeps the model name visible when `fstat` is absent.

Milestone 7 added one more, and it invalidated work already shipped:

8. **`lvgl.arc` is positioned by its centre, not its corner.** `LvglWidgetArc::build` calls `setPos(x, y)`, and `LvglWidgetRoundObject::setPos` stores `x - radius, y - radius`. Every radial written in milestone 6 passed a top-left corner, so on real hardware each one was drawn a full radius up and to the left of where the layout intended, overlapping the panel header and the reading beside it. Nothing in the mocked tests could see it, because the mock stores whatever coordinates it is handed. `primitives.radial` now takes a centre, and the tests assert containment against the square the arc covers rather than against `x` and `y`. That square is centre plus or minus `radius`: `lv_draw_arc.c` sets `rout = radius` and `rin = radius - w`, so the stroke is drawn inside the radius and a thickness does not widen the box.

9. **A `clear()` is collected at a time the script cannot predict.** `LvglWidgetObjectBase::clear` only destroys windows and sets `clearRequest`; the reference cleanup happens later, in `callRefs`, which EdgeTX skips while the widget is off screen, such as behind the settings dialog, and once an error has been reported. When it does run, `clearChildRefs` invalidates every reference in that object's child list, including ones created long after the clear. Rebuilding the dashboard in place after a Dashboard ID or Theme change hit this: the canvas was recreated under the cleared root and then silently invalidated, and the next callback failed with `Invalid object (it has been probably been cleared)`, which disables the widget until the radio restarts. The dashboard now draws into a page container. A reload discards the whole page and builds the next generation as a fresh child of the root, which is never cleared, so no pending cleanup can reach it whenever it eventually lands. Deferring the rebuild by one callback is not sufficient on its own, because the collection point is not guaranteed to be the next callback.

10. **EdgeTX prefers `.luac` bytecode and compiles it beside each script.** The radio writes a `.luac` next to every `.lua` it loads and uses the bytecode on the next run. Copying a new image with `rsync -a` preserves source timestamps, so the new scripts can appear older than bytecode compiled from the previous build and the radio silently keeps running the old code. This cost several rounds of debugging: fixes appeared to do nothing, and the widget reported an error at a line number that no longer existed in the source. `make build` now deletes the bytecode and stamps the sources as new. When a fix appears to have no effect on a radio, confirm which code is actually running before changing anything else.

11. **Every update to an arc moves it, unless the update restates its centre.** `lvgl.arc` is positioned by its centre but stores `centre - radius`, and `LvglWidgetRoundObject::refresh` subtracts the radius twice: once inside `setRadius`, which converts the stored corner back to a centre, and again through the inherited `LvglWidgetObjectBase::refresh`, which calls `setPos(x, y)` with members that already hold a corner. Any `set` call runs `refresh`, whatever keys it carries, so an arc walks up and to the left by its own radius each time it is touched. `build` does not call `refresh`, so a dial is correct until its first update and wrong afterwards: the compass vanished the moment a GPS fix arrived, and the quality dial crept off its panel over a few telemetry readings. `primitives` now routes every arc update through one helper that adds the centre to the change set, which overwrites the drifted members with absolute coordinates so the doubled subtraction lands correctly. The test mock models this arithmetic rather than recording the coordinates it was handed, because a mock that stores what it is given cannot see the object move.

Milestone 8 added one firmware behaviour, and one about what a constant means:

12. **EdgeTX paints its menu button over the widget in App mode, and says how big it is in a unit nobody expects.** `ViewMain` creates the top bar after the screen, commented `// create last to be on top`, and the button is parented to `ViewMain` rather than to the bar, so hiding the bar in App mode leaves the button drawn over the dashboard's top-left corner. Anything underneath it is simply not visible: the shipped dashboard's distance reading was painted over for two releases without a single error being raised. The firmware does publish the size, as `MENU_HEADER_HEIGHT`, but registers it beside the colour constants so it passes through `COLOR2FLAGS` and arrives shifted left by sixteen bits. The global reads 2949120 on a TX16S, not 45. A host that never unshifts it falls back to a hard-coded 45 and is then wrong on every radio whose display class scales the constant, which is why the mock publishes the shifted value and the tests measure a 62 px button as well as a 45 px one.

The presentation pass added one more, and it had been silently wrong for as long as the panels had states:

13. **A rectangle's border width and corner radius are build-time properties.** `LvglWidgetRectangle::build` is the only caller of `lv_obj_set_style_radius` for a rectangle, and `LvglWidgetRectangle` adds no refresh of its own, so a `rounded` passed to `set` is parsed and then ignored. Border width is worse, because it looks like it works: `lv_obj_set_style_border_width` is called only from `LvglWidgetBorderedObject::setOpacity`, which runs behind `LvglParamFuncOrValue::changedValue`, and `refresh()` hands it the opacity the object already has. So `set{thickness = n}` updates the C++ member, never reaches LVGL, and reports nothing. Every panel therefore drew whatever weight it was born with: a component created healthy and later going critical asked for the focus weight and kept the resting one, on every radio, for three milestones. The panel now builds its border at the focus weight and shows or hides it, because visibility is the only property of a border that can actually change after the object exists. The mock keeps what was applied at build apart from what was last passed, so a test asserting the latter fails.

Two more lessons came from the tests rather than the firmware:

- A budget test that measured only the shipped layout could not fail, and hid a loader that broke on any layout larger than twelve components. Measure the worst case the schema permits, and assert that the measured work actually happened.
- An assertion can be vacuous without being wrong. A test that a missing model bitmap falls back to the model name passed while the panel was too short to have shown an image at all. It now asserts first that the panel could have shown one.
- A geometry test that only checks the right and bottom edges cannot see two rows resolved onto the same line. Milestone 7's region tests assert that every supporting row clears the one above it and every column clears the one beside it, and that shedding a row actually buys the dominant reading a larger font, which is the reason for shedding it.
- A fallback can hide the bug a test was written for. The reserved-corner test passed with the `MENU_HEADER_HEIGHT` unshifting removed, because the code's own 45 px default was right for the display the test used. Only measuring a display whose button is a different size made the shift load bearing. A default that rescues the mistake is worth keeping; a test that cannot see past it is not.
- A component that reimplements a shared helper stops receiving that helper's fixes. `service-probe` had its own copy of the panel frame arithmetic, so it kept drawing its title into the menu button's corner after every catalogue component had stopped. `metric` shadowed a subset of the frame's fields and handed that to the header primitive, so it silently missed the new one.
- A fixture's own limitation can be written up as firmware behaviour. A global variable test asserted that switching flight mode left the value unmoved and explained it as EdgeTX resolving inheritance; the mock ignored the flight mode argument, so the assertion could not have failed and the explanation was invented. See the fixture discipline section below.
- A refresh short-circuit is a cache, and a cache that misses a change shows an old number with a straight face. Three of milestone 7's components compared only their dominant reading and so froze a supporting row: the pack sum when three of four cells sagged, the RSSI readout while link quality sat pinned at 100, and the whole navigation panel when its GPS sensor appeared but had no fix yet. Each was fixed by adding the missed field to that component's comparison list, **and that is why there was a fourth**: `variable-indicator` drew a global variable's configured name and did not compare it, so when EdgeTX answered `getGlobalVariableDetails` after the first read the header took the new name and the supporting row kept saying `GV1`.

  The list is the defect. A component now declares what it draws, into one table, and is handed that table to paint from; the comparison is over exactly those values. A field the paint step reads but the declaration never wrote is `nil` on screen, which is loud, and a field declared but not painted costs a comparison and nothing worse. The list cannot drift from the drawing because there is no list.

  Auditing the catalogue for the same shape once the mechanism existed found three more, all latent: `flight-mode` drew the mode number and compared only the name, so two modes sharing a configured name would have frozen it; `flight-timer` drew the configured total and compared only the elapsed value, so a timer reconfigured mid-flight kept the old one; and `navigation` drew the coordinates and compared distance and bearing, which are measured *from home* and do not move when a model tracks an arc at constant range. `model-identity` had it too and could not be made to fail, because a model's labels change only when its name does — unreachable by coincidence rather than by construction. All nine components with a short-circuit now share the one mechanism.

  **What a component declares follows what it currently draws, not what it was built with.** Every panel that can shed a supporting row went on declaring that row while it was shed, which is the same invisible work `trim-panel`'s reflow was made of, and it also meant a row coming back was only correct because `update` discarded the last drawn record to force a repaint. The discard is remembering; the declaration is construction. All of them now gate on whether the row is showing, so a shed row declares nothing, a returning row declares a key that was absent, and `changed` sees the reveal by counting keys. The discards are gone.

  The finding worth recording is that **none of those discards was load-bearing**, and it took some effort to establish rather than assume. With a gate removed, no test could be made to fail on a stale row, because a reveal is always caused by a resize and a resize always moves some other declared value — a fitted caption's width, if nothing else — so the panel repainted anyway. The discards were protecting a path that is not reachable. That is the same shape as `model-identity` above: correct by coincidence. The tests therefore assert the property directly, that every declared key belongs to a row that is drawn and every drawn row has one, rather than trying to observe staleness that cannot currently occur.

### Fixture discipline

Six defects reached a radio while this suite stayed green, and a seventh was found in the tree before it could. They are listed below, and they are one defect: **a fixture encoded what we assumed, so it could not fail when the assumption was wrong.** A green suite told us nothing, because the mock and the code under test agreed with each other and both were wrong about the radio.

The rule has grown a part for each shape the failures came in, and each part is here because something shipped.

**A fixture that stands in for firmware must reproduce that firmware's arithmetic, ordering and data shape, and must cite the file it came from.** Not the result we expect it to produce: the behaviour. A mock that records the coordinates it is handed cannot see an object move. A mock whose `clear()` is an immediate flag cannot reproduce a deferred cleanup. A mock that returns its input unchanged cannot distinguish two encodings that are only the same number here. Where the firmware raises, the mock raises; where the firmware caps a value at 99, so does the mock; where the firmware accepts a fixed set of keys, the mock rejects everything else.

**A function that answers "the largest thing that fits" must also answer whether it fits.** This has now cost the same mistake twice. `theme.fitReading` returned the smallest font on the ladder whether or not the text fitted at it, and `tx-battery` read that as success and spent width on a battery the reading needed. Then the design-mock generator's own band fitter did exactly the same thing -- returned the smallest font and a cost of zero sizes when the truth was that nothing fitted at all -- and reported `navigation` at `1x1` as free when its widest distance is 60 pixels in a 48 pixel slot.

Both were written by someone who knew about the first one. The shape survives being known about because the failing answer is indistinguishable from a good one: a font comes back, it is a real font, and the caller has no way to tell that it was a surrender rather than a fit. The rule is therefore structural rather than a matter of care. **Where a search can fail, the failure is a return value, not a convention about the answer.** A caller that ignores it gets what it always got; a caller that is deciding whether to spend space on something else has to check it, and now can.

**A position derived from a size must be recomputed when the size changes, never carried as an offset.** This is the most persistent defect in the project, now at eight appearances and it has now happened in the tests, in three components, in `theme` itself and in the design-mock generator: something decides a size and something else draws at a position computed for the old one. The most recent was a unit printed twelve pixels inside its own reading, because the reading was resized from `SMLSIZE` to `MIDSIZE` and the unit was shifted by the reading's displacement rather than re-placed against its new end. It appeared only where the font actually changed, so two panels of the same width behaved differently and width looked like the cause. The overlap was exactly the growth minus the gap, which is what an offset held across a resize always produces.

It survives because the stale offset is usually right -- it is wrong only in the cases where something resized, which are the cases nobody renders while working. The two most recent are worth their own note, because each hid somewhere the first six did not.

The seventh was a **width estimate standing in for a measurement in a placement decision**. `theme.textWidth` over-reports on purpose, so that text shrinks rather than clips, and a generous number is the right answer to "does this fit" and the wrong one to "where does this start": half of the generosity lands in the left edge of anything centred with it. A transmitter reading sat thirteen pixels left of its slot for that reason, and ten and a half more because the width being centred was the widest string the component can ever print rather than the one on the screen. **The estimate decides whether something fits; the measurement decides where it goes**, and `lcd.sizeText` is available in both `create` and `update` because `luaLcdSizeText` touches neither the draw context nor the LCD buffer.

The eighth was found **latent, in an anchor guarding an expensive recomputation**. `followUnit` re-placed a unit only when the reading's text changed, and tested that by comparing the text's *length*. Two strings of one length are not one width -- `--` and `12` are both two characters and differ by twelve pixels at DBLSIZE, because a dash is a fifth of a line height and a digit is three sevenths -- so the unit held station across exactly the change every telemetry component makes when its sensor goes quiet. **An anchor that guards a recomputation is a place this shape hides**, because the guard is a proxy for the thing rather than the thing, and a proxy that is usually faithful is the same trap as an offset that is usually right. Anchor on the value itself: Lua interns short strings, so comparing them costs no more than comparing their lengths. The defence is not care but arithmetic: **derive the dependent position from the current value at the point of drawing**, and check the result mechanically. A collision check over every drawn label, comparing ink rectangles pairwise and against the panel edge, is cheap, catches every member of this family at once, and found this one after four other measures on the same page reported everything healthy.

**A check that would pass if everything moved together is not a check on position.** Overlap, containment and wrap are each satisfied by a uniformly displaced element, and all three passed a reading sitting 23.5 pixels outside the slot the layout rule put it in -- on a shipped dashboard, until a user looked at it. Nothing overlapped, because the displacement moved the number *away* from the battery beside it; nothing left its panel, because a panel is wider than a number; nothing wrapped, because the label was as wide as before. The rule had been implemented, and the words `slotCentres`, `slotX` and `slotsFor` appeared nowhere in the suite.

So a rule about where something goes needs an assertion about where it went, and the two are not the same kind of claim: relational checks constrain elements against each other and a positional one constrains an element against the panel. **Derive the expected position from the geometry rather than by calling the function under test** -- an assertion that restates the implementation passes for any self-consistent wrong answer, which is the failure mode already recorded above. Where a choice between arrangements has to be recovered, read it off something placed by different means: the battery's own drawn x says which slot set is in force, because a glyph is positioned from its geometry and not from a text width.

**An assertion must pin the value the contract names, not assert that something differs from something else.** "Differs from" is satisfied by every wrong answer as well as the right one, and is therefore satisfied when every value is wrong in the same way, which is precisely what happened. The same applies to "is not nil", "is greater than zero", and any assertion whose truth does not depend on the implementation at all: `contrast(a, b) >= 1.0` was in this suite for two milestones and is a tautology.

**An assertion must be about what the panel draws, not about what it computed.** This is the newest of the shapes and was found by accident. Seven assertions in this suite described the text of supporting rows on panels that shed those rows: the shipped dashboard's cell count, both link panels of the telemetry layout, a trim panel's caption, and others. Every one passed, because the component computed the row's text and then hid the label, so the string existed and was correct and was on no screen anywhere. They only failed once the component stopped doing work for labels nobody sees, which also recovered 298 instructions a frame in the header case, and 736 from the worst callback in the trim panel. The two facts are the same fact. Invisible work is work nothing is checking, and an assertion that reads state the panel does not draw is testing the component's bookkeeping rather than its output. Where a component can shed an element, assert that it sheds it, and assert the content at a span that shows it.

The hard part is that invisible work is invisible to assertions as well as to eyes: nothing about what is *drawn* can see a panel repositioning a label it has hidden, so the cost grows unnoticed and the only symptom is a number on a budget report. The harness therefore counts writes and visibility calls per object, which is its own bookkeeping and not a claim about firmware, so a test can assert that a shed row costs nothing to keep shed. Those counters are swapped out rather than branched around while a callback is measured, for the same reason property validation is: see the mock rule below. Branching cost 261 instructions of a measured callback before they were swapped, which is the same mistake as charging a Lua stand-in for a C++ call, made by the tool built to detect it.

**A document that states a contract must be executed, not read.** The layout example in this specification did not load for at least two milestones, and nobody noticed because nothing ran it: it named a setting no component declares, gave a source as a numeric identifier the telemetry service rejects, and asked `link-status` for a `4 x 3` span it does not support, so the host would have dropped that panel. Two of those three survived being corrected by hand, which is the point — reading an example carefully is not the same as running it. The suite now extracts every fenced YAML block from this file at test time and puts it through `yaml.parse`, `layout.validate`, `componentHost.resolveSettings` and, for a theme block, `theme.build`. It is extracted rather than copied into the test, because a copy is a second source of truth and would drift from the document exactly as the document drifted from the code. A block that matches no known kind fails rather than being skipped, and an extraction that finds nothing fails rather than passing over an empty string, because a test that reads a document it cannot find is a vacuous assertion wearing a new hat.

**A fixture must model what an object *is*, not only what it accepts.** This one cost a user a dashboard of error banners, and it is the narrowest shape yet. The LVGL stand-in already refused a property key `parseParam` does not accept, which models what an object accepts through `set`. Nothing modelled what the object is. An object handed back by `lvgl.*` is userdata: `LvglWidgetObjectBase::getRef` allocates one pointer with `lua_newuserdata` and attaches `lvgl_base_mt` or `lvgl_mt`, and neither metatable declares `__newindex`, so a field assigned onto a label raises and a field read off one is always nil. The stand-in was a plain Lua table, which accepts any name you invent and returns it again. So `label.headingText = text` in `primitives.header` stored the heading happily here and broke **every panel on the radio at once**, with the suite green; and `label.headingText` in `placeHeader` read back the truth here and nil there, so a reflow silently never refitted. The write was loud and the read was silent, and both came from the same wrong idea about what the fixture was standing in for. The mock now seals its objects with a `__newindex` that raises in the radio's own words, and reaches its own bookkeeping through `rawset`, which is the honest admission that `properties`, `writes` and the rest are the fixture's fields and not the firmware's. Ask of any stand-in not only *what does the real thing accept* but *what kind of thing is it*, because the second question is the one nobody asked for eight milestones.

**A comment must not explain a test's behaviour with a claim about the radio that nobody has checked.** This is the least obvious of the three and the most corrosive. A global variable test asserted that switching flight mode left a value unmoved, and explained the non-movement as EdgeTX resolving inheritance. The explanation was invented. The value did not move because the fixture ignored the flight mode argument entirely and answered the same number for every mode, so the assertion could not have failed however wrong the host was. A vacuous assertion is inert; a vacuous assertion with a confident explanation actively stops the next reader checking, because it answers the question they were about to ask. If a comment states what the radio does, it is a claim, and it carries the same obligation as a value: cite it or do not write it.

#### The evidence

| # | Defect | What the fixture encoded |
| --- | --- | --- |
| 1 | Arc drift. Every dial walked off the screen a radius per update | The LVGL mock stored the coordinates it was handed instead of modelling `LvglWidgetRoundObject`'s doubled subtraction, so it could not see an object move |
| 2 | An unbounded loader that broke on any layout over twelve components | The budget test measured the shipped five-component layout against a ceiling it used a third of |
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

Status last verified on 2026-09-18:

| Work item | Status | Implemented | Remaining |
| --- | --- | --- | --- |
| Build and test foundation | Complete | Make targets, isolated Python environment, unit/integration suites, EdgeTX Lua parsing, tracked simulator fixture, reproducible `build/sdcard` assembly, and GitHub Actions CI running `make check` against Lua 5.3 | None |
| Milestone 1: Runtime skeleton | Complete | LVGL host, integer 4 x 4 geometry, gutters, per-component containers, batched reflow, App mode fixture, and `1 x 1`-sized mocked tests | Additional physical-radio verification belongs to hardening |
| Milestone 2: Read-only YAML loader | Complete | Constrained parser, empty flow collections, schema version check, model/Dashboard ID resolution, default fallback, fail-closed document validation, per-entry validation, preserved unknown keys, optional theme block, and a malformed-input matrix | Physical-radio verification belongs to hardening |
| Milestone 3: Component runtime | Complete | Referenced-module loading, metatable-safe contract validation, declared settings with typed defaults, `supportedSpans` enforcement, host-owned containers, declared refresh intervals with phase staggering, and isolated create/update/refresh/background/event/destroy dispatch | Production components arrive in milestones 6 and 7 |
| Milestone 4: Design system | Complete | Semantic tokens, panel/typography/bar/radial/badge primitives, Modern, Follow EdgeTX, and Custom modes, guaranteed-legible derived palettes, all seven states, and one shared responsive ladder deciding composition from the box and the font from the composition | Physical readability review at 480 x 272 on a TX16S-class display |
| Milestone 5: Shared data services | Complete | Registry with per-service intervals, staggering, and subscription caps; telemetry, model, control, extrema, and navigation services; immutable snapshots; graceful degradation for missing sources, unseen sensors, absent firmware APIs, and stale telemetry; `service-probe` diagnostic views and two shipped diagnostics layouts | Hardware verification, and timer-based extrema reset |
| Milestone 6: Core components | Complete | `metric` with `custom`/`altitude`/`speed` presets, source and flight extrema, and a secondary reading; `flight-timer`, `flight-mode`, `tx-battery`, `variable-indicator`, `trim-panel`, and `model-identity`; width-aware font fitting, shared panel frame and header geometry, bipolar bars with neutral markers, and images; a shipped dashboard demonstrating all seven | Physical-radio verification of estimated text widths and of model bitmap scaling |
| Milestone 7: Telemetry-specialized components | Complete | `cell-battery` with cells-table validation and a usable-range bar; `link-status` with independent RSSI and quality sources, a published link view, and explicit no-sensor/no-link states; `navigation` with four responsive presentations and a north-up dial; centre-positioned arcs, the `compass` primitive, and a shipped dashboard demonstrating all ten components | Hardware confirmation of the cells shape and of no-RSSI-sensor detection |
| Milestone 8: The App mode menu button and multiple screens | Complete | Dashboard ID option, per-model/per-dashboard filename resolution, dashboard-scoped layouts shared by every model, panels laid out around the App mode menu button through the shared frame, an error overlay that clears it, notices separated from errors, and two-instance and model-change coverage | Status rail deferred by decision, not outstanding; simulator confirmation of the corner on a radio |
| Milestone 9: Hardening | In progress | Unit/integration tests, firmware-like string behavior tests, CI running Lua 5.3 parsing, simulator fixture, corrupt-layout, contract-rejection, hostile-module, and legibility coverage, component failure isolation, an enforced instruction budget measured at the largest legal layout for both components and services, diagnostic views over every service, and a host diagnostics view on its own screen | Target-radio matrix and physical-radio testing |
| Milestone 10: On-radio editor | Not started | None | Entire phase 2 editor and write/recovery workflow |
| Presentation and consistency pass | Complete | An audit of every component at every declared span measured through the real host, then: the panel as a card with a clipped accent stripe, alert states tinting the surface instead of the frame, the badge vocabulary cut from thirteen strings to five, header geometry that never reflows on a state change, one shared responsive ladder replacing eight private copies, a render declaration the redraw comparison is derived from, one settings vocabulary with enforced `choices`, and `trim-panel` no longer drawing what it hides | Six items deliberately set aside, listed under [Deliberately set aside](#deliberately-set-aside); none of it seen on a radio |

The design system is in place: the host owns every color, resolves one theme per dashboard, and hands each component a `services` table carrying the theme, shared primitives, span-appropriate typography, a state resolver, and the five shared data services. The `metric` component is the reference implementation and now reads real telemetry; the temporary `demo` setting is gone. Milestone 4's remaining item is a physical readability review, which requires hardware.

Measured cost on the largest layout the schema permits, sixteen single-cell components: worst callback 7518 of 20000 instructions, worst steady frame 2520. Both are asserted by the test suite. Fourteen layouts are exercised, thirteen of them at sixteen components: metrics with sixteen distinct live sources, sixteen diagnostic panels spanning all five services, sixteen components that demand a refresh every frame, one layout per catalogue component type, and the shipped ten-component dashboard.

**The worst callback is the staged loader, not any component's own work.** It is the callback that builds one `trim-panel` with four indicators, at 7509. Every layout's second-worst is the loader's header stage, between 6209 and 7361. The three telemetry components at sixteen cells reach 6721, 6593 and 6337, all of them in that header stage, and their worst steady frames are 2290, 2380 and 2562. Removing the services' subscription caps raises the worst steady frame to 6200, which is what the caps are for. On a full grid, component work is no longer the binding constraint, which is worth knowing before optimising a panel.

### Aircraft-reported state: deferred, with the research kept

**The dashboard shows nothing the aircraft reports about its own state.** `flight-mode` shows EdgeTX's own flight modes — the transmitter's up-to-nine mixer modes, each with its own trims, selected by a switch and named in Model Setup. `luaGetFlightMode` returns `mixerCurrentFlightMode` and `g_model.flightModeData[mode].name` (`radio/src/lua/api_general.cpp`), so it is transmitter-side and needs no telemetry at all. `variable-indicator` uses the term in the same sense, because a global variable holds one value per mode.

It is **not** arming state, not the flight controller's mode — Angle, Acro, Horizon, Rescue — and not gyro or stabilisation state. Those live on the aircraft and can only arrive as telemetry, and no component reads them. That is a gap in the catalogue rather than a decision, and it is recorded here so it can be seen without being noticed as an absence.

A component for it is **deferred, not rejected**. The condition for revisiting is the component-by-component review pass over the existing eleven being complete. The research is below because it is the expensive part and would otherwise be redone.

**What the radio actually publishes.** This table is the design constraint: the same sensor name carries a different shape on different links.

| Protocol | Flight mode | Arming | Evidence |
| --- | --- | --- | --- |
| Crossfire / ELRS | `FM`, `UNIT_TEXT` | none | `CS(FLIGHT_MODE_ID, 0, STR_SENSOR_FLIGHT_MODE, UNIT_TEXT, 0)`, `telemetry/crossfire.cpp`; frame `0x21`, `telemetry/crossfire.h` |
| Spektrum | `FM`, `UNIT_TEXT` | none | `SS(I2C_PSEUDO_TX, 8, uint32, STR_SENSOR_FLIGHT_MODE, UNIT_TEXT, 0)`, `telemetry/spektrum.cpp` |
| FlySky AFHDS2A | `FM`, `UNIT_RAW` — a mode **index** | `Arm`, `UNIT_RAW` | `telemetry/flysky_ibus.cpp` |
| FrSky S.Port | absent | absent | no entry in `telemetry/frsky_sport.cpp` |

`STR_SENSOR_FLIGHT_MODE` is `"FM"` and `STR_SENSOR_ARM` is `"Arm"` (`telemetry/sensor_names.h`). A text sensor's value is capped at `TELEMETRY_SENSOR_TEXT_LENGTH`, which is 16, and EdgeTX stores a hash of the string in the numeric slot "so changes can be detected quickly" (`telemetry/telemetry_sensors.cpp`). Lua receives the string itself, not the hash: `case UNIT_TEXT: lua_pushstring(L, telemetryItems[...].text)` (`radio/src/lua/api_general.cpp`). `getFieldInfo` reports the unit for a telemetry source, so a component can tell a text sensor from a numeric one before reading it.

**Arming is not separately published on ELRS.** The only `Arm` sensor EdgeTX defines is FlySky's. Flight controllers are understood to encode arming inside the `FM` string, but **that vocabulary is the flight controller's and is not in the EdgeTX tree**, so a component that recognised specific mode strings would be designed against a guess. That is the fixture-discipline mistake in a new place, and it is the single most important thing recorded here.

**The proposal, if it is built.** A component that displays any `UNIT_TEXT` sensor and lets the *layout* map strings to states — `critical: "!ERR"` — rather than an "aircraft mode" component with a built-in vocabulary. The vocabulary then lives where someone who knows their flight controller can state it, and the component is honest about what it knows: it shows the string the aircraft sent.

`metric` cannot absorb this. It formats a number to a precision and normalises it to a range; thresholds, extrema and `fraction` are all meaningless for text, and its ladder sizes the reading from the widest **numeric** form with a unit riding beside it, which a string has no equivalent of. Fitting text into it would make one name cover two components, which is what the settings vocabulary work undid.

**Groundwork already in place.** The telemetry service maps `UNIT_TEXT` to a `text` kind and holds the string in `raw` with no numeric value. That path existed and had never been exercised by anything, so the test fixture now carries an `FM` text sensor and the service's handling of one is covered, including the common case of the sensor being absent. That is worth having whether or not the component is ever built.

### The host diagnostics view

Nothing in this project has ever run on a radio. When it does and something looks wrong, the only evidence available is pixels, and inferring from pixels is what cost an evening on an arc drifting by its own radius and another on a radio running bytecode that was no longer on the card. The `host-diagnostics` component exists so a hardware session can answer "what is loaded and what did it resolve to" by reading it instead of deducing it.

It ships as four sections, one per panel, on the `host` dashboard:

| Section | Answers |
| --- | --- |
| `identity` | Widget version, `main.lua`'s size and modification time, **whether a `main.luac` is sitting beside it**, which of the three candidate filenames answered, the full path, and the model name the path was derived from |
| `theme` | The resolved mode, whether the layout or the widget option asked for it, whether a mode that does not exist fell back to Modern, and every notice the theme recorded |
| `components` | One line per placement: id, type, span, and whether it built, failed later, or was rejected before it built |
| `sources` | One line per telemetry source any panel asked for, spelled as the layout spelled it, and whether it bound |

**It reads the live host context and re-derives nothing.** A diagnostics view that resolved the layout filename a second time, or rebuilt the theme to see what it would say, would be reporting on a world assembled for it rather than the one the dashboard is running, and would be confidently wrong at exactly the moment it is being trusted. That is the same mistake as a fixture that encodes what we assume. Where a fact was not recoverable afterwards, the host now records it where it is decided rather than letting the view guess later, and each of those was a guess the view would otherwise have had to make:

- `layoutStore.read` reports **which** of the three candidate names answered, not only the path it settled on. A dashboard called `main` on a model called `main` produces two candidates that read alike, and a layout quietly falling back to `default.yaml` looks exactly like one that was found.
- `context.themeSource` records whether the layout's own block or the widget option chose the mode. The option was inert for a while while looking identical to a working one.
- `theme.build` reports the mode it was **asked** for beside the one it settled on, because a fallback to Modern reports `modern` and is otherwise invisible.
- `context.rejected` holds placements that never built, with the reason. A component that raises during `create` is discarded and is not in `components` at all, so before this the view could have reported every panel that works and no panel that does not, which is the wrong half.

**The bytecode line is the one that earns the view.** EdgeTX compiles a `.luac` beside every script it loads and prefers it afterwards, so a radio can run code that is no longer on the card; that is constraint 10 and it cost hours. `make build` deletes the bytecode, but a card assembled any other way will not have. `fstat` reports `{size, attrib, time}` and nothing at all for a file it cannot stat (`luaFstat`, `radio/src/lua/api_filesystem.cpp`), so the view stamps the source and says plainly when a `.luac` is beside it — in which case the timestamp shown is not the code that is executing.

**Reachability.** It is a component on its own dashboard, reached by paging like everything else. It cannot be a widget setting: in App mode `Widget::openMenu` returns before opening anything, so the settings menu is unreachable from the main view, which is precisely where somebody diagnosing a dashboard is standing.

**Cost.** Nothing when it is not showing, because a component no layout places is never loaded. When it is showing it builds a fixed number of line objects, so its build cost does not depend on how much there turns out to be to say, and repaints only the lines whose text changed. Sixteen panels of it — the worst the schema permits — peak at 6215 instructions, in the loader's header stage rather than in the component; the component's own worst stage is 4509 against `trim-panel`'s 7518. It does not become the worst callback.

**Panels shed lines.** A two-cell panel shows about five, so each section is ordered by what someone is there to find: the bytecode alarm above the layout path, failures above the roll call, unbound sources above bound ones, and a count on the first line that says whether anything was shed. A list that pushes the one broken component off the bottom is worse than no list.

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
writes, in `primitives.header`, which is why eleven of twelve components never
touched it and could not have got it right or wrong. Fixing the host fixed
eleven components. The two that rewrite their heading at runtime go through
`primitives.setHeading`, and a test forbids writing it directly.

**This is detectable rather than unrepresentable, and that is worth saying.**
The render declaration made its mistake impossible: a component cannot compare
a field it never declared, because the host derives the comparison. The same
move is not available here, because the host does not own paint -- a component
holds its own LVGL objects and calls `set` on them. Making this
unrepresentable would mean the host owning drawing as well as deciding, which
is a much larger change than this defect justifies. Detectable is what is
available: the host writes the heading, and a directory-reading test fails on
a component that writes its own.

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

It was 4, nothing had ever measured it, and it made a reflow the most expensive callback in the dashboard. It is the only per-callback cost the dashboard chooses rather than earns, so it was worth measuring properly rather than assuming a smaller number is better.

Measured at single-instruction resolution on sixteen `trim-panel` components, the largest layout the schema permits using the most expensive component to reposition:

| Batch | Worst reflow callback | Callbacks to settle | Total reflow work | Headline worst callback |
| --- | --- | --- | --- | --- |
| 1 | 2280 | 16 | 34641 | 7509 |
| 2 | 4364 | 8 | 34057 | 7509 |
| **3** | **6448** | **6** | **33911** | **7509** |
| 4 | 8532 | 4 | 33765 | 8532 |
| 5 | 10616 | 4 | 33765 | 10616 |
| 6 | 12700 | 3 | 33692 | 12700 |
| 8 | 16868 | 2 | — | exceeds the suite's ceiling |

**The relationship is linear and the per-callback overhead is negligible.** Each step adds exactly 2084 instructions, which is what one `trim-panel` costs to reposition, and the intercept is 196. So a batch of *n* costs `2084n + 196`, and the overhead the schema pays for splitting the work is under a tenth of one component. Total reflow work is 2.6% higher at a batch of 1 than at 4, which is that overhead paid sixteen times instead of four.

**Three is where the saving stops.** Below it the headline does not move at all, because the binding constraint becomes the loader building one component at 7509, and no batch size affects that — the component stage already builds one component per callback. A batch of 2 or 1 therefore settles a reflow more slowly and buys nothing.

**What it costs is passes.** Sixteen components settle in six callbacks rather than four. `MainWindow::run` calls `ViewMain::refreshWidgets` once per `MENU_TASK_PERIOD`, which is 50 ms (`radio/src/tasks.cpp:50`), so a full reflow takes about 300 ms rather than 200. A reflow runs only when the host zone moves or resizes — a screen change or a dashboard change — so the extra 100 ms is spent at a moment nobody is reading a value.

**The headroom is the real argument, not the 12%.** Both 8532 and 7509 are comfortable against 20000. But reflow is the only per-callback cost that multiplies one component's work by a constant, which makes the constant the cheapest protection against a future component being expensive to move. At 4, a component costing 3750 instructions to reposition breaches the suite's ceiling; at 3 it takes 4935 to do the same.

The suite asserts the conclusion rather than the number: **a reflow may not be the most expensive callback the dashboard makes.** That comparison fails at a batch of 4 and at 5, which a fixed ceiling chosen today would not have done, and it is paired with an assertion that a reflow was measured at all — without which a zero compares less than everything and the whole check passes having proved nothing. That hole was real and was found by breaking the recording and watching the comparison stay green.

This question is closed. Re-open it only with a measurement.

**Why a `trim-panel` reflow is the most expensive of them, and why that
stays.** It is not a defect and not worth optimising further. Reflow is
batched three components to a callback, so the figure is three `update` calls
plus the host's own work. At sixteen cells a `trim-panel` showing one
indicator costs 872 instructions to reposition, which sits in the middle of the catalogue
between `cell-battery` at 769 and `model-identity` at 902. Showing four costs
1798. The excess is entirely the three extra indicators, at 309 each, and each
indicator is a caption, a bipolar bar of three objects and a readout. A panel
that draws four readings repositions four readings' worth of geometry. There
is no shared mechanism left for it to adopt: it goes through the panel frame,
the header, the render declaration and the shared `reconcile` like everything
else.

That was established by measurement after removing the part that *was*
accidental. The panel used to hide the caption and readout rows a narrow cell
cannot fit, and then keep positioning them on every reflow, formatting them
four times a frame, and writing them into labels nobody could see: about 740
instructions of work with no reader, which took the worst callback from 9268
to 8532 when removed, before the batch measurement took it to 6448. Invisible
work is the hazard here, because it leaves no
trace on screen and so no assertion about what is drawn can see it. The test
harness counts writes and visibility calls per object for exactly that reason,
and those counters are swapped out while a callback is measured, on the same
grounds as property validation.

The worst steady frame rose from 2000 to 2400 with milestone 7, on sixteen
`link-status` panels, which is the component that reads the most per refresh:
two sources, a minimum, and the link view. A component's declared refresh
interval, not its size, is what decides steady-state cost: `cell-battery`
walks its cells table on every refresh and declares 20 ticks for it, and
`navigation` declares 25 because telemetry GPS never arrives faster. It is
now 2562 on sixteen `navigation` panels; `trim-panel` held it until it
stopped formatting four readouts a frame that its cells had no room to show.

### Component module contract

A component file under `components/<type>.lua` returns a table describing itself:

| Field | Required | Purpose |
| --- | --- | --- |
| `id` | Yes | Must equal the `type` name used in YAML, so a renamed file cannot load silently. |
| `apiVersion` | Yes | Must equal the host component API version. Anything else is rejected visibly. |
| `create(parent, rect, settings, services)` | Yes | Builds LVGL objects and returns the component's own context. |
| `supportedSpans` | No | Span strings such as `"2x1"`, or `"any"`. Absent means every span is accepted. |
| `settings` | No | Declared `{key, label, type, default}` entries. Absent and mistyped YAML values fall back to the default. |
| `update(instance, rect, settings)` | No | Applies changed geometry or configuration. |
| `refresh(instance)` | No | Runs once per visible host cycle. |
| `background(instance)` | No | Runs while the dashboard screen is not visible. |
| `event(instance, event)` | No | Returns true when the event is consumed, which stops propagation. |
| `destroy(instance)` | No | Runs before the host tears the component down. |

The host creates one LVGL container per placement and passes it as `parent`, with a container-local rectangle starting at the origin. A component therefore cannot draw over a neighbour or reach the dashboard root. Contract fields are read with `rawget`, so a module with a raising `__index` cannot break the host.

Every callback is dispatched under `pcall`. The first failure permanently disables that one component and reports it, so a broken module cannot repeatedly raise or disable the surrounding dashboard. A component that fails during `create` has its container cleared, leaving no partial drawing behind.

### Measuring text, against estimating it

`lcd.sizeText(text, flags)` returns the real rendered width. `luaLcdSizeText` calls `getTextWidth`, which is `lv_txt_get_width(s, len, getFont(flags), 0, LV_TEXT_FLAG_EXPAND)` -- a sum of the font's own per-glyph advances. Three properties make it usable from a widget rather than only from a paint: it carries **no `luaLcdAllowed` or `luaLcdBuffer` guard**, alone among the drawing entry points in `api_colorlcd.cpp`, because it touches neither; our size constants **are** the flags it wants, since `SMLSIZE` is `FONT(XS)` and `getFont` indexes on exactly that; and the font it consults is decompressed once and cached by `decompressFont`, so a call is a C loop over the string rather than a decode.

**The estimate is 0.58 of a line height per character, and it is generous by design.** That is right for deciding whether something fits -- erring that way shrinks text that would have fitted rather than clipping text that does not -- and wrong for deciding where something starts, where the generosity is simply a gap. Against the real advances of `lv_font_en_STD.c`, the one font in the tree whose `glyph_dsc` is uncompressed:

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
- **What it would change.** Across seven components at every span they declare, **17 of 112 pairs would resolve to a larger font**, every one of them larger and none smaller, which is what removing generosity predicts. `flight-timer` gains a size at nine spans and `navigation` at seven. Those are improvements, but they are visible ones, and they would arrive across the whole catalogue at once.
- **What it would not fix.** The mock cannot reproduce the radio's advances exactly. It models them from `lv_font_en_STD.c`, the one font whose `glyph_dsc` is uncompressed in the tree, and applies that one font's proportions to every size; the bold faces in particular are wider on a radio than in the harness. What that buys is the thing that matters, which is that the harness **disagrees with the estimate** -- `7.9` is 22 pixels there against the estimate's 37 -- so a test can tell a measured placement from an estimated one. A model that merely repeated the estimate could not, and the placement defect that reached a user's screen would have been invisible to the suite either way.

**Correction to a claim that stood here and was wrong.** This section previously said the compressed advances "are not readable from source at all". They are. EdgeTX's `lz4_fonts.h` states that `glyph_dsc` sits at offset zero of the compressed payload, with `uncomp_size` and `glyph_bitmap` declared beside the blob; extracting `lv_font_en_XS`'s array and decompressing it as an LZ4 block against the declared size yields the advance table directly, first attempt, and `adv_w` in sixteenths is the same number `lv_txt_get_width` sums. Building a fixture from that is a morning's work and the result would be exact rather than modelled.

It is not worth doing yet, and the reason is worth stating so nobody does it out of tidiness. The `STD`-derived model is adequate for everything the harness is asked to do, because what the suite must catch is wrong arithmetic rather than the radio predicted to the pixel, and it already distinguishes the two width sources that matter. **The one case it cannot settle is a fit landing within a pixel or two of a font-step boundary**, where the harness and the radio could choose different sizes. That risk is narrow and bounded, and if it ever bites, the door is open and this paragraph is how to walk through it.

The decision is the user's. What is recorded here is that the measurement exists, that it is reachable, and what it costs.

### Instruction budget

EdgeTX aborts any widget callback that exceeds **20000 Lua VM instructions**, raising `CPU limit` (`radio/src/lua/widgets.cpp`). Building a full dashboard costs far more than that, so the host never loads in one call. `create` only loads runtime modules and the root container, then `refresh` advances a staged loader one step per call:

1. `read` — resolve and read the layout file.
2. `tokenize` — convert the text into indentation tokens.
3. `parse` — build the document, validate it, and resolve the theme.
4. `components` — instantiate exactly one component, repeated until done.

Every stage is bounded by a fixed amount of work rather than by the size of the layout: the file is tokenized a fixed number of lines per call, and each component is parsed, validated, and built in its own call. A zone change is batched the same way. A layout that fills the grid therefore costs more callbacks, never a larger callback.

The regression test measures every callback with a 200-instruction count hook, mirroring the firmware, and fails if any exceeds 75% of the budget. It exercises **the largest layout the schema permits**, sixteen single-cell components, not just the shipped one. Measuring only the shipped layout previously hid a loader that passed on five components and failed on twelve.

Component authors must respect the same ceiling: `create`, `update`, `refresh`, `background`, and `event` each run inside the host's callback and share its allowance. Avoid per-character string loops, which are the most common way to exhaust it.

**Anything the harness does to observe must be excluded from what it measures, and a number that moves when only the harness changed is the harness.** This has now caught the instrument charging us for its own work three times: property validation standing in for `parseParam`, which is C++ and free on a radio; the per-object write and visibility counters, which cost 261 instructions of a measured callback while they were branched around rather than swapped out; and sealing every object against field assignment, which a radio's userdata is already and pays nothing to become, and which cost 276 of the worst callback and 126 of the steady frame before it was moved behind the same switch. The last of those was very nearly reported as a regression in the widget. Before attributing a movement to the code, change nothing in the code and see whether it still moves.

Current figures are in **Current cost**, and they are measured with the count hook set to every instruction rather than every 200, because the 200-instruction hook the firmware uses rounds a reading to the nearest 200 and hides exactly the size of change most of this work produces.

Shared data services share the same allowance, and are bounded the same way. The test measures three sixteen-component layouts: metrics with sixteen distinct live telemetry sources, sixteen diagnostic panels spanning all five services, and sixteen components demanding a refresh every frame. Each exercise declares which services it must actually run, and the test fails if one of them never updated during the sampled frames, so a layout that quietly subscribed to nothing cannot make the service layer measure zero.

##### Refresh scheduling

EdgeTX refreshes widgets on every main loop pass, so steady-state cost is paid tens of times per second and is shared by every component on the dashboard. Two mechanisms keep it bounded.

A component declares `refreshInterval`, in 10ms ticks, stating how often it actually needs servicing. A numeric telemetry readout is indistinguishable at 5 Hz and 50 Hz in flight, so `metric` declares 20 ticks, where the `heartbeat` fixture, which animates, declares 10. Absent or zero means every frame.

Components that share an interval are then **phase staggered**: each is assigned an offset derived from its position in the layout, so they fall due on different frames instead of all at once. Staggering preserves each component's exact declared rate, which simple batching would not.

A per-frame dispatch cap is retained as a guarantee for layouts that defeat staggering, such as many components all asking to refresh every frame. The cap serves components in rotation so none is starved, and a component delayed by the cap does not accumulate a backlog of missed deadlines.

### Masking with a container

EdgeTX exposes no masking primitive to Lua, but it does not need to: **a container clips its children to its own rectangle, so a box is a rectangular mask.**

`lv_refr.c`'s `refr_obj` intersects the clip area passed to an object's children with that object's coordinates, and keeps the original area only when the object carries `LV_OBJ_FLAG_OVERFLOW_VISIBLE`. EdgeTX never sets that flag anywhere outside the LVGL submodule, so every child of every `lvgl.box` the dashboard creates is already clipped to it. Where the intersection is empty the children are skipped entirely.

This is what lets the panel accent be drawn as shapes that are deliberately too large and then trimmed, rather than as shapes computed to fit. A quarter-circle band whose outer edge is the panel's own corner curve is easy to state exactly and impossible to express as a rectangle; clipping it to a column one accent width across turns it into the tapering corner the design asks for, without any arithmetic that could drift.

Two limits are worth knowing. The mask is rectangular: `lv_obj_set_style_clip_corner` would clip children to a parent's *rounded* corners, but EdgeTX neither calls it nor exposes it, so a rounded mask is not available. And the container must be resized with whatever it masks, because a stale mask either clips away part of a panel that grew or fails to clip a band on one that shrank.

The container itself paints nothing, which is hard-won constraint 2 read in the dashboard's favour: `LvglWidgetBox::build` creates a bare `lv_obj` and its `setColor` is the base class's empty virtual. A mask that asked for a colour would be relying on that silence, so it asks for none.

### Painting backgrounds

EdgeTX's `lvgl.box` accepts a `color` parameter and silently ignores it: `LvglWidgetBox::build` creates a bare `lv_obj` and, unlike `LvglWidgetBorderedObject`, never applies the color as a background. A box therefore keeps the radio theme's own styling, so a dashboard drawn on boxes renders in EdgeTX's palette rather than its own, and the radio's screen background, including its logo, remains visible behind it.

Every visible surface must be a **filled `lvgl.rectangle`**. Boxes are used only as unpainted containers for grouping and clipping. A regression test asserts that the dashboard canvas and every component panel background is a filled rectangle, and that no box relies on a `color` parameter.

### Services passed to components

| Key | Purpose |
| --- | --- |
| `theme` | Resolved theme with `rgb` (24-bit), `color` (display values), and `spacing`. |
| `primitives` | Shared panel, label, value, bar, radial, and badge builders. |
| `fonts` | Typography roles chosen for this component's span. |
| `span` | The component's `colSpan` and `rowSpan`. |
| `state(name, accent)` | Resolves a state name into concrete colors, border weight, and badge text. |
| `telemetry` | Cached source readings with units, precision, and freshness. |
| `model` | Model identity, bitmap path, timers, flight mode, and transmitter voltage. |
| `control` | Effective trim positions and read-only global variables. |
| `extrema` | EdgeTX sensor extrema and dashboard flight sessions. |
| `navigation` | GPS fix, pilot position, distance, and north-up home-to-model bearing. |

Any data service may be absent when its module failed to load, so a component must tolerate `nil` rather than assume.

### Subscribing to a service

A component subscribes once, in `create`, and keeps the returned snapshot for its lifetime:

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

Subscribing in `create` is not a convention, it is the mechanism: a source nothing subscribed to is never read. Two components naming the same source share one subscription and therefore one poll.

| Service | Subscription | Snapshot highlights |
| --- | --- | --- |
| `telemetry` | `subscribe(name)`, `link()` | `value`, `raw`, `kind`, `unit`, `unitText`, `precision`, `state`, `available`, `fresh`, `stale`, `age`; `live`, `rssi`, `indicator` |
| `model` | `identity()`, `timer(index)`, `flightMode()`, `txVoltage()` | `name`/`bitmapPath`; `value`, `countdown`, `elapsed`, `remaining`, `expired`, `text`; `index`/`name`; a telemetry-shaped reading |
| `control` | `trim(name, scale)`, `globalVariable(index, flightMode)` | `raw`, `value`, `fraction`, `scale`, `centered`, `threePosition`; `name`, `value`, `min`, `max`, `precision`, `unitText`, `flightMode` |
| `extrema` | `sourceExtreme(name, mode)`, `sessionExtrema(name)`, `flight(armSource)` | an ordinary reading of `<name>-`/`<name>+`; `min`, `max`, `samples`, `session`; `armed`, `active`, `count`, `duration` |
| `navigation` | `subscribe(name, distanceSource)` | `fix`, `home`, `latitude`, `longitude`, `pilotLatitude`, `pilotLongitude`, `distance`, `distanceUnit`, `distanceSource`, `bearing`, `age` |

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

Modern uses the specified palette verbatim. Follow EdgeTX derives tokens from `lcd.getColor()` (which returns RGB565) and Custom applies a limited override set over Modern. Both derived modes then pass through a legibility pass that guarantees minimum contrast for body, muted, and faint text, for panel elevation and borders, and for every semantic accent. Critical red is never theme-derived. The dashboard never calls `lcd.setColor()`.

A layout file may carry an optional `theme` block, which takes precedence over the native Theme widget option. A layout that omits it defers to that option, which is how one layout is carried on two screens under two palettes: the shipped `states` layout states no theme, and the tracked model gives its two screens `modern` and `edgetx`. Everything else about the two pages is identical because it is the same file, which is what makes the palettes comparable rather than merely both present.

```yaml
theme:
  mode: custom
  overrides:
    canvas: 0x000000
    surface: 0x101010
    accent: green
```

### Phase 1: YAML-configured dashboard

Phase 1 reads externally authored YAML and never creates, edits, migrates, or rewrites layout files on the radio.

#### Milestone 1: Runtime skeleton

- Register one LVGL dashboard host widget with a native Dashboard ID option.
- Implement grid rectangle calculation and nested LVGL component containers.
- Render a hard-coded 4 x 4 arrangement of labeled placeholder components.
- Respond correctly when the host zone changes.
- Verify App mode as the primary deployment and ordinary `1 x 1` as the fallback.

Deliverable: a runnable dashboard whose placeholder panels occupy stable configured spans.

#### Milestone 2: Read-only YAML loader

- Implement the constrained schema-versioned YAML parser.
- Resolve `<model-identifier>--<dashboard-id>.yaml` and fall back to `default.yaml`.
- Validate component IDs, safe type names, coordinates, spans, overlap, and supported schema version.
- Preserve unknown keys in memory for forward compatibility.
- Render visible placeholders for invalid entries without preventing valid entries from loading.
- Keep all layout file access read-only.

Deliverable: changing YAML rearranges the complete dashboard without changing Lua code.

This is the first architecture checkpoint. Further component work should not begin until two separately loaded placeholder components render from YAML in both App mode and `1 x 1`.

#### Milestone 3: Component runtime

- Load only referenced component modules with `loadScript()`.
- Finalize component metadata, API version, lifecycle callbacks, settings schema, and supported-span declarations.
- Support bundled modules and compatible user-copied modules under `components/`.
- Reject incompatible API versions and unsafe module names visibly.
- Isolate component creation and refresh failures so one component cannot disable the dashboard.

Deliverable: independently authored component files run together under a stable host contract.

#### Milestone 4: Design system

- Implement semantic theme tokens and shared panel, typography, spacing, bar, radial, and state primitives.
- Implement Modern, Follow EdgeTX, and limited Custom theme modes.
- Implement normal, stale, unavailable, warning, critical, and selected states.
- Establish responsive presentations for `1 x 1`, `2 x 1`, and `2 x 2` spans before expanding to unusual spans.
- Verify physical readability at 480 x 272 on a TX16S-class display.

Deliverable: one polished metric component demonstrating every state, theme mode, and baseline span.

#### Milestone 5: Shared data services

- Implement `telemetryService` for cached values, units, precision, and freshness.
- Implement `modelService` for identity, bitmap, timers, flight mode, and transmitter voltage.
- Implement `controlService` for effective trims and read-only global variables.
- Implement `extremaService` for EdgeTX extrema and arm-switch flight sessions.
- Implement `navigationService` for GPS fix, pilot position, distance, and north-up home-to-model bearing.
- Update each service once per host cycle and expose immutable snapshots to components.

Deliverable: diagnostic views prove normalized service output independently of final component rendering.

Delivered. The `service-probe` component renders any service's normalized output as label and value rows, and two layouts ship: `services.yaml` for telemetry and navigation, `services2.yaml` for model, control, and extrema. Both load from their Dashboard ID alone, on any model.

The cadence is deliberate rather than "once per host cycle" literally. Polling five services on every cycle was measured and rejected: at most one service is updated per cycle, services are phase staggered on registration, a service nothing subscribed to is never scheduled, and each service caps how many subscriptions it refreshes in one update. A component still sees one consistent set of readings per cycle, because services update before component refreshes.

#### Milestone 6: Core components

Implement these components in order:

1. `metric`
2. `flight-timer`
3. `flight-mode`
4. `tx-battery`
5. `variable-indicator`
6. `trim-panel`
7. `model-identity`

This order establishes value formatting, source access, model APIs, bars, radial indicators, trim semantics, GV formatting, and bitmap handling before the more protocol-sensitive components.

Deliverable: seven responsive components operating from YAML configuration.

Delivered. All seven ship, every one of them driven entirely by YAML and by the shared services, and the shipped `layouts/default.yaml` demonstrates all of them on one screen.

Three shared additions came out of the work rather than being planned:

- `theme.frame` resolves the padded content geometry, header row, and badge column that every panel shares, so a badge cannot land on the label it accompanies and two components cannot disagree about where a header sits. Widening a narrow panel's badge past half its content width was a real defect this found.
- `theme.textWidth` and `theme.fitText` fit a reading by measured width as well as height. This closes milestone 6's carried-forward item about a `1 x 1` metric whose value was only checked vertically.
- `primitives.bipolarBar`, an optional centre marker on `primitives.bar`, and `primitives.image` cover the three shapes the new components needed and the earlier catalog did not.

Milestone 7 added two more, both about arcs:

- `primitives.compass` draws a north-up bearing dial. The ring is the arc's background and the pointer is its indicator, so one LVGL object carries both, and a bearing that does not exist hides the pointer by setting its opacity to zero rather than resting it at north, which would read as a real due-north fix.
- `primitives.arcBounds` was added here to convert an arc's centre into the rectangle it occupies. It has since been deleted: no component ever called it, its only callers were tests, and it was wrong — it put the outer edge half a stroke too far out, which nothing noticed because the only thing checking it repeated its arithmetic. The tests now measure the arc the mock actually drew.

Two specification details were corrected by the implementation, and both are recorded where they belong: model bitmaps cannot use `Bitmap.open()` under LVGL, and a `metric` preset cannot be expressed as a settings default.

#### Milestone 7: Telemetry-specialized components

Implement these components in order:

1. `cell-battery`
2. `link-status`
3. `navigation`

- Validate cells-table and GPS-table value shapes.
- Handle protocol-dependent RSSI and link-quality source selection.
- Test telemetry disconnect, reconnect, stale data, missing GPS fix, and unavailable home position.

Deliverable: the full ten-component catalog with graceful telemetry degradation.

Delivered. All three ship, and `layouts/default.yaml` now demonstrates the
complete ten-component catalogue on one screen.

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

Protocol-dependent source selection is a component setting, not a heuristic.
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

`theme.frame` already owns the padded content geometry, the header row and the badge column, and all ten catalogue components take `frame.top` and `frame.pad` from it. Giving it the obstructed corner therefore fixes every component at once, in the place that exists to prevent them disagreeing, and is not the "every component compensating individually" this specification rejects. The header label moves to the right of the button rather than below it, which would cost a whole row, and the content start moves below it. The panel keeps its whole rectangle and the grid keeps its geometry.

The corner reaches the frame through the theme builder each component is handed, rather than through a new argument on every component, so a component written by someone else is laid out correctly without knowing any of this exists. It is read on each call rather than captured, so a zone that moves is picked up by the update that follows it.

The reading gets larger rather than smaller. With the dial shrunk to suit the reduced height, the shipped dashboard's distance is chosen at `MIDSIZE` where it was previously `SMLSIZE`.

A `1 x 1` cell in that corner cannot be saved, and no approach saves it. Its reading survives, pushed below the button, and its header label is dropped rather than clipped to the four pixels left beside the badge. Avoid placing a single-cell component in the top-left of an App mode layout.

The error overlay was subject to the same problem and was fixed first. It was drawn at (8, 8), so in App mode a component could fail, the host could report it, and the radio would show nothing.

##### Why there is no status rail

This milestone originally specified a dashboard-owned status rail carrying model name, flight mode, transmitter voltage, link state, clock and active timer. It is deferred, not cancelled, and the reasoning is recorded here so it is not re-litigated from scratch.

EdgeTX's own top bar is already a configurable widget rail. `TopBar` is a `WidgetsContainer` over `{0, 0, LCD_W, MENU_HEADER_HEIGHT}` with per-model configurable zone widths, it accepts any widget, and `TopBar::getZone` already starts its zones at `MENU_HEADER_BUTTONS_LEFT + 1`, reserving the menu-button corner exactly as a dashboard rail would have to. It is C++, so it costs nothing against the 20000-instruction Lua callback budget, whereas a dashboard rail would spend from the same allowance as the grid.

The arithmetic then settles it. A full-width rail in App mode leaves the grid `272 - 45 = 227` px. The ordinary Full screen layout with EdgeTX's top bar leaves the widget zone `272 - 45 = 227` px as well, by `ViewMainDecoration::getWidgetsZone`, and Full screen can also show flight mode, sliders and trims, which reduce it further. So a dashboard rail in App mode is at best a tie on grid area against simply inserting AeroGrid as a Full screen widget, and it buys a less capable status bar for a share of the instruction budget. AeroGrid already works inserted either way.

Note that an earlier comparison used 232 px for the Full screen zone. That number appears nowhere in the firmware; it came from a test fixture. The correct figure is 227.

If the rail is revisited, the arguments for it are that App mode has no top bar at all, that a dashboard rail would follow AeroGrid's theme rather than the radio's, that it would share the telemetry service instead of polling a second time, and that it could show dashboard state such as which layout is loaded or which service has gone stale. None of those outweighed the geometry.

The visibility policy is settled even though the feature is not built: **the rail defaults to off when a layout says nothing about it.** Not automatic, not on. A layout must opt in. Off by default means the rail can never silently take 45 px from a dashboard or force a reflow its author did not ask for, and every layout that exists today keeps its geometry unchanged if the rail ever arrives. Choosing the default automatically, from whether EdgeTX gave the widget a top bar, was considered and rejected: it makes a layout's geometry depend on which EdgeTX layout it happens to be inserted into, which is exactly the invisible coupling that is painful to debug on a radio.

#### Milestone 9: Phase 1 hardening

- Test corrupt, missing, and future-version YAML files.
- Test missing, incompatible, and failing component modules.
- Test package and component API compatibility.
- Add a diagnostics view for versions, layout path, components, unresolved sources, and failures. Delivered as `host-diagnostics`; see [The host diagnostics view](#the-host-diagnostics-view).
- Validate on TX16S v2, TX16S v3, TX15, and GX15 with EdgeTX 2.12+.
- Measure instruction use, Lua and bitmap memory, LVGL object count, and refresh cost.
- Establish release budgets from simulator and physical-radio baselines.

Deliverable: a read-only YAML-configured phase 1 release suitable for normal radio use.

### Phase 2: On-radio editor

#### Milestone 10: On-radio editor

- Display the editing grid and selection state in temporary fullscreen mode.
- Add, move, resize, configure, and remove components.
- Generate per-component settings forms from typed schemas.
- Implement source, switch, number, boolean, choice, color, string, timer, and file controls.
- Add Apply, Cancel, defaults, validation feedback, and recovery workflows.
- Implement validated temporary-file saves, backups, schema migration, and interrupted-save recovery.
- Support touch and rotary/key navigation according to the remaining phase 2 input decision.
- Add selected/editing state refinements and explicit diagnostic export.

Deliverable: layouts created and safely maintained entirely on the radio.

## Acceptance Criteria

- A user can run AeroGrid in a single `1 x 1` or App mode zone.
- The dashboard displays at least two independently implemented Lua component files.
- A component can be placed at any valid 4 x 4 grid coordinate.
- A component can span multiple rows and columns.
- Overlapping and out-of-bounds placements cannot be saved.
- Phase 1 loads complete dashboards from read-only YAML without requiring an on-radio editor.
- Separate Dashboard IDs load separate screens for the same model without internal paging.
- Phase 2 supports adding, moving, resizing, configuring, and removing components.
- Component settings forms are generated from component metadata rather than hard-coded in the host.
- A source setting can select an EdgeTX telemetry/input source, persist its name, and read its live value after reload, including after the sensors have been rediscovered in a different order.
- Telemetry components distinguish current, stale, unavailable, and valid zero values.
- Altitude and speed presets use the shared metric component while preserving domain-appropriate labels and supporting values.
- Navigation shows a north-up direction from home to model and never presents it as aircraft-relative orientation.
- Flight extrema follow the configured manual, timer, or switch reset policy.
- The dashboard offers Modern, Follow EdgeTX, and Custom theme modes without changing global EdgeTX colors.
- Trim panels display effective trim positions inside the grid without replacing or modifying EdgeTX trim controls.
- A variable indicator displays current-flight-mode global variables using their configured bounds, precision, and unit.
- Bar and radial indicators remain geometrically stable at minimum, maximum, zero, and out-of-range values.
- Invalid component configuration cannot be applied or persisted.
- In phase 2, Apply writes a valid per-model and per-Dashboard-ID YAML layout to the SD card.
- In phase 2, Cancel leaves both the active and persisted layout unchanged.
- The dashboard recovers from an invalid primary layout using backup or default data.
- One missing or failing component does not prevent other components from running.
- Layouts render without gaps caused by grid rounding.
- Components work in both App mode and the ordinary Full screen layout, subject to available decorations and interaction state.
- The 480 x 272 dashboard follows the defined visual hierarchy and remains legible on physical hardware.
- Dynamic values and state changes do not resize panels or shift neighboring content.
- Components use host theme tokens and provide valid presentations for every span they advertise.
- Incompatible components and future layout versions fail visibly without corrupting the saved layout.
- Diagnostics identify missing sources and component failures without requiring continuous SD-card writes.

## Open Decisions

- Whether collision handling rejects, swaps, or automatically relocates components.
- Whether phase 2 editing supports rotary/keys from its first release or initially targets touch input.
- Exact automatic source defaults and name-recovery behavior for each RF protocol.
- Whether flight-session statistics need optional persistence or export.
- Whether status-rail item ordering is configurable in the first release.
- Which default YAML dashboard examples ship for aircraft, helicopter, and long-range use.
- Phase 2 collision and resize-anchor behavior.
- Numeric performance budgets after simulator and physical-radio baselining.
- Whether the three development components ship in a release.
