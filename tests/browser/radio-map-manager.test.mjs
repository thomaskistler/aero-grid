// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";
import { radioCompatibility, radioHardware } from "../../docs/javascripts/radio-storage.mjs";
import { RADIO_MAP_PRESETS, plannedMapStorage } from "../../docs/javascripts/radio-map-library.mjs";

const source = (await readFile(new URL("../../docs/javascripts/radio-map-manager.mjs", import.meta.url), "utf8"))
  .replace(/^import[\s\S]*?from "[^"]+";\n/gm, "");

async function manager(board, restoreConnection = false, areas = [], tileSizes = new Map()) {
  const nodes = new Map();
  function node() {
    const classes = new Set();
    return {
      value: "", textContent: "", hidden: false, disabled: false, style: {}, handlers: {}, children: [],
      classList: {
        toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
        contains(name) { return classes.has(name); },
      },
      attributes: {},
      setAttribute(name, value) { this.attributes[name] = value; },
      click() { return this.handlers.click?.(); },
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
  const storage = {
    root: null,
    async connect() { this.root = {}; },
    async restore() {
      if (restoreConnection) this.root = {};
      return restoreConnection;
    },
    async inspect() { return { radio: metadata }; },
    disconnect() { this.root = null; },
  };
  const context = {
    document: { body: node(), querySelector: () => get("panel"), getElementById: get, createElement: node, createElementNS: node },
    radioStorage: storage, radioHardware, radioCompatibility, RADIO_MAP_PRESETS,
    inspectMapLibrary: async () => ({
      areas, tileBytes: [...tileSizes.values()].reduce((total, size) => total + size, 0), tileSizes,
    }),
    plannedMapStorage,
    mapLibrarySignatureFromAreas: () => "[]",
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
    scrollY: 120, scrollTo() {},
    addEventListener(name, handler) { if (name === "keydown") keydown = handler; },
    setInterval(handler) { poll = handler; },
    Event: class { constructor(type) { this.type = type; } },
    queueMicrotask,
  };
  vm.runInNewContext(source, context);
  await new Promise((resolve) => setImmediate(resolve));
  if (!restoreConnection) await get("ag-map-connect").handlers.click();
  return {
    get: (id) => get(`ag-map-${id}`), storage, metadata, poll, changeBounds,
    panel: get("panel"), keydown, resizeCount: () => resizeCount,
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

test("area entries show tile counts and occupied size, switching to estimates when coverage changes", async () => {
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
  assert.equal(detail().textContent, "4 tiles · 40.0 KiB occupied");
  const row = view.get("area-list").children[0];
  assert.equal(row.attributes["data-selected"], "true");
  assert.equal(row.children[1].attributes["aria-label"], "Rename Field");
  assert.equal(row.children[2].attributes["aria-label"], "Delete Field");
  assert.equal(row.children[0].children[2].textContent, "On radio");
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
  assert.equal(detail().textContent, "4 tiles · 40.0 KiB occupied");
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
  assert.equal(view.get("selected-summary").textContent, "Field · Zoom 16–17");
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
