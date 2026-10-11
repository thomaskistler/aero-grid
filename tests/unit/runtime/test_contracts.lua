-- SPDX-License-Identifier: GPL-2.0-only

local root = ... or "."
local fixture = assert(loadfile(root .. "/tests/support/runtime_fixture.lua"))(root)
local firmware = fixture.firmware
local loadModule = fixture.loadModule
local grid = fixture.grid
local yaml = fixture.yaml
local layout = fixture.layout
local layoutStore = fixture.layoutStore
local panelHost = fixture.panelHost
local theme = fixture.theme
local primitives = fixture.primitives
local services = fixture.services
local telemetryService = fixture.telemetryService
local modelService = fixture.modelService
local assertEqual = fixture.assertEqual

local function testGridGeometry()
    local zone = { w = 480, h = 272 }
    local left = assert(grid.rect(zone, { col = 0, row = 0, colSpan = 2, rowSpan = 2 }, 4, 4, 4))
    local right = assert(grid.rect(zone, { col = 2, row = 0, colSpan = 2, rowSpan = 4 }, 4, 4, 4))

    assertEqual(left.x, 0)
    assertEqual(left.y, 0)
    assertEqual(left.w, 238)
    assertEqual(left.h, 134)
    assertEqual(right.x, 242)
    assertEqual(right.y, 0)
    assertEqual(right.w, 238)
    assertEqual(right.h, 272)
end

local function testValidation()
    local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: altitude
    type: placeholder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      title: "Altitude #1"
      warning: 120.5
      enabled: true
  - id: speed
    type: placeholder
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
]]))

    local normalized, errors = layout.validate(document, grid)
    assertEqual(#errors, 0)
    assertEqual(#normalized.panels, 2)
    assertEqual(normalized.panels[1].config.title, "Altitude #1")
    assertEqual(normalized.panels[1].config.warning, 120.5)
    assertEqual(normalized.panels[1].config.enabled, true)
end

local function testOverlapIsRejected()
    local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: first
    type: placeholder
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
  - id: second
    type: placeholder
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 1
]]))

    local normalized, errors = layout.validate(document, grid)
    assertEqual(#normalized.panels, 1)
    assertEqual(#errors, 1)
    assert(string.match(errors[1], "overlaps first"), errors[1])
end

--- Layout names, including ones no editor would accept, resolve to distinct
--- path-safe files inside the user layout folder.
local function testLayoutNameResolution()
    assertEqual(layoutStore.path("/WIDGETS/AeroGrid", "main"), "/AEROGRID/layouts/main.yaml")
    local names = { "main", "MAIN2", "Kavan Sonic", "FPV-7in", "Heli_450", "..%2fescape", "a/b" }
    local seen = {}
    for _, name in ipairs(names) do
        local path = layoutStore.path("/WIDGETS/AeroGrid", name)
        local segment = string.match(path, "^/AEROGRID/layouts/([^/]+)%.yaml$")
        assert(segment, "unsafe layout path for " .. name .. ": " .. path)
        assert(not string.find(segment, "%.%."), "traversal survived for " .. name)
        assert(not seen[path], "filename collision for " .. name .. ": " .. path)
        seen[path] = true
    end
end

--- Unknown top-level keys are retained so newer authoring tools survive a load.
local function testUnknownKeysArePreserved()
    local document = assert(yaml.parse([[
version: 1
vendorExtra: keep-me
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: placeholder
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    futureKey: keep-me-too
]]))

    local normalized, errors = layout.validate(document, grid)
    assertEqual(#errors, 0)
    assertEqual(normalized.vendorExtra, "keep-me")
    assertEqual(normalized.panels[1].futureKey, "keep-me-too")
end

--- Malformed documents must degrade into errors rather than raising.
--- Documents this loader cannot interpret fail closed; documents with merely
--- bad entries keep loading their valid panels.
local function testMalformedInput()
    local cases = {
        {
            name = "scalar panel entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - bare-scalar\n",
        },
        {
            name = "numeric panel entry",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - 42\n",
        },
        { name = "panels mapping", text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  nope: 1\n" },
        { name = "missing grid", fatal = true, text = "version: 1\npanels: []\n" },
        {
            name = "future version",
            fatal = true,
            text = "version: 99\ngrid:\n  columns: 4\n  rows: 4\npanels: []\n",
        },
        {
            name = "wrong grid size",
            fatal = true,
            text = "version: 1\ngrid:\n  columns: 3\n  rows: 3\npanels: []\n",
        },
        {
            name = "unsafe type",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - id: a\n    type: ../evil\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n",
        },
        {
            name = "fractional span",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - id: a\n    type: placeholder\n    col: 0\n    row: 0\n    colSpan: 1.5\n    rowSpan: 1\n",
        },
        {
            name = "out of bounds",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - id: a\n    type: placeholder\n    col: 3\n    row: 0\n    colSpan: 2\n    rowSpan: 1\n",
        },
        {
            name = "duplicate id",
            text = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n  - id: a\n    type: placeholder\n    col: 0\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n  - id: a\n    type: placeholder\n    col: 1\n    row: 0\n    colSpan: 1\n    rowSpan: 1\n",
        },
    }

    for _, case in ipairs(cases) do
        local document = yaml.parse(case.text)
        if document then
            local ok, normalized, errors = pcall(layout.validate, document, grid)
            assert(ok, case.name .. " raised: " .. tostring(normalized))
            if case.fatal then
                assertEqual(normalized, nil, case.name .. " should fail closed")
            else
                assert(normalized, case.name .. " returned no layout")
                assert(#errors > 0, case.name .. " reported no error")
            end
        end
    end

    -- A non-table document must be rejected without raising.
    local ok, result = pcall(layout.validate, "not a document", grid)
    assert(ok, "string document raised")
    assertEqual(result, nil)
end

--- One invalid entry must not prevent surrounding valid entries from loading.
local function testInvalidEntryIsIsolated()
    local document = assert(yaml.parse([[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: good
    type: placeholder
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
  - bare-scalar
  - id: alsogood
    type: placeholder
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 1
]]))

    local normalized, errors = layout.validate(document, grid)
    assertEqual(#normalized.panels, 2)
    assertEqual(normalized.panels[1].id, "good")
    assertEqual(normalized.panels[2].id, "alsogood")
    assertEqual(#errors, 1)
end

local function testPanelContract()
    local valid = { id = "demo", apiVersion = 1, create = function() end }
    assert(panelHost.validateModule(valid, "demo"))

    local function rejects(module, typeName, pattern)
        local ok, err = panelHost.validateModule(module, typeName)
        assertEqual(ok, false)
        assert(string.match(err, pattern), err)
    end

    rejects("not a table", "demo", "must return a table")
    rejects({ id = "demo", apiVersion = 2, create = function() end }, "demo", "incompatible")
    rejects({ id = "../evil", apiVersion = 1, create = function() end }, "../evil", "invalid id")
    rejects({ id = "other", apiVersion = 1, create = function() end }, "demo", "does not match type")
    rejects({ id = "demo", apiVersion = 1 }, "demo", "no create function")
    rejects({ id = "demo", apiVersion = 1, create = function() end, refresh = 5 }, "demo", "refresh must be a function")
    rejects({ id = "demo", apiVersion = 1, create = function() end, supportedSpans = 5 }, "demo", "supportedSpans")
end

local function testSupportedSpans()
    local restricted = { supportedSpans = { "1x1", "2x2" } }
    assertEqual(panelHost.supportsSpan(restricted, 1, 1), true)
    assertEqual(panelHost.supportsSpan(restricted, 2, 2), true)
    assertEqual(panelHost.supportsSpan(restricted, 4, 1), false)
    assertEqual(panelHost.supportsSpan({ supportedSpans = { "any" } }, 4, 4), true)
    assertEqual(panelHost.supportsSpan({}, 3, 2), true)
    assertEqual(panelHost.spanName(2, 3), "2x3")
end

local function testSettingsResolution()
    local module = {
        settings = {
            { key = "title", type = "string", default = "DEFAULT" },
            { key = "limit", type = "number", default = 10 },
            { key = "shown", type = "boolean", default = true },
            "malformed",
        },
    }

    local settings, warnings =
        panelHost.resolveSettings(module, { title = "Given", limit = "not a number", extra = "kept" })

    assertEqual(settings.title, "Given")
    assertEqual(settings.limit, 10)
    assertEqual(settings.shown, true)
    -- Kept, because a layout written for a newer panel must survive an
    -- older host, and reported, because an undeclared key is far more often a
    -- misspelling or a stale name than a message from the future.
    assertEqual(settings.extra, "kept")
    assert(
        string.find(table.concat(warnings, "\n"), "extra is not a setting of this panel", 1, true),
        "an undeclared key was accepted in silence"
    )
    assertEqual(#warnings, 3, "the warning count changed; read them before editing")

    -- Obsolete source-name companions are unknown settings.
    local _, named = panelHost.resolveSettings(
        { settings = { { key = "source", type = "string", default = "" } } },
        { source = "RxBt", sourceName = "Rx battery" }
    )
    assertEqual(#named, 1, "an obsolete source-name companion was accepted")

    -- A value outside a declared choice list is a typo, not a preference.
    local choiceModule = {
        settings = {
            { key = "shape", type = "string", default = "bar", choices = { "bar", "radial", "none" } },
        },
    }
    local chosen, choiceWarnings = panelHost.resolveSettings(choiceModule, { shape = "nonsense" })
    assertEqual(chosen.shape, "bar", "an unknown choice was not replaced")
    assertEqual(#choiceWarnings, 1)
    assert(string.find(choiceWarnings[1], "must be one of bar, radial, none", 1, true), choiceWarnings[1])

    local valid = panelHost.resolveSettings(choiceModule, { shape = "radial" })
    assertEqual(valid.shape, "radial", "a declared choice was rejected")

    local defaults = panelHost.resolveSettings(module, nil)
    assertEqual(defaults.title, "DEFAULT")
end

--- Every panel's settings schema, read as one catalogue.
--- The vocabulary rules are properties of the set, not of any one panel,
--- so they are checked over the set. Modules written to the same
--- contract by different sessions is exactly the situation in which each is
--- individually defensible and the collection is not.
--- Read from disk rather than listed here. A hand-kept list would leave a
--- newly added panel uncovered by exactly the check that exists to keep
--- the catalogue consistent, and nothing would say so.
local function panelTypes()
    local listingPath = root .. "/build/panel-types.txt"
    os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/panels' > '" .. listingPath .. "'")
    local listing = assert(io.open(listingPath, "r"))
    local types = {}
    for name in listing:lines() do
        local stem = string.match(name, "^(.+)%.lua$")
        if stem then
            types[#types + 1] = stem
        end
    end
    listing:close()
    os.remove(listingPath)
    assert(#types > 0, "no panels were found to check")
    return types
end

--- Lua sources in one directory under the widget, by file name.
--- Read from the directory for the same reason `panelTypes` is: a list
--- written by hand stops covering the host the moment somebody adds a file.
local function sourceFiles(directory)
    local listingPath = root .. "/build/source-listing.txt"
    os.execute("ls '" .. root .. "/src/WIDGETS/AeroGrid/" .. directory .. "' > '" .. listingPath .. "'")
    local listing = assert(io.open(listingPath, "r"))
    local names = {}
    for name in listing:lines() do
        if string.match(name, "%.lua$") then
            names[#names + 1] = name
        end
    end
    listing:close()
    os.remove(listingPath)
    assert(#names > 0, "no sources were found in " .. directory)
    return names
end

--- Names that were retired because another key already asked their question.
--- Listed by what replaced them, so a reintroduction says where to go.
local RETIRED_KEYS = {
    display = "reading, or readout where it names a text form",
    primary = "reading",
    min = "a range named for what it bounds",
    max = "a range named for what it bounds",
    armSource = "the layout's session block",
    title = "label",
}

--- What each panel's thresholds are measured in, where the answer is
--- fixed by the quantity rather than by configuration.
local FIXED_THRESHOLD_UNITS = {
    ["cell-battery"] = "volts per cell",
    ["tx-battery"] = "volts",
    ["flight-timer"] = "seconds",
    ["navigation"] = "metres",
}

local function settingsCatalog()
    local catalog = {}
    for _, kind in ipairs(panelTypes()) do
        catalog[kind] = loadModule("panels/" .. kind .. ".lua").settings or {}
    end
    return catalog
end

local function testSettingsVocabulary()
    local catalog = settingsCatalog()
    local kinds = panelTypes()
    -- Fourteen panels ship: eleven instruments, two diagnostics, and the
    -- fixed theme showcase. `heartbeat` and
    -- `placeholder` were built to prove
    -- the host contract and are fixtures under `tests/fixtures/panels`, so
    -- they are not read here: the vocabulary rules below are about what a
    -- person configures on a radio.
    assertEqual(#kinds, 14, "the catalogue changed size; expected eleven instruments and three utility panels")

    for kind, settings in pairs(catalog) do
        local declared = {}
        for _, setting in ipairs(settings) do
            declared[setting.key] = setting

            local replacement = RETIRED_KEYS[setting.key]
            assert(
                not replacement,
                kind .. " declares the retired key " .. tostring(setting.key) .. "; use " .. tostring(replacement)
            )

            -- A choice list that omits its own default rejects the value the host
            -- falls back to, so the setting has no reachable resting value.
            if setting.choices then
                local found = false
                for _, choice in ipairs(setting.choices) do
                    if choice == setting.default then
                        found = true
                    end
                end
                assert(
                    found,
                    kind
                        .. "."
                        .. setting.key
                        .. " declares choices that do not include its default "
                        .. tostring(setting.default)
                )
            end
        end

        -- A setting must have more than one answer a layout could sensibly give.
        -- `direction` was added to every panel with thresholds, and on five
        -- of them the physics fixes the answer: a voltage and a link only alarm
        -- downward, a distance only upward, and a timer's direction is EdgeTX's
        -- own `countdown` flag rather than anything a layout decides. A setting
        -- with one valid value is not configuration, it is noise, and it makes a
        -- reader wonder what the other value would do.
        for key, setting in pairs(declared) do
            if type(setting.choices) == "table" then
                assert(
                    #setting.choices > 1,
                    kind
                        .. "."
                        .. key
                        .. " offers one choice, so it is a fact rather than a setting;"
                        .. " remove it and document the behaviour"
                )
            end
        end

        -- A threshold's unit is not recoverable from a bare number, so the label
        -- carries it. Where the unit is fixed by what the panel measures the
        -- label names it; where it follows configuration, as a metric's does and
        -- as link-status's does when `reading` resolves to RSSI rather than
        -- quality, the label says that instead of naming a unit that may be wrong.
        for _, key in ipairs({ "warning", "critical" }) do
            local setting = declared[key]
            if setting and setting.type == "number" then
                local unit = FIXED_THRESHOLD_UNITS[kind]
                if unit then
                    assert(
                        string.find(setting.label, unit, 1, true),
                        kind
                            .. "."
                            .. key
                            .. " is measured in "
                            .. unit
                            .. " and its label does not say so: "
                            .. tostring(setting.label)
                    )
                else
                    assert(
                        string.find(setting.label, "unit", 1, true),
                        kind
                            .. "."
                            .. key
                            .. " has no fixed unit and its label does not"
                            .. " say which one applies: "
                            .. tostring(setting.label)
                    )
                end
            end
        end
    end

    -- Keep the panel's persisted settings aligned with the supported surface.
    local trimSettings = {}
    for _, setting in ipairs(catalog["trim-panel"]) do
        trimSettings[setting.key] = setting
    end
    assertEqual(#catalog["trim-panel"], 7)
    assertEqual(trimSettings.trim1.default, "trim-ail")
    assertEqual(trimSettings.trim2.default, "trim-ele")
    assertEqual(trimSettings.trim4.default, "trim-rud")

    -- The palette reserves cyan for electrical data. Both batteries measure
    -- volts; one of them used to be green.
    for _, kind in ipairs({ "cell-battery", "tx-battery" }) do
        for _, setting in ipairs(catalog[kind]) do
            if setting.key == "accent" then
                assertEqual(setting.default, "cyan", kind .. " defaults to an accent the colour rule does not allow")
            end
        end
    end
end

--- Every YAML example in the specification is loaded, not trusted.
---
--- The specification's layout example did not load for at least two
--- milestones. It named `showLabel`, which no panel declares, and a
--- numeric source identifier, which `telemetryService` rejects, and it was
--- the single most copyable thing in the document. Nothing read it, so
--- nothing could say so.
---
--- The examples are extracted from the document at test time rather than
--- copied here. A copy would be a second source of truth and would drift
--- from the document exactly as the document drifted from the code, which is
--- the failure this exists to prevent.
local function yamlBlocksIn(path)
    local handle = io.open(path, "r")
    assert(handle, "no document at " .. path)
    local text = handle:read("a")
    handle:close()
    assert(type(text) == "string" and #text > 0, path .. " is empty, so every example in it would pass vacuously")

    local blocks = {}
    for body in string.gmatch(text, "\n```yaml\n(.-)\n```") do
        blocks[#blocks + 1] = body
    end
    return blocks
end

local function specificationExamples()
    return yamlBlocksIn(root .. "/plans/aerogrid-spec.md")
end

--- Check one complete layout document exactly as the host would.
---@param body string
---@param label string
local function checkLayoutExample(body, label)
    local document = yaml.parse(body)
    assert(type(document) == "table", label .. " did not parse")

    local normalized, errors = layout.validate(document, grid)
    assert(normalized, label .. " was rejected: " .. table.concat(errors or {}, "; "))
    assertEqual(#errors, 0, label .. ": " .. table.concat(errors, "; "))

    -- An example that declares nothing would satisfy every assertion below by
    -- having nothing to satisfy them with.
    assert(#normalized.panels > 0, label .. " declares no panels")

    for _, placement in ipairs(normalized.panels) do
        local where = label .. ": " .. placement.id
        local chunk = loadfile(root .. "/src/WIDGETS/AeroGrid/panels/" .. placement.type .. ".lua")
        assert(chunk, where .. ": no panel file for type " .. placement.type)
        local module = chunk()

        local valid, moduleError = panelHost.validateModule(module, placement.type)
        assert(valid, where .. ": " .. tostring(moduleError))
        assert(
            panelHost.supportsSpan(module, placement.colSpan, placement.rowSpan),
            where
                .. ": "
                .. placement.type
                .. " does not support "
                .. panelHost.spanName(placement.colSpan, placement.rowSpan)
        )

        -- Undeclared keys and values outside a declared choice list are both
        -- reported here, which is what the example used to trip over.
        local _, warnings = panelHost.resolveSettings(module, placement.config)
        assertEqual(#warnings, 0, where .. ": " .. table.concat(warnings, "; "))
    end

    return normalized
end

--- Check a single panel entry, which is a layout's panel sequence cut
--- down to one. Spliced into the smallest document that can carry it, so the
--- same validation runs: a panel example naming a setting that does not
--- exist is exactly as wrong as a whole layout doing it, and there is no
--- reason for the document to be able to carry one unchecked.
---@param body string
---@param label string
local function checkPanelExample(body, label)
    local indented = string.gsub("\n" .. body, "\n", "\n  ")
    local document = "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:" .. indented .. "\n"
    return checkLayoutExample(document, label)
end

local function testSpecificationExamplesLoad()
    local blocks = specificationExamples()
    assert(#blocks > 0, "no YAML examples were found in the specification")

    local layouts, entries = 0, 0
    for index, body in ipairs(blocks) do
        local label = "specification example " .. index
        assert(#body > 0, label .. " is empty")

        if string.match(body, "^version:") then
            layouts = layouts + 1
            local normalized = checkLayoutExample(body, label)
            -- The example carries a session block, and a block that stopped
            -- reaching the host would still parse.
            if string.match(body, "\nsession:") then
                assert(
                    normalized.session and normalized.session.armSource,
                    label .. ": a session block did not survive validation"
                )
            end
        elseif string.match(body, "^%- id:") then
            entries = entries + 1
            checkPanelExample(body, label)
        else
            -- An unclassified example is one nothing checks, which is the state
            -- this test exists to end. Failing is the point: add a branch here.
            -- It has already caught one: a bare panel entry added to the
            -- source-settings section, which no branch covered until one did.
            error(
                label
                    .. " is neither a layout nor a panel entry, so nothing"
                    .. " checks it. Its first line is: "
                    .. tostring(string.match(body, "^([^\n]*)"))
            )
        end
    end

    -- Both kinds have to still be present. Deleting the layout example from
    -- the document would otherwise leave this test passing over whatever
    -- remained.
    assert(layouts > 0, "the specification carries no complete layout example")
    assert(entries > 0, "the specification carries no panel entry example")
end

--- Link thresholds name their source rather than the selected headline.
local function testLinkThresholdsNeedAStatedReading()
    local module = loadModule("panels/link-status.lua")
    for _, reading in ipairs({ "auto", "quality", "rssi" }) do
        local _, warnings = panelHost.resolveSettings(module, {
            reading = reading,
            warning = 50,
            critical = 30,
        })
        assertEqual(#warnings, 2, "obsolete generic link thresholds must be reported")
        local _, current = panelHost.resolveSettings(module, {
            reading = reading,
            qualitySource = "RQly",
            qualityWarning = 50,
            qualityCritical = 30,
            rssiWarning = -90,
            rssiCritical = -100,
        })
        assertEqual(#current, 0, table.concat(current, "; "))
    end
end

--- Every shipped panel has documentation, and its examples load.
---
--- Two failures to prevent, and the second is the one that rots quietly. An
--- example that stops loading is caught the same way the specification's are,
--- by running it rather than reading it. A panel with no documentation
--- file at all is caught by reading the panel directory rather than a
--- list, because a list is what lets the eleventh panel be quietly
--- undocumented: nothing would be wrong, there would simply be less.
--- Panels reviewed and documented so far, and the ones still owed.
---
--- The review is one panel per pull request, so this starts as debt and
--- is meant to empty. It is an explicit list rather than a silent gap for one
--- reason: a panel that is not on it and has no page fails immediately,
--- so a panel added to the catalogue tomorrow cannot be quietly
--- undocumented. Removing the last name here should delete this table too.
local UNDOCUMENTED = {
    ["host-diagnostics"] = true,
    ["service-probe"] = true,
}

local function testPanelDocumentationLoads()
    local kinds = panelTypes()
    assert(#kinds > 0, "no panels were found to document")
    -- The utility is documented as a dashboard, not an instrument reference.
    for index = #kinds, 1, -1 do
        if kinds[index] == "theme-showcase" then
            local handle = assert(io.open(root .. "/docs/user-guide/customize-themes.md", "r"))
            local page = handle:read("*a")
            handle:close()
            assert(string.find(page, "# Customize themes", 1, true))
            assert(string.find(page, "/WIDGETS/AeroGrid/themes/", 1, true))
            assert(string.find(page, "/AEROGRID/themes/", 1, true))
            table.remove(kinds, index)
        end
    end

    local known = {}
    for _, kind in ipairs(kinds) do
        known[kind] = true
    end
    -- A name here that is not a panel is a rename nobody finished, and it
    -- would excuse a real panel from ever being documented.
    for kind in pairs(UNDOCUMENTED) do
        assert(
            known[kind],
            kind
                .. " is listed as undocumented but is not a"
                .. " panel; the list is excusing something that does not exist"
        )
    end

    local documented = 0
    for _, kind in ipairs(kinds) do
        local path = root .. "/docs/panels/" .. kind .. ".md"
        local handle = io.open(path, "r")
        if not handle then
            assert(
                UNDOCUMENTED[kind],
                kind
                    .. " ships with no documentation at "
                    .. path
                    .. ", and is not on the list of panels still owed one"
            )
        end
        if handle then
            local page = handle:read("*a")
            handle:close()
            assert(
                not UNDOCUMENTED[kind],
                kind .. " is documented but is still" .. " listed as owing documentation; remove it from UNDOCUMENTED"
            )
            documented = documented + 1
            assert(
                string.match(page, "^# `[^\n]+`\n\n| 1x2 | 2x1 | 2x2 |"),
                kind .. " must put its visual examples immediately after the title"
            )
            local sections = {}
            for heading in string.gmatch(page, "\n## ([^\n]+)") do
                sections[#sections + 1] = heading
            end
            assertEqual(
                table.concat(sections, ","),
                "Settings,Behavior,States,Examples",
                kind .. " has inconsistent reference sections"
            )

            local blocks = yamlBlocksIn(path)
            assert(
                #blocks > 0,
                kind
                    .. " is documented with no example at all, so"
                    .. " nothing in its documentation can be checked by running it"
            )

            for index, body in ipairs(blocks) do
                local label = kind .. " example " .. index
                assert(#body > 0, label .. " is empty")

                if string.match(body, "^version:") then
                    checkLayoutExample(body, label)
                elseif string.match(body, "^%- id:") then
                    -- Checked before the example is validated, so the failure names the
                    -- real problem rather than whichever setting the other panel
                    -- happens not to declare. A page about one panel whose example
                    -- places a different one is worse than no example: it is confidently
                    -- wrong, and it is exactly what copying the previous page produces.
                    local declared = string.match(body, "\n%s*type:%s*([%w%-]+)")
                    assertEqual(
                        declared,
                        kind,
                        label .. " places a " .. tostring(declared) .. " on the page documenting " .. kind
                    )
                    checkPanelExample(body, label)
                else
                    error(
                        label
                            .. " is neither a layout nor a panel entry, so"
                            .. " nothing checks it. Its first line is: "
                            .. tostring(string.match(body, "^([^\n]*)"))
                    )
                end
            end
        end
    end

    -- The count is pinned so that a page disappearing is a failure rather than
    -- a quieter suite.
    local owed = 0
    for _ in pairs(UNDOCUMENTED) do
        owed = owed + 1
    end
    assertEqual(documented + owed, #kinds, "every panel is either documented or listed as owing a page")
    assertEqual(
        documented,
        11,
        "the number of documented panels changed; update this count as the" .. " review works through the catalogue"
    )
end

--- The reading is sized from the model's own widest mode name, and fits.
---
--- `flight-mode` used to offer three forms of ten, six and four characters.
--- They were never renderings: `fitReading` chose a font from whichever form
--- fitted, and the panel then drew the **whole** name at that font, so a
--- ten-character name at `2 x 2` needed about 400 pixels of a 226 pixel panel
--- and lost nearly half of itself over the edge. Nothing noticed, because
--- every test used `Sport`, which fits at every span under either behaviour.
--- That is the shape of assertion this replaces: one that was true before the
--- fix as well.
---
--- Shortening the name is not available. A truncated mode name is a different
--- name, not an abbreviation of one, so the font steps down instead.
local function testFlightModeSizing()
    local flightMode = loadModule("panels/flight-mode.lua")
    local resolved = theme.build("modern-dark")

    local function modelWith(names)
        return modelService.new(
            services.environment({
                getFlightMode = function(index)
                    if type(index) ~= "number" or index < 0 or index >= 9 then
                        index = 0
                    end
                    return index, names[index] or ""
                end,
            }),
            services
        )
    end

    -- Read from every mode, not just the active one. A service that answered
    -- the active mode's name nine times would size from `Norm` and clip
    -- `LongRange7`, which is exactly what it must not do.
    assertEqual(modelWith({ [0] = "Norm", [4] = "LongRange7" }):widestFlightModeName(), "LongRange7")
    -- An unnamed mode is drawn as FM<n>, so that is its width, not zero. Named
    -- one mode with something shorter, so the widest name in the model is an
    -- unnamed one: measuring those as empty would answer "Up" instead.
    assertEqual(modelWith({ [0] = "Up" }):widestFlightModeName(), "FM1")
    assertEqual(modelWith({}):widestFlightModeName(), "FM0")
    -- Without the firmware call there is nothing to read and a sane default.
    assertEqual(modelService.new(services.environment({}), services):widestFlightModeName(), "FM0")

    -- Every declared span must fit the widest name the model can show. This is
    -- the assertion the old behaviour fails: four of the eight spans clipped.
    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    for _, widest in ipairs({ "LongRange7", "Norm" }) do
        local checked = 0
        for _, span in ipairs(flightMode.supportedSpans) do
            local cols, rows = string.match(span, "(%d)x(%d)")
            cols, rows = tonumber(cols), tonumber(rows)
            local rect = {
                x = 0,
                y = 0,
                w = cellWidth * cols + GUTTER * (cols - 1),
                h = cellHeight * rows + GUTTER * (rows - 1),
            }
            local fonts = theme.typography(cols, rows)
            local layout = flightMode.presentationFor(cols, rows)
            local area = flightMode.regionsFor(resolved, theme, rect, layout, fonts, widest)

            -- **Measured, because the contract is about what is drawn.** This
            -- used to ask `textWidth`, which is the estimate: a constant ratio of
            -- the line height, over-reporting `LongRange7` at DBLSIZE as 232
            -- pixels where the font actually advances 170. Asserting the estimate
            -- pinned a number no pixel depends on, and it was stricter than the
            -- panel edge rather than equal to it.
            assert(
                theme.measureText(area.name, widest) <= area.content,
                widest
                    .. " at "
                    .. span
                    .. " needs "
                    .. theme.measureText(area.name, widest)
                    .. " of "
                    .. area.content
                    .. " pixels, so the name is drawn past the panel edge"
            )
            checked = checked + 1
        end
        assertEqual(checked, 8, "not every declared span was measured")
    end

    -- And the point of reading the model rather than assuming ten characters:
    -- a model with short names keeps the larger reading.
    local function fontAt(widest)
        local rect = { x = 0, y = 0, w = cellWidth * 2 + GUTTER, h = cellHeight * 2 + GUTTER }
        local fonts = theme.typography(2, 2)
        return flightMode.regionsFor(resolved, theme, rect, flightMode.presentationFor(2, 2), fonts, widest).name
    end
    assert(
        theme.fontHeight(fontAt("Norm")) > theme.fontHeight(fontAt("LongRange7")),
        "a model with short mode names gained nothing from reading its names"
    )
end

--- A mode number needs a row, and no single-row span has one.
local function testFlightModeIndexNeedsARow()
    local flightMode = loadModule("panels/flight-mode.lua")

    -- The refusal, which is the behaviour being added. Accepting it and then
    -- ignoring it is the worst of the three options, because a layout author
    -- reads the setting back and believes it.
    local refused = flightMode.validateSettings(
        { showIndex = true },
        { colSpan = 4, rowSpan = 1 },
        { showIndex = true }
    )
    assertEqual(
        #refused,
        1,
        "showIndex on a single row was accepted; no single row has space beneath" .. " the reading at any width"
    )
    assert(string.find(refused[1], "two rows tall", 1, true), refused[1])
    assert(
        string.find(refused[1], "drop showIndex", 1, true),
        "the message must say what to do about it: " .. refused[1]
    )

    -- Two rows is where it works, and a panel that never asked has nothing to
    -- be told about.
    assertEqual(
        #flightMode.validateSettings({ showIndex = true }, { colSpan = 1, rowSpan = 2 }, { showIndex = true }),
        0,
        "showIndex was refused on two rows"
    )
    assertEqual(
        #flightMode.validateSettings({}, { colSpan = 1, rowSpan = 1 }, {}),
        0,
        "a panel that never asked for the mode number was told off anyway"
    )
    -- Without a span nothing can be said, and saying nothing is correct.
    assertEqual(#flightMode.validateSettings({ showIndex = true }, nil, { showIndex = true }), 0)

    -- The host fills defaults in before this runs, so `settings` cannot say
    -- whether the layout asked. A setting that arrives only as a default is
    -- the panel shedding a row, which is normal and silent.
    assertEqual(
        #flightMode.validateSettings({ showIndex = true }, { colSpan = 4, rowSpan = 1 }, {}),
        0,
        "a default the layout never stated was reported as an ignored request"
    )

    -- And the span has to reach it through the host, or the rule above is
    -- correct and never consulted.
    local _, warnings = panelHost.resolveSettings(flightMode, { showIndex = true }, { colSpan = 4, rowSpan = 1 })
    assertEqual(
        #warnings,
        1,
        "the placement's span did not reach validateSettings, so a rule that" .. " depends on it can never fire"
    )
    assert(string.find(warnings[1], "two rows tall", 1, true), warnings[1])

    local _, allowed = panelHost.resolveSettings(flightMode, { showIndex = true }, { colSpan = 1, rowSpan = 2 })
    assertEqual(#allowed, 0)
end

--- A setting that cannot apply at this span says so, and only when asked for.
---
--- No single-row span grants a supporting row: a 65 pixel panel has no space
--- beneath the reading whatever its width. Five settings across four
--- panels drive such a row, and all five were accepted and silently
--- ignored there, which is worse than either refusing or working -- a layout
--- author reads the setting back and believes it.
---
--- The second half is the part that needed care. `showPack` and `showCount`
--- default to **true**, so a panel that never mentioned them arrives with
--- them set, and complaining then would report the panel's own shedding as
--- an ignored request and fail every existing layout. The host therefore
--- hands `validateSettings` the layout's own config beside the resolved
--- settings, and only a stated value is refused.
local function testInertSettingsAreRefused()
    local single = { colSpan = 4, rowSpan = 1 }
    local tall = { colSpan = 1, rowSpan = 2 }

    local cases = {
        { "tx-battery", "showPercent" },
        { "cell-battery", "showPack" },
        { "cell-battery", "showCount" },
        { "model-identity", "showLabels" },
        { "flight-mode", "showIndex" },
    }

    for _, case in ipairs(cases) do
        local kind, key = case[1], case[2]
        local module = loadModule("panels/" .. kind .. ".lua")
        assert(
            type(module.validateSettings) == "function",
            kind .. " states no rule for " .. key .. " at a span that cannot" .. " show it"
        )

        local stated = { [key] = true }

        -- Stated on a single row: refused, by name, with what to do about it.
        local rejectedSpan = kind == "cell-battery" and { colSpan = 1, rowSpan = 1 } or single
        local refused = module.validateSettings(stated, rejectedSpan, stated)
        assertEqual(
            #refused,
            1,
            kind
                .. "."
                .. key
                .. " was accepted on a single row, where no panel"
                .. " has space beneath the reading at any width"
        )
        assert(string.find(refused[1], key, 1, true), refused[1])
        local requiredSize = kind == "cell-battery" and "two-row panel" or "two rows tall"
        assert(string.find(refused[1], requiredSize, 1, true), refused[1])
        assert(
            string.find(refused[1], "drop " .. key, 1, true),
            "the message must say what to do about it: " .. refused[1]
        )

        -- Stated on two rows: allowed, because there it works.
        assertEqual(
            #module.validateSettings(stated, tall, stated),
            0,
            kind .. "." .. key .. " was refused on a panel that can show it"
        )

        -- Arrived as a default the layout never mentioned: silent, because that
        -- is the panel shedding a row rather than a request being ignored.
        assertEqual(
            #module.validateSettings(stated, single, {}),
            0,
            kind
                .. "."
                .. key
                .. " reported a default the layout never stated as"
                .. " an ignored request, which would fail every existing layout"
        )

        -- Without a span nothing can be said, and saying nothing is correct.
        assertEqual(#module.validateSettings(stated, nil, stated), 0)
    end

    -- The host is what carries the config through, so the rule above is
    -- correct and never consulted if it does not.
    local module = loadModule("panels/tx-battery.lua")
    local _, warnings = panelHost.resolveSettings(module, { showPercent = true }, single)
    assertEqual(
        #warnings,
        1,
        "the layout's own config did not reach validateSettings, so a rule that"
            .. " depends on what was stated can never fire"
    )

    -- And a layout that states nothing gets the defaults without being told
    -- off for them, through the host as well as directly.
    local _, quiet = panelHost.resolveSettings(loadModule("panels/cell-battery.lua"), { source = "Cels" }, single)
    assertEqual(
        #quiet,
        0,
        "a layout that stated neither showPack nor showCount was reported for" .. " both: " .. table.concat(quiet, "; ")
    )
end

--- Nothing in the host reaches an LVGL object by name.
---
--- An object handed back by `lvgl.*` is userdata on a radio, not a table:
--- `LvglWidgetObjectBase::getRef` calls `lua_newuserdata` for one pointer and
--- attaches `lvgl_base_mt` or `lvgl_mt`, neither of which declares
--- `__newindex`. So `label.headingText = text` raises there, and
--- `label.headingText` reads as nil. A stand-in that is a plain Lua table
--- does both silently and correctly-looking, which is how a field written
--- onto every panel's heading label passed this suite and then broke every
--- panel on the first radio that ran it.
---
--- The fixture now refuses the write, which catches any path a test walks.
--- This catches the paths no test walks, and catches reads as well, because
--- the read was the quieter half of the same defect: `placeHeader` asked the
--- label what its heading was, got nil on the radio, and therefore never
--- refitted on a reflow while looking entirely healthy here.
---
--- The rule is that the only things an object understands are its methods.
--- Every object name is collected from where it is constructed, and then any
--- use of it with a dot rather than a colon is a violation.
local function testLvglObjectsAreNeverReachedByName()
    -- Constructors whose result is an object rather than one of the small
    -- tables this host builds around several of them. `panel`, `bar`, `radial`,
    -- `compass` and `accentArc` return plain Lua tables and are deliberately
    -- absent: those are ours, and holding fields is what they are for. The
    -- object inside one, such as `band.arc`, is reached through the helper that
    -- owns it rather than by name.
    local OBJECT_MAKERS = { "label", "value", "badge", "image", "marker" }
    local LVGL_MAKERS = { "box", "rectangle", "label", "arc", "image" }

    local primitives = loadModule("lib/primitives.lua")
    for _, name in ipairs(OBJECT_MAKERS) do
        assert(
            type(primitives[name]) == "function",
            "primitives."
                .. name
                .. " is not a function, so this test is"
                .. " guarding a constructor that no longer exists under that name"
        )
    end

    -- Every production source, read from the directories rather than from a
    -- list, so a file written tomorrow is held to this from the moment it
    -- exists. That is the lesson from the documentation check: a rule that
    -- names its subjects is a rule the next subject escapes.
    local sources = { "main.lua" }
    for _, name in ipairs(sourceFiles("lib")) do
        sources[#sources + 1] = "lib/" .. name
    end
    for _, kind in ipairs(panelTypes()) do
        sources[#sources + 1] = "panels/" .. kind .. ".lua"
    end

    local checked, names = 0, 0
    for _, relative in ipairs(sources) do
        local handle = assert(io.open(root .. "/src/WIDGETS/AeroGrid/" .. relative, "r"))
        local source = handle:read("a")
        handle:close()
        checked = checked + 1

        -- Comments are stripped before anything is matched. They are where the
        -- firmware citations live, and a citation naming `lv_arc.c` reads as the
        -- object `arc` followed by a field `c` to any pattern simple enough to
        -- be worth writing. A rule that fires on a comment is a rule people
        -- learn to work around.
        source = string.gsub(source, "%-%-[^\n]*", "")

        local held = {}
        local function hold(name)
            if name then
                held[name] = true
            end
        end

        for _, maker in ipairs(OBJECT_MAKERS) do
            for name in string.gmatch(source, "([%w_]+%.?[%w_]*)%s*=%s*[%w_]*%.?primitives%." .. maker .. "%(") do
                hold(name)
            end
            for name in string.gmatch(source, "local%s+([%w_]+)%s*=%s*primitives%." .. maker .. "%(") do
                hold(name)
            end
        end
        for _, maker in ipairs(LVGL_MAKERS) do
            for name in string.gmatch(source, "([%w_]+%.?[%w_]*)%s*=%s*lvgl%." .. maker .. "%(") do
                hold(name)
            end
        end
        -- `header` hands back a label and a badge together.
        for first, second in
            string.gmatch(source, "([%w_]+%.?[%w_]*)%s*,%s*([%w_]+%.?[%w_]*)%s*=%s*" .. "[%w_]*%.?primitives%.header%(")
        do
            hold(first)
            hold(second)
        end

        for name in pairs(held) do
            -- `local` leaves the bare name; a field of `context` keeps its prefix.
            -- Either way the object is that name, and a dot after it is a field.
            names = names + 1
            -- A frontier, because `ring` is a suffix of `string` and the first
            -- version of this reported `primitives` for reaching `ring.upper`.
            local pattern = "%f[%w_]" .. string.gsub(name, "%.", "%%.") .. "%.([%w_]+)"
            for field in string.gmatch(source, pattern) do
                assert(
                    false,
                    relative
                        .. " reaches "
                        .. name
                        .. "."
                        .. field
                        .. ", but an LVGL object is userdata on a radio and has no fields."
                        .. " Writing one raises and reading one is always nil."
                        .. " Keep host bookkeeping beside the object, not on it."
                )
            end
        end
    end

    assert(checked >= 24, "only " .. checked .. " sources were read")
    assert(
        names >= 20,
        "only "
            .. names
            .. " object names were found, so this test is looking"
            .. " at far less of the host than it should be"
    )
end

--- No panel writes its own heading text into the label.
---
--- This is the fourth defect of the shape "a string is drawn without being
--- measured", after a flight mode's name, the supporting rows, and a
--- navigation origin. The reading goes through the ladder and supporting rows
--- through `fitLabel`; the heading went through neither, straight into a
--- label whose long mode LVGL defaults to wrapping.
---
--- The host writes headings through `primitives.header`. Panels that
--- rename their heading, such as a timer taking its name from the model,
--- must use `primitives.setHeading`.
---
--- It is honestly weaker than the render declaration in #24, which made its
--- mistake unrepresentable rather than merely detectable. The difference is
--- that the host owns the redraw comparison and can derive it, but it does
--- not own paint: a panel holds its own LVGL objects and calls `set` on
--- them. Making this unrepresentable would mean the host owning drawing as
--- well as deciding, which is a larger change than this defect justifies.
--- Detectable is what is available, so detectable is what this does.
local function testHeadingIsNeverWrittenDirectly()
    local kinds = panelTypes()
    local checked = 0

    for _, kind in ipairs(kinds) do
        local path = root .. "/src/WIDGETS/AeroGrid/panels/" .. kind .. ".lua"
        local handle = assert(io.open(path, "r"))
        local source = handle:read("a")
        handle:close()
        checked = checked + 1

        -- `context.label` and `context.title` are the header label, whichever a
        -- panel calls it. Anything else is a row the panel owns.
        for _, name in ipairs({ "label", "title" }) do
            -- Every write to the header label, not just the first: a panel may
            -- set its colour in one place and its text in another.
            for changes in string.gmatch(source, "context%." .. name .. ":set%((%b{})%)") do
                -- `text` as a key, rather than anywhere in the line. The first
                -- version of this searched the whole call and matched `context`,
                -- which contains the word, and so failed on a panel setting
                -- nothing but a colour.
                assert(
                    not string.match(changes, "[{,%s]text%s*="),
                    kind
                        .. " writes its heading straight into the label: "
                        .. changes
                        .. " -- use primitives.setHeading, which fits it to"
                        .. " the column the badge leaves"
                )
            end
        end
    end

    assertEqual(checked, #kinds)
    assert(checked >= 11, "only " .. checked .. " panels were read")
end

--- No panel writes its badge straight into the label.
---
--- The same shape as the heading above, and for the same reason: a badge's
--- **position depends on its text**, because it is right-aligned within the
--- column `theme.frame` reserves. Ten panels carried the identical line
--- -- `context.badge:set{text =, color =}` -- and not one of them placed it,
--- so every word narrower than `STALE` floated at the column's left edge.
---
--- Writing the text without placing it is now the whole of the defect, so
--- this forbids the write rather than checking the placement. What the
--- placement should be is `testBadgesEndFlushWithTheirPanel`, measured on
--- real panels.
local function testBadgeIsNeverWrittenDirectly()
    local kinds = panelTypes()
    local checked, withBadges = 0, 0

    for _, kind in ipairs(kinds) do
        local path = root .. "/src/WIDGETS/AeroGrid/panels/" .. kind .. ".lua"
        local handle = assert(io.open(path, "r"))
        local source = handle:read("a")
        handle:close()
        checked = checked + 1
        if string.match(source, "primitives%.setBadge") then
            withBadges = withBadges + 1
        end

        -- Every write to the badge, not just the first, and `text` as a key
        -- rather than anywhere in the call: the heading version of this matched
        -- the word `context` and failed on a panel setting only a colour.
        for changes in string.gmatch(source, "context%.badge:set%((%b{})%)") do
            assert(
                not string.match(changes, "[{,%s]text%s*="),
                kind
                    .. " writes its badge straight into the label: "
                    .. changes
                    .. " -- use primitives.setBadge, which places it flush with the"
                    .. " column rather than leaving it at the column's left edge"
            )
        end
    end

    assertEqual(checked, #kinds)
    -- Non-vacuous: the panels that draw badges really do go through the
    -- helper, so this is forbidding a thing that has an alternative.
    assert(withBadges >= 9, "only " .. withBadges .. " panels route their badge through primitives.setBadge")
end

--- No panel reaches for `lvgl.show` or `lvgl.hide` inside `update`.
---
--- A reflow is where visibility is decided, and every panel used to
--- decide it by hand: eleven copies of the same show-or-hide pair across
--- seven panels, and one panel reconciling a bar's two objects
--- separately and forgetting its marker. `primitives.reconcile` and
--- `primitives.reconcileBar` are the shared versions, and this is what stops
--- a twelfth copy appearing.
---
--- Read from the panel directory rather than a list, so a panel
--- written tomorrow is held to it from the moment it exists.
---
--- `create` is deliberately not checked. Hiding an object at build time is a
--- statement of its initial state rather than a reconciliation, there is no
--- previous visibility to compare against, and `reconcile` there would only
--- be the same call spelled longer.
local function testReflowGoesThroughReconcile()
    local kinds = panelTypes()
    assert(#kinds > 0, "no panels were found to check")

    local checked = 0
    for _, kind in ipairs(kinds) do
        local path = root .. "/src/WIDGETS/AeroGrid/panels/" .. kind .. ".lua"
        local handle = assert(io.open(path, "r"))
        local source = handle:read("a")
        handle:close()

        -- The panel's own `update`, which is everything from its definition
        -- to the next one at column zero.
        local body = string.match(source, "\nfunction [%w]+%.update%b()(.-)\n[%w]")
        if body then
            checked = checked + 1
            local offender = string.match(body, "(lvgl%.[sh][a-z]+)%s*%(")
            assert(
                not offender,
                kind
                    .. " calls "
                    .. tostring(offender)
                    .. " inside update; use primitives.reconcile or reconcileBar, which"
                    .. " know about the settled case and about a bar's marker"
            )
        end
    end

    -- Every panel has an `update`, so a pattern that silently matched none
    -- of them would otherwise pass this having checked nothing.
    assertEqual(
        checked,
        #kinds,
        "only " .. checked .. " of " .. #kinds .. " panels' update bodies" .. " were found, so the rest went unchecked"
    )
end

--- A panel declares what it draws, and nothing it has shed.
---
--- The reveal work gave five panels the property that a shed row is not
--- declared, so `primitives.changed` sees it reappear and nothing formats
--- text for a hidden label. The six panels that work was not applied to
--- kept doing it, which is how `flight-mode` came to format a mode number
--- every frame for a panel with no room to show one.
---
--- This checks the mechanism is reached rather than the wording: a `render`
--- that writes a supporting row must consult what the panel is showing. It is
--- a weaker statement than the per-panel tests elsewhere, and that is the
--- point -- it holds for a panel nobody has written a test for yet.
local function testRenderConsultsWhatIsShown()
    local kinds = panelTypes()

    -- Panels whose `render` declares only the dominant reading have no
    -- supporting row to gate, and are named rather than detected so that one
    -- losing its rows is a failure rather than a silent exemption.
    local NO_SUPPORTING_ROW = {
        ["host-diagnostics"] = true,
        ["service-probe"] = true,
        ["flight-counter"] = true,
        ["theme-showcase"] = true,
    }

    local checked, exempt = 0, 0
    for _, kind in ipairs(kinds) do
        local path = root .. "/src/WIDGETS/AeroGrid/panels/" .. kind .. ".lua"
        local handle = assert(io.open(path, "r"))
        local source = handle:read("a")
        handle:close()

        local body = string.match(source, "\nfunction [%w]+%.render%b()(.-)\n[%w]")
        if NO_SUPPORTING_ROW[kind] then
            exempt = exempt + 1
            if kind == "flight-counter" then
                assert(
                    body and not string.find(body, "out.detail", 1, true),
                    "flight counter only renders its count/state"
                )
            else
                assert(
                    not body,
                    kind .. " has a render function but is listed as" .. " having no supporting row to gate"
                )
            end
        else
            assert(
                body,
                kind .. " has no render function, so the redraw" .. " comparison cannot be derived from what it draws"
            )
            checked = checked + 1
            assert(
                string.find(body, "context%.show%w+"),
                kind
                    .. "'s render never consults what the panel is showing, so it"
                    .. " formats text for rows the panel has shed"
            )
        end
    end

    assertEqual(checked + exempt, #kinds)
    assert(checked >= 9, "only " .. checked .. " panels were checked")
end

--- A raising callback disables only its own panel, and only reports once.
local function testLifecycleIsolation()
    local entry = {
        placement = { id = "bad" },
        instance = {},
        module = {
            refresh = function()
                error("boom", 0)
            end,
        },
    }

    local ok, err = panelHost.dispatch(entry, "refresh")
    assertEqual(ok, false)
    assertEqual(err, "boom")
    assertEqual(entry.failed, true)

    local secondOk, secondError = panelHost.dispatch(entry, "refresh")
    assertEqual(secondOk, false)
    assertEqual(secondError, nil)

    -- Absent optional callbacks are a no-op success.
    local healthy = { placement = { id = "ok" }, instance = {}, module = {} }
    assertEqual(panelHost.dispatch(healthy, "background"), true)
    assertEqual(healthy.failed, nil)
end

--- Colors must survive the RGB565 round trip EdgeTX uses for theme roles.

testGridGeometry()
testValidation()
testOverlapIsRejected()
testLayoutNameResolution()
testUnknownKeysArePreserved()
testMalformedInput()
testInvalidEntryIsIsolated()
testPanelContract()
testSupportedSpans()
testSettingsResolution()
testSettingsVocabulary()
testInertSettingsAreRefused()
testHeadingIsNeverWrittenDirectly()
testBadgeIsNeverWrittenDirectly()
testLvglObjectsAreNeverReachedByName()
testReflowGoesThroughReconcile()
testRenderConsultsWhatIsShown()
testLinkThresholdsNeedAStatedReading()
testSpecificationExamplesLoad()
testPanelDocumentationLoads()
testLifecycleIsolation()
testFlightModeSizing()
testFlightModeIndexNeedsARow()
