-- SPDX-License-Identifier: GPL-2.0-only

--- Component module contract, settings resolution, and isolated lifecycle dispatch.
--- The host owns this contract so an independently authored component file can be
--- loaded, validated, and driven without trusting its implementation.

---@class AeroGridComponentSetting
---@field key string Configuration key read from the layout YAML.
---@field type? "string"|"number"|"boolean"|"table" Rejects mistyped YAML values.
---@field choices? string[] Values this setting accepts; anything else is reported.
---@field default? any Applied when the key is absent, mistyped, or not a choice.

---@class AeroGridComponentModule
---@field id string Must equal the component type name used in YAML.
---@field apiVersion integer Must equal the host component API version.
---@field supportedSpans? string[] Span strings such as "2x1", or "any".
---@field refreshInterval? integer Ticks of 10ms between refreshes. 0 or absent
---  means every frame. Telemetry rarely needs more than a few hertz, and the
---  host pays every component's cost inside one instruction budget.
---@field settings? AeroGridComponentSetting[]
---@field create fun(parent: any, rect: table, settings: table, services: table): any
---@field update? fun(instance: any, rect: table, settings: table)
---@field refresh? fun(instance: any)
---@field background? fun(instance: any)
---@field event? fun(instance: any, event: any): boolean
---@field destroy? fun(instance: any)

---@class AeroGridComponentEntry
---@field placement table Validated YAML component placement.
---@field module AeroGridComponentModule
---@field instance any Component-owned runtime context.
---@field settings table Resolved configuration passed to create.
---@field interval integer Resolved refresh interval in 10ms ticks.
---@field nextRefresh integer Tick at which this component is next due.
---@field failed? boolean Set after a lifecycle failure disables the component.
---@field error? string First lifecycle failure message.

local componentHost = {}

--- Host-side component API version. Modules declaring anything else are rejected.
componentHost.API_VERSION = 1

--- Optional lifecycle callbacks, in a fixed order so errors stay deterministic.
local OPTIONAL_CALLBACKS = { "update", "refresh", "background", "event", "destroy" }

--- Restrict module identifiers to the same path-safe characters as layout types.
---@param value any
---@return boolean
local function isSafeIdentifier(value)
    return type(value) == "string" and string.match(value, "^[%w_-]+$") ~= nil
end

--- Read a contract field without triggering a module's metamethods.
--- A hostile or buggy `__index` must not be able to raise inside the host.
---@param module any
---@param key string
---@return any
local function field(module, key)
    if type(module) ~= "table" then
        return nil
    end

    local ok, value = pcall(rawget, module, key)
    if not ok then
        return nil
    end
    return value
end

--- Verify a loaded module satisfies the component contract.
---@param module any Value returned by the component's Lua chunk.
---@param typeName string Component type requested by the layout.
---@return boolean valid
---@return string? error
function componentHost.validateModule(module, typeName)
    if type(module) ~= "table" then
        return false, "component module must return a table"
    end
    if field(module, "apiVersion") ~= componentHost.API_VERSION then
        return false, "incompatible component API"
    end

    local id = field(module, "id")
    if not isSafeIdentifier(id) then
        return false, "component module declares an invalid id"
    end
    if id ~= typeName then
        return false, "component module id " .. id .. " does not match type " .. typeName
    end
    if type(field(module, "create")) ~= "function" then
        return false, "component has no create function"
    end

    for _, name in ipairs(OPTIONAL_CALLBACKS) do
        local callback = field(module, name)
        if callback ~= nil and type(callback) ~= "function" then
            return false, name .. " must be a function"
        end
    end

    local spans = field(module, "supportedSpans")
    if spans ~= nil and type(spans) ~= "table" then
        return false, "supportedSpans must be a sequence"
    end

    local settings = field(module, "settings")
    if settings ~= nil and type(settings) ~= "table" then
        return false, "settings must be a sequence"
    end

    local interval = field(module, "refreshInterval")
    if interval ~= nil and (type(interval) ~= "number" or interval < 0 or interval ~= math.floor(interval)) then
        return false, "refreshInterval must be a non-negative whole number of ticks"
    end

    return true
end

--- Resolve a module's refresh interval in 10ms ticks.
---@param module AeroGridComponentModule
---@return integer
function componentHost.refreshInterval(module)
    local interval = field(module, "refreshInterval")
    if type(interval) ~= "number" or interval < 0 then
        return 0
    end
    return math.floor(interval)
end

--- Spread components that share an interval across different frames.
--- Without this, every component with the same rate falls due on the same
--- frame and the host pays their whole cost at once. The offset is derived
--- from the component's ordinal so it is deterministic and evenly spread.
---@param interval integer
---@param ordinal integer Position of the component in the layout, from 1.
---@return integer offset Ticks to delay this component's first refresh.
function componentHost.phaseOffset(interval, ordinal)
    if interval <= 1 then
        return 0
    end
    return (ordinal - 1) % interval
end

--- Format a placement span as the string used in supportedSpans declarations.
---@param colSpan integer
---@param rowSpan integer
---@return string
function componentHost.spanName(colSpan, rowSpan)
    return tostring(colSpan) .. "x" .. tostring(rowSpan)
end

--- Report whether a module accepts a grid span.
--- A module without a supportedSpans declaration accepts every span.
---@param module AeroGridComponentModule
---@param colSpan integer
---@param rowSpan integer
---@return boolean
function componentHost.supportsSpan(module, colSpan, rowSpan)
    local spans = module.supportedSpans
    if spans == nil then
        return true
    end

    local wanted = componentHost.spanName(colSpan, rowSpan)
    for _, span in ipairs(spans) do
        if span == "any" or span == wanted then
            return true
        end
    end

    return false
end

--- Merge declared setting defaults over the layout's configuration table.
--- Mistyped values fall back to the default so one bad key cannot break rendering.
---@param module AeroGridComponentModule
---@param config any Raw config mapping from the layout file.
---@return table settings
---@return string[] warnings
function componentHost.resolveSettings(module, config, span)
    local settings = {}
    local warnings = {}
    local declared = {}

    if type(config) == "table" then
        for key, value in pairs(config) do
            settings[key] = value
        end
    end

    for index, setting in ipairs(module.settings or {}) do
        if type(setting) ~= "table" or type(setting.key) ~= "string" then
            warnings[#warnings + 1] = "setting " .. index .. " is malformed"
        else
            declared[setting.key] = setting
            local current = settings[setting.key]
            if current == nil then
                settings[setting.key] = setting.default
            elseif setting.type ~= nil and type(current) ~= setting.type then
                warnings[#warnings + 1] = setting.key .. " must be a " .. tostring(setting.type)
                settings[setting.key] = setting.default
            elseif setting.choices ~= nil then
                -- A choice the component does not offer is a typo, and a typo that
                -- falls back silently is one nobody finds: `presentation: nonsense`
                -- used to load, render the default, and report nothing. The layout is
                -- authored by hand in a text editor, so this is the only check it
                -- gets.
                local allowed = false
                for _, choice in ipairs(setting.choices) do
                    if choice == current then
                        allowed = true
                        break
                    end
                end
                if not allowed then
                    warnings[#warnings + 1] = setting.key
                        .. " must be one of "
                        .. table.concat(setting.choices, ", ")
                        .. ", not "
                        .. tostring(current)
                    settings[setting.key] = setting.default
                end
            end
        end
    end

    -- A key the component does not declare is almost always a misspelling of
    -- one it does, or a key left behind by a rename. Unknown keys are still
    -- kept, because a layout written for a newer component must not be
    -- destroyed by an older host, but they are reported rather than ignored:
    -- silence here is how a renamed setting survives a whole repository of
    -- layouts and only shows up on a radio.
    if type(config) == "table" then
        for key in pairs(config) do
            if not declared[key] and not string.match(key, "Name$") then
                warnings[#warnings + 1] = key .. " is not a setting of this component"
            end
        end
    end

    -- A rule that spans two settings cannot be expressed per setting, so a
    -- component may state one itself. `choices` catches a value that is wrong
    -- on its own; this catches a pair that is wrong together, which is the only
    -- kind of authoring mistake the schema cannot see.
    --
    -- The placement's span is offered alongside, because some settings are only
    -- meaningless at a particular size: `flight-mode`'s mode number needs a
    -- supporting row and no single-row span has one, however wide.
    --
    -- And the layout's own config, because "did the author ask for this" is a
    -- different question from "what is this set to". A setting that defaults to
    -- true and cannot apply at this span is the panel shedding a row, which is
    -- normal; the same setting *stated* by a layout that then gets nothing is a
    -- request being ignored. Only the second is worth complaining about, and by
    -- this point `settings` has been filled from the defaults and can no longer
    -- tell them apart.
    if type(rawget(module, "validateSettings")) == "function" then
        local ok, reported = pcall(module.validateSettings, settings, span, config)
        if not ok then
            warnings[#warnings + 1] = "validateSettings raised: " .. tostring(reported)
        elseif type(reported) == "table" then
            for _, message in ipairs(reported) do
                warnings[#warnings + 1] = tostring(message)
            end
        end
    end

    return settings, warnings
end

--- Invoke one lifecycle callback under pcall.
--- The first failure permanently disables that component so a broken module
--- cannot repeatedly raise errors or take down the surrounding dashboard.
---@param entry AeroGridComponentEntry
---@param event string Optional callback name such as "refresh".
---@param ... any Additional callback arguments.
---@return boolean ok
---@return string? error Set only on the call that first fails.
---@return any result First value returned by the callback.
function componentHost.dispatch(entry, event, ...)
    if type(entry) ~= "table" or entry.failed then
        return false
    end

    local callback = field(entry.module, event)
    if type(callback) ~= "function" then
        return true
    end

    local ok, resultOrError = pcall(callback, entry.instance, ...)
    if ok then
        return true, nil, resultOrError
    end

    entry.failed = true
    entry.error = tostring(resultOrError)
    return false, entry.error
end

return componentHost
