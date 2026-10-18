-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local panel = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/host-diagnostics.lua"))()
local panelHost = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/panel_host.lua"))()
local settings, errors = panelHost.resolveSettings(panel, { section = "log" })
assert(#errors == 0 and settings.maxEntries == 64)
for _, value in ipairs({ 0, -1, 257, 1.5, math.huge, 0 / 0 }) do
    local _, warnings = panelHost.resolveSettings(panel, { maxEntries = value })
    assert(#warnings > 0, "invalid retention must be reported")
end
for _, value in ipairs({ 1, 64, 256 }) do
    local _, warnings = panelHost.resolveSettings(panel, { section = "log", maxEntries = value })
    assert(#warnings == 0)
end
assert(panel.lines({}, "log")[1] == "no shared diagnostics log")
local log = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/diagnostics_log.lua"))().new()
local host = {
    layoutName = "Flight",
    diagnosticsLog = log,
    panels = { { placement = { type = panel.id }, settings = settings, instance = {} } },
}
log:register(host)
assert(panel.lines(host, "log")[1] == "No messages recorded")
for index = 1, 10 do
    log:append(host, "nav", "event " .. index, index * 100)
end
local rows = {}
for index = 1, 3 do
    rows[index] = {
        set = function(self, properties)
            self.text = properties.text
        end,
    }
end
local context = { host = host, section = "log", visibleLines = 3, rows = rows, texts = {} }
panel.refresh(context)
assert(string.find(rows[1].text, "event 8", 1, true))
assert(string.find(rows[3].text, "event 10", 1, true))
context.visibleLines = 1
panel.refresh(context)
assert(string.find(rows[1].text, "event 10", 1, true), "shrinking keeps the newest message visible")
context.visibleLines = 3
panel.refresh(context)
assert(string.find(rows[1].text, "event 8", 1, true), "enlarging restores older visible messages")
print("Host diagnostics log panel tests passed")
