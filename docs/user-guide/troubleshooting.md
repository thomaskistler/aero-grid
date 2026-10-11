# Troubleshoot and file bugs

## Troubleshoot a reading

If a panel shows no reading or an unexpected value:

1. Open the panel's settings using its **gear** icon while editing. If it has
   a **Source** setting, check that you selected the value you want to display.
2. For a telemetry reading, check that the receiver is connected and the
   sensor appears on the radio's **Telemetry** page.
3. Check the guide for that panel for any additional setup:
   [battery](../panels/cell-battery.md),
   [timer](../panels/flight-timer.md),
   [navigation](../panels/navigation.md), or
   [metric](../panels/metric.md).

A missing reading does not mean the value is zero.

## Check layouts and themes

Use the **Diagnostics** layout to check loaded components and errors.
Check the selected **Layout** and **Theme** in the widget settings, and
restart the radio or simulator after adding a new layout or theme.

Saved files in `/AEROGRID/layouts/` and `/AEROGRID/themes/` override bundled
files with the same name. Check whether an override explains an unexpected
layout or color. See [Add a dashboard](add-dashboard.md) and
[Customize themes](customize-themes.md) for details.

## File a bug

Search [existing issues](https://github.com/thomaskistler/aero-grid/issues)
first. If none describes the problem, open a
[new issue](https://github.com/thomaskistler/aero-grid/issues/new).

Include:

| Detail | What to provide |
| --- | --- |
| Summary | What failed and a specific issue title. |
| Versions | AeroGrid package version or Git commit, EdgeTX version, and radio model. |
| Environment | Physical radio or simulator; simulator version and desktop OS when relevant. |
| Reproduction | Steps, selected layout and theme, and the smallest settings or layout that reproduce the problem. |
| Expected and actual | What should happen, what happens instead, and exact error text. |
| Evidence | Screenshots, recordings, or relevant diagnostics and logs. |
| Data setup | Sources, units, receiver/link state, switches, and timers needed to reproduce it. |

State whether the issue persists after a restart. Attach a minimal YAML layout,
not an entire SD card. Remove private model information, GPS coordinates, and
unrelated data before posting.

For development-specific diagnostics and contribution guidance, see
[Issues, changes, and releases](../developer-guide/contributing.md#file-an-issue).
