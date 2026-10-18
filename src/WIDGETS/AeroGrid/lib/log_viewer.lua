-- SPDX-License-Identifier: GPL-2.0-only

local viewer = { RUNTIME_API = 1 }

local function matches(event, name)
    return _G[name] ~= nil and event == _G[name]
end

function viewer.close(host)
    if host.logOverlay then
        host.logOverlay:clear()
        lvgl.hide(host.logOverlay)
    end
    host.logViewer = nil
    host.touchTapHandled = true
end

--- Measure one line per callback, and only for entries reached by the viewport.
local function wrapStep(host, state, index)
    local work = state.wrapping
    if not work then
        local entry = state.entries[index]
        work = { text = entry and host.diagnosticsLog.format(entry) or "No messages recorded", lines = {} }
        state.wrapping = work
    end
    local text = work.text
    local low, high = 1, #text
    while low < high do
        local middle = math.floor((low + high + 1) / 2)
        if host.themeBuilder.measureText(SMLSIZE, string.sub(text, 1, middle)) <= state.width then
            low = middle
        else
            high = middle - 1
        end
    end
    local finish = low
    if finish < #text then
        finish = string.match(string.sub(text, 1, finish + 1), "^.*()%s") or finish
    end
    work.lines[#work.lines + 1] = string.gsub(string.sub(text, 1, finish), "%s+$", "")
    work.text = string.gsub(string.sub(text, finish + 1), "^%s+", "")
    if work.text ~= "" then
        return nil
    end
    state.cache[index] = work.lines
    state.wrapping = nil
    return work.lines
end

local function move(state, direction)
    local lines = state.cache[state.index]
    if direction < 0 then
        if state.offset > 1 then
            state.offset = state.offset - 1
        elseif state.index > 1 then
            local previous = state.index - 1
            if not state.cache[previous] then
                state.prepareIndex, state.preparedLines = previous, nil
                return
            end
            state.index, state.offset = previous, #state.cache[previous]
        end
    elseif state.offset < #lines then
        state.offset = state.offset + 1
    elseif state.index < math.max(1, #state.entries) then
        state.index, state.offset = state.index + 1, 1
    end
end

local function render(state)
    local index, offset = state.index, state.offset
    for rowIndex, row in ipairs(state.rows) do
        local lines = state.cache[index]
        local text = lines[offset] or ""
        row:set({ text = text })
        offset = offset + 1
        if offset > #lines then
            index, offset = index + 1, 1
        end
        if index > math.max(1, #state.entries) then
            for nextRow = rowIndex + 1, #state.rows do
                state.rows[nextRow]:set({ text = "" })
            end
            break
        end
    end
end

function viewer.open(host)
    local width, height = host.zone.w, host.zone.h
    local overlay = host.logOverlay
    if not overlay then
        overlay = lvgl.box(host.page, { x = 0, y = 0, w = width, h = height })
        host.logOverlay = overlay
        host.pageBuiltFullscreen = true
    end
    overlay:set({ w = width, h = height })
    lvgl.show(overlay)
    local state = {
        entries = host.diagnosticsLog:read(),
        cache = {},
        rows = {},
        width = width - 16,
        height = height,
        lineHeight = host.themeBuilder.fontHeight(SMLSIZE) + 2,
    }
    host.logViewer = state
    lvgl.rectangle(overlay, {
        x = 0,
        y = 0,
        w = width,
        h = height,
        filled = true,
        color = host.theme.color.canvas,
    })
    host.primitives.label(overlay, host.theme, {
        x = 8,
        y = 6,
        w = width - 100,
        text = "DIAGNOSTICS LOG (snapshot)",
        font = SMLSIZE,
        color = host.theme.color.text,
    })
    state.closeButton = lvgl.button(overlay, {
        x = width - 80,
        y = 2,
        w = 72,
        h = 30,
        text = "Close",
        press = function()
            viewer.close(host)
        end,
    })
    for index = 1, math.max(1, math.floor((height - 40) / state.lineHeight)) do
        state.rows[index] = host.primitives.label(overlay, host.theme, {
            x = 8,
            y = 36 + (index - 1) * state.lineHeight,
            w = state.width,
            text = "",
            font = SMLSIZE,
            color = host.theme.color.text,
        })
    end
    state.index = math.max(1, #state.entries)
    state.offset = 1
    state.prepareIndex, state.preparedLines = state.index, 0
    state.rows[1]:set({ text = "Loading log..." })
end

--- Prepare the initial tail or one newly reached message without blocking input.
function viewer.advance(host)
    local state = host.logViewer
    if not state.prepareIndex then
        return
    end
    local index = state.prepareIndex
    local lines = wrapStep(host, state, index)
    if not lines then
        return
    end
    if not state.preparedLines then
        state.index, state.offset = index, #lines
        state.prepareIndex = nil
        render(state)
        return
    end
    state.preparedLines = state.preparedLines + #lines
    if state.preparedLines >= #state.rows or index == 1 then
        state.index = index
        state.offset = math.max(1, state.preparedLines - #state.rows + 1)
        state.prepareIndex = nil
        render(state)
    else
        state.prepareIndex = index - 1
    end
end

function viewer.handle(host, event, touch)
    local state = host.logViewer
    if matches(event, "EVT_VIRTUAL_EXIT") or matches(event, "EVT_EXIT_BREAK") then
        viewer.close(host)
    elseif state.prepareIndex then
        return true
    elseif matches(event, "EVT_TOUCH_FIRST") and touch then
        state.dragY, state.slid = touch.y, false
    elseif matches(event, "EVT_TOUCH_SLIDE") and touch and state.dragY then
        local delta = state.dragY - touch.y
        local steps = math.floor(math.abs(delta) / state.lineHeight)
        if steps > 0 then
            state.slid = true
            local direction = delta > 0 and 1 or -1
            move(state, direction)
            state.dragY = touch.y
            render(state)
        end
    elseif matches(event, "EVT_TOUCH_TAP") and touch and not state.slid then
        if touch.x >= host.zone.w - 80 and touch.y < 32 then
            viewer.close(host)
        end
    elseif matches(event, "EVT_TOUCH_BREAK") then
        state.dragY = nil
    elseif matches(event, "EVT_ROT_LEFT") or matches(event, "EVT_VIRTUAL_PREV") then
        move(state, -1)
        render(state)
    elseif matches(event, "EVT_ROT_RIGHT") or matches(event, "EVT_VIRTUAL_NEXT") then
        move(state, 1)
        render(state)
    end
    return true
end

return viewer
