local M = {}

local ns = vim.api.nvim_create_namespace("multi_cursors")

M.ns = ns
M.cursor_hl_group = "MultipleCursorsCursor"
M.visual_hl_group = "MultipleCursorsVisual"

--- Set up default highlight groups (only if not already defined by user)
function M.setup_defaults()
  -- Cursor: reverse video (like the real cursor)
  if vim.fn.hlexists(M.cursor_hl_group) == 0 or vim.api.nvim_get_hl(0, { name = M.cursor_hl_group }) == nil
      or next(vim.api.nvim_get_hl(0, { name = M.cursor_hl_group })) == nil then
    vim.api.nvim_set_hl(0, M.cursor_hl_group, { reverse = true, default = true })
  end
  -- Visual selection: link to Visual
  if vim.fn.hlexists(M.visual_hl_group) == 0 or vim.api.nvim_get_hl(0, { name = M.visual_hl_group }) == nil
      or next(vim.api.nvim_get_hl(0, { name = M.visual_hl_group })) == nil then
    vim.api.nvim_set_hl(0, M.visual_hl_group, { link = "Visual", default = true })
  end
end

--- Highlight a single cursor position using extmarks.
--- Returns the extmark id.
---@param bufnr number
---@param pos number[] { line, col } (1-indexed)
---@return number extmark_id
function M.highlight_cursor(bufnr, pos)
  local line = pos[1] - 1 -- 0-indexed
  local col = pos[2] - 1 -- 0-indexed byte
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line < 0 or line >= line_count then
    return nil
  end
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
  local line_len = #line_text

  if col >= line_len then
    -- Past end of line: use virtual text to show cursor
    return vim.api.nvim_buf_set_extmark(bufnr, ns, line, line_len, {
      virt_text = { { " ", M.cursor_hl_group } },
      virt_text_pos = "overlay",
      priority = 10000,
    })
  else
    -- Highlight the character at the cursor position.
    -- Find the end byte of the current character (handles multi-byte).
    local char_end = col + 1
    while char_end < line_len and bit.band(line_text:byte(char_end + 1), 0xC0) == 0x80 do
      char_end = char_end + 1
    end
    return vim.api.nvim_buf_set_extmark(bufnr, ns, line, col, {
      end_col = char_end,
      hl_group = M.cursor_hl_group,
      priority = 10000,
    })
  end
end

--- Highlight a visual region using extmarks.
--- Returns the extmark id.
---@param bufnr number
---@param rgn number[][] { start_pos, end_pos } (1-indexed)
---@param mode string|nil "V" for line-wise, defaults to characterwise
---@return number extmark_id
function M.highlight_region(bufnr, rgn, mode)
  -- Sort the region so start <= end
  local s, e
  if rgn[1][1] < rgn[2][1] or (rgn[1][1] == rgn[2][1] and rgn[1][2] <= rgn[2][2]) then
    s, e = rgn[1], rgn[2]
  else
    s, e = rgn[2], rgn[1]
  end

  local start_line = s[1] - 1
  local start_col = s[2] - 1
  local end_line = e[1] - 1
  local end_col = e[2] -- extmark end_col is exclusive, so e[2] (1-indexed) = e[2]-1+1

  if mode == "V" then
    -- Line-wise: highlight full lines
    start_col = 0
    local last_line_text = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
    end_col = #last_line_text
  end

  return vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, start_col, {
    end_row = end_line,
    end_col = end_col,
    hl_group = M.visual_hl_group,
    priority = 9999,
  })
end

--- Remove a specific extmark
---@param bufnr number
---@param id number|nil
function M.remove_extmark(bufnr, id)
  if id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  end
end

--- Clear all extmarks in the namespace for a buffer
---@param bufnr number
function M.clear_all(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

return M
