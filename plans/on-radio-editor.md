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
- The gear opens schema-driven settings, including Size, Column, Row, and
  Remove panel. Offer only supported sizes that fit with the top-left cell
  fixed.
- Drag a panel's body to move it. Snap only to fitting, non-overlapping
  positions; never move other panels to make room.
- Show an actual panel-styled **+** tile in the first available 1 x 1 cell,
  scanning left-to-right and top-to-bottom. Hide it when the grid is full.
  Use the shared panel drawing and resize functions with a gray sidebar.
  Center the + using measured font dimensions.
- Return closes text editing/settings/catalog one level at a time before
  exiting dashboard editing.
- Support touch and rotary/key input.

## Current implementation

The gesture editor and persistence workflow are implemented in the draft PR,
but broader hardware verification remains outstanding.

Edits are isolated in an in-memory working copy. Existing panel instances
preview placement and size without reconstruction. New additions remain
placeholder cards until saving, avoiding duplicate trackers and other panel
side effects. Configuration changes take effect on save/reload.

Currently, Return from dashboard editing validates, saves a changed layout,
and exits. Leaving fullscreen also initiates saving. Save failures retain the
draft and report the error; there is no per-gesture autosave.

Saving uses staged validation and serialization, verified temporary-file
writes, backup rotation, and recovery. Preserve unknown configuration keys
and do not rewrite unsupported newer layout versions. Firmware callbacks
must stay within the editor's 15,000-instruction regression-test budget.

## Planned exit dialog (not implemented)

User decisions, 2026-10-07:

- Return from dashboard editing exits immediately if nothing changed.
- Otherwise, show a **Save / Cancel** dialog instead of immediately saving.
- Save validates and overwrites the current layout under its existing
  name/path. Do not offer an editable name, rename, or Save As for now.
- Cancel discards draft changes and exits editing, restoring the committed
  dashboard without writing the layout.
- Leaving fullscreen does nothing: it must not trigger saving, discard,
  or the exit dialog. Retain the draft so fullscreen reentry can resume it.
- Return inside a settings/catalog drawer still closes that drawer first.

These decisions supersede the earlier editable-name dialog proposal.
Layout naming, rename/copy behavior, and existing-name conflicts belong to
the separate [layout-management issue #127](https://github.com/thomaskistler/aero-grid/issues/127).
The exit workflow above is planned, not implemented; current behavior still
saves automatically on Return and fullscreen exit.

## Configuration drawer redesign (planned)

The current drawer edits schema-generated generic rows. Replace that basic
presentation with clear, setting-specific controls while retaining isolated
draft editing and the firmware callback budget.

### Layout and navigation

- Show the selected panel's name in a clear header, with readable setting
  labels and values below it.
- Use a scrollable settings area with an obvious scroll affordance and
  consistent touch, rotary, and key focus behavior.
- Provide a small touch back control in the top-left header, rather than the
  mockup's labeled Back button. This follows the touch-to-return header
  convention on ordinary EdgeTX 2.12 pages.
- The header back control and physical RTN perform the same action: close
  the drawer, retain draft changes, and return to dashboard editing without
  saving. Nested text editing/pickers return one level first.
- RTN from dashboard editing opens the planned Save / Cancel dialog if the
  draft changed, or exits immediately otherwise. It currently saves and exits.
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
- Size: an explicit selector for supported dimensions that fit, anchored at
  the current top-left cell. Make blocked/unavailable choices understandable.
- Remove panel: visually separate it from ordinary settings to reduce
  accidental activation.
- Validation: show feedback beside the affected setting and preserve the
  draft on errors.

### Mockup and open design points

The browser prototype at `build/drawer-mockup.html` shows a 480 x 272 radio
viewport with a 320-pixel right-hand drawer over a dimmed dashboard. It has
Model identity and Metric panel examples, size choices, accent swatches,
scrollable settings, and metric-list editing. It is an ignored local design
artifact, not firmware or a committed deliverable.

The prototype uses browser-native inputs only to illustrate interactions;
these are not proof that equivalent controls are exposed by EdgeTX's Lua
LVGL API. Confirm available firmware controls before choosing implementation.

The following remain proposals, not settled requirements:

- Exact drawer width, spacing, and visual treatment.
- Whether blocked sizes should be shown disabled or omitted; the current
  runtime offers fitting sizes only.
- Confirmation before removing a panel, as illustrated in the prototype.
- Live configuration preview and rendering real new panels before save.
  Currently configuration applies on save/reload and additions are placeholders.

Review the simple and structured-list mockups before replacing the runtime
drawer. Verify navigation, scrolling, input controls, error feedback, and
Return/back behavior at radio resolution and within callback limits.

## Code surfaces

- `src/WIDGETS/AeroGrid/main.lua`: fullscreen lifecycle, input routing,
  long-press detection, live previews, and staged saves.
- `src/WIDGETS/AeroGrid/lib/editor.lua`: working-copy operations, fitting
  placements/sizes, schema settings, and strict validation.
- `src/WIDGETS/AeroGrid/lib/editor_ui.lua`: gesture controls, shared + panel,
  configuration/catalog drawers, and editor exit flow.
- `src/WIDGETS/AeroGrid/lib/layout_store.lua` and `lib/yaml.lua`: deterministic
  serialization, verified writes, backups, and recovery.
- `src/WIDGETS/AeroGrid/assets/`: licensed SVG sources and rendered icons.
- `tests/integration/test_editor_ui.lua` and editor/persistence unit tests:
  input behavior, isolation, recovery, and callback budgets.

## Remaining verification and limitations

- Verify controls, drawer usability, and persistence on physical radios and
  across supported display sizes and EdgeTX versions.
- Verify repeated native editor entry/exit for memory and object stability.
- Refine drawer UX as needed; do not claim physical verification from mocks
  or native simulator runs.
- Undo is not implemented.
- Implement the agreed Save / Cancel exit workflow; layout management is
  deferred separately and does not block it.
