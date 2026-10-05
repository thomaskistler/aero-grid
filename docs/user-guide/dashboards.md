# Configure a dashboard

## Select a layout

Each widget instance has two native settings: **Dashboard ID** (`DashID` in Lua) and **Theme**. AeroGrid combines the Dashboard ID with `model.getInfo().filename` and loads:

```text
/WIDGETS/AeroGrid/layouts/<model-identifier>--<dashboard-id>.yaml
```

If that file does not exist, AeroGrid tries `/WIDGETS/AeroGrid/layouts/<dashboard-id>.yaml`, which is shared by every model, and finally `/WIDGETS/AeroGrid/layouts/default.yaml`.

Changing either setting rebuilds the dashboard safely. Phase one never writes layout files.

Dashboard ID **`aircraft`** provides a model9-oriented layout: timer 1 at the top
left, a cell-battery panel in the second row, link quality without a bar in the
third row, and altitude with maximum altitude above maximum vertical speed
on the right side of the bottom-left panel. On the right are a 1 x 1 TX battery
panel in the top-right corner (the slot immediately to its left stays empty),
GV9 flights, GV1 expo, and a 2 x 2 model image. It uses `RxBt`, `RQly`, `1RSS`,
`Alt`, `Alt+`, and `VSpd+`; adjust these names for another model. The battery
uses the default per-cell alarm thresholds and `RxBt` as a 2S pack source:
the headline is average cell voltage,
with total voltage and configured count alongside it. `RxBt` must measure
the battery itself, not a regulated receiver supply.
No link alarm thresholds are assumed. The TX battery panel keeps transmitter
voltage visible even in App mode, which hides EdgeTX's top bar.

Dashboard ID **`aircraft-lite`** isolates the flight timer, TX battery, and model
image in the same positions as `aircraft`. It omits the receiver telemetry and
GV panels for hardware memory-growth comparison; it does not require a receiver.
Restart the radio between comparisons to avoid counting previously initialized
dashboard instances in the Widget memory total.

Use a different Dashboard ID on each custom screen to run several independent dashboards for one model. Each instance renders exactly one layout; paging between them is EdgeTX sliding between its own screens, not anything AeroGrid does. Changing model reloads whatever the new model's files select, because EdgeTX destroys and rebuilds every widget around a model change.

### App mode and the EdgeTX menu button

In App mode EdgeTX draws its menu button over the top-left corner of the screen, above everything the widget draws. It cannot be hidden, because in App mode it is the only route to the radio's menus. It is 47 x 45 pixels on a 480 x 272 display.

AeroGrid lays the affected panel out around it. One-row panels (`1x1` through
`4x1`) reserve a strip on the left for the button and keep their vertical
reading space. Taller panels move the header to the right of the button and
start their content below it. Grid placement and neighbouring panels do not change.
For a primary without a slotted visual or side stack, the builder first measures
its sizing sample, including its unit, at the ordinary centered position.
If it clears the icon, the primary keeps that position and font; headers and
supporting content retain their independent left inset. Overlapping samples and
slotted groups retain the inset layout. Live values exceeding the sample are
prevented from extending left into the icon.

A top-left `1 x 1` cell remains narrow: the left reservation reduces the reading
width and can drop its heading or optional content. Wider one-row spans retain
more useful width without forcing their reading below the button.

The ordinary `1 x 1` layout is unaffected either way: with a top bar the widget sits below the button, and without one the button is not drawn.

## Create a layout

Copy a shipped YAML file to a new Dashboard ID, keeping the original as a reference.
This minimal layout displays EdgeTX timer 1:

```yaml
version: 1
grid:
  columns: 4
  rows: 4
components:
  - id: flight-clock
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
      accent: green
```

Save it as `/WIDGETS/AeroGrid/layouts/my-dashboard.yaml` and select
`my-dashboard` as Dashboard ID.

Positions are zero-based: `col: 0`, `row: 0` is the top-left cell. Spans specify
how many cells a panel occupies. Keep placements within the 4 x 4 grid without
overlap, use unique component IDs, and choose spans supported by the component.
The `type` selects the component; `config` contains its settings.

See the [Reference Guide](../reference-guide/index.md) for source names, options,
defaults, and examples. AeroGrid uses a constrained YAML parser, not the full YAML
language; follow shipped examples rather than introducing advanced YAML features.

## Theming

The host owns every color; components never define palettes. Three modes are available through the native **Theme** widget option or a layout's optional `theme` block, which takes precedence:

| Mode | Behavior |
| --- | --- |
| `modern` | The designed dark instrument palette. Used verbatim. |
| `edgetx` | Derives tokens from the radio's active EdgeTX theme via `lcd.getColor()`. |
| `custom` | Modern plus a limited override set: `canvas`, `surface`, `text`, and `accent`. |

Both derived modes pass through a legibility pass that enforces minimum contrast for text, panel elevation, borders, and every semantic accent, so a hostile or pale source theme cannot produce an unreadable dashboard. Critical red is never theme-derived, and AeroGrid never calls `lcd.setColor()`.

## Troubleshoot a reading

Check the component's source name and expected data type first. A cells-table
source and a numeric pack-voltage source are not interchangeable. Check receiver
connection, sensor discovery, GPS fix, and model timer configuration as applicable.

Use `services` and `services2` to inspect normalized service values and freshness.
Interpret missing or stale states using the component's reference page rather than
treating them as zero. If a copied fix is not taking effect, follow the
[upgrade instructions](installation.md#stale-bytecode).
