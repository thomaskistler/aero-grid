// SPDX-License-Identifier: GPL-2.0-only
// Optional Chromium acceptance check: the picker returns native, disposable OPFS handles.
import assert from "node:assert/strict";
import { RELEASE_API } from "../../docs/javascripts/radio-installer.mjs";

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? "playwright");
const site = new URL(process.argv[2] ?? "http://127.0.0.1:8000/");
const manifest = await (await fetch(new URL("installer/latest.json", site))).json();
const catalog = await (await fetch(new URL("installer/releases.json", site))).json();
const historical = catalog.releases.find((entry) => entry.available && entry.version !== catalog.latest);
assert.ok(historical, "Acceptance requires a mirrored historical release");
const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}),
});
const context = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
const errors = [];
context.on("page", (page) => page.on("pageerror", (error) => errors.push(error.message)));
await context.route("**/*", async (route) => {
  const url = route.request().url();
  const tagPrefix = RELEASE_API.replace("/latest", "/tags/v");
  if (url === RELEASE_API || url.startsWith(tagPrefix)) {
    const version = url === RELEASE_API ? manifest.version : url.slice(tagPrefix.length);
    await route.fulfill({ json: {
      tag_name: `v${version}`, draft: false, prerelease: false,
      assets: [`AeroGrid-${version}.zip`, `AeroGrid-${version}.zip.sha256`].map((name) => ({
        name,
        browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/v${version}/${name}`,
      })),
    } });
  } else if (new URL(url).origin === site.origin) await route.continue();
  else await route.abort();
});

try {
  const page = await context.newPage();
  const activate = (selector) => process.env.INSTALLER_KEYBOARD
    ? page.locator(selector).press("Enter") : page.locator(selector).click();
  await page.addInitScript(() => {
    if (window !== window.top) return;
    // The docs theme's external syntax highlighter is unrelated to this offline check.
    window.hljs = { highlightAll() {} };
    window.__radioReady = (async () => {
      const privateRoot = await navigator.storage.getDirectory();
      const root = await privateRoot.getDirectoryHandle("installer-acceptance", { create: true });
      const put = async (path, text) => {
        const parts = path.split("/");
        let directory = root;
        for (const part of parts.slice(0, -1)) directory = await directory.getDirectoryHandle(part, { create: true });
        const file = await directory.getFileHandle(parts.at(-1), { create: true });
        const stream = await file.createWritable();
        await stream.write(text);
        await stream.close();
      };
      await put("RADIO/radio.yml", "board: tx16s\nsemver: 2.12.4\n");
      await put("MODELS/model1.yml", "keep model");
      await put("AEROGRID/layouts/user.yaml", "keep layout");
      await put("MAPS/tile.png", "keep map");
      await put("WIDGETS/Other/main.lua", "keep other widget");
      await put("WIDGETS/AeroGrid/main.luac", "stale bytecode");
      await put("WIDGETS/AeroGrid/lib/package.lua", 'return {\nversion = "0.0.1",\n}');
      return root;
    })();
    window.showDirectoryPicker = async (options) => {
      if (options.mode !== "read") throw new Error("Connection must be read-only");
      return window.__radioReady;
    };
  });
  await page.goto(new URL("user-guide/installation/", site).href);
  await page.waitForFunction(() => document.querySelector("[data-latest]").textContent !== "Unavailable");
  assert.equal(await page.locator("[data-connect] .ag-usb-icon").count(), 1);
  assert.equal(await page.locator(`input[name=aerogrid-release][value="${catalog.latest}"]`).isChecked(), true);
  assert.equal(await page.locator("input[name=aerogrid-release]").count(), catalog.releases.length);
  assert.equal(await page.locator("[data-release-dialog]").isVisible(), false);
  await activate("[data-release-open]");
  assert.equal(await page.locator("[data-release-dialog]").isVisible(), true);
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("[data-release-dialog]").isVisible(), false);
  assert.equal(await page.locator("[data-release-open]").evaluate((node) => node === document.activeElement), true);
  await activate("[data-release-open]");
  await activate("[data-release-close]");
  assert.equal(await page.locator("[data-release-dialog]").isVisible(), false);
  for (const entry of catalog.releases.filter((entry) => !entry.available)) {
    assert.equal(await page.locator(`input[name=aerogrid-release][value="${entry.version}"]`).isDisabled(), true);
  }
  assert.equal(await page.locator("[data-install]").isDisabled(), true);
  assert.match(await page.locator("[data-connect]").getAttribute("class"), /ag-radio-primary/);
  assert.doesNotMatch(await page.locator("[data-install]").getAttribute("class"), /ag-radio-primary/);
  assert.equal(await page.locator(".ag-guide-sidebar").count(), 0);
  assert.equal(await page.locator(".ag-icon-link.active").getAttribute("aria-label"), "Install / Upgrade");
  assert.equal(await page.locator(".ag-install-details[open]").count(), 0);
  assert.ok(await page.evaluate(() => {
    const panel = document.querySelector("[data-radio-installer]").getBoundingClientRect();
    const help = document.querySelector(".ag-install-help").getBoundingClientRect();
    const connect = document.querySelector("[data-connect]").getBoundingClientRect();
    const install = document.querySelector("[data-install]").getBoundingClientRect();
    return panel.right <= help.left && Math.abs(panel.top - help.top) < 1
      && connect.bottom < window.innerHeight && install.bottom < window.innerHeight;
  }), "Desktop layout puts setup beside the installer and both actions in the first viewport");
  await activate("[data-connect]");
  await page.waitForFunction(() => document.querySelector("[data-connect]").textContent === "Disconnect Radio");
  assert.equal(await page.locator("[data-edgetx]").textContent(), "2.12.4");
  assert.match(await page.locator("[data-device]").textContent(), /tx16s/);
  assert.match(await page.locator("[data-install]").textContent(), /^Update/);
  assert.equal(await page.locator("[data-install]").isDisabled(), false);
  assert.equal(await page.locator("[data-connect] .ag-usb-icon").count(), 1);
  assert.match(await page.locator("[data-install]").getAttribute("class"), /ag-radio-primary/);
  assert.doesNotMatch(await page.locator("[data-connect]").getAttribute("class"), /ag-radio-primary/);
  const read = (path) => page.evaluate(async (path) => {
    let directory = await window.__radioReady;
    const parts = path.split("/");
    for (const part of parts.slice(0, -1)) directory = await directory.getDirectoryHandle(part);
    return (await (await directory.getFileHandle(parts.at(-1))).getFile()).text();
  }, path);
  assert.equal(await read("WIDGETS/AeroGrid/main.luac"), "stale bytecode");
  await activate("[data-install]");
  assert.match(await page.locator("[data-confirm-description]").textContent(), /NO backup or rollback/);
  await activate("[data-confirm-cancel]");
  assert.equal(await read("WIDGETS/AeroGrid/main.luac"), "stale bytecode");

  // A failed download must leave even the old bytecode untouched.
  await page.route("**/installer/releases/**/main.lua", (route) => route.fulfill({ status: 503, body: "Unavailable" }));
  await activate("[data-install]");
  await activate("[data-confirm-start]");
  await page.waitForFunction(() => document.querySelector("[data-status]").textContent.includes("No radio files were changed"));
  assert.equal(await read("WIDGETS/AeroGrid/main.luac"), "stale bytecode");
  await page.unroute("**/installer/releases/**/main.lua");

  await activate("[data-install]");
  await activate("[data-confirm-start]");
  await page.waitForFunction(() => document.querySelector("[data-status]").textContent.includes("installed and file contents verified"), null, { timeout: 60000 });
  assert.equal(await page.locator("[data-install]").textContent(), "Up to date");
  assert.equal(await page.locator("[data-install]").isDisabled(), true);
  for (const [path, text] of [
    ["RADIO/radio.yml", "board: tx16s\nsemver: 2.12.4\n"],
    ["MODELS/model1.yml", "keep model"], ["AEROGRID/layouts/user.yaml", "keep layout"],
    ["MAPS/tile.png", "keep map"], ["WIDGETS/Other/main.lua", "keep other widget"],
  ]) assert.equal(await read(path), text);
  await assert.rejects(read("WIDGETS/AeroGrid/main.luac"), /not.*found/i);

  const historicalAPI = RELEASE_API.replace("/latest", `/tags/v${historical.version}`);
  await page.route(historicalAPI, (route) => route.fulfill({ status: 503, body: "Unavailable" }));
  await activate("[data-release-open]");
  await page.locator(`input[name=aerogrid-release][value="${historical.version}"]`).press("Space");
  await page.waitForFunction(() => document.querySelector("[data-release-status]").textContent.startsWith("Selected release unavailable:"));
  assert.equal(await page.locator("[data-install]").isDisabled(), true);
  assert.match(await read("WIDGETS/AeroGrid/lib/package.lua"), new RegExp(manifest.version.replaceAll(".", "\\.")));
  await page.unroute(historicalAPI);
  const chooseRelease = async (version) => {
    await activate("[data-release-open]");
    await page.locator(`input[name=aerogrid-release][value="${version}"]`).press("Space");
    await page.waitForFunction((version) =>
      document.querySelector("[data-release-status]").textContent.startsWith(`Selected release: ${version}`), version);
    assert.equal(await page.locator("[data-release-dialog]").isVisible(), false);
    assert.equal(await page.locator("[data-latest]").textContent(), version);
  };
  await chooseRelease(catalog.latest);
  await chooseRelease(historical.version);
  assert.equal(await page.locator("[data-latest]").textContent(), historical.version);
  assert.equal(await page.locator("[data-release-label]").textContent(), "Selected AeroGrid release");
  assert.equal(await page.locator("[data-downgrade]").isVisible(), true);
  assert.match(await page.locator("[data-install]").textContent(), /^Downgrade/);
  await activate("[data-install]");
  assert.equal(await page.locator(`input[name=aerogrid-release][value="${catalog.latest}"]`).isDisabled(), true);
  assert.match(await page.locator("[data-confirm-description]").textContent(), /DOWNGRADE from/);
  assert.match(await page.locator("[data-confirm-start]").textContent(), /^Confirm downgrade/);
  await activate("[data-confirm-cancel]");
  assert.match(await read("WIDGETS/AeroGrid/lib/package.lua"), new RegExp(manifest.version.replaceAll(".", "\\.")));
  await activate("[data-install]");
  await activate("[data-confirm-start]");
  await page.waitForFunction((version) =>
    document.querySelector("[data-status]").textContent.includes(`AeroGrid ${version} installed and file contents verified`),
  historical.version, { timeout: 60000 });
  assert.equal(await page.locator("[data-install]").textContent(), "Up to date");
  assert.equal(await page.locator("[data-downgrade]").isVisible(), false);
  assert.match(await read("WIDGETS/AeroGrid/lib/package.lua"), new RegExp(historical.version.replaceAll(".", "\\.")));
  assert.equal(await read("AEROGRID/layouts/user.yaml"), "keep layout");
  assert.equal(await read("MAPS/tile.png"), "keep map");
  await chooseRelease(catalog.latest);
  assert.equal(await page.locator("[data-release-label]").textContent(), "Latest stable AeroGrid");
  assert.match(await page.locator("[data-install]").textContent(), /^Update/);
  assert.equal(await page.locator("[data-downgrade]").isVisible(), false);
  await activate("[data-connect]");
  assert.equal(await page.locator("[data-connect]").textContent(), "Connect Radio");
  assert.equal(await page.locator("[data-install]").isDisabled(), true);
  assert.match(await page.locator("[data-connect]").getAttribute("class"), /ag-radio-primary/);
  assert.doesNotMatch(await page.locator("[data-install]").getAttribute("class"), /ag-radio-primary/);

  for (const width of [320, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: 1000 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
      `Installation layout must not overflow at ${width}px`);
    await activate("[data-release-open]");
    assert.ok(await page.locator("[data-release-dialog]").evaluate((node) => {
      const rect = node.getBoundingClientRect();
      return rect.left >= 0 && rect.right <= innerWidth
        && rect.top >= 0 && rect.bottom <= innerHeight && node.scrollWidth <= node.clientWidth;
    }), `Release popup must fit at ${width}px`);
    await page.keyboard.press("Escape");
  }
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  assert.ok(await page.evaluate(() => {
    const panel = document.querySelector("[data-radio-installer]").getBoundingClientRect();
    const help = document.querySelector(".ag-install-help").getBoundingClientRect();
    return help.top >= panel.bottom;
  }), "Mobile layout stacks setup below the installer");
  assert.equal(await page.locator("[data-radio-installer] button:visible").count(), 3);
  await activate(".ag-install-details summary >> nth=0");
  assert.equal(await page.locator(".ag-install-details[open]").count(), 1);

  const guide = await context.newPage();
  await guide.addInitScript(() => { window.hljs = { highlightAll() {} }; });
  await guide.goto(new URL("user-guide/add-dashboard/", site).href);
  assert.equal(await guide.locator(".ag-guide-sidebar").count(), 1);

  const unsupported = await context.newPage();
  await unsupported.addInitScript(() => {
    if (window !== window.top) return;
    window.hljs = { highlightAll() {} };
    window.showDirectoryPicker = undefined;
  });
  await unsupported.goto(new URL("user-guide/installation/", site).href);
  await unsupported.waitForFunction(() => document.querySelector("[data-status]").textContent.includes("requires desktop Chrome"));
  assert.equal(await unsupported.locator("[data-connect]").isDisabled(), true);
  assert.equal(await unsupported.locator("[data-install]").isDisabled(), true);
  assert.deepEqual(errors, []);
  console.log("Chromium panel acceptance passed: USB icon, release selection, authorized downgrade/readback, failed checks/downloads, preserved data, disconnect, responsive layout, unsupported browser. OS picker selection is simulated; no radio was accessed.");
} catch (error) {
  for (const page of context.pages()) {
    if (!await page.locator("[data-radio-installer]").count()) continue;
    console.error(await page.locator("[data-radio-installer]").innerText());
    console.error(await page.evaluate(() => ({
      disabled: document.querySelector("[data-install]").disabled,
      confirmationHidden: document.querySelector("[data-confirm]").hidden,
    })));
  }
  console.error("Browser errors:", errors);
  console.error("Browser:", browser.version());
  throw error;
} finally {
  await context.close();
  await browser.close();
}
