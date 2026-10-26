local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert((vim.uv or vim.loop).fs_realpath(root))
local file = root .. '/code.lua'
local lines = {}
for i = 1, 100 do lines[i] = 'source_line_' .. i end
vim.fn.writefile(lines, file)
local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '-u', 'NONE', '-i', 'NONE' }, { rpc = true })
assert(child > 0)
local function lua(code, ...) return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... }) end
local function input(keys)
  vim.rpcrequest(child, 'nvim_input', keys)
  vim.wait(80)
  lua('vim.cmd("redraw")')
end
local function rendered_footer()
  return lua([[
    local footer = require('stringer.footer')
    local entry = footer.entries[_G.pane_win]
    if not entry then return { text = 'NO FOOTER' } end
    local position, row, col
    if entry.float then
      position = vim.api.nvim_win_get_position(entry.float)
      row, col = position[1] + 1, position[2] + 1
    else
      position = vim.api.nvim_win_get_position(_G.pane_win)
      local info = vim.fn.getwininfo(_G.pane_win)[1]
      row, col = position[1] + info.height + info.winbar + 1, position[2] + 1
    end
    local text = ''
    for c = col, col + vim.api.nvim_win_get_width(_G.pane_win) - 1 do
      text = text .. vim.fn.screenstring(row, c)
    end
    return { text = text, row = row, col = col, floating = entry.float ~= nil }
  ]])
end

local ok, err = xpcall(function()
  vim.rpcrequest(child, 'nvim_ui_attach', 160, 38, { rgb = true })
  lua([[
    local cwd, root, file = ...
    vim.opt.runtimepath:prepend(cwd)
    vim.cmd('runtime plugin/stringer.lua')
    vim.notify = function(message) _G.last_message = message end
    vim.o.hidden, vim.o.mouse, vim.o.laststatus = true, 'a', 2
    local s = require('stringer')
    s.setup({ storage_dir = root .. '/paths', pane_width = 76 })
    local buf = vim.fn.bufadd(file); vim.fn.bufload(buf); vim.api.nvim_set_current_buf(buf)
    _G.code_win = vim.api.nvim_get_current_win()
    local marks = {}
    for i = 1, 80 do marks[i] = { file = file, line = i, snapshot = 'source_line_' .. i } end
    marks[80].note = 'Final note\nLast note line'
    assert(require('stringer.store').create('footer-test', marks))
    assert(s.open('footer-test')); assert(s.show())
    _G.pane_win = vim.api.nvim_get_current_win()
  ]], vim.fn.getcwd(), root, file)
  input('')
  local first = rendered_footer()
  assert(first.text:find('Enter jump', 1, true) and first.text:find('? help', 1, true), vim.inspect(first))
  assert(not first.floating, 'Expected a native per-window statusline')
  input('H')
  assert(rendered_footer().text:find('show skipped', 1, true), 'Visibility hint did not update')
  input('H')
  lua('assert(require("stringer").jump(80)); assert(require("stringer").show())')
  for _, mode in ipairs({ 2, 1, 3, 0 }) do
    lua('vim.o.laststatus = ...', mode)
    input('G')
    local footer = rendered_footer()
    assert(footer.text:find('? help', 1, true), vim.inspect(footer))
    assert(lua('local row, col = ...; return vim.fn.screenattr(row, col) ~= vim.fn.screenattr(row, col + 6)',
      footer.row, footer.col), 'Footer keys and action labels have the same style')
    assert(lua([[
      local r = require('stringer.state').active
      local p = vim.fn.screenpos(_G.pane_win, r.ranges[80].last, 1)
      return p.row > 0 and p.row < (...)
    ]], footer.row), 'Final note is covered by footer in mode ' .. mode .. ': ' .. vim.inspect(footer))
    assert(lua('return require("stringer.pane").selected(require("stringer.state").active)') == 80,
      'EOF padding became a selected mark')
    lua('vim.api.nvim_set_current_win(_G.code_win)')
    input('')
    assert(rendered_footer().text:find('? help', 1, true), 'Footer vanished when code gained focus')
    assert(lua('return vim.api.nvim_get_current_win() == _G.code_win'), 'Footer took focus')
    assert(lua('return vim.o.laststatus') == mode, 'Footer changed global statusline setting')
    lua('vim.api.nvim_set_current_win(_G.pane_win)')
  end

  lua('vim.api.nvim_win_set_width(_G.pane_win, 20)')
  input('')
  assert(rendered_footer().text:find('? help', 1, true), 'Narrow footer lost help')
  lua('vim.api.nvim_win_set_width(_G.pane_win, 76)')
  input('')
  local laststatus = lua('return vim.o.laststatus')
  input('q')
  input('')
  assert(lua([[
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'stringer-footer' then return false end
    end
    return true
  ]]), 'Closing pane leaked a footer window')

  lua('assert(require("stringer").show()); _G.pane_win = vim.api.nvim_get_current_win()')
  input('')
  assert(rendered_footer().text:find('? help', 1, true))
  lua('require("stringer").setup({footer=false})')
  input('')
  assert(lua('return require("stringer.footer").entries[_G.pane_win] == nil'), 'Disabled footer remains attached')
  assert(lua('return vim.o.laststatus') == laststatus)
  lua('require("stringer").setup({footer=true}); vim.o.laststatus=3; vim.cmd("tabnew"); assert(require("stringer").show()); _G.second_pane=vim.api.nvim_get_current_win()')
  input('')
  assert(lua([[
    local f = require('stringer.footer')
    local a, b = f.entries[_G.pane_win], f.entries[_G.second_pane]
    return a and b and a.float and b.float
      and vim.api.nvim_win_get_tabpage(a.float) == vim.api.nvim_win_get_tabpage(_G.pane_win)
      and vim.api.nvim_win_get_tabpage(b.float) == vim.api.nvim_win_get_tabpage(_G.second_pane)
  ]]), 'Shared panes have footer windows in the wrong tabs')
  lua('vim.cmd("close")')
  input('')
  assert(lua('local e = require("stringer.footer").entries[_G.pane_win]; return e and vim.api.nvim_win_is_valid(e.float)'),
    'Closing one pane removed another footer')

  lua('assert(require("stringer").fisheye()); _G.pane_win = require("stringer.fisheye.state").view.path_win')
  input('')
  assert(rendered_footer().text:find('? help', 1, true), 'Fish-eye footer is missing')
  lua('assert(require("stringer").next())')
  input('')
  assert(rendered_footer().text:find('? help', 1, true), 'Fish-eye rebuild lost footer')
  assert(lua('return vim.api.nvim_get_current_win() == require("stringer.fisheye.state").view.main'))
  lua('assert(require("stringer").fisheye_close())')
  input('')
  lua('vim.o.laststatus = 1; assert(require("stringer").show()); _G.pane_win = vim.api.nvim_get_current_win(); vim.cmd("only")')
  input('G')
  assert(rendered_footer().floating and rendered_footer().text:find('? help', 1, true), 'Single-window laststatus=1 footer is missing')
end, debug.traceback)

vim.fn.jobstop(child)
vim.fn.delete(root, 'rf')
if not ok then print(err); vim.cmd('cquit 1') end
print('FOOTER UI PASS: persistent hints, statusline modes, final notes, focus, resizing, cleanup, tabs and fish-eye')
vim.cmd('qa!')
