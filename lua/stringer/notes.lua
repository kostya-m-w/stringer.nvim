local model = require('stringer.model')
local state = require('stringer.state')
local M = {}

function M.save()
  local editor = M.editor
  if not editor or not vim.api.nvim_buf_is_valid(editor.buf) then return nil, 'No note editor' end
  local record = editor.record
  if state.active ~= record or (record.revision or 0) ~= editor.revision then
    return nil, 'Marks changed while editing this note; copy the draft and reopen the note before saving'
  end
  local note = table.concat(vim.api.nvim_buf_get_lines(editor.buf, 0, -1, false), '\n')
  local marks = vim.deepcopy(record.marks)
  marks[editor.index].note = note ~= '' and note or nil
  if marks[editor.index].note == record.marks[editor.index].note then
    vim.bo[editor.buf].modified = false
    return true
  end
  local ok, err = model.persist(record, marks, record.index)
  if not ok then return nil, err end
  editor.revision = record.revision
  vim.bo[editor.buf].modified = false
  return true
end

function M.open(record, index)
  local editor = M.editor
  if editor and vim.api.nvim_buf_is_valid(editor.buf) then
    local same = editor.record == record and editor.index == index
      and editor.revision == (record.revision or 0)
    if not same and vim.bo[editor.buf].modified then
      return nil, 'Save or discard the open note draft before editing another mark'
    end
    if same then
      if editor.win and vim.api.nvim_win_is_valid(editor.win) then
        vim.api.nvim_set_current_win(editor.win)
        return true
      end
    else
      vim.api.nvim_buf_delete(editor.buf, { force = true })
      editor = nil
    end
  else
    editor = nil
  end
  if not editor then
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, 'stringer-note://' .. buf)
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(record.marks[index].note or '', '\n', { plain = true }))
    vim.bo[buf].modified = false
    editor = { buf = buf, record = record, index = index, revision = record.revision or 0 }
    M.editor = editor
    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = buf,
      callback = function()
        local ok, err = M.save()
        if not ok then error('Stringer: ' .. err, 0) end
      end,
    })
    vim.keymap.set('n', 'q', function()
      if vim.bo[buf].modified then
        vim.notify('Stringer: save the note with :write or discard it with :bwipeout!', vim.log.levels.ERROR)
      else
        vim.cmd.close()
      end
    end, { buffer = buf, desc = 'Close saved note' })
  end
  local width = math.max(1, math.min(80, vim.o.columns - 4))
  local height = math.max(1, math.min(16, vim.o.lines - 6))
  local origin = vim.api.nvim_get_current_win()
  editor.win = vim.api.nvim_open_win(editor.buf, true, {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal', border = 'rounded', title = ' Stringer note — :write to save ',
  })
  local note_win = editor.win
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(note_win), once = true,
    callback = function()
      vim.schedule(function()
        if editor.win == note_win and vim.api.nvim_win_is_valid(origin) then
          vim.api.nvim_set_current_win(origin)
        end
      end)
    end,
  })
  vim.wo[editor.win].wrap = true
  return true
end

return M
