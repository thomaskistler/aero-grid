# Pre-generated panel screenshots

Implementation plan for [issue #107](https://github.com/thomaskistler/aero-grid/issues/107).
This is a scoped documentation delivery plan, not a change to the frozen runtime
specification.

## Stage 1 proof result

The native Companion route works on the current macOS installation.
`tools/capture-panels.py` builds a small native runner, boots an isolated model with
fixed actual trim values, verifies the values through the real control service,
waits for stable panel pixels, and saves all three crops. Two fresh runs produced
byte-identical PNGs. The full framebuffer was visually inspected.

This is a macOS/TX16S/Companion 2.12 prototype, not a portable pinned capture
framework. All nine display panels are implemented as separate recipes sharing
fixture preparation, capture, crop geometry, black borders, and provenance.
The native runner receives regions from the shared pipeline. Named YAML files
under `tools/capture-recipes/` now configure settings, sample values, panel
placements, theme, and border. `--recipe` selects custom examples; fixture
adapters and readiness checks remain in code and derive their expected values
from the selected recipe.
No VS Code extension code is reused and no production widget source
is changed. Capture-only readiness instrumentation is added to the isolated SD
copy. See the [developer instructions](../docs/developer-guide/tools.md#panel-screenshots).

## Catalogue generation result

All nine YAML recipes generate 1x2, 2x1, and 2x2 examples with 10 px black padding.
`--all` generates the 27 images directly under ignored
`build/doc-capture/<panel>/`. Each panel directory is replaced on regeneration;
no previous runs are retained. Each includes its recipe, provenance, simulator
log, and diagnostic full frame. A failed batch stops without publishing assets.

Trim, timer, flight mode, and identity use isolated firmware model settings.
Telemetry panels and TX voltage use **real EdgeTX rendering with synthetic sample
data** through capture-only API overrides passed into the real service
environment. Services and panel rendering are unchanged; these captures do
not prove end-to-end receiver telemetry. The model bitmap is the user-supplied
Crack Yak image, with redistribution permission confirmed by the contributor.

The same settings are used across all three spans. TX battery percentage is
disabled because the 2x1 panel rejects it. Readiness checks require the populated
panel presentation as well as expected service values, preventing stable
loading/unavailable frames from being accepted as screenshots.

All 27 PNGs are now copied into `docs/assets/panels/` and embedded in the
nine reference pages with sample and presentation disclosures. Changes remain
local until committed and published.

User-approved capture presentation overrides omit bottom progress bars and
brighten `textFaint` from `#69737A` to `#A7B0B6`. These are recorded in recipes
and provenance and must be disclosed in published captions. Production colors
and behavior remain unchanged; there is no post-processing of framebuffer pixels.

The Modern production palette was subsequently brightened after outdoor review:
muted is now `#DCE2E6` and faint is `#C4CDD3`. New captures with
`brighten_supporting_text` use the resolved muted color for faint text; the
existing images retain the historical colors recorded above.

## Outcome and scope

Provide real EdgeTX-rendered examples for all nine display panel references,
at 1x2, 2x1, and 2x2 spans: 27 baseline PNG images. Span names mean columns x rows.
All nine panels currently declare these spans as supported.

Generate images ahead of publication and commit them under
`docs/assets/panels/<panel>/<span>.png`. MkDocs and Pages consume those
files without running the simulator. Screenshot regeneration is a maintainer
operation, not a requirement for normal documentation builds.

Baseline captures use a pinned TX16S simulator at 480 x 272, Modern theme,
populated normal-state sample data, and one documented settings recipe per
panel. Use the same recipe across spans when valid. If a setting combination
cannot be used at a smaller span, record the override explicitly rather than
silently dropping it or modifying panel behavior.

## 1. Prove real-renderer capture before building the catalogue

Start with trim-panel at the three requested spans. Trims require no receiver,
show both graphical and numeric content, and expose compact-layout differences.

Prefer the EdgeTX WASM simulator used by EdgeTX Dev Kit: it already exposes
framebuffer copying. First establish whether it can be run with a small
standalone runner, without launching VS Code. Pin the actual firmware build,
binary digest, acquisition source, and runner dependencies; the locally cached
binary is an investigation aid, not a reproducible dependency specification.

Do not rely on undocumented VS Code module monkey-patching or turn the extension
implementation into an unmaintained copy. Review licensing before reusing any
implementation. Native Companion is an alternative, but local probing found
Intel/ARM and bundled-library loading hurdles.

The proof must:

- Boot a dedicated SD image and load current AeroGrid code.
- Set known positive, negative, and neutral trim values.
- Capture real framebuffer pixels, crop the panel, and write a PNG.
- Report startup, Lua, loading, or capture errors instead of emitting a plausible
  blank/fallback image.
- Stop all simulator workers and leave personal simulator/model state untouched.
- Repeat successfully from a fresh process and isolated image.

**Decision gate:** if standalone startup/input/capture requires fragile
workarounds, use a generated capture gallery and manual EdgeTX Dev Kit captures
for the beta. Real screenshots are required; automation is not. Do not substitute
the existing mocked HTML illustrations without an explicit scope change.

## 2. Define deterministic capture recipes and fixtures

Create a machine-readable manifest for panel type, span, settings, sample
values, placement, expected visible content, and output path. Validate recipes
through existing layout/panel validation before booting the simulator.

Build only under a dedicated directory such as `build/doc-capture/`. Never run
the ordinary `make build` against a customized active simulator image.

Sample-data coverage:

| Panel | Required fixture data |
| --- | --- |
| Metric | Numeric reading, unit/precision, optional supporting readings and visual bounds. |
| Flight timer | Named model timer frozen at a representative nonzero value. |
| Flight mode | Fixed named transmitter flight mode. |
| TX battery | Fixed voltage and explicitly documented calibration, if used. |
| Trim panel | Signed effective trim positions with visible small deviations. |
| Model identity | Fixed model name and a redistributable bitmap with known provenance. |
| Cell battery | Known cells-table or pack reading with matching source settings. |
| Link status | Live link evidence, LQ/RSSI and configured protocol details. |
| Navigation | Valid fix, known home/model positions, non-cardinal bearing and distance. |

Prefer supported simulator/model input APIs. Investigate telemetry injection
separately: raw protocol frames may not be necessary for illustrative screenshots.
If a capture-only fixture supplies firmware API values or service snapshots,
label the result as **real EdgeTX rendering with synthetic sample data** and
document the bypass. Keep that adapter outside the production widget and release
package. Such images demonstrate presentation, not end-to-end telemetry validity.

Freeze changing inputs and timer state rather than capturing by elapsed wall
clock alone. Avoid real personal models, receiver data, or unlicensed bitmaps.

## 3. Establish framing and capture readiness

Use an actual AeroGrid 4 x 4 dashboard; do not manufacture panel dimensions from
standalone boxes. Place the subject away from App mode's top-left menu overlay
for the baseline comparisons, consistently across captures. State this placement
in the reference captions. Menu-affected examples can be added separately.

Derive crop bounds from the same grid geometry used by the host, accounting for
the actual widget zone, gutters, and panel placement. Keep full-frame captures
under ignored build output for troubleshooting.

Preserve native pixel dimensions and proportions. Do not redraw, stretch, or
enhance text. Documentation may scale down responsively; readers should be able
to open the original image. A narrower panel must not be stretched to match a
wider panel's width in a comparison.

Wait for successful host loading and expected content, then for stable rendered
frames with fixed inputs. Use a bounded timeout and fail with logs/full-frame
evidence if readiness is not reached. A fixed sleep or two identical blank
frames is not sufficient proof of readiness.

## 4. Generate and validate the full set

Expand the proven workflow to all nine panels and 27 baseline cases.
Add focused extra images only where needed to explain materially different
presentations, such as metric radial versus bar or model image versus name.
Warning/stale/unavailable galleries are follow-up scope, not required for the
initial 27 images.

Proposed commands:

- `make docs-images`: explicit screenshot regeneration using the capture runner.
- A case selector for regenerating one panel/span during development.
- A fixture-only preparation command if manual capture is the chosen route.

Keep additional dependencies separate from the runtime and ordinary Lua tests.
Stage output until all requested cases succeed; do not partially overwrite the
committed catalogue on a failed run.

Validation includes:

- All 27 expected paths exist with correct native crop dimensions.
- Known values and expected content appear; no error/loading overlays are present.
- No unexpected clipping, changes of settings, or unsupported configurations.
- Repeat captures with fixed inputs are stable; investigate any differing pixels
  instead of assuming bit-for-bit determinism.
- Human visual review of every image against the live simulator.
- Existing runtime tests still pass if any shared support code changed.

## 5. Embed images and document regeneration

Place visual examples directly after each `docs/panels/*.md` page title, with labeled
1x2, 2x1, and 2x2 images and the exact example configuration, or a linked recipe.
Explain intentional supporting-content shedding and important span-dependent
presentation changes.

Captions identify simulated sample data, radio resolution, theme, span convention,
and menu-free placement. Add regeneration instructions to the Developer Guide.
Store capture provenance beside the recipes: AeroGrid revision, simulator
version/digest, inputs, settings, geometry, and command.

Do not embed a timestamp in PNGs if it creates gratuitous regeneration churn.
Run `make docs` to validate image links and preview desktop/narrow layouts.
CI initially checks manifest completeness, asset references, and the strict
MkDocs build; full simulator regeneration in CI is optional after the standalone
runner proves portable.

## Delivery order and beta gate

1. Review three trim-panel proof images and settle the capture route.
2. Freeze recipes/framing and generate the remaining 24 baseline images.
3. Review and embed all examples, then document regeneration.
4. Publish the updated reference site before the beta release.

Do not block beta on a universal simulator automation framework. If the automated
route fails the proof gate, the same recipes and framing support manual captures
and satisfy the documentation goal without misrepresenting mock illustrations.
