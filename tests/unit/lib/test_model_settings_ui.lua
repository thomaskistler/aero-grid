-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local base = root .. "/src/WIDGETS/AeroGrid"
local ui = assert(loadfile(base .. "/lib/model_settings_ui.lua"))()
local config = assert(loadfile(base .. "/lib/flight_config.lua"))()
local armedConfig = assert(loadfile(base .. "/lib/armed_service.lua"))()
local support = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
support.constants()
local mock = support.lvgl()
support.lcd()
EVT_VIRTUAL_EXIT = 9106
getFieldInfo = function(value)
    local channel = type(value) == "string" and tonumber(string.match(value, "^[cC][hH](%d+)$"))
    return channel and { id = channel + 100 } or nil
end
getSourceIndex = function(value)
    local info = getFieldInfo(value)
    return info and info.id
end
getSwitchIndex = function(value)
    local number = tonumber(string.match(value, "^L(%d%d)$"))
    return number and number + 1000 or value == "!L64" and -1064 or 0
end
model = {
    getLogicalSwitch = function(index)
        return { func = (index == 0 or index == 62) and 17 or 0 }
    end,
}

local function fixture(width)
    local c = {
        root = lvgl.box({ x = 0, y = 0, w = 480, h = 272 }),
        zone = { w = width or 480, h = 272 },
        flightConfig = config,
        armedConfig = armedConfig,
        armControl = {
            switchIndex = function(_, value)
                return getSwitchIndex(value)
            end,
        },
    }
    local control = { filename = "plane.yml", attempts = 0, published = 0, closed = 0, errors = 0 }
    local document = { modelFilename = control.filename, revision = 7, flight = config.defaults() }
    local state = ui.open(c, document, {
        modelFilename = function()
            return control.filename
        end,
        save = function(values, revision, filename, armed)
            control.attempts = control.attempts + 1
            assert(revision == document.revision and filename == document.modelFilename)
            if control.failure then
                return false, control.failure
            end
            if control.exception then
                error("filesystem exception")
            end
            document = { flight = values, armed = armed, revision = revision + 1, modelFilename = filename }
            return true, document
        end,
        saved = function(saved)
            assert(saved == document)
            control.published = control.published + 1
        end,
        cancel = function()
            control.closed = control.closed + 1
        end,
        error = function()
            control.errors = control.errors + 1
        end,
    })
    assert(state.nextY == 4 and state.smartStatus.hidden)
    for _ = 1, 12 do
        ui.advance(c)
        mock.settle()
    end
    assert(not state.build and not state.save and not state.cancel, "no draft-form buttons")
    assert(state.smartStatus.properties.y > state.controls.flightSwitch.parent.properties.y)
    local headings = {}
    for _, object in ipairs(mock.objects) do
        if object.parent == state.dialog and object.kind == "label" then
            headings[object.properties.text] = object.properties.y
            if type(object.properties.text) == "string" and object.properties.font() == SMLSIZE then
                local lines = 0
                for line in string.gmatch(object.properties.text, "[^\n]+") do
                    assert(lcd.sizeText(line, SMLSIZE) <= state.width, "description must fit the available width")
                    lines = lines + 1
                end
                local _, lineHeight = lcd.sizeText("Ag", SMLSIZE)
                assert(object.properties.h >= lines * lineHeight, "description must reserve height for every line")
            end
        end
    end
    assert(headings["Model arming"] < state.controls.armed.parent.properties.y)
    local descriptions = {}
    for text in pairs(headings) do
        if type(text) == "string" then
            descriptions[string.gsub(text, "\n", " ")] = true
            assert(not string.find(text, "Confirms flight", 1, true))
        end
    end
    assert(descriptions["Used by charts, navigation and flight detection"])
    assert(headings["Flight detection"] > state.controls.armed.parent.properties.y)
    assert(headings["Flight detection"] < state.controls.motorSource.parent.properties.y)
    assert(descriptions["Detects when a flight begins and ends using live telemetry data."])
    assert(
        descriptions["On during a detected flight. Use for your own special functions. Choose a dedicated Sticky logical switch, or None."]
    )
    assert(state.controls.armed.parent.properties.title == "Arm switch")
    assert(headings["Flight status output"] > state.controls.history.parent.properties.y)
    assert(state.controls.minFlightDuration.parent.properties.title == "Start detection window (s)")
    assert(state.controls.disarmDuration.parent.properties.title == "End detection window (s)")
    assert(state.controls.minFlightDuration.parent.properties.y < state.controls.disarmDuration.parent.properties.y)
    assert(state.controls.disarmDuration.parent.properties.y < state.controls.smartDetection.parent.properties.y)
    assert(state.controls.flightSwitch.parent.properties.title == "Flight status switch")
    return c, state, control, function()
        return document
    end
end

do
    local c = fixture(320)
    ui.close(c)
end

do
    local c, state, control, document = fixture()
    local layout = { dirty = true }
    c.editorUi = layout
    local function change(key, value)
        state.controls[key].properties.set(value)
        local attempts = control.attempts
        ui.advance(c)
        assert(control.attempts == attempts + 1)
        assert(c.modelSettingsUi == state, "saving a field keeps the page open")
        assert(state.revision == document().revision, "each field uses the latest saved revision")
    end
    change("history", 0)
    assert(document().flight.history == false and document().armed == nil, "unrelated edits preserve legacy arming")
    change("armed", 1064)
    assert(document().armed == "L64")
    change("motorSource", 105)
    change("motorReversed", 1)
    change("smartDetection", 1)
    assert(state.controls.flightSwitch.kind == "choice")
    local output = state.controls.flightSwitch.properties
    assert(#output.values == 65 and output.values[1] == "None" and output.values[65] == "L64")
    assert(output.filter(1) and output.filter(2) and output.filter(64))
    assert(not output.filter(3) and not output.filter(65), "hide unconfigured logical switches")
    change("flightSwitch", 64)
    assert(output.get() == 64, "choice indices map to logical switch names")
    change("minFlightDuration", 225)
    assert(document().flight.motorSource == "ch5" and document().flight.motorReversed)
    assert(document().flight.smartDetection and document().flight.flightSwitch == "L63")
    assert(document().flight.minFlightDuration == 2.25)
    change("armed", 0)
    assert(document().armed == "", "explicit None disables model arming")
    local attempts = control.attempts
    state.controls.flightSwitch.properties.set(-1063)
    state.controls.flightSwitch.properties.set(63)
    state.controls.flightSwitch.properties.set(0)
    state.controls.flightSwitch.properties.set(66)
    state.controls.flightSwitch.properties.set(2.5)
    ui.advance(c)
    assert(control.attempts == attempts and document().flight.flightSwitch == "L63")
    change("flightSwitch", 2)
    assert(document().flight.flightSwitch == "L01")
    change("flightSwitch", 1)
    assert(document().flight.flightSwitch == "")
    attempts = control.attempts
    state.controls.armed.properties.set(999)
    state.controls.motorSource.properties.set(999)
    ui.advance(c)
    assert(control.attempts == attempts and state.armed == "")
    ui.handle(c, EVT_VIRTUAL_EXIT)
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and control.closed == 1)
    assert(document().flight.smartDetection and c.editorUi == layout and layout.dirty)
    state.controls.history.properties.set(1)
    assert(control.attempts == attempts, "retired controls cannot save")
end

do
    local c, state, control, document = fixture()
    control.failure = "SD card unavailable"
    state.controls.motorSource.properties.set(107)
    assert(control.attempts == 0, "native callbacks defer filesystem work")
    ui.advance(c)
    assert(state.values.motorSource == "ch3" and document().flight.motorSource == "ch3")
    assert(state.controls.motorSource.properties.get() == 103)
    assert(state.status.properties.text == control.failure and control.errors == 1)
    control.failure = nil
    state.controls.motorSource.properties.set(107)
    ui.advance(c)
    assert(document().flight.motorSource == "ch7" and control.published == 1)
    assert(state.status.properties.text == "")
    state.controls.minMotorPercent.properties.set(10000)
    ui.advance(c)
    assert(control.attempts == 2 and state.values.minMotorPercent < 100 and control.errors == 2)
    control.exception = true
    state.controls.history.properties.set(0)
    ui.advance(c)
    assert(string.find(state.status.properties.text, "filesystem exception") and control.errors == 3)
    ui.close(c)
    mock.settle()
end

do
    local c, state, control = fixture()
    state.controls.history.properties.set(0)
    control.filename = "other.yml"
    ui.advance(c)
    assert(not c.modelSettingsUi and control.attempts == 0 and control.closed == 1)
end

do
    local c, state, control, document = fixture()
    state.controls.history.properties.set(0)
    state.dialog.properties.close()
    ui.advance(c)
    ui.advance(c)
    mock.settle()
    assert(not c.modelSettingsUi and document().flight.history == false)
    assert(control.published == 1 and control.closed == 1, "Back preserves a queued confirmed change")
end
