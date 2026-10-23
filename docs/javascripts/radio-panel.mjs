// SPDX-License-Identifier: GPL-2.0-only
import { radioStorage, compareVersions, radioHardware, radioCompatibility } from "./radio-storage.mjs";
import { actionFor, ContentMismatchError, loadCatalog, loadLatest, loadRelease, preparePackage, replaceWidget, verifyInstalled } from "./radio-installer.mjs";

const panel = document.querySelector("[data-radio-installer]");
if (panel) {
  const element = (name) => panel.querySelector(`[data-${name}]`);
  const base = new URL("../installer/", import.meta.url);
  const connect = element("connect");
  const install = element("install");
  const confirm = element("confirm");
  const confirmStart = element("confirm-start");
  const status = element("status");
  const releaseStatus = element("release-status");
  const progress = element("progress");
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

  function message(text, error = false) {
    status.textContent = text;
    status.classList.toggle("ag-radio-error", error);
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
    element("connection").textContent = connected ? "SD card connected" : "Radio disconnected";
    element("device").textContent = details
      ? `${details.radio.board ?? "Unknown board"} | ${details.radio.name}` : "No SD card selected";
    element("edgetx").textContent = details?.radio.version ?? "Unknown";
    const hardware = radioHardware(details?.radio.board);
    element("radio-type").textContent = hardware.type;
    element("radio-screen").textContent = hardware.screen;
    const compatibility = details ? radioCompatibility(details.radio) : null;
    element("compatibility").textContent = compatibility?.message ?? "Connect your radio to check compatibility.";
    element("compatibility").classList.toggle("ag-radio-compatibility-warning", !!compatibility && !compatibility.supported);
    element("widget").textContent = !details ? "Unknown" : !details.widget.present
      ? "Not installed" : `${details.widget.version ?? "Unknown version"}${incomplete ? " | incomplete / different files" : " | metadata detected"}`;
    const displayedVersion = selectedVersion ?? latestManifest?.version;
    element("latest").textContent = displayedVersion
      ? `${displayedVersion}${displayedVersion === catalog?.latest ? " - latest" : ""}` : "Unavailable";
    const releaseDisabled = busy || checking || checkingRelease || !!confirmation || !catalog;
    element("release-picker").disabled = releaseDisabled;
    element("release-open").disabled = releaseDisabled;
    const downgrade = details?.widget.version && manifest
      && compareVersions(details.widget.version, manifest.version) > 0;
    element("downgrade").hidden = !downgrade;
    element("downgrade").textContent = downgrade
      ? `Downgrade: AeroGrid ${details.widget.version} to ${manifest.version}. Older releases may not support your current layouts or settings. User data is not converted.`
      : "";
    const action = details && manifest
      ? actionFor(incomplete ? { present: true, version: null } : details.widget, manifest.version) : null;
    install.textContent = busy ? "Installation in progress..." : action?.label
      ?? (selectedVersion ? `Install AeroGrid ${selectedVersion}` : "Install latest AeroGrid");
    install.disabled = !supported || busy || checking || checkingRelease || !!confirmation || !connected || !action?.enabled;
    confirm.hidden = !confirmation;
  }

  async function inspect() {
    details = await radioStorage.inspect();
    if (details.widget.present && details.widget.version === manifest?.version) {
      try {
        await verifyInstalled(radioStorage.root, manifest, () => {}, true);
        incomplete = false;
      } catch (error) {
        if (!(error instanceof ContentMismatchError)) throw error;
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
      title.textContent = `${entry.version}${entry.version === catalog.latest ? " - latest" : ""}`;
      const description = document.createElement("small");
      description.textContent = entry.available ? entry.name : entry.reason;
      text.append(title, description);
      label.append(input, text);
      const link = document.createElement("a");
      link.href = entry.release;
      link.textContent = "Release notes";
      link.setAttribute("aria-label", `Release notes for AeroGrid ${entry.version}`);
      row.append(label, link);
      element("releases").append(row);
    }
  }

  async function selectedRelease(version) {
    return version === catalog.latest ? loadLatest(base) : loadRelease(base, version);
  }

  async function refreshRelease() {
    checkingRelease = true;
    manifest = null;
    releaseStatus.textContent = "Checking the latest stable release...";
    render();
    try {
      [latestManifest, catalog] = await Promise.all([loadLatest(base), loadCatalog(base)]);
      if (catalog.latest !== latestManifest.version) throw new Error("Release catalog is out of date. Reload after publication.");
      selectedVersion = catalog.latest;
      manifest = latestManifest;
      renderReleases();
      releaseStatus.textContent = `Selected release: ${manifest.version} (latest stable).`;
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
    releaseStatus.textContent = `Checking AeroGrid ${selectedVersion}...`;
    render();
    try {
      manifest = await selectedRelease(selectedVersion);
      if (radioStorage.root) await inspect();
      releaseStatus.textContent = `Selected release: ${manifest.version}${manifest.version === catalog.latest ? " (latest stable)" : ""}.`;
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
      message("SD card connected via folder access. Close other applications using the card before installing.");
      await inspect();
      if (!details.radio.board || !details.radio.version) {
        message("SD card connected. RADIO/radio.yml has missing or invalid board/semver metadata; the affected fields are Unknown.");
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
    const warning = `Install AeroGrid ${version} on ${details.radio.name}?\n\n`
      + (!compatibility.supported ? `${compatibility.message}\n\n` : "")
      + (downgrade ? `DOWNGRADE from ${details.widget.version} to ${version}. Older releases may not support your current layouts or settings. User data will not be converted.\n\n` : "")
      + "The entire WIDGETS/AeroGrid folder, including custom files inside it, will be deleted and replaced. "
      + "There is NO backup or rollback. An interruption may leave AeroGrid unusable until you reinstall.\n\n"
      + (!details.widget.version && details.widget.present ? "The existing version is unknown; version comparison is unavailable.\n\n" : "")
      + "User data in /AEROGRID, maps, other widgets, model/radio settings, and firmware will not be changed. "
      + "Keep USB connected and this page open until completion. Your radio must support EdgeTX's LVGL widget API.";
    confirmation = { version, details: structuredClone(details), downgrade: !!downgrade };
    element("confirm-title").textContent = downgrade ? "Confirm downgrade" : "Confirm installation";
    confirmStart.textContent = downgrade ? `Confirm downgrade to ${version}` : `Confirm installation of ${version}`;
    element("confirm-description").textContent = warning;
    render();
    confirmStart.focus();
  });

  element("confirm-cancel").addEventListener("click", () => {
    confirmation = null;
    render();
    install.focus();
  });

  confirmStart.addEventListener("click", async () => {
    if (!confirmation || busy) return;
    const { version, details: expected, downgrade } = confirmation;
    confirmation = null;
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
        const selected = await selectedRelease(version);
        if (selected.version !== version) throw new Error("The latest release changed. Reload to confirm the new version.");
        const prepared = await preparePackage(selected, base, report);
        const current = await radioStorage.inspect();
        if (current.radio.board !== expected.radio.board || current.radio.version !== expected.radio.version
            || current.widget.present !== expected.widget.present || current.widget.version !== expected.widget.version) {
          throw new Error("SD-card metadata changed since connection. Reconnect before installing.");
        }
        replacing = true;
        await replaceWidget(root, prepared, report, { allowDowngrade: downgrade });
        manifest = selected;
        incomplete = false;
        await inspect();
      });
      progress.value = 1;
      message(`AeroGrid ${version} installed and file contents verified. Disconnect from this page, safely eject through your operating system, then restart the radio.`);
    } catch (error) {
      if (replacing) incomplete = true;
      message(`${error.message}${replacing ? "" : " No radio files were changed."}`, true);
    } finally {
      busy = false;
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
    try {
      const current = await radioStorage.inspect();
      if (JSON.stringify(current) !== JSON.stringify(details)) {
        details = current;
        message("SD-card metadata changed. Review the detected versions before installing.");
      }
    } catch (error) {
      radioStorage.disconnect();
      details = null;
      confirmation = null;
      message(`SD-card access lost: ${error.message} Reconnect the radio and select its SD card again.`, true);
    } finally {
      checking = false;
      render();
    }
  }, 5000);

  render();
  if (!supported) {
    message("Automatic USB storage installation requires desktop Chrome or Edge over HTTPS (or localhost). Use the manual ZIP instructions below.");
  }
  void refreshRelease();
}
