# `trim-panel`

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Trim panel at 1x2](../assets/panels/trim-panel/1x2.png) | ![Trim panel at 2x1](../assets/panels/trim-panel/2x1.png) | ![Trim panel at 2x2](../assets/panels/trim-panel/2x2.png) |

Displays the radio's **effective trim positions**, including trim values
inherited from another flight mode. The panel is read-only; use the radio's
trim controls to change a trim. It needs no aircraft telemetry.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `trim1` | `trim-ail` | Source displayed as aileron (top bar). |
| `trim2` | `trim-ele` | Source displayed as elevator (left bar). |
| `trim4` | `trim-rud` | Source displayed as rudder (bottom bar). |
| `scale` | `auto` | `standard`, `extended`, or `auto`; see below. |
| `readout` | `percent` | `percent`, `raw` (stored trim units), or `none`. |
| `label` | `TRIM` | Panel heading. |
| `accent` | `cyan` | Panel accent: `cyan`, `green`, `amber`, or `orange`. Trim fills remain green. |

Each source setting must name an available trim source. Its fixed position and
A/E/R readout suffix identify its aileron, elevator, or rudder role. Unknown
settings are rejected when the layout is loaded.

## Behavior

Aileron is the top bar, elevator the left bar, and rudder the bottom bar.
Fill extends from neutral toward the current trim. The white dot shows
aileron/elevator position and disappears if either source is unavailable.

Choose signed percentages, raw values, or no readout with `readout`.
The `A`, `E`, and `R` suffixes identify each axis. Three-position trims
show `3P MID`, `3P HI`, or `3P LO`.

Use `scale: auto` to follow standard travel and switch to extended travel
when needed. Select `standard` or `extended` to keep a fixed range.

## States

An unavailable trim shows `--` where there is room for a readout (`-- A`,
`-- E`, or `-- R`) and a faint rather than green bar.
The whole panel shows an `N/A` badge only when none of its three sources
is readable.

## Examples

The default three-axis panel:

```yaml
- id: trims
  type: trim-panel
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    readout: percent
    scale: auto
```

A compact three-axis panel with stored-unit readouts:

```yaml
- id: compact-trims
  type: trim-panel
  col: 1
  row: 1
  colSpan: 1
  rowSpan: 1
  config:
    readout: raw
```
