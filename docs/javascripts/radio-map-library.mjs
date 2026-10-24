// SPDX-License-Identifier: GPL-2.0-only
import { child } from "./radio-storage.mjs";

const MAX_AREAS = 64;
const MAX_AREA_BYTES = 8 * 1024;
const MAX_TILE_BYTES = 256 * 1024;
const MAX_AREA_DIRECTORY_ENTRIES = 256;
const MAX_LIBRARY_TILES = 100_000;
const ID = /^[a-z0-9_-]{1,32}$/;

// Deliberately accept only the exporter schema, not general YAML (tags, aliases,
// flow collections, block scalars or implicit scalar coercion).
function areaDocument(text) {
  const result = Object.create(null);
  let scope = result;
  let section = "";
  let subsection = "";
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    if (!line.trim()) continue;
    const match = /^( *)(- )?([A-Za-z][A-Za-z0-9]*):(?: (.+))?$/.exec(line);
    if (!match) throw new Error("Unsupported map YAML syntax.");
    const [, spaces, item, key, raw] = match;
    const depth = spaces.length;
    if (!depth && !item) {
      scope = result;
      section = key;
      subsection = "";
    } else if (section === "selection" && !item && depth === 2) {
      scope = result.selection;
      subsection = key;
    } else if (section === "selection" && subsection === "bounds" && !item && depth === 4) {
      scope = result.selection?.bounds;
    } else if (section === "levels" && depth === 2 && item && key === "zoom") {
      scope = Object.create(null);
      result.levels.push(scope);
    } else if (!(section === "levels" && depth === 4 && !item && scope !== result)) {
      throw new Error("Unsupported map YAML nesting.");
    }
    if (!scope || Object.hasOwn(scope, key)) throw new Error(`Duplicate or invalid map YAML field: ${key}.`);
    if (raw === undefined) {
      if (!depth && key === "levels") scope[key] = [];
      else if ((!depth && key === "selection") || (depth === 2 && key === "bounds")) {
        scope[key] = Object.create(null);
      } else throw new Error("Unsupported map YAML section.");
    } else if (raw.startsWith('"')) {
      scope[key] = JSON.parse(raw);
      if (typeof scope[key] !== "string") throw new Error("Invalid map YAML string.");
    } else if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(raw)) {
      scope[key] = Number(raw);
    } else if (/^[A-Za-z][A-Za-z0-9_:.-]*$/.test(raw)) {
      scope[key] = raw;
    } else throw new Error("Unsupported map YAML scalar.");
  }
  return result;
}

function exactKeys(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key))) {
    throw new Error("Unsupported map YAML fields.");
  }
}

function parseArea(text, expectedId) {
  if (typeof text !== "string" || new TextEncoder().encode(text).length > MAX_AREA_BYTES) {
    throw new Error(`Map area ${expectedId} has an invalid or oversized manifest.`);
  }
  const document = areaDocument(text);
  const scalar = (key) => document[key];
  const id = scalar("id");
  const imagerySet = scalar("imagerySet");
  const version = scalar("version");
  if (scalar("format") !== "aerogrid-map-area" || version !== 2) {
    throw new Error(`Map area ${expectedId} does not use the supported AeroGrid map format.`);
  }
  exactKeys(document, ["format", "version", "id", "name", "imagerySet", "projection", "tileScheme",
    "tileSize", "imageFormat", "selection", "levels"]);
  if (id !== expectedId || !ID.test(id) || typeof imagerySet !== "string" || !ID.test(imagerySet)
      || scalar("projection") !== "EPSG:3857" || scalar("tileScheme") !== "XYZ"
      || scalar("tileSize") !== 256 || scalar("imageFormat") !== "jpeg") {
    throw new Error(`Map area ${expectedId} does not use the supported AeroGrid map format.`);
  }
  const levels = document.levels;
  if (!Array.isArray(levels) || !levels.length || levels.length > 9) {
    throw new Error(`Map area ${expectedId} has invalid zoom coverage.`);
  }
  for (const [index, level] of levels.entries()) {
    exactKeys(level, ["zoom", "xMin", "xMax", "yMin", "yMax"]);
    const world = 2 ** level.zoom;
    if (!Number.isInteger(level.zoom) || level.zoom < 11 || level.zoom > 19
        || (index && levels[index - 1].zoom >= level.zoom)
        || ![level.xMin, level.xMax, level.yMin, level.yMax].every(Number.isInteger)
        || level.xMin < 0 || level.xMin >= world || level.xMax < level.xMin
        || level.xMax >= level.xMin + world - 1
        || level.yMin < 0 || level.yMax < level.yMin || level.yMax >= world) {
      throw new Error(`Map area ${expectedId} has invalid tile coordinates.`);
    }
  }
  const tileCount = levels.reduce((total, level) =>
    total + (level.xMax - level.xMin + 1) * (level.yMax - level.yMin + 1), 0);
  if (tileCount > 2000 || levels.some((level, index) =>
    index && level.zoom !== levels[index - 1].zoom + 1)) {
    throw new Error(`Map area ${expectedId} exceeds the supported coverage contract.`);
  }
  exactKeys(document.selection, ["bounds", "radio", "coverageMode"]);
  exactKeys(document.selection.bounds, ["west", "south", "east", "north"]);
  const saved = document.selection;
  if (typeof document.name !== "string" || !document.name || document.name !== document.name.trim()
      || document.name.length > 80 || typeof saved.radio !== "string" || !validBounds(saved.bounds)
      || !["full-area-clamped", "per-zoom-clamped"].includes(saved.coverageMode)) {
    throw new Error(`Map area ${id} has unsupported saved selection metadata.`);
  }
  const planner = globalThis.AeroGridMapPlanner;
  if (!planner) throw new Error("The map planner must be loaded before inspecting format 2 areas.");
  const zooms = levels.map(level => level.zoom);
  const coverage = planner.coveragePlan(saved.bounds, zooms, saved.radio,
    saved.coverageMode === "per-zoom-clamped");
  if (!selectionLevelsMatch(coverage.levels, levels) || coverage.tileCount !== tileCount) {
    throw new Error(`Map area ${id} has selection geometry inconsistent with its runtime coverage.`);
  }
  const selection = { ...planner.specification(document.name, coverage.bounds, zooms, saved.radio, coverage),
    selectedBounds: { ...saved.bounds }, coverageMode: saved.coverageMode };
  return { version, id, imagerySet, levels, tileCount, selection };
}

function selectionLevelsMatch(selectionLevels, manifestLevels) {
  if (!Array.isArray(selectionLevels) || selectionLevels.length !== manifestLevels.length) return false;
  return selectionLevels.every((selection, index) => {
    if (!selection || typeof selection !== "object" || !Array.isArray(selection.xRanges)) return false;
    const manifest = manifestLevels[index];
    const world = 2 ** manifest.zoom;
    const ranges = manifest.xMax < world
      ? [{ min: manifest.xMin, max: manifest.xMax }]
      : [
        { min: 0, max: manifest.xMax - world },
        { min: manifest.xMin, max: world - 1 },
      ];
    const tileCount = ranges.reduce((total, range) => total + range.max - range.min + 1, 0)
      * (manifest.yMax - manifest.yMin + 1);
    return selection.zoom === manifest.zoom
      && selection.yMin === manifest.yMin
      && selection.yMax === manifest.yMax
      && selection.tiles === tileCount
      && JSON.stringify(selection.xRanges) === JSON.stringify(ranges);
  });
}

function validBounds(bounds) {
  return !!bounds && [bounds.south, bounds.north, bounds.west, bounds.east].every(Number.isFinite)
    && bounds.south >= -85.0511287798066 && bounds.north <= 85.0511287798066
    && bounds.south < bounds.north && bounds.west >= -180 && bounds.west <= 180
    && bounds.east >= -180 && bounds.east <= 180 && bounds.west !== bounds.east;
}

async function readFile(directory, name, limit) {
  const handle = await child(directory, name, "file");
  const file = await handle.getFile();
  if (file.size > limit) throw new Error(`${name} exceeds the supported map metadata size.`);
  return file.text();
}

async function validateTile(file, name) {
  if (!file.size || file.size > MAX_TILE_BYTES) {
    throw new Error(`${name} is empty or exceeds the 256 KiB map tile limit.`);
  }
  // Inventory needs only the bounded JPEG header and end marker, not all pixels.
  let bytes;
  if (file.size > 4096 && file.slice) {
    bytes = new Uint8Array(4098);
    bytes.set(new Uint8Array(await file.slice(0, 4096).arrayBuffer()));
    bytes.set(new Uint8Array(await file.slice(-2).arrayBuffer()), 4096);
  } else bytes = new Uint8Array(await file.arrayBuffer());
  if (!globalThis.AeroGridMapSources.compatibleJpeg(bytes)) {
    throw new Error(`${name} is not a compatible 256x256 JPEG.`);
  }
}

async function fileSize(directory, name) {
  try {
    const handle = directory && await child(directory, name, "file", true);
    if (!handle) return null;
    const file = await handle.getFile();
    await validateTile(file, name);
    return file.size;
  } catch (error) {
    if (error.name === "NotFoundError") return null;
    throw error;
  }
}

async function optionalDirectory(parent, name) {
  if (!parent) return null;
  try {
    return await child(parent, name, "directory", true);
  } catch (error) {
    if (error.name === "NotFoundError") return null;
    throw error;
  }
}

export async function inspectMapLibrary(root) {
  const maps = await optionalDirectory(root, "AEROGRID")
    .then((aerogrid) => optionalDirectory(aerogrid, "maps"));
  const empty = () => ({
    areas: [], tileBytes: 0, referencedTiles: new Set(), tileSizes: new Map(),
    missingTiles: new Set(), missingTileCount: 0,
  });
  if (!maps) return empty();
  const areasDirectory = await optionalDirectory(maps, "areas");
  const tilesDirectory = await optionalDirectory(maps, "tiles");
  if (!areasDirectory) return empty();

  const areaFiles = [];
  let directoryEntries = 0;
  for await (const [name, handle] of areasDirectory.entries()) {
    if (++directoryEntries > MAX_AREA_DIRECTORY_ENTRIES) {
      throw new Error("The AeroGrid areas directory exceeds 256 entries.");
    }
    if (name.startsWith("._")) continue;
    if (handle.kind !== "file" || !name.endsWith(".yaml")) continue;
    if (areaFiles.length >= MAX_AREAS) throw new Error("The radio contains more than 64 AeroGrid map areas.");
    const id = name.slice(0, -5);
    if (!ID.test(id)) throw new Error(`Unsupported AeroGrid map area filename: ${name}.`);
    areaFiles.push(id);
  }

  const areas = [];
  const referencedTiles = new Set();
  const tileSizes = new Map();
  const missingTiles = new Set();
  const tileDirectories = new Map();
  for (const id of areaFiles.sort()) {
    const manifest = parseArea(await readFile(areasDirectory, `${id}.yaml`, MAX_AREA_BYTES), id);
    let bytes = 0;
    const areaTiles = new Set();
    const areaMissingTiles = new Set();
    for (const level of manifest.levels) {
      for (let x = level.xMin; x <= level.xMax; x++) {
        const canonicalX = x % (2 ** level.zoom);
        let parent = tilesDirectory;
        let directoryPath = "";
        for (const part of [manifest.imagerySet, String(level.zoom), String(canonicalX)]) {
          directoryPath += `/${part}`;
          if (!tileDirectories.has(directoryPath)) {
            tileDirectories.set(directoryPath, await optionalDirectory(parent, part));
          }
          parent = tileDirectories.get(directoryPath);
        }
        const xDirectory = parent;
        for (let y = level.yMin; y <= level.yMax; y++) {
          const tilePath = `${manifest.imagerySet}/${level.zoom}/${canonicalX}/${y}.jpg`;
          if (!areaTiles.has(tilePath)) {
            if (!referencedTiles.has(tilePath) && referencedTiles.size >= MAX_LIBRARY_TILES) {
              throw new Error("The radio map library references more than 100,000 unique tiles.");
            }
            if (!referencedTiles.has(tilePath)) {
              const size = await fileSize(xDirectory, `${y}.jpg`);
              if (size === null) missingTiles.add(tilePath);
              else tileSizes.set(tilePath, size);
              referencedTiles.add(tilePath);
            }
            areaTiles.add(tilePath);
            if (missingTiles.has(tilePath)) areaMissingTiles.add(tilePath);
            else bytes += tileSizes.get(tilePath);
          }
        }
      }
    }
    areas.push({ ...manifest, storageBytes: bytes,
      missingTiles: areaMissingTiles, missingTileCount: areaMissingTiles.size });
  }
  return {
    areas,
    tileBytes: [...tileSizes.values()].reduce((total, size) => total + size, 0),
    referencedTiles, tileSizes, missingTiles, missingTileCount: missingTiles.size,
  };
}

export function* mapSelectionTiles(imagerySet, selection) {
  for (const level of selection.levels) {
    for (const range of level.xRanges) {
      for (let x = range.min; x <= range.max; x++) {
        for (let y = level.yMin; y <= level.yMax; y++) {
          yield `${imagerySet}/${level.zoom}/${x % (2 ** level.zoom)}/${y}.jpg`;
        }
      }
    }
  }
}

export function plannedMapStorage(records, storedTileSizes) {
  const sizes = new Map(storedTileSizes);
  const selectedTiles = new Set();
  for (const record of records) {
    if (record.deleted) continue;
    const imagerySet = record.imagerySet || "new-capture";
    if (record.staged) {
      for (const [path, bytes] of record.staged.files) {
        const prefix = "AEROGRID/maps/tiles/";
        if (path.startsWith(prefix)) sizes.set(path.slice(prefix.length), bytes.length);
      }
    }
    for (const path of mapSelectionTiles(imagerySet, record.selection)) selectedTiles.add(path);
  }
  let knownBytes = 0;
  let unknownTiles = 0;
  for (const path of selectedTiles) {
    if (sizes.has(path)) knownBytes += sizes.get(path);
    else unknownTiles++;
  }
  return {
    minimumBytes: knownBytes + unknownTiles * 10 * 1024,
    maximumBytes: knownBytes + unknownTiles * 30 * 1024,
    estimated: unknownTiles > 0,
    addedBytes: [...selectedTiles].reduce((total, path) =>
      total + (storedTileSizes.has(path) ? 0 : sizes.get(path) ?? 0), 0),
    removedBytes: [...storedTileSizes].reduce((total, [path, bytes]) =>
      total + (selectedTiles.has(path) ? 0 : bytes), 0),
  };
}

export async function readMapTile(root, imagerySet, zoom, x, y) {
  if (!ID.test(imagerySet) || ![zoom, x, y].every(Number.isInteger)
      || zoom < 0 || zoom > 20 || x < 0 || y < 0) {
    throw new Error("Invalid map tile path.");
  }
  try {
    const aerogrid = await optionalDirectory(root, "AEROGRID");
    const maps = await optionalDirectory(aerogrid, "maps");
    const tiles = await optionalDirectory(maps, "tiles");
    const set = await optionalDirectory(tiles, imagerySet);
    const zoomDirectory = await optionalDirectory(set, String(zoom));
    const column = await optionalDirectory(zoomDirectory, String(x));
    const handle = column && await child(column, `${y}.jpg`, "file", true);
    if (!handle) return null;
    const file = await handle.getFile();
    if (!file.size || file.size > MAX_TILE_BYTES) throw new Error("Saved map tile is empty or oversized.");
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!globalThis.AeroGridMapSources.compatibleJpeg(bytes)) {
      throw new Error("Saved map tile is not a compatible 256x256 JPEG.");
    }
    return bytes;
  } catch (error) {
    if (error.name === "NotFoundError") return null;
    throw error;
  }
}

export function mapLibrarySignatureFromAreas(areas) {
  return JSON.stringify(areas.map((area) => [
    area.id, area.imagerySet, area.selection,
  ]));
}

export async function mapLibrarySignature(root) {
  const { areas } = await inspectMapLibrary(root);
  return mapLibrarySignatureFromAreas(areas);
}

async function directoryFor(root, path, cache) {
  let directory = root;
  let key = "";
  for (const part of path) {
    key += `/${part}`;
    if (!cache.has(key)) {
      cache.set(key, await directory.getDirectoryHandle(part, { create: true }));
    }
    directory = cache.get(key);
  }
  return directory;
}

export async function writeMapFiles(root, files, onProgress = () => {}, options = {}) {
  const checkCancelled = () => {
    if (options.signal?.aborted) throw new DOMException("Map sync cancelled.", "AbortError");
  };
  const entries = [...files.entries()];
  for (const [path, bytes] of entries) {
    const parts = path.split("/");
    const zoom = Number(parts[4]);
    const x = Number(parts[5]);
    const y = Number(parts[6]?.slice(0, -4));
    const metadataPath = parts.length === 4 && parts[2] === "areas"
      && /^[a-z0-9_-]{1,32}\.yaml$/.test(parts[3]);
    const tilePath = parts.length === 7 && parts[2] === "tiles"
      && ID.test(parts[3]) && /^(1[1-9])$/.test(parts[4])
      && /^\d+$/.test(parts[5]) && /^\d+\.jpg$/.test(parts[6])
      && Number.isSafeInteger(x) && Number.isSafeInteger(y)
      && x < 2 ** zoom && y < 2 ** zoom;
    if (parts[0] !== "AEROGRID" || parts[1] !== "maps" || parts.length < 4
        || parts.some((part) => !/^[A-Za-z0-9_.-]+$/.test(part) || part === "." || part === "..")
        || (!metadataPath && !tilePath)
        || !(bytes instanceof Uint8Array)) {
      throw new Error(`Refusing unsafe map-library path: ${path}.`);
    }
  }
  const directories = new Map();
  let completed = 0;
  async function writeEntry([path, bytes]) {
    const parts = path.split("/");
    const directory = await directoryFor(root, parts.slice(0, -1), directories);
    let handle;
    if (parts[2] === "tiles") {
      try {
        handle = await directory.getFileHandle(parts.at(-1));
      } catch (error) {
        if (error.name !== "NotFoundError") throw error;
      }
      if (handle) {
        onProgress(++completed, entries.length, path);
        return;
      }
    }
    handle ??= await directory.getFileHandle(parts.at(-1), { create: true });
    const stream = await handle.createWritable();
    try {
      await stream.write(bytes);
      await stream.close();
    } catch (error) {
      try {
        await stream.abort();
      } catch (abortError) {
        throw new Error(`${path}: ${error.message}; abort also failed: ${abortError.message}`);
      }
      throw new Error(`${path}: ${error.message}`);
    }
    onProgress(++completed, entries.length, path);
  }
  for (const entry of entries.filter(([path]) => path.includes("/tiles/"))) {
    checkCancelled();
    await writeEntry(entry);
  }
  checkCancelled();
  options.onCommit?.();
  for (const entry of entries.filter(([path]) => path.includes("/areas/"))) await writeEntry(entry);
}

export async function removeMapArea(root, id) {
  if (!ID.test(id)) throw new Error("Invalid AeroGrid map area ID.");
  const maps = await child(root, "AEROGRID", "directory").then((directory) => child(directory, "maps", "directory"));
  const before = await inspectMapLibrary(root);
  const removed = before.areas.find((area) => area.id === id);
  if (!removed) return;
  const areas = await child(maps, "areas", "directory");
  try {
    await areas.removeEntry(`${id}.yaml`);
  } catch (error) {
    if (error.name !== "NotFoundError") throw new Error(`Could not remove areas/${id}.yaml: ${error.message}`);
  }
  const remaining = await inspectMapLibrary(root);
  const tiles = await optionalDirectory(maps, "tiles");
  const set = await optionalDirectory(tiles, removed.imagerySet);
  if (!set) return;
  for (const level of removed.levels) {
    const zoomDirectory = await optionalDirectory(set, String(level.zoom));
    for (let x = level.xMin; x <= level.xMax; x++) {
      const canonicalX = x % (2 ** level.zoom);
      const xDirectory = await optionalDirectory(zoomDirectory, String(canonicalX));
      if (!xDirectory) continue;
      for (let y = level.yMin; y <= level.yMax; y++) {
        const tilePath = `${removed.imagerySet}/${level.zoom}/${canonicalX}/${y}.jpg`;
        if (remaining.referencedTiles.has(tilePath)) continue;
        const tile = await child(xDirectory, `${y}.jpg`, "file", true);
        if (tile) await xDirectory.removeEntry(`${y}.jpg`);
      }
    }
  }
}

export async function pruneUnreferencedMapTiles(root, previousTiles, retainedTiles) {
  const maps = await child(root, "AEROGRID", "directory")
    .then((directory) => child(directory, "maps", "directory"));
  const tiles = await optionalDirectory(maps, "tiles");
  for (const path of previousTiles) {
    if (retainedTiles.has(path)) continue;
    const [imagerySet, zoomText, xText, filename] = path.split("/");
    const zoom = Number(zoomText);
    const x = Number(xText);
    const match = /^(\d+)\.jpg$/.exec(filename);
    const y = match ? Number(match[1]) : NaN;
    const world = 2 ** zoom;
    if (!ID.test(imagerySet) || !/^(1[1-9])$/.test(zoomText)
        || !Number.isSafeInteger(x) || x < 0 || x >= world
        || !Number.isSafeInteger(y) || y < 0 || y >= world) {
      throw new Error(`Refusing unsafe unreferenced map tile path: ${path}.`);
    }
    const set = await optionalDirectory(tiles, imagerySet);
    const zoomDirectory = await optionalDirectory(set, zoomText);
    const column = await optionalDirectory(zoomDirectory, xText);
    if (!column) continue;
    try {
      await column.removeEntry(filename);
    } catch (error) {
      if (error.name !== "NotFoundError") throw new Error(`Could not remove unreferenced map tile ${path}: ${error.message}`);
    }
  }
}

export const RADIO_MAP_PRESETS = Object.freeze({
  "Color - 480 x 272": "tx16s",
  "Color - 480 x 320": "tx15",
  "Color - 320 x 480": "nv14",
  "Color - 800 x 480": "tx16s-mk3",
  "Monochrome - 128 x 64": "mono-128x64",
  "Monochrome - 212 x 64": "mono-212x64",
});

export const MAP_STORAGE_LIMITS = Object.freeze({
  maxAreas: MAX_AREAS,
  maxAreaBytes: MAX_AREA_BYTES,
  maxTileBytes: MAX_TILE_BYTES,
});
