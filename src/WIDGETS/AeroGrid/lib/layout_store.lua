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

--- The always-blank layout. It is never written, so new screens start empty.
layoutStore.EMPTY = "Empty"

--- Longest layout name accepted from the editor.
layoutStore.NAME_LIMIT = 24

local function directory(path)
    return string.sub(path, -1) == "/" and path or path .. "/"
end

--- SD-card root that holds the widget directory.
--- `/WIDGETS/AeroGrid/` yields `/`; any other location yields the widget
--- directory itself, which keeps test copies self-contained.
---@param widgetPath string
---@return string
function layoutStore.sdRoot(widgetPath)
    local base = directory(widgetPath)
    return string.match(base, "^(.*/)WIDGETS/[^/]+/$") or base
end

--- Directory of user layouts, kept outside the widget so updates leave it alone.
---@param widgetPath string
---@return string
function layoutStore.userDirectory(widgetPath)
    return layoutStore.sdRoot(widgetPath) .. "AEROGRID/layouts/"
end

--- Whether a layout name names the reserved blank layout.
---@param name any
---@return boolean
function layoutStore.isEmpty(name)
    return name == nil or name == "" or string.lower(tostring(name)) == string.lower(layoutStore.EMPTY)
end

--- Check a layout name typed in the editor.
---@param name any
---@return boolean ok
---@return string? error
function layoutStore.validName(name)
    if type(name) ~= "string" or name == "" then
        return false, "Enter a layout name"
    end
    if #name > layoutStore.NAME_LIMIT then
        return false, "Use at most " .. layoutStore.NAME_LIMIT .. " characters"
    end
    if not string.match(name, "^[%w_-]+$") then
        return false, "Use only letters, digits, - and _"
    end
    if layoutStore.isEmpty(name) then
        return false, layoutStore.EMPTY .. " is reserved"
    end
    return true
end

--- Resolve the user YAML filename that Save writes for a layout name.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param name string Layout name selected in the native widget settings.
---@return string
function layoutStore.path(widgetPath, name)
    return layoutStore.userDirectory(widgetPath) .. sanitize(name) .. ".yaml"
end

--- Whether a user or shipped layout already uses this name.
---@param widgetPath string
---@param name string
---@return boolean
function layoutStore.exists(widgetPath, name)
    local stat = fstat
    if type(stat) ~= "function" then
        return false
    end
    return stat(layoutStore.path(widgetPath, name)) ~= nil
        or stat(directory(widgetPath) .. "layouts/" .. sanitize(name) .. ".yaml") ~= nil
end

--- Suggest `<model><N>` with the first number no layout uses yet.
---@param widgetPath string
---@param modelName any
---@return string
function layoutStore.suggestName(widgetPath, modelName)
    local base = string.gsub(tostring(modelName or ""), "[^%w_-]+", "-")
    base = string.gsub(string.gsub(base, "^%-+", ""), "%-+$", "")
    if base == "" then
        base = "Layout"
    end
    for number = 1, 999 do
        local suffix = tostring(number)
        local name = string.sub(base, 1, layoutStore.NAME_LIMIT - #suffix) .. suffix
        if not layoutStore.exists(widgetPath, name) then
            return name
        end
    end
    return string.sub(base, 1, layoutStore.NAME_LIMIT - 4) .. "1000"
end

--- Return layout paths in recovery order, including the previous committed copy.
--- A user layout and its backup come first, then the shipped layout of that
--- name, then the shipped default. Empty is never written, so it has no user
--- candidates.
---@param widgetPath string
---@param name string Layout name selected in the native widget settings.
---@return table[]
function layoutStore.candidates(widgetPath, name)
    local base = directory(widgetPath)
    local shippedPath = base .. "layouts/" .. sanitize(name) .. ".yaml"
    local defaultPath = base .. "layouts/default.yaml"
    local paths = {}
    if not layoutStore.isEmpty(name) then
        local userPath = layoutStore.path(widgetPath, name)
        paths[#paths + 1] = { filename = userPath, origin = "user" }
        paths[#paths + 1] = { filename = userPath .. ".bak", origin = "user-backup" }
    else
        shippedPath = base .. "layouts/" .. layoutStore.EMPTY .. ".yaml"
    end
    paths[#paths + 1] = { filename = shippedPath, origin = "shipped" }
    paths[#paths + 1] = { filename = defaultPath, origin = "default" }
    paths[#paths + 1] = { filename = defaultPath .. ".bak", origin = "default-backup" }
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
---@param name string
---@return string? content
---@return string? error
---@return string filename
---@return string origin
---@return table[] candidates
function layoutStore.readCandidates(widgetPath, name)
    local candidates = layoutStore.candidates(widgetPath, name)
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
--- Candidates are tried in order: the user layout of that name, the shipped
--- layout of that name, and the shipped default.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param name string Layout name selected in the native widget settings.
---@return string? content
---@return string? error
---@return string filename
---@return string origin One of `user`, `shipped`, `default`, or `none`.
function layoutStore.read(widgetPath, name)
    return layoutStore.readCandidates(widgetPath, name)
end

--- Read, parse, and validate a layout, falling back to default.yaml.
--- Retained for tests and callers that can afford the whole cost at once.
---@param widgetPath string Absolute AeroGrid widget directory.
---@param name string Layout name selected in the native widget settings.
---@param yaml table YAML module implementing parse.
---@param layout table Layout module implementing validate.
---@param grid table Grid module used during validation.
---@return table? document
---@return string[] errors
---@return string filename Selected specific or fallback layout path.
function layoutStore.load(widgetPath, name, yaml, layout, grid)
    local candidates = layoutStore.candidates(widgetPath, name)
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
            mkdir = _G.mkdir,
        }
    for _, name in ipairs({ "open", "read", "write", "close", "rename", "remove", "stat" }) do
        if type(operations[name]) ~= "function" then
            return false, "file operation unavailable: " .. name, filename
        end
    end

    -- The user directory does not exist on a fresh card. `mkdir` reports an
    -- existing directory as an error, so the result is ignored and the open
    -- below decides.
    if type(operations.mkdir) == "function" then
        local parent = ""
        for segment in string.gmatch(string.match(filename, "^(.*)/[^/]*$") or "", "[^/]+") do
            parent = parent .. "/" .. segment
            if not operations.stat(parent) then
                operations.mkdir(parent)
            end
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
function layoutStore.save(widgetPath, name, document, yaml, layout, grid, fileOps)
    local filename = layoutStore.path(widgetPath, name)
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
function layoutStore.startSave(widgetPath, name, document, yaml, layout, grid, fileOps)
    return {
        filename = layoutStore.path(widgetPath, name),
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
