vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime plugin/stringer.lua')
local s = require('stringer')
local state = require('stringer.state')
local fish = require('stringer.fisheye')
local fs = require('stringer.fisheye.state')
local plan = require('stringer.fisheye.plan')
local store = require('stringer.store')
local uv = vim.uv or vim.loop
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert(uv.fs_realpath(root))
local passed, failed, directory, files = 0, 0, nil, nil
local messages = {}
vim.notify = function(message) messages[#messages + 1] = message end

local function eq(a, b) assert(vim.deep_equal(a, b), ('expected %s, got %s'):format(vim.inspect(b), vim.inspect(a))) end
local function yes(ok, err) assert(ok, tostring(err)); return ok end
local function no(ok) assert(not ok, 'Expected failure') end
local function settle() vim.wait(80) end

local function reset()
  state.active = nil
  fs.busy = true
  vim.o.hidden = true
  vim.cmd('silent! tabonly!')
  vim.cmd('silent! only!')
  vim.cmd('enew!')
  fish.forget()
  fs.busy, fs.settings = false, nil
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= vim.api.nvim_get_current_buf() then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  directory = root .. '/' .. (passed + failed + 1)
  vim.fn.mkdir(directory, 'p')
  files = {}
  for i = 1, 9 do
    files[i] = directory .. '/file' .. i .. '.lua'
    local lines = {}
    for n = 1, 80 do lines[n] = ('file_%d_line_%d'):format(i, n) end
    vim.fn.writefile(lines, files[i])
  end
  s.setup({ storage_dir = directory .. '/paths', pane_width = '30%', fisheye_previous = 2, fisheye_next = 2,
    fisheye_notes = true, fisheye_note_width = '35%' })
  messages = {}
end
local function test(name, callback)
  local ok, err = xpcall(function() reset(); callback() end, debug.traceback)
  if ok then passed = passed + 1; print('PASS ' .. name)
  else failed = failed + 1; print('FAIL ' .. name .. '\n' .. err) end
end
local function create(index, same_file)
  local marks = {}
  for i, file in ipairs(files) do
    marks[i] = { file = same_file and files[1] or file, line = i * 7, snapshot = 'captured ' .. i }
    if i % 2 == 1 then marks[i].note = 'Note ' .. i .. '\nMore context' end
  end
  yes(store.create('path', marks)); yes(s.open('path')); state.active.index = index or 5
  return state.active
end
local function row(index)
  for _, item in ipairs(fs.view.rows) do if item.index == index then return item end end
end

test('pure neighborhood preserves order, excludes skipped marks and does not wrap', function()
  local marks = { {}, { skipped = true }, {}, {}, {}, {} }
  local rows = plan.neighbors(marks, 4, 2, 2)
  eq(vim.tbl_map(function(item) return item.index end, rows), { 1, 3, 4, 5, 6 })
  eq(vim.tbl_map(function(item) return item.distance end, rows), { -2, -1, 0, 1, 2 })
  eq(#plan.neighbors(marks, 1, 4, 0), 1)
  eq(#plan.neighbors(marks, 6, 0, 4), 1)
  eq(plan.neighbors(marks, 2, 0, 0)[1].index, 2)
end)
test('golden weights allocate exact totals and drop farthest rows on short screens', function()
  local rows = plan.neighbors({ {}, {}, {}, {}, {} }, 3, 2, 2)
  local heights = plan.heights(rows, 100)
  local sum = 0; for _, h in ipairs(heights) do sum = sum + h end
  eq(sum, 100); assert(heights[3] > heights[2] and heights[2] > heights[1])
  assert(math.abs(heights[3] / heights[2] - plan.phi) < 0.15)
  local reduced = plan.fit(rows, 18)
  assert(#reduced < #rows)
  assert(vim.tbl_contains(vim.tbl_map(function(item) return item.distance end, reduced), 0))
  eq(#plan.fit(rows, 3), 1)
end)
test('opens one dedicated tab with a path pane and retains original layout', function()
  create()
  local tab, win, before = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win(), vim.fn.winlayout()
  yes(s.fisheye()); settle()
  assert(fish.in_tab()); assert(fs.view.path_win and fs.view.main)
  eq(vim.api.nvim_win_get_buf(fs.view.path_win), require('stringer.pane').buffer(state.active))
  eq(vim.api.nvim_get_current_win(), fs.view.main)
  local fish_tab = fs.view.tab
  yes(s.fisheye()); eq(fs.view.tab, fish_tab); eq(#vim.api.nvim_list_tabpages(), 2)
  yes(s.fisheye_close()); eq(vim.api.nvim_get_current_tabpage(), tab)
  eq(vim.api.nvim_get_current_win(), win); eq(vim.fn.winlayout(), before)
end)
test('explicit navigation is cyclic while previews stop at boundaries', function()
  local r = create(1); yes(s.fisheye()); settle()
  eq(fs.view.rows[1].index, 1)
  yes(s.prev()); eq(r.index, 9); eq(fs.view.rows[#fs.view.rows].index, 9)
  yes(s.next()); eq(r.index, 1)
  vim.api.nvim_win_set_cursor(fs.view.main, { 40, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', {}); settle(); eq(r.index, 1)
end)
test('preview focus promotes its exact mark, including repeated buffers', function()
  local r = create(5, true); yes(s.fisheye()); settle()
  local target = fs.view.rows[1]
  assert(target.index ~= r.index)
  local win, index = target.win, target.index
  vim.api.nvim_set_current_win(win); settle()
  eq(r.index, index); eq(fs.view.main, win); eq(vim.api.nvim_get_current_win(), win)
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'edited in promoted main' })
  for _, item in ipairs(fs.view.rows) do eq(vim.api.nvim_win_get_buf(item.win), vim.api.nvim_get_current_buf()) end
  eq(vim.bo.modifiable, true)
end)
test('each same-buffer source window highlights only its own stored line', function()
  create(5, true); yes(s.fisheye()); settle()
  for _, item in ipairs(fs.view.rows) do
    local matches = vim.fn.getmatches(item.win)
    local own = vim.tbl_filter(function(match) return match.group == 'StringerFishLine' end, matches)
    eq(#own, 1); eq(own[1].pos1[1], item.mark.line)
  end
end)
test('asymmetric counts put the main at the appropriate end', function()
  create(5); yes(s.fisheye_range(4, 0)); yes(s.fisheye()); settle()
  eq(fs.view.rows[#fs.view.rows].index, 5)
  eq(vim.api.nvim_win_get_position(fs.view.main)[1], vim.api.nvim_win_get_position(fs.view.rows[#fs.view.rows].win)[1])
  yes(s.fisheye_range(0, 4)); eq(fs.view.rows[1].index, 5)
  yes(s.fisheye_range(0, 0)); eq(#fs.view.rows, 1)
  no(s.fisheye_range(-1, 2)); no(s.fisheye_range(1.5, 2)); no(s.fisheye_range(nil, 2))
end)
test('notes are read-only and their global toggle survives closing and reopening', function()
  create(5); yes(s.fisheye()); settle()
  assert(row(5).note_win, vim.inspect(fs.view))
  eq(vim.bo[row(5).note_buf].modifiable, false)
  local main = fs.view.main
  vim.api.nvim_win_set_cursor(main, { 36, 2 })
  yes(s.fisheye_notes()); eq(fs.settings.notes, false)
  eq(vim.api.nvim_win_get_cursor(fs.view.main), { 36, 2 })
  for _, item in ipairs(fs.view.rows) do eq(item.note_win, nil) end
  yes(s.fisheye_close()); yes(s.fisheye()); eq(fs.settings.notes, false)
  yes(s.fisheye_notes()); assert(row(5).note_win)
end)
test('missing and stale main targets become navigable placeholders', function()
  local r = create(5); vim.fn.delete(files[5]); r.marks[6].line = 999
  yes(s.fisheye()); settle()
  eq(r.index, 5); assert(row(5).problem); eq(vim.bo[row(5).buf].modifiable, false)
  assert(row(5).note_win)
  yes(s.next()); eq(r.index, 6); assert(row(6).problem)
  yes(s.next()); eq(r.index, 7); eq(row(7).problem, nil)
  vim.fn.writefile({ 'restored' }, files[5]); r.marks[5].line = 1
  yes(s.jump(5)); eq(row(5).problem, nil)
end)
test('skipped marks never appear as neighbors; explicit skipped main is allowed', function()
  local r = create(5); r.marks[4].skipped = true; r.marks[6].skipped = true
  yes(s.fisheye()); settle()
  for _, item in ipairs(fs.view.rows) do assert(item.index ~= 4 and item.index ~= 6) end
  yes(s.jump(4)); eq(r.index, 4); eq(fs.view.main, row(4).win)
  yes(s.next()); eq(r.index, 5)
  yes(s.skip(5)); settle(); eq(r.index, 7)
end)
test('empty and all-skipped paths retain an explanatory main window', function()
  yes(s.new('empty')); yes(s.fisheye()); settle(); eq(#fs.view.rows, 1); assert(fs.view.rows[1].problem)
  no(s.next())
  yes(s.fisheye_close()); local r = create(1)
  for _, mark in ipairs(r.marks) do mark.skipped = true end
  r.index = nil; yes(s.fisheye()); settle(); eq(fs.view.anchor, nil); no(s.next())
  yes(s.jump(3)); eq(fs.view.anchor, 3); eq(#fs.view.rows, 1)
end)
test('nohidden navigation and close do not abandon modified source', function()
  local r = create(5); yes(s.fisheye_range(0, 0)); yes(s.fisheye()); settle()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'unsaved' }); vim.o.hidden = false
  no(s.next()); eq(r.index, 5); eq(vim.api.nvim_win_get_buf(fs.view.main), buf)
  no(s.fisheye_close()); assert(fish.in_tab()); eq(vim.bo[buf].modified, true)
  vim.o.hidden = true; yes(s.next()); eq(vim.bo[buf].modified, true)
end)
test('mutations and outside-tab path changes reconcile without stealing focus', function()
  local r = create(5); yes(s.fisheye()); settle()
  yes(s.move_up(5)); settle(); eq(fs.view.anchor, r.index)
  yes(s.remove(r.index)); settle(); assert(fs.view.anchor ~= nil)
  local origin = fs.view.origin_tab
  vim.api.nvim_set_current_tabpage(origin)
  yes(s.new('newpath')); settle(); eq(vim.api.nvim_get_current_tabpage(), origin)
  local fish_tab = fs.view.tab
  vim.api.nvim_set_current_tabpage(fish_tab); settle()
  eq(fs.view.record, state.active); eq(fs.view.record.name, 'newpath')
end)
test('manual tab closure cleans up without recreating the view', function()
  create(); yes(s.fisheye()); settle(); vim.cmd('tabclose'); settle()
  eq(fs.view, nil); eq(#vim.api.nvim_list_tabpages(), 1)
end)
test('focusing an unavailable preview promotes a stable placeholder window', function()
  local r = create(5); vim.fn.delete(files[4]); yes(s.fisheye()); settle()
  local target = row(4); assert(target and target.problem)
  local win = target.win
  vim.api.nvim_set_current_win(win); settle()
  eq(r.index, 4); eq(fs.view.main, win); eq(vim.bo.modified, false)
end)
test('destructive hidden-buffer policies block navigation and mutations', function()
  local r = create(5); yes(s.fisheye_range(0, 0)); yes(s.fisheye()); settle()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'keep me' }); vim.bo[buf].bufhidden = 'wipe'
  local text = r.text
  no(s.next()); no(s.skip(5)); eq(r.text, text); eq(store.read(r.file), text)
  eq(vim.bo[buf].modified, true); eq(r.index, 5)
  vim.bo[buf].bufhidden = ''
end)
test('editing keeps main cursor and split identities while stale highlights are removed', function()
  local r = create(5); yes(s.fisheye()); settle()
  local win, buf = fs.view.main, vim.api.nvim_get_current_buf()
  local ids = vim.tbl_map(function(item) return item.win end, fs.view.rows)
  vim.api.nvim_buf_set_lines(buf, 2, -1, false, {})
  vim.api.nvim_win_set_cursor(win, { 2, 3 }); settle()
  eq(r.index, 5); eq(fs.view.main, win)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 3 })
  eq(vim.tbl_map(function(item) return item.win end, fs.view.rows), ids)
  assert(vim.wo[win].winbar:find('line past EOF', 1, true))
  yes(s.fisheye_refresh()); assert(row(5).problem); eq(vim.bo[buf].modified, true)
end)
test('manual preview closure is repaired and user buffer replacement detaches management', function()
  create(5); yes(s.fisheye()); settle()
  local preview = fs.view.rows[1].win
  vim.api.nvim_win_close(preview, false); settle()
  for _, item in ipairs(fs.view.rows) do assert(vim.api.nvim_win_is_valid(item.win)) end
  local main = fs.view.main
  local unrelated = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(unrelated, 0, -1, false, { 'user work' })
  vim.api.nvim_win_set_buf(main, unrelated); settle()
  eq(fs.view, nil); eq(vim.api.nvim_win_get_buf(main), unrelated); eq(vim.bo[unrelated].modified, true)
end)
test('injected split failure preserves the active mark and usable old source view', function()
  local r = create(5); yes(s.fisheye_range(0, 0)); yes(s.fisheye()); settle()
  local buf = vim.api.nvim_get_current_buf()
  local original = vim.api.nvim_open_win
  vim.api.nvim_open_win = function() error('injected split failure') end
  local ok, err = pcall(function()
    no(s.next()); eq(r.index, 5)
    assert(vim.api.nvim_win_is_valid(fs.view.main)); eq(vim.api.nvim_win_get_buf(fs.view.main), buf)
  end)
  vim.api.nvim_open_win = original; yes(ok, err)
  yes(s.fisheye_refresh()); assert(row(5).note_win)
end)
test('saved note changes update side panels without resetting main editing position', function()
  local r = create(5); yes(s.fisheye()); settle()
  vim.api.nvim_win_set_cursor(fs.view.main, { 36, 2 })
  yes(s.note(5))
  local editor = require('stringer.notes').editor
  vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, { 'new note' }); vim.cmd('write'); settle()
  eq(vim.api.nvim_get_current_win(), editor.win)
  eq(vim.api.nvim_buf_get_lines(row(5).note_buf, 0, -1, false), { 'new note' })
  eq(vim.api.nvim_win_get_cursor(fs.view.main), { 36, 2 })
  eq(r.marks[5].note, 'new note')
end)
test('closing fish-eye after its origin tab is gone leaves a usable ordinary tab', function()
  create(); yes(s.fisheye()); settle()
  local origin = fs.view.origin_tab
  vim.api.nvim_cmd({ cmd = 'tabclose', args = { tostring(vim.api.nvim_tabpage_get_number(origin)) } }, {})
  settle(); eq(#vim.api.nvim_list_tabpages(), 1)
  yes(s.fisheye_close()); eq(fs.view, nil); eq(#vim.api.nvim_list_tabpages(), 1)
end)
test('layout respects user minimum window sizes without changing global options', function()
  local height, width = vim.o.winminheight, vim.o.winminwidth
  local preferred_height, preferred_width = vim.o.winheight, vim.o.winwidth
  local ok, err = pcall(function()
    vim.o.winheight, vim.o.winwidth = math.max(4, preferred_height), math.max(20, preferred_width)
    vim.o.winminheight, vim.o.winminwidth = 4, 20
    create(); yes(s.fisheye()); settle()
    eq(vim.o.winminheight, 4); eq(vim.o.winminwidth, 20)
    for _, item in ipairs(fs.view.rows) do assert(vim.api.nvim_win_get_height(item.win) >= 4) end
    yes(s.fisheye_close())
  end)
  vim.o.winminheight, vim.o.winminwidth = height, width
  vim.o.winheight, vim.o.winwidth = preferred_height, preferred_width
  yes(ok, err)
end)

state.active = nil; fs.busy = true; vim.cmd('silent! tabonly!'); fish.forget(); fs.busy = false
vim.fn.delete(root, 'rf')
print(('%d passed, %d failed'):format(passed, failed))
vim.cmd(failed == 0 and 'qa!' or 'cquit 1')
