local config = require('stringer.config')
local M = { cache = {} }
local modern_clients = vim.fn.has('nvim-0.11') == 1

local function invoke(client, method, ...)
  if modern_clients then return client[method](client, ...) end
  return client[method](...)
end

function M.frame(text)
  if not text then return end
  local ruby = text:match([[:in%s+[`'"](.-)['"]%s*$]])
  if ruby and ruby ~= '' then return ruby end
  local java = text:match('^at%s+(.+)%([^()]+%.java:%d+%)$')
  if java then return java:gsub('^.*/', '') end
  local js = text:match('^at%s+(.+)%s+%(.+:%d+:%d+%)$')
  if js then return js end
end

-- Hierarchical DocumentSymbol ranges describe scope. Flat SymbolInformation
-- locations generally describe declarations only, so intentionally ignore them.
function M.enclosing(symbols, line)
  local best, best_span, best_depth
  local function visit(items, parents, depth)
    for _, symbol in ipairs(items or {}) do
      local range = symbol.range
      local contains = range and range.start and range['end']
        and line >= range.start.line
        and (line < range['end'].line or (line == range['end'].line and range['end'].character > 0))
      if contains and type(symbol.name) == 'string' then
        local path = vim.deepcopy(parents)
        if symbol.kind == 5 or symbol.kind == 2 or symbol.kind == 3 then path[#path + 1] = symbol.name end
        if symbol.kind == 6 or symbol.kind == 9 or symbol.kind == 12 then
          local span = range['end'].line - range.start.line
          if not best or span < best_span or (span == best_span and depth > best_depth) then
            local label = vim.deepcopy(parents)
            label[#label + 1] = symbol.name
            best, best_span, best_depth = table.concat(label, '.'), span, depth
          end
        end
        visit(symbol.children, path, depth + 1)
      end
    end
  end
  visit(symbols, {}, 0)
  return best
end

function M.invalidate(buf)
  M.cache[buf] = nil
end

function M.request(buf, changed)
  if not config.options.symbol_labels or not vim.api.nvim_buf_is_loaded(buf) then return end
  local clients = vim.lsp.get_clients({ bufnr = buf })
  table.sort(clients, function(a, b) return a.id < b.id end)
  local capable = {}
  for _, client in ipairs(clients) do
    local ok, supported = pcall(invoke, client, 'supports_method', 'textDocument/documentSymbol',
      modern_clients and buf or { bufnr = buf })
    if ok and supported then capable[#capable + 1] = client end
  end
  local ids = {}
  for _, client in ipairs(capable) do ids[#ids + 1] = client.id end
  local identity = table.concat(ids, ',')
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local old = M.cache[buf]
  if old and old.tick == tick and old.identity == identity then return end
  local entry = { tick = tick, identity = identity, results = {} }
  M.cache[buf] = entry
  for _, client in ipairs(capable) do
    pcall(invoke, client, 'request', 'textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(buf) } },
      function(err, result)
        if M.cache[buf] ~= entry or not vim.api.nvim_buf_is_loaded(buf)
          or vim.api.nvim_buf_get_changedtick(buf) ~= tick then return end
        if not err and type(result) == 'table' then entry.results[client.id] = result end
        changed()
      end, buf)
  end
end

function M.title(mark)
  if config.options.symbol_labels then
    local frame = M.frame(mark.frame)
    if frame then return frame end
    local buf = vim.fn.bufnr(mark.file)
    local entry = M.cache[buf]
    if entry and vim.api.nvim_buf_is_loaded(buf) and entry.tick == vim.api.nvim_buf_get_changedtick(buf) then
      local ids = vim.tbl_keys(entry.results)
      table.sort(ids)
      for _, id in ipairs(ids) do
        local title = M.enclosing(entry.results[id], mark.line - 1)
        if title then return title end
      end
    end
  end
  return vim.fs.basename(mark.file)
end

return M
