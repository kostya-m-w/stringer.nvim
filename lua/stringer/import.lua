local parsers = require('stringer.import.parsers')
local resolver = require('stringer.import.resolve')
local M = {}

local function fail(err)
  vim.notify('Stringer: ' .. err, vim.log.levels.ERROR)
  return nil, err
end

function M.show_report()
  if not M.report then return fail('No import report available') end
  local lines = vim.deepcopy(M.report)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'stringer-import-report://' .. buf)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'stringer-report'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_cmd({ cmd = 'split', mods = { split = 'botright' } }, {})
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(12, #lines))
  vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = buf, desc = 'Close import report' })
  return true
end

function M.cancel()
  if M.pending then M.pending.cancelled = true; M.pending = nil end
  return true
end

function M.start(name, commit)
  M.cancel()
  local source = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
  local root = require('stringer.pane').project_root()
  local formats = parsers.detect(lines)
  if #formats == 0 then return fail('No Ruby, V8 JavaScript/TypeScript, or Java frames found') end
  local token = { cancelled = false }
  M.pending = token
  local function finish_pending()
    if M.pending == token then M.pending = nil end
  end
  local function parse(format)
    if token.cancelled then return end
    if not format then finish_pending(); return end
    local parsed, err = parsers.parse(lines, format)
    if not parsed then finish_pending(); fail(err); return end
    resolver.resolve(parsed, root, token, function(result)
      if token.cancelled then return end
      local count = #result.marks
      local partial = #result.issues > 0
      M.report = { ('Stringer import: %d resolved frames, %d excluded (%s)'):format(count, #result.issues, format),
        'Project root: ' .. root, 'Order: outermost available caller to deepest frame', '' }
      for _, issue in ipairs(result.issues) do
        M.report[#M.report + 1] = ('Source line %d: %s'):format(issue.source_line, issue.reason)
        M.report[#M.report + 1] = '  ' .. vim.fn.strtrans(issue.raw)
        for _, candidate in ipairs(issue.candidates or {}) do M.report[#M.report + 1] = '  candidate: ' .. candidate end
      end
      if count == 0 then
        finish_pending()
        fail('No local source files resolved; no codepath created')
        M.show_report()
        return
      end
      local function save(value)
        if token.cancelled then return end
        finish_pending()
        if not value or value == '' then return end
        local ok, save_err = commit(value, result.marks)
        if not ok then
          M.report[1] = 'Import was not saved: ' .. tostring(save_err)
          return
        end
        local summary = ('Imported %d marks into %s%s'):format(count, value,
          partial and (' (partial: %d frames excluded)'):format(#result.issues) or '')
        M.report[1] = summary
        vim.notify('Stringer: ' .. summary)
        if partial then M.show_report() end
      end
      if name then save(name)
      else vim.ui.input({ prompt = 'Imported codepath name: ' }, save) end
    end)
  end
  if #formats == 1 then parse(formats[1])
  else vim.ui.select(formats, { prompt = 'Stacktrace format:' }, parse) end
  return true -- Parsing/indexing and prompts may finish asynchronously.
end

return M
