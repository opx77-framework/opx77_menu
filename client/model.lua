--- The model: the validated tree, the navigation stack, and the view.

OpxMenu = OpxMenu or {}

--- Mirrors `version` in open77.lua, which no Lua code can read; a release moves both lines.
OpxMenu.VERSION = "0.4.0"

local Text = OpxMenu.Text

local Model = {}
OpxMenu.model = Model

-- The host silently drops any event past 1024 value nodes, and `data` rides in every one.
local MAX_NODES = 400

local MAX_DATA_NODES = 64
local MAX_DATA_DEPTH = 4
local MAX_ROWS = 200
local MAX_DEPTH = 8

local MAX_LABEL = 96
local MAX_VALUE = 48
local MAX_DESCRIPTION = 160

--- A finite number: not NaN, not an infinity.
---@param value any
---@return boolean
local function finite(value)
  -- `value == value` is the NaN test: NaN is the one value unequal to itself
  return type(value) == "number" and value == value
    and value > -math.huge and value < math.huge
end

local function validName(value, maximum)
  return type(value) == "string" and #value > 0 and #value <= maximum
    and value:match("^[%w_:%-%.]+$") ~= nil
end

--- Rows drawn at once. Resolved once from the operator's config: a value that is not a
--- whole number of at least one would silently draw an empty window on every frame.
local VISIBLE_ROWS = 9
do
  local rows = OPX_MENU_CONFIG.VISIBLE_ROWS
  if finite(rows) and rows >= 1 then VISIBLE_ROWS = math.floor(rows) end
end

--- Text the status line accepts. A table would sanitise to nil and silently clear the
--- line, so every path that writes it refuses one.
---@param value any
---@return boolean
local function validStatus(value)
  return value == nil or type(value) == "string" or type(value) == "number"
end

--- Status-line validator, shared with client/exports.lua.
Model.validStatus = validStatus

--- Resource-name validator, shared with client/exports.lua.
Model.validName = validName

---@param slider MenuSlider
---@return MenuSlider|nil, string|nil
local function normalizeSlider(slider)
  if type(slider) ~= "table" then return nil, "invalid_slider" end
  local minimum = finite(slider.min) and slider.min + 0.0 or 0.0
  local maximum = finite(slider.max) and slider.max + 0.0 or 100.0
  if maximum <= minimum then return nil, "invalid_slider_range" end
  local step = finite(slider.step) and math.abs(slider.step) + 0.0 or 1.0
  if step <= 0 then step = 1.0 end
  local value = finite(slider.value) and slider.value + 0.0 or minimum
  if value < minimum then value = minimum end
  if value > maximum then value = maximum end
  local suffix = Text.clean(slider.suffix, 8) or ""
  return { min = minimum, max = maximum, step = step, value = value, suffix = suffix }
end

---@param item MenuItem
---@return table|nil, string|nil
local function normalizeChoices(item)
  local raw = item.choices
  if type(raw) ~= "table" then return nil, "invalid_choices" end
  local labels = {}
  for index = 1, #raw do
    local label = Text.clean(raw[index], MAX_VALUE)
    if label == nil then return nil, "invalid_choice" end
    labels[index] = label
  end
  if #labels == 0 then return nil, "empty_choices" end
  local selected = finite(item.selected) and math.floor(item.selected) or 1
  if selected < 1 or selected > #labels then selected = 1 end
  return { labels = labels, selected = selected }
end

--- Count a caller's opaque table, refusing rather than truncating.
---@param value any
---@param depth integer
---@param budget table
---@return boolean
local function fitsInPayload(value, depth, budget)
  budget.data = budget.data + 1
  if budget.data > MAX_DATA_NODES then return false end
  if type(value) ~= "table" then return true end
  if depth > MAX_DATA_DEPTH then return false end
  for key, nested in pairs(value) do
    if not fitsInPayload(key, depth + 1, budget) then return false end
    if not fitsInPayload(nested, depth + 1, budget) then return false end
  end
  return true
end

local normalizeItems

--- Normalise one item. `budget` is shared by the whole tree, wide or deep.
---@param item MenuItem
---@param index integer
---@param depth integer
---@param budget table
---@return MenuEntry|nil, string|nil
local function normalizeItem(item, index, depth, budget)
  if type(item) ~= "table" then return nil, "item_must_be_a_table" end

  budget.nodes = budget.nodes + 1
  if budget.nodes > MAX_NODES then return nil, "menu_too_large" end

  local id = item.id
  if id == nil then
    id = "item_" .. tostring(index)
  elseif not validName(id, 64) then
    return nil, "invalid_item_id"
  end

  if item.separator == true then
    return { id = id, kind = "separator", label = Text.clean(item.label, MAX_LABEL) or "" }
  end

  local label = Text.clean(item.label or item.text, MAX_LABEL)
  if label == nil or label == "" then return nil, "invalid_item_label" end

  if item.event ~= nil and not validName(item.event, 96) then
    return nil, "invalid_item_event"
  end
  if item.description ~= nil and Text.clean(item.description, MAX_DESCRIPTION) == nil then
    return nil, "invalid_item_description"
  end

  if item.data ~= nil then
    if type(item.data) ~= "table" then return nil, "invalid_item_data" end
    if not fitsInPayload(item.data, 1, { data = 0 }) then return nil, "item_data_too_large" end
  end

  local entry = {
    id = id,
    label = label,
    description = Text.clean(item.description, MAX_DESCRIPTION),
    event = item.event,
    data = item.data,
    disabled = item.disabled == true,
    -- nil, not false: the menu-wide default answers where an item does not.
    close = item.close == true or nil,
  }

  if item.items ~= nil then
    if depth >= MAX_DEPTH then return nil, "menu_too_deep" end
    local children, reason = normalizeItems(item.items, depth + 1, budget)
    if children == nil then return nil, reason end
    entry.kind = "submenu"
    entry.items = children
    entry.title = Text.clean(item.title, MAX_LABEL) or label
    entry.value = Text.clean(item.value, MAX_VALUE)
    -- Resolved when the screen is pushed, not here: `update` rebuilds this list.
    entry.cursor = item.cursor
    return entry
  end

  if type(item.toggle) == "boolean" then
    entry.kind = "toggle"
    entry.on = item.toggle
    entry.labels = {
      on = Text.clean(item.onLabel, MAX_VALUE) or "ON",
      off = Text.clean(item.offLabel, MAX_VALUE) or "OFF",
    }
    return entry
  end

  if item.choices ~= nil then
    local choices, reason = normalizeChoices(item)
    if choices == nil then return nil, reason end
    entry.kind = "choices"
    entry.choices = choices.labels
    entry.selected = choices.selected
    return entry
  end

  if item.slider ~= nil then
    local slider, reason = normalizeSlider(item.slider)
    if slider == nil then return nil, reason end
    entry.kind = "slider"
    entry.slider = slider
    return entry
  end

  if item.back == true then
    entry.kind = "back"
    return entry
  end

  if item.close == true and item.event == nil then
    -- `close = true` beside an `event` stays an action that also closes.
    entry.kind = "close"
    return entry
  end

  entry.kind = "action"
  entry.value = Text.clean(item.value, MAX_VALUE)
  return entry
end

---@param items MenuItem[]
---@param depth integer
---@param budget table
---@return MenuEntry[]|nil, string|nil
normalizeItems = function(items, depth, budget)
  if type(items) ~= "table" then return nil, "items_must_be_a_table" end
  local total = #items
  if total > MAX_ROWS then return nil, "too_many_items" end

  local list = {}
  for index = 1, total do
    local entry, reason = normalizeItem(items[index], index, depth, budget)
    if entry == nil then return nil, reason end
    list[index] = entry
  end
  if #list == 0 then return nil, "empty_menu" end
  -- A screen of only disabled rows is allowed; a screen of only separators is not.
  local substantial = false
  for index = 1, #list do
    if list[index].kind ~= "separator" then substantial = true break end
  end
  if not substantial then return nil, "only_separators" end
  return list
end

---@param entry MenuEntry|nil
---@return boolean
local function selectable(entry)
  return entry ~= nil and entry.kind ~= "separator" and not entry.disabled
end

--- Where the cursor starts: the row a caller named, or the first selectable one.
---@param items MenuEntry[]
---@param wanted MenuCursor|nil
---@return integer
local function cursorIndex(items, wanted)
  local total = #items
  if type(wanted) == "string" then
    for index = 1, total do
      local entry = items[index]
      if entry.id == wanted and selectable(entry) then return index end
    end
  elseif type(wanted) == "number" and wanted % 1 == 0 then
    local index = math.floor(wanted)
    if selectable(items[index]) then return index end
  end
  for index = 1, total do
    if selectable(items[index]) then return index end
  end
  return 1
end

---@param items MenuEntry[]
---@param title string
---@param id string|nil
---@param cursor MenuCursor|nil
---@return MenuFrame
local function frame(items, title, id, cursor)
  return { items = items, title = title, id = id, index = cursorIndex(items, cursor) }
end

--- Build a menu from a caller's spec.
---@param owner string
---@param generation integer
---@param spec MenuSpec
---@return MenuRecord|nil, string|nil  the record, or nil and a reason
function Model.build(owner, generation, spec)
  if not validName(owner, 64) then return nil, "invalid_owner" end
  if type(spec) ~= "table" then return nil, "spec_must_be_a_table" end

  local id = spec.id
  if id == nil then
    id = owner
  elseif not validName(id, 64) then
    return nil, "invalid_menu_id"
  end

  local title = Text.clean(spec.title, MAX_LABEL)
  if title == nil or title == "" then title = owner:upper() end

  if spec.event ~= nil and not validName(spec.event, 96) then
    return nil, "invalid_menu_event"
  end

  if not validStatus(spec.status) then return nil, "invalid_status" end

  if spec.data ~= nil then
    if type(spec.data) ~= "table" then return nil, "invalid_menu_data" end
    if not fitsInPayload(spec.data, 1, { data = 0 }) then return nil, "menu_data_too_large" end
  end

  local budget = { nodes = 0 }
  local items, reason = normalizeItems(spec.items, 1, budget)
  if items == nil then return nil, reason end

  local record = {
    owner = owner,
    generation = generation,
    id = id,
    title = title,
    event = spec.event,
    data = spec.data,
    closeOnSelect = spec.closeOnSelect == true,
    reportFocus = spec.reportFocus == true,
    items = items,
    nodes = budget.nodes,
    stack = { frame(items, title, nil, spec.cursor) },
  }
  return record
end

--- Re-walk the stack onto a freshly built tree, by id, so an update keeps the
--- player's screen.
---@param record MenuRecord
---@param items MenuEntry[]
---@param title string
---@return MenuFrame[]
local function rewalk(record, items, title)
  -- Not `spec.cursor`: that says where a menu OPENS, not where it moves.
  local root = math.min(record.stack[1].index, #items)
  local stack = { frame(items, title, nil, root) }
  local cursor = items
  for depth = 2, #record.stack do
    local previous = record.stack[depth]
    local found
    for index = 1, #cursor do
      local entry = cursor[index]
      if entry.id == previous.id and entry.kind == "submenu" then found = entry break end
    end
    if found == nil then break end
    -- Re-settled, not clamped: the update may have disabled the row it sits on.
    stack[#stack + 1] = frame(found.items, found.title, found.id, previous.index)
    cursor = found.items
  end
  return stack
end

--- Rebuild a live menu from a new spec, keeping the player's position.
---@param record MenuRecord
---@param spec MenuSpec
---@return boolean, string|nil
function Model.rebuild(record, spec)
  if type(spec) ~= "table" then return false, "spec_must_be_a_table" end
  -- Every field is checked before any is written: a refused patch must change nothing.
  if not validStatus(spec.status) then return false, "invalid_status" end

  local items, nodes
  if spec.items ~= nil then
    local budget = { nodes = 0 }
    local built, reason = normalizeItems(spec.items, 1, budget)
    if built == nil then return false, reason end
    items, nodes = built, budget.nodes
  end

  local title
  if spec.title ~= nil then title = Text.clean(spec.title, MAX_LABEL) end

  if spec.event ~= nil and not validName(spec.event, 96) then
    return false, "invalid_menu_event"
  end

  if spec.data ~= nil then
    if type(spec.data) ~= "table" then return false, "invalid_menu_data" end
    if not fitsInPayload(spec.data, 1, { data = 0 }) then return false, "menu_data_too_large" end
  end

  if items ~= nil then
    record.items = items
    record.nodes = nodes
  end
  if title ~= nil then record.title = title end
  if spec.event ~= nil then record.event = spec.event end
  if spec.data ~= nil then record.data = spec.data end
  if spec.closeOnSelect ~= nil then record.closeOnSelect = spec.closeOnSelect == true end
  if spec.reportFocus ~= nil then record.reportFocus = spec.reportFocus == true end

  -- Read back off the record: only the fields the patch carried have moved.
  record.stack = rewalk(record, record.items, record.title)
  return true
end

---@param record MenuRecord
---@return MenuFrame|nil
function Model.frame(record)
  return record.stack[#record.stack]
end

---@param record MenuRecord
---@return MenuEntry|nil
function Model.item(record)
  local top = Model.frame(record)
  if top == nil then return nil end
  return top.items[top.index]
end

--- Move the cursor, skipping separators and disabled rows. Wraps.
---@param record MenuRecord
---@param delta integer
---@return boolean  true when the cursor moved
function Model.move(record, delta)
  local top = Model.frame(record)
  if top == nil then return false end
  local total = #top.items
  if total == 0 then return false end
  local index = top.index
  -- Bounded by the row count: a screen of only separators must not hang the tick.
  for _ = 1, total do
    index = ((index - 1 + delta) % total) + 1
    if selectable(top.items[index]) then
      if index == top.index then return false end
      top.index = index
      return true
    end
  end
  return false
end

--- Put the cursor on the first selectable row of the current screen.
---@param record MenuRecord
function Model.settle(record)
  local top = Model.frame(record)
  if top == nil then return end
  if selectable(top.items[top.index]) then return end
  for index = 1, #top.items do
    if selectable(top.items[index]) then top.index = index return end
  end
end

---@param record MenuRecord
---@param entry MenuEntry|nil
---@return boolean
function Model.push(record, entry)
  if entry == nil or entry.kind ~= "submenu" then return false end
  if #record.stack >= MAX_DEPTH then return false end
  record.stack[#record.stack + 1] =
    frame(entry.items, entry.title, entry.id, entry.cursor)
  Model.settle(record)
  return true
end

---@param record MenuRecord
---@return boolean
function Model.pop(record)
  if #record.stack <= 1 then return false end
  record.stack[#record.stack] = nil
  return true
end

--- The right-hand text for a row. Derived, never stored.
---@param entry MenuEntry|nil
---@return string|nil
function Model.value(entry)
  if entry == nil then return nil end
  local kind = entry.kind
  if kind == "toggle" then
    return entry.on and entry.labels.on or entry.labels.off
  elseif kind == "choices" then
    return entry.choices[entry.selected]
  elseif kind == "slider" then
    local slider = entry.slider
    local number = slider.value
    -- Whole values print without a decimal: "VOLUME 70.0%" reads as a bug.
    local text = number % 1 == 0 and tostring(math.floor(number)) or string.format("%.2f", number)
    return text .. slider.suffix
  end
  return entry.value
end

--- The machine-readable current value, for the event payload.
---@param entry MenuEntry|nil
---@return any
function Model.raw(entry)
  if entry == nil then return nil end
  local kind = entry.kind
  if kind == "toggle" then return entry.on end
  if kind == "choices" then return entry.choices[entry.selected] end
  if kind == "slider" then return entry.slider.value end
  return entry.value
end

--- Does this row hold a value LEFT and RIGHT move?
---@param entry MenuEntry|nil
---@return boolean
function Model.holdsValue(entry)
  if entry == nil then return false end
  return entry.kind == "toggle" or entry.kind == "choices" or entry.kind == "slider"
end

--- LEFT/RIGHT on the selected item.
---@param entry MenuEntry|nil
---@param delta integer
---@return boolean  true when something changed
function Model.adjust(entry, delta)
  if entry == nil or entry.disabled then return false end
  local kind = entry.kind
  if kind == "toggle" then
    entry.on = not entry.on
    return true
  elseif kind == "choices" then
    local total = #entry.choices
    if total <= 1 then return false end
    entry.selected = ((entry.selected - 1 + delta) % total) + 1
    return true
  elseif kind == "slider" then
    local slider = entry.slider
    local before = slider.value
    local value = slider.value + (slider.step * delta)
    -- Clamped, not wrapped: a volume that jumps from 0 to 100 is a complaint.
    if value < slider.min then value = slider.min end
    if value > slider.max then value = slider.max end
    -- Snapped to the grid: 0.1 added ten times is not 1.0.
    local steps = math.floor(((value - slider.min) / slider.step) + 0.5)
    value = slider.min + (steps * slider.step)
    if value > slider.max then value = slider.max end
    slider.value = value
    return value ~= before
  end
  return false
end

--- Which slice of a long list is on screen, cursor near the middle of the window.
---@param index integer
---@param total integer
---@param rows integer
---@return integer
local function windowFirst(index, total, rows)
  if total <= rows then return 1 end
  local first = index - (rows // 2)
  if first < 1 then first = 1 end
  if first > total - rows + 1 then first = total - rows + 1 end
  return first
end

--- The breadcrumb, built from the stack's titles.
---@param record MenuRecord
---@return string
local function trail(record)
  local stack = record.stack
  local parts = {}
  for depth = 1, #stack do
    parts[depth] = stack[depth].title or ""
  end
  return table.concat(parts, " / ")
end

--- Everything the page needs for one frame: a window of rows, never the whole list.
---@param record MenuRecord
---@return MenuView|nil
function Model.view(record)
  local top = Model.frame(record)
  if top == nil then return nil end
  local rows = VISIBLE_ROWS
  local total = #top.items
  local first = windowFirst(top.index, total, rows)
  local window = {}
  local last = math.min(first + rows - 1, total)
  for index = first, last do
    local entry = top.items[index]
    local kind = entry.kind
    window[index - first + 1] = {
      label = entry.label,
      value = Model.value(entry),
      -- nil rather than false: an absent field costs no value node.
      arrow = kind == "submenu" or nil,
      spin = (kind == "choices" or kind == "slider" or kind == "toggle") or nil,
      rule = kind == "separator" or nil,
      off = entry.disabled or nil,
      on = (index == top.index) or nil,
    }
  end
  local selected = top.items[top.index]
  return {
    title = top.title,
    trail = #record.stack > 1 and trail(record) or nil,
    rows = window,
    first = first,
    total = total,
    index = top.index,
    depth = #record.stack,
    hint = selected and selected.description or nil,
    -- Only the failure flag crosses: `a and a.ok or nil` would collapse a false.
    status = record.status and record.status.text or nil,
    statusBad = record.status ~= nil and not record.status.ok or nil,
  }
end

--- The payload every event carries. One shape for every action.
---@param record MenuRecord
---@param entry MenuEntry|nil
---@param action MenuAction
---@return MenuPayload
function Model.payload(record, entry, action)
  local top = Model.frame(record)
  local payload = {
    menu = record.id,
    handle = record.handle,
    owner = record.owner,
    action = action,
    itemId = entry and entry.id or nil,
    label = entry and entry.label or nil,
    index = top and top.index or nil,
    depth = #record.stack,
    data = entry and entry.data or nil,
    menuData = record.data,
  }
  -- Assigned, not folded above: `x and raw(x) or nil` would collapse a false toggle.
  if entry ~= nil then payload.value = Model.raw(entry) end
  return payload
end
