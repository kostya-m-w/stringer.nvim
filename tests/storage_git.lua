vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime plugin/stringer.lua')
local s = require('stringer')
local state = require('stringer.state')
local store = require('stringer.store')
local dirs = require('stringer.directories')
local args = require('stringer.arguments')
local provenance = require('stringer.git')
local capture = require('stringer.capture')
local codec = require('stringer.codec')
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p'); root = assert(uv.fs_realpath(root))
local passed, failed, dir, messages = 0, 0, nil, {}
vim.notify = function(message) messages[#messages + 1] = message end
local function eq(a, b) assert(vim.deep_equal(a, b), ('expected %s, got %s'):format(vim.inspect(b), vim.inspect(a))) end
local function yes(ok, err) assert(ok, tostring(err)); return ok end
local function no(ok) assert(not ok, 'Expected failure') end
local function await()
  yes(vim.wait(6000, function() return #capture.pending == 0 and require('stringer.import').pending == nil end, 5),
    'Capture timed out')
end
local function edit(file, line)
  local buf = vim.fn.bufadd(file); vim.fn.bufload(buf); vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
end
local function reset()
  capture.cancel(); require('stringer.import').cancel()
  state.active = nil
  local fs = require('stringer.fisheye.state'); fs.busy = true
  vim.o.hidden = true; vim.cmd('silent! tabonly!'); vim.cmd('silent! only!'); vim.cmd('enew!')
  require('stringer.fisheye').forget(); fs.busy = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  dir = root .. '/' .. (passed + failed + 1); vim.fn.mkdir(dir, 'p')
  s.setup({ storage_dir = dir .. '/Ticket A', pane_width = 48 })
  messages = {}
end
local function test(name, fn)
  local ok, err = xpcall(function() reset(); fn() end, debug.traceback)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. '\n' .. err) end
end
local function git(directory, arguments)
  local command = { 'git', '-C', directory }
  vim.list_extend(command, arguments)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or '')
end
local function commit(repo)
  git(repo, { 'add', '--all' })
  git(repo, { '-c', 'user.name=Stringer Tests', '-c', 'user.email=stringer@example.invalid',
    '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture' })
  return git(repo, { 'rev-parse', 'HEAD' })
end
local function repository(name, unborn)
  local repo = dir .. '/' .. name
  vim.fn.mkdir(repo, 'p'); git(repo, { 'init', '-q' })
  local file = repo .. '/source file.rb'
  vim.fn.writefile({ 'one', 'two', 'three' }, file)
  return repo, file, not unborn and commit(repo) or nil
end
local function mark_path()
  local file = dir .. '/source.lua'; vim.fn.writefile({ 'one', 'two' }, file)
  yes(s.new('Investigate retries')); edit(file, 2); yes(s.add()); await()
  return state.active, file
end

test('quoted parser preserves names and literal backslashes and rejects malformed fragments', function()
  eq(args.parse([[new "Investigate customer's retries"]]), { 'new', "Investigate customer's retries" })
  eq(args.parse([[new 'Investigate "retry" behavior']]), { 'new', 'Investigate "retry" behavior' })
  eq(args.parse([[move 'C:\tickets\ABC']]), { 'move', 'C:\\tickets\\ABC' })
  eq(args.parse([[new "say \"hello\""]]), { 'new', 'say "hello"' })
  no(args.parse([[new "unfinished]])); no(args.parse([[new 'one'two]]))
  eq(args.parse('fisheye-range 4 0'), { 'fisheye-range', '4', '0' })
end)
test('names with spaces work in commands and separators remain literal data', function()
  vim.cmd([[Stringer new "Investigate retries (T-123)"]])
  eq(state.active.name, 'Investigate retries (T-123)')
  vim.cmd([[Stringer rename 'Retry failure analysis']])
  eq(state.active.name, 'Retry failure analysis')
  vim.cmd([[Stringer copy "Literal | name"]])
  eq(store.list(), { 'Literal | name', 'Retry failure analysis' })
  no(s.new(' bad')); no(s.new('bad ')); no(s.new('a/b')); no(s.new('a\nb'))
  vim.cmd('Stringer new Unquoted two words'); eq(state.active.name, 'Retry failure analysis')
end)
test('completion quotes multiword candidates and respects already typed prefixes', function()
  yes(s.new('Investigate payment retries'))
  eq(vim.fn.getcompletion('Stringer open Inv', 'cmdline'), { '"Investigate payment retries"' })
  local line = 'Stringer open "Investigate pay'
  eq(args.complete('pay', line, #line, {}), { 'payment retries"' })
  line = "Stringer open 'Investigate pay"
  eq(args.complete('pay', line, #line, {}), { "payment retries'" })
end)
test('switching storage directory cannot redirect active saves, reloads or renames', function()
  local r, file = mark_path(); local original = r.file
  local cwd = vim.fn.getcwd()
  yes(s.directory(dir .. '/Ticket B')); eq(vim.fn.getcwd(), cwd)
  yes(store.create(r.name, {}))
  edit(file, 1); yes(s.add()); await(); eq(#store.load_file(original).marks, 2)
  eq(#store.load(r.name).marks, 0)
  yes(s.reload()); eq(state.active.file, original); eq(#state.active.marks, 2)
  yes(s.rename('Renamed analysis'))
  eq(vim.fs.dirname(state.active.file), dir .. '/Ticket A')
  eq(dirs.current(), dir .. '/Ticket B')
end)
test('name prompts and picker remain bound to their original destination directory', function()
  local origin = dirs.current()
  local input, callback = vim.ui.input, nil
  vim.ui.input = function(_, cb) callback = cb end
  local ok, err = pcall(function()
    yes(s.new()); yes(s.directory(dir .. '/Ticket B')); callback('Prompt result')
    eq(state.active.file, origin .. '/Prompt result.stringer')
    yes(s.copy()); yes(s.directory(dir .. '/Ticket C')); callback('Copy result')
    yes(store.load('Copy result', dir .. '/Ticket B'))
  end)
  vim.ui.input = input; yes(ok, err)
end)
test('directory errors and aliases preserve predictable selection', function()
  local old = dirs.current()
  local file = dir .. '/not-directory'; vim.fn.writefile({ 'file' }, file)
  no(s.directory(file)); eq(dirs.current(), old)
  yes(s.directory(dir .. '/real'))
  assert(uv.fs_symlink(dir .. '/real', dir .. '/alias'))
  yes(s.directory(dir .. '/alias')); eq(dirs.current(), dir .. '/real')
  s.setup({ gutter = true }); eq(dirs.current(), dir .. '/real')
end)
test('move preserves bytes, identity, history, drafts and fish-eye view', function()
  local r = mark_path(); yes(s.show()); yes(s.fisheye_range(0, 0)); yes(s.fisheye())
  local fish = require('stringer.fisheye.state').view
  local old, text, revision, history = r.file, r.text, r.revision, #r.history
  yes(s.note(1)); local editor = require('stringer.notes').editor
  vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, { 'draft note' })
  yes(s.move(dir .. '/Ticket B'))
  eq(state.active, r); eq(r.text, text); eq(r.revision, revision); eq(#r.history, history)
  eq(store.read(old), nil); eq(store.read(r.file), text); eq(dirs.current(), dir .. '/Ticket B')
  eq(require('stringer.fisheye.state').view, fish); eq(vim.bo[editor.buf].modified, true)
  yes(require('stringer.notes').save()); eq(store.load_file(r.file).marks[1].note, 'draft note')
end)
test('cross-device move stages bytes and rejects a destination collision', function()
  local r = mark_path(); local old, original = r.file, uv.fs_link
  uv.fs_link = function(src, dest)
    if src == old then return nil, 'cross-device', 'EXDEV' end
    return original(src, dest)
  end
  local ok, err = pcall(function()
    yes(s.move(dir .. '/Other volume')); eq(store.read(old), nil); eq(store.read(r.file), r.text)
    yes(store.create(r.name, {}, dir .. '/Ticket A'))
    no(s.move(dir .. '/Ticket A')); eq(vim.fs.dirname(r.file), dir .. '/Other volume')
  end)
  uv.fs_link = original; yes(ok, err)
end)
test('filesystems without hardlinks use exclusive publication without clobbering', function()
  local r = mark_path(); local original = uv.fs_link
  uv.fs_link = function() return nil, 'unsupported', 'ENOTSUP' end
  local ok, err = pcall(function()
    yes(s.move(dir .. '/No links')); eq(store.read(r.file), r.text)
    yes(s.copy('copy')); no(s.copy('copy'))
  end)
  uv.fs_link = original; yes(ok, err)
end)
test('source unlink failure rolls back and rollback failure reports both retained files', function()
  local r = mark_path(); local old, selected = r.file, dirs.current()
  local original = uv.fs_unlink
  uv.fs_unlink = function(path) if path == old then return nil, 'cannot remove source' end; return original(path) end
  local ok, err = pcall(function()
    no(s.move(dir .. '/Target')); eq(r.file, old); eq(dirs.current(), selected)
    eq(store.read(dir .. '/Target/' .. r.name .. '.stringer'), nil)
    uv.fs_unlink = function() return nil, 'cannot remove either file' end
    no(s.move(dir .. '/Target')); eq(r.file, old)
    eq(store.read(old), r.text); eq(store.read(dir .. '/Target/' .. r.name .. '.stringer'), r.text)
    assert(messages[#messages]:find('destination remains', 1, true))
  end)
  uv.fs_unlink = original; yes(ok, err)
end)
test('publication races never replace the competing destination', function()
  local original = uv.fs_link
  uv.fs_link = function(src, dest)
    vim.fn.writefile({ 'competing writer' }, dest)
    return original(src, dest)
  end
  local ok, err = pcall(function()
    no(s.new('race')); eq(state.active, nil)
    eq(store.read(store.path('race')), 'competing writer\n')
  end)
  uv.fs_link = original; yes(ok, err)
end)
test('Git provenance is per-file, full length and immutable after snapshot refresh', function()
  local repo, file, head = repository('Repo with spaces')
  yes(s.new('Git analysis')); edit(file, 2); yes(s.add()); await()
  local r = state.active
  eq(r.marks[1].git, { commit = head, path = 'source file.rb' }); eq(r.marks[1].snapshot, 'two')
  vim.fn.writefile({ 'one', 'committed change', 'three' }, file)
  local next_head = commit(repo); assert(next_head ~= head)
  vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'unsaved new text' })
  yes(s.refresh_snapshot(1)); eq(r.marks[1].git.commit, head)
  yes(s.add()); await(); eq(r.marks[2].git.commit, next_head)
  eq(r.marks[2].snapshot, 'unsaved new text')
  yes(s.copy('Git copy')); eq(store.load('Git copy').marks, r.marks)
end)
test('worktrees, detached HEAD and nested repositories use their own commits', function()
  local repo, _, head = repository('main')
  local worktree = dir .. '/worktree'
  git(repo, { 'worktree', 'add', '-q', '--detach', worktree, 'HEAD' })
  local nested, file, nested_head = repository('main/nested')
  assert(nested ~= repo)
  vim.fn.writefile({ 'nested one', 'nested two' }, file)
  nested_head = commit(nested); assert(nested_head ~= head)
  yes(s.new('Mixed repositories')); edit(worktree .. '/source file.rb', 1); yes(s.add())
  edit(file, 2); yes(s.add()); await()
  eq(state.active.marks[1].git.commit, head)
  eq(state.active.marks[2].git.commit, nested_head)
end)
test('unborn repositories and missing Git still permit marks without provenance', function()
  local _, file = repository('unborn', true)
  yes(s.new('Unborn')); edit(file); yes(s.add()); await(); eq(state.active.marks[1].git, nil)
  local original = vim.fn.executable
  vim.fn.executable = function(name) if name == 'git' then return 0 end; return original(name) end
  local ok, err = pcall(function() yes(s.add()); await(); eq(state.active.marks[2].git, nil) end)
  vim.fn.executable = original; yes(ok, err)
end)
test('SHA-256 repositories record the complete checked-out object ID when supported', function()
  local repo = dir .. '/sha256'; vim.fn.mkdir(repo, 'p')
  local initialized = vim.system({ 'git', '-C', repo, 'init', '-q', '--object-format=sha256' }, { text = true }):wait()
  if initialized.code ~= 0 then print('SKIP fixture: this Git does not support SHA-256 repositories'); return end
  local file = repo .. '/source.rb'; vim.fn.writefile({ 'source' }, file)
  local head = commit(repo); eq(#head, 64)
  yes(s.new('SHA256')); edit(file); yes(s.add()); await()
  eq(state.active.marks[1].git, { commit = head, path = 'source.rb' })
end)
test('rapid captures commit in invocation order and append to the latest mark list', function()
  local r, file = mark_path()
  local original, callbacks = provenance.enrich, {}
  provenance.enrich = function(marks, token, callback) callbacks[#callbacks + 1] = function() callback(marks, {}) end end
  local ok, err = pcall(function()
    edit(file, 1); yes(s.add()); edit(file, 2); yes(s.add())
    yes(s.skip(1)); callbacks[2](); eq(#r.marks, 1)
    callbacks[1](); eq(#r.marks, 3)
    eq(r.marks[2].line, 1); eq(r.marks[3].line, 2); eq(r.marks[1].skipped, true)
    yes(s.add()); yes(s.new('Other path')); callbacks[3](); eq(#state.active.marks, 0)
  end)
  provenance.enrich = original; capture.cancel(); yes(ok, err)
end)
test('import groups Git provenance and stays bound to its starting storage directory', function()
  local _, file, head = repository('repo')
  vim.cmd('enew'); vim.api.nvim_buf_set_lines(0, 0, -1, false, { file .. ":2:in `worker'", file .. ":1:in `main'" })
  local origin = dirs.current()
  yes(s.import('Imported trace')); yes(s.directory(dir .. '/Another ticket')); await()
  eq(state.active.file, origin .. '/Imported trace.stringer')
  eq(#state.active.marks, 2)
  for _, mark in ipairs(state.active.marks) do eq(mark.git.commit, head); eq(mark.git.path, 'source file.rb') end
end)
test('Git process errors leave marking usable and cancelled processes do not publish', function()
  local _, file = repository('repo')
  yes(s.new('Process errors')); edit(file)
  local original, killed = vim.system, false
  vim.system = function(_, _, callback)
    local process = { kill = function() killed = true end }
    vim.schedule(function() callback({ code = 124, stdout = '', stderr = 'timeout' }) end)
    return process
  end
  local ok, err = pcall(function()
    yes(s.add()); await(); eq(#state.active.marks, 1); eq(state.active.marks[1].git, nil)
    assert(table.concat(messages, '\n'):find('provenance unavailable', 1, true))
    yes(s.add()); yes(s.new('Switched')); await(); vim.wait(30)
    eq(#state.active.marks, 0); eq(killed, true)
  end)
  vim.system = original; yes(ok, err)
end)
test('move failure preserves a destination changed by another writer', function()
  local r = mark_path(); local old, text = r.file, r.text
  local link, unlink = uv.fs_link, uv.fs_unlink
  local destination = dir .. '/Target/' .. r.name .. '.stringer'
  uv.fs_link = function(src, dst)
    if src == old then return nil, 'cross-device', 'EXDEV' end
    return link(src, dst)
  end
  uv.fs_unlink = function(path)
    if path == old then
      vim.fn.writefile({ 'another writer' }, destination)
      return nil, 'source removal blocked'
    end
    return unlink(path)
  end
  local ok, err = pcall(function()
    no(s.move(dir .. '/Target')); eq(r.file, old)
    eq(store.read(old), text); eq(store.read(destination), 'another writer\n')
    assert(messages[#messages]:find('Destination changed', 1, true))
  end)
  uv.fs_link, uv.fs_unlink = link, unlink; yes(ok, err)
end)
test('moving a legacy file preserves its bytes rather than upgrading its format', function()
  yes(s.new('Legacy path'))
  local r = state.active
  local text = '{"type":"stringer","format_version":1,"mark_version":1}\n'
  vim.fn.writefile({ text:sub(1, -2) }, r.file)
  yes(s.reload()); r = state.active
  yes(s.move(dir .. '/Archive')); eq(store.read(r.file), text)
end)
test('v4 provenance accepts full object IDs and rejects malformed paths and metadata', function()
  for _, length in ipairs({ 40, 64 }) do
    local mark = { file = dir .. '/source', line = 1, git = { commit = string.rep('a', length), path = 'src/code.rb' } }
    eq(codec.decode(codec.encode({ mark })), { mark })
  end
  for _, path in ipairs({ '../source', '/absolute', 'src/../source', 'C:\\absolute' }) do
    no(codec.decode(codec.encode({ { file = dir .. '/source', line = 1, git = { commit = string.rep('a', 40), path = path } } })))
  end
  no(codec.decode(codec.encode({ { file = dir .. '/source', line = 1, git = { commit = 'abc', path = 'source' } } })))
  local old = codec.encode({ { file = dir .. '/source', line = 1, snapshot = '' } })
  old[1] = old[1]:gsub('"mark_version":4', '"mark_version":3')
  yes(codec.decode(old))
end)

capture.cancel(); require('stringer.import').cancel()
state.active = nil; vim.cmd('silent! tabonly!')
vim.fn.delete(root, 'rf')
print(('%d passed, %d failed'):format(passed, failed))
vim.cmd(failed == 0 and 'qa!' or 'cquit 1')
