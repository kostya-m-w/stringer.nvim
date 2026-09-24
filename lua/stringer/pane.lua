local config = require('stringer.config')
local state = require('stringer.state')
local layout = require('stringer.layout')
local labels = require('stringer.labels')
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
    return (record.row_to_index or {})[vim.api.nvim_win_get_cursor(0)[1]] or 0
  end
  return record.index
end

function M.highlight(record)
  local buf = M.buffer(record)
  if not buf or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  for index, range in pairs(record.ranges or {}) do
    for row = range.first, range.last do
      local group = row > range.location and 'StringerNote'
        or (record.marks[index].skipped and 'StringerSkipped' or nil)
      if group then vim.api.nvim_buf_set_extmark(buf, M.namespace, row - 1, 0, { line_hl_group = group }) end
    end
  end
  if state.active == record and record.index and record.marks[record.index] then
    local range = (record.ranges or {})[record.index]
    if range then
      for row = range.first, range.location do
        vim.api.nvim_buf_set_extmark(buf, M.namespace, row - 1, 0, {
          line_hl_group = 'StringerActive', sign_text = row == range.first and '>' or nil,
          sign_hl_group = 'StringerActive', priority = 110,
        })
      end
    end
  end
end

function M.width(record)
  local buf, width = M.buffer(record), nil
  for _, win in ipairs(buf and vim.fn.win_findbuf(buf) or {}) do
    local info = vim.fn.getwininfo(win)[1]
    local available = math.max(1, vim.api.nvim_win_get_width(win) - (info and info.textoff or 0))
    width = width and math.min(width, available) or available
  end
  return width or math.max(1, config.options.pane_width - 2)
end

function M.refresh(record, selected)
  local buf = M.buffer(record)
  if not buf then
    return
  end
  local previous_rows = record.row_to_index or {}
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local cursor = vim.api.nvim_win_get_cursor(win)
    local index = previous_rows[cursor[1]]
    local range = index and (record.ranges or {})[index]
    cursors[win] = { row = cursor[1], index = index, offset = range and cursor[1] - range.first or 0 }
  end
  local view = layout.build(record, M.width(record), labels.title, config.options.inline_notes and state.active == record)
  local lines = view.lines
  record.row_to_index, record.index_to_row, record.ranges = view.row_to_index, view.index_to_row, view.ranges
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  for win, cursor in pairs(cursors) do
    local index = (win == vim.api.nvim_get_current_win() and selected) or cursor.index
    local row = index and record.index_to_row[index]
    if index and not row then
      for i = index, #record.marks do
        if record.index_to_row[i] then row = record.index_to_row[i]; break end
      end
      if not row then
        for i = math.min(index, #record.marks), 1, -1 do
          if record.index_to_row[i] then row = record.index_to_row[i]; break end
        end
      end
    end
    local owning = row and record.row_to_index[row]
    local range = owning and record.ranges[owning]
    if range and not (selected and win == vim.api.nvim_get_current_win()) then
      row = math.min(row + cursor.offset, range.last)
    end
    vim.api.nvim_win_set_cursor(win, { row or math.min(cursor.row, #lines), 0 })
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
    s = { 'skip', 'Toggle skipped mark' },
    H = { 'hide_skipped', 'Hide or reveal skipped marks' },
    n = { 'note', 'Edit mark note' },
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
  vim.api.nvim_win_set_cursor(win, { record.index_to_row[record.index or 1] or M.first_mark_line, 0 })
  return true
end

return M
