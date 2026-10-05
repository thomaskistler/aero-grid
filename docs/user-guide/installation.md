# Installation and upgrades

Back up your SD card and model configuration before making changes. AeroGrid targets EdgeTX color radios with the LVGL widget API; tested radios and firmware are recorded in [hardware validation](../hardware-validation.md).

## Install on an SD card

Copy `src/WIDGETS/AeroGrid/` into the radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode screen. The ordinary `1 x 1` layout is also supported.

Upgrade the entire package, not individual Lua files, and remove old `.luac`
files as described below. `lib/package.lua` defines the package version and the
runtime, component, and layout API versions. The host rejects incompatible or
unversioned runtime modules; a failed service leaves unrelated panels running.
The `host` diagnostics dashboard reports the version loaded by the host.
These checks detect API-incompatible mixtures, not every mixture of compatible
releases or stale bytecode.

## Stale bytecode

EdgeTX compiles each script to a `.luac` beside it on the SD card and then prefers the bytecode. `rsync` preserves source timestamps, so a freshly copied `.lua` can look older than bytecode the radio compiled from the previous build, and the radio keeps running code that is no longer on disk. The symptom is a fix that visibly does nothing, including error messages citing line numbers that no longer exist in the source.

`make build` therefore deletes every `.luac` from the image and stamps the sources as new. If you copy an image somewhere by hand, do the same.

Remove old `.luac` files inside `/WIDGETS/AeroGrid/` after replacing the package, then restart the radio. Preserve custom layouts separately and restore them after upgrading. Copy only the widget package, not the simulator's fixture `/RADIO/` or `/MODELS/` configuration.

Next, [configure a dashboard](dashboards.md) and check its source bindings. An unavailable reading is not a valid zero.
