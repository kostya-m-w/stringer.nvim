if vim.g.loaded_stringer then
  return
end
vim.g.loaded_stringer = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('Stringer requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

local stringer = require('stringer')
stringer._initialize()
local commands = {
  'new', 'open', 'show', 'add', 'next', 'prev', 'rename', 'remove', 'move-up', 'move-down', 'undo', 'reload',
  'skip', 'hide-skipped', 'note', 'import', 'import-report', 'cancel-import',
}
vim.api.nvim_create_user_command('Stringer', function(args)
  local subcommand, name = args.fargs[1], args.fargs[2]
  local valid = vim.tbl_contains(commands, subcommand)
  local named = { new = true, open = true, rename = true, import = true }
  if not valid or #args.fargs > 2 or (name and not named[subcommand]) then
    vim.notify('Usage: Stringer new/open/rename/import [name] | ' .. table.concat(commands, ' | '), vim.log.levels.ERROR)
    return
  end
  stringer[(subcommand:gsub('-', '_'))](name)
end, {
  nargs = '+',
  desc = 'Capture, edit, and navigate ordered codepaths',
  complete = function(lead, line)
    local before = line:match('^%s*Stringer%s+(.*)$') or ''
    local candidates = commands
    if before:match('^open%s+') then
      candidates = require('stringer.store').list() or {}
    elseif before:match('%s') then
      return {}
    end
    return vim.tbl_filter(function(item) return item:sub(1, #lead) == lead end, candidates)
  end,
})
