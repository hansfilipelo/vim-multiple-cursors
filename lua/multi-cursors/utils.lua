local M = {}

--- Return [line, col] for a mark string like "." or "'<"
---@param mark string
---@return number[] [line, col]
function M.pos(mark)
  local p = vim.fn.getpos(mark)
  return { p[2], p[3] }
end

--- Return { start_pos, end_pos } for two marks
---@param start_mark string
---@param end_mark string
---@return number[][] region
function M.region(start_mark, end_mark)
  return { M.pos(start_mark), M.pos(end_mark) }
end

--- Compare two [line, col] positions.
--- Returns negative if l < r, positive if l > r, 0 if equal.
---@param l number[]
---@param r number[]
---@return number
function M.compare_pos(l, r)
  if l[1] == r[1] then
    return l[2] - r[2]
  end
  return l[1] - r[1]
end

--- Check if two positions are equal
---@param a number[]
---@param b number[]
---@return boolean
function M.pos_equal(a, b)
  return a[1] == b[1] and a[2] == b[2]
end

--- Get the text content between a region { {l1,c1}, {l2,c2} }
---@param rgn number[][]
---@return string
function M.get_text(rgn)
  local start_pos = rgn[1]
  local end_pos = rgn[2]
  local lines = vim.fn.getline(start_pos[1], end_pos[1])
  if #lines == 0 then
    return ""
  end
  -- Trim last line to end column
  lines[#lines] = string.sub(lines[#lines], 1, end_pos[2])
  -- Trim first line from start column
  lines[1] = string.sub(lines[1], start_pos[2])
  return table.concat(lines, "\n")
end

--- Find next occurrence of text in the buffer.
--- Returns { start_pos, end_pos } or nil.
---@param text string
---@param use_word_boundary boolean
---@return number[][]|nil
function M.find_next(text, use_word_boundary)
  local pattern = vim.fn.escape(text, "\\")
  pattern = string.gsub(pattern, "\n", "\\n")
  if use_word_boundary then
    pattern = "\\<" .. pattern .. "\\>"
  end
  pattern = "\\V\\C" .. pattern
  local found = vim.fn.search(pattern)
  if found == 0 then
    return nil
  end
  local start_pos = M.pos(".")
  vim.fn.search(pattern, "ce")
  local end_pos = M.pos(".")
  return { start_pos, end_pos }
end

--- Exit visual mode and return to normal mode, preserving cursor position.
function M.exit_visual_mode()
  vim.cmd('execute "normal! \\<Esc>gv\\<Esc>"')
end

--- Select a region in visual mode
---@param rgn number[][] { start_pos, end_pos }
function M.select_in_visual_mode(rgn)
  if M.pos_equal(rgn[1], rgn[2]) then
    vim.cmd("normal! v")
  else
    vim.fn.cursor(rgn[2])
    vim.cmd("normal! m`")
    vim.fn.cursor(rgn[1])
    vim.cmd("normal! v``")
  end
  -- Reselect to set '< and '> marks
  vim.cmd('execute "normal! \\<Esc>gv"')
end

--- Update '< and '> marks to match a region, ending in normal mode
---@param rgn number[][] { start_pos, end_pos }
function M.update_visual_markers(rgn)
  if M.pos_equal(rgn[1], rgn[2]) then
    vim.cmd("normal! v")
  else
    vim.fn.cursor(rgn[2])
    vim.cmd("normal! m`")
    vim.fn.cursor(rgn[1])
    vim.cmd("normal! v``")
  end
  M.exit_visual_mode()
end

--- Get visual region relative to cursor position
---@param pos number[]
---@return number[][]
function M.get_visual_region(pos)
  local left = M.pos("'<")
  local right = M.pos("'>")
  if M.pos_equal(pos, left) then
    return { right, left }
  else
    return { left, right }
  end
end

--- Safely get a character, returning its string representation
---@param peek boolean|nil if true, use getchar(0) for non-blocking
---@return string
function M.get_char(peek)
  local ok, c
  if peek then
    ok, c = pcall(vim.fn.getchar, 0)
  else
    ok, c = pcall(vim.fn.getchar)
  end
  if not ok then
    return ""
  end
  if type(c) == "number" then
    if c == 0 then
      return ""
    end
    return vim.fn.nr2char(c)
  end
  return c
end

return M
