# Map areas and shared tiles

AeroGrid stores **named flying areas referencing one shared image library**.
Overlapping areas reuse a tile only when its imagery-set ID and canonical XYZ
coordinates match. Areas may overlap geographically; different imagery editions
are intentionally separate.

## SD-card layout

```text
AEROGRID/maps/
  areas/my-field.yaml
  selections/my-field.json
  sources/synthetic-v1-jpeg-q90.json
  tiles/synthetic-v1-jpeg-q90/17/30160/55726.jpg
```

Browser ZIPs contain these root-relative paths, not a wrapping ZIP-name folder.
Extract at the SD-card root. They include no `WIDGETS/`, `MODELS/`, `RADIO/` or
firmware files. The experimental map panel selects an installed area from live
GPS by default; leave its area override blank. An explicit `pack: my-field`
remains available for development or a deliberately fixed selection.
The radio currently supports TX16S 480 x 272 geometry only; planning another
screen size does not establish runtime compatibility.

The consumer and simulator behavior described here belongs to the independent
radio-panel workstream; this downloader branch supplies no radio implementation.
See [testing](testing.md#planner-and-downloader-contract) for standalone archive
checks and the explicitly pinned combined-source reader check.

The radio-panel workstream's simulator build generates a separate `synthetic` area referencing
`companion-v1-jpeg-v1` around Companion's known GPS location. The browser's
`synthetic-v1-jpeg-q90` source generates different, coordinate-derived artificial
images at any selected location. Both are test patterns, not flight terrain.
Simulator fixtures remain excluded from release ZIPs.

## Runtime manifest v1

```yaml
format: aerogrid-map-area
version: 1
id: my-field
imagerySet: synthetic-v1-jpeg-q90
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

- IDs use 1-32 lowercase ASCII letters, digits, underscores or hyphens.
  The area ID must match its filename. The human display name lives in the
  saved selection, rather than being interpreted as a filename.
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

Map tiles are JPEG-only, including synthetic fixtures. Old PNG prototype packs
must be re-exported; regenerate Companion fixtures with the panel branch's `make build`. The JPEG
browser library has a new IndexedDB name and does not reuse old PNG namespaces.
Old PNG site-storage entries and SD files are not automatically deleted.
Transparent marker/UI artwork remains PNG and is not part of the tile format.

The browser preserves the exact planner coverage: full-area-clamped or
per-zoom-clamped, all selected levels, and the original blue flying area.
It verifies the exported selection's coverage by recalculating it rather than
trusting a supplied tile count.

## Shared identity and metadata

An imagery-set ID identifies a **source, immutable edition and conversion
profile**. It must not be reused for changed pixels. Browser JPEG encoders can
differ across engines; the saved Google library preserves its first encoded
bytes. Synthetic exports are test data, not a cross-browser reproducibility
guarantee. A future imagery refresh or conversion change needs
a new namespace; old areas keep referencing their existing edition.

`selections/<id>.json` preserves the original `aerogrid-map-selection` v1,
including display name, original bounds, radio preset and coverage mode.
`sources/<imagerySet>.json` identifies the source, edition, conversion, license,
attribution and whether imagery is synthetic. The radio need not read either
file or scan the tile library to display an area.

## Connected map manager

The browser map manager uses the same SD-card-root picker and page-session
`RadioStorage` connection as the installer. The SD-card handle is retained in
IndexedDB with a per-tab session marker, so navigation and reloads restore the
connection after rechecking read permission and the SD-card root. Explicit
disconnect clears it; restoring never prompts for new permission or grants
write permission. It recognizes the connected radio's
screen dimensions, lists only AeroGrid areas with the supported area/selection
pair, and treats compatibility issues as warnings, as the installer does.
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
those tiles, removes an area's manifest and selection when deleted, and
preserves all shared tile references. A mid-write failure may leave some new
unreferenced tiles or partially updated metadata; retry after reconnecting and
reviewing the current radio library. Installer writes and map writes share the
radio storage lock.

The browser File System Access API does not expose free SD-card capacity.
The manager reports actual referenced map-image bytes, but cannot preflight
available filesystem space; writing can fail if the card fills. Sync is
currently disabled pending confirmation that the selected Google imagery may
be stored offline. Online map previews and preparation do not establish that
permission.

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
exports reuse the saved pixels and namespace, fetching only tiles not yet saved.
Overlapping areas exported by the same browser/site therefore share tile paths
and bytes after extraction. Each ZIP still includes every tile its area needs.

The source metadata records the library creation time, conversion profile,
first-capture policy and unresolved licensing status. This is not an upstream
Google edition or a guarantee that all tiles were captured on the same date.
Cached tiles are never automatically refreshed. Concurrent tabs retain the
first committed tile rather than replacing it.

Browser storage is capped at 128 MiB of JPEG payload, independently of the ZIP
limit. Storage/quota failures stop the export explicitly. Cancellation may
leave already captured tiles cached for later reuse. Private browsing, storage
eviction, another browser/device/site or clearing site data can start a new
library and therefore duplicate imagery already on the radio. Clearing site
data is also the current way to deliberately start a fresh capture; it cannot
change radio files. A connected installed-library reader, targeted refresh and
cleanup are deferred, not implied by this ZIP-only workflow.

## Browser export and limits

The planner offers a Google hybrid ZIP and retains selection JSON export. Its
collapsed developer-test section exports original synthetic imagery through
the same manifest/image/archive pipeline. The source-specific request and
conversion code lives in `docs/javascripts/map-sources.js`, separate from area
geometry and ZIP packaging in `map-pack.js`.

Sources implement `{ metadata, readTile(zoom, x, y, signal) }`.
`readTile` supplies a validated 256 x 256 JPEG as a `Uint8Array`; `metadata` supplies an
imagery-set ID, source, edition, conversion, license, attribution and synthetic
flag. `httpSource` implements common bounded fetching and browser decoding.
Another provider can implement the same interface without changing the radio
format. Network policy failures are explicit: no `no-cors` responses, arbitrary
URL input, proxy, hidden credential or fallback provider is introduced.

Generation processes one tile at a time, yielding between tiles for progress
and cancellation. Changing the selection, name or area ID invalidates an
in-progress export. There is no cross-reload resume. Any failed tile or invalid
input prevents the final ZIP from being offered.

The sample-size action runs the same saved JPEG source/conversion as export,
then weights one encoded sample per zoom by that level's tile count. It measures
the stored JPEG, not an unrelated input format or assumed bytes-per-tile range. Scene
complexity still varies; this is a rough JPEG payload estimate, not an exact ZIP
size. The ZIP also includes small manifest, metadata and entry overheads.

Encoded tiles are capped at 256 KiB; accumulated archive-entry data is capped at
128 MiB independently of the 2,000-tile count. The ZIP uses stored entries because
JPEG tiles are already compressed. ZIP finalization allocates another
output buffer plus overhead: 128 MiB is **not** a total browser RAM guarantee.
Resource limits fail explicitly and never reduce the requested coverage.

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

## Updates now and later

For ZIP updates, reuse the area ID and explicitly confirm replacement of that
area's metadata when extracting. Matching shared tile paths are reused for
fixed imagery editions and for exports from the same saved Google library.
Extraction cannot inspect installed coverage, download only missing tiles,
roll back an interrupted installation or remove obsolete images. Back up
existing data before replacing it. Unused images can remain without changing
the declared coverage.

A later connected workflow can read area manifests, show coverage/installed
images and calculate missing or unreferenced tiles. It must verify new images
before committing a recoverable area-manifest replacement. It must derive
references from all area manifests before cleanup, refusing unsafe cleanup
when any area's references cannot be understood. SD-card writes are not one
atomic transaction. Widget installation/update must preserve the map library
and user data. Direct SD writing, area browsing/deletion and widget updates
are not implemented by this ZIP-only layer.
