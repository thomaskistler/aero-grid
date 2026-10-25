// SPDX-License-Identifier: GPL-2.0-only
"use strict";

const { execFileSync } = require("node:child_process");
const path = require("node:path");
const zlib = require("node:zlib");
const cache = new Map();
function jpeg(rgb) {
    const key = Buffer.from(rgb).toString("base64");
    if (!cache.has(key)) {
        const encoded = execFileSync(process.env.MAP_TEST_PYTHON ||
            path.join(__dirname, "../build/venv/bin/python"), ["-c",
            "import sys; from PIL import Image; " +
            "Image.frombytes('RGB',(256,256),sys.stdin.buffer.read()).save(sys.stdout.buffer,format='JPEG',quality=90,subsampling=0)"],
        { input: rgb });
        cache.set(key, new Uint8Array(encoded));
    }
    return cache.get(key);
}
function png(rgb) {
    const rows = Buffer.alloc(256 * 769);
    for (let y = 0; y < 256; y++) Buffer.from(rgb).copy(rows, y * 769 + 1, y * 768, (y + 1) * 768);
    function chunk(type, bytes) {
        const body = Buffer.concat([Buffer.from(type), bytes]);
        let crc = 0xffffffff;
        for (const byte of body) {
            crc ^= byte;
            for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
        }
        const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
        length.writeUInt32BE(bytes.length);
        checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
        return Buffer.concat([length, body, checksum]);
    }
    const header = Buffer.from([0, 0, 1, 0, 0, 0, 1, 0, 8, 2, 0, 0, 0]);
    return new Uint8Array(Buffer.concat([Buffer.from("\x89PNG\r\n\x1a\n", "latin1"),
        chunk("IHDR", header), chunk("IDAT", zlib.deflateSync(rows)), chunk("IEND", Buffer.alloc(0))]));
}
module.exports = { jpeg, png };
