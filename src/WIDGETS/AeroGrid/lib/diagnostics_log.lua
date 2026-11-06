-- SPDX-License-Identifier: GPL-2.0-only

local log = { RUNTIME_API = 1, DEFAULT_LIMIT = 64, MAX_LIMIT = 256 }
log.__index = log

function log.new()
    return setmetatable({
        hosts = setmetatable({}, { __mode = "k" }),
        nextHost = 0,
        entries = {},
        first = 1,
        count = 0,
    }, log)
end

function log:register(host)
    self.nextHost = self.nextHost + 1
    self.hosts[host] = self.nextHost
end

local function requestedLimit(entry)
    if
        not entry.failed
        and entry.placement.type == "host-diagnostics"
        and entry.settings.section == "log"
        and not entry.instance.preview
    then
        local requested = entry.settings.maxEntries or log.DEFAULT_LIMIT
        if requested ~= requested then
            requested = log.DEFAULT_LIMIT
        end
        return math.max(1, math.floor(requested))
    end
    return 0
end

--- Derive demand from live panels so removal, failure and previews cannot keep logging enabled.
function log:limit()
    local limit = 0
    for host in pairs(self.hosts) do
        for _, entry in ipairs(host.panels or {}) do
            limit = math.max(limit, requestedLimit(entry))
        end
    end
    return math.min(limit, log.MAX_LIMIT)
end

function log:trim(limit)
    while self.count > limit do
        self.entries[self.first] = nil
        self.first = self.first % log.MAX_LIMIT + 1
        self.count = self.count - 1
    end
end

function log:append(host, panel, text, now)
    local limit = self:limit()
    if limit == 0 then
        return
    end
    self:trim(limit - 1)
    local index = (self.first + self.count - 1) % log.MAX_LIMIT + 1
    self.entries[index] = {
        time = now,
        host = tostring(host.layoutName) .. "#" .. tostring(self.hosts[host]),
        panel = panel,
        text = text,
    }
    self.count = self.count + 1
end

function log:read(maxEntries)
    local limit = self:limit()
    if limit > 0 then
        self:trim(limit)
    end
    local entries = {}
    for offset = math.max(0, self.count - (maxEntries or self.count)), self.count - 1 do
        entries[#entries + 1] = self.entries[(self.first + offset - 1) % log.MAX_LIMIT + 1]
    end
    return entries
end

--- Freeze the bounded ring before yielding; later appends cannot change the viewer.
function log:startSnapshot()
    return {
        ring = table.move(self.entries, 1, log.MAX_LIMIT, 1, {}),
        first = self.first,
        count = self.count,
        stage = "demand",
        limit = 0,
        panel = 1,
        entries = {},
    }
end

local function demandStep(self, work)
    local entry = work.host and (work.host.panels or {})[work.panel]
    if entry then
        work.limit = math.min(log.MAX_LIMIT, math.max(work.limit, requestedLimit(entry)))
        work.panel = work.panel + 1
    else
        work.host = next(self.hosts, work.host)
        work.panel = 1
        return not work.host
    end
end

function log:advanceSnapshot(work)
    if work.stage == "demand" then
        if demandStep(self, work) then
            work.offset = work.limit > 0 and math.max(0, work.count - work.limit) or 0
            work.stage = "copy"
        end
        return
    end
    for offset = work.offset, math.min(work.count - 1, work.offset + 15) do
        work.entries[#work.entries + 1] = work.ring[(work.first + offset - 1) % log.MAX_LIMIT + 1]
    end
    work.offset = math.min(work.count, work.offset + 16)
    if work.offset == work.count then
        work.ring = nil
        return work.entries
    end
end

--- Read a visible panel snapshot, advancing one demand entry or eviction per call.
function log:readVisibleStep(work, maxEntries)
    assert(maxEntries >= 0 and maxEntries <= 12 and maxEntries % 1 == 0, "visible log limit must be 0 to 12")
    if not work.stage then
        work.stage, work.limit, work.panel = "demand", 0, 1
    end
    if work.stage == "demand" then
        if demandStep(self, work) then
            work.stage = "trim"
        end
        return
    end
    if work.limit > 0 and self.count > work.limit then
        self:trim(self.count - 1)
        return
    end
    local entries = {}
    for offset = math.max(0, self.count - maxEntries), self.count - 1 do
        entries[#entries + 1] = self.entries[(self.first + offset - 1) % log.MAX_LIMIT + 1]
    end
    return entries
end

function log.format(entry)
    local seconds = math.floor(entry.time / 100)
    return string.format(
        "%02d:%02d:%02d [%s/%s] %s",
        math.floor(seconds / 3600),
        math.floor(seconds / 60) % 60,
        seconds % 60,
        entry.host,
        entry.panel,
        entry.text
    )
end

return log
