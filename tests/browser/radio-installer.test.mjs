// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  child, compareVersions, inspectRoot, inspectWidget, packageVersion,
  parseRadioMetadata, parseVersion, radioHardware, radioCompatibility, RadioStorage,
} from "../../docs/javascripts/radio-storage.mjs";
import {
  actionFor, ContentMismatchError, loadCatalog, loadRelease, preparePackage,
  replaceWidget, sha256, validateManifest, verifyInstalled,
} from "../../docs/javascripts/radio-installer.mjs";

const encoder = new TextEncoder();
const base = new URL("https://example.test/aero-grid/installer/");

test("compatibility requires known color hardware and stable EdgeTX 2.11.0 or later", () => {
  for (const version of ["2.11.0", "2.11.9", "2.12.4", "3.0.0"]) {
    assert.equal(radioCompatibility({ board: "tx16s", version }).supported, true);
  }
  for (const radio of [
    null, { board: null, version: "2.12.4" }, { board: "future", version: "2.12.4" },
    { board: "boxer", version: "2.12.4" }, { board: "tx16s", version: null },
    { board: "tx16s", version: "invalid" }, { board: "tx16s", version: "2.10.9" },
    { board: "tx16s", version: "2.11.0-rc.1" }, { board: "tx16s", version: "2.13.0-rc.1" },
  ]) {
    const result = radioCompatibility(radio);
    assert.equal(result.supported, false);
    assert.match(result.message, /Install at your own risk/);
  }
});

test("radio hardware inference handles verified display families and unknown boards", () => {
  assert.deepEqual(radioHardware("tx16s"), { type: "RadioMaster TX16S", screen: "Color - 480 x 272" });
  assert.equal(radioHardware("TX16S").type, "RadioMaster TX16S");
  for (const [board, screen] of [
    ["t15", "Color - 480 x 320"], ["tx15", "Color - 480 x 320"],
    ["tx16smk3", "Color - 800 x 480"], ["nv14", "Color - 320 x 480"],
    ["el18", "Color - 320 x 480"], ["pl18", "Color - 480 x 320"],
    ["x9d+", "Monochrome - 212 x 64"], ["boxer", "Monochrome - 128 x 64"],
  ]) assert.equal(radioHardware(board).screen, screen);
  assert.deepEqual(radioHardware("future-radio"), { type: "future-radio", screen: "Unknown" });
  assert.deepEqual(radioHardware(null), { type: "Unknown", screen: "Unknown" });
  assert.deepEqual(radioHardware("toString"), { type: "toString", screen: "Unknown" });
  assert.equal(parseRadioMetadata("board: x9d+2019\nsemver: 2.12.0").board, "x9d+2019");
});

class MemoryFile {
  kind = "file";
  constructor(name, data, context, path) {
    Object.assign(this, { name, data: encoder.encode(data), context, path });
  }
  async getFile() {
    if (this.context.unplugged) throw new DOMException("Drive removed", "NotReadableError");
    return new File([this.data], this.name);
  }
  async createWritable() {
    this.context.events.push(`open:${this.path}`);
    if (this.context.failOpen) throw new Error("Disk full");
    return {
      write: async (bytes) => {
        if (this.context.failWrite) throw new Error("USB write failed");
        this.data = new Uint8Array(bytes);
        this.context.events.push(`write:${this.path}`);
        if (this.context.corrupt) this.data = encoder.encode("corrupt");
      },
      close: async () => {
        if (this.context.failClose) throw new Error("USB close failed");
        this.context.events.push(`close:${this.path}`);
      },
      abort: async () => this.context.events.push(`abort:${this.path}`),
    };
  }
}

class MemoryDirectory {
  kind = "directory";
  constructor(name = "RADIO SD", context = { events: [] }, path = "") {
    Object.assign(this, { name, context, path, children: new Map() });
  }
  async *entries() {
    if (this.context.unplugged) throw new DOMException("Drive removed", "NotReadableError");
    this.context.scans?.push(this.path);
    yield* this.children.entries();
  }
  async getDirectoryHandle(name, options = {}) {
    this.context.directoryLookups?.push(this.path + name);
    if (!this.children.has(name) && options.create) {
      this.children.set(name, new MemoryDirectory(name, this.context, this.path + name + "/"));
      this.context.events.push(`mkdir:${this.path}${name}`);
    }
    const result = this.children.get(name);
    if (!result) throw new DOMException("Missing directory", "NotFoundError");
    if (result.kind !== "directory") throw new DOMException("Wrong kind", "TypeMismatchError");
    return result;
  }
  async getFileHandle(name, options = {}) {
    if (!this.children.has(name) && options.create) {
      this.children.set(name, new MemoryFile(name, "", this.context, this.path + name));
      this.context.events.push(`create:${this.path}${name}`);
    }
    const result = this.children.get(name);
    if (!result) throw new DOMException("Missing file", "NotFoundError");
    if (result.kind !== "file") throw new DOMException("Wrong kind", "TypeMismatchError");
    return result;
  }
  async removeEntry(name, options = {}) {
    this.context.events.push(`delete:${this.path}${name}`);
    if (this.context.failDelete) throw new Error("Delete failed");
    const entry = this.children.get(name);
    if (entry?.kind === "directory" && entry.children.size && !options.recursive) {
      throw new DOMException("Directory not empty", "InvalidModificationError");
    }
    if (this.context.appleDouble) this.children.delete(`._${name}`);
    if (!this.children.delete(name)) throw new DOMException("Missing entry", "NotFoundError");
  }
  async requestPermission() {
    return this.context.denied ? "denied" : "granted";
  }
}

async function put(root, path, data) {
  const parts = path.split("/");
  let dir = root;
  for (const part of parts.slice(0, -1)) dir = await dir.getDirectoryHandle(part, { create: true });
  const file = new MemoryFile(parts.at(-1), data, root.context, path);
  dir.children.set(file.name, file);
  return file;
}

async function fixture(widget = "old") {
  const root = new MemoryDirectory();
  await put(root, "RADIO/radio.yml", 'board: tx16s\r\nsemver: "2.12.4"\r\n');
  await put(root, "MODELS/model1.yml", "user model");
  await put(root, "SCRIPTS/TOOLS/tool.lua", "user tool");
  await put(root, "AEROGRID/layouts/User.yaml", "user layout");
  await put(root, "AEROGRID/themes/custom.yml", "user theme");
  await put(root, "AEROGRID/layout-registry.txt", "user registry");
  await put(root, "MAPS/tiles/tile.png", "user map");
  await put(root, "FIRMWARE/edgetx_tx16s-v99.0.0.bin", "not flashed");
  await put(root, "edgetx.sdcard.version", "2.11");
  await put(root, "WIDGETS/Other/main.lua", "other widget");
  if (widget === "old") {
    await put(root, "WIDGETS/AeroGrid/lib/package.lua", 'return {\n version = "0.1.0",\n}');
    await put(root, "WIDGETS/AeroGrid/main.luac", "stale bytecode");
    await put(root, "WIDGETS/AeroGrid/custom.txt", "will be removed");
  }
  if (widget === "unknown") await put(root, "WIDGETS/AeroGrid/main.lua", "partial");
  root.context.events = [];
  return root;
}

async function releaseFixture() {
  const content = {
    "main.lua": encoder.encode("return {}"),
    "lib/package.lua": encoder.encode('return {\n version = "0.4.0",\n}'),
    "assets/satellite.png": new Uint8Array([0, 255, 8, 64]),
  };
  const manifest = {
    schema: 1, version: "0.4.0",
    release: "https://github.com/thomaskistler/aero-grid/releases/tag/v0.4.0",
    archiveSha256: "a".repeat(64),
    files: await Promise.all(Object.entries(content).map(async ([path, bytes]) => ({
      path, size: bytes.length, sha256: await sha256(bytes),
    }))),
  };
  const release = {
    tag_name: "v0.4.0", draft: false, prerelease: false,
    assets: ["AeroGrid-0.4.0.zip", "AeroGrid-0.4.0.zip.sha256"].map((name) => ({
      name, browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/v0.4.0/${name}`,
    })),
  };
  const fetcher = async (url) => {
    const address = String(url);
    if (address === "https://api.github.com/repos/thomaskistler/aero-grid/releases/tags/v0.4.0") return Response.json(release);
    if (address === new URL("releases/0.4.0/manifest.json", base).href) return Response.json(manifest);
    const path = address.split("/releases/0.4.0/")[1];
    return path in content ? new Response(content[path]) : new Response("missing", { status: 404 });
  };
  return { manifest, content, release, fetcher };
}

async function snapshot(root) {
  const result = {};
  async function walk(directory, prefix) {
    for await (const [name, handle] of directory.entries()) {
      if (handle.kind === "directory") await walk(handle, prefix + name + "/");
      else result[prefix + name] = [...new Uint8Array(await (await handle.getFile()).arrayBuffer())];
    }
  }
  await walk(root, "");
  return result;
}

test("radio metadata reads only unique top-level board/semver scalars", () => {
  assert.deepEqual(parseRadioMetadata('\uFEFFboard: "tx16s" # radio\r\nsemver: \'2.12.4\'\r\n'), {
    board: "tx16s", version: "2.12.4",
  });
  for (const text of ["", " board: tx16s\n semver: 2.12.4", "board: x\nboard: y\nsemver: nope",
    "board: [tx16s]\nsemver: {x: 2.12.4}", "board: &ref tx16s\nsemver: *version"]) {
    assert.deepEqual(parseRadioMetadata(text), { board: null, version: null });
  }
  assert.deepEqual(parseRadioMetadata("board: tx16s\nsemver: bad"), { board: "tx16s", version: null });
  assert.deepEqual(parseRadioMetadata("board: ???\nsemver: 3.0.0"), { board: null, version: "3.0.0" });
});

test("semantic versions order numerically, honor prereleases, and reject malformed values", () => {
  for (const version of ["01.2.3", "1.2", "1.2.3-beta.01", "a.b.c", "999999999999999999999.0.0"]) {
    assert.equal(parseVersion(version), null);
  }
  assert.equal(compareVersions("0.10.0", "0.4.0"), 1);
  assert.equal(compareVersions("1.0.0-rc.2", "1.0.0-rc.10"), -1);
  assert.equal(compareVersions("1.0.0", "1.0.0-beta.1"), 1);
  assert.equal(compareVersions("1.0.0+build.2", "1.0.0+build.1"), 0);
  assert.equal(compareVersions("1.0.0-a", "1.0.0-a.1"), -1);
  assert.equal(compareVersions("1.0.0-1", "1.0.0-a"), -1);
  assert.equal(compareVersions("1.0.0-beta.2", "1.0.0-beta.2"), 0);
});

test("package metadata is text only; commented/ambiguous/invalid versions stay unknown", () => {
  assert.equal(packageVersion('return {\nversion = "1.2.3",\n}'), "1.2.3");
  assert.equal(packageVersion('-- version = "9.9.9"\nreturn {\nversion = "1.2.3",\n}'), "1.2.3");
  assert.equal(packageVersion('--[[\nversion = "9.9.9"\n]]\nreturn {}'), null);
  assert.equal(packageVersion('version = "1.2.3"\nversion = "1.2.4"'), null);
  assert.equal(packageVersion('version = "bad"'), null);
});

test("connection is read-only, validates root, and ignores firmware filenames and SD pack version", async () => {
  const root = await fixture();
  const storage = new RadioStorage(async (options) => {
    assert.equal(options.mode, "read");
    return root;
  });
  assert.deepEqual(await storage.connect(), { board: "tx16s", version: "2.12.4", name: "RADIO SD" });
  assert.deepEqual((await storage.inspect()).widget, { present: true, version: "0.1.0" });
  assert.deepEqual(root.context.events, []);
  storage.disconnect();
  assert.equal(storage.root, null);
  const wrong = new RadioStorage(async () => root.children.get("WIDGETS"));
  await assert.rejects(wrong.connect(), /SD-card root/);
  assert.equal(wrong.root, null);
});

test("cancel, denial, unplug and read errors do not report successful access", async () => {
  const storage = new RadioStorage(async () => { throw new DOMException("Cancelled", "AbortError"); });
  await assert.rejects(storage.connect(), { name: "AbortError" });
  assert.equal(storage.root, null);
  const root = await fixture();
  storage.picker = async () => root;
  await storage.connect();
  root.context.denied = true;
  await assert.rejects(storage.requestWritePermission(), /denied/);
  assert.deepEqual(root.context.events, []);
  root.context.unplugged = true;
  await assert.rejects(storage.inspect(), { name: "NotReadableError" });
});

test("missing/invalid YAML fields are independent unknowns; oversize metadata is an error", async () => {
  const root = await fixture();
  root.children.get("RADIO").children.delete("radio.yml");
  assert.equal((await inspectRoot(root)).version, null);
  await put(root, "RADIO/radio.yml", "x".repeat(256 * 1024 + 1));
  await assert.rejects(inspectRoot(root), /metadata size/);
});

test("widget absence, unknown version and ambiguous entries are distinct", async () => {
  assert.deepEqual(await inspectWidget(await fixture("absent")), { present: false, version: null });
  assert.deepEqual(await inspectWidget(await fixture("unknown")), { present: true, version: null });
  const root = await fixture();
  await put(root, "WIDGETS/aerogrid/main.lua", "duplicate");
  await assert.rejects(inspectWidget(root), /Ambiguous/);
});

test("action selection installs, updates, shows equal and labels downgrades explicitly", () => {
  assert.equal(actionFor({ present: false }, "0.4.0").label, "Install AeroGrid v0.4.0");
  assert.match(actionFor({ present: false }, "0.4.0").label, /^Install/);
  assert.match(actionFor({ present: true, version: null }, "0.4.0").label, /^Update/);
  assert.equal(actionFor({ present: true, version: "0.4.0" }, "0.4.0").enabled, false);
  assert.equal(actionFor({ present: true, version: "0.5.0" }, "0.4.0").enabled, true);
  assert.match(actionFor({ present: true, version: "0.5.0" }, "0.4.0").label, /^Downgrade/);
  assert.equal(actionFor({ present: true, version: "0.4.0-beta.1" }, "0.4.0").enabled, true);
});

test("selected historical releases are pinned and cross-checked against their GitHub tag", async () => {
  const fixture = await releaseFixture();
  assert.deepEqual(await loadRelease(base, "0.4.0", fixture.fetcher), fixture.manifest);
  await assert.rejects(loadRelease(base, "../RADIO", fixture.fetcher), /Invalid selected/);
  await assert.rejects(loadRelease(base, "00.4.0", fixture.fetcher), /Invalid selected/);
  fixture.release.draft = true;
  await assert.rejects(loadRelease(base, "0.4.0", fixture.fetcher), /selected stable/);
  fixture.release.draft = false;
  fixture.release.tag_name = "v0.5.0";
  await assert.rejects(loadRelease(base, "0.4.0", fixture.fetcher), /selected stable/);
  fixture.release.tag_name = "v0.4.0";
  fixture.release.assets = [];
  await assert.rejects(loadRelease(base, "0.4.0", fixture.fetcher), /missing installation assets/);
  fixture.release.assets = ["AeroGrid-0.4.0.zip", "AeroGrid-0.4.0.zip.sha256"].map((name) => ({
    name, browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/v0.4.0/${name}`,
  }));
  fixture.manifest.version = "0.3.0";
  await assert.rejects(loadRelease(base, "0.4.0", fixture.fetcher), /does not match/);
});

test("release catalog validates entries, unavailable states, latest and numeric ordering", async () => {
  const entry = (version, available = true) => ({
    version, name: `AeroGrid ${version}`,
    release: `https://github.com/thomaskistler/aero-grid/releases/tag/v${version}`,
    available, reason: available ? null : "Missing installation assets.",
  });
  const catalog = { schema: 1, latest: "0.10.0", releases: [entry("0.2.0"), entry("0.10.0"), entry("0.3.0", false)] };
  const releases = ["0.2.0", "0.10.0", "0.3.0"].map((version) => ({
    tag_name: `v${version}`, name: `AeroGrid ${version}`, draft: false, prerelease: false,
    assets: [`AeroGrid-${version}.zip`, `AeroGrid-${version}.zip.sha256`].map((name) => ({
      name, browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/v${version}/${name}`,
    })),
  }));
  const fetcher = async (url) => Response.json(String(url).includes("api.github.com") ? releases : catalog);
  assert.deepEqual((await loadCatalog(base, fetcher)).releases.map((item) => item.version), ["0.10.0", "0.3.0", "0.2.0"]);
  for (const bad of [
    { ...catalog, releases: [null] },
    { ...catalog, releases: [...catalog.releases, entry("0.2.0")] },
    { ...catalog, releases: [entry("1.0.0-beta.1")] },
    { ...catalog, releases: [{ ...entry("0.10.0"), release: "https://example.com" }] },
    { ...catalog, releases: [{ ...entry("0.10.0"), available: "yes" }] },
    { ...catalog, releases: [{ ...entry("0.10.0", false), reason: null }] },
  ]) await assert.rejects(loadCatalog(base, async () => Response.json(bad)), /catalog|entry/);
  const live = [releases[0], { tag_name: "v0.11.0", name: "New release", draft: false, prerelease: false },
    { tag_name: "v0.12.0-beta.1", draft: false, prerelease: true }];
  const updated = await loadCatalog(base, async (url) =>
    Response.json(String(url).includes("api.github.com") ? live : catalog));
  assert.deepEqual(updated.releases.map((item) => item.version), ["0.11.0", "0.2.0"]);
  assert.equal(updated.latest, "0.11.0");
  assert.equal(updated.releases[0].available, false);
  const withoutCatalog = await loadCatalog(base, async (url) =>
    String(url).includes("api.github.com") ? Response.json(releases)
      : new Response("", { status: 404 }));
  assert.deepEqual(withoutCatalog.releases.map((item) => item.version), ["0.10.0", "0.3.0", "0.2.0"]);
  assert.ok(withoutCatalog.releases.every((item) => !item.available
    && item.reason === "Automatic installation files are not available on this site."));
  await assert.rejects(loadCatalog(base, async () =>
    new Response("", { status: 500 })), /HTTP 500/);
  await assert.rejects(loadCatalog(base, async (url) => String(url).includes("api.github.com")
    ? new Response("", { status: 403 }) : Response.json(catalog)), /HTTP 403/);
});

test("manifest rejects traversal, case/file collisions, bad hashes, counts and size limits", async () => {
  const { manifest } = await releaseFixture();
  for (const path of ["../RADIO/radio.yml", "/main.lua", "a\\b.lua", "a//b.lua", ".", "main.luac", "readme.txt"]) {
    const bad = structuredClone(manifest);
    bad.files[0].path = path;
    assert.throws(() => validateManifest(bad), /Unsafe|Incomplete/);
  }
  for (const extra of [
    { ...manifest.files[0], path: "MAIN.lua" },
    { ...manifest.files[0], path: "lib" },
    { ...manifest.files[0], path: "LIB/a.lua" },
    { ...manifest.files[0], path: "extra.lua", size: 2 * 1024 * 1024 + 1 },
    { ...manifest.files[0], path: "extra.lua", sha256: "bad" },
  ]) {
    assert.throws(() => validateManifest({ ...manifest, files: [...manifest.files, extra] }));
  }
  assert.throws(() => validateManifest({ ...manifest, version: "0.4.0-beta.1" }));
  assert.throws(() => validateManifest({ ...manifest, files: [] }));
  assert.throws(() => validateManifest({ ...manifest, files: Array(1501).fill(manifest.files[0]) }));
});

test("corrupt/missing downloads are rejected before any mutation", async () => {
  const root = await fixture();
  const { manifest, fetcher } = await releaseFixture();
  await assert.rejects(preparePackage(manifest, base, () => {}, async () => new Response("bad")), /verification/);
  await assert.rejects(preparePackage(manifest, base, () => {}, async () => new Response("", { status: 404 })), /HTTP 404/);
  const prepared = await preparePackage(manifest, base, () => {}, fetcher);
  prepared.files[0].bytes[0] ^= 1;
  await assert.rejects(replaceWidget(root, prepared), /Prepared content changed/);
  await assert.rejects(replaceWidget(root, { version: "0.4.0", files: [] }), /validate a complete/);
  assert.deepEqual(root.context.events, []);
});

test("downloads overlap in bounded batches, retain order and drain failures before returning", async () => {
  const { manifest, fetcher, content } = await releaseFixture();
  for (let index = 0; index < 8; index++) {
    const path = `assets/icon${index}.png`;
    content[path] = new Uint8Array([index]);
    manifest.files.push({ path, size: 1, sha256: await sha256(content[path]) });
  }
  let active = 0;
  let peak = 0;
  let requests = 0;
  const delayed = (fail = false) => async (url) => {
    requests++;
    peak = Math.max(peak, ++active);
    try {
      await new Promise((resolve) => setTimeout(resolve, 5));
      if (fail && String(url).endsWith("/main.lua")) throw new Error("Download failed");
      return await fetcher(url);
    } finally {
      active--;
    }
  };
  const progress = [];
  const prepared = await preparePackage(manifest, base, (_message, done) => progress.push(done), delayed());
  assert.equal(peak, 4);
  assert.equal(active, 0);
  assert.equal(requests, manifest.files.length);
  assert.deepEqual(prepared.files.map((file) => file.path), manifest.files.map((file) => file.path));
  assert.ok(progress.every((done, index) => index === 0 || done >= progress[index - 1]));
  assert.equal(progress.at(-1), manifest.files.length);
  requests = 0;
  await assert.rejects(preparePackage(manifest, base, () => {}, delayed(true)), /Download failed/);
  assert.equal(active, 0);
  assert.equal(requests, 4);
});

test("writing reuses directory handles and verification scans each widget directory only once", async () => {
  const root = await fixture();
  const { manifest, fetcher, content } = await releaseFixture();
  for (let index = 0; index < 8; index++) {
    const path = `assets/nested/icon${index}.png`;
    content[path] = new Uint8Array([index]);
    manifest.files.push({ path, size: 1, sha256: await sha256(content[path]) });
  }
  root.context.directoryLookups = [];
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
  assert.equal(root.context.directoryLookups.filter((path) => path === "WIDGETS/AeroGrid/assets").length, 1);
  assert.equal(root.context.directoryLookups.filter((path) => path === "WIDGETS/AeroGrid/assets/nested").length, 1);
  root.context.scans = [];
  root.context.events = [];
  await verifyInstalled(root, manifest);
  assert.deepEqual(root.context.scans.slice().sort(), [
    "", "WIDGETS/", "WIDGETS/AeroGrid/", "WIDGETS/AeroGrid/assets/",
    "WIDGETS/AeroGrid/assets/nested/", "WIDGETS/AeroGrid/lib/",
  ]);
  assert.deepEqual(root.context.events, []);
});

test("delete then replace removes stale/custom files, closes streams, verifies and preserves all other data", async () => {
  const root = await fixture();
  const original = await snapshot(root);
  const { manifest, fetcher } = await releaseFixture();
  const prepared = await preparePackage(manifest, base, () => {}, fetcher);
  assert.deepEqual(root.context.events, []);
  await replaceWidget(root, prepared);
  assert.equal(root.context.events[0], "delete:WIDGETS/AeroGrid/lib/package.lua");
  assert.equal(root.context.events.filter((event) => event.startsWith("delete:")).at(-1), "delete:WIDGETS/AeroGrid");
  assert.equal(root.context.events.filter((event) => event.startsWith("close:")).length, manifest.files.length);
  await verifyInstalled(root, manifest);
  assert.equal((await inspectWidget(root)).version, "0.4.0");
  const after = await snapshot(root);
  for (const [path, bytes] of Object.entries(original)) {
    if (!path.startsWith("WIDGETS/AeroGrid/")) assert.deepEqual(after[path], bytes, path);
  }
  assert.equal(after["WIDGETS/AeroGrid/main.luac"], undefined);
  assert.equal(after["WIDGETS/AeroGrid/custom.txt"], undefined);
  assert.ok(Object.keys(after).every((path) => path in original || path.startsWith("WIDGETS/AeroGrid/")));
  await put(root, "WIDGETS/AeroGrid/main.luac", "radio-generated bytecode");
  await verifyInstalled(root, manifest, () => {}, true);
  await assert.rejects(verifyInstalled(root, manifest), ContentMismatchError);
});

test("verification reports exact missing and unexpected paths without ignoring extra files", async () => {
  const root = await fixture();
  const { manifest, fetcher } = await releaseFixture();
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
  const widget = root.children.get("WIDGETS").children.get("AeroGrid");
  widget.children.delete("main.lua");
  await put(root, "WIDGETS/AeroGrid/._main.lua", "unexpected sidecar");
  await assert.rejects(verifyInstalled(root, manifest), (error) => {
    assert.ok(error instanceof ContentMismatchError);
    assert.match(error.message, /Missing files \(1\): "main\.lua"/);
    assert.match(error.message, /Unexpected files \(1\): "\._main\.lua"/);
    assert.deepEqual(error.differences, { missing: ["main.lua"], unexpected: ["._main.lua"] });
    return true;
  });
  await put(root, "WIDGETS/AeroGrid/main.lua", "return {}");
  await assert.rejects(verifyInstalled(root, manifest), /Missing files: none.*Unexpected files \(1\): "\._main\.lua"/);
  widget.children.delete("._main.lua");
  await verifyInstalled(root, manifest);
  for (let index = 0; index < 21; index++) {
    await put(root, `WIDGETS/AeroGrid/extra${index}.lua`, "extra");
  }
  await assert.rejects(verifyInstalled(root, manifest), (error) => {
    assert.match(error.message, /Unexpected files \(21\):.*1 more not shown/);
    assert.equal(error.differences.unexpected.length, 21);
    return true;
  });
});

test("verification tolerates valid macOS sidecars only for existing release files and directories", async () => {
  const root = await fixture();
  const { manifest, fetcher } = await releaseFixture();
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
  const header = new Uint8Array(38);
  const view = new DataView(header.buffer);
  view.setUint32(0, 0x00051607);
  view.setUint32(4, 0x00020000);
  view.setUint16(24, 1);
  view.setUint32(26, 9);
  view.setUint32(30, 38);
  const sidecar = async (path, bytes = header) => {
    const file = await put(root, `WIDGETS/AeroGrid/${path}`, "");
    file.data = bytes;
  };
  await sidecar("._main.lua");
  await sidecar("._assets");
  await sidecar("lib/._package.lua");
  const before = await snapshot(root);
  root.context.events = [];
  await verifyInstalled(root, manifest);
  assert.deepEqual(await snapshot(root), before);
  assert.deepEqual(root.context.events, []);
  await sidecar("._unrelated.lua");
  await assert.rejects(verifyInstalled(root, manifest), /Unexpected files \(1\): "\._unrelated\.lua"/);
  root.children.get("WIDGETS").children.get("AeroGrid").children.delete("._unrelated.lua");
  for (const bytes of [new Uint8Array(38), header.slice(0, 8), header.slice(0, 26)]) {
    await sidecar("._main.lua", bytes);
    await assert.rejects(verifyInstalled(root, manifest), /Unexpected files \(1\): "\._main\.lua"/);
  }
  await sidecar("._main.lua");
  await put(root, "WIDGETS/AeroGrid/main.lua", "corrupt release file");
  await assert.rejects(verifyInstalled(root, manifest), /Installed content verification failed: main.lua/);
});

test("first install and lower-case widget replacement use only the resolved widget directory", async () => {
  const { manifest, fetcher } = await releaseFixture();
  for (const absent of [true, false]) {
    const root = await fixture(absent ? "absent" : "old");
    const widgets = root.children.get("WIDGETS");
    if (!absent) {
      const old = widgets.children.get("AeroGrid");
      old.name = "aerogrid";
      widgets.children.set("aerogrid", old);
      widgets.children.delete("AeroGrid");
    }
    await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
    await verifyInstalled(root, manifest);
    const deletions = root.context.events.filter((event) => event.startsWith("delete:"));
    if (absent) assert.deepEqual(deletions, []);
    else {
      assert.equal(deletions.at(-1), "delete:WIDGETS/aerogrid");
      assert.ok(deletions.slice(0, -1).every((event) => event.startsWith("delete:WIDGETS/AeroGrid/")));
    }
  }
});

test("replacement cannot mutate sibling, root-level, nested lookalike or empty directories", async () => {
  const { manifest, fetcher } = await releaseFixture();
  for (const mode of ["install", "update", "downgrade", "failDelete", "failOpen", "failWrite", "failClose", "corrupt"]) {
    const root = await fixture(mode === "install" ? "absent" : "old");
    for (const path of [
      "AeroGrid/keep.lua", "WIDGETS/AeroGrid-backup/main.lua", "WIDGETS/AeroGrid2/main.lua",
      "WIDGETS/Other/AeroGrid/main.lua", "SOUNDS/keep.wav", "MODELS/AeroGrid/keep.yml",
    ]) await put(root, path, `preserve ${path}`);
    await root.getDirectoryHandle("EMPTY", { create: true });
    const other = root.children.get("WIDGETS").children.get("Other");
    await other.getDirectoryHandle("EMPTY", { create: true });
    if (mode === "downgrade") {
      await put(root, "WIDGETS/AeroGrid/lib/package.lua", 'return {\nversion = "99.0.0",\n}');
    }
    const original = await snapshot(root);
    const rootDirectories = [...root.children.entries()].filter(([, handle]) => handle.kind === "directory");
    const otherEmpty = other.children.get("EMPTY");
    root.context.events = [];
    const prepared = await preparePackage(manifest, base, () => {}, fetcher);
    if (mode.startsWith("fail") || mode === "corrupt") {
      root.context[mode] = true;
      await assert.rejects(replaceWidget(root, prepared), /Installation incomplete/);
    } else {
      await replaceWidget(root, prepared, () => {}, { allowDowngrade: mode === "downgrade" });
    }
    const deletions = root.context.events.filter((event) => event.startsWith("delete:"));
    if (mode === "install") assert.deepEqual(deletions, []);
    else assert.ok(deletions.length > 0, mode);
    for (const event of root.context.events) {
      const path = event.slice(event.indexOf(":") + 1);
      assert.ok(path === "WIDGETS/AeroGrid" || path.startsWith("WIDGETS/AeroGrid/"), `${mode}: ${event}`);
    }
    const after = await snapshot(root);
    for (const [path, bytes] of Object.entries(original)) {
      if (!path.startsWith("WIDGETS/AeroGrid/")) assert.deepEqual(after[path], bytes, `${mode}: ${path}`);
    }
    for (const [name, handle] of rootDirectories) assert.equal(root.children.get(name), handle);
    assert.equal(other.children.get("EMPTY"), otherEmpty);
  }
});

test("ambiguous or wrong-kind installation directories fail before any mutation", async () => {
  const { manifest, fetcher } = await releaseFixture();
  for (const mode of ["duplicate-widget", "duplicate-widgets", "widget-file", "widgets-file"]) {
    const root = await fixture();
    if (mode === "duplicate-widget") await put(root, "WIDGETS/aerogrid/main.lua", "keep");
    if (mode === "duplicate-widgets") await put(root, "widgets/AeroGrid/main.lua", "keep");
    if (mode === "widget-file") await put(root, "WIDGETS/AeroGrid", "not a directory");
    if (mode === "widgets-file") await put(root, "WIDGETS", "not a directory");
    const before = await snapshot(root);
    root.context.events = [];
    await assert.rejects(replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher)),
      /Ambiguous|not a directory/);
    assert.deepEqual(root.context.events, [], mode);
    assert.deepEqual(await snapshot(root), before, mode);
  }
});

test("newer installed version blocks downgrade before deletion", async () => {
  const root = await fixture();
  await put(root, "WIDGETS/AeroGrid/lib/package.lua", 'return {\nversion = "99.0.0",\n}');
  const { manifest, fetcher } = await releaseFixture();
  const prepared = await preparePackage(manifest, base, () => {}, fetcher);
  await assert.rejects(replaceWidget(root, prepared), /Downgrade refused/);
  await assert.rejects(replaceWidget(root, prepared, () => {}, { allowDowngrade: "yes" }), /Downgrade refused/);
  assert.deepEqual(root.context.events, []);
});

test("explicit downgrade authorization permits replacement and preserves user data", async () => {
  const root = await fixture();
  await put(root, "WIDGETS/AeroGrid/lib/package.lua", 'return {\nversion = "99.0.0",\n}');
  const { manifest, fetcher } = await releaseFixture();
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher),
    () => {}, { allowDowngrade: true });
  await verifyInstalled(root, manifest);
  assert.equal(await (await root.children.get("MAPS").children.get("tiles").children.get("tile.png").getFile()).text(), "user map");
});

test("first install creates only WIDGETS and its widget when WIDGETS is absent", async () => {
  const root = await fixture("absent");
  root.children.delete("WIDGETS");
  const { manifest, fetcher } = await releaseFixture();
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
  assert.equal(root.context.events[0], "mkdir:WIDGETS");
  await verifyInstalled(root, manifest);
  assert.equal(await (await root.children.get("RADIO").children.get("radio.yml").getFile()).text(),
    'board: tx16s\r\nsemver: "2.12.4"\r\n');
});

test("deletion, full disk, write, close and readback failures never succeed; retry fully replaces", async () => {
  const { manifest, fetcher } = await releaseFixture();
  for (const flag of ["failDelete", "failOpen", "failWrite", "failClose", "corrupt"]) {
    const root = await fixture();
    const prepared = await preparePackage(manifest, base, () => {}, fetcher);
    root.context[flag] = true;
    await assert.rejects(replaceWidget(root, prepared), /Installation incomplete/);
    root.context[flag] = false;
    await replaceWidget(root, prepared);
    await verifyInstalled(root, manifest);
  }
});

test("deletion logs exact-path errors without routine logs, retrying or writing", async (t) => {
  const info = t.mock.method(console, "info", () => {});
  const errors = t.mock.method(console, "error", () => {});
  const root = await fixture();
  const widgets = root.children.get("WIDGETS");
  const widget = widgets.children.get("AeroGrid");
  const failure = new DOMException("Missing child during deletion", "NotFoundError");
  let attempts = 0;
  widgets.removeEntry = async () => {
    attempts++;
    widget.children.delete("custom.txt");
    throw failure;
  };
  const { manifest, fetcher } = await releaseFixture();
  await assert.rejects(replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher)),
    (error) => error.cause.cause === failure);
  assert.equal(attempts, 1);
  assert.ok(root.context.events.every((event) => event.startsWith("delete:WIDGETS/AeroGrid/")));
  assert.equal(info.mock.calls.length, 0);
  const details = errors.mock.calls[0].arguments[1];
  assert.equal(details.target, "WIDGETS/AeroGrid");
  assert.equal(details.error.cause, failure);
  assert.match(details.message, /Could not delete WIDGETS\/AeroGrid/);
});

test("successful deletion has no routine logging or diagnostic scans", async (t) => {
  const info = t.mock.method(console, "info", () => {});
  const errors = t.mock.method(console, "error", () => {});
  const root = await fixture();
  const widget = root.children.get("WIDGETS").children.get("AeroGrid");
  const { manifest, fetcher } = await releaseFixture();
  const prepared = await preparePackage(manifest, base, () => {}, fetcher);
  root.context.scans = [];
  await replaceWidget(root, prepared);
  // Metadata inspection, deletion and read-back each enumerate the widget once.
  assert.equal(root.context.scans.filter((path) => path === widget.path).length, 3);
  assert.equal(info.mock.calls.length, 0);
  assert.equal(errors.mock.calls.length, 0);
});

test("sidecar-first removal avoids macOS paired-unlink failures for files and directories", async () => {
  const probe = new MemoryDirectory();
  await put(probe, "file.lua", "payload");
  await put(probe, "._file.lua", "metadata");
  probe.context.appleDouble = true;
  const listed = [...probe.children.keys()];
  await probe.removeEntry(listed[0]);
  await assert.rejects(probe.removeEntry(listed[1]), { name: "NotFoundError" });

  const root = await fixture();
  await put(root, "WIDGETS/AeroGrid/._lib", "directory metadata");
  await put(root, "WIDGETS/AeroGrid/lib/._package.lua", "file metadata");
  await put(root, "WIDGETS/AeroGrid/._custom.txt", "custom metadata");
  root.context.appleDouble = true;
  root.context.events = [];
  const { manifest, fetcher } = await releaseFixture();
  await replaceWidget(root, await preparePackage(manifest, base, () => {}, fetcher));
  const events = root.context.events;
  for (const path of ["lib", "lib/package.lua", "custom.txt"]) {
    const parts = path.split("/");
    parts[parts.length - 1] = `._${parts.at(-1)}`;
    assert.ok(events.indexOf(`delete:WIDGETS/AeroGrid/${parts.join("/")}`)
      < events.indexOf(`delete:WIDGETS/AeroGrid/${path}`));
  }
  await verifyInstalled(root, manifest);
  assert.equal(await (await root.children.get("MODELS").children.get("model1.yml").getFile()).text(), "user model");
});

test("storage serializes operations, blocks disconnect, and clears busy after failure", async () => {
  const storage = new RadioStorage(async () => fixture());
  await storage.connect();
  let finish;
  const running = storage.exclusive(() => new Promise((resolve) => { finish = resolve; }));
  await assert.rejects(storage.exclusive(async () => {}), /already running/);
  assert.throws(() => storage.disconnect(), /Wait/);
  finish();
  await running;
  await assert.rejects(storage.exclusive(async () => { throw new Error("failed"); }), /failed/);
  assert.equal(storage.busy, false);
  storage.disconnect();
});
