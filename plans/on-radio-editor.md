# Phase-two on-radio layout editor

This is the dedicated implementation and evolving UX plan for
[issue #111](https://github.com/thomaskistler/aero-grid/issues/111).
Implementation is in
[draft PR #126](https://github.com/thomaskistler/aero-grid/pull/126).
The AeroGrid specification is a frozen design baseline; record subsequent
editor decisions here rather than changing `plans/aerogrid-spec.md`.

## Accepted interaction design

- Editing is available only in explicit fullscreen. Normal App mode is
  read-only; this is a practical UX choice rather than a firmware prohibition.
- Long-press a panel to enter editing. An empty dashboard accepts a hold
  anywhere. Enter provides key-only entry. There is no top EDIT button.
- Edit the live dashboard without a selection outline, grid guides, or toolbar.
- Each panel has one muted gray circular configuration gear at its top-right.
  There is no corner X; remove panels through **gear -> Remove panel**.
- The gear opens schema-driven settings and Remove panel. Position and size
  are edited only by gestures.
- Metric and text list entries always show every declared entry setting, even
  those the layout file omits. Unset optional numbers show "Off" or "Sensor";
  clearing optional values removes them from the entry.
- Drag a panel's body to move it. Snap only to fitting, non-overlapping
  positions, including compatible two-panel swaps at occupied origins. Never
  auto-arrange unrelated panels to make room.
- Drag the top-left, bottom-left, or bottom-right corner to expand/shrink,
  anchoring the opposite corner. Snap to supported, in-bounds, collision-free
  grid spans with live geometry previews. Preserve the top-right configuration
  gear hit area.
- Resizing preserves configuration and validates span-dependent settings before
  accepting a size. Corner candidates exclude incompatible
  spans, such as one-row flight-mode panels with `showIndex` enabled.
- Physical-radio testing confirmed corner resizing, so Size, Column, and Row
  were removed from configuration. This intentionally retires key-only
  geometry editing, while retaining key navigation and panel configuration.
- Show an actual panel-styled **+** tile in the first available 1 x 1 cell,
  scanning left-to-right and top-to-bottom. Hide it when the grid is full.
  Use the shared panel drawing and resize functions with a gray sidebar.
  Center the + using measured font dimensions.
- Return closes text editing/settings/catalog one level at a time before
  exiting dashboard editing.
- Support touch and rotary/key input.

## Current implementation

Saving does not show a progress/status message. The dashboard remains visible
while staged saving finishes; failures still show an error and retain the draft.

Native TX16S testing reproduced fullscreen reentry failing after a changed layout
was saved and the widget returned to App mode. EdgeTX 2.12 makes Lua boxes
touch-transparent only when constructing them outside fullscreen; boxes built
while fullscreen intercepted the native widget long press after exit. Saving no
longer reloads the dashboard: when the saved document matches the live preview
(same panels, types, configuration and resolved settings), the previewed panels
are adopted in place, so leaving the editor and returning to App mode does not
flash. Panels that a preview rebuilt in fullscreen are rebuilt one at a time in
App mode after the reflow; panels built in App mode are kept. Only a page or root
first created in fullscreen still uses the staged full reload. Adoption updates
each panel's placement in place, so a panel moved into the top-left corner
reserves the menu button again in App mode. Suspended save-failure drafts are
left intact.

A reported simulator/radio hard crash was a native use-after-free: after a
configuration dialog closed, EdgeTX deleted its native window while the Lua
dialog wrapper stayed registered, and `LuaWidget::foreground` later checked the
freed window's visibility. This could happen on any later refresh, not only on
fullscreen exit. EdgeTX registers objects created during another object's
construction under that object, so each dialog is created from the visibility
callback of a child of a disposable host box. Closing the dialog clears the
host, which unregisters the wrapper without touching the freed window. Firmware
that does not run that callback falls back to a top-level dialog and a
host-level `lvgl.clear()` on App return. Under `MallocScribble=1`, the native
probe reproduced the crash before the fix and completed every dialog/exit cycle
after it without a full reload. Physical-radio confirmation is still
outstanding.

Panel reflow immediately recentres the current reading and places its unit
beside it, even when telemetry has not changed. Metric, link-status, TX battery,
cell battery, and navigation share the same reading/unit reflow helper; timers
also recenter their unchanged time. Supporting link, cell, and navigation labels
are repositioned immediately. Fullscreen/App-mode transitions
must not leave unchanged readings at the left padding while units retain their
previous positions. Transition regressions cover every delivered panel type,
repeated fullscreen/App-mode transitions, and zone resizing, checking positions
before another telemetry tick or refresh can hide a stale-placement failure.
Native TX16S captures also verified that link-status readings and supporting
labels remain centred when entering fullscreen with unchanged unavailable
readings. Physical-radio confirmation remains outstanding.

Moving onto an occupied top-left position swaps the two panels when each fits
at the other's origin without overlapping either panel or any neighbour.
For adjacent, aligned panels, movement instead exchanges their order within
their combined rectangle: vertical movement requires matching widths, horizontal
movement requires matching heights. The other dimension may differ. For example,
a 2x1 above a 2x2 becomes a 2x2 above a 2x1 without leaving a hole or overlapping.
Different widths/heights also reorder when adjacent empty cells accommodate
the larger panel. Preserve each panel's cross-axis origin, shift their order
along the movement axis, and validate both resulting rectangles against every
other panel. A 1x1 plus an empty neighbouring 1x1 can therefore exchange rows
with a 2-column panel, or columns with a 2-row panel. Occupied neighbouring cells
still block displacement; this does not become whole-dashboard auto-arrangement.
Spans and settings remain unchanged; unrelated panels never auto-arrange.
Movement candidates include compatible swaps, even on a full grid. Resizing
and new-panel placement remain non-overlapping operations without displacement.

The gesture editor and persistence workflow are implemented in the draft PR,
but broader hardware verification remains outstanding.

Edits are isolated in an in-memory working copy. Existing panel instances
preview placement and size without reconstruction. Returning from the main
configuration drawer renders new panels and rebuilds panels with changed
configuration. Rebuilds retire the old instance before creating its replacement
in a later foreground callback, reusing cleared containers. Unchanged panels
retain their instances. Unsaved flight-counter instances are display-only:
they cannot increment GV9, announce flights, or write history.

Return from dashboard editing opens Save / Save as / Discard when the draft
changed, or exits directly otherwise. Leaving fullscreen keeps the draft for
resumption without saving. Save failures retain the draft and report the error;
there is no per-gesture autosave.

Saving uses staged validation and serialization, verified temporary-file
writes, backup rotation, and recovery. Preserve unknown configuration keys
and do not rewrite unsupported newer layout versions. Firmware callbacks
must stay within the editor's 15,000-instruction regression-test budget.

## Exit dialog and named layouts (implemented)

User decisions, 2026-10-07 and 2026-10-09:

- Return from dashboard editing exits immediately if nothing changed.
  Otherwise a native **Unsaved changes** menu offers **Save**,
  **Save as...** and **Discard changes**. Dismissing the menu keeps editing.
  This supersedes the earlier Save / Cancel-only decision and the interim
  automatic save on Return.
- The layout name is the identity. There is no separate dashboard-instance
  identifier and no model-specific file: the widget's **Layout** setting
  names a complete layout, and every dashboard selecting it shares it.
  Saving updates it for all of them on their next load.
- Storage is split. Shipped layouts stay in `/WIDGETS/AeroGrid/layouts/`;
  user layouts go to `/AEROGRID/layouts/<name>.yaml`, outside the widget,
  so updates never touch them. A user layout shadows a shipped one of the
  same name. Load order: user, user backup, shipped, `default`, default
  backup.
- Save writes the current name. Saving a shipped layout writes a user copy
  under the same name, which is the shipped-template write protection.
- `Empty` is a shipped blank layout and is never overwritten: Save is not
  offered on it, and the name is reserved.
- Save As suggests the sanitized model name plus the first unused number
  (`Sonic1`), validates the name (letters, digits, `-`, `_`; at most 24
  characters), and asks before overwriting an existing name. Return in the
  name entry goes back to the menu with the draft intact.
- Lua cannot write widget options, so Save As cannot switch this dashboard
  to the new layout. The dashboard keeps its current layout, and a message
  tells the user to restart and select the new name. Decided 2026-10-09.
- **Layout** is a CHOICE built when EdgeTX loads the script, from an
  append-only `/AEROGRID/registry.txt` plus the names found in both
  folders. EdgeTX stores a CHOICE as a position, so names are never removed
  or reordered; new layouts appear after a restart.
- **Theme** is also a CHOICE (Modern, EdgeTX). `custom` stays layout-only,
  since its overrides live in the layout. Decided 2026-10-09.
- No migration. A widget saved with the old **Dashboard ID** string resets
  to `Empty` (the firmware resets an option whose stored type changed), and
  `<model>--<dashboard>.yaml` files are no longer read.
- Leaving fullscreen does nothing to the draft: no save, discard or prompt.
  The committed layout is shown and fullscreen reentry resumes the draft,
  which lives in memory until restart, model change, or a Layout or Theme
  change.
- Return inside a settings/catalog drawer still closes that drawer first.
- Empty dashboards show only two centred text lines: **Empty dashboard**
  and a mode-specific long-press instruction. The grid and + decoration were
  removed after hardware feedback. The hint disappears during editing and
  is never saved as a panel.

Layout management beyond this (deleting, renaming, restoring defaults) is
tracked in [issue #127](https://github.com/thomaskistler/aero-grid/issues/127).

## Configuration drawers (implemented)

Configuration drawers now use EdgeTX Lua LVGL native dialogs,
replacing the custom character editor and Previous/Next navigation. Construction
is staged one row per callback; controls are inactive while building or applying
a queued edit. Configuration remains isolated in the draft.

The + action opens `lvgl.menu` with the title **Select panel**, matching the
native **Select widget** selection style instead of a settings drawer or a
column of buttons. Selection queues a draft addition and opens the new panel's
configuration drawer immediately; native RTN
or outside-touch cancellation leaves the draft unchanged.

### Layout and navigation

- Show the selected panel's name in a clear header, with readable setting
  labels and values below it.
- Open the drawer centered on the screen, sized similarly to standard
  EdgeTX dialogs/drawers on the target display. Inspect native dimensions
  before implementing; do not retain the prototype's right-edge placement.
- Use a scrollable settings area with an obvious scroll affordance and
  consistent touch, rotary, and key focus behavior.
- Do not add a custom return button; match standard EdgeTX widget settings.
  This supersedes the earlier header/top-content **<** control.
- Outside-touch dismissal and physical RTN perform the same action: close
  the drawer, retain draft changes, and return to dashboard editing without
  saving. Nested text editing/pickers return one level first.
- RTN from dashboard editing opens the Save / Save as / Discard menu if the
  draft changed, or exits immediately otherwise.
- Settings update the draft without a separate drawer Apply/Save action.

EdgeTX navigation references:
[manual](https://manual.edgetx.org/color-radios/user-interface) and
[2.12 page implementation](https://github.com/EdgeTX/edgetx/blob/2.12/radio/src/gui/colorlcd/libui/page.cpp).
Header appearance varies by firmware version; do not assume a labeled Back
button is a native EdgeTX control.

### Settings controls

- Booleans: toggles.
- Enumerated choices: selectors.
- Colors/accents: labeled color swatches or a color selector.
- Sources, switches, and timers: dedicated selection controls rather than
  character-by-character entry.
- Numbers: bounded inputs honoring schema limits and steps.
- Text: a more usable text-entry interface than the current character editor.
- Structured lists, such as metric entries and text lines: clear grouped
  add/edit/remove controls rather than a flattened list of fields.
- Size and position: edited only by gestures. The drawer's Size picker was
  removed after gesture resizing was confirmed on the radio.
- Remove panel: visually separate it from ordinary settings to reduce
  accidental activation, but remove immediately without confirmation.
- Validation: show feedback beside the affected setting and preserve the
  draft on errors.
- Match native form line spacing: firmware `UI_ELEMENT_HEIGHT` plus two
  scaled `PAD_TINY` paddings (32 + 4 pixels on TX16S). Start settings directly
  below the native header. Reserve extra feedback space only for rows with
  visible validation errors, moving subsequent rows down while needed.

### Native API findings and preview scope

EdgeTX 2.12 native dialogs center themselves and use 80% of the LCD width and
height (384 x 218 on TX16S). Their body supplies scrolling and native RTN
handling. Native choices omit unavailable entries; they do not expose per-item
disabled styling (relevant only to the since-removed Size picker).

Settings use `choice`, `toggle`, `numberEdit`, `textEdit`, `source`, `switch`,
and `timer` controls. Source/switch selections are converted back to the named
references already stored in layouts, including ASCII physical-switch
positions. The picker shows menu names (`GV1:Thr`, `CH3`, a telemetry icon
before sensor labels) while panels resolve sources with `getFieldInfo`, which
accepts only Lua field names (`gvar1`, `ch3`, `sf`, plain sensor labels). Both
share one source index, so the drawer stores `getFieldInfo(index).name` (or the
plain menu name) only when it maps back to the picked index, and rejects
sources Lua cannot read. Stored names reopen through `getFieldInfo(name).id`,
falling back to `getSourceIndex` for menu names. Accent settings retain their schema's named choices rather than
switching to numeric colors. Current shipped schemas do not declare file inputs.
Text inputs receive a literal initial string for compatibility with installed
EdgeTX builds that reject value callbacks; queued edits resynchronize that
string with the accepted draft value. Toggle getters return native integer
0/1, while layout values remain booleans.

Native TX16S simulation verified centering, the Size popup, nested physical RTN,
and repeated dialog close/reopen. Native cancellation must clear the dialog's
child callbacks before EdgeTX deletes their windows; omitting that cleanup
caused an intermittent simulator crash during reopening. Regression tests cover
grouped list editing, typed controls, draft isolation, inline errors, queued
edits surviving dismissal, and stale callbacks. Physical-radio verification
and broader display-size testing remain outstanding.

Live geometry previews remain enabled. Configuration/new-panel previews now
refresh after returning to editing, rather than on every field change.
Subscription services deduplicate shared sources; replacement instances do not
coexist with the retired instance. Changed flight-counter panels restart their
runtime state after saving; their unsaved previews cannot perform persistent
actions. Discarding or abandoning a rebuilt preview reloads the committed layout.
Native TX16S simulation verified two consecutive drawer-dismissal content
rebuilds, reusing the panel container and drawing the changed metric heading
while remaining in edit mode. Regression coverage includes new metric panels,
nested-drawer dismissal, repeated rebuilds with deferred LVGL cleanup, unchanged
instance reuse, visible preview failures and correction, discard restoration,
and flight-counter preview side-effect suppression.

### Mockup and open design points

The browser prototype at `build/drawer-mockup.html` shows a 480 x 272 radio
viewport with a centered 384 x 218 dialog over a dimmed dashboard. It has
Model identity and Metric panel examples, size choices, accent swatches,
scrollable settings, and metric-list editing. It is an ignored local design
artifact, not firmware or a committed deliverable.

The prototype uses browser-native inputs only to illustrate interactions;
these are not proof that equivalent controls are exposed by EdgeTX's Lua
LVGL API. Confirm available firmware controls before choosing implementation.

User decisions, 2026-10-07, supersede these aspects of the initial prototype:

- Center the drawer and follow standard EdgeTX sizing; exact dimensions
  depend on native conventions and the target display.
- Disable blocked sizes only if the native picker supports it; hide them
  otherwise.
- Remove panels immediately; the prototype's confirmation is not required.
- Prefer live configuration and new-panel previews if straightforward to
  implement. This is conditional, not a requirement for a complex preview
  framework. Preserve draft isolation, avoid duplicate trackers or persistent
  side effects, and stay within callback limits. If those constraints make
  previews substantial work, retain save/reload behavior and document it.
  Implemented on main-drawer dismissal, with staged instance replacement and
  display-only unsaved flight counters.

The local browser prototype now reflects centering, hidden blocked sizes,
native dismissal without a return button, and immediate removal. Its browser controls and inline metric
cards remain conceptual; the native runtime uses separate grouped-entry dialogs.

Review the simple and structured-list mockups before replacing the runtime
drawer. Verify navigation, scrolling, input controls, error feedback, and
Return/back behavior at radio resolution and within callback limits.

## Code surfaces

- `src/WIDGETS/AeroGrid/main.lua`: fullscreen lifecycle, input routing,
  long-press detection, live previews, and staged saves.
- `src/WIDGETS/AeroGrid/lib/editor.lua`: working-copy operations, fitting
  placements/sizes, schema settings, and strict validation.
- `src/WIDGETS/AeroGrid/lib/editor_ui.lua`: gesture controls, shared + panel,
  live geometry previews, and editor exit flow.
- `src/WIDGETS/AeroGrid/lib/editor_drawer.lua`: native settings dialogs and panel selection menu,
  grouped entries, staged construction, and queued edits.
- `src/WIDGETS/AeroGrid/lib/layout_store.lua` and `lib/yaml.lua`: deterministic
  serialization, verified writes, backups, and recovery.
- `src/WIDGETS/AeroGrid/assets/`: licensed SVG sources and rendered icons.
- `tests/integration/test_editor_ui.lua` and editor/persistence unit tests:
  input behavior, isolation, recovery, and callback budgets.

## Remaining UI work

Status as of 2026-10-09. Do not claim physical verification from mocks, the
mock test suite, or native simulator runs.

### Implemented

- Gesture placement, resizing and compatible reordering; native panel
  selection and settings drawers, including metric/text entry editing.
- Global-variable source picking with canonical Lua field names.
- Save / Save as / Discard, protected `Empty`, overwrite confirmation,
  shared named layouts, and draft resume after leaving fullscreen.
- Layout and Theme pickers, stable layout registry, and user storage outside
  the widget package.
- Text-only empty-dashboard guidance with native centred alignment.
- [Dashboard and editor user guide](../docs/user-guide/dashboards.md), with native TX16S simulator
  captures of editing, metric configuration, the exit menu, and Save As.

No remaining feature work is identified for the agreed editor scope.
Future panels with list settings must declare entry `fields`, as metric and
text already do.

### Awaiting physical-radio confirmation

Confirmed on the radio 2026-10-09 for the build before the exit dialog:
repeated drawer and dialog use without crashes, no flash on leaving editing
or fullscreen, App mode corner reservation and fullscreen reentry, every
entry setting in the drawer, and source picking including global variables.

The user also tested the exit-dialog/named-layout build and reported that it
seems to work. Individual exit actions and registry-stability cases were not
separately reported; do not treat that as exhaustive validation.

- Confirm the Theme picker on hardware.
- Confirm the revised text-only empty hint is centred in both App mode and
  fullscreen; the earlier grid/+ version was rejected on hardware.
- Exercise Save As overwrite and error handling, draft resume, and stable
  Layout positions after adding layouts and restarting.

### Broader verification

- Supported display sizes other than TX16S and other EdgeTX versions.
- Memory and object stability across repeated editor entry and exit on the
  radio.
- Drawer usability refinements found during radio testing.
- Take PR #126 out of draft once hardware validation passes.

### Out of scope

- Undo.
- Key-only geometry editing (retired in favour of gestures).
- Restore defaults, which belongs to
  [layout management #127](https://github.com/thomaskistler/aero-grid/issues/127).
