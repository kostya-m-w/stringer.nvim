local state = require('stringer.state')
local pane = require('stringer.pane')
local source = require('stringer.source')
local gutter = require('stringer.gutter')
local M = { watched = {}, pending = {}, rendering = false }

local function relevant(record, buf)
  if not record or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return false end
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  for _, mark in ipairs(record.marks) do if vim.fs.normalize(mark.file) == file then return true end end
  return false
end

function M.sources(record, force, retried)
  if not record then return end
  local revision = record.revision or 0
  source.read_marks(record.marks, function(values)
    if state.active ~= record or (record.revision or 0) ~= revision then return end
    local stale = false
    for _, lines in pairs(values) do
      for _, value in pairs(lines) do if value.status == 'stale' then stale = true end end
    end
    if stale and not retried then
      vim.schedule(function()
        if state.active == record then M.sources(record, false, true) end
      end)
    end
    M.queue_pane(record)
  end, { force = force })
end

function M.queue_pane(record)
  if not record then return end
  M.pane_pending = record
  if M.pane_scheduled then return end
  M.pane_scheduled = true
  vim.schedule(function()
    local requested = M.pane_pending
    M.pane_scheduled, M.pane_pending = false, nil
    if state.active == requested then pane.refresh(requested) end
  end)
end

function M.changed(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  source.invalidate(vim.api.nvim_buf_get_name(buf))
  if M.pending[buf] then return end
  M.pending[buf] = true
  vim.schedule(function()
    M.pending[buf] = nil
    local record = state.active
    if not vim.api.nvim_buf_is_loaded(buf) then return end
    gutter.refresh(record, buf)
    if relevant(record, buf) then
      M.sources(record)
      M.queue_pane(record)
    end
  end)
end

function M.watch(buf)
  if M.watched[buf] or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return end
  local file = vim.api.nvim_buf_get_name(buf)
  M.watched[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function() M.changed(buf) end,
    on_reload = function() M.changed(buf) end,
    on_detach = function()
      M.watched[buf], M.pending[buf] = nil, nil
      source.invalidate(file)
      gutter.buffers[buf] = nil
      vim.schedule(function() if state.active then M.sources(state.active) end end)
    end,
  })
end

function M.refresh(record, selected)
  if M.rendering then return end
  M.rendering = true
  M.sources(record)
  pane.refresh(record, selected)
  gutter.refresh(state.active)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if relevant(record, buf) then M.watch(buf) end
  end
  M.rendering = false
end

function M.enter(buf)
  if relevant(state.active, buf) then
    M.watch(buf)
    gutter.refresh(state.active, buf)
    M.sources(state.active)
  elseif vim.api.nvim_buf_is_loaded(buf) then
    gutter.clear(buf)
  end
end

return M
