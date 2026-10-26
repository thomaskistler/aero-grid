// SPDX-License-Identifier: GPL-2.0-only
(function (root) {
    "use strict";

    const MAX_SOURCE_BYTES = 1024 * 1024;
    const REQUEST_TIMEOUT_MS = 30000;
    const MAX_RETRIES = 2;
    const MAX_RETRY_DELAY_MS = 10000;

    function cancelled(signal) {
        if (signal && signal.aborted) throw new Error("Download cancelled.");
    }
    function wait(milliseconds, signal) {
        return new Promise((resolve, reject) => {
            cancelled(signal);
            const abort = () => {
                clearTimeout(timer);
                reject(new Error("Download cancelled."));
            };
            const timer = setTimeout(() => {
                if (signal) signal.removeEventListener("abort", abort);
                resolve();
            }, milliseconds);
            if (signal) signal.addEventListener("abort", abort, { once: true });
        });
    }
    function retryDelay(value, attempt, now = Date.now()) {
        if (value !== null && value !== undefined) {
            const seconds = /^\d+$/.test(value.trim()) ? Number(value) : NaN;
            const milliseconds = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(value) - now;
            if (Number.isFinite(milliseconds)) {
                if (milliseconds > MAX_RETRY_DELAY_MS) {
                    throw new Error("The source requested a retry delay longer than 10 seconds. Try again later.");
                }
                return Math.max(0, milliseconds);
            }
        }
        return 500 * 2 ** attempt;
    }

    async function responseImage(response) {
        const type = (response.headers.get("Content-Type") || "").split(";")[0].trim().toLowerCase();
        if (!["image/png", "image/jpeg", "image/webp"].includes(type)) {
            if (response.body) await response.body.cancel();
            throw new Error("The source did not return a PNG, JPEG or WebP image.");
        }
        const length = response.headers.get("Content-Length");
        if (length !== null && Number(length) > MAX_SOURCE_BYTES) {
            if (response.body) await response.body.cancel();
            throw new Error("Source image exceeds the 1 MiB response limit.");
        }
        if (!response.body) throw new Error("The source returned an empty response body.");
        const reader = response.body.getReader();
        const chunks = [];
        let size = 0, complete = false;
        try {
            for (;;) {
                const { done, value } = await reader.read();
                if (done) { complete = true; break; }
                size += value.byteLength;
                if (size > MAX_SOURCE_BYTES) throw new Error("Source image exceeds the 1 MiB response limit.");
                chunks.push(value);
            }
        } finally {
            try { if (!complete) await reader.cancel(); }
            finally { reader.releaseLock(); }
        }
        if (!size) throw new Error("The source returned an empty image.");
        return new Blob(chunks, { type });
    }

    async function fetchImage(url, { signal, fetchTile = root.fetch.bind(root), delay = wait,
        timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
        for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
            cancelled(signal);
            const controller = new AbortController();
            const abort = () => controller.abort();
            if (signal) signal.addEventListener("abort", abort, { once: true });
            let timedOut = false;
            const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
            let retry = false, pause = 500 * 2 ** attempt;
            try {
                let response;
                try {
                    response = await fetchTile(url, {
                        mode: "cors", credentials: "omit", signal: controller.signal
                    });
                } catch (error) {
                    cancelled(signal);
                    if (attempt === MAX_RETRIES) {
                        throw new Error(timedOut ? "Image request timed out after three attempts." :
                            "Unable to fetch image. Check the connection and source CORS support.");
                    }
                    retry = true;
                }
                if (response) {
                    if (!response.ok) {
                        if (response.body) await response.body.cancel();
                        if (![408, 429, 500, 502, 503, 504].includes(response.status) || attempt === MAX_RETRIES) {
                            throw new Error(`Source returned HTTP ${response.status}.`);
                        }
                        pause = retryDelay(response.headers.get("Retry-After"), attempt);
                        retry = true;
                    } else {
                        try {
                            const blob = await responseImage(response);
                            cancelled(signal);
                            return blob;
                        } catch (error) {
                            cancelled(signal);
                            // Invalid content is permanent; only interrupted
                            // network reads retry. Never substitute a blank tile.
                            if (timedOut && attempt === MAX_RETRIES) {
                                throw new Error("Image request timed out after three attempts.");
                            }
                            if ((!timedOut && error.name !== "TypeError") || attempt === MAX_RETRIES) throw error;
                            retry = true;
                        }
                    }
                }
            } finally {
                clearTimeout(timer);
                if (signal) signal.removeEventListener("abort", abort);
            }
            if (retry) await delay(pause, signal);
        }
        throw new Error("Image download did not complete.");
    }

    function rgbaToRgb(pixels, width, height) {
        if (width !== 256 || height !== 256 || !pixels || pixels.length !== 256 * 256 * 4) {
            throw new Error("Source images must decode to exactly 256x256 pixels; no resizing is performed.");
        }
        const rgb = new Uint8Array(256 * 256 * 3);
        for (let src = 0, dest = 0; src < pixels.length; src += 4, dest += 3) {
            if (pixels[src + 3] !== 255) throw new Error("Source imagery must be opaque; transparent tiles are not accepted.");
            rgb[dest] = pixels[src]; rgb[dest + 1] = pixels[src + 1]; rgb[dest + 2] = pixels[src + 2];
        }
        return rgb;
    }

    function imageDimensions(bytes, type) {
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const text = (offset, length) => String.fromCharCode(...bytes.subarray(offset, offset + length));
        if (type === "image/png" && bytes.length >= 33 &&
            text(0, 8) === "\x89PNG\r\n\x1a\n" && view.getUint32(8) === 13 && text(12, 4) === "IHDR") {
            return [view.getUint32(16), view.getUint32(20)];
        }
        if (type === "image/jpeg" && bytes.length >= 4 && view.getUint16(0) === 0xffd8) {
            let offset = 2;
            while (offset + 4 <= bytes.length && bytes[offset++] === 0xff) {
                while (bytes[offset] === 0xff) offset++;
                const marker = bytes[offset++];
                if (marker === 0xda || marker === 0xd9 || offset + 2 > bytes.length) break;
                if (marker === 1 || marker >= 0xd0 && marker <= 0xd7) continue;
                const length = view.getUint16(offset);
                if (length < 2 || offset + length > bytes.length) break;
                if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker) &&
                    length >= 8) return [view.getUint16(offset + 5), view.getUint16(offset + 3)];
                offset += length;
            }
        }
        if (type === "image/webp" && bytes.length >= 30 && text(0, 4) === "RIFF" && text(8, 4) === "WEBP") {
            const kind = text(12, 4);
            if (kind === "VP8X") {
                const little24 = offset => bytes[offset] + bytes[offset + 1] * 256 + bytes[offset + 2] * 65536;
                return [little24(24) + 1, little24(27) + 1];
            }
            if (kind === "VP8 " && text(23, 3) === "\x9d\x01\x2a") {
                return [view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff];
            }
            if (kind === "VP8L" && bytes[20] === 0x2f) {
                const dimensions = view.getUint32(21, true);
                return [(dimensions & 0x3fff) + 1, ((dimensions >>> 14) & 0x3fff) + 1];
            }
        }
        throw new Error("Invalid or unsupported source image header.");
    }

    async function decodeRgb(blob, signal) {
        cancelled(signal);
        if (!(blob instanceof Blob) || !blob.size || blob.size > MAX_SOURCE_BYTES) {
            throw new Error("Source image is empty or exceeds the 1 MiB response limit.");
        }
        const [width, height] = imageDimensions(new Uint8Array(await blob.arrayBuffer()), blob.type);
        if (width !== 256 || height !== 256) {
            throw new Error("Source images must be exactly 256x256 pixels; no resizing is performed.");
        }
        cancelled(signal);
        if (typeof root.createImageBitmap !== "function" || typeof document === "undefined") {
            throw new Error("This browser cannot decode map images. Use a current desktop browser.");
        }
        const bitmap = await root.createImageBitmap(blob, {
            imageOrientation: "none", premultiplyAlpha: "none", colorSpaceConversion: "none"
        });
        try {
            cancelled(signal);
            if (bitmap.width !== 256 || bitmap.height !== 256) {
                throw new Error("Source images must decode to exactly 256x256 pixels; no resizing is performed.");
            }
            const canvas = document.createElement("canvas");
            canvas.width = canvas.height = 256;
            const context = canvas.getContext("2d", { willReadFrequently: true });
            if (!context) throw new Error("Unable to create the image conversion canvas.");
            context.drawImage(bitmap, 0, 0);
            const rgb = rgbaToRgb(context.getImageData(0, 0, 256, 256).data, bitmap.width, bitmap.height);
            cancelled(signal);
            return rgb;
        } finally {
            bitmap.close();
        }
    }

    function httpSource(metadata, tileUrl, dependencies = {}) {
        return {
            metadata: Object.freeze({ ...metadata }),
            async readTile(zoom, x, y, signal) {
                try {
                    const blob = await fetchImage(tileUrl(zoom, x, y), { ...dependencies, signal });
                    const image = await (dependencies.convert || radioJpeg)(blob, signal);
                    cancelled(signal);
                    return image;
                } catch (error) {
                    throw new Error(`Tile ${zoom}/${x}/${y}: ${error.message}`);
                }
            }
        };
    }

    function compatibleJpeg(bytes) {
        if (bytes.length < 4 || bytes[0] !== 255 || bytes[1] !== 216 ||
            bytes[bytes.length - 2] !== 255 || bytes[bytes.length - 1] !== 217) return false;
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        let offset = 2, frame = false;
        const limit = Math.min(bytes.length, 4096);
        while (offset + 4 <= limit && bytes[offset++] === 255) {
            while (offset < limit && bytes[offset] === 255) offset++;
            if (offset + 2 >= limit) return false;
            const marker = bytes[offset++];
            if (marker === 0xda) return frame;
            if (marker === 0xe1 || marker === 0xd9) return false; // Re-encode EXIF, including orientation.
            const length = view.getUint16(offset);
            if (length < 2 || offset + length > limit) return false;
            if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
                if (![0xc0, 0xc2].includes(marker) || length !== 17 || bytes[offset + 2] !== 8 ||
                    view.getUint16(offset + 3) !== 256 || view.getUint16(offset + 5) !== 256 ||
                    bytes[offset + 7] !== 3) return false;
                frame = true;
            }
            offset += length;
        }
        return false;
    }

    async function radioJpeg(blob, signal) {
        // Full decode validates dimensions and opacity, even for byte-preserved input.
        const rgb = await decodeRgb(blob, signal);
        const original = new Uint8Array(await blob.arrayBuffer());
        if (blob.type === "image/jpeg" && original.length <= 256 * 1024 && compatibleJpeg(original)) return original;
        return encodeJpeg(rgb, signal);
    }

    async function encodeJpeg(rgb, signal) {
        cancelled(signal);
        if (!(rgb instanceof Uint8Array) || rgb.length !== 256 * 256 * 3) {
            throw new Error("Tile input must be exactly 256x256 opaque RGB pixels.");
        }
        if (typeof document === "undefined") throw new Error("JPEG encoding requires a browser canvas.");
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 256;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("Unable to create the JPEG conversion canvas.");
        const pixels = context.createImageData(256, 256);
        for (let src = 0, dest = 0; src < rgb.length; src += 3, dest += 4) {
            pixels.data.set(rgb.subarray(src, src + 3), dest);
            pixels.data[dest + 3] = 255;
        }
        context.putImageData(pixels, 0, 0);
        const encoded = await new Promise((resolve, reject) => {
            canvas.toBlob(value => value ? resolve(value) : reject(new Error("JPEG encoding failed.")), "image/jpeg", 0.9);
        });
        cancelled(signal);
        const bytes = new Uint8Array(await encoded.arrayBuffer());
        if (!compatibleJpeg(bytes) || bytes.length > 256 * 1024) {
            throw new Error("Browser did not produce a compatible 256x256 JPEG within 256 KiB.");
        }
        return bytes;
    }

    function libraryDatabase() {
        return new Promise((resolve, reject) => {
            if (!root.indexedDB) {
                reject(new Error("Browser map storage is unavailable. Use a desktop browser with site storage enabled."));
                return;
            }
            const request = root.indexedDB.open("aerogrid-map-library-jpeg-v1", 1);
            let blocked = false;
            request.onupgradeneeded = () => request.result.createObjectStore("entries");
            request.onerror = () => reject(new Error(`Unable to open browser map storage: ${request.error.message}`));
            request.onblocked = () => {
                blocked = true;
                reject(new Error("Browser map storage is blocked. Close other planner tabs and retry."));
            };
            request.onsuccess = () => {
                if (blocked) { request.result.close(); return; }
                request.result.onversionchange = () => request.result.close();
                resolve(request.result);
            };
        });
    }

    function libraryTransaction(database, mode, operation) {
        return new Promise((resolve, reject) => {
            const transaction = database.transaction("entries", mode);
            let result;
            transaction.oncomplete = () => resolve(result);
            transaction.onabort = () => reject(new Error(
                `Unable to save/read browser map library: ${transaction.error ? transaction.error.message : "transaction aborted"}. ` +
                "Check available site storage. Clearing this site's data starts a new library; it does not change radio files."));
            operation(transaction.objectStore("entries"), value => { result = value; });
        });
    }

    async function sharedSource(metadata, tileUrl) {
        const database = await libraryDatabase();
        try {
            // Read/write transactions serialize initialization and tile insertion
            // across tabs, so concurrent exports cannot replace cached pixels.
            const library = await libraryTransaction(database, "readwrite", (store, done) => {
                const request = store.get("library");
                request.onsuccess = () => {
                    const value = request.result || { metadata, bytes: 0 };
                    if (!request.result) store.add(value, "library");
                    done(value);
                };
            });
            return {
                metadata: Object.freeze({ ...library.metadata }),
                close() { database.close(); },
                async readTile(zoom, x, y, signal) {
                    cancelled(signal);
                    const key = `${zoom}/${x}/${y}`;
                    const existing = await libraryTransaction(database, "readonly", (store, done) => {
                        const request = store.get(key);
                        request.onsuccess = () => done(request.result);
                    });
                    if (existing) {
                        cancelled(signal);
                        if (!compatibleJpeg(existing)) throw new Error("Saved JPEG is invalid. Clear this site's map storage and retry.");
                        return existing;
                    }
                    const image = await fetchImage(tileUrl(zoom, x, y), { signal });
                    const jpeg = await radioJpeg(image, signal);
                    cancelled(signal);
                    const saved = await libraryTransaction(database, "readwrite", (store, done) => {
                        const request = store.get(key);
                        request.onsuccess = () => {
                            if (request.result) { done(request.result); return; }
                            const state = store.get("library");
                            state.onsuccess = () => {
                                const value = state.result;
                                if (value.bytes + jpeg.length > 128 * 1024 * 1024) {
                                    done(null);
                                    return;
                                }
                                value.bytes += jpeg.length;
                                store.put(value, "library");
                                store.add(jpeg, key);
                                done(jpeg);
                            };
                        };
                    });
                    if (!saved) {
                        throw new Error("Browser map library reached its 128 MiB limit. " +
                            "Clearing this site's data starts a new library; existing radio files are unchanged.");
                    }
                    cancelled(signal);
                    return saved;
                }
            };
        } catch (error) {
            database.close();
            throw error;
        }
    }

    async function googleHybrid() {
        if (!root.crypto || typeof root.crypto.randomUUID !== "function") {
            throw new Error("Secure random IDs are unavailable. Open this page over HTTPS or localhost.");
        }
        // This is a local first-capture library, not an upstream imagery edition.
        const snapshot = root.crypto.randomUUID();
        return sharedSource({
            id: `google-${snapshot.replace(/-/g, "").slice(0, 20)}`,
            source: "Google hybrid",
            edition: snapshot,
            conversion: "jpeg-preserve-or-browser-q90-v1",
            license: "Google and third-party imagery terms; offline permission not verified by AeroGrid",
            termsUrl: "https://developers.google.com/maps/documentation/tile/policies",
            attribution: "Google and imagery providers (see source terms for required attribution)",
            synthetic: false,
            immutableSource: false,
            cachePolicy: "first-capture-per-tile",
            capturedAt: new Date().toISOString()
        }, (zoom, x, y) => `https://mt1.google.com/vt?lyrs=y&x=${x}&y=${y}&z=${zoom}`);
    }

    root.AeroGridMapSources = { googleHybrid, httpSource, fetchImage, decodeRgb, radioJpeg, encodeJpeg, compatibleJpeg, rgbaToRgb,
        imageDimensions, retryDelay, MAX_SOURCE_BYTES, REQUEST_TIMEOUT_MS, MAX_RETRIES, MAX_RETRY_DELAY_MS };
})(globalThis);
