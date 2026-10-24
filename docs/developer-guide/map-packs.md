# Map areas and shared tiles

AeroGrid stores **named flying areas referencing one shared image library**.
Overlapping areas reuse a tile only when its imagery-set ID and canonical XYZ
coordinates match. Areas may overlap geographically; different imagery editions
are intentionally separate.

## SD-card layout

```text
AEROGRID/maps/
  areas/my-field.yaml
  tiles/synthetic-v1-jpeg-q90/17/30161/55727.jpg
```

Directory handles are reused within each map-write batch and inventory scan.
Writes remain sequential by default; the completed sync inventory is reused for the UI
refresh instead of scanning the tiles again.

The connected manager reads and writes these paths directly under the SD-card
root. Each area has exactly one YAML metadata file; JPEGs remain shared. No
`selections/` or `sources/` sidecars are read or written.

The radio panel in PR #172 consumes these version 2 area manifests and shared
tile paths. It validates the selection metadata and uses the declared level
coverage to locate tiles. Version 1 manifests are not supported.

The consumer and simulator behavior described here belongs to the independent
radio-panel workstream. See [testing](testing.md#planner-and-map-file-contract)
for format 2 file-generation and validation checks.

The radio-panel workstream's simulator build generates a separate `synthetic` area referencing
`companion-v1-jpeg-v1` around Companion's known GPS location. The browser's
`synthetic-v1-jpeg-q90` source generates different, coordinate-derived artificial
images at any selected location. Both are test patterns, not flight terrain.
Simulator fixtures remain excluded from release archives.

## Area metadata v2

```yaml
format: aerogrid-map-area
version: 2
id: my-field
name: "My field: north #1"
imagerySet: synthetic-v1-jpeg-q90
projection: EPSG:3857
tileScheme: XYZ
tileSize: 256
imageFormat: jpeg
selection:
  bounds:
    west: -97.158
    south: 25.997
    east: -97.157
    north: 25.998
  radio: tx16s
  coverageMode: per-zoom-clamped
levels:
  - zoom: 17
    xMin: 30161
    xMax: 30162
    yMin: 55727
    yMax: 55728
```

- IDs use 1-32 lowercase ASCII letters, digits, underscores or hyphens.
  The area ID must match its filename. `name` is a trimmed 1-80-character human
  display name, never a filename. The writer uses JSON double-quoted strings
  (valid YAML), safely preserving colons, hashes, quotes, backslashes and escaped
  newlines. The browser reader accepts only this constrained mapping/sequence
  schema, not general YAML tags, aliases, flow collections or block strings.
- `selection.bounds` contains the **original selected bounds**, not snapped
  coverage. `selection.radio` is the planner preset ID, not a radio object.
  `selection.coverageMode` is `full-area-clamped` or `per-zoom-clamped`.
  The browser reconstructs the planner selection and exact per-zoom bounds
  from these fields and rejects runtime rectangles inconsistent with that plan.
- Manifests are at most 8 KiB and declare 1-9 ascending consecutive zoom levels,
  each within 11-19, with no more than 2,000 tiles in total.
- Bounds are inclusive integers. `0 <= xMin < 2^zoom`,
  `xMin <= xMax < xMin + 2^zoom - 1` and
  `0 <= yMin <= yMax < 2^zoom`. Whole-world coverage is not supported.
- For date-line coverage, X is continuous and may extend past the world edge:
  at zoom 17, `xMin: 131071, xMax: 131072` addresses canonical columns
  `131071` and `0`. Image filenames always use `x modulo 2^zoom`.
  Projection and zooming choose the world copy nearest the area's coverage.
- Each declared rectangle must be complete. No sparse coverage, blank
  replacements or silently omitted zoom levels.
- Images are native 256 x 256, 8-bit, three-component JPEG, baseline or progressive,
  with `.jpg` filenames and no EXIF. The start-of-scan header must occur within
  the first 4 KiB for bounded radio preflight. Web Mercator/XYZ georeferencing
  must not change in conversion. Full image decoding remains firmware-owned.

Map tiles are JPEG-only, including synthetic fixtures. Old PNG prototype
libraries must be regenerated; rebuild Companion fixtures with the panel branch's `make build`. The JPEG
browser library has a new IndexedDB name and does not reuse old PNG namespaces.
Old PNG site-storage entries and SD files are not automatically deleted.
Transparent marker/UI artwork remains PNG and is not part of the tile format.

The browser preserves the exact planner coverage: full-area-clamped or
per-zoom-clamped, all selected levels, and the original blue flying area.
It verifies the selection's coverage by recalculating it rather than
trusting a supplied tile count.

## Shared identity and metadata

An imagery-set ID identifies a **source, immutable edition and conversion
profile**. It must not be reused for changed pixels. Browser JPEG encoders can
differ across engines; the saved Google library preserves its first encoded
bytes. Synthetic imagery is test data, not a cross-browser reproducibility
guarantee. A future imagery refresh or conversion change needs
a new namespace; old areas keep referencing their existing edition.

Format 2 stores only display/selection information and runtime tile coverage.
It contains no provider metadata, attribution, terms or license fields. Source
validation, immutable imagery-set identity, provenance and first-capture caching
remain internal to the browser source adapter; removing SD metadata does not
waive offline permission or attribution obligations.

## Connected map manager

The browser map manager uses the same SD-card-root picker and page-session
`RadioStorage` connection as the installer. The SD-card handle is retained in
IndexedDB with a per-tab session marker, so navigation and reloads restore the
connection after rechecking read permission and the SD-card root. Explicit
disconnect clears it; restoring never prompts for new permission or grants
write permission. It recognizes the connected radio's screen dimensions and
lists only format 2 areas. Compatibility issues are warnings, as the installer
does. The installer and map manager intentionally keep separate dialogs,
progress indicators and completion states because package replacement and map
sync have different cancellation and commit rules. They share radio storage,
connection help and small local rendering helpers only.
All planning uses the connected radio's detected screen dimensions, including
128 x 64 and 212 x 64 monochrome screens. There is no manual planning-size
selector or substitute screen size. Unknown dimensions produce an explicit
coverage-calculation error rather than assuming another radio's dimensions.
Compatibility warnings do not block map controls. It does not write
outside `AEROGRID/maps/`.

Saved areas remain visible on the map; the selected area is highlighted and
only it can be edited. Selecting an area from the list centers the map on its
bounds. Clicking map coverage selects the area; when areas overlap, a chooser
asks which one to select. Panning does not change selection. Dragging a selected
rectangle's corner edits that area's bounds; **Add map area** followed by an
ordinary drag, or Shift-drag directly, can
create a new area, and the Add button can cancel draw mode. The 17/18/19 detail
cards preview the same location and select the maximum zoom, with all
intermediate levels retained.

Storage optimization is always enabled in the manager: new and updated
coverage uses `per-zoom-clamped`, without a visible toggle. Existing saved
full-area coverage remains unchanged on the radio until an update is synced.

Changes are staged per area. Staging reuses radio JPEGs whose imagery-set and
XYZ path still match, and prepares only missing tile content. Sync writes
staged files under the map-library root, retains existing shared tile bytes,
prunes old coverage after updates only when no remaining app area references
those tiles, removes an area's YAML metadata when deleted, and
preserves all shared tile references. A mid-write failure may leave some new
unreferenced tiles or partially updated metadata; retry after reconnecting and
reviewing the current radio library. Installer writes and map writes share the
radio storage lock.

The browser File System Access API does not expose free SD-card capacity.
The manager reports current image bytes and the planned update size, but does
not check available filesystem space. Confirm that the SD card has enough room
before syncing; a write can fail if it fills.

The experimental Google hybrid adapter uses the same keyless XYZ endpoint as
the online preview. This is a technical implementation, **not verification of
offline-use permission**. Google's published
[tile policies](https://developers.google.com/maps/documentation/tile/policies)
exclude offline use under standard terms. Applicable source terms, export rights
and display-attribution requirements remain an external prerequisite for lawful
use. A metadata credit is not assumed to satisfy display requirements, and no
offline authorization or complete provider-specific on-screen attribution is
claimed by this prototype.

Unlike the synthetic source, that live endpoint has no verified immutable
edition. The browser instead creates a local, first-capture library: a random
imagery-set ID is saved in IndexedDB together with each JPEG. Later
preparations reuse the saved pixels and namespace, fetching only tiles not yet
saved. Overlapping areas prepared by the same browser/site therefore share tile
paths and bytes on the radio.

The browser's internal source metadata records the library creation time, conversion profile,
first-capture policy and unresolved licensing status. This is not an upstream
Google edition or a guarantee that all tiles were captured on the same date.
Cached tiles are never automatically refreshed. Concurrent tabs retain the
first committed tile rather than replacing it.

Browser storage is capped at 128 MiB of JPEG payload. Storage/quota failures
stop preparation explicitly. Cancellation may
leave already captured tiles cached for later reuse. Private browsing, storage
eviction, another browser/device/site or clearing site data can start a new
library and therefore duplicate imagery already on the radio. Clearing site
data is also the current way to deliberately start a fresh capture; it cannot
change radio files. Metadata-only edits such as renaming do not need the
browser capture library when the area's saved tiles are present. Missing images
can be restored only with the matching browser capture-library ID (or the known
reproducible synthetic set); the manager never mixes a new capture into an
existing imagery-set namespace. There is no provider inference or authorization
from a name in the area YAML.

If format 2 area YAML remains but a JPEG or the entire `tiles/` tree has been
deleted, connecting marks affected areas **Pending changes** and enables Sync Maps.
Review lists them as **Repair**. Existing JPEGs are reused first; missing tiles
come from the same imagery-set browser cache, then its normal source download
path (or reproducible synthetic generator). Losing the original browser capture
identity still prevents repair: a new capture is never relabeled as the old set.
Missing references remain in the inventory's `referencedTiles` for safe pruning.
`missingTiles`/`missingTileCount` are recorded globally (deduplicated) and per
area, separately from actual `tileSizes`/occupied bytes. Projected storage
estimates missing keys until preparation supplies exact sizes.

Only absent entries and `NotFoundError` are repairable. Empty, oversized or
incompatible JPEG headers/end markers, wrong entry kinds and access failures
remain explicit errors; inventory checks are bounded preflight, not full pixel
decoding. Review rescans for deletions since connection. Confirmation tolerates
later deletions when prepared tile bytes cover every retained missing reference.
Otherwise it writes nothing and asks for another review; concurrent manifest
changes or changed sizes of still-present tiles require reconnecting. A final
inventory must have no missing references before reporting success. Reconnect
to detect external deletions when no changes are pending.

## Browser imagery preparation and limits

The manager stages missing imagery directly as area YAML and JPEG tile files.
The source-specific request and conversion code lives in
`docs/javascripts/map-sources.js`, separate from area geometry and file
generation in `map-pack.js`.

Sources implement `{ metadata, readTile(zoom, x, y, signal) }`.
`readTile` supplies a validated 256 x 256 JPEG as a `Uint8Array`; `metadata` supplies an
imagery-set ID, source, edition, conversion, license, attribution and synthetic
flag. `httpSource` implements common bounded fetching and browser decoding.
Another provider can implement the same interface without changing the radio
format. Network policy failures are explicit: no `no-cors` responses, arbitrary
URL input, proxy, hidden credential or fallback provider is introduced.

Generation processes one tile at a time, yielding between tiles for progress
and cancellation. A failed tile or invalid input prevents the staged update.
There is no cross-reload resume.

Encoded tiles are capped at 256 KiB, and area coverage is capped at 2,000
tiles. Resource limits fail explicitly and never reduce requested coverage.

Network image responses are streamed with a 1 MiB cap, even without a
`Content-Length`. PNG/JPEG/WebP header dimensions are checked before browser
decoding, then decoded dimensions are checked again. Only 256 x 256 opaque
images are accepted: no resizing, missing-image substitution or transparency
flattening. Compatible source JPEGs are decoded for validation, then their
original compressed bytes are preserved without another lossy encode. Other
inputs (including EXIF-bearing JPEGs) are converted with browser JPEG quality
0.90. Encoded output is checked against the same bounded JPEG profile. The
radio decoder in EdgeTX 2.12 supports this profile through its STB integration;
WebP is only a browser input, not a radio output. Browser decoding/color
handling can still differ across engines; separate browser libraries do not
promise cross-browser identical conversions.

Each request, including response-body reading, has a 30-second timeout and at
most two retries for network failures, timeout, HTTP 408/429 or selected transient
5xx statuses. Retry delays back off and honor `Retry-After` up to 10 seconds;
longer server-requested delays fail with a try-later message, never an early
retry. Missing/unauthorized responses and invalid images fail immediately.
Cancellation aborts requests and retry waits. CORS support and endpoint access
are provider/browser-dependent; failure does not trigger a proxy workaround.

## Automatic area selection

The radio-panel consumer accepts version 2 manifests only. It does not
recalculate planner geometry on the radio; the browser validates the saved
selection against the planner when reading or writing areas.

GPS readiness uses the existing navigation service: a known source, a valid fix
and `state: normal`, not stale/unavailable coordinates. This is readiness for
geographic map lookup, not proof of a satellite-count or 3D-fix threshold.
Coordinates alone do not expose that quality reliably. A temporary GPS loss
retains the chosen area and shows the existing GPS-stale/no-fix state.

Without a manual override, the panel incrementally lists `areas/` and reads at
most one manifest per refresh after GPS is ready. It does not scan tile folders.
It selects an area covering the position at every declared zoom, preferring
highest maximum zoom, then smallest highest-detail tile rectangle, then lexical
area ID to break exact ties. Matching handles the date line. Selection is held
while live GPS remains covered, even if another overlapping area would rank
higher; leaving coverage hides the old tiles and triggers selection again.

No match shows `NO MAP AT GPS`; a missing areas directory shows
`NO INSTALLED MAP`. Unmatched searches retry after 10 seconds, allowing later
installation without continuously polling the SD card. A scan retains only its
best candidate, with limits of 64 area manifests and 256 directory entries.
Invalid/unreadable manifests, directory-access failures and exceeded limits
surface through the panel error path rather than silently skipping files.
Changes to a currently selected area's files require reloading the panel.

## Updates

The connected manager reads area manifests, shows coverage/installed image
sizes and calculates missing or unreferenced tiles. Cleanup derives references
from all readable areas and fails if any area's references cannot be understood.
Tiles are written before area YAML, but SD-card writes are not one atomic
transaction. The review dialog requires explicit confirmation before writing.
Widget installation/update must preserve the map library and user data.

All paths are validated before work starts. Directory handles are reused within
the batch, tile writes are deduplicated across areas, and tiles are written one
at a time before any YAML writes. A tile failure stops the batch and prevents
every YAML commit in that batch. Progress counts completed files monotonically.
Cancel finishes the current tile and stops before the next file, leaving area
metadata unchanged. Completed tiles remain available for retry. Cancellation is
disabled once area metadata updates and cleanup begin.
