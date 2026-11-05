-- SPDX-License-Identifier: GPL-2.0-only

-- Records the scheduling decisions of the widget without touching it: every
-- service registry update and every panel dispatch of a run is folded into a
-- hash, so two runs of one scenario are identical exactly when the host made the
-- same decisions in the same callbacks. The modules are wrapped as they are
-- loaded (the widget and the tests both load them with `loadfile`).
local trace = {}

local MASK, PRIME = 0xFFFFFFFF, 16777619

--- Wrap `loadfile` for the rest of the process; returns the recorder.
---@return table recorder `reset()`, `events`, `hash`
function trace.install()
    local recorder = { events = 0, hash = 2166136261 }

    function recorder.reset()
        recorder.events, recorder.hash = 0, 2166136261
    end

    local function record(...)
        local text = table.concat({ ... }, "|")
        local hash = recorder.hash
        for index = 1, #text do
            hash = ((hash ~ string.byte(text, index)) * PRIME) & MASK
        end
        recorder.events, recorder.hash = recorder.events + 1, hash
    end

    local wrappers = {
        ["lib/services.lua"] = function(module)
            local update = module.update
            module.update = function(runtime, now, ...)
                local id, failure = update(runtime, now, ...)
                record("service", now, tostring(id), tostring(failure))
                return id, failure
            end
        end,
        ["lib/panel_host.lua"] = function(module)
            local dispatch = module.dispatch
            module.dispatch = function(entry, event, ...)
                local ok, failure, consumed, unfinished = dispatch(entry, event, ...)
                record("panel", getTime(), entry.placement.id, event, tostring(ok), tostring(unfinished))
                return ok, failure, consumed, unfinished
            end
        end,
    }

    local original = loadfile
    function loadfile(filename, ...)
        local chunk, message = original(filename, ...)
        local wrap = chunk and type(filename) == "string" and wrappers[string.match(filename, "lib/[%w_]+%.lua$")]
        if not wrap then
            return chunk, message
        end
        return function(...)
            local module = chunk(...)
            if type(module) == "table" then
                wrap(module)
            end
            return module
        end
    end

    return recorder
end

return trace
