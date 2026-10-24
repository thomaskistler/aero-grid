// SPDX-License-Identifier: GPL-2.0-only
(function (root) {
    "use strict";

    const encoder = new TextEncoder();
    const MAX_TILE_BYTES = 256 * 1024;
    const SYNTHETIC = Object.freeze({
        id: "synthetic-v1-jpeg-q90",
        source: "AeroGrid procedural test pattern",
        edition: "v1",
        conversion: "browser-jpeg-q90-v1",
        license: "GPL-2.0-only",
        attribution: "AeroGrid contributors",
        synthetic: true
    });
    const integer = (n, low, high) => Number.isInteger(n) && n >= low && n <= high;
    function identifier(value) {
        if (typeof value !== "string" || !/^[a-z0-9_-]{1,32}$/.test(value)) {
            throw new Error("IDs must use 1-32 lowercase ASCII letters, digits, underscores or hyphens.");
        }
        return value;
    }
    function checkAbort(signal) {
        if (signal && signal.aborted) throw new Error("Map preparation cancelled.");
    }

    function syntheticRgb(zoom, x, y) {
        const rgb = new Uint8Array(256 * 256 * 3);
        for (let py = 0; py < 256; py++) {
            for (let px = 0; px < 256; px++) {
                const gx = x * 256 + px, gy = y * 256 + py;
                const shade = (Math.floor(gx / 32) + Math.floor(gy / 32) + zoom) % 2;
                let color = [45 + shade * 15, 70 + shade * 15, 55 + shade * 15];
                if ((gx + gy) % 197 < 9) color = [45, 114, 170];
                if (gx % 256 < 2 || gy % 256 < 2) color = [240, 183, 65];
                // Encode canonical XYZ in an unmistakably artificial top strip.
                if (py >= 8 && py < 16 && px < 192) {
                    const value = px < 64 ? zoom : px < 128 ? x : y;
                    color = value & (1 << (Math.floor(px / 3) % 20)) ? [255, 255, 255] : [0, 0, 0];
                }
                rgb.set(color, (py * 256 + px) * 3);
            }
        }
        return rgb;
    }

    function areaManifest(selection, id, imagerySet) {
        identifier(id);
        identifier(imagerySet);
        const planner = root.AeroGridMapPlanner;
        if (!selection || selection.format !== "aerogrid-map-selection" || selection.version !== 1 ||
            selection.projection !== "EPSG:3857" || selection.tileScheme !== "XYZ" ||
            selection.tileSize !== 256 || selection.imageryIncluded !== false ||
            typeof selection.name !== "string" || !selection.name.trim() ||
            selection.name !== selection.name.trim() || selection.name.length > 80 ||
            !selection.radio || typeof selection.radio.id !== "string" ||
            !Array.isArray(selection.levels) || !selection.levels.length || selection.levels.length > 9) {
            throw new Error("Invalid map selection.");
        }
        const zooms = selection.levels.map(level => level.zoom);
        if (!zooms.every((z, i) => integer(z, 11, 19) && (!i || z === zooms[i - 1] + 1)) ||
            !["full-area-clamped", "per-zoom-clamped"].includes(selection.coverageMode)) {
            throw new Error("Selections require consecutive zooms 11-19 and a supported coverage mode.");
        }
        const expected = planner.coveragePlan(selection.selectedBounds, zooms, selection.radio.id,
            selection.coverageMode === "per-zoom-clamped");
        if (JSON.stringify(expected.levels) !== JSON.stringify(selection.levels) ||
            JSON.stringify(expected.bounds) !== JSON.stringify(selection.bounds) ||
            expected.tileCount !== selection.tileCount || expected.tileCount > 2000) {
            throw new Error("Selection coverage is inconsistent or exceeds 2,000 tiles.");
        }
        const levels = expected.levels.map(level => {
            const n = 2 ** level.zoom;
            const ranges = level.xRanges;
            const xMin = ranges.length === 1 ? ranges[0].min : ranges[1].min;
            const xMax = ranges.length === 1 ? ranges[0].max : n + ranges[0].max;
            return { zoom: level.zoom, xMin, xMax, yMin: level.yMin, yMax: level.yMax };
        });
        const manifest = { format: "aerogrid-map-area", version: 2, id, name: selection.name, imagerySet,
            projection: "EPSG:3857", tileScheme: "XYZ", tileSize: 256, imageFormat: "jpeg",
            selection: {
                bounds: Object.fromEntries(["west", "south", "east", "north"]
                    .map(key => [key, selection.selectedBounds[key]])),
                radio: selection.radio.id, coverageMode: selection.coverageMode
            }, levels };
        let yaml = Object.entries(manifest).filter(([key]) => !["levels", "selection"].includes(key))
            .map(([key, value]) => `${key}: ${typeof value === "string" ? JSON.stringify(value) : value}\n`)
            .join("") + "selection:\n  bounds:\n";
        yaml += Object.entries(manifest.selection.bounds).map(([key, value]) => `    ${key}: ${value}\n`).join("");
        yaml += `  radio: ${JSON.stringify(manifest.selection.radio)}\n`;
        yaml += `  coverageMode: ${JSON.stringify(manifest.selection.coverageMode)}\nlevels:\n`;
        for (const level of levels) {
            yaml += Object.entries(level).map(([key, value], i) => `  ${i ? "  " : "- "}${key}: ${value}\n`).join("");
        }
        if (encoder.encode(yaml).length > 8192) throw new Error("Area manifest exceeds 8 KiB.");
        return { manifest, yaml };
    }

    async function createFiles(selection, id, options = {}) {
        let source = options.source || (!options.getSource
            && (!options.imagerySet || options.imagerySet === SYNTHETIC.id) ? {
                metadata: SYNTHETIC,
                readTile: (zoom, x, y, signal) =>
                    root.AeroGridMapSources.encodeJpeg(syntheticRgb(zoom, x, y), signal)
            } : null);
        const ensureSource = async () => {
            source ||= await options.getSource?.();
            if (!source) throw new Error("Some map images are missing. Reconnect using the browser and site storage where this area was created.");
            const metadata = source.metadata;
            if (!metadata || typeof source.readTile !== "function" ||
                !["source", "edition", "conversion", "license", "attribution"].every(
                    key => typeof metadata[key] === "string" && metadata[key].length > 0) ||
                typeof metadata.synthetic !== "boolean") {
                throw new Error("Source must supply image input and complete provenance metadata.");
            }
            return source;
        };
        let imagerySet = options.imagerySet;
        if (!imagerySet) imagerySet = (await ensureSource()).metadata.id;
        const { manifest, yaml } = areaManifest(selection, id, imagerySet);
        const signal = options.signal;
        const entries = [];
        const existingTiles = new Set();
        let bytes = 0, completed = 0;
        function add(path, content) {
            bytes += content.length;
            entries.push(["AEROGRID/maps/" + path, content]);
        }
        checkAbort(signal);
        add(`areas/${id}.yaml`, encoder.encode(yaml));
        for (const level of manifest.levels) {
            for (let x = level.xMin; x <= level.xMax; x++) {
                for (let y = level.yMin; y <= level.yMax; y++) {
                    checkAbort(signal);
                    const canonicalX = x % 2 ** level.zoom;
                    const image = options.readExistingTile
                        ? await options.readExistingTile(imagerySet, level.zoom, canonicalX, y)
                        : null;
                    let tile = image;
                    if (image) existingTiles.add(`${imagerySet}/${level.zoom}/${canonicalX}/${y}.jpg`);
                    else {
                        const selectedSource = await ensureSource();
                        if (selectedSource.metadata.id !== imagerySet) {
                            throw new Error("Some map images are missing. Reconnect using the browser and site storage where this area was created.");
                        }
                        tile = await selectedSource.readTile(level.zoom, canonicalX, y, signal);
                    }
                    checkAbort(signal);
                    if (!(tile instanceof Uint8Array) || !tile.length) throw new Error("Invalid encoded tile.");
                    if (!root.AeroGridMapSources.compatibleJpeg(tile)) throw new Error("Tile must be a compatible 256x256 JPEG.");
                    if (tile.length > MAX_TILE_BYTES) throw new Error("Encoded tile exceeds 256 KiB.");
                    add(`tiles/${imagerySet}/${level.zoom}/${canonicalX}/${y}.jpg`, tile);
                    completed++;
                    if (options.onProgress) options.onProgress({ completed, total: selection.tileCount, bytes });
                    // Yield between tiles so cancellation and selection changes
                    // are processed even with a purely local source.
                    await new Promise(resolve => setTimeout(resolve, 0));
                }
            }
        }
        checkAbort(signal);
        const files = new Map(entries);
        files.existingTiles = existingTiles;
        return files;
    }

    root.AeroGridMapPack = { areaManifest, syntheticRgb, createFiles, SYNTHETIC, MAX_TILE_BYTES };
})(globalThis);
