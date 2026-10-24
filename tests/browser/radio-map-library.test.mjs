// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  inspectMapLibrary, pruneUnreferencedMapTiles, readMapTile, removeMapArea, writeMapFiles, plannedMapStorage,
} from "../../docs/javascripts/radio-map-library.mjs";

const encoder = new TextEncoder();

test("projected storage counts shared tiles once and includes edits, deletions, and prepared bytes", () => {
  const record = (xMin, xMax, extra = {}) => ({
    imagerySet: "test-set",
    selection: { levels: [{ zoom: 17, xRanges: [{ min: xMin, max: xMax }], yMin: 2, yMax: 2 }] },
    ...extra,
  });
  const stored = new Map([["test-set/17/1/2.jpg", 100], ["test-set/17/2/2.jpg", 200]]);
  assert.deepEqual(plannedMapStorage([record(1, 2), record(1, 1)], stored), {
    minimumBytes: 300, maximumBytes: 300, estimated: false, addedBytes: 0, removedBytes: 0,
  });
  assert.deepEqual(plannedMapStorage([record(1, 2, { deleted: true }), record(1, 1)], stored), {
    minimumBytes: 100, maximumBytes: 100, estimated: false, addedBytes: 0, removedBytes: 200,
  });
  assert.deepEqual(plannedMapStorage([record(1, 2, { deleted: true })], stored), {
    minimumBytes: 0, maximumBytes: 0, estimated: false, addedBytes: 0, removedBytes: 300,
  });
  assert.deepEqual(plannedMapStorage([record(1, 3), record(3, 3)], stored), {
    minimumBytes: 300 + 10240, maximumBytes: 300 + 30720, estimated: true, addedBytes: 0, removedBytes: 0,
  });
  assert.deepEqual(plannedMapStorage([record(1, 3, {
    staged: { files: new Map([["AEROGRID/maps/tiles/test-set/17/3/2.jpg", new Uint8Array(50)]]) },
  }), record(3, 3)], stored), {
    minimumBytes: 350, maximumBytes: 350, estimated: false, addedBytes: 50, removedBytes: 0,
  });
  assert.deepEqual(plannedMapStorage([
    record(1, 1), record(1, 1, { imagerySet: "different-set" }),
  ], stored), { minimumBytes: 100 + 10240, maximumBytes: 100 + 30720, estimated: true, addedBytes: 0, removedBytes: 200 });
});

class MemoryFile {
  kind = "file";
  constructor(name, data = new Uint8Array()) {
    this.name = name;
    this.data = data instanceof Uint8Array ? data : encoder.encode(data);
  }
  async getFile() {
    return {
      size: this.data.length,
      arrayBuffer: async () => this.data.slice().buffer,
      text: async () => new TextDecoder().decode(this.data),
    };
  }
  async createWritable() {
    return {
      write: async (bytes) => { this.data = new Uint8Array(bytes); },
      close: async () => {},
      abort: async () => {},
    };
  }
}

class MemoryDirectory {
  kind = "directory";
  constructor(name = "") {
    this.name = name;
    this.children = new Map();
  }
  async *entries() { yield* this.children.entries(); }
  async getDirectoryHandle(name, options = {}) {
    let entry = this.children.get(name);
    if (!entry && options.create) {
      entry = new MemoryDirectory(name);
      this.children.set(name, entry);
    }
    if (!entry) throw new DOMException("Missing directory", "NotFoundError");
    if (entry.kind !== "directory") throw new DOMException("Wrong kind", "TypeMismatchError");
    return entry;
  }
  async getFileHandle(name, options = {}) {
    let entry = this.children.get(name);
    if (!entry && options.create) {
      entry = new MemoryFile(name);
      this.children.set(name, entry);
    }
    if (!entry) throw new DOMException("Missing file", "NotFoundError");
    if (entry.kind !== "file") throw new DOMException("Wrong kind", "TypeMismatchError");
    return entry;
  }
  async removeEntry(name) {
    if (!this.children.delete(name)) throw new DOMException("Missing entry", "NotFoundError");
  }
}

async function put(root, path, value) {
  const parts = path.split("/");
  let directory = root;
  for (const part of parts.slice(0, -1)) directory = await directory.getDirectoryHandle(part, { create: true });
  directory.children.set(parts.at(-1), new MemoryFile(parts.at(-1), value));
}

function manifest(id, xMin, xMax) {
  return [
    'format: "aerogrid-map-area"', "version: 1", `id: "${id}"`,
    'imagerySet: "test-set"', 'projection: "EPSG:3857"', 'tileScheme: "XYZ"',
    "tileSize: 256", 'imageFormat: "jpeg"', "levels:", "  - zoom: 17",
    `    xMin: ${xMin}`, `    xMax: ${xMax}`, "    yMin: 2", "    yMax: 2", "",
  ].join("\n");
}

function selection(id, xMin, xMax) {
  const tileCount = xMax - xMin + 1;
  const world = 2 ** 17;
  const xRanges = xMax < world
    ? [{ min: xMin, max: xMax }]
    : [{ min: 0, max: xMax - world }, { min: xMin, max: world - 1 }];
  return JSON.stringify({
    format: "aerogrid-map-selection",
    version: 1,
    name: id,
    radio: { id: "tx16s" },
    selectedBounds: { south: 0, north: 1, west: 0, east: 1 },
    bounds: { south: 0, north: 1, west: 0, east: 1 },
    levels: [{
      zoom: 17,
      xRanges,
      yMin: 2,
      yMax: 2,
      tiles: tileCount,
    }],
    tileCount,
    coverageMode: "full-area-clamped",
  });
}

async function fixture() {
  const root = new MemoryDirectory("SD");
  await put(root, "AEROGRID/maps/areas/field-a.yaml", manifest("field-a", 1, 2));
  await put(root, "AEROGRID/maps/areas/field-b.yaml", manifest("field-b", 1, 1));
  await put(root, "AEROGRID/maps/selections/field-a.json", selection("Field A", 1, 2));
  await put(root, "AEROGRID/maps/selections/field-b.json", selection("Field B", 1, 1));
  await put(root, "AEROGRID/maps/sources/test-set.json", JSON.stringify({
    id: "test-set", source: "Test source", edition: "v1", conversion: "jpeg-v1",
    license: "test", attribution: "test", synthetic: true,
  }));
  await put(root, "AEROGRID/maps/tiles/test-set/17/1/2.jpg", new Uint8Array([1, 2, 3, 4]));
  await put(root, "AEROGRID/maps/tiles/test-set/17/2/2.jpg", new Uint8Array([5, 6, 7, 8]));
  return root;
}

test("map library inventory validates app areas and counts shared tile bytes once globally", async () => {
  const root = await fixture();
  await put(root, "AEROGRID/maps/areas/._field-a.yaml", "macOS metadata");
  const result = await inspectMapLibrary(root);
  assert.deepEqual(result.areas.map(({ id, storageBytes }) => [id, storageBytes]), [
    ["field-a", 8],
    ["field-b", 4],
  ]);
  assert.equal(result.tileBytes, 8);
  assert.equal(result.referencedTiles.size, 2);
});

test("an empty map library returns an empty reference set", async () => {
  const library = await inspectMapLibrary(new MemoryDirectory("SD"));
  assert.deepEqual(library.areas, []);
  assert.deepEqual(library.referencedTiles, new Set());
});

test("map inventory rejects saved geometry that does not match its area manifest", async () => {
  const root = await fixture();
  await put(root, "AEROGRID/maps/selections/field-a.json", selection("Field A", 1, 1));
  await assert.rejects(inspectMapLibrary(root), /unsupported saved selection metadata/i);
});

test("map inventory validates date-line X ranges against canonical tile columns", async () => {
  const root = await fixture();
  const world = 2 ** 17;
  await put(root, "AEROGRID/maps/areas/wrapped.yaml", manifest("wrapped", world - 1, world));
  await put(root, "AEROGRID/maps/selections/wrapped.json", selection("Wrapped", world - 1, world));
  await put(root, `AEROGRID/maps/tiles/test-set/17/${world - 1}/2.jpg`, new Uint8Array([8, 8]));
  await put(root, "AEROGRID/maps/tiles/test-set/17/0/2.jpg", new Uint8Array([9, 9]));
  const result = await inspectMapLibrary(root);
  assert.deepEqual(result.areas.find((area) => area.id === "wrapped").selection.levels[0].xRanges, [
    { min: 0, max: 0 },
    { min: world - 1, max: world - 1 },
  ]);
  assert.deepEqual(await readMapTile(root, "test-set", 17, 0, 2), new Uint8Array([9, 9]));
});

test("map inventory rejects X ranges that start outside the tile world", async () => {
  const root = await fixture();
  const world = 2 ** 17;
  await put(root, "AEROGRID/maps/areas/outside.yaml", manifest("outside", world, world));
  await put(root, "AEROGRID/maps/selections/outside.json", selection("Outside", world, world));
  await assert.rejects(inspectMapLibrary(root), /invalid tile coordinates/i);
});

test("tile reads are optional for missing paths and writes preserve existing shared tile bytes", async () => {
  const root = await fixture();
  assert.deepEqual(await readMapTile(root, "test-set", 17, 1, 2), new Uint8Array([1, 2, 3, 4]));
  assert.equal(await readMapTile(root, "test-set", 17, 3, 2), null);
  await writeMapFiles(root, new Map([
    ["AEROGRID/maps/tiles/test-set/17/1/2.jpg", new Uint8Array([9, 9])],
    ["AEROGRID/maps/tiles/test-set/17/3/2.jpg", new Uint8Array([7, 7])],
  ]));
  assert.deepEqual(await readMapTile(root, "test-set", 17, 1, 2), new Uint8Array([1, 2, 3, 4]));
  assert.deepEqual(await readMapTile(root, "test-set", 17, 3, 2), new Uint8Array([7, 7]));
  await assert.rejects(writeMapFiles(root, new Map([["AEROGRID/maps/../MODELS/x", new Uint8Array([1])]])), /unsafe map-library path/i);
});

test("deleting an app-created area prunes only its unshared tiles", async () => {
  const root = await fixture();
  await removeMapArea(root, "field-a");
  const result = await inspectMapLibrary(root);
  assert.deepEqual(result.areas.map((area) => area.id), ["field-b"]);
  assert.equal(result.tileBytes, 4);
  assert.deepEqual(await readMapTile(root, "test-set", 17, 1, 2), new Uint8Array([1, 2, 3, 4]));
  assert.equal(await readMapTile(root, "test-set", 17, 2, 2), null);
});

test("updating area coverage prunes old tiles only after checking every remaining reference", async () => {
  const root = await fixture();
  const previous = await inspectMapLibrary(root);
  await writeMapFiles(root, new Map([
    ["AEROGRID/maps/areas/field-a.yaml", encoder.encode(manifest("field-a", 1, 1))],
    ["AEROGRID/maps/selections/field-a.json", encoder.encode(selection("Field A", 1, 1))],
  ]));
  const updated = await inspectMapLibrary(root);
  await pruneUnreferencedMapTiles(root, previous.referencedTiles, updated.referencedTiles);
  assert.deepEqual(await readMapTile(root, "test-set", 17, 1, 2), new Uint8Array([1, 2, 3, 4]));
  assert.equal(await readMapTile(root, "test-set", 17, 2, 2), null);
});
