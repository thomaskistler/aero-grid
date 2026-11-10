-- SPDX-License-Identifier: GPL-2.0-only

local queue = {}
queue.__index = queue

function queue.new(trace, target)
    local self = setmetatable({ sources = {}, next = {}, events = {}, polled = {} }, queue)
    for batch = 1, trace.BATCHES do
        local at = target + (batch - 1) * trace.PERIOD
        trace.emit(at, false, function(source, value)
            local events = self.sources[source] or {}
            self.sources[source], self.next[source] = events, 1
            local event = { source = source, at = at, value = value }
            events[#events + 1], self.events[#self.events + 1] = event, event
        end)
    end
    return self
end

function queue:take(source, at)
    local events, index = self.sources[source], self.next[source]
    local event = events and events[index]
    if event and event.at <= at then
        self.next[source] = index + 1
        return event
    end
end

return queue
