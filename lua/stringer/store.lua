local uv = vim.uv or vim.loop
local codec = require('stringer.codec')
local config = require('stringer.config')
local M = {}

function M.valid_name(name)
  return type(name) == 'string' and name:match('^[A-Za-z0-9_-]+$') ~= nil
end

function M.path(name)
  if not M.valid_name(name) then
    return nil, 'Path names may contain only letters, numbers, hyphens, and underscores'
  end
  return config.options.storage_dir .. '/' .. name .. '.stringer'
end

function M.read(file)
  local handle, err = io.open(file, 'rb')
  if not handle then
    return nil, err
  end
  local text, read_err = handle:read('*a')
  handle:close()
  return text, read_err
end

function M.list()
  local result = {}
  local scan, err, code = uv.fs_scandir(config.options.storage_dir)
  if not scan then
    if code == 'ENOENT' then
      return result
    end
    return nil, err
  end
  while true do
    local name, kind = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    local stem = name:match('^(.*)%.stringer$')
    if kind == 'file' and M.valid_name(stem) then
      result[#result + 1] = stem
    end
  end
  table.sort(result)
  return result
end

function M.load(name)
  local file, err = M.path(name)
  if not file then
    return nil, err
  end
  local text
  text, err = M.read(file)
  if not text then
    return nil, 'Cannot read codepath: ' .. tostring(err)
  end
  local marks, errors = codec.decode(codec.lines(text))
  if not marks then
    return nil, codec.error_message(errors)
  end
  return { name = name, file = file, text = text, marks = marks }
end

local function unchanged(file, expected)
  if expected == nil then
    local stat, err, code = uv.fs_lstat(file)
    if stat then
      return nil, 'Codepath already exists: ' .. file
    end
    if code ~= 'ENOENT' then
      return nil, err
    end
    return true
  end
  local current, err = M.read(file)
  if current == nil then
    return nil, 'Cannot check saved codepath: ' .. tostring(err)
  end
  if current ~= expected then
    return nil, 'Codepath changed externally; reload it before saving (copy draft edits first)'
  end
  return true
end

-- Compare bytes to the loaded snapshot, then replace with a same-directory temp
-- file. This detects external edits but is not a multi-process locking protocol.
function M.write(file, text, expected)
  local ok, err = pcall(vim.fn.mkdir, vim.fs.dirname(file), 'p')
  if not ok then
    return nil, 'Cannot create storage directory: ' .. tostring(err)
  end
  ok, err = unchanged(file, expected)
  if not ok then
    return nil, err
  end
  local fd, temp = uv.fs_mkstemp(file .. '.XXXXXX')
  if not fd then
    return nil, 'Cannot create temporary file: ' .. tostring(temp)
  end
  local offset = 0
  while offset < #text do
    local count
    count, err = uv.fs_write(fd, text:sub(offset + 1), offset)
    if not count or count == 0 then
      uv.fs_close(fd)
      uv.fs_unlink(temp)
      return nil, 'Cannot write codepath: ' .. tostring(err)
    end
    offset = offset + count
  end
  ok, err = uv.fs_close(fd)
  if ok then
    ok, err = unchanged(file, expected)
  end
  if ok then
    ok, err = uv.fs_rename(temp, file)
  end
  if not ok then
    uv.fs_unlink(temp)
    return nil, 'Cannot save codepath: ' .. tostring(err)
  end
  return true
end

function M.create(name)
  local file, err = M.path(name)
  if not file then
    return nil, err
  end
  local text = codec.text(codec.encode({}))
  local ok
  ok, err = M.write(file, text, nil)
  if not ok then
    return nil, err
  end
  return { name = name, file = file, text = text, marks = {} }
end

return M
