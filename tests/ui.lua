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

  input('3G<CR>')
  assert(lua('return vim.api.nvim_get_current_win() == _G.codewin'), 'Enter did not focus code')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 1, 'Wrong jump line')
  local visible = lua([[
    vim.cmd('redraw')
    local marked = vim.fn.screenpos(_G.panewin, 3, 1)
    local other = vim.fn.screenpos(_G.panewin, 4, 1)
    return {
      vim.fn.screenstring(marked.row, marked.col),
      vim.fn.screenattr(marked.row, marked.col),
      vim.fn.screenattr(other.row, other.col),
    }
  ]])
  assert(visible[1] == '1', 'Pane mark text not rendered')
  assert(visible[2] ~= visible[3], 'Active mark has no visible highlight')

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
  input('4Gn')
  input('iFirst note<CR>Second paragraph<Esc>')
  input(':write<CR>')
  assert(lua('return require("stringer.store").load("ui").marks[2].note') == 'First note\nSecond paragraph',
    'Multiline note not persisted')
  input('q')
  assert(lua('return vim.api.nvim_get_current_win() == require("stringer.pane").windows[vim.api.nvim_get_current_tabpage()]'),
    'Note did not return to pane')
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
end, debug.traceback)

vim.fn.jobstop(child)
vim.fn.delete(root, 'rf')
if not ok then
  print(err)
  vim.cmd('cquit 1')
end
print('UI PASS: highlight, proximity, filtered actions, skipped jumps, multiline notes, stale draft recovery, import navigation')
vim.cmd('qa!')
