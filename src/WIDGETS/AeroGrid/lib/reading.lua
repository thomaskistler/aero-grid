-- SPDX-License-Identifier: GPL-2.0-only

local module = { RUNTIME_API = 1 }

--- Install direct function references on the shared primitives API.
---@param primitives table
function module.install(primitives)
    --- Build a primary reading and a unit that may resolve after construction.
    --- Placement and visibility remain owned by centreReading and reflowReading.
    ---@param parent any
    ---@param theme AeroGridTheme
    ---@param area table Resolved reading geometry.
    ---@param presentation table
    ---@param unitText string Initial unit text; empty for a not-yet-resolved source.
    ---@return any value
    ---@return any unit
    function primitives.reading(parent, theme, area, presentation, unitText)
        local value = primitives.value(parent, theme, {
            x = area.valueX,
            y = area.valueY,
            w = area.valueWidth,
            text = "--",
            color = presentation.value,
            font = area.value,
        })
        local unit = primitives.unit(parent, theme, {
            x = area.valueX,
            y = area.valueY,
            text = unitText,
            color = theme.color.textMuted,
            font = area.unitFont,
        })
        return value, unit
    end

    --- Decide whether anything a panel draws has changed since it last drew.
    --- `render` collects every value `apply` paints. The two tables are swapped
    --- and reused to avoid allocating on each refresh.
    ---@param context table Panel context; owns `rendered` and `scratch`.
    ---@param render fun(context: table, out: table)
    ---@return boolean changed
    ---@return table drawn Values to paint from.
    function primitives.changed(context, render)
        local out = context.scratch
        if not out then
            out = {}
            context.scratch = out
        end

        -- Cleared rather than replaced, so a key the panel stops writing cannot
        -- linger and compare equal forever.
        for key in pairs(out) do
            out[key] = nil
        end
        render(context, out)

        local previous = context.rendered
        if previous then
            local same = true
            for key, value in pairs(out) do
                if previous[key] ~= value then
                    same = false
                    break
                end
            end

            -- A key that stopped being written cannot be seen by comparing what is
            -- here, and one can stop: a bar drops its zero tick when
            -- the range no longer spans zero. Counting is only reached once the
            -- values have all matched, which is the cheap path taken on most frames.
            if same then
                local before, now = 0, 0
                for _ in pairs(previous) do
                    before = before + 1
                end
                for _ in pairs(out) do
                    now = now + 1
                end
                if before == now then
                    return false, previous
                end
            end
        end

        context.rendered = out
        context.scratch = previous
        return true, out
    end

    --- Show or hide a supporting object, positioning it only when it is visible.
    ---
    --- Four panels had written this out privately and `trim-panel` had not
    --- written it at all, which is why it was repositioning eight labels it had
    --- just hidden. Moving a hidden object is not merely wasted: it is invisible
    --- work, and invisible work is the one kind the suite cannot see either.
    --- `settled` lets a caller that already knows visibility has not moved skip
    --- the show or hide entirely, which matters where a panel repeats the pair
    --- per indicator rather than once. Omitting it is always safe: nil reads as
    --- "it may have changed", which is what every caller did before.
    ---@param object? any LVGL object, or nil when the panel never built one.
    ---@param visible boolean
    ---@param changes? table Geometry to apply when the object is shown.
    ---@param settled? boolean Visibility is unchanged since the last call.
    function primitives.reconcile(object, visible, changes, settled)
        if not object then
            return
        end
        if visible then
            if changes then
                object:set(changes)
            end
            if not settled then
                lvgl.show(object)
            end
        elseif not settled then
            lvgl.hide(object)
        end
    end

    --- Show or hide a bar, positioning and filling it only when it is visible.
    ---
    --- A bar is two or three LVGL objects that always move together, which the
    --- single-object `reconcile` cannot express, so five panels wrote the
    --- pair out by hand and a sixth wrote a `reconcile` per object and then
    --- forgot the marker. That last one is why this exists rather than a note
    --- asking people to remember: `placeBar` knows a bar may carry a neutral
    --- marker, and a caller reconciling `track` and `fill` individually silently
    --- leaves the marker where it was.
    ---@param bar? table Bar returned by `primitives.bar`, or nil when none exists.
    ---@param visible boolean
    ---@param x integer
    ---@param y integer
    ---@param width integer
    ---@param fraction number
    ---@param settled? boolean Visibility is unchanged since the last call.
    function primitives.reconcileBar(bar, visible, x, y, width, fraction, settled)
        if not bar then
            return
        end

        if visible then
            primitives.placeBar(bar, x, y, width, fraction)
        end
        if settled then
            return
        end

        local show = visible and lvgl.show or lvgl.hide
        show(bar.track)
        show(bar.fill)
        if bar.marker then
            show(bar.marker)
        end
    end

    --- Angles of the two quarter bands that carry the accent round the corners.
    --- LVGL measures zero at three o'clock and increases clockwise, so the upper
    --- left quarter runs from nine o'clock to twelve, and the lower left from six
    --- o'clock to nine.
    primitives.ACCENT_TOP = { start = 180, finish = 270 }
    primitives.ACCENT_BOTTOM = { start = 90, finish = 180 }

    --- Put the unit beside a reading whose text is known, on its baseline.
    ---
    --- The x follows the reading's **drawn** text rather than the widest it could
    --- be, because a unit that keeps its distance from a short number has stopped
    --- being attached to it. The reading is repainted only when what it says
    --- changes, so the unit moves exactly when it should and not once more.
    ---
    --- The y is exact rather than approximate. `theme.unitTop` derives it from
    --- each font's ascent, which EdgeTX does not report but which is a fixed
    --- property of the fonts it ships.
    ---@param unit any
    ---@param themeBuilder table
    ---@param readingX integer
    ---@param readingY integer
    ---@param readingFont any
    ---@param text any What the reading currently says.
    ---@param unitFont any
    function primitives.placeUnit(unit, themeBuilder, readingX, readingY, readingFont, text, unitFont, withFont)
        local changes = {
            -- Measured, not estimated. The estimate is generous by design so that a
            -- reading shrinks rather than clips, and generosity in a decision about
            -- where something *starts* is just a gap: `7.9` at XXLSIZE was estimated
            -- 48 pixels wider than the radio draws it, and the unit sat that far out.
            x = readingX + themeBuilder.measureText(readingFont, text) + themeBuilder.unitGap(unitFont),
            y = themeBuilder.unitTop(readingFont, unitFont, readingY),
        }
        -- The font goes in the same call rather than a second one. A reflow that
        -- moves the reading to another size moves the rider too, and telling the
        -- label its position and then its font is two writes into one object for
        -- one change.
        if withFont then
            primitives.setFont(unit, unitFont)
        end
        unit:set(changes)
    end

    --- The strings a reading prints in place of a value.
    ---
    --- `--` is what every panel prints for a value it does not have.
    --- `link-status` additionally prints `N/A`, for a source the protocol does
    --- not publish at all, which is a different cause and the same absence. Both
    --- are the reading saying there is no number.
    ---
    --- It is a set rather than a comparison so that adding a sentinel is one
    --- entry here rather than a condition in six panels, and
    --- `testReadingsPrintADeclaredSentinel` holds every panel's own
    --- formatter to producing a member of it. A panel that invents a
    --- seventh spelling of "no value" fails by name instead of quietly drawing
    --- its unit again.
    primitives.SENTINELS = { ["--"] = true, ["N/A"] = true }

    --- Report whether a reading has a value for a unit to qualify.
    ---
    --- **Keyed on what the panel draws, not on what the subscription says.** The
    --- two differ in both directions and only the drawn text is the question a
    --- unit answers:
    ---
    --- - A **stale** reading still shows its last number, so it keeps its unit.
    ---   Staleness is about how old a measurement is, not about whether there is
    ---   one.
    --- - A sensor reading exactly **zero** prints `0`, and `0 V` is a
    ---   measurement. Keying on freshness or on availability would have been
    ---   right here by accident and wrong for `link-status`, whose genuine zero
    ---   this specification is explicit must be shown as the reading it is.
    --- - An **unavailable** source prints the sentinel, and that is the case
    ---   with nothing to qualify.
    ---
    --- So the test is on the string, at the point of drawing, which is also the
    --- only place both halves are known: whether the panel is *permitted* a unit
    --- is settled when it is built, and whether there is a value is not knowable
    --- until there is one. Asking the permission to carry the answer would be
    --- the tenth instance of the seam this project keeps rediscovering.
    ---@param text any What the reading currently says.
    ---@return boolean
    function primitives.hasValue(text)
        return primitives.SENTINELS[text] == nil
    end

    --- Decide whether a unit that only became known at runtime can be shown.
    ---
    --- A global variable's unit and a telemetry sensor's both arrive after the
    --- panel is built -- the first from `getGlobalVariableDetails`, the second
    --- once the source resolves -- so a panel that decided at build time decided
    --- against a unit of `""` and never showed one. This is the same late arrival
    --- the bar's range has, answered the same way: build the object, and let the
    --- answer change once when the truth turns up.
    ---
    --- Measured against the **widest digits** the panel can print rather than
    --- what it currently says, so the unit does not appear and vanish as the
    --- number changes length.
    ---@param themeBuilder table
    ---@param font any Reading font.
    ---@param digits string Widest digits the panel will print.
    ---@param unitFont any
    ---@param unit any
    ---@param width integer The reading's own column.
    ---@return boolean
    function primitives.unitFits(themeBuilder, font, digits, unitFont, unit, width)
        if unit == nil or unit == "" then
            return false
        end
        return themeBuilder.readingWidth(font, digits, unitFont, unit) <= width
    end

    --- Keep a unit beside a reading, moving it only when the reading's width
    --- actually changed.
    ---
    --- `theme.textWidth` is length times the font's line height times a constant,
    --- so the unit's x is a pure function of how many characters the reading has.
    --- Moving it on every repaint therefore wrote the same two numbers into the
    --- same label tens of times a second: measured at sixteen `link-status`
    --- panels refreshing every frame, that was 480 instructions of the steady
    --- frame for no pixel changed.
    ---
    --- The anchor lives on the panel's own context, which is a plain Lua
    --- table. It cannot live on the label: an LVGL object is userdata on a radio
    --- and holds no fields.
    --- The reading's font is passed rather than read off `area`, because the
    --- panels did not agree on what to call it: five said `value` and
    --- `metric` said `primary`. Reaching for one of those names put `metric`'s
    --- unit against a nil font, which the fixture measured as SMLSIZE and placed
    --- 38 pixels off the baseline it was supposed to share. They agree on
    --- `value` now, and the font is still passed -- being handed what to draw
    --- with is what made this immune to the disagreement in the first place.
    ---@param context table The panel's own context.
    ---@param themeBuilder table
    ---@param area table Regions, for `pad`, `valueY` and `unitFont`.
    ---@param font any The font the reading is drawn in.
    ---@param text string What the reading now says. Always a string: every
    --- panel's `render` writes `out.text` through `string.format` or a
    --- literal, so there is nothing here to coerce and a `tostring` per panel per
    --- frame would be the fixture-cost mistake made in the widget.
    function primitives.followUnit(context, themeBuilder, area, font, text)
        if not context.showUnit then
            return
        end

        -- Anchored on the text itself, not on its length. Two strings of one
        -- length are not one width: `--` and `12` are both two characters and
        -- differ by 12 pixels at DBLSIZE, because a dash is a fifth of a line
        -- height and a digit is three sevenths. A length anchor therefore held the
        -- unit still across exactly the change every telemetry panel makes
        -- when its sensor goes quiet. Comparing the strings costs no more: Lua
        -- interns short strings, so this is a pointer comparison.
        if text == context.unitAnchor then
            return
        end
        context.unitAnchor = text

        -- `area.valueX`, not `area.pad`. The reading is centred on a slot derived
        -- from the panel rather than started at the panel's left inset, so the
        -- inset stopped being where the number begins. Reading the wrong one put a
        -- unit fifteen pixels inside its own number -- the same defect shape, for
        -- the seventh time: a position derived from something that moved.
        primitives.placeUnit(context.unit, themeBuilder, area.valueX, area.valueY, font, text, area.unitFont)
    end

    --- Centre a reading on its slot, and bring its unit with it.
    ---
    --- **The drawn string, measured.** Two separate things used to push the
    --- number left of the slot it was supposed to sit in, and they compounded:
    --- the width came from `theme.textWidth`, which over-reports digits, and it
    --- was the width of the *widest*
    --- string the panel can ever print rather than the one on screen. Half
    --- of each error went straight into the left edge. On a `2 x 1` transmitter
    --- panel that put the reading at 22% of the panel where the rule asks for
    --- 32%, and on the bar panel beside it at 41% where the rule asks for 51%.
    ---
    --- The boundary drawn in #46 put the estimate on deciding whether something
    --- fits and the measurement on deciding where it starts. That boundary is
    --- gone: fitting measures as well, because the estimate was wrong in both
    --- directions and clipped `model-identity` outright. Both questions are now
    --- answered from the same advances, which is what they should always have
    --- been. The widest string still chooses the **font**, through the
    --- build-time slot fallback, which is what keeps a reading from resizing as
    --- it changes.
    ---
    --- The consequence, accepted deliberately: a reading gaining a digit
    --- re-centres, because its centre is now a property of the string. The slot
    --- does not move and neither does anything beside it, so this is the number
    --- settling into its place rather than the whole group drifting -- which was
    --- the objection that ruled out centred content in the first place.
    ---
    --- **Guarded on the text, so the measurement is not a per-frame cost.** A
    --- voltage changes a few times a minute and a panel refreshes far more
    --- often, so re-measuring on every update would pay for a placement that
    --- almost never moves.
    ---@param context table The panel's own context, for `value` and `unit`.
    ---@param themeBuilder table
    ---@param area table Regions, for `valueCentre`, `valueY` and `unitFont`.
    ---@param font any The font the reading is drawn in.
    ---@param text string What the reading now says.
    function primitives.centreReading(context, themeBuilder, area, font, text)
        -- A panel that does not slot its reading has nothing to centre it on,
        -- and says so by leaving `valueCentre` unset rather than by being named
        -- here.
        if area.valueCentre == nil then
            return
        end

        -- **Keyed on everything the placement depends on, not on the reading
        -- alone.** The group's width is the number plus its unit, and a unit is
        -- not always a constant: `navigation`'s changes with range, so `778 m`
        -- becoming `1.23 km` widens the group while the digit count holds. An
        -- anchor that watched only the number would have held the group still
        -- across exactly that change -- the ninth instance of the shape whose
        -- eighth was an anchor keyed on a proxy, in the panel converted
        -- immediately after it was written down.
        -- **What the panel is drawing, not what it expected to draw.** `showUnit`
        -- on the region is a build-time answer, and a unit that arrives later --
        -- a global variable's, a telemetry sensor's -- makes it stale: the panel
        -- shows a unit the group's width was computed without, so the box is too
        -- narrow for the pair and LVGL wraps it. The context's own flag is the one
        -- `apply` keeps current.
        local unit = context.showUnit and (context.unitText or "") or ""
        -- **And whether there is a value for it to qualify.** A unit with no
        -- number beside it is not a quieter reading, it is a label for nothing:
        -- the panel drew `-- V`, which says the transmitter is measured in volts
        -- and declines to say how many. `showUnit` cannot answer this, because it
        -- is settled when the panel is built and whether a sensor is reporting is
        -- only known at runtime -- which is exactly the permitted-versus-drawn
        -- seam, answered here, on the string the panel is actually drawing.
        --
        -- The reading does not move when this fires. Its x is
        -- `valueCentre - measureText(font, text) / 2`, its **own** width rather
        -- than the pair's; the unit only widens the box below. So a sensor
        -- dropping and returning takes the unit away and brings it back without
        -- shifting the number, and the flicker that would otherwise rule this out
        -- does not arise.
        if unit ~= "" and not primitives.hasValue(text) then
            unit = ""
        end
        if text == context.readingAnchor and unit == context.readingUnitAnchor then
            return
        end
        context.readingAnchor, context.readingUnitAnchor = text, unit

        local width = themeBuilder.measureText(font, text)
        local x = area.valueCentre - math.floor(width / 2)

        -- The box has to hold the unit as well as the number, or LVGL wraps the
        -- pair; the number is what is centred, and the unit rides past the slot.
        -- Centring the pair instead would line up the *groups* across a row of
        -- panels and therefore not the numbers, and the numbers are what the rule
        -- exists to line up: a panel with a unit and one without would put their
        -- digits in different places.
        local span = width
        if unit ~= "" then
            span = span + themeBuilder.unitGap(area.unitFont) + themeBuilder.measureText(area.unitFont, unit)
        end
        if area.centreReadingGroup then
            x = area.valueCentre - math.floor(span / 2)
        end
        if area.primaryMinX then
            -- A live metric may exceed its declared sizing envelope.
            x = math.max(x, area.primaryMinX)
        end

        context.value:set({ x = x, w = math.max(1, span) })
        context.valueX = x
        -- A panel may not have built a unit at all: `metric` creates one only
        -- where its layout asks for it, so a panel with no unit reaches here with
        -- nothing to move.
        --
        -- **Placed only when it is drawn.** This used to place unconditionally,
        -- so a panel whose span sheds its unit went on measuring the reading and
        -- writing two numbers into a hidden label on every value change -- the
        -- invisible work this project has twice paid to remove. A revealed unit
        -- is placed by whoever reveals it.
        if context.unit then
            local drawn = unit ~= ""
            if drawn then
                primitives.placeUnit(context.unit, themeBuilder, x, area.valueY, font, text, area.unitFont)
                context.unitAnchor = text
            end
            -- Visibility is written only when it moves. A reading changes several
            -- times a second and its unit almost never does, so an unguarded
            -- `show` here would be a call per panel per value for no pixel changed.
            if context.unitDrawn ~= drawn then
                context.unitDrawn = drawn
                if drawn then
                    lvgl.show(context.unit)
                else
                    lvgl.hide(context.unit)
                end
            end
        end
    end

    --- Centre one supporting label on a slot, keyed on what it says.
    ---
    --- The slot centres are a property of the panel, so every row uses them: a
    --- row of one item centres across the whole content box exactly as a lone
    --- reading does, and a row of two takes the same two centres the reading and
    --- its visual use. The panel decides which centre each item gets; this
    --- owns the measuring, the anchoring and the write, so nine panels can
    --- adopt the rule without nine copies of it.
    ---
    --- Anchored on the text itself. A supporting row changes as often as a
    --- reading does -- a bearing every time the aircraft turns -- so measuring
    --- on every update would pay for a placement that mostly does not move.
    ---@param context table The panel's own context, for the anchor.
    ---@param key string Where to keep this label's anchor on the context.
    ---@param themeBuilder table
    ---@param label any
    ---@param centre integer Slot centre this label is centred on.
    ---@param y integer
    ---@param font any
    ---@param text any What the label now says.
    function primitives.centreLabel(context, key, themeBuilder, label, centre, y, font, text)
        if label == nil then
            return
        end
        text = tostring(text == nil and "" or text)
        if text == context[key] then
            return
        end
        context[key] = text

        local width = themeBuilder.measureText(font, text)
        label:set({ x = centre - math.floor(width / 2), y = y, w = math.max(1, width) })
    end

    --- Show or hide a unit, placing it only when it is visible.
    ---
    --- The change table is deliberately empty of position: `placeUnit` owns the x
    --- and the y, and a second opinion stated here would be a second answer to
    --- the same question. Only the font is reconciled, because a reflow can move
    --- the reading to a different size and the rider follows it.
    ---
    --- **`visible` is the caller's permission and nothing more.** Whether there
    --- is a value for the unit to qualify is read from the text the panel is
    --- drawing, through the same `hasValue` the per-frame path uses, so a reflow
    --- cannot restore a unit beside an absent reading. Without it, a panel whose
    --- span granted a unit it had not had would show `-- V` again the moment the
    --- zone changed -- the rule holding in one path and not the other, which is
    --- the shape this project keeps finding.
    ---@param context table The panel's own context, for the drawn flag.
    ---@param unit? any
    ---@param visible boolean Whether the panel is permitted a unit here.
    ---@param themeBuilder table
    ---@param readingX integer
    ---@param readingY integer
    ---@param readingFont any
    ---@param text any What the reading currently says.
    ---@param unitFont any
    ---@param settled? boolean Permission is known not to have moved.
    function primitives.reconcileUnit(
        context,
        unit,
        visible,
        themeBuilder,
        readingX,
        readingY,
        readingFont,
        text,
        unitFont,
        settled
    )
        if not unit then
            return
        end

        visible = visible and primitives.hasValue(text)

        if visible then
            primitives.placeUnit(unit, themeBuilder, readingX, readingY, readingFont, text, unitFont, true)
        end
        -- Whatever `followUnit` was remembering is about a column and a font that
        -- have just moved, so it is discarded rather than trusted.
        if settled and visible == context.unitDrawn then
            return
        end

        context.unitDrawn = visible
        if visible then
            lvgl.show(unit)
        else
            lvgl.hide(unit)
        end
    end

    --- Reposition an unchanged reading and its unit after the layout moves.
    function primitives.reflowReading(context, themeBuilder, area, font, text, showUnit)
        local unit, previousShowUnit = context.unit, context.showUnit
        if showUnit ~= nil then
            context.showUnit = showUnit
        end
        context.area = area
        context.readingAnchor, context.readingUnitAnchor = nil, nil
        -- Reconcile the rider once, including its new font, after centring the value.
        context.unit = nil
        primitives.centreReading(context, themeBuilder, area, font, text)
        context.unit = unit
        primitives.reconcileUnit(
            context,
            unit,
            context.showUnit,
            themeBuilder,
            area.valueCentre and context.valueX or area.valueX,
            area.valueY,
            font,
            text,
            area.unitFont,
            context.showUnit == previousShowUnit
        )
        context.unitAnchor = nil
    end
end

return module
