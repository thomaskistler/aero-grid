# `navigation`

## Size examples

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Navigation at 1x2](../assets/components/navigation/1x2.png) | ![Navigation at 2x1](../assets/components/navigation/2x1.png) | ![Navigation at 2x2](../assets/components/navigation/2x2.png) |

Fixed synthetic model/home coordinates produce 318 m distance and 046-degree
north-up bearing. `presentation: auto` adapts from distance-only at 2x1 to
bearing detail at 1x2 and a compass at 2x2.
Real EdgeTX simulator renders with synthetic GPS inputs, TX16S 480 x 272,
Modern theme, menu-free placement, and 10 px black padding.
Spans mean columns x rows. Supporting text is brighter for documentation.
See [capture settings and regeneration](../developer-guide/build.md#component-screenshot-prototype).

Shows the aircraft's GPS location, distance from home, and **north-up bearing
from home toward the model**. The arrow is not aircraft heading, transmitter
orientation, or a return-home instruction.

The GPS source supplies model coordinates and the pilot/home coordinates
recorded by EdgeTX. AeroGrid does not set or reset home.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `source` | `GPS` | Exact EdgeTX GPS source name; must return a coordinate table. |
| `distanceSource` | empty | Optional native distance sensor, preferred when usable; otherwise distance is calculated from GPS. |
| `presentation` | `auto` | `distance`, `bearing`, `compass`, `detailed`, or `auto`. |
| `bearingFormat` | `degrees` | Numeric azimuth or `quadrant` notation. |
| `showBearing` | presentation default | Independently show or hide the bearing text row. |
| `showCoordinates` | presentation default | Independently show or hide the latitude/longitude row. |
| `warning` / `critical` | none | Distance thresholds in metres, counting upward. |
| `label` | `NAV` | Panel heading. |
| `accent` | `cyan` | Panel accent: `cyan`, `green`, `amber`, or `orange`. |

Unknown settings are rejected at load. Source names are case-sensitive.

## Presentations

Distance remains the main reading in every presentation.

| Presentation | Compass | Bearing text | Coordinates |
| --- | --- | --- | --- |
| `distance` | no | no | no |
| `bearing` | no | yes | no |
| `compass` | yes | yes | no |
| `detailed` | yes | yes | yes |

`auto` selects distance at one cell, bearing at two or three cells, compass
at four or five cells, and detailed at six or more cells.

`showBearing` and `showCoordinates` override the text defaults without
changing the compass selection. Either row, both, or neither can be requested.
Coordinates-only panels use a single footer row.

**One-row panels cannot show supporting text**, even with explicit row
settings. A `2x1` with `presentation: bearing` therefore shows distance only.
Use a two-row span for bearing text or coordinates. Detailed panels retain
both rows at normal 2x2 sizes using regular supporting text and tighter spacing.
Shorter zones can shed rows.

Supported spans are `1x1` through `4x1`, `1x2` through `4x2`,
`2x3` through `4x3`, and `2x4` through `4x4`.

## Compass

The dial has a continuous outer circle, inward tick marks, and inset N/E/S/W
labels. A filled concave arrow points toward the model's bearing from home.
Its size reserves clearance from the cardinal text at every rotation.

The normal arrow is green; alarm and stale states use their state accent.
An unavailable bearing hides the arrow, not a misleading pointer at north.
The ring and labels remain when the dial fits.

Explicit `compass` and `detailed` presentations reserve room for the dial
and reduce the distance font when necessary. `auto` prioritizes the distance
font and can shed the dial. Very small zones still shed unreadable dials.
The dial's diameter is capped at 64 pixels and constrained by available space.

## Bearing and coordinates

`bearingFormat: degrees` shows numeric azimuth, such as `BRG 009 N`,
shortening its caption and cardinal suffix when necessary.

`bearingFormat: quadrant` measures an angle from north or south toward east
or west: `N29°E`, `S29°E`, `S29°W`, or `N29°W`. Exact axes show N/E/S/W.
The `BRG` prefix is shed first, then a narrow panel falls back to an
eight-point cardinal direction. Bearings round to whole degrees.

Bearing text and the arrow update with GPS position. Coordinates show model
latitude and longitude in decimal degrees, each with five decimal places.
This is display precision, not a guarantee of GPS accuracy.

## Distance and states

Computed distance uses a great-circle calculation in metres, displayed in
metres or kilometres as appropriate. A configured native distance source
can provide its own supported unit. Distance units are never dropped:
the font steps down so the unit and reading fit together.

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

A compass with quadrant bearing and no coordinates:

```yaml
- id: location
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    presentation: compass
    bearingFormat: quadrant
    warning: 500
    critical: 1000
```

Coordinates without bearing text, retaining the compass:

```yaml
- id: position
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    presentation: compass
    showBearing: false
    showCoordinates: true
```

Both text rows without a compass:

```yaml
- id: position-text
  type: navigation
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    presentation: bearing
    showCoordinates: true
```
