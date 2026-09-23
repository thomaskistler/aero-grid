-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local firmware = edgetx.firmware

edgetx.constants()
local lvglMock = edgetx.lvgl()
local radioMock = edgetx.radio(io)
local widgetRoot = root .. "/src/WIDGETS/AeroGrid/"

local function loadModule(relative)
    local chunk, err = loadfile(widgetRoot .. relative)
    assert(chunk, err)
    return chunk()
end

local WidgetFixture = {}

function WidgetFixture.new()
    local self = {
        firmware = firmware,
        lvglMock = lvglMock,
        radioMock = radioMock,
        radio = radioMock.state,
        reset = radioMock.reset,
        tick = radioMock.tick,
    }

    function self.createLoaded(zone, options, path)
        local definition = loadModule("main.lua")
        local context = definition.create(zone, options or { DashID = "main", Theme = "modern" }, path)
        local guard = 0
        while context.stage do
            definition.refresh(context)
            guard = guard + 1
            assert(guard < 200, "staged load never finished")
        end
        return context
    end

    function self.pump(context, count, step)
        for _ = 1, count do
            self.tick(step or 20)
            loadModule("main.lua").refresh(context)
        end
    end

    function self.entryById(context, id)
        for _, entry in ipairs(context.components or {}) do
            if entry.placement and entry.placement.id == id then
                return entry
            end
        end
        return nil
    end

    function self.panelOf(entry)
        if not entry then
            return nil
        end
        return entry.instance and entry.instance.panel and entry.instance.panel.root and entry.instance.panel.root.properties
    end

    return self
end

return WidgetFixture
