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
    local readThemeSource = dependencies.readThemeSource

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
            -- Retained layout-level session block.
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
            armed = byId.armed,
            navigation = byId.navigation,
            history = byId.history,
            flight = byId.flight,
        }
    end

    local function rejectPanel(context, placement, preview, reason)
        if not preview then
            addError(context, placement.id .. ": " .. tostring(reason))
            context.rejected[#context.rejected + 1] = {
                placement = placement,
                reason = tostring(reason),
            }
        end
        return nil, tostring(reason)
    end

    local function preparePanel(context, placement, preview)
        local host = context.panelHost
        local panel, panelError = loadModule(context.path, "panels/" .. placement.type .. ".lua")
        local contractValid, contractError

        if panel then
            contractValid, contractError = host.validateModule(panel, placement.type)
        end

        if not panel then
            return rejectPanel(context, placement, preview, panelError)
        end
        if not contractValid then
            return rejectPanel(context, placement, preview, contractError)
        end
        if not host.supportsSpan(panel, placement.colSpan, placement.rowSpan) then
            return rejectPanel(
                context,
                placement,
                preview,
                "panel does not support span " .. host.spanName(placement.colSpan, placement.rowSpan)
            )
        end

        local rect, rectError = panelRect(context, placement)
        if not rect then
            return rejectPanel(context, placement, preview, rectError)
        end

        local settings, warnings = host.resolveSettings(
            panel,
            placement.config,
            { colSpan = placement.colSpan, rowSpan = placement.rowSpan },
            context.modelArmed
        )
        if preview and #warnings > 0 then
            return rejectPanel(context, placement, preview, table.concat(warnings, "; "))
        end
        for _, warning in ipairs(warnings) do
            addError(context, placement.id .. ": " .. warning)
        end
        return { module = panel, settings = settings, rect = rect }
    end

    local function publishPanel(context, entry)
        local interval = context.panelHost.refreshInterval(entry.module)
        entry.interval = interval
        entry.nextRefresh = getTime() + context.panelHost.phaseOffset(interval, #context.panels + 1)
        context.panels[#context.panels + 1] = entry
        context.panelTasksDirty = true
        lvgl.show(entry.container)
        return entry
    end

    --- Synchronous callers prepare immediately; staged loading retains that work
    --- for a separate construction callback.
    local function buildPanel(context, placement, container, preview, prepared)
        local preparation, message = prepared, nil
        if not preparation then
            preparation, message = preparePanel(context, placement, preview)
            if not preparation then
                return nil, message
            end
        else
            local rect, rectError = panelRect(context, placement)
            if not rect then
                return rejectPanel(context, placement, preview, rectError)
            end
            preparation.rect = rect
        end
        local panel, settings, rect = preparation.module, preparation.settings, preparation.rect

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
        services.staged = prepared ~= nil and type(rawget(panel, "construct")) == "function"
        if services.staged then
            lvgl.hide(container)
        end
        local ok, instance =
            pcall(panel.create, container, { x = 0, y = 0, w = rect.w, h = rect.h }, settings, services)

        if ok then
            local entry = {
                placement = placement,
                module = panel,
                instance = instance,
                settings = settings,
                container = container,
                -- Boxes built in fullscreen stay touchable in App mode.
                builtFullscreen = isFullScreen() or nil,
            }
            if services.staged then
                context.pendingConstruction = entry
                return
            end
            return publishPanel(context, entry)
        else
            -- Discard whatever the failed panel managed to build.
            container:clear()
            lvgl.hide(container)
            local _, message = rejectPanel(context, placement, preview, instance)
            return nil, message, container
        end
    end

    local function advanceConstruction(context, preview)
        local entry = assert(context.pendingConstruction, "pending panel construction is missing")
        local rect, message = panelRect(context, entry.placement)
        local ok, done = false, message
        if rect then
            entry.container:set({ x = rect.x, y = rect.y, w = rect.w, h = rect.h })
            ok, done = pcall(entry.module.construct, entry.instance, { x = 0, y = 0, w = rect.w, h = rect.h })
            if ok and type(done) ~= "boolean" then
                ok, done = false, "construct must return a boolean"
            end
        end
        if not ok then
            entry.container:clear()
            lvgl.hide(entry.container)
            context.pendingConstruction = nil
            local _, reason = rejectPanel(context, entry.placement, preview, done)
            return true, nil, reason, entry.container
        elseif done then
            context.pendingConstruction = nil
            return true, publishPanel(context, entry)
        end
        return false
    end

    --- Lines tokenized per widget callback.
    local TOKENIZE_LINES = 8
    local THEME_CHUNK = 8

    local function nextTheme(context, definition)
        if definition then
            context.themeDefinitions[#context.themeDefinitions + 1] = definition
        end
        context.themeWork = nil
        context.themeReadIndex = context.themeReadIndex + 1
        context.stage = context.themeReadIndex > #context.themeNames and "theme-validate" or "theme-read"
    end

    --- Advance the staged loader by exactly one step.
    --- EdgeTX allows roughly 20000 VM instructions per widget callback, and a
    --- whole dashboard costs far more than that, so loading is spread over
    --- consecutive calls. Every stage is bounded by a fixed amount of work rather
    --- than by the size of the layout: the file is tokenized a fixed number of
    --- lines at a time, and each panel is parsed, validated, prepared and built
    --- in separate callbacks. A layout that fills the grid therefore costs more callbacks,
    --- never a larger callback.
    ---@param context AeroGridContext
    ---@return boolean busy True while more work remains.
    local function advanceLoad(context)
        local stage = context.stage

        --- Abandon the load, reporting why.
        local function fail(message)
            if
                stage ~= "services"
                and string.sub(stage, 1, 6) ~= "theme-"
                and recoverLayout(context, tostring(message))
            then
                return true
            end
            addError(context, context.recoveryReason or message)
            local member = context.flightFactory and context.flightFactory.members[context]
            if member then
                member.pending, member.error =
                    false, "Flight configuration unavailable: repair layout " .. context.layoutName
                context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
            end
            context.stage = nil
            context.tokens = nil
            context.source = nil
            context.loadCandidates = nil
            context.loadCandidateIndex = nil
            context.pendingPanel = nil
            context.themeNames, context.themeDefinitions = nil, nil
            context.themeWork = nil
            context.themeBuildWork, context.themePublication = nil, nil
            context.headerWork = nil
            context.commentWork = nil
            context.pendingItem = nil
            showErrors(context)
            return false
        end

        if stage == "theme-read" then
            local names = context.themeNames
            local index = context.themeReadIndex
            local name = names[index]
            local source, filename = readThemeSource(context.path, name)
            if not source then
                if filename ~= "theme file is missing: " .. name .. ".yml" then
                    return fail("themes: " .. tostring(filename))
                end
                nextTheme(context)
                return true
            end
            context.themeWork = {
                name = name,
                filename = filename,
                source = source,
                tokens = {},
                position = 1,
                line = 1,
            }
            context.stage = "theme-tokenize"
            return true
        end

        if stage == "theme-tokenize" then
            local work = context.themeWork
            local position, line, tokenError, commentWork = context.yaml.tokenizeChunk(
                work.source,
                work.position,
                work.line,
                THEME_CHUNK,
                work.tokens,
                128,
                work.commentWork
            )
            if tokenError then
                return fail("themes: " .. work.filename .. ": " .. tokenError)
            end
            work.position, work.line, work.commentWork = position, line, commentWork
            if not position then
                work.source = nil
                context.stage = "theme-parse"
            end
            return true
        end

        if stage == "theme-parse" then
            local work = context.themeWork
            local pending, definition, parseError =
                context.yaml.buildMappingChunk(work.tokens, work.mapping, THEME_CHUNK)
            if parseError then
                return fail("themes: " .. work.filename .. ": " .. parseError)
            end
            work.mapping = pending
            if not pending then
                if definition.name ~= work.name then
                    return fail("themes: " .. work.filename .. ": theme name must match the filename")
                end
                nextTheme(context, definition)
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
            local modelFilename = modelInfo and modelInfo.filename or nil
            if context.modelFilename ~= modelFilename then
                context.navigationHomes = nil
            end
            context.modelFilename = modelFilename
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
            local position, line, tokenError, commentWork = context.yaml.tokenizeChunk(
                context.source,
                context.readPosition,
                context.readLine,
                TOKENIZE_LINES,
                context.tokens,
                128,
                context.commentWork
            )

            if tokenError then
                return fail(tokenError)
            end

            context.readLine = line
            context.commentWork = commentWork
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
            local work = context.headerWork or { tokens = {}, index = 1 }
            context.headerWork = work
            for _ = 1, 32 do
                local token = tokens[work.index]
                if not token then
                    if not work.panelsIndex then
                        return fail("panels must be a sequence")
                    end
                    context.stage = "header-parse"
                    return true
                end
                if token.indent == 0 and string.match(token.content, "^panels:") then
                    work.panelsIndex, work.skipping = work.index + 1, true
                elseif work.skipping and token.indent > 0 then
                    work.panelsIndent = work.panelsIndent or token.indent
                else
                    work.skipping = false
                    work.tokens[#work.tokens + 1] = token
                end
                work.index = work.index + 1
            end
            return true
        end

        if stage == "header-parse" then
            local work = context.headerWork
            local pending, document, buildError = context.yaml.buildChunk(work.tokens, work.parsing, 8)
            if buildError then
                return fail(buildError)
            end
            work.parsing = pending
            if not pending then
                work.document, work.tokens = document, nil
                context.stage = "header-validate"
            end
            return true
        end

        if stage == "header-validate" then
            local work = context.headerWork
            local pending, validated, headerErrors, sourceVersion =
                context.layoutValidator.validateHeaderChunk(work.document, work.validation, 8)
            work.validation = pending
            if pending then
                return true
            end
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
                context.headerWork = nil
                showErrors(context)
                return false
            end

            context.document = validated
            context.layoutSourceVersion = sourceVersion
            context.layoutMigrationVersion = sourceVersion
            context.itemIndex = work.panelsIndex
            context.itemIndent = work.panelsIndent or 2
            context.itemNumber = 0
            context.identifiers = {}
            context.serviceIndex = 0
            context.headerWork = nil
            context.stage = sourceVersion < context.layoutValidator.VERSION and "header-migrate" or "header-finalize"
            return true
        end

        if stage == "header-migrate" then
            local migrated, nextVersion = context.layoutValidator.migrateHeaderStep(context.document)
            if not migrated then
                return fail(nextVersion)
            end
            context.layoutMigrationVersion = nextVersion
            if nextVersion == context.layoutValidator.VERSION then
                context.stage = "header-finalize"
            end
            return true
        end

        if stage == "header-finalize" then
            local pending, validated, headerErrors =
                context.layoutValidator.finalizeHeaderChunk(context.document, context.headerWork, 8)
            context.headerWork = pending
            if pending then
                return true
            end
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

            context.session = validated.session or {}
            context.document = validated
            context.stage = "theme-resolve-begin"
            return true
        end

        if stage == "theme-resolve-begin" then
            context.themeBuildWork = context.themeBuilder.beginBuild(context.themeMode)
            context.stage = "theme-resolve"
            return true
        end

        if stage == "theme-resolve" then
            local work = context.themeBuildWork
            local phase = work.stage
            local limit = phase == "display" and 8
                or phase == "alert" and 4
                or phase == "chart" and not work.definition.correctForContrast and 6
                or 1
            for _ = 1, limit do
                local resolved = context.themeBuilder.advanceBuild(work)
                if resolved then
                    context.themePublication = { theme = resolved, phase = "warnings", index = 1 }
                    context.themeBuildWork = nil
                    context.stage = "theme-publish"
                    break
                elseif work.stage ~= phase then
                    break
                end
            end
            return true
        end

        if stage == "theme-publish" then
            local work = context.themePublication
            if work.phase == "warnings" then
                local warning = work.theme.warnings[work.index]
                if warning then
                    addError(context, "theme: " .. warning)
                    work.index = work.index + 1
                else
                    work.phase, work.index = "notices", 1
                end
            elseif work.phase == "notices" then
                local notice = work.theme.notices[work.index]
                if notice then
                    addNotice(context, notice.severity, "theme: " .. notice.text)
                    work.index = work.index + 1
                else
                    work.phase = "commit"
                end
            elseif work.phase == "commit" then
                if context.layoutSourceVersion < context.layoutValidator.VERSION then
                    addNotice(
                        context,
                        "warning",
                        "Layout version "
                            .. tostring(context.layoutSourceVersion)
                            .. " was migrated in memory; use Save to write version "
                            .. tostring(context.layoutValidator.VERSION)
                            .. "."
                    )
                end
                context.theme, context.themeSource = work.theme, "option"
                context.canvas:set({ color = context.theme.color.canvas })
                context.themePublication = nil
                context.stage = "services"
            else
                return fail("unknown theme publication phase: " .. tostring(work.phase))
            end
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
                context.serviceRuntime.host = context
                context.serviceRuntime.modules = {}
                context.armGeneration = (context.armGeneration or 0) + 1
                context.serviceRuntime.armGeneration = context.armGeneration
                context.navigationHomes = context.navigationHomes or {}
                context.serviceRuntime.navigationHomes = context.navigationHomes
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
                runtime.modules[definition.id] = module
                if definition.id == "armed" then
                    local owner = context.flightFactory.broker
                    context.modelArmed = owner and owner.document and owner.document.armed
                    runtime.modelArmed = context.modelArmed
                    if context.modelArmed == nil and (context.legacyWidgetArmed or 0) ~= 0 then
                        addNotice(
                            context,
                            "warning",
                            "Armed moved to Model settings; old widget selections are not imported. Choose the model switch and Save."
                        )
                    end
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
                if context.configureFlight then
                    context.configureFlight(context)
                end
                if context.recoveryReason then
                    addNotice(context, "warning", "layout recovered after: " .. context.recoveryReason)
                    context.recoveryReason = nil
                end
                showErrors(context)
                return false
            end

            if not string.match(token.content, "^%-") then
                return fail("line " .. token.line .. ": expected a sequence entry")
            end
            context.pendingItem = { first = index, index = index, tokens = {} }
            context.stage = "panel-tokens"
            return true
        end

        if stage == "panel-tokens" then
            local work = context.pendingItem
            for _ = 1, 32 do
                local token = context.tokens[work.index]
                if not token or work.index > work.first and token.indent <= context.itemIndent then
                    context.stage = "panel-parse"
                    return true
                end
                work.tokens[#work.tokens + 1] = {
                    content = token.content,
                    line = token.line,
                    indent = token.indent - context.itemIndent,
                }
                work.index = work.index + 1
            end
            return true
        end

        if stage == "panel-parse" then
            local work = context.pendingItem
            local pending, entries, itemError = context.yaml.buildChunk(work.tokens, work.parsing, 8)
            if itemError then
                return fail(itemError)
            end
            work.parsing = pending
            if pending then
                return true
            end
            context.itemIndex = work.index
            context.itemNumber = context.itemNumber + 1
            context.pendingPlacement = entries[1]
            context.pendingItem = nil
            context.panelMigrationVersion = context.layoutSourceVersion
            context.stage = context.panelMigrationVersion < context.layoutValidator.VERSION and "panel-migrate"
                or "panel-validate"
            return true
        end

        if stage == "panel-migrate" then
            local migrated, nextVersion =
                context.layoutValidator.migratePanelStep(context.pendingPlacement, context.panelMigrationVersion)
            if not migrated then
                return fail(nextVersion)
            end
            context.panelMigrationVersion = nextVersion
            if nextVersion == context.layoutValidator.VERSION then
                context.stage = "panel-validate"
            end
            return true
        end

        if stage == "panel-validate" then
            local placement = context.pendingPlacement
            if type(placement) ~= "table" then
                return fail("pending panel migration is missing")
            end
            if placement.type == "flight-counter" then
                context.flightSources[#context.flightSources + 1] = placement
            end
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
                context.stage = "panel-prepare"
                return true
            else
                addError(context, panelError)
            end
            context.pendingPlacement = nil
            context.panelMigrationVersion = nil
            context.stage = "panels"
            return true
        end

        if stage == "panel-prepare" then
            context.pendingPanel = preparePanel(context, context.pendingPlacement)
            if context.pendingPanel then
                context.stage = "panel-build"
            else
                context.pendingPlacement, context.panelMigrationVersion = nil, nil
                context.stage = "panels"
            end
            return true
        end

        if stage == "panel-build" then
            buildPanel(context, context.pendingPlacement, nil, nil, context.pendingPanel)
            context.pendingPanel = nil
            if context.pendingConstruction then
                context.stage = "panel-construct"
                return true
            end
            context.pendingPlacement = nil
            context.panelMigrationVersion = nil
            context.stage = "panels"
            return true
        end

        if stage == "panel-construct" then
            if not advanceConstruction(context, false) then
                return true
            end
            context.pendingConstruction, context.pendingPlacement, context.panelMigrationVersion = nil, nil, nil
            context.stage = "panels"
            return true
        end

        return false
    end

    --- Begin a staged load, discarding anything already on screen.
    ---@param context AeroGridContext
    local function beginLoad(context)
        if context.pendingConstruction then
            context.pendingConstruction.container:clear()
            lvgl.hide(context.pendingConstruction.container)
            context.pendingConstruction = nil
        end
        if context.flightFactory then
            local member = context.flightFactory.members[context]
            if member then
                member.pending = true
                context.flightFactory.revision = (context.flightFactory.revision or 0) + 1
            end
        end
        context.panels = {}
        context.refreshOwner = nil
        context.rejected = {}
        context.errors = {}
        context.notices = {}
        context.errorLabel = nil
        context.tokens = nil
        context.source = nil
        context.commentWork, context.headerWork = nil, nil
        context.pendingItem = nil
        context.document = nil
        context.layoutSourceVersion = nil
        context.layoutMigrationVersion = nil
        context.pendingPlacement = nil
        context.pendingPanel = nil
        context.panelMigrationVersion = nil
        context.identifiers = nil
        context.itemIndex = nil
        context.loadCandidates = nil
        context.loadCandidateIndex = nil
        context.itemNumber = 0
        context.flightSources = {}
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
        context.themeWork = nil
        context.themeBuildWork, context.themePublication = nil, nil
        context.stage = "theme-read"
    end

    return {
        recoverLayout = recoverLayout,
        panelRect = panelRect,
        reservedFor = reservedFor,
        buildServices = buildServices,
        buildPanel = buildPanel,
        preparePanel = preparePanel,
        advanceConstruction = advanceConstruction,
        advanceLoad = advanceLoad,
        beginLoad = beginLoad,
    }
end

return module
