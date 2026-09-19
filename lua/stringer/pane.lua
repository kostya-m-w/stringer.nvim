local codec = require('stringer.codec')
local config = require('stringer.config')
local state = require('stringer.state')
local store = require('stringer.store')
local M = {
  buffers = {},
  windows = {},
  namespace = vim.api.nvim_create_namespace('stringer.active'),
  diagnostics = vim.api.nvim_create_namespace('stringer.diagnostics'),
}

local function notify(message)
  vim.notify('Stringer: ' .. message, vim.log.levels.ERROR)
end

function M.buffer(record)
  local buf = M.buffers[record.file]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
end

function M.dirty(record)
  local buf = record and M.buffer(record)
  return buf and vim.bo[buf].modified or false
end

function M.highlight(record)
  local buf = M.buffer(record)
  if not buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1)
  if state.active == record and record.index and not M.dirty(record) then
    vim.api.nvim_buf_set_extmark(buf, M.namespace, record.index, 0, {
      line_hl_group = 'StringerActive',
      priority = 110,
    })
  end
end

function M.refresh(record)
  local buf = M.buffer(record)
  if buf then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, codec.lines(record.text))
    vim.bo[buf].modified = false
    vim.diagnostic.reset(M.diagnostics, buf)
    M.highlight(record)
  end
end

function M.save(record)
  local buf = M.buffer(record)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marks, errors = codec.decode(lines)
  if not marks then
    local diagnostics = {}
    for _, err in ipairs(errors) do
      diagnostics[#diagnostics + 1] = {
        lnum = err.line - 1, col = 0, message = err.message,
        severity = vim.diagnostic.severity.ERROR, source = 'Stringer',
      }
    end
    vim.diagnostic.set(M.diagnostics, buf, diagnostics)
    return nil, codec.error_message(errors)
  end
  local text = codec.text(lines)
  local ok, err = store.write(record.file, text, record.text)
  if not ok then
    return nil, err
  end
  state.commit(record, marks, text)
  vim.bo[buf].modified = false
  vim.diagnostic.reset(M.diagnostics, buf)
  M.highlight(record)
  return true
end

local function prepare(record)
  local buf = M.buffer(record)
  if not buf then
    -- Reuse even a buffer opened manually by filename; never replace its draft.
    buf = vim.fn.bufnr(record.file)
    if buf ~= -1 and vim.bo[buf].modified then
      return nil, 'Codepath file has unsaved edits; save or discard them first'
    end
    if buf == -1 then
      buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, record.file)
    end
    M.buffers[record.file] = buf
  end
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'stringer'
  local group = vim.api.nvim_create_augroup('StringerPane' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group, buffer = buf,
    callback = function(args)
      if vim.fs.normalize(vim.fn.fnamemodify(args.file, ':p')) ~= record.file then
        error('Stringer: save to the original codepath file', 0)
      end
      local ok, err = M.save(record)
      if not ok then
        -- A thrown write error prevents :wq from closing an invalid draft.
        error('Stringer: ' .. err, 0)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group, buffer = buf,
    callback = function()
      local fresh, err = store.load(record.name)
      if not fresh then
        error('Stringer: ' .. err, 0)
      end
      state.commit(record, fresh.marks, fresh.text)
      M.refresh(record)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufModifiedSet', 'BufEnter' }, {
    group = group, buffer = buf,
    callback = function() M.highlight(record) end,
  })
  vim.keymap.set('n', '<CR>', function()
    if state.active ~= record then
      notify('Select this codepath with :Stringer open first')
    elseif M.dirty(record) then
      notify('Save or discard pane edits before jumping from a line')
    else
      require('stringer').jump(vim.api.nvim_win_get_cursor(0)[1] - 1)
    end
  end, { buffer = buf, silent = true, desc = 'Jump to Stringer mark' })
  vim.keymap.set('n', 'q', function()
    if M.dirty(record) then
      notify('Save or discard pane edits before closing')
      return
    end
    local ok, err = pcall(vim.cmd.close)
    if not ok then
      notify(tostring(err))
    end
  end, { buffer = buf, silent = true, desc = 'Close Stringer pane' })
  M.refresh(record)
  return buf
end

-- Called only after the caller has checked dirty buffers.
function M.activate(record)
  local buf, err = prepare(record)
  if not buf then
    return nil, err
  end
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
  local buf = M.buffer(record)
  if not buf then
    local err
    buf, err = prepare(record)
    if not buf then
      return nil, err
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      M.windows[tab] = win
      vim.api.nvim_set_current_win(win)
      M.highlight(record)
      return true
    end
  end
  local codewin = require('stringer.navigation').window()
  vim.api.nvim_cmd({ cmd = 'vsplit', mods = { split = 'botright' } }, {})
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, config.options.pane_width)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].winfixwidth = true
  -- Creating a split briefly focuses a duplicate code buffer. Do not let that
  -- transient window replace the user's actual last focused code window.
  state.windows[tab] = codewin
  M.windows[tab] = win
  M.highlight(record)
  return true
end

return M
