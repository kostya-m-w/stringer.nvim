local uv = vim.uv or vim.loop
local M = {}

function M.valid_commit(value)
  return type(value) == 'string' and (#value == 40 or #value == 64) and value:match('^[0-9a-fA-F]+$') ~= nil
end

function M.cancel(token)
  if not token then return end
  token.cancelled = true
  for process in pairs(token.processes or {}) do pcall(process.kill, process, 15) end
end

local function possible_repository(directory)
  if vim.env.GIT_DIR or vim.env.GIT_WORK_TREE then return true end
  -- Fast negative result for ordinary files outside repositories. Git remains
  -- authoritative when a .git directory/file (including a worktree) is found.
  while directory do
    if uv.fs_stat(directory .. '/.git') then return true end
    local parent = vim.fs.dirname(directory)
    if parent == directory then break end
    directory = parent
  end
  return false
end

local function run(directory, args, token, callback)
  if token.cancelled then return end
  local command = { 'git', '-C', directory }
  vim.list_extend(command, args)
  token.processes = token.processes or {}
  local process
  local ok, err = pcall(function()
    process = vim.system(command, { text = true, timeout = 2000, env = { GIT_OPTIONAL_LOCKS = '0' } },
      vim.schedule_wrap(function(result)
        token.processes[process] = nil
        if not token.cancelled then callback(result) end
      end))
    token.processes[process] = true
  end)
  if not ok then callback({ code = -1, stderr = tostring(err), stdout = '' }) end
end

local function pool(items, token, worker, complete)
  local cursor, active, finished = 1, 0, 0
  if #items == 0 then complete(); return end
  local pump
  pump = function()
    if token.cancelled then return end
    while active < 4 and cursor <= #items do
      local item = items[cursor]
      cursor, active = cursor + 1, active + 1
      worker(item, function()
        active, finished = active - 1, finished + 1
        if finished == #items then complete() else pump() end
      end)
    end
  end
  pump()
end

function M.enrich(marks, token, callback)
  if token.cancelled then return end
  if vim.fn.executable('git') == 0 then callback(marks, {}); return end
  local directories, grouped, roots, warnings = {}, {}, {}, {}
  for _, mark in ipairs(marks) do
    local directory = vim.fs.dirname(mark.file)
    if not grouped[directory] then
      grouped[directory] = {}
      if possible_repository(directory) then directories[#directories + 1] = directory end
    end
    grouped[directory][#grouped[directory] + 1] = mark
  end
  pool(directories, token, function(directory, done)
    run(directory, { 'rev-parse', '--show-toplevel' }, token, function(result)
      if result.code == 0 then
        local root = vim.fs.normalize((result.stdout:gsub('\r?\n$', '')))
        roots[root] = roots[root] or {}
        vim.list_extend(roots[root], grouped[directory])
      elseif not (result.stderr or ''):find('not a git repository', 1, true) then
        warnings[#warnings + 1] = 'Git provenance unavailable for ' .. directory .. ': ' .. vim.trim(result.stderr or '')
      end
      done()
    end)
  end, function()
    pool(vim.tbl_keys(roots), token, function(root, done)
      local attempts = 0
      local query
      query = function()
        attempts = attempts + 1
        run(root, { 'rev-parse', '--verify', 'HEAD^{commit}' }, token, function(first)
          local sha = (first.stdout or ''):gsub('%s+$', '')
          if first.code ~= 0 or not M.valid_commit(sha) then
            -- Unborn HEAD is an expected absence, not a failed mark capture.
            if first.code ~= 128 then warnings[#warnings + 1] = 'Git HEAD unavailable for ' .. root end
            done(); return
          end
          run(root, { 'rev-parse', '--verify', 'HEAD^{commit}' }, token, function(second)
            if second.code ~= 0 or (second.stdout or ''):gsub('%s+$', '') ~= sha then
              if attempts < 2 then query(); return end
              warnings[#warnings + 1] = 'Git HEAD changed during capture for ' .. root
            else
              for _, mark in ipairs(roots[root]) do
                local file = vim.fs.normalize(mark.file)
                if file:sub(1, #root + 1) ~= root .. '/' then file = vim.fs.normalize(uv.fs_realpath(file) or file) end
                if file:sub(1, #root + 1) == root .. '/' then
                  mark.git = { commit = sha:lower(), path = file:sub(#root + 2) }
                end
              end
            end
            done()
          end)
        end)
      end
      query()
    end, function() if not token.cancelled then callback(marks, warnings) end end)
  end)
end

return M
