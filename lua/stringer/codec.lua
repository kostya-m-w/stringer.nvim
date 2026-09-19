local M = {}

function M.absolute(path)
  return type(path) == 'string'
    and (path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil or path:match('^\\\\') ~= nil)
end

local function keys_match(value, keys)
  if type(value) ~= 'table' then
    return false
  end
  for key in pairs(value) do
    if not keys[key] then
      return false
    end
  end
  return true
end

function M.decode(lines)
  local marks, errors = {}, {}
  local function problem(line, message)
    errors[#errors + 1] = { line = line, message = message }
  end
  if #lines == 0 then
    return nil, { { line = 1, message = 'Missing Stringer header' } }
  end
  for i, line in ipairs(lines) do
    local ok, value = pcall(vim.json.decode, line)
    if not ok then
      problem(i, 'Invalid JSON: ' .. tostring(value))
    elseif i == 1 then
      if not keys_match(value, { type = true, format_version = true, mark_version = true })
        or value.type ~= 'stringer' then
        problem(i, 'Expected a Stringer header')
      elseif value.format_version ~= 1 or value.mark_version ~= 1 then
        problem(i, 'Unsupported version; expected format_version=1 and mark_version=1')
      end
    elseif not keys_match(value, { file = true, line = true })
      or not M.absolute(value.file) or value.file:find('%z')
      or type(value.line) ~= 'number' or value.line < 1
      or value.line == math.huge or value.line % 1 ~= 0 then
      problem(i, 'Expected an absolute file path and a positive integer line number')
    else
      marks[#marks + 1] = { file = vim.fs.normalize(value.file), line = value.line }
    end
  end
  if #errors > 0 then
    return nil, errors
  end
  return marks
end

function M.encode(marks)
  local lines = { '{"type":"stringer","format_version":1,"mark_version":1}' }
  for _, mark in ipairs(marks) do
    lines[#lines + 1] = '{"file":' .. vim.json.encode(mark.file) .. ',"line":' .. tostring(mark.line) .. '}'
  end
  return lines
end

function M.lines(text)
  -- Remove only the final line terminator: an extra blank record is invalid.
  text = text:gsub('\n$', '')
  local lines = vim.split(text, '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub('\r$', '')
  end
  return lines
end

function M.text(lines)
  return table.concat(lines, '\n') .. '\n'
end

function M.error_message(errors)
  local messages = {}
  for _, err in ipairs(errors) do
    messages[#messages + 1] = ('line %d: %s'):format(err.line, err.message)
  end
  return table.concat(messages, '\n')
end

return M
