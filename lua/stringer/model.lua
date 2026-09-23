local codec = require('stringer.codec')
local store = require('stringer.store')
local M = {}

function M.clean(record)
  local buf = record and vim.fn.bufnr(record.file)
  if buf and buf ~= -1 and vim.bo[buf].modified then
    return nil, 'Save or discard edits in the raw codepath file first'
  end
  return true
end

function M.persist(record, marks, index, selected, undoing)
  local ok, err = M.clean(record)
  if not ok then return nil, err end
  local lines = codec.encode(marks)
  local valid, errors = codec.decode(lines)
  if not valid then return nil, codec.error_message(errors) end
  local text = codec.text(lines)
  ok, err = store.write(record.file, text, record.text)
  if not ok then return nil, err end
  record.history = record.history or {}
  if not undoing then
    record.history[#record.history + 1] = { marks = record.marks, index = record.index }
  end
  record.marks, record.text, record.index = marks, text, index
  record.revision = (record.revision or 0) + 1
  require('stringer.pane').refresh(record, selected)
  return true
end

return M
