// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";
import { actionFor, isDeveloperVersion } from "../../docs/javascripts/radio-installer.mjs";
import { compareVersions, radioCompatibility, radioHardware } from "../../docs/javascripts/radio-storage.mjs";

const source = (await readFile(new URL("../../docs/javascripts/radio-panel.mjs", import.meta.url), "utf8"))
  .replace(/^import .*;\n/gm, "")
  .replaceAll("import.meta.url", JSON.stringify(new URL("../../docs/javascripts/radio-panel.mjs", import.meta.url).href));

async function panel({ gtag, allowInstallation = false, downloadError, writeError,
  siteRoot, extraReleases = [], openConfirmation = true,
  docsURL = "https://thomaskistler.github.io/aero-grid/main/user-guide/installation/" } = {}) {
  class HTMLInputElement {}
  const elements = new Map();
  const document = { hidden: false, activeElement: null };
  function element(name) {
    if (elements.has(name)) return elements.get(name);
    const listeners = new Map();
    const classes = new Set();
    const node = {
      textContent: "", hidden: false, disabled: false, open: false, children: [], checked: false,
      classList: {
        toggle(name, enabled) { if (enabled) classes.add(name); else classes.delete(name); },
        remove(...names) { for (const name of names) classes.delete(name); },
        contains(name) { return classes.has(name); },
      },
      setAttribute() {},
      append(...children) { this.children.push(...children); },
      replaceChildren() { this.children = []; },
      addEventListener(event, listener) {
        if (!listeners.has(event)) listeners.set(event, []);
        listeners.get(event).push(listener);
      },
      async dispatch(event, payload = {}) {
        for (const listener of listeners.get(event) ?? []) await listener(payload);
      },
      focus() { if (!this.disabled) document.activeElement = this; },
      showModal() { this.open = true; },
      close() {
        this.open = false;
        void this.dispatch("close");
      },
    };
    elements.set(name, node);
    return node;
  }
  const host = element("panel");
  host.querySelector = (selector) => element(selector.slice(6, -1));
  document.querySelector = (selector) => selector === 'meta[name="aerogrid-site-root"]'
    ? { content: siteRoot } : host;
  document.createElement = (tag) => {
    const node = element(Symbol());
    if (tag === "input") Object.setPrototypeOf(node, HTMLInputElement.prototype);
    return node;
  };
  let details = {
    radio: { name: "Test SD", board: "tx16s", version: "2.12.4" },
    widget: { present: true, version: "0.0.1" },
  };
  let failure = null;
  const radioStorage = {
    root: {},
    restore: async () => true,
    inspect: async () => {
      if (failure) throw failure;
      return structuredClone(details);
    },
    disconnect() { this.root = null; },
    requestWritePermission() {
      assert.ok(allowInstallation, "Invalidated confirmation must not request write access");
    },
    exclusive: async (operation) => operation(radioStorage.root),
  };
  let poll;
  const requestedBases = [];
  vm.runInNewContext(source, {
    document, window: { isSecureContext: true, showDirectoryPicker() {}, addEventListener() {}, gtag },
    radioStorage, actionFor, isDeveloperVersion, compareVersions, radioCompatibility, radioHardware, HTMLInputElement,
    structuredClone, URL, console, queueMicrotask, location: { href: docsURL },
    loadCatalog: async (base) => {
      requestedBases.push(base.href);
      return { latest: "1.0.0", releases: [{ version: "1.0.0", available: true, name: "Test release" }, ...extraReleases] };
    },
    loadRelease: async (base, version) => {
      requestedBases.push(base.href);
      return { version };
    },
    preparePackage: async (manifest) => {
      if (downloadError) throw downloadError;
      return { version: manifest.version, files: [] };
    },
    replaceWidget: async (_root, prepared) => {
      if (writeError) throw writeError;
      details.widget.version = prepared.version;
    },
    verifyInstalled: async () => {},
    setInterval(callback, interval) { assert.equal(interval, 5000); poll = callback; },
  }, { filename: "radio-panel.mjs" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(element("install").disabled, false);
  if (openConfirmation) {
    await element("install").dispatch("click");
    assert.equal(element("confirm-dialog").open, true);
    assert.equal(element("confirm").hidden, false);
  }
  return {
    element, document, radioStorage, poll, requestedBases,
    change(update) { details = update(structuredClone(details)); },
    loseAccess(name) { failure = new DOMException("Drive unavailable", name); },
  };
}

test("developer builds require checkbox opt-in, warn before installation, and reset to stable when hidden", async () => {
  const version = "1.0.0-dev.12+g" + "a".repeat(40);
  const ui = await panel({
    openConfirmation: false, allowInstallation: true,
    extraReleases: [{ version, available: true, name: "Developer build" }],
  });
  const rows = () => ui.element("releases").children;
  assert.equal(rows().length, 1);
  assert.equal(ui.element("developer-releases").checked, false);
  ui.element("developer-releases").checked = true;
  await ui.element("developer-releases").dispatch("change");
  assert.equal(rows().length, 2);
  const developer = rows()[1].children[0].children[0];
  assert.equal(developer.value, version);
  await ui.element("releases").dispatch("change", { target: developer });
  assert.match(ui.element("latest").textContent, /developer build/);
  await ui.element("install").dispatch("click");
  assert.match(ui.element("confirm-description").textContent, /DEVELOPER BUILD.*unstable/);
  await ui.element("confirm-cancel").dispatch("click");
  ui.element("developer-releases").checked = false;
  await ui.element("developer-releases").dispatch("change");
  assert.equal(rows().length, 1);
  assert.equal(ui.element("latest").textContent, "v1.0.0 - latest");
  await ui.element("releases").dispatch("change", { target: developer });
  assert.equal(ui.element("latest").textContent, "v1.0.0 - latest");
});

for (const version of ["main", "0.1.0", "0.4.0"]) {
  test(`documentation version ${version} uses the shared installer and its independent latest release`, async () => {
    const ui = await panel({
      siteRoot: "/aero-grid/",
      docsURL: `https://thomaskistler.github.io/aero-grid/${version}/user-guide/installation/`,
    });
    assert.deepEqual(ui.requestedBases, Array(2).fill("https://thomaskistler.github.io/aero-grid/installer/"));
    assert.equal(ui.element("latest").textContent, "v1.0.0 - latest");
  });
}

test("each verified release download emits one analytics event with its version", async () => {
  const events = [];
  const ui = await panel({
    allowInstallation: true,
    gtag: (command, event, parameters) => events.push([command, event, { ...parameters }]),
  });
  for (let count = 1; count <= 2; count++) {
    await ui.element("confirm-start").dispatch("click");
    assert.deepEqual(events, Array.from({ length: count }, () =>
      ["event", "release_download", { version: "1.0.0" }]));
    assert.match(ui.element("operation-status").textContent, /installed successfully/);
    await ui.element("confirm-close").dispatch("click");
    ui.change((details) => {
      details.widget.version = "0.0.1";
      return details;
    });
    await ui.poll();
    await ui.element("install").dispatch("click");
  }
});

test("failed downloads do not emit analytics events", async () => {
  const events = [];
  const ui = await panel({
    allowInstallation: true,
    downloadError: new Error("Download content verification failed"),
    gtag: (...event) => events.push(event),
  });
  await ui.element("confirm-start").dispatch("click");
  assert.deepEqual(events, []);
  assert.match(ui.element("operation-status").textContent, /Download content verification failed/);
});

test("a successful download counts even if writing to the radio later fails", async () => {
  const events = [];
  const ui = await panel({
    allowInstallation: true,
    writeError: new Error("Radio disconnected"),
    gtag: (...event) => events.push(event),
  });
  await ui.element("confirm-start").dispatch("click");
  assert.equal(events.length, 1);
  assert.equal(events[0][1], "release_download");
  assert.match(ui.element("operation-status").textContent, /Radio disconnected/);
});

test("installation succeeds when analytics is unavailable", async () => {
  const ui = await panel({ allowInstallation: true });
  await ui.element("confirm-start").dispatch("click");
  assert.match(ui.element("operation-status").textContent, /installed successfully/);
});

for (const changed of ["radio", "widget"]) {
  test(`${changed} metadata change dismisses confirmation and permits a fresh confirmation`, async () => {
    const ui = await panel();
    ui.change((details) => {
      if (changed === "radio") details.radio.version = "2.12.5";
      else details.widget.version = "0.0.2";
      return details;
    });
    await ui.poll();
    assert.equal(ui.element("confirm-dialog").open, false);
    assert.equal(ui.element("confirm").hidden, true);
    assert.match(ui.element("status").textContent, /changed.*confirm installation again/);
    assert.equal(ui.element(changed === "radio" ? "edgetx" : "widget").textContent,
      changed === "radio" ? "2.12.5" : "v0.0.2");
    assert.equal(ui.element("install").disabled, false);
    assert.equal(ui.document.activeElement, ui.element("install"));
    await ui.element("confirm-start").dispatch("click");
    await ui.element("install").dispatch("click");
    assert.equal(ui.element("confirm-dialog").open, true);
    assert.equal(ui.element("confirm").hidden, false);
  });
}

for (const error of ["NotAllowedError", "NotFoundError"]) {
  test(`${error} dismisses confirmation, explains lost access, and enables reconnect`, async () => {
    const ui = await panel();
    ui.loseAccess(error);
    await ui.poll();
    assert.equal(ui.element("confirm-dialog").open, false);
    assert.equal(ui.element("confirm").hidden, true);
    assert.match(ui.element("status").textContent, /SD-card access lost:.*Reconnect/);
    assert.equal(ui.element("status").classList.contains("ag-radio-error"), true);
    assert.equal(ui.radioStorage.root, null);
    assert.equal(ui.element("connection").textContent, "Radio disconnected");
    assert.equal(ui.element("install").disabled, true);
    assert.equal(ui.element("connect").disabled, false);
    assert.equal(ui.document.activeElement, ui.element("connect"));
    await ui.element("confirm-start").dispatch("click");
  });
}
