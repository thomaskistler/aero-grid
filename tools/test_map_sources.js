// SPDX-License-Identifier: GPL-2.0-only
"use strict";

const assert = require("node:assert/strict");
require("../docs/javascripts/map-pack.js");
require("../docs/javascripts/map-planner.js");
require("../docs/javascripts/map-sources.js");
const sources = globalThis.AeroGridMapSources;
const pack = globalThis.AeroGridMapPack;
const images = require("./map-test-images.js");
const png = images.png(pack.syntheticRgb(17, 30160, 55726));
const image = () => new Response(png, { headers: { "Content-Type": "image/png" } });
const noDelay = async () => {};

(async () => {
    const compatible = new Uint8Array([255, 216, 255, 192, 0, 17, 8, 1, 0, 1, 0, 3,
        1, 34, 0, 2, 17, 1, 3, 17, 1, 255, 218, 0, 12, 255, 217]);
    assert(sources.compatibleJpeg(compatible));
    const progressive = compatible.slice();
    progressive[3] = 194;
    assert(sources.compatibleJpeg(progressive));
    for (let length = 0; length < compatible.length; length++) {
        assert.equal(sources.compatibleJpeg(compatible.subarray(0, length)), false);
    }
    for (const [offset, value] of [[3, 195], [6, 12], [7, 2], [11, 4]]) {
        const invalid = compatible.slice();
        invalid[offset] = value;
        assert.equal(sources.compatibleJpeg(invalid), false);
    }
    const exif = new Uint8Array([255, 216, 255, 225, 0, 2, ...compatible.subarray(2)]);
    assert.equal(sources.compatibleJpeg(exif), false);
    assert.equal(sources.compatibleJpeg(new Uint8Array([255, 216, 255, 255, 255, 255, 255, 217])), false);
    let seed = 42;
    for (let length = 0; length < 256; length++) {
        const garbage = Uint8Array.from({ length }, () => {
            seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
            return seed >>> 24;
        });
        if (length > 3) { garbage.set([255, 216]); garbage.set([255, 217], length - 2); }
        assert.equal(sources.compatibleJpeg(garbage), false);
    }
    for (const rgb of [new Uint8Array(3), [], new Uint8Array(256 * 256 * 4)]) {
        await assert.rejects(sources.encodeJpeg(rgb), /RGB/);
    }
    assert.deepEqual(sources.imageDimensions(png, "image/png"), [256, 256]);
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0,
        0xff, 0xc2, 0, 8, 8, 1, 0, 1, 0, 1, 0xff, 0xd9]);
    assert.deepEqual(sources.imageDimensions(jpeg, "image/jpeg"), [256, 256]);
    const webp = new Uint8Array(30);
    webp.set(Buffer.from("RIFF"), 0); webp.set(Buffer.from("WEBPVP8X"), 8);
    webp[24] = webp[27] = 255;
    assert.deepEqual(sources.imageDimensions(webp, "image/webp"), [256, 256]);
    webp.set(Buffer.from("VP8 "), 12); webp.set([0x9d, 1, 0x2a], 23);
    webp.set([0, 1, 0, 1], 26);
    assert.deepEqual(sources.imageDimensions(webp, "image/webp"), [256, 256]);
    webp.set(Buffer.from("VP8L"), 12); webp[20] = 0x2f;
    new DataView(webp.buffer).setUint32(21, 255 + (255 << 14), true);
    assert.deepEqual(sources.imageDimensions(webp, "image/webp"), [256, 256]);
    for (const type of ["image/png", "image/jpeg", "image/webp", "text/html"]) {
        assert.throws(() => sources.imageDimensions(new Uint8Array([1, 2]), type), /header/);
    }
    const oversizedPng = png.slice();
    new DataView(oversizedPng.buffer).setUint32(16, 100000);
    await assert.rejects(sources.decodeRgb(new Blob([oversizedPng], { type: "image/png" })), /256x256/);

    const rgba = new Uint8Array(256 * 256 * 4).fill(255);
    rgba[0] = 17; rgba[1] = 81; rgba[2] = 203;
    const rgb = sources.rgbaToRgb(rgba, 256, 256);
    assert.deepEqual(Array.from(rgb.subarray(0, 3)), [17, 81, 203]);
    rgba[3] = 254;
    assert.throws(() => sources.rgbaToRgb(rgba, 256, 256), /opaque/);
    assert.throws(() => sources.rgbaToRgb(rgba, 512, 256), /256x256/);
    assert.throws(() => sources.rgbaToRgb(new Uint8Array(4), 256, 256), /256x256/);

    let requests = 0;
    const result = await sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async (url, options) => {
            requests++;
            assert.equal(url, "https://fixture.invalid/tile");
            assert.equal(options.mode, "cors");
            assert.equal(options.credentials, "omit");
            return image();
        }
    });
    assert.equal(requests, 1);
    assert.deepEqual(new Uint8Array(await result.arrayBuffer()), png);
    assert.equal(result.type, "image/png");
    const delays = [];
    requests = 0;
    await sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async () => ++requests < 3 ?
            new Response("", { status: 429, headers: { "Retry-After": "1" } }) : image(),
        delay: async value => delays.push(value)
    });
    assert.equal(requests, 3);
    requests = 0;
    await sources.fetchImage("https://fixture.invalid/tile", {
        delay: noDelay, timeoutMs: 1,
        fetchTile: async (url, { signal }) => {
            requests++;
            if (requests === 3) return image();
            return new Response(new ReadableStream({
                start(body) {
                    signal.addEventListener("abort", () => body.error(
                        new DOMException("body timeout", "AbortError")), { once: true });
                }
            }), { headers: { "Content-Type": "image/png" } });
        }
    });
    assert.equal(requests, 3);
    requests = 0;
    await sources.fetchImage("https://fixture.invalid/tile", {
        delay: noDelay,
        fetchTile: async () => {
            requests++;
            return requests === 1 ? new Response(new ReadableStream({
                start(body) { body.error(new TypeError("body network interruption")); }
            }), { headers: { "Content-Type": "image/png" } }) : image();
        }
    });
    assert.equal(requests, 2);
    assert.deepEqual(delays, [1000, 1000]);
    for (const status of [401, 403, 404]) {
        requests = 0;
        await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
            fetchTile: async () => { requests++; return new Response("", { status }); }, delay: noDelay
        }), new RegExp(`HTTP ${status}`));
        assert.equal(requests, 1);
    }
    const duringWait = new AbortController();
    requests = 0;
    const waiting = sources.fetchImage("https://fixture.invalid/tile", {
        signal: duringWait.signal,
        fetchTile: async () => { requests++; return new Response("", { status: 429 }); }
    });
    setTimeout(() => duringWait.abort(), 5);
    await assert.rejects(waiting, /cancelled/);
    assert.equal(requests, 1);
    requests = 0;
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async () => { requests++; return new Response("", { status: 503 }); }, delay: noDelay
    }), /HTTP 503/);
    assert.equal(requests, 3);
    requests = 0;
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async () => { requests++; throw new TypeError("mock network/CORS failure"); }, delay: noDelay
    }), /CORS/);
    assert.equal(requests, 3);
    assert.equal(sources.retryDelay("2", 0), 2000);
    assert.equal(sources.retryDelay("invalid", 1), 1000);
    assert.equal(sources.retryDelay("Wed, 21 Oct 2026 12:00:02 GMT", 0,
        Date.parse("Wed, 21 Oct 2026 12:00:00 GMT")), 2000);
    assert.throws(() => sources.retryDelay("60", 0), /longer than/);
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async () => new Response("", { status: 429, headers: { "Retry-After": "60" } }),
        delay: () => { throw new Error("Must not retry earlier than requested"); }
    }), /longer than/);

    for (const response of [
        () => new Response("oops", { headers: { "Content-Type": "text/html" } }),
        () => new Response("", { headers: { "Content-Type": "image/png" } }),
        () => new Response(png, { headers: {
            "Content-Type": "image/png", "Content-Length": String(sources.MAX_SOURCE_BYTES + 1)
        } })
    ]) {
        requests = 0;
        await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
            fetchTile: async () => { requests++; return response(); }, delay: noDelay
        }));
        assert.equal(requests, 1);
    }
    let streamCancelled = false;
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        fetchTile: async () => new Response(new ReadableStream({
            start(controller) {
                controller.enqueue(new Uint8Array(sources.MAX_SOURCE_BYTES));
                controller.enqueue(new Uint8Array(1));
            },
            cancel() { streamCancelled = true; }
        }), { headers: { "Content-Type": "image/png" } }), delay: noDelay
    }), /1 MiB/);
    assert(streamCancelled);

    requests = 0;
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        timeoutMs: 1, delay: noDelay,
        fetchTile: (url, { signal }) => new Promise((resolve, reject) => {
            requests++;
            signal.addEventListener("abort", () => reject(new DOMException("timeout", "AbortError")), { once: true });
        })
    }), /timed out/);
    assert.equal(requests, 3);
    const controller = new AbortController();
    requests = 0;
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        signal: controller.signal, delay: noDelay,
        fetchTile: (url, { signal }) => new Promise((resolve, reject) => {
            requests++;
            signal.addEventListener("abort", () => reject(new DOMException("cancel", "AbortError")), { once: true });
            controller.abort();
        })
    }), /cancelled/);
    assert.equal(requests, 1);
    const cancelled = new AbortController();
    cancelled.abort();
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        signal: cancelled.signal, fetchTile: () => { throw new Error("must not request"); }
    }), /cancelled/);
    await assert.rejects(sources.fetchImage("https://fixture.invalid/tile", {
        signal: controller.signal,
        fetchTile: async () => image()
    }), /cancelled/);

    await assert.rejects(sources.googleHybrid(), /storage is unavailable/);

    const planner = globalThis.AeroGridMapPlanner;
    const area = { south: 25.997, north: 25.998, west: -97.158, east: -97.157 };
    const coverage = planner.coveragePlan(area, [17], "tx16s-mkii");
    const selection = { ...planner.specification("Test", coverage.bounds, [17], "tx16s-mkii", coverage),
        selectedBounds: area, coverageMode: "full-area-clamped" };
    let decoded = 0;
    const source = sources.httpSource({ ...pack.SYNTHETIC, id: "local-test-rgb1" },
        (z, x, y) => `https://fixture.invalid/${z}/${x}/${y}`, {
            fetchTile: async () => image(),
            convert: async blob => {
                assert.equal(blob.type, "image/png");
                decoded++;
                return compatible;
            }
        });
    const generated = await pack.createFiles(selection, "fixture", { source });
    assert.equal(decoded, selection.tileCount);
    assert([...generated.keys()].some(name => name.startsWith("AEROGRID/maps/tiles/local-test-rgb1/")));
    assert(Buffer.from(generated.get("AEROGRID/maps/areas/fixture.yaml")).includes(
        Buffer.from('imagerySet: "local-test-rgb1"')));
    assert([...generated.keys()].every(name => !name.includes("/sources/") && !name.includes("/selections/")));
    const jpegFiles = await pack.createFiles(selection, "jpeg-field", { source: {
        metadata: { ...pack.SYNTHETIC, id: "jpeg-test" },
        readTile: async () => compatible
    } });
    const jpegManifest = Buffer.from(jpegFiles.get("AEROGRID/maps/areas/jpeg-field.yaml"));
    assert(jpegManifest.includes(Buffer.from('imageFormat: "jpeg"')));
    assert([...jpegFiles.keys()].some(name => name.endsWith(".jpg")));
    await assert.rejects(pack.createFiles(selection, "bad", { source: {
        metadata: pack.SYNTHETIC, readTile: async () => png
    } }), /compatible.*JPEG/);
    await assert.rejects(pack.createFiles(selection, "bad", { source: {
        metadata: pack.SYNTHETIC, imageFormat: "jpeg", readRgb: async () => new Uint8Array()
    } }), /provenance/);
    const failed = sources.httpSource({ ...pack.SYNTHETIC, id: "failed" }, () => "https://fixture.invalid", {
        fetchTile: async () => new Response("", { status: 404 })
    });
    await assert.rejects(pack.createFiles(selection, "fixture", { source: failed }), /Tile 17\/.*HTTP 404/);
    for (const invalid of [{}, { metadata: pack.SYNTHETIC }, { readRgb() {}, metadata: {} }]) {
        await assert.rejects(pack.createFiles(selection, "fixture", { source: invalid }), /provenance/);
    }
    const invalidTile = { metadata: pack.SYNTHETIC, readTile: async () => new Uint8Array(4) };
    await assert.rejects(pack.createFiles(selection, "fixture", { source: invalidTile }), /JPEG/);
    const decodeFailure = sources.httpSource(pack.SYNTHETIC, () => "https://fixture.invalid", {
        fetchTile: async () => image(), convert: () => { throw new Error("Invalid image stream"); }
    });
    await assert.rejects(pack.createFiles(selection, "fixture", { source: decodeFailure }), /Tile 17\/.*Invalid image stream/);
    console.log("Source streaming, retries, timeouts, cancellation, RGB conversion and replaceable-provider checks passed.");
})().catch(error => { console.error(error); process.exitCode = 1; });
