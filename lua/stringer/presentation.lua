local state = require('stringer.state')
local pane = require('stringer.pane')
local labels = require('stringer.labels')
local gutter = require('stringer.gutter')
local M = { watched = {}, pending = {}, rendering = false }

local function relevant(record, buf)
  if not record or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return false end
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  for _, mark in ipairs(record.marks) do if vim.fs.normalize(mark.file) == file then return true end end
  return false
end

function M.labels(buf, record)
  if not relevant(record, buf) then return end
  labels.request(buf, function()
    if relevant(state.active, buf) then M.queue_pane(state.active) end
  end)
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
  labels.invalidate(buf)
  if M.pending[buf] then return end
  M.pending[buf] = true
  vim.schedule(function()
    M.pending[buf] = nil
    local record = state.active
    if not vim.api.nvim_buf_is_loaded(buf) then return end
    gutter.refresh(record, buf)
    if relevant(record, buf) then
      M.labels(buf, record)
      M.queue_pane(record)
    end
  end)
end

function M.watch(buf)
  if M.watched[buf] or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return end
  M.watched[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function() M.changed(buf) end,
    on_reload = function() M.changed(buf) end,
    on_detach = function()
      M.watched[buf], M.pending[buf] = nil, nil
      labels.invalidate(buf)
      gutter.buffers[buf] = nil
    end,
  })
end

function M.refresh(record, selected)
  if M.rendering then return end
  M.rendering = true
  pane.refresh(record, selected)
  gutter.refresh(state.active)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if relevant(record, buf) then M.watch(buf); M.labels(buf, record) end
  end
  M.rendering = false
end

function M.enter(buf)
  if relevant(state.active, buf) then
    M.watch(buf)
    gutter.refresh(state.active, buf)
    M.labels(buf, state.active)
  elseif vim.api.nvim_buf_is_loaded(buf) then
    gutter.clear(buf)
  end
end

return M
