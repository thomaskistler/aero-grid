-- SPDX-License-Identifier: GPL-2.0-only

local menu = { RUNTIME_API = 1 }

-- Same order and colors as tools/generate-menu-icon.py.
local VARIANTS = {
    { name = "blue", 54, 86, 115 },
    { name = "orange", 198, 91, 18 },
    { name = "green", 20, 118, 66 },
    { name = "slate", 33, 40, 48 },
}
-- Squared RGB distance: clearly different from EdgeTX's own icon background.
local MIN_DISTANCE = 120 * 120

-- EdgeTX v2.12 QuickMenu/QuickMenuGroup is C++ only; lvgl.menu is a list.
-- Reproduce its monochrome icon tiles with Lua's supported drawing objects,
-- not themed buttons (whose focus colors cannot be overridden through Lua).
local TILES = {
    { icon = "model", label = "Model\nsettings", action = "modelSettings" },
    { icon = "theme", label = "UI\nsetup", action = "uiSetup" },
}

--- EdgeTX fills its native top-left icon with the theme's FOCUS color.
function menu.variant()
    local focus = lcd and lcd.getColor and COLOR_THEME_FOCUS and lcd.getColor(COLOR_THEME_FOCUS)
    if type(focus) ~= "number" then
        return VARIANTS[1].name
    end
    local value = math.floor(focus / 65536) % 65536
    local red = math.floor(value / 2048) % 32 * 255 / 31
    local green = math.floor(value / 32) % 64 * 255 / 63
    local blue = value % 32 * 255 / 31
    local best, bestDistance
    for _, variant in ipairs(VARIANTS) do
        local distance = (variant[1] - red) ^ 2 + (variant[2] - green) ^ 2 + (variant[3] - blue) ^ 2
        if distance >= MIN_DISTANCE then
            return variant.name
        end
        if not bestDistance or distance > bestDistance then
            best, bestDistance = variant.name, distance
        end
    end
    return best
end

local function matches(event, name)
    return _G[name] ~= nil and event == _G[name]
end

local function enabled(context, state)
    return state.handlers.fullscreen()
        and not (state.handlers.modal and state.handlers.modal())
        and not context.modelSettingsUi
        and not context.runtimeFailed
        and not context.stage
        and not context.reloadState
end

local function valid(context, state, generation)
    return context.aerogridMenu == state
        and state.dashboardRoot == context.root
        and state.generation == generation
        and enabled(context, state)
        and state.modelFilename == state.handlers.modelFilename()
end

function menu.close(context)
    local state = context.aerogridMenu
    if not state then
        return
    end
    state.generation = state.generation + 1
    state.pending, state.action, state.dismiss, state.open = nil, nil, nil, false
    state.tapConsumed = true
    if state.screen then
        lvgl.hide(state.screen)
    end
    lvgl.hide(state.root)
end

local function inside(touch, rectangle)
    return touch
        and touch.x >= rectangle.x
        and touch.y >= rectangle.y
        and touch.x < rectangle.x + rectangle.w
        and touch.y < rectangle.y + rectangle.h
end

local function tileAt(state, touch)
    for index, tile in ipairs(state.tiles) do
        if inside(touch, tile.bounds) then
            return index
        end
    end
end

local function drawSelection(state)
    local black, white = lcd.RGB(0, 0, 0), lcd.RGB(255, 255, 255)
    for index, tile in ipairs(state.tiles) do
        local selected = index == state.selected
        tile.background:set({ color = selected and white or black })
        tile.label:set({ color = selected and black or white })
    end
    state.selectionDirty = nil
end

local function open(context, state)
    if not state.screen then
        local scale = state.h / 45
        local function px(value)
            return math.floor(value * scale + 0.5)
        end
        local padding, gap, tileWidth, tileHeight = px(12), px(12), px(88), px(80)
        local width, height = padding * 2 + tileWidth * 2 + gap, px(32) + tileHeight + padding
        local x, y = math.floor((context.zone.w - width) / 2), state.h + px(4)
        state.bounds = { x = x, y = y, w = width, h = height }
        state.screen = lvgl.box(state.parent, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
            scrollDir = 0,
            visible = function()
                return state.open == true and valid(context, state, state.generation)
            end,
        })
        local popup = lvgl.rectangle(state.screen, {
            x = x,
            y = y,
            w = width,
            h = height,
            filled = true,
            color = lcd.RGB(0, 0, 0),
            opacity = 255,
            scrollDir = 0,
        })
        state.titleRule = lvgl.rectangle(popup, {
            x = 0,
            y = 0,
            w = width,
            h = px(3),
            filled = true,
            color = lcd.RGB(255, 255, 255),
            opacity = 255,
        })
        state.title = lvgl.image(popup, {
            x = math.floor((width - px(122)) / 2),
            y = 0,
            w = px(122),
            h = px(25),
            file = (context.path or "/WIDGETS/AeroGrid/") .. "assets/menu-title-" .. state.h .. ".png",
            fill = false,
        })
        state.tiles = {}
        for index, definition in ipairs(TILES) do
            local left, top = padding + (index - 1) * (tileWidth + gap), px(32)
            local background = lvgl.rectangle(popup, {
                x = left,
                y = top,
                w = tileWidth,
                h = tileHeight,
                filled = true,
                color = lcd.RGB(0, 0, 0),
                opacity = 255,
                scrollDir = 0,
            })
            state.tiles[index] = {
                bounds = { x = x + left, y = y + top, w = tileWidth, h = tileHeight },
                background = background,
                image = lvgl.image(background, {
                    x = math.floor((tileWidth - px(30)) / 2),
                    y = px(6),
                    w = px(30),
                    h = px(30),
                    fill = false,
                    -- Static file updates via :set do not reload StaticImage
                    -- in EdgeTX 2.12; its file callback does.
                    file = function()
                        return (context.path or "/WIDGETS/AeroGrid/")
                            .. "assets/menu-"
                            .. definition.icon
                            .. "-"
                            .. (state.selected == index and "black" or "white")
                            .. "-"
                            .. state.h
                            .. ".png"
                    end,
                }),
                label = lvgl.label(background, {
                    x = 0,
                    y = px(40),
                    w = tileWidth,
                    h = px(38),
                    text = definition.label,
                    font = function()
                        return SMLSIZE
                    end,
                    align = function()
                        return _G.CENTER
                    end,
                    color = lcd.RGB(255, 255, 255),
                }),
            }
        end
        -- EdgeTX reports touches relative to the deepest clickable Window.
        -- A topmost transparent input plane keeps every hit in screen space,
        -- rather than receiving tile-local coordinates from nested rectangles.
        state.input = lvgl.box(state.screen, {
            x = 0,
            y = 0,
            w = context.zone.w,
            h = context.zone.h,
            opacity = 0,
            scrollDir = 0,
        })
    end
    state.open, state.selected = true, 1
    drawSelection(state)
    lvgl.show(state.screen)
end

--- Dimensions are supplied by the host's native button footprint calculation.
function menu.ensure(context, dimensions, handlers)
    local size = dimensions.h
    local name = "aerogrid-" .. menu.variant() .. "-" .. size .. ".png"
    local path = handlers.iconPath or ((context.path or "/WIDGETS/AeroGrid/") .. "assets/" .. name)
    local state = context.aerogridMenu
    local parent = handlers.parent or context.root
    if state and state.parent ~= parent then
        menu.close(context)
        state.root:clear()
        if state.screen then
            state.screen:clear()
        end
        state, context.aerogridMenu = nil, nil
    end
    if not state then
        local root = lvgl.box(parent, {
            x = 0,
            y = 0,
            w = dimensions.w,
            h = dimensions.h,
        })
        state = { root = root, generation = 1, iconPath = path }
        context.aerogridMenu = state
        state.image = lvgl.image(root, {
            x = 0,
            y = 0,
            w = dimensions.h,
            h = dimensions.h,
            file = function()
                return state.iconPath
            end,
            fill = false,
        })
    end
    if
        state.parent ~= parent
        or state.dashboardRoot ~= context.root
        or state.h ~= dimensions.h
        or state.zoneWidth ~= context.zone.w
        or state.zoneHeight ~= context.zone.h
    then
        menu.close(context)
        if state.screen then
            state.screen:clear()
            lvgl.hide(state.screen)
            state.screen = nil
        end
    end
    state.handlers = handlers
    state.parent = parent
    state.dashboardRoot = context.root
    state.zoneWidth, state.zoneHeight = context.zone.w, context.zone.h
    state.iconPath = path
    state.w, state.h = dimensions.w, dimensions.h
    state.root:set({ w = dimensions.w, h = dimensions.h })
    state.image:set({
        x = 0,
        y = 0,
        w = size,
        h = size,
    })
    local filename = handlers.modelFilename()
    if state.modelFilename ~= filename or not handlers.fullscreen() then
        menu.close(context)
        state.modelFilename = filename
    end
    if enabled(context, state) then
        lvgl.show(state.root)
    else
        lvgl.hide(state.root)
    end
    return state
end

function menu.handle(context, event, touch)
    local state = context.aerogridMenu
    if not state or not valid(context, state, state.generation) then
        return false
    end
    if state.open then
        if not event or event == 0 then
            return false
        end
        if state.action or state.dismiss then
            return true
        end
        if matches(event, "EVT_VIRTUAL_EXIT") or matches(event, "EVT_EXIT_BREAK") then
            state.dismiss = true
        elseif matches(event, "EVT_VIRTUAL_ENTER") or matches(event, "EVT_ENTER_BREAK") then
            state.action = TILES[state.selected].action
        elseif
            matches(event, "EVT_VIRTUAL_NEXT")
            or matches(event, "EVT_ROT_RIGHT")
            or matches(event, "EVT_VIRTUAL_PREV")
            or matches(event, "EVT_ROT_LEFT")
        then
            state.selected = 3 - state.selected
            state.selectionDirty = true
        elseif matches(event, "EVT_TOUCH_FIRST") then
            state.captured, state.tapConsumed, state.slid = true, false, false
            state.pressed = tileAt(state, touch)
            if not inside(touch, state.bounds) then
                state.dismiss = true
            elseif state.pressed then
                state.selected, state.selectionDirty = state.pressed, true
            end
        elseif matches(event, "EVT_TOUCH_SLIDE") or matches(event, "EVT_TOUCH_LONG") then
            state.slid = true
        elseif matches(event, "EVT_TOUCH_BREAK") and state.captured and not state.tapConsumed then
            -- EdgeTX can release without a TAP; BREAK coordinates are (0, 0).
            -- Use the captured tile, not those synthetic release coordinates.
            state.tapConsumed = true
            if not state.slid and state.pressed then
                state.action = TILES[state.pressed].action
            end
        elseif matches(event, "EVT_TOUCH_TAP") and not state.tapConsumed then
            state.tapConsumed = true
            local index = tileAt(state, touch)
            if not state.slid and index and (not state.captured or state.pressed == index) then
                state.action = TILES[index].action
            elseif not inside(touch, state.bounds) then
                state.dismiss = true
            end
        end
        return true
    end
    local hit = touch and touch.x >= 0 and touch.y >= 0 and touch.x < state.w and touch.y < state.h
    if matches(event, "EVT_TOUCH_FIRST") then
        state.captured, state.tapConsumed, state.slid = hit == true, false, false
        return state.captured
    end
    local touchEvent = matches(event, "EVT_TOUCH_TAP")
        or matches(event, "EVT_TOUCH_SLIDE")
        or matches(event, "EVT_TOUCH_BREAK")
        or matches(event, "EVT_TOUCH_LONG")
    if state.captured and touchEvent then
        if matches(event, "EVT_TOUCH_SLIDE") or matches(event, "EVT_TOUCH_LONG") then
            state.slid = true
        end
        if matches(event, "EVT_TOUCH_TAP") and not state.tapConsumed then
            state.pending, state.tapConsumed = not state.slid and hit or nil, true
        end
        return true
    end
    if matches(event, "EVT_TOUCH_TAP") and hit then
        if not state.tapConsumed then
            state.pending, state.tapConsumed = true, true
        end
        return true
    end
    return false
end

function menu.advance(context)
    local state = context.aerogridMenu
    if not state then
        return false
    end
    local filename = state.handlers.modelFilename()
    if state.modelFilename ~= filename then
        menu.close(context)
        state.modelFilename = filename
        if enabled(context, state) then
            lvgl.show(state.root)
        end
        return false
    end
    if not valid(context, state, state.generation) then
        menu.close(context)
        return false
    end
    lvgl.show(state.root)
    if state.action then
        local action = state.action
        menu.close(context)
        state.handlers[action]()
        return true
    end
    if state.dismiss then
        menu.close(context)
        lvgl.show(state.root)
        return true
    end
    if state.open then
        if state.selectionDirty then
            drawSelection(state)
            return true
        end
        return false
    end
    if not state.pending or not enabled(context, state) then
        return false
    end
    state.pending = nil
    open(context, state)
    return true
end

return menu
