// SPDX-License-Identifier: GPL-2.0-only
import { child } from "./radio-storage.mjs";

const MAX_AREAS = 64;
const MAX_AREA_BYTES = 8 * 1024;
const MAX_SELECTION_BYTES = 128 * 1024;
const MAX_TILE_BYTES = 256 * 1024;
const MAX_AREA_DIRECTORY_ENTRIES = 256;
const MAX_LIBRARY_TILES = 100_000;
const ID = /^[a-z0-9_-]{1,32}$/;

function parseArea(text, expectedId) {
  if (typeof text !== "string" || new TextEncoder().encode(text).length > MAX_AREA_BYTES) {
    throw new Error(`Map area ${expectedId} has an invalid or oversized manifest.`);
  }
  const scalar = (key) => {
    const matches = [...text.matchAll(new RegExp(`^${key}: (.+)$`, "gm"))];
    if (matches.length !== 1) throw new Error(`Map area ${expectedId} has an invalid ${key} field.`);
    return matches[0][1].replace(/^"|"$/g, "");
  };
  const id = scalar("id");
  const imagerySet = scalar("imagerySet");
  if (scalar("format") !== "aerogrid-map-area" || scalar("version") !== "1"
      || id !== expectedId || !ID.test(id) || !ID.test(imagerySet)
      || scalar("projection") !== "EPSG:3857" || scalar("tileScheme") !== "XYZ"
      || scalar("tileSize") !== "256" || scalar("imageFormat") !== "jpeg") {
    throw new Error(`Map area ${expectedId} does not use the supported AeroGrid map format.`);
  }
  const levelRows = [...text.matchAll(
    /^  - zoom: (\d+)\n    xMin: (\d+)\n    xMax: (\d+)\n    yMin: (\d+)\n    yMax: (\d+)$/gm
  )];
  if (!levelRows.length || levelRows.length > 9) {
    throw new Error(`Map area ${expectedId} has invalid zoom coverage.`);
  }
  const levels = levelRows.map((row) => ({
    zoom: Number(row[1]), xMin: Number(row[2]), xMax: Number(row[3]),
    yMin: Number(row[4]), yMax: Number(row[5]),
  }));
  for (const [index, level] of levels.entries()) {
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
  return { id, imagerySet, levels, tileCount };
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

async function fileSize(directory, name) {
  const handle = await child(directory, name, "file");
  const file = await handle.getFile();
  if (!file.size || file.size > MAX_TILE_BYTES) {
    throw new Error(`${name} is empty or exceeds the 256 KiB map tile limit.`);
  }
  return file.size;
}

async function optionalDirectory(parent, name) {
  if (!parent) return null;
  return child(parent, name, "directory", true);
}

export async function inspectMapLibrary(root) {
  const maps = await optionalDirectory(root, "AEROGRID")
    .then((aerogrid) => optionalDirectory(aerogrid, "maps"));
  if (!maps) return { areas: [], tileBytes: 0, referencedTiles: new Set(), tileSizes: new Map() };
  const areasDirectory = await optionalDirectory(maps, "areas");
  const selectionsDirectory = await optionalDirectory(maps, "selections");
  const sourcesDirectory = await optionalDirectory(maps, "sources");
  const tilesDirectory = await optionalDirectory(maps, "tiles");
  if (!areasDirectory) return { areas: [], tileBytes: 0, referencedTiles: new Set(), tileSizes: new Map() };
  if (!selectionsDirectory || !sourcesDirectory || !tilesDirectory) {
    throw new Error("The AeroGrid map library is incomplete. No radio files were changed.");
  }

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
  const referencedTiles = new Map();
  for (const id of areaFiles.sort()) {
    const manifest = parseArea(await readFile(areasDirectory, `${id}.yaml`, MAX_AREA_BYTES), id);
    let sourceMetadata;
    try {
      sourceMetadata = JSON.parse(await readFile(sourcesDirectory, `${manifest.imagerySet}.json`, MAX_SELECTION_BYTES));
    } catch (error) {
      throw new Error(`Map area ${id} has missing or invalid imagery metadata: ${error.message}`);
    }
    if (sourceMetadata?.id !== manifest.imagerySet
        || !["source", "edition", "conversion", "license", "attribution"].every((key) =>
          typeof sourceMetadata[key] === "string" && sourceMetadata[key].length)
        || typeof sourceMetadata.synthetic !== "boolean") {
      throw new Error(`Map area ${id} has unsupported imagery source metadata.`);
    }
    let selection;
    try {
      selection = JSON.parse(await readFile(selectionsDirectory, `${id}.json`, MAX_SELECTION_BYTES));
    } catch (error) {
      throw new Error(`Map area ${id} has missing or invalid saved selection metadata: ${error.message}`);
    }
    if (!selection || selection.format !== "aerogrid-map-selection" || selection.version !== 1
        || typeof selection.name !== "string" || selection.name !== selection.name.trim()
        || !selection.name || selection.name.length > 80
        || !selection.radio || typeof selection.radio.id !== "string"
        || !validBounds(selection.selectedBounds) || !validBounds(selection.bounds)
        || !selectionLevelsMatch(selection.levels, manifest.levels)
        || !Number.isInteger(selection.tileCount)
        || selection.tileCount !== manifest.tileCount
        || !["full-area-clamped", "per-zoom-clamped"].includes(selection.coverageMode)) {
      throw new Error(`Map area ${id} has unsupported saved selection metadata.`);
    }
    if (selection.coverageMode === "per-zoom-clamped"
        && selection.levels.some((level) => !validBounds(level.bounds))) {
      throw new Error(`Map area ${id} has invalid per-zoom bounds.`);
    }
    let bytes = 0;
    const areaTiles = new Set();
    for (const level of manifest.levels) {
      for (let x = level.xMin; x <= level.xMax; x++) {
        const canonicalX = x % (2 ** level.zoom);
        const zoomDirectory = await child(tilesDirectory, manifest.imagerySet, "directory")
          .then((set) => child(set, String(level.zoom), "directory"));
        const xDirectory = await child(zoomDirectory, String(canonicalX), "directory");
        for (let y = level.yMin; y <= level.yMax; y++) {
          const tilePath = `${manifest.imagerySet}/${level.zoom}/${canonicalX}/${y}.jpg`;
          if (!areaTiles.has(tilePath)) {
            if (!referencedTiles.has(tilePath) && referencedTiles.size >= MAX_LIBRARY_TILES) {
              throw new Error("The radio map library references more than 100,000 unique tiles.");
            }
            const size = referencedTiles.get(tilePath) ?? await fileSize(xDirectory, `${y}.jpg`);
            areaTiles.add(tilePath);
            referencedTiles.set(tilePath, size);
            bytes += size;
          }
        }
      }
    }
    areas.push({ ...manifest, selection, sourceMetadata, storageBytes: bytes });
  }
  return {
    areas,
    tileBytes: [...referencedTiles.values()].reduce((total, size) => total + size, 0),
    referencedTiles: new Set(referencedTiles.keys()),
    tileSizes: referencedTiles,
  };
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
    for (const level of record.selection.levels) {
      for (const range of level.xRanges) {
        for (let x = range.min; x <= range.max; x++) {
          for (let y = level.yMin; y <= level.yMax; y++) {
            selectedTiles.add(`${imagerySet}/${level.zoom}/${x % (2 ** level.zoom)}/${y}.jpg`);
          }
        }
      }
    }
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
  const aerogrid = await child(root, "AEROGRID", "directory", true);
  const maps = await optionalDirectory(aerogrid, "maps");
  const tiles = await optionalDirectory(maps, "tiles");
  const set = await optionalDirectory(tiles, imagerySet);
  const zoomDirectory = await optionalDirectory(set, String(zoom));
  const column = await optionalDirectory(zoomDirectory, String(x));
  const handle = column && await child(column, `${y}.jpg`, "file", true);
  if (!handle) return null;
  const file = await handle.getFile();
  if (!file.size || file.size > MAX_TILE_BYTES) throw new Error("Saved map tile is empty or oversized.");
  return new Uint8Array(await file.arrayBuffer());
}

export function mapLibrarySignatureFromAreas(areas) {
  return JSON.stringify(areas.map((area) => [
    area.id, area.imagerySet, area.storageBytes, area.selection, area.sourceMetadata,
  ]));
}

export async function mapLibrarySignature(root) {
  const { areas } = await inspectMapLibrary(root);
  return mapLibrarySignatureFromAreas(areas);
}

async function directoryFor(root, path) {
  let directory = root;
  for (const part of path) directory = await directory.getDirectoryHandle(part, { create: true });
  return directory;
}

export async function writeMapFiles(root, files, onProgress = () => {}) {
  const entries = [...files.entries()];
  for (const [index, [path, bytes]] of entries.entries()) {
    const parts = path.split("/");
    const zoom = Number(parts[4]);
    const x = Number(parts[5]);
    const y = Number(parts[6]?.slice(0, -4));
    const metadataPath = parts.length === 4 && ["areas", "selections", "sources"].includes(parts[2])
      && (parts[2] === "areas" ? /^[a-z0-9_-]{1,32}\.yaml$/.test(parts[3])
        : /^[a-z0-9_-]{1,32}\.json$/.test(parts[3]));
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
    const directory = await directoryFor(root, parts.slice(0, -1));
    let handle;
    if (parts[2] === "tiles" || parts[2] === "sources") {
      try {
        handle = await directory.getFileHandle(parts.at(-1));
      } catch (error) {
        if (error.name !== "NotFoundError") throw error;
      }
      if (handle) {
        onProgress(index + 1, entries.length, path);
        continue;
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
    onProgress(index + 1, entries.length, path);
  }
}

export async function removeMapArea(root, id) {
  if (!ID.test(id)) throw new Error("Invalid AeroGrid map area ID.");
  const maps = await child(root, "AEROGRID", "directory").then((directory) => child(directory, "maps", "directory"));
  const before = await inspectMapLibrary(root);
  const removed = before.areas.find((area) => area.id === id);
  if (!removed) return;
  for (const [directoryName, filename] of [["areas", `${id}.yaml`], ["selections", `${id}.json`]]) {
    const directory = await child(maps, directoryName, "directory", true);
    if (directory) {
      try {
        await directory.removeEntry(filename);
      } catch (error) {
        if (error.name !== "NotFoundError") throw new Error(`Could not remove ${directoryName}/${filename}: ${error.message}`);
      }
    }
  }
  const remaining = await inspectMapLibrary(root);
  if (!remaining.areas.some((area) => area.imagerySet === removed.imagerySet)) {
    const sources = await child(maps, "sources", "directory", true);
    if (sources) {
      try {
        await sources.removeEntry(`${removed.imagerySet}.json`);
      } catch (error) {
        if (error.name !== "NotFoundError") throw new Error(`Could not remove imagery metadata: ${error.message}`);
      }
    }
  }
  const tiles = await child(maps, "tiles", "directory");
  const set = await child(tiles, removed.imagerySet, "directory", true);
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
  const tiles = await child(maps, "tiles", "directory");
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
  maxSelectionBytes: MAX_SELECTION_BYTES,
  maxTileBytes: MAX_TILE_BYTES,
});
