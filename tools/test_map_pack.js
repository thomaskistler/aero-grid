// SPDX-License-Identifier: GPL-2.0-only
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
require("../docs/javascripts/map-planner.js");
require("../docs/javascripts/map-pack.js");
require("../docs/javascripts/map-sources.js");
const images = require("./map-test-images.js");
globalThis.AeroGridMapSources.encodeJpeg = async rgb => images.jpeg(rgb);
const planner = globalThis.AeroGridMapPlanner;
const pack = globalThis.AeroGridMapPack;

function selection(area, zooms = [16, 17], compact = false, radio = "tx16s-mkii") {
    const coverage = planner.coveragePlan(area, zooms, radio, compact);
    return { ...planner.specification("Test field", coverage.bounds, zooms, radio, coverage),
        selectedBounds: area, coverageMode: compact ? "per-zoom-clamped" : "full-area-clamped" };
}
function files(archive) {
    const result = new Map();
    const bytes = Buffer.from(archive);
    let offset = 0;
    while (bytes.readUInt32LE(offset) === 0x04034b50) {
        const size = bytes.readUInt32LE(offset + 18), nameLength = bytes.readUInt16LE(offset + 26);
        const start = offset + 30 + nameLength;
        const name = bytes.subarray(offset + 30, start).toString();
        assert(!result.has(name));
        result.set(name, bytes.subarray(start, start + size));
        offset = start + size;
    }
    assert.equal(bytes.readUInt32LE(offset), 0x02014b50);
    return result;
}
(async () => {
    for (const id of ["../x", "UPPER", "a/b", "x.y", "", "x".repeat(33), "caf\u00e9"]) {
        assert.throws(() => pack.identifier(id));
    }
    assert.equal(pack.identifier("test-field_1"), "test-field_1");
    const ordinary = { south: 25.997, north: 25.998, west: -97.158, east: -97.157 };
    const atLimit = selection({ south: 0.01, north: 0.02, west: -180,
        east: -180 + 1000 * 360 / 4096 }, [12]);
    assert.equal(atLimit.tileCount, 2000);
    pack.areaManifest(atLimit, "at-limit", pack.SYNTHETIC.id);
    const latitude = y => Math.atan(Math.sinh(Math.PI * (1 - 2 * y / 4096))) * 180 / Math.PI;
    const overArea = { south: latitude(2049), north: latitude(2046), west: -180,
        east: -180 + 667 * 360 / 4096 };
    const overCoverage = planner.coveragePlan(overArea, [12], "tx16s-mkii");
    assert.equal(overCoverage.tileCount, 2001);
    await assert.rejects(pack.createArchive({ ...atLimit, ...overCoverage,
        selectedBounds: overArea }, "over-limit"), /2,000/);
    const crossing = { south: -0.001, north: 0.001, west: 179.999, east: -179.999 };
    const polar = { south: 85.0509, north: 85.0511, west: 10, east: 10.001 };
    const fixtures = [
        ["ordinary", selection(ordinary)],
        ["compact", selection(ordinary, [15, 16, 17, 18], true)],
        ["dateline", selection(crossing, [16, 17], true)],
        ["polar", selection(polar, [17])],
        ["true", selection(ordinary, [17])],
        ["123", selection(ordinary, [17])],
        ["nine-levels", selection({ south: 0, north: 0.00001, west: 1, east: 1.00001 },
            [11, 12, 13, 14, 15, 16, 17, 18, 19], true)]
    ];
    const seen = new Map();
    for (const [id, spec] of fixtures) {
        let progress = 0;
        const archive = await pack.createArchive(spec, id, {
            onProgress: event => { assert.equal(event.completed, ++progress); assert.equal(event.total, spec.tileCount); }
        });
        assert.equal(progress, spec.tileCount);
        const contents = files(archive);
        assert.equal(contents.size, spec.tileCount + 3);
        assert(contents.has(`AEROGRID/maps/areas/${id}.yaml`));
        assert.deepEqual(JSON.parse(contents.get(`AEROGRID/maps/selections/${id}.json`)), spec);
        for (const [name, image] of contents) {
            assert(name.startsWith("AEROGRID/maps/"));
            assert(!name.includes(".."));
            if (!name.endsWith(".jpg")) continue;
            const match = name.match(/\/(\d+)\/(\d+)\/(\d+)\.jpg$/);
            const [zoom, x, y] = match.slice(1).map(Number);
            assert(x >= 0 && x < 2 ** zoom && y >= 0 && y < 2 ** zoom);
            assert(globalThis.AeroGridMapSources.compatibleJpeg(image));
            assert.deepEqual(image, Buffer.from(images.jpeg(pack.syntheticRgb(zoom, x, y))));
            if (seen.has(name)) assert.deepEqual(image, seen.get(name));
            seen.set(name, image);
        }
        if (id === "dateline") {
            const { manifest } = pack.areaManifest(spec, id, pack.SYNTHETIC.id);
            assert(manifest.levels.every(level => level.xMax >= 2 ** level.zoom));
        }
        if (process.argv[2]) {
            fs.mkdirSync(process.argv[2], { recursive: true });
            fs.writeFileSync(path.join(process.argv[2], `${id}.zip`), archive);
        }
    }
    const spec = selection(ordinary);
    const generated = await pack.createFiles(spec, "files-api", {
        source: {
            metadata: pack.SYNTHETIC,
            readTile: async () => { throw new Error("Existing tiles should be reused."); }
        },
        readExistingTile: async (imagerySet, zoom, x, y) => {
            assert.equal(imagerySet, pack.SYNTHETIC.id);
            return images.jpeg(pack.syntheticRgb(zoom, x, y));
        }
    });
    const archived = files(await pack.createArchive(spec, "files-api"));
    assert.deepEqual([...generated.keys()].sort(), [...archived.keys()].sort());
    for (const [name, content] of generated) assert.deepEqual(Buffer.from(content), archived.get(name));
    for (const mutate of [
        s => { s.version = 2; }, s => { s.projection = "EPSG:4326"; },
        s => { s.coverageMode = "unknown"; }, s => { s.tileCount++; },
        s => { s.levels[0].xRanges[0].min++; }, s => { s.levels[0].zoom = 10; },
        s => { s.levels[1].zoom = 19; }, s => { s.selectedBounds.north = 90; },
        s => { s.radio.id = "unsupported"; }, s => { s.imageryIncluded = true; },
        s => { s.name = ""; }, s => { s.bounds.west++; }
    ]) {
        const invalid = structuredClone(spec);
        mutate(invalid);
        await assert.rejects(pack.createArchive(invalid, "bad"));
    }
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(pack.createArchive(spec, "cancelled", { signal: controller.signal }), /cancelled/);
    const mid = new AbortController();
    await assert.rejects(pack.createArchive(spec, "cancelled", {
        signal: mid.signal, onProgress: () => mid.abort()
    }), /cancelled/);
    await assert.rejects(pack.createArchive(spec, "failed", {
        onProgress: () => { throw new Error("Test input failure"); }
    }), /Test input failure/);
    const again = await pack.createArchive(spec, "ordinary");
    assert.deepEqual(again, await pack.createArchive(spec, "ordinary"));
    const renamed = files(await pack.createArchive(spec, "renamed"));
    for (const [name, image] of files(again)) {
        if (name.endsWith(".jpg")) assert.deepEqual(renamed.get(name), image);
    }
    const other = pack.areaManifest(spec, "ordinary", "other-edition-rgb-v1");
    assert.equal(other.manifest.imagerySet, "other-edition-rgb-v1");
    console.log("Map pack encoding, coverage, ZIP, shared identity and cancellation checks passed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
