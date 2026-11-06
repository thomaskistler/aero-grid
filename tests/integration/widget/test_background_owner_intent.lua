-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
fixture.reset()
fixture.lvglMock.setFullScreen(false)
local context = fixture.createLoaded(nil, { Layout = "review-flight-counter", Theme = "modern-dark" })
local definition = fixture.module("main.lua")
fixture.pump(context, 100, 10)
assert(not context.stage and not context.reloadState and not context.flightRegistrationJob)
local entry = assert(context.panels[1])
assert(entry.module.id == "flight-counter")
local scheduling = context.schedulerHost
scheduling.owners = setmetatable({}, { __index = scheduling.owners })
local original, calls = entry.module.background, 0
entry.module.background = function(...)
    calls = calls + 1
    return original(...)
end
for _, ready in ipairs({ false, true }) do
    scheduling.ready = function()
        assert(not entry.instance.schedulerOwned, "test must run before the ownership marker is published")
        return ready
    end
    scheduling.owners["panel:flight-counter"] = "new"
    entry.instance.schedulerOwned = nil
    fixture.tick(20)
    definition.background(context)
    assert(calls == 0, "owner intent must suppress hidden Counter painting before reconciliation")
end
scheduling.ready = function()
    return true
end
scheduling.owners["panel:flight-counter"] = "legacy"
fixture.tick(20)
definition.background(context)
assert(calls == 1, "legacy-owned Counter background behavior must remain available")
scheduling.owners["panel:flight-counter"] = "new"
scheduling.mode = "legacy"
fixture.tick(20)
definition.background(context)
assert(calls == 2, "legacy observation mode must preserve the original background callback")
print("Background ownership intent prevents pre-enrollment Counter painting and preserves legacy compatibility")
