# Chart

![Chart at 2x2](../assets/panels/chart/2x2.png)

![Chart at 2x1](../assets/panels/chart/2x1.png)

One chart overlays up to three numeric telemetry sources. An optional title sits above
the plot; the compact right legend groups each source's name and recorded value
with its recorded minimum and maximum on the next line.
Traces use a one-pixel line. Numeric readings and units occupy separate shared
columns, so different unit widths do not shift the values out of alignment.
The legend starts just below the plot's top when space permits; short panels
keep the groups within the panel. Each extrema row centers the minimum and
maximum together beneath the label and value, with a small fixed gap between them.

## Settings

| Setting | Purpose |
| --- | --- |
| **Label** | Optional title above the plot. Empty hides the title and lets the chart reclaim its header space. |
| **Metrics** | Zero to three sources. Tap **+**, then choose each entry's **Source**, optional **Label**, **Unit**, **Precision** (0–3, or Sensor), and **Color**. |
| **Range min**, **Range max** | Optional per-entry vertical bounds. Both default to **Auto**, one step below the lowest allowed numeric value. Select a number to fix that bound, or return to **Auto** to clear it. If both are entered, maximum must exceed minimum. |
| **Time range** | Growing keeps the recording visible by doubling its time scale; rolling shows the latest fixed window. |
| **Initial / window duration** | 30 seconds, 1 minute, 2 minutes, 5 minutes, or 10 minutes. This is the initial growing range or the rolling window. |
| **Series scales** | Shared uses one vertical scale. Independent gives each trace its own scale, suitable for voltage/current or RSSI/link quality. Independent heights are not directly comparable. |
| **Line smoothing** | Off, light, medium, or strong. The exponential filter has approximately 0.5, 1, or 2 seconds of response time; only the line is filtered. |
| **Accent** | Panel stripe color, independent of trace colors. |

Configure the dashboard's shared `session.armSource` in its layout YAML before
recording. It is a numeric EdgeTX source, such as `sa` or `ch5`; positive means
armed. This dashboard setting is currently YAML-only. See the
[YAML reference](../reference-guide/yaml.md#chart).

### Vertical bounds

Each bound is independent: set only **Range min** to anchor the bottom while the
top grows automatically, set only **Range max** to fix the top, or enter both for
a fixed range. **Auto** follows raw recorded extrema with padding and rounded
bounds. Explicit bounds clip the plot, not the recorded values or legend extrema.
An automatic bound always leaves a nonzero span, even if all readings fall
outside the configured opposite bound.

With **Shared** series scales, the lowest entered minimum and highest entered
maximum define the common bounds. If nobody specifies one side, that side follows
all series' recorded extrema automatically. With **Independent**, each metric's
bounds apply only to its own trace. The former panel-wide **Value range** selector
is no longer needed.

## Behavior

Recording starts when armed, pauses when disarmed, and **continues the existing
recording on rearm**. Disarmed time does not occupy horizontal space. A dashed
marker and a broken trace distinguish resumed recordings or gaps in telemetry.
The right-hand value freezes when disarmed; the down/up triangles show raw minimum
and maximum across all recorded armed periods, including in rolling mode.

Growing mode starts at the selected duration. Exceeding 30 seconds, for example,
changes the range to 60 seconds, shrinking existing history into the left half.
Rolling mode discards old plot detail while preserving lifetime recorded extrema.
Faint solid vertical lines mark whole minutes of cumulative armed time. Longer
or narrower views use 2/5/10-minute steps and larger equivalents to avoid
crowding. These gridlines are distinct from the brighter dashed interruption
markers. A small indicator such as **30s** or **2m** shows the visible duration
inside the plot's bottom-right corner, replacing the bottom axis labels without
reserving a separate row.

Sources share firmware polling with other panels. Raw extrema are collected at
each successful poll, even when the chart redraws less often. Drawing frequency
adapts to the horizontal time resolution. Connected linear segments compress
every observed sample with a maximum vertical error of **half a displayed step**:
for example, precision 1 allows ±0.05 in the source's native units. The metric's
**Precision** override determines this tolerance; **Sensor** uses sensor precision.
When smoothing is enabled, the bound applies to the filtered line, not raw
readings. Raw readouts and extrema remain uncompressed. This is a streaming
bounded-error approximation, not a globally minimum-size encoding.

Each distinct source/options recording holds up to **6,144 knots**, enough for
at least **10 minutes at 10 samples/second** without compression savings.
Smoother signals can fit much longer. Growing mode never recompresses older data
at a looser tolerance. If storage fills, **HISTORY FULL** appears: existing plot
history is preserved and new plot samples stop, while armed readouts and raw
extrema continue updating. Other non-full series keep recording. Rolling mode
reuses storage after old knots leave its window; it retains a boundary knot for
interpolation.

Redraws are staged across callbacks. Within a single screen pixel column the
renderer retains endpoints and extrema, so multiple recorded samples can
contribute even when they share a horizontal pixel. Stored history is unchanged
by this display-only reduction. Gaps remain broken and marked; pixel-coincident
gaps share a marker.

All series occupy **one plot**, not separate mini-charts. Use multiple panels for
separate charts. Supported spans are 2x1, 3x1, 4x1, 2x2, 3x2, 4x2, 3x3, 4x3,
and 4x4; additional height enlarges the plot and can allow larger legend text.
The panel respects the App menu exclusion area.
Metric names and values scale with the widget's actual pixel
height, number of metrics, and readout widths. Legend text is capped at medium
size and cannot grow just because a short value leaves spare width. Larger fonts use at most half
the available content width for the legend, leaving room for the plot. Text never
shrinks below the small readable font; longer readouts can reduce the chosen size,
and resizing recalculates it.
Minimum and maximum use one font step smaller than the metric name/value.
Small filled downward/upward triangles identify them independently of the font.
Units appear only beside the main value, not the minimum and maximum.
Metric groups have up to six pixels of vertical separation when space permits;
the gap shrinks in crowded panels without changing the text sizes or hiding
extrema that otherwise fit.

Larger text does not hide extrema that would fit at the minimum font. When the
panel is too short even at that minimum (for example, three sources in a 2x1
panel), extrema rows are hidden rather than shrinking the text or overlapping
the recorded values. Use a taller panel to show all readouts.

History lives in RAM and continues while the dashboard receives background
callbacks. Geometry-only reflow preserves it. Reloading/restarting the dashboard,
including applying editor changes that rebuild it, clears history. There is no
separate reset control or persistent recording.

## States

Missing telemetry creates a gap and dims the last recorded value, without recording a false zero.
An actual fresh numeric zero remains valid.

| Message | Meaning |
| --- | --- |
| **SET ARM SOURCE** | Configure `session.armSource`; recording is disabled without it. |
| **ARM N/A** | The configured arm source is unavailable; recording is paused. |
| **ADD METRICS** | Add a source in the panel settings. |
| **WAITING FOR ARM** | No samples have been recorded yet. |
| **NO DATA** | Armed, but no configured source has supplied a valid numeric sample. |
| **HISTORY N/A** | The history service is missing or has failed; consult diagnostics. |
| **HISTORY FULL** | At least one series has stopped adding plot samples to preserve its existing recording. Raw readouts and extrema still update while armed. |
