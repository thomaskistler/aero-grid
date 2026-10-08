-- SPDX-License-Identifier: GPL-2.0-only

--- In-memory dashboard editing and all-or-nothing layout validation.

local editor = { RUNTIME_API = 1 }

editor.CATALOG = {
    { type = "cell-battery", label = "Cell battery" },
    { type = "flight-counter", label = "Flight counter" },
    { type = "flight-mode", label = "Flight mode" },
    { type = "flight-timer", label = "Flight timer" },
    { type = "link-status", label = "Link status" },
    { type = "metric", label = "Metric" },
    { type = "model-identity", label = "Model identity" },
    { type = "navigation", label = "Navigation" },
    { type = "text", label = "Switch text" },
    { type = "trim-panel", label = "Trim panel" },
    { type = "tx-battery", label = "Transmitter battery" },
    { type = "host-diagnostics", label = "Host diagnostics" },
    { type = "service-probe", label = "Service probe" },
}

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[copy(key, seen)] = copy(child, seen)
    end
    return result
end

local function safeIdentifier(value)
    return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

local function supportsSpan(module, colSpan, rowSpan)
    local spans = module.supportedSpans
    if spans == nil then
        return true
    end
    local name = tostring(colSpan) .. "x" .. tostring(rowSpan)
    for _, span in ipairs(spans) do
        if span == "any" or span == name then
            return true
        end
    end
    return false
end

local function overlapsAny(grid, placements, placement, except)
    for index, existing in ipairs(placements) do
        if index ~= except and grid.overlaps(existing, placement) then
            return existing
        end
    end
    return nil
end

local function validateSetting(setting, value)
    if value == nil then
        return setting.required ~= true, setting.key .. " is required"
    end
    if setting.type and type(value) ~= setting.type then
        return false, setting.key .. " must be a " .. setting.type
    end
    if type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge) then
        return false, setting.key .. " must be a finite number"
    end
    if type(value) == "number" then
        if type(setting.min) == "number" and value < setting.min then
            return false, setting.key .. " must be at least " .. tostring(setting.min)
        end
        if type(setting.max) == "number" and value > setting.max then
            return false, setting.key .. " must be at most " .. tostring(setting.max)
        end
        if type(setting.step) == "number" and setting.step > 0 and type(setting.min) == "number" then
            local steps = (value - setting.min) / setting.step
            if math.abs(steps - math.floor(steps + 0.5)) > 0.000001 then
                return false, setting.key .. " must use steps of " .. tostring(setting.step)
            end
        end
    end
    if setting.choices then
        for _, choice in ipairs(setting.choices) do
            if value == choice then
                return true
            end
        end
        return false, setting.key .. " must be one of " .. table.concat(setting.choices, ", ")
    end
    return true
end

local function settingsFor(module, config)
    local values, knownConfig, errors = {}, {}, {}
    for _, setting in ipairs(module.settings or {}) do
        if type(setting) ~= "table" or type(setting.key) ~= "string" then
            errors[#errors + 1] = "panel has a malformed setting declaration"
        else
            local value = config[setting.key]
            if value == nil then
                value = setting.default
            end
            values[setting.key] = copy(value)
            if config[setting.key] ~= nil then
                knownConfig[setting.key] = copy(config[setting.key])
            end
            local valid, message = validateSetting(setting, value)
            if not valid then
                errors[#errors + 1] = message
            end
        end
    end
    return values, knownConfig, errors
end

--- Create an editor session from a validated phase-one document.
---@param document table
---@param grid table Grid module.
---@param layout table Layout validator.
---@param panelHost table Panel contract implementation.
---@param loadPanel fun(typeName: string): table?, string?
---@return table? session
---@return string? error
function editor.new(document, grid, layout, panelHost, loadPanel)
    if type(document) ~= "table" or type(document.panels) ~= "table" then
        return nil, "cannot edit an invalid layout"
    end
    local session = {
        original = copy(document),
        draft = copy(document),
        grid = grid,
        layout = layout,
        panelHost = panelHost,
        loadPanel = loadPanel,
        selected = #document.panels > 0 and 1 or 0,
        dirty = false,
        errors = {},
    }
    return session
end

function editor.clone(value)
    return copy(value)
end

function editor.select(session, index)
    local count = #session.draft.panels
    if count == 0 then
        session.selected = 0
        return false, "layout has no panels"
    end
    if type(index) ~= "number" or index % 1 ~= 0 then
        return false, "panel selection must be an integer"
    end
    session.selected = ((index - 1) % count) + 1
    return true
end

local function getPanelModule(session, typeName)
    local module, moduleError = session.loadPanel(typeName)
    if not module then
        return nil, moduleError or ("cannot load panel " .. tostring(typeName))
    end
    local valid, validationError = session.panelHost.validateModule(module, typeName)
    if not valid then
        return nil, validationError
    end
    return module
end

local function freePlacement(session, colSpan, rowSpan)
    for row = 0, 4 - rowSpan do
        for col = 0, 4 - colSpan do
            local candidate = {
                col = col,
                row = row,
                colSpan = colSpan,
                rowSpan = rowSpan,
            }
            if not overlapsAny(session.grid, session.draft.panels, candidate) then
                return candidate
            end
        end
    end
    return nil
end

local function candidateSpans(module)
    local result, seen = {}, {}
    local spans = module.supportedSpans
    if type(spans) == "table" then
        for _, span in ipairs(spans) do
            local width, height
            if type(span) == "string" then
                width, height = string.match(span, "^(%d+)x(%d+)$")
            end
            width, height = tonumber(width), tonumber(height)
            if width and height and not seen[span] then
                result[#result + 1] = { width, height }
                seen[span] = true
            end
        end
    end
    if #result == 0 and spans == nil then
        result[1] = { 1, 1 }
    end
    table.sort(result, function(first, second)
        local firstArea, secondArea = first[1] * first[2], second[1] * second[2]
        if firstArea ~= secondArea then
            return firstArea < secondArea
        end
        if first[2] ~= second[2] then
            return first[2] < second[2]
        end
        return first[1] < second[1]
    end)
    return result
end

function editor.availablePositions(session, colSpan, rowSpan, excluded)
    local positions = {}
    for row = 0, 4 - rowSpan do
        for col = 0, 4 - colSpan do
            local placement = { col = col, row = row, colSpan = colSpan, rowSpan = rowSpan }
            if not overlapsAny(session.grid, session.draft.panels, placement, excluded) then
                positions[#positions + 1] = placement
            end
        end
    end
    return positions
end

function editor.sizes(session)
    local placement = session.draft.panels[session.selected]
    if not placement then
        return {}
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return nil, moduleError
    end
    local sizes = {}
    for rowSpan = 1, 4 do
        for colSpan = 1, 4 do
            local candidate = {
                col = placement.col,
                row = placement.row,
                colSpan = colSpan,
                rowSpan = rowSpan,
            }
            if
                supportsSpan(module, colSpan, rowSpan)
                and placement.col + colSpan <= 4
                and placement.row + rowSpan <= 4
                and not overlapsAny(session.grid, session.draft.panels, candidate, session.selected)
            then
                sizes[#sizes + 1] = tostring(colSpan) .. "x" .. tostring(rowSpan)
            end
        end
    end
    return sizes
end
function editor.add(session, typeName)
    if not safeIdentifier(typeName) then
        return false, "invalid panel type"
    end
    local module, moduleError = getPanelModule(session, typeName)
    if not module then
        return false, moduleError
    end
    local placement
    for _, span in ipairs(candidateSpans(module)) do
        placement = freePlacement(session, span[1], span[2])
        if placement then
            break
        end
    end
    if not placement then
        return false, "no free grid cells support this panel"
    end

    local used = {}
    for _, item in ipairs(session.draft.panels) do
        used[item.id] = true
    end
    local suffix, id = 1, typeName .. "-1"
    while used[id] do
        suffix = suffix + 1
        id = typeName .. "-" .. tostring(suffix)
    end

    local config = {}
    for _, setting in ipairs(module.settings or {}) do
        if type(setting) == "table" and type(setting.key) == "string" and setting.default ~= nil then
            config[setting.key] = copy(setting.default)
        end
    end
    placement.id = id
    placement.type = typeName
    placement.config = config
    session.draft.panels[#session.draft.panels + 1] = placement
    session.selected = #session.draft.panels
    session.dirty = true
    return true
end

function editor.remove(session, index)
    index = index or session.selected
    if index < 1 or index > #session.draft.panels then
        return false, "no panel is selected"
    end
    table.remove(session.draft.panels, index)
    if #session.draft.panels == 0 then
        session.selected = 0
    else
        session.selected = math.min(index, #session.draft.panels)
    end
    session.dirty = true
    return true
end

local function findSelected(session)
    local index = session.selected
    local placement = session.draft.panels[index]
    if not placement then
        return nil, nil, "no panel is selected"
    end
    return placement, index
end

function editor.move(session, colDelta, rowDelta)
    local placement, index, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    local moved = copy(placement)
    moved.col = moved.col + colDelta
    moved.row = moved.row + rowDelta
    local valid, placementError = session.grid.validatePlacement(moved, 4, 4)
    if not valid then
        return false, placementError
    end
    local conflict = overlapsAny(session.grid, session.draft.panels, moved, index)
    if conflict then
        return false, "overlaps panel " .. conflict.id
    end
    placement.col, placement.row = moved.col, moved.row
    session.dirty = true
    return true
end

function editor.resize(session, colDelta, rowDelta)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    local resized = copy(placement)
    resized.colSpan = resized.colSpan + colDelta
    resized.rowSpan = resized.rowSpan + rowDelta
    local valid, placementError = session.grid.validatePlacement(resized, 4, 4)
    if not valid then
        return false, placementError
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return false, moduleError
    end
    if not supportsSpan(module, resized.colSpan, resized.rowSpan) then
        return false, "panel does not support span " .. tostring(resized.colSpan) .. "x" .. tostring(resized.rowSpan)
    end
    local conflict = overlapsAny(session.grid, session.draft.panels, resized, session.selected)
    if conflict then
        return false, "overlaps panel " .. conflict.id
    end
    placement.colSpan, placement.rowSpan = resized.colSpan, resized.rowSpan
    session.dirty = true
    return true
end

function editor.setValue(session, key, value)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return false, moduleError
    end
    local setting
    for _, candidate in ipairs(module.settings or {}) do
        if candidate.key == key then
            setting = candidate
            break
        end
    end
    if not setting then
        return false, "unknown setting " .. tostring(key)
    end
    local valid, settingError = validateSetting(setting, value)
    if not valid then
        return false, settingError
    end
    placement.config = type(placement.config) == "table" and placement.config or {}
    placement.config[key] = copy(value)
    session.dirty = true
    return true
end

local function resolvePath(value, path)
    local parent = value
    for index = 1, #path - 1 do
        if type(parent) ~= "table" then
            return nil, nil
        end
        parent = parent[path[index]]
    end
    if type(parent) ~= "table" or #path == 0 then
        return nil, nil
    end
    return parent, path[#path]
end

function editor.setPath(session, key, path, value)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    if type(path) ~= "table" or #path == 0 then
        return false, "nested setting path is required"
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return false, moduleError
    end
    local declared = false
    for _, setting in ipairs(module.settings or {}) do
        if setting.key == key and setting.type == "table" then
            declared = true
            break
        end
    end
    if not declared then
        return false, "setting is not a structured table"
    end
    local target, targetKey = resolvePath(placement.config and placement.config[key], path)
    if not target then
        return false, "nested setting path does not exist"
    end
    local current = target[targetKey]
    if current ~= nil and type(current) ~= type(value) then
        return false, "nested setting value has the wrong type"
    end
    target[targetKey] = copy(value)
    session.dirty = true
    return true
end

function editor.appendItem(session, key)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return false, moduleError
    end
    for _, setting in ipairs(module.settings or {}) do
        if setting.key == key and setting.type == "table" then
            local value = placement.config and placement.config[key]
            if type(value) ~= "table" then
                return false, key .. " is not a table"
            end
            local maximum = setting.maxItems or 3
            if #value >= maximum then
                return false, key .. " already has the maximum number of entries"
            end
            if #value == 0 then
                return false, "cannot duplicate an entry from an empty list"
            end
            value[#value + 1] = copy(value[#value])
            session.dirty = true
            return true
        end
    end
    return false, "unknown table setting " .. tostring(key)
end

function editor.removeItem(session, key, index)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return false, selectionError
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return false, moduleError
    end
    for _, setting in ipairs(module.settings or {}) do
        if setting.key == key and setting.type == "table" then
            local value = placement.config and placement.config[key]
            if type(value) ~= "table" or index < 1 or index > #value then
                return false, "table entry does not exist"
            end
            if #value <= (setting.minItems or 0) then
                return false, key .. " must keep at least " .. tostring(setting.minItems or 0) .. " entries"
            end
            table.remove(value, index)
            session.dirty = true
            return true
        end
    end
    return false, "unknown table setting " .. tostring(key)
end

local function flattenFields(value, path, label, result)
    local valueType = type(value)
    if valueType ~= "table" then
        local relativePath = {}
        for index = 2, #path do
            relativePath[#relativePath + 1] = path[index]
        end
        result[#result + 1] = {
            key = path[1],
            path = relativePath,
            label = label,
            value = value,
            type = valueType,
        }
        return
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(first, second)
        if type(first) ~= type(second) then
            return type(first) < type(second)
        end
        return first < second
    end)
    for _, key in ipairs(keys) do
        path[#path + 1] = key
        local suffix = type(key) == "number" and ("[" .. tostring(key) .. "]") or ("." .. tostring(key))
        flattenFields(value[key], path, label .. suffix, result)
        path[#path] = nil
    end
end

function editor.formFields(session)
    local settings, config, module = editor.settings(session)
    if not settings then
        return nil, config
    end
    local fields = {}
    for _, setting in ipairs(settings) do
        if type(setting) == "table" and type(setting.key) == "string" then
            local value = config[setting.key]
            if setting.type == "table" and type(value) == "table" then
                fields[#fields + 1] = {
                    key = setting.key,
                    label = (setting.label or setting.key) .. " entries",
                    value = #value,
                    type = "table-list",
                    minItems = setting.minItems,
                    maxItems = setting.maxItems,
                }
                flattenFields(value, { setting.key }, setting.label or setting.key, fields)
            else
                fields[#fields + 1] = {
                    key = setting.key,
                    label = setting.label or setting.key,
                    value = value,
                    type = setting.type or type(value),
                    choices = setting.choices,
                    step = setting.step,
                    min = setting.min,
                    max = setting.max,
                    tableSetting = setting.type == "table",
                    minItems = setting.minItems,
                    maxItems = setting.maxItems,
                }
            end
        end
    end
    return fields, config, module
end

function editor.settings(session)
    local placement, _, selectionError = findSelected(session)
    if not placement then
        return nil, selectionError
    end
    local module, moduleError = getPanelModule(session, placement.type)
    if not module then
        return nil, moduleError
    end
    local config = copy(placement.config or {})
    for _, setting in ipairs(module.settings or {}) do
        if config[setting.key] == nil then
            config[setting.key] = copy(setting.default)
        end
    end
    return module.settings or {}, config, module
end

function editor.restoreDefault(session, document)
    if type(document) ~= "table" or type(document.panels) ~= "table" then
        return false, "default layout is invalid"
    end
    session.draft = copy(document)
    session.selected = #session.draft.panels > 0 and 1 or 0
    session.dirty = true
    return true
end

function editor.cancel(session)
    session.draft = copy(session.original)
    session.selected = #session.draft.panels > 0 and 1 or 0
    session.dirty = false
    session.errors = {}
    return true
end

--- Validate the entire working copy without dropping bad panels or keys.
function editor.validate(session)
    local document = copy(session.draft)
    local normalized, errors = session.layout.validateDocument(document)
    if not normalized then
        session.errors = errors
        return false, copy(errors)
    end
    if type(document.panels) ~= "table" then
        session.errors = { "panels must be a sequence" }
        return false, copy(session.errors)
    end

    local identifiers, accepted = {}, {}
    for index, placement in ipairs(document.panels) do
        local valid, panelError = session.layout.validatePanel(placement, index, session.grid, accepted, identifiers)
        if not valid then
            errors[#errors + 1] = panelError
        else
            identifiers[placement.id] = true
            accepted[#accepted + 1] = placement
            local module, moduleError = getPanelModule(session, placement.type)
            if not module then
                errors[#errors + 1] = "panel " .. placement.id .. ": " .. moduleError
            else
                if not supportsSpan(module, placement.colSpan, placement.rowSpan) then
                    errors[#errors + 1] = "panel "
                        .. placement.id
                        .. ": unsupported span "
                        .. tostring(placement.colSpan)
                        .. "x"
                        .. tostring(placement.rowSpan)
                end

                local settings, knownConfig, settingErrors = settingsFor(module, placement.config or {})
                for _, settingError in ipairs(settingErrors) do
                    errors[#errors + 1] = "panel " .. placement.id .. ": " .. settingError
                end
                if type(module.validateSettings) == "function" then
                    local ok, reported = pcall(
                        module.validateSettings,
                        settings,
                        { colSpan = placement.colSpan, rowSpan = placement.rowSpan },
                        knownConfig
                    )
                    if not ok then
                        errors[#errors + 1] = "panel "
                            .. placement.id
                            .. ": validateSettings raised: "
                            .. tostring(reported)
                    elseif type(reported) == "table" then
                        for _, message in ipairs(reported) do
                            errors[#errors + 1] = "panel " .. placement.id .. ": " .. tostring(message)
                        end
                    end
                end
            end
        end
    end

    session.errors = errors
    if #errors > 0 then
        return false, copy(errors)
    end
    return true, document
end

function editor.apply(session)
    local valid, result = editor.validate(session)
    if not valid then
        return false, result
    end
    session.original = copy(result)
    session.draft = copy(result)
    session.dirty = false
    session.errors = {}
    return true, copy(result)
end

return editor
