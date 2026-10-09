# Installation and upgrades

Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API.

## Install on an SD card

Download an installation ZIP from [GitHub Releases](https://github.com/thomaskistler/aero-grid/releases)
(beta versions appear as prereleases). Extract it and copy `WIDGETS/AeroGrid/`
into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode
screen.

## Upgrade

1. Back up any custom layout files from `/WIDGETS/AeroGrid/layouts/` to your computer.
2. Remove the old `/WIDGETS/AeroGrid/` folder from the SD card rather than merging new files into the old installation. Layout `host` reports the loaded package version.
3. Copy the complete new `AeroGrid` folder into `/WIDGETS/`.
4. Restore your custom layout files without overwriting the new bundled layouts.
5. Restart the radio and check your dashboards.
