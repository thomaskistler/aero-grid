// SPDX-License-Identifier: GPL-2.0-only
// Optional Chromium acceptance check using disposable native OPFS handles.
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
require("../../docs/javascripts/map-planner.js");
require("../../docs/javascripts/map-pack.js");
require("../../docs/javascripts/map-sources.js");
const images = require("../../tools/map-test-images.js");
const planner = globalThis.AeroGridMapPlanner;
const packs = globalThis.AeroGridMapPack;
globalThis.AeroGridMapSources.encodeJpeg = async (rgb) => images.jpeg(rgb);
const bounds = { south: 25.997, north: 25.998, west: -97.158, east: -97.157 };
const coverage = planner.coveragePlan(bounds, [17], "tx16s", true);
const selection = {
  ...planner.specification("Smoke field", coverage.bounds, [17], "tx16s", coverage),
  selectedBounds: bounds, coverageMode: "per-zoom-clamped",
};
const files = await packs.createFiles(selection, "smoke-field");
const tilePaths = [...files.keys()].filter((path) => path.endsWith(".jpg"));
const fixture = [...files].map(([path, bytes]) => [path, Buffer.from(bytes).toString("base64")]);
const preview = Buffer.from(files.get(tilePaths[0]));
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? "playwright");
const site = new URL(process.argv[2] ?? "http://127.0.0.1:8000/");
const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}),
});
const context = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
const errors = [];
context.on("page", (page) => page.on("pageerror", (error) => errors.push(error.message)));
await context.route("**/*", async (route) => {
  const url = new URL(route.request().url());
  if (url.hostname === "mt1.google.com") {
    await route.fulfill({ contentType: "image/jpeg", body: preview });
  } else if (url.origin === site.origin
    || url.href.startsWith("https://cdn.jsdelivr.net/npm/ol@10.6.1/")) {
    await route.continue();
  } else if (url.href.startsWith("https://api.github.com/repos/thomaskistler/aero-grid/releases")) {
    await route.fulfill({ status: 503, body: "Offline smoke check" });
  } else {
    await route.abort();
  }
});

try {
  const page = await context.newPage();
  await page.addInitScript(({ fixture, missing }) => {
    window.hljs = { highlightAll() {} };
    window.__pickerCalls = 0;
    window.__radioReady = (async () => {
      const privateRoot = await navigator.storage.getDirectory();
      const root = await privateRoot.getDirectoryHandle("map-acceptance", { create: true });
      const put = async (path, bytes) => {
        const parts = path.split("/");
        let directory = root;
        for (const part of parts.slice(0, -1)) {
          directory = await directory.getDirectoryHandle(part, { create: true });
        }
        const stream = await (await directory.getFileHandle(parts.at(-1), { create: true })).createWritable();
        await stream.write(bytes);
        await stream.close();
      };
      if (!sessionStorage.getItem("map-smoke-seeded")) {
        for (const [path, base64] of fixture) {
          if (path !== missing) {
            await put(path, Uint8Array.from(atob(base64), (value) => value.charCodeAt(0)));
          }
        }
        for (const [path, text] of [
          ["RADIO/radio.yml", "board: tx16s\nsemver: 2.12.4\n"],
          ["MODELS/model1.yml", "keep model"],
          ["WIDGETS/AeroGrid/main.lua", "keep widget"],
          ["AEROGRID/layouts/user.yaml", "keep layout"],
          ["MAPS/other.txt", "keep other map"],
        ]) await put(path, text);
        sessionStorage.setItem("map-smoke-seeded", "true");
      }
      return root;
    })();
    window.showDirectoryPicker = async (options) => {
      window.__pickerCalls++;
      if (options.mode !== "read") throw new Error("Connection must be read-only");
      return window.__radioReady;
    };
  }, { fixture, missing: tilePaths[0] });
  const activate = (selector) => page.locator(selector).press("Enter");
  const mapURL = new URL("map-manager/", site).href;
  await page.goto(mapURL);
  await page.waitForFunction(() => window.AeroGridMapPlannerView && document.querySelector(".ol-viewport"));
  assert.equal(await page.locator(".ag-guide-sidebar").count(), 0);
  assert.equal(await page.locator(".ag-icon-link.active").getAttribute("aria-label"), "Map Manager");
  assert.equal(await page.locator("[data-radio-connection] [data-connect]").count(), 1);
  await activate("[data-radio-connection] .ag-radio-help-button");
  assert.equal(await page.locator("#ag-map-connect-help").evaluate((node) => node.matches(":popover-open")), true);
  await activate("#ag-map-connect-help button");
  assert.equal(await page.locator("#ag-map-connect-help").evaluate((node) => node.matches(":popover-open")), false);
  await activate("#ag-map-connect");
  await page.waitForFunction(() => document.querySelector("#ag-map-radio-state").textContent === "Radio connected"
    && document.querySelector("#ag-map-area-list").textContent.includes("Pending changes"));
  assert.equal(await page.locator("#ag-map-radio-type").textContent(), "RadioMaster TX16S");
  assert.equal(await page.locator("#ag-map-radio-screen").textContent(), "Color - 480 x 272");
  assert.equal(await page.evaluate(() => window.__pickerCalls), 1);
  const read = (path) => page.evaluate(async (path) => {
    let directory = await window.__radioReady;
    const parts = path.split("/");
    for (const part of parts.slice(0, -1)) directory = await directory.getDirectoryHandle(part);
    return new Uint8Array(await (await (await directory.getFileHandle(parts.at(-1))).getFile()).arrayBuffer());
  }, path).then((bytes) => Buffer.from(Object.values(bytes)));
  await assert.rejects(read(tilePaths[0]), /not.*found/i);
  const unchanged = await read(tilePaths[1]);
  await activate("#ag-map-update");
  await page.waitForFunction(() => !document.querySelector("#ag-map-sync").disabled);
  assert.match(await page.locator("#ag-map-review-list").textContent(), /Repair/);
  await assert.rejects(read(tilePaths[0]), /not.*found/i);
  await activate("#ag-map-update-cancel");
  assert.equal(await page.locator("#ag-map-review-panel").isVisible(), false);
  await activate("#ag-map-update");
  await page.waitForFunction(() => !document.querySelector("#ag-map-sync").disabled);
  await activate("#ag-map-sync");
  await page.waitForFunction(() => document.querySelector("#ag-map-update-cancel").textContent === "Done");
  await activate("#ag-map-update-cancel");
  assert.ok((await read(tilePaths[0])).length > 0);
  assert.deepEqual(await read(tilePaths[1]), unchanged, "Repair preserves existing shared JPEG bytes");

  await activate(".ag-map-area-option");
  await activate(".ag-map-area-edit");
  await page.locator(".ag-map-area-rename").fill("Renamed smoke field");
  await page.locator(".ag-map-area-rename").press("Enter");
  await activate("#ag-map-update");
  await page.waitForFunction(() => !document.querySelector("#ag-map-sync").disabled);
  await activate("#ag-map-sync");
  await page.waitForFunction(() => document.querySelector("#ag-map-update-cancel").textContent === "Done");
  await activate("#ag-map-update-cancel");
  assert.match((await read("AEROGRID/maps/areas/smoke-field.yaml")).toString(), /Renamed smoke field/);
  assert.deepEqual(await read(tilePaths[1]), unchanged, "Metadata edits do not replace shared JPEGs");

  await page.goto(new URL("user-guide/installation/", site).href);
  await page.waitForFunction(() => document.querySelector("[data-connect]").textContent === "Disconnect Radio");
  assert.equal(await page.evaluate(() => window.__pickerCalls), 0, "Installer restores the map connection");
  assert.equal(await page.locator("[data-radio-type]").textContent(), "RadioMaster TX16S");
  await activate(".ag-radio-help-button");
  assert.equal(await page.locator(".ag-radio-help-popover").evaluate((node) => node.matches(":popover-open")), true);
  await activate(".ag-radio-help-popover button");
  await page.goto(mapURL);
  await page.waitForFunction(() => document.querySelector("#ag-map-radio-state").textContent === "Radio connected"
    && document.querySelector("#ag-map-area-list").textContent.includes("Renamed smoke field"));
  assert.equal(await page.evaluate(() => window.__pickerCalls), 0, "Map Manager restores the installer connection");
  assert.equal(await page.locator("#ag-map-update").isDisabled(), true);
  for (const [path, text] of [
    ["MODELS/model1.yml", "keep model"], ["WIDGETS/AeroGrid/main.lua", "keep widget"],
    ["AEROGRID/layouts/user.yaml", "keep layout"], ["MAPS/other.txt", "keep other map"],
  ]) assert.equal((await read(path)).toString(), text);

  for (const width of [320, 768, 1280]) {
    await page.setViewportSize({ width, height: 1000 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
      `Map Manager must not overflow at ${width}px`);
  }
  await activate("#ag-map-connect");
  await page.goto(new URL("user-guide/installation/", site).href);
  await page.waitForFunction(() => document.querySelector("[data-connect]").textContent === "Connect Radio");
  assert.deepEqual(errors, []);
  console.log("Map Manager Chromium acceptance passed: generic help, native OPFS repair/review/sync, rename, shared-tile and user-data preservation, cross-page connection restoration/disconnect, responsive layout. Preview imagery is synthetic; no radio was accessed.");
} finally {
  await context.close();
  await browser.close();
}
