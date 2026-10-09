# Edit a dashboard on the radio

Use the editor to add panels, arrange them, and change their settings without
editing YAML.

## Start editing

1. Select a layout in the AeroGrid widget's **Layout** setting. Choose
   **Empty** to start a new dashboard.
2. Long-press the dashboard to enter fullscreen.
3. In fullscreen, long-press a panel again to start editing. On an empty
   dashboard, long-press anywhere. **Enter** also starts editing.

Normal App mode is read-only, even when the dashboard fills the display.
An empty dashboard shows centred instructions until you start editing.

![Editor showing panel gears and the add-panel tile](../assets/editor/overview.png)

*Editor overview. Captures on this page use the EdgeTX 2.12 TX16S simulator
with a sample layout; readings are illustrative.*

## Add and arrange panels

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

## Change settings

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

## Save or discard

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

## Leave fullscreen without saving

Leaving fullscreen keeps the draft in memory and shows the saved dashboard.
Return to fullscreen to resume editing. Restarting the radio, changing model,
or changing the widget's **Layout** or **Theme** discards the unsaved draft.

For layout selection, themes, and recovery, see
[Configure a dashboard](dashboards.md).
