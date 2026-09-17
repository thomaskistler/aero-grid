# AeroGrid Project Specification

## Status

- Draft specification
- Date: 2026-09-07
- Status last updated: 2026-09-17
- EdgeTX source: `../edgetx`
- Project root: `aero-grid/`
- Implementation: Phase 1, milestones 1 to 8 complete
- Next work: Milestone 9, hardening, and hardware verification
- See [Resuming work](#resuming-work) for the current branch stack and the exact next steps.

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
- Support `single`, `pair`, and `all` presentations so a compact panel may show one trim while a larger panel may show the primary four.
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
- Support `value`, `horizontal-bar`, `bipolar-bar`, and `radial` presentations.
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

The default interface should feel like a modern flight instrument rather than a collection of legacy widget boxes. The supplied references establish the intended direction: dense and glanceable, with strong numeric hierarchy, restrained color, crisp panel boundaries, and minimal decoration.

The primary reference viewport is 480 x 272, matching the TX16S and several other color-screen targets. The same layout model must scale to other supported color displays without scaling type directly from viewport width.

### Design principles

- Optimize for recognition during flight: the current value, unit, label, trend, and warning state must be distinguishable at a glance.
- Use dark neutral surfaces with luminance separation rather than a one-hue dark blue or slate palette.
- Reserve saturated color for meaning: cyan for electrical or selected data, green for healthy/current state, amber for caution, red for critical state, and orange only where it identifies a distinct measurement family.
- Use one dominant reading per component. Supporting values must be visibly secondary.
- Keep component framing quiet. Prefer thin separators, subtle surface changes, and a narrow semantic accent over heavy borders.
- Avoid ornamental gradients, glow effects, glossy styling, decorative blobs, and excessive gauge rings.
- Keep animation purposeful and sparse: value interpolation, state changes, and editor transitions only.
- Preserve stable geometry when values, units, labels, or warning states change.

### Screen composition

- A compact status rail across the top was specified and is deferred; EdgeTX's own top bar fills that role at no cost to the Lua budget. See [Why there is no status rail](#why-there-is-no-status-rail).
- In App mode the top-left 47 x 45 corner belongs to EdgeTX's menu button. Panels lay out around it through `theme.frame` rather than the grid surrendering a strip.
- Use a compact footer only for genuinely global data such as coordinates or an active flight timer. Do not reserve footer space by default.
- Use 4 px outer margins and 4 px grid gutters at 480 x 272 as the initial baseline, subject to hardware verification.
- Component panels should use a 4-6 px corner radius. Nested cards are prohibited.
- A component spanning several cells remains one coherent panel; it must not visually imitate multiple unrelated cards unless its data model genuinely contains repeated items.

### Typography and values

- Use EdgeTX-provided fonts and font sizes to avoid extra memory cost unless a later target-specific benchmark permits a bundled font.
- Use tabular or fixed-width numerals where available so changing values do not shift adjacent content.
- Labels are short, uppercase where appropriate, and visually quiet.
- Primary values use the largest size that fits their component at every supported span.
- Units stay attached to the value but use a smaller size and lower contrast.
- Supporting values and captions must remain legible on the physical radio, not merely in the simulator.
- Letter spacing is zero. Text must wrap, abbreviate, or reduce to a defined smaller font before it clips.

### Initial color tokens

Exact colors require physical-display testing, but components must consume semantic theme tokens rather than hard-coded colors:

```lua
local theme = {
  canvas = 0x101316,
  surface = 0x1A1F23,
  surfaceRaised = 0x22282D,
  border = 0x343B40,
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

### States

- `normal`: Neutral panel with semantic measurement accent.
- `selected`: Clear focus outline suitable for touch and rotary navigation.
- `stale`: Muted value plus an explicit stale indicator; color alone is insufficient.
- `warning`: Amber accent and concise threshold indication.
- `critical`: Red accent with high contrast; avoid continuous distracting animation.
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

A source setting persists the numeric EdgeTX source identifier, not the current telemetry value. The component reads the selected source at runtime:

```lua
local value, isCurrent, isFresh = getSourceValue(config.source)
```

The YAML may also record `sourceName` as optional human-readable and recovery metadata. The numeric identifier is authoritative for normal operation. On model or firmware changes, the loader may use the name to recover a source when the stored identifier is invalid, but it must not silently change a valid identifier.

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

- Persist the numeric EdgeTX source identifier and an optional readable source name.
- Use the valid numeric identifier as authoritative.
- If an identifier becomes invalid, offer explicit recovery by matching the stored name; do not silently bind a different valid source.
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
      source: 216
      sourceName: Cels
      warning: 3.5
      critical: 3.3
      showLabel: true

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
    rowSpan: 3
    config:
      rssiSource: 200
      rssiSourceName: RSSI
      qualitySource: 203
      qualitySourceName: RQly
```

### Schema rules

- `version` is required and currently must equal 1.
- The first implementation always uses a 4 x 4 grid, even though dimensions are recorded for future compatibility.
- `id` must be unique within a layout.
- `type` maps to `components/<type>.lua` and must be restricted to safe filename characters.
- Placement values must be integers within grid bounds.
- Unknown top-level and component keys should be ignored for forward compatibility.
- Unknown component types should produce a visible placeholder rather than prevent the dashboard from loading.
- Component-specific data belongs under `config`.
- Config keys correspond to stable keys in the component's `settings` schema.
- Missing config keys receive component defaults; unknown config keys are preserved when saving for forward compatibility.
- Source identifiers are stored as integers. An adjacent `<key>Name` value may preserve a readable source name.

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
- Source values are valid numeric identifiers or can be recovered explicitly from stored source names.
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
- The dashboard provides a diagnostics view showing package version, EdgeTX version where available, active layout path, loaded components, unresolved sources, parser errors, and recent component failures.
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

State as of 2026-09-17. This section is the entry point after a break: it records where the code lives, what is proven, and what to do next.

### Branch stack

Milestones 1 to 7 are merged into `main`.

| PR | Branch | Base | Contents |
| --- | --- | --- | --- |
| #1 to #7 | merged | `main` | Milestones 1 to 7, the shared services, the full component catalogue, firmware fixes, refresh scheduling, and CI |
| current | `thomaskistler/app-mode-menu-button-corner` | `main` | Milestone 8, the App mode menu button corner and the multi-screen verification |

### Verification state

- `make test`, `make check`, and `make build` pass from a clean tree. `make check` was also run against a real Lua 5.3 `luac`, and both suites were executed under a real Lua 5.3 interpreter, not only under whichever Lua `lupa` provides.
- CI (`.github/workflows/ci.yml`) runs `make check` under Lua 5.3 on every pull request, plus the SD image build and two integrity assertions.
- The dashboard has been confirmed running in the EdgeTX simulator on a TX16S profile through milestone 7. Navigation, link status, the radial and bar metrics and the trim panel have all been read against live simulated telemetry, which is where the arc drift in constraint 11 was found. Two of milestone 7's behaviours still cannot be judged there: whether a cells source on a real receiver returns the table shape assumed here, since nothing on an ELRS link publishes one, and whether a protocol without an RSSI sensor is recognized as a link rather than a dead one.
- Milestone 8's corner work has not yet been seen in the simulator. It is measured against the real host in the test suite, and the numbers are in the milestone section, but the thing it fixes was only ever visible on a screen, so it should be looked at on one.
- The simulator fixture carries two screens, both holding an AeroGrid instance: screen one selects `sim`, which fills its grid with the telemetry components, and screen two selects `sim2`, which covers the radio-local ones that had nowhere to go beside them. Paging between them switches dashboards without opening widget settings, and exercises two widget instances resolving different layouts at once. `sim` carries the Modern palette and `sim2` the EdgeTX-derived one, so the two are one button press apart.
- Two instances running together are held to owning their own root, page, service registry and telemetry service, because EdgeTX runs every Lua widget in one interpreter state and anything a module kept at its own scope would be shared between dashboards that know nothing about each other.
- In App mode, every shipped layout is checked to draw nothing readable inside the corner EdgeTX's menu button covers. The directory is read rather than listed, so a new layout is covered as soon as it is added.
- Every layout under `layouts/` is loaded by the integration suite, not merely the shipped default: each one is built through the real host and components, held to the same containment rules, and refreshed against radio state. A layout is covered as soon as it is added, because the suite reads the directory rather than a list.

### Immediate next steps

1. Run the shipped dashboard on a radio. It now demonstrates the complete ten-component catalogue, so one screen exercises telemetry, cells, link, GPS, model timers, flight mode, transmitter voltage, a global variable, trims, and the model bitmap at once. Four things can only be judged there: whether the estimated text widths behind `theme.fitText` hold against the real fonts, whether an `lvgl.image` of a model bitmap scales the way `StaticImage` is expected to, whether the corrected arc centring places the radial and compass dials where they are meant to go, and whether the compass pointer reads as a direction at arm's length.
2. Run the two diagnostics layouts on a radio. Set the widget's Dashboard ID to `services` or `services2`; they load on any model without a model-specific file. This is the check that milestone 5's normalization is right against real sensors rather than mocks.
3. Confirm the value shapes on real hardware, on more than one protocol. `cell-battery` assumes a cells source returns a contiguous array of per-cell voltages, and `link-status` assumes a protocol without an RSSI sensor is detected by a source contradicting `getRSSI()`. Both are mocked faithfully but neither has met a receiver.
4. Look at milestone 8's corner in the simulator, in App mode, on both screens. The distance reading it recovers should now sit below the menu button at `MIDSIZE`, and the panel headers beside it rather than under it.
5. Compare the two palettes in the simulator. `sim` is Modern and `sim2` is EdgeTX-derived, so paging between them compares the two directly. The derived palette is not flat but it is much more strongly outlined: canvas to surface 1.272 against Modern's 1.122, surface to raised 1.263 against 1.115, but border 3.499 against Modern's 1.460. Whether those outlines read as deliberate or as heavy is a question for a screen, and it is worth establishing whether what stands out is `presentation.border` or the accent bar in `primitives.panel`.
6. Decide the extrema reset policy beyond arm switch. The specification names manual, timer, and switch; switch and manual are implemented, timer is not.
7. Decide whether the status rail is ever built. It is deferred rather than cancelled, and the reasoning is recorded so the question starts from where it was left.

### Open items carried forward

| Item | Where | Note |
| --- | --- | --- |
| Physical readability review at 480 x 272 | Milestone 4 | Needs hardware; the only thing keeping milestone 4 from being fully closed |
| Milestones 5 and 6 have not been run on hardware | Milestones 5 and 6 | The diagnostics layouts exist precisely to make that check quick, and the shipped dashboard now exercises all seven core components at once |
| Staleness is link-wide, not per sensor | Milestone 5 | EdgeTX exposes no per-sensor age except for GPS, so a sensor that stops arriving, or was never received, while the link holds still reads as live. See below |
| Extrema reset policy covers switch and manual only | Milestone 5 | Timer-based reset is specified but not implemented |
| A `1 x 1` component in the App mode top-left corner cannot be fully shown | Milestone 8 | The button covers 40% of its width and 69% of its height. Its reading survives, pushed below the button, and its header label is dropped rather than clipped. No approach saves it; avoid the placement |
| The menu button corner has not been seen on a radio | Milestone 8 | Measured against the real host and asserted for every shipped layout, but the defect it fixes was only ever visible on a screen |
| Host notices are collected but not shown anywhere | Milestone 8 | Contrast corrections and palette fallbacks are recorded on the context with a severity, ready for milestone 9's diagnostics view. Until that exists they are invisible except to a test |
| The status rail is deferred, not cancelled | Milestone 8 | EdgeTX's own top bar fills the role at no Lua cost, and the geometry does not favour a dashboard rail. Default settled as off should it return |
| Steady-state refresh cost scales with component count | Milestone 6 | 2200 of 20000 on the shipped ten-component dashboard, up from 2000; watch it as the catalog grows |
| A cells source's real shape is unverified | Milestone 7 | `cell-battery` assumes a contiguous array of per-cell voltages and validates every entry, but no receiver has produced one yet |
| A protocol without an RSSI sensor is detected indirectly | Milestone 7 | `link-status` relies on `telemetryService` observing a source contradict `getRSSI()`. Until something contradicts it, a genuinely dead link and a missing RSSI sensor are indistinguishable, and both read as no link |
| Text width is estimated, not measured | Milestone 6 | The Lua API exposes no text measurement outside a draw callback, so `theme.textWidth` assumes a mean advance of 0.58 of the line height. Deliberately generous, so it shrinks text that would have fitted rather than clipping text that does not. Needs a hardware check |
| A trim's axis is unknown to the dashboard | Milestone 6 | EdgeTX exposes no axis metadata for a trim source, so `trim-panel` takes an orientation with a per-indicator override instead of matching on trim names |
| `lvgl.image` cannot report a failed decode | Milestone 6 | `StaticImage` clears its source silently, so `model-identity` checks the file with `fstat` beforehand and keeps the model name visible when `fstat` is unavailable |
| `actions/checkout@v4` and `setup-python@v5` target Node 20 | CI | Non-blocking deprecation warning |
| ~~A `1 x 1` metric fits its value vertically but width is unchecked~~ | Milestone 6 | Closed. `theme.fitText` fits a value by measured width as well as height, choosing the font from the widest string the component can ever produce so geometry stays stable |
| ~~`lvgl.arc` is positioned by its top-left corner~~ | Milestone 7 | Closed, and it never was. EdgeTX positions an arc by its **centre**, so every radial drawn before this milestone was one radius up and to the left of its intended place. See below |
| ~~The navigation distance value does not render in the simulator~~ | Milestone 8 | Closed. It rendered perfectly and EdgeTX's menu button was painted over it: `778m` at (8, 25), inside a corner of 47 x 45. Not a Lua fault, and no error was ever raised |
| ~~Component errors are invisible in App mode~~ | Milestone 8 | Closed. The overlay was drawn at (8, 8), underneath the menu button |

### Hard-won constraints

Twelve firmware behaviours cost real debugging time and were invisible to the mocked tests until each mock was made faithful. Each now has a regression test, and each is documented in full further down.

1. **A widget callback may not exceed 20000 Lua VM instructions.** Loading, reflow, refresh, and service updates are all bounded work per callback as a result.
2. **`lvgl.box` accepts a `color` and silently ignores it.** Only a filled `lvgl.rectangle` paints a background.
3. **EdgeTX fonts are much taller than they look.** `XXL` is a 69 px line height at 480 x 272. Lay out from measured heights, never fixed offsets.
4. **`getValue` returns integer zero for a telemetry source whose link is down.** That is indistinguishable from a genuine zero reading, so only a zero may be judged: a non-zero value is proof of life whatever `getRSSI()` says, and `getRSSI()` itself reads zero on a live link whose protocol has no RSSI sensor.

Milestone 6 added three more, all of them about what the Lua API refuses to tell a component:

5. **Lua cannot measure text.** `lcd.sizeText` is only meaningful inside a draw callback, which an LVGL widget does not have, so width has to be estimated. `theme.textWidth` assumes a mean advance of 0.58 of the line height and `theme.fitText` chooses a font from the widest string a component can ever produce, never from the current one, so a reading does not resize as it changes.
6. **A trim source carries no axis.** Nothing in `getFieldInfo` says whether a trim is a roll trim or a pitch trim, and the specification forbids assuming fixed trim names. `trim-panel` therefore takes an orientation, with a per-indicator override.
7. **`lvgl.image` cannot report a failed decode.** `StaticImage::setSource` clears its own source and traces the error when a file will not load, and tells Lua nothing. The decision has to be made before the object exists, so `model-identity` asks `fstat` first and keeps the model name visible when `fstat` is absent.

Milestone 7 added one more, and it invalidated work already shipped:

8. **`lvgl.arc` is positioned by its centre, not its corner.** `LvglWidgetArc::build` calls `setPos(x, y)`, and `LvglWidgetRoundObject::setPos` stores `x - radius, y - radius`. Every radial written in milestone 6 passed a top-left corner, so on real hardware each one was drawn a full radius up and to the left of where the layout intended, overlapping the panel header and the reading beside it. Nothing in the mocked tests could see it, because the mock stores whatever coordinates it is handed. `primitives.radial` now takes a centre, `primitives.arcBounds` converts between the two in one place, and the tests assert containment against the converted box rather than against `x` and `y`.

9. **A `clear()` is collected at a time the script cannot predict.** `LvglWidgetObjectBase::clear` only destroys windows and sets `clearRequest`; the reference cleanup happens later, in `callRefs`, which EdgeTX skips while the widget is off screen, such as behind the settings dialog, and once an error has been reported. When it does run, `clearChildRefs` invalidates every reference in that object's child list, including ones created long after the clear. Rebuilding the dashboard in place after a Dashboard ID or Theme change hit this: the canvas was recreated under the cleared root and then silently invalidated, and the next callback failed with `Invalid object (it has been probably been cleared)`, which disables the widget until the radio restarts. The dashboard now draws into a page container. A reload discards the whole page and builds the next generation as a fresh child of the root, which is never cleared, so no pending cleanup can reach it whenever it eventually lands. Deferring the rebuild by one callback is not sufficient on its own, because the collection point is not guaranteed to be the next callback.

10. **EdgeTX prefers `.luac` bytecode and compiles it beside each script.** The radio writes a `.luac` next to every `.lua` it loads and uses the bytecode on the next run. Copying a new image with `rsync -a` preserves source timestamps, so the new scripts can appear older than bytecode compiled from the previous build and the radio silently keeps running the old code. This cost several rounds of debugging: fixes appeared to do nothing, and the widget reported an error at a line number that no longer existed in the source. `make build` now deletes the bytecode and stamps the sources as new. When a fix appears to have no effect on a radio, confirm which code is actually running before changing anything else.

11. **Every update to an arc moves it, unless the update restates its centre.** `lvgl.arc` is positioned by its centre but stores `centre - radius`, and `LvglWidgetRoundObject::refresh` subtracts the radius twice: once inside `setRadius`, which converts the stored corner back to a centre, and again through the inherited `LvglWidgetObjectBase::refresh`, which calls `setPos(x, y)` with members that already hold a corner. Any `set` call runs `refresh`, whatever keys it carries, so an arc walks up and to the left by its own radius each time it is touched. `build` does not call `refresh`, so a dial is correct until its first update and wrong afterwards: the compass vanished the moment a GPS fix arrived, and the quality dial crept off its panel over a few telemetry readings. `primitives` now routes every arc update through one helper that adds the centre to the change set, which overwrites the drifted members with absolute coordinates so the doubled subtraction lands correctly. The test mock models this arithmetic rather than recording the coordinates it was handed, because a mock that stores what it is given cannot see the object move.

Milestone 8 added one firmware behaviour, and one about what a constant means:

12. **EdgeTX paints its menu button over the widget in App mode, and says how big it is in a unit nobody expects.** `ViewMain` creates the top bar after the screen, commented `// create last to be on top`, and the button is parented to `ViewMain` rather than to the bar, so hiding the bar in App mode leaves the button drawn over the dashboard's top-left corner. Anything underneath it is simply not visible: the shipped dashboard's distance reading was painted over for two releases without a single error being raised. The firmware does publish the size, as `MENU_HEADER_HEIGHT`, but registers it beside the colour constants so it passes through `COLOR2FLAGS` and arrives shifted left by sixteen bits. The global reads 2949120 on a TX16S, not 45. A host that never unshifts it falls back to a hard-coded 45 and is then wrong on every radio whose display class scales the constant, which is why the mock publishes the shifted value and the tests measure a 62 px button as well as a 45 px one.

Two more lessons came from the tests rather than the firmware:

- A budget test that measured only the shipped layout could not fail, and hid a loader that broke on any layout larger than twelve components. Measure the worst case the schema permits, and assert that the measured work actually happened.
- An assertion can be vacuous without being wrong. A test that a missing model bitmap falls back to the model name passed while the panel was too short to have shown an image at all. It now asserts first that the panel could have shown one.
- A geometry test that only checks the right and bottom edges cannot see two rows resolved onto the same line. Milestone 7's region tests assert that every supporting row clears the one above it and every column clears the one beside it, and that shedding a row actually buys the dominant reading a larger font, which is the reason for shedding it.
- A fallback can hide the bug a test was written for. The reserved-corner test passed with the `MENU_HEADER_HEIGHT` unshifting removed, because the code's own 45 px default was right for the display the test used. Only measuring a display whose button is a different size made the shift load bearing. A default that rescues the mistake is worth keeping; a test that cannot see past it is not.
- A component that reimplements a shared helper stops receiving that helper's fixes. `service-probe` had its own copy of the panel frame arithmetic, so it kept drawing its title into the menu button's corner after every catalogue component had stopped. `metric` shadowed a subset of the frame's fields and handed that to the header primitive, so it silently missed the new one.
- A refresh short-circuit is a cache, and a cache that misses a change shows an old number with a straight face. Three of milestone 7's components compared only their dominant reading and so froze a supporting row: the pack sum when three of four cells sagged, the RSSI readout while link quality sat pinned at 100, and the whole navigation panel when its GPS sensor appeared but had no fix yet. Every field a component draws has to be part of the comparison, and each of the three now has a regression test that changes exactly the field the primary reading does not move with.

## Proposed Release Phases

### Implementation status

Status last verified on 2026-09-16:

| Work item | Status | Implemented | Remaining |
| --- | --- | --- | --- |
| Build and test foundation | Complete | Make targets, isolated Python environment, unit/integration suites, EdgeTX Lua parsing, tracked simulator fixture, reproducible `build/sdcard` assembly, and GitHub Actions CI running `make check` against Lua 5.3 | None |
| Milestone 1: Runtime skeleton | Complete | LVGL host, integer 4 x 4 geometry, gutters, per-component containers, batched reflow, App mode fixture, and `1 x 1`-sized mocked tests | Additional physical-radio verification belongs to hardening |
| Milestone 2: Read-only YAML loader | Complete | Constrained parser, empty flow collections, schema version check, model/Dashboard ID resolution, default fallback, fail-closed document validation, per-entry validation, preserved unknown keys, optional theme block, and a malformed-input matrix | Physical-radio verification belongs to hardening |
| Milestone 3: Component runtime | Complete | Referenced-module loading, metatable-safe contract validation, declared settings with typed defaults, `supportedSpans` enforcement, host-owned containers, declared refresh intervals with phase staggering, and isolated create/update/refresh/background/event/destroy dispatch | Production components arrive in milestones 6 and 7 |
| Milestone 4: Design system | Complete | Semantic tokens, panel/typography/bar/radial/badge primitives, Modern, Follow EdgeTX, and Custom modes, guaranteed-legible derived palettes, all seven states, and responsive `1 x 1`, `2 x 1`, and `2 x 2` presentations | Physical readability review at 480 x 272 on a TX16S-class display |
| Milestone 5: Shared data services | Complete | Registry with per-service intervals, staggering, and subscription caps; telemetry, model, control, extrema, and navigation services; immutable snapshots; graceful degradation for missing sources, unseen sensors, absent firmware APIs, and stale telemetry; `service-probe` diagnostic views and two shipped diagnostics layouts | Hardware verification, and timer-based extrema reset |
| Milestone 6: Core components | Complete | `metric` with `custom`/`altitude`/`speed` presets, source and flight extrema, and a secondary reading; `flight-timer`, `flight-mode`, `tx-battery`, `variable-indicator`, `trim-panel`, and `model-identity`; width-aware font fitting, shared panel frame and header geometry, bipolar bars with neutral markers, and images; a shipped dashboard demonstrating all seven | Physical-radio verification of estimated text widths and of model bitmap scaling |
| Milestone 7: Telemetry-specialized components | Complete | `cell-battery` with cells-table validation and a usable-range bar; `link-status` with independent RSSI and quality sources, a published link view, and explicit no-sensor/no-link states; `navigation` with four responsive presentations and a north-up dial; centre-positioned arcs, the `compass` primitive, and a shipped dashboard demonstrating all ten components | Hardware confirmation of the cells shape and of no-RSSI-sensor detection |
| Milestone 8: The App mode menu button and multiple screens | Complete | Dashboard ID option, per-model/per-dashboard filename resolution, dashboard-scoped layouts shared by every model, panels laid out around the App mode menu button through the shared frame, an error overlay that clears it, notices separated from errors, and two-instance and model-change coverage | Status rail deferred by decision, not outstanding; simulator confirmation of the corner on a radio |
| Milestone 9: Hardening | In progress | Unit/integration tests, firmware-like string behavior tests, CI running Lua 5.3 parsing, simulator fixture, corrupt-layout, contract-rejection, hostile-module, and legibility coverage, component failure isolation, an enforced instruction budget measured at the largest legal layout for both components and services, and diagnostic views over every service | Target-radio matrix, a host-level diagnostics view for versions and layout paths, and physical-radio testing |
| Milestone 10: On-radio editor | Not started | None | Entire phase 2 editor and write/recovery workflow |

The design system is in place: the host owns every color, resolves one theme per dashboard, and hands each component a `services` table carrying the theme, shared primitives, span-appropriate typography, a state resolver, and the five shared data services. The `metric` component is the reference implementation and now reads real telemetry; the temporary `demo` setting is gone. Milestone 4's remaining item is a physical readability review, which requires hardware.

Measured cost on the largest layout the schema permits, sixteen single-cell components: worst callback 7800 of 20000 instructions, worst steady frame 2400. Both are asserted by the test suite. Fourteen sixteen-component layouts are measured: metrics with sixteen distinct live sources, sixteen diagnostic panels spanning all five services, sixteen components that demand a refresh every frame, and one layout per catalogue component type. The worst callback is a `trim-panel` reflow, which repositions four indicators for each of the four components in a reflow batch; the three telemetry components cost 3800, 4000, and 4200 at sixteen cells, and their worst steady frames are 1800, 2400, and 1600. Removing the services' subscription caps raises the worst steady frame to 6200, which is what the caps are for.

The worst steady frame rose from 2000 to 2400 with milestone 7, on sixteen
`link-status` panels, which is the component that reads the most per refresh:
two sources, a minimum, and the link view. A component's declared refresh
interval, not its size, is what decides steady-state cost: `cell-battery`
walks its cells table on every refresh and declares 20 ticks for it, and
`navigation` declares 25 because telemetry GPS never arrives faster.

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

### Instruction budget

EdgeTX aborts any widget callback that exceeds **20000 Lua VM instructions**, raising `CPU limit` (`radio/src/lua/widgets.cpp`). Building a full dashboard costs far more than that, so the host never loads in one call. `create` only loads runtime modules and the root container, then `refresh` advances a staged loader one step per call:

1. `read` — resolve and read the layout file.
2. `tokenize` — convert the text into indentation tokens.
3. `parse` — build the document, validate it, and resolve the theme.
4. `components` — instantiate exactly one component, repeated until done.

Every stage is bounded by a fixed amount of work rather than by the size of the layout: the file is tokenized a fixed number of lines per call, and each component is parsed, validated, and built in its own call. A zone change is batched the same way. A layout that fills the grid therefore costs more callbacks, never a larger callback.

The regression test measures every callback with a 200-instruction count hook, mirroring the firmware, and fails if any exceeds 75% of the budget. It exercises **the largest layout the schema permits**, sixteen single-cell components, not just the shipped one. Measuring only the shipped layout previously hid a loader that passed on five components and failed on twelve.

Component authors must respect the same ceiling: `create`, `update`, `refresh`, `background`, and `event` each run inside the host's callback and share its allowance. Avoid per-character string loops, which are the most common way to exhaust it.

Shared data services share the same allowance, and are bounded the same way. The test measures three sixteen-component layouts: metrics with sixteen distinct live telemetry sources, sixteen diagnostic panels spanning all five services, and sixteen components demanding a refresh every frame. Each exercise declares which services it must actually run, and the test fails if one of them never updated during the sampled frames, so a layout that quietly subscribed to nothing cannot make the service layer measure zero.

##### Refresh scheduling

EdgeTX refreshes widgets on every main loop pass, so steady-state cost is paid tens of times per second and is shared by every component on the dashboard. Two mechanisms keep it bounded.

A component declares `refreshInterval`, in 10ms ticks, stating how often it actually needs servicing. A numeric telemetry readout is indistinguishable at 5 Hz and 50 Hz in flight, so `metric` declares 20 ticks and `heartbeat`, which animates, declares 10. Absent or zero means every frame.

Components that share an interval are then **phase staggered**: each is assigned an offset derived from its position in the layout, so they fall due on different frames instead of all at once. Staggering preserves each component's exact declared rate, which simple batching would not.

A per-frame dispatch cap is retained as a guarantee for layouts that defeat staggering, such as many components all asking to refresh every frame. The cap serves components in rotation so none is starved, and a component delayed by the cap does not accumulate a backlog of missed deadlines.

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

A layout file may carry an optional `theme` block, which takes precedence over the native Theme widget option:

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
- `primitives.arcBounds` converts an arc's centre into the rectangle it occupies. Components lay out in corner coordinates and EdgeTX positions arcs by their centre, so the conversion lives in one place instead of in every caller, and the tests assert containment through it.

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
- Add an in-memory diagnostics view for versions, layout path, components, unresolved sources, and recent failures.
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
- A source setting can select an EdgeTX telemetry/input source, persist its identifier, and read its live value after reload.
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
