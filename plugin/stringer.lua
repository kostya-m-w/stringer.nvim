if vim.g.loaded_stringer then
  return
end
vim.g.loaded_stringer = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('Stringer requires Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

local stringer = require('stringer')
local arguments = require('stringer.arguments')
stringer._initialize()
local commands = {
  'new', 'open', 'show', 'add', 'next', 'prev', 'rename', 'remove', 'move-up', 'move-down', 'undo', 'reload',
  'skip', 'hide-skipped', 'note', 'note-discard', 'import', 'import-report', 'cancel-import', 'copy', 'refresh-snapshot',
  'fisheye', 'fisheye-close', 'fisheye-range', 'fisheye-notes', 'fisheye-refresh',
  'directory', 'move',
}
vim.api.nvim_create_user_command('Stringer', function(args)
  local parsed, err = arguments.parse(args.args)
  if not parsed then vim.notify('Stringer: ' .. err, vim.log.levels.ERROR); return end
  local subcommand, name = parsed[1], parsed[2]
  if subcommand == 'fisheye-range' then
    if #parsed ~= 3 then
      vim.notify('Usage: Stringer fisheye-range <previous> <next>', vim.log.levels.ERROR)
    else stringer.fisheye_range(tonumber(parsed[2]), tonumber(parsed[3])) end
    return
  end
  local valid = vim.tbl_contains(commands, subcommand)
  local named = { new = true, open = true, rename = true, import = true, copy = true, directory = true, move = true }
  if not valid or #parsed > 2 or (name and not named[subcommand]) then
    vim.notify('Usage: Stringer new/open/rename/import/copy [name] | ' .. table.concat(commands, ' | '), vim.log.levels.ERROR)
    return
  end
  stringer[(subcommand:gsub('-', '_'))](name)
end, {
  nargs = '+',
  bar = false,
  desc = 'Capture, edit, and navigate ordered codepaths',
  complete = function(lead, line, position)
    return arguments.complete(lead, line, position, commands)
  end,
})
