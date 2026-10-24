local M = { phi = (1 + math.sqrt(5)) / 2 }

function M.anchor(marks, preferred)
  if preferred and marks[preferred] then return preferred end
  for i, mark in ipairs(marks) do if not mark.skipped then return i end end
end

function M.neighbors(marks, anchor, previous, following)
  if not anchor or not marks[anchor] then return { { distance = 0 } } end
  local rows, before, after = {}, {}, {}
  for i = anchor - 1, 1, -1 do
    if not marks[i].skipped and #before < previous then before[#before + 1] = i end
    if #before == previous then break end
  end
  for i = anchor + 1, #marks do
    if not marks[i].skipped and #after < following then after[#after + 1] = i end
    if #after == following then break end
  end
  for i = #before, 1, -1 do rows[#rows + 1] = { index = before[i], distance = -i } end
  rows[#rows + 1] = { index = anchor, distance = 0 }
  for i, index in ipairs(after) do rows[#rows + 1] = { index = index, distance = i } end
  return rows
end

function M.fit(rows, height, minimum)
  rows = vim.deepcopy(rows)
  minimum = math.max(2, minimum or 2)
  -- Reserve a winbar and a separator for each row, plus text minima.
  while #rows > 1 and (math.max(8, minimum) + minimum * (#rows - 1) + 2 * #rows) > height do
    if math.abs(rows[1].distance) > math.abs(rows[#rows].distance) then table.remove(rows, 1)
    else table.remove(rows) end
  end
  return rows
end

function M.heights(rows, total, minimum)
  total = math.max(#rows, math.floor(total))
  minimum = math.max(2, minimum or 2)
  local heights, pending, left = {}, {}, total
  for i in ipairs(rows) do pending[i] = true end
  while next(pending) do
    local weight, count = 0, 0
    for i in pairs(pending) do weight = weight + M.phi ^ -math.abs(rows[i].distance); count = count + 1 end
    local pinned = false
    for i in pairs(pending) do
      local floor = rows[i].distance == 0 and math.min(math.max(8, minimum), total - #rows + 1)
        or math.min(minimum, math.floor(total / #rows))
      local share = left * M.phi ^ -math.abs(rows[i].distance) / weight
      if share < floor and left - floor >= count - 1 then
        heights[i], pending[i], left, pinned = floor, nil, left - floor, true
        break
      end
    end
    if not pinned then
      local fractions, used = {}, 0
      for i in pairs(pending) do
        local exact = left * M.phi ^ -math.abs(rows[i].distance) / weight
        heights[i] = math.max(1, math.floor(exact))
        used = used + heights[i]
        fractions[#fractions + 1] = { i = i, part = exact - math.floor(exact) }
      end
      table.sort(fractions, function(a, b) return a.part == b.part and a.i < b.i or a.part > b.part end)
      for n = 1, left - used do heights[fractions[(n - 1) % #fractions + 1].i] = heights[fractions[(n - 1) % #fractions + 1].i] + 1 end
      break
    end
  end
  return heights
end

return M
