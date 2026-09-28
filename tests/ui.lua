-- Exercise actual input, redraws, mappings, and pane focus with an attached UI.
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert((vim.uv or vim.loop).fs_realpath(root))
local fixture = root .. '/code.lua'
vim.fn.writefile({ 'first_location', 'second_location', 'third_location' }, fixture)
local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '-u', 'NONE', '-i', 'NONE' }, { rpc = true })
assert(child > 0, 'Could not start UI test child')

local function lua(code, ...)
  return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... })
end

local function input(keys)
  vim.rpcrequest(child, 'nvim_input', keys)
  vim.wait(80)
  lua('vim.cmd("redraw")')
end

local ok, err = xpcall(function()
  vim.rpcrequest(child, 'nvim_ui_attach', 120, 35, { rgb = true })
  lua([[
    local cwd, root, file = ...
    vim.opt.runtimepath:prepend(cwd)
    vim.cmd('runtime plugin/stringer.lua')
    vim.o.hidden = true
    vim.o.shortmess = vim.o.shortmess .. 'I'
    vim.notify = function(message) _G.last_notification = message end
    local s = require('stringer')
    s.setup({ storage_dir = root .. '/paths' })
    local buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    _G.codewin = vim.api.nvim_get_current_win()
    assert(s.new('ui'))
    for line = 1, 3 do
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      assert(s.add())
    end
    assert(s.show())
    _G.panewin = vim.api.nvim_get_current_win()
  ]], vim.fn.getcwd(), root, fixture)

  input('4G<CR>')
  assert(lua('return vim.api.nvim_get_current_win() == _G.codewin'), 'Enter did not focus code')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 1, 'Wrong jump line')
  local visible = lua([[
    vim.cmd('redraw')
    local marked = vim.fn.screenpos(_G.panewin, 3, 1)
    local other = vim.fn.screenpos(_G.panewin, 5, 1)
    return {
      vim.fn.screenstring(marked.row, marked.col),
      vim.fn.screenattr(marked.row, marked.col),
      vim.fn.screenattr(other.row, other.col),
    }
  ]])
  assert(visible[1] == '↓', 'Downward entry arrow not rendered')
  assert(visible[2] ~= visible[3], 'Active mark has no visible highlight')
  assert(lua([[
    local p = vim.api.nvim_win_get_position(_G.panewin)
    local text = ''
    for col = p[2] + 1, p[2] + vim.api.nvim_win_get_width(_G.panewin) do
      text = text .. vim.fn.screenstring(p[1] + 1, col)
    end
    return text:find('STRINGER', 1, true) ~= nil and text:find('ui', 1, true) ~= nil
  ]]), 'Persistent codepath header not rendered')
  vim.rpcrequest(child, 'nvim_ui_try_resize', 160, 35)
  input('')
  assert(lua('return vim.api.nvim_win_get_width(_G.panewin)') == 64, 'Adaptive pane did not grow to 40%')
  vim.rpcrequest(child, 'nvim_ui_try_resize', 120, 35)
  input('')
  assert(lua('return vim.api.nvim_win_get_width(_G.panewin)') == 48, 'Adaptive pane did not shrink to 40%')

  lua('assert(require("stringer").show())')
  input('3GJ')
  assert(not lua('return vim.bo.modified'), 'Reordering left an unsaved draft')
  assert(lua('return require("stringer.store").load("ui").marks[1].line') == 2, 'Reorder not persisted')
  assert(lua('return require("stringer.state").active.marks[1].line') == 2, 'Reorder not applied')

  input('3G<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 2, 'Reordered jump failed')
  lua('assert(require("stringer").show())')
  input('q')
  assert(lua('return #vim.api.nvim_list_wins()') == 1, 'Clean pane did not close')
  lua('assert(require("stringer").show())')
  assert(lua('return #vim.api.nvim_list_wins()') == 2, 'Pane did not reopen')

  input('3Gdd')
  assert(lua('return #require("stringer.store").load("ui").marks') == 2, 'Removal not persisted')
  input('u')
  assert(lua('return #require("stringer.state").active.marks') == 3, 'Undo did not restore mark')
  assert(lua('return #require("stringer.store").load("ui").marks') == 3, 'Undo not persisted')
  input('3G<CR>')
  input('3G')
  assert(lua('return require("stringer.state").active.index') == 3, 'Cursor movement did not select nearest mark')

  lua('assert(require("stringer").show())')
  input('3Gs')
  assert(lua('return require("stringer.store").load("ui").marks[1].skipped'), 'Skip not persisted')
  input('H')
  assert(lua('return require("stringer.state").active.row_to_index[3]') == 2, 'Hidden row mapping incorrect')
  input('3GJ')
  assert(lua('return require("stringer.store").load("ui").marks[3].line') == 1, 'Filtered move wrong target')
  input('u')
  input('H')
  input('3G<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 2, 'Explicit skipped jump failed')
  lua('assert(require("stringer").show())')
  input('5Gn')
  input('iFirst note<CR>Second paragraph<Esc>')
  input(':write<CR>')
  assert(lua('return require("stringer.store").load("ui").marks[2].note') == 'First note\nSecond paragraph',
    'Multiline note not persisted')
  input('q')
  assert(lua('return vim.api.nvim_get_current_win() == require("stringer.pane").windows[vim.api.nvim_get_current_tabpage()]'),
    'Note did not return to pane')

  lua([[
    local s = require('stringer')
    assert(s.jump(2))
    vim.wo.number = true
    vim.wo.signcolumn = 'yes:1'
    vim.cmd('redraw')
  ]])
  local gutter_text = lua([[
    local pos = vim.fn.screenpos(_G.codewin, 1, 1)
    local winpos = vim.api.nvim_win_get_position(_G.codewin)
    return vim.fn.screenstring(pos.row, winpos[2] + 1) .. vim.fn.screenstring(pos.row, winpos[2] + 2)
  ]])
  assert(gutter_text == '->', 'Shared source arrow not rendered: ' .. gutter_text)
  lua('assert(require("stringer").show())')
  local note_row = lua('return require("stringer.state").active.ranges[2].location + 1')
  assert(lua([[
    local r = require('stringer.state').active
    local b = require('stringer.pane').buffer(r)
    return vim.api.nvim_buf_get_lines(b, r.ranges[2].location, r.ranges[2].last, false)[1]
  ]]):find('First note', 1, true), 'Active note not expanded')
  input(tostring(note_row) .. 'G<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 1, 'Note row jump targeted wrong mark')
  lua('assert(require("stringer").jump(3))')
  assert(lua('local r = require("stringer.state").active; return r.ranges[2].last == r.ranges[2].location'),
    'Old note section did not collapse')
  lua([[
    assert(require('stringer').jump(2))
    assert(require('stringer').show())
    vim.api.nvim_win_set_width(0, 24)
  ]])
  input('') -- allow resize/layout events to settle
  assert(lua([[
    local r = require('stringer.state').active
    local p = require('stringer.pane')
    local line = vim.api.nvim_buf_get_lines(p.buffer(r), r.ranges[2].location - 1, r.ranges[2].location, false)[1]
    return line:find('code.lua:1', 1, true) ~= nil and vim.fn.strdisplaywidth(line) <= p.width(r)
  ]]), 'Narrow pane hides useful filename ending')
  input(tostring(lua('return require("stringer.state").active.index_to_row[2]')) .. 'G')
  input('n')
  input('A changed<Esc>')
  lua('assert(require("stringer").move_down(2))')
  assert(lua('return not pcall(vim.cmd, "wq")'), 'Stale note save unexpectedly succeeded')
  assert(lua('return vim.bo.modified'), 'Failed note save lost draft')
  lua('vim.cmd("bwipeout!")')

  lua([[
    vim.api.nvim_set_current_win(_G.codewin)
    vim.cmd('enew')
    local file = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      'Error: UI import fixture',
      '    at deepest (' .. file .. ':3:1)',
      '    at entry (' .. file .. ':1:1)',
    })
    vim.cmd('Stringer import imported-ui')
    assert(require('stringer.state').active.name == 'imported-ui')
    assert(require('stringer').show())
  ]], fixture)
  input('3G<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 1, 'Imported entrypoint jump failed')
  input(':Stringer next<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 3, 'Imported downstream jump failed')
  input('ccchanged_location<Esc>')
  assert(lua([[
    local r = require('stringer.state').active
    local p = require('stringer.pane')
    local text = vim.api.nvim_buf_get_lines(p.buffer(r), r.index_to_row[2] - 1, r.index_to_row[2], false)[1]
    return text:find('[changed]', 1, true) ~= nil and text:find('third', 1, true) ~= nil
      and r.marks[2].snapshot == 'third_location'
  ]]), 'Changing source did not preserve and flag the snapshot')
  assert(lua([[
    local r = require('stringer.state').active
    local p = require('stringer.pane')
    local win = p.windows[vim.api.nvim_get_current_tabpage()]
    local badge, source
    for _, span in ipairs(r.spans) do
      if span.row == r.index_to_row[2] then
        if span.group == 'StringerChanged' then badge = span end
        if span.group == 'StringerSource' then source = span end
      end
    end
    if not badge or not source then return false end
    local a = vim.fn.screenpos(win, badge.row, badge.first + 1)
    local b = vim.fn.screenpos(win, source.row, source.first + 1)
    return a.row > 0 and b.row > 0 and vim.fn.screenattr(a.row, a.col) ~= vim.fn.screenattr(b.row, b.col)
  ]]), 'Changed badge is not visually distinct on the active entry')
  lua([[
    assert(require('stringer').show())
    local r = require('stringer.state').active
    vim.api.nvim_win_set_cursor(0, { r.index_to_row[2] + 1, 0 })
  ]])
  input('c')
  assert(lua('return require("stringer.store").load("imported-ui").marks[2].snapshot') == 'changed_location',
    'Capture mapping did not persist current source')
  input('u')
  assert(lua('return require("stringer.state").active.marks[2].snapshot') == 'third_location', 'Snapshot undo failed')
  input(':Stringer copy copied-ui<CR>')
  assert(lua('return require("stringer.state").active.name') == 'imported-ui', 'Copy switched the active path')
  assert(lua('return require("stringer.store").load("copied-ui").marks[2].snapshot') == 'third_location',
    'Copy did not preserve the saved snapshot')

  lua([[
    vim.api.nvim_set_current_win(_G.codewin)
    local marks = {}
    for i = 1, 90 do marks[i] = { file = ..., line = 1, snapshot = 'first_location' } end
    marks[5].note = 'First\nSecond'
    assert(require('stringer.store').create('long-view', marks))
    assert(require('stringer').open('long-view'))
    assert(require('stringer').show())
    local r = require('stringer.state').active
    vim.api.nvim_win_set_cursor(0, { r.index_to_row[30], 0 })
    vim.cmd('normal! zt')
    vim.cmd('normal! 4j')
    vim.cmd('redraw')
    _G.saved_pane_view = vim.fn.winsaveview()
    _G.saved_top_owner = r.row_to_index[_G.saved_pane_view.topline]
    _G.saved_cursor_owner = r.row_to_index[_G.saved_pane_view.lnum]
    _G.long_pane = vim.api.nvim_get_current_win()
  ]], fixture)
  lua('assert(require("stringer").jump(5))')
  input('')
  assert(lua([[
    local r = require('stringer.state').active
    local view = vim.api.nvim_win_call(_G.long_pane, vim.fn.winsaveview)
    return vim.api.nvim_get_current_win() == _G.codewin
      and r.row_to_index[view.topline] == _G.saved_top_owner
      and r.row_to_index[view.lnum] == _G.saved_cursor_owner
  ]]), 'Active-mark change scrolled or focused the pane')
  assert(lua([[
    local p = vim.api.nvim_win_get_position(_G.long_pane)
    local text = ''
    for col = p[2] + 1, p[2] + vim.api.nvim_win_get_width(_G.long_pane) do
      text = text .. vim.fn.screenstring(p[1] + 1, col)
    end
    return text:find('long-view', 1, true) ~= nil
  ]]), 'Codepath name disappeared when the list was scrolled')
end, debug.traceback)

vim.fn.jobstop(child)
vim.fn.delete(root, 'rf')
if not ok then
  print(err)
  vim.cmd('cquit 1')
end
print('UI PASS: adaptive pane, persistent header, downward arrows, status colors, preserved viewport, mark actions and notes')
vim.cmd('qa!')
