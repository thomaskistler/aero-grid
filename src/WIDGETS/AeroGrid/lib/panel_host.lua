-- SPDX-License-Identifier: GPL-2.0-only

--- Panel module contract, settings resolution, and isolated lifecycle dispatch.
--- The host owns this contract so an independently authored panel file can be
--- loaded, validated, and driven without trusting its implementation.

---@class AeroGridPanelSetting
---@field key string Configuration key read from the layout YAML.
---@field type? "string"|"number"|"boolean"|"table" Rejects mistyped YAML values.
---@field choices? string[] Values this setting accepts; anything else is reported.
---@field default? any Applied when the key is absent, mistyped, or not a choice.

---@class AeroGridPanelModule
---@field id string Must equal the panel type name used in YAML.
---@field apiVersion integer Must equal the host panel API version.
---@field supportedSpans? string[] Span strings such as "2x1", or "any".
---@field refreshInterval? integer Ticks of 10ms between refreshes. 0 or absent
---  means every frame. Telemetry rarely needs more than a few hertz, and the
---  host pays every panel's cost inside one instruction budget.
---@field refreshCost? integer Host refresh slots consumed, 1 to 6; defaults to 1.
---@field settings? AeroGridPanelSetting[]
---@field validateSettings? fun(settings: table, span?: table, config?: table, modelArmed?: string): table
---@field beginSettingsValidation? fun(settings: table, span?: table, config?: table, modelArmed?: string): table
---@field advanceSettingsValidation? fun(work: table): boolean One validation unit; work.warnings holds the final result.
---@field create fun(parent: any, rect: table, settings: table, services: table): any
---@field construct? fun(instance: any, rect: table): boolean Finish one staged construction step; true when ready.
---@field update? fun(instance: any, rect: table, settings: table)
---@field reflow? fun(instance: any, rect: table, settings: table, services: table?, placement: table?, begin: boolean): boolean One geometry stage; begin restarts, true completes.
---@field refresh? fun(instance: any)
---@field decl? table Scheduler declaration for a migrated panel.
---@field idle? boolean Explicitly declares no periodic refresh or background work.
---@field step? fun(instance: any, grant: integer, stage: string, now: integer): integer?, boolean?
---@field stageOf? fun(instance: any): string, integer?
--- A numeric refresh result selects the next interval in 10ms ticks.
--- A second result of true requests consecutive turns until this update finishes.
---@field background? fun(instance: any)
---@field resetSession? fun(instance: any, now: integer) Second result true requests another reset turn.
---@field event? fun(instance: any, event: any): boolean
---@field destroy? fun(instance: any)

---@class AeroGridPanelEntry
---@field placement table Validated YAML panel placement.
---@field module AeroGridPanelModule
---@field instance any Panel-owned runtime context.
---@field settings table Resolved configuration passed to create.
---@field interval integer Resolved refresh interval in 10ms ticks.
---@field nextRefresh integer Tick at which this panel is next due.
---@field failed? boolean Set after a lifecycle failure disables the panel.
---@field error? string First lifecycle failure message.

local panelHost = { RUNTIME_API = 1 }

--- Host-side panel API version. Modules declaring anything else are rejected.
panelHost.API_VERSION = 1

--- Optional lifecycle callbacks, in a fixed order so errors stay deterministic.
local OPTIONAL_CALLBACKS =
    { "construct", "update", "reflow", "refresh", "step", "stageOf", "background", "resetSession", "event", "destroy" }

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

function panelHost.isIdle(module)
    return type(module) == "table"
        and rawget(module, "idle") == true
        and rawget(module, "decl") == nil
        and rawget(module, "refresh") == nil
        and rawget(module, "step") == nil
        and rawget(module, "stageOf") == nil
        and rawget(module, "background") == nil
end

--- Verify a loaded module satisfies the panel contract.
---@param module any Value returned by the panel's Lua chunk.
---@param typeName string Panel type requested by the layout.
---@return boolean valid
---@return string? error
function panelHost.validateModule(module, typeName)
    if type(module) ~= "table" then
        return false, "panel module must return a table"
    end
    if field(module, "apiVersion") ~= panelHost.API_VERSION then
        return false, "incompatible panel API"
    end

    local id = field(module, "id")
    if not isSafeIdentifier(id) then
        return false, "panel module declares an invalid id"
    end
    if id ~= typeName then
        return false, "panel module id " .. id .. " does not match type " .. typeName
    end
    if type(field(module, "create")) ~= "function" then
        return false, "panel has no create function"
    end

    for _, name in ipairs(OPTIONAL_CALLBACKS) do
        local callback = field(module, name)
        if callback ~= nil and type(callback) ~= "function" then
            return false, name .. " must be a function"
        end
        local idle = field(module, "idle")
        if idle ~= nil and type(idle) ~= "boolean" then
            return false, "idle must be a boolean"
        elseif idle and not panelHost.isIdle(module) then
            return false, "an idle panel cannot declare periodic work"
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
    local cost = field(module, "refreshCost")
    if cost ~= nil and (type(cost) ~= "number" or cost < 1 or cost > 6 or cost ~= math.floor(cost)) then
        return false, "refreshCost must be a whole number from 1 to 6"
    end

    return true
end

--- Resolve a module's refresh interval in 10ms ticks.
---@param module AeroGridPanelModule
---@return integer
function panelHost.refreshInterval(module)
    local interval = field(module, "refreshInterval")
    if type(interval) ~= "number" or interval < 0 then
        return 0
    end
    return math.floor(interval)
end

--- Spread panels that share an interval across different frames.
--- Without this, every panel with the same rate falls due on the same
--- frame and the host pays their whole cost at once. The offset is derived
--- from the panel's ordinal so it is deterministic and evenly spread.
---@param interval integer
---@param ordinal integer Position of the panel in the layout, from 1.
---@return integer offset Ticks to delay this panel's first refresh.
function panelHost.phaseOffset(interval, ordinal)
    if interval <= 1 then
        return 0
    end
    return (ordinal - 1) % interval
end

--- Format a placement span as the string used in supportedSpans declarations.
---@param colSpan integer
---@param rowSpan integer
---@return string
function panelHost.spanName(colSpan, rowSpan)
    return tostring(colSpan) .. "x" .. tostring(rowSpan)
end

--- Report whether a module accepts a grid span.
--- A module without a supportedSpans declaration accepts every span.
---@param module AeroGridPanelModule
---@param colSpan integer
---@param rowSpan integer
---@return boolean
function panelHost.supportsSpan(module, colSpan, rowSpan)
    local work = panelHost.beginSpanCheck(module, colSpan, rowSpan)
    while not panelHost.advanceSpanCheck(work) do
    end
    return work.supported
end

function panelHost.beginSpanCheck(module, colSpan, rowSpan)
    return { spans = module.supportedSpans, wanted = panelHost.spanName(colSpan, rowSpan), index = 1 }
end

function panelHost.advanceSpanCheck(work)
    local span = work.spans and work.spans[work.index]
    if not work.spans or span == "any" or span == work.wanted then
        work.supported = true
        return true
    elseif span == nil then
        work.supported = false
        return true
    end
    work.index = work.index + 1
    return false
end

function panelHost.beginSettings(module, config, span, modelArmed)
    local work = {
        module = module,
        config = config,
        span = span,
        modelArmed = modelArmed,
        settings = {},
        warnings = {},
        declared = {},
        phase = "copy",
        index = 1,
    }
    if type(config) == "table" then
        work.iterator, work.state, work.key = pairs(config)
    end
    return work
end

local function validationFailed(work, message)
    work.warnings[#work.warnings + 1] = "validateSettings raised: " .. tostring(message)
    work.phase = "done"
end

local function advanceSettingsUnit(work)
    local settings, warnings = work.settings, work.warnings
    local module, config = work.module, work.config
    if work.phase == "copy" or work.phase == "unknown" then
        local key, value
        if work.iterator then
            key, value = work.iterator(work.state, work.key)
        end
        work.key = key
        if key == nil then
            if work.phase == "copy" then
                work.phase = "declare"
            else
                work.phase = "validate"
            end
        elseif work.phase == "copy" then
            settings[key] = value
        elseif not work.declared[key] then
            warnings[#warnings + 1] = key .. " is not a setting of this panel"
        end
    elseif work.phase == "declare" then
        local index = work.index
        local setting = (module.settings or {})[index]
        if setting == nil then
            if type(config) == "table" then
                work.iterator, work.state, work.key = pairs(config)
            end
            work.phase = "unknown"
            return
        end
        work.index = index + 1
        if type(setting) ~= "table" or type(setting.key) ~= "string" then
            warnings[#warnings + 1] = "setting " .. index .. " is malformed"
        else
            work.declared[setting.key] = setting
            local current = settings[setting.key]
            if current == nil then
                settings[setting.key] = setting.default
            elseif setting.type ~= nil and type(current) ~= setting.type then
                warnings[#warnings + 1] = setting.key .. " must be a " .. tostring(setting.type)
                settings[setting.key] = setting.default
            elseif setting.choices ~= nil then
                work.setting, work.choice, work.phase = setting, 1, "choice"
            end
        end
    elseif work.phase == "choice" then
        local setting = work.setting
        local choice = setting.choices[work.choice]
        if choice == settings[setting.key] then
            work.phase = "declare"
        elseif choice == nil then
            warnings[#warnings + 1] = setting.key
                .. " must be one of "
                .. table.concat(setting.choices, ", ")
                .. ", not "
                .. tostring(settings[setting.key])
            settings[setting.key] = setting.default
            work.phase = "declare"
        else
            work.choice = work.choice + 1
        end
    elseif work.phase == "validate" then
        if type(rawget(module, "validateSettings")) ~= "function" then
            work.phase = "done"
            return
        end
        local staged = type(rawget(module, "beginSettingsValidation")) == "function"
            and type(rawget(module, "advanceSettingsValidation")) == "function"
        local ok, reported = pcall(
            staged and module.beginSettingsValidation or module.validateSettings,
            settings,
            work.span,
            config,
            work.modelArmed
        )
        if not ok then
            validationFailed(work, reported)
        elseif staged then
            if type(reported) ~= "table" then
                validationFailed(work, "beginSettingsValidation must return a table")
            else
                work.validation, work.phase = reported, "validation"
            end
        else
            work.reported, work.index, work.phase = reported, 1, "reported"
        end
    elseif work.phase == "validation" then
        local ok, done = pcall(module.advanceSettingsValidation, work.validation)
        if not ok then
            validationFailed(work, done)
        elseif type(done) ~= "boolean" then
            validationFailed(work, "advanceSettingsValidation must return a boolean")
        elseif done then
            work.reported, work.index, work.phase = work.validation.warnings, 1, "reported"
        end
    elseif work.phase == "reported" then
        local message
        if type(work.reported) == "table" then
            message = work.reported[work.index]
        end
        if message ~= nil then
            warnings[#warnings + 1] = tostring(message)
            work.index = work.index + 1
        else
            work.phase = "done"
            if type(work.reported) == "table" then
                work.proof = { settings = settings, validator = module.validateSettings, warnings = work.reported }
            end
        end
    end
end

--- Each unit copies one key, checks one declaration/choice, or advances one
--- panel validation step. Legacy validators remain explicitly unmeasured.
function panelHost.advanceSettings(work)
    for _ = 1, 8 do
        if work.phase == "done" then
            return true
        end
        advanceSettingsUnit(work)
    end
    return work.phase == "done"
end

--- Preserve unknown keys and nested values; apply defaults and report warnings
--- using the same resolution steps as the staged loader.
---@return table settings
---@return string[] warnings
function panelHost.resolveSettings(module, config, span, modelArmed)
    local work = panelHost.beginSettings(module, config, span, modelArmed)
    while not panelHost.advanceSettings(work) do
    end
    return work.settings, work.warnings
end

--- Invoke one lifecycle callback under pcall.
--- The first failure permanently disables that panel so a broken module
--- cannot repeatedly raise errors or take down the surrounding dashboard.
---@param entry AeroGridPanelEntry
---@param event string Optional callback name such as "refresh".
---@param ... any Additional callback arguments.
---@return boolean ok
---@return string? error Set only on the call that first fails.
---@return any result First value returned by the callback.
---@return boolean? unfinished Whether this staged refresh needs another turn.
function panelHost.dispatch(entry, event, ...)
    if type(entry) ~= "table" or entry.failed then
        return false
    end

    local callback = field(entry.module, event)
    if type(callback) ~= "function" then
        return true
    end

    local ok, resultOrError, unfinished = pcall(callback, entry.instance, ...)
    if ok and event == "reflow" and type(resultOrError) ~= "boolean" then
        ok, resultOrError = false, "reflow must return a boolean"
    elseif ok and (event == "refresh" or event == "step") and type(resultOrError) == "number" then
        if resultOrError < 1 or resultOrError > 6000 or resultOrError ~= math.floor(resultOrError) then
            ok, resultOrError = false, "refresh interval must be a whole number from 1 to 6000 ticks"
        else
            entry.interval = resultOrError
        end
    end
    if ok then
        return true, nil, resultOrError, unfinished
    end

    entry.failed = true
    entry.error = tostring(resultOrError)
    return false, entry.error
end

--- One task per placement, not per panel type. The scheduler reports failures at
--- the next callback head, including invalid refresh intervals.
---@param entry AeroGridPanelEntry
---@return table
function panelHost.task(entry)
    assert(not field(entry.module, "idle"), "an idle panel has no task")
    assert(type(entry.module.decl) == "table", "panel has no task declaration")
    assert(type(entry.module.step) == "function", "panel has no task step")
    assert(type(entry.instance) == "table", "panel has no task instance")
    local task = {
        entry = entry,
        decl = entry.module.decl,
        stage = entry.module.decl.first or "run",
        step = function(self, grant, stage, now)
            if entry.failed then
                error(entry.error or "panel is disabled")
            end
            local ok, message, _, unfinished = panelHost.dispatch(entry, "step", grant, stage, now)
            if not ok then
                error(message)
            end
            self.used = entry.instance.used or grant
            if entry.module.stageOf then
                self.stage, self.want = entry.module.stageOf(entry.instance)
            end
            entry.nextRefresh = now + (unfinished and 1 or math.max(1, entry.interval))
            return unfinished and 1 or math.max(1, entry.interval)
        end,
    }
    if entry.module.stageOf then
        task.stage, task.want = entry.module.stageOf(entry.instance)
    end
    return task
end

return panelHost
