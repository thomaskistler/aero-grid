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
  let busy = false;
  let expectedSignature = "";
  let totalStorageBytes = 0;
  let storedTileSizes = new Map();
  let addRequested = false;
  let stageController = null;
  let renamingId = null;
  let updateReady = false;
  let syncing = false;
  let syncController = null;
  let committingSync = false;
  let syncComplete = false;
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
  function cancelDeletion(record) {
    record.deleted = false;
    record.staged = record.stagedBeforeDelete ?? null;
    record.dirty = record.dirtyBeforeDelete ?? false;
    delete record.stagedBeforeDelete;
    delete record.dirtyBeforeDelete;
    setStatus("");
  }
  const renderNames = () => {
    const list = byId("area-list");
    if (renamingId && records.has(renamingId) && supported && !busy) {
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
      button.disabled = !supported || busy;
      const name = document.createElement("strong");
      name.textContent = record.selection.name;
      const details = document.createElement("small");
      const tileCount = record.selection.tileCount;
      const savedCoverageMatches = record.onRadio && record.savedSelection
        && JSON.stringify(record.selection.levels) === JSON.stringify(record.savedSelection.levels);
      const storage = record.staged && !record.staged.deleted
        ? `${formatBytes(record.staged.areaBytes)} prepared`
        : savedCoverageMatches
          ? `${formatBytes(record.storageBytes)} occupied`
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
        if (busy || !supported || record.deleted) return;
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
        edit.disabled = !supported || busy;
        edit.setAttribute("aria-label", `Rename ${record.selection.name}`);
        edit.title = `Rename ${record.selection.name}`;
        const pencil = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        pencil.setAttribute("viewBox", "0 0 24 24");
        pencil.setAttribute("aria-hidden", "true");
        const pencilPath = document.createElementNS("http://www.w3.org/2000/svg", "path");
        pencilPath.setAttribute("d", "M21.174 6.812a1 1 0 0 0-3.986-3.986L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497zM15 5l4 4");
        pencil.append(pencilPath);
        edit.append(pencil);
        edit.addEventListener("click", rename);
        row.append(edit);
        const remove = document.createElement("button");
        remove.type = "button";
        remove.className = "ag-map-area-remove";
        remove.disabled = !supported || busy;
        remove.setAttribute("aria-label", `Delete ${record.selection.name}`);
        remove.title = `Delete ${record.selection.name}`;
        const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        icon.setAttribute("viewBox", "0 0 24 24");
        icon.setAttribute("aria-hidden", "true");
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("d", "M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M10 11v6M14 11v6");
        icon.append(path);
        remove.append(icon);
        remove.addEventListener("click", () => byId("delete").click());
        row.append(remove);
      }
      list.append(row);
    }
  };
  const renderReview = () => {
    const canEdit = !!radioStorage.root && supported && !!radio?.preset && !busy;
    plannerView?.setAreaEditMode(canEdit);
    byId("create-help").textContent = radioStorage.root
      ? "Hold Shift and drag on the map to create a new area."
      : "Connect a radio to edit map areas.";
    panel.classList.toggle("ag-radio-connected", !!radioStorage.root);
    connectButton.classList.toggle("ag-radio-primary", !radioStorage.root);
    connectButton.classList.toggle("ag-radio-danger", !!radioStorage.root);
    byId("compatibility").hidden = !radioStorage.root;
    connectButton.disabled = busy || !globalThis.isSecureContext
      || typeof globalThis.showDirectoryPicker !== "function";
    if (!busy) byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
    const count = pendingCount();
    byId("update").disabled = !radioStorage.root || busy
      || ![...records.values()].some((record) => record.dirty || record.staged);
    byId("delete").disabled = !supported || !currentRecord() || busy;
    byId("area-name").disabled = !supported || !currentRecord() || busy;
    byId("sync").disabled = !updateReady || !count || busy;
    const dirtyCount = [...records.values()].filter((record) => record.dirty && !record.staged).length;
    const changes = count + dirtyCount;
    const summary = changes ? `${changes} ${changes === 1 ? "area has" : "areas have"} pending changes.` : "";
    byId("stage-status").textContent = busy ? "Map operation in progress..." : summary;
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
      button.disabled = busy || zoom < record.selection.levels[0].zoom;
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
    const stagedSize = record.staged && !record.staged.deleted
      ? ` Staged area size: approximately ${formatBytes(record.staged.areaBytes)}.`
      : "";
    byId("selected-summary").textContent =
      `${record.selection.name} · Zoom ${record.selection.levels[0].zoom}–${actualMaximum}${stagedSize}`;
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
      return record && !record.deleted && supported && !busy;
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
    if (!radioStorage.root || !supported || !radio?.preset || busy) return;
    if (event.origin === "drawing-start" || event.origin === "drawing-cancel") {
      addRequested = event.origin === "drawing-start";
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
      byId("canvas").style.cursor = "";
      setStatus("");
    } else {
      if (!record) return;
      record.selection = { ...event.selection, name: byId("area-name").value.trim() || record.selection.name };
      record.staged = null;
      record.dirty = true;
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
    selectedId = records.keys().next().value ?? null;
    refreshStorageSummary();
    renderReview();
    if (selectedId && radio.preset) selectRecord(selectedId);
    else {
      plannerView.clearBounds();
      updateZoomChoices();
    }
    setStatus(library.missingTileCount
      ? `${library.missingTileCount} shared map tiles are missing. Sync Maps to prepare a repair using the original imagery library.`
      : "");
  }
  function refreshLibraryState(library) {
    if (mapLibrarySignatureFromAreas(library.areas) !== expectedSignature
        || [...library.tileSizes].some(([path, size]) =>
          storedTileSizes.has(path) && storedTileSizes.get(path) !== size)) {
      throw new Error("The radio map library changed while preparing the update. Reconnect and review your changes again.");
    }
    totalStorageBytes = library.tileBytes;
    storedTileSizes = library.tileSizes;
    for (const area of library.areas) {
      const record = records.get(area.id);
      record.storageBytes = area.storageBytes;
      record.missingTiles = area.missingTiles;
      record.missingTileCount = area.missingTileCount;
      if (area.missingTileCount && !record.deleted && !record.staged) record.dirty = true;
    }
  }
  connectButton.addEventListener("click", async () => {
    if (busy) return;
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
    busy = true;
    byId("connect-label").textContent = "Connecting...";
    setStatus("Select the mounted radio SD-card root. Connecting does not change files.");
    renderReview();
    try {
      await radioStorage.connect();
      await loadRadio();
    } catch (error) {
      try {
        radioStorage.disconnect();
      } catch (disconnectError) {
        setStatus(`Connection failed: ${error.message}. Disconnect cleanup failed: ${disconnectError.message}`, true);
      }
      supported = false;
      radio = null;
      records.clear();
      selectedId = null;
      totalStorageBytes = 0;
      addRequested = false;
      plannerView.cancelAddingArea();
      plannerView.clearBounds();
      updateZoomChoices();
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
      busy = false;
      byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
      renderReview();
      refreshStorageSummary();
    }
  });
  byId("delete").addEventListener("click", () => {
    const record = currentRecord();
    if (!record || busy) return;
    if (record.deleted) {
      cancelDeletion(record);
      selectRecord(record.id);
      return;
    }
    if (!record.onRadio) {
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
    if (!record || record.deleted || busy || !supported || !radioStorage.root) return;
    const name = value.trim();
    if (name && name.length <= 80) {
      record.selection = { ...record.selection, name };
      if (id === selectedId) {
        byId("name").value = name;
        byId("area-name").value = name;
      }
      record.staged = null;
      record.dirty = true;
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
      if (record.imagerySet === packs.SYNTHETIC.id || record.sourceMetadata?.synthetic) {
        if (record.imagerySet !== packs.SYNTHETIC.id
            || (record.sourceMetadata && (record.sourceMetadata.source !== packs.SYNTHETIC.source
            || record.sourceMetadata.edition !== packs.SYNTHETIC.edition
            || record.sourceMetadata.conversion !== packs.SYNTHETIC.conversion))) {
          throw new Error("This synthetic imagery set cannot be reproduced by the browser manager.");
        }
        source = {
          metadata: packs.SYNTHETIC,
          readTile: (zoom, x, y, signal) =>
            sources.encodeJpeg(packs.syntheticRgb(zoom, x, y), signal),
        };
      } else {
        if (record.sourceMetadata && record.sourceMetadata.source !== "Google hybrid") {
          throw new Error("This imagery source cannot be refreshed by the browser manager.");
        }
        source = await sources.googleHybrid();
      }
      const imagerySet = record.imagerySet || source.metadata.id;
      if (imagerySet !== source.metadata.id) {
        throw new Error("This browser does not have the original first-capture imagery library for this area. " +
          "A new capture cannot be mixed into its existing imagery-set ID.");
      }
      const selectedSource = source;
      const files = await packs.createFiles(selection, record.id, {
        source: selectedSource,
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
      let writeBytes = 0;
      let areaBytes = 0;
      for (const [path, bytes] of files) {
        if (path.includes("/tiles/")) {
          areaBytes += bytes.length;
          const [, , , set, zoom, x, filename] = path.split("/");
          if (await readMapTile(radioStorage.root, set, Number(zoom), Number(x), Number(filename.slice(0, -4))) !== null) continue;
        }
        writeBytes += bytes.length;
      }
      record.selection = selection;
      record.imagerySet = imagerySet;
      record.sourceMetadata = selectedSource.metadata;
      record.staged = { deleted: false, files, bytes: writeBytes, areaBytes };
      record.deleted = false;
      record.dirty = false;
    } finally {
      source?.close?.();
      stageController = null;
    }
  }
  function closeReview(closeDialog = true) {
    if (syncing) {
      if (!committingSync) {
        syncController?.abort();
        byId("update-cancel").disabled = true;
        byId("review-status").textContent = "Cancelling after the current file finishes...";
      }
      return;
    }
    const result = syncComplete ? byId("review-status").textContent : "";
    const failed = byId("review-status").classList.contains("ag-map-error");
    const succeeded = byId("review-status").classList.contains("ag-map-success");
    if (stageController) {
      stageController.abort();
      setStatus("Map preparation cancelled.");
    }
    updateReady = false;
    syncComplete = false;
    byId("update-cancel").textContent = "Cancel";
    byId("update-cancel").disabled = false;
    byId("sync").hidden = false;
    if (closeDialog) byId("review-panel").close();
    if (result) setStatus(result, failed, succeeded);
  }
  byId("update-cancel").addEventListener("click", closeReview);
  byId("review-panel").addEventListener("cancel", (event) => {
    if (syncing) {
      event.preventDefault();
      return;
    }
    closeReview(false);
  });
  byId("update").addEventListener("click", async () => {
    if (!radioStorage.root || busy) return;
    updateReady = false;
    syncComplete = false;
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
    busy = true;
    renderReview();
    byId("sync").disabled = true;
    try {
      refreshLibraryState(await inspectMapLibrary(radioStorage.root));
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
      busy = false;
      renderReview();
      byId("sync").disabled = true;
    }
    updateReady = dialog.open;
    byId("sync").disabled = !updateReady || !pendingCount();
  });
  byId("sync").addEventListener("click", async () => {
    if (!updateReady || !byId("review-panel").open || !pendingCount() || busy) return;
    updateReady = false;
    syncing = true;
    syncController = new AbortController();
    committingSync = false;
    busy = true;
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
        writesStarted = files.size > 0;
        await writeMapFiles(root, orderedFiles, (completed, total) => {
          byId("review-progress").max = total || 1;
          byId("review-progress").value = completed;
          byId("review-status").textContent = syncController.signal.aborted
            ? "Cancelling after the current file finishes..."
            : `Writing map files: ${completed}/${total}.`;
        }, {
          signal: syncController.signal,
          onCommit: () => {
            committingSync = true;
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
      byId("review-status").textContent = "Maps updated. Safely eject the SD card through your operating system before unplugging.";
      byId("review-status").classList.add("ag-map-success");
    } catch (error) {
      if (error.name === "AbortError" && syncController.signal.aborted && !committingSync) {
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
      busy = false;
      syncing = false;
      syncController = null;
      committingSync = false;
      syncComplete = true;
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
    busy = true;
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
        busy = false;
        renderReview();
        refreshStorageSummary();
      }
    })();
  }
  byId("overlap-cancel").addEventListener("click", () => byId("overlap-dialog").close());
  globalThis.addEventListener("beforeunload", (event) => {
    if (busy || pendingCount() || [...records.values()].some((record) => record.dirty) || addRequested) {
      event.preventDefault();
      event.returnValue = "";
    }
  });
  setInterval(async () => {
    if (!radioStorage.root || busy || document.hidden || !supported) return;
    try {
      const current = await radioStorage.inspect();
      if (current.radio.board !== radio?.board || current.radio.version !== radio?.version) {
        updateRadioDetails(current);
        byId("radio").dispatchEvent(new Event("change", { bubbles: true }));
      }
    } catch (error) {
      try {
        radioStorage.disconnect();
      } catch (disconnectError) {
        setStatus(`SD-card access was lost: ${error.message}. Disconnect cleanup failed: ${disconnectError.message}`, true);
      }
      supported = false;
      radio = null;
      records.clear();
      selectedId = null;
      totalStorageBytes = 0;
      addRequested = false;
      plannerView.cancelAddingArea();
      plannerView.clearBounds();
      updateZoomChoices();
      if (!radioStorage.root) setStatus(`SD-card access lost: ${error.message} Reconnect the radio and select its SD card again.`, true);
      byId("radio-state").textContent = "Radio disconnected";
      refreshStorageSummary();
      renderNames();
    } finally {
      byId("connect-label").textContent = radioStorage.root ? "Disconnect Radio" : "Connect Radio";
      renderReview();
    }
  }, 5000);
}
