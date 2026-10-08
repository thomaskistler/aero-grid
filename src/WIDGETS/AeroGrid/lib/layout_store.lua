-- SPDX-License-Identifier: GPL-2.0-only

--- Layout path resolution and validated, recoverable persistence.

local layoutStore = { RUNTIME_API = 1 }

--- Produce a stable four-hex-digit suffix for normalized identifiers.
---@param value string
---@return string
local function shortHash(value)
    local hash = 0
    for index = 1, #value do
        hash = (hash * 33 + string.byte(value, index)) % 65536
    end
    return string.format("%04x", hash)
end

--- Convert a model or dashboard identifier into a safe filename segment.
---@param value any
---@return string
local function sanitize(value)
    local original = string.gsub(tostring(value or ""), "%.[^%.]+$", "")
    local sanitized = original
    sanitized = string.gsub(sanitized, "[^%w_-]", "-")
    sanitized = string.gsub(sanitized, "%-+", "-")
    sanitized = string.gsub(sanitized, "^%-", "")
    sanitized = string.gsub(sanitized, "%-$", "")
    if sanitized == "" then
        return "default"
    end
    if sanitized ~= original then
        sanitized = sanitized .. "-" .. shortHash(original)
    end
    return sanitized
end

--- Read a complete file through EdgeTX's reduced file API.
---@param filename string
---@return string? content
---@return string? error
local function readFile(filename, fileOps)
    local stat = fileOps and fileOps.stat or fstat
    local open = fileOps and fileOps.open or io.open
    local read = fileOps and fileOps.read or io.read
    local close = fileOps and fileOps.close or io.close
    local info = stat(filename)
    local fileSize = type(info) == "table" and info["size"] or nil
    if not fileSize then
        return nil, "file not found: " .. filename
    end

    local handle, openError = open(filename, "r")
    if not handle then
        return nil, openError or ("cannot open: " .. filename)
    end

    -- EdgeTX exposes io.read(handle, size), unlike the standard Lua io.read API.
    ---@diagnostic disable-next-line: param-type-mismatch
    local content = read(handle, fileSize)
    close(handle)
    if content == nil then
        return nil, "cannot read: " .. filename
    end

    return content
end

--- Resolve the model- and dashboard-specific YAML filename.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param modelFilename string Current EdgeTX model filename.
---@param dashboardId string Native Dashboard ID option.
---@return string
function layoutStore.path(widgetPath, modelFilename, dashboardId)
    local base = widgetPath
    if string.sub(base, -1) ~= "/" then
        base = base .. "/"
    end
    return base .. "layouts/" .. sanitize(modelFilename) .. "--" .. sanitize(dashboardId) .. ".yaml"
end

--- Return layout paths in recovery order, including the previous committed copy.
---@param widgetPath string
---@param modelFilename string
---@param dashboardId string
---@return table[]
function layoutStore.candidates(widgetPath, modelFilename, dashboardId)
    local base = string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/"
    local modelPath = layoutStore.path(widgetPath, modelFilename, dashboardId)
    local sharedPath = base .. "layouts/" .. sanitize(dashboardId) .. ".yaml"
    local defaultPath = base .. "layouts/default.yaml"
    local paths = {
        { filename = modelPath, origin = "model" },
        { filename = modelPath .. ".bak", origin = "model-backup" },
        { filename = sharedPath, origin = "dashboard" },
        { filename = sharedPath .. ".bak", origin = "dashboard-backup" },
        { filename = defaultPath, origin = "default" },
        { filename = defaultPath .. ".bak", origin = "default-backup" },
    }
    local seen = {}
    local unique = {}
    for _, candidate in ipairs(paths) do
        if not seen[candidate.filename] then
            seen[candidate.filename] = true
            unique[#unique + 1] = candidate
        end
    end
    return unique
end

function layoutStore.readCandidate(filename)
    return readFile(filename)
end

--- Read the first existing primary, backup, shared, or shipped default file.
---@param widgetPath string
---@param modelFilename string
---@param dashboardId string
---@return string? content
---@return string? error
---@return string filename
---@return string origin
---@return table[] candidates
function layoutStore.readCandidates(widgetPath, modelFilename, dashboardId)
    local candidates = layoutStore.candidates(widgetPath, modelFilename, dashboardId)
    local lastError
    for _, candidate in ipairs(candidates) do
        local content, readError = readFile(candidate.filename)
        if content then
            return content, nil, candidate.filename, candidate.origin, candidates
        end
        lastError = readError
    end
    local fallback = candidates[#candidates - 1]
    return nil, lastError, fallback and fallback.filename or "", "none", candidates
end

--- Resolve and read the layout file, without parsing it.
--- Reading, tokenizing, parsing, and validating are separate steps so the host
--- can spend one widget callback on each and stay inside EdgeTX's budget.
---
--- Three candidates are tried in order: the model- and dashboard-specific
--- layout, a dashboard-specific layout shared by every model, and the shipped
--- default. The middle candidate is what makes a layout such as the bundled
--- service diagnostics usable on any model simply by naming its Dashboard ID.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param modelFilename string Current EdgeTX model filename.
---@param dashboardId string Native Dashboard ID option.
---@return string? content
---@return string? error
---@return string filename
---@return string origin One of `model`, `dashboard`, `default`, or `none`. Selected specific or fallback layout path.
function layoutStore.read(widgetPath, modelFilename, dashboardId)
    return layoutStore.readCandidates(widgetPath, modelFilename, dashboardId)
end

--- Read, parse, and validate a layout, falling back to default.yaml.
--- Retained for tests and callers that can afford the whole cost at once.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param modelFilename string Current EdgeTX model filename.
---@param dashboardId string Native Dashboard ID option.
---@param yaml table YAML module implementing parse.
---@param layout table Layout module implementing validate.
---@param grid table Grid module used during validation.
---@return table? document
---@return string[] errors
---@return string filename Selected specific or fallback layout path.
function layoutStore.load(widgetPath, modelFilename, dashboardId, yaml, layout, grid)
    local candidates = layoutStore.candidates(widgetPath, modelFilename, dashboardId)
    local lastErrors = {}
    for _, candidate in ipairs(candidates) do
        local content, readError = readFile(candidate.filename)
        if content then
            local document, parseError = yaml.parse(content)
            if document then
                local normalized, validationErrors = layout.validate(document, grid)
                if normalized and #validationErrors == 0 then
                    return normalized, validationErrors, candidate.filename, candidate.origin
                end
                lastErrors = validationErrors
            else
                lastErrors = { parseError }
            end
        else
            lastErrors = { readError }
        end
    end
    local fallback = candidates[#candidates - 1]
    return nil, lastErrors, fallback and fallback.filename or "", "none"
end

--- Load the shipped default layout, falling back to its last committed backup.
function layoutStore.loadDefault(widgetPath, yaml, layout, grid)
    local base = string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/"
    local candidates = {
        base .. "layouts/default.yaml",
        base .. "layouts/default.yaml.bak",
    }
    local lastErrors = {}
    for _, filename in ipairs(candidates) do
        local content, readError = readFile(filename)
        if content then
            local document, parseError = yaml.parse(content)
            if document then
                local normalized, errors = layout.validate(document, grid)
                if normalized and #errors == 0 then
                    return normalized, nil, filename
                end
                lastErrors = errors
            else
                lastErrors = { parseError }
            end
        else
            lastErrors = { readError }
        end
    end
    return nil, lastErrors, candidates[1]
end

--- Install prevalidated content only after a byte-for-byte readback check.
local function persistSerialized(filename, serialized, fileOps)
    local function radioOperation(operation)
        if type(operation) ~= "function" then
            return nil
        end
        return function(...)
            local result = operation(...)
            if result == 0 then
                return true
            end
            return false, "filesystem error " .. tostring(result)
        end
    end
    local operations = fileOps
        or {
            open = io.open,
            read = io.read,
            write = io.write,
            close = io.close,
            rename = radioOperation(_G.rename) or (os and os.rename),
            remove = radioOperation(_G.del) or (os and os.remove),
            stat = fstat,
        }
    for _, name in ipairs({ "open", "read", "write", "close", "rename", "remove", "stat" }) do
        if type(operations[name]) ~= "function" then
            return false, "file operation unavailable: " .. name, filename
        end
    end

    local temporary = filename .. ".tmp"
    local backup = filename .. ".bak"
    local handle, openError = operations.open(temporary, "w")
    if not handle then
        return false, openError or ("cannot open temporary layout: " .. temporary), filename
    end
    local writeOk, writeError = operations.write(handle, serialized)
    local closeOk, closeError = operations.close(handle)
    if not writeOk or writeError then
        operations.remove(temporary)
        return false, writeError or "cannot write temporary layout", filename
    end
    if closeOk == false or closeError then
        operations.remove(temporary)
        return false, closeError or "cannot close temporary layout", filename
    end

    local temporaryContent, temporaryError = readFile(temporary, operations)
    if not temporaryContent then
        operations.remove(temporary)
        return false, temporaryError or "cannot verify temporary layout", filename
    end
    if temporaryContent ~= serialized then
        operations.remove(temporary)
        return false, "temporary layout differs from validated content", filename
    end

    if operations.stat(filename) then
        if operations.stat(backup) then
            local removed, removeError = operations.remove(backup)
            if not removed then
                operations.remove(temporary)
                return false, removeError or "cannot replace layout backup", filename
            end
        end
        local rotated, rotateError = operations.rename(filename, backup)
        if not rotated then
            operations.remove(temporary)
            return false, rotateError or "cannot preserve previous layout", filename
        end
    end

    local committed, commitError = operations.rename(temporary, filename)
    if not committed then
        return false, commitError or "cannot install validated layout", filename
    end
    return true, nil, filename
end

--- Synchronous save for callers that do not need staged callback budgets.
function layoutStore.save(widgetPath, modelFilename, dashboardId, document, yaml, layout, grid, fileOps)
    local filename = layoutStore.path(widgetPath, modelFilename, dashboardId)
    local serialized, serializeError = yaml.serialize(document)
    if not serialized then
        return false, serializeError, filename
    end
    local parsed, parseError = yaml.parse(serialized)
    if not parsed then
        return false, "serialized layout could not be parsed: " .. tostring(parseError), filename
    end
    local validated, validationErrors = layout.validate(parsed, grid)
    if not validated or #validationErrors > 0 then
        return false, "serialized layout failed validation: " .. table.concat(validationErrors, "; "), filename
    end
    return persistSerialized(filename, serialized, fileOps)
end

--- Build and verify one panel per callback before atomically installing the file.
function layoutStore.startSave(widgetPath, modelFilename, dashboardId, document, yaml, layout, grid, fileOps)
    return {
        filename = layoutStore.path(widgetPath, modelFilename, dashboardId),
        document = document,
        yaml = yaml,
        layout = layout,
        grid = grid,
        operations = fileOps,
        index = 0,
        parts = {},
        accepted = {},
        identifiers = {},
    }
end

function layoutStore.advanceSave(state)
    local yaml, layout, grid = state.yaml, state.layout, state.grid
    if state.index == 0 then
        local header = {}
        for key, value in pairs(state.document) do
            if key ~= "panels" then
                header[key] = value
            end
        end
        local text, encodeError = yaml.serialize(header)
        if not text then
            return true, false, encodeError
        end
        local parsed, parseError = yaml.parse(text)
        if not parsed then
            return true, false, parseError
        end
        parsed.panels = {}
        local valid, validationErrors = layout.validateDocument(parsed)
        if not valid then
            return true, false, table.concat(validationErrors, "; ")
        end
        state.parts[1] = text
        state.parts[2] = #state.document.panels == 0 and "panels: {}\n" or "panels:\n"
        state.index = 1
    elseif state.index <= #state.document.panels then
        local text, encodeError = yaml.serialize({ panels = { state.document.panels[state.index] } })
        if not text then
            return true, false, encodeError
        end
        local parsed, parseError = yaml.parse(text)
        if not parsed then
            return true, false, parseError
        end
        local panel = parsed.panels[1]
        local valid, panelError = layout.validatePanel(panel, state.index, grid, state.accepted, state.identifiers)
        if not valid then
            return true, false, panelError
        end
        state.accepted[#state.accepted + 1] = panel
        state.identifiers[panel.id] = true
        state.parts[#state.parts + 1] = string.sub(text, #"panels:\n" + 1)
        state.index = state.index + 1
    else
        local saved, saveError = persistSerialized(state.filename, table.concat(state.parts), state.operations)
        return true, saved, saveError
    end
    return false
end

return layoutStore
