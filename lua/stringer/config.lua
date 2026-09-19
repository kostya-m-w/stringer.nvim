local M = {}

M.options = {
  storage_dir = vim.fn.stdpath('data') .. '/stringer/paths',
  pane_width = 48,
}

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == 'table', 'Stringer: setup expects a table')
  for key in pairs(opts) do
    assert(M.options[key] ~= nil, 'Stringer: unknown option ' .. tostring(key))
  end
  local options = vim.tbl_extend('force', M.options, opts)
  assert(type(options.storage_dir) == 'string' and options.storage_dir ~= '', 'Stringer: storage_dir must be a nonempty string')
  assert(type(options.pane_width) == 'number' and options.pane_width >= 1 and options.pane_width % 1 == 0,
    'Stringer: pane_width must be a positive integer')
  options.storage_dir = vim.fs.normalize(vim.fn.fnamemodify(options.storage_dir, ':p'))
  M.options = options
end

return M
