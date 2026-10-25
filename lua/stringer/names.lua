local M = {}
M.error = 'Names must be nonempty, with no surrounding whitespace, path separators, or control characters'

function M.valid(name)
  return type(name) == 'string' and name ~= '' and name ~= '.' and name ~= '..'
    and not name:find('[/\\%c]') and not name:match('^%s') and not name:match('%s$')
end

return M
