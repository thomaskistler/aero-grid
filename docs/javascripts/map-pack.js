// SPDX-License-Identifier: GPL-2.0-only
(function (root) {
    "use strict";

    const encoder = new TextEncoder();
    const MAX_ARCHIVE_BYTES = 128 * 1024 * 1024;
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
        if (signal && signal.aborted) throw new Error("Export cancelled.");
    }
    function concat(parts) {
        const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
        let offset = 0;
        for (const part of parts) { result.set(part, offset); offset += part.length; }
        return result;
    }
    function number(value, bytes, little = false) {
        const result = new Uint8Array(bytes);
        const view = new DataView(result.buffer);
        if (bytes === 2) view.setUint16(0, value, little);
        else view.setUint32(0, value, little);
        return result;
    }
    const crcTable = Uint32Array.from({ length: 256 }, (_, i) => {
        for (let bit = 0; bit < 8; bit++) i = (i >>> 1) ^ (i & 1 ? 0xedb88320 : 0);
        return i >>> 0;
    });
    function crc32(bytes) {
        let crc = 0xffffffff;
        for (const byte of bytes) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
        return (crc ^ 0xffffffff) >>> 0;
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
            typeof selection.name !== "string" || !selection.name.trim() || selection.name.length > 80 ||
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
        const manifest = { format: "aerogrid-map-area", version: 1, id, imagerySet,
            projection: "EPSG:3857", tileScheme: "XYZ", tileSize: 256, imageFormat: "jpeg", levels };
        let yaml = Object.entries(manifest).filter(([key]) => key !== "levels")
            .map(([key, value]) => `${key}: ${typeof value === "string" ? JSON.stringify(value) : value}\n`)
            .join("") + "levels:\n";
        for (const level of levels) {
            yaml += Object.entries(level).map(([key, value], i) => `  ${i ? "  " : "- "}${key}: ${value}\n`).join("");
        }
        if (encoder.encode(yaml).length > 8192) throw new Error("Area manifest exceeds 8 KiB.");
        return { manifest, yaml };
    }

    function zip(entries) {
        const files = [], central = [];
        let offset = 0;
        for (const [path, data] of entries) {
            const name = encoder.encode(path), crc = crc32(data);
            const header = concat([number(0x04034b50, 4, true), number(20, 2, true),
                number(0x800, 2, true), number(0, 2), number(0, 2), number(33, 2, true),
                number(crc, 4, true), number(data.length, 4, true), number(data.length, 4, true),
                number(name.length, 2, true), number(0, 2), name]);
            files.push(header, data);
            central.push(concat([number(0x02014b50, 4, true), number(20, 2, true), header.subarray(4, 28),
                number(0, 2), number(0, 2), number(0, 2), number(0, 2), number(0, 4),
                number(offset, 4, true), name]));
            offset += header.length + data.length;
        }
        const directory = concat(central);
        return concat([...files, directory, number(0x06054b50, 4, true), number(0, 4),
            number(entries.length, 2, true), number(entries.length, 2, true),
            number(directory.length, 4, true), number(offset, 4, true), number(0, 2)]);
    }

    async function createFiles(selection, id, options = {}) {
        const source = options.source || {
            metadata: SYNTHETIC,
            readTile: (zoom, x, y, signal) => root.AeroGridMapSources.encodeJpeg(syntheticRgb(zoom, x, y), signal)
        };
        const metadata = source.metadata;
        if (!metadata || typeof source.readTile !== "function" ||
            !["source", "edition", "conversion", "license", "attribution"].every(
                key => typeof metadata[key] === "string" && metadata[key].length > 0) ||
            typeof metadata.synthetic !== "boolean") {
            throw new Error("Source must supply image input and complete provenance metadata.");
        }
        const sourceMetadata = JSON.stringify(metadata, null, 2) + "\n";
        if (encoder.encode(sourceMetadata).length > 8192) throw new Error("Source metadata exceeds 8 KiB.");
        const { manifest, yaml } = areaManifest(selection, id, metadata.id);
        const signal = options.signal;
        const entries = [];
        let bytes = 0, completed = 0;
        function add(path, content) {
            bytes += content.length;
            if (bytes > MAX_ARCHIVE_BYTES) throw new Error("Export exceeds the 128 MiB archive-entry budget.");
            entries.push(["AEROGRID/maps/" + path, content]);
        }
        checkAbort(signal);
        add(`areas/${id}.yaml`, encoder.encode(yaml));
        add(`selections/${id}.json`, encoder.encode(JSON.stringify(selection, null, 2) + "\n"));
        add(`sources/${metadata.id}.json`, encoder.encode(sourceMetadata));
        for (const level of manifest.levels) {
            for (let x = level.xMin; x <= level.xMax; x++) {
                for (let y = level.yMin; y <= level.yMax; y++) {
                    checkAbort(signal);
                    const canonicalX = x % 2 ** level.zoom;
                    const image = options.readExistingTile
                        ? await options.readExistingTile(metadata.id, level.zoom, canonicalX, y)
                        : null;
                    const tile = image || await source.readTile(level.zoom, canonicalX, y, signal);
                    checkAbort(signal);
                    if (!(tile instanceof Uint8Array) || !tile.length) throw new Error("Invalid encoded tile.");
                    if (!root.AeroGridMapSources.compatibleJpeg(tile)) throw new Error("Tile must be a compatible 256x256 JPEG.");
                    if (tile.length > MAX_TILE_BYTES) throw new Error("Encoded tile exceeds 256 KiB.");
                    add(`tiles/${metadata.id}/${level.zoom}/${canonicalX}/${y}.jpg`, tile);
                    completed++;
                    if (options.onProgress) options.onProgress({ completed, total: selection.tileCount, bytes });
                    // Yield between tiles so cancellation and selection changes
                    // are processed even with a purely local source.
                    await new Promise(resolve => setTimeout(resolve, 0));
                }
            }
        }
        checkAbort(signal);
        return new Map(entries);
    }

    async function createArchive(selection, id, options = {}) {
        const files = await createFiles(selection, id, options);
        checkAbort(options.signal);
        const data = zip([...files]);
        checkAbort(options.signal);
        return data;
    }

    root.AeroGridMapPack = { identifier, areaManifest, syntheticRgb, createFiles, createArchive,
        SYNTHETIC, MAX_ARCHIVE_BYTES, MAX_TILE_BYTES };
})(globalThis);
