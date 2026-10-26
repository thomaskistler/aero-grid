// SPDX-License-Identifier: GPL-2.0-only
"use strict";

const assert = require("node:assert/strict");
require("../docs/javascripts/map-planner.js");
require("../docs/javascripts/map-pack.js");
require("../docs/javascripts/map-sources.js");
const planner = globalThis.AeroGridMapPlanner;
const filesApi = globalThis.AeroGridMapPack;
const sources = globalThis.AeroGridMapSources;
const images = require("./map-test-images.js");
sources.encodeJpeg = async rgb => images.jpeg(rgb);

function selection(bounds, zooms = [16, 17], compact = false, radio = "tx16s-mkii") {
    const coverage = planner.coveragePlan(bounds, zooms, radio, compact);
    return { ...planner.specification("Test field", coverage.bounds, zooms, radio, coverage),
        selectedBounds: bounds, coverageMode: compact ? "per-zoom-clamped" : "full-area-clamped" };
}

(async () => {
    const ordinary = { south: 25.997, north: 25.998, west: -97.158, east: -97.157 };
    const atLimit = selection({ south: 0.01, north: 0.02, west: -180,
        east: -180 + 1000 * 360 / 4096 }, [12]);
    assert.equal(atLimit.tileCount, 2000);
    filesApi.areaManifest(atLimit, "at-limit", filesApi.SYNTHETIC.id);
    const latitude = y => Math.atan(Math.sinh(Math.PI * (1 - 2 * y / 4096))) * 180 / Math.PI;
    const overArea = { south: latitude(2049), north: latitude(2046), west: -180,
        east: -180 + 667 * 360 / 4096 };
    const overCoverage = planner.coveragePlan(overArea, [12], "tx16s-mkii");
    assert.equal(overCoverage.tileCount, 2001);
    assert.throws(() => filesApi.areaManifest({
        ...atLimit, ...overCoverage, selectedBounds: overArea,
    }, "over-limit", filesApi.SYNTHETIC.id), /2,000/);

    const fixtures = [
        ["ordinary", selection(ordinary)],
        ["compact", selection(ordinary, [15, 16, 17, 18], true)],
        ["dateline", selection(
            { south: -0.001, north: 0.001, west: 179.999, east: -179.999 }, [16, 17], true)],
        ["polar", selection({ south: 85.0509, north: 85.0511, west: 10, east: 10.001 }, [17])],
        ["escaped-name", selection(ordinary, [17])],
        ["nine-levels", selection({ south: 0, north: 0.00001, west: 1, east: 1.00001 },
            [11, 12, 13, 14, 15, 16, 17, 18, 19], true)],
    ];
    fixtures[4][1].name = 'Field: "north" #1\nCafé \\ flight area';
    const seen = new Map();
    for (const [id, spec] of fixtures) {
        let progress = 0;
        const generated = await filesApi.createFiles(spec, id, {
            onProgress: event => {
                assert.equal(event.completed, ++progress);
                assert.equal(event.total, spec.tileCount);
            },
        });
        assert.equal(progress, spec.tileCount);
        assert.equal(generated.size, spec.tileCount + 1);
        const { manifest, yaml } = filesApi.areaManifest(spec, id, filesApi.SYNTHETIC.id);
        assert.equal(manifest.version, 2);
        assert.equal(new TextDecoder().decode(generated.get(`AEROGRID/maps/areas/${id}.yaml`)), yaml);
        assert.equal(manifest.name, spec.name);
        assert.deepEqual(manifest.selection.bounds, spec.selectedBounds);
        assert.equal(manifest.selection.radio, spec.radio.id);
        assert.equal(manifest.selection.coverageMode, spec.coverageMode);
        assert([...generated.keys()].every(name =>
            /^AEROGRID\/maps\/(?:areas\/[^/]+\.yaml|tiles\/[^/]+\/\d+\/\d+\/\d+\.jpg)$/.test(name)));
        for (const [name, image] of generated) {
            if (!name.endsWith(".jpg")) continue;
            const match = name.match(/\/(\d+)\/(\d+)\/(\d+)\.jpg$/);
            const [zoom, x, y] = match.slice(1).map(Number);
            assert(x >= 0 && x < 2 ** zoom && y >= 0 && y < 2 ** zoom);
            assert(sources.compatibleJpeg(image));
            assert.deepEqual(image, images.jpeg(filesApi.syntheticRgb(zoom, x, y)));
            if (seen.has(name)) assert.deepEqual(image, seen.get(name));
            seen.set(name, image);
        }
        if (id === "dateline") {
            assert(manifest.levels.every(level => level.xMax >= 2 ** level.zoom));
        }
    }

    const spec = selection(ordinary);
    const reused = await filesApi.createFiles(spec, "reused", {
        source: {
            metadata: filesApi.SYNTHETIC,
            readTile: async () => { throw new Error("Existing tiles should be reused."); },
        },
        readExistingTile: async (imagerySet, zoom, x, y) => {
            assert.equal(imagerySet, filesApi.SYNTHETIC.id);
            return images.jpeg(filesApi.syntheticRgb(zoom, x, y));
        },
    });
    assert.equal(reused.size, spec.tileCount + 1);

    const invalid = structuredClone(spec);
    invalid.version = 2;
    await assert.rejects(filesApi.createFiles(invalid, "invalid"));
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(filesApi.createFiles(spec, "cancelled", { signal: controller.signal }), /cancelled/);
    const mid = new AbortController();
    await assert.rejects(filesApi.createFiles(spec, "cancelled", {
        signal: mid.signal, onProgress: () => mid.abort(),
    }), /cancelled/);
    await assert.rejects(filesApi.createFiles(spec, "failed", {
        onProgress: () => { throw new Error("Test input failure"); },
    }), /Test input failure/);
    await assert.rejects(filesApi.createFiles(spec, "bad", {
        source: { metadata: filesApi.SYNTHETIC, readTile: async () => new Uint8Array([1, 2]) },
    }), /JPEG/);
    assert.equal(filesApi.createArchive, undefined);
    console.log("Map area file generation, JPEG, coverage, shared identity and cancellation checks passed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
