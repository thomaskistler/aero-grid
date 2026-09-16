-- SPDX-License-Identifier: GPL-2.0-only

--- Constrained YAML reader for AeroGrid's phase-one layout schema.
--- Supports two-space mappings, sequences, strings, numbers, booleans, and null.
--- General YAML features such as anchors, tags, and flow collections are excluded.

---@class AeroGridYamlToken
---@field indent integer
---@field content string
---@field line integer

local yaml = {}

--- Remove surrounding whitespace.
---@param value string
---@return string
local function trim(value)
  return string.match(value, "^%s*(.-)%s*$")
end

--- Strip an unquoted YAML comment while preserving hashes inside strings.
--- Most lines contain no hash at all, so the expensive scan is skipped unless
--- one is present. EdgeTX budgets 20000 VM instructions per widget callback,
--- which a per-character loop over a whole layout file would exhaust.
---@param line string
---@return string
local function stripComment(line)
  if not string.find(line, "#", 1, true) then return line end

  local quote = nil
  local escaped = false

  for index = 1, #line do
    local char = string.byte(line, index)
    if escaped then
      escaped = false
    elseif quote == 34 and char == 92 then
      escaped = true
    elseif quote then
      if char == quote then quote = nil end
    elseif char == 34 or char == 39 then
      quote = char
    elseif char == 35 then
      local previous = index > 1 and string.byte(line, index - 1) or nil
      if previous == nil or previous == 32 or previous == 9 then
        return string.sub(line, 1, index - 1)
      end
    end
  end

  return line
end

--- Decode the small escape subset accepted in double-quoted values.
---@param value string
---@return string
local function decodeDoubleQuoted(value)
  local replacements = {
    ['\\"'] = '"',
    ["\\n"] = "\n",
    ["\\t"] = "\t",
    ["\\\\"] = "\\",
  }

  return (string.gsub(value, '\\["nt\\]', replacements))
end

--- Parse a scalar supported by the constrained AeroGrid schema.
---@param value string
---@return string|number|boolean|table|nil
local function parseScalar(value)
  value = trim(value)

  if string.sub(value, 1, 1) == '"' and string.sub(value, -1) == '"' then
    return decodeDoubleQuoted(string.sub(value, 2, -2))
  end
  if string.sub(value, 1, 1) == "'" and string.sub(value, -1) == "'" then
    return (string.gsub(string.sub(value, 2, -2), "''", "'"))
  end
  -- Flow collections are otherwise unsupported, but the empty forms are the
  -- natural way to write "no entries" and must not become plain strings.
  if value == "[]" or value == "{}" then return {} end
  if value == "true" then return true end
  if value == "false" then return false end
  if value == "null" or value == "~" then return nil end

  local number = tonumber(value)
  if number ~= nil then return number end

  return value
end

--- Convert source text into significant indentation-aware tokens.
--- Exposed separately from `build` so the host can spread a large layout over
--- more than one widget callback and stay inside EdgeTX's instruction budget.
---@param text string
---@return AeroGridYamlToken[]? tokens
---@return string? error
function yaml.tokenize(text)
  if type(text) ~= "string" then
    return nil, "YAML input must be a string"
  end

  local tokens = {}
  local lineNumber = 0

  for rawLine in string.gmatch(text .. "\n", "(.-)\r?\n") do
    lineNumber = lineNumber + 1
    if string.find(rawLine, "\t", 1, true) then
      return nil, "line " .. lineNumber .. ": tabs are not supported"
    end

    local line = stripComment(rawLine)
    if string.find(line, "%S") then
      local spaces = #(string.match(line, "^( *)") or "")
      if spaces % 2 ~= 0 then
        return nil, "line " .. lineNumber .. ": indentation must use two spaces"
      end
      tokens[#tokens + 1] = {
        indent = spaces,
        content = trim(line),
        line = lineNumber,
      }
    end
  end

  return tokens
end

local tokenize = yaml.tokenize

local parseBlock

--- Split a mapping token into its key and unparsed value.
---@param token AeroGridYamlToken
---@param value string
---@return string? key
---@return string? remainder
---@return string? error
local function splitMapping(token, value)
  local key, remainder = string.match(value, "^([%a_][%w_-]*):%s*(.*)$")
  if not key then
    return nil, nil, "line " .. token.line .. ": expected a mapping entry"
  end
  return key, remainder
end

--- Parse mapping entries at one indentation level.
---@param tokens AeroGridYamlToken[]
---@param index integer
---@param indent integer
---@param result? table
---@return table? result
---@return integer nextIndex
---@return string? error
local function parseMap(tokens, index, indent, result)
  result = result or {}

  while index <= #tokens do
    local token = tokens[index]
    if token.indent < indent then break end
    if token.indent > indent then
      return nil, index, "line " .. token.line .. ": unexpected indentation"
    end
    if string.match(token.content, "^-%s*") then break end

    local key, remainder, splitError = splitMapping(token, token.content)
    if splitError then return nil, index, splitError end
    if not key or remainder == nil then
      return nil, index, "line " .. token.line .. ": missing mapping key"
    end
    if result[key] ~= nil then
      return nil, index, "line " .. token.line .. ": duplicate key " .. key
    end

    index = index + 1
    if remainder == "" then
      local nextToken = tokens[index]
      if nextToken and nextToken.indent > indent then
        if nextToken.indent ~= indent + 2 then
          return nil, index, "line " .. nextToken.line .. ": indentation jumped more than one level"
        end
        local child, nextIndex, childError = parseBlock(tokens, index, indent + 2)
        if childError then return nil, nextIndex, childError end
        if child == nil then return nil, nextIndex, "line " .. token.line .. ": invalid nested value" end
        result[key] = child
        index = nextIndex
      else
        result[key] = {}
      end
    else
      local scalar = parseScalar(remainder)
      if scalar ~= nil then result[key] = scalar end
    end
  end

  return result, index
end

--- Parse sequence entries at one indentation level.
---@param tokens AeroGridYamlToken[]
---@param index integer
---@param indent integer
---@return table? result
---@return integer nextIndex
---@return string? error
local function parseList(tokens, index, indent)
  local result = {}

  while index <= #tokens do
    local token = tokens[index]
    if token.indent < indent then break end
    if token.indent > indent then
      return nil, index, "line " .. token.line .. ": unexpected indentation"
    end

    local remainder = string.match(token.content, "^-%s*(.*)$")
    if remainder == nil then break end
    index = index + 1

    if remainder == "" then
      local nextToken = tokens[index]
      if not nextToken or nextToken.indent ~= indent + 2 then
        return nil, index, "line " .. token.line .. ": list item requires an indented value"
      end
      local child, nextIndex, childError = parseBlock(tokens, index, indent + 2)
      if childError then return nil, nextIndex, childError end
      result[#result + 1] = child
      index = nextIndex
    elseif string.match(remainder, "^[%a_][%w_-]*:") then
      local item = {}
      local key, value, splitError = splitMapping(token, remainder)
      if splitError then return nil, index, splitError end
      if not key or value == nil then
        return nil, index, "line " .. token.line .. ": missing mapping key"
      end
      if value == "" then
        item[key] = {}
      else
        local scalar = parseScalar(value)
        if scalar ~= nil then item[key] = scalar end
      end

      local nextToken = tokens[index]
      if nextToken and nextToken.indent > indent then
        if nextToken.indent ~= indent + 2 then
          return nil, index, "line " .. nextToken.line .. ": indentation jumped more than one level"
        end
        local parsedItem, nextIndex, mapError = parseMap(tokens, index, indent + 2, item)
        if mapError then return nil, nextIndex, mapError end
        if not parsedItem then
          return nil, nextIndex, "line " .. nextToken.line .. ": invalid mapping"
        end
        item = parsedItem
        index = nextIndex
      end
      result[#result + 1] = item
    else
      result[#result + 1] = parseScalar(remainder)
    end
  end

  return result, index
end

--- Dispatch a nested block to the mapping or sequence parser.
---@param tokens AeroGridYamlToken[]
---@param index integer
---@param indent integer
---@return table? result
---@return integer nextIndex
---@return string? error
parseBlock = function(tokens, index, indent)
  local token = tokens[index]
  if not token then return {}, index end
  if string.match(token.content, "^-%s*") then
    return parseList(tokens, index, indent)
  end
  return parseMap(tokens, index, indent)
end

--- Build a document from previously produced tokens.
---@param tokens AeroGridYamlToken[]
---@return table? document
---@return string? error
function yaml.build(tokens)
  if type(tokens) ~= "table" then
    return nil, "YAML tokens must be a table"
  end
  if #tokens == 0 then return {}, nil end
  if tokens[1].indent ~= 0 then
    return nil, "line " .. tokens[1].line .. ": document must start at column one"
  end

  local result, index, parseError = parseBlock(tokens, 1, 0)
  if parseError then return nil, parseError end
  if index <= #tokens then
    return nil, "line " .. tokens[index].line .. ": unexpected content"
  end

  return result
end

--- Parse constrained YAML text into Lua mappings and sequences.
--- Convenience wrapper; the host stages `tokenize` and `build` separately.
---@param text string
---@return table? document
---@return string? error
function yaml.parse(text)
  local tokens, tokenError = tokenize(text)
  if not tokens then return nil, tokenError end

  return yaml.build(tokens)
end

return yaml