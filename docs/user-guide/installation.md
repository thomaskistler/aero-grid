# Installation and upgrades

Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API; tested radios and firmware are recorded in [hardware validation](../hardware-validation.md).

## Install on an SD card

Copy `src/WIDGETS/AeroGrid/` into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode screen. The ordinary `1 x 1` layout is also supported.

Copy only the widget package, not the simulator's fixture `/RADIO/` or `/MODELS/`
configuration. Next, [configure a dashboard](dashboards.md) and check its source
bindings. An unavailable reading is not a valid zero.

## Upgrade

1. Back up any custom layout files from `/WIDGETS/AeroGrid/layouts/` to your computer.
2. Remove the old `/WIDGETS/AeroGrid/` folder from the SD card.
3. Copy the complete new `AeroGrid` folder into `/WIDGETS/`.
4. Restore your custom layout files without overwriting the new bundled layouts.
5. Restart the radio and check your dashboards.

Replace the folder rather than merging new files into the old installation.
Dashboard ID `host` reports the loaded package version.
