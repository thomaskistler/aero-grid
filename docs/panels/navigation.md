# `navigation`

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Navigation tape below distance at 1x2](../assets/panels/navigation/1x2.png) | ![Navigation tape beside distance at 2x1](../assets/panels/navigation/2x1.png) | ![Navigation tape below distance at 2x2](../assets/panels/navigation/2x2.png) |

Native EdgeTX simulator captures with `showTape: true`, a synthetic GPS fix,
and a computed distance of 318 m. Spans above are columns x rows.

Shows the aircraft's GPS location, distance from home, and **north-up bearing
from home toward the model**. The tape is not aircraft heading, transmitter
orientation, or a return-home instruction.

The GPS source supplies model coordinates and the pilot/home coordinates
recorded by EdgeTX. AeroGrid does not set or reset home.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `source` | `GPS` | Exact EdgeTX GPS source name; must return a coordinate table. |
| `showTape` | `false` | Show the bearing tape instead of bearing text. |
| `bearingFormat` | `degrees` | Numeric azimuth or `quadrant` notation when the tape is off. Hidden in the drawer when the tape is on. |
| `showCoordinates` | `false` | Independently show or hide the latitude/longitude row. |
| `warning` / `critical` | none | Distance thresholds in metres, counting upward. |
| `label` | `NAV` | Panel heading. |
| `accent` | `cyan` | Panel accent: `cyan`, `green`, `amber`, or `orange`. |

Unknown settings are rejected at load. Source names are case-sensitive.

## Behavior

Distance from home is always the main reading, using the configured GPS
source. Home is the position recorded by EdgeTX.

Enable **Show tape** to replace bearing text with a scrolling direction tape.
The tape sits below the distance in square and tall panels, and to its right
in wide panels. Resizing updates this arrangement immediately. Stacked tapes
leave at least 10% of the panel width clear on each side; wide tapes leave
at least 10% clear on the right.

The tape spans 210 degrees and scrolls beneath a fixed pointer. Only `N`, `E`,
`S`, and `W` are labeled: with north centered, west and east are fully visible
at the sides. Major ticks and aligned dots mark every 30 degrees; shorter
minor ticks mark every 10 degrees. Cardinal labels replace the dots at those
positions. Shading and highlighted edges give the tape a recessed appearance,
with softer shadows and darkened rims on light surfaces. Tape shading follows
the panel's warning or critical tint and returns to normal when the alert clears.

When bearing is unavailable, the pointer, ticks, labels, and dots disappear,
and the tape shows the reason instead of implying a due-north bearing.
Stale data retains its last bearing with the panel's `STALE` indication.

With the tape off, choose degrees or quadrant notation, such as `N29°E`,
with `bearingFormat`. Bearing text and coordinates are shown only where they
fit; a tape that cannot fit yields to the distance. Coordinates show the
model's latitude and longitude. Set distance thresholds in metres if needed.

### Layout schema and migration

Current layout documents use `version: 3`. Versions 1 and 2 are upgraded in
memory when loaded; an explicit editor Save persists the upgraded document.
The old `presentation` and `showBearing` settings are removed during migration.

| Old `presentation` | `showTape` | `showCoordinates` if not explicitly set |
| --- | --- | --- |
| `distance` or `bearing` | `false` | `false` |
| `compass` | `true` | `false` |
| `detailed` | `true` | `true` |
| `auto` or omitted | `true` for 4+ cells; otherwise `false` | `true` for 6+ cells; otherwise `false` |

An explicit `showCoordinates` value is preserved, as are the source, label,
bearing format, thresholds, and accent. Legacy automatic choices are resolved
using the saved grid span; resizing does not change those settings afterward.
New widgets default to tape off and coordinates off.

There is no longer a distance-only mode: configurations that previously hid
both compass and bearing text now request bearing text. With the tape on,
`showBearing` has no replacement because tape and bearing text are exclusive.

### Location details and Google Maps

In fullscreen, tap the navigation panel to open location details. A large QR
code links to Google Maps at the **model's GPS coordinates**, not home.
The code and coordinates are frozen when opened so they remain stable while
scanning; close and reopen to capture a newer position. A stale fix is clearly
marked **LAST KNOWN POSITION**. Without a valid GPS position, tapping the panel
does nothing.

Tap anywhere or use the radio's **RTN/Back/Exit** key to return to the dashboard.
The popup uses the same surface, accent stripe, and state styling as the panels.
This action is unavailable
outside fullscreen and while editing. QR generation happens on the radio
without a network connection; opening the link on your phone uses Google Maps.

## States

Warning and critical thresholds are always metres, including when the
display uses kilometres. Critical is checked before warning.

| Condition | Presentation |
| --- | --- |
| Valid fix and home | Distance, live bearing, and requested coordinates. |
| No recognized GPS source | `--`, `N/A` badge, `NO GPS SOURCE` or a shorter form where a footer fits. |
| Source present but no fix | `--`, `N/A` badge, `NO FIX` where a footer fits. |
| Valid fix but no home | No distance or bearing; coordinates remain available. `NO HOME POSITION` or a shorter form, no failure badge. |
| Stale position | Last reading retained, `STALE` badge, `LAST KNOWN` or `LAST` where a footer fits. |
| Distance at or above warning/critical | Amber/red state presentation and `WARN`/`CRIT` badge. |

Zero latitude and longitude together are treated as no fix, matching
EdgeTX's uninitialized GPS values. A valid `0m` reading means the model is
at home, not that GPS is unavailable.

## Examples

A tape with distance thresholds and no coordinates:

```yaml
- id: location
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    showTape: true
    warning: 500
    critical: 1000
```

Tape and coordinates:

```yaml
- id: position
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    showTape: true
    showCoordinates: true
```

Quadrant bearing text and coordinates without a tape:

```yaml
- id: position-text
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    showTape: false
    bearingFormat: quadrant
    showCoordinates: true
```
