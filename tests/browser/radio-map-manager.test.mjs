// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";
import { radioCompatibility, radioHardware } from "../../docs/javascripts/radio-storage.mjs";
import {
  RADIO_MAP_PRESETS, plannedMapStorage, mapLibrarySignatureFromAreas, mapSelectionTiles,
} from "../../docs/javascripts/radio-map-library.mjs";

const source = (await readFile(new URL("../../docs/javascripts/radio-map-manager.mjs", import.meta.url), "utf8"))
  .replace(/^import[\s\S]*?from "[^"]+";\n/gm, "");

async function manager(board, restoreConnection = false, areas = [], tileSizes = new Map(), options = {}) {
  const nodes = new Map();
  function node() {
    const classes = new Set();
    return {
      value: "", textContent: "", hidden: false, disabled: false, style: {}, handlers: {}, children: [],
      classList: {
        toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
        add(...names) { names.forEach((name) => classes.add(name)); },
        remove(...names) { names.forEach((name) => classes.delete(name)); },
        contains(name) { return classes.has(name); },
      },
      attributes: {},
      setAttribute(name, value) { this.attributes[name] = value; },
      click() { return this.handlers.click?.(); },
      showModal() { this.open = true; }, close() { this.open = false; },
      focus() {}, scrollIntoView() {}, select() {}, setCustomValidity() {}, reportValidity() {},
      querySelector() { return null; },
      replaceChildren() { this.children = []; },
      append(...children) { this.children.push(...children); },
      addEventListener(name, handler) { this.handlers[name] = handler; },
      dispatchEvent(event) { return this.handlers[event.type]?.(event); },
    };
  }
  const get = (id) => {
    if (!nodes.has(id)) nodes.set(id, node());
    return nodes.get(id);
  };
  let poll;
  let changeBounds;
  let keydown;
  let resizeCount = 0;
  const metadata = { board, version: "2.12.0" };
  const writes = [];
  let writePermissionRequests = 0;
  const storage = {
    root: null,
    async connect() { this.root = {}; },
    async restore() {
      if (restoreConnection) this.root = {};
      return restoreConnection;
    },
    async inspect() {
      if (options.failInspect) throw new DOMException("Drive removed", "NotReadableError");
      return { radio: metadata };
    },
    async requestWritePermission() {
      writePermissionRequests++;
      await options.requestWritePermission?.();
    },
    async exclusive(callback) { await callback(this.root); },
    disconnect() { this.root = null; },
  };
  const context = {
    document: { body: node(), querySelector: () => get("panel"), getElementById: get, createElement: node, createElementNS: node },
    radioStorage: storage, radioHardware, radioCompatibility, RADIO_MAP_PRESETS,
    inspectMapLibrary: options.inspectMapLibrary ?? (async () => ({
      areas, tileBytes: [...tileSizes.values()].reduce((total, size) => total + size, 0), tileSizes,
    })),
    plannedMapStorage, mapSelectionTiles,
    readMapTile: options.readMapTile ?? (async () => null),
    removeMapArea: options.removeMapArea ?? (async () => {}),
    writeMapFiles: async (root, files, progress, settings) => {
      writes.push(files);
      await options.writeMapFiles?.(root, files);
      if (settings.signal.aborted) throw Object.assign(new Error("Cancelled"), { name: "AbortError" });
      settings.onCommit();
    },
    pruneUnreferencedMapTiles: options.pruneUnreferencedMapTiles ?? (async () => {}),
    AeroGridMapPack: options.packs,
    AeroGridMapSources: options.sources,
    mapLibrarySignatureFromAreas,
    AeroGridMapPlanner: {
      radioFootprint: () => ({ width: 480, height: 272 }),
      tileUrl: (zoom, x, y) => `https://fixture.invalid/${zoom}/${x}/${y}`,
    },
    AeroGridMapPlannerView: {
      ready: Promise.resolve(true), renderAreas() {}, clearBounds() {}, resize() { resizeCount++; },
      setAreaEditMode(enabled) { get("ag-map-edit-mode").enabled = enabled; },
      onBoundsChanged(handler) { changeBounds = handler; },
      onSelectArea() {}, onRenameArea() {}, cancelAddingArea() {}, selectBounds() {},
    },
    isSecureContext: true, showDirectoryPicker() {},
    confirm: options.confirm ?? (() => true),
    scrollY: 120, scrollTo() {},
    addEventListener(name, handler) { if (name === "keydown") keydown = handler; },
    setInterval(handler) { poll = handler; },
    Event: class { constructor(type) { this.type = type; } },
    queueMicrotask,
    AbortController,
    TextEncoder,
  };
  vm.runInNewContext(source, context);
  await new Promise((resolve) => setImmediate(resolve));
  if (!restoreConnection) await get("ag-map-connect").handlers.click();
  return {
    get: (id) => get(`ag-map-${id}`), storage, metadata, poll, changeBounds,
    panel: get("panel"), keydown, resizeCount: () => resizeCount,
    writes, writePermissionRequests: () => writePermissionRequests,
  };
}

test("expanded view restores the map without changing radio state", async () => {
  const view = await manager("tx16s");
  const root = view.storage.root;
  view.get("expand").click();
  assert.equal(view.panel.classList.contains("ag-map-expanded"), true);
  assert.equal(view.get("expand").attributes["aria-pressed"], "true");
  assert.equal(view.get("expand").attributes["aria-label"], "Collapse map");
  view.keydown({ key: "Escape" });
  assert.equal(view.panel.classList.contains("ag-map-expanded"), false);
  assert.equal(view.get("expand").attributes["aria-pressed"], "false");
  assert.equal(view.get("expand").attributes["aria-label"], "Expand map");
  assert.equal(view.resizeCount(), 2);
  assert.equal(view.storage.root, root);
  view.get("expand").click();
  view.get("expand").click();
  assert.equal(view.panel.classList.contains("ag-map-expanded"), false);
});

test("unknown screen dimensions warn and prevent area creation", async () => {
  const view = await manager("unknown-board");
  assert.equal(view.get("edit-mode").enabled, false);
  assert.equal(view.get("compatibility").hidden, false);
  assert.equal(view.get("compatibility").classList.contains("ag-map-warning"), true);
  assert.match(view.get("compatibility").textContent, /Continue at your own risk/);
  assert.match(view.get("compatibility").textContent, /no substitute screen size/);
  assert.equal(view.get("radio").value, "");
  assert.equal(view.get("storage-used").textContent, "0 B");
  await view.poll();
  assert.equal(view.get("edit-mode").enabled, false);
});

test("recognized screens remain automatic and disconnect uses installer danger styling", async () => {
  const view = await manager("tx16s");
  assert.equal(view.get("radio").value, "tx16s");
  assert.equal(view.get("compatibility").classList.contains("ag-map-warning"), false);
  assert.equal(view.get("connect").classList.contains("ag-radio-danger"), true);
  assert.equal(view.get("connect").classList.contains("ag-radio-primary"), false);
  assert.equal(view.get("connect-label").textContent, "Disconnect Radio");
  assert.equal(view.get("radio-state").textContent, "Radio connected");
  assert.equal(view.get("create-help").textContent, "Hold Shift and drag on the map to create a new area.");
  await view.get("connect").handlers.click();
  assert.equal(view.get("create-help").textContent, "Connect a radio to edit map areas.");
  assert.equal(view.get("connect").classList.contains("ag-radio-danger"), false);
  assert.equal(view.get("connect").classList.contains("ag-radio-primary"), true);
  assert.equal(view.get("connect-label").textContent, "Connect Radio");
  assert.equal(view.get("radio-state").textContent, "Radio disconnected");
  assert.equal(view.get("storage-used").textContent, "Unknown");
  assert.equal(view.get("compatibility").hidden, true);
});

test("monochrome screens also warn but allow map controls", async () => {
  const view = await manager("boxer");
  assert.equal(view.get("edit-mode").enabled, true);
  assert.match(view.get("compatibility").textContent, /monochrome/);
  assert.equal(view.get("radio-state").textContent, "Radio connected");
  assert.equal(view.get("radio").value, "mono-128x64");
});

test("map manager restores a radio connection automatically on page load", async () => {
  const view = await manager("tx16s", true);
  assert.equal(view.get("radio-state").textContent, "Radio connected");
  assert.equal(view.get("connect-label").textContent, "Disconnect Radio");
  assert.equal(view.get("connect").classList.contains("ag-radio-danger"), true);
  assert.equal(view.get("radio-type").textContent, "RadioMaster TX16S");
  assert.equal(view.get("edit-mode").enabled, true);
});

test("zoom levels stay visible without an area and after disconnecting", async () => {
  const view = await manager("tx16s");
  const assertVisibleChoices = () => {
    const choices = view.get("zoom-choices").children;
    assert.equal(choices.length, 3);
    assert.deepEqual(choices.map((choice) => choice.children[0].textContent), ["Less storage", "Balanced", "Most detail"]);
    assert.ok(choices.every((choice) => choice.disabled));
  };
  assertVisibleChoices();
  assert.match(view.get("selected-summary").textContent, /Select or add/);
  await view.get("connect").handlers.click();
  assertVisibleChoices();
  assert.match(view.get("selected-summary").textContent, /Connect a radio/);
  assert.equal(view.get("edit-mode").enabled, false);
  view.changeBounds({ origin: "new-area", selection: { name: "Disconnected selection" } });
  assert.equal(view.get("area-list").children.length, 0);
  assert.match(view.get("create-help").textContent, /Connect a radio/);
});

test("area entries show consistent sizes, switching to estimates when coverage changes", async () => {
  const level = (tiles) => ({
    zoom: 17, tiles, xRanges: [{ min: 1, max: tiles }], yMin: 2, yMax: 2,
  });
  const selection = {
    name: "Field", tileCount: 4, levels: [level(4)],
    selectedBounds: { south: 1, north: 2, west: 1, east: 2 },
    coverageMode: "full-area-clamped",
  };
  const view = await manager("tx16s", false, [{
    id: "field", imagerySet: "test-set", selection, storageBytes: 40960,
  }], new Map([1, 2, 3, 4].map((x) => [`test-set/17/${x}/2.jpg`, 10240])));
  const detail = () => view.get("area-list").children[0].children[0].children[1];
  assert.equal(detail().textContent, "4 tiles · 40.0 KiB");
  const row = view.get("area-list").children[0];
  assert.equal(row.attributes["data-selected"], "true");
  assert.equal(row.children[1].attributes["aria-label"], "Rename Field");
  assert.equal(row.children[2].attributes["aria-label"], "Delete Field");
  assert.equal(row.children[0].children[2].textContent, "");
  let deleteRequested = false;
  const deleteHandler = view.get("delete").handlers.click;
  view.get("delete").handlers.click = () => { deleteRequested = true; };
  row.children[2].click();
  assert.equal(deleteRequested, true);
  view.get("delete").handlers.click = deleteHandler;
  assert.equal(view.get("storage-used").textContent, "40.0 KiB");
  assert.equal(view.get("storage-selected").textContent, "40.0 KiB");
  assert.equal(view.get("storage-delta").textContent, "No storage change");
  view.changeBounds({ origin: "edit", selection: {
    ...selection, tileCount: 8, levels: [level(8)],
  } });
  assert.equal(detail().textContent, "8 tiles · 160 KiB");
  assert.match(detail().title, /average of 20 KiB/);
  assert.equal(view.get("storage-selected").textContent, "120 KiB");
  assert.equal(view.get("storage-delta").textContent, "+80 KiB vs SD card");
  view.changeBounds({ origin: "edit", selection: {
    ...selection, tileCount: 2, levels: [level(2)],
  } });
  assert.equal(view.get("storage-selected").textContent, "20.0 KiB");
  assert.equal(view.get("storage-delta").textContent, "-20.0 KiB vs SD card");
  view.changeBounds({ origin: "edit", selection: { ...selection, name: "Renamed" } });
  assert.equal(detail().textContent, "4 tiles · 40.0 KiB");
  assert.equal(view.get("storage-delta").textContent, "No storage change");
  view.get("area-list").children[0].children[1].click();
  const input = view.get("area-list").children[0].children[0];
  assert.equal(input.className, "ag-map-area-rename");
  input.value = "Renamed inline";
  input.handlers.keydown({ key: "Enter", preventDefault() {} });
  assert.equal(view.get("area-list").children[0].children[0].children[0].textContent, "Renamed inline");
});

test("detail choices keep zoom ranges and report unavailable previews without broken images", async () => {
  const view = await manager("tx16s", false, [{
    id: "field", imagerySet: "test-set", storageBytes: 40960,
    selection: {
      name: "Field", tileCount: 4, levels: [16, 17].map((zoom) => ({
        zoom, tiles: zoom === 16 ? 1 : 3, xRanges: [{ min: 1, max: zoom === 16 ? 1 : 3 }],
        yMin: 2, yMax: 2,
      })),
      selectedBounds: { south: 1, north: 2, west: 1, east: 2 },
      coverageMode: "per-zoom-clamped",
    },
  }]);
  const choices = view.get("zoom-choices").children;
  assert.deepEqual(choices.map((choice) => choice.children[1].textContent), ["Less storage", "Balanced", "Most detail"]);
  assert.equal(choices[0].children[2].textContent, "");
  const [tiles, message] = choices[0].children[0].children;
  assert.equal(message.hidden, true);
  tiles.children[0].handlers.error();
  assert.equal(tiles.hidden, true);
  assert.equal(message.hidden, false);
  assert.equal(message.textContent, "Preview unavailable");
  assert.equal(view.get("selected-summary").textContent, "Field · Zoom 16–17 · 40.0 KiB");
  for (const [index, choice] of choices.entries()) {
    const zoom = 17 + index;
    const count = 2 ** zoom;
    const centerX = (1.5 + 180) / 360 * count;
    const radians = 1.5 * Math.PI / 180;
    const centerY = (1 - Math.asinh(Math.tan(radians)) / Math.PI) / 2 * count;
    for (const image of choice.children[0].children[0].children) {
      const [, x, y] = new URL(image.src).pathname.slice(1).split("/").map(Number);
      assert.ok(Math.abs(x - parseFloat(image.style.left) / 100 - centerX) < 1e-9);
      assert.ok(Math.abs(y - parseFloat(image.style.top) / 100 - centerY) < 1e-9);
    }
  }
});

test("renaming an area with complete saved coverage needs no source cache or JPEG reads", async () => {
  const captureId = "google-original";
  const area = savedArea(captureId);
  const path = `${captureId}/17/1/2.jpg`;
  let tileReads = 0;
  let sourceRequests = 0;
  const manifestNames = [];
  const view = await manager("tx16s", false, [area], new Map([[path, 4]]), {
    readMapTile: async () => { tileReads++; return null; },
    sources: { googleHybrid: async () => { sourceRequests++; throw new Error("Unexpected source request"); } },
    packs: {
      areaManifest(selection, id, imagerySet) {
        manifestNames.push(selection.name);
        assert.equal(id, "field");
        assert.equal(imagerySet, captureId);
        return { yaml: "renamed metadata" };
      },
      async createFiles() { throw new Error("Complete saved coverage should not be regenerated."); },
      SYNTHETIC: { id: "synthetic-v1-jpeg-q90" },
    },
  });
  view.get("area-name").value = "Renamed without cache";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  assert.equal(view.get("sync").disabled, false, view.get("review-status").textContent);
  assert.equal(view.get("review-add").textContent, "0 B");
  assert.equal(view.get("review-total").textContent, "4 B");
  assert.equal(tileReads, 0);
  assert.equal(sourceRequests, 0);
  view.get("area-name").value = "Changed after review";
  view.get("area-name").dispatchEvent({ type: "input" });
  assert.equal(view.get("sync").disabled, true);
  await view.get("sync").click();
  assert.equal(view.writePermissionRequests(), 0);
  assert.equal(view.writes.length, 0);
  assert.match(view.get("review-status").textContent, /changed after review/);
  await view.get("update").click();
  assert.equal(view.get("sync").disabled, false);
  await view.get("sync").click();
  assert.deepEqual([...view.writes[0].keys()], ["AEROGRID/maps/areas/field.yaml"]);
  assert.deepEqual(manifestNames, ["Renamed without cache", "Changed after review"]);
  assert.equal(tileReads, 0);
  assert.equal(sourceRequests, 0);
});

test("preparation reuses its existing-tile read metadata instead of reading saved JPEGs twice", async () => {
  const capture = { id: "google-original", source: "Google hybrid" };
  const area = savedArea(capture.id);
  const image = new Uint8Array([1, 2, 3, 4]);
  let reads = 0;
  let sourceReads = 0;
  const view = await manager("tx16s", false, [area],
    new Map([[`${capture.id}/17/1/2.jpg`, image.length]]), {
      readMapTile: async (root, set, zoom, x, y) => {
        reads++;
        return x === 1 ? image : null;
      },
      sources: { googleHybrid: async () => ({
        metadata: capture,
        async readTile() { sourceReads++; return image; },
      }) },
      packs: {
        SYNTHETIC: { id: "synthetic-v1-jpeg-q90" },
        async createFiles(selection, id, options) {
          const existingTiles = new Set();
          const files = new Map([[`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])]]);
          for (const x of [1, 2]) {
            const saved = await options.readExistingTile(capture.id, 17, x, 2);
            const bytes = saved ?? await (await options.getSource()).readTile(17, x, 2);
            if (saved) existingTiles.add(`${capture.id}/17/${x}/2.jpg`);
            files.set(`AEROGRID/maps/tiles/${capture.id}/17/${x}/2.jpg`, bytes);
          }
          files.existingTiles = existingTiles;
          return files;
        },
      },
    });
  view.changeBounds({ origin: "edit", selection: {
    ...area.selection, tileCount: 2,
    levels: [{ ...area.selection.levels[0], tiles: 2, xRanges: [{ min: 1, max: 2 }] }],
  } });
  await view.get("update").click();
  assert.equal(reads, 2);
  assert.equal(sourceReads, 1);
  assert.equal(view.get("review-add").textContent, "4 B");
  assert.equal(view.get("sync").disabled, false);
});

function savedArea(imagerySet) {
  return {
    id: "field", imagerySet, version: 2, storageBytes: 4,
    selection: {
      name: "Field", tileCount: 1, levels: [{
        zoom: 17, tiles: 1, xRanges: [{ min: 1, max: 1 }], yMin: 2, yMax: 2,
      }],
      selectedBounds: { south: 1, north: 2, west: 1, east: 2 },
      coverageMode: "per-zoom-clamped",
    },
  };
}

test("batched deletions remove metadata together and prune shared imagery from one final inventory", async () => {
  const first = savedArea("test-set");
  const second = { ...first, id: "second", selection: { ...first.selection, name: "Second" } };
  let areas = [first, second];
  let inspections = 0;
  let removals = 0;
  let prunes = 0;
  const sharedPath = "test-set/17/1/2.jpg";
  const view = await manager("tx16s", false, [], new Map(), {
    inspectMapLibrary: async () => {
      inspections++;
      return {
        areas, tileBytes: areas.length ? 4 : 0,
        tileSizes: areas.length ? new Map([[sharedPath, 4]]) : new Map(),
        referencedTiles: areas.length ? new Set([sharedPath]) : new Set(),
        missingTiles: new Set(), missingTileCount: 0,
      };
    },
    removeMapArea: async (root, id) => {
      removals++;
      areas = areas.filter((area) => area.id !== id);
    },
    pruneUnreferencedMapTiles: async (root, before, after) => {
      prunes++;
      assert.deepEqual(before, new Set([sharedPath]));
      assert.deepEqual(after, new Set());
    },
  });
  view.get("delete").click();
  view.get("delete").click();
  await view.get("update").click();
  assert.equal(inspections, 2);
  await view.get("sync").click();
  assert.equal(removals, 2);
  assert.equal(inspections, 4);
  assert.equal(prunes, 1);
  assert.match(view.get("review-status").textContent, /Done\. Maps updated/);
});

test("SD-card access loss preserves pending edits and reconnect explicitly keeps or reloads them", async () => {
  const original = savedArea("test-set");
  let failInspect = false;
  let connectedAreas = [original];
  const options = {
    confirm: () => true,
    inspectMapLibrary: async () => ({
      areas: connectedAreas, tileBytes: 4,
      tileSizes: new Map([["test-set/17/1/2.jpg", 4]]),
      missingTiles: new Set(), referencedTiles: new Set(["test-set/17/1/2.jpg"]),
      missingTileCount: 0,
    }),
  };
  Object.defineProperty(options, "failInspect", {
    get: () => failInspect,
  });
  const view = await manager("tx16s", false, [], new Map(), options);
  view.get("area-name").value = "Pending rename";
  view.get("area-name").dispatchEvent({ type: "input" });
  failInspect = true;
  await view.poll();
  assert.equal(view.storage.root, null);
  assert.match(view.get("connect-status").textContent, /Pending edits are still on this page/);
  assert.equal(view.get("area-list").children[0].children[0].children[0].textContent, "Pending rename");

  failInspect = false;
  await view.get("connect").click();
  assert.equal(view.storage.root !== null, true);
  assert.equal(view.get("area-list").children[0].children[0].children[0].textContent, "Pending rename");
  assert.equal(view.get("update").disabled, false);

  view.get("area-name").value = "Second pending edit";
  view.get("area-name").dispatchEvent({ type: "input" });
  failInspect = true;
  await view.poll();
  assert.match(view.get("connect-status").textContent, /Pending edits are still on this page/);
  connectedAreas = [{ ...original, id: "other", selection: { ...original.selection, name: "Other radio area" } }];
  failInspect = false;
  await view.get("connect").click();
  assert.equal(view.get("area-list").children[0].children[0].children[0].textContent, "Other radio area");
  assert.equal(view.get("update").disabled, true);
});

async function repairManager({ allMissing = false, originalAvailable = true, overlap = true } = {}) {
  const capture = { id: "google-original", source: "Google hybrid" };
  const tile = new Uint8Array([1, 2, 3, 4]);
  const tilePath = (x) => `${capture.id}/17/${x}/2.jpg`;
  const disk = new Map(allMissing ? [] : [[tilePath(1), tile]]);
  const cache = new Map([[tilePath(2), tile]]);
  let downloads = 0;
  const first = savedArea(capture.id);
  first.selection = { ...first.selection, tileCount: 2,
    levels: [{ ...first.selection.levels[0], tiles: 2, xRanges: [{ min: 1, max: 2 }] }] };
  const areas = [first];
  if (overlap) areas.push({ ...first, id: "overlap", selection: { ...first.selection, name: "Overlap" } });
  const inventory = () => {
    const missingTiles = new Set([1, 2].map(tilePath).filter((path) => !disk.has(path)));
    return {
      areas: areas.map((area) => ({ ...area, storageBytes: disk.size * tile.length,
        missingTiles: new Set(missingTiles), missingTileCount: missingTiles.size })),
      tileSizes: new Map([...disk].map(([path, bytes]) => [path, bytes.length])),
      referencedTiles: new Set([1, 2].map(tilePath)), tileBytes: disk.size * tile.length,
      missingTiles, missingTileCount: missingTiles.size,
    };
  };
  const view = await manager("tx16s", false, [], new Map(), {
    inspectMapLibrary: async () => inventory(),
    readMapTile: async (root, set, zoom, x, y) => disk.get(`${set}/${zoom}/${x}/${y}.jpg`) ?? null,
    writeMapFiles: async (root, files) => {
      for (const [path, bytes] of files) {
        if (path.includes("/tiles/")) disk.set(path.slice("AEROGRID/maps/tiles/".length), bytes);
      }
    },
    sources: { googleHybrid: async () => ({
      metadata: originalAvailable ? capture : { ...capture, id: "google-new" },
      async readTile(zoom, x, y) {
        const key = `${capture.id}/${zoom}/${x}/${y}.jpg`;
        if (!cache.has(key)) { downloads++; cache.set(key, tile); }
        return cache.get(key);
      },
    }) },
    packs: {
      SYNTHETIC: { id: "synthetic-v1-jpeg-q90" },
      async createFiles(selection, id, options) {
        const source = await options.getSource();
        const files = new Map([[`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])]]);
        for (const x of [1, 2]) {
          const existing = await options.readExistingTile(capture.id, 17, x, 2);
          const bytes = existing ?? await source.readTile(17, x, 2);
          files.set(`AEROGRID/maps/tiles/${tilePath(x)}`, bytes);
        }
        return files;
      },
    },
  });
  return { view, disk, tilePath, downloads: () => downloads };
}

test("missing shared tiles enable Repair, reuse original cache/network and clear state after sync and reconnect", async () => {
  for (const allMissing of [false, true]) {
    const { view, downloads } = await repairManager({ allMissing });
    assert.equal(view.get("update").disabled, false);
    assert.equal(view.get("area-list").children[0].children[0].children[2].textContent, "Pending changes");
    assert.match(view.get("connect-status").textContent, /tiles are missing/);
    assert.equal(view.get("storage-used").textContent, allMissing ? "0 B" : "4 B");
    await view.get("update").click();
    assert.equal(view.get("review-list").children.length, 2);
    assert.ok(view.get("review-list").children.every((item) => item.children[0].textContent === "Repair"));
    assert.equal(view.get("sync").disabled, false, view.get("review-status").textContent);
    assert.equal(view.get("review-add").textContent, allMissing ? "8 B" : "4 B");
    assert.equal(view.get("review-total").textContent, "8 B");
    assert.equal(downloads(), allMissing ? 1 : 0);
    await view.get("sync").click();
    assert.match(view.get("review-status").textContent, /Maps updated/);
    assert.equal(view.get("storage-used").textContent, "8 B");
    assert.equal(view.get("update").disabled, true);
    assert.equal(view.get("area-list").children[0].children[0].children[2].textContent, "");
    assert.ok([...view.writes[0].keys()].at(-1).includes("/areas/"));
    view.get("update-cancel").click();
    await view.get("connect").click();
    await view.get("connect").click();
    assert.equal(view.get("update").disabled, true);
    assert.equal(view.get("storage-used").textContent, "8 B");
  }
});

test("repair refuses an unavailable original capture without writing or changing identity", async () => {
  const { view, downloads } = await repairManager({ originalAvailable: false });
  await view.get("update").click();
  assert.match(view.get("review-status").textContent, /Some map images are missing/);
  assert.equal(view.get("sync").disabled, true);
  assert.equal(downloads(), 0);
  assert.equal(view.writes.length, 0);
});

test("tiles deleted since connection are discovered during review and prepared tiles cover later deletion races", async () => {
  const { view, disk, tilePath } = await repairManager({ overlap: false });
  disk.delete(tilePath(1));
  await view.get("update").click();
  assert.equal(view.get("review-add").textContent, "8 B");
  assert.equal(view.get("review-list").children[0].children[0].textContent, "Repair");
  await view.get("sync").click();
  assert.match(view.get("review-status").textContent, /Maps updated/);

  view.get("update-cancel").click();
  view.get("area-name").value = "Renamed";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  disk.delete(tilePath(1));
  await view.get("sync").click();
  assert.match(view.get("review-status").textContent, /Maps updated/);
  assert.equal(disk.size, 2);
});

test("unprepared missing imagery after review refuses all writes and is repairable in the next review", async () => {
  const synthetic = { id: "synthetic-v1-jpeg-q90", synthetic: true };
  const tile = new Uint8Array([1, 2, 3, 4]);
  const path = (x) => `${synthetic.id}/17/${x}/2.jpg`;
  let missing = false;
  const first = savedArea(synthetic.id);
  const second = { ...first, id: "second", selection: {
    ...first.selection, name: "Second",
    levels: [{ ...first.selection.levels[0], xRanges: [{ min: 2, max: 2 }] }],
  } };
  const view = await manager("tx16s", false, [], new Map(), {
    inspectMapLibrary: async () => ({
      areas: [first, { ...second, missingTileCount: Number(missing),
        missingTiles: new Set(missing ? [path(2)] : []) }],
      tileBytes: missing ? 4 : 8, missingTileCount: Number(missing),
      tileSizes: new Map(missing ? [[path(1), 4]] : [[path(1), 4], [path(2), 4]]),
      missingTiles: new Set(missing ? [path(2)] : []),
    }),
    writeMapFiles: async (root, files) => {
      if (files.has(`AEROGRID/maps/tiles/${path(2)}`)) missing = false;
    },
    packs: {
      SYNTHETIC: synthetic,
      async createFiles(selection, id) {
        return new Map([
          [`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])],
          ...[...mapSelectionTiles(synthetic.id, selection)].map((key) =>
            [`AEROGRID/maps/tiles/${key}`, tile]),
        ]);
      },
    },
  });
  view.get("area-name").value = "Renamed";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  missing = true;
  await view.get("sync").click();
  assert.equal(view.writes.length, 0);
  assert.match(view.get("review-status").textContent, /More map tiles went missing/);
  assert.doesNotMatch(view.get("review-status").textContent, /library changed/);
  view.get("update-cancel").click();
  await view.get("update").click();
  assert.ok(view.get("review-list").children.some((item) => item.children[0].textContent === "Repair"));
  assert.equal(view.get("sync").disabled, false);
  await view.get("sync").click();
  assert.match(view.get("review-status").textContent, /Maps updated/);
});

test("format 2 preparation uses only the original browser capture identity and writes tiles before area YAML", async () => {
  const capture = { id: "google-capture", source: "Google hybrid" };
  let preparations = 0;
  const view = await manager("tx16s", false, [savedArea(capture.id)], new Map(), {
    sources: { googleHybrid: async () => ({ metadata: capture }) },
    packs: {
      SYNTHETIC: { id: "synthetic-v1-jpeg-q90" },
      async createFiles(selection, id, options) {
        const source = await options.getSource();
        preparations++;
        assert.equal(source.metadata, capture);
        assert.equal(selection.name, "Renamed");
        return new Map([
          [`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])],
          [`AEROGRID/maps/tiles/${capture.id}/17/1/2.jpg`, new Uint8Array([1, 2, 3, 4])],
        ]);
      },
    },
  });
  view.get("area-name").value = "Renamed";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  assert.equal(preparations, 1);
  assert.equal(view.get("sync").disabled, false);
  assert.equal(view.writePermissionRequests(), 0);
  assert.equal(view.writes.length, 0);
  assert.equal(view.get("review-panel").open, true);
  assert.deepEqual(view.get("review-list").children[0].children.map((part) => part.textContent), ["Update", "Renamed"]);
  assert.equal(view.get("review-add").textContent, "4 B");
  assert.equal(view.get("review-remove").textContent, "0 B");
  assert.equal(view.get("review-total").textContent, "4 B");
  assert.match(view.get("review-status").textContent, /Review the changes/);
  await view.get("sync").click();
  assert.equal(view.writePermissionRequests(), 1);
  assert.deepEqual([...view.writes[0].keys()], [
    "AEROGRID/maps/tiles/google-capture/17/1/2.jpg", "AEROGRID/maps/areas/field.yaml",
  ]);
  assert.equal(view.get("review-panel").open, true);
  assert.match(view.get("review-status").textContent, /Maps updated/);
  assert.equal(view.get("update-cancel").textContent, "Done");
  view.get("update-cancel").click();
  assert.equal(view.get("review-panel").open, false);
});

test("sync review prevents dismissal during writes and shows completion in the modal", async () => {
  let releasePermission;
  const permission = new Promise((resolve) => { releasePermission = resolve; });
  const synthetic = { id: "synthetic-v1-jpeg-q90", synthetic: true };
  const view = await manager("tx16s", false, [savedArea(synthetic.id)], new Map(), {
    requestWritePermission: () => permission,
    packs: {
      SYNTHETIC: synthetic,
      async createFiles(selection, id) {
        return new Map([
          [`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])],
          [`AEROGRID/maps/tiles/${synthetic.id}/17/1/2.jpg`, new Uint8Array([1, 2, 3, 4])],
        ]);
      },
    },
  });
  view.get("area-name").value = "Updated Field";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  const sync = view.get("sync").click();
  assert.equal(view.get("review-panel").open, true);
  assert.equal(view.get("update-cancel").disabled, false);
  let defaultPrevented = false;
  view.get("review-panel").handlers.cancel({
    preventDefault() { defaultPrevented = true; },
  });
  assert.equal(defaultPrevented, true);
  assert.equal(view.get("review-panel").open, true);
  assert.equal(view.writes.length, 0);
  releasePermission();
  await sync;
  assert.equal(view.get("review-panel").open, true);
  assert.match(view.get("review-status").textContent, /Maps updated/);
  assert.equal(view.get("review-progress").value, view.get("review-progress").max);
});

test("cancel during sync keeps the review open and reports unchanged area records", async () => {
  let releaseWrite;
  const write = new Promise((resolve) => { releaseWrite = resolve; });
  const synthetic = { id: "synthetic-v1-jpeg-q90", synthetic: true };
  const view = await manager("tx16s", false, [savedArea(synthetic.id)], new Map(), {
    writeMapFiles: () => write,
    packs: {
      SYNTHETIC: synthetic,
      async createFiles(selection, id) {
        return new Map([
          [`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])],
          [`AEROGRID/maps/tiles/${synthetic.id}/17/1/2.jpg`, new Uint8Array([1, 2, 3, 4])],
        ]);
      },
    },
  });
  view.get("area-name").value = "Updated Field";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  const sync = view.get("sync").click();
  await new Promise((resolve) => setImmediate(resolve));
  view.get("update-cancel").click();
  assert.equal(view.get("review-panel").open, true);
  assert.match(view.get("review-status").textContent, /Cancelling/);
  releaseWrite();
  await sync;
  assert.match(view.get("review-status").textContent, /Sync cancelled.*Area records were not changed/);
  assert.equal(view.get("update-cancel").textContent, "Done");
});

test("missing original format 2 capture is refused without exposing storage jargon", async () => {
  let prepared = false;
  let closed = false;
  const view = await manager("tx16s", false, [savedArea("google-original")], new Map(), {
    sources: { googleHybrid: async () => ({
      metadata: { id: "google-new", source: "Google hybrid" },
      close() { closed = true; },
    }) },
    packs: {
      SYNTHETIC: { id: "synthetic-v1-jpeg-q90" },
      async createFiles(selection, id, options) {
        await options.getSource();
        prepared = true;
        return new Map();
      },
    },
  });
  view.get("area-name").value = "Renamed";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  assert.match(view.get("review-status").textContent, /Some map images are missing/);
  assert.equal(prepared, false);
  assert.equal(closed, true);
  assert.equal(view.get("sync").disabled, true);
  assert.equal(view.writes.length, 0);
});

test("format 2 synthetic preparation and sync need no SD source sidecar", async () => {
  const synthetic = { id: "synthetic-v1-jpeg-q90", synthetic: true };
  let preparations = 0;
  const view = await manager("tx16s", false, [savedArea(synthetic.id)], new Map(), {
    packs: {
      SYNTHETIC: synthetic,
      async createFiles(selection, id, options) {
        const source = await options.getSource();
        preparations++;
        assert.equal(source.metadata, synthetic);
        return new Map([
          [`AEROGRID/maps/areas/${id}.yaml`, new Uint8Array([1])],
          [`AEROGRID/maps/tiles/${synthetic.id}/17/1/2.jpg`, new Uint8Array([1, 2, 3, 4])],
        ]);
      },
    },
  });
  view.get("area-name").value = "Renamed";
  view.get("area-name").dispatchEvent({ type: "input" });
  await view.get("update").click();
  assert.equal(preparations, 1);
  assert.equal(view.get("sync").disabled, false);
  await view.get("sync").click();
  assert.equal(view.writePermissionRequests(), 1);
  assert.equal(view.writes.length, 1);
});
