local config = require('stringer.config')
local state = require('stringer.state')
local M = {
  buffers = {},
  windows = {},
  namespace = vim.api.nvim_create_namespace('stringer.active'),
  first_mark_line = 3,
}

function M.buffer(record)
  local buf = M.buffers[record.file]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
end

function M.project_root()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  return vim.fs.root(cwd, '.git') or cwd
end

local function relative(file, directory)
  local prefix = directory:gsub('/+$', '') .. '/'
  if file:sub(1, #prefix) == prefix then
    return file:sub(#prefix + 1)
  end
end

function M.display_path(file, root)
  file = vim.fs.normalize(file)
  local project = relative(file, root or M.project_root())
  if project then
    return project
  end
  local home = relative(file, vim.fs.normalize(vim.fn.expand('~')))
  return home and '~/' .. home or file
end

function M.selected(record)
  if vim.api.nvim_get_current_buf() == M.buffer(record) then
    return vim.api.nvim_win_get_cursor(0)[1] - M.first_mark_line + 1
  end
  return record.index
end

function M.highlight(record)
  local buf = M.buffer(record)
  if not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  if state.active == record and record.index and record.marks[record.index] then
    vim.api.nvim_buf_set_extmark(buf, M.namespace, record.index + M.first_mark_line - 2, 0, {
      line_hl_group = 'StringerActive', sign_text = '>', sign_hl_group = 'StringerActive', priority = 110,
    })
  end
end

function M.refresh(record, selected)
  local buf = M.buffer(record)
  if not buf then
    return
  end
  local lines = {
    ('Stringer: %s (%d marks)'):format(record.name, #record.marks),
    '<CR> jump  dd remove  K/J move  u undo  r rename  R reload  q close',
  }
  local root = M.project_root()
  for i, mark in ipairs(record.marks) do
    lines[#lines + 1] = ('%d  %s:%d'):format(i, vim.fn.strtrans(M.display_path(mark.file, root)), mark.line)
  end
  if #record.marks == 0 then
    lines[#lines + 1] = '(No marks yet. Use :Stringer add from a code file.)'
  end
  -- Do not disturb pane cursors on ordinary redraws or proximity updates.
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    cursors[win] = vim.api.nvim_win_get_cursor(win)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  for win, cursor in pairs(cursors) do
    cursor[1] = math.min(cursor[1], #lines)
    if selected and win == vim.api.nvim_get_current_win() then
      cursor = { math.min(selected + M.first_mark_line - 1, #lines), 0 }
    end
    vim.api.nvim_win_set_cursor(win, cursor)
  end
  M.highlight(record)
end

function M.rekey(record, old_file)
  local buf = M.buffers[old_file]
  M.buffers[old_file] = nil
  M.buffers[record.file] = buf
end

local function prepare(record)
  local buf = M.buffer(record)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'stringer://' .. buf)
    M.buffers[record.file] = buf
  end
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'stringer'
  vim.bo[buf].undolevels = -1
  local mappings = {
    ['<CR>'] = { 'jump', 'Jump to mark' },
    dd = { 'remove', 'Remove mark' },
    K = { 'move_up', 'Move mark up' },
    J = { 'move_down', 'Move mark down' },
    u = { 'undo', 'Undo last mark change' },
    r = { 'rename', 'Rename codepath' },
    R = { 'reload', 'Reload codepath' },
  }
  for key, action in pairs(mappings) do
    local method = action[1]
    vim.keymap.set('n', key, function()
      if state.active ~= record then
        vim.notify('Stringer: select this codepath with :Stringer open first', vim.log.levels.ERROR)
        return
      end
      local api = require('stringer')
      if method == 'jump' then
        api.jump(M.selected(record))
      else
        api[method]()
      end
    end, { buffer = buf, silent = true, desc = action[2] })
  end
  vim.keymap.set('n', 'q', function()
    local ok, err = pcall(vim.cmd.close)
    if not ok then
      vim.notify('Stringer: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end, { buffer = buf, silent = true, desc = 'Close Stringer pane' })
  M.refresh(record)
  return buf
end

function M.activate(record)
  local buf = prepare(record)
  for tab, win in pairs(M.windows) do
    if vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'stringer' then
      vim.api.nvim_win_set_buf(win, buf)
    else
      M.windows[tab] = nil
    end
  end
  return true
end

function M.show(record)
  local buf = M.buffer(record) or prepare(record)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      M.windows[tab] = win
      vim.api.nvim_set_current_win(win)
      M.refresh(record)
      return true
    end
  end
  local codewin = require('stringer.navigation').window()
  vim.api.nvim_cmd({ cmd = 'vsplit', mods = { split = 'botright' } }, {})
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, config.options.pane_width)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'yes:1'
  vim.wo[win].wrap = false
  vim.wo[win].winfixwidth = true
  state.windows[tab] = codewin
  M.windows[tab] = win
  M.refresh(record)
  vim.api.nvim_win_set_cursor(win, { (record.index or 1) + M.first_mark_line - 1, 0 })
  return true
end

return M
