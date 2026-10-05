# Architecture

## Host and components

AeroGrid has one EdgeTX LVGL host widget. It reads and validates a constrained YAML
layout, creates a responsive 4 x 4 grid, and dynamically loads component modules
with API-version checks.

Modules live in `components/<type>.lua`. Each placement receives its own LVGL
container and container-local coordinates, preventing drawing over neighboring
panels. Components declare supported spans, typed settings, and lifecycle callbacks.
The host owns scheduling, shared services, and theme tokens.

See the
[project specification](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md)
for the complete module contract, schema, and implementation milestones.

## Shared data services

The host polls EdgeTX; components never do. A component subscribes once, in `create`, and keeps the immutable snapshot it is given:

```lua
function example.create(parent, rect, settings, services)
  local telemetry = services.telemetry
  return {feed = telemetry and telemetry:subscribe(settings.source)}
end
```

| Service | Provides |
| --- | --- |
| `telemetry` | Cached source readings with units, precision, and freshness. |
| `model` | Model identity, bitmap path, timers, flight mode, and transmitter voltage. |
| `control` | Effective trim positions and read-only global variables, for the active or a pinned flight mode. |
| `extrema` | EdgeTX sensor extrema and dashboard flight sessions. |
| `navigation` | GPS fix, pilot position, distance, and north-up home-to-model bearing. |

`telemetry:link()` publishes the link itself: whether it is live, the raw `getRSSI()` reading, and whether that indicator can be trusted at all. It is what lets `link-status` tell a dead link from a protocol that populates no RSSI sensor.

Subscribing in `create` is the mechanism, not a convention: a source nothing subscribed to is never read, and a service nothing subscribed to is never scheduled. Two components naming the same source share one poll. Snapshots are read-only views over state the service mutates in place, so they cost no allocation per cycle and cannot be corrupted by the components reading them.

Freshness deserves care. EdgeTX returns integer zero for a telemetry source both when the sensor reads zero and when telemetry is not streaming, so only a zero is ambiguous and only a zero is judged: a non-zero value is always a reading, and a zero is stored only while the link is believed up, otherwise the last live value is kept and marked stale. The link indicator is `getRSSI() > 0`, which reads zero on a live link whose protocol has no RSSI sensor, so the service stops trusting it once a source proves it wrong.

Two limitations remain, and neither is solvable from Lua: staleness is link-wide rather than per sensor, and a sensor that is configured but has never been received reads as a valid zero while the link is up.

Every service degrades rather than raising. A missing firmware API, an unknown source name, a sensor never received, an out-of-range timer, or a GPS source with no fix all produce an `unavailable` snapshot.

### Service diagnostics

Set the widget's **Dashboard ID** to `services` or `services2` to load the bundled diagnostic screens on any model. They print each service's normalized output directly, so a wrong unit, a missing precision, a stale classification, or a bearing taken from the wrong end is visible before any component depends on it.

## Rendering and lifetime

Use shared primitives and theme tokens instead of component-specific palettes.

Four things the Lua API will not tell a component are worth knowing before writing another one:

- **Text cannot be measured.** `theme.fitText` estimates width from the font's line height and picks a size from the widest string a component can ever produce, so a reading never resizes as it changes.
- **A trim source carries no axis.** `trim-panel` takes an orientation, with a per-indicator override, instead of guessing from trim names.
- **`lvgl.image` cannot report a failed decode.** `model-identity` checks the file with `fstat` first and falls back to the model name.
- **`lvgl.arc` is positioned by its centre, not its corner.** `LvglWidgetRoundObject::setPos` stores `x - radius`, so every radial written before milestone 7 was drawn a full radius up and to the left of where it was meant to be. `primitives.arcBounds` converts between the two conventions, and the tests assert containment through it.

See the component module contract in [plans/aerogrid-spec.md](https://github.com/thomaskistler/aero-grid/blob/main/plans/aerogrid-spec.md) for the fields a component declares and the services it receives.

Keep font callbacks persistent. Shared labels install one callback and
`primitives.setFont` changes its backing state. Replacing a callback during refresh
or reflow retains old Lua registry references in EdgeTX 2.12.4. See the
[hardware investigation](../hardware-validation.md) for the evidence and regression
coverage.

## Instruction budget

EdgeTX aborts a widget callback that exceeds 20000 Lua VM instructions with `CPU limit`. AeroGrid therefore loads in stages: `create` only prepares the runtime, and each `refresh` performs one bounded step (a fixed number of lines tokenized, or one component parsed, validated, and built). Zone changes are batched the same way. The dashboard fills in over a few frames instead of blocking a single callback, and a layout that fills the grid costs more callbacks rather than larger ones.

`make test` measures every callback the firmware can invoke, against the largest layout the schema permits, and fails if one exceeds 75% of the budget, printing the worst case:

```text
budget headroom: worst callback trim-panel x16 refresh/reflow used 7800 of 20000
steady state:    worst frame link-status x16 refresh/steady used 2400 of 20000
```

Component callbacks and service updates share this allowance. Per-character string loops are the usual way to exhaust it.

Fourteen sixteen-component layouts are measured: metrics with sixteen distinct live telemetry sources, sixteen diagnostic panels spanning all five services, sixteen components demanding a refresh every frame, and one layout per catalogue component type. Each declares which services it must actually run, and the test fails if one never updated during the sampled frames, so a layout that subscribed to nothing cannot make the service layer measure zero. The test also asserts that every component really was refreshed during the sampled frames, so a scheduling bug cannot make the measurement pass by measuring an idle dashboard.

Services are bounded the same way components are: at most one service is updated per host cycle, services are phase staggered, an unsubscribed service is never scheduled, and each service caps how many subscriptions it refreshes in one update. Removing those caps raises the worst steady frame to 6200.

Because EdgeTX refreshes widgets on every main loop pass, components declare a `refreshInterval` in 10ms ticks rather than being serviced every frame, and components sharing an interval are phase staggered so they fall due on different frames. A per-frame cap bounds the worst case for layouts that defeat staggering.

Resource tests cover reload collectibility, font callback replacement, sustained timer updates, and changing telemetry. They do not measure native LVGL or bitmap memory or reproduce firmware GC cadence. Hardware validation remains necessary.
