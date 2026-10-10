# Run and test in simulators

Both simulators run EdgeTX firmware, but use different builds and interfaces.
Use VS Code for a tight edit/run loop and Companion for native firmware UI,
radio controls, and screenshot tooling. Record which one you used when
reporting a result.

| Simulator | What you need | Best use |
| --- | --- | --- |
| VS Code EdgeTX Dev Kit | VS Code and the Dev Kit extension; first launch downloads WASM firmware. | Editor-integrated runs, watch mode, controls, synthetic telemetry, and logs. |
| EdgeTX Simulator supplied with Companion | EdgeTX Companion 2.12 with the TX16S simulator. | Native UI/control checks, telemetry simulation, and debugging without VS Code. |

Neither proves receiver behavior, native radio memory stability, or support
for every color radio.

## Prepare a disposable SD image

```sh
make build
```

Use the **absolute path to `build/sdcard/`**, not `src/`, `WIDGETS/`, or
`tests/fixtures/sdcard/`, as the simulator SD-card root. It contains `RADIO/`,
`MODELS/`, `IMAGES/`, `AEROGRID/`, and `WIDGETS/`.
Run `pwd` at the repository root to find the checkout's absolute path.

**Do not run both simulators against the same image at the same time.**
They can write files on the simulated SD card. Stop the simulator before rebuilding,
back up experiments elsewhere, and remember that `make build` resets them.
Use `make build BUILD_DIR=build/companion` and point Companion at
`build/companion/sdcard/` if you want separate state.

## VS Code: EdgeTX Dev Kit

Install [EdgeTX Dev Kit](https://marketplace.visualstudio.com/items?itemName=jeffreychix.edgetx-dev-kit)
(`jeffreychix.edgetx-dev-kit`) from VS Code's Extensions view.
The steps here use the extension's 2.x simulator commands; Companion is not
required.

1. Open the repository **folder** in VS Code. Open
    `src/WIDGETS/AeroGrid/main.lua`.
2. In the Command Palette, run **EdgeTX: Toggle EdgeTX Mode** if it is not
    already active. Confirm the profile is **tx16s**, **2.12**, **color**,
    **480 x 272**, as recorded in `.vscode/edgetx.json`. If the profile is
    missing or stale, run **EdgeTX: Set Radio Profile**.
3. In workspace settings, set **EdgeTX: SD Card Path** (`edgetx.sdCardPath`)
    to the absolute generated image path.
4. Run **Tasks: Run Task > AeroGrid: Build Simulator SD**, or `make build`
    in a terminal. The other supplied task, **AeroGrid: Test**, runs
    `make test`.
5. Run **EdgeTX: Open Simulator** to boot the fixture and inspect its
    configured models/screens. Allow the initial firmware download to finish.
    Use **Show Controls** for switches, sticks, trims, and radio buttons.

To launch the active entry point directly, use **EdgeTX: Simulate Script**.
`main.lua` includes the App-mode simulation annotation
`---@simulate Layout1x1AM zone=0`. For the fixture's existing model/screen
configuration, prefer **Open Simulator** rather than relying on script
auto-placement.

## Companion: native EdgeTX Simulator

Install [EdgeTX Companion 2.12](https://github.com/EdgeTX/edgetx/releases)
for your OS, including the TX16S simulator. There are two launch paths:
Companion's embedded simulator, available on macOS too, and the standalone
EdgeTX Simulator distributed on Windows/Linux.

### Launch from Companion

1. Open Companion and create/select a radio profile for **RadioMaster TX16S**.
   In **Edit Settings...**, set that profile's **SD Structure path** to the
   absolute generated `build/sdcard/` directory.
2. Choose **File > Read Models and Settings from SD Path**. This opens the
   fixture's radio settings and models in a Companion document without a
   connected radio. Confirm that the AeroGrid fixture models are present.
3. Use the document's **Simulate Radio** action (`Alt+Shift+S`) to boot the
   complete radio. Use **Simulate Model** (`Alt+S`) if you intentionally want
   only the selected model.

The embedded simulator uses the profile's SD path for widget/layout/image
files, but a **temporary copy** of the document's radio/model data.
Do not expect model changes made during this simulation to be written back
to the fixture or Companion document. AeroGrid's user layouts are separate
SD-card files; treat that SD path as writable.

After rebuilding the image, close the simulation and read models/settings
from SD Path again before simulating, so an older open document cannot
reintroduce stale model configuration.

### Launch the standalone simulator

On Windows/Linux, open the EdgeTX Simulator installed with Companion
(`simulator.exe` on Windows; packaged executable naming can vary on Linux).
Create the TX16S radio profile in Companion first, then configure the
standalone simulator's **Startup Options**:

| Option | Value |
| --- | --- |
| Radio Profile | Your TX16S profile. |
| Radio Type | RadioMaster TX16S. |
| Simulator | The available TX16S simulator matching that profile. |
| Data Source | **SD Path**. |
| SD Image Path | The absolute path to the generated `build/sdcard/`. |

Click **OK**. **SD Path** makes the simulator load radio/model data from the
same image that contains the widget. Do not select a default/new `.etx` data
file: that boots a different model configuration.
If using **Folder** instead, set **Data Folder** and **SD Image Path** to
that same SD-card root, not its `MODELS/` subdirectory.

The image contains `RADIO/radio.yml` and `MODELS/model*.yml`; the standalone
simulator loads these directly and persists radio/model changes.
You do not need to import them individually or read a connected radio.
If no simulator is listed, check the installed Companion package and profile
before modifying the fixture.

## Use the fixture models

A clean build selects **AEROGRID STD**, with Default on its first screen.
Change models with the simulated
radio's model-selection UI, just as on a radio.

| Model | What to exercise |
| --- | --- |
| **AEROGRID STD** (`model1.yml`) | Six screens: Default, Empty, Host, services, services2, and Theme. All four shipped layouts, plus both diagnostic panel types. |
| **AEROGRID PANEL1** (`model2.yml`) | Six screens: cell battery, flight counter, flight mode, flight timer, link status, and metric. |
| **AEROGRID PANEL2** (`model3.yml`) | Five screens: model identity, navigation, text, trim panel, and TX battery. |

Review layouts live in `src/WIDGETS/AeroGrid/layouts/review-*.yaml`.
The two panel models contain exactly one dashboard per user-facing panel type.
All screens use App mode and the Modern Dark theme. On the text dashboard, SF
changes MODE, SA changes RATE, and SB changes FLAP; NO MIDDLE deliberately
leaves SA's middle position unmapped.

The last screen of **AEROGRID STD** is a telemetry-free theme showcase. Its
fixed samples show token swatches, text levels, accents, a dial, bars, and
the six dashboard panel states. Change the widget's Theme option to compare Modern Dark
and Modern Light, or copy the layout and add
[custom YAML overrides](../user-guide/dashboards.md#create-your-own-theme).

**Host** reports loading, package identity, and service errors; `services`
and `services2` exercise the service-probe panel across all five services.
Auxiliary layouts (`sim`, `sim2`, `states`, and `review-cell-sources`) remain
available through the widget's **Layout** option in UI Setup rather than
occupying dedicated fixture screens. Development layouts are not included
in the release ZIP.

The flight-counter review installs only one tracker. Arm with SF down, raise
CH3 above 25%, and supply a live telemetry link; qualification and disarm
timeouts are shortened to three seconds for review. History and announcements
are disabled. Resize the single panel in the editor to inspect other spans
without installing multiple trackers.
