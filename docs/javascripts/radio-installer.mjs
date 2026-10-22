// SPDX-License-Identifier: GPL-2.0-only
import { child, compareVersions, inspectRoot, inspectWidget, packageVersion, parseVersion } from "./radio-storage.mjs";

export const RELEASE_API = "https://api.github.com/repos/thomaskistler/aero-grid/releases/latest";
const RELEASE_ROOT = "https://github.com/thomaskistler/aero-grid/releases";
const MAX_FILES = 1500;
const MAX_TOTAL = 64 * 1024 * 1024;
const MAX_FILE = 2 * 1024 * 1024;
const preparedPackages = new WeakSet();

export class ContentMismatchError extends Error {}

export async function sha256(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function actionFor(widget, latest) {
  if (!widget.present) return { enabled: true, label: `Install AeroGrid ${latest}` };
  if (!widget.version) return { enabled: true, label: `Update to AeroGrid ${latest}` };
  const comparison = compareVersions(widget.version, latest);
  if (comparison === 0) return { enabled: false, label: "Up to date" };
  if (comparison > 0) return { enabled: false, label: "Newer version installed - no downgrade" };
  return { enabled: true, label: `Update to AeroGrid ${latest}` };
}

export function validateManifest(manifest) {
  const version = parseVersion(manifest?.version);
  if (manifest?.schema !== 1 || !version || version.prerelease.length
      || !/^\d+\.\d+\.\d+$/.test(manifest.version)
      || manifest.release !== `${RELEASE_ROOT}/tag/v${manifest.version}`
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
    if (!response.ok) throw new Error(`HTTP ${response.status} loading ${url}.`);
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

export async function loadLatest(base, fetcher = globalThis.fetch) {
  const [manifest, release] = await Promise.all([
    fetchJSON(new URL("latest.json", base), fetcher),
    fetchJSON(RELEASE_API, fetcher),
  ]);
  validateManifest(manifest);
  if (release.draft !== false || release.prerelease !== false
      || release.tag_name !== `v${manifest.version}`) {
    throw new Error("The latest stable release is not available on this site yet. Retry after publication.");
  }
  for (const name of [`AeroGrid-${manifest.version}.zip`, `AeroGrid-${manifest.version}.zip.sha256`]) {
    if (!release.assets?.some((asset) => asset.name === name
        && asset.browser_download_url === `${RELEASE_ROOT}/download/v${manifest.version}/${name}`)) {
      throw new Error("The latest stable release is missing installation assets.");
    }
  }
  return manifest;
}

export async function preparePackage(manifest, base, progress, fetcher = globalThis.fetch) {
  // Detach from caller-owned metadata before network waits or destructive operations.
  const pinned = validateManifest(structuredClone(manifest));
  const files = [];
  for (const file of pinned.files) {
    progress(`Downloading ${file.path}`, files.length, pinned.files.length);
    const url = new URL(`releases/${pinned.version}/${file.path}`, base);
    const bytes = await fetchBytes(url, MAX_FILE, fetcher);
    if (bytes.length !== file.size || await sha256(bytes) !== file.sha256) {
      throw new Error(`Download content verification failed: ${file.path}. No radio files were changed.`);
    }
    files.push({ ...file, bytes });
  }
  const metadata = files.find((file) => file.path === "lib/package.lua");
  if (packageVersion(new TextDecoder().decode(metadata.bytes)) !== pinned.version) {
    throw new Error("Package version does not match the release manifest.");
  }
  const prepared = { version: pinned.version, files };
  preparedPackages.add(prepared);
  return prepared;
}

async function directoryFor(root, path) {
  let directory = root;
  for (const part of path) directory = await directory.getDirectoryHandle(part, { create: true });
  return directory;
}

async function listFiles(directory, prefix = "") {
  const files = [];
  for await (const [name, handle] of directory.entries()) {
    const path = prefix + name;
    if (handle.kind === "directory") files.push(...await listFiles(handle, `${path}/`));
    else files.push(path);
    if (files.length > MAX_FILES) throw new Error("Unexpected files in the AeroGrid folder.");
  }
  return files;
}

export async function verifyInstalled(root, manifest, progress = () => {}, allowCompiled = false) {
  const widgets = await child(root, "WIDGETS", "directory");
  const widget = await child(widgets, "AeroGrid", "directory");
  const expected = manifest.files.map((file) => file.path).sort();
  const actual = (await listFiles(widget)).filter((path) => !(
    allowCompiled && path.endsWith(".luac") && expected.includes(path.slice(0, -1))
  )).sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new ContentMismatchError("AeroGrid file list is incomplete or contains different files.");
  for (const [index, file] of manifest.files.entries()) {
    progress(`Verifying ${file.path}`, index, manifest.files.length);
    let directory = widget;
    const parts = file.path.split("/");
    for (const part of parts.slice(0, -1)) directory = await child(directory, part, "directory");
    const handle = await child(directory, parts.at(-1), "file");
    const installed = await handle.getFile();
    if (installed.size !== file.size || await sha256(await installed.arrayBuffer()) !== file.sha256) {
      throw new ContentMismatchError(`Installed content verification failed: ${file.path}.`);
    }
  }
}

export async function replaceWidget(root, prepared, progress = () => {}) {
  if (!preparedPackages.has(prepared)) throw new Error("Download and validate a complete installation package first.");
  // Recheck bytes even if another caller retained and modified a prepared buffer.
  validateManifest({
    schema: 1, version: prepared.version, release: `${RELEASE_ROOT}/tag/v${prepared.version}`,
    archiveSha256: "0".repeat(64), files: prepared.files,
  });
  for (const file of prepared.files) {
    if (file.bytes.length !== file.size || await sha256(file.bytes) !== file.sha256) {
      throw new Error(`Prepared content changed: ${file.path}. No radio files were changed.`);
    }
  }
  await inspectRoot(root);
  const installed = await inspectWidget(root);
  if (installed.version && compareVersions(installed.version, prepared.version) > 0) {
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
      await widgets.removeEntry(old.name, { recursive: true });
    }
    stage = "Creating WIDGETS/AeroGrid";
    changed = true;
    const target = await widgets.getDirectoryHandle("AeroGrid", { create: true });
    for (const [index, file] of prepared.files.entries()) {
      stage = `Writing WIDGETS/AeroGrid/${file.path}`;
      progress(stage, index, prepared.files.length);
      const parts = file.path.split("/");
      const directory = await directoryFor(target, parts.slice(0, -1));
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
    throw new Error(`${stage}: ${error.message}${changed ? " Installation incomplete. AeroGrid may be unusable; retry the full installation before using it. No backup or rollback is available." : ""}`);
  }
}
