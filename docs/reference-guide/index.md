# Component reference

For installation and layout how-tos, see the [User Guide](../user-guide/installation.md). The pages below describe each panel's settings and behavior. Existing component page URLs are preserved.

AeroGrid loads each component from `src/WIDGETS/AeroGrid/components/<type>.lua`, where `<type>` is the `type` named in the layout YAML. The host creates one LVGL container per placement, so a component receives container-local coordinates and cannot draw over its neighbours.

| Component | Purpose |
| --- | --- |
| [`metric`](../components/metric.md) | One to three independent numeric readings, per-reading units/precision, primary thresholds and bar/radial, with footer or side-stack layout. |
| [`flight-timer`](../components/flight-timer.md) | One EdgeTX model timer, counting the way the model configured it. |
| [`flight-mode`](../components/flight-mode.md) | The active EdgeTX flight mode. |
| [`tx-battery`](../components/tx-battery.md) | Transmitter voltage, with an optional configurable charge estimate. |
| [`trim-panel`](../components/trim-panel.md) | Three-axis square with center-zero bars, a live aileron/elevator dot, and labelled readouts; legacy single/pair/four layouts retained. |
| [`model-identity`](../components/model-identity.md) | Model name, model bitmap, or both. |
| [`cell-battery`](../components/cell-battery.md) | Aircraft cells or pack voltage, with a battery glyph, configurable cell count, and supporting voltage. |
| [`link-status`](../components/link-status.md) | Measured LQ/RSSI, ELRS 4.x mode-aware sensitivity margin, optional SNR/power, independent alarms, and link freshness. |
| [`navigation`](../components/navigation.md) | GPS location, distance from home, a north-up home-to-model compass, and independently configurable bearing/coordinate rows. |
| `service-probe` | Prints one shared service's normalized output as diagnostic rows. |
| `placeholder` | Verifies placement and resizing at any span. |
| `heartbeat` | Verifies the lifecycle callbacks and span restrictions. |

Each component declares the spans it supports and a typed settings schema with labels and defaults, so `layouts/default.yaml` is the only thing that needs editing to rearrange or reconfigure the dashboard. The shipped layout demonstrates the nine display components on one screen; the two diagnostics views have a screen of their own. Global variables use the metric panel's ordinary sources (`gvar1`, `gvar2`, etc.), with explicit display labels, units, precision, and ranges.

Every component degrades rather than raising: a source the radio does not recognize, a timer index that does not exist, a radio without global variables, a firmware without a flight-mode API, a model bitmap that is not on the card, a cells source that answers with the wrong shape, a GPS sensor with no fix, and a link that has dropped each produce a clear state with a text badge, because colour alone is not enough to communicate one.

The three telemetry components exist because these distinctions are easy to get wrong and dangerous to get wrong:

- **A pack is only as good as its worst cell.** With a cells monitor, `cell-battery` leads with the lowest cell and judges per-cell thresholds on it even when the panel shows the pack sum. A numeric pack-voltage source requires a configured cell count and can only provide an average, not detect a weak cell. The battery glyph fills over the configured empty-to-full voltage range; it estimates no remaining capacity.
- **A zero can mean three different things.** `link-status` separates a dead link, a protocol with no RSSI sensor, and a reading that genuinely is zero, reading the distinction from the telemetry service rather than guessing it again. RSSI and link quality are named independently and one is never inferred from the other.
- **A direction needs somewhere to measure from.** `navigation` reports no source, no fix, and no home position as three different states, withholds a bearing rather than resting the dial at north, and says in words that the dial is north-up and measured from home. EdgeTX reports neither aircraft heading nor transmitter orientation, so nothing here may be read as either.

For component implementation details, see the [Developer Guide](../developer-guide/architecture.md).
