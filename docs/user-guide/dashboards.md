# Configure a dashboard

## Select a layout

Choose **Layout** in the widget settings. The list contains `Empty`, every
layout shipped in `/WIDGETS/AeroGrid/layouts/`, and every layout you have saved
in `/AEROGRID/layouts/`. Use `default` for the bundled aircraft dashboard, or
`Empty` to start a new screen from a blank grid.

An empty dashboard shows centred text explaining how to enter fullscreen and
start editing. The hint disappears during editing and is never saved as a panel.

The layout name is its identity on every model. A layout you saved under the
same name as a shipped one takes precedence over it, and widget updates never
touch `/AEROGRID/`. A name with no file falls back to `default`.

EdgeTX reads the list only when the radio starts, so a layout saved or copied
to the SD card appears after a restart. The list order is recorded in
`/AEROGRID/registry.txt` and only ever grows: EdgeTX stores the setting as a
position in the list, so deleting a layout file leaves its entry, and
selecting it then shows `default`. Delete the registry file only if no screen
selects a saved layout, because every position is reassigned.

Use a different layout on each EdgeTX screen to show different dashboards.
You can edit layouts on the radio in temporary fullscreen mode, or edit YAML
files on a computer and copy them to the SD card.

Upgrading from a version with **Dashboard ID** and **Theme** text settings
resets each AeroGrid widget to `Empty` and Modern; select its layout and theme
again. Model-specific files named
`<model>--<dashboard>.yaml` are no longer read; rename one to a plain layout
name and move it to `/AEROGRID/layouts/` to keep it.

Before using the bundled layout, adjust its source names, battery cell count,
and alarm thresholds for your model. Its battery source must measure the
flight pack, not a regulated receiver supply.

The bundled dashboard includes a [flight-counter](../panels/flight-counter.md)
tracker using GV9 FM0, `armSwitch: "SFv"` for armed, and CH3 for motor output.
Adjust the panel's `armSwitch` and `motorSource` to match your model;
the separate Mode text panel also needs matching switch mappings. Reserve GV9
with precision 0 and limits allowing `0..999`. The tracker uses 30-second
qualification, a 10-second disarm timeout, and CSV history by default.
Use only one tracking panel across all dashboards and do not run EdgeTX Flights
alongside it. When copying the default layout for a second dashboard, remove the
tracker or replace it with a read-only `metric` using `gvar9`.

## Create a layout

Copy `default.yaml` to a new filename and edit it, or start with this example.
This minimal layout displays EdgeTX timer 1:

```yaml
version: 1
grid:
  columns: 4
  rows: 4
panels:
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

Save it as `/AEROGRID/layouts/my-dashboard.yaml`, restart the radio, and
select `my-dashboard` as Layout. Names may use letters, digits, `-` and `_`.

Positions are zero-based: `col: 0`, `row: 0` is the top-left cell. Spans specify
how many cells a panel occupies. Keep placements within the 4 x 4 grid without
overlap, use unique panel IDs, and choose spans supported by the panel.
The `type` selects the panel; `config` contains its settings.

See the [Panel reference](../reference-guide/index.md) for settings and examples.
Use exact, case-sensitive source names from your model's telemetry configuration.
Follow the YAML structure above and the panel examples.

## Edit a dashboard on the radio

Long-press to enter fullscreen, then long-press again to start editing.
Use **Empty** for a new dashboard, the **+ panel** to add panels, and the
**gear** to configure them. Press **RTN** to save or discard your changes.

See the [On-radio editor guide](editor.md) for moving, resizing, source
selection, Save As, and resuming an unsaved draft.

## Layout recovery

If the primary layout cannot be read, parsed, or validated, AeroGrid tries its
backup, then the shipped layout of that name, and finally the shipped
default and its backup. Review the active path in the `host` diagnostics
panel after recovery.

## App mode and Full screen

Choose the screen layout in EdgeTX's **Model Setup → Screens**, then assign
AeroGrid to its widget area.

| Layout | What you see |
| --- | --- |
| **App mode** | A dashboard covering the display, without the EdgeTX top bar, flight-mode label, sliders, or trims. The menu button remains in the top-left corner. |
| **Full screen (`1 x 1`)** | One dashboard widget, with the option to keep EdgeTX's top bar, flight-mode label, sliders, and trims. |

Use App mode for a clean dashboard, or Full screen to keep the radio's
standard information alongside it. In App mode, a wider top-left panel
leaves more room beside the menu button.

## Theming

Choose **Theme** in the widget settings: **Modern** or **EdgeTX**. A layout's
optional `theme` block overrides that selection, and is the only place to use
`custom`, because custom colours are defined there.

| Mode | Behavior |
| --- | --- |
| `modern` | AeroGrid's dark instrument palette. |
| `edgetx` | Colors based on the radio's active theme. |
| `custom` | The modern palette with overrides for `canvas`, `surface`, `text`, and `accent`. |

## Troubleshoot a reading

Check the panel's source name and expected data type first. A cells-table
source and a numeric pack-voltage source are not interchangeable. Check receiver
connection, sensor discovery, GPS fix, and model timer configuration as applicable.

Use `host` to inspect the loaded layout, panel loading, and service failures.
Interpret missing or stale states using the panel's reference page rather than
treating them as zero. If a copied fix is not taking effect, follow the
[upgrade instructions](installation.md#upgrade).
