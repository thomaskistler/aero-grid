-- SPDX-License-Identifier: GPL-2.0-only

local cache = {}
cache.__index = cache

-- Bump when either the file format or the sampling algorithm changes.
local VERSION = 1
local MAX_SIZE = 65536

function cache.new(yaml, file, filename, operations)
    return setmetatable({
        yaml = yaml,
        file = file,
        filename = filename,
        operations = file.operations(operations),
    }, cache)
end

function cache:lookup(filename, key)
    self.target = { file = filename, key = key }
    self.brightness, self.reason, self.saving, self.stage = nil, nil, false, "read"
end

function cache:save(brightness)
    self.target.brightness = brightness
    self.reason, self.saving, self.stage = nil, true, "read"
end

local function completeRead(self, reason)
    if reason then
        self.reason = reason
        self.entries, self.brightness, self.targetIndex = {}, nil, nil
    end
    self.tokens = nil
    if self.saving then
        self.entries[self.targetIndex or (#self.entries + 1)] = self.target
        self.output, self.index, self.stage = { "version: " .. VERSION .. "\nbackgrounds:\n" }, 1, "serialize"
        return false
    end
    self.stage = nil
    return true
end

local function valid(entry)
    return type(entry) == "table"
        and type(entry.file) == "string"
        and #entry.file > 0
        and type(entry.key) == "string"
        and #entry.key > 0
        and type(entry.brightness) == "number"
        and entry.brightness >= 0
        and entry.brightness <= 255
        and entry.brightness % 1 == 0
end

--- Bound parsing and serialization to a few lines or one background per call.
function cache:step()
    if self.stage == "read" then
        self.entries, self.seen, self.source, self.size, self.targetIndex = {}, {}, nil, nil, nil
        local info = self.operations.stat(self.filename)
        if not info then
            return completeRead(self)
        end
        self.size = info.size
        if type(info.size) ~= "number" or info.size > MAX_SIZE then
            return completeRead(self, "background cache is too large")
        end
        local source, message = self.file.read(self.filename, self.operations)
        if not source then
            self.reason, self.stage = message, nil
            return true
        end
        self.source, self.position, self.line, self.tokens, self.stage = source, 1, 1, {}, "tokenize"
    elseif self.stage == "tokenize" then
        local cursor, lines = self.position, 0
        while cursor <= #self.source and lines < 8 do
            local stop = string.find(self.source, "\n", cursor, true) or (#self.source + 1)
            if stop - cursor > 512 then
                return completeRead(self, "background cache line is too long")
            end
            if stop - self.position > 512 then
                break
            end
            cursor, lines = stop + 1, lines + 1
        end
        local position, line, message =
            self.yaml.tokenizeChunk(self.source, self.position, self.line, lines, self.tokens)
        if message then
            return completeRead(self, "invalid background cache: " .. tostring(message))
        end
        self.position, self.line = position, line
        if not position then
            self.stage = "header"
        end
    elseif self.stage == "header" then
        local tokens = self.tokens
        local header = tokens[1] and #tokens[1].content < 32 and self.yaml.build({ tokens[1] })
        if not header or type(header.version) ~= "number" then
            return completeRead(self, "invalid background cache version")
        end
        if header.version ~= VERSION then
            self.entries = {}
            return completeRead(self)
        end
        if not tokens[2] or tokens[2].indent ~= 0 or tokens[2].content ~= "backgrounds:" then
            return completeRead(self, "invalid background cache entries")
        end
        self.index, self.stage = 3, "entries"
    elseif self.stage == "entries" then
        local index, tokens = self.index, self.tokens
        if index > #tokens then
            return completeRead(self)
        end
        if
            not tokens[index + 2]
            or tokens[index].indent ~= 2
            or not string.match(tokens[index].content, "^%- ")
            or tokens[index + 1].indent ~= 4
            or tokens[index + 2].indent ~= 4
            or (tokens[index + 3] and tokens[index + 3].indent > 2)
        then
            return completeRead(self, "invalid background cache entry")
        end
        local entry, nextIndex, message = self.yaml.itemAt(tokens, index, 2)
        if message or nextIndex ~= index + 3 or not valid(entry) or self.seen[entry.file] then
            return completeRead(self, "invalid background cache entry: " .. tostring(message or "invalid fields"))
        end
        self.seen[entry.file] = true
        self.entries[#self.entries + 1] = entry
        if entry.file == self.target.file then
            self.targetIndex = #self.entries
            if entry.key == self.target.key then
                self.brightness = entry.brightness
            end
        end
        self.index = nextIndex
    elseif self.stage == "serialize" then
        local entry = self.entries[self.index]
        if entry then
            local serialized, message = self.yaml.serialize({ entry })
            if not serialized then
                self.reason, self.stage = message, nil
                return true
            end
            self.output[#self.output + 1] = string.gsub(serialized, "([^\n]+)", "  %1")
            self.index = self.index + 1
        else
            self.stage = "write"
        end
    elseif self.stage == "write" then
        local serialized = table.concat(self.output)
        if #serialized > MAX_SIZE then
            self.reason, self.stage = "background cache is too large to save", nil
            return true
        end
        local changed = false
        local function unchanged(rotated)
            if rotated then
                return true
            end
            local info = self.operations.stat(self.filename)
            local source = info
                    and type(info.size) == "number"
                    and info.size <= MAX_SIZE
                    and self.file.read(self.filename, self.operations)
                or nil
            changed = (info and info.size or nil) ~= self.size or source ~= self.source
            return not changed, "background cache changed while saving"
        end
        local saved, message = self.file.write(self.filename, serialized, self.operations, unchanged)
        if changed then
            self.stage = "read"
            return false
        end
        if not saved then
            self.reason = message
        end
        self.source, self.entries, self.output, self.seen, self.stage = nil, nil, nil, nil, nil
        return true
    else
        return true
    end
    return false
end

return cache
