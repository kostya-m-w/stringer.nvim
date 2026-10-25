local git = require('stringer.git')
local state = require('stringer.state')
local model = require('stringer.model')
local M = { pending = {} }

function M.cancel()
  if #M.pending > 0 then vim.notify('Stringer: pending mark captures cancelled because the active path changed') end
  for _, job in ipairs(M.pending) do git.cancel(job.token) end
  M.pending = {}
end

local function drain()
  while M.pending[1] and M.pending[1].ready do
    local job = table.remove(M.pending, 1)
    if not job.token.cancelled and state.active == job.record then
      local marks = vim.deepcopy(job.record.marks)
      marks[#marks + 1] = job.mark
      job.ok, job.err = model.persist(job.record, marks, job.record.index)
      job.done = true
      job.complete(job.ok, job.err)
    end
  end
end

function M.add(record, mark, complete)
  local job = { record = record, mark = mark, token = {}, complete = complete }
  M.pending[#M.pending + 1] = job
  git.enrich({ mark }, job.token, function(_, warnings)
    if job.token.cancelled then return end
    for _, warning in ipairs(warnings) do vim.notify('Stringer: ' .. warning, vim.log.levels.WARN) end
    job.ready = true
    drain()
  end)
  if job.done then return job.ok, job.err end
  return true
end

return M
