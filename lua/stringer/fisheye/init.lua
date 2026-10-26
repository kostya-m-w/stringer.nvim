local state = require('stringer.state')
local config = require('stringer.config')
local pane = require('stringer.pane')
local fs = require('stringer.fisheye.state')
local plan = require('stringer.fisheye.plan')
local windows = require('stringer.fisheye.windows')
local M = {}

local function notify(err) vim.notify('Stringer fish-eye: ' .. tostring(err), vim.log.levels.ERROR) end
local function valid(win) return win and vim.api.nvim_win_is_valid(win) end
local function screen_key(view)
  return table.concat({ vim.o.columns, vim.o.lines,
    valid(view.path_win) and vim.api.nvim_win_get_width(view.path_win) or 0,
    valid(view.path_win) and vim.api.nvim_win_get_height(view.path_win) or 0 }, ':')
end

function M.exists()
  return fs.view and vim.api.nvim_tabpage_is_valid(fs.view.tab) or false
end

function M.in_tab()
  return M.exists() and vim.api.nvim_get_current_tabpage() == fs.view.tab
end

function M.configure(opts)
  local defaults = config.options
  fs.settings = fs.settings or { previous = defaults.fisheye_previous, following = defaults.fisheye_next,
    notes = defaults.fisheye_notes }
  opts = opts or {}
  if opts.fisheye_previous ~= nil then fs.settings.previous = defaults.fisheye_previous end
  if opts.fisheye_next ~= nil then fs.settings.following = defaults.fisheye_next end
  if opts.fisheye_notes ~= nil then fs.settings.notes = defaults.fisheye_notes end
end

local function guarded(fn)
  local previous = fs.busy
  fs.busy = true
  local ok, value, err = xpcall(fn, debug.traceback)
  fs.busy = previous
  if not ok then return nil, value end
  return value, err
end

local function anchor(record, marks, index)
  if index and marks[index] then return index end
  local view = fs.view
  if view and view.record == record and view.anchor then
    local start = math.min(view.anchor, #marks)
    for i = start, #marks do if not marks[i].skipped then return i end end
    local just_skipped = view.count == #marks and marks[view.anchor] and marks[view.anchor].skipped
      and view.anchor_mark and not view.anchor_mark.skipped
    if just_skipped then
      for i = 1, #marks do if not marks[i].skipped then return i end end
    end
    for i = start - 1, 1, -1 do if not marks[i].skipped then return i end end
  end
  return plan.anchor(marks)
end

local function prepare(record, marks, index)
  M.configure()
  index = anchor(record, marks, index)
  local height = valid(fs.view.path_win) and vim.api.nvim_win_get_height(fs.view.path_win)
    or math.max(1, vim.o.lines - vim.o.cmdheight - 3)
  local all = plan.neighbors(marks, index, fs.settings.previous, fs.settings.following)
  local descriptors = plan.fit(all, height, vim.o.winminheight)
  local targets = windows.targets({ marks = marks }, descriptors)
  return targets, index, #all > #descriptors
end

function M.preflight(record, marks, index)
  if not M.in_tab() or fs.busy then return true end
  return guarded(function()
    local targets = prepare(record, marks, index)
    return windows.preflight(fs.view, targets)
  end)
end

local function refresh_presentation(record)
  require('stringer.presentation').refresh(record)
end

function M.rebuild(record, index, options)
  if not M.in_tab() then return nil, 'Fish-eye tab is not active' end
  if fs.busy then return true end
  options = options or {}
  local view = fs.view
  return guarded(function()
    local original_focus = vim.api.nvim_get_current_win()
    if not valid(view.path_win) then
      pane.show(record)
      view.path_win = vim.api.nvim_get_current_win()
      if valid(original_focus) then vim.api.nvim_set_current_win(original_focus) end
    end
    local targets, selected, clipped = prepare(record, record.marks, index)
    local ok, err = windows.preflight(view, targets)
    if not ok then return nil, err end
    local old_rows, old_main = view.rows, view.main
    local old_main_view = valid(old_main) and vim.api.nvim_win_call(old_main, vim.fn.winsaveview)
    local target_mark = selected and record.marks[selected]
    options = vim.tbl_extend('force', options, { preserve = options.preserve and view.record == record
      and target_mark and view.anchor_mark and target_mark.file == view.anchor_mark.file
      and target_mark.line == view.anchor_mark.line or false })
    ok, err = windows.render(view, targets, fs.settings, options)
    if not ok then
      -- Recover the last displayed neighborhood after a partial API failure.
      local recovery = {}
      for _, old in ipairs(old_rows or {}) do
        local row = { index = old.index, distance = old.distance, mark = old.mark }
        row.buf, row.problem = windows.resolve(row.mark)
        recovery[#recovery + 1] = row
      end
      if #recovery > 0 then
        local recovered, restored = pcall(windows.render, view, recovery, fs.settings, { preserve = true, keep_win = old_main })
        if recovered and restored and old_main_view and valid(view.main) then
          pcall(vim.api.nvim_win_call, view.main, function() vim.fn.winrestview(old_main_view) end)
        end
      end
      return nil, err
    end
    view.record, view.anchor, view.count = record, selected, #record.marks
    view.anchor_mark = selected and vim.deepcopy(record.marks[selected]) or nil
    view.revision, view.dirty, view.clipped = record.revision or 0, false, clipped
    view.screen = screen_key(view)
    record.index = selected
    state.windows[view.tab] = view.main
    refresh_presentation(record)
    return true
  end)
end

function M.jump(record, index, keep_win)
  if not record.marks[index] then return nil, 'No mark at that position' end
  return M.rebuild(record, index, { focus = true, keep_win = keep_win })
end

function M.forget()
  local view = fs.view
  fs.view, fs.pending = nil, false
  if not view then return end
  for _, row in ipairs(view.rows or {}) do windows.clear_match(row) end
  state.windows[view.tab] = nil
  windows.cleanup_buffers(view)
end

function M.detach(reason)
  local view = fs.view
  if not view then return end
  for _, row in ipairs(view.rows or {}) do
    if valid(row.win) then vim.wo[row.win].winbar = ''; vim.wo[row.win].winfixheight = false end
  end
  M.forget()
  notify(reason .. '; fish-eye management stopped, windows and edits retained')
end

function M.open()
  local record = state.active
  if not record then return nil, 'Select a codepath before opening fish-eye' end
  M.configure()
  if M.exists() then
    guarded(function() vim.api.nvim_set_current_tabpage(fs.view.tab); return true end)
    return M.rebuild(record, record.index, { focus = true })
  end
  if vim.o.columns < 45 or vim.o.lines < 12 then return nil, 'Editor is too small for fish-eye and the path pane' end
  M.forget()
  local origin_tab, origin_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  local code_win = require('stringer.navigation').window() or origin_win
  local code_options = {}
  for _, key in ipairs({ 'number', 'relativenumber', 'wrap', 'cursorline', 'signcolumn', 'statusline' }) do code_options[key] = vim.wo[code_win][key] end
  local ok, err = guarded(function()
    vim.cmd('tabnew')
    local tab, main, seed = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.bo[seed].buftype = 'nofile'
    vim.bo[seed].bufhidden = 'hide'
    fs.view = { tab = tab, origin_tab = origin_tab, origin_win = origin_win, main = main,
      rows = { { win = main, buf = seed, distance = 0 } }, roles = {}, owned_buffers = { [seed] = true },
      code_options = code_options }
    pane.show(record)
    fs.view.path_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(main)
    return true
  end)
  if ok then ok, err = M.rebuild(record, record.index, { focus = true }) end
  if not ok then M.close(); return nil, err end
  return true
end

function M.close()
  if not M.exists() then M.forget(); return true end
  local view = fs.view
  local ok, err = windows.preflight(view, {}, true)
  if not ok then return nil, err end
  return guarded(function()
    if #vim.api.nvim_list_tabpages() == 1 then vim.cmd('tabnew') end
    vim.api.nvim_cmd({ cmd = 'tabclose', args = { tostring(vim.api.nvim_tabpage_get_number(view.tab)) } }, {})
    M.forget()
    if vim.api.nvim_tabpage_is_valid(view.origin_tab) then
      vim.api.nvim_set_current_tabpage(view.origin_tab)
      if valid(view.origin_win) then vim.api.nvim_set_current_win(view.origin_win) end
    end
    return true
  end)
end

function M.range(previous, following)
  for _, count in ipairs({ previous, following }) do
    if type(count) ~= 'number' or count < 0 or count % 1 ~= 0 then return nil, 'Fish-eye counts must be nonnegative integers' end
  end
  if previous == nil or following == nil then return nil, 'Supply both previous and next counts' end
  M.configure()
  local before, after = fs.settings.previous, fs.settings.following
  fs.settings.previous, fs.settings.following = previous, following
  if M.in_tab() then
    local ok, err = M.rebuild(state.active, state.active.index, { preserve = true })
    if not ok then fs.settings.previous, fs.settings.following = before, after; return nil, err end
  elseif M.exists() then fs.view.dirty = true end
  return true
end

function M.toggle_notes()
  M.configure()
  fs.settings.notes = not fs.settings.notes
  if M.in_tab() then
    local ok, err = M.rebuild(state.active, state.active.index, { preserve = true })
    if not ok then fs.settings.notes = not fs.settings.notes; return nil, err end
  elseif M.exists() then fs.view.dirty = true end
  return true
end

function M.refresh()
  if not M.in_tab() then return nil, 'Open the fish-eye tab first' end
  return M.rebuild(state.active, state.active.index, { focus = true })
end

function M.changed(record)
  if not M.exists() or fs.busy then return end
  local view = fs.view
  if view.record == record and view.revision == (record.revision or 0) and view.anchor == record.index then return end
  view.dirty = true
  M.queue()
end

function M.queue()
  if fs.busy or fs.pending or not M.exists() then return end
  fs.pending = true
  local view = fs.view
  vim.schedule(function()
    fs.pending = false
    if fs.view ~= view or not M.in_tab() or not state.active then return end
    local ok, err = M.rebuild(state.active, state.active.index, { preserve = true })
    if not ok then
      if view.record ~= state.active then M.detach(err) else notify(err) end
    end
  end)
end

function M.enter()
  if not M.in_tab() or fs.busy then return end
  local view, win = fs.view, vim.api.nvim_get_current_win()
  if view.record ~= state.active then M.queue(); return end
  local role = view.roles[win]
  if not role and win ~= view.path_win and vim.bo.buftype == '' and vim.api.nvim_win_get_config(win).relative == '' then
    M.detach('An unmanaged code window was opened'); return
  end
  if role and role.buf ~= vim.api.nvim_get_current_buf() then M.detach('A managed code window was replaced'); return end
  if role and role.kind == 'preview' and role.index then
    local previous = view.main
    local ok, err = M.jump(state.active, role.index, win)
    if not ok then
      guarded(function() if valid(previous) then vim.api.nvim_set_current_win(previous) end; return true end)
      notify(err)
    end
  elseif role and role.kind == 'main' then state.windows[view.tab] = win end
end

function M.source_changed(buf)
  if not M.in_tab() or fs.busy then return end
  guarded(function()
    for _, row in ipairs(fs.view.rows) do
      if valid(row.win) and row.buf == buf then windows.mark_line(row, false) end
    end
    return true
  end)
end

function M.install()
  local group = vim.api.nvim_create_augroup('StringerFisheye', { clear = true })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, { group = group, callback = M.enter })
  vim.api.nvim_create_autocmd('TabEnter', { group = group, callback = function()
    if M.in_tab() and (fs.view.dirty or fs.view.record ~= state.active) then M.queue() end
  end })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized' }, { group = group, callback = function()
    -- Window operations queue resize events after the rebuild guard releases.
    if M.in_tab() and fs.view.screen ~= screen_key(fs.view) then
      fs.view.screen = screen_key(fs.view)
      M.queue()
    end
  end })
  vim.api.nvim_create_autocmd({ 'WinClosed', 'TabClosed' }, { group = group, callback = function()
    if fs.busy then return end
    local view = fs.view
    vim.schedule(function()
      if fs.view ~= view or not view then return end
      if not M.exists() then M.forget() else M.queue() end
    end)
  end })
end

return M
