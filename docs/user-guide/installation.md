# Installation and upgrades

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
3. Restart the radio and check your dashboards. Select Layout `host` to
   check the loaded package version.

Your layouts and layout list live in `/AEROGRID/`, outside the widget folder.
Leave that folder untouched: there is no need to back up and restore layouts
as part of an upgrade.

If upgrading from an older version that stored custom layouts inside
`/WIDGETS/AeroGrid/layouts/`, move those files to `/AEROGRID/layouts/` before
removing the old widget. See [layout selection](dashboards.md#select-a-layout)
for the old naming and widget-setting changes.
