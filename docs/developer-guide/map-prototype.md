# Radio map rendering prototype

This is an experimental **radio-side** panel, independent of the browser
planner. It consumes the [shared map-area contract](#shared-map-area); it is not
a satellite downloader.
The first performance target is a **RadioMaster TX16S MKII, 480 x 272**,
using the existing **EdgeTX 2.12 LVGL API** baseline. The repository does not
currently declare a precise minimum supported patch release; API inspection
for this prototype uses 2.12.0, not proof that every 2.12 build works on hardware.

## Run the experiment

```sh
make build
```

The normal build recreates the disposable simulator SD image, includes the `review-map` development layout,
and copies 20 stored USGS/USDA NAIP aerial-imagery JPEG tiles at zoom 16/17.
Their manifest is `/AEROGRID/maps/areas/companion-naip.yaml`; tiles are under
`/AEROGRID/maps/tiles/companion-naip-20261024/`. Builds require no network access.
The snapshot covers Companion's GPS at 25.9973, -97.1572. Source and exact export
parameters are recorded in `tests/fixtures/map-imagery/source.json`; refresh with
`build/venv/bin/python tools/fetch-map-imagery-fixture.py`.
Automated panel tests retain the separate procedural fixture generator.
All map fixtures remain excluded from release packages.

Use the generated SD path with the [TX16S simulator](simulators.md).
Open the second screen of **AG Navigation**, which already selects **review-map**.
For a physical radio,
back up your configuration, install the complete widget directory, copy the
generated `AEROGRID/maps/` library into `/AEROGRID/maps/`, and copy `review-map.yaml` to
`/WIDGETS/AeroGrid/layouts/`. Restart before selecting the layout.
Do not copy the fixture's `MODELS/` or `RADIO/` onto your radio.
On the radio, open the layout editor, tap **+**, and choose **Map** in
**Select panel**. Configure its GPS source and optional heading, home switch,
satellite, marker and path settings in the normal drawer, then save the layout.
No YAML editing is required. The panel still needs an installed v2 map area and
live GPS inside its coverage; adding the panel does not download or install maps.
Area selection remains automatic from GPS, with no area-picker setting.
macOS `._` metadata sidecars are ignored when scanning installed area manifests.
An invalid actual area filename is reported by name; area IDs must contain
1-32 lowercase letters, digits, hyphens or underscores.
Existing map panels can be resized to any in-bounds grid span. Tiles remain
native size and the viewport clips to the panel. Small panels hide zoom
controls and the fullscreen hint when space is insufficient; the
standard header handles title fitting and state badges. Drag
panning remains available in fullscreen.

**Long-press the map to enter widget fullscreen and reveal the controls.**
Normal App view shows a long-press hint instead. Exit fullscreen with a long
RTN press. The map controls are custom-drawn, touch-only controls, not native
buttons; they have no firmware border or encoder focus. A press activates on
release, and moving eight pixels or leaving its hit area cancels activation.
Fullscreen exit and resize cancel a pending press.
The full-grid panel provides a compact dark rounded zoom block with white `+`
and `-` symbols and a subtle divider in the lower-right corner. Above it,
the follow control reuses the aircraft silhouette in white, facing north,
inside the same rounded-square button; below it, a separate circled info control
opens the location QR overlay.
The fixture provides zoom levels 16 / 17; installed areas may provide 1-9
consecutive levels within 11-19. The target button resumes aircraft follow after
manual dragging, applying the same dead-zone policy and smooth transition.
Drag to pan; there are no arrow
buttons. Zoom preserves the geographic viewport centre unless
coverage clamping prevents it. Aircraft follow starts enabled: the map stays
stationary while valid, fresh GPS remains inside the central 60% of its viewport
(20% margins on each side). Crossing that boundary recenters both axes once,
clamped to the pack's coverage. The aircraft can therefore remain off-center
at coverage edges. Recenter uses a smoothstep transition (gentle acceleration
and deceleration) toward a fixed target. Recent map-pixel velocity is filtered
over roughly a second; a third of the estimated time to the viewport edge
sets duration, clamped to 0.5–3 seconds. Slow or stationary fixes get three
seconds. If estimated edge arrival drops below 0.75 seconds during a pan,
the remaining motion is rebased from its current position to finish within
0.5 seconds. This is a best-effort correction, not a visibility guarantee
after abrupt GPS jumps.

The panel requests refresh every two ticks (20 ms), subject to the widget host
and firmware scheduling. Tile source loads remain limited to one per 25 ticks
(250 ms); retained tiles and both markers move between those loads. Synchronous
firmware image decoding can still interrupt animation.

Moving a finger at least eight pixels during a map drag pauses following for
that panel instance, even if coverage clamping prevents panning. A tap does not
pause it. Follow stays paused across zoom changes, resizing and fullscreen exit;
the target button resumes it. Recreating the panel also starts follow again.

In fullscreen, a single-finger drag also pans the map. Loaded tiles follow the
finger immediately. Newly exposed tiles load during the gesture, at most one
source per panel callback; moving again replaces the pending queue with the
current viewport's needs. Overlapping tiles stay visible. Release only ends
the gesture, with no separate redraw phase. A drag within the same tile
coverage needs no tile loading or hide/reveal cycle. Unloaded edges may be blank
until loading catches up, and synchronous firmware decoding may interrupt
movement.
EdgeTX 2.12 supplies single-contact touch events, not a pinch gesture API.
Yellow lines mark each tile's top/left edges and all four outer coverage edges.

The synthetic pack covers Companion's default GPS position,
**25.9973, -97.1572**, so there is no need to change its coordinates.
Enable GPS telemetry with a live link. A cyan aircraft silhouette with a rounded
nose, tapered fuselage, straight wing leading edges, swept tail fins,
continuous fuselage boundary and subtle translucent black shadow replaces the
position circle/dot. It turns clockwise from true north on the north-up map,
around the exact GPS position. The north-facing silhouette is 38 pixels wide;
the shadow extends about one pixel beyond its thin dark outline.
The re-follow control uses the same shape at 22 pixels wide, in white,
with a fixed north-facing orientation.

Set `positionMarker: arrow` in the map's YAML `config` (or choose `arrow` in
Position marker) for a blue (#328BEE) navigation chevron inside a 44-pixel
white circle at 67% opacity. The arrow uses the same heading, GPS anchoring and
freshness behavior as the plane. `positionMarker: plane` is the default;
the re-follow button remains the fixed white aircraft.

Set `headingSource: Hdg` in the map's YAML `config` to use a numeric telemetry
source in **degrees clockwise from true north**. Zero is valid north; negative
and greater-than-360 values wrap. This is a panel option independent of the GPS
source and arm switch. With a configured source, unavailable, stale or
non-numeric heading does not silently switch to GPS course.

Omit `headingSource` or leave it blank to derive **course over ground** from
successive valid, fresh GPS positions, using the shared navigation bearing
helper. Course is not necessarily nose heading, especially in wind or sideslip.
Changes accumulate until at least one metre separates the positions, reducing
stationary GPS jitter. The last five accepted movement bearings are averaged
as unit direction vectors, so 359 and 1 degrees average near north, not south.
Nearly opposing samples with no stable mean retain the previous course.
This adds up to five movement samples of turn response; it smooths quantized
GPS fixes but cannot remove GPS drift. The selected heading telemetry source
is not filtered. Once established, the last course is held while
stationary. Before sufficient movement there is no known direction: the plane
remains cyan and is not presented as a valid north heading. The aircraft never
changes color when GPS motion first establishes a course. GPS loss, stale or
invalid coordinates reset the position baseline and course history;
recovery needs new movement.
Zoom, panning and resizing do not change heading.

Aircraft and button glyphs are transparent native-size PNGs, generated with
`python3 tools/generate-aircraft-icons.py --output src/WIDGETS/AeroGrid/assets`.
EdgeTX 2.12's Lua image API exposes no rotation, so 36 pre-rendered orientations
cover 0–350 degrees in 10-degree steps (at most 5 degrees of visual error).
Only crossing an orientation boundary changes the stable filename callback;
position updates move the same 52 x 52 image, anchored at its centre (26, 26).
The follow image is a fixed 24 x 24 PNG, with no added shadow.
Only one aircraft image object is present, not 36 simultaneously loaded sprites.
Heading changes can nevertheless decode a new image and consume native cache
entries, adding pressure to the tile cache. A 52 x 52 RGBA payload is about
10.6 KiB; actual decoded allocation and on-radio turning performance remain
unmeasured. There are no runtime pixel transforms or image scaling.

Home uses an upright red (#EC483E) house with a small rounded doorway inside
the same 44-pixel white circle at 67% opacity as the arrow marker.
Its native 52 x 52 PNG is anchored at its centre (26, 26), exactly at home.
A valid EdgeTX home appears as a standalone marker; no home is
invented when pilot coordinates are unavailable. No source, no fix, stale GPS, invalid
coordinates and off-view positions have distinct status text; an off-view
marker is hidden rather than pinned to a false position. The first viewport
is centred on coverage, not on an unverified GPS value.

To capture home from GPS on arming, set `armSwitch: SFv` (or another armed
switch position, including logical switches such as `L01`) in the map's YAML
`config`. Leave it blank or omit it to use EdgeTX home. This reuses the
navigation panel's service: it must observe disarmed before armed and have a
valid, fresh GPS reading at capture. The switch is configured independently
per panel. Within one widget instance, identical GPS source and arm-switch
settings share the same home state; different settings capture independently.
Separate widget instances do not share captured home.

Paths use a blue (#328BEE) 5-pixel stroke over an 8-pixel white outline at
67% opacity. Both layers fade together by age to zero opacity at 30 seconds.
Full-path mode retains uniform opacity (255 for blue, 170 for white).
With the arrow marker, segments are clipped outside its circle with clearance
for the outline, so the trail does not show through the translucent marker.
Each recorded segment has two reusable line pairs in arrow mode to preserve
both outside portions when a historical segment crosses the marker circle.
The bounded pool initializes eight line pairs per refresh to keep creation
within the Lua callback budget. Separate outline and stroke layers preserve
draw order, with both below the home and position markers.
The development map layout enables the arrow and trail for simulator evaluation.

Headers use the same shared status component as Navigation: title color,
standard state badge, panel styling, and satellite indicator layout. Map-specific
explanations such as `WAITING FOR GPS` appear in the map body, not the badge.
Body status messages stay centered unless they overlap EdgeTX's reserved menu
corner. In that case they move below it, or beside it in short wide panels.
If neither region fits the complete message, the body label is hidden while the
header status remains; resizing or entering fullscreen restores it when space permits.
Satellite icon creation and spacing against the heading and displayed badge
are also shared.

The map uses the standard panel builder for its full-size card, accent stripe,
MAP title and state badge (including NO FIX). The viewport fills the entire panel
apart from the accent sidebar, with the shared header overlaid on the map.
Area selection is automatic from live GPS; there is no per-panel area override.
Set `satelliteSource` to show the Navigation-style satellite count and alerts;
`showSatellites: false` hides only the count. `showCoordinates: true` adds
six-decimal latitude/longitude when GPS is valid. `flightPath` accepts `off`,
`trail` or `full`: samples require at least five metres of movement and one
second between accepted fixes. The trail retains the last 30 seconds, capped at
31 timestamped points; old points expire even while stationary or GPS is unavailable.
Full mode keeps up to 1,024 timestamped fixes independently of a 63-segment drawing
budget. At capacity, a bounded search compares 32 interior samples by their
distance from the line between their neighbours, removing the least significant
candidate instead of dropping every other fix. The flight start and latest fix
are retained. Gap boundaries are protected when choosing candidates; if no
eligible interior is found, detail is discarded with a new break, never a false
connection. This is bounded, approximate history compaction, not lossless logging.

Full-route rendering projects a snapshot and groups visible runs without
bridging GPS gaps or off-screen excursions. It then splits the run with the
largest screen-space deviation until the error is at most 1.5 pixels or the
63-segment budget is exhausted. Complex views may exceed that error tolerance;
the drawing budget takes precedence. If disjoint visible runs alone exceed the
budget, the newest 63 runs are prioritized. Segments crossing the viewport are
kept even when both endpoints are outside it.

Projection and simplification run incrementally, at most 16 point operations per
refresh. Full-mode line updates are also batched, at most eight line pairs per
refresh, including arrow-circle clipping. The last completed geometry is reused
while a new snapshot is prepared; initial routes and changes can appear
progressively. Pan, zoom, resize and new samples invalidate the cache; stationary
refreshes reuse it without reprojecting history. Native line allocation remains
bounded (63 pairs, or 126 in arrow mode); it does not grow with stored history.
These are Lua work bounds, not measured native-radio rendering or RAM guarantees.
Trail mode remains a separate, unsimplified 30-second timestamped window, so
full-history compaction cannot alter its age fade. The modes remain alternatives,
not a combined full-route-plus-fading-tail display.
GPS outages break the displayed path.
In fullscreen, the separate circled info control opens the same location QR overlay
as tapping a Navigation panel, leaving map taps available for panning.
Distance/scale overlays remain intentionally absent. The home PNG renders at native size without
rotation; regenerate it with
`python3 tools/generate-map-icons.py --output src/WIDGETS/AeroGrid/assets`.

## Rendering and memory boundaries

- The tile pool is sized to the viewport, including partially visible tiles:
  nine persistent 256 x 256 image objects at 480 x 272, up to fifteen at
  800 x 480. It grows only when a larger viewport requires it and reuses slots
  when shrinking; a separate tile layer keeps new slots below markers and paths.
  The TX16S remains the first performance target; larger-radio native costs are
  unmeasured. Tiles render at native size, without
  scaling, rotation or alpha. Parent clipping supplies the viewport.
- GPS-only updates change marker position only when its rounded pixel position
  changes, its image source only when the 10-degree heading bucket changes, and status text
  only when necessary. They perform no tile
  file reads, tile geometry/visibility writes or image-object creation.
  The projection transform is cached until the viewport changes.
- A viewport change reuses matching tile sources and existing objects.
  Overlapping tiles stay visible; only obsolete images are hidden. At most one new tile is preflighted and revealed
  per 250 ms, independently of the animation refresh cadence.
  Zoom controls are ignored during loading. This intentionally conservative
  loading cadence can take roughly two seconds to reveal a six-tile view;
  newly exposed edges can remain blank while animated panning continues.

Firmware facts below were checked against
[EdgeTX v2.12.0](https://github.com/EdgeTX/edgetx/tree/v2.12.0):

| Source | Consequence |
| --- | --- |
| `radio/src/lua/lua_lvgl_widget.cpp`, `LvglWidgetImage::callRefs` | A stable filename callback calls `StaticImage::setSource` only when the filename changes. Updating an image's `file` string with `set` is not equivalent; the image class has no source-replacing `refresh` override. |
| `radio/src/gui/colorlcd/libui/static.cpp`, `StaticImage::setZoom` | A 256 x 256 image in a 256 x 256 frame uses 1:1 scale. The firmware explicitly warns that LVGL scaling is slow. |
| `radio/src/gui/colorlcd/libui/bitmapbuffer_fileio.cpp`, `decoder_open` / `convert_bitmap` | Opaque RGB images decode through a temporary four-byte-per-pixel buffer into two-byte RGB565 pixels. A tile's decoded RGB565 payload is 128 KiB; its temporary RGBA payload is another 256 KiB during decoding, before decoder workspace. |
| `radio/src/gui/colorlcd/lv_conf.h`, `LV_IMG_CACHE_DEF_SIZE` | The default cache has eight entries. Six visible RGB tiles alone have 768 KiB of decoded payload; eight cached RGB tiles have 1 MiB. These are estimates from the source, **not measured free memory or total widget consumption**. |

Lua stages **source changes**, not a firmware decode job queue. The firmware
owns decoding, cache eviction and draw invalidation. Marker movement can
repaint background pixels, and cache pressure from other UI images can cause
redecoding. No Lua-level check proves that the SD card stays idle during native
redraws. Simulator firmware also has a different LVGL memory allocation from
the radio.

A full 272-pixel-high viewport can expose nine tiles at once when it crosses
three tile rows and columns. That exceeds the eight-entry native cache even
before marker images, so this worst case can cause additional decoding.

Missing files or invalid JPEG headers fail through AeroGrid's retained panel
error/logging path. The bounded preflight checks dimensions and opaque RGB
encoding, **not the full compressed image stream**. Native decode failures
can still leave blank tiles: the firmware does not return decode success to
Lua. Inspect the firmware debug log; a successful header check is not evidence
that an image decoded or that sufficient memory was available.

## Shared map area

The radio consumes this versioned contract, independently of how an area is
produced. The local fixture generator provides an original synthetic example.
A named area references shared canonical XYZ images:

```yaml
format: aerogrid-map-area
version: 2
id: synthetic
name: "Synthetic test area"
imagerySet: companion-v1-jpeg-v1
projection: EPSG:3857
tileScheme: XYZ
tileSize: 256
imageFormat: jpeg
selection:
  bounds:
    west: -97.163085937500
    south: 25.992612489709
    east: -97.152099609375
    north: 26.002487141946
  radio: tx16s
  coverageMode: full-area-clamped
levels:
  - zoom: 16
    xMin: 15080
    xMax: 15081
    yMin: 27863
    yMax: 27864
  - zoom: 17
    xMin: 30160
    xMax: 30163
    yMin: 55726
    yMax: 55729
```

The numeric bounds above illustrate structure; use the generated manifest for
the actual sample. The loader reads `areas/<id>.yaml`, then images at
`tiles/<imagerySet>/<zoom>/<x>/<y>.jpg` under `/AEROGRID/maps/`.
It consumes area metadata version 2, including the required display name and
selection metadata; version 1 manifests are not supported.
It accepts 1-9 consecutive integer zoom levels within 11-19, at most 2,000
tiles total, and a manifest no larger than 8 KiB. Date-line areas use continuous
unwrapped X bounds; filenames reduce X modulo `2^zoom`. Images remain
256 x 256 8-bit RGB JPEG. Coverage clamps independently at each level;
undersized coverage is centred, not enlarged.
With `config.pack` blank or omitted, live GPS automatically selects an installed
area. Highest detail wins overlaps, then smallest coverage, then lexical area
ID. The selected area stays in use until live GPS leaves its coverage; temporary
GPS loss does not switch it. An explicit `config.pack` remains a development
override (used by the fixed simulator fixture). The GPS source is `config.source`
(default `GPS`). Selection requires a valid, fresh fix within coverage at
every zoom level. Directory scanning examines one entry per
refresh, supports at most 64 areas and 256 directory entries, and retries
after ten seconds when no map is available. Missing or invalid manifests use
the retained panel error/logging path rather than being silently skipped.
Area and imagery-set IDs must be 1-32 lowercase letters, digits, underscores
or hyphens; the manifest ID must match its filename.
Matching imagery-set IDs and canonical XYZ paths identify shared tiles across
areas; different imagery sets must use different directories.

The old provisional `pack.yaml` layout is no longer supported. Regenerate
synthetic fixtures with `make build`. Selection JSON alone still contains
no images and is not installable. The planner and downloader are separate
workstreams; neither is required to build or validate this panel.

## Validation and hardware gate

Focused checks:

```sh
build/venv/bin/python -m unittest discover -s tools -p 'test_map_test_pack.py'
python3 -m unittest discover -s tools -p 'test_aircraft_icons.py'
python3 tests/run.py
```

Mock coverage checks projection, validation, clamping, button zoom/pan,
marker freshness, absence of file/tile writes during 1000 changing GPS samples,
bounded tile-source work, repeated zoom cycles and image-object reuse.
It does not decode images or execute the native LVGL cache.

Before choosing a final image format or considering follow production-ready, record
the exact radio and EdgeTX patch version, SD card, package, and observations:

| Experiment | Record |
| --- | --- |
| Cold view / repeated zoom | Time to first tile and completed view; visible artifacts; decode errors in logs. |
| Stationary map, moving GPS | Responsiveness of marker and normal radio controls; CPU/load observations where available. |
| Repeated pans and 100 zoom cycles | Whether latency grows, tiles disappear, allocation errors appear, or the radio becomes unstable. |
| Memory | Firmware/native memory observations separately from Lua GC and compressed JPEG file sizes. |
| GPS loss, recovery and coverage edges | Marker/status correctness and no unintended automatic map motion. |

Actual TX16S MKII performance, decoded memory headroom and image compatibility
remain unverified until this runs on native firmware and the physical radio.
Do not use synthetic terrain or this prototype for flight navigation.
