// SPDX-License-Identifier: GPL-2.0-only
import { radioStorage, compareVersions } from "./radio-storage.mjs";
import { actionFor, ContentMismatchError, loadLatest, preparePackage, replaceWidget, verifyInstalled } from "./radio-installer.mjs";

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
  const supported = window.isSecureContext && typeof window.showDirectoryPicker === "function";
  let manifest = null;
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
    connect.textContent = connected ? "Disconnect Radio" : "Connect Radio";
    connect.disabled = !supported || busy || checking || !!confirmation;
    panel.classList.toggle("ag-radio-connected", connected);
    panel.setAttribute("aria-busy", String(busy || checking));
    element("connection").textContent = connected ? "SD card connected" : "Radio disconnected";
    element("device").textContent = details
      ? `${details.radio.board ?? "Unknown board"} | ${details.radio.name}` : "No SD card selected";
    element("edgetx").textContent = details?.radio.version ?? "Unknown";
    element("edgetx-source").textContent = details
      ? "Source: RADIO/radio.yml (saved firmware metadata, not a live query)" : "Detected after connection";
    element("widget").textContent = !details ? "Unknown" : !details.widget.present
      ? "Not installed" : `${details.widget.version ?? "Unknown version"}${incomplete ? " | incomplete / different files" : " | metadata detected"}`;
    element("latest").textContent = manifest?.version ?? "Unavailable";
    const action = details && manifest
      ? actionFor(incomplete ? { present: true, version: null } : details.widget, manifest.version) : null;
    install.textContent = busy ? "Installation in progress..." : action?.label ?? "Install latest AeroGrid";
    install.disabled = !supported || busy || checking || checkingRelease || !!confirmation || !connected || !action?.enabled;
    if (details?.widget.version && manifest && compareVersions(details.widget.version, manifest.version) > 0) {
      install.disabled = true;
    }
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

  async function refreshRelease() {
    checkingRelease = true;
    manifest = null;
    releaseStatus.textContent = "Checking the latest stable release...";
    render();
    try {
      manifest = await loadLatest(base);
      releaseStatus.textContent = `Latest stable release: ${manifest.version}.`;
      if (radioStorage.root) await inspect();
    } catch (error) {
      manifest = null;
      releaseStatus.textContent = `Automatic installation unavailable: ${error.message} Reload the page to check again, or use the manual ZIP instructions below.`;
    } finally {
      checkingRelease = false;
      render();
    }
  }

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
    const warning = `Install AeroGrid ${version} on ${details.radio.name}?\n\n`
      + "The entire WIDGETS/AeroGrid folder, including custom files inside it, will be deleted and replaced. "
      + "There is NO backup or rollback. An interruption may leave AeroGrid unusable until you reinstall.\n\n"
      + (!details.widget.version && details.widget.present ? "The existing version is unknown; version comparison is unavailable.\n\n" : "")
      + "User data in /AEROGRID, maps, other widgets, model/radio settings, and firmware will not be changed. "
      + "Keep USB connected and this page open until completion. Your radio must support EdgeTX's LVGL widget API.";
    confirmation = { version, details: structuredClone(details) };
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
    const { version, details: expected } = confirmation;
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
        const latest = await loadLatest(base);
        if (latest.version !== version) throw new Error("The latest release changed. Retry to confirm the new version.");
        const prepared = await preparePackage(latest, base, report);
        const current = await radioStorage.inspect();
        if (current.radio.board !== expected.radio.board || current.radio.version !== expected.radio.version
            || current.widget.present !== expected.widget.present || current.widget.version !== expected.widget.version) {
          throw new Error("SD-card metadata changed since connection. Reconnect before installing.");
        }
        replacing = true;
        await replaceWidget(root, prepared, report);
        manifest = latest;
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
