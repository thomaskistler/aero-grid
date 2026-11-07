-- SPDX-License-Identifier: GPL-2.0-only

return function(host)
    local kinds = {
        "metric",
        "chart",
        "state",
        "navigation",
        "output",
        "rx-battery",
        "link-status",
        "tx-battery",
        "flight-timer",
        "flight-counter",
        "flight-mode",
        "model-identity",
        "trim-panel",
        "theme-showcase",
        "service-probe",
        "host-diagnostics",
    }
    local state = { index = 1, pass = 1, phase = "begin", checked = 0, total = #kinds * 2 + 6 }
    function state:step()
        local kind = kinds[self.index]
        if not kind then
            self.done = true
            return true
        end
        if self.phase == "begin" then
            local current = {}
            for key, value in pairs(host) do
                current[key] = value
            end
            current.errors, current.rejected, current.notices, current.panels = {}, {}, {}, {}
            current.reloadState, current.pageRetirement, current.pendingConstruction = nil, nil, nil
            current.panelPreparation, current.pendingPanel = nil, nil
            current.zone = { x = 0, y = 0, w = 480, h = 272 }
            local config = {}
            if kind == "state" then
                config.entries = { { label = "SW1", states = { { switch = "SA^", text = "UP" } } } }
            elseif kind == "metric" or kind == "chart" then
                config.metrics = { { source = "S01", precision = 1 }, { source = "S02" } }
            end
            for index = 1, 64 do
                config["future" .. index] = index
                if self.pass > 2 then
                    local entry = kind == "state" and config.entries[1] or config.metrics[1]
                    entry["future" .. index] = index
                    if kind == "state" then
                        entry.states[1]["future" .. index] = index
                    end
                end
            end
            local placement = {
                id = "subject",
                type = kind,
                col = 0,
                row = 0,
                colSpan = kind == "theme-showcase" and 4 or 2,
                rowSpan = kind == "theme-showcase" and 4 or 2,
                config = config,
            }
            if self.pass % 2 == 0 then
                current.stage = nil
                current.appRebuild = { phase = "prepare", entry = { module = { id = kind }, placement = placement } }
            else
                current.appRebuild, current.pendingPlacement, current.stage = nil, placement, "panel-prepare"
            end
            self.current, self.turn, self.phase = current, 0, "advance"
        elseif self.phase == "advance" then
            local current = self.current
            self.turn = self.turn + 1
            if self.turn == 5 then
                current.zone = { x = 0, y = 0, w = 640, h = 360 }
            end
            if self.pass % 2 == 0 then
                current.dashboardLifecycle.advanceAppRebuild(current)
            else
                current.dashboardLoader.advanceLoad(current)
            end
            assert(#current.panels == 0 and not current.pendingConstruction, "preparation published native objects")
            local prepared = self.pass % 2 == 0 and current.appRebuild.prepared or current.pendingPanel
            if prepared then
                local expected = self.pass <= 2 and 64 or kind == "state" and 192 or 128
                assert(#current.errors == expected, "preparation omitted validation warnings")
                assert(#current.rejected == 0 and prepared.settings.future64 == 64)
                if prepared.module.validateSettings then
                    assert(prepared.settingsValidation and prepared.settingsValidation.settings == prepared.settings)
                    assert(
                        #prepared.settingsValidation.warnings == expected - 64,
                        "constructor validation proof lost warnings"
                    )
                end
                self.phase = "finish"
            end
            assert(self.turn < 1000, "preparation did not complete")
        else
            self.current, self.phase = nil, "begin"
            self.checked = self.checked + 1
            if self.pass < (self.index <= 3 and 4 or 2) then
                self.pass = self.pass + 1
            else
                self.index, self.pass = self.index + 1, 1
            end
        end
        return false
    end
    return state
end
