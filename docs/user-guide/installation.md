# Install and upgrade

Install the latest stable AeroGrid on your radio, or bring your existing installation up to date. Your layouts, maps, and radio settings stay in place.

<div class="ag-install-workspace">
<div class="ag-radio" data-radio-installer>
  <h2 id="install-over-usb">Install over USB</h2>
  <div class="ag-radio-header">
    <div>
      <strong data-connection>Radio disconnected</strong>
      <div class="ag-radio-muted" data-device>No SD card selected</div>
    </div>
    <button type="button" class="ag-radio-button" data-connect disabled>Connect Radio</button>
  </div>
  <div class="ag-radio-cards">
    <div class="ag-radio-card">
      <span>EdgeTX firmware version</span>
      <strong data-edgetx>Unknown</strong>
      <small data-edgetx-source>Detected after connection</small>
    </div>
    <div class="ag-radio-card">
      <span>AeroGrid on SD card</span>
      <strong data-widget>Unknown</strong>
      <small>Target: /WIDGETS/AeroGrid/</small>
    </div>
    <div class="ag-radio-card">
      <span>Latest stable AeroGrid</span>
      <strong data-latest>Unavailable</strong>
      <small>Beta/RC releases excluded</small>
    </div>
  </div>
  <div class="ag-install-action">
  <h3>AeroGrid installation</h3>
  <p class="ag-radio-muted">The latest stable release replaces /WIDGETS/AeroGrid/ completely, including custom files inside it. No backup or rollback is created. Layouts, maps, radio/model settings, and firmware are left untouched.</p>
  <div class="ag-radio-actions">
    <button type="button" class="ag-radio-button ag-radio-primary" data-install disabled>Install latest AeroGrid</button>
  </div>
  <div class="ag-radio-confirm" role="group" aria-labelledby="ag-confirm-title" data-confirm hidden>
    <strong id="ag-confirm-title">Confirm installation</strong>
    <p data-confirm-description></p>
    <div class="ag-radio-actions">
      <button type="button" class="ag-radio-button ag-radio-primary" data-confirm-start>Confirm installation</button>
      <button type="button" class="ag-radio-button" data-confirm-cancel>Cancel</button>
    </div>
  </div>
  <progress data-progress max="1" value="0" aria-label="AeroGrid installation progress" hidden></progress>
  <p role="status" aria-live="polite" aria-atomic="true" data-status>JavaScript and browser folder access are required for automatic installation. Manual installation remains available below.</p>
  <p class="ag-radio-muted" role="status" aria-live="polite" data-release-status></p>
  </div>
</div>
<aside class="ag-install-help" aria-labelledby="ag-connect-title">
  <h2 id="ag-connect-title">Connect your radio</h2>
  <p>Use <strong>desktop Chrome or Edge</strong> and a USB cable that supports data.</p>
  <p>Power on the radio, connect its <strong>data USB port</strong>, and choose <strong>USB Storage</strong> on the radio if prompted.</p>
  <p>Then click <strong>Connect Radio</strong> and select the <strong>SD-card root</strong>: the folder containing <code>RADIO</code>, <code>MODELS</code>, and <code>WIDGETS</code>, not the <code>WIDGETS</code> folder itself.</p>
  <p class="ag-install-note">Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API.</p>
  <a href="#manual-installation">Prefer to copy the files yourself?</a>
</aside>
</div>

<div class="ag-install-safety" role="note">
  <strong>Keep the radio connected until installation finishes.</strong>
  <span>Do not close this page or let another application write to the card. Afterwards, disconnect in the page, safely eject the drive through your operating system, then unplug and restart the radio.</span>
</div>

<details class="ag-install-details">
<summary>How connection and version detection work</summary>
<p>Connection grants this page access to the selected folder, using the same USB Storage workflow as EdgeTX Buddy's SD-card editor. It is <strong>not WebSerial, firmware flashing, or a live firmware query</strong>. The board identifier and EdgeTX version come from the saved <code>board</code> and <code>semver</code> fields in <code>RADIO/radio.yml</code>. Missing or invalid fields appear as <strong>Unknown</strong>. Copied or externally edited settings may not describe the attached hardware or currently running firmware.</p>
<p><code>edgetx.sdcard.version</code> describes the SD contents and is not used as the firmware version. AeroGrid's version is read from <code>lib/package.lua</code>; metadata alone does not prove that every installed file is intact.</p>
<p><strong>Disconnect Radio</strong> releases this page's connection, but does not eject the drive or revoke browser permissions. Access loss is detected by filesystem checks, not an immediate USB disconnect event. The browser cannot distinguish a mounted radio card from a local copy of one.</p>
</details>

<details class="ag-install-details">
<summary>What changes, and what to do if installation is interrupted</summary>
<p>The installer downloads and checks the complete release <strong>before deleting anything</strong>, then replaces <code>/WIDGETS/AeroGrid/</code> and reads back the new files to verify their contents. This is not an atomic operation. Custom files inside the widget folder are removed, including stale compiled Lua files.</p>
<p>If replacement fails, AeroGrid may be unusable; reconnect and repeat the full installation before using it. No automatic rollback is available. Your <code>/AEROGRID/</code> user data, maps, other widgets, radio/model settings, and firmware are left untouched.</p>
</details>

<h2 id="manual-installation">Manual installation</h2>

### Install on an SD card

Download an installation ZIP from [GitHub Releases](https://github.com/thomaskistler/aero-grid/releases)
(beta versions appear as prereleases). Extract it and copy `WIDGETS/AeroGrid/`
into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode
screen.

### Upgrade

1. Remove the old `/WIDGETS/AeroGrid/` folder from the SD card rather than
   merging new files into the old installation. This also removes stale
   compiled Lua files.
2. Copy the complete new `AeroGrid` folder into `/WIDGETS/`.
3. Restart the radio and check your dashboards.

Your layouts and layout list live in `/AEROGRID/`, outside the widget folder.
Leave that folder untouched: there is no need to back up and restore layouts
as part of an upgrade.

<details class="ag-install-details">
<summary>Watch the installation walkthrough</summary>
<div class="ag-video">
  <iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/JgGA676uW7E" title="Install AeroGrid on an EdgeTX radio" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
  <p><a href="https://www.youtube.com/watch?v=JgGA676uW7E">Watch the installation walkthrough on YouTube</a>.</p>
</div>
</details>
