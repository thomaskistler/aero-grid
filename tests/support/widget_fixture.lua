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
assert(os.execute("cp -R '" .. root .. "/tests/fixtures/panels/.' '" .. fixtureWidgetRoot .. "panels/'"))

local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)

local WidgetFixture = {}

function WidgetFixture.new()
    local definitions = setmetatable({}, { __mode = "k" })
    local self = {
        firmware = firmware,
        lcdMock = lcdMock,
        lvglMock = lvglMock,
        radioMock = radioMock,
        radio = radioMock.state,
        reset = radioMock.reset,
        tick = radioMock.tick,
        edgetx = edgetx,
        hostIo = hostIo,
        path = fixtureWidgetRoot,
    }

    function self.createLoaded(zone, options, path, definition)
        definition = definition or self.module("main.lua")
        local context = helpers.createLoaded(
            definition,
            zone or { x = defaultZone.x, y = defaultZone.y, w = defaultZone.w, h = defaultZone.h },
            options or { Layout = "main", Theme = "modern-dark" },
            path or fixtureWidgetRoot
        )
        definitions[context] = definition
        return context
    end

    function self.pump(context, count, step)
        local definition = definitions[context] or self.module("main.lua")
        helpers.pump(context, count or 60, step, self.tick, definition.refresh)
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
        local module = loadModule(relative)
        if relative == "main.lua" then
            for _, name in ipairs({ "create", "update", "refresh", "background", "event" }) do
                local callback = module[name]
                module[name] = function(...)
                    local first, second = callback(...)
                    lvglMock.settle()
                    return first, second
                end
            end
        end
        return module
    end

    function self.writeFile(path, text)
        local handle = assert(hostIo.open(path, "w"))
        assert(handle:write(text))
        assert(handle:close())
    end

    function self.makeWidget(name, layout, panels)
        assert(type(name) == "string" and string.match(name, "^[%w_.%-]+$") and name ~= "." and name ~= "..")
        local path = root .. "/build/test-widgets/" .. name .. "/"
        assert(os.execute("rm -rf '" .. path .. "' && mkdir -p '" .. path .. "'"))
        assert(os.execute("cp -R '" .. fixtureWidgetRoot .. ".' '" .. path .. "'"))
        if layout then
            self.writeFile(path .. "layouts/Default.yaml", layout)
        end
        for filename, source in pairs(panels or {}) do
            self.writeFile(path .. "panels/" .. filename, source)
        end
        return path
    end

    function self.addTheme(path, name, changes)
        local yaml = self.module("lib/yaml.lua")
        local catalog = assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)
        local copy = assert(yaml.parse(assert(yaml.serialize(catalog.themes[1]))))
        copy.version, copy.name, copy.label = 1, name, name
        copy.correctForContrast = changes.correctForContrast ~= false
        for key, value in pairs(changes.colors or {}) do
            copy.colors[key] = value
        end
        for key, value in pairs(changes) do
            if key ~= "colors" then
                copy[key] = value
            end
        end
        assert(os.execute("mkdir -p '" .. path .. "AEROGRID/themes'"))
        self.writeFile(path .. "AEROGRID/themes/" .. name .. ".yml", assert(yaml.serialize(copy)))
    end

    function self.entryById(context, id)
        return helpers.entryById(context, id)
    end

    function self.panelOf(entry)
        return helpers.panelOf(entry)
    end

    function self.boundsOf(entry)
        return entry.container.properties
    end

    function self.assertFont(actual, expected, message)
        assert(
            actual == expected,
            (message or "wrong font")
                .. ": expected "
                .. edgetx.fontName(expected)
                .. ", got "
                .. edgetx.fontName(actual)
        )
    end

    function self.reflowDone(context)
        return context.width == context.zone.w
            and context.height == context.zone.h
            and context.left == (context.zone.xabs or 0)
            and context.top == (context.zone.yabs or 0)
            and context.fullScreen == lvgl.isFullScreen()
            and not context.reflowIndex
    end

    function self.hostTurn(context)
        local definition = definitions[context] or self.module("main.lua")
        for _ = 1, 20 do
            definition.refresh(context)
            if context.hostTask and context.scheduler.state(context.hostTask).ran == context.scheduler.callbacks then
                if not context.lifecycleRequest then
                    return
                end
            end
            for _, task in pairs(context.lifecycleTasks or {}) do
                if context.scheduler.state(task).ran == context.scheduler.callbacks then
                    return
                end
            end
        end
        error("host work never received a grant")
    end

    function self.requeue(context)
        -- Enrol every task afresh on the next callback, in enrolment order.
        context.scheduler.clear()
        context.taskSync, context.enrolledTasks, context.hostTasks = nil, nil, nil
    end

    function self.isolateWork(context)
        -- Keep a nonempty document without competing flight or service work.
        context.flightFactory = nil
        context.document.panels, context.emptyHint = { {} }, nil
        context.serviceRuntime = context.servicesModule.runtime({})
    end

    function self.instanceOf(context, id)
        local entry = self.entryById(context, id)
        return entry and entry.instance or nil
    end

    function self.assertContained(context, label)
        for _, entry in ipairs(context.panels) do
            local bounds = entry.container.properties
            local where = (label or "dashboard") .. ": " .. entry.placement.id
            assert(bounds.x >= 0 and bounds.y >= 0, where .. " left the zone origin")
            assert(bounds.x + bounds.w <= context.zone.w, where .. " exceeds the zone width")
            assert(bounds.y + bounds.h <= context.zone.h, where .. " exceeds the zone height")
            assert(bounds.w > 0 and bounds.h > 0, where .. " collapsed")
            local panel = entry.module.id == "theme-showcase" and entry.instance.root.properties or self.panelOf(entry)
            assert(panel.x == 0 and panel.y == 0, where .. " left its container")
            assert(panel.w <= bounds.w and panel.h <= bounds.h, where .. " overflowed its container")
            assert(not entry.failed, where .. ": " .. tostring(entry.error))
        end
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
