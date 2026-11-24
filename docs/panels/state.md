# State

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![State at 1x2](../assets/panels/text/1x2.png) | ![State at 2x1](../assets/panels/text/2x1.png) | ![State at 2x2](../assets/panels/text/2x2.png) |

Displays one to three readings selected by physical or logical switch conditions.
The first entry is the main reading; the others are supporting readings.
Switch positions describe transmitter controls, not confirmed aircraft state.

## Settings

![State panel settings](../assets/editor/state-settings.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **Entries** | No entries | Up to three readings. The first is the main reading; the others are supporting readings. Tap **+** to start the first entry blank or copy the last entry, including its states. |
| **Accent** | cyan | Normal panel accent; the main entry's **Background** can override it. |

### State entry

Tap a reading under **Entries** to open its settings.

![State entry settings](../assets/editor/state-entry.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **Label** | STATE | Panel heading for the main reading; caption for supporting readings. Single-line text. New entries copy the last entry's label. |
| **States** | No states | Up to three ordered conditions. Tap **+** to append a blank state, rather than copying the last state. |

Tap a reading to edit, move, or delete it.

### State condition

Tap a condition under **States** and choose **Edit** to open its settings.

![State condition settings](../assets/editor/state-condition.png)

| Setting | Default | What it does |
| --- | --- | --- |
| **When** | Not selected | Physical switch position, such as `SF^`, `SA-`, or `SFv`, or logical switch `L01`–`L64`. Prefix a logical switch with `!` to match when it is off, for example `!L04`. The first true condition wins. |
| **Text** | Empty | Exact single-line text displayed when this condition wins. |
| **Background** | normal | Main entry's whole-panel presentation: **normal**, **active**, **warning**, or **critical**. Supporting entries do not control the panel presentation. |

Tap a condition to move or delete it.

## Behavior

Conditions are evaluated in insertion order. The first true condition wins.
An unknown, unavailable, or stale earlier condition stops evaluation rather
than silently falling through. If none matches, the entry is unmapped; it
never retains the previous state. New states append at the bottom. To change
priority, use **Move up** or **Move down**.

Switch readings work without receiver telemetry. Texts such as `ARMED` are
your own labels: verify their relationship to your model's configuration.
No text implies an alarm color. The main entry's winning **Background** selects
the entire panel's shared presentation: panel surface, sidebar, text colors,
and badge. **active** uses the same blue presentation and `IN-FLIGHT` badge as
the flight counter; **warning** and **critical** use their shared colors without
displaying `WARN` or `CRIT` badges.
**normal** restores the configured **Accent** and normal surface. An unavailable
or unmapped main entry clears the mode and uses the unavailable presentation.
Supporting entries update their own readings but never override the panel mode,
even when their conditions specify a different **Background**.

Supporting captions and texts appear below the main reading or in a compact
side stack when there is room. They are hidden when they cannot fit intact.
Text is never shortened to suggest a different switch state. Space is reserved
for the widest configured text, not just the currently selected one.

## States

| Condition | Presentation |
| --- | --- |
| No entries, no states, or an earlier condition missing **When** or **Text** | `--` and unavailable presentation. An empty panel uses the `STATE` heading. |
| First true main condition | Exact configured **Text** and its whole-panel **Background**. |
| Earlier main condition unknown, unavailable, or stale | `--` and `N/A` badge, with no active or alarm background. |
| No main condition matches | `UNMAPPED` (or `?` in a narrow reading slot) and `N/A` badge. |
| A configured main text cannot fit even at the smallest font | `NO FIT` and `N/A` badge; widen the panel or shorten the configured texts. |
| Supporting condition unavailable or unmapped | Caption with `--` (unavailable) or `?` (unmapped); main state is unchanged. |
| Invalid configuration | Layout diagnostic rather than an inferred mode. |
