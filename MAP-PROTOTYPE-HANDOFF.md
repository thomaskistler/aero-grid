# Radio map prototype handoff (temporary)

Status: experimental, not flight-navigation software. This document captures the
2026-10-20 session and subsequent shared-area migration, and can be removed
after the outstanding work is tracked. The panel is independent of the planner
and downloader branches. Its consumer contract is documented in
`docs/developer-guide/map-prototype.md`; original local fixtures validate it
without browser code or network access.

## Implemented

- YAML-only `map-prototype` panel, resizable to all grid spans on the current
  TX16S 480x272 target. Standard panel shell, accent, title and state badge;
  native-size imagery fills the panel except for the accent sidebar.
- Normal `make build` copies a stored USGS/USDA NAIP 20-tile aerial snapshot at zoom
  16/17 covering Companion's default GPS: 25.9973, -97.1572.
  AG Navigation's second screen (`review-map`) selects it.
- Reusable tile objects, retained overlap during pans, per-level coverage
  clamping and incremental loading: at most one source every 250 ms.
- Fullscreen single-finger dragging, live loading while dragging and no
  separate release redraw. Moving eight pixels cancels the host's editor hold.
- Borderless custom touch controls: combined dark rounded +/- block and a
  separate rounded-square re-follow button using the position glyph in white.
  Controls are touch-only, not encoder-focusable. Native local press coordinates
  and screen-space TAP events are handled; duplicate taps are suppressed.
- Orange home pin/house PNG and approved cyan aircraft PNG: straight wing
  leading edges, tapering fuselage with a continuous dark boundary, swept tail
  fins, no aileron lines. Plane is 38px wide with a subtle one-pixel black shadow.
  Re-follow uses the same shape in white at 22px, fixed north-facing.
  Home artwork is 15% smaller than its original size, with its pin-tip GPS
  anchor unchanged; aircraft and re-follow sizes are unchanged.
  Heading uses 36 pre-rendered PNGs in 10-degree steps via a stable filename
  callback. At most 5 degrees visual error; one image object with a (26,26)
  anchor, no runtime scaling. New orientations can trigger native decoding and
  image-cache eviction; on-radio turning performance is unmeasured.
  No Flaticon asset is included.
- Optional map-local `headingSource` telemetry setting, in degrees clockwise
  from true north. Blank derives GPS course over ground after at least one
  metre of movement, averaging the last five movement bearings circularly;
  stationary fixes retain the last course. GPS gaps reset baseline and history.
  Opposing ambiguous samples retain the previous mean. Configured heading
  telemetry stays direct. Course is not necessarily aircraft nose heading. Missing/stale
  configured telemetry does not silently switch sources; the plane stays cyan
  before and after movement. Status badges omit heading availability and zoom level.
- Shared navigation service supplies GPS freshness/fix state and home capture.
  Map-local `armSwitch` matches navigation-panel semantics: blank reads EdgeTX
  home; configured switch captures on observed disarmed-to-armed with fresh GPS.
  Matching GPS/switch subscriptions share within one widget runtime; this is
  not persistent model-wide synchronization across widgets/screens.
- Map-area selection is always automatic and GPS-driven; the former per-panel
  area override has been removed. Optional settings show a satellite count,
  six-decimal coordinates, and a bounded `off`/`trail`/`full` flight path.
  Fullscreen includes a separate circled info control for the location QR overlay,
  keeping the map's pan interactions independent.
- Aircraft follow starts enabled. Central 60% dead zone; a breach starts a
  fixed-target, coverage-clamped smoothstep pan. Filtered map-pixel velocity
  selects 0.5-3 seconds from estimated edge-arrival time; a near-edge safety
  correction shortens remaining motion. Refresh requests are every 20 ms,
  subject to host/firmware scheduling. Tile loading has a separate 250 ms gate.
- Manual dragging cancels animation and pauses follow. Re-follow resumes the
  dead-zone policy; no forced recenter if the aircraft is already in that zone.
  GPS loss/stale/invalid data cancel the transition. Zoom/resize reset animation.
- Removed the home-to-aircraft dotted connector; optional flight paths are
  independent of the home marker.

## Known limitations and remaining work

- The build includes a stored NAIP aerial snapshot at Companion's GPS.
  Imagery for the user's own flying location is still needed for field testing.
- The radio consumes a shared tile library and named area manifests:
  1-9 consecutive zooms within 11-19, max
  2,000 tiles per area, <=8 KiB YAML, EPSG:3857 XYZ 256px RGB JPEG, including
  antimeridian wrapping. The former per-pack `pack.yaml` layout is replaced;
  regenerate fixtures with `make build`. Selection JSON alone is not loadable.
  GPS-driven installed-area selection is automatic:
  live navigation position, highest maximum zoom, then smallest coverage,
  lexical ID ties; keep the selected area until live GPS exits its coverage.
  Scans are incremental, bounded, and read manifests rather than tile folders.
  No manual installed-area picker, direct SD writer or widget installer/update flow is
  enabled. Browser export, imagery fetching and source provenance belong to
  the separate planner/downloader workstreams, not this panel branch.
- Only TX16S-size geometry is supported. Native image scaling/rotation is avoided;
  the aircraft selects pre-rendered PNG orientations instead.
  Tiny panels hide controls. Undersized coverage is centered rather than scaled.
- Nine visible tiles are possible, exceeding EdgeTX's eight-entry native cache
  even before marker assets. Re-decoding/cache churn and synchronous decoder
  pauses may still interrupt dragging or follow animation. No prefetch added.
- Lua mock budgets do not measure decoding/drawing/native RAM. Physical radio
  free/minimum/largest-block memory, SD latency and endurance remain unmeasured.
  JPEG header preflight does not prove the compressed stream can decode.
- Follow tuning is experimental: filtered speed, safety timing and fixed-target
  behavior need moving-GPS and abrupt-change testing on native firmware/radio.
  Outside coverage the marker can leave view; no dedicated off-coverage UX yet.
- Flight-path rendering is bounded and uses native line primitives rather than
  writable image buffers. Trail mode keeps up to 31 points over the last 30
  seconds, fading and expiring by age; full mode decimates into
  a maximum of 64 points. Sampling, line appearance and native-radio cost still
  need hardware validation.
- No pinch zoom, persistence of pan/follow/home across reboot, or new model-wide
  settings store. Marker colors are generated using modern-dark accents, not
  dynamically recolored by the theme.

## Validation and reproduction

`docs/developer-guide/map-prototype.md` is the maintained technical guide.
Key sources: `panels/map-prototype.lua`, `lib/navigation_service.lua`,
`tools/generate-map-test-pack.py`, `tools/generate-map-icons.py`.

Focused coverage includes projection, pack validation, all spans, home anchoring
during drag reversals, tile reuse/loading bounds, GPS-only no-tile-write behavior,
follow dead zone/easing/adaptive duration/clamping/pause/resume, custom touch
event sequences, fullscreen cleanup, deterministic artwork and packaging.
Heading coverage includes clockwise cardinal/diagonal rotation, telemetry
precedence and normalization, stale/invalid readings, GPS-derived course,
stationary holding, GPS recovery and the marker's rotated footprint.

```sh
build/venv/bin/python -m unittest discover -s tools -p 'test_map_test_pack.py'
python3 -m unittest discover -s tools -p 'test_aircraft_icons.py'
python3 -m unittest discover -s tools -p 'test_release_package.py'
make check
make lint
make docs
make build
```

Native EdgeTX Companion 2.12 TX16S captures exercised dragging, touch zoom,
fullscreen exit, marker rendering and control layout. Capture helpers/logs live
in this session's artifacts and ignored `build/` outputs, not release sources.
They are useful evidence, not a substitute for physical-radio measurements.
