-- Adapters retain the original filename instead of letting quickfix expand a
-- Java basename against cwd. Input is data; none of it is evaluated as code.
local M = {}

local function clean(line)
  return vim.trim(line:gsub('\27%[[%d;]*[A-Za-z]', ''):gsub('\r$', ''))
end

local function ruby(line)
  local body = line:gsub('^from%s+', '')
  local file, number = body:match('^(.-):(%d+):in%s+')
  if not file then file, number = body:match('^(.-%.rb):(%d+):?') end
  if file then return { file = file, line = tonumber(number) } end
end

local function java(line)
  local method, file, number = line:match('^at%s+(.+)%(([^()]+%.java):(%d+)%)$')
  if not file then return end
  method = method:gsub('^.*/', '') -- Java module/classloader prefix
  local class = method:match('^(.*)%.[^.]+$') or ''
  return { file = file, line = tonumber(number), class = class }
end

local function javascript(line)
  local body = line:match('^at%s+(.+)')
  if not body then return end
  local location = body:match('%((.*)%)$') or body
  location = location:gsub('^async%s+', '')
  local file, number, column = location:match('^(.*):(%d+):(%d+)$')
  if file then return { file = file, line = tonumber(number), column = tonumber(column) } end
end

local adapters = { ruby = ruby, javascript = javascript, java = java }

function M.detect(lines)
  local found = {}
  for _, raw in ipairs(lines) do
    local line = clean(raw)
    if ruby(line) then found.ruby = true end
    if java(line) then found.java = true
    elseif javascript(line) then found.javascript = true end
  end
  local result = {}
  for _, format in ipairs({ 'ruby', 'javascript', 'java' }) do
    if found[format] then result[#result + 1] = format end
  end
  return result
end

function M.parse(lines, format)
  local parser = adapters[format]
  if not parser then return nil, 'Unsupported stacktrace format' end
  local frames, issues = {}, {}
  local interrupted = false
  for number, raw in ipairs(lines) do
    local line = clean(raw)
    if line:match('^Caused by:') or line:match('^Suppressed:') or line:match('^%.%.%. %d+ more')
      or line:find('most recent call last', 1, true) then
      return nil, 'Chained, elided, or outermost-first traces are not supported; use a single conventional stack'
    end
    local frame = parser(line)
    if frame then
      if interrupted then return nil, 'Multiple or interrupted stacks detected; import one coherent stack at a time' end
      frame.raw, frame.source_line, frame.format = line, number, format
      frames[#frames + 1] = frame
    elseif line:match('^at%s+') or line:match('^from%s+') then
      issues[#issues + 1] = { source_line = number, raw = line, reason = 'Frame has no supported local file/line location' }
    elseif #frames > 0 and line ~= '' then
      interrupted = true
    end
  end
  if #frames == 0 then return nil, 'No supported frames found in this buffer' end
  -- Conventional Ruby, V8, and JVM stacks print their deepest frame first.
  local ordered = {}
  for i = #frames, 1, -1 do ordered[#ordered + 1] = frames[i] end
  return { frames = ordered, issues = issues, format = format }
end

return M
