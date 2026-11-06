-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/diagnostics_log.lua"))()
local log = module.new()
local first = { layoutName = "Flight", panels = {} }
local second = { layoutName = "Diagnostics", panels = {} }
log:register(first)
log:register(second)
assert(log:limit() == 0)
log:append(first, "nav", "ignored", 100)
assert(log.count == 0)

local function panel(limit)
    return {
        placement = { type = "host-diagnostics" },
        settings = { section = "log", maxEntries = limit },
        instance = {},
    }
end
second.panels[1] = panel(64)
assert(log:limit() == 64, "another screen enables logging")
for index = 1, 300 do
    log:append(first, "nav", "event " .. index, index * 100)
end
local entries = log:read()
assert(#entries == 64 and entries[1].text == "event 237" and entries[64].text == "event 300")
assert(entries[1].host == "Flight#1" and entries[1].panel == "nav")
assert(module.format(entries[64]) == "00:05:00 [Flight#1/nav] event 300")
local tail = log:read(2)
assert(#tail == 2 and tail[1].text == "event 299")
first.panels[1] = panel(256)
assert(log:limit() == 256)
for index = 301, 600 do
    log:append(first, "nav", "event " .. index, index)
end
assert(#log:read() == 256 and log:read()[1].text == "event 345")
first.panels = {}
assert(#log:read() == 64, "removing the larger consumer shrinks history")
second.panels[1].settings.maxEntries = 1
assert(#log:read() == 1)
log:append(first, "other", "newest", 360100)
assert(log.count == 1 and module.format(log:read()[1]) == "01:00:01 [Flight#1/other] newest")

second.panels[1].failed = true
log:append(first, "nav", "failed panel must not enable logging", 0)
assert(log.count == 1)
second.panels[1].failed = nil
second.panels[1].instance.preview = true
assert(log:limit() == 0, "editor previews must not enable logging")
second.panels[1].instance.preview = nil
second.panels[1].settings.section = "identity"
assert(log:limit() == 0)
second.panels = {}
log:append(first, "nav", "ignored after removal", 0)
assert(log.count == 1, "disabling logging retains existing messages without adding more")
do
    local temporary = { layoutName = "Transient", panels = { panel(64) } }
    log:register(temporary)
    assert(log:limit() == 64)
end
collectgarbage("collect")
assert(log:limit() == 0, "the shared registry must not keep removed widget hosts alive")
assert(module.new().count == 0, "restarting the widget script starts an empty log")
do
    local bounded = module.new()
    local owners = {}
    for index = 1, 16 do
        local owner = { layoutName = "Host" .. index, panels = {} }
        for position = 1, 16 do
            owner.panels[position] = panel(256)
        end
        bounded:register(owner)
        owners[index] = owner
    end
    for index = 1, 300 do
        bounded:append(owners[1], "nav", "event " .. index, index)
    end
    for _, owner in ipairs(owners) do
        for _, entry in ipairs(owner.panels) do
            entry.settings.maxEntries = 1
        end
    end
    local work, snapshot = {}, nil
    for _ = 1, 1000 do
        local count = bounded.count
        snapshot = bounded:readVisibleStep(work, 12)
        assert(bounded.count >= count - 1, "one turn may evict at most one entry")
        if snapshot then
            break
        end
    end
    assert(snapshot and #snapshot == 1 and snapshot[1].text == "event 300")
    assert(bounded.count == 1 and #bounded:read() == 1)
    bounded:append(owners[1], "nav", "newest", 400)
    assert(snapshot[1].text == "event 300", "captured entries remain immutable after eviction")
    for _, limit in ipairs({ 0, 1, 12 }) do
        local current = {}
        for _ = 1, 1000 do
            local result = bounded:readVisibleStep(current, limit)
            if result then
                assert(#result == math.min(limit, bounded.count))
                break
            end
        end
    end
    assert(not pcall(bounded.readVisibleStep, bounded, {}, 13))
    for _, owner in ipairs(owners) do
        owner.panels = {}
    end
    local current = {}
    for _ = 1, 1000 do
        local result = bounded:readVisibleStep(current, 12)
        if result then
            assert(#result == 1, "disabled logging retains history just like synchronous read")
            break
        end
    end
end
print("Shared diagnostics log tests passed")
