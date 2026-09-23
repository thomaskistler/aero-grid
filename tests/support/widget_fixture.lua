-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
local firmware = edgetx.firmware
local hostIo = io

edgetx.constants()
local lcdMock = edgetx.lcd()
local lvglMock = edgetx.lvgl()
local radioMock = edgetx.radio(io)
local widgetRoot = root .. "/src/WIDGETS/AeroGrid/"
local defaultZone = { x = 0, y = 0, w = 480, h = 272 }

io = {
    open = hostIo.open,
    read = function(handle, size)
        return handle:read(size)
    end,
    close = function(handle)
        return handle:close()
    end,
}

local function loadModule(relative)
    local chunk, err = loadfile(widgetRoot .. relative)
    assert(chunk, err)
    return chunk()
end

local WidgetFixture = {}

function WidgetFixture.new()
    local self = {
        firmware = firmware,
        lcdMock = lcdMock,
        lvglMock = lvglMock,
        radioMock = radioMock,
        radio = radioMock.state,
        reset = radioMock.reset,
        tick = radioMock.tick,
    }

    function self.createLoaded(zone, options, path)
        local definition = loadModule("main.lua")
        local context = definition.create(
            zone or { x = defaultZone.x, y = defaultZone.y, w = defaultZone.w, h = defaultZone.h },
            options or { DashID = "main", Theme = "modern" },
            path or widgetRoot
        )
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

    function self.instanceOf(context, id)
        local entry = self.entryById(context, id)
        return entry and entry.instance or nil
    end

    return self
end

return WidgetFixture
