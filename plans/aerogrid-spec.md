# AeroGrid Project Specification

## Status

- Draft specification
- Date: 2026-09-07
- EdgeTX source: `../edgetx`
- Project root: `aero-grid/`
- Implementation: Phase 1 in progress
- Current checkpoint: YAML-driven placeholder dashboard and reproducible simulator image

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

### Component requirements

#### Cell battery

- Accept an EdgeTX cells source. A cells source may return a table of individual voltages.
- Use the lowest valid cell voltage as the primary safety reading by default.
- Scale the horizontal bar over the configured usable range from critical to full, not from zero volts.
- Support warning, critical, stale, and unavailable states.
- Optionally show cell count and summed pack voltage.
- Do not estimate remaining battery percentage unless a future component explicitly defines and labels its estimation model.

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

#### Navigation

- Accept a GPS source and an optional native distance source.
- Use current and pilot coordinates returned by an EdgeTX GPS source to calculate distance and the initial bearing from the home/pilot position toward the model.
- Prefer an explicitly selected native distance source when configured.
- Render direction as an absolute north-up bearing or compass arrow from home to model. Aircraft heading and transmitter orientation are not required and must not rotate this arrow.
- Provide responsive modes: compact distance, distance and bearing, north-up compass/bearing arrow, and detailed navigation with coordinates.
- Surface missing fix, stale GPS, and unavailable home-position states explicitly.

#### Flight mode

- Read the current mode through `getFlightMode()`.
- Support a compact status-rail presentation and a grid presentation.

#### Model identity

- Read name and bitmap metadata through `model.getInfo()`.
- Load the assigned image once with `Bitmap.open()` and retain the bitmap object.
- Fall back to the model name when the image is missing or cannot be loaded.
- Support name-only, image-only, and combined presentations subject to component span.

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
- Support `standard`, `extended`, and `auto` display scales. Auto may expand after observing a value outside the standard range, but cannot reliably detect the model's extended-trim setting because EdgeTX does not expose that flag to Lua.
- Clearly represent centered, positive, negative, unavailable, and unsupported three-position trim states.

#### Variable indicator

- Bind to either an EdgeTX global-variable index or a numeric EdgeTX source.
- For a global variable, read the value for the current or explicitly selected flight mode with `model.getGlobalVariable(index, flightMode)`.
- Use `model.getGlobalVariableDetails(index)` where available to obtain the configured name, minimum, maximum, precision, and unit.
- Rely on EdgeTX to resolve global-variable flight-mode inheritance.
- Support `value`, `horizontal-bar`, `bipolar-bar`, and `radial` presentations.
- Normalize bar and radial geometry using GV bounds or explicit source bounds; clamp only the drawing, not the displayed value.
- Show a center marker when the configured range crosses zero.
- Remain read-only. AeroGrid does not modify global variables.
- Allow semantic labels such as Flight count, Expo, Rates, Gain, or Volume while retaining the configured GV name as optional supporting text.

A flight counter that already exists in a global variable is displayed by `variable-indicator`. AeroGrid does not detect or increment flights and does not own flight-counter persistence.

### Status rail

The optional dashboard-owned status rail may contain model name, flight mode, transmitter voltage, link state, clock, and active timer items. Rail items reuse the same shared services as grid components. Users can enable, disable, and order rail items, but the first implementation may ship with one fixed order. Enabling the rail reduces the rectangle available to the 4 x 4 grid and must trigger a complete grid geometry update.

### Shared services

The host provides shared services so components do not duplicate polling, conversion, or tracking logic:

- `telemetryService`: source lookup, cached values, units, freshness, and stale/unavailable classification.
- `extremaService`: source, session, and flight minimum/maximum tracking.
- `navigationService`: GPS fix, pilot/home coordinates, distance, and absolute bearing from home to model.
- `modelService`: model identity, bitmap path, model timers, flight mode, and transmitter voltage.
- `controlService`: current flight mode, resolved trim-source values, global-variable values, bounds, precision, and units.
- `themeService`: resolved semantic colors, contrast correction, and state precedence.

Services are updated once per host cycle. Components consume immutable snapshots for that cycle.

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
├── services/
│   ├── telemetry.lua
│   ├── extrema.lua
│   ├── navigation.lua
│   ├── model.lua
│   ├── control.lua
│   └── theme.lua
└── layouts/
    ├── default.yaml
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

- Provide an optional compact status rail across the top for model or flight mode, link quality, profile, clock, and radio battery.
- The status rail is dashboard-owned and sits outside the component grid when enabled; the remaining content rectangle becomes the 4 x 4 grid area.
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

## Proposed Release Phases

### Implementation status

Status last verified on 2026-09-07:

| Work item | Status | Implemented | Remaining |
| --- | --- | --- | --- |
| Build and test foundation | Complete | Make targets, isolated Python environment, unit/integration suites, EdgeTX Lua parsing, tracked simulator fixture, and reproducible `build/sdcard` assembly | Add CI when a hosted workflow is selected |
| Milestone 1: Runtime skeleton | Complete | LVGL host, integer 4 x 4 geometry, gutters, nested containers, responsive reflow, placeholder rendering, App mode fixture, and `1 x 1`-sized mocked tests | Additional physical-radio verification belongs to hardening |
| Milestone 2: Read-only YAML loader | In progress | Constrained parser, schema version check, model/Dashboard ID resolution, default fallback, ID/type/bounds/span/overlap validation, read-only loading, and visible errors | Preserve unknown top-level data, broaden malformed-input tests, and verify multiple real model filenames in the simulator |
| Milestone 3: Component runtime | In progress | Referenced-module loading, safe component type names, API-version check, create-time isolation, and repeated placeholder instances | Final metadata/settings/span contract, lifecycle dispatch, refresh/background failure isolation, and a second independently authored component |
| Milestone 4: Design system | Not started | Initial placeholder colors only | Semantic tokens, primitives, theme modes, states, responsive typography, and hardware review |
| Milestone 5: Shared data services | Not started | None | Telemetry, model, control, extrema, and navigation services |
| Milestones 6–7: Production components | Not started | Placeholder component only | Complete ten-component catalog and metric presets |
| Milestone 8: Status rail and multiple screens | In progress | Dashboard ID option and per-model/per-dashboard filename resolution | Status rail and multi-instance simulator verification |
| Milestone 9: Hardening | In progress | Unit/integration tests, firmware-like string behavior tests, simulator fixture, exact Lua 5.3 parsing, and component load diagnostics | Corruption matrix, target-radio matrix, runtime diagnostics view, performance budgets, and physical-radio testing |
| Milestone 10: On-radio editor | Not started | None | Entire phase 2 editor and write/recovery workflow |

The first architecture checkpoint is not yet complete because Milestone 2 still has remaining compatibility work and Milestone 3 has only one component implementation. The current runtime is suitable for continued simulator development, not normal flight use.

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

#### Milestone 7: Telemetry-specialized components

Implement these components in order:

1. `cell-battery`
2. `link-status`
3. `navigation`

- Validate cells-table and GPS-table value shapes.
- Handle protocol-dependent RSSI and link-quality source selection.
- Test telemetry disconnect, reconnect, stale data, missing GPS fix, and unavailable home position.

Deliverable: the full ten-component catalog with graceful telemetry degradation.

#### Milestone 8: Status rail and multiple screens

- Implement the optional status rail with configurable visibility and a fixed initial item order.
- Reuse shared services rather than polling separately for rail items.
- Verify that enabling the rail recalculates the complete grid rectangle.
- Verify separate Dashboard IDs for multiple screens on one model.
- Verify model switching reloads the correct layout and that each instance remains one page.

Deliverable: multiple independent, model-scoped dashboards with a stable compact status rail.

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
