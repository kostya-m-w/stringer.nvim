vim.opt.runtimepath:prepend(vim.fn.getcwd())
local footer = require('stringer.footer')
local config = require('stringer.config')
local count = 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then print('FAIL ' .. name .. '\n' .. err); vim.cmd('cquit 1') end
  count = count + 1; print('PASS ' .. name)
end

test('compact hints fit every tested width and always retain help', function()
  for width = 1, 120 do
    for _, hidden in ipairs({ false, true }) do
      local result = footer.render(width, hidden)
      assert(vim.fn.strdisplaywidth(result.text) <= width)
      assert(result.text:find('?', 1, true))
      for _, span in ipairs(result.spans) do
        assert(span.first >= 0 and span.last <= #result.text and span.first < span.last)
      end
    end
  end
end)
test('wider hints reflect the skipped-mark toggle and prioritize common actions', function()
  local shown, hidden = footer.render(90, false).text, footer.render(90, true).text
  assert(shown:find('H hide skipped', 1, true)); assert(hidden:find('H show skipped', 1, true))
  local compact = footer.render(48, false).text
  assert(compact:find('Enter jump', 1, true)); assert(compact:find('n note', 1, true))
  assert(compact:find('c capture', 1, true)); assert(compact:find('? help', 1, true))
end)
test('footer configuration validates booleans', function()
  config.setup({ footer = false }); assert(config.options.footer == false)
  assert(not pcall(config.setup, { footer = 'always' }))
  config.setup({ footer = true })
end)
test('native footer restores local statusline on detach and in inherited code splits', function()
  local record = { hide_skipped = false }
  vim.o.laststatus = 2
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = 'stringer'
  vim.wo.statusline = 'user-local-header'
  local win = vim.api.nvim_get_current_win()
  footer.refresh(record, buf, 1)
  local generated = vim.wo.statusline
  assert(generated:find('StringerFooter', 1, true))
  vim.cmd('vsplit')
  local inherited = vim.api.nvim_get_current_win()
  vim.cmd('enew')
  vim.wo.statusline = generated
  footer.restore_inherited(inherited)
  assert(vim.wo.statusline == 'user-local-header')
  footer.detach(win)
  assert(vim.wo[win].statusline == 'user-local-header')
end)
print(count .. ' footer tests passed')
vim.cmd('qa!')
