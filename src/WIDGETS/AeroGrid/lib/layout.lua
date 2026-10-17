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

layout.VERSION = 3

function layout.normalizePanel(panel)
    if panel.type == "navigation" and type(panel.config) == "table" then
        -- Former distance thresholds must never become satellite-count limits.
        panel.config.warning = nil
        panel.config.critical = nil
    end
    if panel.type == "rx-battery" and type(panel.config) == "table" then
        -- Schema 2 was unreleased: accept its old selector, but never persist it.
        panel.config.sourceType = nil
        if panel.config.cellWarning == nil then
            panel.config.cellWarning = panel.config.warning
        end
        if panel.config.cellCritical == nil then
            panel.config.cellCritical = panel.config.critical
        end
        panel.config.warning = nil
        panel.config.critical = nil
    end
    return panel
end

local migrations = {
    [2] = {
        header = function() end,
        panel = function(panel)
            if panel.type ~= "navigation" then
                return
            end
            local config = type(panel.config) == "table" and panel.config or {}
            local presentation = config.presentation or "auto"
            local cells = (panel.colSpan or 1) * (panel.rowSpan or 1)
            if config.showTape == nil then
                config.showTape = presentation == "compass"
                    or presentation == "detailed"
                    or (presentation == "auto" and cells >= 4)
            end
            if config.showCoordinates == nil then
                config.showCoordinates = presentation == "detailed" or (presentation == "auto" and cells >= 6)
            end
            config.presentation = nil
            config.showBearing = nil
            panel.config = config
        end,
    },
    [1] = {
        header = function() end,
        panel = function(panel)
            if panel.type == "cell-battery" then
                panel.type = "rx-battery"
                local config = type(panel.config) == "table" and panel.config or {}
                config.lowestSource = nil
                if config.sourceType == nil or config.sourceType == "cells" then
                    config.cells = nil
                end
                if config.reading == "lowest" or config.reading == "average" then
                    config.reading = "cell"
                end
                config.sourceType = nil
                panel.config = config
            end
        end,
    },
}

local function supportedVersion(version)
    if type(version) ~= "number" or version ~= math.floor(version) or version < 1 or version > layout.VERSION then
        return false
    end

    for current = version, layout.VERSION - 1 do
        if type(migrations[current]) ~= "table" then
            return false
        end
    end
    return true
end

layout.supportsVersion = supportedVersion

--- Apply exactly one adjacent header migration step.
---@param document table
---@return boolean migrated
---@return integer|string versionOrError
function layout.migrateHeaderStep(document)
    if type(document) ~= "table" or not supportedVersion(document.version) then
        return false, "unsupported layout version"
    end
    if document.version == layout.VERSION then
        return true, document.version
    end
    local version = document.version
    migrations[version].header(document)
    document.version = version + 1
    return true, document.version
end

--- Apply exactly one adjacent panel migration step.
---@param panel table
---@param sourceVersion integer
---@return boolean migrated
---@return integer|string versionOrError
function layout.migratePanelStep(panel, sourceVersion)
    if type(panel) ~= "table" or not supportedVersion(sourceVersion) then
        return false, "unsupported layout version"
    end
    if sourceVersion == layout.VERSION then
        return true, sourceVersion
    end
    migrations[sourceVersion].panel(panel)
    return true, sourceVersion + 1
end

--- Synchronous convenience for callers that can afford the complete chain.
--- Runtime load and save callbacks use migratePanelStep one step per cycle.
---@param panel table
---@param sourceVersion integer
---@return table panel
function layout.migratePanel(panel, sourceVersion)
    while sourceVersion < layout.VERSION do
        local migrated, nextVersion = layout.migratePanelStep(panel, sourceVersion)
        if not migrated or type(nextVersion) ~= "number" then
            return panel
        end
        sourceVersion = nextVersion
    end
    return panel
end

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
---@return integer? sourceVersion
function layout.validateHeader(document)
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
    local sourceVersion = document.version
    normalized.version = sourceVersion
    normalized.grid = document.grid
    normalized.panels = {}
    if document.theme ~= nil then
        errors[#errors + 1] = "layout-level theme settings are no longer supported; choose a theme in widget settings"
    end
    normalized.session = validateSession(document.session, errors)

    if not supportedVersion(sourceVersion) then
        return nil, { "unsupported layout version" }
    end
    if type(document.grid) ~= "table" or document.grid.columns ~= 4 or document.grid.rows ~= 4 then
        return nil, { "phase 1 requires a 4 x 4 grid" }
    end

    return normalized, errors, sourceVersion
end

--- Finalize a header after its version steps have been applied.
---@param document table
---@return table? header
---@return string[] errors
function layout.finalizeHeader(document)
    if type(document) ~= "table" or document.version ~= layout.VERSION then
        return nil, { "layout header migrations are incomplete" }
    end
    local normalized = {}
    for key, value in pairs(document) do
        normalized[key] = value
    end
    normalized.version = layout.VERSION
    normalized.panels = {}
    return normalized, {}
end

--- Validate a current-version header without applying upgrades in a runtime callback.
---@param document table
---@return table? header
---@return string[] errors
function layout.validateCurrentHeader(document)
    local normalized, errors = layout.validateHeader(document)
    if not normalized then
        return nil, errors
    end
    if normalized.version ~= layout.VERSION then
        return nil, { "layout must be migrated before editing" }
    end
    return normalized, errors
end

--- Synchronous convenience for tests and tools; runtime callbacks step headers.
---@param document table
---@return table? header
---@return string[] errors
---@return integer? sourceVersion
function layout.validateDocument(document)
    local normalized, errors, sourceVersion = layout.validateHeader(document)
    if not normalized then
        return nil, errors
    end
    while normalized.version < layout.VERSION do
        local migrated, migrationError = layout.migrateHeaderStep(normalized)
        if not migrated then
            errors[#errors + 1] = tostring(migrationError)
            return nil, errors
        end
    end
    local finalized, finalErrors = layout.finalizeHeader(normalized)
    for _, message in ipairs(finalErrors or {}) do
        errors[#errors + 1] = message
    end
    return finalized, errors, sourceVersion
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
    layout.normalizePanel(panel)
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
    local normalized, errors, sourceVersion = layout.validateDocument(document)
    if not normalized or not sourceVersion then
        return nil, errors
    end

    if not isSequence(document.panels) then
        errors[#errors + 1] = "panels must be a sequence"
        return normalized, errors
    end

    local identifiers = {}
    for index, panel in ipairs(document.panels) do
        layout.migratePanel(panel, sourceVersion)
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
