local config = require('stringer.config')
local model = require('stringer.model')
local store = require('stringer.store')
local state = require('stringer.state')
local navigation = require('stringer.navigation')
local pane = require('stringer.pane')
local presentation = require('stringer.presentation')
local M = {}

local function fail(err)
  vim.notify('Stringer: ' .. tostring(err), vim.log.levels.ERROR)
  return nil, err
end

local function active()
  if not state.active then
    return nil, 'No active codepath; use :Stringer new or :Stringer open'
  end
  return state.active
end

local clean = model.clean

local function activate(record)
  local ok, err = clean(record)
  if not ok then
    return fail(err)
  end
  ok, err = pane.activate(record)
  if not ok then
    return fail(err)
  end
  local previous = state.active
  state.active = record
  if previous and previous.file ~= record.file then
    pane.highlight(previous)
  end
  presentation.refresh(record)
  M.sync()
  return true
end

function M.setup(opts)
  config.setup(opts)
  M._initialize()
end

function M.new(name)
  if not name then
    vim.ui.input({ prompt = 'New Stringer codepath: ' }, function(value)
      if value and value ~= '' then M.new(value) end
    end)
    return true
  end
  local ok, err = clean(state.active)
  if not ok then
    return fail(err)
  end
  local record
  record, err = store.create(name)
  if not record then
    return fail(err)
  end
  return activate(record)
end

function M.open(name)
  local ok, err = clean(state.active)
  if not ok then
    return fail(err)
  end
  if not name or name == '' then
    local names
    names, err = store.list()
    if not names then
      return fail(err)
    end
    if #names == 0 then
      return M.new()
    end
    vim.ui.select(names, { prompt = 'Open Stringer codepath:' }, function(choice)
      if choice then
        M.open(choice)
      end
    end)
    return true
  end
  local record
  record, err = store.load(name)
  if not record then
    return fail(err)
  end
  return activate(record)
end

local function persist(record, marks, index, selected, undoing)
  local ok, err = model.persist(record, marks, index, selected, undoing)
  if not ok then return fail(err) end
  return true
end

function M.add()
  local record, err = active()
  if not record then
    return fail(err)
  end
  local ok
  ok, err = clean(record)
  if not ok then
    return fail(err)
  end
  local mark
  mark, err = navigation.capture()
  if not mark then
    return fail(err)
  end
  local marks = vim.deepcopy(record.marks)
  marks[#marks + 1] = mark
  ok, err = persist(record, marks, record.index)
  if ok then M.sync() end
  return ok, err
end

function M.sync()
  local record = state.active
  if record and not navigation.navigating then
    local index = navigation.nearest(record)
    if index ~= record.index then
      record.index = index
      presentation.refresh(record)
    end
  end
end

local function selection(record, index)
  if index == nil then
    M.sync()
    index = pane.selected(record)
  end
  if type(index) ~= 'number' or index % 1 ~= 0 or not record.marks[index] then
    return nil, 'Select a mark first'
  end
  return index
end

function M.remove(index)
  local record, err = active()
  if not record then return fail(err) end
  index, err = selection(record, index)
  if not index then return fail(err) end
  local marks = vim.deepcopy(record.marks)
  table.remove(marks, index)
  local current = record.index
  if current == index then current = nil
  elseif current and current > index then current = current - 1 end
  return persist(record, marks, current, math.max(1, math.min(index, #marks)))
end

local function move(direction, index)
  local record, err = active()
  if not record then return fail(err) end
  index, err = selection(record, index)
  if not index then return fail(err) end
  local target = index + direction
  while record.hide_skipped and record.marks[target] and record.marks[target].skipped do
    target = target + direction
  end
  if target < 1 or target > #record.marks then return fail('Mark is already at that end of the codepath') end
  local marks = vim.deepcopy(record.marks)
  local moved = table.remove(marks, index)
  table.insert(marks, target, moved)
  local current = record.index
  if current == index then current = target
  elseif current and index < target and current > index and current <= target then current = current - 1
  elseif current and index > target and current >= target and current < index then current = current + 1 end
  return persist(record, marks, current, target)
end

function M.move_up(index) return move(-1, index) end
function M.move_down(index) return move(1, index) end

function M.skip(index)
  local record, err = active()
  if not record then return fail(err) end
  index, err = selection(record, index)
  if not index then return fail(err) end
  local marks = vim.deepcopy(record.marks)
  marks[index].skipped = not marks[index].skipped or nil
  local current = record.index
  if current == index and marks[index].skipped then current = nil end
  return persist(record, marks, current, index)
end

function M.hide_skipped()
  local record, err = active()
  if not record then return fail(err) end
  local selected = pane.selected(record)
  record.hide_skipped = not record.hide_skipped
  presentation.refresh(record, selected)
  return true
end

function M.note(index)
  local record, err = active()
  if not record then return fail(err) end
  index, err = selection(record, index)
  if not index then return fail(err) end
  local ok
  ok, err = require('stringer.notes').open(record, index)
  if not ok then return fail(err) end
  return true
end

function M.import(name)
  return require('stringer.import').start(name, function(value, marks)
    local ok, err = clean(state.active)
    if not ok then return fail(err) end
    local file
    file, err = store.path(value)
    if not file then return fail(err) end
    ok, err = clean({ file = file })
    if not ok then return fail(err) end
    local record
    record, err = store.create(value, marks)
    if not record then return fail(err) end
    return activate(record)
  end)
end

function M.import_report() return require('stringer.import').show_report() end
function M.cancel_import() return require('stringer.import').cancel() end

function M.undo()
  local record, err = active()
  if not record then return fail(err) end
  local history = record.history or {}
  local previous = history[#history]
  if not previous then return fail('No mark changes to undo') end
  local ok
  ok, err = persist(record, previous.marks, previous.index, previous.index or 1, true)
  if ok then table.remove(history) end
  return ok, err
end

function M.reload()
  local record, err = active()
  if not record then return fail(err) end
  return M.open(record.name)
end

function M.rename(name)
  local record, err = active()
  if not record then return fail(err) end
  if not name then
    vim.ui.input({ prompt = 'Rename Stringer codepath: ', default = record.name }, function(value)
      if value and value ~= '' then
        if state.active ~= record then
          fail('Active codepath changed while the rename prompt was open')
        else
          M.rename(value)
        end
      end
    end)
    return true
  end
  local ok
  ok, err = clean(record)
  if not ok then return fail(err) end
  local file
  file, err = store.rename(record, name)
  if not file then return fail(err) end
  local old_file = record.file
  record.file, record.name = file, name
  pane.rekey(record, old_file)
  presentation.refresh(record)
  return true
end

function M.show()
  M.sync()
  local record, err = active()
  if not record then
    return fail(err)
  end
  local ok
  ok, err = pane.show(record)
  if not ok then
    return fail(err)
  end
  return true
end

function M.jump(index)
  local record, err = active()
  if not record then
    return fail(err)
  end
  if type(index) ~= 'number' or index % 1 ~= 0 then
    return fail('Mark index must be an integer')
  end
  local ok
  ok, err = navigation.jump(record, index)
  if not ok then
    return fail(err)
  end
  presentation.refresh(record)
  return true
end

local function step(direction)
  local record, err = active()
  if not record then
    return fail(err)
  end
  if #record.marks == 0 then
    return fail('The active codepath is empty')
  end
  local current = navigation.nearest(record) or (direction == 1 and 0 or 1)
  for offset = 1, #record.marks do
    local index = (current - 1 + direction * offset) % #record.marks + 1
    if not record.marks[index].skipped then return M.jump(index) end
  end
  return fail('The active codepath has no enabled marks')
end

function M.next()
  return step(1)
end

function M.prev()
  return step(-1)
end

function M._initialize()
  local group = vim.api.nvim_create_augroup('Stringer', { clear = true })
  local function highlights()
    vim.api.nvim_set_hl(0, 'StringerActive', { default = true, link = 'Visual' })
    vim.api.nvim_set_hl(0, 'StringerSkipped', { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(0, 'StringerNote', { default = true, link = 'Comment' })
    vim.api.nvim_set_hl(0, 'StringerGutter', { default = true, link = 'Special' })
    vim.api.nvim_set_hl(0, 'StringerGutterActive', { default = true, link = 'Search' })
    vim.api.nvim_set_hl(0, 'StringerGutterSkipped', { default = true, link = 'Comment' })
  end
  highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter', 'CursorMoved', 'CursorMovedI' }, {
    group = group, callback = function()
      navigation.remember()
      M.sync()
    end,
  })
  vim.api.nvim_create_autocmd({ 'DirChanged', 'BufEnter' }, {
    group = group, callback = function(args)
      local record = state.active
      if record and (args.event == 'DirChanged' or vim.api.nvim_get_current_buf() == pane.buffer(record)) then
        pane.refresh(record)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter', 'BufFilePost' }, {
    group = group, callback = function(args) presentation.enter(args.buf) end,
  })
  vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'DirChanged' }, {
    group = group, callback = function() presentation.queue_pane(state.active) end,
  })
  vim.api.nvim_create_autocmd({ 'LspAttach', 'LspDetach' }, {
    group = group, callback = function(args) presentation.changed(args.buf) end,
  })
  navigation.remember()
  if state.active then presentation.refresh(state.active)
  else require('stringer.gutter').refresh(nil) end
end

return M
