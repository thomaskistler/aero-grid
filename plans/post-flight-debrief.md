# Post-flight debrief

> Design plan. No code has been written yet. Open questions are listed at the
> end and must be settled before implementation starts.

After a flight completes, AeroGrid shows a short summary of that flight: one
chart per value with the flight statistics that matter, with warning and
critical periods highlighted. The goal is to answer "how did that flight go?"
at a glance without opening a log file on a computer.

## User experience

### The pill

![Pill over the dashboard](assets/post-flight-debrief/frame1.png)

- When flight detection reports a completed flight, the dashboard shows a
  pill at the bottom center.
- Pill text:
  - Outside widget fullscreen: **Debrief ready · long-press, then swipe up**
  - In widget fullscreen or App mode: **Debrief ready · swipe up**
- The pill is plain text: no "new" dot, no arrow.
- The pill means "a new debrief exists". It stays until the debrief is opened
  or the session is reset.
- Each dashboard shows its own pill for its own debrief.

### Opening and closing

![Debrief](assets/post-flight-debrief/frame2.png)

- Swipe up opens the latest debrief; swipe down hides it. Swipe up always
  works after a flight, even after the pill has gone.
- Touch only works in widget fullscreen, so outside fullscreen the user
  long-presses first (hence the pill wording).

### Layout

![Debrief scrolled](assets/post-flight-debrief/frame3.png)

- **Header card:** model name, flight number, flight start date and time
  (for example "Flight 42 · Nov 17, 14:24"), and the flight time in large
  digits. No alarm-count badge.
- **Tiles:** a flat list of chart tiles, no sections. Tile sizes use the
  dashboard's 4 x 4 grid, like panels, so they scale with the screen:
  - **Compact** 2 x 2: half the width and half the height of the screen.
  - **Wide** 4 x 2 or 4 x 1: the full width, at compact height or half of it.
- The whole debrief scrolls vertically, header included. There is no scroll
  bar. The mockup images predate the grid-based sizes.
- A small grab handle sits at the top of the sheet.

### Tiles

Each tile is essentially a Chart panel configuration with one to three
series:

- Title at the top left, like a panel title. No colored side stripe.
- Legend: for each series, a flight statistic instead of the live value, for
  example `min 3.48V`, `max 186m`, `avg 20.3A`, `used 1,840 mAh`. The value
  is colored by the worst level the series reached (normal, warning,
  critical).
- Chart window is exactly the detected flight, with axis labels `0:00` and
  the flight time.
- Warning and critical periods are shaded amber and red, with dashed
  threshold lines.
- No markers at the minimum or maximum; the curve makes them obvious.
- Tapping a tile does nothing for now (no enlarged chart).

## Configuration

- The debrief is part of the **layout**, like its panels. Different
  dashboards can have different debriefs.
- A new AeroGrid menu item, **Flight debrief**, sits next to **Model
  settings** and **UI setup** and configures the debrief of the current
  layout.
- Edits follow the existing layout rules: changes are a draft until **Save**
  or **Save as**; editing a bundled layout creates a user copy.
- A debrief is an ordered list of tiles. Each tile has a title and one to
  three series; each series has a telemetry source and a statistic (min, max,
  avg, or used).
- Automatic population from the layout's panels is wanted but not yet
  designed.

## Data

### Telemetry sources

- Every debrief series is a telemetry sensor name. There are no special
  Battery, Link, or Navigation tile types.
- Values that AeroGrid computes itself are published as EdgeTX sensors with
  `setTelemetryValue`, so they can be charted, logged, and used anywhere
  else in EdgeTX. Only values EdgeTX cannot calculate itself are published:

  | Sensor | Panel | Unit | Value |
  | --- | --- | --- | --- |
  | `VCel` | Battery | V, 2 decimals | Lowest cell from a cells monitor, or pack voltage divided by the configured or estimated cell count |
  | `Mrgn` | Link | dB | ELRS RSSI margin |
  | `Drop` | Link | s | Accumulated time without a link |
  | `HDst` | Navigation | m | Distance to home, including a switch-captured home |
  | `FDst` | Navigation | m | Accumulated distance flown |

- The panels that compute these values (Battery, Link, Navigation) publish
  them automatically. No panel means no sensor; there is no move of this
  logic into Model settings.
- `Drop` and `FDst` behave like any other accumulating telemetry, such as
  consumption: they keep counting until EdgeTX telemetry is reset. The
  debrief shows a flight's share with the `used` statistic.
- Only the first panel of each type on a layout publishes; further panels of
  the same type are ignored.
- Panels publish from their background hook too, so sensors keep updating
  while the dashboard is hidden.

### Thresholds

- EdgeTX sensors carry no warning or critical thresholds.
- Panels register their configured thresholds with the dashboard's telemetry
  service, and debrief charts read them from there. Thresholds therefore come
  from panels on the same layout.

### Recording

- Charts reuse the Chart panel recording (`history_service`), including gaps
  for stale telemetry.
- At flight end, the flight slice of each series is copied at about chart
  width (roughly 200 points per series) and the statistics are computed.
- Each dashboard records its own debrief. Hidden dashboards keep their
  services running, so changing screens mid-flight loses nothing.
- Only the latest debrief is kept, in memory. A new flight replaces it, and
  it is lost on power off.

## Codebase anchors

| Area | Location |
| --- | --- |
| Flight phases and completion | `lib/flight_service.lua` |
| Touch and swipe forwarding | `main.lua` (touch event handling) |
| Panel background hook | `main.lua` (panel background tasks) |
| Recording engine | `lib/history_service.lua` |
| Shared telemetry subscriptions | `lib/telemetry_service.lua` |
| Battery cell logic | `panels/rx-battery.lua` |
| ELRS margin and link state | `panels/link-status.lua` |
| Distance and home | `lib/navigation_service.lua` |
| AeroGrid menu items | `lib/aerogrid_menu.lua` |
| Chart behavior to mirror | `docs/panels/chart.md` |

## Open questions

1. **Published sensors:** sensor IDs.
2. **Screen format:** legend overflow, the date when the
   radio has no real-time clock, and other screens (480 x 320, 800 x 480,
   portrait).
3. **Outside fullscreen:** confirm the long-press flow and that App mode
   accepts touch.
4. **Flight debrief setup page:** adding, removing, and reordering tiles,
   choosing statistics, and automatic population from the layout's panels.
5. **Small rules:** conflicting thresholds from two panels, whether Session
   reset clears the debrief, no flight detection configured, very short
   flights, and a tile limit to protect the 6 MiB Lua heap.
