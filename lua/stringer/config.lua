local M = {}

M.options = {
  storage_dir = vim.fn.stdpath('data') .. '/stringer/paths',
  pane_width = 48,
  gutter = true,
  gutter_sign = 'o',
  gutter_note_sign = 'N',
  gutter_priority = 10,
  inline_notes = true,
  symbol_labels = true,
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
  for _, key in ipairs({ 'gutter', 'inline_notes', 'symbol_labels' }) do
    assert(type(options[key]) == 'boolean', 'Stringer: ' .. key .. ' must be a boolean')
  end
  for _, key in ipairs({ 'gutter_sign', 'gutter_note_sign' }) do
    local text = options[key]
    assert(type(text) == 'string' and not text:find('%c') and vim.fn.strdisplaywidth(text) >= 1
      and vim.fn.strdisplaywidth(text) <= 2, 'Stringer: ' .. key .. ' must occupy one or two display cells')
  end
  assert(type(options.gutter_priority) == 'number' and options.gutter_priority >= 0
    and options.gutter_priority % 1 == 0, 'Stringer: gutter_priority must be a nonnegative integer')
  options.storage_dir = vim.fs.normalize(vim.fn.fnamemodify(options.storage_dir, ':p'))
  M.options = options
end

return M
