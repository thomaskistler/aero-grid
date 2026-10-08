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

User decision, 2026-10-07: When Return exits editor mode, open a dialog that
allows changing the **layout name** and offers **Save** and **Cancel**, instead
of immediately saving. Return inside a drawer still closes that drawer first.

Before implementing this follow-up, define the meaning of Cancel, how the
layout name is persisted and relates to the Dashboard ID/file name, and how
the dialog interacts with leaving fullscreen. These details have not yet
been agreed; this note does not change runtime behavior.

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
- Implement the exit dialog only after settling its remaining semantics.
