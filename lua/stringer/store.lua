local uv = vim.uv or vim.loop
local codec = require('stringer.codec')
local directories = require('stringer.directories')
local names = require('stringer.names')
local M = {}

M.valid_name = names.valid

function M.path(name, directory)
  if not M.valid_name(name) then
    return nil, names.error
  end
  return (directory or directories.current()) .. '/' .. name .. '.stringer'
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

function M.list(directory)
  local result = {}
  local scan, err, code = uv.fs_scandir(directory or directories.current())
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

function M.load(name, directory)
  local file, err = M.path(name, directory)
  if not file then
    return nil, err
  end
  return M.load_file(file)
end

function M.load_file(file)
  file = vim.fs.normalize(vim.fn.fnamemodify(file, ':p'))
  local name = vim.fs.basename(file):match('^(.*)%.stringer$')
  if not names.valid(name) then return nil, names.error end
  local text, err = M.read(file)
  if not text then
    return nil, 'Cannot read codepath: ' .. tostring(err)
  end
  local marks, errors = codec.decode(codec.lines(text))
  if not marks then
    return nil, codec.error_message(errors)
  end
  return { name = name, file = file, text = text, marks = marks }
end

local function same_file(a, b)
  return a and b and a.dev == b.dev and a.ino == b.ino
end

local function publish(temp, file)
  local ok, err, code = uv.fs_link(temp, file)
  if ok then return true end
  if code == 'EXDEV' or code == 'ENOTSUP' or code == 'EOPNOTSUPP' or code == 'EPERM' then
    -- Exclusive copy is a non-clobber fallback for filesystems without links.
    return uv.fs_copyfile(temp, file, { excl = true })
  end
  return nil, err
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
    return nil, 'Codepath changed externally; use :Stringer reload before changing it'
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
  ok, err = uv.fs_fsync(fd)
  local closed, close_err = uv.fs_close(fd)
  if ok and not closed then ok, err = nil, close_err end
  if ok then
    ok, err = unchanged(file, expected)
  end
  if ok then
    if expected == nil then ok, err = publish(temp, file)
    else ok, err = uv.fs_rename(temp, file) end
  end
  if not ok then
    uv.fs_unlink(temp)
    return nil, 'Cannot save codepath: ' .. tostring(err)
  end
  if expected == nil then uv.fs_unlink(temp) end
  return true
end

function M.create(name, marks, directory)
  local file, err = M.path(name, directory)
  if not file then
    return nil, err
  end
  marks = marks or {}
  local lines = codec.encode(marks)
  local valid, errors = codec.decode(lines)
  if not valid then return nil, codec.error_message(errors) end
  local text = codec.text(lines)
  local ok
  ok, err = M.write(file, text, nil)
  if not ok then
    return nil, err
  end
  return { name = name, file = file, text = text, marks = valid }
end

local function transfer(record, file)
  local ok, err = unchanged(record.file, record.text)
  if not ok then
    return nil, err
  end
  if file == record.file then
    return file
  end
  ok, err = unchanged(file, nil)
  if not ok then
    return nil, err
  end
  local original = uv.fs_lstat(record.file)
  if not original or original.type ~= 'file' then return nil, 'Move requires a regular codepath file' end
  local code
  ok, err, code = uv.fs_link(record.file, file)
  if not ok and (code == 'EXDEV' or code == 'ENOTSUP' or code == 'EOPNOTSUPP' or code == 'EPERM') then
    ok, err = M.write(file, record.text, nil)
  end
  if not ok then
    return nil, 'Cannot publish codepath destination: ' .. tostring(err)
  end
  local published = uv.fs_lstat(file)
  ok, err = unchanged(record.file, record.text)
  if ok and not same_file(original, uv.fs_lstat(record.file)) then ok, err = nil, 'Source file was replaced during move' end
  if ok then ok, err = unchanged(file, record.text) end
  if ok then ok, err = uv.fs_unlink(record.file) end
  if not ok then
    local removed, cleanup_err
    if same_file(published, uv.fs_lstat(file)) and M.read(file) == record.text then
      removed, cleanup_err = uv.fs_unlink(file)
    else cleanup_err = 'Destination changed; retained for manual reconciliation' end
    return nil, 'Move failed: ' .. tostring(err)
      .. (removed and '' or ('; source retained at %s; destination remains at %s: %s'):format(record.file, file, tostring(cleanup_err)))
  end
  return file
end

function M.rename(record, name)
  local file, err = M.path(name, vim.fs.dirname(record.file))
  if not file then return nil, err end
  return transfer(record, file)
end

function M.move(record, directory)
  local destination, err = directories.resolve(directory, true)
  if not destination then return nil, err end
  return transfer(record, destination .. '/' .. vim.fs.basename(record.file))
end

function M.copy(record, name, directory)
  local ok, err = unchanged(record.file, record.text)
  if not ok then return nil, err end
  return M.create(name, vim.deepcopy(record.marks), directory)
end

return M
