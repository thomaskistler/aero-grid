# Flight counter

| 1x2 | 2x1 | 2x2 |
| --- | --- | --- |
| ![Flight counter at 1x2](../assets/panels/flight-counter/1x2.png) | ![Flight counter at 2x1](../assets/panels/flight-counter/2x1.png) | ![Flight counter at 2x2](../assets/panels/flight-counter/2x2.png) |

Displays the model's GV9 flight total and highlights a detected active flight.
Flight tracking is shared by AeroGrid dashboards and does not require a visible
Flight counter.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| **Label** | FLT | Panel heading. Clear it to restore the default. |
| **Arm switch position** | none for new panels | Legacy panel switch, shown only when nonblank and no model arming has been saved. Older layouts retain their previous switch, including the former SF↑ default. |

Select **Arm switch** in **AeroGrid → Model settings**. Changes apply immediately
to every dashboard for the model. Until model arming is set,
retained legacy Flight counter arm conditions remain in use and must agree for
shared flight tracking. Conflicts require an explicit model selection, not an
automatic choice. Saving **None** disables arming, including legacy fallbacks.

### Model flight settings

In fullscreen, tap the **AeroGrid icon → Model settings**. These settings are
shared by this model's dashboards, including Empty dashboards. Each confirmed
change saves automatically, separately from layout changes. Back closes the page.

| Setting | Default | What it does |
| --- | --- | --- |
| **Arm switch** | none | Model-wide physical switch position or logical switch (L01–L64, including inverted logical switches). This is a switch condition, not a numeric channel. |
| **Motor channel** | CH3 | Motor channel used to check whether the motor is running. Select your model's actual throttle channel. The picker is restricted to channels. |
| **Reversed motor channel** | off | Reverse the channel reading before calculating motor percentage. Enable it if the selected channel runs from high at idle to low at full power. |
| **Motor threshold (%)** | 25 | Motor percentage must be strictly above this value to qualify. Valid values are 0 up to, but not including, 100. |
| **Start detection window (s)** | 30 | Observation window during which armed state, sufficient motor output, and live telemetry must hold continuously to confirm flight start. |
| **End detection window (s)** | 10 | Observation window of continuous disarming required to confirm flight end. Rearming within this window keeps the flight open. |
| **Smart detection** | off | Allow supported altitude or GPS groundspeed sensors to qualify a flight earlier. Standard motor qualification remains available. |
| **Write CSV history** | on | Append confirmed completed flights to `/flights-history.csv` on the SD card. |
| **Flight status switch** | none | Native logical-switch picker for an optional dedicated Sticky logical switch, on while a detected flight is active. Inverted switches are not supported. |

**Model arming** applies to charts, navigation, and flight detection.
**Flight detection** detects when a flight begins and ends using live telemetry data; it does not arm the model.
Both detection windows accept values greater than 0 and at most 3600 seconds.
They confirm the boundaries; the flight's start and end times remain the
beginning of each observation window, not the later confirmation time.

Use the **Flight status switch** with EdgeTX Special Functions to configure your
own sounds or announcements.

Existing layouts keep their detection settings until you change Model settings.
If older counters disagree, choose the intended configuration explicitly.
Configure Model settings before removing the last legacy counter.

## Behavior

A flight qualifies when the effective armed condition, **Minimum motor percent**,
and live telemetry hold continuously for the **Start detection window**. Any
interruption before qualification resets the attempt. Qualification increments
the total once. Motor percentage maps the channel's normal low-to-high travel
to 0–100%, after applying **Reversed motor channel**.

With **Smart detection** on, a flight can also qualify when trustworthy
barometric altitude is **more than 3 metres above its arming reference for
2 continuous seconds**, **or** valid GPS groundspeed is **more than 10 mph for
2 continuous seconds**. Both shortcuts still require armed state, motor above
the configured threshold, and live telemetry. The fixed speed rule is a
provisional heuristic, not a guaranteed taxi/flight discriminator.

Smart discovers supported CRSF/ELRS and FrSky S.Port sensors automatically.
Open **Model settings** to see sensor readiness or why standard detection is
being used. Missing, ambiguous, stale, or unsupported sensors never block
standard qualification. Altitude needs a trustworthy recent reading seen while
disarmed or freshly received at the observed arm transition; starting AeroGrid
already armed or receiving altitude late does not establish that reference.
Healthy half-second and one-second updates are supported. `Current` means Smart
is bridging a normal interval between updates; stopped or unverifiable streams
fall back to standard detection. Low flights and short hops are not guaranteed
to qualify early.

The model's **Arm switch** overrides panel arm switches and also drives
Chart, first-arm Navigation, and flight-session minima in this widget.
Custom State-panel conditions remain independent.
An unavailable arm reading cannot confirm disarming.

After qualification, telemetry or motor changes do not end the flight.
Continuous disarming starts the **Disarm seconds** timeout. Re-arming before
it expires cancels the pending end without counting again. A callback gap of
more than one second restarts qualification or a pending end timeout rather
than assuming the condition held while unobserved. Tracking continues through
hidden dashboards, layout/theme rebuilds, and panel previews while AeroGrid
callbacks are running. Adding counters does not create another detector.

Reserve GV9 in flight mode 0, with precision 0 and limits allowing 0–999.
The existing total is kept, including one previously written by EdgeTX
Flights. Invalid or unsavable counts produce an error rather than wrapping.
Do not also run EdgeTX Flights or another GV9 flight counter. Configure other
flight modes to inherit GV9 from flight mode 0.

**Write CSV history** records only confirmed completions. It uses the same
five columns as EdgeTX Flights: flight date, model name, flight count,
duration, and model identifier. Model names are CSV-quoted when needed.
Duration runs from the start of qualification to the final disarming; the
disarm grace period is excluded. History does not restore or calculate GV9.
SD-card failures are reported without discarding the already saved count.

If dashboard arm conditions conflict or settings change during a flight, the
current flight finishes using its original condition and output. New flights
wait until the configuration is consistent.

### Optional logical-switch output

First configure a dedicated **Sticky** logical switch in EdgeTX, with no inputs,
AND condition, delay, or duration. Then select it in **Flight status switch**.
The native picker lists only configured logical switches; an empty list means
none have been configured. It must not also be the flight's Arm input.
AeroGrid changes only its state, not its model configuration. Use the switch
in your own Special Functions or sounds.

The output turns true at qualification and false after confirmed completion,
including the disarm grace period. A full command buffer is reported and retried.
Do not share this output with another script. It is not a safety interlock:
stopped Lua execution, model changes, or transmitter restarts cannot guarantee
output cleanup.

GV9 persists through model saving and transmitter restarts, but in-flight
detection state does not. Changing model or restarting during a flight can
lose its history and qualify it again.

## States

| Condition | Presentation |
| --- | --- |
| Resting or qualifying | Count and normal styling, without a badge. |
| Qualified flight or pending disarm timeout | Count, mist blue surface, blue accent, and `IN-FLIGHT` badge. If the blue surface would be illegible, the surface keeps its normal color. |
| Confirmed completion | Count retained and normal styling restored. |
| GV9 unavailable | `--` and an `N/A` badge. |
| Configuration or persistence failure | Actionable service error; resolve it before relying on tracking. |
