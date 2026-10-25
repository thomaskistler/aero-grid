// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { test } from "node:test";
import "../../docs/javascripts/map-planner.js";
import "../../docs/javascripts/map-pack.js";
import "../../docs/javascripts/map-sources.js";
import images from "../../tools/map-test-images.js";
import {
  inspectMapLibrary, mapLibrarySignatureFromAreas, pruneUnreferencedMapTiles, readMapTile,
  removeMapArea, writeMapFiles, plannedMapStorage,
} from "../../docs/javascripts/radio-map-library.mjs";

const encoder = new TextEncoder();
const tileImage = images.jpeg(globalThis.AeroGridMapPack.syntheticRgb(17, 1, 2));

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

test("map writes resolve each directory once per batch", async () => {
  const root = new MemoryDirectory("SD");
  const files = new Map();
  for (let y = 0; y < 100; y++) {
    files.set(`AEROGRID/maps/tiles/test-set/17/1/${y}.jpg`, new Uint8Array([y]));
  }
  files.set("AEROGRID/maps/areas/field.yaml", encoder.encode("test"));
  MemoryDirectory.directoryLookups = 0;
  let completed = 0;
  await writeMapFiles(root, files, (count) => { completed = count; });
  assert.equal(MemoryDirectory.directoryLookups, 7);
  assert.equal(completed, 101);
  const lookups = MemoryDirectory.directoryLookups;
  await writeMapFiles(root, files);
  assert.equal(MemoryDirectory.directoryLookups - lookups, 7);
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
      slice: (start, end) => ({ arrayBuffer: async () => this.data.slice(start, end).buffer }),
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
  static directoryLookups = 0;
  kind = "directory";
  constructor(name = "") {
    this.name = name;
    this.children = new Map();
  }
  async *entries() { yield* this.children.entries(); }
  async getDirectoryHandle(name, options = {}) {
    MemoryDirectory.directoryLookups++;
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

async function fixture() {
  const root = new MemoryDirectory("SD");
  await putArea(root, plannedSelection(ordinary, [16, 17]), "field-a");
  await putArea(root, plannedSelection(ordinary, [17]), "field-b");
  return root;
}

test("map library inventory validates app areas and counts shared tile bytes once globally", async () => {
  const root = await fixture();
  await put(root, "AEROGRID/maps/areas/._field-a.yaml", "macOS metadata");
  const result = await inspectMapLibrary(root);
  const areaA = plannedSelection(ordinary, [16, 17]);
  const areaB = plannedSelection(ordinary, [17]);
  assert.deepEqual(result.areas.map(({ id, storageBytes }) => [id, storageBytes]), [
    ["field-a", areaA.tileCount * tileImage.length],
    ["field-b", areaB.tileCount * tileImage.length],
  ]);
  assert.equal(result.tileBytes, areaA.tileCount * tileImage.length);
  assert.equal(result.referencedTiles.size, areaA.tileCount);
});

test("an empty map library returns an empty reference set", async () => {
  const library = await inspectMapLibrary(new MemoryDirectory("SD"));
  assert.deepEqual(library.areas, []);
  assert.deepEqual(library.referencedTiles, new Set());
  assert.equal(library.missingTileCount, 0);
});

async function directoryAt(root, path) {
  let directory = root;
  for (const part of path.split("/")) directory = await directory.getDirectoryHandle(part);
  return directory;
}

async function timedWriterFixture(fail = false) {
  const root = new MemoryDirectory("SD");
  let column = root;
  for (const part of ["AEROGRID", "maps", "tiles", "test-set", "17", "1"]) {
    column = await column.getDirectoryHandle(part, { create: true });
  }
  const original = column.getFileHandle.bind(column);
  const events = [];
  let active = 0;
  let maximum = 0;
  column.getFileHandle = async (name, options) => {
    const handle = await original(name, options);
    handle.createWritable = async () => {
      active++;
      maximum = Math.max(maximum, active);
      events.push(`start:${name}`);
      return {
        async write() {
          await new Promise((resolve) => setTimeout(resolve, name === "0.jpg" ? 2 : 10));
          if (fail && name === "0.jpg") throw new Error("Injected write failure");
        },
        async close() { active--; events.push(`close:${name}`); },
        async abort() { active--; events.push(`abort:${name}`); },
      };
    };
    return handle;
  };
  const files = new Map([["AEROGRID/maps/areas/field.yaml", encoder.encode("metadata")]]);
  for (let y = 0; y < 8; y++) files.set(`AEROGRID/maps/tiles/test-set/17/1/${y}.jpg`, tileImage);
  return { root, files, events, active: () => active, maximum: () => maximum };
}

test("tile writes stay sequential, reuse directories and keep metadata last", async () => {
  const fixture = await timedWriterFixture();
  const progress = [];
  MemoryDirectory.directoryLookups = 0;
  await writeMapFiles(fixture.root, fixture.files, (completed, total, path) => {
    progress.push(completed);
    assert.equal(total, 9);
    if (path.includes("/areas/")) {
      assert.equal(fixture.active(), 0);
      assert.equal(fixture.events.filter((event) => event.startsWith("close:")).length, 8);
    }
  });
  assert.equal(fixture.maximum(), 1);
  assert.equal(MemoryDirectory.directoryLookups, 7);
  assert.deepEqual(progress, [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  const before = fixture.events.length;
  await writeMapFiles(fixture.root, fixture.files);
  assert.equal(fixture.events.length, before);
});

test("tile failures abort the current write and never commit metadata", async () => {
  const fixture = await timedWriterFixture(true);
  await assert.rejects(writeMapFiles(fixture.root, fixture.files), /Injected write failure/);
  assert.equal(fixture.active(), 0);
  assert.equal(fixture.events.filter((event) => event.startsWith("start:")).length, 1);
  assert.equal(fixture.events.filter((event) => /^(close|abort):/.test(event)).length, 1);
  const maps = await directoryAt(fixture.root, "AEROGRID/maps");
  assert.equal(maps.children.has("areas"), false);
});

test("cancelling after a tile stops before the next tile and metadata", async () => {
  const fixture = await timedWriterFixture();
  const controller = new AbortController();
  let committed = false;
  await assert.rejects(writeMapFiles(fixture.root, fixture.files, () => controller.abort(), {
    signal: controller.signal,
    onCommit: () => { committed = true; },
  }), { name: "AbortError" });
  assert.equal(fixture.active(), 0);
  assert.deepEqual(fixture.events, ["start:0.jpg", "close:0.jpg"]);
  assert.equal(committed, false);
  const maps = await directoryAt(fixture.root, "AEROGRID/maps");
  assert.equal(maps.children.has("areas"), false);
});

test("writer validates the entire batch before touching the radio", async () => {
  const root = new MemoryDirectory("SD");
  await assert.rejects(writeMapFiles(root, new Map([
    ["AEROGRID/maps/tiles/test-set/17/1/2.jpg", tileImage],
    ["AEROGRID/maps/../unsafe", tileImage],
  ])), /unsafe map-library path/);
  assert.equal(root.children.size, 0);
});

test("missing shared JPEGs are references, not occupied bytes, and repair clears inventory state", async () => {
  const root = await fixture();
  const before = await inspectMapLibrary(root);
  const shared = plannedSelection(ordinary, [17]).levels[0];
  const path = `test-set/17/${shared.xRanges[0].min}/${shared.yMin}.jpg`;
  const column = await directoryAt(root, `AEROGRID/maps/tiles/test-set/17/${shared.xRanges[0].min}`);
  await column.removeEntry(`${shared.yMin}.jpg`);
  const missing = await inspectMapLibrary(root);
  assert.equal(mapLibrarySignatureFromAreas(missing.areas), mapLibrarySignatureFromAreas(before.areas));
  assert.deepEqual(missing.missingTiles, new Set([path]));
  assert.equal(missing.missingTileCount, 1);
  assert.equal(missing.tileSizes.has(path), false);
  assert.equal(missing.tileBytes, before.tileBytes - tileImage.length);
  assert.deepEqual(missing.referencedTiles, before.referencedTiles);
  assert.ok(missing.areas.every((area) => area.missingTiles.has(path) && area.missingTileCount === 1));
  assert.ok(missing.areas.every((area, index) =>
    area.storageBytes === before.areas[index].storageBytes - tileImage.length));
  const records = missing.areas.map((area) => ({ ...area }));
  assert.equal(plannedMapStorage(records, missing.tileSizes).estimated, true);
  for (const record of records) {
    record.staged = { files: new Map([[`AEROGRID/maps/tiles/${path}`, tileImage]]) };
  }
  const storage = plannedMapStorage(records, missing.tileSizes);
  assert.equal(storage.minimumBytes, before.tileBytes);
  assert.equal(storage.addedBytes, tileImage.length);
  assert.equal(storage.estimated, false);
  await writeMapFiles(root, records[0].staged.files);
  const repaired = await inspectMapLibrary(root);
  assert.equal(repaired.missingTileCount, 0);
  assert.equal(repaired.tileBytes, before.tileBytes);
  assert.ok(repaired.areas.every((area) => !area.missingTileCount));
});

test("missing tiles directory or nested directories are repairable, and missing references survive pruning", async () => {
  for (const path of ["tiles", "tiles/test-set", "tiles/test-set/17"]) {
    const root = await fixture();
    const before = await inspectMapLibrary(root);
    const parts = `AEROGRID/maps/${path}`.split("/");
    const parent = await directoryAt(root, parts.slice(0, -1).join("/"));
    await parent.removeEntry(parts.at(-1));
    const missing = await inspectMapLibrary(root);
    assert.ok(missing.missingTileCount > 0);
    assert.deepEqual(missing.referencedTiles, before.referencedTiles);
    assert.equal(missing.tileSizes.size + missing.missingTileCount, before.referencedTiles.size);
    await removeMapArea(root, "field-a");
    const remaining = await inspectMapLibrary(root);
    assert.equal(remaining.areas[0].id, "field-b");
    assert.equal(remaining.missingTileCount, remaining.areas[0].tileCount);
    await pruneUnreferencedMapTiles(root, before.referencedTiles, remaining.referencedTiles);
  }
});

test("real file preparation repairs a deleted tiles tree and overlapping areas reuse the original imagery set", async () => {
  const root = await fixture();
  const before = await inspectMapLibrary(root);
  await (await directoryAt(root, "AEROGRID/maps")).removeEntry("tiles");
  const broken = await inspectMapLibrary(root);
  assert.equal(broken.tileBytes, 0);
  assert.equal(broken.missingTileCount, before.referencedTiles.size);
  const cache = new Map();
  let reads = 0;
  const source = {
    metadata: { ...packs.SYNTHETIC, id: "test-set" },
    async readTile(zoom, x, y) {
      const key = `${zoom}/${x}/${y}`;
      if (!cache.has(key)) { reads++; cache.set(key, tileImage); }
      return cache.get(key);
    },
  };
  for (const area of broken.areas) {
    const files = await packs.createFiles(area.selection, area.id, {
      source, readExistingTile: (set, zoom, x, y) => readMapTile(root, set, zoom, x, y),
    });
    await writeMapFiles(root, new Map([...files].sort(([a], [b]) =>
      Number(a.includes("/areas/")) - Number(b.includes("/areas/")))));
  }
  assert.equal(reads, before.referencedTiles.size);
  const repaired = await inspectMapLibrary(root);
  assert.equal(repaired.missingTileCount, 0);
  assert.equal(repaired.tileBytes, before.tileBytes);
  assert.deepEqual(repaired.referencedTiles, before.referencedTiles);
  assert.ok(repaired.areas.every((area) => !area.missingTileCount && area.imagerySet === "test-set"));
});

test("only NotFound tile failures are repairable; invalid tiles and access/type errors fail explicitly", async () => {
  for (const failure of ["empty", "oversize", "corrupt", "wrong-file-kind", "wrong-directory-kind",
    "NotAllowedError", "NotReadableError", "SecurityError", "NotFoundError"]) {
    const root = await fixture();
    const level = plannedSelection(ordinary, [17]).levels[0];
    const x = level.xRanges[0].min;
    const filename = `${level.yMin}.jpg`;
    const column = await directoryAt(root, `AEROGRID/maps/tiles/test-set/17/${x}`);
    const tile = column.children.get(filename);
    if (failure === "empty") tile.data = new Uint8Array();
    else if (failure === "oversize") tile.data = new Uint8Array(256 * 1024 + 1);
    else if (failure === "corrupt") tile.data = new Uint8Array([1, 2, 3, 4]);
    else if (failure === "wrong-file-kind") column.children.set(filename, new MemoryDirectory(filename));
    else if (failure === "wrong-directory-kind") {
      (await directoryAt(root, "AEROGRID/maps")).children.set("tiles", new MemoryFile("tiles"));
    } else tile.getFile = async () => { throw new DOMException("Injected tile failure", failure); };
    if (failure === "NotFoundError") {
      assert.equal((await inspectMapLibrary(root)).missingTileCount, 1);
      assert.equal(await readMapTile(root, "test-set", 17, x, level.yMin), null);
    } else {
      await assert.rejects(inspectMapLibrary(root));
      await assert.rejects(readMapTile(root, "test-set", 17, x, level.yMin));
    }
  }
});

test("map inventory rejects saved geometry that does not match its area manifest", async () => {
  const root = await fixture();
  const selection = plannedSelection(ordinary, [16, 17]);
  const { yaml } = packs.areaManifest(selection, "field-a", "test-set");
  await put(root, "AEROGRID/maps/areas/field-a.yaml", yaml.replace(/xMax: (\d+)/, (_, x) => `xMax: ${Number(x) + 1}`));
  await assert.rejects(inspectMapLibrary(root), /selection geometry inconsistent/i);
});

test("map inventory validates date-line X ranges against canonical tile columns", async () => {
  const root = new MemoryDirectory("SD");
  const dateLine = plannedSelection(
    { south: -0.001, north: 0.001, west: 179.999, east: -179.999 }, [17], true,
  );
  await putArea(root, dateLine, "wrapped");
  const world = 2 ** 17;
  const result = await inspectMapLibrary(root);
  const ranges = result.areas.find((area) => area.id === "wrapped").selection.levels[0].xRanges;
  assert.deepEqual(ranges, [{ min: 0, max: 0 }, { min: world - 1, max: world - 1 }]);
  const y = result.areas[0].levels[0].yMin;
  assert.deepEqual(await readMapTile(root, "test-set", 17, 0, y), tileImage);
  assert.deepEqual(await readMapTile(root, "test-set", 17, world - 1, y), tileImage);
});

test("map inventory rejects X ranges that start outside the tile world", async () => {
  const root = await fixture();
  const world = 2 ** 17;
  const { yaml } = packs.areaManifest(plannedSelection(ordinary, [17]), "outside", "test-set");
  await put(root, "AEROGRID/maps/areas/outside.yaml", yaml.replace(/xMin: \d+/, `xMin: ${world}`));
  await assert.rejects(inspectMapLibrary(root), /invalid tile coordinates/i);
});

test("tile reads are optional for missing paths and writes preserve existing shared tile bytes", async () => {
  const root = await fixture();
  const level = plannedSelection(ordinary, [17]).levels[0];
  const x = level.xRanges[0].min;
  assert.deepEqual(await readMapTile(root, "test-set", 17, x, level.yMin), tileImage);
  assert.equal(await readMapTile(root, "test-set", 17, x + 100, level.yMin), null);
  await writeMapFiles(root, new Map([
    [`AEROGRID/maps/tiles/test-set/17/${x}/${level.yMin}.jpg`, new Uint8Array([9, 9])],
    [`AEROGRID/maps/tiles/test-set/17/${x + 100}/${level.yMin}.jpg`, tileImage],
  ]));
  assert.deepEqual(await readMapTile(root, "test-set", 17, x, level.yMin), tileImage);
  assert.deepEqual(await readMapTile(root, "test-set", 17, x + 100, level.yMin), tileImage);
  await assert.rejects(writeMapFiles(root, new Map([["AEROGRID/maps/../MODELS/x", new Uint8Array([1])]])), /unsafe map-library path/i);
});

test("deleting an app-created area prunes only its unshared tiles", async () => {
  const root = await fixture();
  const before = await inspectMapLibrary(root);
  const shared = plannedSelection(ordinary, [17]).levels[0];
  const old = plannedSelection(ordinary, [16]).levels[0];
  await removeMapArea(root, "field-a");
  const afterRemoval = await inspectMapLibrary(root);
  await pruneUnreferencedMapTiles(root, before.referencedTiles, afterRemoval.referencedTiles);
  const result = await inspectMapLibrary(root);
  assert.deepEqual(result.areas.map((area) => area.id), ["field-b"]);
  assert.equal(result.tileBytes, result.areas[0].selection.tileCount * tileImage.length);
  assert.deepEqual(await readMapTile(root, "test-set", 17, shared.xRanges[0].min, shared.yMin),
    tileImage);
  assert.equal(await readMapTile(root, "test-set", 16, old.xRanges[0].min, old.yMin), null);
});

test("updating format 2 coverage prunes old tiles only after checking every remaining reference", async () => {
  const root = await fixture();
  const previous = await inspectMapLibrary(root);
  const selection = plannedSelection(ordinary, [17]);
  const { yaml } = packs.areaManifest(selection, "field-a", "test-set");
  await writeMapFiles(root, new Map([
    ["AEROGRID/maps/areas/field-a.yaml", encoder.encode(yaml)],
  ]));
  const updated = await inspectMapLibrary(root);
  await pruneUnreferencedMapTiles(root, previous.referencedTiles, updated.referencedTiles);
  const common = selection.levels[0];
  const old = plannedSelection(ordinary, [16]).levels[0];
  assert.deepEqual(await readMapTile(root, "test-set", 17, common.xRanges[0].min, common.yMin),
    tileImage);
  assert.equal(await readMapTile(root, "test-set", 16, old.xRanges[0].min, old.yMin), null);
});

const planner = globalThis.AeroGridMapPlanner;
const packs = globalThis.AeroGridMapPack;
const ordinary = { south: 25.997, north: 25.998, west: -97.158, east: -97.157 };
function plannedSelection(bounds = ordinary, zooms = [16, 17], compact = false, radio = "tx16s") {
  const coverage = planner.coveragePlan(bounds, zooms, radio, compact);
  return { ...planner.specification('Field: "north" #1\nFlight area', coverage.bounds, zooms, radio, coverage),
    selectedBounds: bounds, coverageMode: compact ? "per-zoom-clamped" : "full-area-clamped" };
}

async function putArea(root, selection, id = "field") {
  const { manifest, yaml } = packs.areaManifest(selection, id, "test-set");
  await put(root, `AEROGRID/maps/areas/${id}.yaml`, yaml);
  for (const level of manifest.levels) {
    for (let x = level.xMin; x <= level.xMax; x++) {
      for (let y = level.yMin; y <= level.yMax; y++) {
        await put(root, `AEROGRID/maps/tiles/test-set/${level.zoom}/${x % 2 ** level.zoom}/${y}.jpg`,
          tileImage);
      }
    }
  }
  return yaml;
}

test("format 2 reconstructs exact original selection and per-zoom geometry without any sidecars", async () => {
  for (const [bounds, zooms, compact, radio] of [
    [ordinary, [16, 17], false, "tx16s"],
    [ordinary, [15, 16, 17, 18], true, "tx15"],
    [{ south: -0.001, north: 0.001, west: 179.999, east: -179.999 }, [16, 17], true, "nv14"],
    [{ south: 85.0509, north: 85.0511, west: 10, east: 10.001 }, [17], false, "tx16s-mk3"],
    [{ south: 0, north: 0.00001, west: 1, east: 1.00001 }, [11, 12, 13, 14, 15, 16, 17, 18, 19], true, "mono-128x64"],
  ]) {
    const root = new MemoryDirectory("SD");
    const selection = plannedSelection(bounds, zooms, compact, radio);
    await putArea(root, selection);
    const { areas, referencedTiles } = await inspectMapLibrary(root);
    assert.equal(areas[0].version, 2);
    assert.deepEqual(areas[0].selection, selection);
    assert.equal(areas[0].sourceMetadata, undefined);
    assert.equal(referencedTiles.size, selection.tileCount);
  }
});

test("exported format 2 files can be written, reloaded, renamed and deleted with shared tiles intact", async () => {
  const root = new MemoryDirectory("SD");
  const original = plannedSelection();
  const image = images.jpeg(packs.syntheticRgb(17, 1, 2));
  const source = { metadata: packs.SYNTHETIC, readTile: async () => image };
  const first = await packs.createFiles(original, "first", { source });
  await writeMapFiles(root, first);
  await writeMapFiles(root, await packs.createFiles(original, "second", { source }));
  const before = await inspectMapLibrary(root);
  assert.equal(before.areas.length, 2);
  assert.deepEqual(before.areas[0].selection, original);
  assert.equal(before.tileBytes, image.length * original.tileCount);
  const renamed = { ...plannedSelection(ordinary, [16]), name: "Renamed: #field\nline 2" };
  const metadata = packs.areaManifest(renamed, "first", packs.SYNTHETIC.id);
  await writeMapFiles(root, new Map([["AEROGRID/maps/areas/first.yaml", encoder.encode(metadata.yaml)]]));
  const updated = await inspectMapLibrary(root);
  assert.deepEqual(updated.areas[0].selection, renamed);
  await pruneUnreferencedMapTiles(root, before.referencedTiles, updated.referencedTiles);
  assert.equal((await inspectMapLibrary(root)).tileBytes, before.tileBytes);
  const beforeDelete = await inspectMapLibrary(root);
  await removeMapArea(root, "first");
  const afterFirstDelete = await inspectMapLibrary(root);
  await pruneUnreferencedMapTiles(root, beforeDelete.referencedTiles, afterFirstDelete.referencedTiles);
  assert.equal((await inspectMapLibrary(root)).tileBytes, before.tileBytes);
  const beforeLastDelete = await inspectMapLibrary(root);
  await removeMapArea(root, "second");
  const afterLastDelete = await inspectMapLibrary(root);
  await pruneUnreferencedMapTiles(root, beforeLastDelete.referencedTiles, afterLastDelete.referencedTiles);
  const after = await inspectMapLibrary(root);
  assert.equal(after.areas.length, 0);
  assert.equal(after.tileBytes, 0);
  const maps = await (await root.getDirectoryHandle("AEROGRID")).getDirectoryHandle("maps");
  assert.deepEqual([...maps.children.keys()].sort(), ["areas", "tiles"]);
});

test("format 2 rejects malformed YAML, unsupported fields and planner-inconsistent geometry", async () => {
  const original = plannedSelection();
  const { yaml } = packs.areaManifest(original, "field", "test-set");
  for (const mutate of [
    text => text + 'name: "duplicate"\n',
    text => text + "ignored: true\n",
    text => text + "  invalid nesting\n",
    text => text.replace('name: "Field:', 'name: !unsafe "Field:'),
    text => text.replace('name: "Field:', 'name: &alias "Field:'),
    text => text.replace(/name: .+/, 'name: "broken\\q"'),
    text => text.replace(/name: .+/, "name: |\n  multiline"),
    text => text.replace(/    west: .+/, "    west: .nan"),
    text => text.replace(/    west: .+/, "    west: 190"),
    text => text.replace(/    east: .+\n/, "").replace(/(  radio: .+\n)/, "$1    east: -97.157\n"),
    text => text.replace(/    north: .+/, "    north: 30"),
    text => text.replace(/  radio: .+/, '  radio: "unsupported"'),
    text => text.replace(/  coverageMode: .+/, '  coverageMode: "unknown"'),
    text => text.replace(/    xMax: (\d+)/, (_, x) => `    xMax: ${Number(x) + 1}`),
    text => text.replace(/    yMin: .+/, "    yMin: -1"),
    text => text.replace(/    yMax: .+/, "    yMax: 9007199254740992"),
    text => text.replace("version: 2", "version: 3"),
    text => text.replace(/imagerySet: .+/, "imagerySet: 123"),
    text => text.replace("levels:", "levels:\n  unexpected: 1"),
    text => text.replace(/name: .+/, `name: "${"a".repeat(81)}"`),
    text => text + "#".repeat(8192),
  ]) {
    const root = new MemoryDirectory("SD");
    await putArea(root, original);
    await put(root, "AEROGRID/maps/areas/field.yaml", mutate(yaml));
    await assert.rejects(inspectMapLibrary(root));
  }
});

test("map writer accepts only area YAML and tile files", async () => {
  for (const path of ["selections/field.json", "sources/test-set.json"]) {
    const root = new MemoryDirectory("SD");
    await assert.rejects(writeMapFiles(root, new Map([[`AEROGRID/maps/${path}`, encoder.encode("{}")]])),
      /unsafe map-library path/);
    assert.equal(root.children.size, 0);
  }
});

test("only format 2 area manifests are accepted", async () => {
  const root = new MemoryDirectory("SD");
  await root.getDirectoryHandle("AEROGRID", { create: true })
    .then(directory => directory.getDirectoryHandle("maps", { create: true }))
    .then(maps => maps.getDirectoryHandle("tiles", { create: true }));
  await put(root, "AEROGRID/maps/areas/old.yaml", [
    'format: "aerogrid-map-area"', "version: 1", 'id: "old"',
    'imagerySet: "test-set"', 'projection: "EPSG:3857"', 'tileScheme: "XYZ"',
    "tileSize: 256", 'imageFormat: "jpeg"', "levels:", "  - zoom: 17",
    "    xMin: 1", "    xMax: 1", "    yMin: 2", "    yMax: 2", "",
  ].join("\n"));
  await assert.rejects(inspectMapLibrary(root), /does not use the supported AeroGrid map format/i);
});
