-- SPDX-License-Identifier: GPL-2.0-only

-- Record the final tree while forwarding every operation to real native LVGL.
return function(real, cases, sameTree, parent)
    local api = setmetatable({}, { __index = real })
    local function record(kind, native, properties, owner)
        local node = { kind = kind, native = native, properties = {}, children = {}, hidden = false }
        for key, value in pairs(properties) do
            node.properties[key] = value
        end
        function node:set(changes)
            self.native:set(changes)
            for key, value in pairs(changes) do
                self.properties[key] = value
            end
        end
        if owner then
            owner.children[#owner.children + 1] = node
        end
        return node
    end
    for _, kind in ipairs({ "box", "rectangle", "label", "arc" }) do
        api[kind] = function(owner, properties)
            local native = real[kind](owner.native, properties)
            return record(kind, native, properties, owner)
        end
    end
    for _, key in ipairs({ "show", "hide" }) do
        api[key] = function(node)
            real[key](node.native)
            node.hidden = key == "hide"
        end
    end
    local function withApi(fn, ...)
        local previous = lvgl
        lvgl = api
        local ok, first = pcall(fn, ...)
        lvgl = previous
        assert(ok, first)
        return first
    end
    local roots = {
        real.box(parent, { x = 0, y = 0, w = 800, h = 480 }),
        real.box(parent, { x = 0, y = 0, w = 800, h = 480 }),
    }
    local state = { index = 1, checked = 0, total = #cases, phase = "begin" }
    function state:step()
        local case = cases[self.index]
        if not case then
            return true
        end
        if self.phase == "begin" then
            local services = case.dependencies()
            local owner = record("box", roots[1], {}, nil)
            self.reference = withApi(case.panel.create, owner, case.rect, case.settings, services)
            services = case.dependencies()
            services.staged = true
            owner = record("box", roots[2], {}, nil)
            self.partial = withApi(case.panel.create, owner, case.rect, case.settings, services)
            assert(self.partial.createStage and not self.partial.panel, case.name)
            self.phase = "construct"
        elseif self.phase == "construct" then
            for _ = 1, 40 do
                if withApi(case.panel.construct, self.partial, case.rect) then
                    assert(not self.partial.createStage and not self.partial.createParent)
                    sameTree(self.reference.panel.root, self.partial.panel.root, case.name .. "/native")
                    self.phase = "refresh"
                    break
                end
            end
            assert(self.phase == "refresh", case.name .. ": native construction did not finish")
        elseif self.phase == "refresh" then
            withApi(case.panel.refresh, self.reference)
            withApi(case.panel.refresh, self.partial)
            sameTree(self.reference.panel.root, self.partial.panel.root, case.name .. "/native-refresh")
            self.phase = "cleanup"
        else
            -- Deleted native objects must be collected before the next build.
            roots[1]:clear()
            roots[2]:clear()
            self.reference, self.partial = nil, nil
            self.index, self.checked, self.phase = self.index + 1, self.checked + 1, "begin"
        end
        return false
    end
    return state
end
