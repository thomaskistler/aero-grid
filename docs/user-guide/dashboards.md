# Configure a dashboard

## Select a layout

Set **Dashboard ID** in the widget settings to the layout's filename without
`.yaml`. Use `default` for the bundled aircraft dashboard.

Layouts are stored in `/WIDGETS/AeroGrid/layouts/`. AeroGrid looks for these
files in order:

1. `<model-identifier>--<dashboard-id>.yaml` for a model-specific layout.
2. `<dashboard-id>.yaml` for a layout shared across models.
3. `default.yaml` if neither file exists.

Use a different Dashboard ID on each EdgeTX screen to select different layouts.
You can edit layouts on the radio in temporary fullscreen mode, or edit YAML
files on a computer and copy them to the SD card.

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

Save it as `/WIDGETS/AeroGrid/layouts/my-dashboard.yaml` and select
`my-dashboard` as Dashboard ID.

Positions are zero-based: `col: 0`, `row: 0` is the top-left cell. Spans specify
how many cells a panel occupies. Keep placements within the 4 x 4 grid without
overlap, use unique panel IDs, and choose spans supported by the panel.
The `type` selects the panel; `config` contains its settings.

See the [Panel reference](../reference-guide/index.md) for settings and examples.
Use exact, case-sensitive source names from your model's telemetry configuration.
Follow the YAML structure above and the panel examples.

## Edit a dashboard on the radio

Editing is available only in explicit fullscreen. Normal App mode remains
read-only even though the dashboard fills the display: it has no **EDIT** button
and tapping panels does not select them. Long-press the dashboard to enter
fullscreen.

Temporarily take AeroGrid fullscreen, then choose **EDIT** in the upper-right
corner or press Enter. The dashboard stays visible and live while editing.
The editor prepares its controls over several frames; wait for the bottom toolbar
to appear before selecting panels.
Tap an actual panel to select it; a cyan outline marks its bounds. The bottom
toolbar offers **Panel - / Panel +**, **Add panel**, **Move**, **Resize**,
**Configure**, **Remove**, **Defaults**, **Apply / Save**, and **Cancel**.
The editor supports touch and rotary/key input. Move panels one cell at a time; resize
keeps the selected panel's top-left cell fixed. Out-of-bounds moves, unsupported
spans, and overlaps are rejected and shown in the editor.

Move and Resize show grid guides over the dashboard. Tap a destination cell
to move, or the desired bottom-right cell to resize. Existing panels preview
their new bounds without constructing another instance; removing one hides it
until Apply. Newly added panels use a labeled preview card until Apply, so
draft additions cannot start a second flight tracker or other panel side effects.

Configuration and the panel catalog open in a drawer over the dashboard.
Use **Previous / Next** to scroll its entries, **- / +** to change a value,
and **Back to dashboard** to close the drawer. Text editing uses **Previous /
Next** to move the cursor, **- / +** to change the character, **Delete** to remove
it, and **Accept text** to finish. Configuration fields come from each panel's settings schema. Use the supplied
choices and numeric bounds where available; text fields accept source names as
typed, case-sensitive values. Adding or changing values only affects the
in-memory draft. **Apply / Save** validates the whole layout before writing it
to the model- and Dashboard ID-specific YAML file. The previous saved file is
kept as `.bak`. **Cancel** discards the draft without changing the active
dashboard or saved layout, restoring the original panel geometry and visibility.
**Defaults** replaces the draft with the shipped
default layout; it is not persisted until Apply / Save.

If the primary layout cannot be read, parsed, or validated, AeroGrid tries its
backup, then the shared Dashboard ID layout and its backup, and finally the
shipped default and its backup. Review the active path in the `host` diagnostics
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

Choose **Theme** in the widget settings. A layout's optional `theme` block
overrides that selection.

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
