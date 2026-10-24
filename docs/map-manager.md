# Map Manager

Manage AeroGrid map areas on your radio. Select an area to edit its coverage and map detail.

The connected manager writes [area format 2](developer-guide/map-packs.md):
one YAML file per area and shared JPEG tiles. The independent format 1 radio
reader does not accept these files.

<noscript>This tool requires JavaScript. Enable it to use the map manager.</noscript>

<div id="ag-map-planner">
  <section class="ag-map-manager" aria-labelledby="ag-map-manager-title">
    <h2 id="ag-map-manager-title" class="visually-hidden">Radio map library</h2>
    <div class="ag-map-connection-panel">
    <header class="ag-radio-header">
      <strong><svg class="ag-connection-icon" viewBox="0 0 24 24" aria-hidden="true"><g class="ag-connection-off"><path d="M9 17H7A5 5 0 0 1 7 7"/><path d="M15 7h2a5 5 0 0 1 4 8"/><line x1="8" x2="12" y1="12" y2="12"/><line x1="2" x2="22" y1="2" y2="22"/></g><g class="ag-connection-on"><path d="M9 17H7A5 5 0 0 1 7 7h2"/><path d="M15 7h2a5 5 0 1 1 0 10h-2"/><line x1="8" x2="16" y1="12" y2="12"/></g></svg><span id="ag-map-radio-state" role="status" aria-live="polite">Radio disconnected</span></strong>
      <button id="ag-map-connect" class="ag-radio-button ag-radio-primary" type="button"><svg class="ag-usb-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V3m-3 3 3-3 3 3M12 15l-5-5V7m5 10 5-5V9"/><circle cx="7" cy="5" r="2"/><circle cx="12" cy="21" r="2"/><rect x="15" y="5" width="4" height="4"/></svg><span id="ag-map-connect-label">Connect Radio</span></button>
    </header>
    <div class="ag-radio-cards ag-map-radio-details">
      <div class="ag-radio-card">
        <span>Radio</span>
        <dl class="ag-radio-specs">
          <div><dt>Type</dt><dd id="ag-map-radio-type">Unknown</dd></div>
          <div><dt>Screen</dt><dd id="ag-map-radio-screen">Unknown</dd></div>
          <div><dt>EdgeTX</dt><dd id="ag-map-edgetx">Unknown</dd></div>
        </dl>
      </div>
      <div class="ag-radio-card">
        <span>Map imagery on SD card</span>
        <strong id="ag-map-storage-used">Unknown</strong>
        <small>Map tiles on the radio.</small>
      </div>
      <div class="ag-radio-card" aria-live="polite" aria-atomic="true">
        <span>Selected map imagery</span>
        <strong id="ag-map-storage-selected">Unknown</strong>
        <small id="ag-map-storage-delta" title="Change compared with map imagery on the SD card.">Connect a radio to calculate changes.</small>
      </div>
    </div>
    <p id="ag-map-compatibility" class="ag-radio-muted" role="status" aria-live="polite" hidden></p>
    <p id="ag-map-connect-status" role="status" aria-live="polite"></p>
    </div>

    <div class="ag-map-manager-layout">
      <div class="ag-map-sidebar">
      <section class="ag-map-areas-panel" aria-labelledby="ag-map-areas-title">
        <div class="ag-map-section-heading">
          <h3 id="ag-map-areas-title">Map areas</h3>
        </div>
        <p id="ag-map-create-help" class="ag-map-note ag-map-create-help">Connect a radio to edit map areas.</p>
        <div id="ag-map-area-list" class="ag-map-area-list" role="group" aria-label="App-created map areas"></div>
        <dialog id="ag-map-overlap-dialog" class="ag-map-overlap-dialog" aria-labelledby="ag-map-overlap-title">
          <h3 id="ag-map-overlap-title">Choose an overlapping map area</h3>
          <p>Several saved areas cover this point. Choose which one to select.</p>
          <div id="ag-map-overlap-options" class="ag-map-actions"></div>
          <button id="ag-map-overlap-cancel" class="ag-radio-button" type="button">Cancel</button>
        </dialog>
        <div class="ag-map-area-actions" hidden>
          <button id="ag-map-delete" class="ag-radio-button ag-map-delete" type="button" disabled>Delete area</button>
        </div>
        <div class="ag-map-change-actions">
          <button id="ag-map-update" class="ag-radio-button ag-radio-primary" type="button" disabled>Sync Maps</button>
          <p id="ag-map-stage-status" role="status" aria-live="polite">Connect a radio to begin.</p>
        </div>
      </section>
      </div>
      <section id="ag-map-viewer" class="ag-map-viewer" aria-label="Map">
        <div class="ag-map-toolbar">
          <h3>Coverage Map</h3>
          <div class="ag-map-actions">
          <button class="ag-radio-help-button" type="button" popovertarget="ag-map-editing-help" aria-label="Editing and storage help" title="Editing and storage help"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3m.08 4h.01"/></svg></button>
          </div>
        </div>
        <p id="ag-map-location-status" role="status" aria-live="polite"></p>
        <div class="ag-map-frame">
          <div id="ag-map-canvas" aria-label="Map with saved map areas and planned download coverage" tabindex="0"></div>
          <button id="ag-map-expand" class="ag-radio-help-button ag-map-expand" type="button" aria-pressed="false" aria-controls="ag-map-viewer" aria-label="Expand map" title="Expand map"><svg viewBox="0 0 24 24" aria-hidden="true"><path class="ag-map-expand-icon" d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/><path class="ag-map-collapse-icon" d="M3 8h5V3m8 0v5h5M8 21v-5H3m18 0h-5v5"/></svg></button>
          <fieldset id="ag-map-options" class="ag-map-location-control" disabled>
            <legend class="visually-hidden">Map navigation</legend>
            <button id="ag-map-locate" type="button" aria-label="Use my location" title="Use my location"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 12h3m14 0h3M12 2v3m0 14v3"/><circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="3"/></svg></button>
          </fieldset>
          <output id="ag-map-zoom" aria-label="Current map zoom" hidden>Zoom --</output>
        </div>
        <section class="ag-map-detail" aria-labelledby="ag-map-zoom-title">
          <h3 id="ag-map-zoom-title">Maximum map detail</h3>
          <div id="ag-map-zoom-choices" class="ag-map-zoom-choices" role="group" aria-label="Maximum map detail"></div>
          <p id="ag-map-selected-summary" role="status" aria-live="polite" hidden></p>
        </section>
        <p id="ag-map-status" role="status" aria-live="polite">Loading map viewer...</p>
        <p id="ag-map-imagery-status" role="status" aria-live="polite"></p>
        <div class="ag-map-legend" aria-label="Map colors">
          <span><i class="ag-map-key-selected" aria-hidden="true"></i>Selected area</span>
          <span><i class="ag-map-key-other" aria-hidden="true"></i>Other map areas</span>
        </div>
        <div id="ag-map-editing-help" class="ag-radio-help-popover" popover="auto" role="region" aria-labelledby="ag-map-editing-help-title">
          <h3 id="ag-map-editing-help-title">Editing and storage help</h3>
          <p><strong>Get started.</strong> Connect your radio to load its saved areas and enable editing. You can browse the map without connecting.</p>
          <p><strong>Create or resize an area.</strong> Hold the Shift key, then click and drag on the map to draw a new area. Select an existing area in the list or on the map, then drag a blue corner to resize it.</p>
          <p><strong>Use a larger map.</strong> Click the expand icon in the map's top-right corner to fill the page with just the map. Your selection and changes stay intact. Click the icon again or press Escape to return to the area list and detail choices.</p>
          <p><strong>Rename or delete an area.</strong> Click an area's title on the map to rename it, including in expanded view. You can also select it in Map areas and use its pencil or trash icon. When renaming, Enter saves and Escape cancels. Deleting marks the area for removal; it does not immediately erase it from the radio.</p>
          <p><strong>Choose map detail.</strong> Compare Less storage, Balanced, and Most detail beneath the map. More detail uses more SD-card space. The previews show the same location so you can compare them directly.</p>
          <p><strong>Understand storage.</strong> Map imagery on SD card shows current usage. Selected map imagery shows the total for all areas after your pending changes, not just the selected area. The + or - value shows how much that total will change. Shared imagery counts only once. Sizes for new or edited areas, projected totals, and storage changes are approximations until the imagery is prepared; actual sizes may differ.</p>
          <p><strong>Save your changes.</strong> Click Sync Maps to review additions and removals, then confirm to write them to the radio. Nothing is written before confirmation. The dialog shows preparation and write progress and stays open during writes. Keep the radio connected until syncing finishes, then disconnect and safely eject it before unplugging.</p>
          <p><strong>Repair missing images.</strong> Keep an area's map record and choose Sync Maps if its JPEG tiles were deleted. Existing images are reused. If any are missing, reconnect using the browser and site storage where the area was created. Invalid or unreadable files must be resolved separately; they are not silently replaced.</p>
          <button class="ag-radio-button" type="button" popovertarget="ag-map-editing-help" popovertargetaction="hide">Close</button>
        </div>
      </section>
    </div>
    <dialog id="ag-map-review-panel" class="ag-release-dialog ag-map-review-dialog" aria-labelledby="ag-map-review-title">
      <h2 id="ag-map-review-title">Sync Maps</h2>
      <p>Nothing changes on the radio until you confirm.</p>
      <ul id="ag-map-review-list" class="ag-map-review-list" aria-label="Areas to sync"></ul>
      <dl class="ag-map-review-summary" aria-label="Storage summary">
        <div><dt>To add</dt><dd id="ag-map-review-add"></dd></div>
        <div><dt>To remove</dt><dd id="ag-map-review-remove"></dd></div>
        <div><dt>After sync</dt><dd id="ag-map-review-total"></dd></div>
      </dl>
      <progress id="ag-map-review-progress" max="1" value="0" aria-label="Map sync progress" hidden></progress>
      <p id="ag-map-review-status" role="status" aria-live="polite" aria-atomic="true"></p>
      <div class="ag-map-actions">
        <button id="ag-map-update-cancel" class="ag-radio-button" type="button">Cancel</button>
        <button id="ag-map-sync" class="ag-radio-button ag-radio-primary" type="button" disabled>Confirm sync</button>
      </div>
    </dialog>
  </section>

  <div class="ag-install-safety" role="note">
    <strong>Keep the radio connected until sync finishes.</strong>
    <span>Do not close this page or let another application write to the card. Afterwards, disconnect in the page, safely eject the drive through your operating system, then unplug the USB data cable.</span>
  </div>

  <div class="ag-map-legacy-controls" hidden>
    <p id="ag-map-summary"></p>
    <button id="ag-map-viewport" type="button" disabled>Use visible area</button>
    <input id="ag-map-area-name" type="text" maxlength="80" disabled>
    <input id="ag-map-compact" type="checkbox" checked>
    <fieldset id="ag-map-zoom-range" disabled>
      <legend>Planner inputs</legend>
      <div class="ag-map-controls">
        <label for="ag-map-radio">Radio screen</label>
        <select id="ag-map-radio"></select>
        <p id="ag-map-radio-summary"></p>
      </div>
      <output id="ag-map-min-zoom-value">Select an area</output>
      <output id="ag-map-max-zoom-value">18</output>
      <div id="ag-map-range-slider"><input id="ag-map-max-zoom" type="range" min="11" max="19" step="1" value="18"></div>
    </fieldset>
    <button id="ag-map-clear" type="button">Clear selection</button>
    <input id="ag-map-name" type="text" value="my-flying-field" maxlength="80">
  </div>
</div>
