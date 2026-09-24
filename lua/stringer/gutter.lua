local config = require('stringer.config')
local M = { namespace = vim.api.nvim_create_namespace('stringer.gutter'), buffers = {} }

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, M.namespace, 0, -1) end
  M.buffers[buf] = nil
end

function M.groups(record, file)
  local groups = {}
  for index, mark in ipairs(record.marks) do
    if vim.fs.normalize(mark.file) == file then
      local group = groups[mark.line] or { skipped = true }
      group.note = group.note or (mark.note ~= nil and mark.note ~= '')
      group.skipped = group.skipped and mark.skipped == true
      group.active = group.active or index == record.index
      groups[mark.line] = group
    end
  end
  return groups
end

function M.refresh(record, only_buf)
  if not record or not config.options.gutter then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then M.clear(buf) end
    end
    return
  end
  local buffers = only_buf and { only_buf } or vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_loaded(buf) then
      -- Extmarks can survive unload/reload even though attachment tracking is
      -- reset. Always reconcile our namespace, not only tracked buffers.
      M.clear(buf)
      if vim.bo[buf].buftype == '' then
        local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
        local groups = M.groups(record, file)
        for line, group in pairs(groups) do
          if line <= vim.api.nvim_buf_line_count(buf) then
            local hl = group.active and 'StringerGutterActive'
              or (group.skipped and 'StringerGutterSkipped' or 'StringerGutter')
            vim.api.nvim_buf_set_extmark(buf, M.namespace, line - 1, 0, {
              sign_text = group.note and config.options.gutter_note_sign or config.options.gutter_sign,
              sign_hl_group = hl, priority = config.options.gutter_priority,
            })
            M.buffers[buf] = true
          end
        end
      end
    else
      M.buffers[buf] = nil
    end
  end
end

return M
