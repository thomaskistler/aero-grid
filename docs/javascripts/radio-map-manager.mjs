// SPDX-License-Identifier: GPL-2.0-only
import { radioStorage, radioHardware, radioCompatibility } from "./radio-storage.mjs";
import {
  inspectMapLibrary, mapLibrarySignatureFromAreas, pruneUnreferencedMapTiles, readMapTile,
  removeMapArea, writeMapFiles, plannedMapStorage, mapSelectionTiles,
  RADIO_MAP_PRESETS,
} from "./radio-map-library.mjs";

const panel = document.querySelector("#ag-map-planner");
if (panel) {
  const planner = globalThis.AeroGridMapPlanner;
  const plannerView = globalThis.AeroGridMapPlannerView;
  const sources = globalThis.AeroGridMapSources;
  const packs = globalThis.AeroGridMapPack;
  const byId = (id) => document.getElementById(`ag-map-${id}`);
  const connectButton = byId("connect");
  const records = new Map();
  let selectedId = null;
  let radio = null;
  let supported = false;
  let phase = "idle";
  let expectedSignature = "";
  let storedMissingTiles = new Set();
  let totalStorageBytes = 0;
  let storedTileSizes = new Map();
  let addRequested = false;
  let stageController = null;
  let renamingId = null;
  let updateReady = false;
  let syncController = null;
  let reviewSignature = "";
  let expanded = false;
  const setExpanded = (enabled) => {
    if (enabled === expanded) return;
    expanded = enabled;
    panel.classList.toggle("ag-map-expanded", enabled);
    document.body.classList.toggle("ag-map-expanded-page", enabled);
    const button = byId("expand");
    button.setAttribute("aria-pressed", String(enabled));
    button.setAttribute("aria-label", enabled ? "Collapse map" : "Expand map");
    button.title = enabled ? "Collapse map" : "Expand map";
    plannerView?.resize();
    button.focus({ preventScroll: true });
  };
  byId("expand").addEventListener("click", () => setExpanded(!expanded));
  globalThis.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !event.defaultPrevented && expanded) setExpanded(false);
  });

  const formatBytes = (bytes) => {
    if (!Number.isFinite(bytes)) return "Unknown";
    if (bytes < 1024) return `${bytes} B`;
    const unit = bytes < 1024 ** 2 ? 1024 : 1024 ** 2;
    return `${(bytes / unit).toFixed(1)} ${unit === 1024 ? "KiB" : "MiB"}`;
  };
  const sameCoverage = (left, right) => !!left && !!right
    && left.levels.length === right.levels.length
    && left.levels.every((level, index) => {
      const other = right.levels[index];
      return level.zoom === other.zoom && level.yMin === other.yMin && level.yMax === other.yMax
        && JSON.stringify(level.xRanges) === JSON.stringify(other.xRanges);
    });
  const formatEstimate = (bytes) => {
    const unit = bytes < 1024 ? 1 : bytes < 1024 ** 2 ? 1024 : 1024 ** 2;
    return `${Math.round(bytes / unit)} ${unit === 1 ? "B" : unit === 1024 ? "KiB" : "MiB"}`;
  };
  const setStatus = (text, error = false, success = false) => {
    const target = byId("connect-status");
    target.textContent = text;
    target.classList.toggle("ag-map-error", error);
    target.classList.toggle("ag-map-success", success);
  };
  const currentRecord = () => selectedId ? records.get(selectedId) : null;
  const pendingCount = () => [...records.values()].filter((record) => record.staged).length;
  const busy = () => ["preparing", "writing", "committing"].includes(phase);
  const hasDraft = () => pendingCount() > 0
    || [...records.values()].some((record) => record.dirty) || addRequested;
  const draftSignature = () => JSON.stringify([...records.values()].map((record) => [
    record.id, record.imagerySet, record.selection, record.deleted, record.dirty,
    record.staged ? [...record.staged.files.keys()].sort() : null,
  ]));
  const invalidateReview = () => {
    updateReady = false;
    reviewSignature = "";
    if (phase === "reviewing" && byId("review-panel").open) {
      byId("review-status").textContent = "Map changes changed after review. Prepare them again before syncing.";
    }
  };
  function cancelDeletion(record) {
    record.deleted = false;
    record.staged = record.stagedBeforeDelete ?? null;
    record.dirty = record.dirtyBeforeDelete ?? false;
    delete record.stagedBeforeDelete;
    delete record.dirtyBeforeDelete;
    invalidateReview();
    setStatus("");
  }
  const actionIcon = (pathData) => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", pathData);
    svg.append(path);
    return svg;
  };
  const renderNames = () => {
    const list = byId("area-list");
    if (renamingId && records.has(renamingId) && supported && !busy()) {
      if (list.querySelector(".ag-map-area-rename")) return;
    } else renamingId = null;
    list.replaceChildren();
    for (const record of records.values()) {
      const row = document.createElement("div");
      row.className = "ag-map-area-row";
      row.setAttribute("data-selected", String(record.id === selectedId));
      if (record.id === renamingId) {
        const input = document.createElement("input");
        input.className = "ag-map-area-rename";
        input.value = record.selection.name;
        input.maxLength = 80;
        input.setAttribute("aria-label", "Area name");
        let finished = false;
        const finish = (save) => {
          if (finished) return;
          const value = input.value.trim();
          if (save && (!value || value.length > 80)) {
            input.setCustomValidity("Enter an area name between 1 and 80 characters.");
            input.reportValidity();
            return;
          }
          finished = true;
          renamingId = null;
          if (save && value !== record.selection.name) {
            byId("area-name").value = value;
            byId("area-name").dispatchEvent(new Event("input"));
          } else renderNames();
          byId("area-list").querySelector('[aria-pressed="true"]')?.focus();
        };
        input.addEventListener("input", () => input.setCustomValidity(""));
        input.addEventListener("keydown", (event) => {
          if (event.key === "Enter" || event.key === "Escape") {
            event.preventDefault();
            finish(event.key === "Enter");
          }
        });
        input.addEventListener("blur", () => finish(true));
        row.append(input);
        list.append(row);
        queueMicrotask(() => { input.focus(); input.select(); });
        continue;
      }
      const button = document.createElement("button");
      button.type = "button";
      button.className = "ag-map-area-option";
      button.setAttribute("aria-pressed", String(record.id === selectedId));
      button.disabled = !supported || busy();
      const name = document.createElement("strong");
      name.textContent = record.selection.name;
      const details = document.createElement("small");
      const tileCount = record.selection.tileCount;
      const savedCoverageMatches = record.onRadio && record.savedSelection
        && JSON.stringify(record.selection.levels) === JSON.stringify(record.savedSelection.levels);
      const storage = record.staged && !record.staged.deleted
        ? formatBytes(record.staged.areaBytes)
        : savedCoverageMatches
          ? formatBytes(record.storageBytes)
          : formatEstimate(tileCount * 20 * 1024);
      details.textContent = `${tileCount.toLocaleString()} ${tileCount === 1 ? "tile" : "tiles"} · ${storage}`;
      if (!savedCoverageMatches && !record.staged) {
        details.title = "Estimated at an average of 20 KiB per map tile. Preparing the area provides its actual map tile size.";
      }
      button.append(name, details);
      const marker = document.createElement("span");
      marker.className = record.staged || record.dirty ? "ag-map-pending" : "ag-map-area-state";
      marker.textContent = record.deleted || record.staged || record.dirty || record.missingTileCount
        ? "Pending changes" : "";
      button.append(marker);
      const rename = () => {
        if (busy() || !supported || record.deleted) return;
        selectRecord(record.id);
        renamingId = record.id;
        renderNames();
      };
      button.addEventListener("keydown", (event) => {
        if (event.key === "F2") {
          event.preventDefault();
          rename();
        }
      });
      button.addEventListener("click", () => {
        if (record.deleted) cancelDeletion(record);
        selectRecord(record.id);
      });
      row.append(button);
      if (record.id === selectedId && !record.deleted) {
        const edit = document.createElement("button");
        edit.type = "button";
        edit.className = "ag-map-area-edit";
        edit.disabled = !supported || busy();
        edit.setAttribute("aria-label", `Rename ${record.selection.name}`);
        edit.title = `Rename ${record.selection.name}`;
        edit.append(actionIcon("M21.174 6.812a1 1 0 0 0-3.986-3.986L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497zM15 5l4 4"));
        edit.addEventListener("click", rename);
        row.append(edit);
        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "ag-map-area-remove";
        remove.disabled = !supported || busy();
        remove.setAttribute("aria-label", `Delete ${record.selection.name}`);
        remove.title = `Delete ${record.selection.name}`;
        remove.append(actionIcon("M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M10 11v6M14 11v6"));
        remove.addEventListener("click", () => byId("delete").click());
        row.append(remove);
      }
      list.append(row);
    }
  };
  const renderReview = () => {
    const canEdit = !!radioStorage.root && supported && !!radio?.preset && !busy();
    plannerView?.setAreaEditMode(canEdit);
    byId("create-help").textContent = radioStorage.root
      ? "Hold Shift and drag on the map to create a new area."
      : "Connect a radio to edit map areas.";
    panel.classList.toggle("ag-radio-connected", !!radioStorage.root);
    connectButton.classList.toggle("ag-radio-primary", !radioStorage.root);
    connectButton.classList.toggle("ag-radio-danger", !!radioStorage.root);
    byId("compatibility").hidden = !radioStorage.root;
    connectButton.disabled = busy() || !globalThis.isSecureContext
      || typeof globalThis.showDirectoryPicker !== "function";
    if (!busy()) byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
    const count = pendingCount();
    byId("update").disabled = !radioStorage.root || busy()
      || ![...records.values()].some((record) => record.dirty || record.staged);
    byId("delete").disabled = !supported || !currentRecord() || busy();
    byId("area-name").disabled = !supported || !currentRecord() || busy();
    byId("sync").disabled = !updateReady || !count || busy();
    const dirtyCount = [...records.values()].filter((record) => record.dirty && !record.staged).length;
    const changes = count + dirtyCount;
    const summary = changes ? `${changes} ${changes === 1 ? "area has" : "areas have"} pending changes.` : "";
    byId("stage-status").textContent = busy() ? "Map operation in progress..." : summary;
    renderNames();
    renderMapAreas();
    refreshStorageSummary();
    updateZoomChoices();
  };
  function renderMapAreas() {
    const areas = [...records.values()].filter((record) => record.onRadio || record.dirty || record.staged);
    plannerView?.renderAreas(areas, addRequested ? null : selectedId);
  }
  function refreshStorageSummary() {
    byId("storage-used").textContent = radio ? formatBytes(totalStorageBytes) : "Unknown";
    if (!radio) {
      byId("storage-selected").textContent = "Unknown";
      byId("storage-delta").textContent = "Connect a radio to calculate changes.";
      return;
    }
    const { minimumBytes, maximumBytes, estimated } = plannedMapStorage(records.values(), storedTileSizes);
    const signedBytes = (bytes) => `${bytes < 0 ? "-" : "+"}${formatBytes(Math.abs(bytes))}`;
    const averageBytes = (minimumBytes + maximumBytes) / 2;
    byId("storage-selected").textContent = estimated
      ? formatEstimate(averageBytes)
      : formatBytes(minimumBytes);
    const minimumChange = minimumBytes - totalStorageBytes;
    const averageChange = averageBytes - totalStorageBytes;
    byId("storage-delta").textContent = estimated
      ? `${averageChange < 0 ? "-" : "+"}${formatEstimate(Math.abs(averageChange))} vs SD card`
      : minimumChange === 0
        ? "No storage change"
        : `${signedBytes(minimumChange)} vs SD card`;
  }
  function updateZoomChoices() {
    const container = byId("zoom-choices");
    container.replaceChildren();
    const record = currentRecord();
    if (!supported || !record || record.deleted) {
      for (const zoom of [17, 18, 19]) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "ag-map-zoom-choice";
        button.disabled = true;
        button.setAttribute("aria-pressed", "false");
        const label = document.createElement("strong");
        label.textContent = zoom === 17 ? "Less storage" : zoom === 18 ? "Balanced" : "Most detail";
        const help = document.createElement("small");
        help.textContent = "Select a map area";
        button.append(label, help);
        container.append(button);
      }
      byId("selected-summary").textContent = supported
        ? "Select or add a map area to choose its maximum detail."
        : "Connect a radio to manage map areas.";
      return;
    }
    const selected = record.selection.selectedBounds;
    const centerLng = selected.west > selected.east
      ? (selected.west + selected.east + 360) / 2 : (selected.west + selected.east) / 2;
    const centerLat = (selected.south + selected.north) / 2;
    for (const zoom of [17, 18, 19]) {
      const count = 2 ** zoom;
      const centerX = ((centerLng + 180) / 360 * count % count + count) % count;
      const radians = centerLat * Math.PI / 180;
      const centerY = (1 - Math.asinh(Math.tan(radians)) / Math.PI) / 2 * count;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "ag-map-zoom-choice";
      button.setAttribute("aria-pressed", String(record.selection.levels.at(-1).zoom === zoom));
      button.disabled = busy() || zoom < record.selection.levels[0].zoom;
      const preview = document.createElement("div");
      preview.className = "ag-map-zoom-preview";
      const tiles = document.createElement("div");
      tiles.className = "ag-map-zoom-tiles";
      const unavailable = document.createElement("span");
      unavailable.textContent = "Preview unavailable";
      unavailable.hidden = true;
      // A 256 x 144 native-pixel viewport, centered identically at every zoom.
      for (let x = Math.floor(centerX - 0.5); x < Math.ceil(centerX + 0.5); x++) {
        for (let y = Math.max(0, Math.floor(centerY - 144 / 512));
          y < Math.min(count, Math.ceil(centerY + 144 / 512)); y++) {
          const image = document.createElement("img");
          image.alt = "";
          image.loading = "lazy";
          image.style.left = `${(x - centerX) * 100}%`;
          image.style.top = `${(y - centerY) * 100}%`;
          image.addEventListener("error", () => {
            tiles.hidden = true;
            unavailable.hidden = false;
          });
          image.src = planner.tileUrl(zoom, (x % count + count) % count, y);
          tiles.append(image);
        }
      }
      preview.append(tiles, unavailable);
      const label = document.createElement("strong");
      label.textContent = zoom === 17 ? "Less storage" : zoom === 18 ? "Balanced" : "Most detail";
      const levels = document.createElement("small");
      const overview = record.selection.levels[0].zoom;
      levels.textContent = "";
      if (zoom < overview) levels.textContent = "Below overview";
      button.append(preview, label, levels);
      button.addEventListener("click", () => {
        if (record.selection.levels.at(-1).zoom === zoom) return;
        try {
          plannerView.setMaximumZoom(zoom);
        } catch (error) {
          setStatus(error.message, true);
        }
      });
      container.append(button);
    }
    const actualMaximum = record.selection.levels.at(-1).zoom;
    const areaSize = record.staged && !record.staged.deleted
      ? record.staged.areaBytes
      : record.storageBytes;
    byId("selected-summary").textContent =
      `${record.selection.name} · Zoom ${record.selection.levels[0].zoom}–${actualMaximum} · ${formatBytes(areaSize)}`;
  }
  function syncPlannerInputs(record) {
    byId("name").value = record.selection.name;
    byId("area-name").value = record.selection.name;
    byId("radio").value = radio.preset;
    byId("max-zoom").value = String(record.selection.levels.at(-1).zoom);
    byId("compact").checked = true;
  }
  function selectRecord(id) {
    const record = records.get(id);
    if (!record || record.deleted || !supported) return;
    if (addRequested) {
      addRequested = false;
      plannerView.cancelAddingArea();
    }
    selectedId = id;
    syncPlannerInputs(record);
    if (radio.preset) {
      plannerView.selectBounds(record.selection.selectedBounds, radio.preset,
        record.selection.levels.at(-1).zoom);
    } else {
      plannerView.clearBounds();
      setStatus("The radio screen dimensions are unknown. Coverage cannot be calculated without its actual screen size.", true);
    }
    updateZoomChoices();
    renderReview();
    refreshStorageSummary();
  }
  function selectMapAreas(ids) {
    const available = [...new Set(ids)].filter((id) => {
      const record = records.get(id);
      return record && !record.deleted && supported && !busy();
    });
    if (available.length === 1) {
      selectRecord(available[0]);
      return;
    }
    if (available.length < 2) return;
    const dialog = byId("overlap-dialog");
    if (dialog.open) return;
    const options = byId("overlap-options");
    options.replaceChildren();
    for (const id of available) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "ag-radio-button";
      button.textContent = records.get(id).selection.name;
      button.addEventListener("click", () => {
        dialog.close();
        selectRecord(id);
      });
      options.append(button);
    }
    dialog.showModal();
  }
  function selectionChanged(event) {
    if (!radioStorage.root || !supported || !radio?.preset || busy()) return;
    if (event.origin === "drawing-start" || event.origin === "drawing-cancel") {
      addRequested = event.origin === "drawing-start";
      invalidateReview();
      renderReview();
      return;
    }
    if (event.error) {
      setStatus(event.error.message, true);
      return;
    }
    const record = currentRecord();
    if (!event.selection || event.origin === "load" || event.origin === "clear") return;
    if (event.origin === "new-area" || addRequested) {
      const uuid = globalThis.crypto?.randomUUID?.();
      if (!uuid) {
        setStatus("Secure random IDs are unavailable. Open this page over HTTPS or localhost.", true);
        return;
      }
      const id = `area-${uuid.replace(/-/g, "").slice(0, 20)}`;
      const selection = { ...event.selection, name: "New map area" };
      const added = {
        id, imagerySet: null, selection, storageBytes: 0, staged: null,
        deleted: false, dirty: true, onRadio: false,
      };
      records.set(id, added);
      selectedId = id;
      byId("name").value = selection.name;
      byId("area-name").value = selection.name;
      addRequested = false;
      invalidateReview();
      byId("canvas").style.cursor = "";
      setStatus("");
    } else {
      if (!record) return;
      record.selection = { ...event.selection, name: byId("area-name").value.trim() || record.selection.name };
      record.staged = null;
      record.dirty = true;
      invalidateReview();
      byId("name").value = record.selection.name;
      setStatus("");
    }
    updateZoomChoices();
    renderReview();
  }
  function updateRadioDetails(details) {
    const hardware = radioHardware(details.radio.board);
    byId("radio-type").textContent = hardware.type;
    byId("radio-screen").textContent = hardware.screen;
    byId("edgetx").textContent = details.radio.version || "Unknown";
    const detectedPreset = RADIO_MAP_PRESETS[hardware.screen];
    const preset = detectedPreset || "";
    radio = { ...details.radio, preset };
    supported = true;
    byId("radio-state").textContent = "Radio connected";
    byId("radio").value = preset;
    const compatibility = radioCompatibility(details.radio);
    byId("compatibility").textContent = (compatibility.supported
      ? compatibility.message
      : `${compatibility.message.replace("Install at your own risk.", "Continue at your own risk.")}`)
      + (!detectedPreset
        ? " Screen dimensions are unknown. Map coverage cannot be calculated until the radio screen can be identified; no substitute screen size is used."
        : "");
    byId("compatibility").classList.toggle("ag-map-warning", !compatibility.supported);
  }
  async function loadRadio(knownLibrary) {
    if (!await plannerView.ready) throw new Error("The map viewer did not load. Reload the page and try again.");
    invalidateReview();
    const details = await radioStorage.inspect();
    updateRadioDetails(details);
    const library = knownLibrary ?? await inspectMapLibrary(radioStorage.root);
    totalStorageBytes = library.tileBytes;
    storedTileSizes = library.tileSizes;
    records.clear();
    for (const area of library.areas) records.set(area.id, {
      ...area, savedSelection: area.selection, staged: null,
      deleted: false, dirty: area.missingTileCount > 0, onRadio: true,
    });
    expectedSignature = mapLibrarySignatureFromAreas(library.areas);
    storedMissingTiles = new Set(library.missingTiles ?? []);
    selectedId = records.keys().next().value ?? null;
    refreshStorageSummary();
    renderReview();
    if (selectedId && radio.preset) selectRecord(selectedId);
    else {
      plannerView.clearBounds();
      updateZoomChoices();
    }
    setStatus(library.missingTileCount
      ? `${library.missingTileCount} map tiles are missing. Choose Sync Maps to repair them.`
      : "");
  }
  function refreshLibraryState(library, acceptTileChanges = false) {
    if (mapLibrarySignatureFromAreas(library.areas) !== expectedSignature
        || [...library.tileSizes].some(([path, size]) =>
          (storedTileSizes.has(path) && storedTileSizes.get(path) !== size)
          || (!acceptTileChanges && storedMissingTiles.has(path)))) {
      throw new Error("Map areas or images changed while preparing. Review the current card before syncing.");
    }
    totalStorageBytes = library.tileBytes;
    storedTileSizes = library.tileSizes;
    storedMissingTiles = new Set(library.missingTiles ?? []);
    for (const area of library.areas) {
      const record = records.get(area.id);
      record.storageBytes = area.storageBytes;
      record.missingTiles = area.missingTiles;
      record.missingTileCount = area.missingTileCount;
      if (area.missingTileCount && !record.deleted) {
        const stagedTiles = new Set([...(record.staged?.files?.keys() ?? [])]
          .filter((path) => path.startsWith("AEROGRID/maps/tiles/"))
          .map((path) => path.slice("AEROGRID/maps/tiles/".length)));
        if (![...area.missingTiles].every((path) => stagedTiles.has(path))) {
          record.staged = null;
          record.dirty = true;
          invalidateReview();
        }
      }
    }
  }
  connectButton.addEventListener("click", async () => {
    if (busy()) return;
    if (radioStorage.root) {
      const dirtyCount = [...records.values()].filter((record) => record.dirty).length;
      if ((pendingCount() || dirtyCount || addRequested) && !globalThis.confirm(
        "Disconnect and discard pending map changes from this page? The radio will not be changed."
      )) return;
      try {
        radioStorage.disconnect();
        supported = false;
        radio = null;
        records.clear();
        totalStorageBytes = 0;
        selectedId = null;
        addRequested = false;
        plannerView.cancelAddingArea();
        byId("radio-state").textContent = "Radio disconnected";
        byId("radio-type").textContent = "Unknown";
        byId("radio-screen").textContent = "Unknown";
        byId("edgetx").textContent = "Unknown";
        plannerView.clearBounds();
        updateZoomChoices();
        setStatus("Disconnected from this page. Safely eject the drive through your operating system before unplugging.");
      } catch (error) {
        setStatus(error.message, true);
      }
      renderReview();
      refreshStorageSummary();
      renderNames();
      return;
    }
    if (!globalThis.isSecureContext || typeof globalThis.showDirectoryPicker !== "function") {
      setStatus("Radio access requires desktop Chrome or Edge over HTTPS (or localhost).", true);
      return;
    }
    phase = "preparing";
    const pendingBeforeConnect = hasDraft();
    byId("connect-label").textContent = "Connecting...";
    setStatus("Select the mounted radio SD-card root. Connecting does not change files.");
    renderReview();
    try {
      await radioStorage.connect();
      const library = await inspectMapLibrary(radioStorage.root);
      if (pendingBeforeConnect) {
        const sameAreas = mapLibrarySignatureFromAreas(library.areas) === expectedSignature;
        if (sameAreas) {
          const keepDraft = globalThis.confirm(
            "The connected card has the same saved map areas as before. Keep this page's pending edits for this card? Choose Cancel to discard them and reload the card."
          );
          if (keepDraft) {
            invalidateReview();
            updateRadioDetails(await radioStorage.inspect());
            refreshLibraryState(library, true);
            for (const area of library.areas) {
              const record = records.get(area.id);
              if (area.missingTileCount) {
                record.staged = null;
                record.dirty = true;
              }
            }
            renderReview();
          } else {
            await loadRadio(library);
          }
        } else if (globalThis.confirm(
          "The connected card has different saved map areas. Discard this page's pending edits and reload from the connected card?"
        )) {
          await loadRadio(library);
        } else {
          radioStorage.disconnect();
          supported = false;
          radio = null;
          byId("radio-state").textContent = "Radio disconnected";
          setStatus("Pending edits were kept. Reconnect the card they were made for, or choose to discard and reload.");
        }
      } else {
        await loadRadio(library);
      }
    } catch (error) {
      try {
        radioStorage.disconnect();
      } catch (disconnectError) {
      console.error("[AeroGrid maps] Connection cleanup failed.", disconnectError);
      setStatus("Connection failed. Safely eject the card, then reconnect and review its map areas.", true);
      }
      if (!pendingBeforeConnect) {
        supported = false;
        radio = null;
        records.clear();
        selectedId = null;
        totalStorageBytes = 0;
        addRequested = false;
        plannerView.cancelAddingArea();
        plannerView.clearBounds();
        updateZoomChoices();
      } else {
        supported = false;
        radio = null;
      }
      byId("radio-state").textContent = "Radio disconnected";
      byId("radio-type").textContent = "Unknown";
      byId("radio-screen").textContent = "Unknown";
      byId("edgetx").textContent = "Unknown";
      if (!radioStorage.root) {
        setStatus(error.name === "AbortError"
          ? "Connection cancelled or folder access was not granted."
          : `Unable to connect: ${error.message}`, error.name !== "AbortError");
      }
    } finally {
      phase = "idle";
      byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
      renderReview();
      refreshStorageSummary();
    }
  });
  byId("delete").addEventListener("click", () => {
    const record = currentRecord();
    if (!record || busy()) return;
    if (record.deleted) {
      cancelDeletion(record);
      selectRecord(record.id);
      return;
    }
    if (!record.onRadio) {
      invalidateReview();
      records.delete(record.id);
      selectedId = [...records.values()].find((candidate) => !candidate.deleted)?.id ?? null;
      if (selectedId) selectRecord(selectedId);
      else {
        plannerView.clearBounds();
        updateZoomChoices();
        renderReview();
      }
      setStatus("");
      return;
    }
    record.stagedBeforeDelete = record.staged;
    record.dirtyBeforeDelete = record.dirty;
    record.deleted = true;
    record.staged = { deleted: true, files: new Map(), bytes: 0 };
    record.dirty = false;
    invalidateReview();
    selectedId = [...records.values()].find((candidate) => !candidate.deleted)?.id ?? null;
    if (selectedId) selectRecord(selectedId);
    else {
      plannerView.clearBounds();
      updateZoomChoices();
      renderReview();
    }
    setStatus("");
  });
  const renameArea = (id, value) => {
    const record = records.get(id);
    if (!record || record.deleted || busy() || !supported || !radioStorage.root) return;
    const name = value.trim();
    if (name && name.length <= 80) {
      record.selection = { ...record.selection, name };
      if (id === selectedId) {
        byId("name").value = name;
        byId("area-name").value = name;
      }
      record.staged = null;
      record.dirty = true;
      invalidateReview();
      updateZoomChoices();
      renderReview();
      setStatus("");
    }
  };
  byId("area-name").addEventListener("input", () => renameArea(selectedId, byId("area-name").value));
  plannerView?.onBoundsChanged(selectionChanged);
  plannerView?.onSelectArea(selectMapAreas);
  plannerView?.onRenameArea(renameArea);

  async function prepareRecord(record) {
    const name = record.selection.name.trim();
    if (!name || name.length > 80) {
      throw new Error("Enter an area name between 1 and 80 characters.");
    }
    if ([...records.values()].some((candidate) => candidate.id !== record.id
        && !candidate.deleted && candidate.selection.name.toLowerCase() === name.toLowerCase())) {
      throw new Error("Map area names must be unique (case-insensitive).");
    }
    let selection;
    try {
      selection = { ...record.selection, name };
    } catch (error) {
      throw new Error(`Cannot prepare this area: ${error.message}`);
    }
    selection.selectedBounds = { ...selection.selectedBounds };
    stageController = new AbortController();
    const signal = stageController.signal;
    plannerView.setAreaEditMode(false);
    byId("stage-status").textContent = "Preparing missing tiles and map metadata...";
    let source;
    try {
      const imagerySet = record.imagerySet;
      const savedTilePaths = imagerySet ? [...mapSelectionTiles(imagerySet, selection)] : [];
      const coveredBySavedTiles = record.onRadio && sameCoverage(record.savedSelection, selection)
        && imagerySet && !record.missingTileCount
        && savedTilePaths.every((path) => storedTileSizes.has(path))
        && typeof packs.areaManifest === "function";
      let files;
      let areaBytes = 0;
      if (coveredBySavedTiles) {
        areaBytes = savedTilePaths.reduce((total, path) => total + storedTileSizes.get(path), 0);
        const { yaml } = packs.areaManifest(selection, record.id, imagerySet);
        files = new Map([[`AEROGRID/maps/areas/${record.id}.yaml`, new TextEncoder().encode(yaml)]]);
      } else {
        const getSource = async () => {
          if (record.imagerySet === packs.SYNTHETIC.id || record.sourceMetadata?.synthetic) {
            if (record.imagerySet !== packs.SYNTHETIC.id
                || (record.sourceMetadata && (record.sourceMetadata.source !== packs.SYNTHETIC.source
                || record.sourceMetadata.edition !== packs.SYNTHETIC.edition
                || record.sourceMetadata.conversion !== packs.SYNTHETIC.conversion))) {
              throw new Error("Saved map images are unavailable. Choose another area or reconnect the original card.");
            }
            source = {
              metadata: packs.SYNTHETIC,
              readTile: (zoom, x, y, signal) =>
                sources.encodeJpeg(packs.syntheticRgb(zoom, x, y), signal),
            };
            if (record.imagerySet && record.imagerySet !== source.metadata.id) {
              throw new Error("Saved map images are unavailable. Choose another area or reconnect the original card.");
            }
            return source;
          }
          if (record.sourceMetadata && record.sourceMetadata.source !== "Google hybrid") {
            throw new Error("Saved map images are unavailable. Reconnect using the browser and site storage where this area was created.");
          }
          source = await sources.googleHybrid();
          if (record.imagerySet && source.metadata.id !== record.imagerySet) {
            source.close?.();
            source = null;
            throw new Error("Some map images are missing. Reconnect using the browser and site storage where this area was created.");
          }
          return source;
        };
        files = await packs.createFiles(selection, record.id, {
          imagerySet,
          getSource,
          signal,
          onProgress: ({ completed, total }) => {
            byId("stage-status").textContent = `Preparing map imagery: ${completed}/${total} tiles.`;
            byId("review-progress").max = total || 1;
            byId("review-progress").value = completed;
            byId("review-status").textContent = `Preparing map imagery: ${completed}/${total} tiles.`;
          },
          readExistingTile: (set, zoom, x, y) => set === imagerySet
            ? readMapTile(radioStorage.root, set, zoom, x, y) : null,
        });
      }
      let writeBytes = 0;
      for (const [path, bytes] of files) {
        if (path.includes("/tiles/")) {
          if (!coveredBySavedTiles) areaBytes += bytes.length;
          const tilePath = path.slice("AEROGRID/maps/tiles/".length);
          if (files.existingTiles?.has(tilePath)) continue;
        }
        writeBytes += bytes.length;
      }
      record.selection = selection;
      record.imagerySet = imagerySet || source?.metadata.id;
      record.sourceMetadata = source?.metadata ?? record.sourceMetadata;
      record.staged = { deleted: false, files, bytes: writeBytes, areaBytes };
      record.deleted = false;
      record.dirty = false;
    } finally {
      source?.close?.();
      stageController = null;
    }
  }
  function closeReview(closeDialog = true) {
    if (phase === "writing" || phase === "committing") {
      if (phase === "writing") {
        syncController?.abort();
        byId("update-cancel").disabled = true;
        byId("review-status").textContent = "Cancelling after the current file finishes...";
      }
      return;
    }
    const result = phase === "finished" ? byId("review-status").textContent : "";
    const failed = byId("review-status").classList.contains("ag-map-error");
    const succeeded = byId("review-status").classList.contains("ag-map-success");
    if (stageController) {
      stageController.abort();
      setStatus("Map preparation cancelled.");
    }
    phase = "idle";
    updateReady = false;
    byId("update-cancel").textContent = "Cancel";
    byId("update-cancel").disabled = false;
    byId("sync").hidden = false;
    if (closeDialog) byId("review-panel").close();
    if (result) setStatus(result, failed, succeeded);
  }
  byId("update-cancel").addEventListener("click", closeReview);
  byId("review-panel").addEventListener("cancel", (event) => {
    if (phase === "writing" || phase === "committing") {
      event.preventDefault();
      return;
    }
    closeReview(false);
  });
  byId("update").addEventListener("click", async () => {
    if (!radioStorage.root || busy()) return;
    updateReady = false;
    reviewSignature = "";
    const dialog = byId("review-panel");
    const list = byId("review-list");
    list.replaceChildren();
    byId("review-status").textContent = "Preparing map changes...";
    byId("review-status").classList.remove("ag-map-error", "ag-map-success");
    byId("review-progress").max = 1;
    byId("review-progress").value = 0;
    byId("review-progress").hidden = false;
    byId("update-cancel").textContent = "Cancel";
    byId("update-cancel").disabled = false;
    byId("sync").hidden = false;
    dialog.showModal();
    byId("sync").disabled = true;
    phase = "preparing";
    renderReview();
    byId("sync").disabled = true;
    try {
      refreshLibraryState(await inspectMapLibrary(radioStorage.root), true);
      // Rebuild the review after checking for tiles removed since connection.
      list.replaceChildren();
      for (const record of records.values()) {
        if (!record.staged && !record.dirty) continue;
        const item = document.createElement("li");
        const action = document.createElement("span");
        action.className = "ag-map-review-action";
        action.textContent = record.deleted ? "Remove" : record.missingTileCount ? "Repair"
          : record.onRadio ? "Update" : "Add";
        const name = document.createElement("strong");
        name.textContent = record.selection.name;
        item.append(action, name);
        list.append(item);
      }
      for (const record of records.values()) {
        if (!dialog.open) return;
        if (record.dirty && !record.deleted) await prepareRecord(record);
      }
      const storage = plannedMapStorage(records.values(), storedTileSizes);
      if (storage.estimated) throw new Error("Some map imagery has not been prepared; exact data changes cannot be confirmed.");
      byId("review-add").textContent = formatBytes(storage.addedBytes);
      byId("review-remove").textContent = formatBytes(storage.removedBytes);
      byId("review-total").textContent = formatBytes(storage.minimumBytes);
      byId("review-progress").hidden = true;
      byId("review-status").textContent = "Maps prepared. Review the changes before syncing.";
    } catch (error) {
      if (error.name !== "AbortError") console.error("[AeroGrid maps] Preparation failed.", error);
      byId("review-progress").hidden = true;
      if (error.name === "AbortError") {
        byId("review-status").textContent = "Map preparation cancelled.";
      } else {
        byId("review-status").textContent = `Unable to prepare maps: ${error.message}`;
        byId("review-status").classList.add("ag-map-error");
        setStatus(error.message, true);
      }
      return;
    } finally {
      phase = dialog.open ? "reviewing" : "idle";
      renderReview();
      byId("sync").disabled = true;
    }
    updateReady = dialog.open;
    reviewSignature = updateReady ? draftSignature() : "";
    byId("sync").disabled = !updateReady || !pendingCount();
  });
  byId("sync").addEventListener("click", async () => {
    if (!updateReady || !byId("review-panel").open || !pendingCount() || busy()) return;
    if (reviewSignature !== draftSignature() || [...records.values()].some((record) => record.dirty)) {
      invalidateReview();
      byId("review-status").textContent = "Map changes were edited after review. Review them again before syncing.";
      byId("review-status").classList.add("ag-map-error");
      renderReview();
      return;
    }
    updateReady = false;
    syncController = new AbortController();
    phase = "writing";
    byId("review-status").textContent = "Requesting permission to write to the SD card...";
    byId("review-status").classList.remove("ag-map-error", "ag-map-success");
    byId("review-progress").max = 1;
    byId("review-progress").value = 0;
    byId("review-progress").hidden = false;
    byId("update-cancel").disabled = false;
    renderReview();
    let writesStarted = false;
    try {
      await radioStorage.requestWritePermission();
      let syncedLibrary;
      await radioStorage.exclusive(async (root) => {
        const previousLibrary = await inspectMapLibrary(root);
        refreshLibraryState(previousLibrary);
        const changes = [...records.values()].filter((record) => record.staged);
        const preparedTiles = new Set(changes.flatMap((record) => [...record.staged.files.keys()]
          .filter((path) => path.startsWith("AEROGRID/maps/tiles/"))
          .map((path) => path.slice("AEROGRID/maps/tiles/".length))));
        const retainedTiles = new Set([...records.values()].filter((record) => !record.deleted)
          .flatMap((record) => [...mapSelectionTiles(record.imagerySet, record.selection)]));
        if ([...(previousLibrary.missingTiles ?? [])]
          .some((path) => retainedTiles.has(path) && !preparedTiles.has(path))) {
          throw new Error("More map tiles went missing after preparation. Close this review and use Sync Maps again to prepare their repair.");
        }
        const writeChanges = changes.filter((item) => !item.staged.deleted);
        const files = new Map(writeChanges.flatMap((record) => [...record.staged.files]));
        const orderedFiles = new Map([...files].sort(([left], [right]) =>
          Number(left.includes("/areas/")) - Number(right.includes("/areas/"))));
        writesStarted = changes.length > 0;
        await writeMapFiles(root, orderedFiles, (completed, total) => {
          byId("review-progress").max = total || 1;
          byId("review-progress").value = completed;
          byId("review-status").textContent = syncController.signal.aborted
            ? "Cancelling after the current file finishes..."
            : `Writing map files: ${completed}/${total}.`;
        }, {
          signal: syncController.signal,
          onCommit: () => {
            phase = "committing";
            byId("update-cancel").disabled = true;
            byId("review-status").textContent = "Updating map area records...";
          },
        });
        byId("review-status").textContent = "Updating map area records...";
        for (const record of changes.filter((item) => item.staged.deleted)) {
          writesStarted = true;
          await removeMapArea(root, record.id);
        }
        byId("review-status").textContent = "Cleaning up unreferenced map tiles...";
        const updatedLibrary = await inspectMapLibrary(root);
        if (updatedLibrary.missingTileCount) {
          throw new Error("Map tiles went missing during sync. Reconnect and prepare their repair.");
        }
        await pruneUnreferencedMapTiles(
          root, previousLibrary.referencedTiles, updatedLibrary.referencedTiles);
        syncedLibrary = updatedLibrary;
      });
      const old = selectedId;
      await loadRadio(syncedLibrary);
      if (old && records.has(old)) selectRecord(old);
      byId("review-progress").value = byId("review-progress").max;
      byId("review-status").textContent = "Done. Maps updated. Safely eject the SD card through your operating system before unplugging.";
      byId("review-status").classList.add("ag-map-success");
    } catch (error) {
      console.error("[AeroGrid maps] Sync failed.", error);
      if (error.name === "AbortError" && syncController.signal.aborted && phase === "writing") {
        byId("review-status").textContent =
          "Sync cancelled. Area records were not changed. Completed tile files remain on the SD card and can be reused when you retry.";
      } else {
        byId("review-status").textContent =
          `Map update failed: ${error.message} ` + (writesStarted
            ? "Some files may already have been written; reconnect and review the map library before retrying."
            : "No radio files were changed.");
        byId("review-status").classList.add("ag-map-error");
      }
    } finally {
      phase = "finished";
      syncController = null;
      byId("update-cancel").disabled = false;
      byId("update-cancel").textContent = "Done";
      byId("sync").hidden = true;
      renderReview();
    }
  });

  plannerView?.ready.then(() => renderMapAreas());
  renderReview();
  refreshStorageSummary();
  renderNames();
  byId("radio-state").textContent = "Radio disconnected";
  byId("radio-type").textContent = "Unknown";
  byId("radio-screen").textContent = "Unknown";
  byId("edgetx").textContent = "Unknown";
  connectButton.disabled = !globalThis.isSecureContext || typeof globalThis.showDirectoryPicker !== "function";
  if (connectButton.disabled) {
    setStatus("Radio access requires desktop Chrome or Edge over HTTPS (or localhost).", true);
  } else {
    phase = "preparing";
    renderReview();
    void (async () => {
      try {
        if (await radioStorage.restore()) await loadRadio();
      } catch (error) {
        radioStorage.disconnect();
        supported = false;
        radio = null;
        records.clear();
        selectedId = null;
        totalStorageBytes = 0;
        byId("radio-state").textContent = "Radio disconnected";
        byId("radio-type").textContent = "Unknown";
        byId("radio-screen").textContent = "Unknown";
        byId("edgetx").textContent = "Unknown";
        setStatus(error.message, true);
      } finally {
        phase = "idle";
        renderReview();
        refreshStorageSummary();
      }
    })();
  }
  byId("overlap-cancel").addEventListener("click", () => byId("overlap-dialog").close());
  globalThis.addEventListener("beforeunload", (event) => {
    if (busy() || hasDraft()) {
      event.preventDefault();
      event.returnValue = "";
    }
  });
  setInterval(async () => {
    if (!radioStorage.root || busy() || document.hidden || !supported) return;
    try {
      const current = await radioStorage.inspect();
      if (current.radio.board !== radio?.board || current.radio.version !== radio?.version) {
        updateRadioDetails(current);
        byId("radio").dispatchEvent(new Event("change", { bubbles: true }));
      }
    } catch (error) {
      console.error("[AeroGrid maps] SD-card access lost.", error);
      try {
        radioStorage.disconnect();
      } catch (disconnectError) {
        console.error("[AeroGrid maps] Could not clear the saved SD-card connection.", disconnectError);
      }
      supported = false;
      radio = null;
      invalidateReview();
      setStatus(hasDraft()
        ? "Radio access was lost. Pending edits are still on this page. Reconnect the same card to keep them, or choose to discard and reload."
        : "Radio access was lost. Reconnect the card to continue.", true);
      byId("radio-state").textContent = "Radio disconnected";
      byId("radio-type").textContent = "Unknown";
      byId("radio-screen").textContent = "Unknown";
      byId("edgetx").textContent = "Unknown";
      refreshStorageSummary();
    } finally {
      byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
      renderReview();
    }
  }, 5000);
}
