# Satellite maps: specification and delivery status

## Status and scope

Status reviewed: 2026-10-21.

This is the consolidated specification for browser map preparation, the SD-card
map library, and the AeroGrid radio map panel. It records the implemented
prototype and the remaining product work; it does not declare the feature
production-ready or authorize every proposed follow-up.

The implementation currently spans three open pull requests:

| Layer | Implementation | State at review |
| --- | --- | --- |
| [#171](https://github.com/thomaskistler/aero-grid/pull/171) | Browser planner and radio-screen coverage simulator | Draft; targets `main` |
| [#172](https://github.com/thomaskistler/aero-grid/pull/172) | Radio map-panel prototype, shared-library reader, automatic area selection | Draft; independently targets `main` |
| [#176](https://github.com/thomaskistler/aero-grid/pull/176) | Shared map-library producer, JPEG ZIP export, imagery adapter | Ready for review; targets #171's branch |

**This document describes the combined state, including #176, not just the
files present on the planner branch.** PR states are a dated snapshot, not a
claim that these changes are merged or released. Later layers supersede earlier
handoff notes: PNG map packs and the exactly-two-zoom prototype contract are
obsolete. Transparent marker artwork remains PNG.

Detailed implementation references, available on the combined branch:

- `docs/developer-guide/map-packs.md`: manifest, shared identity, export limits,
  migration, and automatic area selection.
- `docs/developer-guide/map-prototype.md`: radio interaction, rendering,
  resource constraints, and hardware checks.
- `docs/user-guide/map-planner.md`: browser workflow.
- `MAP-PROTOTYPE-HANDOFF.md`: temporary historical handoff, not the canonical
  product specification.

  ## PR ownership and parallel iteration

  The agreed consolidation keeps exactly three workstreams and retains the
  integrated browser planner/download page:

  | PR | Intended base | Owns |
  | --- | --- | --- |
  | #171: planner | `main` | Area selection, geometry/coverage calculations, radio presets, preview, selection JSON, and this consolidated specification |
  | #172: radio panel | `main` | Runtime rendering, telemetry/follow/area discovery, radio manifest reader, synthetic SD fixtures, and their tests |
  | #176: downloader | #171's planner branch | Imagery adapters, browser tile library, JPEG conversion, ZIP production, download controls, and their tests |

  This organization is now in place. The radio-side changes previously carried
  in #176 have moved into #172. The old planner/panel native stack was replaced
  by native stack #177 containing #171 and #176; #172 is standalone. Existing PR
  numbers and draft/ready states were preserved.

  Panel development must not require planner or downloader implementation files.
  Its fixtures exercise the shared contract independently. Downloader development
  must not require the panel implementation to export valid manifests and tiles;
  contract tests should stand alone, with cross-component tests additionally run
  against the combined branches. The downloader still has an intentional planner
  dependency because both share one browser page. That does not block parallel
  iteration, but planner changes may require resynchronizing the downloader.

  The shared manifest and image contract in this specification is the integration
  boundary, not either branch's current internal code. A contract change requires
  agreement and coordinated producer/consumer updates; interface drift must not be
  hidden by silently changing both sides in one unrelated PR.

  Keep panel-only technical documentation with the panel and browser-only
  documentation with its owning browser layer. Shared workflow/CI/configuration
  files may need small integration hunks, but a PR should not carry another
  workstream's full implementation merely to make those hunks apply.

  ## Product goal

Allow an EdgeTX user anywhere in the world to select a flying area in a browser,
prepare offline satellite imagery for an SD card, and see aircraft and home
positions on that imagery in AeroGrid.

The intended experience should require minimal setup, no locally installed
downloader, and no user-supplied API key. Worldwide availability is a requirement,
not evidence that a suitable imagery license has already been found.

The first delivery workflow is **select area -> download ZIP -> extract at
SD-card root**. Direct-to-radio saving and AeroGrid installation/upgrades are
deferred. Long term, these should fit a coherent browser companion experience:
connect the radio, manage maps, and install or update AeroGrid without destroying
user data. The USB radio functionality developed for AeroGrid installation
must also support future map updates through the same connection/storage
capability. The connection mechanism and shared UX are not yet specified;
map updating remains outside the initial installer scope.

The prototype is not flight-navigation software. Synthetic imagery is test
data, and this feature must not be represented as a safety-critical navigation
aid.

## End-to-end status

| Capability | Present in the combined implementation | Missing or unverified |
| --- | --- | --- |
| Area planning | Editable flying area, radio presets, automatic overview, detail range, two coverage policies | Broader usability and browser/device verification |
| Screen simulation | Integer zoom and coverage-clamped dragging at preset dimensions | Actual AeroGrid layout and rendering-performance simulation |
| Pack preparation | Complete SD-ready ZIP, source abstraction, synthetic export, experimental Google hybrid export | Verified offline-authorized worldwide satellite source |
| Shared tile library | Named areas reference shared XYZ JPEG tiles; persistent first-capture browser library | Installed-SD inspection, targeted refresh, cleanup, cross-browser library reconciliation |
| Radio loading | Shared manifest validation, bounded loading, automatic GPS area selection | Physical-radio performance and native-memory evidence |
| Radio interaction | Aircraft/home markers, heading, touch pan/zoom, adaptive follow | Normal editor-catalog integration, broader radio support, final off-coverage UX |
| Installation | Manual ZIP extraction; map-only files | Transactional/recoverable installation, direct SD access, AeroGrid install/update |
| Flight trail | None | Sampling, capacity, rendering strategy, and implementation |

## Browser planning requirements

### Flying area and coverage

The blue rectangle is the user's exact flying area. It must not jump to tile
boundaries when edited. The separate dashed amber outline and overview grid
describe download coverage, not a second editable selection.

Selection uses Shift-drag. Use visible area supports alternatives to that
gesture; Use my location and Clear selection are retained. Coordinate-entry,
two-corner, and explicit Apply bounds workflows are intentionally absent.

Tiles use EPSG:3857 Web Mercator, XYZ addressing, and native 256 x 256 pixels.
Latitude is limited to Web Mercator coverage; date-line crossing is supported.

Overview zoom is the highest integer from 11 through 19 at which the original
flying area fits the chosen full radio screen. Reject an area that cannot fit
at zoom 11. Maximum detail is user-selected through 19; include every integer
level from overview through maximum, with no silent omission.

| Planner preset | Screen pixels | Minimum screen-filling tile footprint |
| --- | --- | --- |
| Original TX16S/MAX | 480 x 272 | 2 x 2 |
| TX16S MKII/MAX | 480 x 272 | 2 x 2 |
| TX15/MAX | 480 x 320 | 2 x 2 |
| TX16S MK3/MAX | 800 x 480 | 4 x 2 |

These are planning dimensions, not a claim that all four radios are supported
by the runtime. The tile footprint is `ceil(width / 256)` by
`ceil(height / 256)` with edge-clamped panning; it is not the maximum number of
partially intersecting tiles during arbitrary panning.

Two coverage policies are implemented:

- **Full-area-clamped:** snap and expand the flying area at overview zoom to
  a screen-filling tile rectangle. Cover that same geographic footprint at
  every included zoom.
- **Per-zoom-clamped / space-saving:** independently snap the original flying
  area at each zoom and expand only enough to fill the selected screen.
  Higher levels need not cover the expanded overview footprint.

Neither policy adds a plane-centering buffer. Both have the same overview
coverage. Space-saving assumes the aircraft stays in the blue flying area.

### Preview and output

The radio-screen preview has native internal preset dimensions and scales
visually to fit the browser page. Dedicated buttons move one integer zoom
level at a time; dragging is clamped to the active level's actual coverage.
It is an online, full-screen coverage approximation, not a simulation of
radio decoding, telemetry, or the final panel chrome.

Retain selection JSON export independently of imagery export. A named selection
preserves original bounds, expanded/per-level coverage, radio preset, zoom
range, and coverage mode. Selection JSON is not directly radio-loadable.

Export must preserve the selected coverage exactly, reject more than 2,000
tiles, and never silently reduce detail or replace missing imagery.

## SD-card map-library contract

### Layout and identity

ZIPs contain root-relative SD paths, without an enclosing ZIP-name directory:

```text
AEROGRID/maps/
  areas/my-field.yaml
  selections/my-field.json
  sources/<imagery-set>.json
  tiles/<imagery-set>/<zoom>/<canonical-x>/<y>.jpg
```

An area is a named set of complete coverage rectangles referencing one imagery
set. Multiple areas can overlap and reuse identical tile paths. A ZIP is
self-contained for its area: it includes every referenced tile even if the
browser has downloaded those tiles before.

Area and imagery-set IDs contain 1-32 lowercase ASCII letters, digits,
underscores, or hyphens. The area ID matches its manifest filename. Human
display names belong in selection metadata, not filesystem path components.

An imagery-set namespace identifies fixed tile bytes and their source/edition/
conversion policy. Changed pixels must not overwrite an existing tile identity.
Different imagery editions may legitimately duplicate geographic coverage.

### Runtime manifest

```yaml
format: aerogrid-map-area
version: 1
id: my-field
imagerySet: example-edition-jpeg
projection: EPSG:3857
tileScheme: XYZ
tileSize: 256
imageFormat: jpeg
levels:
  - zoom: 17
    xMin: 30160
    xMax: 30163
    yMin: 55726
    yMax: 55729
```

The coordinates above illustrate the schema, not a user's location.

| Constraint | Current contract |
| --- | --- |
| Manifest size | At most 8 KiB |
| Levels | 1-9 ascending consecutive integers, within 11-19 |
| Area size | At most 2,000 tiles across all levels |
| Rectangles | Inclusive integer bounds; complete coverage, no sparse holes |
| X range | Starts in the canonical world; may continue across the date line, but cannot cover the whole world |
| Y range | Within the level's ordinary XYZ world bounds |
| Tile files | 256 x 256, 8-bit, three-component baseline or progressive JPEG; `.jpg`; no EXIF |
| Radio preflight | JPEG start-of-scan header within the first 4 KiB |

Date-line rectangles use continuous X in the manifest; filenames use X modulo
the world's column count at that zoom. Conversion must preserve georeferencing,
dimensions, and opacity.

`selections/<area>.json` preserves `aerogrid-map-selection` v1. Source metadata
records identity, edition policy, conversion, attribution, licensing status,
and whether images are synthetic. The runtime needs only area manifests and
tile images; it does not scan the shared tile directory.

### JPEG conversion and migration

Compatible JPEG inputs are decoded for validation and then stored byte-for-byte
without recompression. Other accepted opaque inputs are converted to JPEG at
browser quality 0.90, then checked against the radio profile. No resizing,
transparency flattening, or blank-tile substitution is permitted.

JPEG reduces compressed storage, not decoded tile memory. Browser encoders may
produce different bytes; identical source coordinates alone do not establish
cross-browser conversion identity.

Old `pack.yaml`/PNG prototype maps are not supported by a compatibility reader.
Re-export them, or regenerate simulator fixtures with `make build`. Old PNG
browser caches and SD files are not automatically deleted.

## Downloader and browser library

The implementation separates source acquisition/conversion in
`docs/javascripts/map-sources.js` from coverage/manifest/archive work in
`docs/javascripts/map-pack.js`. Sources provide metadata and
`readTile(zoom, x, y, signal)`, returning validated radio-compatible JPEG bytes.

The browser processes one tile at a time with progress and cancellation.
Changing selection, name, or area ID invalidates active work. A failed tile or
resource limit prevents offering a partial ZIP. Cancellation can retain already
captured tiles for reuse, but there is no cross-reload export-job resume.

| Resource | Current limit/behavior |
| --- | --- |
| Network image response | Streamed, at most 1 MiB |
| Request and body timeout | 30 seconds per attempt |
| Retry count | At most two retries for eligible transient failures |
| Retry policy | Backoff; honor `Retry-After` up to 10 seconds, otherwise fail with try-later |
| Encoded tile | At most 256 KiB |
| Archive-entry payload | At most 128 MiB; stored ZIP entries |
| Persistent JPEG payload | At most 128 MiB; storage/quota errors stop export |

ZIP finalization creates an additional output buffer; the payload cap is not
a total browser-RAM guarantee. There is no fixed request-rate cap beyond serial
processing and retry backoff. Provider-specific rate policy remains relevant.

Sample measurement uses the same JPEG source/conversion/cache path as export:
one sample per level, weighted by tile count. It estimates stored tile payload,
not exact ZIP size or decoded radio memory.

### Current imagery adapters and unresolved permission

Synthetic browser images can be generated for any selected location and test
the actual export/loader path without third-party imagery. The Companion fixture
is separate and fixed around its default GPS coordinates; it does not match an
arbitrary user's live position.

**Current implementation is not gated:** #176 exposes an experimental keyless
Google hybrid ZIP action using the preview endpoint. Its PR records that the
user subsequently requested this while investigating terms separately.
This supersedes the earlier handoff's description of a synthetic-only exporter,
but does not settle licensing.

Google's published standard tile policies exclude offline use. CORS access,
technical downloading, warnings, or metadata attribution do not grant offline
rights. No verified worldwide, high-resolution, no-key source permitting this
workflow has been established. Complete provider-specific on-radio attribution
is also unresolved. The adapter is not evidence that the product's imagery
requirements are met.

The Google endpoint exposes no verified immutable edition. A random, persisted
local library namespace instead retains each tile's first captured JPEG bytes.
Later exports reuse captured tiles; concurrent tabs preserve the first committed
bytes. New coordinates may be captured later, so this is not a common imagery
date or upstream snapshot. Cached tiles are not automatically refreshed.

IndexedDB loss, eviction, private browsing, another browser/device/site, or
clearing site data can create a new namespace and duplicate images already on
the radio. A new library cannot identify installed duplicates by itself.
Network/CORS errors remain explicit; no proxy, credential, or `no-cors` bypass
is implemented.

**Required release decision:** resolve the source rights and attribution model,
then decide whether to retain, replace, restrict, or disable this experimental
adapter. This is separate from implementing or testing the pack contract.

## Radio panel

### Supported prototype and interaction

`panels/map-prototype.lua` currently targets TX16S-size 480 x 272 geometry and
the EdgeTX 2.12 LVGL API. No exact minimum patch release or broader radio support
matrix is established. The panel is YAML-configured and intentionally absent
from the normal editor add-panel catalog.

The map uses native-size tile images, clipped to its grid span. It includes
aircraft/home markers, status text, and touch-only zoom/re-follow controls.
Small spans hide controls when necessary. Long-press enters widget fullscreen;
long RTN exits. Fullscreen dragging pans with per-level coverage clamping.
There is no pinch zoom or encoder-focusable map-control UI.

The map remains stationary while the aircraft stays within its central 60%
dead zone. A breach starts a coverage-clamped, fixed-target eased pan, typically
0.5-3 seconds based on filtered movement. This is adaptive follow, not mandatory
continuous aircraft centering. Manual drag pauses follow; re-follow resumes the
dead-zone policy without forcing immediate centering. GPS loss cancels active
follow motion. Coverage edges can leave the aircraft off-center or out of view.

Heading uses optional telemetry in degrees clockwise from true north, otherwise
a circular mean of the last five accepted GPS movement bearings. GPS-derived
course is not nose heading and adds turn-response lag. Stationary positions
retain the last course; GPS loss resets its history. Configured heading failure
shows `NO HDG`, rather than silently changing sources. Aircraft orientation uses
36 pre-rendered PNGs in 10-degree steps.

The shared navigation service supplies GPS freshness and home. Blank `armSwitch`
uses EdgeTX home; a configured switch captures home on an observed
disarmed-to-armed transition with fresh GPS. Matching subscriptions share within
one widget instance only. This is not a persistent model-wide home/settings
service across screens.

### Automatic area selection

With the area override blank, discovery starts when the navigation service has
a known source, valid fix, and normal/fresh state. This is not a satellite-count
or 3D-fix guarantee.

Discovery reads at most one area manifest per refresh and retains the best
candidate. A match covers the position at every declared level. Ranking is:
highest maximum zoom, then smallest highest-detail coverage, then lexical ID.
The chosen area is sticky while GPS remains covered; leaving coverage triggers
rediscovery. GPS loss retains selection with the appropriate telemetry status.
An explicit `pack` area ID still supports fixed/development selections.

Discovery allows at most 64 area manifests and 256 directory entries. Invalid
manifests and access/limit failures surface as errors, not silently skipped maps.
No match shows `NO MAP AT GPS`; no installed area directory shows
`NO INSTALLED MAP`. Unmatched searches retry after 10 seconds. Replacing files
for an already active area requires reloading the panel.

### Rendering constraints and evidence

Nine reusable tile image objects cover the worst TX16S viewport intersection.
Retained tiles survive panning; new sources are staged at most once every
250 ms. Animation requests refresh about every 20 ms, subject to firmware
scheduling. Stable GPS-only updates avoid Lua tile-file work unless viewport
or tile coverage changes; heading changes may still change marker sources.

EdgeTX's default native image cache has eight entries. Nine visible tiles plus
markers can therefore trigger cache churn and synchronous decoding. An opaque
256 x 256 tile has approximately 128 KiB RGB565 payload, with an additional
approximately 256 KiB temporary RGBA buffer during decoding, before other
allocations. Lua GC measurements do not establish native-memory headroom.
Stable Lua sources do not prove that native redraws avoid SD reads.

Automated browser/export/parser/decoder tests and native Companion interaction
checks exist. Physical-radio memory, latency, decoding, and sustained-use
performance remain unverified. Header preflight is not full image validation
or a guarantee that the firmware has enough memory to draw it.

## Installation and library lifecycle

Users extract a complete map ZIP at SD root. It includes only map-library
files, not widget, model, radio configuration, or firmware files. Install the
widget separately and select a layout containing the experimental panel.

Reusing an area ID replaces its manifest and saved selection after extraction
confirmation. Matching immutable tile paths can be reused by overlapping areas.
Extraction is not transactional, cannot inspect installed state, and cannot
roll back partial installation. Backups remain necessary. Removed coverage can
leave unreferenced images; no automatic deletion is performed.

A future connected installer must validate images before committing recoverable
manifest updates. Cleanup must derive references from every area and refuse
unsafe deletion when any manifest is unreadable or unsupported. AeroGrid updates
must preserve map libraries and user data. Browser access to mounted SD storage
must be investigated separately from firmware flashing; EdgeTX Buddy-like UX
does not itself establish a usable filesystem API.

## Remaining work and decision register

| Item | What remains | Dependency or acceptance evidence |
| --- | --- | --- |
| Imagery source and attribution | Verify worldwide coverage, terms, offline rights, display credits, and technical access; settle experimental Google adapter disposition | Required before representing downloads as a supported, authorized product |
| Public map-panel UX | Decide catalog availability, area settings/display, missing-map guidance, and off-coverage behavior | Users can add/configure the panel and understand its states without fixture YAML |
| Radio support | Verify actual viewport geometry and behavior for each advertised radio and EdgeTX patch | Planner preset alone is insufficient |
| Hardware rendering | Measure cold/warm loading, repeated pan/zoom/turns, native memory, cache churn, errors, and control responsiveness | Record exact radio, firmware, SD card, and package |
| Library refresh | Define source editions, refresh granularity, namespace retention, and browser-storage-loss behavior | No changed pixels silently overwrite a shared identity |
| Connected map management | Installed-area inspection, missing-tile calculation, recoverable writes, deletion, and reference-safe cleanup | Requires explicit browser/OS compatibility and failure-recovery design |
| Companion install/update UX | Shared connection flow, version handling, backups, and preservation of maps/settings | Future scope, not part of ZIP-only delivery |
| Historical trail | Decide whether needed, distance-based sampling, capacity, and rendering strategy | No trail or writable-raster implementation currently exists |
| Persistence | Decide pan/zoom/follow/home persistence and any model-wide setting ownership | Current instance/subscription behavior must not be mistaken for model-wide storage |
| Merge/release integration | Review the stack, reconcile dated handoffs, regenerate fixtures, and document migration | Each layer remains unmerged at this snapshot |

Hardware measurements can change resource budgets, loading cadence, image
strategy, and supported devices. They are **not a prerequisite** to pack-format,
export, georeferencing, or source-interface development. Synthetic tiles around
known coordinates support those checks; real imagery is useful for visual
quality, realistic compressed sizes/read behavior, and source integration.

### Task backlog by workstream

Unchecked items below are outstanding, not claims that implementation is
authorized. **Decision** items require an agreed design before code;
**validation** items require evidence rather than necessarily new features.
**Deferred** items are outside the agreed first ZIP-only delivery.

#### Planner (#171)

Core area selection, coverage calculations, radio presets, selection JSON, and
integer-zoom preview are implemented. No additional planner feature has yet
been agreed as required for the first slice.

- [ ] **Validation:** Check selection/editing, visible-area selection, zoom
  controls, preview scaling, and status/error readability across the intended
  desktop and touch-browser matrix; record that matrix and fix demonstrated
  usability failures.
- [ ] **Integration:** Keep selection JSON and both coverage modes compatible
  with the downloader as the branches evolve; retain date-line, screen-fit,
  and tile-limit regression coverage.
- [ ] **Decision:** After runtime radio verification, distinguish supported
  radios from planning-only presets clearly in the UI and documentation.
  Do not remove useful planning presets merely because runtime support is pending.

#### Downloader (#176)

ZIP generation, JPEG conversion, synthetic export, experimental Google export,
progress/cancellation, and browser tile reuse are implemented.

- [ ] **Decision/research:** Resolve offline imagery rights, worldwide
  availability, source access/rate constraints, and required attribution.
  Decide whether to retain, restrict, disable, or replace the Google adapter.
- [ ] **Implementation after source decision:** Implement any required adapter
  or source-policy changes and carry required source/edition/credit metadata
  through export. Coordinate visible radio attribution with the panel owner.
- [ ] **Validation:** Verify actual supported source responses and browser CORS
  behavior when authorized; existing intercepted/mock-image checks do not prove
  the live endpoint works.
- [ ] **Decision:** Specify deliberate imagery refresh, edition identity,
  browser-library loss/recovery, and handling of old/unreferenced data.
  The current first-capture cache is not an update manager.
- [ ] **Integration:** Preserve independent archive/image/contract tests and a
  combined producer-to-radio-reader check after the PR split.
- [ ] **Deferred:** Inspect installed maps, calculate missing tiles, write
  directly to SD, perform recoverable area replacements, and safely remove
  unreferenced tiles.

#### Radio panel (#172)

Rendering, markers, heading, touch controls, adaptive follow, JPEG loading, and
automatic area discovery are implemented prototypes.

- [ ] **Decision and implementation:** Define normal editor-catalog availability
  and configuration, then make adding the panel possible without development
  fixture YAML.
- [ ] **Decision and implementation:** Finish user-facing missing-map,
  selected-area, and off-coverage guidance. Preserve existing explicit
  no-map/GPS/error states rather than substituting false positions.
- [ ] **Implementation after source decision:** Provide the required visible
  imagery attribution; source metadata alone does not establish compliance.
- [ ] **Validation:** Measure physical-radio cold/warm load, sustained pans,
  repeated zooms, heading changes, native memory, decoder errors, and control
  responsiveness. Address demonstrated cache/memory/latency failures before
  declaring support.
- [ ] **Validation:** Check moving-GPS follow, abrupt changes, coverage edges,
  heading lag, GPS loss/recovery, and manual pause/re-follow on native hardware.
  Tune behavior based on evidence, without making these tests a prerequisite
  for downloader development.
- [ ] **Validation and implementation as needed:** Establish the radio/EdgeTX
  patch support matrix and adapt geometry/resources for additional radios.
  Currently only TX16S-size runtime geometry is targeted.
- [ ] **Decision:** Specify whether pan/zoom/follow/home should persist and
  whether home/settings should be shared model-wide across screens.
- [ ] **Deferred decision:** Decide whether a historical trail is needed;
  agree sampling, capacity, and rendering before implementing it.

#### Cross-workstream coordination

- [x] Complete the agreed three-PR split without losing the combined behavior;
  keep the radio panel independent of browser implementation.
- [ ] Reconcile dated handoff documents, installation instructions, old-pack
  migration guidance, and fixture generation with the final PR organization.
- [ ] Review and integrate the three PRs, preserving their intended boundaries
  and the shared contract.
- [ ] **Deferred decision:** Design the common connect-radio experience for
  maps and AeroGrid installation/upgrades, including browser/OS support,
  recoverable writes, and user-data preservation.

### Acceptance checks for the existing ZIP-only slice

- The chosen area and all selected zooms round-trip from planner through ZIP to
  the actual radio parser/projection, including space-saving and date-line cases.
- Exported JPEGs fully decode; compatible source JPEGs remain byte-identical.
  Shared identities never acquire conflicting tile bytes.
- Limits, bad responses, malformed images, missing tiles, cancellation, storage
  failures, and stale selections fail explicitly without offering incomplete ZIPs.
- Overlapping exports reuse saved tile bytes, but each archive remains complete.
- Automatic area selection has deterministic ranking, sticky coverage behavior,
  bounded discovery, and correct GPS-loss/no-map/error states.
- Simulator fixtures are separate from user maps and excluded from release
  packages. A map ZIP never overwrites `WIDGETS/`, `MODELS/`, or `RADIO/`.
- Documentation distinguishes implemented software, measured hardware evidence,
  source permission, and future UX; none is inferred from the others.

Keep this document current as decisions land. Concrete contract changes must
also update the producer, radio consumer, detailed technical guide, fixtures,
and relevant tests together.
