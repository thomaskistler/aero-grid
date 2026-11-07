-- SPDX-License-Identifier: GPL-2.0-only

-- Exercise the unmodified loader and enclosing App-rebuild atom with real LVGL.
return function(host, cases)
    local page = lvgl.box(host.page, { x = 0, y = 0, w = 800, h = 480 })
    local state = { index = 1, checked = 0, total = #cases, phase = "begin", pass = 1 }
    local function zoneFor(rect, span)
        return {
            x = 0,
            y = 0,
            w = math.ceil((rect.w - (span.colSpan - 1) * 4) * 4 / span.colSpan) + 12,
            h = math.ceil((rect.h - (span.rowSpan - 1) * 4) * 4 / span.rowSpan) + 12,
        }
    end
    function state:step()
        local case = cases[self.index]
        if not case then
            return true
        end
        if self.phase == "begin" then
            local dependencies, current = case.dependencies(), {}
            for key, value in pairs(host) do
                current[key] = value
            end
            current.theme = dependencies.theme
            current.serviceRuntime = { byId = { telemetry = dependencies.telemetry, model = dependencies.model } }
            current.panels, current.errors, current.rejected, current.notices = {}, {}, {}, {}
            current.page, current.errorLabel = page, nil
            current.reserved = self.pass % 2 == 0 and { w = 47, h = 45 } or nil
            current.stage, current.reloadState, current.pageRetirement, current.pendingConstruction = nil, nil, nil, nil
            current.zone = zoneFor(case.rect, dependencies.span)
            local placement = {
                id = "subject",
                type = case.kind,
                col = 0,
                row = 0,
                colSpan = dependencies.span.colSpan,
                rowSpan = dependencies.span.rowSpan,
            }
            current.appRebuild = {
                phase = "build",
                index = 1,
                entry = { module = case.panel, placement = placement },
                prepared = {
                    module = case.panel,
                    settings = case.settings,
                    settingsValidation = case.settingsValidation,
                },
            }
            if self.pass > 2 then
                current.pendingPanel = current.appRebuild.prepared
                current.pendingPlacement = placement
                current.appRebuild, current.stage = nil, "panel-build"
            end
            self.current, self.placement, self.resized, self.phase = current, placement, nil, "advance"
        elseif self.phase == "advance" then
            -- Each production atom has its own counter window. Only the audit
            -- controller drains them here; deletion still gets a separate turn.
            for _ = 1, 40 do
                local current = self.current
                local partial = current.pendingConstruction
                local stage = partial and partial.instance.createStage
                if self.pass % 2 == 0 and stage == "controls" and not self.resized then
                    current.zone = zoneFor({ w = case.rect.w + 30, h = case.rect.h + 40 }, self.placement)
                    self.resized = 1
                elseif self.resized == 1 and (stage == "place" or stage == "reading" or stage == "reflow") then
                    current.zone = zoneFor({ w = case.rect.w + 60, h = case.rect.h + 80 }, self.placement)
                    self.resized = 2
                end
                if self.pass > 2 then
                    current.dashboardLoader.advanceLoad(current)
                else
                    current.dashboardLifecycle.advanceAppRebuild(current)
                end
                assert(#current.errors == 0, case.name .. ": " .. table.concat(current.errors, "; "))
                if self.pass <= 2 and not current.appRebuild or self.pass > 2 and current.stage == "panels" then
                    assert(#current.panels == 1 and not current.pendingConstruction, case.name)
                    local entry = current.panels[1]
                    local instance = entry.instance
                    local rect = assert(current.dashboardLoader.panelRect(current, entry.placement))
                    assert(not instance.createStage and instance.panel.width == rect.w)
                    assert(instance.panel.height == rect.h)
                    self.phase = "cleanup"
                    break
                end
            end
            assert(self.phase == "cleanup", case.name .. ": native construction did not finish")
        else
            page:clear()
            self.current, self.phase = nil, "begin"
            if self.pass < 4 then
                self.pass = self.pass + 1
            else
                self.index, self.checked, self.pass = self.index + 1, self.checked + 1, 1
            end
        end
        return false
    end
    return state
end
