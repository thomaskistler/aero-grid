# AeroGrid

AeroGrid is a configurable 4 x 4 glass-cockpit dashboard for EdgeTX color radios.
Its read-only YAML layouts combine telemetry, model timers, flight modes, trim
positions, and model images in responsive panels.

## Getting started

Copy the complete
[`src/WIDGETS/AeroGrid/` package](https://github.com/thomaskistler/aero-grid/tree/main/src/WIDGETS/AeroGrid)
into your radio's `/WIDGETS/` directory, then select **AeroGrid** in an App mode
screen. The ordinary widget layout is also supported.

Set **Dashboard ID** to select a layout. The `aircraft` dashboard combines flight
timer, receiver battery, link status, altitude, transmitter battery, global
variables, and model image panels. Adjust its source names and battery settings
for your model before use.

See the [installation and configuration guide](https://github.com/thomaskistler/aero-grid#install-on-an-sd-card)
for layout selection, source configuration, upgrades, and stale-bytecode handling.

## Component reference

Each component reference describes its settings, supported presentations, and
behavior when data is unavailable.

| Component | Purpose |
| --- | --- |
| [Metric](components/metric.md) | Configurable numeric readings, thresholds, and visuals. |
| [Flight timer](components/flight-timer.md) | An EdgeTX model timer and supporting flight information. |
| [Flight mode](components/flight-mode.md) | The radio's active flight mode. |
| [TX battery](components/tx-battery.md) | Transmitter voltage and optional charge estimate. |
| [Cell battery](components/cell-battery.md) | Pack or individual-cell battery readings. |
| [Link status](components/link-status.md) | Receiver link quality and signal health. |
| [Trim panel](components/trim-panel.md) | Effective trim positions and three-axis visualization. |
| [Model identity](components/model-identity.md) | Model name, bitmap, or both. |
| [Navigation](components/navigation.md) | GPS position, bearing, and distance. |

## Development and validation

The [repository README](https://github.com/thomaskistler/aero-grid#development)
covers the simulator, build commands, automated tests, and component development.
The [hardware validation record](hardware-validation.md) tracks radio observations
and remaining acceptance work; mock results are not substitutes for hardware tests.
