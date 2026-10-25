// SPDX-License-Identifier: GPL-2.0-only
/** Installation-page UI: connection, release selection, confirmation, and progress. */
import { radioStorage, compareVersions, radioHardware, radioCompatibility } from "./radio-storage.mjs";
import { actionFor, ContentMismatchError, loadCatalog, loadRelease, preparePackage, replaceWidget, verifyInstalled } from "./radio-installer.mjs";

const panel = document.querySelector("[data-radio-installer]");
if (panel) {
  const element = (name) => panel.querySelector(`[data-${name}]`);
  const base = new URL("../installer/", import.meta.url);
  const connect = element("connect");
  const install = element("install");
  const confirm = element("confirm");
  const confirmDialog = element("confirm-dialog");
  const confirmStart = element("confirm-start");
  const status = element("status");
  const releaseStatus = element("release-status");
  const progress = element("progress");
  const operationStatus = element("operation-status");
  const confirmClose = element("confirm-close");
  const releaseDialog = element("release-dialog");
  const supported = window.isSecureContext && typeof window.showDirectoryPicker === "function";
  let manifest = null;
  let latestManifest = null;
  let catalog = null;
  let selectedVersion = null;
  let details = null;
  let busy = false;
  let checking = false;
  let checkingRelease = false;
  let incomplete = false;
  let confirmation = null;
  let operationFinished = false;

  function message(text, error = false, success = false) {
    const target = busy && confirmDialog.open ? operationStatus : status;
    target.textContent = text;
    target.classList.toggle("ag-radio-error", error);
    target.classList.toggle("ag-radio-success", success);
  }

  function render() {
    const connected = !!radioStorage.root;
    element("connect-label").textContent = connected ? "Disconnect Radio" : "Connect Radio";
    connect.classList.toggle("ag-radio-primary", !connected);
    connect.classList.toggle("ag-radio-danger", connected);
    install.classList.toggle("ag-radio-primary", connected);
    connect.disabled = !supported || busy || checking || !!confirmation;
    panel.classList.toggle("ag-radio-connected", connected);
    panel.setAttribute("aria-busy", String(busy || checking));
    element("connection").textContent = connected ? "Radio connected" : "Radio disconnected";
    element("edgetx").textContent = details?.radio.version ?? "Unknown";
    const hardware = radioHardware(details?.radio.board);
    element("radio-type").textContent = hardware.type;
    element("radio-screen").textContent = hardware.screen;
    const compatibility = details ? radioCompatibility(details.radio) : null;
    element("compatibility").textContent = compatibility?.message ?? "Connect your radio to check compatibility.";
    element("compatibility").classList.toggle("ag-radio-compatibility-warning", !!compatibility && !compatibility.supported);
    element("widget").textContent = !details ? "Unknown" : !details.widget.present
      ? "Not installed" : details.widget.version ? `v${details.widget.version}` : "Unknown version";
    const displayedVersion = selectedVersion ?? latestManifest?.version;
    element("latest").textContent = displayedVersion
      ? `v${displayedVersion}${displayedVersion === catalog?.latest ? " - latest" : ""}` : "Unavailable";
    const releaseDisabled = busy || checking || checkingRelease || !!confirmation || !catalog;
    element("release-picker").disabled = releaseDisabled;
    element("release-open").disabled = releaseDisabled;
    const downgrade = details?.widget.version && manifest
      && compareVersions(details.widget.version, manifest.version) > 0;
    element("downgrade").hidden = !downgrade;
    element("downgrade").textContent = downgrade
      ? `Downgrade: AeroGrid v${details.widget.version} to v${manifest.version}. Older releases may not support your current layouts or settings. User data is not converted.`
      : "";
    const action = details && manifest
      ? actionFor(incomplete ? { present: true, version: null } : details.widget, manifest.version) : null;
    install.textContent = busy ? "Installation in progress..." : action?.label
      ?? (selectedVersion ? `Install AeroGrid v${selectedVersion}` : "Install latest AeroGrid");
    install.disabled = !supported || busy || checking || checkingRelease || !!confirmation || !connected || !action?.enabled;
    confirm.hidden = !confirmation;
    confirmClose.hidden = !operationFinished;
    confirmClose.textContent = "Done";
    element("confirm-cancel").disabled = busy;
  }

  function closeConfirmation() {
    confirmation = null;
    confirmDialog.close();
    render();
    install.focus();
  }

  async function inspect() {
    details = await radioStorage.inspect();
    if (details.widget.present && details.widget.version === manifest?.version) {
      try {
        await verifyInstalled(radioStorage.root, manifest, () => {}, true);
        incomplete = false;
      } catch (error) {
        if (!(error instanceof ContentMismatchError)) throw error;
        console.error("[AeroGrid installer] Installed file verification failed.", error, error.differences);
        incomplete = true;
        message(`${error.message} A full replacement is available.`, true);
      }
    }
  }

  function renderReleases() {
    element("releases").replaceChildren();
    for (const entry of catalog.releases) {
      const row = document.createElement("div");
      row.className = "ag-release-row";
      const label = document.createElement("label");
      const input = document.createElement("input");
      input.type = "radio";
      input.name = "aerogrid-release";
      input.value = entry.version;
      input.checked = entry.version === selectedVersion;
      input.disabled = !entry.available;
      const text = document.createElement("span");
      const title = document.createElement("strong");
      title.textContent = `v${entry.version}${entry.version === catalog.latest ? " - latest" : ""}`;
      const description = document.createElement("small");
      description.textContent = entry.available ? entry.name : entry.reason;
      text.append(title, description);
      label.append(input, text);
      const link = document.createElement("a");
      link.href = entry.release;
      link.textContent = "Release notes";
      link.setAttribute("aria-label", `Release notes for AeroGrid v${entry.version}`);
      row.append(label, link);
      element("releases").append(row);
    }
  }

  async function refreshRelease() {
    checkingRelease = true;
    manifest = null;
    releaseStatus.textContent = "Checking the latest stable release...";
    render();
    try {
      catalog = await loadCatalog(base);
      selectedVersion = catalog.latest;
      renderReleases();
      const latest = catalog.releases.find((entry) => entry.version === selectedVersion);
      if (!latest.available) {
        latestManifest = null;
        releaseStatus.textContent = `${latest.reason} Choose another available release or use the manual ZIP instructions below.`;
        return;
      }
      latestManifest = await loadRelease(base, selectedVersion);
      manifest = latestManifest;
      releaseStatus.textContent = "";
      if (radioStorage.root) await inspect();
    } catch (error) {
      manifest = null;
      latestManifest = null;
      catalog = null;
      releaseStatus.textContent = `Automatic installation unavailable: ${error.message} Reload the page to check again, or use the manual ZIP instructions below.`;
    } finally {
      checkingRelease = false;
      render();
    }
  }

  element("release-open").addEventListener("click", () => {
    releaseDialog.showModal();
    const selected = releaseDialog.querySelector("input:checked");
    selected?.focus();
  });
  element("release-close").addEventListener("click", () => releaseDialog.close());
  releaseDialog.addEventListener("close", () => element("release-open").focus());

  element("releases").addEventListener("change", async (event) => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) || input.type !== "radio"
        || busy || checking || checkingRelease || confirmation
        || !catalog?.releases.some((entry) => entry.version === input.value && entry.available)) return;
    selectedVersion = input.value;
    releaseDialog.close();
    manifest = null;
    incomplete = false;
    checkingRelease = true;
    releaseStatus.textContent = `Checking AeroGrid v${selectedVersion}...`;
    render();
    try {
      manifest = await loadRelease(base, selectedVersion);
      if (radioStorage.root) await inspect();
      releaseStatus.textContent = "";
    } catch (error) {
      manifest = null;
      releaseStatus.textContent = `Selected release unavailable: ${error.message}`;
    } finally {
      checkingRelease = false;
      render();
    }
  });

  connect.addEventListener("click", async () => {
    if (radioStorage.root) {
      radioStorage.disconnect();
      details = null;
      incomplete = false;
      message("Disconnected from this page. Eject the SD card through your operating system before unplugging.");
      render();
      return;
    }
    checking = true;
    message("Select the mounted radio SD-card root. No files are changed when connecting.");
    render();
    try {
      await radioStorage.connect();
      incomplete = false;
      message("");
      await inspect();
      if (!details.radio.board || !details.radio.version) {
        message("Radio details are incomplete. Check the radio's system information, then reconnect.", true);
      }
    } catch (error) {
      radioStorage.disconnect();
      details = null;
      if (error.name === "AbortError") message("Connection cancelled or folder access was not granted.");
      else message(`Unable to connect: ${error.message}`, true);
    } finally {
      checking = false;
      render();
    }
  });

  install.addEventListener("click", async () => {
    if (!manifest || !details || busy) return;
    const version = manifest.version;
    const downgrade = details.widget.version && compareVersions(details.widget.version, version) > 0;
    const compatibility = radioCompatibility(details.radio);
    const warning = `Install AeroGrid v${version} on ${details.radio.name}?\n\n`
      + (!compatibility.supported ? `${compatibility.message}\n\n` : "")
      + (downgrade ? `DOWNGRADE from v${details.widget.version} to v${version}. Older releases may not support your current layouts or settings. User data will not be converted.\n\n` : "")
      + (details.widget.present
        ? "This will replace the AeroGrid installation on your radio. No backup or rollback is available.\n\n"
        : "This will install AeroGrid on your radio.\n\n")
      + (!details.widget.version && details.widget.present ? "The existing version is unknown; version comparison is unavailable.\n\n" : "")
      + "AeroGrid user data, maps, other widgets, model/radio settings, and firmware will not be changed.";
    confirmation = { version, details: structuredClone(details), downgrade: !!downgrade };
    element("confirm-title").textContent = downgrade ? "Confirm downgrade" : "Confirm installation";
    confirmStart.textContent = downgrade ? `Confirm downgrade to v${version}` : `Confirm installation of v${version}`;
    element("confirm-description").textContent = warning;
    operationFinished = false;
    progress.hidden = true;
    operationStatus.textContent = "";
    operationStatus.classList.remove("ag-radio-error", "ag-radio-success");
    render();
    confirmDialog.showModal();
    confirmStart.focus();
  });

  element("confirm-cancel").addEventListener("click", () => {
    confirmation = null;
    confirmDialog.close();
    render();
    install.focus();
  });

  confirmDialog.addEventListener("cancel", (event) => {
    if (busy) {
      event.preventDefault();
      return;
    }
    confirmation = null;
    render();
    queueMicrotask(() => install.focus());
  });
  confirmDialog.addEventListener("close", () => {
    if (!operationFinished) return;
    const result = operationStatus.textContent;
    const failed = operationStatus.classList.contains("ag-radio-error");
    const succeeded = operationStatus.classList.contains("ag-radio-success");
    operationFinished = false;
    render();
    if (result) message(result, failed, succeeded);
  });
  confirmClose.addEventListener("click", closeConfirmation);

  confirmStart.addEventListener("click", async () => {
    if (!confirmation || busy) return;
    const { version, details: expected, downgrade } = confirmation;
    confirmation = null;
    operationFinished = false;
    busy = true;
    const permission = radioStorage.requestWritePermission();
    progress.hidden = false;
    progress.value = 0;
    render();
    let replacing = false;
    const report = (text, count, total) => {
      message(text);
      progress.value = total ? count / total : 0;
    };
    try {
      await permission;
      await radioStorage.exclusive(async (root) => {
        const selected = await loadRelease(base, version);
        if (selected.version !== version) throw new Error("This release is no longer available. Reload and choose it again.");
        const prepared = await preparePackage(selected, base, report);
        const current = await radioStorage.inspect();
        if (current.radio.board !== expected.radio.board || current.radio.version !== expected.radio.version
            || current.widget.present !== expected.widget.present || current.widget.version !== expected.widget.version) {
          throw new Error("The radio information or installed AeroGrid version changed. Reconnect and confirm installation again.");
        }
        replacing = true;
        await replaceWidget(root, prepared, report, { allowDowngrade: downgrade });
        manifest = selected;
        incomplete = false;
        await inspect();
      });
      progress.value = 1;
      message(`Done. AeroGrid v${version} installed successfully. Disconnect Radio, safely eject the drive through your operating system, then unplug the USB data cable.`, false, true);
    } catch (error) {
      if (replacing) incomplete = true;
      console.error("[AeroGrid installer] Installation failed.", error, error.cause?.differences);
      message(`${error.message}${replacing ? "" : " No radio files were changed."}`, true);
    } finally {
      busy = false;
      operationFinished = true;
      render();
    }
  });

  window.addEventListener("beforeunload", (event) => {
    if (busy) {
      event.preventDefault();
      event.returnValue = "";
    }
  });

  // Folder handles have no reliable USB unplug event; re-read while the page is visible.
  setInterval(async () => {
    if (!radioStorage.root || busy || checking || checkingRelease || document.hidden) return;
    checking = true;
    const previous = details;
    const root = radioStorage.root;
    let invalidated = false;
    try {
      const current = await radioStorage.inspect();
      if (busy || radioStorage.root !== root || details !== previous) return;
      if (JSON.stringify(current) !== JSON.stringify(details)) {
        details = current;
        if (confirmation) {
          confirmation = null;
          confirmDialog.close();
          invalidated = true;
          message("The radio information or installed AeroGrid version changed. Review the versions and confirm installation again.");
        }
      }
    } catch (error) {
      if (busy || radioStorage.root !== root || details !== previous) return;
      radioStorage.disconnect();
      details = null;
      if (confirmation) {
        confirmation = null;
        confirmDialog.close();
        invalidated = true;
      }
      message(`SD-card access lost: ${error.message} Reconnect the radio and select its SD card again.`, true);
    } finally {
      checking = false;
      render();
      if (invalidated) (radioStorage.root ? install : connect).focus();
    }
  }, 5000);

  render();
  if (!supported) {
    message("USB installation requires desktop Chrome or Edge over HTTPS (or localhost). Safari and Opera are not supported. Use the manual ZIP instructions below.");
  }
  if (supported) {
    checking = true;
    render();
    void (async () => {
      try {
        if (await radioStorage.restore()) await inspect();
      } catch (error) {
        radioStorage.disconnect();
        details = null;
        message(error.message, true);
      } finally {
        checking = false;
        render();
      }
    })();
  }
  void refreshRelease();
}
