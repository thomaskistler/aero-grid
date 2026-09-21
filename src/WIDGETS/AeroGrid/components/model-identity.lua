-- SPDX-License-Identifier: GPL-2.0-only

--- Model name and model bitmap.
---
--- EdgeTX records a bitmap filename on the model header and stores the file
--- under `/IMAGES/`. `modelService` resolves the name and the path; this
--- component decides whether the image can actually be shown.
---
--- That decision has to be made before the image object exists, because
--- EdgeTX's `lvgl.image` wraps `StaticImage`, which quietly clears its source
--- when a file cannot be decoded and reports nothing back to Lua. An image
--- created for a missing file therefore renders as an empty hole rather than
--- as an error. The component asks the filesystem first with `fstat` and falls
--- back to the model name when the file is absent. On firmware without
--- `fstat` the name is kept visible alongside the image, so a failed decode
--- still leaves the panel saying something true.
---
--- The specification describes loading the bitmap with `Bitmap.open()` and
--- retaining the object. That belongs to the legacy `lcd.drawBitmap` drawing
--- model; an LVGL widget cannot draw a `Bitmap` object, so the equivalent here
--- is one `lvgl.image` created once and kept.

---@class AeroGridIdentitySettings
---@field presentation? "auto"|"name"|"image"|"both"
---@field label? string
---@field accent? string
---@field showLabels? boolean Show the model's configured label list.

---@class AeroGridIdentityContext
---@field panel table
---@field feed? AeroGridModelIdentity
---@field stateName string

local modelIdentity = {
  id = "model-identity",
  apiVersion = 1,
  supportedSpans = {
    "1x1", "2x1", "3x1", "4x1",
    "1x2", "2x2", "3x2", "4x2",
    "2x3", "3x3", "4x3", "2x4", "3x4", "4x4",
  },
  -- Model identity changes only when the model changes, which reloads the
  -- widget anyway. Five seconds is already generous.
  refreshInterval = 500,
  settings = {
    -- Responsive content, like `navigation`: which arrangement is drawn.
    {key = "presentation", label = "Show", type = "string", default = "auto",
      choices = {"auto", "name", "image", "both"}},
    {key = "label", label = "Label", type = "string", default = "MODEL"},
    {key = "accent", label = "Accent", type = "string", default = "cyan",
      choices = {"cyan", "green", "amber", "orange"}},
    {key = "showLabels", label = "Show model labels", type = "boolean", default = false},
  },
}

--- Longest model name EdgeTX stores, used to size the reading.
--- `LEN_MODEL_NAME` is 15 on colour targets.
local WIDEST_NAME = "MMMMMMMMMMMMMMM"

--- Forms of the reading, longest first.
---
--- A model name is text rather than a measurement, so a shorter form gives up
--- characters of a name and not magnitude of a reading. Fifteen characters is
--- what EdgeTX will store, and reserving all of it on every panel was why this
--- component drew the smallest reading on the dashboard at almost every span.
local FORMS = {WIDEST_NAME, "MMMMMMMMMM", "MMMMMM"}

--- Resolve the presentation for a span.
--- `auto` needs real room before it spends it on a picture: a single cell is
--- barely larger than the name itself, so the name wins there.
---@param settings AeroGridIdentitySettings
---@param colSpan integer
---@param rowSpan integer
---@return table
function modelIdentity.presentationFor(settings, colSpan, rowSpan)
  local choice = settings.presentation
  local cells = (colSpan or 1) * (rowSpan or 1)

  if choice == "name" then return {showName = true, showImage = false} end
  if choice == "image" then return {showName = false, showImage = true} end
  if choice == "both" then return {showName = true, showImage = true} end

  if cells >= 4 then return {showName = true, showImage = true} end
  return {showName = true, showImage = false}
end

--- Report whether a file exists on the SD card.
--- `fstat` is absent on some builds, in which case nothing can be proven and
--- the caller keeps its fallback visible instead.
---@param path any
---@return boolean exists
---@return boolean checked
function modelIdentity.fileExists(path)
  if type(path) ~= "string" or path == "" then return false, true end
  if type(fstat) ~= "function" then return false, false end

  local ok, info = pcall(fstat, path)
  return ok and type(info) == "table", true
end

--- Refuse a label list on a panel that has nowhere to put one.
---
--- The labels are a supporting row, and no single-row span grants one: a 65
--- pixel panel has no space beneath the name whatever its width. This panel
--- declares taller spans than most, up to `4 x 4`, so the setting works
--- almost everywhere; the four it does not work on are worth saying rather
--- than leaving the author to wonder.
---
--- Only a layout that stated it is told. The default is false, so today the
--- distinction changes nothing here, but `cell-battery` defaults its two to
--- true and there the difference is the whole point.
---@param settings AeroGridIdentitySettings
---@param span? table Placement span, when the host knows it.
---@param config? table What the layout actually stated.
---@return string[] messages
function modelIdentity.validateSettings(settings, span, config)
  local messages = {}
  if type(config) ~= "table" then return messages end

  -- **A label stated on a panel that asks for a picture is not drawn.** The
  -- model name takes the heading there, so the configured label has nowhere
  -- to go. Silently overriding it is the shape this project keeps finding --
  -- a setting read, accepted and then ignored -- so the author is told.
  --
  -- Keyed on what the layout asked for rather than on what the panel will
  -- draw, and deliberately. Whether a picture survives depends on the
  -- panel's height in pixels, which is the zone's business and not knowable
  -- here; a panel whose picture is shed falls back to the name in the body
  -- and does use its label. So this says what the author asked for and what
  -- that costs, rather than claiming the label is never drawn.
  --
  -- `auto` is not included: it means "decide for me", and a label set
  -- alongside it is used at every span that shows no picture. Only an
  -- explicit request for one is a request that the label be replaced.
  if config.label ~= nil
      and (config.presentation == "image" or config.presentation == "both") then
    messages[#messages + 1] = "label is not drawn on a panel showing the"
      .. " model picture; the model name takes the heading there. Drop label,"
      .. " or use presentation auto or name if you want your own heading."
  end

  if not config.showLabels then return messages end
  if type(span) ~= "table" or type(span.rowSpan) ~= "number" then
    return messages
  end

  if span.rowSpan < 2 then
    messages[#messages + 1] = "showLabels needs a panel two rows tall;"
      .. " a single row has no space beneath the name at any width."
      .. " Give the panel rowSpan 2, or drop showLabels."
  end

  return messages
end

--- Compute the content regions for the current rectangle.
---@param theme AeroGridTheme
---@param themeBuilder table
---@param rect AeroGridRect
---@param layout table
---@param fonts table
---@return table
function modelIdentity.regionsFor(theme, themeBuilder, rect, layout, fonts)
  local frame = themeBuilder.frame(theme, rect, fonts)
  local labelHeight = frame.labelHeight
  local top = frame.top
  local showName = layout.showName
  local showImage = layout.showImage
  local showLabels = layout.showLabels

  -- Composition comes from the shared ladder, like every other panel of this
  -- size. The image takes what the text leaves, below.
  --
  -- The ladder is not told what will be drawn, because the bands no longer
  -- ask: the bottom quarter is reserved whether or not the label row is on.
  local ladder = themeBuilder.ladder(theme, rect, frame)
  showLabels = showLabels and ladder.rows > 0

  local nameFont, formIndex = themeBuilder.fitReading(
    FORMS, frame.content, ladder.room)
  local nameHeight = themeBuilder.fontHeight(nameFont)

  -- **Where there is a picture, the picture is the panel.** The aircraft is
  -- what the user recognizes and the name only says which one it is, so the
  -- name moves into the heading and the body is the picture's alone. The two
  -- stop competing for the body, which is what made a long name overhang and
  -- a wide frame crop: neither is traded against the other any more.
  --
  -- The name keeps the body only when there is no picture, and that case is
  -- unchanged.
  local imageTop = top
  local imageHeight = rect.h - top - frame.bottom

  -- **The name sits in the body band, like every other reading.** It used to
  -- be pinned directly under the heading, which is the panel's content top
  -- and not where anything else on the dashboard puts a reading: 14 px above
  -- the band at `2 x 2`, 49 at `2 x 3` and 83 at `4 x 4`, where it read as
  -- stuck to the heading with the panel empty beneath it.
  --
  -- This is the one component that never used the shared vertical rule, and
  -- the reason it went unnoticed is that it is the one whose reading is a
  -- name rather than a number, so no cross-panel comparison ever lined it up
  -- against a neighbour.
  --
  -- The ladder is asked with what this panel draws, which is the supporting
  -- row or not. It has no bar and no compact visual at all, so nothing else
  -- here is a claim about a visualization.
  -- The ink, not the line box: see `theme.bodyTop`. A model name is the one
  -- reading in the catalogue that can descend, and a descender is drawn
  -- below the ink this centres, which is stated in the guide.
  local nameY = themeBuilder.bodyTop(ladder, themeBuilder.fontAscent(nameFont))

  if showLabels then imageHeight = imageHeight - labelHeight - 2 end

  -- Dropped entirely where what is left would be too small to recognize,
  -- which is the same floor as before and now reached less often, because
  -- the name no longer takes a slice first.
  if showImage and imageHeight < 24 then
    showImage = false
    imageHeight = 0
  end

  -- Decided after the floor, so a panel whose picture was shed falls back to
  -- the name in the body rather than showing neither.
  local nameInBody = showName and not showImage

  -- **The picture spans the content box, so it is exempt the way a bar is,
  -- and nothing here splits.** Where the name is drawn at all it has the
  -- body to itself, so there is no second element competing for horizontal
  -- room. The name centres across the whole content box and the label row,
  -- which carries one item, centres the same way.
  local readingCentre = frame.pad + math.floor(frame.content / 2)
  local nameWidth = themeBuilder.measureText(nameFont, FORMS[formIndex])

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    -- The slot's centre, a property of the panel. Where the name starts
    -- depends on what it currently reads, so `primitives.centreReading` owns
    -- that and computes it from the measured string.
    valueCentre = readingCentre,
    valueX = themeBuilder.slotX(readingCentre, nameWidth),
    valueWidth = nameWidth,
    -- The room the name has, which is not the width it draws in.
    valueBudget = frame.content,
    labelsCentre = readingCentre,
    nameY = nameY,
    nameFont = nameFont,
    formIndex = formIndex,
    imageY = imageTop,
    imageHeight = math.max(1, imageHeight),
    labelsY = math.max(1, rect.h - frame.bottom - labelHeight),
    -- What the body draws. A panel showing a picture puts its name in the
    -- heading instead, so the two are different questions and the old single
    -- `showName` answered both.
    showName = nameInBody,
    -- Whether the name belongs to the heading rather than to the body, which
    -- is what `apply` needs to know to choose the heading's text.
    nameIsHeading = showImage == true,
    showImage = showImage,
    showLabels = showLabels,
  }
end

--- Build the component's LVGL objects.
---@param parent any
---@param rect AeroGridRect
---@param settings AeroGridIdentitySettings
---@param services table
---@return AeroGridIdentityContext
function modelIdentity.create(parent, rect, settings, services)
  local theme = services.theme
  local primitives = services.primitives
  local fonts = services.fonts
  local span = services.span
  local layout = modelIdentity.presentationFor(
    settings, span.colSpan, span.rowSpan)
  layout.showLabels = settings.showLabels == true
  local presentation = services.state("normal", settings.accent)
  local area = modelIdentity.regionsFor(
    theme, services.themeBuilder, rect, layout, fonts)

  local context = {
    theme = theme,
    themeBuilder = services.themeBuilder,
    primitives = primitives,
    state = services.state,
    fonts = fonts,
    layout = layout,
    settings = settings,
    rect = {x = rect.x, y = rect.y, w = rect.w, h = rect.h},
    stateName = "normal",
    text = "--",
    labelsText = "",
    imagePath = nil,
  }

  local modelService = services.model
  if modelService then context.feed = modelService:identity() end

  local panel = primitives.panel(parent, rect, theme, presentation)
  context.panel = panel

  context.label, context.badge = primitives.header(
    panel.root, theme, area.frame, fonts, settings.label, presentation,
    services.themeBuilder)

  context.value = primitives.value(panel.root, theme, {
    x = area.valueX,
    y = area.nameY,
    w = area.valueWidth,
    text = "--",
    color = presentation.value,
    font = area.nameFont,
  })

  -- Built only where the layout asked for the label list. It used to be
  -- built on every panel and hidden on most, which is an object and a write
  -- per reflow for a row that can never be filled.
  if layout.showLabels then
    context.labelsLabel = primitives.label(panel.root, theme, {
      x = area.pad,
      y = area.labelsY,
      w = area.content,
      text = "",
      color = theme.color.textFaint,
      font = fonts.label,
    })
  end

  -- What the panel currently draws, so `render` declares only that.
  context.showName = area.showName
  context.showLabels = area.showLabels
  context.showImage = area.showImage

  if not area.showName then lvgl.hide(context.value) end
  if context.labelsLabel and not area.showLabels then
    lvgl.hide(context.labelsLabel)
  end

  context.area = area
  -- The first paint goes through the same path as every later one.
  local _, drawn = primitives.changed(context, modelIdentity.render)
  modelIdentity.apply(context, drawn)
  return context
end

--- Create the image once the model's bitmap is known to exist.
--- The object is built lazily because identity is only read after create, and
--- it is created exactly once: rebuilding it on every refresh would reload the
--- file from the SD card.
---@param context AeroGridIdentityContext
---@param path string
function modelIdentity.ensureImage(context, path)
  if context.image or not context.area.showImage then return end

  local area = context.area
  context.image = context.primitives.image(context.panel.root, {
    x = area.pad,
    y = area.imageY,
    w = area.content,
    h = area.imageHeight,
    file = path,
    -- **Contain, not cover.** `fill` reaches EdgeTX as `StaticImage`'s
    -- `fillFrame`, and `setZoom` computes
    -- `z = fillFrame ? max(zw, zh) : min(zw, zh)`. The larger zoom scales
    -- until the frame is covered and cuts off whatever does not fit; the
    -- smaller scales until the whole picture is inside it and leaves the
    -- panel showing at the ends. A model image is the aircraft, and a
    -- cropped aircraft is a worse answer than a smaller one: at four cells
    -- by two, covering kept a tenth of the picture's height.
    --
    -- `dontEnlarge` defaults false in the same constructor, so a picture
    -- smaller than its frame is scaled up to meet it rather than sitting
    -- small in the middle.
    fill = false,
  })
  context.imagePath = path

  -- With the picture in place the name becomes supporting text unless the
  -- layout asked for both, so an image-only panel really is image only.
  if not context.layout.showName then lvgl.hide(context.value) end
end

--- Repaint the component from its current subscription.
---@param context AeroGridIdentityContext
--- Collect everything this panel draws, into one table.
---
--- The labels row is the reason this exists. It was drawn by `apply` and left
--- out of the refresh comparison, which compared only the name and the bitmap.
--- Nothing could be made to fail, because a model's labels change only when
--- the model does and that changes its name too, so the missed field was
--- masked by a compared one. It was unreachable by coincidence. Collecting
--- what is drawn, and comparing exactly that, makes it unreachable by
--- construction instead.
---@param context AeroGridIdentityContext
---@param out table
function modelIdentity.render(context, out)
  local feed = context.feed
  local available = type(feed) == "table" and feed.available == true

  out.state = available and "normal" or "unavailable"
  local name = available and feed.name or ""
  out.text = name ~= "" and name or "--"
  -- Gated on `area`, which is what the box granted, rather than on `layout`,
  -- which is only what the span asked for. A panel whose ladder sheds the row
  -- was still writing the label list into a hidden label every time the model
  -- changed, which is the work this stopped doing everywhere else.
  if context.showLabels and available then
    out.labels = feed.labels or ""
  end
  -- The path decides whether an image is created, so it is part of what the
  -- panel draws even though it is not text.
  out.bitmapPath = available and feed.bitmapPath or nil
end

--- Paint the panel from what `render` collected, and from nothing else.
---@param context AeroGridIdentityContext
---@param drawn table
function modelIdentity.apply(context, drawn)
  local presentation = context.state(drawn.state, context.settings.accent)

  context.stateName = drawn.state
  context.text = drawn.text
  context.labelsText = drawn.labels or ""

  -- **The heading says which model where the picture says what it is.** A
  -- panel drawing a picture has no room for the name below it and no need of
  -- a word like `MODEL` above it: the picture states the category and the
  -- name states the individual. So the name takes the heading and the
  -- configured label is not drawn.
  --
  -- It goes through the heading's own fitting, which upper-cases, steps the
  -- font down and finally abbreviates and reports what it dropped. A model
  -- name is treated as a heading here and as a reading in the other
  -- arrangement, and the two therefore do different things to the same
  -- string -- which is the cost of the picture being the subject when there
  -- is one.
  -- Resolved before the heading is chosen, because which text the heading
  -- carries depends on whether a picture is actually drawn -- and that is
  -- only known once the file has been looked for. Deciding the heading first
  -- would show the configured label for one frame and then replace it.
  modelIdentity.resolveImage(context, drawn)

  local heading = context.settings.label
  if context.area.nameIsHeading and context.image then
    heading = drawn.text
  end
  if heading ~= context.headingText then
    context.headingText = heading
    context.primitives.placeHeader(context.label, context.badge,
      context.area.frame, context.themeBuilder, context.fonts, heading,
        context.badgeText)
  end

  context.value:set({text = drawn.text, color = presentation.value})
  -- The name is centred on its slot, so where it starts depends on what it
  -- reads. Keyed on the text, so a model that has not been renamed costs
  -- nothing beyond the comparison.
  context.primitives.centreReading(context, context.themeBuilder,
    context.area, context.area.nameFont, drawn.text)
  context.label:set({color = presentation.label})
  context.primitives.setBadge(context, context.themeBuilder, context.badge,
    context.area.frame, context.fonts.badge, presentation.badge or "",
    presentation.accent)
  if context.showLabels then
    context.labelsLabel:set({text = context.labelsText})
    -- A row of one item centres across the content box, as a lone reading
    -- does.
    context.primitives.centreLabel(context, "labelsAnchor",
      context.themeBuilder, context.labelsLabel, context.area.labelsCentre,
      context.area.labelsY, context.fonts.label, context.labelsText)
  end
  context.primitives.stylePanel(context.panel, presentation)
end

--- Decide whether this panel can draw its picture, and build it if so.
---
--- Split out of `apply` because the heading's text depends on the answer: a
--- panel showing a picture puts the model name up there, and one that cannot
--- keeps its configured label. Asking afterwards drew the label for a frame
--- and then replaced it.
---@param context AeroGridIdentityContext
---@param drawn table
function modelIdentity.resolveImage(context, drawn)
  if drawn.state ~= "normal" or not context.area.showImage then return end

  local path = drawn.bitmapPath
  if type(path) ~= "string" or path == "" then
    -- No image is configured at all, so the name is the identity.
    modelIdentity.revealName(context)
    return
  end
  if context.imagePath == path or context.imageRejected == path then return end

  local exists, checked = modelIdentity.fileExists(path)
  if exists or not checked then
    -- Without `fstat` nothing can be proven, so the image is attempted and
    -- the name is deliberately left visible as the fallback.
    modelIdentity.ensureImage(context, path)
    if not checked then modelIdentity.revealName(context) end
  else
    context.imageRejected = path
    modelIdentity.revealName(context)
  end
end

--- Fall back to the model name when the image cannot be shown.
---@param context AeroGridIdentityContext
function modelIdentity.revealName(context)
  if context.image then return end

  local area = context.area
  context.value:set({x = area.valueX, y = area.nameY,
    w = area.valueWidth})
  lvgl.show(context.value)
end

--- Advance the component, repainting only when something drawn changed.
---@param context AeroGridIdentityContext
function modelIdentity.refresh(context)
  if not context.feed then return end

  local changed, drawn = context.primitives.changed(
    context, modelIdentity.render)
  if changed then modelIdentity.apply(context, drawn) end
end

--- Reposition after a zone change.
---@param context AeroGridIdentityContext
---@param rect AeroGridRect
function modelIdentity.update(context, rect)
  local area = modelIdentity.regionsFor(context.theme, context.themeBuilder,
    rect, context.layout, context.fonts)
  context.area = area

  context.primitives.resizePanel(context.panel, rect)
  context.primitives.placeHeader(context.label, context.badge, area.frame,
    context.themeBuilder, context.fonts, context.settings.label,
      context.badgeText)

  local primitives = context.primitives
  -- The name stays visible when there is no image, whatever the arrangement
  -- asked for, because a panel showing neither is a panel showing nothing.
  local nameVisible = area.showName or not context.image

  primitives.reconcile(context.value, nameVisible, {
    x = area.valueX,
    -- The body band, whether or not a picture was asked for. Where one is
    -- drawn the name is the heading and this object is hidden; where one was
    -- asked for and could not be drawn the name is the reading, and a
    -- reading belongs in the band. This used to read the panel's content top
    -- in exactly that fallback, which put the name under the heading on the
    -- one path where nothing else was there to explain it.
    y = area.nameY,
    -- The width the name draws in, not the room it had: a box given the
    -- whole content box and an x centred for a shorter string reaches past
    -- the panel's right edge by the difference.
    w = area.valueWidth,
    font = function() return area.nameFont end,
  }, nameVisible == context.showName)
  -- Every anchor is about a slot and a font that have just moved, and the
  -- box above was sized from the widest name rather than the current one.
  context.readingAnchor, context.readingUnitAnchor = nil, nil
  context.labelsAnchor = nil
  primitives.centreReading(context, context.themeBuilder, area,
    area.nameFont, context.text)

  primitives.reconcile(context.labelsLabel, area.showLabels,
    {x = area.pad, y = area.labelsY, w = area.content},
    area.showLabels == context.showLabels)
  primitives.centreLabel(context, "labelsAnchor", context.themeBuilder,
    area.showLabels and context.labelsLabel or nil, area.labelsCentre,
    area.labelsY, context.fonts.label, context.labelsText)

  primitives.reconcile(context.image, area.showImage, {
    x = area.pad,
    y = area.imageY,
    w = area.content,
    h = area.imageHeight,
  }, area.showImage == context.showImage)

  -- A row that has just reappeared holds whatever it had when it was shed,
  -- and `render` stopped declaring its key while it was hidden.
  if area.showLabels ~= context.showLabels then context.rendered = nil end
  context.showName = nameVisible
  context.showLabels = area.showLabels
  context.showImage = area.showImage
end

return modelIdentity
