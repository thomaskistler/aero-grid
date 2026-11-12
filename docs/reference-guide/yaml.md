# YAML reference

Use this reference to write layout YAML by hand or with an AI agent. For
on-radio settings and behavior, see the [panel reference](index.md).
For custom palettes, see [Theme files](#theme-files).

## File locations

AeroGrid reads YAML layout files from two places:

- Bundled layouts: `/WIDGETS/AeroGrid/layouts/<name>.yaml`.
- User layouts: `/AEROGRID/layouts/<name>.yaml` (on the SD card).

A user layout with the selected name takes precedence over a bundled layout of the same name. The user folder is outside the widget folder, so a widget update does not replace user layouts. The editor accepts names of 1–24 letters, digits, `_` or `-`; `Empty` is reserved for the blank screen. Use that name as the filename stem. If loading a candidate fails, AeroGrid can try its backup, the bundled file of that name, then the bundled default and its backup.

## Document structure

A new layout should use version 5 and exactly a 4 × 4 grid. `col` and `row` are zero-based; spans count grid cells. The cell at the upper left is `(0, 0)`.

| Top-level key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `version` | integer | yes | Layout schema version. Write `5`. |
| `grid` | mapping | yes | Must contain `columns: 4` and `rows: 4`. Other grid dimensions are rejected. |
| `panels` | sequence of mappings | yes | Ordered panel placements. Use `[]` for an empty layout. |
| `session` | mapping | no | Legacy compatibility only; see [Session](#session). |
| `theme` | mapping | no | **Not supported.** A layout that has this key is reported as invalid. Choose a theme in widget settings instead. |

Each `panels` entry has these placement keys:

| Key | Type | Required | Rule |
| --- | --- | --- | --- |
| `id` | string | yes | Unique within the layout; letters, digits, `_` and `-` only (`^[A-Za-z0-9_-]+$`). |
| `type` | string | yes | Panel kind, using the exact names in the Panels sections below. It must also contain only letters, digits, `_` and `-`. |
| `col` | integer | yes | Starting column, 0–3. |
| `row` | integer | yes | Starting row, 0–3. |
| `colSpan` | integer | yes | Positive width in cells; must fit within column 4 and be supported by the panel. |
| `rowSpan` | integer | yes | Positive height in cells; must fit within row 4 and be supported by the panel. |
| `config` | mapping | no | Panel-specific settings. Omit it to use panel defaults; otherwise write a mapping, not a sequence or scalar. |

A placement must fit the 4 × 4 grid: `col + colSpan <= 4` and `row + rowSpan <= 4`. Placements may touch edges but may not occupy the same cell. If two placements overlap, the first valid placement in the sequence wins and the later one is dropped. A panel must also support its exact span, written as `<colSpan>x<rowSpan>` (for example, `2x1`); the word `any` in a panel's span list accepts every in-bounds span.

Panel IDs and types are case-sensitive. Unknown top-level keys and extra placement keys are preserved rather than rejected. In contrast, a key inside `config` that the panel does not declare is reported as an unknown setting; spelling and case must match exactly.

## Session

`session` is optional and must be a mapping when present. Its only declared key is `armSource`; unknown session keys are not reported and are not retained in the normalized session:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `armSource` | string | unset | Accepted so existing layouts load, but no longer used. Configure **Arm switch** in Model settings instead. |

Configure arming, session reset, and flight detection/output in
[Model settings](../user-guide/model-settings.md), not layout YAML.
For compatibility behavior, see
[Older layouts](../user-guide/model-settings.md#older-layouts).
Custom State conditions remain independent.

## Validation and errors

The loader parses and validates a candidate before building panels. Unsupported YAML syntax, an unsupported schema version, a missing or non-4×4 grid, a non-sequence `panels` value, or the unsupported layout-level `theme` key makes the candidate invalid; AeroGrid reports the load problem and may recover using the next backup or bundled candidate. Versions 1–4 are migrated to version 5 in memory. Existing panel, Navigation, and legacy arm settings are retained. Version 4 detection settings remain available for migration to Model settings. Save writes version 5 without deleting retained legacy arm conditions. Write version 5 for new files.

An invalid panel entry is rejected without preventing other valid entries from loading. This includes a non-mapping entry, an unsafe or duplicate ID, an unknown panel type, invalid placement values, a placement outside the grid, an overlap, or a span the panel does not support. The failed panel is dropped and its reason is reported. When overlaps occur, the earlier accepted entry remains.

Missing or wrong-typed panel settings and invalid choice values fall back to
their defaults, with a warning where appropriate. Nested entries and
cross-field rules receive panel-specific validation. A panel that cannot be
constructed is dropped. The editor rejects previews with warnings and refuses
to save invalid settings. Numeric bounds and steps are editor constraints
unless runtime validation is explicitly noted below. Correct every warning
rather than relying on fallback behavior.

Unknown `config` keys are kept in the resolved configuration but reported as “is not a setting of this panel”; they are not silently discarded. This catches typos. A non-mapping `config` is normalized to an empty mapping, so always use the mapping form. Unknown top-level keys and extra panel-entry keys are retained without a setting warning; do not rely on them having meaning to this version of AeroGrid.

YAML parsing and structural validation do not prove that an EdgeTX source exists on a particular model or radio. Use exact source names as the radio reports them. A missing live source can still render as unavailable even when the layout structure is valid.

## YAML syntax supported

The widget uses a deliberately small YAML parser, not a general YAML implementation. Emit only these forms:

- Indented block mappings (`key: value`) and sequences (`- item`), using **two spaces per indentation level**. Tabs and odd-space indentation are errors.
- Strings, numbers, lowercase `true` and `false`, and `null` or `~` scalars. To force a string that looks like a number, boolean, or null, quote it.
- Single-quoted strings; represent an apostrophe inside one as `''`. Double-quoted strings support `\\`, `\"`, `\n`, `\r` and `\t` escapes.
- Comments beginning with `#` at the start of a line or after whitespace. A `#` inside a quoted string is preserved.
- Empty flow collections only: `[]` and `{}`. They are useful for empty sequences and mappings; non-empty inline collections are unsupported.
- Empty mapping values with indented children, including nested mappings and lists.

Do **not** use anchors or aliases, tags, block scalars (`|` or `>`), flow-style non-empty lists or maps, merge keys, directives, or other general YAML features. Duplicate mapping keys are rejected. Mapping keys must begin with an ASCII letter or `_`, and may then contain letters, digits, `_` or `-`. Quote text that could otherwise be parsed as a boolean, number or null. Prefer double-quoting source names, labels and other strings when uncertain.

## Panels

Omitted settings use their listed defaults. “Unset” means the setting has no schema default and stays unset unless specified. Numeric constraints in the tables are the drawer's declared bounds/steps or, when explicitly noted, the panel's runtime validation. All choice values are the YAML values, even if the drawer displays a friendlier choice label.

### `chart`

Drawer title: **Chart** · [drawer settings and behavior](../panels/chart.md) · Supported spans: `2x1`, `3x1`, `4x1`, `2x2`, `3x2`, `4x2`, `3x3`, `4x3`, `4x4`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `""` | Any string | Label | Blank hides the heading. |
| `armSwitch` | string | `""` | Physical position or logical switch | Arm switch position | Legacy fallback before model arming is saved. |
| `metrics` | sequence | `[]` | 0-3 contiguous entries | Metrics | Entry fields follow. |
| `duration` | number | Unset (drawer: `Auto`) | Whole minutes `1`-`60` | Window minutes | Omit for a growing window. Earlier strings such as `30s` or `5m` round up to whole minutes; values above 60 are limited to 60. |
| `scaling` | string | `shared` | `shared`, `independent` | Series scales | Independent scales suit unlike units. |
| `smoothing` | string | `off` | `off`, `light`, `medium`, `strong` | Line smoothing | Changes the line, not raw readouts or extrema. |
| `accent` | string | `cyan` | `cyan`, `green`, `orange`, `amber` | Accent | Panel accent only. |
| `timeRange` | string | `fixed` | Any string | Not shown | Obsolete and ignored. |
| `range` | string | `auto` | `auto`, `fixed` | Not shown | Obsolete and ignored. |

#### Metric entry (`metrics[]`)

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `source` | string | Unset | Numeric EdgeTX source name | Source | Required by the editor for an entry. |
| `label` | string | Source name | Any string | Label | Legend caption. |
| `unit` | string | Sensor unit | Any string | Unit | Label only; no conversion. |
| `precision` | number | Unset (drawer: `Sensor`) | Integer `0`-`3` | Precision | Omit to use sensor precision. |
| `rangeMin` | number | Unset (drawer: `Auto`) | Finite number | Range min | Optional lower bound. |
| `rangeMax` | number | Unset (drawer: `Auto`) | Finite number | Range max | Must exceed minimum when both are set. |
| `accent` | string | By entry order | `cyan`, `green`, `orange`, `amber` | Color | Defaults to cyan, orange, then green. |

With shared scales, the lowest fixed minimum and highest fixed maximum apply
to all traces; an unset side follows all traces automatically. For example,
`rangeMin: 0` anchors the bottom at zero while an omitted `rangeMax` grows.
The legend sits beside wide plots and above square or tall plots.

```yaml
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: power-chart
    type: chart
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      label: Power
      scaling: independent
      smoothing: light
      metrics:
        - source: RxBt
          label: RX
          precision: 1
          accent: cyan
        - source: Curr
          label: A
          precision: 1
          accent: green
```

### `flight-counter`

Drawer title: **Flight counter** · [drawer settings and behavior](../panels/flight-counter.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `FLT` | Any string | Label | Heading. |
| `armSwitch` | string | `""` | Blank, physical switch position, or logical switch such as `L01` | Arm switch position (legacy only) | New panels use model arming. Version-1–3 layouts retain the former `SF^` default when omitted. |

Configure flight detection, optional **Smart detection**, and the optional
logical-switch output in **AeroGrid → Model settings**, not in new panel YAML. The old
`motorSource`, `motorReversed`, `minMotorPercent`, `minFlightDuration`,
and `disarmDuration` fields remain readable for
legacy migration. Do not remove the last legacy counter before saving Model
settings. Flight tracking then continues independently of counter placement.
The obsolete `announcements` and `history` fields are ignored; configure sounds using the
flight-active logical switch and EdgeTX Special Functions. See
[Older layouts](../user-guide/model-settings.md#older-layouts) for migration.

```yaml
- id: flights
  type: flight-counter
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    label: FLT
```

### `flight-mode`

Drawer title: **Flight mode** · [drawer settings and behavior](../panels/flight-mode.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `MODE` | Any string | Label | Heading. |
| `showIndex` | boolean | `false` | `true` / `false` | Show mode number | |
| `accent` | string | `green` | `cyan`, `green`, `amber`, `orange` | Accent | |

No panel-specific cross-field validation is declared.

```yaml
- id: mode
  type: flight-mode
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    showIndex: true
```

### `flight-timer`

Drawer title: **Flight timer** · [drawer settings and behavior](../panels/flight-timer.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `timer` | number | `0` | Integer `0`, `1` or `2` | Model timer | Must identify one of the radio's three model timers when explicitly present. |
| `label` | string | `""` | Any string | Label | Empty means derive the heading from the timer's name or number. |
| `warning` | number | Unset (drawer: `Off`) | `0` or more whole seconds; omit for Off | Warning seconds | Threshold is interpreted according to the timer's count-up/countdown direction. |
| `critical` | number | Unset (drawer: `Off`) | `0` or more whole seconds; omit for Off | Critical seconds | Critical takes precedence if both conditions apply; expired countdowns are critical. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

Cross-field rules: no threshold ordering or numeric range is enforced by the panel validator. An explicitly supplied `timer` must be an integer from 0 through 2; an absent value gets the valid default `0`.

```yaml
- id: timer
  type: flight-timer
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    timer: 0
    warning: 300
    critical: 60
```

### `host-diagnostics`

Drawer title: **Host diagnostics** · [drawer settings and behavior](../panels/host-diagnostics.md) · Supported spans: `2x2`, `3x2`, `4x2`, `2x3`, `3x3`, `4x3`, `2x4`, `3x4`, `4x4`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `""` | Any string | Label | Blank derives the heading from the selected section. |
| `section` | string | `identity` | `identity`, `theme`, `panels`, `sources`, `log`, `scheduler` | Section | Selects which host diagnostics to show. |
| `maxEntries` | number | `64` | Integer 1–256 | Maximum log entries | Shown for `log`. Largest live log panel setting determines shared retention. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

`maxEntries` must be an integer from 1 to 256.

```yaml
- id: diagnostics
  type: host-diagnostics
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    section: panels
```

### `link-status`

Drawer title: **Link status** · [drawer settings and behavior](../panels/link-status.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `LINK` | Any string | Label | Heading. |
| `rssiSource` | string | `RSSI` | EdgeTX source name, or blank when no RSSI threshold is configured | RSSI source | Used by RSSI readings and thresholds. |
| `qualitySource` | string | `""` | Any EdgeTX source name or blank | Link quality source | Link quality is not inferred when absent. |
| `modeSource` | string | `""` | Any EdgeTX source name or blank | RF mode source | Required for RSSI-margin thresholds. |
| `snrSource` | string | `""` | Any EdgeTX source name or blank | SNR source | |
| `powerSource` | string | `""` | Any EdgeTX source name or blank | Transmit power source | |
| `protocol` | string | `generic` | `generic`, `elrs4` | Protocol mapping | ELRS 4 mapping is needed for margin thresholds. |
| `reading` | string | `auto` | `auto`, `rssi`, `quality` | Primary reading | `auto` chooses the best available primary reading. |
| `extrema` | string | `none` | `none`, `source` | Minimum tracked | `source` shows EdgeTX's own minimum. A saved `flight` loads as `source`. |
| `extremaSource` | string | `""` | Any EdgeTX source name or blank | Minimum source | Used with source tracking; blank falls back to the primary reading source. |
| `qualityWarning` | number | Unset (drawer: `Off`) | `0`–`100` percent; step `1` | Warning quality % | Requires `qualitySource`. |
| `qualityCritical` | number | Unset (drawer: `Off`) | `0`–`100` percent; step `1` | Critical quality % | Requires `qualitySource`. |
| `marginWarning` | number | Unset (drawer: `Off`) | `0`–`60` dB; step `1` | Warning RSSI margin dB | Requires `protocol: elrs4`, `modeSource` and `rssiSource`. |
| `marginCritical` | number | Unset (drawer: `Off`) | `0`–`60` dB; step `1` | Critical RSSI margin dB | Requires `protocol: elrs4`, `modeSource` and `rssiSource`. |
| `rssiWarning` | number | Unset (drawer: `Off`) | `-130`–`100` in source units; step `1` | Warning RSSI | Requires `rssiSource`. |
| `rssiCritical` | number | Unset (drawer: `Off`) | `-130`–`100` in source units; step `1` | Critical RSSI | Requires `rssiSource`. |
| `barMin` | number | `0` | Any number | Bar minimum | Bar scale lower bound, in the primary reading's units. |
| `barMax` | number | `100` | Any number | Bar maximum | Bar scale upper bound, in the primary reading's units. |
| `visual` | string | `bar` | `bar`, `none` | Visualization | |
| `accent` | string | `green` | `cyan`, `green`, `amber`, `orange` | Accent | |

Cross-field rules:

- RSSI thresholds (`rssiWarning` or `rssiCritical`) require a nonblank `rssiSource`; quality thresholds require a nonblank `qualitySource`.
- Quality thresholds must be within `0`–`100`. RSSI-margin thresholds require `protocol: elrs4` plus nonblank `modeSource` and `rssiSource`.
- For each threshold family (RSSI, quality, margin), when both values are set, `Critical` must be less than or equal to `Warning` (the panel alarms as the link degrades downward). There are no declared threshold bounds for RSSI or margin.

```yaml
- id: link
  type: link-status
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    rssiSource: RSSI
    qualitySource: RQly
    reading: auto
```

### `metric`

Drawer title: **Metric** · [drawer settings and behavior](../panels/metric.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `metrics` | sequence | `[]` | 0–3 entries | Metrics | Ordered readings: first is primary, remaining readings are supporting. Each item is a mapping; its fields follow. |
| `visual` | string | `none` | `bar`, `radial`, `none` | Visualization | Draws the main reading's visual only when it fits. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

#### Metric entry (`metrics[]`)

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `source` | string | Unset | EdgeTX numeric source name | Source | Nested in `metrics[]`; required by the drawer for a configured entry. An omitted or blank source renders unavailable rather than causing YAML validation to fail. |
| `label` | string | Unset | Any string | Label | Nested in `metrics[]`; fallback caption is the source name, or “Metric” if no source. |
| `unit` | string | Unset | Any string | Unit | Nested in `metrics[]`; unset follows the sensor unit, while `""` suppresses the unit. |
| `precision` | number | Unset | Integer `0`–`3`, or drawer's empty value `Sensor` | Precision | Nested in `metrics[]`; unset/empty follows sensor precision. |
| `direction` | string | `auto` | `auto`, `rising`, `falling` | Direction | Nested in `metrics[]`; `auto` infers falling only when both thresholds are active and Critical is below Warning; otherwise it is rising. |
| `rangeMin` | number | `0` | Finite number; drawer keyboard entry, blank restores the default | Range min | Nested in `metrics[]`; scale minimum, not a clamp on the displayed value. |
| `rangeMax` | number | `100` | Finite number; drawer keyboard entry, blank restores the default | Range max | Nested in `metrics[]`; scale maximum. |
| `warning` | number | Unset | Finite number; drawer step `0.1`; Off when outside the range | Warning | Nested in `metrics[]`; a threshold outside `rangeMin`–`rangeMax` is ignored as Off. |
| `critical` | number | Unset | Finite number; drawer step `0.1`; Off when outside the range | Critical | Nested in `metrics[]`; a threshold outside `rangeMin`–`rangeMax` is ignored as Off. |

Cross-field and list rules:

- `metrics` must be a contiguous sequence with zero to three items. The list may be empty; each item must be a mapping and only the listed entry keys are accepted.
- If present, `source` must be a string; `label` and `unit` must be strings; `precision` must be an integer from 0 to 3; numeric range/threshold values must be finite; and `direction` must be one of its three choices.
- Thresholds outside the inclusive range are treated as Off, not reported as an error. A reversed range is allowed; threshold containment uses the lower and upper endpoints after ordering them. The primary metric alone controls the alarm state; supporting metrics' thresholds do not.

```yaml
- id: altitude
  type: metric
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    metrics:
      - source: Alt
        label: Altitude
        precision: 1
    visual: none
```

### `model-identity`

Drawer title: **Model identity** · [drawer settings and behavior](../panels/model-identity.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `presentation` | string | `auto` | `auto`, `name`, `image`, `both` | Show | `auto` shows the name alone in small panels and both name and picture when there is room. |
| `label` | string | `MODEL` | Any string | Label | A custom label conflicts with an explicit `image` or `both` presentation because the model name takes the heading. |
| `showLabels` | boolean | `false` | `true` / `false` | Show model labels | |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

Cross-field rule: when `presentation` is explicitly `image` or `both`, a custom `label` other than the default `MODEL` produces a warning. `auto` and `name` do not trigger it.

```yaml
- id: identity
  type: model-identity
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    presentation: auto
```

### `navigation`

Drawer title: **Navigation** · [drawer settings and behavior](../panels/navigation.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `NAV` | Any string | Label | |
| `source` | string | `GPS` | EdgeTX GPS source name | GPS source | |
| `homeMode` | string | `edgetx` | `edgetx`, `first-arm` | Home position | Choose EdgeTX home or capture using the effective Armed condition. |
| `armSwitch` | string | `""` | Blank, physical switch position, or logical switch such as `L01` | Home arm switch | Legacy fallback before model arming is saved. Older layouts with a nonblank switch migrate to `first-arm`; other older layouts keep EdgeTX home. |
| `satelliteSource` | string | `""` | Any EdgeTX source name or blank | Satellite count source | |
| `satelliteWarning` | number | `8` | Nonnegative integer | Warn below satellites | |
| `satelliteCritical` | number | `4` | Nonnegative integer | Critical below satellites | |
| `showTape` | boolean | `false` | `true` / `false` | Show tape | When true, the tape is shown instead of the alternate bearing text. |
| `bearingFormat` | string | `degrees` | `degrees`, `quadrant` | Bearing format | Drawer hides this while `showTape` is true; it remains a valid YAML setting. |
| `showCoordinates` | boolean | `false` | `true` / `false` | Show coordinates | |
| `showSatellites` | boolean | `true` | `true` / `false` | Show satellites | Controls the header icon and locked count when `satelliteSource` is set and space permits; satellite alerts remain active when false. Omitted values preserve the enabled default. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

Cross-field and format rules:

- A nonblank `armSwitch` must be a valid physical switch position or logical switch name in the same format as Flight counter.
- `satelliteWarning` and `satelliteCritical` must be nonnegative integers. Critical must not exceed Warning; defaults are used for either omitted threshold during this comparison.

```yaml
- id: nav
  type: navigation
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    source: GPS
    showTape: true
    bearingFormat: quadrant
```

### `output`

Drawer title: **Channel output** · [drawer settings and behavior](../panels/output.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `CHANNEL OUTPUT` | Any string | Label | |
| `firstChannel` | number | `1` | Integer `1`–`32`; step `1` | First channel | |
| `channelCount` | number | Unset (drawer: `Auto`) | Integer `1`–`32`; step `1`; omit for Auto | Channel count | |
| `showNames` | boolean | `true` | `true` / `false` | Show channel names | |
| `showTrim` | boolean | `true` | `true` / `false` | Show trim | |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

Panel validation requires supplied channel numbers to be whole values from 1 to 32. If invalid, it reports the setting and resets `firstChannel` to 1 or clears `channelCount` so the latter returns to Auto.

```yaml
- id: outputs
  type: output
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    firstChannel: 1
    channelCount: 8
```

### `rx-battery`

Drawer title: **RX battery** · [drawer settings and behavior](../panels/rx-battery.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `PACK` | Any string | Label | |
| `source` | string | `Cels` | EdgeTX voltage source name | Voltage source | |
| `cells` | number | `0` | Integer `0`–`16`; step `1` | Cell count (0 = auto) | `0` enables automatic cell-count detection. |
| `reading` | string | `cell` | `cell`, `pack` | Primary reading | |
| `cellFull` | number | `4.2` | `0`–`10`; step `0.01` | Full (V/cell) | This starts the drawer's Voltage levels section. |
| `cellWarning` | number | `3.6` | `0`–`10`; step `0.01` | Warning (V/cell) | |
| `cellCritical` | number | `3.4` | `0`–`10`; step `0.01` | Critical (V/cell) | |
| `cellEmpty` | number | `3.2` | `0`–`10`; step `0.01` | Empty (V/cell) | |
| `visual` | string | `battery` | `battery`, `bar`, `none` | Visualization | The drawer labels the `none` choice as “details”. |
| `showPack` | boolean | `true` | `true` / `false` | Show alt reading | Preference for optional detail. |
| `showCount` | boolean | `true` | `true` / `false` | Show cell count | Preference for optional detail. |
| `showDelta` | boolean | `false` | `true` / `false` | Show cell delta | Preference for optional detail. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

Cross-field rules:

- `cells` must be `0` or an integer from 1 through 16. Voltage settings must be finite and ordered `cellFull > cellWarning >= cellCritical >= cellEmpty`.
- `cellFull` and `cellEmpty` are hidden in the drawer when `visual` is `none`. Detail preferences are hidden when `visual` is `battery`; their values may still be in YAML, but content is best-effort and may not fit.

```yaml
- id: receiver
  type: rx-battery
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    source: Cels
    cells: 2
```

### `service-probe`

Drawer title: **Service probe** · [drawer settings and behavior](../panels/service-probe.md) · Supported spans: `2x2`, `3x2`, `4x2`, `2x3`, `3x3`, `4x3`, `2x4`, `3x4`, `4x4`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `service` | string | `telemetry` | `telemetry`, `model`, `control`, `navigation` | Service | Selects the host service under inspection. |
| `source` | string | `""` | Any service/source name or blank | Source | |
| `index` | number | `0` | Any number | Index | Service-specific lookup/index. |
| `label` | string | `""` | Any string | Label | Blank derives the heading from the selected service. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

No panel-specific cross-field validation is declared.

```yaml
- id: probe
  type: service-probe
  col: 0
  row: 0
  colSpan: 2
  rowSpan: 2
  config:
    service: telemetry
    source: RSSI
```

### `state`

Drawer title: **State** · [drawer settings and behavior](../panels/state.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `entries` | sequence | One default entry | 1–3 contiguous entries | Entries | Each entry is a mapping with a label and an ordered state-condition list. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

#### State entry (`entries[]`)

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `SW1` | Nonempty, single-line string | Label | Nested in `entries[]`; required. |
| `states` | sequence | Three default conditions | 1–3 contiguous conditions | States | Nested in `entries[]`; evaluated in order and the first active condition wins. |

#### State condition (`entries[].states[]`)

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `switch` | string | `SA^` in default example; required otherwise | Switch position such as `SF^`, `SA-`, `SFv`, or logical switch `L01` | When | Nested in `entries[].states[]`; required. |
| `text` | string | `UP` in default example; required otherwise | Nonempty, single-line string | Text | Nested in `entries[].states[]`; displayed when the condition matches. |
| `background` | string | `normal` | `normal`, `active`, `warning`, `critical` | Background | Nested in `entries[].states[]`; omitted uses `normal`. |

Cross-field and list rules:

- `entries` and each entry's `states` must be contiguous sequences with 1–3 items. Each entry and condition must be a mapping; unrecognized keys inside either mapping are reported as invalid state settings.
- Every entry needs a nonempty, single-line `label`; every condition needs a valid `switch` and nonempty, single-line `text`. `background`, if present, must be one of its four choices.

```yaml
- id: switches
  type: state
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    entries:
      - label: Gear
        states:
          - switch: SA^
            text: DOWN
            background: active
          - switch: SAv
            text: UP
            background: warning
```

### `trim-panel`

Drawer title: **Trim** · [drawer settings and behavior](../panels/trim-panel.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `trim1` | string | `trim-ail` | EdgeTX trim source name | Trim 1 | |
| `trim2` | string | `trim-ele` | EdgeTX trim source name | Trim 2 | |
| `trim4` | string | `trim-rud` | EdgeTX trim source name | Trim 4 | Corresponds to rudder trim. |
| `scale` | string | `auto` | `auto`, `standard`, `extended` | Scale | |
| `readout` | string | `percent` | `percent`, `raw`, `none` | Readout | |
| `label` | string | `TRIM` | Any string | Label | |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

No panel-specific cross-field validation is declared.

```yaml
- id: trims
  type: trim-panel
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    scale: auto
    readout: percent
```

### `tx-battery`

Drawer title: **TX battery** · [drawer settings and behavior](../panels/tx-battery.md) · Supported spans: `any`.

| Key | Type | Default | Allowed values | Drawer label | Notes |
| --- | --- | --- | --- | --- | --- |
| `label` | string | `TX` | Any string | Label | |
| `packEmpty` | number | Unset (drawer: `Radio`) | `3`–`20` V; step `0.01` | Empty volts, whole pack | Optional lower voltage endpoint for the estimate. |
| `packFull` | number | Unset (drawer: `Radio`) | `3`–`20` V; step `0.01` | Full volts, whole pack | Optional upper voltage endpoint for the estimate. |
| `warning` | number | Unset (drawer: `Off`) | `3`–`20` V; step `0.01` | Warning volts | |
| `critical` | number | Unset (drawer: `Off`) | `3`–`20` V; step `0.01` | Critical volts | |
| `visual` | string | `battery` | `battery`, `bar`, `none` | Visualization | |
| `showPercent` | boolean | `false` | `true` / `false` | Show estimate | The estimate needs a usable voltage range; otherwise it is unavailable. |
| `accent` | string | `cyan` | `cyan`, `green`, `amber`, `orange` | Accent | |

No panel-specific `validateSettings` function is declared, so the schema layer enforces only setting types and `visual` choices. When both `packEmpty` and `packFull` are numbers and Full is greater than Empty, they define the estimate range; otherwise the panel falls back to the radio battery-meter range. Warning and Critical are downward voltage thresholds, with Critical taking priority, and the panel does not validate their ordering.

```yaml
- id: transmitter
  type: tx-battery
  col: 0
  row: 0
  colSpan: 1
  rowSpan: 1
  config:
    visual: battery
    showPercent: true
```

## Complete example

This version-5 layout places six panels without overlap on the 4 × 4 grid.
Set the Arm switch in Model settings separately. Replace source names with
exact names available on the target radio/model.

```yaml
version: 5
grid:
  columns: 4
  rows: 4
panels:
  - id: flight
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
      label: Flight
      warning: 300
      critical: 60
  - id: link
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: auto
      extrema: source
  - id: altitude
    type: metric
    col: 0
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: Alt
          label: Altitude
          precision: 1
      visual: bar
  - id: receiver
    type: rx-battery
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      source: Cels
      cells: 2
      reading: cell
  - id: mode
    type: state
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 1
    config:
      entries:
        - label: Flight mode
          states:
            - switch: SF^
              text: Disarmed
            - switch: SFv
              text: Armed
              background: active
  - id: identity
    type: model-identity
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      presentation: auto
```

## Tips for AI agents

- Emit `version: 5`, the exact 4 × 4 grid, and a `panels` sequence. Use the schema and keys on this page; cross-reference drawer descriptions via the linked panel page.
- Place panels only at supported spans, within bounds, and without overlap. Give every panel a unique safe `id`.
- Use the exact `type` and `config` key spellings. Omit optional keys to take defaults; don't invent aliases or include unknown keys.
- Honor nested sequence constraints and all cross-field rules, especially source requirements and threshold ordering.
- Verify EdgeTX source/switch names on the target radio. A syntactically valid name may still be unavailable on that model.
- Stick to the supported YAML subset: two-space indentation, no tabs, anchors, tags or non-empty flow collections.

## Theme files

Themes use separate `.yml` files, not a layout-level `theme` key.
Copy a complete shipped theme from `/WIDGETS/AeroGrid/themes/` to
`/AEROGRID/themes/<name>.yml`; user themes override shipped names.

| Key | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Write `1`. |
| `name` | yes | Filename stem using letters, digits, `-`, and `_`. |
| `label` | yes | Nonempty name shown in the Theme picker. |
| `accent` | yes | Default accent: `cyan`, `green`, `amber`, or `orange`. |
| `colors` | yes | Complete color mapping copied from a shipped theme. Values use `0xRRGGBB`. |
| `spacing` | yes | Complete spacing mapping copied from a shipped theme; nonnegative integers. |
| `light` | no | Light-palette alert defaults; defaults to `false`. |
| `tintSeparation` | no | Alert-surface separation target, at least 1. |
| `correctForContrast` | no | Adjust colors for readability; defaults to `true` when omitted. Both shipped themes explicitly set it to `false`. |

Optional entries in `colors`:

| Key | Meaning |
| --- | --- |
| `warningBg`, `criticalBg`, `activeBg` | Explicit panel backgrounds for those states; otherwise derived. |
| `chartCyan`, `chartGreen`, `chartAmber`, `chartOrange` | Chart trace and legend colors; otherwise use the matching semantic accent. |
| `chartGrid` | Chart time grid and baseline; otherwise uses `border`. |

With contrast correction enabled, chart inks are adjusted to at least 4.5:1
contrast against the panel surface; the chart grid is unchanged. With correction
disabled, explicit colors are preserved and you must check readability.
Omitted alert backgrounds still use contrast-checked derived tints.
Unknown fields and invalid values are rejected. Preview every state in
**Palette** on the radio before using a custom theme.
