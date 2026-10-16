# `output`

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Channel output at 1x2](../assets/panels/output/1x2.png) | ![Channel output at 2x1](../assets/panels/output/2x1.png) | ![Channel output at 2x2](../assets/panels/output/2x2.png) |

Native EdgeTX simulator captures with synthetic output and stick-trim readings.

Displays the radio's final channel outputs, after output limits and reversal.
No aircraft telemetry is required. Add **Channel output** in the on-radio editor.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `showNames` | `true` | Show up to three letters of the channel name when space permits. |
| `showTrim` | `true` | Show the corresponding effective stick-trim arrow. |
| `firstChannel` | `1` | First channel to show, from 1 to 32. |
| `channelCount` | Auto | Number of consecutive channels to show, from 1 to 32. Omit to fill available rows. |
| `label` | `CHANNEL OUTPUT` | Panel heading. |
| `accent` | `cyan` | Panel and output-fill accent: `cyan`, `green`, `amber`, or `orange`. |

## Behavior

Channels appear consecutively starting at **First channel** (CH1 by default).
**Channel count** defaults to Auto, filling available rows; a configured count
is capped by the available space and CH32. The panel adjusts when resized.
**Show channel names** and **Show trim** are independent, default-on toggles
saved per panel. Hiding names leaves just `CH<N>` and more room for the tape;
hiding trims removes the green arrows without changing output readings.
Channel names come
from the model's Outputs page. When an Output is unnamed, the panel uses its
enabled mix name, Input name, input-line name, or source name, in that order.
Conflicting names from active mixes are omitted rather than guessed.
Up to three letters follow the channel number
(for example, `CH1: AIL`), and are omitted when the name will not fit.
Side-by-side rows omit names unless at least 64 pixels remain for the tape.

A green downward arrow shows the corresponding **effective stick trim**, not
output subtrim or the trim's calculated contribution to servo travel. The arrow
uses the trim panel's automatic standard/extended trim scale.

## States

An unreadable output shows `--`, with its fill and trim arrow hidden. If no
visible channel is readable, the panel displays `N/A`.

## Examples

```yaml
- id: outputs
  type: output
  col: 0
  row: 0
  colSpan: 4
  rowSpan: 2
  firstChannel: 9
  channelCount: 8
  showNames: true
  showTrim: false
```
