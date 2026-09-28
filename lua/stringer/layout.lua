local M = {}

local function characters(text)
  local result = {}
  for i = 0, vim.fn.strchars(text) - 1 do result[#result + 1] = vim.fn.strcharpart(text, i, 1) end
  return result
end

-- Widths are display cells, not bytes. Left truncation keeps location endings.
function M.fit(text, width, left)
  width = math.max(0, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  if width == 0 then return '' end
  local chars, result, cells = characters(text), '', 0
  if left then
    for i = #chars, 1, -1 do
      local size = vim.fn.strdisplaywidth(chars[i])
      if cells + size > width - 1 then break end
      result, cells = chars[i] .. result, cells + size
    end
    return '…' .. result
  end
  for _, char in ipairs(chars) do
    local size = vim.fn.strdisplaywidth(char)
    if cells + size > width - 1 then break end
    result, cells = result .. char, cells + size
  end
  return result .. '…'
end

local function wrap(text, width)
  local rows, row, cells = {}, '', 0
  for _, char in ipairs(characters(text)) do
    local size = vim.fn.strdisplaywidth(char)
    if cells + size > width and row ~= '' then
      rows[#rows + 1], row, cells = row, '', 0
    end
    -- A two-cell glyph cannot fit a one-cell pane; keep rendering bounded.
    if size > width then char, size = '…', 1 end
    row, cells = row .. char, cells + size
  end
  rows[#rows + 1] = row
  return rows
end

function M.suffixes(marks)
  local files, result = {}, {}
  for _, mark in ipairs(marks) do files[mark.file] = true end
  for file in pairs(files) do
    local parts = vim.split(file, '/', { plain = true, trimempty = true })
    local suffix = parts[#parts] or file
    for count = 1, #parts do
      suffix = table.concat(parts, '/', #parts - count + 1)
      local unique = true
      for other in pairs(files) do
        if other ~= file and (other == suffix or other:sub(-#suffix - 1) == '/' .. suffix) then
          unique = false
          break
        end
      end
      if unique then break end
    end
    result[file] = suffix
  end
  return result
end

function M.build(record, width, preview, inline_notes)
  width = math.max(1, width)
  local skipped = 0
  for _, mark in ipairs(record.marks) do if mark.skipped then skipped = skipped + 1 end end
  local hidden = record.hide_skipped and skipped or 0
  local active_hidden = record.index and record.hide_skipped and record.marks[record.index]
    and record.marks[record.index].skipped
  local header = ('%d marks · %d skipped · %d hidden%s'):format(
    #record.marks, skipped, hidden, active_hidden and ' [active hidden]' or '')
  local view = {
    lines = { header, '<CR> jump  c capture  n note  s skip  H hide  K/J move  dd remove  u undo  q close' },
    row_to_index = {}, index_to_row = {}, ranges = {}, spans = {},
  }
  local function span(row, first, last, group)
    if last > first then
      view.spans[#view.spans + 1] = { row = row, first = first, last = last, group = group }
    end
  end
  span(1, 0, #header, 'StringerHeaderInfo')
  for first, digits in header:gmatch('()(%d+)') do
    -- Header counts are ASCII; span coordinates are UTF-8 byte offsets.
    span(1, first - 1, first - 1 + #digits, 'StringerHeaderCount')
  end
  local hidden_at = header:find('[active hidden]', 1, true)
  if hidden_at then span(1, hidden_at - 1, #header, 'StringerUncaptured') end
  span(2, 0, #view.lines[2], 'StringerHelp')
  local suffixes = M.suffixes(record.marks)
  local function add(index, line)
    view.lines[#view.lines + 1] = line
    view.row_to_index[#view.lines] = index
  end
  for i, mark in ipairs(record.marks) do
    if not (record.hide_skipped and mark.skipped) then
      local row = #view.lines + 1
      view.index_to_row[i] = row
      local text, badge = preview(mark)
      local parts = { { '↓ ', 'StringerEntryArrow' }, { tostring(i) .. ' ', 'StringerMarkNumber' } }
      local badge_groups = { changed = 'StringerChanged', missing = 'StringerMissing', unreadable = 'StringerUnreadable',
        uncaptured = 'StringerUncaptured', checking = 'StringerChecking' }
      for value in (badge or ''):gmatch('%[([^%]]+)%]') do
        parts[#parts + 1] = { '[' .. value .. '] ', badge_groups[value] or 'StringerChecking' }
      end
      if mark.skipped then parts[#parts + 1] = { '[skip] ', 'StringerSkipped' } end
      if mark.note then parts[#parts + 1] = { '[note] ', 'StringerNoteBadge' } end
      parts[#parts + 1] = { vim.fn.strtrans(text), mark.skipped and 'StringerSkipped' or 'StringerSource' }
      local full = ''
      for _, part in ipairs(parts) do full = full .. part[1] end
      local displayed = width == 1 and '↓' or M.fit(full, width)
      add(i, displayed)
      local limit = displayed == full and #displayed or math.max(0, #displayed - #'…')
      if width == 1 then limit = #'↓' end
      local column = 0
      for _, part in ipairs(parts) do
        span(row, column, math.min(column + #part[1], limit), part[2])
        column = column + #part[1]
      end
      local location = vim.fn.strtrans(suffixes[mark.file]) .. ':' .. tostring(mark.line)
      local indent = string.rep(' ', math.min(4, math.max(0, width - 1)))
      local location_text = indent .. M.fit(location, width - #indent, true)
      add(i, location_text)
      span(row + 1, #indent, #location_text, mark.skipped and 'StringerSkipped' or 'StringerLocation')
      local colon = location_text:find(':%d+$')
      if colon then span(row + 1, colon, #location_text, 'StringerLineNumber') end
      local range = { first = row, location = row + 1, last = row + 1 }
      if inline_notes and record.index == i and mark.note then
        local note_prefix = width >= 6 and '    │ ' or (width >= 2 and '│' or '')
        for _, line in ipairs(vim.split(mark.note, '\n', { plain = true })) do
          for _, chunk in ipairs(wrap(vim.fn.strtrans(line), math.max(1, width - vim.fn.strdisplaywidth(note_prefix)))) do
            add(i, note_prefix .. chunk)
            span(#view.lines, 0, #view.lines[#view.lines], 'StringerNote')
          end
        end
        range.last = #view.lines
      end
      view.ranges[i] = range
    end
  end
  if #view.lines == 2 then
    view.lines[3] = #record.marks == 0 and '(No marks yet. Use :Stringer add from a code file.)'
      or '(All marks hidden. Press H to reveal skipped marks.)'
  end
  return view
end

return M
