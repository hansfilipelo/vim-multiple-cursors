local highlight = require("multi-cursors.highlight")

---@class Cursor
---@field position number[] {line, col} 1-indexed
---@field visual number[][] region {{l,c},{l,c}} or empty
---@field saved_visual number[][] saved region for reposition
---@field paste_buffer_text string saved unnamed register content
---@field paste_buffer_type string saved unnamed register type
---@field cursor_extmark_id number|nil extmark id for cursor highlight
---@field visual_extmark_id number|nil extmark id for visual highlight
---@field line_length number column count of the line (col('$'))
---@field bufnr number buffer number
local Cursor = {}
Cursor.__index = Cursor

--- Create a new Cursor
---@param position number[] {line, col}
---@param bufnr number
---@return Cursor
function Cursor.new(position, bufnr)
  local self = setmetatable({}, Cursor)
  self.position = { position[1], position[2] }
  self.visual = {}
  self.saved_visual = {}
  self.paste_buffer_text = vim.fn.getreg('"')
  self.paste_buffer_type = vim.fn.getregtype('"')
  self.bufnr = bufnr
  self.cursor_extmark_id = highlight.highlight_cursor(bufnr, position)
  self.visual_extmark_id = nil
  self.line_length = vim.fn.col({ position[1], "$" })
  self.insert_col = nil -- insert mode column (set when entering insert mode)
  -- Open any fold at this position
  pcall(function()
    vim.cmd(position[1] .. "foldopen!")
  end)
  return self
end

--- Return the line number
---@return number
function Cursor:line()
  return self.position[1]
end

--- Return the column number
---@return number
function Cursor:column()
  return self.position[2]
end

--- Move position by delta line and column. Also moves visual region.
---@param dline number
---@param dcol number
function Cursor:move(dline, dcol)
  self.position[1] = self.position[1] + dline
  self.position[2] = self.position[2] + dcol
  if #self.visual > 0 then
    self.visual[1][1] = self.visual[1][1] + dline
    self.visual[1][2] = self.visual[1][2] + dcol
    self.visual[2][1] = self.visual[2][1] + dline
    self.visual[2][2] = self.visual[2][2] + dcol
  end
  if self.insert_col then
    self.insert_col = self.insert_col + dcol
  end
  self:update_highlight()
end

--- Update position to a new [line, col]
---@param pos number[]
function Cursor:update_position(pos)
  self.position[1] = pos[1]
  self.position[2] = pos[2]
  self:update_highlight()
end

--- Reapply cursor highlight.
--- When insert_col is set, highlight at the insert point instead of position.
function Cursor:update_highlight()
  highlight.remove_extmark(self.bufnr, self.cursor_extmark_id)
  local pos = self.position
  if self.insert_col then
    pos = { self.position[1], self.insert_col }
  end
  self.cursor_extmark_id = highlight.highlight_cursor(self.bufnr, pos)
end

--- Refresh line_length for the cursor's line
function Cursor:update_line_length()
  self.line_length = vim.fn.col({ self:line(), "$" })
end

--- Update visual selection and its highlight
---@param rgn number[][] region
---@param mode string|nil "V" for linewise
function Cursor:update_visual_selection(rgn, mode)
  self.visual = vim.deepcopy(rgn)
  highlight.remove_extmark(self.bufnr, self.visual_extmark_id)
  self.visual_extmark_id = highlight.highlight_region(self.bufnr, rgn, mode)
end

--- Remove visual selection and its highlight
function Cursor:remove_visual_selection()
  self.saved_visual = vim.deepcopy(self.visual)
  self.visual = {}
  highlight.remove_extmark(self.bufnr, self.visual_extmark_id)
  self.visual_extmark_id = nil
end

--- Restore the unnamed register from this cursor's paste buffer
function Cursor:restore_unnamed_register()
  vim.fn.setreg('"', self.paste_buffer_text, self.paste_buffer_type)
end

--- Save the unnamed register into this cursor's paste buffer
function Cursor:save_unnamed_register()
  self.paste_buffer_text = vim.fn.getreg('"')
  self.paste_buffer_type = vim.fn.getregtype('"')
end

--- Clean up all highlights
function Cursor:destroy()
  highlight.remove_extmark(self.bufnr, self.cursor_extmark_id)
  highlight.remove_extmark(self.bufnr, self.visual_extmark_id)
  self.cursor_extmark_id = nil
  self.visual_extmark_id = nil
end

return Cursor
