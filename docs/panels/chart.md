# Chart

| 2x1 | 2x2 |
| --- | --- |
| ![Chart at 2x1](../assets/panels/chart/2x1.png) | ![Chart at 2x2](../assets/panels/chart/2x2.png) |

Records up to three numeric EdgeTX sources on one chart while armed or in flight.
The legend shows each recorded value and its minimum and maximum.
It sits on the right in wide panels and above the plot in square or tall panels.
Values that cannot fit show `...` rather than a truncated number.
Select **Arm switch** in **AeroGrid → Model settings**; changes save automatically.
For legacy switches, see [Older layouts](../user-guide/model-settings.md#older-layouts).

## Settings

![Chart panel settings with the default Auto window](../assets/editor/chart-settings.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **Label** | Blank | Optional chart heading. Clear it to hide the heading. |
| **Metrics** | No entries | Up to three readings. Tap **+** to add one, or tap an entry to edit it. |
| **Window minutes** | Auto | **Auto** grows the window as recording continues. A whole number of minutes from 1 to 60 fixes it. Step below 1 to select **Auto**. |
| **Series scales** | shared | **shared** uses one vertical scale; **independent** gives each metric its own scale, useful for unlike units. Independent trace heights are not directly comparable. |
| **Line smoothing** | off | **off**, **light**, **medium**, or **strong**. Smooths the line only, not the recorded value or extrema. |
| **Accent** | cyan | Normal panel accent; does not change trace colors. |

### Metric entry

Tap a reading under **Metrics** to open its settings.

![Chart metric entry settings with GV1 selected as Source](../assets/editor/chart-metric-entry.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **Label** | Source name | Name in the legend. Clear it to use the source name. |
| **Source** | required | Numeric EdgeTX source to record. |
| **Range min**, **Range max** | Auto | Tap to type a fixed lower or upper vertical bound. Negative numbers and decimals are accepted. If both are set, maximum must exceed minimum. Clear the text for **Auto**. |
| **Unit** | Sensor unit | Unit text beside the value. Changes the label, not the number. |
| **Precision** | Sensor | Decimal places, 0 to 3. Step below 0 to select **Sensor**, using the source's precision. |
| **Color** | by entry order | Trace and legend color: **cyan**, **green**, **orange**, or **amber**. Defaults to cyan, orange, then green; cyan uses blue ink in Modern Light. An explicit choice keeps that color. |

Use **Remove entry** in the entry's settings dialog to delete a reading.

## Behavior

### Recording and pauses

Recording starts while armed. A confirmed flight using the same arm condition
keeps recording through the disarm grace period, including on hidden dashboards.
Otherwise, disarming pauses immediately. Readouts freeze when recording pauses;
minimum and maximum cover all recorded periods.

Recording also pauses while the editor or Model settings is open on any
AeroGrid dashboard. Resuming adds a gap with faint connectors between the
last and resumed values. The gap indicates omitted time, not the pause's length.
Missing or stale telemetry breaks traces without recording a false zero;
a fresh numeric zero is valid.

### Flight markers

A neutral band shades each confirmed flight, using its actual start and end
times rather than the later confirmation times. Samples recorded during
disarm grace remain beyond the band's end. No Flight counter panel or logical
switch output is needed. A chart opened mid-flight shades only its recorded portion.

Upward triangles on the bottom axis mark arming; downward triangles mark disarming.
The first arming that starts recording is not marked. The latest 64 flight
intervals are retained for shading.

### Time window and scales

The horizontal axis starts at recording time zero. With **Auto**, the window
starts at 1 minute and expands as recording continues, keeping earlier data
on screen. A full fixed window slides left by 1 minute, dropping the oldest
minute. The bottom-right label shows the recording-time window; pause gaps
also use space in it.

An **Auto** bound starts close to the first reading. When drawn data leaves the
range, the scale expands to fit it. Auto bounds only grow until
the panel is resized or the session is reset. With **shared** scales, the lowest
configured minimum and highest configured maximum apply to all traces, and Auto
sides follow all traces. With **independent** scales, each metric uses its own
bounds. Fixed bounds clip the plot, not recorded values or extrema.

Smoothing changes the line, not readouts or extrema. **Light**, **medium**, and
**strong** respond over approximately 0.5, 1, and 2 seconds.

### Clearing and limits

If **HISTORY FULL** appears, existing plot history is preserved and new plot
samples stop for the full series. Readouts and extrema continue
updating.

History is not saved to the SD card. Restarting or rebuilding the dashboard
clears recordings. Opening or resizing a chart starts an empty plot at the
current recording time; earlier traces are not restored. Editor previews do
not record or replay traces. New sources show a no-data preview until saved.

Use **Session reset switch** in
[Model settings](../user-guide/model-settings.md#session-reset) to clear recordings,
extrema, and markers across all dashboards.

## States

| Condition | Presentation |
| --- | --- |
| **SET ARM SOURCE** | Select **Arm switch** in Model settings; recording is disabled without an effective switch. |
| **ARM N/A** | The selected armed switch condition is unavailable and no matching active flight is keeping recording running. |
| **ADD METRICS** | Add a source in the panel settings. |
| **WAITING FOR ARM** | No samples have been recorded yet. |
| **NO DATA** | Recording, but no configured source has supplied a valid numeric sample. |
| **HISTORY N/A** | History is unavailable; consult [Host diagnostics](host-diagnostics.md). |
| **HISTORY FULL** | A series has stopped adding plot samples to preserve its recording; readouts and extrema still update. |
| **PREVIEW** | An edited chart whose recording already exists; the preview does not draw its traces or change recording. |
| **PREVIEW: NO DATA** | A new or incompatible recording configuration; sampling starts after saving. |
