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
- Otherwise, show the current layout name and **Cancel / Save / Save As**
  actions instead of immediately saving.
- Save validates and updates the current named layout, then exits editing.
  Other dashboards referencing that layout pick up the changes on reload.
- Save As asks for a new name, validates and saves an independent copy,
  switches this dashboard to that copy, and exits editing. Leave the
  original layout unchanged.
- Dismissing the Save As name entry returns to the exit dialog without
  losing the draft.
- Cancel discards draft changes and exits editing, restoring the committed
  dashboard without writing the layout.
- Leaving fullscreen does nothing: it must not trigger saving, discard,
  or the exit dialog. Retain the draft so fullscreen reentry can resume it.
- Return inside a settings/catalog drawer still closes that drawer first.

The three-action dialog supersedes the earlier Save / Cancel-only decision.
Layout management is tracked in
[issue #127](https://github.com/thomaskistler/aero-grid/issues/127);
existing-name conflict handling and shipped-template write protection still
need to be settled there before implementing the shared-layout workflow.
The exit workflow above is planned, not implemented; current behavior still
saves automatically on Return and fullscreen exit.

## Named shared layouts (planned)

User decision, 2026-10-07: Keep sharing simple. Dashboards can reference the
same complete named layout rather than always creating model-specific copies
from a template.

- Saving an existing shared name updates that layout for all dashboards
  referencing it on their next load/reload.
- Save As creates an independent named layout for the current dashboard.
- Share the entire layout, including panel settings. Users decide whether
  sources, switches, timers, and other settings suit the models sharing it.
- Do not add inheritance, per-model overrides, or automatic compatibility
  decisions. Normal validation and unavailable-source reporting still apply.
- Keep the reusable layout name distinct from the dashboard-instance
  identifier (`DashID`).

This supersedes the copy-only template proposal. First-run template selection,
an Empty layout, storage organization, and shipped-template handling were
discussed but are not settled requirements. Restore defaults remains part of
the separate layout-management topic.

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
- Provide a small touch **<** control at the top-left of the dialog content.
  EdgeTX 2.12 exposes the native dialog body, not its title bar, to Lua;
  this replaces the originally planned header control without a custom dialog.
- The touch back control and physical RTN perform the same action: close
  the drawer, retain draft changes, and return to dashboard editing without
  saving. Nested text editing/pickers return one level first.
- RTN from dashboard editing opens the planned Cancel / Save / Save As dialog if the
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
- Size: use the built-in EdgeTX Lua LVGL picker where available, anchored at
  the current top-left cell. If it supports disabled entries, show supported
  sizes that do not fit as disabled; otherwise hide those sizes. Do not build
  a custom picker solely to support disabled entries.
- Remove panel: visually separate it from ordinary settings to reduce
  accidental activation, but remove immediately without confirmation.
- Validation: show feedback beside the affected setting and preserve the
  draft on errors.

### Native API findings and preview scope

EdgeTX 2.12 native dialogs center themselves and use 80% of the LCD width and
height (384 x 218 on TX16S). Their body supplies scrolling and native RTN
handling. Native choices omit unavailable entries; they do not expose per-item
disabled styling, so the Size picker contains only fitting sizes.

Settings use `choice`, `toggle`, `numberEdit`, `textEdit`, `source`, `switch`,
and `timer` controls. Source/switch selections are converted back to the named
references already stored in layouts, including ASCII physical-switch
positions. Accent settings retain their schema's named choices rather than
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

Live geometry previews remain enabled. Configuration/new-panel previews still
apply on save/reload: panel instances own subscriptions and potentially
persistent tracker state, so rebuilding them per setting would not be a simple,
side-effect-free preview. A new preview framework is outside this drawer change.

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
  Currently configuration applies on save/reload and additions are placeholders.

The local browser prototype now reflects centering, hidden blocked sizes,
top-content back, and immediate removal. Its browser controls and inline metric
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
- `src/WIDGETS/AeroGrid/lib/editor_drawer.lua`: native settings/catalog dialogs,
  grouped entries, staged construction, and queued edits.
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
- Undo is not needed and is out of scope.
- Restore defaults belongs to
  [layout management #127](https://github.com/thomaskistler/aero-grid/issues/127),
  not this editor UI.
- Implement the agreed Cancel / Save / Save As exit workflow alongside the
  named-layout reference/persistence support it requires. Broader layout
  management remains tracked separately.
