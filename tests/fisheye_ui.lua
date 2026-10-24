local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = assert((vim.uv or vim.loop).fs_realpath(root))
for i = 1, 9 do
  local lines = {}
  for n = 1, 100 do lines[n] = ('file_%d_line_%d'):format(i, n) end
  vim.fn.writefile(lines, root .. '/file' .. i .. '.lua')
end
local child = vim.fn.jobstart({ vim.v.progpath, '--embed', '-u', 'NONE', '-i', 'NONE' }, { rpc = true })
assert(child > 0)
local function lua(code, ...) return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... }) end
local function input(keys)
  vim.rpcrequest(child, 'nvim_input', keys)
  vim.wait(100)
  lua('vim.cmd("redraw")')
end
local function settle() input('') end
local ok, err = xpcall(function()
  vim.rpcrequest(child, 'nvim_ui_attach', 180, 60, { rgb = true })
  lua([[
    local cwd, root = ...
    vim.opt.runtimepath:prepend(cwd)
    vim.cmd('runtime plugin/stringer.lua')
    vim.o.hidden, vim.o.mouse = true, 'a'
    vim.notify = function(message) _G.last_message = message end
    local s = require('stringer')
    s.setup({ storage_dir = root .. '/paths' })
    local marks = {}
    for i = 1, 9 do marks[i] = { file = root .. '/file' .. i .. '.lua', line = i * 7, note = 'Note #' .. i .. '\nDetails' } end
    local buf = vim.fn.bufadd(marks[1].file)
    vim.fn.bufload(buf); vim.api.nvim_set_current_buf(buf)
    _G.origin_tab, _G.origin_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    _G.original_layout = vim.fn.winlayout()
    assert(require('stringer.store').create('flow', marks))
    assert(s.open('flow')); assert(s.jump(5)); assert(s.fisheye())
  ]], vim.fn.getcwd(), root)
  settle()
  local geometry = lua([[
    local view = require('stringer.fisheye.state').view
    local result = {}
    for _, row in ipairs(view.rows) do
      result[#result + 1] = { index = row.index, height = vim.api.nvim_win_get_height(row.win),
        position = vim.api.nvim_win_get_position(row.win), notes = row.note_win ~= nil,
        note_height = row.note_win and vim.api.nvim_win_get_height(row.note_win) }
    end
    return result
  ]])
  assert(#geometry == 5, vim.inspect(geometry))
  for i, item in ipairs(geometry) do
    assert(item.index == i + 2 and item.notes, vim.inspect(geometry))
    assert(item.height == item.note_height)
    if i > 1 then assert(item.position[1] > geometry[i - 1].position[1]) end
  end
  assert(geometry[3].height > geometry[2].height and geometry[2].height > geometry[1].height, vim.inspect(geometry))
  assert(math.abs(geometry[3].height / geometry[2].height - 1.618) < 0.35, vim.inspect(geometry))
  assert(lua([[
    local view = require('stringer.fisheye.state').view
    local r = view.rows[3]
    local position = vim.fn.screenpos(r.win, r.mark.line, 1)
    local top = vim.api.nvim_win_get_position(r.win)[1]
    return math.abs(position.row - top - vim.api.nvim_win_get_height(r.win) / 2) <= 3
  ]]), 'Main mark is not centered')
  input('jjj')
  assert(lua('return require("stringer.state").active.index') == 5, 'Cursor motion rebuilt the view')

  -- The promotion and insert keys arrive in one batch, not separate requests.
  input('<C-w>kiPROMOTED<Esc>')
  assert(lua('return require("stringer.state").active.index') == 4, 'Keyboard preview promotion failed')
  assert(lua([[
    local view = require('stringer.fisheye.state').view
    return vim.api.nvim_get_current_win() == view.main
      and vim.api.nvim_buf_get_name(0):match('file4.lua$') ~= nil
      and vim.api.nvim_get_current_line():find('PROMOTED', 1, true) ~= nil
  ]]), 'Queued editing input reached the wrong buffer')

  local mouse = lua([[
    local row = require('stringer.fisheye.state').view.rows[1]
    local p = vim.fn.screenpos(row.win, row.mark.line, 1)
    return { row.index, p.row - 1, p.col - 1 }
  ]])
  vim.rpcrequest(child, 'nvim_input_mouse', 'left', 'press', '', 0, mouse[2], mouse[3])
  vim.rpcrequest(child, 'nvim_input_mouse', 'left', 'release', '', 0, mouse[2], mouse[3])
  settle()
  assert(lua('return require("stringer.state").active.index') == mouse[1], 'Mouse preview promotion failed')

  input(':Stringer fisheye-range 4 0<CR>')
  assert(lua([[
    local v = require('stringer.fisheye.state').view
    return v.rows[#v.rows].win == v.main
  ]]), 'Asymmetric main was not at the bottom')
  input(':Stringer fisheye-range 2 2<CR>')
  lua('assert(require("stringer").jump(5))'); settle()
  input(':Stringer fisheye-notes<CR>')
  assert(lua([[
    for _, row in ipairs(require('stringer.fisheye.state').view.rows) do if row.note_win then return false end end
    return true
  ]]), 'Global notes toggle did not hide all panels')
  input(':Stringer fisheye-notes<CR>')

  lua('vim.api.nvim_win_set_width(require("stringer.fisheye.state").view.path_win, 140)')
  settle()
  assert(lua('return require("stringer.fisheye.state").view.notes_suppressed'), 'Wide path pane did not suppress cramped notes')
  lua('vim.api.nvim_win_set_width(require("stringer.fisheye.state").view.path_win, 72)')
  settle()
  assert(lua('return require("stringer.fisheye.state").view.rows[3].note_win ~= nil'), 'Notes did not return after resizing the path pane')

  vim.rpcrequest(child, 'nvim_ui_try_resize', 65, 22); settle()
  assert(lua('return #require("stringer.fisheye.state").view.rows') < 5, 'Small screen did not reduce previews')
  assert(lua('return require("stringer.fisheye.state").settings.notes'), 'Narrow layout changed global note preference')
  vim.rpcrequest(child, 'nvim_ui_try_resize', 180, 60); settle()
  assert(lua('return #require("stringer.fisheye.state").view.rows') == 5, 'Previews did not return after growing screen')
  assert(lua('return require("stringer.fisheye.state").view.rows[3].note_win ~= nil'), 'Notes did not return')

  lua([[
    local s, r = require('stringer'), require('stringer.state').active
    local p = require('stringer.pane')
    vim.api.nvim_set_current_win(require('stringer.fisheye.state').view.path_win)
    vim.api.nvim_win_set_cursor(0, { r.index_to_row[1], 0 })
  ]])
  input('<CR>')
  assert(lua('return require("stringer.state").active.index') == 1)
  assert(lua('return require("stringer.fisheye.state").view.rows[1].index') == 1)
  input(':Stringer prev<CR>')
  assert(lua('return require("stringer.state").active.index') == 9)
  assert(lua('local v = require("stringer.fisheye.state").view; return v.rows[#v.rows].index') == 9)
  input(':Stringer fisheye-close<CR>')
  assert(lua([[
    return vim.api.nvim_get_current_tabpage() == _G.origin_tab
      and vim.api.nvim_get_current_win() == _G.origin_win
      and vim.deep_equal(vim.fn.winlayout(), _G.original_layout)
      and vim.bo[vim.fn.bufnr((... ) .. '/file4.lua')].modified
  ]], root), 'Close lost original layout or edited source')
end, debug.traceback)
vim.fn.jobstop(child)
vim.fn.delete(root, 'rf')
if not ok then print(err); vim.cmd('cquit 1') end
print('FISH-EYE UI PASS: golden geometry, promotion/input, notes, asymmetric layout, resizing, cyclic navigation, cleanup')
vim.cmd('qa!')
