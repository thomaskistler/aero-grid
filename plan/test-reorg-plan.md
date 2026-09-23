# Test Reorganization Plan

## Goals

1. Keep tests as simple and readable as possible.
2. Eliminate duplicate setup and assertion code.
3. Replace large monolithic test files with per-component tests.
4. Cover widget-builder behavior once, without repeating layout assertions for every panel.
5. Keep each panel test focused on functionality unique to that panel.

## Proposed Test Structure

```text
tests/
  support/
    edgetx.lua
    assertions.lua
    widget_fixture.lua
    layout_fixtures.lua
    builder_matrix.lua
  unit/
    lib/
      test_grid.lua
      test_yaml.lua
      test_layout.lua
      test_component_host.lua
      test_theme.lua
      test_primitives.lua
      test_services.lua
      test_telemetry_service.lua
      test_model_service.lua
      test_control_service.lua
      test_extrema_service.lua
      test_navigation_service.lua
    components/
      test_cell_battery.lua
      test_flight_mode.lua
      test_flight_timer.lua
      test_link_status.lua
      test_metric.lua
      test_model_identity.lua
      test_tx_battery.lua
      test_variable_indicator.lua
      test_navigation.lua
  integration/
    widget/
      test_widget_lifecycle.lua
      test_widget_builder_matrix.lua
      test_widget_theme.lua
    layouts/
      test_layout_validation.lua
      test_layout_overlap.lua
```

## Test Layers

### 1. Shared base harness

Create a common test harness for widget tests.

Responsibilities:
- load the radio fixture and widget source
- create a widget context with a minimal but realistic host
- provide helper methods such as:
  - `createLoaded()`
  - `pump()`
  - `entryById()`
  - `panelOf()`
  - `boundsOf()`
  - `assertPanelBounds()`
- centralize common cleanup and settling logic

This removes repeated boilerplate from every component test.

### 2. Shared layout fixtures

Create reusable layout YAML fixtures for the common layout cases:
- single component
- 2x2 layout
- multi-panel layout
- overlap case
- full-width metric layout
- representative builder-driven layout

These fixtures should live in `tests/support/layout_fixtures.lua` or a similar shared file.

Rules:
- each fixture should represent one clear scenario
- avoid one-off YAML embedded inside many tests
- keep layout data small and intentional

### 3. Shared widget-builder API tests

Write generic tests for behaviors that apply to all builder-driven panels once, instead of in each panel file.

Covered behavior:
- supported span validation
- layout placement and bounds
- overlap rejection
- theme application
- refresh lifecycle
- default/empty state handling
- shared panel container behavior

This test layer should validate the builder contract as a whole, not every individual panel.

### 4. Panel-specific tests

Each component test file should only verify behavior unique to that component.

Examples:
- `test_metric.lua`
  - preset resolution
  - source/unit formatting
  - threshold handling
  - radial vs bar presentation
  - extrema behavior
- `test_flight_mode.lua`
  - mode label/state transitions
  - flight-mode styling
  - layout-specific rendering rules
- `test_cell_battery.lua`
  - low/critical voltage thresholds
  - color state changes
  - battery label/value handling
- `test_link_status.lua`
  - connection/health display states
  - link source formatting
- `test_model_identity.lua`
  - model name/identity display
  - label formatting
  - identity-specific state rules

If a behavior is generic to all panels, it belongs in the shared builder test suite, not a panel file.

## Test File Responsibilities

### `tests/unit/lib/*`

These should remain pure and minimal. They should validate the Lua services and library logic without depending on the full widget host.

Examples:
- grid geometry
- YAML parsing/validation
- layout validation and overlap rejection
- theme token resolution
- service registry behavior
- telemetry/model/control/extrema/navigation utilities

### `tests/unit/components/*`

These should test “panel behavior” only.

Rules:
- use the shared widget fixture abstraction
- read minimal real layout data
- avoid duplicating generic layout assertions
- keep each file focused on one panel type

### `tests/integration/widget/*`

These should validate host integration and lifecycle behavior only.

Examples:
- widget creation lifecycle
- staged loading behavior
- refresh ordering
- actual host callbacks
- builder contract across representative panel types

## Shared Patterns to Introduce

### Base widget test helper

```lua
local WidgetTest = {}

function WidgetTest.new(root)
  local self = {}
  -- shared setup: edgetx, makeWidget, createLoaded, pump, etc.
  return self
end

return WidgetTest
```

### Shared fixture helper

```lua
local fixtures = {
  singleMetric = [[...]],
  overlap = [[...]],
  multiPanel = [[...]],
}

return fixtures
```

### Shared builder matrix tests

A builder matrix test should be parameterized over representative panel examples and only verify the common contract.

Example assertions:
- a component can be created
- a valid placement is accepted
- overlapping placements are rejected
- theme/contrast tokens are applied
- default refresh does not fail

## Migration Strategy

1. Create `tests/support` helpers first.
2. Move shared runtime helpers out of `test_runtime.lua`.
3. Split the monolithic widget suite into component-level files.
4. Extract builder/common assertions into one shared reusable matrix.
5. Keep panel files narrow and unique.
6. Remove duplicate setup from old large files once the new structure is stable.

## Expected Outcome

This structure will make the suite:
- easier to read
- easier to extend
- less repetitive
- better aligned with the source layout
- less brittle when individual panels change

The result is a test suite where generic widget behavior is tested once, while panel-specific logic remains easy to find and reason about.

## Coverage Ownership During Migration

The focused component files own pure component behavior:

- input normalization and formatting
- state resolution
- threshold and range calculations
- component-specific wording and presentation choices

The legacy runtime and widget integration files continue to own behavior that
requires the complete host:

- LVGL geometry and measured bounds
- staged loading and refresh ordering
- reflow and lifecycle cleanup
- component failure isolation
- telemetry/service wiring across multiple panels

These assertions are intentionally not removed as duplicates: they exercise a
different layer than the focused unit tests. As migration continues, only
assertions with identical setup, inputs, and responsibility should be moved;
host-level coverage should remain in integration tests.
