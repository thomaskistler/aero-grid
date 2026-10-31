-- SPDX-License-Identifier: GPL-2.0-only

local menu = { RUNTIME_API = 1 }

-- BEGIN GENERATED ICON MASKS (tools/generate-menu-icon.py)
local ICON_MASKS = {
    [36] = "\0\0\29\3\255\29\0\1\1\41\29\1\1\1\137\29\2\1\1\232\30\2\1\1\5\0\3\30\3\255\30\3\1\1\82\30\4\1\1\182\30\5\1\1\253\31\5\1\1\31\0\6\31\2\255\31\6\1\1\127\31\7\1\1\226\32\7\1\1\3\0\8\32\3\255\32\8\1\1\71\32\9\1\1\171\32\10\1\1\249\33\10\1\1\22\0\11\33\2\255\33\11\1\1\116\33\12\1\1\216\34\12\1\1\1\0\13\34\3\255\34\13\1\1\61\34\14\1\1\160\34\15\1\1\246\35\15\1\1\16\0\16\35\4\255\35\16\1\1\105\35\17\1\1\209\35\18\1\1\204\35\19\1\1\105\0\20\34\3\255\34\20\1\1\246\35\20\1\1\16\34\21\1\1\160\34\22\1\1\60\0\23\33\2\255\33\23\1\1\216\34\23\1\1\1\33\24\1\1\116\0\25\32\3\255\32\25\1\1\249\33\25\1\1\22\32\26\1\1\171\32\27\1\1\71\0\28\31\2\255\31\28\1\1\226\32\28\1\1\3\31\29\1\1\127\0\30\30\3\255\30\30\1\1\253\31\30\1\1\31\30\31\1\1\182\30\32\1\1\82\0\33\29\3\255\29\33\1\1\232\30\33\1\1\5\29\34\1\1\137\29\35\1\1\41",
    [45] = "\0\0\36\2\255\36\0\1\1\99\36\1\1\1\198\0\2\37\3\255\37\2\1\1\46\37\3\1\1\142\37\4\1\1\236\38\4\1\1\8\0\5\38\3\255\38\5\1\1\88\38\6\1\1\187\38\7\1\1\254\39\7\1\1\35\0\8\39\2\255\39\8\1\1\132\39\9\1\1\231\40\9\1\1\4\0\10\40\3\255\40\10\1\1\77\40\11\1\1\176\40\12\1\1\251\41\12\1\1\26\0\13\41\2\255\41\13\1\1\122\41\14\1\1\222\42\14\1\1\2\0\15\42\3\255\42\15\1\1\66\42\16\1\1\166\42\17\1\1\249\43\17\1\1\20\0\18\43\2\255\43\18\1\1\111\43\19\1\1\211\0\20\44\5\255\44\20\1\1\55\44\21\1\1\155\44\22\1\1\230\44\23\1\1\154\44\24\1\1\55\0\25\43\2\255\43\25\1\1\210\43\26\1\1\110\0\27\42\3\255\42\27\1\1\248\43\27\1\1\20\42\28\1\1\165\42\29\1\1\66\0\30\41\2\255\41\30\1\1\221\42\30\1\1\2\41\31\1\1\121\0\32\40\3\255\40\32\1\1\251\41\32\1\1\26\40\33\1\1\176\40\34\1\1\77\0\35\39\2\255\39\35\1\1\230\40\35\1\1\4\39\36\1\1\131\0\37\38\3\255\38\37\1\1\254\39\37\1\1\35\38\38\1\1\187\38\39\1\1\88\0\40\37\3\255\37\40\1\1\236\38\40\1\1\8\37\41\1\1\142\37\42\1\1\46\0\43\36\2\255\36\43\1\1\198\36\44\1\1\99",
    [62] = "\0\0\49\1\255\49\0\1\1\249\50\0\1\1\22\0\1\50\2\255\50\1\1\1\115\50\2\1\1\216\51\2\1\1\1\0\3\51\3\255\51\3\1\1\59\51\4\1\1\159\51\5\1\1\246\52\5\1\1\16\0\6\52\2\255\52\6\1\1\104\52\7\1\1\204\0\8\53\3\255\53\8\1\1\49\53\9\1\1\148\53\10\1\1\240\54\10\1\1\10\0\11\54\2\255\54\11\1\1\93\54\12\1\1\193\0\13\55\3\255\55\13\1\1\41\55\14\1\1\137\55\15\1\1\232\56\15\1\1\5\0\16\56\3\255\56\16\1\1\83\56\17\1\1\182\56\18\1\1\253\57\18\1\1\31\0\19\57\2\255\57\19\1\1\127\57\20\1\1\227\58\20\1\1\3\0\21\58\3\255\58\21\1\1\72\58\22\1\1\171\58\23\1\1\250\59\23\1\1\24\0\24\59\2\255\59\24\1\1\117\59\25\1\1\217\60\25\1\1\1\0\26\60\3\255\60\26\1\1\61\60\27\1\1\161\60\28\1\1\246\61\28\1\1\17\0\29\61\4\255\61\29\1\1\106\61\30\1\1\209\61\31\1\1\204\61\32\1\1\104\0\33\60\3\255\60\33\1\1\246\61\33\1\1\16\60\34\1\1\159\60\35\1\1\60\0\36\59\2\255\59\36\1\1\216\60\36\1\1\1\59\37\1\1\115\0\38\58\3\255\58\38\1\1\249\59\38\1\1\22\58\39\1\1\170\58\40\1\1\71\0\41\57\2\255\57\41\1\1\226\58\41\1\1\3\57\42\1\1\126\0\43\56\3\255\56\43\1\1\253\57\43\1\1\30\56\44\1\1\181\56\45\1\1\82\0\46\55\3\255\55\46\1\1\232\56\46\1\1\5\55\47\1\1\137\55\48\1\1\40\0\49\54\2\255\54\49\1\1\192\54\50\1\1\93\0\51\53\3\255\53\51\1\1\240\54\51\1\1\10\53\52\1\1\148\53\53\1\1\49\0\54\52\2\255\52\54\1\1\203\52\55\1\1\104\0\56\51\3\255\51\56\1\1\246\52\56\1\1\16\51\57\1\1\159\51\58\1\1\59\0\59\50\2\255\50\59\1\1\216\51\59\1\1\1\50\60\1\1\115\0\61\49\1\255\49\61\1\1\249\50\61\1\1\22",
}
-- END GENERATED ICON MASKS

-- EdgeTX v2.12 QuickMenu/QuickMenuGroup is C++ only; lvgl.menu is a list.
-- Reproduce its monochrome icon tiles with Lua's supported drawing objects,
-- not themed buttons (whose focus colors cannot be overridden through Lua).
local TILES = {
    { icon = "model", label = "Model\nsettings", action = "modelSettings" },
    { icon = "theme", label = "UI\nsetup", action = "uiSetup" },
}

--- EdgeTX fills its native top-left icon with the theme's FOCUS color.
local function backgroundColor()
    local focus = lcd and lcd.getColor and COLOR_THEME_FOCUS and lcd.getColor(COLOR_THEME_FOCUS)
    return type(focus) == "number" and focus or lcd.RGB(54, 86, 115)
end

local function createBackground(root, size, color)
    local mask = assert(ICON_MASKS[size], "Unsupported AeroGrid menu icon size")
    local rectangles = {}
    local byte, rectangle = string.byte, lvgl.rectangle
    for index = 1, #mask, 5 do
        local x, y, w, h, opacity = byte(mask, index, index + 4)
        rectangles[(index + 4) / 5] = rectangle(root, {
            x = x,
            y = y,
            w = w,
            h = h,
            filled = true,
            color = color,
            opacity = opacity,
        })
    end
    return rectangles
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
    local name = "aerogrid-mark-" .. size .. ".png"
    local path = handlers.iconPath or ((context.path or "/WIDGETS/AeroGrid/") .. "assets/" .. name)
    local color = backgroundColor()
    local state = context.aerogridMenu
    local created = false
    local parent = handlers.parent or context.root
    if state and (state.parent ~= parent or state.backgroundSize ~= size) then
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
    if state.backgroundColor ~= color then
        for _, rectangle in ipairs(state.background) do
            rectangle:set({ color = color })
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
    if enabled(context, state) then
        lvgl.show(state.root)
    else
        lvgl.hide(state.root)
    end
    return state, created
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
