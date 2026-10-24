// SPDX-License-Identifier: GPL-2.0-only

const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

export function parseVersion(value) {
  if (typeof value !== "string" || value.length > 100) return null;
  const match = VERSION.exec(value);
  if (!match || match.slice(1, 4).some((part) => !Number.isSafeInteger(Number(part)))) return null;
  const prerelease = match[4]?.split(".") ?? [];
  if (prerelease.some((part) => /^\d+$/.test(part) && part.length > 1 && part.startsWith("0"))) return null;
  return { numbers: match.slice(1, 4).map(Number), prerelease };
}

export function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) throw new Error("Cannot compare invalid versions.");
  for (let index = 0; index < 3; index++) {
    if (a.numbers[index] !== b.numbers[index]) return Math.sign(a.numbers[index] - b.numbers[index]);
  }
  if (!a.prerelease.length || !b.prerelease.length) {
    return Math.sign(b.prerelease.length - a.prerelease.length);
  }
  for (let index = 0; index < Math.max(a.prerelease.length, b.prerelease.length); index++) {
    const x = a.prerelease[index];
    const y = b.prerelease[index];
    if (x === y) continue;
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    if (/^\d+$/.test(x) && /^\d+$/.test(y)) {
      return x.length === y.length ? (x > y ? 1 : -1) : Math.sign(x.length - y.length);
    }
    if (/^\d+$/.test(x)) return -1;
    if (/^\d+$/.test(y)) return 1;
    return x > y ? 1 : -1;
  }
  return 0;
}

function scalar(text, key) {
  const lines = text.replace(/^\uFEFF/, "").split(/\r?\n/).filter((line) => line.startsWith(`${key}:`));
  if (lines.length !== 1) return null;
  const value = lines[0].slice(key.length + 1).trim();
  const match = /^(?:"([^"\\]*)"|'([^']*)'|([^#"'[\]{}&*!|>\s][^#]*?))\s*(?:#.*)?$/.exec(value);
  return match ? (match[1] ?? match[2] ?? match[3]).trim() : null;
}

export function parseRadioMetadata(text) {
  const board = scalar(text, "board");
  const version = scalar(text, "semver");
  return {
    board: board && /^[A-Za-z0-9_+-]{1,48}$/.test(board) ? board : null,
    version: parseVersion(version) ? version : null,
  };
}

// EdgeTX v2.12.0: targets/{horus,pl18,st16,tx15,tx16smk3,t15pro}/hal.h
// define color LCD dimensions; targets/taranis/CMakeLists.txt selects mono GUI sizes.
const SCREEN_GROUPS = [
  { boards: ["tx16s", "t16", "t18", "x10", "x10express", "x12s", "f16", "v16"], screen: "Color - 480 x 272" },
  { boards: ["t15", "t15pro", "tx15", "st16", "pl18", "pl18u", "pl18ev"], screen: "Color - 480 x 320" },
  { boards: ["nv14", "el18", "nb4p"], screen: "Color - 320 x 480" },
  { boards: ["tx16smk3"], screen: "Color - 800 x 480" },
  { boards: ["x9d", "x9d+", "x9d+2019", "x9e"], screen: "Monochrome - 212 x 64" },
  { boards: ["x7", "x7access", "x9lite", "x9lites", "xlite", "xlites", "t12", "t12max",
    "tpro", "tprov2", "tpros", "bumblebee", "t14", "t20", "t20v2", "tlite", "tlitef4",
    "lr3pro", "tx12", "tx12mk2", "mt12", "boxer", "gx12", "zorro", "pocket", "t8",
    "commando8", "v12", "v14"], screen: "Monochrome - 128 x 64" },
];

const RADIO_NAMES = {
  tx16s: "RadioMaster TX16S",
  tx16smk3: "RadioMaster TX16S MK3",
  tx15: "RadioMaster TX15",
  tx12: "RadioMaster TX12",
  tx12mk2: "RadioMaster TX12 MKII",
  boxer: "RadioMaster Boxer",
  pocket: "RadioMaster Pocket",
  zorro: "RadioMaster Zorro",
  gx12: "RadioMaster GX12",
  mt12: "RadioMaster MT12",
  t15: "Jumper T15",
  t15pro: "Jumper T15 Pro",
  t16: "Jumper T16",
  t18: "Jumper T18",
  x10: "FrSky Horus X10",
  x10express: "FrSky Horus X10 Express",
  x12s: "FrSky Horus X12S",
};

export function radioHardware(board) {
  const key = typeof board === "string" ? board.toLowerCase() : null;
  return {
    type: key && Object.hasOwn(RADIO_NAMES, key) ? RADIO_NAMES[key] : board || "Unknown",
    screen: SCREEN_GROUPS.find((group) => group.boards.includes(key))?.screen ?? "Unknown",
  };
}

export function radioCompatibility(radio) {
  const hardware = radioHardware(radio?.board);
  if (hardware.screen === "Unknown") {
    return { supported: false, message: "Radio type or screen could not be identified. Install at your own risk." };
  }
  if (hardware.screen.startsWith("Monochrome")) {
    return { supported: false, message: "This radio has a monochrome screen. AeroGrid requires a color-screen radio running EdgeTX 2.11.0 or later. Install at your own risk." };
  }
  const version = parseVersion(radio?.version);
  if (!version) {
    return { supported: false, message: "The EdgeTX version could not be identified. AeroGrid requires a color-screen radio running EdgeTX 2.11.0 or later. Install at your own risk." };
  }
  if (compareVersions(radio.version, "2.11.0") < 0) {
    return { supported: false, message: "This EdgeTX version is older than the required EdgeTX 2.11.0. Install at your own risk." };
  }
  if (version.prerelease.length) {
    return { supported: false, message: "This radio is running prerelease EdgeTX firmware. Compatibility is unverified. Install at your own risk." };
  }
  return { supported: true, message: "Compatibility check passed: recognized color-screen radio with EdgeTX 2.11.0 or later." };
}

export function packageVersion(text) {
  const source = text.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, "").replace(/--[^\r\n]*/g, "");
  const matches = [...source.matchAll(/^\s*version\s*=\s*["']([^"']+)["']\s*,?\s*$/gm)];
  return matches.length === 1 && parseVersion(matches[0][1]) ? matches[0][1] : null;
}

export async function child(directory, name, kind, optional = false) {
  const matches = [];
  for await (const [entryName, handle] of directory.entries()) {
    if (entryName.toLowerCase() === name.toLowerCase()) matches.push(handle);
  }
  if (matches.length > 1) throw new Error(`Ambiguous SD-card entries: ${name}.`);
  if (!matches.length) {
    if (optional) return null;
    throw new Error(`Missing ${name}. Select the radio's SD-card root, not a subfolder.`);
  }
  if (matches[0].kind !== kind) throw new Error(`${name} is not a ${kind}.`);
  return matches[0];
}

export async function readText(directory, name, limit) {
  const handle = await child(directory, name, "file", true);
  if (!handle) return null;
  const file = await handle.getFile();
  if (file.size > limit) throw new Error(`${name} exceeds the supported metadata size.`);
  return file.text();
}

export async function inspectRoot(root) {
  const radio = await child(root, "RADIO", "directory");
  await child(root, "MODELS", "directory");
  const markers = [];
  for (const name of ["WIDGETS", "SCRIPTS", "SOUNDS"]) {
    markers.push(await child(root, name, "directory", true));
  }
  if (!markers.some(Boolean)) throw new Error("This does not look like an EdgeTX SD-card root.");
  const text = await readText(radio, "radio.yml", 256 * 1024);
  const metadata = text === null ? { board: null, version: null } : parseRadioMetadata(text);
  return { ...metadata, name: root.name };
}

export async function inspectWidget(root) {
  const widgets = await child(root, "WIDGETS", "directory", true);
  const widget = widgets && await child(widgets, "AeroGrid", "directory", true);
  if (!widget) return { present: false, version: null };
  const lib = await child(widget, "lib", "directory", true);
  const text = lib && await readText(lib, "package.lua", 32 * 1024);
  return { present: true, version: text ? packageVersion(text) : null };
}

// A page-session storage capability, deliberately independent of installer UI and paths.
export class RadioStorage {
  constructor(picker = (options) => globalThis.showDirectoryPicker(options)) {
    this.picker = picker;
    this.root = null;
    this.busy = false;
  }

  async connect() {
    if (this.busy) throw new Error("A radio operation is already running.");
    const root = await this.picker({ id: "aerogrid-radio", mode: "read" });
    const metadata = await inspectRoot(root);
    await inspectWidget(root);
    this.root = root;
    return metadata;
  }

  disconnect() {
    if (this.busy) throw new Error("Wait for the radio operation to finish.");
    this.root = null;
  }

  async inspect() {
    if (!this.root) throw new Error("Connect the radio's SD card first.");
    return { radio: await inspectRoot(this.root), widget: await inspectWidget(this.root) };
  }

  async requestWritePermission() {
    if (!this.root) throw new Error("Connect the radio's SD card first.");
    const permission = await this.root.requestPermission({ mode: "readwrite" });
    if (permission !== "granted") throw new Error("SD-card write permission was denied. No installation started.");
  }

  async exclusive(operation) {
    if (this.busy) throw new Error("A radio operation is already running.");
    if (!this.root) throw new Error("Connect the radio's SD card first.");
    this.busy = true;
    try {
      if (globalThis.navigator?.locks) {
        return await navigator.locks.request("aerogrid-radio-write", { ifAvailable: true }, (lock) => {
          if (!lock) throw new Error("Another AeroGrid page is writing to a radio. Wait for it to finish.");
          return operation(this.root);
        });
      }
      return await operation(this.root);
    } finally {
      this.busy = false;
    }
  }
}

export const radioStorage = new RadioStorage();
