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
print("Shared diagnostics log tests passed")
