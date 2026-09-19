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

  input('2G<CR>')
  assert(lua('return vim.api.nvim_get_current_win() == _G.codewin'), 'Enter did not focus code')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 1, 'Wrong jump line')
  local visible = lua([[
    vim.cmd('redraw')
    local marked = vim.fn.screenpos(_G.panewin, 2, 1)
    local other = vim.fn.screenpos(_G.panewin, 3, 1)
    return {
      vim.fn.screenstring(marked.row, marked.col),
      vim.fn.screenattr(marked.row, marked.col),
      vim.fn.screenattr(other.row, other.col),
    }
  ]])
  assert(visible[1] == '{', 'Pane mark text not rendered')
  assert(visible[2] ~= visible[3], 'Active mark has no visible highlight')

  lua('assert(require("stringer").show())')
  input('2Gddp')
  assert(lua('return vim.bo.modified'), 'Reordering did not modify the pane')
  assert(lua([[
    local p = require('stringer.pane')
    return #vim.api.nvim_buf_get_extmarks(0, p.namespace, 0, -1, {})
  ]]) == 0, 'Dirty pane still highlights a saved index')
  input('q')
  assert(lua('return vim.api.nvim_get_current_win() == _G.panewin'), 'q discarded dirty pane')
  input(':write<CR>')
  assert(not lua('return vim.bo.modified'), 'Write did not save reorder')
  assert(lua('return require("stringer.state").active.marks[1].line') == 2, 'Reorder not applied')

  input('2G<CR>')
  assert(lua('return vim.api.nvim_win_get_cursor(0)[1]') == 2, 'Reordered jump failed')
  lua('assert(require("stringer").show())')
  input('q')
  assert(lua('return #vim.api.nvim_list_wins()') == 1, 'Clean pane did not close')
  lua('assert(require("stringer").show())')
  assert(lua('return #vim.api.nvim_list_wins()') == 2, 'Pane did not reopen')

  input('2Gdd')
  input('u')
  input(':write<CR>')
  assert(lua('return #require("stringer.state").active.marks') == 3, 'Undo did not restore mark')
end, debug.traceback)

vim.fn.jobstop(child)
vim.fn.delete(root, 'rf')
if not ok then
  print(err)
  vim.cmd('cquit 1')
end
print('UI PASS: rendered highlight, pane focus, reorder/save, dirty close, reopen, undo')
vim.cmd('qa!')
