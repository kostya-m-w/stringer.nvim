local M = {}

function M.setup()
  local function get(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local function set(name, options)
    options.default = true
    vim.api.nvim_set_hl(0, name, options)
  end
  local normal, visual, bar = get('Normal'), get('Visual'), get('WinBar')
  local dark = vim.o.background == 'dark'
  local active_bg = visual.bg or get('CursorLine').bg or (dark and '#303847' or '#e4e9f2')
  local header_bg = bar.bg or get('StatusLine').bg or (dark and '#253042' or '#dce4f0')
  local title_fg = get('Title').fg or (dark and '#e5c07b' or '#805500')
  -- Active highlighting only supplies a background, leaving status colors intact.
  set('StringerActive', { bg = active_bg, ctermbg = visual.ctermbg or (dark and 237 or 254) })
  set('StringerHeader', { bg = header_bg, fg = normal.fg, bold = true })
  set('StringerHeaderName', { bg = header_bg, fg = title_fg, bold = true })
  set('StringerHeaderInfo', { bg = header_bg, fg = normal.fg })
  set('StringerHeaderCount', { bg = header_bg, fg = title_fg, bold = true })
  set('StringerSource', { fg = normal.fg })
  local links = {
    StringerEntryArrow = 'Special', StringerMarkNumber = 'LineNr', StringerHelp = 'Comment',
    StringerLocation = 'Comment', StringerLineNumber = 'Number', StringerSkipped = 'Comment',
    StringerNote = 'Comment', StringerNoteBadge = 'Special', StringerChanged = 'DiagnosticWarn',
    StringerMissing = 'DiagnosticError', StringerUnreadable = 'DiagnosticError',
    StringerUncaptured = 'DiagnosticInfo', StringerChecking = 'Comment',
  }
  for name, target in pairs(links) do set(name, { link = target }) end
  set('StringerGutter', { fg = '#e5c07b', ctermfg = 3 })
  set('StringerGutterActive', { fg = '#e5c07b', ctermfg = 3, bold = true })
  set('StringerGutterSkipped', { fg = '#a08040', ctermfg = 3 })
end

return M
