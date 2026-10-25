local uv = vim.uv or vim.loop
local M = {}

function M.resolve(path, create)
  if type(path) ~= 'string' or path == '' or path:find('%c') then return nil, 'Expected a nonempty directory path' end
  if path == '~' then path = uv.os_homedir()
  elseif path:sub(1, 2) == '~/' then path = uv.os_homedir() .. path:sub(2) end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if create then
    local ok, err = pcall(vim.fn.mkdir, path, 'p')
    if not ok then return nil, 'Cannot create storage directory: ' .. tostring(err) end
  end
  local stat, err, code = uv.fs_stat(path)
  if stat and stat.type ~= 'directory' then return nil, 'Storage location is not a directory' end
  if not stat and (create or code ~= 'ENOENT') then return nil, tostring(err) end
  if stat then return vim.fs.normalize(uv.fs_realpath(path) or path) end
  -- Canonicalize an existing parent even when the final directory is new.
  local parent = vim.fs.dirname(path)
  if parent ~= path then
    local resolved = M.resolve(parent, false)
    if resolved then return resolved .. '/' .. vim.fs.basename(path) end
  end
  return path
end

function M.current()
  if not M.selected then M.selected = assert(M.resolve(require('stringer.config').options.storage_dir, false)) end
  return M.selected
end

function M.setup(opts)
  if not M.selected or (opts and opts.storage_dir ~= nil) then
    M.selected = assert(M.resolve(require('stringer.config').options.storage_dir, false))
  end
end

function M.select(path)
  local directory, err = M.resolve(path, true)
  if not directory then return nil, err end
  M.selected = directory
  return directory
end

return M
