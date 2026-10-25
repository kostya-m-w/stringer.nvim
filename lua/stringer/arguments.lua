local M = {}

function M.tokens(text, partial)
  local tokens, i = {}, 1
  while i <= #text do
    while text:sub(i, i):match('%s') do i = i + 1 end
    if i > #text then break end
    local start, quote, value, closed = i, nil, '', false
    local first = text:sub(i, i)
    if first == '"' or first == "'" then quote = first; i = i + 1 end
    while i <= #text do
      local char = text:sub(i, i)
      if quote then
        if char == quote then closed = true; i = i + 1; break end
        local following = text:sub(i + 1, i + 1)
        if char == '\\' and (following == quote or following == '\\') then
          value, i = value .. following, i + 2
        else value, i = value .. char, i + 1 end
      else
        if char:match('%s') then break end
        if char == '"' or char == "'" then return nil, 'Quote the whole argument, not a fragment' end
        value, i = value .. char, i + 1
      end
    end
    if quote and not closed and not partial then return nil, 'Unterminated quoted argument' end
    if closed and i <= #text and not text:sub(i, i):match('%s') then return nil, 'Expected whitespace after closing quote' end
    tokens[#tokens + 1] = { value = value, start = start, quote = quote, closed = closed }
  end
  if partial and (#tokens == 0 or (text:match('%s$') and (not tokens[#tokens].quote or tokens[#tokens].closed))) then
    tokens[#tokens + 1] = { value = '', start = #text + 1 }
  end
  return tokens
end

function M.parse(text)
  local tokens, err = M.tokens(text)
  if not tokens then return nil, err end
  return vim.tbl_map(function(token) return token.value end, tokens)
end

function M.quote(text, quote)
  if not quote and not text:find('[%s\'"]') then return text end
  quote = quote or '"'
  return quote .. text:gsub('\\', '\\\\'):gsub(quote, '\\' .. quote) .. quote
end

function M.complete(lead, line, position, commands)
  local before = line:sub(1, position)
  local start = before:match('Stringer%s+()')
  if not start then return commands end
  local tokens = M.tokens(before:sub(start), true)
  if not tokens then return {} end
  local token = tokens[#tokens]
  local candidates
  if #tokens == 1 then candidates = commands
  elseif #tokens == 2 and tokens[1].value == 'open' then
    candidates = require('stringer.store').list() or {}
  elseif #tokens == 2 and (tokens[1].value == 'directory' or tokens[1].value == 'move') then
    candidates = vim.fn.getcompletion(token.value, 'dir')
  else return {} end
  local prefix = before:sub(start + token.start - 1, #before - #lead)
  local result = {}
  for _, candidate in ipairs(candidates) do
    if candidate:sub(1, #token.value) == token.value then
      local encoded = M.quote(candidate, token.quote)
      if encoded:sub(1, #prefix) == prefix then result[#result + 1] = encoded:sub(#prefix + 1) end
    end
  end
  return result
end

return M
