# `rx-battery`

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![RX battery at 1x2](../assets/panels/rx-battery/1x2.png) | ![RX battery at 2x1](../assets/panels/rx-battery/2x1.png) | ![RX battery at 2x2](../assets/panels/rx-battery/2x2.png) |

Displays aircraft-battery voltage from either an EdgeTX **cells monitor** or
a numeric **pack-voltage sensor**, such as `RxBt`. The source must actually
measure the flight battery; regulated receiver supply voltage does not reveal
pack voltage.

The headline always shows two decimals. This is display precision, not a
promise of sensor accuracy or resolution. The panel does not infer remaining
capacity from voltage.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `label` | `PACK` | Panel heading. |
| `sourceType` | `cells` | Selects the cells-table or pack-voltage source shape. |
| `source` | `Cels` | Exact EdgeTX source name, edited in the selected source subdrawer. |
| `reading` | `cell` | `cell` or `pack`. A cell reading is the table's lowest cell in cells mode and the calculated average in pack mode. |
| `showPack` | `true` | Show the supporting pack voltage, or the calculated average when pack voltage is primary. |
| `showCount` | `true` | Show the cells-monitor count or the pack's configured/estimated series count. |
| `cells` | `0` | Pack mode only: `0` estimates series count; 1–16 sets it explicitly. Cells mode gets its count from the monitor. |
| `cellFull` | `4.2` | Full usable-range voltage, in V/cell. |
| `warning` | `3.6` | Warning threshold, in V/cell. |
| `critical` | `3.4` | Critical threshold, in V/cell. |
| `cellEmpty` | `3.2` | Empty usable-range voltage, in V/cell. |
| `visual` | `battery` | `battery`, `bar`, or `none`. The visual measures voltage against the usable per-cell range, not remaining charge. |
| `accent` | `cyan` | Semantic accent: `cyan`, `green`, `amber`, or `orange`. |

The editor presents **Label** first, then **Source type** and one summarized
source subdrawer: **Cells monitor** or **Pack voltage**. Primary reading and
supporting voltage/count controls remain in the main drawer. Voltage levels
are grouped under **Voltage levels**, in Full, Warning, Critical, Empty order,
with V/cell shown in each label. The appearance heading groups visualization
and accent inline. Full and Empty are hidden while visualization is `none`.

Voltage levels must be coherent: **Full > Warning >= Critical >= Empty**.
Unknown settings and invalid threshold ordering are rejected.

### Layout schema and migration

Current layout files use schema version 2. For example:

```yaml
version: 2
grid:
  columns: 4
  rows: 4
panels:
  - id: flight-pack
    type: rx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: RX battery
      sourceType: pack
      source: RxBt
      cells: 0
      reading: cell
```

When a version-1 layout is loaded, the runtime migrates it **in memory** before
panel validation/loading: `cell-battery` becomes `rx-battery`, `lowestSource`
is removed, cells-mode `cells` is removed, and `lowest`/`average` readings
become `cell` (`pack` remains `pack`). Explicit voltage levels are preserved;
omitted values use the new defaults above. A brief upgrade notice explains
that the migrated layout is not yet saved. Loading never overwrites a layout:
use the editor's explicit **Save** action to persist it as version 2. Newer or
malformed layout versions are rejected rather than interpreted with older
assumptions.

The central migration registry has one adjacent helper per layout version for
both headers and panels. Runtime loading and staged Save apply at most one
transition per callback, so future upgrades do not require an unbounded pass
through the migration chain in a single callback.

## Behavior

In **cells** mode, `source` must return the cells table. The sensor supplies
the cell count and pack sum. A `cell` headline uses the lowest valid cell;
alarms always judge that lowest cell, even when `reading: pack` is selected.

In **pack** mode, `source` must return a numeric total voltage. With
`cells: 1`–`16`, the panel calculates average cell voltage from pack voltage
and series count. With `cells: 0`, it estimates count by dividing the first
fresh, valid pack voltage by `cellFull` and rounding to the nearest integer.
The count is held for that telemetry connection rather than recalculated as
voltage falls; after a disconnect, the next fresh reading starts a new
estimate. An estimated count is marked `EST`. Estimation assumes the first
reading is near full, so starting the radio mid-flight, a partly charged pack,
load sag, or an unusual chemistry can produce the wrong count. Configure the
known series count when possible. Pack voltage cannot reveal a weak or
unbalanced cell, so alarms judge only its calculated average.

All four voltage levels are in **volts per cell**. The battery/bar spans
`cellEmpty` to `cellFull`; alarm thresholds are separate. `critical` is checked
before `warning`. A pack headline is total voltage, while its fill is still
normalized using average volts per cell.

## States

| State | Condition | Presentation |
| --- | --- | --- |
| `normal` | Valid, fresh judged voltage above `warning` | Reading and visual in their normal colors. |
| `warning` | Judged voltage at or below `warning` | Amber state color, tinted panel, `WARN` badge. |
| `critical` | Judged voltage at or below `critical` | Red state color, tinted panel, `CRIT` badge. |
| `stale` | Retained reading whose source is stale | Last voltage retained, muted presentation, `STALE` badge. |
| `unavailable` | No usable headline | `--`, no unit or battery glyph, `N/A` badge. |

In cells mode, an empty table shows `NO CELLS`; a numeric source used as a
cells monitor or an unusable table shows `CELLS ERR`. Invalid pack voltage
shows `VOLT ERR`. Before any reading arrives, the count row is blank.

## Examples

Cells monitor:

```yaml
- id: monitored-pack
  type: rx-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    sourceType: cells
    source: Cels
    reading: cell
```

Pack-voltage source with an explicit series count:

```yaml
- id: flight-pack
  type: rx-battery
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    sourceType: pack
    source: RxBt
    cells: 4
    reading: cell
```
