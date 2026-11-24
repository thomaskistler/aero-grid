-- SPDX-License-Identifier: GPL-2.0-only

local menu = {}

-- EdgeTX v2.12 QuickMenu/QuickMenuGroup is C++ only; lvgl.menu is a list.
-- Reproduce its monochrome icon tiles with Lua's supported drawing objects,
-- not themed buttons (whose focus colors cannot be overridden through Lua).
local TILES = {
    { icon = "model", label = "Model\nsettings", action = "modelSettings" },
    { icon = "theme", label = "UI\nsetup", action = "uiSetup" },
    { icon = "stats", label = "Flight\ndebrief", action = "debrief" },
}

--- EdgeTX fills its native top-left icon with the theme's FOCUS color.
local function backgroundColor()
    local focus = lcd and lcd.getColor and COLOR_THEME_FOCUS and lcd.getColor(COLOR_THEME_FOCUS)
    return type(focus) == "number" and focus or lcd.RGB(54, 86, 115)
end

local function createBackground(root, size, color)
    local shoulder, middle, edge = math.floor(size * 0.8), math.floor(size / 2), size - 1
    return {
        lvgl.rectangle(root, {
            x = 0,
            y = 0,
            w = shoulder,
            h = size,
            filled = true,
            color = color,
        }),
        lvgl.triangle(root, {
            pts = { { shoulder, 0 }, { edge, middle }, { shoulder, middle } },
            color = color,
        }),
        lvgl.triangle(root, {
            pts = { { shoulder, middle }, { edge, middle }, { shoulder, edge } },
            color = color,
        }),
    }
end

local function matches(event, name)
    return _G[name] ~= nil and event == _G[name]
end

--- The button shows in fullscreen unless an overlay covers the dashboard.
--- The layout editor keeps it in place.
local function shown(context, state)
    return not context.stage
        and not context.reloadState
        and state.handlers.fullscreen()
        and not (state.handlers.modal and state.handlers.modal())
        and not context.modelSettingsUi
        and not context.runtimeFailed
end

--- While editing the button stays visible but passes touches to the editor.
local function enabled(context, state)
    return shown(context, state) and not (state.handlers.editing and state.handlers.editing())
end

local function setVisible(state, visible)
    if visible then
        lvgl.show(state.root)
    else
        lvgl.hide(state.root)
    end
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
    state.press = context.gesture.cancel(state.press)
    if state.screen then
        lvgl.hide(state.screen)
    end
    setVisible(state, false)
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
        local width, height = padding * 2 + tileWidth * #TILES + gap * (#TILES - 1), px(32) + tileHeight + padding
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
    local name = "aerogrid-mark-" .. size .. ".png"
    local path = handlers.iconPath or ((context.path or "/WIDGETS/AeroGrid/") .. "assets/" .. name)
    local color = backgroundColor()
    local state = context.aerogridMenu
    local created = false
    local parent = handlers.parent or context.root
    if state and (state.parent ~= parent or state.backgroundSize ~= size or state.iconPath ~= path) then
        menu.close(context)
        state.root:clear()
        if state.screen then
            state.screen:clear()
        end
        state, context.aerogridMenu = nil, nil
    end
    if not state then
        created = true
        local root = lvgl.box(parent, {
            x = 0,
            y = 0,
            w = dimensions.w,
            h = dimensions.h,
        })
        state = {
            root = root,
            generation = 1,
            iconPath = path,
            backgroundColor = color,
            backgroundSize = size,
            background = createBackground(root, size, color),
        }
        context.aerogridMenu = state
        state.image = lvgl.image(root, {
            x = 0,
            y = 0,
            w = dimensions.h,
            h = dimensions.h,
            file = path,
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
    if state.backgroundColor ~= color then
        for _, shape in ipairs(state.background) do
            shape:set({ color = color })
        end
        state.backgroundColor = color
    end
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
    setVisible(state, shown(context, state))
    return state, created
end

--- Show or hide the button for the current screen.
function menu.sync(context)
    local state = context.aerogridMenu
    if state then
        setVisible(state, shown(context, state))
    end
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
        elseif matches(event, "EVT_VIRTUAL_NEXT") or matches(event, "EVT_ROT_RIGHT") then
            state.selected = state.selected % #TILES + 1
            state.selectionDirty = true
        elseif matches(event, "EVT_VIRTUAL_PREV") or matches(event, "EVT_ROT_LEFT") then
            state.selected = (state.selected - 2) % #TILES + 1
            state.selectionDirty = true
        elseif matches(event, "EVT_TOUCH_FIRST") then
            state.press = context.gesture.track(nil, event, touch)
            local pressed = tileAt(state, touch)
            if not inside(touch, state.bounds) then
                state.dismiss = true
            elseif pressed then
                state.selected, state.selectionDirty = pressed, true
            end
        elseif context.gesture.touch(event) then
            local tap
            state.press, tap = context.gesture.track(state.press, event, touch)
            local index = tap and tileAt(state, tap)
            if index and (not state.press.x or tileAt(state, state.press) == index) then
                state.action = TILES[index].action
            elseif tap and not inside(tap, state.bounds) then
                state.dismiss = true
            end
        end
        return true
    end
    local function hit(point)
        return point and point.x >= 0 and point.y >= 0 and point.x < state.w and point.y < state.h
    end
    if matches(event, "EVT_TOUCH_FIRST") then
        state.press = hit(touch) and context.gesture.track(nil, event, touch) or nil
        return state.press ~= nil
    end
    if context.gesture.touch(event) and (state.press or matches(event, "EVT_TOUCH_TAP") and hit(touch)) then
        local tap
        state.press, tap = context.gesture.track(state.press, event, touch)
        if tap then
            state.pending = hit(tap) or nil
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
        setVisible(state, shown(context, state))
        return false
    end
    if not valid(context, state, state.generation) then
        menu.close(context)
        setVisible(state, shown(context, state))
        return false
    end
    setVisible(state, true)
    if state.action then
        local action = state.action
        menu.close(context)
        state.handlers[action]()
        setVisible(state, shown(context, state))
        return true
    end
    if state.dismiss then
        menu.close(context)
        setVisible(state, true)
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
