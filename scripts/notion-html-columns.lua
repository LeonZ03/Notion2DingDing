-- 补齐 Pandoc 不会自动保留的 Notion HTML 结构语义：
-- 1. Notion 单图 figure 改为普通图片段落，避免 Pandoc 在 DOCX 中生成 1×1 图形表；
-- 2. column-list/column 映射为一行 Word 布局表；只有一个 column 时直接解包；
-- 3. to-do-list 去掉错误的普通圆点层，同时保留 Pandoc 生成的 ☐/☒ 状态标记，
--    供钉钉导入后恢复为原生可点击待办。

local PAGE_CONTENT_WIDTH_INCHES = 10.0
local CELL_PADDING_INCHES = 0.12

local function has_class(classes, expected)
  for _, class_name in ipairs(classes) do
    if class_name == expected then
      return true
    end
  end
  return false
end

local function read_ratio(column)
  local ratio = tonumber(column.attributes["notion-column-ratio"] or "")
  if ratio and ratio > 0 then
    return ratio
  end

  local style = column.attributes.style or ""
  local percent = tonumber(style:match("width:%s*([%d%.]+)%%"))
  if percent and percent > 0 then
    return percent / 100
  end
  return 0
end

local function width_in_inches(image)
  local raw = image.attributes.width or ""
  local number, unit = raw:match("^%s*([%d%.]+)%s*(%a+)%s*$")
  number = tonumber(number)
  if number and unit == "in" then
    return number
  elseif number and unit == "cm" then
    return number / 2.54
  elseif number and unit == "mm" then
    return number / 25.4
  elseif number and unit == "pt" then
    return number / 72
  elseif number and unit == "px" then
    return number / 96
  end

  local style = image.attributes.style or ""
  local pixels = tonumber(style:match("width:%s*([%d%.]+)px"))
  if pixels then
    return pixels / 96
  end
  return nil
end

local function fit_column_images(column, ratio)
  local maximum = math.max(0.75, PAGE_CONTENT_WIDTH_INCHES * ratio - CELL_PADDING_INCHES)
  return pandoc.walk_block(column, {
    Image = function(image)
      local original = width_in_inches(image)
      local target = maximum
      if original and original < target then
        target = original
      end
      image.attributes.width = string.format("%.3fin", target)
      image.attributes.height = nil
      image.attributes.style = nil
      return image
    end,
  })
end

local function todo_state(item)
  local first = item[1]
  if not first or (first.t ~= "Plain" and first.t ~= "Para") then
    return nil
  end
  local marker = first.content[1]
  if not marker or marker.t ~= "Str" then
    return nil
  end
  if marker.text == "☒" then
    return true
  elseif marker.text == "☐" then
    return false
  end
  return nil
end

function BulletList(element)
  for _, item in ipairs(element.content) do
    if todo_state(item) == nil then
      return nil
    end
  end

  local blocks = {}
  for _, item in ipairs(element.content) do
    local first = item[1]
    table.insert(blocks, pandoc.Para(first.content))
    for index = 2, #item do
      table.insert(blocks, item[index])
    end
  end
  return blocks
end

function Figure(element)
  if not has_class(element.classes, "image") then
    return nil
  end

  local blocks = {}
  for _, block in ipairs(element.content) do
    table.insert(blocks, block)
  end

  local caption = element.caption
  if caption then
    if caption.long and #caption.long > 0 then
      for _, block in ipairs(caption.long) do
        table.insert(blocks, block)
      end
    elseif caption.short and #caption.short > 0 then
      table.insert(blocks, pandoc.Para(caption.short))
    end
  end
  return blocks
end

function Div(element)
  if not has_class(element.classes, "column-list") then
    return nil
  end

  local columns = {}
  local widths = {}
  local total = 0
  for _, block in ipairs(element.content) do
    if block.t == "Div" and has_class(block.classes, "column") then
      table.insert(columns, block)
      local ratio = read_ratio(block)
      table.insert(widths, ratio)
      total = total + ratio
    end
  end

  if #columns == 1 then
    return columns[1].content
  elseif #columns == 0 then
    return element.content
  end
  if total <= 0 then
    total = #columns
    for index = 1, #columns do
      widths[index] = 1
    end
  end

  local cells = {}
  local aligns = {}
  local normalized_widths = {}
  for index, column in ipairs(columns) do
    local normalized = widths[index] / total
    local fitted = fit_column_images(column, normalized)
    table.insert(cells, fitted.content)
    table.insert(aligns, pandoc.AlignDefault)
    table.insert(normalized_widths, normalized)
  end

  local simple = pandoc.SimpleTable({}, aligns, normalized_widths, {}, { cells })
  local result = pandoc.utils.from_simple_table(simple)
  result.attr = pandoc.Attr(
    "",
    { "notion-column-layout" },
    { ["custom-style"] = "Notion Columns" }
  )
  return result
end
