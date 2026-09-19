vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime plugin/stringer.lua')

local stringer = require('stringer')
local codec = require('stringer.codec')
local store = require('stringer.store')
local state = require('stringer.state')
local pane = require('stringer.pane')
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(uv.fs_realpath(root))
local notifications = {}
vim.notify = function(message) notifications[#notifications + 1] = message end
local passed, failed = 0, 0
local fixture, other, directory

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), ('expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual)))
end

local function succeeds(ok, err)
  assert(ok, tostring(err))
  return ok
end

local function rejects(ok, err, pattern)
  assert(not ok, 'expected failure')
  if pattern then
    assert(tostring(err):find(pattern), tostring(err))
  end
end

local function edit(file, line)
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
end

local function reset()
  vim.o.hidden = true
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  vim.cmd('enew!')
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  state.active, state.windows = nil, {}
  pane.buffers, pane.windows = {}, {}
  directory = root .. '/' .. tostring(passed + failed + 1)
  vim.fn.mkdir(directory .. '/repo-a', 'p')
  vim.fn.mkdir(directory .. '/repo-b', 'p')
  fixture = directory .. '/repo-a/a "quoted" file.lua'
  other = directory .. '/repo-b/b.lua'
  vim.fn.writefile({ 'one', 'two', 'three', 'four' }, fixture)
  vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, other)
  stringer.setup({ storage_dir = directory .. '/paths', pane_width = 40 })
  notifications = {}
end

local function test(name, fn)
  local ok, err = xpcall(function()
    reset()
    fn()
  end, debug.traceback)
  if ok then
    passed = passed + 1
    print('PASS ' .. name)
  else
    failed = failed + 1
    print('FAIL ' .. name .. '\n' .. err)
  end
end

local function capture_path()
  succeeds(stringer.new('demo'))
  edit(fixture, 2)
  succeeds(stringer.add())
  edit(other, 3)
  succeeds(stringer.add())
  edit(fixture, 4)
  succeeds(stringer.add())
  return state.active
end

test('codec round trips escaped paths and repeated locations', function()
  local marks = { { file = fixture, line = 2 }, { file = fixture, line = 2 }, { file = other, line = 3 } }
  eq(codec.decode(codec.encode(marks)), marks)
  eq(codec.decode(codec.encode({})), {})
  eq(codec.decode(codec.lines(codec.text(codec.encode(marks)))), marks)
end)

test('codec rejects invalid versions and reports all record line numbers', function()
  local marks, errors = codec.decode({ '{"type":"stringer","format_version":2,"mark_version":1}', '',
    '{"file":"relative.lua","line":1}', '{"file":"/a","line":1.5}', 'null', '[]',
    '{"file":"/a","line":1,"extra":true}' })
  eq(marks, nil)
  eq(#errors, 7)
  for i, err in ipairs(errors) do eq(err.line, i) end
  rejects(codec.decode(codec.lines(codec.text(codec.encode({})) .. '\n')))
end)

test('storage creates, lists, and rejects overwrites and invalid names', function()
  eq(store.list(), {})
  succeeds(store.create('z'))
  succeeds(store.create('a'))
  eq(store.list(), { 'a', 'z' })
  rejects(store.create('../bad'))
  rejects(store.create('z'))
  eq(store.load('a').marks, {})
end)

test('commands register, validate arguments, and complete path names', function()
  vim.cmd('Stringer new demo')
  eq(state.active.name, 'demo')
  eq(vim.fn.getcompletion('Stringer op', 'cmdline'), { 'open' })
  eq(vim.fn.getcompletion('Stringer open d', 'cmdline'), { 'demo' })
  vim.cmd('Stringer next unexpected')
  assert(notifications[#notifications]:find('Usage'))
end)

test('capture and navigation span codebases and repeated files', function()
  local record = capture_path()
  local codewin = vim.api.nvim_get_current_win()
  succeeds(stringer.next())
  eq(vim.api.nvim_buf_get_name(0), fixture)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  succeeds(stringer.next())
  eq(vim.api.nvim_buf_get_name(0), other)
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
  succeeds(stringer.next())
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
  rejects(stringer.next())
  eq(record.index, 3)
  succeeds(stringer.prev())
  eq(vim.api.nvim_get_current_win(), codewin)
  eq(store.load('demo').marks, record.marks)
end)

test('empty paths and boundaries do not wrap', function()
  rejects(stringer.next())
  succeeds(stringer.new('demo'))
  rejects(stringer.next())
  edit(fixture)
  succeeds(stringer.add())
  succeeds(stringer.prev())
  eq(state.active.index, 1)
  rejects(stringer.prev())
  eq(state.active.index, 1)
end)

test('capture rejects unnamed, unsaved, and special buffers', function()
  succeeds(stringer.new('demo'))
  rejects(stringer.add())
  vim.api.nvim_buf_set_name(0, directory .. '/not-saved.lua')
  rejects(stringer.add())
  succeeds(stringer.show())
  rejects(stringer.add())
  eq(#state.active.marks, 0)
end)

test('failed activation leaves the current path intact', function()
  local record = capture_path()
  rejects(stringer.open('missing'))
  eq(state.active, record)
  vim.fn.writefile({ 'bad header' }, store.path('bad'))
  rejects(stringer.open('bad'))
  eq(state.active, record)
end)

test('path picker selects and opens a saved path', function()
  succeeds(stringer.new('a'))
  succeeds(stringer.new('b'))
  local original = vim.ui.select
  vim.ui.select = function(items, _, callback)
    eq(items, { 'a', 'b' })
    callback('a')
  end
  local ok, err = pcall(stringer.open)
  vim.ui.select = original
  succeeds(ok, err)
  eq(state.active.name, 'a')
end)

test('pane navigation preserves pane and highlights the saved mark', function()
  local record = capture_path()
  local codewin = vim.api.nvim_get_current_win()
  succeeds(stringer.show())
  local panewin, buf = vim.api.nvim_get_current_win(), pane.buffer(record)
  succeeds(stringer.next())
  eq(vim.api.nvim_get_current_win(), codewin)
  eq(vim.api.nvim_win_get_buf(panewin), buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, pane.namespace, 0, -1, {})
  eq(#marks, 1)
  eq(marks[1][2], 1)
  succeeds(stringer.show())
  eq(vim.api.nvim_get_current_win(), panewin)
  eq(#vim.api.nvim_list_wins(), 2)
end)

test('saved reorder and deletion reset active mark and change navigation order', function()
  local record = capture_path()
  succeeds(stringer.next())
  succeeds(stringer.show())
  local buf = pane.buffer(record)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { lines[1], lines[4], lines[2] })
  vim.cmd('write')
  eq(record.index, nil)
  eq(#record.marks, 2)
  eq(record.marks[1].line, 4)
  eq(vim.bo[buf].modified, false)
  succeeds(stringer.next())
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
end)

test('unchanged saves preserve active position', function()
  local record = capture_path()
  succeeds(stringer.next())
  succeeds(stringer.show())
  vim.cmd('write')
  eq(record.index, 1)
end)

test('invalid save preserves disk and snapshot and prevents wq closing', function()
  local record = capture_path()
  local before = record.text
  succeeds(stringer.show())
  local buf, win = pane.buffer(record), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { 'invalid' })
  rejects(pcall(vim.cmd, 'wq'))
  eq(vim.api.nvim_win_is_valid(win), true)
  eq(record.text, before)
  eq(store.read(record.file), before)
  eq(vim.bo[buf].modified, true)
  eq(vim.diagnostic.get(buf, { namespace = pane.diagnostics })[1].lnum, 2)
  succeeds(stringer.next())
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  eq(#vim.api.nvim_buf_get_extmarks(buf, pane.namespace, 0, -1, {}), 0)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, codec.lines(before))
  succeeds(stringer.show())
  vim.cmd('write')
  eq(#vim.diagnostic.get(buf, { namespace = pane.diagnostics }), 0)
end)

test('dirty pane blocks append, switching, and pane-line jumps', function()
  succeeds(store.create('other'))
  local record = capture_path()
  succeeds(stringer.show())
  local buf = pane.buffer(record)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'draft' })
  rejects(stringer.open('other'))
  rejects(stringer.new('newpath'))
  rejects(stringer.add())
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
  eq(record.index, nil)
  eq(state.active, record)
  vim.cmd('close!')
  succeeds(stringer.show())
  eq(vim.api.nvim_buf_get_lines(buf, 1, 2, false), { 'draft' })
end)

test('edit bang discards draft and reloads external changes', function()
  local record = capture_path()
  succeeds(stringer.show())
  local buf = pane.buffer(record)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'draft' })
  local marks = { { file = other, line = 1 } }
  vim.fn.writefile(codec.encode(marks), record.file)
  vim.cmd('edit!')
  eq(record.marks, marks)
  eq(vim.bo[buf].modified, false)
  succeeds(stringer.next())
  eq(vim.api.nvim_buf_get_name(0), other)
end)

test('external modification blocks append and pane save without losing edits', function()
  local record = capture_path()
  local original = record.text
  local external = codec.text(codec.encode({ { file = fixture, line = 1 } }))
  vim.fn.writefile(codec.lines(external), record.file)
  rejects(stringer.add())
  eq(record.text, original)
  succeeds(stringer.show())
  local buf = pane.buffer(record)
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
  rejects(pcall(vim.cmd, 'write'))
  eq(vim.bo[buf].modified, true)
  eq(store.read(record.file), external)
  eq(record.text, original)
end)

test('failed atomic replacement preserves disk, state, and draft', function()
  local record = capture_path()
  local before = record.text
  local original = uv.fs_rename
  uv.fs_rename = function() return nil, 'injected rename failure' end
  local ok, err = pcall(function()
    rejects(stringer.add())
    succeeds(stringer.show())
    local buf = pane.buffer(record)
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
    rejects(pcall(vim.cmd, 'write'))
    eq(vim.bo[buf].modified, true)
    eq(record.text, before)
    eq(store.read(record.file), before)
    eq(#vim.fn.glob(record.file .. '.*', false, true), 0)
  end)
  uv.fs_rename = original
  succeeds(ok, err)
end)

test('missing and stale targets preserve active position and current buffer', function()
  local record = capture_path()
  succeeds(stringer.next())
  local buf = vim.api.nvim_get_current_buf()
  vim.fn.delete(other)
  rejects(stringer.next())
  eq(record.index, 1)
  eq(vim.api.nvim_get_current_buf(), buf)
  vim.api.nvim_buf_set_lines(buf, 2, -1, false, {})
  rejects(stringer.jump(3))
  eq(record.index, 1)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
end)

test('modified code buffer obeys nohidden safeguards', function()
  local record = capture_path()
  succeeds(stringer.next())
  vim.o.hidden = false
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved change' })
  rejects(stringer.next())
  eq(record.index, 1)
  eq(vim.api.nvim_buf_get_name(0), fixture)
  eq(vim.bo.modified, true)
  vim.o.hidden = true
  succeeds(stringer.next())
  eq(vim.bo[vim.fn.bufnr(fixture)].modified, true)
end)

test('navigation from pane fails gracefully with no eligible window', function()
  capture_path()
  succeeds(stringer.show())
  vim.cmd('only')
  local buf = vim.api.nvim_get_current_buf()
  rejects(stringer.next())
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test('code window selection stays within the current tab', function()
  local record = capture_path()
  succeeds(stringer.show())
  vim.cmd('tabnew')
  edit(other)
  local codewin = vim.api.nvim_get_current_win()
  succeeds(stringer.show())
  succeeds(stringer.next())
  eq(vim.api.nvim_get_current_win(), codewin)
  eq(vim.api.nvim_buf_get_name(0), fixture)
  eq(record.index, 1)
end)

test('opening a pane retains the last focused of multiple code windows', function()
  capture_path()
  vim.cmd('botright vsplit')
  local last_codewin = vim.api.nvim_get_current_win()
  succeeds(stringer.show())
  succeeds(stringer.next())
  eq(vim.api.nvim_get_current_win(), last_codewin)
end)

test('reopening paths reuses buffers and replaces the visible pane', function()
  local record = capture_path()
  succeeds(stringer.show())
  local buf, win = pane.buffer(record), vim.api.nvim_get_current_win()
  succeeds(stringer.new('second'))
  assert(vim.api.nvim_win_get_buf(win) ~= buf)
  succeeds(stringer.open('demo'))
  eq(pane.buffer(state.active), buf)
  eq(vim.api.nvim_win_get_buf(win), buf)
  eq(state.active.index, nil)
end)

test('manually opened dirty codepath buffer is not overwritten', function()
  succeeds(store.create('demo'))
  edit(store.path('demo'))
  vim.api.nvim_buf_set_lines(0, 1, -1, false, { 'draft' })
  rejects(stringer.open('demo'))
  eq(vim.api.nvim_buf_get_lines(0, 1, -1, false), { 'draft' })
  eq(state.active, nil)
end)

test('saved codepaths reopen and navigate in a fresh Neovim process', function()
  capture_path()
  vim.env.STRINGER_REOPEN_DIR = directory .. '/paths'
  vim.env.STRINGER_REOPEN_FILE = fixture
  local output = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', 'tests/reopen.lua' })
  assert(vim.v.shell_error == 0, output)
  assert(output:find('REOPEN PASS'), output)
end)

vim.fn.delete(root, 'rf')
print(('%d passed, %d failed'):format(passed, failed))
vim.cmd(failed == 0 and 'qa!' or 'cquit 1')
