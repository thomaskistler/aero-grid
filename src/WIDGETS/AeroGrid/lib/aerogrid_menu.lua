-- SPDX-License-Identifier: GPL-2.0-only

local menu = { RUNTIME_API = 1 }

-- Same order and colors as tools/generate-menu-icon.py.
local VARIANTS = {
    { name = "orange", 185, 76, 20 },
    { name = "violet", 97, 70, 198 },
    { name = "green", 19, 117, 111 },
    { name = "slate", 61, 77, 101 },
}
-- Squared RGB distance: clearly different from EdgeTX's own icon background.
local MIN_DISTANCE = 120 * 120

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
end

local function valid(context, state, generation)
    return context.aerogridMenu == state
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
    state.pending, state.action = nil, nil
    if state.nativeMenu then
        lvgl.close(state.nativeMenu)
        state.nativeMenu = nil
    end
    lvgl.hide(state.root)
end

--- Dimensions are supplied by the host's native button footprint calculation.
function menu.ensure(context, dimensions, handlers)
    local size = dimensions.h
    local name = "aerogrid-" .. menu.variant() .. "-" .. size .. ".png"
    local path = handlers.iconPath or ((context.path or "/WIDGETS/AeroGrid/") .. "assets/" .. name)
    local state = context.aerogridMenu
    if not state then
        local root = lvgl.box(handlers.parent or context.root, {
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
    state.handlers = handlers
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
    if not state or not enabled(context, state) then
        return false
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
        if matches(event, "EVT_TOUCH_SLIDE") then
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
    if not valid(context, state, state.generation) then
        menu.close(context)
        return false
    end
    if state.action then
        local action = state.action
        state.action = nil
        state.handlers[action]()
        return true
    end
    if not state.pending or not enabled(context, state) then
        return false
    end
    state.pending = nil
    local generation = state.generation
    local selected = false
    state.nativeMenu = lvgl.menu({
        title = "AeroGrid",
        values = { "Model settings", "UI setup" },
        get = function()
            return 1
        end,
        set = function(index)
            if not selected and valid(context, state, generation) and not state.action then
                selected = true
                state.nativeMenu = nil
                state.action = index == 1 and "modelSettings" or index == 2 and "uiSetup" or nil
            end
        end,
    })
    return true
end

return menu
