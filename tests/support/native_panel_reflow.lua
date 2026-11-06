-- SPDX-License-Identifier: GPL-2.0-only

return function(host, cases, recorder, sameTree, costOnly)
    local function object(context)
        return context.root or context.panel.root
    end
    local function reset(panel, context)
        if panel.resetSession then
            for _ = 1, 200 do
                local _, pending = panel.resetSession(context, 1000)
                if not pending then
                    return
                end
            end
            error("panel reset did not finish")
        end
    end
    local function exercise(state, case)
        local panel = case.panel
        local span = case.dependencies().span
        local placement = {
            id = "subject",
            type = case.kind,
            col = 0,
            row = 0,
            colSpan = span.colSpan,
            rowSpan = span.rowSpan,
        }
        local current = {}
        for key, value in pairs(host) do
            current[key] = value
        end
        current.errors, current.notices = {}, {}
        current.recordingReflow = not costOnly
        current.reloadState, current.pageRetirement, current.reflowIndex, current.reflowEntry = nil, nil, nil, nil
        current.panels = {
            {
                module = panel,
                instance = state.partial,
                placement = placement,
                settings = case.settings,
                container = state.container,
            },
        }
        local boundBuilder = current.dashboardLoader.buildServices(current, placement).themeBuilder
        local function bind(context)
            if context.builder then
                context.builder = boundBuilder
            else
                context.themeBuilder = boundBuilder
            end
        end
        bind(state.partial)
        if not costOnly then
            bind(state.reference)
        end
        local function begin(rect, corner)
            current.zone = {
                x = 0,
                y = 0,
                xabs = corner and 0 or 1000,
                yabs = corner and 0 or 1000,
                w = math.ceil((rect.w - (span.colSpan - 1) * 4) * 4 / span.colSpan) + 12,
                h = math.ceil((rect.h - (span.rowSpan - 1) * 4) * 4 / span.rowSpan) + 12,
            }
            local actual = lvgl
            lvgl = setmetatable({
                isAppMode = function()
                    return true
                end,
            }, { __index = actual })
            current.dashboardLifecycle.beginReflow(current)
            lvgl = actual
            assert((current.reserved ~= nil) == corner, case.name .. ": real menu reservation was not exercised")
            local placed = assert(current.dashboardLoader.panelRect(current, placement))
            assert(placed.w == rect.w and placed.h == rect.h, case.name .. ": requested span changed")
        end
        for pass = 1, 4 do
            local rect = pass == 1 and case.rect
                or pass == 3 and { x = 0, y = 0, w = 90, h = 50 }
                or { x = 0, y = 0, w = 800, h = case.kind == "output" and 1200 or 480 }
            begin(rect, pass >= 3)
            local interrupted, cancelled, done
            for advance = 1, 400 do
                if advance == 2 and current.reflowEntry and not interrupted then
                    if pass == 2 then
                        rect = { x = 0, y = 0, w = case.rect.w + 60, h = case.rect.h + 80 }
                        begin(rect, pass >= 3)
                    elseif pass == 3 then
                        reset(panel, state.partial)
                        if not costOnly then
                            reset(panel, state.reference)
                        end
                    elseif pass == 4 then
                        panel.update(state.partial, rect, case.settings, nil, placement)
                    end
                    interrupted = true
                elseif advance >= 3 and pass == 2 and panel.cancelRefresh and not cancelled then
                    panel.cancelRefresh(state.partial)
                    cancelled = true
                end
                done = not current.dashboardLifecycle.advanceReflow(current)
                assert(#current.errors == 0, case.name .. ": " .. table.concat(current.errors, "; "))
                assert(not current.panels[1].failed, case.name .. ": dispatch failed")
                if done then
                    break
                end
            end
            assert(done and not state.partial.reflowWork, case.name .. ": lifecycle reflow did not finish")
            if not costOnly then
                panel.update(state.reference, rect, case.settings, nil, placement)
                if case.kind == "output" then
                    case.settle(case, state.reference)
                end
                if case.kind ~= "chart" then
                    sameTree(object(state.reference), object(state.partial), case.name .. "/geometry-" .. pass)
                end
            end
            case.settle(case, state.partial)
            if not costOnly then
                case.settle(case, state.reference)
                sameTree(object(state.reference), object(state.partial), case.name .. "/refreshed-" .. pass)
            end
        end
    end
    if not costOnly then
        local state = recorder(lvgl, cases, sameTree, host.page, exercise, true)
        state.recordingTrees = true
        return state
    end
    local page = lvgl.box(host.page, { x = 0, y = 0, w = 1000, h = 1400 })
    local state = { index = 1, checked = 0, total = #cases, phase = "begin", costOnly = true }
    function state:step()
        local case = cases[self.index]
        if not case then
            return true
        end
        if self.phase == "begin" then
            self.container = lvgl.box(page, { x = 0, y = 0, w = 1000, h = 1400 })
            local services = case.dependencies()
            self.partial = case.panel.create(self.container, case.rect, case.settings, services)
            if services.seedHistory then
                services.seedHistory()
            end
            case.settle(case, self.partial)
            self.phase = "exercise"
        elseif self.phase == "exercise" then
            exercise(self, case)
            self.phase = "cleanup"
        else
            page:clear()
            self.partial, self.container = nil, nil
            self.index, self.checked, self.phase = self.index + 1, self.checked + 1, "begin"
        end
        return false
    end
    return state
end
