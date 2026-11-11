-- SPDX-License-Identifier: GPL-2.0-only

--- What the host actually loaded, read back from the host itself.
---
--- When something looks wrong on a radio, most available evidence is pixels, and
--- inferring from pixels is what cost an evening on an arc drifting by its
--- own radius and another on a radio running bytecode that was no longer on
--- the card. This exists so a hardware session can answer "what is loaded and
--- what did it resolve to" by reading it rather than deducing it.
---
--- **Everything here reads the live host context.** Nothing is re-derived. A
--- diagnostics view that resolved the layout filename a second time, or
--- rebuilt the theme to see what it would say, would be reporting on a world
--- assembled separately from the one the dashboard is using, and would be
--- confidently wrong at exactly the moment it is being trusted. Where a fact
--- is not recoverable afterwards, the host records it where it is decided
--- instead: `layoutOrigin`, `themeSource` and `theme.requested` are all there
--- for that reason, and each replaced a guess this file would otherwise have
--- had to make.
---
--- A panel no layout places is never loaded. A live log panel also enables
--- shared event collection on hidden screens. Rendering uses a fixed number
--- of line objects and repaints only the lines whose text changed.
---
--- **The content-flow rule does not apply here, and this is an exemption
--- rather than an omission.** That rule arranges a panel around a reading:
--- the reading takes one slot, a compact visual the other, and supporting
--- rows the same two centres. This panel has no reading and no visual. It is
--- a list of lines of running text, each as long as the fact it reports, and
--- what it is for is being read densely by somebody holding a radio that is
--- behaving oddly.
---
--- Centring those lines would be actively worse. A column of left-aligned
--- text is scanned down its first character; centring gives every line a
--- different left edge, so finding the line that says `bytecode:` means
--- reading all of them. The rule exists to make panels agree with one
--- another at a glance, and this panel is not glanced at.
---
--- The same applies to `service-probe`, which is the same shape. Neither is a
--- shipped panel -- no dashboard layout places either -- so neither is
--- part of the set the arrangement was designed for.

---@class AeroGridDiagnosticsSettings
---@field section "identity"|"theme"|"panels"|"sources"|"log"|"scheduler"
---@field maxEntries? integer Shared log retention, 1 to 256.
---@field label? string Panel title; defaults to the section name.
---@field accent? string

local diagnostics = {
    id = "host-diagnostics",
    apiVersion = 1,
    supportedSpans = { "2x2", "3x2", "4x2", "2x3", "3x3", "4x3", "2x4", "3x4", "4x4" },
    -- Read, not watched. Nothing here changes between frames except a panel
    -- failing or a source binding, and neither is worth a frame.
    refreshInterval = 50,
    settings = {
        -- An empty label is not an absent one: it means derive the heading at
        -- runtime, here from the section being shown.
        { key = "label", label = "Label", type = "string", default = "" },
        {
            key = "section",
            label = "Section",
            type = "string",
            default = "identity",
            choices = { "identity", "theme", "panels", "sources", "log", "scheduler" },
        },
        {
            key = "maxEntries",
            label = "Maximum log entries",
            type = "number",
            default = 64,
            step = 1,
            min = 1,
            max = 256,
            visibleWhen = { key = "section", value = "log" },
        },
        {
            key = "accent",
            label = "Accent",
            type = "string",
            default = "cyan",
            choices = { "cyan", "green", "amber", "orange" },
        },
    },
}

--- Most lines any section will draw, whatever its span.
local MAX_LINES = 12

local function schedulerStats(context)
    if context.host and not context.preview then
        context.schedulerActive = true
    end
    if context.host and not context.preview and not context.host.schedulerStats then
        context.host.schedulerStats = {
            started = getTime(),
            callbacks = 0,
            used = 0,
            requested = 0,
            denied = 0,
            revision = 0,
            utilization = 0,
            deferrals = 0,
        }
    end
    return context.host and context.host.schedulerStats
end

--- Named consumers stacked in the scheduler graph; the rest share one layer.
local CONSUMERS = 5

local function consumerName(owner)
    if owner == "flight" then
        return "flight detector"
    elseif owner.placement then
        return tostring(owner.placement.id) .. " " .. tostring(owner.placement.type)
    end
    return tostring(owner.id) .. " service"
end

local function schedulerGraph(context, rect, area)
    if context.graph then
        for _, column in ipairs(context.graph.columns) do
            for _, segment in ipairs(column) do
                lvgl.hide(segment)
            end
        end
        for _, line in ipairs(context.graph.lines) do
            lvgl.hide(line)
        end
    else
        local root = lvgl.box(context.panel.root, { x = 0, y = 0, w = rect.w, h = rect.h })
        context.graph = {
            root = root,
            -- Created first so the deferral line and cursor draw over the stack.
            stack = lvgl.box(root, { x = 0, y = 0, w = rect.w, h = rect.h }),
            overlay = lvgl.box(root, { x = 0, y = 0, w = rect.w, h = rect.h }),
            columns = {},
            lines = {},
            references = {},
            rank = {},
            owners = {},
        }
    end
    local graph, color, chart = context.graph, context.theme.color, context.theme.chartColor
    graph.colors = { chart.cyan, color.blue, chart.green, chart.amber, color.critical, color.track }
    for _, box in ipairs({ graph.root, graph.stack, graph.overlay }) do
        box:set({ w = rect.w, h = rect.h })
    end
    graph.legend = math.min(CONSUMERS + 1, math.max(1, area.lines - 2))
    graph.x, graph.y = area.pad, area.top + area.lineHeight * graph.legend
    graph.width, graph.height = math.max(2, area.content // 1), math.max(1, rect.h - graph.y - area.frame.bottom)
    graph.index, graph.previous = 0, nil
    graph.revision = context.host and context.host.schedulerStats and context.host.schedulerStats.revision or 0
    local cursor = {
        x = graph.x,
        y = graph.y,
        w = 1,
        h = graph.height,
        color = color.textFaint,
    }
    if graph.cursor then
        graph.cursor:set(cursor)
    else
        graph.cursor = lvgl.vline(graph.overlay, cursor)
    end
    for index, percent in ipairs({ 0, 100 }) do
        local options = {
            x = graph.x,
            y = graph.y + (100 - percent) * graph.height / 100,
            w = graph.width,
            h = 1,
            color = color.textFaint,
        }
        if graph.references[index] then
            graph.references[index]:set(options)
        else
            graph.references[index] = lvgl.hline(graph.overlay, options)
        end
    end
    for index = 1, MAX_LINES do
        if index <= graph.legend and index <= area.lines then
            lvgl.show(context.rows[index])
        else
            lvgl.hide(context.rows[index])
        end
    end
    context.texts[1] = "Requests deferred"
    context.rows[1]:set({ text = context.texts[1], color = chart.orange })
    for slot = 1, graph.legend - 1 do
        context.texts[slot + 1] = nil
        context.rows[slot + 1]:set({ color = graph.colors[slot] })
    end
end

--- Keep each busy consumer in one color while it stays among the busiest.
local function rankConsumers(context, stats)
    local graph = context.graph
    local rank, owners, slots = graph.rank, graph.owners, stats.consumers or {}
    local seconds = stats.seconds and stats.seconds > 0 and stats.seconds or 1
    for owner, rate in pairs(rank) do
        rank[owner] = rate * 0.8
    end
    for owner, used in pairs(slots) do
        rank[owner] = (rank[owner] or 0) + used / seconds * 0.2
    end
    local order = {}
    for owner, rate in pairs(rank) do
        if rate < 0.05 then
            rank[owner] = nil
        else
            order[#order + 1] = owner
        end
    end
    table.sort(order, function(a, b)
        return rank[a] > rank[b]
    end)
    local busiest = {}
    for index = 1, math.min(CONSUMERS, #order) do
        busiest[order[index]] = true
    end
    for slot = 1, CONSUMERS do
        local owner = owners[slot]
        if owner and busiest[owner] then
            busiest[owner] = nil
        else
            owners[slot] = nil
        end
    end
    for index = 1, math.min(CONSUMERS, #order) do
        local owner = order[index]
        if busiest[owner] then
            for slot = 1, CONSUMERS do
                if not owners[slot] then
                    owners[slot] = owner
                    break
                end
            end
        end
    end
    for slot = 1, graph.legend - 1 do
        local owner = owners[slot]
        local text = owner and string.format("%.1f %s", rank[owner], consumerName(owner)) or ""
        if context.texts[slot + 1] ~= text then
            context.texts[slot + 1] = text
            context.rows[slot + 1]:set({ text = text })
        end
    end
    return slots
end

local function refreshScheduler(context)
    local stats, graph = schedulerStats(context), context.graph
    if not stats or stats.revision == graph.revision then
        return
    end
    local consecutive = stats.revision == graph.revision + 1
    graph.revision = stats.revision
    local index = graph.index
    local slots = rankConsumers(context, stats)
    local capacity = stats.capacity and stats.capacity > 0 and stats.capacity or nil
    local column = graph.columns[index + 1]
    if not column then
        column = {}
        graph.columns[index + 1] = column
    end
    local function boundary(percent)
        return graph.y + math.floor((100 - percent) * graph.height / 100 + 0.5)
    end
    local named, bottom = 0, boundary(0)
    for layer = 1, CONSUMERS + 1 do
        if layer <= CONSUMERS then
            local owner = graph.owners[layer]
            named = named + (owner and capacity and (slots[owner] or 0) * 100 / capacity or 0)
        else
            named = math.max(named, stats.utilization)
        end
        local top = boundary(math.min(100, named))
        local segment = column[layer]
        if bottom > top then
            local options = { x = graph.x + index, y = top, w = 1, h = bottom - top, color = graph.colors[layer] }
            if segment then
                segment:set(options)
                lvgl.show(segment)
            else
                column[layer] = lvgl.vline(graph.stack, options)
            end
        elseif segment then
            lvgl.hide(segment)
        end
        bottom = top
    end
    local y = boundary(stats.deferrals)
    local previous = consecutive and index > 0 and graph.previous or y
    local options = { pts = { { graph.x + math.max(0, index - 1), previous }, { graph.x + index, y } } }
    local line = graph.lines[index + 1]
    if line then
        line:set(options)
        lvgl.show(line)
    else
        options.color = context.theme.chartColor.orange
        options.thickness = 1
        graph.lines[index + 1] = lvgl.line(graph.overlay, options)
    end
    local following = (index + 1) % graph.width + 1
    for _, segment in ipairs(graph.columns[following] or {}) do
        lvgl.hide(segment)
    end
    if graph.lines[following] then
        lvgl.hide(graph.lines[following])
    end
    graph.previous = y
    graph.cursor:set({ x = graph.x + index })
    graph.index = (index + 1) % graph.width
end

function diagnostics.validateSettings(settings)
    local limit = settings.maxEntries
    if limit ~= nil and (type(limit) ~= "number" or limit ~= limit or limit < 1 or limit > 256 or limit % 1 ~= 0) then
        return { "maxEntries must be an integer from 1 to 256" }
    end
    return {}
end

function diagnostics.log(host, maxEntries)
    local log = host.diagnosticsLog
    if not log then
        return { "no shared diagnostics log" }
    end
    local entries = log:read(maxEntries)
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = log.format(entry)
    end
    return #lines > 0 and lines or { "No messages recorded" }
end

--- Describe the script the radio was asked to run.
---
--- EdgeTX prefers `.luac` bytecode and compiles it beside each script, so a
--- radio can silently run code that is no longer on the card. `make build`
--- deletes the bytecode for that reason; a card assembled any other way will
--- not have. This reports `main.lua`'s size and modification time and,
--- decisively, whether a `main.luac` is sitting beside it. If one is, the
--- timestamp shown is not the code that is executing, and that is the whole
--- diagnosis.
---
--- `fstat` returns `{size, attrib, time = {year, mon, day, hour, min, sec}}`
--- and returns nothing at all for a file it cannot stat
--- (`luaFstat`, `radio/src/lua/api_filesystem.cpp`). It is absent on some
--- builds, in which case nothing here can be proven and this says so rather
--- than inventing a reassuring answer.
---@param widgetPath any
---@return table stamp
function diagnostics.sourceStamp(widgetPath)
    local path = type(widgetPath) == "string" and widgetPath or ""
    local base = string.sub(path, -1) == "/" and path or path .. "/"

    if type(fstat) ~= "function" then
        return { available = false, bytecode = false }
    end

    local function statOf(name)
        local ok, info = pcall(fstat, base .. name)
        if not ok or type(info) ~= "table" then
            return nil
        end
        return info
    end

    local source = statOf("main.lua")
    local bytecode = statOf("main.luac")
    local stamp = {
        available = source ~= nil,
        size = source and source.size or nil,
        bytecode = bytecode ~= nil,
    }

    local time = source and source.time
    if type(time) == "table" and time.year then
        stamp.modified = string.format(
            "%04d-%02d-%02d %02d:%02d",
            time.year,
            time.mon or 0,
            time.day or 0,
            time.hour or 0,
            time.min or 0
        )
    end

    return stamp
end

--- Which layout was opened, and which of the three candidate names answered.
---@param host table Live host context.
---@return string[]
function diagnostics.identity(host)
    local stamp = diagnostics.sourceStamp(host.path)
    local lines = {}
    local version = host.packageInfo and host.packageInfo.version or "unknown"

    -- Ordered by what a person is here to find out, because a two-cell panel
    -- shows about five lines and the rest are shed. "What is executing" comes
    -- first: it is the question this section exists for.
    if not stamp.available then
        lines[#lines + 1] = "v" .. version .. " main.lua unreadable"
    else
        lines[#lines + 1] = "v" .. version .. " main.lua " .. tostring(stamp.size) .. "b"
        if stamp.modified then
            lines[#lines + 1] = stamp.modified
        end
    end
    -- The alarm, and deliberately above the layout path: a radio running stale
    -- bytecode makes every other line on this panel untrustworthy.
    if stamp.bytecode then
        lines[#lines + 1] = "RUNNING main.luac"
    end

    -- The filename search has three branches and leaves nothing behind to say
    -- which one won; two of them can produce similar-looking paths.
    lines[#lines + 1] = "layout " .. tostring(host.layoutName) .. " -> " .. tostring(host.layoutOrigin or "--")
    lines[#lines + 1] = tostring(host.layoutPath or "no layout")
    lines[#lines + 1] = "model " .. tostring(host.modelFilename or "--")

    return lines
end

--- Which palette was resolved, who asked for it, and what it had to adapt.
---@param host table Live host context.
---@return string[]
function diagnostics.theme(host)
    local theme = host.theme
    if type(theme) ~= "table" then
        return { "no theme" }
    end

    local lines = {
        "mode: " .. tostring(theme.mode),
        -- The widget option is the sole theme selection source.
        "asked by: " .. tostring(host.themeSource or "--"),
    }

    -- `build` falls back to modern-dark for an unknown name, so the fallback
    -- cannot be seen in the resolved mode alone.
    if theme.requested and theme.requested ~= theme.mode then
        lines[#lines + 1] = "fell back from " .. tostring(theme.requested)
    end

    local before = #lines
    for _, notice in ipairs(host.notices or {}) do
        lines[#lines + 1] = tostring(notice.severity) .. ": " .. tostring(notice.text)
    end
    -- Notices are deliberately kept off the error overlay, which means until
    -- now they were visible nowhere at all.
    if #lines == before then
        lines[#lines + 1] = "no notices"
    end

    return lines
end

--- One line per panel: what it is, where it sits, whether it lives.
---@param host table Live host context.
---@return string[]
function diagnostics.panels(host)
    local entries = host.panels or {}
    local rejected = host.rejected or {}
    if #entries == 0 and #rejected == 0 then
        return { "no panels" }
    end

    local function where(placement)
        placement = placement or {}
        return tostring(placement.id)
            .. " "
            .. tostring(placement.type)
            .. " "
            .. tostring(placement.colSpan or "?")
            .. "x"
            .. tostring(placement.rowSpan or "?")
    end

    -- Failures first, then the rest, because a panel this size sheds its last
    -- lines and a roll call that pushes the one broken panel off the
    -- bottom is worse than no list. The count says whether anything was shed.
    local failed, healthy = {}, {}

    -- A placement that never constructed is not in `panels` at all, because
    -- there is no instance to put there. It is the half of this report that
    -- matters, so the host keeps it separately and it is listed first.
    for _, entry in ipairs(rejected) do
        failed[#failed + 1] = where(entry.placement) .. " REJECTED " .. tostring(entry.reason or "")
    end

    for _, entry in ipairs(entries) do
        if entry.failed then
            -- Built, then raised in a later callback. Otherwise only an error
            -- banner, which may have scrolled before anyone looked.
            failed[#failed + 1] = where(entry.placement) .. " FAILED " .. tostring(entry.error or "")
        else
            healthy[#healthy + 1] = where(entry.placement) .. " ok"
        end
    end

    local lines = { (#entries + #rejected) .. " panels, " .. #failed .. " failed" }
    for _, line in ipairs(failed) do
        lines[#lines + 1] = line
    end
    for _, line in ipairs(healthy) do
        lines[#lines + 1] = line
    end
    return lines
end

--- One line per telemetry source any panel asked for.
---
--- Read from the telemetry service's own subscription table, which is the
--- table the dashboard reads from. A misspelled sensor name and a sensor the
--- radio does not have look identical on a panel, and they look identical
--- here too, which is correct: the radio cannot tell them apart either. What
--- this adds is the name that was asked for, spelled exactly as the layout
--- spelled it, which is the half nobody can see. `Alt` against `GAlt`, and
--- `Batt%` against `Bat%`, were an hour each.
---@param host table Live host context.
---@return string[]
function diagnostics.sources(host)
    local registry = host.serviceRuntime
    local telemetry = registry and registry.byId and registry.byId.telemetry
    if not telemetry then
        return { "no telemetry service" }
    end

    local entries = telemetry.entries
    if type(entries) ~= "table" or #entries == 0 then
        return { "no sources subscribed" }
    end

    -- Unbound first, for the same reason the panel list puts failures first.
    local unbound, bound = {}, {}
    for _, entry in ipairs(entries) do
        local state = entry.state or {}
        if state.known then
            bound[#bound + 1] = tostring(state.name) .. " #" .. tostring(state.id) .. " " .. tostring(state.state)
        else
            unbound[#unbound + 1] = tostring(state.name) .. " UNBOUND"
        end
    end

    local lines = { #entries .. " sources, " .. #unbound .. " unbound" }
    for _, line in ipairs(unbound) do
        lines[#lines + 1] = line
    end
    for _, line in ipairs(bound) do
        lines[#lines + 1] = line
    end
    return lines
end

--- Every section, by name.
diagnostics.SECTIONS = {
    identity = diagnostics.identity,
    theme = diagnostics.theme,
    panels = diagnostics.panels,
    sources = diagnostics.sources,
    log = diagnostics.log,
}

--- Lines for one section of one host.
---
--- Under `pcall`, because this reports on the host's own state and a report
--- that raises must not be the thing that takes the dashboard down. The host
--- isolates a failing panel anyway, but a diagnostics view failing at the
--- moment it is being consulted is worse than unhelpful, so it degrades to
--- saying so instead.
---@param host any
---@param section any
---@param maxEntries? integer Limit work to the visible log rows.
---@return string[]
function diagnostics.lines(host, section, maxEntries)
    local reporter = diagnostics.SECTIONS[section]
    if not reporter then
        return { "no section " .. tostring(section) }
    end
    if type(host) ~= "table" then
        return { "no host" }
    end

    local ok, lines = pcall(reporter, host, maxEntries)
    if not ok then
        return { "report failed:", tostring(lines) }
    end
    return lines
end

--- Compute the panel's geometry from the shared frame.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param fonts table
---@return table
function diagnostics.regionsFor(theme, themeBuilder, rect, fonts)
    -- The shared frame, not a copy of its arithmetic. `service-probe` kept its
    -- own and therefore kept drawing into the corner EdgeTX paints its menu
    -- button over, because only the shared helper knows that corner exists.
    local frame = themeBuilder.frame(theme, rect, fonts)
    local lineHeight = frame.labelHeight + 1
    local room = rect.h - frame.top - frame.bottom
    local lines = math.floor(room / lineHeight)

    if lines < 0 then
        lines = 0
    end
    if lines > MAX_LINES then
        lines = MAX_LINES
    end

    return {
        frame = frame,
        pad = frame.pad,
        content = frame.content,
        top = frame.top,
        lineHeight = lineHeight,
        lines = lines,
    }
end

--- Build the panel's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridDiagnosticsSettings
---@param services table
---@return table
function diagnostics.create(parent, rect, settings, services)
    local theme = services.theme
    local primitives = services.primitives
    local fonts = services.fonts
    local presentation = services.state("normal", settings.accent)
    local area = diagnostics.regionsFor(theme, services.themeBuilder, rect, fonts)

    local section = tostring(settings.section or "identity")
    local context = {
        panel = primitives.panel(parent, rect, theme, presentation),
        theme = theme,
        themeBuilder = services.themeBuilder,
        primitives = primitives,
        fonts = fonts,
        settings = settings,
        section = section,
        preview = services.preview,
        -- The live context, handed down by the host. Held, not copied.
        host = services.host,
        rows = {},
        texts = {},
    }

    local title = settings.label
    if type(title) ~= "string" or title == "" then
        title = section
    end

    context.title, context.badge =
        primitives.header(context.panel.root, theme, area.frame, fonts, title, presentation, services.themeBuilder)

    -- Every line object is created once, up to the cap, so a later enlargement
    -- reveals lines instead of forcing a rebuild, and the cost of building this
    -- panel does not depend on how much there turns out to be to say.
    for index = 1, MAX_LINES do
        context.rows[index] = primitives.label(context.panel.root, theme, {
            x = area.pad,
            y = area.top + (index - 1) * area.lineHeight,
            w = area.content,
            h = section == "log" and area.lineHeight - 1 or 0,
            text = "",
            color = theme.color.text,
            font = fonts.label,
        })
        context.texts[index] = ""
        if index > area.lines then
            lvgl.hide(context.rows[index])
        end
    end

    context.visibleLines = area.lines
    if section == "scheduler" then
        context.refreshCost = 0
        schedulerStats(context)
        schedulerGraph(context, rect, area)
    end
    return context
end

--- Repaint only the lines whose text changed.
---@param context table
function diagnostics.refresh(context)
    if context.section == "scheduler" then
        refreshScheduler(context)
        return
    end
    local lines = diagnostics.lines(context.host, context.section, context.visibleLines)
    local start = context.section == "log" and math.max(1, #lines - context.visibleLines + 1) or 1
    local changed = 0

    for position = 1, context.visibleLines do
        local index = context.section == "log" and context.visibleLines - position + 1 or position
        local text = lines[start + index - 1] or ""
        if text ~= context.texts[index] then
            context.texts[index] = text
            context.rows[index]:set({ text = text })
            changed = changed + 1
            -- A history shift changes every row; keep its repaint within the host budget.
            if context.section == "log" and changed == 3 then
                break
            end
        end
    end
end

--- Reposition after a zone change.
---@param context table
---@param rect AeroGridRect
function diagnostics.update(context, rect)
    local primitives = context.primitives
    local area = diagnostics.regionsFor(context.theme, context.themeBuilder, rect, context.fonts)

    primitives.resizeHeader(context, rect, area.frame, context.settings.label)

    for index = 1, MAX_LINES do
        primitives.reconcile(context.rows[index], index <= area.lines, {
            x = area.pad,
            y = area.top + (index - 1) * area.lineHeight,
            w = area.content,
            h = context.section == "log" and area.lineHeight - 1 or 0,
        })
    end

    -- A line that has just appeared holds whatever it had when it was hidden,
    -- and `refresh` only writes a line whose text changed, so the record of
    -- what was drawn is dropped for the lines that were not showing.
    for index = context.visibleLines + 1, area.lines do
        context.texts[index] = nil
    end

    context.visibleLines = area.lines
    if context.section == "scheduler" then
        schedulerGraph(context, rect, area)
    end
end

function diagnostics.destroy(context)
    if context.section == "scheduler" and context.host and not context.preview then
        context.schedulerActive = false
        for _, entry in ipairs(context.host.panels or {}) do
            if entry.instance and entry.instance ~= context and entry.instance.schedulerActive then
                return
            end
        end
        context.host.schedulerStats = nil
    end
end

return diagnostics
