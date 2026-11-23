-- SPDX-License-Identifier: GPL-2.0-only

--- The tap rule shared by every touch surface.
---
--- EdgeTX sends no TAP when a press outlasts its tap time, and BREAK reports
--- (0, 0), so a release taps at the point captured by FIRST. A press taps at
--- most once; moving more than SLOP pixels or a long press cancels the tap.
local gesture = { SLOP = 10 }

local function matches(event, name)
    local value = _G[name]
    return value ~= nil and event == value
end

local function point(touch)
    return type(touch) == "table" and type(touch.x) == "number" and type(touch.y) == "number"
end

--- Whether an event belongs to a touch gesture.
function gesture.touch(event)
    return matches(event, "EVT_TOUCH_FIRST")
        or matches(event, "EVT_TOUCH_SLIDE")
        or matches(event, "EVT_TOUCH_LONG")
        or matches(event, "EVT_TOUCH_TAP")
        or matches(event, "EVT_TOUCH_BREAK")
end

--- Advance a press through one event.
---@param press? table The value returned for the previous event.
---@return table? press The value to pass with the next event.
---@return table? tap The point to act on; returned at most once per press.
function gesture.track(press, event, touch)
    if matches(event, "EVT_TOUCH_FIRST") then
        return point(touch) and { x = touch.x, y = touch.y } or {}, nil
    end
    if matches(event, "EVT_TOUCH_SLIDE") then
        if
            press
            and (
                not press.x
                or not point(touch)
                or math.abs(touch.x - press.x) > gesture.SLOP
                or math.abs(touch.y - press.y) > gesture.SLOP
            )
        then
            press.slid = true
        end
        return press, nil
    end
    if matches(event, "EVT_TOUCH_LONG") then
        if press then
            press.slid = true
        end
        return press, nil
    end
    local tap
    if matches(event, "EVT_TOUCH_TAP") then
        tap = point(touch) and touch or press and press.x and press
    elseif matches(event, "EVT_TOUCH_BREAK") then
        tap = press and press.x and press
    else
        return press, nil
    end
    press = press or {}
    if press.done or press.slid then
        tap = nil
    end
    press.done = true
    return press, tap or nil
end

--- End a press without a tap, so a later TAP or BREAK of it is ignored.
function gesture.cancel(press)
    press = press or {}
    press.done = true
    return press
end

return gesture
