-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid"
local menu = assert(loadfile(base .. "/lib/aerogrid_menu.lua"))()
local support = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
support.constants()
support.lcd()
local mock = support.lvgl()
EVT_TOUCH_FIRST, EVT_TOUCH_BREAK, EVT_TOUCH_TAP, EVT_TOUCH_SLIDE, EVT_TOUCH_LONG = 9101, 9102, 9103, 9104, 9105
EVT_VIRTUAL_EXIT, EVT_VIRTUAL_ENTER, EVT_VIRTUAL_NEXT, EVT_VIRTUAL_PREV = 9106, 9107, 9108, 9109
EVT_ROT_LEFT, EVT_ROT_RIGHT, EVT_EXIT_BREAK = 9110, 9111, 9112

local function fixture(width, height, size)
    local control = { fullscreen = true, modal = false, filename = "plane.yml", model = 0, layout = 0 }
    local c = {
        root = lvgl.box({ x = 0, y = 0, w = width or 480, h = height or 272 }),
        zone = { w = width or 480, h = height or 272 },
        path = base .. "/",
    }
    local handlers = {
        fullscreen = function()
            return control.fullscreen
        end,
        modal = function()
            return control.modal
        end,
        modelFilename = function()
            return control.filename
        end,
        modelSettings = function()
            assert(not c.aerogridMenu.open and c.aerogridMenu.screen.hidden, "close before invoking the next UI")
            control.model = control.model + 1
        end,
        uiSetup = function()
            control.layout = control.layout + 1
        end,
    }
    local dimensions = { w = size or 45, h = size or 45 }
    local state = menu.ensure(c, dimensions, handlers)
    return c, state, control, handlers, dimensions
end

local function touch(c, x, y)
    assert(menu.handle(c, EVT_TOUCH_FIRST, { x = x, y = y }))
    assert(menu.handle(c, EVT_TOUCH_BREAK, { x = x, y = y }))
    assert(menu.handle(c, EVT_TOUCH_TAP, { x = x, y = y }))
end

local function open(c)
    touch(c, 1, 1)
    assert(not c.aerogridMenu.open, "touch must defer constructing LVGL objects")
    assert(menu.advance(c))
    assert(c.aerogridMenu.open and not c.aerogridMenu.screen.hidden)
    assert(mock.menu() == nil, "the native list popup must not be used")
end

local function selectTile(c, index)
    local bounds = c.aerogridMenu.tiles[index].bounds
    touch(c, bounds.x + 2, bounds.y + 2)
end

do
    for index = 1, 2 do
        local c, state, control = fixture()
        open(c)
        local bounds = state.tiles[index].bounds
        local point = { x = bounds.x + bounds.w / 2, y = bounds.y + 20 }
        assert(menu.handle(c, EVT_TOUCH_FIRST, point))
        assert(menu.handle(c, EVT_TOUCH_BREAK, { x = 0, y = 0 }))
        assert(control.model == 0 and control.layout == 0, "release action must remain deferred")
        assert(menu.advance(c), "a release without a TAP must activate the captured tile")
        assert(control.model == (index == 1 and 1 or 0))
        assert(control.layout == (index == 2 and 1 or 0))
        menu.handle(c, EVT_TOUCH_TAP, point)
        menu.advance(c)
        assert(control.model + control.layout == 1, "a later bubbled TAP must not invoke the action twice")
    end
    local c, state, control = fixture()
    open(c)
    menu.handle(c, EVT_TOUCH_BREAK, { x = 0, y = 0 })
    assert(not menu.advance(c) and state.open, "the opening release cannot activate a tile")
    local bounds = state.tiles[1].bounds
    menu.handle(c, EVT_TOUCH_FIRST, { x = bounds.x + 20, y = bounds.y + 20 })
    menu.handle(c, EVT_TOUCH_SLIDE, { x = bounds.x + 40, y = bounds.y + 20 })
    menu.handle(c, EVT_TOUCH_BREAK, { x = 0, y = 0 })
    menu.advance(c)
    assert(control.model == 0 and state.open, "drag releases must not activate a tile")
end

do
    for _, display in ipairs({ { 320, 240, 36 }, { 480, 272, 45 }, { 800, 480, 62 } }) do
        local c, state, control, handlers, dimensions = fixture(table.unpack(display))
        local image = state.image.properties
        assert(image.x == 0 and image.y == 0 and image.w == display[3] and image.h == display[3])
        assert(string.find(image.file(), "aerogrid-blue-" .. display[3] .. ".png", 1, true))
        assert(state.button == nil, "no rectangular button may cover the pilot-wings silhouette")
        open(c)
        local b = state.bounds
        assert(state.titleRule.properties.y == 0 and state.titleRule.properties.h > 0)
        assert(state.titleRule.properties.w == b.w)
        assert(state.title.properties.y == 0 and state.title.properties.fill == false)
        assert(string.find(state.title.properties.file, "menu-title-" .. display[3] .. ".png", 1, true))
        assert(math.abs(state.title.properties.x * 2 + state.title.properties.w - b.w) <= 1)
        assert(b.x >= 0 and b.y >= state.h and b.x + b.w <= c.zone.w and b.y + b.h <= c.zone.h)
        assert(math.abs(b.x * 2 + b.w - c.zone.w) <= 1, "popup is centered below the header")
        assert(#state.tiles == 2 and state.tiles[1].label.properties.text == "Model\nsettings")
        assert(state.input.properties.w == c.zone.w and state.input.properties.h == c.zone.h)
        assert(
            state.input.properties.opacity == 0,
            "a transparent topmost input plane keeps native touches in screen space"
        )
        assert(state.tiles[2].label.properties.text == "UI\nsetup")
        assert(state.tiles[1].background.properties.color == lcd.RGB(255, 255, 255))
        assert(state.tiles[1].label.properties.color == lcd.RGB(0, 0, 0))
        assert(string.find(state.tiles[1].image.properties.file(), "-black-", 1, true))
        assert(state.tiles[2].background.properties.color == lcd.RGB(0, 0, 0))
        assert(string.find(state.tiles[2].image.properties.file(), "-white-", 1, true))
        control.fullscreen = false
        menu.ensure(c, dimensions, handlers)
        assert(state.root.hidden and state.screen.hidden and not state.open)
        assert(not menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 }), "App mode owns its native menu")
        assert(not menu.handle(c, EVT_VIRTUAL_ENTER))
    end
end

do
    local getColor = lcd.getColor
    assert(menu.variant() == "blue")
    lcd.getColor = function()
        return lcd.RGB(54, 86, 115)
    end
    assert(menu.variant() == "orange", "keep AeroGrid's existing alternate palette")
    lcd.getColor = function()
        return lcd.RGB(120, 120, 120)
    end
    assert(menu.variant() == "orange")
    lcd.getColor = function()
        return nil
    end
    assert(menu.variant() == "blue")
    lcd.getColor = getColor
end

do
    local c, state, control = fixture()
    open(c)
    menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
    assert(not menu.advance(c) and state.open, "opening tap cannot also dismiss the new popup")
    assert(menu.handle(c, 123456), "the popup owns keys, not underlying dashboard controls")
    assert(not menu.handle(c, 0), "idle refresh must keep services and panels running")
    selectTile(c, 1)
    assert(control.model == 0, "tile actions must defer opening the next UI")
    assert(menu.advance(c) and control.model == 1)
    menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
    menu.advance(c)
    assert(control.model == 1 and not state.open, "bubbled tap cannot act twice or reopen")
    open(c)
    selectTile(c, 2)
    menu.advance(c)
    assert(control.layout == 1)
    open(c)
    local screen = state.screen
    menu.handle(c, EVT_VIRTUAL_NEXT)
    assert(state.selected == 2)
    menu.advance(c)
    assert(state.tiles[2].background.properties.color == lcd.RGB(255, 255, 255))
    assert(state.tiles[1].label.properties.color == lcd.RGB(255, 255, 255))
    menu.handle(c, EVT_ROT_LEFT)
    menu.handle(c, EVT_ROT_RIGHT)
    menu.handle(c, EVT_VIRTUAL_ENTER)
    assert(control.layout == 1)
    menu.advance(c)
    assert(control.layout == 2)
    open(c)
    assert(state.screen == screen, "repeated opens reuse the bounded LVGL object tree")
    menu.handle(c, EVT_VIRTUAL_PREV)
    assert(state.selected == 2)
    menu.handle(c, EVT_VIRTUAL_EXIT)
    assert(state.open)
    menu.advance(c)
    assert(not state.open and not state.root.hidden and control.model == 1 and control.layout == 2)
    open(c)
    menu.handle(c, EVT_EXIT_BREAK)
    menu.advance(c)
    assert(not state.open)
end

do
    local c, state, control = fixture()
    assert(not menu.handle(c, EVT_TOUCH_FIRST, { x = state.w, y = 1 }), "right edge is exclusive")
    assert(not menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = state.h }), "bottom edge is exclusive")
    for _, event in ipairs({ EVT_TOUCH_LONG, EVT_TOUCH_SLIDE }) do
        menu.handle(c, EVT_TOUCH_FIRST, { x = 1, y = 1 })
        menu.handle(c, event, { x = 1, y = 1 })
        menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
        assert(not menu.advance(c) and not state.open, "hold/drag must not open the popup or editor")
    end
    open(c)
    local tile = state.tiles[1].bounds
    menu.handle(c, EVT_TOUCH_FIRST, { x = tile.x + 1, y = tile.y + 1 })
    menu.handle(c, EVT_TOUCH_SLIDE, { x = tile.x + 3, y = tile.y + 1 })
    menu.handle(c, EVT_TOUCH_TAP, { x = tile.x + 3, y = tile.y + 1 })
    menu.advance(c)
    assert(control.model == 0 and state.open, "dragging cannot activate a tile")
    menu.handle(c, EVT_TOUCH_FIRST, { x = 1, y = 1 })
    menu.advance(c)
    assert(not state.open and not state.root.hidden)
    menu.handle(c, EVT_TOUCH_BREAK, { x = 1, y = 1 })
    menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
    menu.advance(c)
    assert(not state.open, "outside-dismiss gesture must not reopen the header icon")
end

do
    for _, change in ipairs({
        "filename",
        "fullscreen",
        "modal",
        "modelSettingsUi",
        "runtimeFailed",
        "stage",
        "reloadState",
        "replacement",
        "parent",
        "dashboardRoot",
        "resize",
    }) do
        local c, state, control, handlers, dimensions = fixture()
        open(c)
        selectTile(c, 1)
        if change == "filename" then
            control.filename = "other.yml"
        elseif change == "fullscreen" then
            control.fullscreen = false
        elseif change == "modal" then
            control.modal = true
        elseif change == "modelSettingsUi" then
            c.modelSettingsUi = {}
        elseif change == "runtimeFailed" or change == "stage" or change == "reloadState" then
            c[change] = true
        elseif change == "replacement" then
            c.aerogridMenu = nil
        elseif change == "parent" then
            handlers.parent = lvgl.box({ x = 0, y = 0, w = 480, h = 272 })
            menu.ensure(c, dimensions, handlers)
        elseif change == "dashboardRoot" then
            handlers.parent = c.root
            c.root = lvgl.box({ x = 0, y = 0, w = 480, h = 272 })
            menu.ensure(c, dimensions, handlers)
        elseif change == "resize" then
            c.zone.w = 800
            menu.ensure(c, { w = 62, h = 62 }, handlers)
        end
        menu.advance(c)
        assert(control.model == 0, change .. " must invalidate deferred actions")
        if change ~= "replacement" then
            assert(not state.open and (state.screen == nil or state.screen.hidden))
        end
        if change == "filename" then
            open(c)
            selectTile(c, 1)
            menu.advance(c)
            assert(control.model == 1, "model changes must not permanently disable the header")
        end
    end
end
