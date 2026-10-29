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
| **Armed switch position** | none for new panels | Legacy panel switch, shown only when nonblank and widget **Armed switch** is unset. Older layouts retain their previous switch, including the former SF↑ default. |

Select **Armed switch** beside Layout and Theme in native widget settings.
It remains separate for each widget; an unset selection uses that widget's
retained legacy Flight counter arm condition. Dashboards participating in flight
tracking must agree on this condition.

### Model flight settings

In fullscreen, tap the **AeroGrid icon → Model settings**. These settings are
shared by this model's dashboards, including Empty dashboards. **Save** commits
them separately from layout changes; **Cancel** leaves them unchanged.

| Setting | Default | What it does |
| --- | --- | --- |
| **Motor channel** | CH3 | Motor channel used to check whether the motor is running. Select your model's actual throttle channel. The picker is restricted to channels. |
| **Reversed motor channel** | off | Reverse the channel reading before calculating motor percentage. Enable it if the selected channel runs from high at idle to low at full power. |
| **Minimum motor percent** | 25 | Motor percentage must be strictly above this value to qualify. Valid values are 0 up to, but not including, 100. Whole-number values change in steps of 1. |
| **Qualification seconds** | 30 | How long armed, sufficient motor output, and live telemetry must hold continuously before a flight counts. Must be greater than 0 and at most 3600 seconds. Whole-number values change in steps of 1. |
| **Disarm seconds** | 10 | Continuous disarming needed to confirm the end of a counted flight. Must be greater than 0 and at most 3600 seconds. Whole-number values change in steps of 1. |
| **Announce flights** | off | Play a tone and speak the total when a flight qualifies and when its end is confirmed. No external sound files are needed. |
| **Write CSV history** | on | Append confirmed completed flights to `/flights-history.csv` on the SD card. |
| **Flight-active output** | none | Optional dedicated Sticky logical switch, true while a detected flight is active. |

Existing layouts keep their detection settings until you save Model settings.
If older counters disagree, choose the intended configuration explicitly.
Save Model settings before removing the last legacy counter.

## Behavior

A flight qualifies when the effective armed condition, **Minimum motor percent**,
and live telemetry hold continuously for **Qualification seconds**. Any
interruption before qualification resets the attempt. Qualification increments
the total once. Motor percentage maps the channel's normal low-to-high travel
to 0–100%, after applying **Reversed motor channel**.

The widget's **Armed switch** overrides panel arm switches and also drives
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

Select a dedicated **Sticky** logical switch with no configured inputs, AND
condition, delay, or duration. It must not also be the flight's Armed input.
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
