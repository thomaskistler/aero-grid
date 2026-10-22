# Install and upgrade

<div class="ag-video">
  <iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/JgGA676uW7E" title="Install AeroGrid on an EdgeTX radio" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
  <p><a href="https://www.youtube.com/watch?v=JgGA676uW7E">Watch the installation walkthrough on YouTube</a>.</p>
</div>

Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API.

## Install over USB

Use **desktop Chrome or Edge** to install directly onto a mounted radio SD card,
using the same USB Storage workflow as EdgeTX Buddy's SD-card editor.
Power on the radio, connect its **data USB port**, and choose **USB Storage** on
the radio if prompted. Click **Connect Radio**, then select the **SD-card root**
(the folder containing `RADIO`, `MODELS`, and `WIDGETS`), not the `WIDGETS` folder.

<div class="ag-radio" data-radio-installer>
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
  <p class="ag-radio-muted">Updates delete and replace the entire widget folder. No backup or rollback is created. Layouts, maps, radio/model settings, and firmware are left untouched.</p>
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

Connection grants this page access to the selected folder; it is **not WebSerial,
firmware flashing, or a live firmware query**. The board identifier and EdgeTX
version come from the saved `board` and `semver` fields in `RADIO/radio.yml`.
Missing or invalid fields appear as **Unknown**. Copied or externally edited
settings may not describe the attached hardware or currently running firmware.
`edgetx.sdcard.version` describes the SD contents and is not used as the firmware
version. AeroGrid's version is read from `lib/package.lua`; metadata alone does
not prove that every installed file is intact.

The installer downloads and checks the complete release **before deleting anything**,
then replaces `/WIDGETS/AeroGrid/` and reads back the new files to verify their
contents. This is not an atomic operation: do not unplug, close the page, or let
another application write to the card during installation. If replacement fails,
AeroGrid may be unusable; reconnect and repeat the full installation before using
it. No automatic rollback is available. Custom files inside the widget folder are
removed, including stale compiled Lua files.

**Disconnect Radio** releases this page's connection, but does not eject the drive
or revoke browser permissions. After completion, disconnect in the page,
**safely eject the SD-card drive through your operating system**, then unplug and
restart the radio. Access loss is detected by filesystem checks, not an immediate
USB disconnect event. The browser cannot distinguish a mounted radio card from a
local copy of one.

## Install on an SD card

Download an installation ZIP from [GitHub Releases](https://github.com/thomaskistler/aero-grid/releases)
(beta versions appear as prereleases). Extract it and copy `WIDGETS/AeroGrid/`
into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode
screen.

## Upgrade

1. Remove the old `/WIDGETS/AeroGrid/` folder from the SD card rather than
   merging new files into the old installation. This also removes stale
   compiled Lua files.
2. Copy the complete new `AeroGrid` folder into `/WIDGETS/`.
3. Restart the radio and check your dashboards.

Your layouts and layout list live in `/AEROGRID/`, outside the widget folder.
Leave that folder untouched: there is no need to back up and restore layouts
as part of an upgrade.
