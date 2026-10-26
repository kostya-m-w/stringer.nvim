local config = require('stringer.config')
local M = { entries = {}, originals = {}, namespace = vim.api.nvim_create_namespace('stringer.footer'), adjusting = false }

function M.render(width, hidden)
  width = math.max(1, width)
  if width < 6 then return { text = '?', spans = { { first = 0, last = 1, key = true } } } end
  local hints = { { '?', 'help' } }
  local function text(items)
    local parts = {}
    for _, item in ipairs(items) do parts[#parts + 1] = item[1] .. ' ' .. item[2] end
    return table.concat(parts, ' · ')
  end
  for _, hint in ipairs({ { 'Enter', 'jump' }, { 'n', 'note' }, { 'c', 'capture' }, { 's', 'skip' },
    { 'H', hidden and 'show skipped' or 'hide skipped' }, { 'q', 'close' } }) do
    table.insert(hints, #hints, hint)
    if vim.fn.strdisplaywidth(text(hints)) > width then table.remove(hints, #hints - 1) end
  end
  local result = { text = text(hints), spans = {} }
  local column = 0
  for i, hint in ipairs(hints) do
    result.spans[#result.spans + 1] = { first = column, last = column + #hint[1], key = true }
    column = column + #hint[1] + 1 + #hint[2]
    if i < #hints then column = column + #' · ' end
  end
  return result
end

function M.native(win)
  if vim.o.laststatus == 2 then return true end
  if vim.o.laststatus ~= 1 then return false end
  local count = 0
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if vim.api.nvim_win_get_config(other).relative == '' then count = count + 1 end
  end
  return count > 1
end

function M.needs_padding(buf)
  if not config.options.footer then return false end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_config(win).relative == '' and not M.native(win) then return true end
  end
  return false
end

local function close_float(entry)
  if entry.float and vim.api.nvim_win_is_valid(entry.float) then vim.api.nvim_win_close(entry.float, true) end
  entry.float = nil
end

function M.prepare(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local entry = M.entries[win]
    if entry and entry.float and entry.options then
      local info = vim.fn.getwininfo(win)[1]
      if M.native(win) or entry.options.row ~= info.height - 1 or entry.options.width ~= info.width then
        close_float(entry)
      end
    end
  end
end

function M.detach(win)
  local entry = M.entries[win]
  if not entry then return end
  M.entries[win] = nil
  close_float(entry)
  if vim.api.nvim_win_is_valid(win) then
    if vim.wo[win].statusline == entry.statusline then vim.wo[win].statusline = entry.original_statusline end
  end
end

function M.sweep()
  for win, entry in pairs(M.entries) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= entry.parent_buf then M.detach(win) end
  end
end

function M.restore_inherited(win)
  if not vim.api.nvim_win_is_valid(win) or vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'stringer' then return end
  local original = M.originals[vim.wo[win].statusline]
  if original ~= nil then vim.wo[win].statusline = original end
end

-- In fallback mode the last screen row is chrome. The unowned EOF padding row
-- makes the final mark/note reachable above it, and cursor motion skips padding.
function M.ensure_cursor(win)
  local entry = M.entries[win]
  if M.adjusting or not entry or vim.api.nvim_get_current_win() ~= win then return end
  -- A statusline-mode change resizes the parent before its queued footer
  -- refresh. Do not move the cursor against stale float geometry (0.10).
  local info = vim.fn.getwininfo(win)[1]
  if entry.float and entry.options and (entry.options.row ~= info.height - 1
    or entry.options.width ~= info.width) then return end
  M.adjusting = true
  local ok, err = pcall(function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    if cursor[1] > entry.last_line then
      cursor = { entry.last_line, 0 }
      vim.api.nvim_win_set_cursor(win, cursor)
    end
    if not entry.float or not vim.api.nvim_win_is_valid(entry.float) then return end
    local height = vim.fn.getwininfo(win)[1].height
    local view = vim.fn.winsaveview()
    if cursor[1] >= view.topline + math.max(1, height - 1) then
      view.topline = math.max(1, cursor[1] - math.max(1, height - 1) + 1)
      vim.fn.winrestview(view)
    end
  end)
  M.adjusting = false
  if not ok then error(err) end
end

function M.refresh(record, buf, last_line)
  M.sweep()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_config(win).relative == '' then
      if not config.options.footer then M.detach(win)
      else
        local entry = M.entries[win]
        if not entry then
          local original = vim.wo[win].statusline
          entry = { original_statusline = M.originals[original] or original, parent_buf = buf }
          M.entries[win] = entry
        end
        entry.last_line = last_line
        local width = vim.api.nvim_win_get_width(win)
        local rendered = M.render(width, record.hide_skipped)
        if M.native(win) then
          close_float(entry)
          local statusline, column = '%#StringerFooter#', 0
          for _, span in ipairs(rendered.spans) do
            statusline = statusline .. rendered.text:sub(column + 1, span.first):gsub('%%', '%%%%')
              .. '%#StringerFooterKey#' .. rendered.text:sub(span.first + 1, span.last):gsub('%%', '%%%%')
              .. '%#StringerFooter#'
            column = span.last
          end
          -- Zero-width highlight switches identify the owner without executing
          -- a statusline expression during redraw on older Neovim versions.
          entry.statusline = statusline .. rendered.text:sub(column + 1):gsub('%%', '%%%%')
            .. ('%%#StringerFooterOwner%d#%%#StringerFooter#'):format(win) .. '%='
          M.originals[entry.statusline] = entry.original_statusline
          vim.wo[win].statusline = entry.statusline
        else
          if vim.wo[win].statusline == entry.statusline then vim.wo[win].statusline = entry.original_statusline end
          entry.statusline = nil
          if not entry.buf or not vim.api.nvim_buf_is_valid(entry.buf) then
            entry.buf = vim.api.nvim_create_buf(false, true)
            vim.bo[entry.buf].bufhidden = 'wipe'
            vim.bo[entry.buf].filetype = 'stringer-footer'
          end
          if vim.api.nvim_buf_get_lines(entry.buf, 0, 1, false)[1] ~= rendered.text then
            vim.bo[entry.buf].modifiable = true
            vim.api.nvim_buf_set_lines(entry.buf, 0, -1, false, { rendered.text })
            vim.bo[entry.buf].modifiable = false
            vim.bo[entry.buf].modified = false
          end
          vim.api.nvim_buf_clear_namespace(entry.buf, M.namespace, 0, -1)
          for _, span in ipairs(rendered.spans) do
            vim.api.nvim_buf_set_extmark(entry.buf, M.namespace, 0, span.first,
              { end_col = span.last, hl_group = 'StringerFooterKey' })
          end
          local options = { relative = 'win', win = win, row = vim.fn.getwininfo(win)[1].height - 1, col = 0,
            width = width, height = 1, focusable = false, style = 'minimal', zindex = 40, noautocmd = true }
          if not entry.float or not vim.api.nvim_win_is_valid(entry.float) then
            entry.float = vim.api.nvim_win_call(win, function() return vim.api.nvim_open_win(entry.buf, false, options) end)
          end
          entry.options = options
          vim.wo[entry.float].winhighlight = 'Normal:StringerFooter,NormalNC:StringerFooter'
        end
        M.ensure_cursor(win)
      end
    end
  end
end

return M
