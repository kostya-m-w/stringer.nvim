local uv = vim.uv or vim.loop
local codec = require('stringer.codec')
local M = {}

local function readable(file)
  local stat = uv.fs_stat(file)
  return stat and stat.type == 'file' and uv.fs_access(file, 'R') or false
end

local function local_path(file, root)
  if file:match('^file://') then
    file = file:gsub('^file://localhost/', 'file:///')
    if not file:match('^file:///') then return nil, 'Nonlocal file URI' end
    file = file:sub(8):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  end
  if file:find('%z') or file:find('[<>]') then return nil, 'Not a local source path' end
  if not codec.absolute(file) and file:match('^[%a][%w+.-]*:') then return nil, 'Nonlocal or runtime-internal location' end
  return vim.fs.normalize(codec.absolute(file) and file or root .. '/' .. file)
end

-- Scan once per import, yielding regularly. Do not follow directory symlinks.
local function java_index(root, token, callback)
  local queue, cursor, index, scan, directory = { root }, 1, {}, nil, nil
  local function step()
    if token.cancelled then return end
    for _ = 1, 128 do
      if not scan then
        directory = queue[cursor]
        if not directory then callback(index); return end
        cursor = cursor + 1
        scan = uv.fs_scandir(directory)
      end
      if scan then
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
          scan = nil
        elseif kind == 'directory' and name ~= '.git' then
          queue[#queue + 1] = directory .. '/' .. name
        elseif kind == 'file' and name:match('%.java$') then
          index[name] = index[name] or {}
          index[name][#index[name] + 1] = directory .. '/' .. name
        end
      end
    end
    vim.schedule(step)
  end
  step()
end

function M.resolve(parsed, root, token, callback)
  local needs_index = false
  for _, frame in ipairs(parsed.frames) do
    if frame.format == 'java' and not frame.file:find('[/\\]') then needs_index = true end
  end
  local function finish(index)
    if token.cancelled then return end
    local marks, issues = {}, vim.deepcopy(parsed.issues)
    for _, frame in ipairs(parsed.frames) do
      local file, reason, candidates
      if frame.format == 'java' and not frame.file:find('[/\\]') then
        candidates = index[frame.file] or {}
        local package = (frame.class or ''):match('^(.*)%.[^.]+$')
        if package then
          local suffix = '/' .. package:gsub('%.', '/') .. '/' .. frame.file
          local narrowed = {}
          for _, candidate in ipairs(candidates) do
            if candidate:sub(-#suffix) == suffix then narrowed[#narrowed + 1] = candidate end
          end
          if #narrowed > 0 then candidates = narrowed end
        end
        table.sort(candidates)
        if #candidates == 1 then file = candidates[1]
        else reason = #candidates == 0 and 'No project-local Java source found' or 'Ambiguous Java source filename' end
      else
        file, reason = local_path(frame.file, root)
      end
      if file and not readable(file) then reason, file = 'Local source file is missing or unreadable', nil end
      if frame.line < 1 then reason, file = 'Invalid source line number', nil end
      if file then
        marks[#marks + 1] = { file = file, line = frame.line, frame = frame.raw }
      else
        issues[#issues + 1] = {
          source_line = frame.source_line, raw = frame.raw, reason = reason, candidates = candidates,
        }
      end
    end
    table.sort(issues, function(a, b) return a.source_line < b.source_line end)
    callback({ marks = marks, issues = issues, format = parsed.format })
  end
  if needs_index then java_index(root, token, finish) else finish({}) end
end

return M
