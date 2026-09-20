local state = require('stringer.state')
local uv = vim.uv or vim.loop
local M = {}

-- Only a focused code window influences proximity. Pane cursor movement must
-- not change the active mark. Keep the current entry when distances tie.
function M.nearest(record)
  local win = vim.api.nvim_get_current_win()
  if M.navigating or not M.eligible(win) then
    return record.index
  end
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local best, distance
  for i, mark in ipairs(record.marks) do
    if mark.file == file then
      local delta = math.abs(mark.line - line)
      if not distance or delta < distance or (delta == distance and i == record.index) then
        best, distance = i, delta
      end
    end
  end
  return best or record.index
end

function M.eligible(win)
  return win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ''
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
end

function M.remember()
  local win = vim.api.nvim_get_current_win()
  if M.eligible(win) then
    state.windows[vim.api.nvim_get_current_tabpage()] = win
  end
end

function M.window()
  local current = vim.api.nvim_get_current_win()
  if M.eligible(current) then
    return current
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local remembered = state.windows[tab]
  if M.eligible(remembered) and vim.api.nvim_win_get_tabpage(remembered) == tab then
    return remembered
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if M.eligible(win) then
      return win
    end
  end
  return nil, 'No code window in this tab; open a code window before navigating'
end

function M.capture()
  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local stat = uv.fs_stat(file)
  if vim.bo[buf].buftype ~= '' or file == '' or not stat or stat.type ~= 'file' then
    return nil, 'Marks require a normal, saved file buffer; save the file first'
  end
  return { file = vim.fs.normalize(file), line = vim.api.nvim_win_get_cursor(0)[1] }
end

function M.jump(record, index)
  local mark = record.marks[index]
  if not mark then
    return nil, 'No mark at that position'
  end
  local stat = uv.fs_stat(mark.file)
  if not stat or stat.type ~= 'file' then
    return nil, 'Target file is unavailable: ' .. mark.file
  end
  local win, err = M.window()
  if not win then
    return nil, err
  end
  M.navigating = true
  local ok, result = pcall(function()
    local buf = vim.fn.bufadd(mark.file)
    vim.fn.bufload(buf)
    if not vim.api.nvim_buf_is_loaded(buf) then
      error('Could not load ' .. mark.file, 0)
    end
    if mark.line > vim.api.nvim_buf_line_count(buf) then
      error(('Stale mark: %s has fewer than %d lines'):format(mark.file, mark.line), 0)
    end
    -- :buffer honors 'hidden' and modified-buffer safeguards, unlike forced
    -- buffer replacement. The argument is a buffer number, never a filename.
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_cmd({ cmd = 'buffer', args = { tostring(buf) } }, {})
      vim.api.nvim_win_set_cursor(win, { mark.line, 0 })
    end)
    vim.api.nvim_set_current_win(win)
  end)
  M.navigating = false
  if not ok then
    return nil, tostring(result)
  end
  record.index = index
  M.remember()
  return true
end

return M
