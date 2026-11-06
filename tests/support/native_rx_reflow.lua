-- SPDX-License-Identifier: GPL-2.0-only

return function(host, cases, recorder, sameTree, costOnly)
    local function zoneFor(rect, placement)
        return {
            x = 0,
            y = 0,
            w = math.ceil((rect.w - (placement.colSpan - 1) * 4) * 4 / placement.colSpan) + 12,
            h = math.ceil((rect.h - (placement.rowSpan - 1) * 4) * 4 / placement.rowSpan) + 12,
        }
    end
    local function exercise(state, case)
        local panel = case.panel
        local span = case.dependencies().span
        local placement =
            { id = "subject", type = "rx-battery", col = 0, row = 0, colSpan = span.colSpan, rowSpan = span.rowSpan }
        local current = {}
        for key, value in pairs(host) do
            current[key] = value
        end
        current.errors, current.notices = {}, {}
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
        for pass = 1, 3 do
            local rect = pass == 2 and { x = 0, y = 0, w = case.rect.w + 30, h = case.rect.h + 40 } or case.rect
            current.zone = zoneFor(rect, placement)
            current.dashboardLifecycle.beginReflow(current)
            local resized, cancelled, reset, done
            for advance = 1, 40 do
                local work = state.partial.reflowWork
                if pass == 2 and work and work.stage == "fit" and advance >= 3 and not resized then
                    rect = { x = 0, y = 0, w = case.rect.w + 60, h = case.rect.h + 80 }
                    current.zone = zoneFor(rect, placement)
                    current.dashboardLifecycle.beginReflow(current)
                    resized = true
                elseif pass == 2 and work and work.stage == "place" and not cancelled then
                    panel.cancelRefresh(state.partial)
                    cancelled = true
                elseif pass == 3 and work and work.stage == "place" and not reset then
                    panel.resetSession(state.partial, 1000)
                    if not costOnly then
                        panel.resetSession(state.reference, 1000)
                    end
                    reset = true
                end
                done = not current.dashboardLifecycle.advanceReflow(current)
                assert(#current.errors == 0, case.name .. ": " .. table.concat(current.errors, "; "))
                if done then
                    break
                end
            end
            assert(done and not state.partial.reflowWork, case.name .. ": lifecycle reflow did not finish")
            assert(state.partial.rect.w == rect.w and state.partial.rect.h == rect.h)
            if not costOnly then
                panel.update(state.reference, rect)
                sameTree(state.reference.panel.root, state.partial.panel.root, case.name .. "/native-reflow-" .. pass)
                panel.refresh(state.reference)
            end
            panel.refresh(state.partial)
            if not costOnly then
                sameTree(
                    state.reference.panel.root,
                    state.partial.panel.root,
                    case.name .. "/native-reflow-refresh-" .. pass
                )
            end
        end
    end
    if not costOnly then
        return recorder(lvgl, cases, sameTree, host.page, exercise)
    end
    local page = lvgl.box(host.page, { x = 0, y = 0, w = 1000, h = 1000 })
    local state = { index = 1, checked = 0, total = #cases, phase = "begin", costOnly = true }
    function state:step()
        local case = cases[self.index]
        if not case then
            return true
        end
        if self.phase == "begin" then
            self.container = lvgl.box(page, { x = 0, y = 0, w = 1000, h = 1000 })
            self.partial = case.panel.create(self.container, case.rect, case.settings, case.dependencies())
            case.panel.refresh(self.partial)
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
