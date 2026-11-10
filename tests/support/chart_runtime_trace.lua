-- SPDX-License-Identifier: GPL-2.0-only

local trace = { VERSION = 2, EPOCH = 1000000, BATCHES = 4, PERIOD = 5 }

function trace.value(at, source)
    return ((at * 17 + source * 13) % 97 + 1) / 100
end

function trace.digest(hash, at, source, value, missing)
    at = math.floor(at)
    return (hash * 33 + at * 17 + source * 13 + math.floor(value * 1000) * 7 + (missing and 1 or 0)) % 16777213
end

function trace.emit(at, missing, visit)
    for source = 1, 6 do
        visit(source, trace.value(at, source), missing)
    end
end

function trace.expected(seedEnd, seedStep, target)
    local prefix, events, prefixHash, eventHash = 0, 0, 1, 1
    local at = 0
    while true do
        local missing = at > 0 and (at // seedStep) % 53 == 0
        trace.emit(at, missing, function(source, value, gap)
            prefix = prefix + 1
            prefixHash = trace.digest(prefixHash, at, source, gap and 0 or value, gap)
        end)
        if at == seedEnd then
            break
        end
        at = math.min(seedEnd, at + seedStep)
    end
    for batch = 1, trace.BATCHES do
        at = target + (batch - 1) * trace.PERIOD
        trace.emit(at, false, function(source, value, gap)
            events = events + 1
            eventHash = trace.digest(eventHash, at, source, value, gap)
        end)
    end
    return prefix, prefixHash, events, eventHash
end

return trace
