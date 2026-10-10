-- SPDX-License-Identifier: GPL-2.0-only

--- AeroGrid schema validation and normalization.

---@class AeroGridLayoutDocument
---@field version integer
---@field grid table
---@field panels table[]

---@class AeroGridValidatedLayout
---@field version integer
---@field grid table
---@field panels table[] Only valid, non-overlapping panels.
--- Unrecognized top-level keys from the source document are preserved verbatim.

local layout = { RUNTIME_API = 1 }

--- Restrict IDs and panel types to path-safe characters.
---@param value any
---@return boolean
local function isSafeIdentifier(value)
    return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

--- Report whether a value is a pure array, so a mapping written where a
--- sequence is required is rejected instead of silently loading nothing.
---@param value any
---@return boolean
local function isSequence(value)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end

    return count == #value
end

--- Validate the optional layout-level flight session block.
---
--- The arm switch bounds one flight, and a dashboard has one flight. It used
--- to be a per-panel setting, which let two panels state different
--- switches; `extremaService:flight` takes the first caller's and ignores the
--- rest, so the second panel's was silently discarded. A setting whose
--- value is thrown away is worse than no setting, because it reads like a
--- choice. It belongs to the layout, which is the thing there is one of.
---@param value any
---@param errors string[]
---@return table? session
local function validateSession(value, errors)
    if value == nil then
        return nil
    end
    if type(value) ~= "table" then
        errors[#errors + 1] = "session must be a mapping"
        return nil
    end

    local result = {}
    if value.armSource ~= nil then
        if type(value.armSource) ~= "string" then
            errors[#errors + 1] = "session armSource must be a string"
        else
            result.armSource = value.armSource
        end
    end

    return result
end

--- Validate the document's own fields, excluding its panels.
--- A document this loader cannot interpret fails closed, because rendering its
--- panels under phase-one assumptions would silently misplace them.
---@param document table
---@return table? header
---@return string[] errors
function layout.validateDocument(document)
    if type(document) ~= "table" then
        return nil, { "layout document must be a table" }
    end

    local errors = {}
    local normalized = {}

    -- Unknown top-level keys are carried through so a newer authoring tool's
    -- additions survive a round trip in memory.
    for key, value in pairs(document) do
        normalized[key] = value
    end
    normalized.version = document.version
    normalized.grid = document.grid
    normalized.panels = {}
    if document.theme ~= nil then
        errors[#errors + 1] = "layout-level theme settings are no longer supported; choose a theme in widget settings"
    end
    normalized.session = validateSession(document.session, errors)

    if document.version ~= 1 then
        return nil, { "unsupported layout version" }
    end
    if type(document.grid) ~= "table" or document.grid.columns ~= 4 or document.grid.rows ~= 4 then
        return nil, { "phase 1 requires a 4 x 4 grid" }
    end

    return normalized, errors
end

--- Validate one panel against the grid and the entries already accepted.
--- Returning the outcome per entry lets the host validate and build panels
--- one at a time, rather than holding the whole layout in one callback.
---@param panel any
---@param index integer Position in the sequence, for error messages.
---@param grid table
---@param accepted table[] Panels already accepted.
---@param identifiers table<string, boolean> Ids already used.
---@return boolean valid
---@return string? error
function layout.validatePanel(panel, index, grid, accepted, identifiers)
    local prefix = "panel " .. index .. ": "

    if type(panel) ~= "table" then
        return false, prefix .. "entry must be a mapping"
    end

    if not isSafeIdentifier(panel.id) then
        return false, prefix .. "invalid id"
    end
    if identifiers[panel.id] then
        return false, prefix .. "duplicate id " .. panel.id
    end
    if not isSafeIdentifier(panel.type) then
        return false, prefix .. "invalid type"
    end

    local placementValid, placementError = grid.validatePlacement(panel, 4, 4)
    if not placementValid then
        return false, prefix .. placementError
    end

    for _, existing in ipairs(accepted) do
        if grid.overlaps(existing, panel) then
            return false, prefix .. "overlaps " .. existing.id
        end
    end

    panel.config = type(panel.config) == "table" and panel.config or {}
    return true
end

--- Validate a parsed phase-one document while retaining valid panels.
--- Invalid panels are reported and omitted so they cannot block the
--- dashboard. The host loads incrementally instead; this remains for callers
--- that can afford to validate a whole document at once.
---@param document AeroGridLayoutDocument
---@param grid table Grid module implementing placement validation and overlap checks.
---@return AeroGridValidatedLayout? layout
---@return string[] errors
function layout.validate(document, grid)
    local normalized, errors = layout.validateDocument(document)
    if not normalized then
        return nil, errors
    end

    if not isSequence(document.panels) then
        errors[#errors + 1] = "panels must be a sequence"
        return normalized, errors
    end

    local identifiers = {}
    for index, panel in ipairs(document.panels) do
        local valid, panelError = layout.validatePanel(panel, index, grid, normalized.panels, identifiers)
        if valid then
            identifiers[panel.id] = true
            normalized.panels[#normalized.panels + 1] = panel
        else
            errors[#errors + 1] = panelError
        end
    end

    return normalized, errors
end

return layout
