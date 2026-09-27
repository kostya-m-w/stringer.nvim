local uv = vim.uv or vim.loop
local M = { cache = {} }

local function result(status, message)
  return { status = status, message = message }
end

local function identity(file)
  local stat, err, code = uv.fs_stat(file)
  if not stat then
    if code == 'ENOENT' or code == 'ENOTDIR' then return 'missing', nil, result('missing', 'Source file is missing') end
    return 'error:' .. tostring(err), nil, result('unreadable', tostring(err))
  end
  if stat.type ~= 'file' then return 'nonfile', nil, result('unreadable', 'Source path is not a file') end
  local buf = vim.fn.bufnr(file)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
    return 'buffer:' .. buf .. ':' .. vim.api.nvim_buf_get_changedtick(buf), buf
  end
  return table.concat({ 'disk', stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec,
    stat.ctime.sec, stat.ctime.nsec }, ':')
end

local function utf8(text)
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local count, low, high = 0, 128, 191
    if byte < 128 then count = 0
    elseif byte >= 194 and byte <= 223 then count = 1
    elseif byte >= 224 and byte <= 239 then
      count = 2
      if byte == 224 then low = 160 elseif byte == 237 then high = 159 end
    elseif byte >= 240 and byte <= 244 then
      count = 3
      if byte == 240 then low = 144 elseif byte == 244 then high = 143 end
    else return false end
    for offset = 1, count do
      local next_byte = text:byte(i + offset)
      local minimum, maximum = offset == 1 and low or 128, offset == 1 and high or 191
      if not next_byte or next_byte < minimum or next_byte > maximum then return false end
    end
    i = i + count + 1
  end
  return true
end

function M.line_result(text)
  if text == nil then return result('missing', 'Stored source line is past EOF') end
  if text:find('[\r\n%z]') then return result('unreadable', 'Unsupported source encoding or line terminator') end
  if not utf8(text) then return result('unreadable', 'Source text is not valid UTF-8') end
  return { status = 'ok', text = text }
end

function M.invalidate(file)
  M.cache[vim.fs.normalize(file)] = nil
end

-- Loaded buffers complete synchronously. Disk reads yield between 64 KiB chunks.
-- Concurrent requests for one source revision share a read and its requested lines.
function M.read(file, numbers, callback, opts)
  file = vim.fs.normalize(file)
  local signature, buf, unavailable = identity(file)
  local entry = M.cache[file]
  if not entry or entry.signature ~= signature or (opts and opts.force) then
    entry = { signature = signature, values = {}, wanted = {}, waiters = {} }
    M.cache[file] = entry
  end
  local ready = true
  for _, line in ipairs(numbers) do
    entry.wanted[line] = true
    if not entry.values[line] then ready = false end
  end
  local function subset()
    local values = {}
    for _, line in ipairs(numbers) do values[line] = entry.values[line] end
    return values
  end
  if ready then callback(subset()); return end
  if unavailable or buf then
    local count = buf and vim.api.nvim_buf_line_count(buf) or 0
    for _, line in ipairs(numbers) do
      if unavailable then entry.values[line] = unavailable
      elseif line > count then entry.values[line] = M.line_result(nil)
      else entry.values[line] = M.line_result(vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]) end
    end
    callback(subset())
    return
  end
  entry.waiters[#entry.waiters + 1] = function() callback(subset()) end
  if entry.pending then return end
  entry.pending = true
  local fd, offset, tail, lines, first = nil, 0, '', {}, true
  local done = false
  local function finish(problem)
    if done then return end
    done = true
    if fd then uv.fs_close(fd); fd = nil end
    if M.cache[file] ~= entry or identity(file) ~= signature then
      problem = result('stale', 'Source changed during read; retry capture')
      if M.cache[file] == entry then M.cache[file] = nil end
    end
    for line in pairs(entry.wanted) do entry.values[line] = problem or M.line_result(lines[line]) end
    entry.pending = false
    local waiters = entry.waiters
    entry.waiters = {}
    for _, waiting in ipairs(waiters) do waiting() end
  end
  local function read_chunk()
    if M.cache[file] ~= entry then finish(result('stale', 'Source read superseded')); return end
    uv.fs_read(fd, 65536, offset, vim.schedule_wrap(function(err, data)
      if err then finish(result('unreadable', err)); return end
      if not data or data == '' then
        if tail ~= '' or #lines == 0 then lines[#lines + 1] = tail end
        finish()
        return
      end
      offset = offset + #data
      if first then
        first = false
        if data:sub(1, 2) == '\255\254' or data:sub(1, 2) == '\254\255' or data:find('%z') then
          finish(result('unreadable', 'Unsupported source encoding (load the file in Neovim to decode it)'))
          return
        end
        data = data:gsub('^\239\187\191', '')
      end
      tail = tail .. data
      local start = 1
      while true do
        local newline = tail:find('\n', start, true)
        if not newline then break end
        lines[#lines + 1] = tail:sub(start, newline - 1):gsub('\r$', '')
        start = newline + 1
      end
      tail = tail:sub(start)
      local maximum = 0
      for line in pairs(entry.wanted) do maximum = math.max(maximum, line) end
      if #lines >= maximum then finish() else read_chunk() end
    end))
  end
  uv.fs_open(file, 'r', 438, vim.schedule_wrap(function(err, opened)
    if err then finish(result('unreadable', err)); return end
    fd = opened
    read_chunk()
  end))
end

function M.read_marks(marks, callback, opts)
  local groups, remaining = {}, 0
  for _, mark in ipairs(marks) do
    if not groups[mark.file] then groups[mark.file] = {}; remaining = remaining + 1 end
    groups[mark.file][mark.line] = true
  end
  if remaining == 0 then callback({}); return end
  local all = {}
  for file, requested in pairs(groups) do
    M.read(file, vim.tbl_keys(requested), function(values)
      all[file] = values
      remaining = remaining - 1
      if remaining == 0 then callback(all) end
    end, opts)
  end
end

-- Rendering is pure with respect to files: it only consumes the cache.
function M.preview(mark)
  local entry = M.cache[vim.fs.normalize(mark.file)]
  local current = entry and entry.values[mark.line] or result('pending')
  local badge = mark.snapshot == nil and '[uncaptured] ' or ''
  if current.status == 'missing' then badge = badge .. '[missing] '
  elseif current.status == 'unreadable' then badge = badge .. '[unreadable] '
  elseif current.status ~= 'ok' then badge = badge .. '[checking] '
  elseif mark.snapshot ~= nil and mark.snapshot ~= current.text then badge = '[changed] ' end
  local text = mark.snapshot
  if text == nil then text = current.status == 'ok' and current.text or '(source unavailable)' end
  text = text:gsub('^%s+', '')
  if text == '' then text = '(blank line)' end
  return text, badge
end

return M
