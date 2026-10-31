# Install over USB

Install the latest stable AeroGrid on your radio, or choose a previous release. Your layouts, maps, and radio settings stay in place.

<div class="ag-install-workspace">
<div class="ag-radio" data-radio-installer>
  <div class="ag-radio-header">
    <div>
      <strong><svg class="ag-connection-icon" viewBox="0 0 24 24" aria-hidden="true"><g class="ag-connection-off"><path d="M9 17H7A5 5 0 0 1 7 7"/><path d="M15 7h2a5 5 0 0 1 4 8"/><line x1="8" x2="12" y1="12" y2="12"/><line x1="2" x2="22" y1="2" y2="22"/></g><g class="ag-connection-on"><path d="M9 17H7A5 5 0 0 1 7 7h2"/><path d="M15 7h2a5 5 0 1 1 0 10h-2"/><line x1="8" x2="16" y1="12" y2="12"/></g></svg><span data-connection>Radio disconnected</span></strong>
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
    </div>
    <button type="button" class="ag-radio-card ag-release-card" data-release-open aria-haspopup="dialog" aria-controls="ag-release-dialog" disabled>
      <span data-release-label>Selected AeroGrid release</span>
      <strong data-latest>Unavailable</strong>
      <small>Choose a different release</small>
    </button>
  </div>
  <dialog id="ag-release-dialog" class="ag-release-dialog" data-release-dialog aria-labelledby="ag-release-title" aria-describedby="ag-release-description">
    <div class="ag-release-dialog-header">
      <h2 id="ag-release-title">Choose a release</h2>
      <button type="button" class="ag-radio-button" data-release-close aria-label="Close release selection">Close</button>
    </div>
  <fieldset class="ag-release-picker" data-release-picker disabled>
    <legend class="visually-hidden">Available AeroGrid releases</legend>
    <p id="ag-release-description" class="ag-radio-muted">Latest stable is selected by default. Developer builds may not be fully tested and may be unstable. Use at your own risk. Beta and RC releases are not included.</p>
    <label><input type="checkbox" data-developer-releases> Show developer releases</label>
    <div class="ag-release-list" data-releases></div>
  </fieldset>
  </dialog>
  <div class="ag-install-action">
  <p class="ag-radio-compatibility" data-compatibility role="status" aria-live="polite">Connect your radio to check compatibility.</p>
  <p class="ag-radio-downgrade" data-developer-warning role="status" aria-live="polite" hidden></p>
  <p class="ag-radio-downgrade" data-downgrade hidden></p>
  <div class="ag-radio-actions">
    <button type="button" class="ag-radio-button" data-install aria-haspopup="dialog" aria-controls="ag-install-confirm-dialog" disabled>Install latest AeroGrid</button>
  </div>
  <dialog id="ag-install-confirm-dialog" class="ag-release-dialog" data-confirm-dialog aria-labelledby="ag-confirm-title">
    <h2 id="ag-confirm-title" data-confirm-title>Confirm installation</h2>
    <div class="ag-radio-confirm" role="group" aria-labelledby="ag-confirm-title" data-confirm hidden>
      <p id="ag-confirm-description" data-confirm-description></p>
      <div class="ag-radio-actions">
        <button type="button" class="ag-radio-button ag-radio-primary" data-confirm-start>Confirm installation</button>
        <button type="button" class="ag-radio-button" data-confirm-cancel>Cancel</button>
      </div>
    </div>
    <progress data-progress max="1" value="0" aria-label="AeroGrid installation progress" hidden></progress>
    <p id="ag-install-operation-status" role="status" aria-live="polite" aria-atomic="true" data-operation-status></p>
    <button type="button" class="ag-radio-button" data-confirm-close hidden>Close</button>
  </dialog>
  <p role="status" aria-live="polite" aria-atomic="true" data-status></p>
  <p class="ag-radio-muted" role="status" aria-live="polite" data-release-status></p>
  </div>
</div>
</div>

<div class="ag-install-safety" role="note">
  <strong>Keep the radio connected until installation finishes.</strong>
  <span>Do not close this page or let another application write to the card. Afterwards, disconnect in the page, safely eject the drive through your operating system, then unplug the USB data cable.</span>
</div>

<h2 id="manual-installation" class="ag-install-section-title">Manual installation</h2>

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

Your layouts, themes, model settings, and layout list live in `/AEROGRID/`,
outside the widget folder. Leave that folder untouched: there is no need to back up and restore layouts
as part of an upgrade.

<details class="ag-install-details">
<summary>Watch the installation walkthrough</summary>
<div class="ag-video">
  <iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/JgGA676uW7E" title="Install AeroGrid on an EdgeTX radio" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
  <p><a href="https://www.youtube.com/watch?v=JgGA676uW7E">Watch the installation walkthrough on YouTube</a>.</p>
</div>
</details>
