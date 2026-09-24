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

function M.build(record, width, title, inline_notes)
  width = math.max(1, width)
  local skipped = 0
  for _, mark in ipairs(record.marks) do if mark.skipped then skipped = skipped + 1 end end
  local hidden = record.hide_skipped and skipped or 0
  local active_hidden = record.index and record.hide_skipped and record.marks[record.index]
    and record.marks[record.index].skipped
  local header = ('Stringer: %s (%d marks, %d skipped, %d hidden)%s'):format(
    record.name, #record.marks, skipped, hidden, active_hidden and ' [active hidden]' or '')
  local view = {
    lines = { header, '<CR> jump  n note  s skip  H hide  K/J move  dd remove  u undo  q close' },
    row_to_index = {}, index_to_row = {}, ranges = {},
  }
  local suffixes = M.suffixes(record.marks)
  local function add(index, line)
    view.lines[#view.lines + 1] = line
    view.row_to_index[#view.lines] = index
  end
  for i, mark in ipairs(record.marks) do
    if not (record.hide_skipped and mark.skipped) then
      local row = #view.lines + 1
      view.index_to_row[i] = row
      local prefix = i .. ' ' .. (mark.skipped and '[skip] ' or '') .. (mark.note and '[note] ' or '')
      local name = vim.fn.strtrans(title(mark))
      add(i, M.fit(prefix .. name, width))
      local location = vim.fn.strtrans(suffixes[mark.file]) .. ':' .. tostring(mark.line)
      local indent = string.rep(' ', math.min(3, math.max(0, width - 1)))
      add(i, indent .. M.fit(location, width - #indent, true))
      local range = { first = row, location = row + 1, last = row + 1 }
      if inline_notes and record.index == i and mark.note then
        local note_prefix = width >= 5 and '   │ ' or (width >= 2 and '│' or '')
        for _, line in ipairs(vim.split(mark.note, '\n', { plain = true })) do
          for _, chunk in ipairs(wrap(vim.fn.strtrans(line), math.max(1, width - vim.fn.strdisplaywidth(note_prefix)))) do
            add(i, note_prefix .. chunk)
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
