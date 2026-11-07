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
local fixtureWidgetRoot = root .. "/build/test-widget-fixture/"
local defaultZone = { x = 0, y = 0, w = 480, h = 272 }
local helpers = assert(loadfile(root .. "/tests/support/widget_helpers.lua"))()

io = {
    open = hostIo.open,
    read = function(handle, size)
        return handle:read(size)
    end,
    write = function(handle, content)
        return handle:write(content)
    end,
    close = function(handle)
        return handle:close()
    end,
}

os.execute("rm -rf '" .. fixtureWidgetRoot .. "' && mkdir -p '" .. fixtureWidgetRoot .. "'")
os.execute("cp -R '" .. widgetRoot .. ".' '" .. fixtureWidgetRoot .. "'")
os.execute("cp -R '" .. root .. "/tests/fixtures/layouts/development/.' '" .. fixtureWidgetRoot .. "layouts/'")

local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

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
        return helpers.createLoaded(
            definition,
            zone or { x = defaultZone.x, y = defaultZone.y, w = defaultZone.w, h = defaultZone.h },
            options or { Layout = "main", Theme = "modern-dark" },
            path or fixtureWidgetRoot
        )
    end

    function self.pump(context, count, step)
        helpers.pump(context, count, step, self.tick, function(value)
            loadModule("main.lua").refresh(value)
        end)
    end

    function self.pumpUntil(context, predicate, limit, step)
        for _ = 1, limit or 100 do
            if predicate(context) then
                return true
            end
            self.pump(context, 1, step)
        end
        return predicate(context)
    end

    function self.module(relative)
        return loadModule(relative)
    end

    function self.entryById(context, id)
        return helpers.entryById(context, id)
    end

    function self.panelOf(entry)
        return helpers.panelOf(entry)
    end

    function self.instanceOf(context, id)
        local entry = self.entryById(context, id)
        return entry and entry.instance or nil
    end

    function self.assertNoOverlap(context)
        local entries = context.panels or {}
        for firstIndex = 1, #entries do
            local first = entries[firstIndex].container.properties
            for secondIndex = firstIndex + 1, #entries do
                local second = entries[secondIndex].container.properties
                local overlaps = first.x < second.x + second.w
                    and second.x < first.x + first.w
                    and first.y < second.y + second.h
                    and second.y < first.y + first.h
                assert(not overlaps, "builder placed overlapping panels")
            end
        end
    end

    return self
end

return WidgetFixture
