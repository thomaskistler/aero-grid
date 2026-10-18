# Install and upgrade

<div class="ag-video">
  <iframe width="560" height="315" src="https://www.youtube-nocookie.com/embed/JgGA676uW7E" title="Install AeroGrid on an EdgeTX radio" loading="lazy" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
  <p><a href="https://www.youtube.com/watch?v=JgGA676uW7E">Watch the installation walkthrough on YouTube</a>.</p>
</div>

Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API.

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
