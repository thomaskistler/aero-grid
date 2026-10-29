-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid"
local ui = assert(loadfile(base .. "/lib/model_settings_ui.lua"))()
local menu = assert(loadfile(base .. "/lib/aerogrid_menu.lua"))()
local config = assert(loadfile(base .. "/lib/flight_config.lua"))()
local support = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
support.constants()
local mock = support.lvgl()
EVT_TOUCH_FIRST, EVT_TOUCH_BREAK, EVT_TOUCH_TAP, EVT_TOUCH_SLIDE, EVT_TOUCH_LONG = 9101, 9102, 9103, 9104, 9105
EVT_VIRTUAL_EXIT = 9106
getFieldInfo = function(value)
    if type(value) == "number" then
        return { id = value, name = "CH" .. (value - 100) }
    end
    local channel = tonumber(string.match(value or "", "^[cC][hH](%d+)$"))
    if channel then
        return { id = channel + 100, name = "CH" .. channel }
    end
end
getSourceIndex = function(value)
    local info = getFieldInfo(value)
    return info and info.id
end

local function context()
    return {
        root = lvgl.box({ x = 0, y = 0, w = 480, h = 272 }),
        zone = { w = 480, h = 272 },
        flightConfig = config,
        path = base .. "/",
        panels = {},
    }
end

local function finish(context)
    for _ = 1, 12 do
        ui.advance(context)
        mock.settle()
    end
    assert(context.modelSettingsUi and not context.modelSettingsUi.build)
end

do
    local c = context()
    local layoutDraft = { dirty = true, draft = { panels = {} } }
    c.editorUi = layoutDraft
    local document = { modelFilename = "plane.yml", revision = 4, flight = config.defaults(), status = "Armed: SF up" }
    local saved, cancelled = 0, 0
    local state = ui.open(c, document, {
        save = function()
            saved = saved + 1
            return true, {}
        end,
        cancel = function()
            cancelled = cancelled + 1
        end,
    })
    finish(c)
    assert(state.status.properties.text == "Armed: SF up")
    assert(state.controls.armSwitch == nil and state.controls.ownership == nil)
    assert(state.controls.motorSource.kind == "source")
    assert(state.controls.smartDetection.kind == "toggle" and not state.draft.smartDetection)
    assert(state.controls.flightSwitch.kind == "numberEdit", "output uses a positive numeric picker, not SWITCH input")
    state.controls.motorSource.properties.set(105)
    state.controls.motorReversed.properties.set(1)
    state.controls.smartDetection.properties.set(1)
    assert(
        state.draft.smartDetection and not document.flight.smartDetection,
        "Smart toggles only the independent draft"
    )
    state.controls.flightSwitch.properties.set(64)
    assert(state.draft.motorSource == "ch5" and state.draft.motorReversed and state.draft.flightSwitch == "L64")
    assert(document.flight.motorSource == "ch3" and document.flight.flightSwitch == "")
    state.cancel.properties.press()
    assert(c.modelSettingsUi and cancelled == 0, "native callback must defer closing")
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and cancelled == 1 and saved == 0)
    assert(c.editorUi == layoutDraft and layoutDraft.dirty, "model Cancel must not discard a layout draft")
    state.save.properties.press()
    assert(saved == 0, "retired dialog callbacks are inert")
end

do
    local c, attempts, published = context(), 0, 0
    local state = ui.open(c, { modelFilename = "plane.yml", revision = 7 }, {
        save = function(draft, revision, filename)
            attempts = attempts + 1
            assert(revision == 7 and filename == "plane.yml" and draft.motorSource == "ch7" and draft.smartDetection)
            draft.motorSource = "ch1"
            if attempts == 1 then
                return false, "SD card unavailable"
            end
            return true, { revision = 8 }
        end,
        saved = function(document)
            assert(document.revision == 8)
            published = published + 1
        end,
    })
    finish(c)
    state.controls.motorSource.properties.set(107)
    state.controls.smartDetection.properties.set(1)
    state.save.properties.press()
    assert(attempts == 0)
    ui.advance(c)
    assert(c.modelSettingsUi == state and state.draft.motorSource == "ch7")
    assert(state.status.properties.text == "SD card unavailable" and published == 0)
    state.save.properties.press()
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and attempts == 2 and published == 1)
end

do
    local c, filename, cancelled, saves = context(), "plane.yml", 0, 0
    local state = ui.open(c, { modelFilename = filename, revision = 0 }, {
        modelFilename = function()
            return filename
        end,
        save = function()
            saves = saves + 1
            return true, {}
        end,
        cancel = function()
            cancelled = cancelled + 1
        end,
    })
    finish(c)
    state.save.properties.press()
    filename = "other.yml"
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and saves == 0 and cancelled == 1)
    state.save.properties.press()
    assert(saves == 0)
end

do
    local c, saves = context(), 0
    local state = ui.open(c, {
        modelFilename = "plane.yml",
        revision = 0,
        choices = {
            { label = "Layout A / counter 1", flight = { motorSource = "ch1", minFlightDuration = 1.5 } },
            { label = "Layout B / counter 2", flight = { motorSource = "ch9" } },
        },
    }, {
        save = function()
            saves = saves + 1
            error("injected filesystem exception")
        end,
    })
    finish(c)
    assert(state.legacyChoice.properties.values[1] == "Defaults")
    assert(state.legacyChoice.properties.values[3] == "Layout B / counter 2")
    state.legacyChoice.properties.set(2)
    assert(state.draft.motorSource == "ch1" and state.draft.minFlightDuration == 1.5)
    assert(state.controls.minFlightDuration.properties.get() == 150)
    state.controls.minFlightDuration.properties.set(225)
    assert(state.draft.minFlightDuration == 2.25)
    state.legacyChoice.properties.set(3)
    assert(state.draft.motorSource == "ch9")
    state.draft.minMotorPercent = 100
    state.save.properties.press()
    ui.advance(c)
    assert(c.modelSettingsUi == state and saves == 0, "validation failures retain an independent editable draft")
    state.controls.minMotorPercent.properties.set(2550)
    state.save.properties.press()
    ui.advance(c)
    assert(c.modelSettingsUi == state and saves == 1)
    assert(string.find(state.status.properties.text, "filesystem exception", 1, true))
    ui.close(c)
    mock.settle()
end

do
    local c, cancelled = context(), 0
    local state = ui.open(c, { modelFilename = "plane.yml", revision = 0 }, {
        save = function()
            error("RTN must not save")
        end,
        cancel = function()
            cancelled = cancelled + 1
        end,
    })
    local properties = state.dialog.properties
    properties.close()
    assert(c.modelSettingsUi and state.dialog == nil)
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and cancelled == 1, "RTN while building must cancel without creating more controls")
end

do
    local c, fullscreen, modal, filename = context(), false, false, "plane.yml"
    local opened = { model = 0, layout = 0 }
    local handlers = {
        fullscreen = function()
            return fullscreen
        end,
        modal = function()
            return modal
        end,
        modelFilename = function()
            return filename
        end,
        modelSettings = function()
            opened.model = opened.model + 1
        end,
        uiSetup = function()
            opened.layout = opened.layout + 1
        end,
    }
    for _, dimensions in ipairs({ { w = 38, h = 36 }, { w = 47, h = 45 }, { w = 65, h = 62 } }) do
        local state = menu.ensure(c, dimensions, handlers)
        assert(
            state.root.hidden and state.root.properties.w == dimensions.w and state.root.properties.h == dimensions.h
        )
        assert(not menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 }), "App/native input remains untouched")
        local image = state.image.properties
        assert(image.x == 0 and image.y == 0, "native artwork starts at the physical top-left")
        assert(image.w == dimensions.h and image.h == dimensions.h, "silhouette is square; reservation is wider")
        local asset = "aerogrid-orange-" .. dimensions.h .. ".png"
        assert(string.sub(image.file(), -#asset) == asset, "each display uses its exact native-resolution mask")
        assert(state.button == nil, "a styled rectangular button must not fill the transparent angled edge")
    end
    fullscreen = true
    local previousLcd = lcd
    support.lcd()
    local defaultFocus = lcd.getColor
    assert(menu.variant() == "orange", "orange is distinct from the default EdgeTX FOCUS blue")
    lcd.getColor = function()
        return lcd.RGB(237, 149, 46)
    end
    assert(menu.variant() == "violet", "an orange EdgeTX theme moves AeroGrid to the next variant")
    lcd.getColor = function()
        return lcd.RGB(120, 120, 120)
    end
    assert(menu.variant() == "orange", "a neutral gray theme keeps the first variant")
    lcd.getColor = function()
        return nil
    end
    assert(menu.variant() == "orange")
    lcd.getColor = defaultFocus
    lcd = previousLcd
    local state = menu.ensure(c, { w = 48, h = 36 }, handlers)
    assert(not state.root.hidden)
    assert(menu.handle(c, EVT_TOUCH_FIRST, { x = 47, y = 35 }))
    assert(menu.handle(c, EVT_TOUCH_LONG, { x = 100, y = 100 }), "icon hold must not enter the editor")
    assert(menu.handle(c, EVT_TOUCH_BREAK, { x = 47, y = 35 }))
    assert(menu.handle(c, EVT_TOUCH_TAP, { x = 47, y = 35 }))
    assert(menu.advance(c))
    local native = mock.menu()
    assert(native.title == "AeroGrid" and native.values[1] == "Model settings" and native.values[2] == "UI setup")
    assert(menu.handle(c, EVT_TOUCH_TAP, { x = 47, y = 35 }))
    assert(not menu.advance(c), "a bubbled duplicate tap must not create another menu")
    assert(not menu.handle(c, 123456), "captured touch must not swallow later keys")
    native.set(1)
    assert(opened.model == 0)
    assert(menu.advance(c) and opened.model == 1)
    native.set(2)
    menu.advance(c)
    assert(opened.layout == 0, "a native menu selection is one-shot")
    menu.handle(c, EVT_TOUCH_FIRST, { x = 1, y = 1 })
    menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
    menu.advance(c)
    mock.menu().set(2)
    menu.advance(c)
    assert(opened.layout == 1)
    assert(not menu.handle(c, EVT_TOUCH_FIRST, { x = 48, y = 35 }), "right edge is exclusive")
    assert(not menu.handle(c, EVT_TOUCH_TAP, { x = 48, y = 35 }))
    menu.handle(c, EVT_TOUCH_FIRST, { x = 1, y = 1 })
    menu.handle(c, EVT_TOUCH_TAP, { x = 1, y = 1 })
    menu.advance(c)
    native = mock.menu()
    filename = "other.yml"
    menu.ensure(c, { w = 48, h = 36 }, handlers)
    native.set(1)
    menu.advance(c)
    assert(opened.model == 1, "model switch invalidates native menu callbacks")
    modal = true
    menu.ensure(c, { w = 48, h = 36 }, handlers)
    assert(state.root.hidden and not menu.handle(c, EVT_TOUCH_FIRST, { x = 1, y = 1 }))
    modal, fullscreen = false, false
    menu.ensure(c, { w = 48, h = 36 }, handlers)
    native.set(2)
    menu.advance(c)
    assert(opened.layout == 1 and state.root.hidden, "leaving fullscreen invalidates stale actions")
end
