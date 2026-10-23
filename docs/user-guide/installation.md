# Install and upgrade

Install the latest stable AeroGrid on your radio, or choose a previous release. Your layouts, maps, and radio settings stay in place.

<div class="ag-install-workspace">
<div class="ag-radio" data-radio-installer>
  <h2 id="install-over-usb">Install over USB</h2>
  <p class="ag-radio-muted">USB installation is supported only in <strong>desktop Google Chrome or Microsoft Edge</strong>. <strong>Safari and Opera are not supported.</strong></p>
  <div class="ag-radio-header">
    <div>
      <strong><svg class="ag-connection-icon" viewBox="0 0 24 24" aria-hidden="true"><g class="ag-connection-off"><path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/></g><g class="ag-connection-on"><path d="M6.3 20.3a2.4 2.4 0 0 0 3.4 0L12 18l-6-6-2.3 2.3a2.4 2.4 0 0 0 0 3.4Z"/><path d="m2 22 3-3"/><path d="M7.5 13.5 10 11"/><path d="M10.5 16.5 13 14"/><path d="m18 3-4 4h6l-4 4"/></g></svg><span data-connection>Radio disconnected</span></strong>
    </div>
    <button type="button" class="ag-radio-button ag-radio-primary" data-connect disabled><svg class="ag-usb-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V3m-3 3 3-3 3 3M12 15l-5-5V7m5 10 5-5V9"/><circle cx="7" cy="5" r="2"/><circle cx="12" cy="21" r="2"/><rect x="15" y="5" width="4" height="4"/></svg><span data-connect-label>Connect Radio</span></button>
  </div>
  <div class="ag-radio-cards">
    <div class="ag-radio-card">
      <span>Radio</span>
      <dl class="ag-radio-specs">
        <div><dt>Type</dt><dd data-radio-type>Unknown</dd></div>
        <div><dt>Screen</dt><dd data-radio-screen>Unknown</dd></div>
        <div><dt>EdgeTX</dt><dd data-edgetx>Unknown</dd></div>
      </dl>
    </div>
    <div class="ag-radio-card">
      <span>AeroGrid on SD card</span>
      <strong data-widget>Unknown</strong>
      <small>Detected after connection</small>
    </div>
    <button type="button" class="ag-radio-card ag-release-card" data-release-open aria-haspopup="dialog" aria-controls="ag-release-dialog" disabled>
      <span data-release-label>Selected AeroGrid release</span>
      <strong data-latest>Unavailable</strong>
      <small>Choose a different release <span aria-hidden="true">&#9662;</span></small>
    </button>
  </div>
  <dialog id="ag-release-dialog" class="ag-release-dialog" data-release-dialog aria-labelledby="ag-release-title" aria-describedby="ag-release-description">
    <div class="ag-release-dialog-header">
      <h2 id="ag-release-title">Choose a release</h2>
      <button type="button" class="ag-radio-button" data-release-close aria-label="Close release selection">Close</button>
    </div>
  <fieldset class="ag-release-picker" data-release-picker disabled>
    <legend class="visually-hidden">Available AeroGrid releases</legend>
    <p id="ag-release-description" class="ag-radio-muted">Latest stable is selected by default. Beta and RC releases are not included.</p>
    <div class="ag-release-list" data-releases></div>
  </fieldset>
  </dialog>
  <div class="ag-install-action">
  <p class="ag-radio-compatibility" data-compatibility role="status" aria-live="polite">Connect your radio to check compatibility.</p>
  <p class="ag-radio-downgrade" data-downgrade hidden></p>
  <div class="ag-radio-actions">
    <button type="button" class="ag-radio-button" data-install disabled>Install latest AeroGrid</button>
  </div>
  <div class="ag-radio-confirm" role="group" aria-labelledby="ag-confirm-title" data-confirm hidden>
    <strong id="ag-confirm-title" data-confirm-title>Confirm installation</strong>
    <p data-confirm-description></p>
    <div class="ag-radio-actions">
      <button type="button" class="ag-radio-button ag-radio-primary" data-confirm-start>Confirm installation</button>
      <button type="button" class="ag-radio-button" data-confirm-cancel>Cancel</button>
    </div>
  </div>
  <progress data-progress max="1" value="0" aria-label="AeroGrid installation progress" hidden></progress>
  <p role="status" aria-live="polite" aria-atomic="true" data-status></p>
  <p class="ag-radio-muted" role="status" aria-live="polite" data-release-status></p>
  </div>
</div>
<aside class="ag-install-help" aria-labelledby="ag-connect-title">
  <h2 id="ag-connect-title">Connect your radio</h2>
  <p>Power on the radio, connect its <strong>data USB port</strong> using a USB cable that supports data, and choose <strong>USB Storage</strong> on the radio if prompted.</p>
  <p>Then click <strong>Connect Radio</strong> and select the <strong>SD-card drive</strong>: the folder containing <code>RADIO</code>, <code>MODELS</code>, and <code>WIDGETS</code>, not the <code>WIDGETS</code> folder itself.</p>
  <p class="ag-install-note">Back up your SD card and model configuration before making changes. AeroGrid requires a color-screen radio running EdgeTX 2.11.0 or later.</p>
  <a href="#manual-installation">Prefer to copy the files yourself?</a>
</aside>
</div>

<div class="ag-install-safety" role="note">
  <strong>Keep the radio connected until installation finishes.</strong>
  <span>Do not close this page or let another application write to the card. Afterwards, disconnect in the page, safely eject the drive through your operating system, then unplug and restart the radio.</span>
</div>

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
