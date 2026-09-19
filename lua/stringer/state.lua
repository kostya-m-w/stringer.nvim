local M = { active = nil, windows = {} }

function M.commit(record, marks, text)
  if not vim.deep_equal(record.marks, marks) then
    record.index = nil
  end
  record.marks = marks
  record.text = text
end

return M
