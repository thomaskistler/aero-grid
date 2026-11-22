# Run and test in simulators

Use VS Code for an integrated edit/run loop and Companion for native firmware
UI and controls. Record the simulator and version when reporting results.

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

**Do not run both simulators against the same image at the same time.**
They can write files on the simulated SD card. Stop the simulator before rebuilding,
back up experiments elsewhere, and remember that `make build` resets them.
Use `make build BUILD_DIR=build/companion` and point Companion at
`build/companion/sdcard/` if you want separate state.

## VS Code: EdgeTX Dev Kit

Install [EdgeTX Dev Kit](https://marketplace.visualstudio.com/items?itemName=jeffreychix.edgetx-dev-kit)
(`jeffreychix.edgetx-dev-kit`) from VS Code's Extensions view.
Use the extension's 2.x simulator commands; Companion is not required.

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

A clean build selects **AG Overview**, with Default on its first screen.
Change models with the simulated
radio's model-selection UI, just as on a radio.

| Model | What to exercise |
| --- | --- |
| **AG Overview** (`model1.yml`) | Default; sim; sim2. |
| **AG Flight** (`model2.yml`) | review-model-identity; review-flight-mode; review-flight-timer; review-flight-counter; review-chart. |
| **AG Power-Link** (`model3.yml`) | review-rx-battery; review-cell-sources; review-tx-battery; review-link-status; review-metric. |
| **AG Navigation** (`model4.yml`) | review-navigation. |
| **AG Controls** (`model5.yml`) | review-output; review-trim-panel. |
| **AG System** (`model6.yml`) | Diagnostics; services; services2; review-state; states; Palette; Empty. |
| **AG Debrief** (`model7.yml`) | Overview-based debrief testing with 1x1 Link, 2x1 Navigation, and all debrief sensors already registered. Arm with SF down; receiver required is off and the start window is 10 seconds. |

Review and simulator-only layouts live in
`tests/fixtures/layouts/development/`; `make build` adds them to the disposable
simulator image without including them in the widget source or release ZIP.
All screens use App mode and Modern Dark. Models share switches, mixes, trims,
and timer setup, but EdgeTX keeps live timer/trim state per model.

Useful scenarios:

| Layout/model | Inputs and purpose |
| --- | --- |
| `sim` / `sim2` | Telemetry / radio-local values and metric modes. |
| State (`review-state`) | SF changes MODE, SA changes RATE, SB changes FLAP. NO MIDDLE intentionally leaves SA's middle position unmapped. |
| Palette | Telemetry-free theme samples; change Theme or [add a custom theme](../user-guide/customize-themes.md). |
| Diagnostics / `services` / `services2` | Host errors and service-probe views. |
| AG Flight | SF down arms; CH3 above 25% with live telemetry exercises detection. Start/end windows are ten seconds; Smart detection is enabled. |

AG Flight reserves Sticky **L01** for flight status. Its one-shot `agstart` and
`agend` tracks play three tones at flight start and four at end, not at model
startup. The flight-counter screen reads the shared model count.

To change the baseline, follow
[Maintain simulator fixtures](contributing.md#maintain-simulator-fixtures).
