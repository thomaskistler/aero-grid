# `text`

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Text at 1x2](../assets/panels/text/1x2.png) | ![Text at 2x1](../assets/panels/text/2x1.png) | ![Text at 2x2](../assets/panels/text/2x2.png) |

Displays one to three text readings selected by physical switch positions.
The first entry is the main reading; the others are supporting readings.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `texts` | required | Ordered list of one to three entries. |
| `accent` | `cyan` | Normal accent: `cyan`, `green`, `amber`, or `orange`. |

Each entry has these settings:

| Entry key | Default | Meaning |
| --- | --- | --- |
| `label` | required | Main heading or supporting caption. |
| `source` | required | Lowercase physical switch source, such as `sa` or `sb`; the switch must exist on your radio. |
| `positions.up` | required | Text for the up position (`-1024`). |
| `positions.middle` | absent | Text for the middle position (`0`); configure it for a three-position switch. |
| `positions.down` | required | Text for the down position (`+1024`). |

Labels and mapped texts must be nonempty single-line strings. Quote texts
that YAML could interpret as numbers or booleans, such as `"ON"` and `"OFF"`.

## Behavior

Map both ends for a two-position switch. Add `middle` for a three-position
switch. An omitted middle mapping does **not** reuse either end.

Switch readings work without receiver telemetry. They describe transmitter
switch positions, not confirmed aircraft state. Texts such as `ARMED` are
your own labels: verify their relationship to your model's configuration.
No text implies an alarm color; all mapped positions use the selected accent.

Supporting captions and texts appear below the main reading or in a compact
side stack when there is room. They are hidden when they cannot fit intact.
Text is never shortened to suggest a different switch state.

## States

| Condition | Presentation |
| --- | --- |
| Known, mapped main position | Exact configured text and normal accent. |
| Main source unknown or unavailable | `--` and `N/A` badge. |
| Position has no mapping, or value is not a switch position | `UNMAPPED` (or `?` in a narrow reading slot) and `N/A` badge. |
| Configured main text cannot fit even at the smallest font | `NO FIT` and `N/A` badge; widen the panel or shorten the configured texts. |
| Supporting source unavailable or unmapped | Caption with `--` (unavailable) or `?` (unmapped); main state is unchanged. |
| Invalid configuration | Layout diagnostic rather than an inferred mode. |

## Examples

A two-position switch and two supporting three-position switches:

```yaml
- id: switch-text
  type: text
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    accent: green
    texts:
      - label: MODE
        source: sf
        positions:
          up: DISARMED
          down: ARMED
      - label: RATE
        source: sa
        positions:
          up: LOW
          middle: MEDIUM
          down: HIGH
      - label: FLAP
        source: sb
        positions:
          up: RETRACT
          middle: TAKEOFF
          down: LAND
```

Use only the first entry for a single reading, or omit the third for two.
Choose switches and texts appropriate to your radio and model.
