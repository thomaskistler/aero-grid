-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Bind host operations once; callbacks retain their original work limits.
---@param dependencies table
---@return table
function module.new(dependencies)
    local addError = dependencies.addError
    local addNotice = dependencies.addNotice
    local showErrors = dependencies.showErrors
    local loadModule = dependencies.loadModule
    local isFullScreen = dependencies.isFullScreen
    local readThemeDefinition = dependencies.readThemeDefinition

    --- Advance to the next layout candidate after a read or parse failure.
    ---@param context AeroGridContext
    ---@param reason string
    ---@return boolean recovered
    local function recoverLayout(context, reason)
        local candidates = context.loadCandidates
        if type(candidates) ~= "table" then
            return false
        end

        local index = context.loadCandidateIndex or 0
        local nextIndex = index + 1
        local candidate = candidates[nextIndex]
        if not candidate then
            return false
        end

        context.recoveryCandidate = {
            candidate = candidate,
            index = nextIndex,
            reason = context.recoveryReason or reason,
        }
        context.recoveryReason = context.recoveryCandidate.reason
        context.reloadState = "clear"
        return true
    end

    --- The rectangle one placement occupies inside the host zone.
    --- Both building and reflow go through this, so the two cannot drift apart.
    ---@param context AeroGridContext
    ---@param placement table
    ---@return AeroGridRect? rect
    ---@return string? error
    local function panelRect(context, placement)
        return context.grid.rect(context.zone, placement, 4, 4, 4)
    end

    --- The part of one placement's own rectangle the menu button covers.
    ---
    --- Expressed in the panel's coordinates, because a panel is handed a
    --- container-local rectangle and can neither see nor reach the zone. On a
    --- 480 x 272 display only a placement at column zero, row zero can overlap,
    --- but that is a property of the arithmetic rather than a rule, so the
    --- intersection is computed rather than assumed.
    ---@param context AeroGridContext
    ---@param placement table
    ---@return table? reserved
    local function reservedFor(context, placement)
        local reserved = context.reserved
        if not reserved then
            return nil
        end

        local rect = panelRect(context, placement)
        if not rect then
            return nil
        end

        local width = reserved.w - rect.x
        local height = reserved.h - rect.y
        if width <= 0 or height <= 0 then
            return nil
        end

        return {
            w = width < rect.w and width or rect.w,
            h = height < rect.h and height or rect.h,
            side = placement.rowSpan == 1,
        }
    end

    --- Assemble the shared objects handed to one panel.
    --- Typography depends on the panel's span, so services are built per
    --- placement rather than shared across the dashboard. The data services
    --- themselves are dashboard-wide singletons and are passed through by
    --- reference, so two panels naming the same source share one poll.
    ---@param context AeroGridContext
    ---@param placement table
    ---@return table services
    local function buildServices(context, placement)
        local builder = context.themeBuilder
        local theme = context.theme
        local registry = context.serviceRuntime
        local byId = registry and registry.byId or {}

        -- Where the radio paints over us, the theme builder this panel sees
        -- resolves its panel frame around that corner. Binding it here rather than
        -- adding an argument to every panel means a panel written by
        -- someone else is laid out correctly too, without knowing any of this
        -- exists. The reservation is read on each call, not captured, so a zone
        -- that moves is picked up by the update that follows it.
        -- Always bound: a panel built in fullscreen, where nothing is reserved, is
        -- still shown in App mode later. Saving an edit updates `placement` in place.
        builder = setmetatable({
            frame = function(resolved, rect, fonts, reserved, badgeText)
                return context.themeBuilder.frame(resolved, rect, fonts, reservedFor(context, placement), badgeText)
            end,
        }, { __index = context.themeBuilder })

        return {
            theme = theme,
            -- The flight session belongs to the dashboard, not to a panel, so it
            -- is handed down rather than configured per panel.
            session = context.session or {},
            primitives = context.primitives,
            themeBuilder = builder,
            fonts = builder.typography(placement.colSpan, placement.rowSpan),
            span = { colSpan = placement.colSpan, rowSpan = placement.rowSpan },
            state = function(name, accentName)
                return builder.state(theme, name, accentName)
            end,
            clock = getTime,
            -- The host's own state, for the diagnostics view and nothing else.
            --
            -- The live context, not a copy. A diagnostics view reporting on a
            -- snapshot assembled for it would be reporting on a world built
            -- separately from the one the dashboard is using, and would be
            -- confidently wrong at exactly the moment it is being trusted. Handing it
            -- over costs one table field per panel and nothing else; a panel
            -- that abuses it is isolated like any other.
            host = context,
            -- Shared data services. Any of these may be absent when its module failed
            -- to load, so a panel must tolerate nil rather than assume.
            telemetry = byId.telemetry,
            model = byId.model,
            control = byId.control,
            extrema = byId.extrema,
            navigation = byId.navigation,
        }
    end

    --- Load, validate, and instantiate every panel in the selected layout.
    --- Instantiate one validated placement.
    ---@param context AeroGridContext
    ---@param placement table
    local function buildPanel(context, placement, container, preview)
        local host = context.panelHost

        --- Record a placement that will not be built, and why.
        ---
        --- A panel that never constructs leaves nothing behind but an error in
        --- a banner that may have scrolled, and it is absent from `panels`
        --- because there is no instance to put there. So the reason is kept where
        --- it is known. Without this the diagnostics view could report every panel
        --- that works and no panel that does not, which is the wrong half.
        local function reject(reason)
            if not preview then
                addError(context, placement.id .. ": " .. tostring(reason))
                context.rejected[#context.rejected + 1] = {
                    placement = placement,
                    reason = tostring(reason),
                }
            end
            return nil, tostring(reason)
        end

        local panel, panelError = loadModule(context.path, "panels/" .. placement.type .. ".lua")
        local contractValid, contractError

        if panel then
            contractValid, contractError = host.validateModule(panel, placement.type)
        end

        if not panel then
            return reject(panelError)
        end
        if not contractValid then
            return reject(contractError)
        end
        if not host.supportsSpan(panel, placement.colSpan, placement.rowSpan) then
            return reject("panel does not support span " .. host.spanName(placement.colSpan, placement.rowSpan))
        end

        local rect, rectError = panelRect(context, placement)
        if not rect then
            return reject(rectError)
        end

        local settings, warnings =
            host.resolveSettings(panel, placement.config, { colSpan = placement.colSpan, rowSpan = placement.rowSpan })
        if preview and #warnings > 0 then
            return reject(table.concat(warnings, "; "))
        end
        for _, warning in ipairs(warnings) do
            addError(context, placement.id .. ": " .. warning)
        end

        -- Each panel draws inside its own container, so it cannot reach the
        -- dashboard root or paint over a neighbour. The container is deliberately
        -- unpainted; the panel's own panel fills it.
        local geometry = {
            x = rect.x,
            y = rect.y,
            w = rect.w,
            h = rect.h,
        }
        if container then
            container:set(geometry)
            lvgl.show(container)
        else
            container = lvgl.box(context.page, geometry)
            -- Preview pools reuse containers, so their origin follows the object.
            if isFullScreen() then
                context.fullscreenContainers = context.fullscreenContainers or setmetatable({}, { __mode = "k" })
                context.fullscreenContainers[container] = true
            end
        end

        local services = buildServices(context, placement)
        services.preview = preview == true
        local ok, instance =
            pcall(panel.create, container, { x = 0, y = 0, w = rect.w, h = rect.h }, settings, services)

        -- A heading too long for its column is cut to fit, because the alternative
        -- is LVGL wrapping it down over the reading. Cutting a name the author
        -- chose is a loss, so it is reported rather than done quietly: being told
        -- is what makes it an abbreviation instead of a corruption, and the author
        -- can pick a shorter heading.
        --
        -- Collected from the primitive that did the cutting rather than read back
        -- off the label. A label is userdata on a radio and answers no questions
        -- about itself, so asking it produced nil there and the truth here.
        --
        -- Drained whether or not the panel survived. A panel that raises after
        -- drawing its header leaves a report behind, and a report left behind is
        -- one the next panel would be blamed for.
        local reports = context.primitives.headingReports
        if #reports > 0 then
            for _, report in ipairs(reports) do
                addNotice(
                    context,
                    "warning",
                    placement.id
                        .. ": heading "
                        .. tostring(report.requested)
                        .. " does not fit this panel and is drawn as "
                        .. tostring(report.drawn)
                )
            end
            context.primitives.headingReports = {}
        end

        if ok then
            local interval = host.refreshInterval(panel)
            context.panels[#context.panels + 1] = {
                placement = placement,
                module = panel,
                instance = instance,
                settings = settings,
                container = container,
                -- Boxes built in fullscreen stay touchable in App mode.
                builtFullscreen = isFullScreen() or nil,
                interval = interval,
                -- Stagger panels that share an interval so they do not all fall
                -- due on the same frame.
                nextRefresh = getTime() + host.phaseOffset(interval, #context.panels + 1),
            }
            return context.panels[#context.panels]
        else
            -- Discard whatever the failed panel managed to build.
            container:clear()
            lvgl.hide(container)
            local _, message = reject(instance)
            return nil, message, container
        end
    end

    --- Lines tokenized per widget callback.
    local TOKENIZE_LINES = 24

    --- Advance the staged loader by exactly one step.
    --- EdgeTX allows roughly 20000 VM instructions per widget callback, and a
    --- whole dashboard costs far more than that, so loading is spread over
    --- consecutive calls. Every stage is bounded by a fixed amount of work rather
    --- than by the size of the layout: the file is tokenized a fixed number of
    --- lines at a time, and each panel is parsed, validated, and built in its
    --- own callback. A layout that fills the grid therefore costs more callbacks,
    --- never a larger callback.
    ---@param context AeroGridContext
    ---@return boolean busy True while more work remains.
    local function advanceLoad(context)
        local stage = context.stage

        --- Abandon the load, reporting why.
        local function fail(message)
            if
                stage ~= "services"
                and stage ~= "theme-read"
                and stage ~= "theme-validate"
                and recoverLayout(context, tostring(message))
            then
                return true
            end
            addError(context, context.recoveryReason or message)
            context.stage = nil
            context.tokens = nil
            context.source = nil
            context.loadCandidates = nil
            context.loadCandidateIndex = nil
            context.themeNames, context.themeDefinitions = nil, nil
            showErrors(context)
            return false
        end

        if stage == "theme-read" then
            local names = context.themeNames
            local index = context.themeReadIndex
            local name = names[index]
            local definition, readError = readThemeDefinition(context.path, name, context.yaml)
            if not definition and readError ~= "theme file is missing: " .. name .. ".yml" then
                return fail("themes: " .. tostring(readError))
            end
            if definition then
                context.themeDefinitions[#context.themeDefinitions + 1] = definition
            end
            context.themeReadIndex = index + 1
            if index == #names then
                context.stage = "theme-validate"
            end
            return true
        end

        if stage == "theme-validate" then
            local configured, configureError = context.themeBuilder.setCatalog({
                version = 1,
                themes = context.themeDefinitions,
            })
            context.themeNames, context.themeDefinitions, context.themeReadIndex = nil, nil, nil
            if not configured then
                return fail("themes: " .. tostring(configureError))
            end
            context.stage = "read"
            return true
        end

        if stage == "read" then
            -- The runtime may have failed to load; refuse rather than index nil.
            if not context.layoutStore then
                return fail("AeroGrid runtime module failed to load")
            end

            local modelInfo = model.getInfo()
            local content, readError, filename, origin, candidates
            local recoveryIndex
            if context.recoveryCandidate then
                local recovery = context.recoveryCandidate
                context.recoveryCandidate = nil
                context.recoveryReason = recovery.reason
                local candidate = recovery.candidate
                content, readError = context.layoutStore.readCandidate(candidate.filename)
                filename, origin = candidate.filename, candidate.origin
                candidates = context.layoutStore.candidates(context.path, context.layoutName)
                recoveryIndex = recovery.index
            elseif type(context.layoutStore.readCandidates) == "function" then
                content, readError, filename, origin, candidates =
                    context.layoutStore.readCandidates(context.path, context.layoutName)
            else
                content, readError, filename, origin = context.layoutStore.read(context.path, context.layoutName)
            end

            if content or context.layoutPath == nil then
                context.layoutPath = filename
                context.layoutOrigin = origin
            end
            context.modelFilename = modelInfo and modelInfo.filename or nil
            context.loadCandidates = candidates
            context.loadCandidateIndex = recoveryIndex
            if candidates and not recoveryIndex then
                for index, candidate in ipairs(candidates) do
                    if candidate.filename == filename then
                        context.loadCandidateIndex = index
                        break
                    end
                end
                if not context.loadCandidateIndex and origin == "none" then
                    context.loadCandidateIndex = #candidates
                end
            end
            if not content then
                return fail(readError)
            end

            context.source = content
            context.tokens = {}
            context.readPosition = 1
            context.readLine = 1
            context.stage = "tokenize"
            return true
        end

        if stage == "tokenize" then
            local position, line, tokenError = context.yaml.tokenizeChunk(
                context.source,
                context.readPosition,
                context.readLine,
                TOKENIZE_LINES,
                context.tokens
            )

            if tokenError then
                return fail(tokenError)
            end

            context.readLine = line
            if position then
                context.readPosition = position
                return true
            end

            context.source = nil
            context.stage = "header"
            return true
        end

        if stage == "header" then
            local tokens = context.tokens
            if not tokens then
                return fail("layout tokens are missing")
            end
            -- Split the panel sequence out so the document itself stays small.
            local header, panelsIndex, panelsIndent = {}, nil, nil
            local index = 1

            while index <= #tokens do
                local token = tokens[index]
                if token.indent == 0 and string.match(token.content, "^panels:") then
                    panelsIndex = index + 1
                    index = index + 1
                    -- Skip the sequence body; it is parsed one entry at a time later.
                    while index <= #tokens and tokens[index].indent > 0 do
                        panelsIndent = panelsIndent or tokens[index].indent
                        index = index + 1
                    end
                else
                    header[#header + 1] = token
                    index = index + 1
                end
            end

            if not panelsIndex then
                return fail("panels must be a sequence")
            end

            local document, buildError = context.yaml.build(header)
            if not document then
                return fail(buildError)
            end

            local validated, headerErrors = context.layoutValidator.validateDocument(document)
            if not validated or #(headerErrors or {}) > 0 then
                local reason = table.concat(headerErrors or { "unsupported layout header" }, "; ")
                if recoverLayout(context, reason) then
                    return true
                end
                if context.recoveryReason then
                    addError(context, context.recoveryReason)
                else
                    for _, headerError in ipairs(headerErrors or {}) do
                        addError(context, headerError)
                    end
                end
                context.stage = nil
                context.tokens = nil
                context.loadCandidates = nil
                context.loadCandidateIndex = nil
                showErrors(context)
                return false
            end

            context.themeSource = "option"
            context.theme = context.themeBuilder.build(context.themeMode)
            for _, warning in ipairs(context.theme.warnings) do
                addError(context, "theme: " .. warning)
            end
            for _, notice in ipairs(context.theme.notices) do
                addNotice(context, notice.severity, "theme: " .. notice.text)
            end
            context.canvas:set({ color = context.theme.color.canvas })

            context.session = validated.session or {}
            context.document = validated
            context.itemIndex = panelsIndex
            context.itemIndent = panelsIndent or 2
            context.itemNumber = 0
            context.identifiers = {}
            context.serviceIndex = 0
            context.stage = "services"
            return true
        end

        if stage == "services" then
            -- Services are staged for the same reason panels are: each module has
            -- to be compiled and run, and the whole set does not fit in one callback.
            -- They are built before any panel, so a panel can subscribe from
            -- inside its own create call.
            local index = context.serviceIndex

            if index == 0 then
                local support, supportError =
                    loadModule(context.path, "lib/services.lua", context.packageInfo.runtimeApi)
                if not support then
                    -- A dashboard without services still renders: every panel sees
                    -- nil and must degrade to an unavailable presentation.
                    addError(context, "services: " .. tostring(supportError))
                    context.serviceIndex = nil
                    context.stage = "panels"
                    return true
                end

                context.servicesModule = support
                context.serviceRuntime = support.runtime(support.environment())
                context.serviceIndex = 1
                return true
            end

            local definition = context.servicesModule.DEFINITIONS[index]
            if not definition then
                context.serviceIndex = nil
                context.stage = "panels"
                return true
            end

            context.serviceIndex = index + 1

            local module, moduleError = loadModule(context.path, definition.file, context.packageInfo.runtimeApi)
            local constructor = module and rawget(module, "new") or nil
            if type(constructor) == "function" then
                local runtime = context.serviceRuntime
                if not runtime then
                    return fail("service runtime is missing")
                end
                local ok, instance = pcall(constructor, runtime.env, context.servicesModule, runtime)
                if ok and type(instance) == "table" then
                    context.servicesModule.register(runtime, instance, getTime())
                else
                    addError(context, definition.id .. ": " .. tostring(instance))
                end
            else
                addError(context, definition.id .. ": " .. tostring(moduleError or "service module has no constructor"))
            end

            return true
        end

        if stage == "panels" then
            local tokens = context.tokens
            local index = context.itemIndex

            if not tokens then
                return fail("layout tokens are missing")
            end
            local token = index and tokens[index] or nil
            if not index or not token or token.indent < context.itemIndent then
                context.tokens = nil
                context.stage = nil
                context.loadCandidates = nil
                context.loadCandidateIndex = nil
                if context.recoveryReason then
                    addNotice(context, "warning", "layout recovered after: " .. context.recoveryReason)
                    context.recoveryReason = nil
                end
                showErrors(context)
                return false
            end

            local placement, nextIndex, itemError = context.yaml.itemAt(tokens, index, context.itemIndent)
            if itemError then
                return fail(itemError)
            end

            context.itemIndex = nextIndex
            context.itemNumber = context.itemNumber + 1

            local valid, panelError = context.layoutValidator.validatePanel(
                placement,
                context.itemNumber,
                context.grid,
                context.document.panels,
                context.identifiers
            )

            if valid then
                context.identifiers[placement.id] = true
                context.document.panels[#context.document.panels + 1] = placement
                buildPanel(context, placement)
            else
                addError(context, panelError)
            end

            return true
        end

        return false
    end

    --- Begin a staged load, discarding anything already on screen.
    ---@param context AeroGridContext
    local function beginLoad(context)
        context.panels = {}
        context.rejected = {}
        context.errors = {}
        context.notices = {}
        context.errorLabel = nil
        context.tokens = nil
        context.source = nil
        context.document = nil
        context.identifiers = nil
        context.itemIndex = nil
        context.loadCandidates = nil
        context.loadCandidateIndex = nil
        context.itemNumber = 0
        -- Subscriptions belong to the panels that made them, so the registry is
        -- rebuilt with the dashboard rather than reused across a reload.
        context.serviceRuntime = nil
        context.serviceIndex = nil
        context.themeNames = { "modern-dark" }
        if context.themeMode ~= "modern-dark" then
            context.themeNames[#context.themeNames + 1] = context.themeMode
        end
        context.themeDefinitions = {}
        context.themeReadIndex = 1
        context.stage = "theme-read"
    end

    return {
        recoverLayout = recoverLayout,
        panelRect = panelRect,
        reservedFor = reservedFor,
        buildServices = buildServices,
        buildPanel = buildPanel,
        advanceLoad = advanceLoad,
        beginLoad = beginLoad,
    }
end

return module
