// SPDX-License-Identifier: GPL-2.0-only
/** Release discovery, verified downloads, and AeroGrid-only SD-card replacement. */
import { child, compareVersions, inspectRoot, inspectWidget, packageVersion, parseVersion } from "./radio-storage.mjs";

const RELEASES_API = "https://api.github.com/repos/thomaskistler/aero-grid/releases";
const RELEASE_ROOT = "https://github.com/thomaskistler/aero-grid/releases";
const MAX_FILES = 1500;
const MAX_TOTAL = 64 * 1024 * 1024;
const MAX_FILE = 2 * 1024 * 1024;
const preparedPackages = new WeakSet();

export function isDeveloperVersion(version) {
  return typeof version === "string" && /^\d+\.\d+\.\d+-dev\.[1-9]\d*\+(?:[a-f0-9]{8}|g[a-f0-9]{40})$/.test(version);
}

function releaseTag(version) {
  return isDeveloperVersion(version) ? "dev" : `v${version}`;
}

class HttpError extends Error {
  constructor(status, url) {
    super(`HTTP ${status} loading ${url}.`);
    this.status = status;
  }
}

/** Verification failure; differences holds path lists or per-file size details when available. */
export class ContentMismatchError extends Error {
  constructor(message, differences = null) {
    super(message);
    this.differences = differences;
  }
}

export async function sha256(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Maps { present, version } and a target version to { enabled, label }. */
export function actionFor(widget, latest) {
  const target = isDeveloperVersion(latest) ? "AeroGrid developer build" : `AeroGrid v${latest}`;
  if (!widget.present) return { enabled: true, label: `Install ${target}` };
  if (!widget.version) return { enabled: true, label: `Update to ${target}` };
  const comparison = compareVersions(widget.version, latest);
  if (comparison === 0) return { enabled: false, label: "Up to date" };
  if (comparison > 0) return { enabled: true, label: `Downgrade to ${target}` };
  return { enabled: true, label: `Update to ${target}` };
}

/** Validates a schema-1 { version, release, archiveSha256, files: [{ path, size, sha256 }] } or throws. */
export function validateManifest(manifest) {
  const version = parseVersion(manifest?.version);
  if (manifest?.schema !== 1 || !version
      || (!/^\d+\.\d+\.\d+$/.test(manifest.version) && !isDeveloperVersion(manifest.version))
      || manifest.release !== `${RELEASE_ROOT}/tag/${releaseTag(manifest.version)}`
      || !/^[a-f0-9]{64}$/.test(manifest.archiveSha256)
      || !Array.isArray(manifest.files) || !manifest.files.length || manifest.files.length > MAX_FILES) {
    throw new Error("Invalid installation release manifest.");
  }
  const seen = new Set();
  const directories = new Map();
  let total = 0;
  for (const file of manifest.files) {
    const parts = typeof file.path === "string" ? file.path.split("/") : [];
    if (!parts.length || file.path.length > 220
        || parts.some((part) => !/^[A-Za-z0-9_.-]+$/.test(part) || part === "." || part === "..")
        || seen.has(file.path.toLowerCase()) || !Number.isInteger(file.size)
        || file.size < 0 || file.size > MAX_FILE || !/^[a-f0-9]{64}$/.test(file.sha256)
        || file.path.endsWith(".luac")
        || (!file.path.endsWith(".lua") && !["assets", "themes", "layouts"].includes(parts[0]))) {
      throw new Error(`Unsafe installation file: ${file.path}.`);
    }
    seen.add(file.path.toLowerCase());
    for (let index = 1; index < parts.length; index++) {
      const path = parts.slice(0, index).join("/");
      const previous = directories.get(path.toLowerCase());
      if (previous && previous !== path) throw new Error(`Case-colliding installation directory: ${path}.`);
      directories.set(path.toLowerCase(), path);
    }
    total += file.size;
  }
  if (total > MAX_TOTAL || [...directories.keys()].some((path) => seen.has(path))
      || !manifest.files.some((file) => file.path === "main.lua")
      || !manifest.files.some((file) => file.path === "lib/package.lua")) {
    throw new Error("Incomplete or conflicting installation file list.");
  }
  return manifest;
}

async function fetchBytes(url, limit, fetcher) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30000);
  try {
    const response = await fetcher(url, { signal: controller.signal, cache: "no-store", credentials: "omit" });
    if (!response.ok) throw new HttpError(response.status, url);
    if (Number(response.headers.get("content-length")) > limit) throw new Error(`Download is too large: ${url}.`);
    if (!response.body) throw new Error(`Empty download: ${url}.`);
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > limit) throw new Error(`Download is too large: ${url}.`);
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchJSON(url, fetcher) {
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await fetchBytes(url, MAX_FILE, fetcher)));
}

function validateRelease(manifest, release) {
  validateManifest(manifest);
  const developer = isDeveloperVersion(manifest.version);
  const tag = releaseTag(manifest.version);
  if (release.draft !== false || release.prerelease !== developer
      || release.tag_name !== tag
      || (developer && release.name !== `AeroGrid ${manifest.version} (developer build)`)) {
    if (developer) throw new Error("The developer build changed or is not available on this site yet. Reload after publication.");
    throw new Error("The selected stable release is not available on this site yet. Reload after publication.");
  }
  const archive = `AeroGrid-${developer ? "dev" : manifest.version}.zip`;
  for (const name of [archive, `${archive}.sha256`]) {
    if (!release.assets?.some((asset) => asset.name === name
        && asset.browser_download_url === `${RELEASE_ROOT}/download/${tag}/${name}`)) {
      throw new Error("The selected release is missing installation assets.");
    }
  }
  return manifest;
}

/** Loads a validated manifest from the installer base URL and checks its published GitHub release. */
export async function loadRelease(base, version, fetcher = globalThis.fetch) {
  if ((!/^\d+\.\d+\.\d+$/.test(version) && !isDeveloperVersion(version)) || !parseVersion(version)) {
    throw new Error("Invalid selected release version.");
  }
  const [manifest, release] = await Promise.all([
    fetchJSON(new URL(`releases/${isDeveloperVersion(version) ? "dev" : version}/manifest.json`, base), fetcher),
    fetchJSON(`${RELEASES_API}/tags/${releaseTag(version)}`, fetcher),
  ]);
  if (manifest.version !== version) throw new Error("Selected release version does not match its manifest.");
  return validateRelease(manifest, release);
}

/** Returns { schema, latest, releases: [{ version, name, release, available, reason }] }. */
export async function loadCatalog(base, fetcher = globalThis.fetch) {
  let catalog;
  let missingCatalog = false;
  try {
    catalog = await fetchJSON(new URL("releases.json", base), fetcher);
  } catch (error) {
    if (!(error instanceof HttpError) || error.status !== 404) throw error;
    missingCatalog = true;
    catalog = { schema: 1, releases: [] };
  }
  if (catalog?.schema !== 1 || !Array.isArray(catalog.releases)
      || (!missingCatalog && !catalog.releases.length) || catalog.releases.length > 2000) {
    throw new Error("Invalid installation release catalog.");
  }
  const seen = new Set();
  for (const entry of catalog.releases) {
    if (!entry || !parseVersion(entry.version)
        || (!/^\d+\.\d+\.\d+$/.test(entry.version) && !isDeveloperVersion(entry.version))
        || seen.has(entry.version) || typeof entry.name !== "string" || entry.name.length > 500
        || entry.release !== `${RELEASE_ROOT}/tag/${releaseTag(entry.version)}`
        || typeof entry.available !== "boolean"
        || (entry.available ? entry.reason !== null : typeof entry.reason !== "string" || !entry.reason.length)) {
      throw new Error("Invalid installation release entry.");
    }
    seen.add(entry.version);
  }
  const published = [];
  const versions = new Set();
  for (let page = 1; page <= 20; page++) {
    const batch = await fetchJSON(`${RELEASES_API}?per_page=100&page=${page}`, fetcher);
    if (!Array.isArray(batch) || batch.length > 100) throw new Error("Invalid GitHub release list.");
    for (const release of batch) {
      if (release?.draft !== false) continue;
      const developer = release.tag_name === "dev" && release.prerelease === true;
      const version = developer ? release.name?.match(/^AeroGrid (.+) \(developer build\)$/)?.[1]
        : release.tag_name?.replace(/^v/, "");
      if (developer ? !isDeveloperVersion(version)
        : release.prerelease !== false || !/^\d+\.\d+\.\d+$/.test(version)) continue;
      if (!parseVersion(version)) continue;
      if (versions.has(version)) throw new Error("Duplicate GitHub release version.");
      versions.add(version);
      const prepared = catalog.releases.find((entry) => entry.version === version);
      const archive = `AeroGrid-${developer ? "dev" : version}.zip`;
      const hasAssets = [archive, `${archive}.sha256`].every((name) =>
        release.assets?.some((asset) => asset.name === name
          && asset.browser_download_url === `${RELEASE_ROOT}/download/${releaseTag(version)}/${name}`));
      const available = prepared?.available === true && hasAssets;
      published.push({
        version, name: typeof release.name === "string" ? release.name.slice(0, 500) : `AeroGrid ${version}`,
        release: `${RELEASE_ROOT}/tag/${releaseTag(version)}`,
        available,
        reason: available ? null : missingCatalog ? "Automatic installation files are not available on this site."
          : !hasAssets ? "The GitHub release is missing installation assets."
          : prepared?.reason ?? "Installation assets have not been published on this site yet.",
      });
    }
    if (batch.length < 100) break;
    if (page === 20) throw new Error("GitHub release list exceeds the supported limit.");
  }
  if (!published.some((entry) => !isDeveloperVersion(entry.version))) {
    throw new Error("No published stable GitHub releases are available.");
  }
  published.sort((left, right) => Number(isDeveloperVersion(left.version)) - Number(isDeveloperVersion(right.version))
    || compareVersions(right.version, left.version));
  return { schema: 1, latest: published[0].version, releases: published };
}

/**
 * Downloads and verifies all files without touching the radio; returns { version, files }.
 * Each file adds bytes to its manifest entry. progress receives (text, completed, total).
 */
export async function preparePackage(manifest, base, progress, fetcher = globalThis.fetch) {
  // Detach from caller-owned metadata before network waits or destructive operations.
  const pinned = validateManifest(structuredClone(manifest));
  const files = [];
  let completed = 0;
  for (let start = 0; start < pinned.files.length; start += 4) {
    const results = await Promise.allSettled(pinned.files.slice(start, start + 4).map(async (file) => {
      progress(`Downloading ${file.path}`, completed, pinned.files.length);
      const url = new URL(`releases/${isDeveloperVersion(pinned.version) ? "dev" : pinned.version}/${file.path}`, base);
      const bytes = await fetchBytes(url, MAX_FILE, fetcher);
      if (bytes.length !== file.size || await sha256(bytes) !== file.sha256) {
        throw new Error(`Download content verification failed: ${file.path}. No radio files were changed.`);
      }
      progress(`Downloaded ${file.path}`, ++completed, pinned.files.length);
      return { ...file, bytes };
    }));
    for (const result of results) {
      if (result.status === "rejected") throw result.reason;
      files.push(result.value);
    }
  }
  const metadata = files.find((file) => file.path === "lib/package.lua");
  if (packageVersion(new TextDecoder().decode(metadata.bytes)) !== pinned.version) {
    throw new Error("Package version does not match the release manifest.");
  }
  const prepared = { version: pinned.version, files };
  preparedPackages.add(prepared);
  return prepared;
}

async function directoryFor(root, path, cache) {
  let directory = root;
  let key = "";
  for (const part of path) {
    key += `${part}/`;
    if (!cache.has(key)) cache.set(key, await directory.getDirectoryHandle(part, { create: true }));
    directory = cache.get(key);
  }
  return directory;
}

async function listFiles(directory, prefix = "", directories = new Set(), files = new Map()) {
  for await (const [name, handle] of directory.entries()) {
    const path = prefix + name;
    if (handle.kind === "directory") {
      directories.add(path);
      await listFiles(handle, `${path}/`, directories, files);
    }
    else files.set(path, handle);
    if (files.size > MAX_FILES) throw new Error("Unexpected files in the AeroGrid folder.");
  }
  return files;
}

async function appleDoubleSidecar(handle, path, expectedPaths, directories) {
  const parts = path.split("/");
  const name = parts.at(-1);
  if (!name.startsWith("._")) return false;
  parts[parts.length - 1] = name.slice(2);
  const counterpart = parts.join("/");
  if (!expectedPaths.has(counterpart) && !directories.has(counterpart)) return false;
  const file = await handle.getFile();
  if (file.size < 26 || file.size > MAX_FILE) return false;
  const header = new DataView(await file.slice(0, 26).arrayBuffer());
  const count = header.getUint16(24);
  const tableEnd = 26 + count * 12;
  if (header.getUint32(0) !== 0x00051607 || header.getUint32(4) !== 0x00020000
      || !count || tableEnd > file.size) return false;
  const entries = new DataView(await file.slice(26, tableEnd).arrayBuffer());
  for (let index = 0; index < count; index++) {
    const offset = entries.getUint32(index * 12 + 4);
    const size = entries.getUint32(index * 12 + 8);
    if (offset < tableEnd || offset + size > file.size) return false;
  }
  return true;
}

/**
 * Read-only content check against manifest.files; throws ContentMismatchError on differences.
 * allowCompiled permits matching Lua bytecode companions. progress receives (text, completed, total).
 */
export async function verifyInstalled(root, manifest, progress = () => {}, allowCompiled = false) {
  const widgets = await child(root, "WIDGETS", "directory");
  const widget = await child(widgets, "AeroGrid", "directory");
  const expected = manifest.files.map((file) => file.path).sort();
  const expectedPaths = new Set(expected);
  const directories = new Set();
  const installedFiles = await listFiles(widget, "", directories);
  const actual = [];
  for (const [path, handle] of installedFiles) {
    if (allowCompiled && path.endsWith(".luac") && expectedPaths.has(path.slice(0, -1))) continue;
    if (!expectedPaths.has(path) && await appleDoubleSidecar(handle, path, expectedPaths, directories)) continue;
    actual.push(path);
  }
  actual.sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    const actualPaths = new Set(actual);
    const missing = expected.filter((path) => !actualPaths.has(path));
    const unexpected = actual.filter((path) => !expectedPaths.has(path));
    const describe = (label, paths) => paths.length
      ? `${label} (${paths.length}): ${paths.slice(0, 20).map((path) => JSON.stringify(path)).join(", ")}${paths.length > 20 ? `; ${paths.length - 20} more not shown` : ""}.`
      : `${label}: none.`;
    throw new ContentMismatchError(
      `AeroGrid file list does not match the selected release. Paths are relative to WIDGETS/AeroGrid. ${describe("Missing files", missing)} ${describe("Unexpected files", unexpected)}`,
      { missing, unexpected }
    );
  }
  for (const [index, file] of manifest.files.entries()) {
    progress(`Verifying ${file.path}`, index, manifest.files.length);
    const installed = await installedFiles.get(file.path).getFile();
    if (installed.size !== file.size || await sha256(await installed.arrayBuffer()) !== file.sha256) {
      throw new ContentMismatchError(`Installed content verification failed: ${file.path}.`,
        { path: file.path, expectedSize: file.size, actualSize: installed.size });
    }
  }
}

async function deleteWidgetTree(parent, directory, path, budget = { remaining: 10000 }, depth = 0) {
  if (depth > 64) throw new Error(`Deletion depth limit reached: ${path}.`);
  const entries = [];
  for await (const entry of directory.entries()) {
    if (--budget.remaining < 0) throw new Error(`Deletion entry limit reached: ${path}.`);
    entries.push(entry);
  }
  // macOS unlinks a file's AppleDouble sidecar automatically; remove sidecars first.
  entries.sort(([left], [right]) => Number(right.startsWith("._")) - Number(left.startsWith("._")));
  for (const [name, handle] of entries) {
    const entryPath = `${path}/${name}`;
    if (handle.kind === "directory") {
      await deleteWidgetTree(directory, handle, entryPath, budget, depth + 1);
    } else {
      try {
        await directory.removeEntry(name);
      } catch (error) {
        throw new Error(`Could not delete ${entryPath}: ${error.message}`, { cause: error });
      }
    }
  }
  try {
    await parent.removeEntry(directory.name);
  } catch (error) {
    throw new Error(`Could not delete ${path}: ${error.message}`, { cause: error });
  }
}

/**
 * Requires SD-root write permission and a package from preparePackage; rechecks bytes before deletion.
 * Replaces only WIDGETS/AeroGrid (creating WIDGETS if absent), then verifies written content.
 * Failure can leave an incomplete installation; no backup or rollback. Downgrades require opt-in.
 * Caller must serialize writes; progress receives (text, completed, total).
 */
export async function replaceWidget(root, prepared, progress = () => {}, { allowDowngrade = false } = {}) {
  if (!preparedPackages.has(prepared)) throw new Error("Download and validate a complete installation package first.");
  // Recheck bytes even if another caller retained and modified a prepared buffer.
  validateManifest({
    schema: 1, version: prepared.version, release: `${RELEASE_ROOT}/tag/${releaseTag(prepared.version)}`,
    archiveSha256: "0".repeat(64), files: prepared.files,
  });
  for (const file of prepared.files) {
    if (file.bytes.length !== file.size || await sha256(file.bytes) !== file.sha256) {
      throw new Error(`Prepared content changed: ${file.path}. No radio files were changed.`);
    }
  }
  await inspectRoot(root);
  const installed = await inspectWidget(root);
  if (installed.version && compareVersions(installed.version, prepared.version) > 0 && allowDowngrade !== true) {
    throw new Error("A newer AeroGrid version is installed. Downgrade refused.");
  }
  let widgets = await child(root, "WIDGETS", "directory", true);
  const old = widgets && await child(widgets, "AeroGrid", "directory", true);
  let stage = "Creating WIDGETS";
  let changed = false;
  try {
    if (!widgets) {
      changed = true;
      widgets = await root.getDirectoryHandle("WIDGETS", { create: true });
    }
    if (old) {
      stage = "Deleting WIDGETS/" + old.name;
      progress(stage, 0, prepared.files.length);
      changed = true;
      try {
        await deleteWidgetTree(widgets, old, `WIDGETS/${old.name}`);
      } catch (error) {
        console.error("[AeroGrid installer] Sidecar-first deletion failed.", {
          target: `WIDGETS/${old.name}`,
          name: error.name, message: error.message, error,
        });
        throw error;
      }
    }
    stage = "Creating WIDGETS/AeroGrid";
    changed = true;
    const target = await widgets.getDirectoryHandle("AeroGrid", { create: true });
    const directories = new Map();
    for (const [index, file] of prepared.files.entries()) {
      stage = `Writing WIDGETS/AeroGrid/${file.path}`;
      progress(stage, index, prepared.files.length);
      const parts = file.path.split("/");
      const directory = await directoryFor(target, parts.slice(0, -1), directories);
      const handle = await directory.getFileHandle(parts.at(-1), { create: true });
      const stream = await handle.createWritable();
      try {
        await stream.write(file.bytes);
        await stream.close();
      } catch (error) {
        try {
          await stream.abort();
        } catch (abortError) {
          throw new Error(`${error.message}; closing the failed stream also failed: ${abortError.message}`);
        }
        throw error;
      }
    }
    stage = "Verifying installed files";
    await verifyInstalled(root, prepared, progress);
  } catch (error) {
    throw new Error(`${stage}: ${error.message}${changed ? " Installation incomplete. AeroGrid may be unusable; retry the full installation before using it. No backup or rollback is available." : ""}`, { cause: error });
  }
}
