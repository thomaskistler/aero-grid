# Add, configure and edit a dashboard

Add AeroGrid to a radio screen, choose a layout, then customize it on the radio.
Install [AeroGrid](installation.md) first and select the model you want to use.

## Add a dashboard

Open the main screen's top-left menu and choose **UI Setup**.

![EdgeTX main menu with UI Setup at the right](../assets/editor/screen-menu.png)

Select the **+** tab, then tap **Add Screen**.

![Add Screen tab and button in EdgeTX UI Setup](../assets/editor/add-screen.png)

On the new screen, tap the **Layout** thumbnail and choose **App mode**.
This makes one widget fill the screen.

![Screen layout picker with App mode highlighted](../assets/editor/screen-layout.png)

Tap **Setup widgets**, then tap the empty widget area.

![App mode screen with Setup widgets button](../assets/editor/app-screen.png)

Choose **AeroGrid** in **Select widget**.

![Select widget menu with AeroGrid highlighted](../assets/editor/select-widget.png)

In the AeroGrid settings, choose **Layout**. Select **Empty** to build your
own dashboard, or **Default** to start with the bundled aircraft dashboard.
Choose **Modern** or **EdgeTX** for **Theme**.

![AeroGrid widget settings with Layout and Theme pickers](../assets/editor/widget-options.png)

Press **RTN** to close the settings and leave setup. Your dashboard is now
on the new screen. Repeat these steps to add another dashboard.

## Understand layouts

A **dashboard** is AeroGrid on a radio screen. A **layout** defines its panels,
their positions and sizes, and their settings, including sources and alarms.
Choose a layout to decide what that dashboard displays.

| Layout | Purpose |
| --- | --- |
| **Empty** | A blank starting point for your own dashboard. Shows instructions until you start editing. |
| **Default** | A ready-made aircraft dashboard. Configure its sources, switches, battery cell count, and alarms for your model before using it. |
| **Host** | A diagnostics dashboard for checking loaded components and errors. |

Bundled layouts are stored in `/WIDGETS/AeroGrid/layouts/`. Your saved layouts
are stored separately in `/AEROGRID/layouts/`, so upgrading AeroGrid leaves
them untouched.

**Save** updates the current layout. For a bundled layout it creates your
copy under the same name, leaving the bundled original untouched.
**Save as...** creates a separately named layout.

Several dashboards, even on different models, can select the same layout.
They share all panel settings, so check that the sources and switches suit
each model. Saving changes under that name affects all dashboards using it
when they next reload.

Restart the radio after saving a new name so it appears in the **Layout**
picker. The layout list is kept in `/AEROGRID/registry.txt`; leave that file
alone so existing screen selections keep their positions. A missing layout
falls back to **Default**.

## Edit a dashboard on the radio

1. Long-press the dashboard to enter fullscreen. The EdgeTX logo in the
   top-left corner disappears.
2. In fullscreen, long-press a panel again to start editing. On an empty
   dashboard, long-press anywhere. **Enter** also starts editing.

Normal App mode is read-only, even when the dashboard fills the display.
An empty dashboard shows centred instructions until you start editing.

![Editor showing panel gears and the add-panel tile](../assets/editor/overview.png)

| Action | How |
| --- | --- |
| Add | Tap the **+ panel**, then choose a panel type. Its settings open automatically. |
| Move | Drag the panel's body to a free position. |
| Reorder | Drag onto another panel. Compatible panels exchange positions or order; other panels stay put. |
| Resize | Drag the top-left, bottom-left, or bottom-right corner. The opposite corner stays fixed. |
| Configure | Tap the **gear** in the top-right corner. |
| Remove | Open the gear, then choose **Remove panel**. Removal is immediate. |

Panels snap to the 4 × 4 layout grid. Moves and sizes must fit without
overlapping other panels. The **+ panel** disappears when there is no free
cell. There are no grid lines or resize handles: drag the corners directly.
Moving and resizing require touch.

Use the native choices, toggles, number controls, and text keyboard in the
settings dialog. Sources, switches, and timers use EdgeTX pickers.
Global variables appear as **GV1–GV9** when enabled for the model.

![Metric panel settings with entry, accent, visualization, and removal controls](../assets/editor/settings.png)

For a metric panel, open **Metrics**, choose an entry, then **Source**.
Metric entries and text lines have their own add, edit, and remove dialogs.

![Metric-entry dialog with GV1 selected as Source](../assets/editor/metric-entry.png)

Press **RTN** or tap outside a dialog to return one level. Changes remain in
your draft. Placement and size preview immediately; settings preview when you
close the main panel dialog. Rotary/key input can select panels and open
settings, but cannot move or resize them.

From the editing dashboard, press **RTN**. If nothing changed, editing closes.
Otherwise choose an action:

| Action | Result |
| --- | --- |
| **Save** | Updates the current layout and exits editing. |
| **Save as...** | Asks for a name and saves a separate layout. |
| **Discard changes** | Exits editing and restores the saved layout. |

![Unsaved changes menu offering Save, Save as, and Discard changes](../assets/editor/exit.png)

Dismiss the menu to keep editing. **Save** is not offered for **Empty**:
use **Save as...** to name your new dashboard.

Save As suggests the model name plus the first unused number, such as
`Sonic1`. You can change it using letters, digits, `-`, and `_` (at most
24 characters). An existing name requires overwrite confirmation.
Press **RTN** in the name dialog to return to the exit menu without losing
your draft.

![Save layout as dialog with Sonic1 entered as the new name](../assets/editor/save-as.png)

**After Save As, restart the radio and select the new name in the widget's
Layout setting.** The widget cannot change its own settings, so it continues
showing its previous layout until you select the new one.

User layouts are saved in `/AEROGRID/layouts/`. Saving a shipped layout creates
a user copy under the same name; the shipped file stays untouched. Other
screens using that name see the changes when they reload.

Wait for saving to finish before powering off. A save error keeps your draft
so you can retry; the previous saved file is retained as `.bak`.

Leaving fullscreen keeps the draft in memory and shows the saved dashboard.
Return to fullscreen to resume editing. Restarting the radio, changing model,
or changing the widget's **Layout** or **Theme** discards the unsaved draft.

## Layout recovery

If the primary layout cannot be read, parsed, or validated, AeroGrid tries its
backup, then the shipped layout of that name, and finally the shipped
default and its backup. Review the active path in the `Host` diagnostics
panel after recovery.

## App mode and Full screen

| Layout | What you see |
| --- | --- |
| **App mode** | A dashboard covering the display, without the EdgeTX top bar, flight-mode label, sliders, or trims. The menu button remains in the top-left corner. |
| **Full screen (`1 x 1`)** | One dashboard widget, with the option to keep EdgeTX's top bar, flight-mode label, sliders, and trims. |

Use App mode for a clean dashboard, or Full screen to keep the radio's
standard information alongside it. In App mode, a wider top-left panel
leaves more room beside the menu button.

## Theming

Choose **Theme** in the widget settings.

| Mode | Behavior |
| --- | --- |
| **Modern** | AeroGrid's dark instrument palette. |
| **EdgeTX** | Colors based on the radio's active theme. |

## Troubleshoot a reading

Check the panel's source name and expected data type first. A cells-table
source and a numeric pack-voltage source are not interchangeable. Check receiver
connection, sensor discovery, GPS fix, and model timer configuration as applicable.

Use `Host` to inspect the loaded layout, panel loading, and service failures.
Interpret missing or stale states using the panel's reference page rather than
treating them as zero. If a copied fix is not taking effect, follow the
[upgrade instructions](installation.md#upgrade).
