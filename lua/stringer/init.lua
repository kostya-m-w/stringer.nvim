local config = require('stringer.config')
local codec = require('stringer.codec')
local store = require('stringer.store')
local state = require('stringer.state')
local navigation = require('stringer.navigation')
local pane = require('stringer.pane')
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

local function clean(record)
  if record and pane.dirty(record) then
    return nil, 'Save or discard codepath edits first (:write or :edit!)'
  end
  return true
end

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
  if previous then
    pane.highlight(previous)
  end
  pane.highlight(record)
  return true
end

function M.setup(opts)
  config.setup(opts)
  M._initialize()
end

function M.new(name)
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
      return fail('No saved codepaths; use :Stringer new <name>')
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
  local text = codec.text(codec.encode(marks))
  ok, err = store.write(record.file, text, record.text)
  if not ok then
    return fail(err)
  end
  -- Appending cannot change an existing mark's position.
  record.marks, record.text = marks, text
  pane.refresh(record)
  return true
end

function M.show()
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
  pane.highlight(record)
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
  local index = record.index and record.index + direction or (direction == 1 and 1 or #record.marks)
  if index < 1 or index > #record.marks then
    return fail(direction == 1 and 'End of codepath reached' or 'Beginning of codepath reached')
  end
  return M.jump(index)
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
  end
  highlights()
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, { group = group, callback = navigation.remember })
  navigation.remember()
end

return M
