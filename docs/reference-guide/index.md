# Panel reference

Choose a panel below for visual examples, its settings, and how it behaves.

Display preferences are best-effort: panels silently hide optional information
that does not fit, preserving the settings so it can return when space permits.
Limited space does not produce a configuration warning. Invalid settings still
produce errors, and warning, critical, stale and unavailable state indications
remain active.

| Panel | Purpose |
| --- | --- |
| [Channel output](../panels/output.md) | Channel outputs with automatically matched stick-trim arrows. |
| [Flight counter](../panels/flight-counter.md) | Panel-owned flight detection, GV9 count, and completed-flight history. |
| [Flight mode](../panels/flight-mode.md) | The active EdgeTX flight mode. |
| [Flight timer](../panels/flight-timer.md) | An EdgeTX model timer. |
| [Host diagnostics](../panels/host-diagnostics.md) | Troubleshooting report on the widget, theme, panels, and sources. |
| [Link status](../panels/link-status.md) | Link quality, signal strength, and optional RF details. |
| [Metric](../panels/metric.md) | Up to three numeric readings, including telemetry and global variables. |
| [Model identity](../panels/model-identity.md) | Model name and picture. |
| [Navigation](../panels/navigation.md) | GPS position, distance from home, and bearing toward the model. |
| [RX battery](../panels/rx-battery.md) | Aircraft cell or pack voltage. |
| [Service probe](../panels/service-probe.md) | Troubleshooting view of one shared data service. |
| [State](../panels/state.md) | Up to three readings selected by ordered switch conditions. |
| [Trim](../panels/trim-panel.md) | Aileron, elevator, and rudder trims. |
| [TX battery](../panels/tx-battery.md) | TX battery voltage and an optional voltage-based estimate. |

Writing a layout file by hand or with an AI agent? The
[YAML reference](yaml.md) describes the complete layout file format.

## Using the panel settings

Each panel page lists the settings exactly as they appear when you tap a
panel's gear in the [on-radio editor](../user-guide/edit-dashboard.md).
The controls behave the same way in every panel:

| Control | How it works |
| --- | --- |
| Choice | Opens a list of the allowed values. |
| Number | Steps by the increment listed on the panel page. Optional numbers have one extra step below their lowest value, shown as a word such as **Off** or **Sensor** instead of a number. Stepping down to it clears the setting so the panel's fallback applies. |
| Text | Opens the keyboard. Clearing an optional text restores its default, such as the source name. |
| Source, Switch, Timer | Opens the standard EdgeTX picker. Sources that Lua cannot read are rejected with a message. |
| Entry rows | Panels with lists, such as Metric, show one row per entry with a short summary. Tap a row to open that entry's settings. |
| **+** | Adds an entry at the bottom, copied from the last entry. It is unavailable when the list is full. |
| **Remove entry** | Inside an entry, deletes it. A panel keeps at least its minimum number of entries. |
| **Remove panel** | Deletes the panel from the screen. |

Press **RTN** or tap outside a settings dialog to go back one level. Changes
stay in your draft until you save the layout.

To add a screen, see [Add a dashboard](../user-guide/add-dashboard.md).
To arrange panels, see [Edit a dashboard on the radio](../user-guide/edit-dashboard.md).
