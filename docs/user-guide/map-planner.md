# Map planner (prototype)

Select your flying area, choose your radio, and preview its map coverage.
**Prototype:** prepare an SD-ready ZIP using Google hybrid imagery, or export a
selection without images. Offline-use permission is not established by this
tool; review the source terms before downloading imagery.

<noscript>This tool requires JavaScript. Enable it to use the map planner.</noscript>

<div id="ag-map-planner">
  <p>Pan and zoom to your field. <strong>Hold Shift and drag to select an area</strong>
  or resize the blue rectangle. On touch screens, use <strong>Use visible area</strong>.</p>
  <p id="ag-map-status" role="status" aria-live="polite">Loading map viewer...</p>
  <p id="ag-map-imagery-status" role="status" aria-live="polite"></p>
  <fieldset id="ag-map-options" class="ag-map-actions" disabled>
    <legend class="visually-hidden">Map actions</legend>
    <button id="ag-map-locate" class="btn btn-outline-primary" type="button">Use my location</button>
    <button id="ag-map-viewport" class="btn btn-outline-primary" type="button">Use visible area</button>
    <button id="ag-map-clear" class="btn btn-outline-secondary" type="button">Clear selection</button>
  </fieldset>
  <p id="ag-map-location-status" role="status" aria-live="polite"></p>
  <div class="ag-map-frame">
    <div id="ag-map-canvas" aria-label="Satellite map powered by OpenLayers" tabindex="0"></div>
    <output id="ag-map-zoom" aria-label="Current map zoom">Zoom --</output>
  </div>
  <p id="ag-map-coverage-legend" role="status" aria-live="polite">Solid blue: your flying area. Dashed amber: planned download coverage.</p>
  <fieldset id="ag-map-zoom-range" disabled>
    <legend>Radio and planned zoom levels</legend>
    <div class="ag-map-controls">
      <label for="ag-map-radio">RadioMaster radio (color screen)</label>
      <select id="ag-map-radio" aria-describedby="ag-map-radio-summary"></select>
      <p id="ag-map-radio-summary" role="status" aria-live="polite"></p>
    </div>
    <div class="ag-map-range-labels">
      <span>Overview zoom (automatic): <output id="ag-map-min-zoom-value" aria-live="polite">Select an area</output></span>
      <label for="ag-map-max-zoom">Maximum zoom: <output id="ag-map-max-zoom-value" for="ag-map-max-zoom">18</output></label>
    </div>
    <div id="ag-map-range-slider" class="ag-map-range-slider">
      <input id="ag-map-max-zoom" type="range" min="11" max="19" step="1" value="18">
    </div>
    <p>The overview fits your selected area on the radio screen. Adjust maximum detail;
    all levels from the overview through the maximum are included.</p>
    <label><input id="ag-map-compact" type="checkbox"> Space-saving coverage: separate tile coverage at each zoom</label>
    <p>Download less surrounding imagery at higher zooms. Assumes the plane stays inside the blue area.</p>
  </fieldset>
  <p id="ag-map-summary" role="status" aria-live="polite">No area selected.</p>
  <button id="ag-map-measure" class="btn btn-outline-primary" type="button" disabled>Measure sample tiles</button>
  <p id="ag-map-measurement" role="status" aria-live="polite">Select an area to measure one sample tile per zoom level.</p>
  <section class="ag-radio-preview" aria-labelledby="ag-map-radio-preview-title">
    <h3 id="ag-map-radio-preview-title">Radio-screen preview</h3>
    <p id="ag-map-radio-preview-status" role="status" aria-live="polite">Select a flying area to see how it fits on your radio.</p>
    <div class="ag-map-actions">
      <button id="ag-map-preview-out" class="btn btn-outline-primary" type="button" disabled>Zoom out</button>
      <output id="ag-map-preview-zoom" aria-live="polite">No area selected</output>
      <button id="ag-map-preview-in" class="btn btn-outline-primary" type="button" disabled>Zoom in</button>
    </div>
    <div id="ag-map-radio-preview-frame" hidden>
      <div id="ag-map-radio-preview" aria-label="Draggable radio-screen map preview"></div>
    </div>
    <p>Zoom one level at a time and drag to explore available tiles. Panning stops
    at each level's planned download boundaries. Full-screen simulation, not the
    final AeroGrid panel layout; imagery is loaded online for this preview.</p>
  </section>
    <div class="ag-map-controls">
      <label for="ag-map-name">Selection name</label>
      <input id="ag-map-name" type="text" value="my-flying-field" maxlength="80" required>
    </div>
  <div class="ag-map-controls">
    <label for="ag-map-area-id">Area ID</label>
    <input id="ag-map-area-id" type="text" value="my-flying-field" maxlength="32"
      pattern="[a-z0-9_-]{1,32}" aria-describedby="ag-map-install-help">
  </div>
  <div class="ag-map-actions">
    <button id="ag-map-export" class="btn btn-primary" type="button" disabled>Download selection JSON</button>
    <button id="ag-map-satellite-export" class="btn btn-primary" type="button" disabled aria-describedby="ag-map-source-notice">Download Google hybrid ZIP</button>
    <button id="ag-map-pack-cancel" class="btn btn-outline-secondary" type="button" disabled>Cancel export</button>
  </div>
  <p id="ag-map-source-notice">Source: Google hybrid. Google's published
  <a href="https://developers.google.com/maps/documentation/tile/policies" target="_blank" rel="noopener">tile policies</a>
  exclude offline use under standard terms. This experimental adapter does not
  grant export rights or establish permission; resolve applicable terms before use.
  Browser CORS or provider restrictions may prevent downloads; no proxy bypass is used.</p>
  <p id="ag-map-pack-status" role="status" aria-live="polite">Select an area to export a map ZIP.</p>
  <p id="ag-map-install-help">Extract the ZIP at the SD-card root. The map panel
  automatically selects a matching installed area when GPS is live; leave its
  area override blank. Overlaps prefer highest detail, then smallest coverage,
  and the selected area is kept while the position remains covered.
  To update an area, export the same ID and confirm replacement of its metadata
  when extracting. This browser saves downloaded Google tiles and reuses them
  for overlapping areas; every ZIP still contains all images its area needs.
  Saved images are not automatically refreshed. Clearing this site's browser
  data, using another browser, or browser storage eviction starts a new library
  and can duplicate images already on the radio. Storage errors stop the export;
  the saved library is limited to 128 MiB. Old radio images are not automatically
  removed. ZIP extraction is not transactional. No widget, model
  or radio configuration files are included. Direct-to-radio saving and AeroGrid
  installation/update come later. Runtime rendering currently targets TX16S
  480 x 272 only.</p>
  <p>Map tiles are JPEG files: compatible source JPEGs are preserved; other images
  are converted at quality 90. Old PNG prototype packs must be exported again.
  Existing PNG browser caches and SD files are not automatically removed.</p>
  <details>
    <summary>Developer test: synthetic map ZIP</summary>
    <p>Creates artificial georeferenced test images for the selected coverage.
    These are not satellite images and must not be used for flight navigation.
    The radio renderer currently targets TX16S 480 x 272 only; the other radio
    presets plan coverage but do not establish runtime compatibility.</p>
    <div class="ag-map-actions">
      <button id="ag-map-pack-export" class="btn btn-outline-primary" type="button" disabled>Download synthetic test ZIP</button>
    </div>
    <p>Synthetic imagery has a fixed edition, so matching shared tile paths are
    reused across areas. No network imagery is downloaded by this test export.</p>
  </details>
</div>
