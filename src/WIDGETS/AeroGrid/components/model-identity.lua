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
  if type(config) ~= "table" or not config.showLabels then return messages end
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
  local ladder = themeBuilder.ladder(theme, rect, frame)
  showLabels = showLabels and ladder.rows > 0

  local nameFont, formIndex = themeBuilder.fitReading(
    FORMS, frame.content, ladder.room)
  local nameHeight = themeBuilder.fontHeight(nameFont)

  -- The image takes whatever the text does not, and is dropped entirely when
  -- that leaves it too little to be recognizable. Every row that will be drawn
  -- has to come out of its height: the image is created after the labels, so
  -- it paints over anything it is allowed to overlap.
  local imageTop = top
  local imageHeight = rect.h - top - frame.bottom
  local nameY = top

  if showLabels then imageHeight = imageHeight - labelHeight - 2 end

  if showImage and showName then
    imageHeight = imageHeight - nameHeight - 2
    nameY = rect.h - frame.bottom - nameHeight
      - (showLabels and (labelHeight + 2) or 0)
  end
  if showImage and imageHeight < 24 then
    showImage = false
    imageHeight = 0
    nameY = top
  end

  return {
    frame = frame,
    pad = frame.pad,
    content = frame.content,
    nameY = nameY,
    nameFont = nameFont,
    formIndex = formIndex,
    imageY = imageTop,
    imageHeight = math.max(1, imageHeight),
    labelsY = math.max(1, rect.h - frame.bottom - labelHeight),
    showName = showName,
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
    panel.root, theme, area.frame, fonts, settings.label, presentation)

  context.value = primitives.value(panel.root, theme, {
    x = area.pad,
    y = area.nameY,
    w = area.content,
    text = "--",
    color = presentation.value,
    font = area.nameFont,
  })

  context.labelsLabel = primitives.label(panel.root, theme, {
    x = area.pad,
    y = area.labelsY,
    w = area.content,
    text = "",
    color = theme.color.textFaint,
    font = fonts.label,
  })

  -- What the panel currently draws, so `render` declares only that.
  context.showName = area.showName
  context.showLabels = area.showLabels
  context.showImage = area.showImage

  if not area.showName then lvgl.hide(context.value) end
  if not area.showLabels then lvgl.hide(context.labelsLabel) end

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
    fill = true,
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

  context.value:set({text = drawn.text, color = presentation.value})
  context.label:set({color = presentation.label})
  context.badge:set({text = presentation.badge or "", color = presentation.accent})
  if context.showLabels then
    context.labelsLabel:set({text = context.labelsText})
  end
  context.primitives.stylePanel(context.panel, presentation)

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
  context.value:set({x = area.pad, y = area.frame.top, w = area.content})
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
  context.primitives.placeHeader(context.label, context.badge, area.frame)

  local primitives = context.primitives
  -- The name stays visible when there is no image, whatever the arrangement
  -- asked for, because a panel showing neither is a panel showing nothing.
  local nameVisible = area.showName or not context.image

  primitives.reconcile(context.value, nameVisible, {
    x = area.pad,
    y = context.image and area.nameY or area.frame.top,
    w = area.content,
    font = function() return area.nameFont end,
  }, nameVisible == context.showName)

  primitives.reconcile(context.labelsLabel, area.showLabels,
    {x = area.pad, y = area.labelsY, w = area.content},
    area.showLabels == context.showLabels)

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
