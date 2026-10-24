local uv = vim.uv or vim.loop
local config = require('stringer.config')
local geometry = require('stringer.fisheye.plan')
local M = {}

local function valid(win) return win and vim.api.nvim_win_is_valid(win) end

function M.resolve(mark)
  if not mark then return nil, 'No enabled marks. Select a mark in the path pane or add one.' end
  local stat = uv.fs_stat(mark.file)
  if not stat or stat.type ~= 'file' then return nil, 'Source file is missing or not a file' end
  if not uv.fs_access(mark.file, 'R') then return nil, 'Source file is unreadable' end
  local ok, buf = pcall(function()
    local target = vim.fn.bufadd(mark.file)
    vim.fn.bufload(target)
    if not vim.api.nvim_buf_is_loaded(target) then error('Could not load source') end
    return target
  end)
  if not ok then return nil, tostring(buf) end
  if mark.line > vim.api.nvim_buf_line_count(buf) then return nil, 'Stored line is past the end of the source buffer' end
  return buf
end

function M.targets(record, descriptors)
  local targets = {}
  for _, descriptor in ipairs(descriptors) do
    local row = vim.deepcopy(descriptor)
    row.mark = row.index and record.marks[row.index] or nil
    row.buf, row.problem = M.resolve(row.mark)
    targets[#targets + 1] = row
  end
  return targets
end

function M.preflight(view, targets, closing)
  local needed, owned = {}, {}
  for _, row in ipairs(targets) do if row.buf then needed[row.buf] = true end end
  for _, row in ipairs(view.rows or {}) do if valid(row.win) then owned[row.win] = true end end
  if closing then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(view.tab)) do owned[win] = true end
  end
  for win in pairs(owned) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].modified and not needed[buf] and not (view.owned_buffers or {})[buf] then
      local elsewhere = false
      for _, other in ipairs(vim.fn.win_findbuf(buf)) do if not owned[other] then elsewhere = true end end
      local destructive = vim.tbl_contains({ 'wipe', 'delete', 'unload' }, vim.bo[buf].bufhidden)
      if not elsewhere and (not vim.o.hidden or destructive) then
        return nil, 'Save modified buffer before rebuilding/closing fish-eye, or use a nondestructive hidden-buffer policy: '
          .. vim.api.nvim_buf_get_name(buf)
      end
    end
  end
  return true
end

local function scratch(view, lines, kind)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'stringer-fisheye-' .. kind .. '://' .. buf)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'stringer-fisheye-' .. kind
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  view.owned_buffers[buf] = true
  return buf
end

function M.clear_match(row)
  if row.match and valid(row.win) then pcall(vim.fn.matchdelete, row.match, row.win) end
  row.match = nil
end

function M.mark_line(row, center)
  M.clear_match(row)
  if not row.mark or row.problem or not valid(row.win) then return end
  local buf = vim.api.nvim_win_get_buf(row.win)
  vim.wo[row.win].winbar = vim.wo[row.win].winbar:gsub(' %[line past EOF%]$', '')
  if row.mark.line > vim.api.nvim_buf_line_count(buf) then
    vim.wo[row.win].winbar = vim.wo[row.win].winbar .. ' [line past EOF]'
    return
  end
  vim.api.nvim_win_call(row.win, function()
    row.match = vim.fn.matchaddpos('StringerFishLine', { row.mark.line }, 90)
    if center then
      vim.api.nvim_win_set_cursor(row.win, { row.mark.line, 0 })
      vim.cmd('normal! zvzz')
    end
  end)
end

local function title(row)
  if not row.mark then return 'No enabled marks' end
  return ('#%d %s:%d%s'):format(row.index, vim.fn.strtrans(vim.fs.basename(row.mark.file)), row.mark.line,
    row.problem and ' [unavailable]' or '')
end

function M.cleanup_buffers(view)
  for buf in pairs(view.owned_buffers) do
    if not vim.api.nvim_buf_is_valid(buf) then view.owned_buffers[buf] = nil
    elseif #vim.fn.win_findbuf(buf) == 0 and not vim.bo[buf].modified then
      vim.api.nvim_buf_delete(buf, { force = false })
      view.owned_buffers[buf] = nil
    end
  end
end

function M.render(view, targets, settings, options)
  options = options or {}
  local created, used, old_rows, main, roles = {}, {}, view.rows or {}, nil, {}
  local old_focus = vim.api.nvim_get_current_win()
  local saved_main
  if options.preserve and valid(view.main) then
    saved_main = { buf = vim.api.nvim_win_get_buf(view.main), view = vim.api.nvim_win_call(view.main, vim.fn.winsaveview) }
  end
  local ok, err = xpcall(function()
    -- Prepare all destination windows before closing any old source window.
    for _, row in ipairs(targets) do
      if not row.buf then
        local lines = { title(row), '', row.problem }
        if row.mark then
          lines[#lines + 1] = vim.fn.strtrans(row.mark.file)
          if row.mark.snapshot ~= nil then lines[#lines + 1] = 'Captured: ' .. vim.fn.strtrans(row.mark.snapshot) end
        end
        for _, old in ipairs(old_rows) do
          if old.problem == row.problem and old.index == row.index and view.owned_buffers[old.buf]
            and vim.api.nvim_buf_is_valid(old.buf) then
            row.buf = old.buf
            vim.bo[row.buf].modifiable = true
            vim.api.nvim_buf_set_lines(row.buf, 0, -1, false, lines)
            vim.bo[row.buf].modifiable = false
            break
          end
        end
        if not row.buf then row.buf = scratch(view, lines, 'placeholder') end
      end
      if row.distance == 0 and valid(options.keep_win) and vim.api.nvim_win_get_buf(options.keep_win) == row.buf then
        row.win = options.keep_win
      end
      for _, previous in ipairs(old_rows) do
        if not row.win and valid(previous.win) and not used[previous.win]
          and previous.index == row.index and vim.api.nvim_win_get_buf(previous.win) == row.buf then row.win = previous.win end
      end
      if not row.win then
        local anchor = valid(view.main) and view.main or view.path_win
        row.win = vim.api.nvim_open_win(row.buf, false, { win = anchor,
          split = anchor == view.path_win and 'left' or 'below' })
        created[#created + 1] = row.win
      end
      used[row.win] = true
      if row.distance == 0 then main = row.win end
    end
    for _, old in ipairs(old_rows) do
      M.clear_match(old)
      if valid(old.note_win) then vim.api.nvim_win_close(old.note_win, false) end
    end
    -- Keep a destination focused so retiring a former main window is harmless.
    if not used[old_focus] and old_focus ~= view.path_win then vim.api.nvim_set_current_win(main) end
    for _, old in ipairs(old_rows) do
      if valid(old.win) and not used[old.win] then vim.api.nvim_win_close(old.win, false) end
    end
    for i = 2, #targets do
      local result = vim.fn.win_splitmove(targets[i].win, targets[i - 1].win, { vertical = false, rightbelow = true })
      if result ~= 0 then error('Could not arrange fish-eye windows') end
    end
    local stack_width = vim.api.nvim_win_get_width(main)
    local configured = config.options.fisheye_note_width
    local note_width = type(configured) == 'string' and math.floor(stack_width * tonumber(configured:sub(1, -2)) / 100)
      or configured
    local code_min, note_min = math.max(24, vim.o.winminwidth), math.max(16, vim.o.winminwidth)
    note_width = math.max(note_min, math.min(note_width, stack_width - code_min - 1))
    view.notes_suppressed = settings.notes and stack_width < code_min + note_min + 1
    for _, row in ipairs(targets) do
      for key, value in pairs(view.code_options) do vim.wo[row.win][key] = value end
      vim.wo[row.win].winfixheight = true
      vim.wo[row.win].winfixwidth = false
      if row.distance ~= 0 then vim.wo[row.win].cursorline = false end
      local label = (row.distance == 0 and 'MAIN ' or 'Preview ') .. title(row)
      if view.notes_suppressed and row.mark and row.mark.note then label = label .. ' [notes: narrow]' end
      vim.wo[row.win].winbar = '%#' .. (row.distance == 0 and 'StringerFishMain' or 'StringerFishPreview')
        .. '# ' .. label:gsub('%%', '%%%%')
      roles[row.win] = { kind = row.distance == 0 and 'main' or 'preview', index = row.index, buf = row.buf }
      if settings.notes and not view.notes_suppressed and row.mark and row.mark.note then
        row.note_buf = scratch(view, vim.split(row.mark.note, '\n', { plain = true }), 'notes')
        row.note_win = vim.api.nvim_open_win(row.note_buf, false, { win = row.win, split = 'right' })
        created[#created + 1] = row.note_win
        vim.api.nvim_win_set_width(row.note_win, note_width)
        vim.wo[row.note_win].wrap = true
        vim.wo[row.note_win].number = false
        vim.wo[row.note_win].relativenumber = false
        vim.wo[row.note_win].signcolumn = 'no'
        vim.wo[row.note_win].winfixheight = true
        vim.wo[row.note_win].winbar = '%#StringerFishPreview# Notes · #' .. row.index
        roles[row.note_win] = { kind = 'notes', index = row.index, buf = row.note_buf }
        vim.keymap.set('n', '<CR>', function() require('stringer').jump(row.index) end, { buffer = row.note_buf })
        vim.keymap.set('n', 'n', function() require('stringer').note(row.index) end, { buffer = row.note_buf })
      end
    end
    local total = 0
    for _, row in ipairs(targets) do total = total + vim.api.nvim_win_get_height(row.win) end
    local heights = geometry.heights(targets, total, vim.o.winminheight)
    for _ = 1, 2 do
      for i, row in ipairs(targets) do vim.api.nvim_win_set_height(row.win, heights[i]) end
    end
    for _, row in ipairs(targets) do
      local preserve = row.distance == 0 and saved_main and saved_main.buf == row.buf
      M.mark_line(row, not preserve)
      if preserve then vim.api.nvim_win_call(row.win, function() vim.fn.winrestview(saved_main.view) end) end
    end
    if options.focus or not valid(old_focus) then vim.api.nvim_set_current_win(main)
    elseif valid(old_focus) then vim.api.nvim_set_current_win(old_focus) end
  end, debug.traceback)
  if not ok then
    for _, win in ipairs(created) do if valid(win) then pcall(vim.api.nvim_win_close, win, false) end end
    M.cleanup_buffers(view)
    return nil, err
  end
  view.rows, view.main, view.roles = targets, main, roles
  M.cleanup_buffers(view)
  return true
end

return M
